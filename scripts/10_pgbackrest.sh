#!/usr/bin/env bash
# 10_pgbackrest.sh : pgBackRest (data-db1, data-db2 각각, root 로 실행)
#   저장소는 data-mgmt 의 MinIO (S3 방식, 버킷 pgbackrest, 경로 /lab)
#   실습용이라 자체 서명 인증서를 검증하지 않는다 (repo1-storage-verify-tls=n). 운영에서는 쓰면 안 된다.
#   Leader 에서만 stanza-create, check, full 백업, info 를 실행한다. Replica 는 설정만 한다.
set -euo pipefail
set +x
cd /

CONF=/etc/pgbackrest/pgbackrest.conf
STANZA=lab
STAMP=$(date +%Y%m%d%H%M%S)
PGBIN=/usr/pgsql-17/bin
pgbr() { sudo -u postgres pgbackrest --stanza="$STANZA" "$@"; }

echo "[10] pgBackRest 설치"
dnf install -y -q pgbackrest
pgbackrest version

install -d -m 770 -o postgres -g postgres /var/log/pgbackrest /var/spool/pgbackrest
install -d -m 750 -o postgres -g postgres /etc/pgbackrest

echo "[10] ${CONF} 작성 (postgres 600, 원본 백업)"
[ -e "$CONF" ] && cp -p "$CONF" "${CONF}.bak.${STAMP}"
[ -e /etc/pgbackrest.conf ] && mv /etc/pgbackrest.conf "/etc/pgbackrest.conf.bak.${STAMP}"   # 패키지 기본 파일이 우선 읽히지 않도록 옮긴다
(
  umask 077
  AK=$(< /etc/lab-secrets/minio_access_key)
  SK=$(< /etc/lab-secrets/minio_secret_key)
  cat > "$CONF" <<EOF
[global]
repo1-type=s3
repo1-path=/lab
repo1-s3-bucket=pgbackrest
repo1-s3-endpoint=192.168.56.13
repo1-storage-port=9000
repo1-s3-region=us-east-1
repo1-s3-uri-style=path
repo1-storage-verify-tls=n
repo1-s3-key=${AK}
repo1-s3-key-secret=${SK}
repo1-retention-full=2
compress-type=zst
process-max=2
start-fast=y
archive-async=n
log-level-console=info
log-level-file=detail

[${STANZA}]
pg1-path=/data/pgsql/17/data
pg1-port=5432
pg1-socket-path=/run/postgresql
EOF
)
chown postgres:postgres "$CONF"
chmod 600 "$CONF"

ROLE=$(sudo -u postgres "${PGBIN}/psql" -X -At -c 'SELECT CASE WHEN pg_is_in_recovery() THEN $$replica$$ ELSE $$leader$$ END')
echo "  이 노드 역할: ${ROLE}"
if [ "$ROLE" != "leader" ]; then
  echo "[10] Replica 는 설정만 한다."
  echo "[10] 완료"
  exit 0
fi

echo "[10] stanza-create"
pgbr stanza-create
echo "[10] check (WAL 아카이브 동작 확인)"
pgbr check
echo "[10] full 백업"
START=$(date +%s)
pgbr --type=full backup
echo "  full 백업 소요: $(( $(date +%s) - START ))초"

echo "[10] 결과"
pgbr info
sudo -u postgres "${PGBIN}/psql" -X -c "SELECT archived_count, last_archived_wal, last_archived_time, failed_count, last_failed_time FROM pg_stat_archiver;"
echo "[10] 완료"
