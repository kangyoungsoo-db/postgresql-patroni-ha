#!/usr/bin/env bash
# 04_sample.sh : 샘플 데이터 적재 (data-db1 에서만, root 로 실행)
#   lab_tuning DB 생성
#   customers 100,000 건, orders 1,000,000 건
#   기본키만 만들고 그 밖의 인덱스는 만들지 않는다 (튜닝 실습의 출발점)
#   부하 테스트(pgbench 등)는 하지 않는다
# lab_tuning 이 이미 있으면 지우지 않고 멈춘다.
set -euo pipefail

PRIMARY_HOST="data-db1"
PGBIN="/usr/pgsql-17/bin"
DB="lab_tuning"
HOST=$(hostname -s)

psql_pg() { runuser -u postgres -- "${PGBIN}/psql" -X -v ON_ERROR_STOP=1 "$@"; }

if [ "$HOST" != "$PRIMARY_HOST" ]; then
  echo "[중단] $PRIMARY_HOST 에서만 실행한다."
  exit 1
fi
if [ "$(psql_pg -tAc 'SELECT pg_is_in_recovery()')" != "f" ]; then
  echo "[중단] 이 서버가 Primary 상태가 아니다."
  exit 1
fi
if [ "$(psql_pg -tAc "SELECT 1 FROM pg_database WHERE datname='${DB}'")" = "1" ]; then
  echo "[중단] ${DB} 가 이미 있다. 지우지 않고 멈춘다."
  exit 1
fi

echo "[04] ${DB} 생성"
runuser -u postgres -- "${PGBIN}/createdb" "$DB"

START=$(date +%s)
psql_pg -d "$DB" <<'SQL'
\timing on
-- 같은 데이터가 다시 나오도록 난수 시드를 고정한다
SELECT setseed(0.42);

CREATE TABLE customers (
    customer_id  integer      PRIMARY KEY,
    name         text         NOT NULL,
    email        text         NOT NULL,
    region       text         NOT NULL,
    grade        text         NOT NULL,
    created_at   timestamptz  NOT NULL
);

CREATE TABLE orders (
    order_id     bigint         PRIMARY KEY,
    customer_id  integer        NOT NULL REFERENCES customers(customer_id),
    order_date   timestamptz    NOT NULL,
    status       text           NOT NULL,
    amount       numeric(10,2)  NOT NULL,
    is_urgent    boolean        NOT NULL   -- 긴급 주문, true 약 5% (부분 인덱스 실습용)
);

-- customers 10만 건: 지역 8곳, 등급 4단계, 가입일은 2022-01-01 부터 3년 사이에 고르게 분포
INSERT INTO customers
SELECT g,
       'customer_' || g,
       'user' || g || '@example.com',
       (ARRAY['Seoul','Busan','Incheon','Daegu','Daejeon','Gwangju','Ulsan','Jeju'])[1 + floor(random() * 8)::int],
       (ARRAY['BRONZE','SILVER','GOLD','VIP'])[1 + floor(random() * 4)::int],
       timestamptz '2022-01-01 00:00:00+09' + random() * interval '1095 days'
FROM generate_series(1, 100000) AS g;

-- orders 100만 건
--   customer_id : 1 ~ 100000 고르게 분포
--   order_date  : 2024-01-01 부터 2년(730일) 사이에 고르게 분포
--   status      : 5가지 상태에 고르게 분포 (각 약 20%)
--   amount      : 1,000 ~ 500,000
--   is_urgent   : true 약 5%, false 약 95%
INSERT INTO orders
SELECT g,
       1 + floor(random() * 100000)::int,
       timestamptz '2024-01-01 00:00:00+09' + random() * interval '730 days',
       (ARRAY['PENDING','PAID','SHIPPED','DELIVERED','CANCELLED'])[1 + floor(random() * 5)::int],
       round((1000 + random() * 499000)::numeric, 2),
       random() < 0.05
FROM generate_series(1, 1000000) AS g;
\timing off
SQL
ELAPSED=$(( $(date +%s) - START ))

echo "[04] 결과"
echo "  적재 전체 소요: ${ELAPSED}초"
psql_pg -d "$DB" <<'SQL'
SELECT relname                                         AS table_name,
       to_char(n_live_tup_exact, 'FM9,999,999')        AS rows,
       pg_size_pretty(pg_relation_size(oid))           AS table_size,
       pg_size_pretty(pg_indexes_size(oid))            AS index_size,
       pg_size_pretty(pg_total_relation_size(oid))     AS total_size
FROM (
  SELECT c.oid, c.relname,
         CASE c.relname WHEN 'customers' THEN (SELECT count(*) FROM customers)
                        WHEN 'orders'    THEN (SELECT count(*) FROM orders) END AS n_live_tup_exact
  FROM pg_class c
  WHERE c.relname IN ('customers','orders') AND c.relkind = 'r'
) t
ORDER BY relname;

SELECT pg_size_pretty(pg_database_size('lab_tuning')) AS db_size;

-- 분포 확인
SELECT status, count(*) AS cnt FROM orders GROUP BY status ORDER BY status;
SELECT is_urgent, count(*) AS cnt, round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM orders GROUP BY is_urgent ORDER BY is_urgent;
SELECT min(order_date), max(order_date), count(DISTINCT customer_id) AS customers_with_orders FROM orders;
SQL
echo "[04] 완료"
