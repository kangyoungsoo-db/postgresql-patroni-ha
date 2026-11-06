# data-lab: PostgreSQL 17 Primary / Standby 실습 환경 (README v3)

VM 3대로 PostgreSQL 17 고가용성 실습 환경을 만든다. 처음에는 수동 스트리밍 복제(0 ~ 6단계)로 만들고, 그 위에 Patroni, etcd, PgBouncer, pgBackRest, MinIO, 모니터링을 올렸다(7 ~ 12단계, 문서 뒤쪽 "확장 구성").

| VM | 역할 | IP | CPU | RAM | 데이터 디스크 |
|---|---|---|---|---|---|
| data-db1 | Patroni 노드 (평소 Leader) | 192.168.56.11 | 2 | 3 GB | 50 GB (/data) |
| data-db2 | Patroni 노드 (평소 Replica) | 192.168.56.12 | 2 | 3 GB | 50 GB (/data) |
| data-mgmt | etcd 3번, MinIO, Prometheus, Grafana | 192.168.56.13 | 2 | 2 GB | 50 GB (/data) |

- Box: bento/rockylinux-10.1 (202512.01.0)
- PostgreSQL: PGDG 저장소의 postgresql17-server
- PGDATA: /data/pgsql/17/data
- 사양과 IP는 Vagrantfile 맨 위 `NODES` 에서 숫자만 바꾸면 된다.

## 파일 구성

| 파일 | 하는 일 | 실행 대상 |
|---|---|---|
| Vagrantfile | VM 3대 정의, 데이터 디스크 생성과 연결, provision 등록 | 없음 |
| scripts/01_base.sh | 시간대, /etc/hosts, 기본 패키지, 방화벽, /data 마운트, SELinux 라벨 | 세 VM |
| scripts/02_pg17.sh | PostgreSQL 17 설치, initdb (data-db1 만), 기본 설정 | data-db1, data-db2 |
| scripts/03_replication.sh | 복제 사용자와 pg_hba (data-db1), pg_basebackup 으로 Standby 생성 (data-db2) | VM 안에서 직접 |
| scripts/04_sample.sh | lab_tuning DB, customers 10만 건, orders 100만 건 적재 | data-db1 |
| scripts/05_secrets.sh | 복사한 비밀값을 /etc/lab-secrets 로 옮기고 원본 삭제 | 세 VM |
| scripts/06_etcd.sh | etcd 3.6 설치와 기동 (3대 클러스터) | 세 VM |
| scripts/07_patroni.sh | PostgreSQL 을 Patroni 관리로 넘김, softdog watchdog | data-db1, data-db2 |
| scripts/08_pgbouncer.sh | PgBouncer 6432 | data-db1, data-db2 |
| scripts/09_minio.sh | MinIO (TLS 자체 서명), 버킷 pgbackrest | data-mgmt |
| scripts/10_pgbackrest.sh | pgBackRest 설정, Leader 에서 stanza 생성과 full 백업 | data-db1, data-db2 |
| scripts/11_exporters.sh | node_exporter, postgres_exporter, 백업 시각 타이머 | data-db1, data-db2 |
| scripts/12_monitoring.sh | Prometheus (백업 경보), Grafana (PostgreSQL 대시보드) | data-mgmt |
| scripts/13_tuning.sh | 쿼리 튜닝 실습 1 전체 (측정, 인덱스 시험과 생성, 결과 같음 증명) | VM 안에서 직접 (Leader, Replica) |
| scripts/lab_lib.sh | 실습 스크립트 공통 함수 (기록, 상태 확인, 쓰기 시험, 결과 요약) | source 해서 씀 |
| scripts/lab_ctl.sh | 스냅샷 복원 뒤 시계 맞추기, full/baseline 준비, 상태 기록 시작과 요약 | VM 안에서 직접 |
| scripts/14_backup_restore.sh | 실습 2 백업과 복구 (pg_dump, pg_restore, pgBackRest diff/incr, 별도 경로 복구) | Leader |
| scripts/15_manual_failover.sh | 실습 3 수동 페일오버 (복제 끊김, kill -9, pg_promote, pg_rewind) | baseline 의 data-db1, data-db2 |
| scripts/16_patroni_basics.sh | 실습 4 Patroni 상태, REST, PgBouncer 경로, switchover | full |
| scripts/17_ops.sh | 실습 5 잠금, 교착 상태, VACUUM, 운영 점검 SQL, Prometheus | full (prom 은 data-mgmt) |
| scripts/18_drill_primary_down.sh | 실습 6 장애 훈련 1 Primary 강제 종료 | full |
| scripts/19_drill_network_split.sh | 실습 7 장애 훈련 2 망 분리 (nftables) | full |
| scripts/20_drill_etcd_quorum.sh | 실습 8 장애 훈련 3 etcd 1대, 2대 중지 | full |
| scripts/21_drill_backup_fail.sh | 실습 9 장애 훈련 4 백업 실패와 경보 | full |
| scripts/22_drill_pitr.sh | 실습 10 장애 훈련 5 PITR | full, Leader |
| run_13_tuning.ps1 | 실습 1 을 두 VM 에 올리고 실행 (호스트) | PowerShell |
| run_all_labs.ps1 | 실습 2 ~ 10 을 스냅샷 복원부터 정리까지 한 번에 실행 (호스트) | PowerShell |

`vagrant up` 은 VM 생성과 부팅, 데이터 디스크 연결까지만 한다. 스크립트는 자동으로 실행되지 않고, 아래 순서대로 하나씩 실행한다.

---

## 0단계. 준비 (PowerShell, PowerShell 창을 열 때마다)

이 프로젝트는 Vagrant 홈을 따로 쓴다. 기존 D:\vagrant_home 은 건드리지 않는다.

[PowerShell]
```powershell
cd D:\data-lab
```
이 명령은 실습 폴더로 이동한다.

```powershell
$env:VAGRANT_HOME = "D:\data-lab\.vagrant_home"
```
이 명령은 지금 열린 PowerShell 창에서만 Vagrant 홈을 바꾼다. 창을 새로 열면 다시 입력한다.

### 0-1. box 복사 (처음 한 번만)

[PowerShell]
```powershell
New-Item -ItemType Directory -Force -Path D:\data-lab\.vagrant_home\boxes
```
이 명령은 새 Vagrant 홈에 boxes 폴더를 만든다. 이미 있으면 그대로 둔다.

```powershell
Copy-Item -Recurse -Path D:\vagrant_home\boxes\bento-VAGRANTSLASH-rockylinux-10.1 -Destination D:\data-lab\.vagrant_home\boxes\
```
이 명령은 기존 box 폴더를 새 Vagrant 홈으로 복사한다 (약 1 GB). 원본은 읽기만 한다.

```powershell
vagrant box list
```
이 명령은 새 홈에 box 가 보이는지 확인한다.
- 정상: `bento/rockylinux-10.1 (virtualbox, 202512.01.0, (amd64))` 한 줄이 나오고 오류가 없다.
- `machine index ... corrupt` 오류가 나오면 VAGRANT_HOME 이 적용되지 않은 것이다. 위 `$env:VAGRANT_HOME` 을 다시 입력한다.

---

## 1단계. VM 올리기 (PowerShell)

한 대씩 올린다. 처음에는 VM 1대당 약 2 ~ 5분 걸린다.

[PowerShell]
```powershell
vagrant up data-db1
```
이 명령은 data-db1 을 만들고 켠다. 처음 한 번은 50 GB 데이터 디스크(D:\data-lab\.disks\data-db1-pgdata.vdi)를 만들어 붙인다.

```powershell
vagrant status
```
이 명령은 VM 상태를 보여 준다. data-db1 이 `running` 이면 다음으로 넘어간다.

```powershell
vagrant up data-db2
```
이 명령은 data-db2 를 만들고 켠다.

---

## 2단계. 스크립트 복사와 기본 설정 (PowerShell)

[PowerShell]
```powershell
vagrant provision data-db1 --provision-with 00_copy
```
이 명령은 scripts 폴더를 data-db1 의 /home/vagrant/lab-scripts 로 복사한다. 한 번만 실행한다.

```powershell
vagrant provision data-db2 --provision-with 00_copy
```
이 명령은 같은 복사를 data-db2 에 한다.

```powershell
vagrant provision data-db1 --provision-with 01_base
```
이 명령은 data-db1 에 01_base.sh 를 실행한다. 마지막에 `[01] 완료` 가 나오면 성공이다.

```powershell
vagrant provision data-db2 --provision-with 01_base
```
이 명령은 같은 기본 설정을 data-db2 에 한다.

---

## 3단계. SELinux 라벨 확인 (VM 안)

02 를 실행하기 전에 /data/pgsql 라벨을 눈으로 확인한다. 두 VM 모두 한다.

[PowerShell]
```powershell
vagrant ssh data-db1
```
이 명령은 data-db1 에 접속한다.

[VM 안]
```bash
ls -Zd /data/pgsql
```
이 명령은 /data/pgsql 의 SELinux 라벨을 보여 준다.
- 정상: `system_u:object_r:postgresql_db_t:s0 /data/pgsql`
- `default_t` 나 `unlabeled_t` 가 보이면 02 로 넘어가지 않고 멈춘다.

```bash
df -h /data
```
이 명령은 /data 에 약 50 GB 디스크가 붙었는지 보여 준다.

```bash
exit
```
이 명령은 VM 에서 나온다.

data-db2 도 `vagrant ssh data-db2` 로 들어가서 같은 확인을 한다.

---

## 4단계. PostgreSQL 17 설치 (PowerShell)

[PowerShell]
```powershell
vagrant provision data-db1 --provision-with 02_pg17
```
이 명령은 data-db1 에 PostgreSQL 17 을 설치하고 initdb 와 기본 설정을 한다. 결과에서 버전과 `data_directory = /data/pgsql/17/data` 를 확인한다.

```powershell
vagrant provision data-db2 --provision-with 02_pg17
```
이 명령은 data-db2 에 PostgreSQL 17 을 설치한다. initdb 는 하지 않는다 (5단계에서 Primary 를 복사해 만든다).

---

## 5단계. 복제 구성 (VM 안, 비밀번호 입력)

복제 비밀번호는 D:\data-lab\.secrets\repl_pw 에 있다. 바꾸려면 ALTER ROLE replicator PASSWORD 를 쓴다.

VM 안에 /root/repl_pw 가 있으면 03 은 그 파일에서 비밀번호를 읽고 바로 지운다. 없으면 직접 입력받는다.

비밀번호를 직접 입력해야 해서 VM 안에서 실행한다. 비밀번호는 화면에 보이지 않는다. 문서에는 `<비밀번호>` 로만 적는다.

### 5-1. data-db1 (Primary)

[PowerShell]
```powershell
vagrant ssh data-db1
```
이 명령은 data-db1 에 접속한다.

[VM 안]
```bash
sudo bash ~/lab-scripts/03_replication.sh
```
이 명령은 복제 사용자 replicator 를 만들고 pg_hba.conf 에 복제 허용을 추가한다. `<비밀번호>` 를 두 번 입력한다.

```bash
exit
```
이 명령은 VM 에서 나온다.

### 5-2. data-db2 (Standby)

[PowerShell]
```powershell
vagrant ssh data-db2
```
이 명령은 data-db2 에 접속한다.

[VM 안]
```bash
sudo bash ~/lab-scripts/03_replication.sh
```
이 명령은 같은 `<비밀번호>` 를 입력받아 pg_basebackup 으로 Standby 를 만들고 기동한다. 결과에 `streaming` 이 보이면 성공이다.

```bash
exit
```
이 명령은 VM 에서 나온다.

---

## 6단계. 샘플 데이터 적재 (PowerShell)

[PowerShell]
```powershell
vagrant provision data-db1 --provision-with 04_sample
```
이 명령은 data-db1 에 lab_tuning DB 를 만들고 customers 10만 건, orders 100만 건을 넣는다. orders.is_urgent 는 true 가 약 5% 이다 (부분 인덱스 실습용). 결과에 걸린 시간과 테이블 크기가 나온다. data-db2 에는 복제로 자동 반영된다.

---

## VM 켜고 끄기

Patroni 를 올린 뒤의 순서는 문서 뒤쪽 "서비스 켜고 끄는 순서" 를 따른다.

## 현재 설정과 정상 상태 스냅샷

wal_log_hints = on 으로 설정되어 있다 (pg_rewind 를 쓰기 위함, 바꾸려면 재시작 필요).

정상 상태 스냅샷 이름은 baseline 이다. 되돌리기: vagrant snapshot restore data-db1 baseline

(Patroni 를 올린 뒤에는 full 스냅샷도 있다. 두 스냅샷의 차이는 문서 뒤쪽 "스냅샷 두 개의 차이와 되돌리는 법" 을 본다.)

주의: 되돌릴 때는 data-db1 과 data-db2 를 같이 baseline 으로 되돌려야 복제가 맞는다. 한 대만 되돌리면 WAL 위치가 어긋나 복제가 끊긴다.

[PowerShell]
```powershell
vagrant snapshot list data-db1
```
이 명령은 data-db1 의 스냅샷 목록을 보여 준다. `baseline` 이 보이면 정상이다.

```powershell
vagrant snapshot restore data-db1 baseline
```
이 명령은 data-db1 을 baseline 시점으로 되돌린다.

```powershell
vagrant snapshot restore data-db2 baseline
```
이 명령은 data-db2 를 baseline 시점으로 되돌린다. data-db1 다음에 바로 실행한다.

참고: 스냅샷을 찍은 뒤부터 바뀐 내용은 D:\VirtualBoxVMs\data-db1\Snapshots 같은 VM 폴더의 차분 디스크에 쌓인다. D:\data-lab\.disks 의 vdi 는 baseline 시점의 원본으로 남는다.

## 주의: vagrant destroy 는 데이터 디스크도 지운다

Vagrant 2.4.9 소스(VirtualBox provider 의 `delete`)를 확인한 결과, `vagrant destroy` 는 `VBoxManage unregistervm <VM> --delete` 를 실행한다. VirtualBox 도움말에 따르면 `--delete` 는 "VM 이 쓰는 모든 하드디스크 이미지 파일"을 지운다. 따라서 **D:\data-lab\.disks 의 데이터 디스크도 같이 삭제된다.**

destroy 가 필요하면 먼저 VM 을 끄고 .disks 폴더를 백업한다.

[PowerShell]
```powershell
Copy-Item -Recurse -Path D:\data-lab\.disks -Destination D:\data-lab-backup\.disks
```
이 명령은 데이터 디스크 폴더를 다른 곳에 복사해 둔다. 스냅샷이 있으면 최신 데이터는 VM 폴더의 Snapshots 안 차분 디스크에 있으므로 .disks 만 복사해서는 최신 상태가 남지 않는다.

참고: destroy 때 Host-Only 어댑터는 지우지 않도록 Vagrantfile 에 `destroy_unused_network_interfaces = false` 를 적어 두었다.

---

## 최종 확인 체크리스트

| 번호 | 확인할 것 | 실행 위치 | 명령 | 정상 결과 |
|---|---|---|---|---|
| 1 | 두 VM 이 켜져 있다 | PowerShell | `vagrant status` | data-db1, data-db2 모두 `running` |
| 2 | data-db1 에 접속된다 | PowerShell | `vagrant ssh data-db1` | `[vagrant@data-db1 ~]$` 프롬프트 |
| 3 | data-db2 에 접속된다 | PowerShell | `vagrant ssh data-db2` | `[vagrant@data-db2 ~]$` 프롬프트 |
| 4 | Primary 에서 복제가 streaming 이다 | data-db1 VM 안 | `sudo -iu postgres psql -c "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;"` | `data-db2`, `192.168.56.12`, `streaming`, `async` |
| 5 | Standby 가 WAL 을 받고 있다 | data-db2 VM 안 | `sudo -iu postgres psql -c "SELECT status, sender_host FROM pg_stat_wal_receiver;"` | `streaming`, `data-db1` |
| 6 | Standby 는 읽기 전용이다 | data-db2 VM 안 | `sudo -iu postgres psql -c "SELECT pg_is_in_recovery();"` | `t` |
| 7 | 복제 슬롯이 쓰이고 있다 | data-db1 VM 안 | `sudo -iu postgres psql -c "SELECT slot_name, active FROM pg_replication_slots;"` | `data_db2`, `t` |
| 8 | customers 건수 | data-db1 VM 안 | `sudo -iu postgres psql -d lab_tuning -c "SELECT count(*) FROM customers;"` | `100000` |
| 9 | orders 건수 | data-db1 VM 안 | `sudo -iu postgres psql -d lab_tuning -c "SELECT count(*) FROM orders;"` | `1000000` |
| 10 | Standby 에도 같은 건수가 있다 | data-db2 VM 안 | `sudo -iu postgres psql -d lab_tuning -c "SELECT count(*) FROM orders;"` | `1000000` |
| 11 | PGDATA 위치 | 두 VM 안 | `sudo -iu postgres psql -c "SHOW data_directory;"` | `/data/pgsql/17/data` |
| 12 | WAL 보관 상한 | 두 VM 안 | `sudo -iu postgres psql -c "SHOW max_slot_wal_keep_size;"` | `10GB` |
| 13 | 긴급 주문 비율 | data-db1 VM 안 | `sudo -iu postgres psql -d lab_tuning -c "SELECT count(*) FROM orders WHERE is_urgent;"` | 약 50,000 (5% 안팎) |

---

# 확장 구성 (Patroni, etcd, PgBouncer, pgBackRest, MinIO, 모니터링)

## 구성도

| 구성 요소 | data-db1 (192.168.56.11) | data-db2 (192.168.56.12) | data-mgmt (192.168.56.13) | 포트 |
|---|---|---|---|---|
| PostgreSQL 17 | Patroni 가 관리 (평소 Leader) | Patroni 가 관리 (평소 Replica) | 없음 | 5432 |
| Patroni 4.1 | 있음 | 있음 | 없음 | 8008 (REST) |
| etcd 3.6 | 멤버 1 | 멤버 2 | 멤버 3 (DB 와 따로 멈추도록 관리 서버에 둠) | 2379, 2380 |
| watchdog | softdog, /dev/watchdog, mode=required | softdog, /dev/watchdog, mode=required | 없음 | 없음 |
| PgBouncer | 로컬 PostgreSQL 로 연결 | 로컬 PostgreSQL 로 연결 | 없음 | 6432 |
| pgBackRest | 설정 (Leader 에서 백업) | 설정 (Leader 가 되면 백업) | 없음 | 없음 |
| MinIO | 없음 | 없음 | 저장소 (버킷 pgbackrest) | 9000 (S3), 9001 (콘솔) |
| node_exporter | 있음 (백업 시각 textfile 포함) | 있음 | 없음 | 9100 |
| postgres_exporter | 있음 | 있음 | 없음 | 9187 |
| Prometheus | 없음 | 없음 | 있음 (경보 규칙 1개) | 9090 |
| Grafana | 없음 | 없음 | 있음 (PostgreSQL 대시보드 1개) | 3000 |

## 접속 정보

| 대상 | 주소 | 사용자 | 비밀번호 |
|---|---|---|---|
| Grafana | http://192.168.56.13:3000 | admin | `<비밀번호>` (D:\data-lab\.secrets\grafana_admin_pw) |
| MinIO 콘솔 | https://192.168.56.13:9001 | `<접근 키>` (D:\data-lab\.secrets\minio_access_key) | `<비밀번호>` (D:\data-lab\.secrets\minio_secret_key) |
| Prometheus | http://192.168.56.13:9090 | 없음 | 없음 |
| PgBouncer (Primary 찾기) | host=data-db1,data-db2 port=6432 dbname=lab_tuning target_session_attrs=read-write | lab_app | `<비밀번호>` (D:\data-lab\.secrets\lab_app_pw) |
| PostgreSQL 직접 | 192.168.56.11 또는 .12, 5432 | postgres | `<비밀번호>` (D:\data-lab\.secrets\postgres_pw) |
| 복제 사용자 | 5432 replication | replicator | `<비밀번호>` (D:\data-lab\.secrets\repl_pw) |
| Patroni REST | http://192.168.56.11:8008, http://192.168.56.12:8008 | 없음 | 없음 |

- 복제 비밀번호는 D:\data-lab\.secrets\repl_pw 에 있다. 바꾸려면 ALTER ROLE replicator PASSWORD 를 쓴다. Patroni 를 쓰는 지금은 /etc/patroni/patroni.yml 의 replication 비밀번호도 같이 바꿔야 한다.
- VM 안의 비밀값은 /etc/lab-secrets (root 전용, 600) 에 있다.
- MinIO 콘솔은 자체 서명 인증서라 브라우저 경고가 뜬다. 실습용이라 그대로 진행한다.

## 운영에서는 안 되는 실습용 설정

- pgBackRest 는 `repo1-storage-verify-tls=n` 으로 MinIO 의 자체 서명 인증서를 검증하지 않는다. 운영에서는 신뢰할 수 있는 인증서를 쓰고 검증을 켜야 한다.
- MinIO 커뮤니티판은 개발이 끝나(archived) 보안 업데이트가 없다. GitHub 에 남은 마지막 바이너리(RELEASE.2025-09-07T16-13-09Z)를 SHA256 으로 확인해서 실습에만 쓴다.
- etcd 는 TLS 와 인증 없이 Host-Only 망 안에서만 쓴다.

## 확장 구성 설치 순서 (PowerShell)

새 PowerShell 창이면 0단계의 `$env:VAGRANT_HOME` 부터 입력한다.

```powershell
vagrant up data-mgmt
```
이 명령은 data-mgmt 를 만들고 켠다.

```powershell
vagrant provision data-mgmt --provision-with 01_base
```
이 명령은 data-mgmt 에 기본 설정과 /data 디스크를 준비한다. data-db1, data-db2 도 한 번씩 다시 실행해 hosts 에 data-mgmt 를 넣는다.

```powershell
vagrant provision data-db1 --provision-with 00_secrets
```
이 명령은 D:\data-lab\.secrets 를 VM 으로 복사한다. 세 VM 모두 한 번씩 실행한다.

```powershell
vagrant provision data-db1 --provision-with 05_secrets
```
이 명령은 복사한 비밀값을 /etc/lab-secrets 로 옮기고 원본을 지운다. 세 VM 모두 한 번씩 실행한다.

```powershell
vagrant provision data-db1 --provision-with 06_etcd
```
이 명령은 etcd 를 설치하고 시작한다. data-db2, data-mgmt 에도 실행한다.

```powershell
vagrant provision data-db1 --provision-with 07_patroni
```
이 명령은 data-db1 의 PostgreSQL 을 Patroni 관리로 넘긴다. 다음에 data-db2 에 실행한다.

```powershell
vagrant provision data-db1 --provision-with 08_pgbouncer
```
이 명령은 PgBouncer 를 설치한다. data-db2 에도 실행한다.

```powershell
vagrant provision data-mgmt --provision-with 09_minio
```
이 명령은 MinIO 를 설치하고 버킷 pgbackrest 를 만든다.

```powershell
vagrant provision data-db2 --provision-with 10_pgbackrest
```
이 명령은 Replica 에 pgBackRest 설정만 한다.

```powershell
vagrant provision data-db1 --provision-with 10_pgbackrest
```
이 명령은 Leader 에서 stanza 생성, check, full 백업을 한다.

```powershell
vagrant provision data-db1 --provision-with 11_exporters
```
이 명령은 node_exporter, postgres_exporter, 백업 시각 타이머를 설치한다. data-db2 에도 실행한다.

```powershell
vagrant provision data-mgmt --provision-with 12_monitoring
```
이 명령은 Prometheus 와 Grafana 를 설치한다.

## 상태 확인 (VM 안)

```bash
sudo patronictl -c /etc/patroni/patroni.yml list
```
이 명령은 Leader 와 Replica, 지연(Lag)을 보여 준다.

```bash
/usr/local/bin/etcdctl --endpoints=http://127.0.0.1:2379 endpoint health --cluster
```
이 명령은 etcd 3대가 healthy 인지 보여 준다.

```bash
cat /sys/class/watchdog/watchdog0/identity
```
이 명령은 /dev/watchdog 를 어떤 드라이버가 쓰는지 보여 준다. `Software Watchdog` 이 정상이다. `iTCO_wdt` 가 보이면 승격이 막힐 수 있다.

```bash
sudo -u postgres pgbackrest --stanza=lab info
```
이 명령은 백업 목록과 WAL 아카이브 범위를 보여 준다.

```bash
sudo -u postgres pgbackrest --stanza=lab --type=full backup
```
이 명령은 full 백업을 한다. Leader 에서 실행한다.

```bash
sudo patronictl -c /etc/patroni/patroni.yml switchover lab
```
이 명령은 Leader 를 다른 노드로 계획 전환한다. 묻는 대로 답한다.

## 백업 경보

- data-db1, data-db2 의 lab-backup-metric.timer 가 5분마다 `pgbackrest info` 를 읽어 `lab_backup_last_success_timestamp_seconds` 를 node_exporter textfile 로 쓴다.
- Prometheus 경보 `PgBackRestBackupTooOld` 는 마지막 성공 백업이 26시간(93600초)보다 오래되었거나 지표가 없으면 10분 뒤 firing 이 된다.
- 확인 주소: http://192.168.56.13:9090/alerts

## 13단계. 쿼리 튜닝 실습 (코드로 한 번에)

13_tuning.sh 는 실습 1(쿼리 튜닝)의 1-1 ~ 1-9 를 한 번에 실행하고 결과를 기록한다. 손으로 따라 칠 때 비교할 기준 결과를 만드는 용도이다.

| 단계 | 하는 일 | 인덱스 |
|---|---|---|
| 1-1 | 상태 확인, VACUUM (ANALYZE) | 없음 |
| 1-2 | 튜닝 전 측정 (쿼리 7개) | 없음 |
| 1-3 | 단일 인덱스 시험 (customer_id) | BEGIN 안에서 만들고 ROLLBACK |
| 1-4 | 복합 인덱스 컬럼 순서 비교 | 틀린 순서는 ROLLBACK, idx_orders_customer_date 남김 |
| 1-5 | 부분 인덱스와 전체 인덱스 크기 비교 | 전체는 ROLLBACK, idx_orders_urgent_date 남김 |
| 1-6 | 기간 인덱스, 함수를 씌우면 못 쓰는 경우, 넓은 범위는 Seq Scan | idx_orders_order_date 남김 |
| 1-7 | JOIN 계획 (Nested Loop, Hash Join, Hash Join 을 껐을 때) | idx_customers_email 남김 |
| 1-8 | 튜닝 전후 결과 같음 증명 (행 수, md5) | 없음 |
| 1-9 | 튜닝 전후 비교표, 인덱스 크기와 사용 횟수, DB 크기 | 없음 |

- 시간은 쿼리마다 5번 실행한 중앙값이다. 부하 테스트가 아니다.
- DROP 과 데이터 변경을 하지 않는다. 시험 인덱스는 ROLLBACK 으로 없앤다.
- 기본키 말고 다른 인덱스가 이미 있으면 지우지 않고 멈춘다. 처음부터 다시 하려면 full 스냅샷으로 세 VM 을 같이 되돌리고 resume 한 뒤 실행한다.
- Leader 에서 실행하면 실습 전체를, Replica 에서 실행하면 인덱스가 복제되어 왔는지와 Replica 에서도 인덱스를 쓰는지만 확인한다.
- 결과는 VM 안 ~/lab-results/ 에 쌓이고, 가장 최근 기록은 ~/lab-results/13_tuning_latest.log 이다.

처음부터 설치했다면 2단계의 00_copy 때 13_tuning.sh 도 같이 복사된다. 이미 만든 VM 에는 아래처럼 파일 하나만 올린다.

[PowerShell]
```powershell
vagrant upload scripts\13_tuning.sh /home/vagrant/lab-scripts/13_tuning.sh data-db1
```
이 명령은 13_tuning.sh 를 data-db1 에 복사한다. data-db2 에도 같은 명령을 VM 이름만 바꿔 실행한다.

```powershell
vagrant ssh data-db1 -c "sudo patronictl -c /etc/patroni/patroni.yml list"
```
이 명령은 Leader 가 어느 쪽인지 확인한다. 아래 실행은 Leader 에서 먼저 한다. Leader 가 data-db2 이면 아래 두 명령의 VM 이름을 서로 바꾼다.

[PowerShell]
```powershell
vagrant ssh data-db1 -c "sudo bash ~/lab-scripts/13_tuning.sh"
```
이 명령은 Leader(data-db1) 에서 실습 1 전체를 실행한다. 마지막에 `[13] 완료` 가 나오면 성공이다.

```powershell
vagrant ssh data-db2 -c "sudo bash ~/lab-scripts/13_tuning.sh"
```
이 명령은 Replica(data-db2) 에서 읽기 전용 확인을 한다.

결과 기록을 호스트로 가져오기

```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
```
이 명령은 지금 PowerShell 창이 VM 출력의 한글을 깨지지 않게 읽도록 한다.

```powershell
vagrant ssh data-db1 -c "cat ~/lab-results/13_tuning_latest.log" | Out-File -Encoding utf8 D:\data-lab-docs\logs\13_tuning_data-db1.log
```
이 명령은 data-db1 의 최근 기록을 D:\data-lab-docs\logs 에 저장한다. data-db2 도 VM 이름과 파일 이름만 바꿔 실행한다.

## 14 ~ 22단계. 실습 2 ~ 10 을 코드로 한 번에 (run_all_labs.ps1)

[PowerShell]
```powershell
powershell -ExecutionPolicy Bypass -File D:\data-lab\run_all_labs.ps1
```
이 명령은 실습 2 ~ 10 을 순서대로 실행하고 D:\data-lab-docs\logs\labs_<시각>\ 에 실습별 로그와 summary.md 를 남긴다. 시작할 때 한 번만 yes 를 묻는다. 약 70 ~ 90분 걸린다.

- `-Yes` : 시작 확인을 건너뛴다.
- `-From 6` : 실습 6 부터 한다 (쓸 수 있는 값 2, 3, 4, 6, 7, 8, 9).

| 실습 | 시작 상태 | 하는 일 |
|---|---|---|
| 2 백업과 복구 | 지금 상태 (비정상이면 full) | pg_dump, pg_restore 비교, pgBackRest diff/incr, 별도 경로 복구와 임시 인스턴스 |
| 3 수동 페일오버 | baseline (data-db1, data-db2) | 복제 끊김, Primary kill -9, pg_promote, pg_rewind, 사라진 행 확인 |
| 4 자동 페일오버 기본 | full | patronictl, REST, PgBouncer 경로, switchover 왕복 |
| 5 운영 | 실습 4 그대로 | 잠금 대기, lock_timeout, 세션 끊기, 교착 상태, VACUUM, 점검 SQL, Prometheus |
| 6 Primary 강제 종료 | full | vagrant halt -f data-db1, 자동 전환, 쓰기 중단 시간, 다시 붙기 |
| 7 망 분리 | full | data-db1 Host-Only 망 차단 90초, 강등과 승격 시각, 다시 붙기 |
| 8 etcd 정족수 | full | etcd 1대 중지(유지), 2대 중지(Leader 강등), 회복 |
| 9 백업 실패와 경보 | full | MinIO 중지, 백업과 아카이브 실패, 경보 firing, 복구와 경보 해제 |
| 10 PITR | 실습 9 그대로 | full 백업, 표 DROP, 시점 복구로 별도 경로 확인 |
| 끝 | | 세 VM 을 full 로 되돌려 깨끗한 상태로 둔다 |

스냅샷을 되돌릴 때 지키는 것 (스크립트가 자동으로 한다)
- full 은 세 VM 을 모두 끈 뒤(vagrant halt -f) 되돌린다. 한 대씩 켜진 채 되돌리면 살아 있는 etcd 의 새 기록이 되돌린 VM 으로 다시 들어와 etcd 와 PostgreSQL 상태가 어긋난다.
- 실행 중에 찍은 스냅샷이라 되돌리면 시계가 스냅샷 시각에 머문다. 되돌린 뒤 호스트 시각으로 맞춘다 (lab_ctl.sh timesync).
- full 은 pause 상태로 찍었으므로 되돌린 뒤 resume 하고 Leader + Replica streaming 을 확인한다 (lab_ctl.sh full-ready).
- 스크립트 폴더는 되돌릴 때마다 다시 올린다 (스냅샷 안의 lab-scripts 에는 새 스크립트가 없다).

실습 3 의 pg_rewind 에는 복제 비밀번호가 필요하다. baseline 에는 /etc/lab-secrets 가 없으므로, 실행 파일이 D:\data-lab\.secrets\repl_pw 를 data-db1 에 올리고 VM 안에서 postgres 의 .pgpass(600) 로 옮긴 뒤 바로 지운다. 내용은 출력하지 않는다.

## 서비스 켜고 끄는 순서 (PowerShell)

끌 때는 Replica, Leader, 관리 서버 순서로 끈다. 관리 서버(etcd 3번)를 마지막에 꺼야 DB 노드가 내려가는 동안 etcd 정족수가 유지된다.

```powershell
vagrant halt data-db2
```
이 명령은 Replica(data-db2)를 먼저 끈다.

```powershell
vagrant halt data-db1
```
이 명령은 Leader(data-db1)를 끈다. Replica 가 이미 꺼져 있어 자동 전환이 일어나지 않는다.

```powershell
vagrant halt data-mgmt
```
이 명령은 관리 서버를 마지막에 끈다.

켤 때는 반대로 관리 서버, data-db1, data-db2 순서로 켠다. etcd 는 3대 중 2대가 켜져야 정족수가 생긴다.

```powershell
vagrant up data-mgmt
```
이 명령은 etcd 3번, MinIO, 모니터링을 먼저 켠다.

```powershell
vagrant up data-db1
```
이 명령은 data-db1 을 켠다. etcd 정족수(2대)가 생기고 Patroni 가 PostgreSQL 을 띄운다.

```powershell
vagrant up data-db2
```
이 명령은 data-db2 를 켠다. Replica 로 붙는다.

## 스냅샷 두 개의 차이와 되돌리는 법

| 스냅샷 | 있는 VM | 상태 | 쓰임 |
|---|---|---|---|
| baseline | data-db1, data-db2 | 수동 스트리밍 복제 (Patroni, etcd 없음). wal_log_hints=on, TL 1 | pg_promote, pg_rewind 를 손으로 연습 |
| full | data-db1, data-db2, data-mgmt | Patroni + etcd 3대 + PgBouncer + pgBackRest(full 백업 1개) + 모니터링. TL 4. 튜닝 인덱스 없음 (기본키만) | Patroni 장애 훈련, 백업 복구, 모니터링, 튜닝 처음부터 다시 |

주의 사항
- full 은 `patronictl pause` 상태에서 찍었다. softdog 가 스냅샷 중 VM 을 재부팅하지 않게 하려는 것이다. 되돌린 뒤에는 반드시 `resume` 한다.
- full 은 세 VM 을 모두 같이 되돌려야 etcd, Patroni, 복제가 맞는다.
- baseline 은 data-db1, data-db2 두 대를 같이 되돌린다. 이때 data-mgmt 는 꺼 두거나 그대로 둬도 된다 (baseline 에는 Patroni 가 없다).
- baseline 으로 되돌린 뒤 다시 full 로 가려면 세 VM 을 full 로 되돌린다.
- VM 을 일시정지하거나 저장 상태로 25초 넘게 멈추면 softdog 가 VM 을 재부팅할 수 있다. 스냅샷 전에는 pause 한다.

full 로 되돌리기 (PowerShell)

```powershell
vagrant snapshot restore data-mgmt full
```
이 명령은 data-mgmt 를 full 시점으로 되돌린다.

```powershell
vagrant snapshot restore data-db1 full
```
이 명령은 data-db1 을 full 시점으로 되돌린다.

```powershell
vagrant snapshot restore data-db2 full
```
이 명령은 data-db2 를 full 시점으로 되돌린다.

```powershell
vagrant ssh data-db1
```
이 명령은 data-db1 에 접속한다.

[VM 안]
```bash
sudo patronictl -c /etc/patroni/patroni.yml resume lab
```
이 명령은 Patroni 유지보수 모드를 끝내고 자동 전환과 watchdog 을 다시 켠다.

baseline 으로 되돌리기 (PowerShell)

```powershell
vagrant snapshot restore data-db1 baseline
```
이 명령은 data-db1 을 수동 복제 시점으로 되돌린다.

```powershell
vagrant snapshot restore data-db2 baseline
```
이 명령은 data-db2 를 수동 복제 시점으로 되돌린다.
