#!/usr/bin/env bash
# 22_drill_pitr.sh : 장애 훈련 5 PITR (시점 복구) (full 상태, Leader 에서 root 로 실행)
#   시나리오: 주문 보관 표를 실수로 DROP 했다. 운영 DB 는 그대로 두고, 별도 경로에 DROP 직전 시점까지 복구해 확인한다.
#   10-1 full 백업
#   10-2 표 lab_pitr 에 1,000건 -> 목표 시각 기록 -> 목표 뒤 10건 -> DROP TABLE -> WAL 넘기고 아카이브 확인
#   10-3 pgbackrest restore --type=time 으로 /data/pgsql/lab-work/pitr_<시각> 에 복구
#   10-4 임시 인스턴스(소켓 전용, 5433)로 띄워 1,000건이 있고 목표 뒤 10건은 없는지 확인, 걸린 시간 기록
#   운영에서 실제로 되살릴 때는 복구본에서 pg_dump -t 로 표만 꺼내 운영 DB 에 넣는다 (여기서는 확인까지만)
set -euo pipefail
source "$(dirname "$0")/lab_lib.sh"
pgbr() { runuser -u postgres -- pgbackrest --stanza=lab "$@"; }

[ "${1:-}" = "run" ] || die "사용법: 22_drill_pitr.sh run"
[ "$(in_recovery)" = "f" ] || die "${HOST} 는 Leader 가 아니다"
STAMP=$(date +%Y%m%d_%H%M%S)
install -d -m 700 -o postgres -g postgres "$WORK"

step "10-1" "full 백업"
T0=$(now_ms)
pgbr --type=full backup
result "full 백업: $(secs "$T0" "$(now_ms)")초"

step "10-2" "데이터 넣기, 목표 시각, 실수로 DROP"
psql_pg -d "$DB" -q <<'SQL'
DROP TABLE IF EXISTS lab_pitr;
CREATE TABLE lab_pitr (id int PRIMARY KEY, note text NOT NULL, at timestamptz NOT NULL DEFAULT now());
INSERT INTO lab_pitr (id, note) SELECT g, 'before target' FROM generate_series(1, 1000) g;
SQL
sleep 2
TARGET=$(psql_q -c "SELECT to_char(clock_timestamp(), 'YYYY-MM-DD HH24:MI:SS.US') || to_char(clock_timestamp(), 'TZH')")
result "목표 시각: ${TARGET}"
sleep 2
psql_pg -d "$DB" -q -c "INSERT INTO lab_pitr (id, note) SELECT g, 'after target' FROM generate_series(1001, 1010) g;"
psql_pg -d "$DB" -c "SELECT note, count(*) FROM lab_pitr GROUP BY note ORDER BY note;"
sleep 1
psql_pg -d "$DB" -q -c "DROP TABLE lab_pitr;"
DROP_AT=$(date '+%H:%M:%S')
result "${DROP_AT} DROP TABLE lab_pitr (실수)"
psql_pg -d "$DB" -c "SELECT to_regclass('lab_pitr') AS lab_pitr_now;"
SEG=$(psql_q -c "SELECT pg_walfile_name(pg_switch_wal())")
log "DROP 이 들어 있는 WAL ${SEG} 의 아카이브 대기"
for i in $(seq 1 60); do
  LAST=$(psql_q -c "SELECT coalesce(last_archived_wal, '') FROM pg_stat_archiver")
  [ -n "$LAST" ] && [[ ! "$LAST" < "$SEG" ]] && break
  sleep 1
done
psql_pg -c "SELECT last_archived_wal, last_archived_time, failed_count FROM pg_stat_archiver;"

step "10-3" "별도 경로에 목표 시각까지 복구 (pgbackrest restore --type=time)"
RDIR="${WORK}/pitr_${STAMP}"
install -d -m 700 -o postgres -g postgres "$RDIR"
restorecon -R "$WORK" >/dev/null 2>&1 || true
T0=$(now_ms)
pgbr --pg1-path="$RDIR" --type=time "--target=${TARGET}" --target-action=promote restore
T1=$(now_ms)
result "restore (파일 복원): $(secs "$T0" "$T1")초, $(du -sh "$RDIR" | cut -f1)"
grep -E '^(restore_command|recovery_target)' "${RDIR}/postgresql.auto.conf" | sed 's/^/  /' || true

step "10-4" "임시 인스턴스로 띄워 확인"
OPTS="-p 5433 -c listen_addresses='' -c unix_socket_directories=/run/postgresql -c archive_mode=off -c hot_standby=off -c logging_collector=off -c shared_buffers=128MB -c cluster_name=lab_pitr -c data_directory=${RDIR} -c hba_file=${RDIR}/pg_hba.conf -c ident_file=${RDIR}/pg_ident.conf"
T2=$(now_ms)
runuser -u postgres -- "${PGBIN}/pg_ctl" -D "$RDIR" -o "$OPTS" -l "${RDIR}.log" -w -t 600 start
wait_tmp_instance 600 || die "임시 인스턴스가 접속을 받지 않는다 (${RDIR}.log 확인)"
T3=$(now_ms)
result "기동 (WAL 재생, 목표 시각에서 멈추고 승격): $(secs "$T2" "$T3")초"
result "복구 전체 (restore + 기동): $(secs "$T0" "$T3")초"
grep -Ei 'recovery stopping|recovery has paused|selected new timeline|archive recovery complete|consistent recovery state' "${RDIR}.log" | sed 's/^/  /' | tail -5 || true
runuser -u postgres -- "${PGBIN}/psql" -X -p 5433 -h /run/postgresql -d "$DB" -c "SELECT note, count(*), min(at), max(at) FROM lab_pitr GROUP BY note ORDER BY note;"
N=$(runuser -u postgres -- "${PGBIN}/psql" -X -Atq -p 5433 -h /run/postgresql -d "$DB" -c "SELECT count(*) FROM lab_pitr")
if [ "$N" = "1000" ]; then result "복구본에 목표 시각 전 1,000건이 있고, 목표 뒤 10건과 DROP 은 반영되지 않았다"; else result "복구본 건수 ${N} (기대 1000)"; fi
log "운영에서 되살릴 때 쓰는 명령 (여기서는 실행하지 않음)"
echo "  pg_dump -p 5433 -h /run/postgresql -d lab_tuning -t lab_pitr -Fc -f lab_pitr.dump"
echo "  pg_restore -d lab_tuning lab_pitr.dump"
runuser -u postgres -- "${PGBIN}/pg_ctl" -D "$RDIR" -m fast -w stop
psql_pg -d "$DB" -c "SELECT to_regclass('lab_pitr') AS lab_pitr_in_production;"
done_ok "PITR"
