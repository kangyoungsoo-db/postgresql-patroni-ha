#!/usr/bin/env bash
# 15_manual_failover.sh : 실습 3 수동 페일오버 (baseline 스냅샷 상태에서 root 로 실행)
#   시나리오: 복제가 끊긴 사이 Primary(data-db1) 에만 쓴 데이터가 있는 상태에서 Primary 가 비정상 종료된다.
#             Standby(data-db2) 를 pg_promote 로 승격하고, 옛 Primary 를 pg_rewind 로 되감아 새 Standby 로 붙인다.
#   단계 (실행 위치)
#     prepare (data-db1) : 실습 표 lab_failover 와 '전환 전' 100건, Standby 가 따라올 때까지 대기
#     cut     (data-db2) : primary_conninfo 를 비워 복제를 끊는다
#     crash   (data-db1) : '복제 안 된' 50건을 쓰고 postmaster 를 kill -9
#     promote (data-db2) : pg_promote, 타임라인 확인, '승격 뒤' 30건, pg_rewind 준비(권한, pg_hba, 슬롯)
#     rewind  (data-db1) : pg_rewind 로 data-db2 기준으로 되감고 Standby 로 기동
#     verify  (data-db2) : 복제 상태, 양쪽 건수 비교
#   비밀번호: 호스트가 /home/vagrant/lab-repl_pw 로 올린 파일을 rewind 단계에서 postgres 의 .pgpass(600) 로 옮기고 바로 지운다.
set -euo pipefail
source "$(dirname "$0")/lab_lib.sh"

PART=${1:-}
systemctl is-active --quiet patroni 2>/dev/null && die "patroni 가 실행 중이다. baseline 스냅샷에서만 실행한다"
STATE_FILE=${RESULTS}/lab3_times.txt
mark() { echo "$1=$(now_ms)" >> "$STATE_FILE"; }

case "$PART" in
prepare)
  [ "$HOST" = "data-db1" ] || die "data-db1 에서 실행한다"
  [ "$(in_recovery)" = "f" ] || die "data-db1 이 Primary 가 아니다"
  : > "$STATE_FILE"
  step "3-1" "준비 : 실습 표와 전환 전 데이터"
  psql_pg -d "$DB" -q <<'SQL'
DROP TABLE IF EXISTS lab_failover;
CREATE TABLE lab_failover (id serial PRIMARY KEY, phase text NOT NULL, node text NOT NULL, at timestamptz NOT NULL DEFAULT now());
INSERT INTO lab_failover (phase, node) SELECT '1_before', 'data-db1' FROM generate_series(1, 100);
SQL
  for i in $(seq 1 30); do
    [ "$(psql_q -c "SELECT count(*) FROM pg_stat_replication WHERE replay_lsn = pg_current_wal_lsn()")" = "1" ] && break
    sleep 1
  done
  psql_pg -c "SELECT application_name, state, pg_current_wal_lsn() AS primary_lsn, replay_lsn, replay_lag FROM pg_stat_replication;"
  psql_pg -c "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;"
  psql_pg -d "$DB" -c "SELECT phase, count(*) FROM lab_failover GROUP BY phase ORDER BY phase;"
  psql_pg -c "SELECT timeline_id, redo_lsn FROM pg_control_checkpoint();"
  done_ok "prepare"
  ;;

cut)
  [ "$HOST" = "data-db2" ] || die "data-db2 에서 실행한다"
  step "3-2" "Standby 쪽에서 복제 끊기"
  psql_pg -d "$DB" -c "SELECT phase, count(*) FROM lab_failover GROUP BY phase ORDER BY phase;"
  psql_pg -q -c "ALTER SYSTEM SET primary_conninfo = '';"
  psql_pg -q -c "SELECT pg_reload_conf();"
  for i in $(seq 1 20); do
    [ "$(psql_q -c 'SELECT count(*) FROM pg_stat_wal_receiver')" = "0" ] && break
    sleep 1
  done
  psql_pg -c "SELECT count(*) AS wal_receiver FROM pg_stat_wal_receiver;"
  psql_pg -c "SELECT pg_last_wal_replay_lsn() AS replay_lsn;"
  done_ok "cut"
  ;;

crash)
  [ "$HOST" = "data-db1" ] || die "data-db1 에서 실행한다"
  step "3-3" "복제가 끊긴 Primary 에만 쓰고 비정상 종료 (kill -9)"
  psql_pg -c "SELECT count(*) AS replicas_connected FROM pg_stat_replication;"
  psql_pg -d "$DB" -q -c "INSERT INTO lab_failover (phase, node) SELECT '2_not_replicated', 'data-db1' FROM generate_series(1, 50);"
  psql_pg -q -c "CHECKPOINT;"
  psql_pg -d "$DB" -c "SELECT phase, count(*) FROM lab_failover GROUP BY phase ORDER BY phase;"
  psql_pg -c "SELECT pg_current_wal_lsn() AS primary_lsn;"
  PID=$(head -1 "${PGDATA}/postmaster.pid")
  mark crash
  kill -9 "$PID"
  log "postmaster(PID ${PID}) 에 SIGKILL 을 보냈다"
  sleep 2
  systemctl stop postgresql-17 >/dev/null 2>&1 || true
  pgrep -u postgres -f "${PGBIN}/postgres" >/dev/null && die "postgres 가 아직 살아 있다"
  result "data-db1 PostgreSQL 이 내려갔다 (systemd 재시작도 막음)"
  done_ok "crash"
  ;;

promote)
  [ "$HOST" = "data-db2" ] || die "data-db2 에서 실행한다"
  step "3-4" "Standby 승격 (pg_promote)"
  psql_pg -c "SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();"
  T0=$(now_ms)
  psql_pg -c "SELECT pg_promote(true, 60);"
  T1=$(now_ms)
  mark promoted
  result "pg_promote : $(secs "$T0" "$T1")초"
  psql_pg -c "SELECT pg_is_in_recovery(), substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8) AS timeline_hex;"
  psql_pg -d "$DB" -q -c "INSERT INTO lab_failover (phase, node) SELECT '3_after_promote', 'data-db2' FROM generate_series(1, 30);"
  psql_pg -d "$DB" -c "SELECT phase, count(*) FROM lab_failover GROUP BY phase ORDER BY phase;"
  log "pg_rewind 준비 : replicator 에 필요한 함수 권한, pg_hba 한 줄, data-db1 용 복제 슬롯"
  psql_pg -q <<'SQL'
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean) TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean) TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO replicator;
SELECT pg_create_physical_replication_slot('data_db1') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'data_db1');
SQL
  HBA="${PGDATA}/pg_hba.conf"
  if ! grep -q 'lab3 pg_rewind' "$HBA"; then
    cp -p "$HBA" "${HBA}.bak.$(date +%Y%m%d%H%M%S)"
    echo 'host    postgres        replicator      192.168.56.11/32        scram-sha-256   # lab3 pg_rewind' >> "$HBA"
    psql_pg -q -c "SELECT pg_reload_conf();"
  fi
  psql_pg -c "SELECT slot_name, active FROM pg_replication_slots;"
  done_ok "promote"
  ;;

rewind)
  [ "$HOST" = "data-db1" ] || die "data-db1 에서 실행한다"
  step "3-5" "옛 Primary 를 pg_rewind 로 되감고 새 Standby 로 붙이기"
  UP=/home/vagrant/lab-repl_pw
  [ -s "$UP" ] || die "${UP} 가 없다 (호스트에서 올려야 한다)"
  PGPASS=/var/lib/pgsql/.pgpass
  [ -e "$PGPASS" ] && cp -p "$PGPASS" "${PGPASS}.bak.$(date +%Y%m%d%H%M%S)"
  (
    umask 077
    IFS= read -r pw < "$UP" || true   # 끝에 줄바꿈이 없는 파일도 읽는다
    pw=${pw%$'\r'}
    [ -n "$pw" ] || exit 3
    pw=${pw//\\/\\\\}; pw=${pw//:/\\:}
    printf 'data-db2:5432:*:replicator:%s\n' "$pw" > "$PGPASS"
  ) && RC=0 || RC=$?
  rm -f "$UP"
  [ "$RC" = "0" ] || die "비밀번호 파일을 읽지 못했다"
  chown postgres:postgres "$PGPASS"; chmod 600 "$PGPASS"
  log "비밀번호를 postgres 의 .pgpass(600) 로 옮기고 올린 파일을 지웠다"
  systemctl is-active --quiet postgresql-17 && die "data-db1 PostgreSQL 이 실행 중이다"
  T0=$(now_ms)
  runuser -u postgres -- env PGPASSFILE="$PGPASS" "${PGBIN}/pg_rewind" -D "$PGDATA" \
    --source-server="host=data-db2 port=5432 user=replicator dbname=postgres" --progress
  T1=$(now_ms)
  result "pg_rewind : $(secs "$T0" "$T1")초"
  cat >> "${PGDATA}/postgresql.auto.conf" <<'EOF'
# lab3: pg_rewind 뒤 data-db2 를 따라가는 Standby 설정
primary_conninfo = 'host=data-db2 port=5432 user=replicator application_name=data-db1'
primary_slot_name = 'data_db1'
EOF
  runuser -u postgres -- touch "${PGDATA}/standby.signal"
  restorecon -R /data/pgsql >/dev/null 2>&1 || true
  T0=$(now_ms)
  systemctl start postgresql-17
  for i in $(seq 1 60); do
    [ "$(psql_q -c "SELECT status FROM pg_stat_wal_receiver" 2>/dev/null)" = "streaming" ] && break
    sleep 1
  done
  T1=$(now_ms)
  result "기동부터 streaming 까지 : $(secs "$T0" "$T1")초"
  psql_pg -c "SELECT pg_is_in_recovery(), status, sender_host, slot_name FROM pg_stat_wal_receiver;"
  psql_pg -d "$DB" -c "SELECT phase, node, count(*) FROM lab_failover GROUP BY phase, node ORDER BY phase;"
  done_ok "rewind"
  ;;

verify)
  [ "$HOST" = "data-db2" ] || die "data-db2 에서 실행한다"
  step "3-6" "확인 : 새 Primary(data-db2) 와 새 Standby(data-db1)"
  psql_pg -c "SELECT application_name, client_addr, state, sync_state, replay_lag FROM pg_stat_replication;"
  psql_pg -d "$DB" -c "SELECT phase, node, count(*) FROM lab_failover GROUP BY phase, node ORDER BY phase;"
  LOST=$(psql_q -d "$DB" -c "SELECT 50 - count(*) FROM lab_failover WHERE phase = '2_not_replicated'")
  result "복제되지 못하고 사라진 행: ${LOST}건 (data-db1 에만 쓰였던 50건 중)"
  psql_pg -c "SELECT substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8) AS timeline_hex;"
  done_ok "verify"
  ;;

*)
  die "사용법: 15_manual_failover.sh prepare|cut|crash|promote|rewind|verify"
  ;;
esac
