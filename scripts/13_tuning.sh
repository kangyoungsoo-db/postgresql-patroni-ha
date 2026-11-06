#!/usr/bin/env bash
# 13_tuning.sh : 쿼리 튜닝 실습 1 전체 (1-1 ~ 1-9) 를 한 번에 실행하고 결과를 기록한다 (root 로 실행)
#   Leader 에서 실행하면 : 튜닝 전 측정, 인덱스 시험과 생성, 튜닝 후 측정, 결과 같음 증명(행 수, md5)
#   Replica 에서 실행하면 : 읽기 전용 확인만 한다 (인덱스가 복제되어 왔는지, Replica 에서도 인덱스를 쓰는지)
#
# 실행 (PowerShell)
#   vagrant ssh data-db1 -c "sudo bash ~/lab-scripts/13_tuning.sh"
#   vagrant ssh data-db2 -c "sudo bash ~/lab-scripts/13_tuning.sh"
#
# 지키는 것
#   - DROP 과 데이터 변경을 하지 않는다. 시험용 인덱스는 BEGIN 안에서 만들고 ROLLBACK 으로 없앤다.
#   - 기본키 말고 다른 인덱스가 이미 있으면 지우지 않고 멈춘다 (튜닝 전 측정이 의미가 없어지므로).
#     처음부터 다시 하려면 full 스냅샷으로 세 VM 을 같이 되돌리고 resume 한 뒤 실행한다.
#   - 비밀번호를 쓰지 않는다 (postgres 계정 peer 접속).
#   - 부하 테스트가 아니다. 쿼리마다 5번 실행해 가운데 값(중앙값)을 기록한다.
#
# 결과 기록 : /home/vagrant/lab-results/13_tuning_<호스트>_<시각>.log
#             /home/vagrant/lab-results/13_tuning_latest.log (가장 최근 기록 링크)
set -euo pipefail
cd /

PGBIN="${PGBIN:-/usr/pgsql-17/bin}"
DB="lab_tuning"
HOST=$(hostname -s)
STAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="${LOG_DIR:-/home/vagrant/lab-results}"
LOG="${LOG_DIR}/13_tuning_${HOST}_${STAMP}.log"

psql_db() { runuser -u postgres -- "${PGBIN}/psql" -X -v ON_ERROR_STOP=1 -d "$DB" "$@"; }

mkdir -p "$LOG_DIR"
ln -sfn "$LOG" "${LOG_DIR}/13_tuning_latest.log"   # 가장 최근 기록을 가리키는 링크
exec > >(tee -a "$LOG") 2>&1

echo "[13] 쿼리 튜닝 실습 시작: ${HOST}, $(date '+%Y-%m-%d %H:%M:%S')"

if [ "$(psql_db -tAc "SELECT count(*) FROM pg_class WHERE relname = 'orders' AND relkind = 'r'")" != "1" ]; then
  echo "[중단] ${DB}.orders 가 없다. 04_sample.sh 를 먼저 실행한다."
  exit 1
fi

IN_RECOVERY=$(psql_db -tAc "SELECT pg_is_in_recovery()")

# ---------------------------------------------------------------------------
# Replica 모드 : 읽기 전용 확인
# ---------------------------------------------------------------------------
if [ "$IN_RECOVERY" = "t" ]; then
  echo "[13] ${HOST} 는 Replica 이다. 읽기 전용 확인만 한다."
  psql_db <<'SQL'
\pset pager off
SET TimeZone = 'Asia/Seoul';
\echo
\echo '[R-1] Replica 인지 확인 (t 이면 Replica)'
SELECT pg_is_in_recovery() AS in_recovery, pg_last_wal_replay_lsn() AS replay_lsn;
\echo
\echo '[R-2] Leader 에서 만든 인덱스가 복제되어 왔는지'
SELECT tablename, indexname, pg_size_pretty(pg_relation_size(format('%I', indexname)::regclass)) AS size, indexdef
FROM pg_indexes
WHERE schemaname = 'public' AND tablename IN ('orders', 'customers')
ORDER BY tablename, indexname;
\echo
\echo '[R-3] Replica 에서도 같은 쿼리가 인덱스를 쓰는지 (Q1 고객 한 명의 최근 주문 5건)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, order_date, status, amount FROM orders WHERE customer_id = 12345 ORDER BY order_date DESC LIMIT 5;
SQL
  chown -R vagrant:vagrant "$LOG_DIR" 2>/dev/null || true
  echo "[13] 결과 기록: ${LOG}"
  echo "[13] 완료"
  exit 0
fi

# ---------------------------------------------------------------------------
# Leader 모드 : 사전 확인
# ---------------------------------------------------------------------------
EXTRA_IDX=$(psql_db -tAc "SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND tablename IN ('orders','customers') AND indexname NOT IN ('orders_pkey','customers_pkey')")
if [ "$EXTRA_IDX" != "0" ]; then
  echo "[중단] 기본키 말고 다른 인덱스가 이미 ${EXTRA_IDX}개 있다. 지우지 않고 멈춘다."
  psql_db -c "SELECT tablename, indexname FROM pg_indexes WHERE schemaname = 'public' AND tablename IN ('orders','customers') ORDER BY 1, 2;"
  echo "  처음부터 다시 하려면 full 스냅샷으로 세 VM 을 같이 되돌리고 patronictl resume 한 뒤 실행한다."
  exit 1
fi

echo "[13] ${HOST} 는 Leader 이다. 실습 1-1 ~ 1-9 를 실행한다."
START=$(date +%s)

psql_db <<'SQL'
\pset pager off
\set VERBOSITY terse
SET TimeZone = 'Asia/Seoul';
SET client_min_messages = warning;

-- =========================================================================
-- 준비 : 측정 결과를 담을 임시 테이블과 측정 함수 (세션이 끝나면 사라진다)
-- =========================================================================
CREATE TEMP TABLE lab_query  (name text PRIMARY KEY, title text, sql text);
CREATE TEMP TABLE lab_result (at timestamptz, step text, query text, label text,
                              plan_shape text, exec_ms numeric, buffers bigint, rows bigint);
CREATE TEMP TABLE lab_size   (step text, index_name text, note text, size_bytes bigint);
CREATE TEMP TABLE lab_check  (query text, phase text, cnt bigint, md5 text);
CREATE TEMP TABLE lab_idx_before (indexrelname name, idx_scan bigint);

-- 튜닝 대상 쿼리 7개 (Q2 와 Q2F 는 같은 뜻, 쓰는 법만 다르다)
INSERT INTO lab_query VALUES
('Q1',  '고객 한 명의 최근 주문 5건',
 $q$SELECT order_id, order_date, status, amount FROM orders WHERE customer_id = 12345 ORDER BY order_date DESC LIMIT 5$q$),
('Q2',  '하루 매출 (범위 조건)',
 $q$SELECT count(*), sum(amount) FROM orders WHERE order_date >= '2025-06-01 00:00:00+09' AND order_date < '2025-06-02 00:00:00+09'$q$),
('Q2F', '하루 매출 (컬럼에 함수를 씌운 같은 뜻의 쿼리)',
 $q$SELECT count(*), sum(amount) FROM orders WHERE date(order_date AT TIME ZONE 'Asia/Seoul') = DATE '2025-06-01'$q$),
('Q3',  '긴급 주문 최근 20건',
 $q$SELECT order_id, customer_id, order_date, amount FROM orders WHERE is_urgent ORDER BY order_date DESC LIMIT 20$q$),
('Q4',  '이메일로 고객을 찾아 최근 주문 5건 (JOIN)',
 $q$SELECT o.order_id, o.order_date, o.amount FROM customers c JOIN orders o ON o.customer_id = c.customer_id WHERE c.email = 'user12345@example.com' ORDER BY o.order_date DESC LIMIT 5$q$),
('Q5',  '지역별 한 달 매출 (JOIN 집계)',
 $q$SELECT c.region, count(*) AS orders, sum(o.amount) AS amount FROM customers c JOIN orders o ON o.customer_id = c.customer_id WHERE o.order_date >= '2025-12-01 00:00:00+09' AND o.order_date < '2026-01-01 00:00:00+09' GROUP BY c.region ORDER BY c.region$q$),
('Q6',  '넓은 범위 집계 (전체의 약 75%)',
 $q$SELECT count(*), sum(amount) FROM orders WHERE order_date >= '2024-07-01 00:00:00+09'$q$);

SELECT max(sql) FILTER (WHERE name = 'Q1')  AS q1,
       max(sql) FILTER (WHERE name = 'Q2')  AS q2,
       max(sql) FILTER (WHERE name = 'Q2F') AS q2f,
       max(sql) FILTER (WHERE name = 'Q3')  AS q3,
       max(sql) FILTER (WHERE name = 'Q4')  AS q4,
       max(sql) FILTER (WHERE name = 'Q5')  AS q5,
       max(sql) FILTER (WHERE name = 'Q6')  AS q6
FROM lab_query \gset

-- 측정 : EXPLAIN (ANALYZE, BUFFERS) 를 5번 실행해 실행 시간 중앙값, 읽은 페이지 수, 계획 모양을 돌려준다
CREATE FUNCTION pg_temp.measure(p_step text, p_name text, p_label text)
RETURNS lab_result LANGUAGE plpgsql AS $f$
DECLARE
  q   text;
  j   jsonb;
  ts  numeric[] := '{}';
  res lab_result;
BEGIN
  SELECT sql INTO q FROM lab_query WHERE name = p_name;
  FOR i IN 1..5 LOOP
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || q INTO j;
    ts := ts || (j -> 0 ->> 'Execution Time')::numeric;
  END LOOP;
  res.at    := clock_timestamp();
  res.step  := p_step;
  res.query := p_name;
  res.label := p_label;
  SELECT string_agg(v #>> '{}', ' > ') INTO res.plan_shape
  FROM jsonb_path_query(j, 'strict $.**."Node Type"') AS v;
  SELECT round(x, 3) INTO res.exec_ms FROM unnest(ts) AS x ORDER BY x OFFSET 2 LIMIT 1;
  res.buffers := (j -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint
               + (j -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint;
  res.rows    := (j -> 0 -> 'Plan' ->> 'Actual Rows')::bigint;
  RETURN res;
END $f$;

-- 인덱스 크기
CREATE FUNCTION pg_temp.idx_size(p_step text, p_index text, p_note text)
RETURNS lab_size LANGUAGE sql AS $f$
  SELECT p_step, p_index, p_note, pg_relation_size(p_index::regclass)
$f$;

-- 결과 지문 : 결과 행 수와, 결과 전체를 정렬해 이어 붙인 문자열의 md5
CREATE FUNCTION pg_temp.fingerprint(p_name text, p_phase text)
RETURNS lab_check LANGUAGE plpgsql AS $f$
DECLARE
  q   text;
  res lab_check;
BEGIN
  SELECT sql INTO q FROM lab_query WHERE name = p_name;
  res.query := p_name;
  res.phase := p_phase;
  EXECUTE format('SELECT count(*), md5(coalesce(string_agg(t::text, %L ORDER BY t::text), %L)) FROM (%s) AS t', '|', '', q)
    INTO res.cnt, res.md5;
  RETURN res;
END $f$;

\echo
\echo '========================================================================='
\echo '[1-1] 준비 : 상태 확인과 통계 갱신'
\echo '========================================================================='
SELECT version();
SELECT now() AS started_at, inet_server_addr() AS server_ip;
SELECT pg_is_in_recovery() AS in_recovery, current_setting('shared_buffers') AS shared_buffers,
       current_setting('work_mem') AS work_mem, current_setting('max_parallel_workers_per_gather') AS parallel_workers;
SELECT (SELECT count(*) FROM customers) AS customers, (SELECT count(*) FROM orders) AS orders,
       (SELECT count(*) FROM orders WHERE is_urgent) AS urgent;
\d orders
VACUUM (ANALYZE) customers, orders;
\echo 'VACUUM (ANALYZE) 완료 : 통계와 visibility map 을 최신으로 맞췄다'
SELECT relname, relpages, reltuples::bigint, pg_size_pretty(pg_relation_size(oid)) AS table_size
FROM pg_class WHERE relname IN ('customers', 'orders') ORDER BY relname;
SELECT pg_database_size(current_database()) AS db_bytes_before \gset
-- 인덱스 사용 횟수는 실습 전 값을 빼서 보여 준다 (customers_pkey 에는 04 적재 때 FK 검사로 약 100만 번이 이미 쌓여 있다)
INSERT INTO lab_idx_before SELECT indexrelname, idx_scan FROM pg_stat_user_indexes WHERE relname IN ('orders', 'customers');

\echo
\echo '========================================================================='
\echo '[1-2] 튜닝 전 측정 : 기본키 말고 인덱스가 없는 상태'
\echo '========================================================================='
\echo '--- Q1 계획 (읽는 예시) ---'
EXPLAIN (ANALYZE, BUFFERS) :q1;
INSERT INTO lab_result
SELECT m.* FROM lab_query, LATERAL pg_temp.measure('1-2', name, '튜닝 전') AS m;
INSERT INTO lab_check
SELECT f.* FROM lab_query, LATERAL pg_temp.fingerprint(name, 'before') AS f;
SELECT query, plan_shape, exec_ms, buffers, rows FROM lab_result WHERE step = '1-2' ORDER BY query;

\echo
\echo '========================================================================='
\echo '[1-3] 단일 인덱스 시험 (customer_id) : BEGIN 안에서 만들고 ROLLBACK'
\echo '========================================================================='
BEGIN;
CREATE INDEX idx_try_orders_customer ON orders (customer_id);
EXPLAIN (ANALYZE, BUFFERS) :q1;
SELECT pg_temp.measure('1-3', 'Q1', '단일 인덱스 (customer_id) 시험')::text AS keep_r \gset
SELECT pg_temp.idx_size('1-3', 'idx_try_orders_customer', '단일 (customer_id), ROLLBACK')::text AS keep_s \gset
ROLLBACK;
INSERT INTO lab_result SELECT (:'keep_r'::lab_result).*;
INSERT INTO lab_size   SELECT (:'keep_s'::lab_size).*;
\echo 'ROLLBACK 완료 : 시험 인덱스는 남아 있지 않다'
SELECT count(*) AS try_index_left FROM pg_indexes WHERE indexname = 'idx_try_orders_customer';

\echo
\echo '========================================================================='
\echo '[1-4] 복합 인덱스와 컬럼 순서'
\echo '========================================================================='
\echo '--- 1-4a 순서가 틀린 복합 인덱스 (order_date, customer_id) 시험 후 ROLLBACK ---'
BEGIN;
CREATE INDEX idx_try_orders_date_customer ON orders (order_date, customer_id);
EXPLAIN (ANALYZE, BUFFERS) :q1;
SELECT pg_temp.measure('1-4a', 'Q1', '순서가 틀린 복합 (order_date, customer_id) 시험')::text AS keep_r \gset
ROLLBACK;
INSERT INTO lab_result SELECT (:'keep_r'::lab_result).*;
\echo '--- 1-4b 맞는 순서 복합 인덱스 (customer_id, order_date) 생성 (남겨 둠) ---'
CREATE INDEX idx_orders_customer_date ON orders (customer_id, order_date);
EXPLAIN (ANALYZE, BUFFERS) :q1;
INSERT INTO lab_result SELECT * FROM pg_temp.measure('1-4b', 'Q1', '복합 (customer_id, order_date)');
INSERT INTO lab_size   SELECT * FROM pg_temp.idx_size('1-4b', 'idx_orders_customer_date', '복합 (customer_id, order_date), 남김');

\echo
\echo '========================================================================='
\echo '[1-5] 부분 인덱스 (is_urgent 가 true 인 약 5% 만)'
\echo '========================================================================='
\echo '--- 1-5a 전체 인덱스 (is_urgent, order_date) 시험 후 ROLLBACK ---'
BEGIN;
CREATE INDEX idx_try_orders_urgent_full ON orders (is_urgent, order_date);
EXPLAIN (ANALYZE, BUFFERS) :q3;
SELECT pg_temp.measure('1-5a', 'Q3', '전체 인덱스 (is_urgent, order_date) 시험')::text AS keep_r \gset
SELECT pg_temp.idx_size('1-5a', 'idx_try_orders_urgent_full', '전체 (is_urgent, order_date), ROLLBACK')::text AS keep_s \gset
ROLLBACK;
INSERT INTO lab_result SELECT (:'keep_r'::lab_result).*;
INSERT INTO lab_size   SELECT (:'keep_s'::lab_size).*;
\echo '--- 1-5b 부분 인덱스 (order_date) WHERE is_urgent 생성 (남겨 둠) ---'
CREATE INDEX idx_orders_urgent_date ON orders (order_date) WHERE is_urgent;
EXPLAIN (ANALYZE, BUFFERS) :q3;
INSERT INTO lab_result SELECT * FROM pg_temp.measure('1-5b', 'Q3', '부분 (order_date) WHERE is_urgent');
INSERT INTO lab_size   SELECT * FROM pg_temp.idx_size('1-5b', 'idx_orders_urgent_date', '부분 (order_date) WHERE is_urgent, 남김');

\echo
\echo '========================================================================='
\echo '[1-6] 기간 인덱스, 그리고 인덱스가 있어도 안 쓰이는 경우'
\echo '========================================================================='
CREATE INDEX idx_orders_order_date ON orders (order_date);
INSERT INTO lab_size SELECT * FROM pg_temp.idx_size('1-6', 'idx_orders_order_date', '단일 (order_date), 남김');
\echo '--- Q2 하루 범위 : 인덱스를 쓴다 ---'
EXPLAIN (ANALYZE, BUFFERS) :q2;
INSERT INTO lab_result SELECT * FROM pg_temp.measure('1-6', 'Q2', '기간 인덱스 (order_date)');
\echo '--- Q2F 같은 뜻이지만 컬럼에 함수를 씌움 : 인덱스를 못 쓴다 ---'
EXPLAIN (ANALYZE, BUFFERS) :q2f;
INSERT INTO lab_result SELECT * FROM pg_temp.measure('1-6', 'Q2F', '컬럼에 함수 (인덱스 못 씀)');
\echo '--- Q6 전체의 약 75% : 인덱스가 있어도 Seq Scan 이 낫다고 판단한다 ---'
EXPLAIN (ANALYZE, BUFFERS) :q6;
INSERT INTO lab_result SELECT * FROM pg_temp.measure('1-6', 'Q6', '넓은 범위 (Seq Scan 유지)');

\echo
\echo '========================================================================='
\echo '[1-7] JOIN 계획'
\echo '========================================================================='
\echo '--- 1-7a Q4 : customers.email 에 인덱스가 없을 때 ---'
EXPLAIN (ANALYZE, BUFFERS) :q4;
INSERT INTO lab_result SELECT * FROM pg_temp.measure('1-7a', 'Q4', 'email 인덱스 없음, orders 는 복합 인덱스');
\echo '--- 1-7b customers.email 에 UNIQUE 인덱스 생성 (남겨 둠) ---'
CREATE UNIQUE INDEX idx_customers_email ON customers (email);
INSERT INTO lab_size SELECT * FROM pg_temp.idx_size('1-7b', 'idx_customers_email', 'UNIQUE (email), 남김');
EXPLAIN (ANALYZE, BUFFERS) :q4;
INSERT INTO lab_result SELECT * FROM pg_temp.measure('1-7b', 'Q4', 'email UNIQUE 인덱스');
\echo '--- 1-7c Q5 : 한 달 치 주문과 고객 10만 명을 잇는 집계 ---'
EXPLAIN (ANALYZE, BUFFERS) :q5;
INSERT INTO lab_result SELECT * FROM pg_temp.measure('1-7c', 'Q5', '플래너 선택 그대로');
\echo '--- 1-7d 비교용 : 이 세션에서만 Hash Join 을 끄면 ---'
SET enable_hashjoin = off;
EXPLAIN (ANALYZE, BUFFERS) :q5;
INSERT INTO lab_result SELECT * FROM pg_temp.measure('1-7d', 'Q5', 'Hash Join 끔 (비교용)');
RESET enable_hashjoin;

\echo
\echo '========================================================================='
\echo '[1-8] 튜닝 전후 결과가 같은지 증명 (행 수와 md5)'
\echo '========================================================================='
INSERT INTO lab_check
SELECT f.* FROM lab_query, LATERAL pg_temp.fingerprint(name, 'after') AS f;
SELECT b.query, b.cnt AS rows_before, a.cnt AS rows_after, b.md5 AS md5_before, a.md5 AS md5_after,
       (b.cnt = a.cnt AND b.md5 = a.md5) AS same
FROM lab_check b JOIN lab_check a ON a.query = b.query AND a.phase = 'after'
WHERE b.phase = 'before'
ORDER BY b.query;
\echo '--- Q2 와 Q2F 는 같은 뜻의 쿼리이므로 결과도 같아야 한다 ---'
SELECT (SELECT md5 FROM lab_check WHERE query = 'Q2'  AND phase = 'after')
     = (SELECT md5 FROM lab_check WHERE query = 'Q2F' AND phase = 'after') AS q2_equals_q2f;

\echo
\echo '========================================================================='
\echo '[1-9] 정리 : 튜닝 전후 비교, 인덱스 크기와 사용 횟수'
\echo '========================================================================='
INSERT INTO lab_result
SELECT m.* FROM lab_query, LATERAL pg_temp.measure('1-9', name, '튜닝 후') AS m;

\echo '--- 단계별 측정 전체 (실행 시간은 5번 중 중앙값, buffers 는 읽은 8KB 페이지 수) ---'
SELECT step, query, label, plan_shape, exec_ms, buffers, rows FROM lab_result ORDER BY at;

\echo '--- 쿼리별 튜닝 전후 ---'
SELECT q.name AS query, q.title,
       b.exec_ms AS before_ms, a.exec_ms AS after_ms,
       round(b.exec_ms / nullif(a.exec_ms, 0), 1) AS faster_x,
       b.buffers AS before_buffers, a.buffers AS after_buffers,
       b.plan_shape AS before_plan, a.plan_shape AS after_plan
FROM lab_query q
JOIN lab_result b ON b.query = q.name AND b.step = '1-2'
JOIN lab_result a ON a.query = q.name AND a.step = '1-9'
ORDER BY q.name;

\echo '--- 인덱스 크기 (시험 후 ROLLBACK 한 것 포함) ---'
SELECT step, index_name, note, pg_size_pretty(size_bytes) AS size, size_bytes FROM lab_size ORDER BY step, index_name;

\echo '--- 지금 남아 있는 인덱스와 이번 실습 중 사용 횟수 (측정 반복 횟수 포함) ---'
SELECT pg_stat_clear_snapshot() \gset
SELECT s.relname AS table_name, s.indexrelname AS index_name,
       s.idx_scan - coalesce(b.idx_scan, 0) AS idx_scan_in_lab,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS size
FROM pg_stat_user_indexes s
LEFT JOIN lab_idx_before b ON b.indexrelname = s.indexrelname
WHERE s.relname IN ('orders', 'customers')
ORDER BY s.relname, s.indexrelname;

\echo '--- DB 크기 전후 ---'
SELECT pg_size_pretty(:db_bytes_before::bigint) AS db_before,
       pg_size_pretty(pg_database_size(current_database())) AS db_after;
SQL

ELAPSED=$(( $(date +%s) - START ))
chown -R vagrant:vagrant "$LOG_DIR" 2>/dev/null || true
echo
echo "[13] 걸린 시간: ${ELAPSED}초"
echo "[13] 결과 기록: ${LOG}"
echo "[13] 완료"
