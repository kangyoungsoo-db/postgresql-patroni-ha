#!/usr/bin/env bash
# 08_pgbouncer.sh : PgBouncer (data-db1, data-db2 각각, root 로 실행)
#   6432 포트, 로컬 PostgreSQL(127.0.0.1:5432)로 연결한다
#   접속 확인용 사용자 lab_app 을 만든다 (Leader 에서만 만들고, Replica 에는 복제로 전달된다)
#   클라이언트는 host=data-db1,data-db2 port=6432 target_session_attrs=read-write 로 Primary 를 찾는다
set -euo pipefail
set +x
cd /

PGBIN=/usr/pgsql-17/bin
INI=/etc/pgbouncer/pgbouncer.ini
USERLIST=/etc/pgbouncer/userlist.txt
STAMP=$(date +%Y%m%d%H%M%S)
psql_pg() { sudo --preserve-env=PGLAB_PW -u postgres "${PGBIN}/psql" -X -At -v ON_ERROR_STOP=1 "$@"; }

echo "[08] PgBouncer 설치"
dnf install -y -q pgbouncer
pgbouncer --version | head -1

if [ "$(psql_pg -c 'SELECT pg_is_in_recovery()')" = "f" ]; then
  echo "[08] Leader: lab_app 사용자 준비"
  export PGLAB_PW="$(< /etc/lab-secrets/lab_app_pw)"
  psql_pg -q <<'SQL'
\getenv pw PGLAB_PW
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lab_app') AS need_create \gset
\if :need_create
  CREATE ROLE lab_app LOGIN PASSWORD :'pw';
\else
  ALTER ROLE lab_app PASSWORD :'pw';
\endif
GRANT CONNECT ON DATABASE lab_tuning TO lab_app;
\c lab_tuning
GRANT USAGE ON SCHEMA public TO lab_app;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO lab_app;
SQL
  unset PGLAB_PW
else
  echo "[08] Replica: lab_app 이 복제로 들어올 때까지 대기"
  for i in $(seq 1 12); do
    [ "$(psql_pg -c "SELECT count(*) FROM pg_roles WHERE rolname='lab_app'")" = "1" ] && break
    sleep 5
  done
fi

echo "[08] userlist.txt 작성 (SCRAM 해시만 저장, 평문 비밀번호 없음)"
(
  umask 077
  psql_pg -c "SELECT format('\"%s\" \"%s\"', rolname, rolpassword) FROM pg_authid WHERE rolname = 'lab_app'" > "${USERLIST}.new"
)
if [ ! -s "${USERLIST}.new" ]; then
  echo "[중단] lab_app 의 SCRAM 해시를 가져오지 못했다."
  exit 1
fi
[ -e "$USERLIST" ] && cp -p "$USERLIST" "${USERLIST}.bak.${STAMP}"
mv "${USERLIST}.new" "$USERLIST"
chown pgbouncer:pgbouncer "$USERLIST"
chmod 600 "$USERLIST"

echo "[08] pgbouncer.ini 작성 (원본 백업)"
[ -e "$INI" ] && cp -p "$INI" "${INI}.bak.${STAMP}"
cat > "$INI" <<'EOF'
[databases]
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = session
max_client_conn = 200
default_pool_size = 20
ignore_startup_parameters = extra_float_digits
logfile = /var/log/pgbouncer/pgbouncer.log
pidfile = /run/pgbouncer/pgbouncer.pid
EOF
chown pgbouncer:pgbouncer "$INI"
chmod 640 "$INI"

firewall-cmd --permanent --add-port=6432/tcp >/dev/null
firewall-cmd --reload >/dev/null
systemctl enable pgbouncer >/dev/null 2>&1
systemctl restart pgbouncer
sleep 2

echo "[08] 결과"
systemctl is-active pgbouncer
ss -ltn 'sport = :6432' | tail -n +2
echo "[08] 완료"
