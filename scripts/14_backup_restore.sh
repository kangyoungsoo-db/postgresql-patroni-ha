#!/usr/bin/env bash
# 14_backup_restore.sh : 실습 2 백업과 복구 (Leader 에서 root 로 실행)
#   2-1 pg_dump 논리 백업 (custom 형식) 과 역할 백업 (pg_dumpall --globals-only)
#   2-2 pg_restore 로 새 DB 에 복구하고 원본과 행 수, md5 비교
#   2-3 pgBackRest 백업 종류 (full 이 있는 상태에서 diff, incr) 와 info
#   2-4 pgBackRest 로 별도 경로에 복구하고 임시 인스턴스(소켓 전용, 5433)로 띄워 행 수 비교
# 지키는 것: 운영 데이터 디렉터리와 기존 DB 는 건드리지 않는다. 지우는 작업이 없다.
set -euo pipefail
source "$(dirname "$0")/lab_lib.sh"

[ "${1:-}" = "run" ] || die "사용법: 14_backup_restore.sh run"
[ "$(in_recovery)" = "f" ] || die "${HOST} 는 Leader 가 아니다"

STAMP=$(date +%Y%m%d_%H%M%S)
install -d -m 700 -o postgres -g postgres "$WORK"
restorecon -R /data/pgsql >/dev/null 2>&1 || true
pgbr() { runuser -u postgres -- pgbackrest --stanza=lab "$@"; }

# 표 하나의 지문 : 행 수와, 기본키 순서로 이어 붙인 전체 행의 md5
fingerprint() {   # $1=DB $2=표 $3=정렬 컬럼
  psql_q -d "$1" -c "SELECT count(*) || ' ' || md5(string_agg(t::text, '|' ORDER BY t.$3)) FROM $2 AS t"
}

step "2-1" "pg_dump 논리 백업"
DUMP="${WORK}/lab_tuning_${STAMP}.dump"
T0=$(now_ms)
runuser -u postgres -- "${PGBIN}/pg_dump" -Fc -d "$DB" -f "$DUMP"
T1=$(now_ms)
result "pg_dump -Fc : $(secs "$T0" "$T1")초, 파일 $(du -h "$DUMP" | cut -f1), DB 크기 $(psql_q -c "SELECT pg_size_pretty(pg_database_size('${DB}'))")"
log "덤프 안의 목록 (일부)"
runuser -u postgres -- "${PGBIN}/pg_restore" -l "$DUMP" | grep -E 'TABLE DATA|INDEX|CONSTRAINT' | head -12
GLOB="${WORK}/globals_${STAMP}.sql"
( umask 077; runuser -u postgres -- "${PGBIN}/pg_dumpall" --globals-only > "$GLOB" )
result "pg_dumpall --globals-only : 역할 $(grep -c '^CREATE ROLE' "$GLOB")개 (비밀번호 해시가 들어 있어 내용은 출력하지 않는다, 권한 600)"

step "2-2" "pg_restore 로 새 DB 에 복구하고 비교"
RDB="lab_restore_${STAMP}"
runuser -u postgres -- "${PGBIN}/createdb" "$RDB"
T0=$(now_ms)
runuser -u postgres -- "${PGBIN}/pg_restore" -j 2 -d "$RDB" "$DUMP"
T1=$(now_ms)
result "pg_restore -j 2 : $(secs "$T0" "$T1")초, 새 DB ${RDB}"
for spec in "customers customer_id" "orders order_id"; do
  set -- $spec
  A=$(fingerprint "$DB" "$1" "$2"); B=$(fingerprint "$RDB" "$1" "$2")
  if [ "$A" = "$B" ]; then same=같음; else same=다름; fi
  result "$1 원본 [$A] 복구 [$B] -> $same"
done
psql_pg -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size FROM pg_database WHERE datname IN ('${DB}', '${RDB}') ORDER BY 1;"

step "2-3" "pgBackRest 백업 종류 (diff, incr)"
log "백업 전 상태"
pgbr info
for t in diff incr; do
  T0=$(now_ms)
  pgbr --type="$t" backup
  T1=$(now_ms)
  result "${t} 백업 : $(secs "$T0" "$T1")초"
done
pgbr info
pgbr --output=json info | python3 -c '
import json, sys
for s in json.load(sys.stdin):
    for b in s.get("backup", []):
        print("  %-38s %-5s 원본 %7.1f MB, 저장 %6.1f MB, 걸린 시간 %d초" % (
            b["label"], b["type"], b["info"]["size"] / 1048576, b["info"]["repository"]["delta"] / 1048576,
            b["timestamp"]["stop"] - b["timestamp"]["start"]))'
psql_pg -c "SELECT archived_count, last_archived_wal, last_archived_time, failed_count FROM pg_stat_archiver;"

step "2-4" "pgBackRest 로 별도 경로에 복구하고 임시 인스턴스로 확인"
RDIR="${WORK}/restore_${STAMP}"
install -d -m 700 -o postgres -g postgres "$RDIR"
restorecon -R "$WORK" >/dev/null 2>&1 || true
T0=$(now_ms)
pgbr --pg1-path="$RDIR" --type=immediate --target-action=promote restore
T1=$(now_ms)
result "pgbackrest restore (가장 최근 백업, 백업 끝 시점까지) : $(secs "$T0" "$T1")초, $(du -sh "$RDIR" | cut -f1)"
log "postgresql.auto.conf 에 pgBackRest 가 넣은 복구 설정"
grep -E '^(restore_command|recovery_target)' "${RDIR}/postgresql.auto.conf" || true
# 운영 인스턴스와 겹치지 않도록: 소켓만(5433), 아카이브 끔, 데이터/설정 경로를 복구 폴더로 고정
OPTS="-p 5433 -c listen_addresses='' -c unix_socket_directories=/run/postgresql -c archive_mode=off -c hot_standby=off -c logging_collector=off -c shared_buffers=128MB -c cluster_name=lab_restore -c data_directory=${RDIR} -c hba_file=${RDIR}/pg_hba.conf -c ident_file=${RDIR}/pg_ident.conf"
T0=$(now_ms)
runuser -u postgres -- "${PGBIN}/pg_ctl" -D "$RDIR" -o "$OPTS" -l "${RDIR}.log" -w -t 600 start
wait_tmp_instance 600 || die "임시 인스턴스가 접속을 받지 않는다 (${RDIR}.log 확인)"
T1=$(now_ms)
result "임시 인스턴스 기동 (WAL 재생, 승격 포함) : $(secs "$T0" "$T1")초"
for spec in "customers customer_id" "orders order_id"; do
  set -- $spec
  A=$(fingerprint "$DB" "$1" "$2")
  B=$(runuser -u postgres -- "${PGBIN}/psql" -X -Atq -p 5433 -h /run/postgresql -d "$DB" -c "SELECT count(*) || ' ' || md5(string_agg(t::text, '|' ORDER BY t.$2)) FROM $1 AS t")
  if [ "$A" = "$B" ]; then same=같음; else same=다름; fi
  result "$1 운영 [$A] 복구본 [$B] -> $same"
done
runuser -u postgres -- "${PGBIN}/psql" -X -p 5433 -h /run/postgresql -d postgres -c "SELECT pg_is_in_recovery(), current_setting('port') AS port, timeline_id FROM pg_control_checkpoint();"
runuser -u postgres -- "${PGBIN}/pg_ctl" -D "$RDIR" -m fast -w stop
result "임시 인스턴스 정지. 복구 폴더 ${RDIR} 는 남겨 둔다 (다음 스냅샷 복원 때 사라진다)"

done_ok "실습 2 백업과 복구"
