# 실습 1. 쿼리 튜닝 (EXPLAIN, 인덱스)

> 2026-11-05, 개인 실습 환경 D:\data-lab
> 코드(13_tuning.sh)로 한 번 실행해 기준 결과를 만들었다. 나중에 처음부터 설치한 뒤 이 문서의 "손으로 칠 명령"을 따라 직접 다시 한다.

| 항목 | 값 |
|---|---|
| DB | PostgreSQL 17.11, Patroni Leader data-db1, Replica data-db2 |
| VM | 2 vCPU, 3 GB, shared_buffers 736MB, work_mem 4MB, 병렬 작업자 2 |
| 데이터 | lab_tuning: customers 100,000건 (9 MB), orders 1,000,000건 (71 MB, 9,130 페이지), 긴급 주문 50,234건 |
| 출발점 | 기본키만 있고, FK 컬럼(orders.customer_id)에도 인덱스가 없다 |
| 측정 방법 | EXPLAIN (ANALYZE, BUFFERS)를 쿼리마다 5번 실행한 중앙값. 부하 테스트는 하지 않았다 |
| 걸린 시간 | 스크립트 전체 14초 |

---

## 한눈에 보기

| 쿼리 | 내용 | 튜닝 전 | 튜닝 후 | 읽은 페이지 | 계획 변화 |
|---|---|---|---|---|---|
| Q1 | 고객 한 명의 최근 주문 5건 | 33.4 ms | 0.021 ms | 9,244 -> 8 | Seq Scan + Sort -> Index Scan |
| Q2 | 하루 매출 (범위 조건) | 37.3 ms | 1.3 ms | 9,130 -> 1,251 | Seq Scan -> Bitmap Index Scan |
| Q2F | Q2와 같은 뜻, 컬럼에 함수 | 147.2 ms | 150.9 ms | 9,130 -> 9,130 | 그대로 Seq Scan (인덱스 못 씀) |
| Q3 | 긴급 주문 최근 20건 | 42.9 ms | 0.019 ms | 9,244 -> 22 | Seq Scan + Sort -> 부분 인덱스 Index Scan |
| Q4 | 이메일로 고객 찾아 최근 주문 5건 | 76.6 ms | 0.059 ms | 10,476 -> 19 | Hash Join -> Nested Loop + 인덱스 2개 |
| Q5 | 지역별 한 달 매출 (JOIN 집계) | 57.1 ms | 41.6 ms | 10,288 -> 10,310 | Hash Join 유지, orders 쪽만 Bitmap |
| Q6 | 넓은 범위 집계 (약 75%) | 89.2 ms | 89.9 ms | 9,130 -> 9,130 | 그대로 Seq Scan (이게 맞음) |

- 7개 쿼리 모두 튜닝 전후 결과의 행 수와 md5가 같았다.
- 남긴 인덱스는 4개이고, DB 크기는 111 MB에서 168 MB로 늘었다 (인덱스 약 57 MB).
- 빨라진 쿼리는 "적게 골라 읽는" 쿼리(Q1, Q3, Q4, Q2)이다. 많이 읽는 쿼리(Q5, Q6)와 함수를 씌운 쿼리(Q2F)는 인덱스로 거의 바뀌지 않았다.

> [이미지] run_13_tuning.ps1 실행 화면 (쿼리별 튜닝 전후 표)

---

## 실습 쿼리 7개

| 이름 | SQL |
|---|---|
| Q1 | `SELECT order_id, order_date, status, amount FROM orders WHERE customer_id = 12345 ORDER BY order_date DESC LIMIT 5;` |
| Q2 | `SELECT count(*), sum(amount) FROM orders WHERE order_date >= '2025-06-01 00:00:00+09' AND order_date < '2025-06-02 00:00:00+09';` |
| Q2F | `SELECT count(*), sum(amount) FROM orders WHERE date(order_date AT TIME ZONE 'Asia/Seoul') = DATE '2025-06-01';` |
| Q3 | `SELECT order_id, customer_id, order_date, amount FROM orders WHERE is_urgent ORDER BY order_date DESC LIMIT 20;` |
| Q4 | `SELECT o.order_id, o.order_date, o.amount FROM customers c JOIN orders o ON o.customer_id = c.customer_id WHERE c.email = 'user12345@example.com' ORDER BY o.order_date DESC LIMIT 5;` |
| Q5 | `SELECT c.region, count(*) AS orders, sum(o.amount) AS amount FROM customers c JOIN orders o ON o.customer_id = c.customer_id WHERE o.order_date >= '2025-12-01 00:00:00+09' AND o.order_date < '2026-01-01 00:00:00+09' GROUP BY c.region ORDER BY c.region;` |
| Q6 | `SELECT count(*), sum(amount) FROM orders WHERE order_date >= '2024-07-01 00:00:00+09';` |

손으로 칠 때는 아래 명령의 `<Q1>` 자리에 위 SQL을 그대로 붙인다.

---

## 1-1. 준비

**목표**: Leader를 확인하고, 통계를 최신으로 맞춘 뒤 출발점(인덱스 없음)을 눈으로 본다.

**손으로 칠 명령**

[PowerShell]
```powershell
vagrant ssh data-db1
```

[data-db1 VM 안]
```bash
sudo patronictl -c /etc/patroni/patroni.yml list
```
data-db1이 Leader, data-db2가 Replica streaming, Lag 0이면 다음으로 넘어간다.

```bash
sudo -iu postgres psql -d lab_tuning
```

[psql]
```sql
\timing on
```
```sql
SHOW TimeZone;
```
Asia/Seoul이 아니면 `SET TimeZone = 'Asia/Seoul';`을 입력한다 (Q2F가 Q2와 같은 날짜를 보게 하기 위함).

```sql
\d orders
```
```sql
VACUUM (ANALYZE) customers, orders;
```
```sql
SELECT relname, relpages, reltuples::bigint FROM pg_class WHERE relname IN ('customers', 'orders');
```

**이번 결과**

| 테이블 | 페이지 | 행 | 크기 |
|---|---|---|---|
| customers | 1,136 | 100,000 | 9,088 kB |
| orders | 9,130 | 1,000,000 | 71 MB |

**결과 읽는 법**
- `\d orders`의 Indexes에 orders_pkey만 있고 Foreign-key constraints에 customer_id가 있다. FK에는 인덱스가 자동으로 생기지 않는다.
- relpages는 테이블이 8 KB 페이지 몇 개인지이다. 뒤에서 Buffers 숫자가 이 값(9,130)과 비슷하면 "테이블을 다 읽었다"는 뜻이다.
- VACUUM (ANALYZE)는 데이터를 바꾸지 않고 통계와 visibility map만 갱신한다.

**면접에서 말할 한 줄**: "튜닝 전에 VACUUM ANALYZE로 통계를 맞추고, 테이블 페이지 수를 기준값으로 잡아 두었습니다."

---

## 1-2. 튜닝 전 측정과 EXPLAIN 읽기

**목표**: 인덱스가 없을 때 고객 한 명의 주문을 찾으려고 100만 건을 다 읽는 것을 숫자로 확인한다.

**손으로 칠 명령** [psql]
```sql
EXPLAIN (ANALYZE, BUFFERS) <Q1>
```
두 번 실행하고 두 번째 결과를 본다 (첫 번째는 디스크 읽기가 섞일 수 있다). Q2 ~ Q6도 같은 방법으로 한 번씩 측정해 둔다.

**이번 결과 (Q1)**
```
Limit  (actual time=31.301..33.140 rows=5 loops=1)
  Buffers: shared hit=9244
  ->  Gather Merge  (rows=5 loops=1)
        Workers Planned: 2
        ->  Sort  (rows=3 loops=3)
              Sort Key: order_date DESC
              ->  Parallel Seq Scan on orders  (actual ... rows=4 loops=3)
                    Filter: (customer_id = 12345)
                    Rows Removed by Filter: 333329
                    Buffers: shared hit=9130
Execution Time: 33.160 ms
```

**결과 읽는 법**
- **아래에서 위로 읽는다.** 가장 안쪽 노드가 먼저 실행되고, 결과가 위로 올라간다.
- **Parallel Seq Scan**: 테이블 전체를 3개 프로세스(본인 1 + 작업자 2)가 나눠 읽었다.
- **rows=4 loops=3**: rows는 프로세스 하나의 평균이다. 실제 찾은 행은 약 4 x 3 = 12건이다.
- **Rows Removed by Filter: 333329**: 이것도 프로세스 하나 기준이다. 3을 곱하면 약 100만 건을 읽고 버렸다.
- **Buffers: shared hit=9130**: orders의 relpages(9,130)와 같다. 테이블을 처음부터 끝까지 읽었다는 증거이다. hit는 메모리, read는 디스크에서 읽은 페이지이다.
- **Sort**: 인덱스가 없어서 찾은 행을 따로 정렬했다.

**튜닝 전 측정 전체**

| 쿼리 | 계획 | 시간 | 페이지 |
|---|---|---|---|
| Q1 | Limit > Gather Merge > Sort > Seq Scan | 33.4 ms | 9,244 |
| Q2 | Aggregate > Gather > Aggregate > Seq Scan | 37.3 ms | 9,130 |
| Q2F | Aggregate > Gather > Aggregate > Seq Scan | 147.2 ms | 9,130 |
| Q3 | Limit > Gather Merge > Sort > Seq Scan | 42.9 ms | 9,244 |
| Q4 | Limit > Gather Merge > Sort > Hash Join > Seq Scan > Hash > Seq Scan | 76.6 ms | 10,476 |
| Q5 | Aggregate > Gather Merge > Sort > Aggregate > Hash Join > Seq Scan > Hash > Seq Scan | 57.1 ms | 10,288 |
| Q6 | Aggregate > Gather > Aggregate > Seq Scan | 89.2 ms | 9,130 |

Q2F는 Q2와 같은 페이지를 읽는데 4배 느리다. 100만 행마다 date() 함수를 계산하기 때문이다.

> [이미지] 1-2 Q1 실행 계획 화면

**면접에서 말할 한 줄**: "고객 한 명의 주문 5건을 찾는 데 100만 건을 다 읽고 있었고, EXPLAIN ANALYZE의 Rows Removed by Filter와 Buffers가 테이블 페이지 수와 같다는 걸로 전체 스캔을 확인했습니다."

---

## 1-3. 단일 인덱스 시험 (BEGIN, ROLLBACK)

**목표**: customer_id 단일 인덱스의 효과를 보고, 운영 데이터를 남기지 않고 시험하는 방법을 익힌다.

**손으로 칠 명령** [psql]
```sql
BEGIN;
```
```sql
CREATE INDEX idx_try_orders_customer ON orders (customer_id);
```
```sql
EXPLAIN (ANALYZE, BUFFERS) <Q1>
```
```sql
SELECT pg_size_pretty(pg_relation_size('idx_try_orders_customer'));
```
```sql
ROLLBACK;
```
```sql
\di idx_try*
```

**이번 결과**: 33.4 ms, 9,244 페이지에서 0.029 ms, 15 페이지로 줄었다. 계획은 `Limit > Sort > Bitmap Heap Scan > Bitmap Index Scan`이다. 인덱스 크기는 9,088 kB이고, ROLLBACK 뒤 `\di`에 아무것도 나오지 않았다.

**결과 읽는 법**
- **Bitmap Index Scan**: 인덱스에서 조건에 맞는 행 위치를 먼저 모은다.
- **Bitmap Heap Scan**: 모은 위치의 테이블 페이지만 읽는다 (Heap Blocks: exact=12).
- **Sort가 아직 남아 있다**: 인덱스에 order_date가 없어서 정렬은 여전히 따로 한다. 다음 단계에서 없앤다.
- **CREATE INDEX는 트랜잭션 안에서 되돌릴 수 있다.** 같은 트랜잭션 안에서는 플래너가 새 인덱스를 보고 쓴다. 단, 그동안 테이블에 쓰기 잠금(SHARE)이 걸리므로 운영 중인 테이블에서는 짧게 끝내야 한다.

**면접에서 말할 한 줄**: "인덱스 효과는 BEGIN 안에서 만들어 EXPLAIN으로 보고 ROLLBACK해서, 운영에 흔적을 남기지 않고 먼저 검증했습니다."

---

## 1-4. 복합 인덱스와 컬럼 순서

**목표**: 같은 두 컬럼이라도 순서에 따라 효과가 크게 달라지는 것을 확인한다.

**손으로 칠 명령** [psql]

틀린 순서 (시험 후 ROLLBACK)
```sql
BEGIN;
```
```sql
CREATE INDEX idx_try_orders_date_customer ON orders (order_date, customer_id);
```
```sql
EXPLAIN (ANALYZE, BUFFERS) <Q1>
```
```sql
ROLLBACK;
```

맞는 순서 (남김)
```sql
CREATE INDEX idx_orders_customer_date ON orders (customer_id, order_date);
```
```sql
EXPLAIN (ANALYZE, BUFFERS) <Q1>
```

**이번 결과**

| 인덱스 | 계획 | 시간 | 페이지 |
|---|---|---|---|
| 없음 | Seq Scan + Sort | 33.4 ms | 9,244 |
| (customer_id) 단일 | Bitmap + Sort | 0.029 ms | 15 |
| (order_date, customer_id) 틀린 순서 | Index Scan Backward | 7.272 ms | 1,334 |
| (customer_id, order_date) 맞는 순서 | Index Scan Backward, Sort 없음 | 0.023 ms | 8 |

**결과 읽는 법**
- **맞는 순서**: 인덱스가 customer_id로 먼저 모이고 그 안에서 order_date 순으로 정렬되어 있다. 그래서 고객 12345 구간의 끝에서 거꾸로(Backward) 5건만 읽고 끝난다. Sort 노드가 사라졌다.
- **틀린 순서**: 계획에 `Index Cond: (customer_id = 12345)`가 보여도, 인덱스 맨 앞이 order_date라서 고객 구간으로 바로 갈 수 없다. 최신 날짜부터 인덱스를 거의 다 훑으며 고객을 찾았다 (1,334 페이지).
- **원칙**: 같다(=) 조건 컬럼을 앞에, 범위나 정렬 컬럼을 뒤에 둔다.
- **크기**: 단일 (customer_id)는 9 MB인데 복합은 30 MB이다. 고객당 주문이 약 10건이라 단일 인덱스는 중복 값을 묶어 저장(B-tree deduplication, PostgreSQL 13부터)하지만, order_date까지 붙으면 값이 모두 달라져 묶이지 않는다.

> [이미지] 1-4a 틀린 순서와 1-4b 맞는 순서 계획 비교

**면접에서 말할 한 줄**: "복합 인덱스를 (customer_id, order_date)로 만들어 정렬까지 인덱스로 해결했고, 순서를 뒤집으면 같은 쿼리가 300배 느려지는 것도 확인했습니다."

---

## 1-5. 부분 인덱스

**목표**: 전체의 5%만 자주 찾는 조건이면, 그 5%만 담은 인덱스로 충분하다는 것을 크기로 확인한다.

**손으로 칠 명령** [psql]

전체 인덱스 (시험 후 ROLLBACK)
```sql
BEGIN;
```
```sql
CREATE INDEX idx_try_orders_urgent_full ON orders (is_urgent, order_date);
```
```sql
EXPLAIN (ANALYZE, BUFFERS) <Q3>
```
```sql
SELECT pg_size_pretty(pg_relation_size('idx_try_orders_urgent_full'));
```
```sql
ROLLBACK;
```

부분 인덱스 (남김)
```sql
CREATE INDEX idx_orders_urgent_date ON orders (order_date) WHERE is_urgent;
```
```sql
EXPLAIN (ANALYZE, BUFFERS) <Q3>
```
```sql
SELECT pg_size_pretty(pg_relation_size('idx_orders_urgent_date'));
```

**이번 결과**

| 인덱스 | 시간 | 페이지 | 크기 |
|---|---|---|---|
| 없음 | 42.9 ms | 9,244 | 없음 |
| 전체 (is_urgent, order_date) | 0.027 ms | 23 | 30 MB |
| 부분 (order_date) WHERE is_urgent | 0.017 ms | 22 | 1,120 kB |

**결과 읽는 법**
- 두 인덱스 모두 Q3를 거의 같은 속도로 처리한다.
- 크기는 부분 인덱스가 전체의 약 3.6% (약 27분의 1)이다. 긴급 주문 5%만 담았기 때문이다.
- 부분 인덱스 계획에는 Index Cond가 없다. 인덱스에 들어 있는 행 자체가 이미 is_urgent = true이다.
- 쿼리의 WHERE가 인덱스의 WHERE 조건을 포함해야 플래너가 부분 인덱스를 쓴다.

**면접에서 말할 한 줄**: "긴급 주문 5%만 자주 조회해서 부분 인덱스를 썼고, 같은 속도를 내면서 인덱스 크기는 30 MB에서 1.1 MB로 줄였습니다."

---

## 1-6. 기간 인덱스, 그리고 인덱스가 안 쓰이는 경우

**목표**: 같은 뜻의 쿼리라도 쓰는 법에 따라 인덱스를 못 쓰는 경우와, 인덱스를 안 쓰는 게 맞는 경우를 구별한다.

**손으로 칠 명령** [psql]
```sql
CREATE INDEX idx_orders_order_date ON orders (order_date);
```
```sql
EXPLAIN (ANALYZE, BUFFERS) <Q2>
```
```sql
EXPLAIN (ANALYZE, BUFFERS) <Q2F>
```
```sql
EXPLAIN (ANALYZE, BUFFERS) <Q6>
```

**이번 결과**

| 쿼리 | 계획 | 시간 | 페이지 |
|---|---|---|---|
| Q2 범위 조건 | Bitmap Index Scan on idx_orders_order_date | 1.3 ms | 1,251 |
| Q2F 컬럼에 date() | Parallel Seq Scan | 150.9 ms | 9,130 |
| Q6 약 75% 범위 | Parallel Seq Scan | 89.9 ms | 9,130 |

**결과 읽는 법**
- **Q2F**: `date(order_date AT TIME ZONE ...)`처럼 컬럼에 함수를 씌우면, 인덱스에 저장된 값(order_date)과 비교할 수 없어 인덱스를 못 쓴다. 결과는 Q2와 같지만 116배 느리다. 해결은 컬럼은 그대로 두고 상수 쪽을 범위로 바꾸는 것(Q2 형태)이다. 꼭 함수가 필요하면 그 식으로 표현식 인덱스를 만든다.
- **Q6**: 인덱스가 있어도 전체의 75%를 읽어야 하면 Seq Scan이 더 싸다. 인덱스로 가면 페이지를 무작위로 여러 번 오가야 하기 때문이다. 플래너가 맞게 판단한 것이다.
- **Q2의 1,251 페이지**: 하루치 1,340건이 1,244개 페이지에 흩어져 있다. 데이터가 날짜 순으로 들어가지 않아서 행마다 다른 페이지에 있다 (상관관계가 낮다).

> [이미지] 1-6 Q2와 Q2F 계획 비교

**면접에서 말할 한 줄**: "같은 하루 매출 쿼리도 컬럼에 함수를 씌우면 인덱스를 못 타서 116배 느렸고, 범위 조건으로 바꿔 인덱스를 쓰게 했습니다. 반대로 75%를 읽는 쿼리는 Seq Scan이 맞는 선택이었습니다."

---

## 1-7. JOIN 계획

**목표**: JOIN 방식(Nested Loop, Hash Join, Merge Join)이 언제 선택되는지 보고, 플래너 선택을 바꿔 비교한다.

**손으로 칠 명령** [psql]
```sql
EXPLAIN (ANALYZE, BUFFERS) <Q4>
```
```sql
CREATE UNIQUE INDEX idx_customers_email ON customers (email);
```
```sql
EXPLAIN (ANALYZE, BUFFERS) <Q4>
```
```sql
EXPLAIN (ANALYZE, BUFFERS) <Q5>
```
```sql
SET enable_hashjoin = off;
```
```sql
EXPLAIN (ANALYZE, BUFFERS) <Q5>
```
```sql
RESET enable_hashjoin;
```

**이번 결과**

| 단계 | 계획 | 시간 | 페이지 |
|---|---|---|---|
| Q4 인덱스 없음 | Hash Join, 두 테이블 모두 Seq Scan | 76.6 ms | 10,476 |
| Q4 orders 복합 인덱스만 | Nested Loop, customers는 Seq Scan | 7.3 ms | 1,151 |
| Q4 email 인덱스 추가 | Nested Loop, 양쪽 모두 인덱스 | 0.061 ms | 19 |
| Q5 플래너 선택 | Parallel Hash Join | 64.6 ms | 10,310 |
| Q5 Hash Join 끔 | Merge Join | 69.9 ms | 10,563 |

**결과 읽는 법**
- **Nested Loop**: 바깥쪽에서 몇 건만 나오고(고객 1명), 안쪽을 인덱스로 찾을 수 있을 때 가장 빠르다. Q4에서 customers 1행을 찾고, 그 고객의 주문을 idx_orders_customer_date로 찾았다.
- **email 인덱스 전**: 고객 1명을 찾으려고 customers 1,136 페이지를 다 읽었다 (Rows Removed by Filter: 99999). 남은 병목이 어디인지 계획에서 가장 큰 Buffers를 보면 된다.
- **Hash Join**: 양쪽 모두 많을 때 (한 달 주문 40,980건과 고객 10만 명) 작은 쪽으로 해시 표를 만들고 다른 쪽을 대 본다.
- **enable_hashjoin = off**: 이 세션에서만 Hash Join을 막는다. Merge Join이 나왔고 조금 느렸다. 플래너의 선택이 맞았다는 확인용이며, 운영 설정으로 쓰는 것이 아니다.
- **Q5는 1.4배만 빨라졌다**: 결과가 지역 8개로 모이는 집계라 customers 10만 명을 결국 다 읽는다. 인덱스로 해결되지 않는 쿼리도 있다.

> [이미지] 1-7 Q4 email 인덱스 전후 계획

**면접에서 말할 한 줄**: "JOIN 쿼리는 계획에서 Buffers가 가장 큰 노드를 찾아 병목을 하나씩 없앴고, 이메일 조회 JOIN은 Hash Join에서 인덱스 두 개를 쓰는 Nested Loop로 바뀌며 76 ms에서 0.06 ms가 됐습니다."

---

## 1-8. 튜닝 전후 결과가 같은지 증명

**목표**: 인덱스를 바꿔도 결과가 같다는 것을 행 수와 md5로 증명한다.

**손으로 칠 명령** [psql]

튜닝 전(1-2 단계)과 튜닝 후(지금)에 같은 명령을 실행해 값을 비교한다. 예시는 Q1이다.
```sql
SELECT count(*), md5(string_agg(t::text, '|' ORDER BY t::text)) FROM (<Q1 에서 끝의 ; 를 뺀 것>) AS t;
```

**이번 결과**

| 쿼리 | 행 수 | md5 (앞 8자리) | 같음 |
|---|---|---|---|
| Q1 | 5 | 9953bc78 | t |
| Q2 | 1 | 8468037a | t |
| Q2F | 1 | 8468037a | t |
| Q3 | 20 | 820560b1 | t |
| Q4 | 5 | 9b447fd9 | t |
| Q5 | 8 | 11142e57 | t |
| Q6 | 1 | e9e135e3 | t |

**결과 읽는 법**
- 결과 행 전체를 글자로 바꿔 정렬하고 이어 붙인 뒤 md5를 구한다. 한 글자라도 다르면 md5가 달라진다.
- `ORDER BY t::text`로 정렬해서, 실행 계획이 바뀌어 행 순서가 달라져도 같은 값이 나온다.
- Q2와 Q2F의 md5가 같다. 두 쿼리가 같은 뜻이라는 증거이다.
- 측정하는 동안 데이터 변경이 없었으므로 "같은 시점의 데이터"로 비교한 것이다.

**면접에서 말할 한 줄**: "튜닝 전후 7개 쿼리 모두 같은 데이터로 돌려 행 수와 md5가 같은 것을 확인했고, 결과가 바뀌지 않았다는 것을 숫자로 증명했습니다."

---

## 1-9. 정리: 인덱스 비용과 Replica 확인

**목표**: 인덱스가 공짜가 아니라는 것과, Leader에서 만든 인덱스가 Replica에도 그대로 생긴다는 것을 확인한다.

**손으로 칠 명령** [psql]
```sql
SELECT indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) FROM pg_stat_user_indexes WHERE relname IN ('orders', 'customers');
```
```sql
SELECT pg_size_pretty(pg_database_size('lab_tuning'));
```

[data-db2 VM 안]
```bash
sudo -iu postgres psql -d lab_tuning -c "\di"
```

**이번 결과**

| 남긴 인덱스 | 크기 | 쓰는 쿼리 |
|---|---|---|
| idx_orders_customer_date (customer_id, order_date) | 30 MB | Q1, Q4 |
| idx_orders_order_date (order_date) | 21 MB | Q2, Q5 |
| idx_customers_email UNIQUE (email) | 3,992 kB | Q4 |
| idx_orders_urgent_date (order_date) WHERE is_urgent | 1,120 kB | Q3 |

- DB 크기: 111 MB에서 168 MB (인덱스 4개로 약 57 MB 증가, orders 테이블 71 MB의 약 80%)
- data-db2: 인덱스 6개(기본키 2 + 새 인덱스 4)가 모두 보였고, Replica에서도 Q1이 `Index Scan Backward using idx_orders_customer_date`로 0.121 ms에 실행됐다.

**결과 읽는 법**
- 인덱스는 저장 공간을 쓰고, INSERT와 UPDATE 때마다 같이 고쳐야 해서 쓰기를 느리게 한다. 그래서 쓰지 않는 인덱스는 idx_scan으로 찾아서 정리 대상으로 본다.
- customers_pkey의 idx_scan은 원래 약 100만이었다. 04 적재 때 주문 100만 건마다 FK 검사로 고객을 확인했기 때문이다. 그래서 스크립트는 실습 전 값을 빼서 보여 준다.
- CREATE INDEX는 WAL에 기록되어 Replica에 그대로 재생된다. Replica에서 따로 만들 수 없고(읽기 전용), 만들 필요도 없다.

**면접에서 말할 한 줄**: "인덱스 4개로 조회는 최대 수천 배 빨라졌지만 DB가 57 MB 늘었고, 쓰기 비용도 생기기 때문에 실제 쓰는 쿼리가 있는 인덱스만 남겼습니다."

---

## EXPLAIN 읽는 법 요약

| 보는 곳 | 뜻 | 확인할 것 |
|---|---|---|
| 노드 이름 | Seq Scan, Index Scan, Bitmap, Hash Join, Nested Loop, Sort | 읽는 방식과 정렬이 따로 있는지 |
| cost=a..b | 플래너 추정 비용 (단위 없음) | 계획끼리 비교할 때만 쓴다 |
| rows (추정) vs actual rows | 예상 행 수와 실제 행 수 | 크게 다르면 통계가 오래됐을 수 있다 |
| loops | 그 노드가 실행된 횟수 | 병렬이면 rows는 1회 평균이다 |
| Rows Removed by Filter | 읽고 버린 행 | 많으면 조건에 맞는 인덱스가 없다 |
| Buffers hit / read | 메모리 / 디스크에서 읽은 8 KB 페이지 | 테이블 페이지 수와 비교한다 |
| Execution Time | 실제 실행 시간 | 두 번째 실행 값을 쓴다 |

---

## 면접 질문 정리

### Q. EXPLAIN과 EXPLAIN ANALYZE의 차이는?
- **정의**: EXPLAIN은 플래너가 예상한 계획만 보여 주고, EXPLAIN ANALYZE는 쿼리를 실제로 실행해 실제 행 수와 시간을 같이 보여 준다. BUFFERS를 붙이면 읽은 페이지 수가 나온다.
- **내가 해 본 것**: 7개 쿼리를 EXPLAIN (ANALYZE, BUFFERS)로 5번씩 실행해 중앙값을 비교했다. Q1은 Buffers 9,130이 테이블 페이지 수와 같아 전체 스캔을 확인했다.
- **한 줄 답변**: "실제 실행 결과가 필요해서 ANALYZE와 BUFFERS를 같이 보고, 시간보다 읽은 페이지 수로 개선을 판단했습니다."

### Q. 복합 인덱스 컬럼 순서는 어떻게 정하나요?
- **정의**: B-tree는 앞 컬럼부터 정렬되므로 같다(=) 조건 컬럼을 앞에, 범위나 정렬 컬럼을 뒤에 둔다.
- **내가 해 본 것**: (customer_id, order_date)는 0.023 ms, 8 페이지였고, (order_date, customer_id)는 7.272 ms, 1,334 페이지였다.
- **한 줄 답변**: "같다 조건을 앞에 두니 정렬까지 인덱스로 끝났고, 순서를 바꾸면 300배 느려지는 걸 직접 확인했습니다."

### Q. 인덱스를 만들었는데 안 쓰는 이유는?
- **정의**: 컬럼에 함수나 형 변환을 씌운 경우, 읽을 비율이 커서 Seq Scan이 더 싼 경우, 통계가 오래된 경우, 복합 인덱스 앞 컬럼 조건이 없는 경우이다.
- **내가 해 본 것**: date()를 씌운 Q2F는 151 ms로 Seq Scan, 범위로 쓴 Q2는 1.3 ms로 인덱스를 썼다. 75%를 읽는 Q6는 인덱스가 있어도 Seq Scan이었다.
- **한 줄 답변**: "컬럼에 함수를 씌우면 인덱스를 못 쓰고, 많이 읽는 쿼리는 Seq Scan이 맞기 때문에 둘을 구별해서 봅니다."

### Q. 부분 인덱스는 언제 쓰나요?
- **정의**: 테이블 일부 행에만 만드는 인덱스이다. 자주 찾는 조건이 일부 행에 몰려 있을 때 쓴다.
- **내가 해 본 것**: 긴급 주문 5%에 부분 인덱스를 만들어 같은 속도로 크기를 30 MB에서 1.1 MB로 줄였다.
- **한 줄 답변**: "자주 찾는 5%만 담아 인덱스 크기를 27분의 1로 줄였습니다."

### Q. 튜닝 후 결과가 같다는 건 어떻게 확인하나요?
- **정의**: 같은 시점 데이터로 튜닝 전후 쿼리를 실행해 행 수와 결과 해시를 비교한다.
- **내가 해 본 것**: 7개 쿼리 결과를 정렬해 md5를 구했고 모두 같았다. 시험용 인덱스는 BEGIN 안에서 만들고 ROLLBACK했다.
- **한 줄 답변**: "행 수와 md5로 결과가 같은 것을 확인하고, 시험은 ROLLBACK으로 되돌려 운영 데이터에 흔적을 남기지 않았습니다."

---

## 처음부터 다시 할 때

| 방법 | 순서 |
|---|---|
| 코드로 다시 (기준 결과 만들기) | 처음부터 설치 또는 full 스냅샷 세 VM 복원과 resume, 그다음 `powershell -ExecutionPolicy Bypass -File D:\data-lab\run_13_tuning.ps1` |
| 손으로 다시 (연습) | 처음부터 설치 또는 full 스냅샷 복원과 resume, 그다음 이 문서의 1-1부터 "손으로 칠 명령"을 차례로 입력 |

- 13_tuning.sh는 기본키 말고 다른 인덱스가 있으면 멈춘다. 지금 VM에는 튜닝 인덱스 4개가 남아 있으므로, 다시 하려면 full 스냅샷으로 되돌린다.
- 손으로 할 때 숫자는 이 문서와 조금 다를 수 있다. 계획 모양(노드 이름)과 페이지 수가 같은지를 먼저 비교한다.

## 기록 파일

| 파일 | 내용 |
|---|---|
| D:\data-lab\scripts\13_tuning.sh | 실습 1 전체를 실행하는 스크립트 |
| D:\data-lab\run_13_tuning.ps1 | 위 스크립트를 두 VM에 올리고 실행하는 한 줄 실행 파일 |
| D:\data-lab-docs\logs\13_tuning_data-db1_20261105_163901.log | Leader 전체 결과 |
| D:\data-lab-docs\logs\13_tuning_data-db2_20261105_163901.log | Replica 확인 결과 |
| D:\data-lab\README_v2.md | 13단계 설명이 들어간 README |
