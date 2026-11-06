#!/usr/bin/env bash
# 17_ops.sh : 실습 5 운영 (root 로 실행)
#   locks  (Leader)    : 잠금 대기 찾기(pg_blocking_pids), lock_timeout, 막고 있는 세션 끊기, 교착 상태(deadlock)
#   vacuum (Leader)    : dead tuple 이 쌓이는 모습, VACUUM 과 VACUUM FULL 의 차이 (pgstattuple)
#   sqlmon (Leader)    : 운영 점검 SQL (접속, 캐시 적중률, 복제 지연, 아카이브, 체크포인트, 큰 표, XID 나이)
#   prom   (data-mgmt) : Prometheus 로 같은 내용을 보기 (대상 상태, 주요 지표, 경보)
# 실습용 표(lab_lock, lab_vac)만 만들고 바꾼다. 기존 표의 데이터는 바꾸지 않는다.
set -euo pipefail
source "$(dirname "$0")/lab_lib.sh"

leader_only() { [ "$(in_recovery)" = "f" ] || die "${HOST} 는 Leader 가 아니다"; }
bgpsql() {   # $1=application_name, 나머지=psql 인자 (백그라운드 세션용)
  local app=$1; shift
  runuser -u postgres -- env PGAPPNAME="$app" "${PGBIN}/psql" -X -d "$DB" "$@"
}

case "${1:-}" in
locks)
  leader_only
  step "5-1" "잠금 대기 찾기"
  psql_pg -d "$DB" -q <<'SQL'
DROP TABLE IF EXISTS lab_lock;
CREATE TABLE lab_lock (id int PRIMARY KEY, v int NOT NULL);
INSERT INTO lab_lock VALUES (1, 0), (2, 0);
SQL
  OUT=$(mktemp -d)
  log "세션 A(lab_blocker): id=1 을 UPDATE 하고 커밋하지 않은 채 30초 대기"
  bgpsql lab_blocker -c "BEGIN; UPDATE lab_lock SET v = v + 1 WHERE id = 1; SELECT pg_sleep(30); COMMIT;" > "${OUT}/a.txt" 2>&1 &
  PA=$!
  sleep 2
  log "세션 B(lab_waiter): 같은 행을 UPDATE (A 가 끝날 때까지 기다린다)"
  bgpsql lab_waiter -c "UPDATE lab_lock SET v = v + 10 WHERE id = 1;" > "${OUT}/b.txt" 2>&1 &
  PB=$!
  sleep 3
  log "누가 누구를 막고 있나 (pg_stat_activity, pg_blocking_pids)"
  psql_pg -d "$DB" -c "SELECT pid, application_name AS app, state, wait_event_type, wait_event, pg_blocking_pids(pid) AS blocked_by, now() - xact_start AS xact_age, left(query, 50) AS query FROM pg_stat_activity WHERE application_name LIKE 'lab_%' ORDER BY application_name;"
  log "잠금 목록 (granted = f 가 기다리는 쪽)"
  psql_pg -d "$DB" -c "SELECT a.application_name AS app, l.locktype, l.mode, l.granted, l.relation::regclass AS rel FROM pg_locks l JOIN pg_stat_activity a USING (pid) WHERE a.application_name LIKE 'lab_%' AND l.locktype IN ('relation', 'transactionid', 'tuple') ORDER BY app, l.granted DESC;"
  log "세션 C: lock_timeout 2초로 같은 행을 UPDATE (기다리다 포기)"
  T0=$(now_ms)
  bgpsql lab_timeout -c "SET lock_timeout = '2s';" -c "UPDATE lab_lock SET v = v + 100 WHERE id = 1;" 2>&1 || true
  T1=$(now_ms)
  result "lock_timeout 으로 $(secs "$T0" "$T1")초 만에 오류를 내고 끝났다"
  log "막고 있는 세션 A 를 pg_terminate_backend 로 끊는다"
  BLK=$(psql_q -d "$DB" -c "SELECT pid FROM pg_stat_activity WHERE application_name = 'lab_blocker'")
  T0=$(now_ms)
  psql_pg -d "$DB" -c "SELECT pg_terminate_backend(${BLK});"
  wait "$PB" || true
  T1=$(now_ms)
  wait "$PA" || true
  result "세션 B 는 A 를 끊은 뒤 $(secs "$T0" "$T1")초 안에 끝났다"
  echo "  세션 A 출력: $(tr '\n' ' ' < "${OUT}/a.txt" | cut -c1-160)"
  echo "  세션 B 출력: $(tr '\n' ' ' < "${OUT}/b.txt")"
  psql_pg -d "$DB" -c "SELECT * FROM lab_lock ORDER BY id;"

  step "5-2" "교착 상태 (deadlock)"
  log "세션 D: id=1 -> id=2 순서, 세션 E: id=2 -> id=1 순서로 동시에 UPDATE"
  bgpsql lab_dead_d -c "BEGIN; UPDATE lab_lock SET v = v + 1 WHERE id = 1; SELECT pg_sleep(2); UPDATE lab_lock SET v = v + 1 WHERE id = 2; COMMIT;" > "${OUT}/d.txt" 2>&1 &
  PD=$!
  bgpsql lab_dead_e -c "BEGIN; UPDATE lab_lock SET v = v + 1 WHERE id = 2; SELECT pg_sleep(2); UPDATE lab_lock SET v = v + 1 WHERE id = 1; COMMIT;" > "${OUT}/e.txt" 2>&1 &
  PE=$!
  wait "$PD" || true
  wait "$PE" || true
  echo "  세션 D 출력: $(tr '\n' ' ' < "${OUT}/d.txt" | cut -c1-220)"
  echo "  세션 E 출력: $(tr '\n' ' ' < "${OUT}/e.txt" | cut -c1-220)"
  result "deadlock_timeout = $(psql_q -c 'SHOW deadlock_timeout') 뒤 한쪽이 'deadlock detected' 로 취소되고 다른 쪽은 커밋된다"
  psql_pg -d "$DB" -c "SELECT datname, deadlocks FROM pg_stat_database WHERE datname = '${DB}';"
  rm -rf "$OUT"
  done_ok "locks"
  ;;

vacuum)
  leader_only
  step "5-3" "dead tuple 과 VACUUM"
  psql_pg -d "$DB" -q <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgstattuple;
DROP TABLE IF EXISTS lab_vac;
CREATE TABLE lab_vac (id int PRIMARY KEY, pad text NOT NULL) WITH (autovacuum_enabled = false);
INSERT INTO lab_vac SELECT g, md5(g::text) FROM generate_series(1, 200000) g;
SQL
  show() {
    psql_pg -d "$DB" -c "SELECT '$1' AS step, pg_size_pretty(pg_relation_size('lab_vac')) AS table_size, tuple_count AS live, dead_tuple_count AS dead, round(dead_tuple_percent::numeric, 1) AS dead_pct, round(free_percent::numeric, 1) AS free_pct FROM pgstattuple('lab_vac');"
  }
  show "1. 적재 직후"
  log "전체 행 UPDATE (MVCC: 새 버전을 쓰고 옛 버전은 dead tuple 로 남는다)"
  psql_pg -d "$DB" -q -c "UPDATE lab_vac SET pad = pad || 'x';"
  show "2. UPDATE 뒤"
  T0=$(now_ms)
  psql_pg -d "$DB" -c "VACUUM (VERBOSE) lab_vac;" 2>&1 | grep -E 'tuples:|pages:|removable|index scan|elapsed|system usage' | head -8 || true
  T1=$(now_ms)
  show "3. VACUUM 뒤"
  result "VACUUM : $(secs "$T0" "$T1")초. dead tuple 은 치웠지만 파일 크기는 그대로이다 (빈 공간은 다음 INSERT, UPDATE 가 다시 쓴다)"
  T0=$(now_ms)
  psql_pg -d "$DB" -q -c "VACUUM FULL lab_vac;"
  T1=$(now_ms)
  show "4. VACUUM FULL 뒤"
  result "VACUUM FULL : $(secs "$T0" "$T1")초. 표를 새로 써서 크기가 줄지만, 그동안 ACCESS EXCLUSIVE 잠금으로 읽기도 막힌다"
  step "5-4" "autovacuum 과 XID 나이 점검"
  psql_pg -c "SELECT name, setting FROM pg_settings WHERE name IN ('autovacuum', 'autovacuum_naptime', 'autovacuum_vacuum_scale_factor', 'autovacuum_vacuum_threshold', 'autovacuum_freeze_max_age') ORDER BY name;"
  psql_pg -d "$DB" -c "SELECT relname, n_live_tup, n_dead_tup, last_vacuum, last_autovacuum, last_autoanalyze FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 6;"
  psql_pg -c "SELECT datname, age(datfrozenxid) AS xid_age, round(100.0 * age(datfrozenxid) / current_setting('autovacuum_freeze_max_age')::int, 2) AS pct_of_freeze_max FROM pg_database ORDER BY 2 DESC;"
  done_ok "vacuum"
  ;;

sqlmon)
  leader_only
  step "5-5" "운영 점검 SQL"
  log "접속 수 (상태별)"
  psql_pg -c "SELECT coalesce(state, 'background') AS state, count(*) FROM pg_stat_activity GROUP BY 1 ORDER BY 2 DESC;"
  log "오래 걸리는 쿼리와 오래 열린 트랜잭션 (5초 이상)"
  psql_pg -c "SELECT pid, usename, state, now() - xact_start AS xact_age, left(query, 60) AS query FROM pg_stat_activity WHERE xact_start < now() - interval '5 seconds' AND pid <> pg_backend_pid() ORDER BY xact_start;"
  log "DB 별 캐시 적중률, 커밋, 롤백, 임시 파일"
  psql_pg -c "SELECT datname, round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) AS cache_hit_pct, xact_commit, xact_rollback, temp_files, deadlocks FROM pg_stat_database WHERE datname IS NOT NULL ORDER BY datname;"
  log "복제 상태와 지연"
  psql_pg -c "SELECT application_name, client_addr, state, sync_state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes, write_lag, flush_lag, replay_lag FROM pg_stat_replication;"
  psql_pg -c "SELECT slot_name, slot_type, active, wal_status, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained FROM pg_replication_slots;"
  log "WAL 아카이브"
  psql_pg -c "SELECT archived_count, last_archived_wal, last_archived_time, failed_count, last_failed_wal FROM pg_stat_archiver;"
  log "체크포인트 (PostgreSQL 17 의 pg_stat_checkpointer)"
  psql_pg -c "SELECT num_timed, num_requested, write_time, sync_time, buffers_written FROM pg_stat_checkpointer;"
  log "큰 표와 인덱스"
  psql_pg -d "$DB" -c "SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) AS total, pg_size_pretty(pg_relation_size(relid)) AS heap, pg_size_pretty(pg_indexes_size(relid)) AS indexes FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 6;"
  log "Patroni"
  pctl list || true
  done_ok "sqlmon"
  ;;

prom)
  [ "$HOST" = "data-mgmt" ] || die "data-mgmt 에서 실행한다"
  step "5-6" "Prometheus 로 보기 (http://192.168.56.13:9090)"
  python3 - <<'PY'
import json, urllib.parse, urllib.request
BASE = "http://127.0.0.1:9090/api/v1/"
def get(path, **q):
    url = BASE + path + ("?" + urllib.parse.urlencode(q) if q else "")
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.load(r)["data"]
print("  [수집 대상]")
for t in get("targets")["activeTargets"]:
    print("    %-10s %-22s %-5s %s" % (t["labels"]["job"], t["labels"]["instance"], t["health"], t.get("lastError", "")[:60]))
queries = [
    ("수집 대상 up", "up"),
    ("PostgreSQL 접속 가능 pg_up", "pg_up"),
    ("lab_tuning 초당 커밋 (5분 평균)", 'rate(pg_stat_database_xact_commit{datname="lab_tuning"}[5m])'),
    ("복제 지연 초 (Replica)", "pg_replication_lag_seconds"),
    ("마지막 성공 백업 뒤 지난 시간(초)", "time() - max(lab_backup_last_success_timestamp_seconds)"),
    ("/data 남은 공간(GB)", 'node_filesystem_avail_bytes{mountpoint="/data"} / 1e9'),
    ("메모리 사용 가능(GB)", "node_memory_MemAvailable_bytes / 1e9"),
    ("1분 부하", "node_load1"),
]
for title, q in queries:
    res = get("query", query=q)["result"]
    print("  [%s] %s" % (title, q))
    if not res:
        print("    (값 없음)")
    for r in res[:6]:
        m = r["metric"]
        who = m.get("instance") or m.get("server") or ""
        print("    %-22s %s" % (who, round(float(r["value"][1]), 3)))
print("  [경보]")
alerts = get("alerts")["alerts"]
if not alerts:
    print("    현재 pending 이나 firing 인 경보 없음")
for a in alerts:
    print("    %s %s since %s" % (a["labels"]["alertname"], a["state"], a.get("activeAt")))
for g in get("rules")["groups"]:
    for r in g["rules"]:
        print("    규칙 %s : 상태 %s, 식 %s" % (r["name"], r.get("state"), r["query"][:90]))
PY
  done_ok "prom"
  ;;

*)
  die "사용법: 17_ops.sh locks | vacuum | sqlmon | prom"
  ;;
esac
