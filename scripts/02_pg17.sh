#!/usr/bin/env bash
# 02_pg17.sh : PostgreSQL 17 설치와 기본 설정 (두 VM 공통, root 로 실행)
#   data-db1 : 설치 + initdb + 기본 설정 + 기동
#   data-db2 : 설치 + PGDATA 경로 설정까지만 (initdb 하지 않음, 03 에서 pg_basebackup 으로 만든다)
# 기본 설정은 ALTER SYSTEM 으로 postgresql.auto.conf 에만 쓴다 (postgresql.conf 는 건드리지 않음).
set -euo pipefail

PRIMARY_HOST="data-db1"
PGHOME="/data/pgsql"
PGDATA="/data/pgsql/17/data"
PGBIN="/usr/pgsql-17/bin"
REPO_RPM="https://download.postgresql.org/pub/repos/yum/reporpms/EL-10-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
STAMP=$(date +%Y%m%d%H%M%S)
HOST=$(hostname -s)

echo "[02] 사전 확인: /data 마운트와 SELinux 라벨"
if ! mountpoint -q /data; then
  echo "  [중단] /data 가 마운트되어 있지 않다. 01_base.sh 를 먼저 실행한다."
  exit 1
fi
if ! ls -Zd "$PGHOME" | grep -q postgresql_db_t; then
  echo "  [중단] $PGHOME 의 SELinux 라벨이 postgresql_db_t 가 아니다."
  ls -Zd "$PGHOME"
  exit 1
fi

echo "[02] PGDG 저장소 등록"
if ! rpm -q pgdg-redhat-repo >/dev/null 2>&1; then
  dnf install -y "$REPO_RPM"
fi
# EL10 에는 모듈 스트림이 없지만, 있으면 배포판 postgresql 모듈을 끈다
if dnf -q module list postgresql >/dev/null 2>&1; then
  dnf -qy module disable postgresql || true
fi

echo "[02] PostgreSQL 17 설치"
dnf install -y postgresql17-server postgresql17-contrib

echo "[02] PGDATA 경로를 $PGDATA 로 지정 (systemd drop-in)"
mkdir -p /etc/systemd/system/postgresql-17.service.d
cat > /etc/systemd/system/postgresql-17.service.d/override.conf <<EOF
[Service]
Environment=PGDATA=${PGDATA}
EOF
systemctl daemon-reload

mkdir -p "${PGHOME}/17"
chown -R postgres:postgres "$PGHOME"
restorecon -R "$PGHOME"

echo "[02] postgres 계정 환경변수 (PGDATA, PATH)"
PROFILE=/var/lib/pgsql/.bash_profile
if [ -f "$PROFILE" ] && ! grep -q "data-lab" "$PROFILE"; then
  cp -p "$PROFILE" "${PROFILE}.bak.${STAMP}"     # 바꾸기 전에 백업
  cat >> "$PROFILE" <<EOF
# data-lab
export PGDATA=${PGDATA}
export PATH=${PGBIN}:\$PATH
EOF
fi

if [ "$HOST" != "$PRIMARY_HOST" ]; then
  echo "[02] $HOST 는 Standby 이다. initdb 와 기동은 하지 않는다 (03 에서 처리)."
  echo "[02] 결과"
  rpm -q postgresql17-server
  ls -Zd "$PGHOME"
  echo "[02] 완료"
  exit 0
fi

echo "[02] initdb"
if [ -f "${PGDATA}/PG_VERSION" ]; then
  echo "  이미 초기화되어 있다. 건너뛴다."
else
  "${PGBIN}/postgresql-17-setup" initdb
fi
systemctl enable --now postgresql-17

echo "[02] 기본 설정 (shared_buffers 는 VM 메모리의 25%)"
# /proc/meminfo 의 MemTotal(kB) 을 MB 로 바꾸고 4 로 나눈다
MEM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
MEM_MB=$(( MEM_KB / 1024 ))
SB_MB=$(( MEM_MB / 4 ))
echo "  MemTotal ${MEM_KB} kB = ${MEM_MB} MB"
echo "  shared_buffers = ${MEM_MB} / 4 = ${SB_MB} MB"
# max_slot_wal_keep_size : 복제 슬롯 때문에 쌓이는 WAL 의 상한. 넘으면 슬롯을 무효화해서 /data 가 가득 차는 것을 막는다.
# postgresql.auto.conf 에 쓰므로 03 의 pg_basebackup 때 Standby 에도 같이 복사된다.
runuser -u postgres -- "${PGBIN}/psql" -X -v ON_ERROR_STOP=1 -q <<EOF
ALTER SYSTEM SET listen_addresses = '*';
ALTER SYSTEM SET max_connections = 100;
ALTER SYSTEM SET shared_buffers = '${SB_MB}MB';
ALTER SYSTEM SET max_slot_wal_keep_size = '10GB';
EOF
systemctl restart postgresql-17

echo "[02] 결과"
runuser -u postgres -- "${PGBIN}/psql" -X -c "SELECT version();"
runuser -u postgres -- "${PGBIN}/psql" -X -c "SELECT name, setting, unit FROM pg_settings WHERE name IN ('data_directory','port','listen_addresses','max_connections','shared_buffers','max_slot_wal_keep_size','work_mem') ORDER BY name;"
runuser -u postgres -- "${PGBIN}/psql" -X -c "SHOW shared_buffers;"
echo "  VM 메모리 ${MEM_MB} MB, shared_buffers ${SB_MB} MB, max_slot_wal_keep_size 10GB"
echo "[02] 완료"
