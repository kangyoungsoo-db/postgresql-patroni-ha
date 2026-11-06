# 실습 2. 백업과 복구 (pg_dump, pgBackRest)

> 2026-11-05, 개인 실습 환경 D:\data-lab
> 코드(14_backup_restore.sh)로 한 번 실행해 기준 결과를 만들었다. 나중에 처음부터 설치한 뒤 "손으로 칠 명령"을 따라 직접 다시 한다.

| 항목 | 값 |
|---|---|
| DB | PostgreSQL 17.11, Patroni Leader data-db1 (TL 4), Replica data-db2 |
| VM | 2 vCPU, 3 GB, 데이터 디스크 /data |
| 데이터 | lab_tuning 168 MB (customers 10만, orders 100만, 실습 1 인덱스 4개 포함) |
| 백업 저장소 | pgBackRest stanza lab, MinIO(S3, data-mgmt), zst 압축, process-max 2 |
| 걸린 시간 | 실습 전체 1분 14초 |

---

## 한눈에 보기

| 방법 | 종류 | 결과 |
|---|---|---|
| pg_dump -Fc | 논리 백업 | 3.1초, 168 MB DB 가 24 MB 파일 |
| pg_restore -j 2 | 논리 복구 | 7.2초, 원본과 행 수, md5 같음 |
| pgBackRest full | 물리 백업 | 133.5 MB 를 33 MB 로 6초 (구축 때) |
| pgBackRest diff | 물리 백업 | full 이후 바뀐 것만, 228 MB 를 73.3 MB 로 7.4초 |
| pgBackRest incr | 물리 백업 | 직전 백업 이후 바뀐 것만, 53.2 KB 를 6 KB 로 1.6초 |
| pgBackRest restore | 물리 복구 | 358 MB 를 별도 경로에 10.2초, 기동 1.9초, 행 수와 md5 같음 |

- 논리 백업은 "SQL 로 다시 만드는" 방식이라 표 하나만 꺼내기 좋고 버전이 달라도 옮길 수 있다. 대신 큰 DB 는 복구가 느리다.
- 물리 백업은 데이터 파일과 WAL 을 그대로 복사하는 방식이라 빠르고, WAL 과 합치면 원하는 시점으로 되돌릴 수 있다 (PITR).

> [이미지] 실습 2 실행 화면 (요약)

---

## 2-1. pg_dump 논리 백업

**목표**: DB 하나를 custom 형식으로 백업하고, 역할(계정)은 따로 백업한다.

**손으로 칠 명령** [data-db1 VM 안, Leader]
```bash
sudo install -d -m 700 -o postgres -g postgres /data/pgsql/lab-work
```
```bash
sudo -iu postgres pg_dump -Fc -d lab_tuning -f /data/pgsql/lab-work/lab_tuning.dump
```
```bash
sudo -iu postgres pg_restore -l /data/pgsql/lab-work/lab_tuning.dump | grep -E 'TABLE DATA|INDEX'
```
```bash
sudo -iu postgres bash -c 'umask 077; pg_dumpall --globals-only > /data/pgsql/lab-work/globals.sql'
```

**이번 결과**: 3.1초, 파일 24 MB (DB 168 MB). 목록에 TABLE DATA 2개, 인덱스 4개, 기본키, FK 가 들어 있었다. 역할은 3개.

**결과 읽는 법**
- `-Fc`(custom 형식)는 압축되고, pg_restore 로 표 하나만 고르거나 병렬(-j)로 복구할 수 있다. 평문 SQL(-Fp)은 psql 로만 넣을 수 있다.
- 덤프 파일이 DB 보다 훨씬 작은 이유: 인덱스는 데이터가 아니라 "CREATE INDEX 문"으로 저장되고, 표 데이터는 압축된다. 대신 복구할 때 인덱스를 다시 만들어야 해서 시간이 든다.
- pg_dump 는 DB 하나만 담는다. 역할과 권한(클러스터 전체 정보)은 `pg_dumpall --globals-only` 로 따로 남겨야 한다. 이 파일에는 비밀번호 해시가 들어 있어 권한 600 으로 보관한다.
- pg_dump 는 하나의 스냅샷으로 읽기 때문에 운영 중에 떠도 일관된 백업이 나온다.

**면접에서 말할 한 줄**: "pg_dump -Fc 로 168 MB DB 를 3초 만에 24 MB 로 백업했고, 역할은 pg_dumpall --globals-only 로 따로 남겨야 한다는 점까지 챙겼습니다."

---

## 2-2. pg_restore 로 새 DB 에 복구하고 비교

**목표**: 백업이 "정말 복구되는지" 새 DB 에 넣어 확인한다.

**손으로 칠 명령** [data-db1 VM 안]
```bash
sudo -iu postgres createdb lab_restore_test
```
```bash
sudo -iu postgres pg_restore -j 2 -d lab_restore_test /data/pgsql/lab-work/lab_tuning.dump
```
```bash
sudo -iu postgres psql -d lab_tuning -Atc "SELECT count(*) || ' ' || md5(string_agg(t::text, '|' ORDER BY t.order_id)) FROM orders t"
```
```bash
sudo -iu postgres psql -d lab_restore_test -Atc "SELECT count(*) || ' ' || md5(string_agg(t::text, '|' ORDER BY t.order_id)) FROM orders t"
```

**이번 결과**

| 표 | 원본 | 복구본 | 같음 |
|---|---|---|---|
| customers | 100000, 6211607a... | 100000, 6211607a... | 같음 |
| orders | 1000000, b8abca88... | 1000000, b8abca88... | 같음 |

pg_restore -j 2 는 7.2초 걸렸고, 복구한 DB 크기도 168 MB 로 같았다.

**결과 읽는 법**
- 백업 3.1초, 복구 7.2초. 복구가 더 오래 걸리는 이유는 인덱스와 제약 조건을 다시 만들기 때문이다. 큰 DB 에서는 이 차이가 훨씬 커진다.
- `-j 2` 는 표와 인덱스를 2개씩 병렬로 넣는다. custom, directory 형식에서만 된다.
- 행 수만 보면 내용이 바뀌어도 모른다. 정렬한 전체 행의 md5 까지 같아야 "같은 데이터"라고 말할 수 있다.

**면접에서 말할 한 줄**: "백업은 복구해 봐야 백업이라고 보고, 새 DB 에 복구한 뒤 행 수와 md5 로 원본과 같은지 확인했습니다."

---

## 2-3. pgBackRest 백업 종류 (full, diff, incr)

**목표**: 물리 백업 세 종류의 차이를 크기와 시간으로 본다.

**손으로 칠 명령** [data-db1 VM 안, Leader]
```bash
sudo -iu postgres pgbackrest --stanza=lab info
```
```bash
sudo -iu postgres pgbackrest --stanza=lab --type=diff backup
```
```bash
sudo -iu postgres pgbackrest --stanza=lab --type=incr backup
```
```bash
sudo -iu postgres pgbackrest --stanza=lab info
```
```bash
sudo -iu postgres psql -c "SELECT archived_count, last_archived_wal, failed_count FROM pg_stat_archiver;"
```

**이번 결과**

| 백업 | 기준 | 원본에서 복사한 양 | 저장소에 쓴 양 | 시간 |
|---|---|---|---|---|
| full 20261105-155815F | 전체 | 133.5 MB | 33 MB | 6초 |
| diff ..._171906D | full 이후 바뀐 것 | 228 MB | 73.3 MB | 7.4초 |
| incr ..._171914I | 직전 diff 이후 바뀐 것 | 53.2 KB | 6 KB | 1.6초 |

**결과 읽는 법**
- **full**: 전부 복사한다. 복구할 때 이것 하나면 된다.
- **diff**: 마지막 full 이후 바뀐 파일만. 복구할 때 full + diff 두 개가 필요하다. 이번에는 full 이후 실습 1 인덱스(약 57 MB)와 lab_restore DB(168 MB)가 생겨서 228 MB 가 됐다.
- **incr**: 직전 백업(종류 상관없음) 이후 바뀐 것만. 가장 작고 빠르지만 복구할 때 full + diff + incr 이 모두 있어야 한다 (`backup reference total: 1 full, 1 diff`).
- **"a timeline switch has occurred ... enabling delta checksum" 경고**: full 백업 뒤 switchover 로 타임라인이 2에서 4로 바뀌어서, 파일 시각 대신 체크섬으로 바뀐 파일을 찾았다는 뜻이다. 승격이나 복구 뒤에는 정상이다.
- **zst 압축**: 저장소에 쓴 양이 원본의 약 4분의 1이다.
- **pg_stat_archiver failed_count 1**: 이전에 WAL 아카이브가 한 번 실패한 적이 있다는 뜻이다. archived_count 가 계속 늘고 있으면 지금은 정상이다. 운영에서는 이 숫자가 늘어나는지 모니터링한다 (실습 9 에서 일부러 재현).

**면접에서 말할 한 줄**: "full, diff, incr 을 직접 떠서 incr 은 1.6초에 6 KB 만 쓰지만 복구할 때 full 과 diff 가 모두 필요하다는 차이를 확인했습니다."

---

## 2-4. pgBackRest 로 별도 경로에 복구하고 확인

**목표**: 운영 DB 를 건드리지 않고, 백업을 다른 폴더에 풀어 임시 인스턴스로 띄워 본다.

**손으로 칠 명령** [data-db1 VM 안]
```bash
sudo install -d -m 700 -o postgres -g postgres /data/pgsql/lab-work/restore_test
```
```bash
sudo -iu postgres pgbackrest --stanza=lab --pg1-path=/data/pgsql/lab-work/restore_test --type=immediate --target-action=promote restore
```
```bash
sudo grep -E '^(restore_command|recovery_target)' /data/pgsql/lab-work/restore_test/postgresql.auto.conf
```
```bash
sudo -iu postgres pg_ctl -D /data/pgsql/lab-work/restore_test -l /data/pgsql/lab-work/restore_test.log -o "-p 5433 -c listen_addresses='' -c archive_mode=off -c hot_standby=off -c shared_buffers=128MB -c logging_collector=off -c data_directory=/data/pgsql/lab-work/restore_test -c hba_file=/data/pgsql/lab-work/restore_test/pg_hba.conf -c ident_file=/data/pgsql/lab-work/restore_test/pg_ident.conf" -w start
```
```bash
sudo -iu postgres psql -p 5433 -h /run/postgresql -d lab_tuning -c "SELECT count(*) FROM orders;"
```
```bash
sudo -iu postgres pg_ctl -D /data/pgsql/lab-work/restore_test -m fast stop
```

**이번 결과**: restore 10.2초(358 MB), 기동(WAL 재생과 승격) 1.9초. customers, orders 모두 운영과 행 수, md5 가 같았다. 임시 인스턴스는 포트 5433, 타임라인 5 로 승격됐다.

**결과 읽는 법**
- `--pg1-path` 로 복구 위치를 바꾸면 운영 데이터 디렉터리는 그대로 두고 시험할 수 있다. pgBackRest 는 restore_command 에도 바뀐 경로를 넣어 준다.
- `--type=immediate`: 백업이 일관된 상태가 되는 순간(백업 끝)까지만 WAL 을 재생하고 멈춘다. `--target-action=promote` 로 그 자리에서 읽기 쓰기 가능하게 승격한다.
- 띄울 때 꼭 바꾸는 옵션:
  - `-p 5433 -c listen_addresses=''`: 운영(5432)과 겹치지 않게 소켓으로만 접속
  - `archive_mode=off`: 복구본이 새 타임라인 WAL 을 운영 저장소에 올려 섞이지 않게
  - `data_directory`, `hba_file`, `ident_file`: Patroni 설정 파일에 운영 경로가 들어 있어도 복구 폴더를 보게 고정
- `pg_ctl -w` 가 "server started" 를 말해도 아직 접속이 안 될 수 있다. 스크립트는 접속될 때까지 기다리게 했다 (로컬 시험에서 찾은 문제).

**면접에서 말할 한 줄**: "pgBackRest 복구를 운영과 다른 경로, 다른 포트에 해서 운영을 건드리지 않고 10초 만에 복구본을 띄워 데이터가 같은지 확인했고, 복구본은 archive_mode 를 꺼서 운영 백업 저장소를 오염시키지 않게 했습니다."

---

## 면접 질문 정리

### Q. 논리 백업과 물리 백업의 차이는?
- **정의**: 논리 백업(pg_dump)은 데이터를 SQL 로 꺼내고, 물리 백업(pgBackRest, pg_basebackup)은 데이터 파일과 WAL 을 그대로 복사한다.
- **내가 해 본 것**: pg_dump 3.1초, 24 MB 와 pg_restore 7.2초. pgBackRest restore 는 358 MB 를 10.2초에 풀고 1.9초에 기동했다.
- **한 줄 답변**: "표 하나 되살리기나 버전 이동에는 논리 백업, 전체 복구와 시점 복구에는 물리 백업을 씁니다."

### Q. full, diff, incr 은 어떻게 다른가?
- **정의**: full 은 전체, diff 는 마지막 full 이후, incr 은 직전 백업 이후 바뀐 것만 담는다.
- **내가 해 본 것**: diff 7.4초 73.3 MB, incr 1.6초 6 KB. incr 복구에는 full, diff, incr 이 모두 필요했다.
- **한 줄 답변**: "백업은 incr 이 가장 빠르지만 복구에 필요한 묶음이 길어지므로, full 주기와 보관 개수를 함께 정합니다."

### Q. 백업이 잘 됐는지는 어떻게 아나?
- **정의**: 백업 성공 메시지가 아니라, 실제로 복구해서 데이터를 비교해야 안다.
- **내가 해 본 것**: pg_restore 와 pgBackRest restore 둘 다 별도 DB, 별도 경로에 복구해 행 수와 md5 가 같은 것을 확인했다.
- **한 줄 답변**: "정기적으로 다른 경로에 복구해 보고 데이터 지문을 비교하는 것까지가 백업이라고 생각합니다."

---

## 기록 파일

| 파일 | 내용 |
|---|---|
| D:\data-lab\scripts\14_backup_restore.sh | 실습 2 전체 스크립트 |
| D:\data-lab-docs\logs\labs_20261105_171809\lab02_backup_restore.log | 실행 기록 |
