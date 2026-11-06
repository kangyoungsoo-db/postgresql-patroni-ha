#!/usr/bin/env bash
# 21_drill_backup_fail.sh : 장애 훈련 4 백업 실패 재현과 경보 (full 상태, root 로 실행)
#   백업 저장소(MinIO)를 멈추면 백업과 WAL 아카이브가 실패하고, 백업 시각 지표가 사라져 경보가 firing 된다.
#   경보 규칙(12_monitoring.sh): 마지막 성공 백업이 26시간보다 오래되었거나 "지표가 없으면" 10분 뒤 firing.
#   여기서는 26시간을 기다릴 수 없으므로, 저장소가 죽어 지표가 사라지는 실제 경로(absent)로 firing 을 확인한다.
#   전체 흐름
#     1. data-mgmt : alert                    (지금 경보 상태와 마지막 백업 뒤 지난 시간)
#     2. data-mgmt : minio-stop
#     3. data-db1  : backup-fail              (백업 실패 메시지, 아카이브 실패 수, 쌓이는 WAL)
#     4. data-db1, data-db2 : metric          (지표 갱신을 바로 실행)
#     5. data-mgmt : alert-wait firing 900    (inactive -> pending -> firing 시각)
#     6. data-mgmt : minio-start
#     7. data-db1  : backup-ok                (백업 성공, 밀린 WAL 아카이브 따라잡기)
#     8. data-db1, data-db2 : metric
#     9. data-mgmt : alert-wait inactive 300  (경보가 풀리는 시각)
set -euo pipefail
source "$(dirname "$0")/lab_lib.sh"
pgbr() { runuser -u postgres -- pgbackrest --stanza=lab "$@"; }

alert_state() {   # PgBackRestBackupTooOld 의 상태 (inactive / pending / firing)
  python3 - <<'PY'
import json, urllib.request
try:
    d = json.load(urllib.request.urlopen("http://127.0.0.1:9090/api/v1/alerts", timeout=5))["data"]["alerts"]
    s = [a["state"] for a in d if a["labels"].get("alertname") == "PgBackRestBackupTooOld"]
    print(s[0] if s else "inactive")
except Exception as e:
    print("error")
PY
}
prom_value() {   # $1=PromQL
  python3 - "$1" <<'PY'
import json, sys, urllib.parse, urllib.request
q = urllib.parse.urlencode({"query": sys.argv[1]})
try:
    r = json.load(urllib.request.urlopen("http://127.0.0.1:9090/api/v1/query?" + q, timeout=5))["data"]["result"]
    print(", ".join("%s" % round(float(x["value"][1]), 1) for x in r) if r else "(값 없음)")
except Exception as e:
    print("error")
PY
}

case "${1:-}" in
alert)
  [ "$HOST" = "data-mgmt" ] || die "data-mgmt 에서 실행한다"
  step "9" "$(date '+%H:%M:%S') 경보와 백업 지표"
  echo "  PgBackRestBackupTooOld 상태: $(alert_state)"
  echo "  마지막 성공 백업 뒤 지난 초 : $(prom_value 'time() - max(lab_backup_last_success_timestamp_seconds)')"
  echo "  저장소 읽기 성공(1) 여부    : $(prom_value 'lab_backup_info_ok')"
  echo "  저장소의 성공 백업 수       : $(prom_value 'lab_backup_count')"
  done_ok "alert"
  ;;
minio-stop)
  step "9-1" "$(date '+%H:%M:%S') MinIO 중지 (백업 저장소 장애)"
  systemctl stop minio
  echo "  minio: $(systemctl is-active minio || true)"
  done_ok "minio-stop"
  ;;
minio-start)
  step "9-5" "$(date '+%H:%M:%S') MinIO 시작 (저장소 복구)"
  systemctl start minio
  for i in $(seq 1 30); do curl -ksf https://127.0.0.1:9000/minio/health/live >/dev/null && break; sleep 2; done
  echo "  minio: $(systemctl is-active minio || true), health/live HTTP $(curl -ks -o /dev/null -w '%{http_code}' https://127.0.0.1:9000/minio/health/live)"
  done_ok "minio-start"
  ;;
backup-fail)
  [ "$(in_recovery)" = "f" ] || die "${HOST} 는 Leader 가 아니다"
  step "9-2" "$(date '+%H:%M:%S') 저장소가 없는 상태에서 백업 시도"
  T0=$(now_ms)
  set +e
  pgbr --type=incr --io-timeout=10 --db-timeout=30 backup > /tmp/lab_bk.txt 2>&1
  RC=$?
  set -e
  T1=$(now_ms)
  grep -E 'ERROR|WARN' /tmp/lab_bk.txt | head -4 | sed 's/^/  /'
  result "pgbackrest backup 종료 코드 ${RC} ($(secs "$T0" "$T1")초 뒤 실패)"
  log "WAL 을 하나 넘겨서 아카이브도 실패하는지 본다"
  psql_pg -d "$DB" -q -c "CREATE TABLE IF NOT EXISTS lab_walgen (id int); INSERT INTO lab_walgen SELECT generate_series(1, 1000);"
  psql_pg -q -c "SELECT pg_switch_wal();"
  sleep 20
  psql_pg -c "SELECT archived_count, last_archived_wal, failed_count, last_failed_wal, last_failed_time FROM pg_stat_archiver;"
  result "아카이브를 기다리는 WAL(.ready) 수: $(ls "${PGDATA}/pg_wal/archive_status/" | grep -c '\.ready$' || true)"
  done_ok "backup-fail"
  ;;
backup-ok)
  [ "$(in_recovery)" = "f" ] || die "${HOST} 는 Leader 가 아니다"
  step "9-6" "$(date '+%H:%M:%S') 저장소 복구 뒤 밀린 아카이브와 백업"
  T0=$(now_ms)
  for i in $(seq 1 60); do
    [ "$(ls "${PGDATA}/pg_wal/archive_status/" | grep -c '\.ready$' || true)" = "0" ] && break
    sleep 2
  done
  result "밀린 WAL 아카이브가 모두 올라가기까지 $(secs "$T0" "$(now_ms)")초"
  psql_pg -c "SELECT archived_count, last_archived_wal, failed_count, last_failed_wal FROM pg_stat_archiver;"
  T0=$(now_ms)
  pgbr --type=incr backup
  result "incr 백업 성공: $(secs "$T0" "$(now_ms)")초"
  pgbr check && result "pgbackrest check 성공"
  pgbr info
  done_ok "backup-ok"
  ;;
metric)
  step "9" "$(date '+%H:%M:%S') ${HOST} 백업 지표 바로 갱신"
  systemctl start lab-backup-metric.service
  sed 's/^/  /' /var/lib/node_exporter/textfile/pgbackrest.prom | grep -v '^  #' || true
  done_ok "metric"
  ;;
alert-wait)
  [ "$HOST" = "data-mgmt" ] || die "data-mgmt 에서 실행한다"
  WANT=${2:?firing 또는 inactive}; MAXW=${3:-900}
  step "9" "경보가 ${WANT} 가 될 때까지 지켜보기 (최대 ${MAXW}초, 20초마다)"
  T0=$(now_ms); PREV=""
  while :; do
    S=$(alert_state)
    if [ "$S" != "$PREV" ]; then
      echo "  $(date '+%H:%M:%S') +$(secs "$T0" "$(now_ms)")초  상태 ${S}  (지표: $(prom_value 'max(lab_backup_last_success_timestamp_seconds)'))"
      PREV=$S
    fi
    [ "$S" = "$WANT" ] && break
    [ $(( ($(now_ms) - T0) / 1000 )) -ge "$MAXW" ] && { result "${MAXW}초 안에 ${WANT} 가 되지 않았다"; break; }
    sleep 20
  done
  result "${WANT} 까지 $(secs "$T0" "$(now_ms)")초"
  [ "$S" = "$WANT" ] || die "경보 상태가 기대와 다르다"
  done_ok "alert-wait"
  ;;
*)
  die "사용법: 21_drill_backup_fail.sh alert | minio-stop | minio-start | backup-fail | backup-ok | metric | alert-wait <firing|inactive> [최대 초]"
  ;;
esac
