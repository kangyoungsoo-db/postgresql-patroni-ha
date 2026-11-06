#!/usr/bin/env bash
# 03_replication.sh : 스트리밍 복제 구성 (VM 안에서 root 로 직접 실행)
#   data-db1 에서 실행 : 복제 사용자 replicator 생성, pg_hba 에 복제 허용 추가
#   data-db2 에서 실행 : pg_basebackup 으로 Standby 생성, 복제 슬롯 data_db2 사용
# 비밀번호는 read -rsp 로 입력받는다. 화면, 로그, 명령 인자에 남기지 않는다.
# Standby 의 비밀번호는 postgres 계정의 ~/.pgpass (권한 600) 에만 저장된다.
# 실행 순서: data-db1 에서 먼저, 그다음 data-db2 에서.
set -euo pipefail
set +x   # 비밀번호가 출력되지 않도록 명령 추적을 끈다

PRIMARY_HOST="data-db1"
STANDBY_HOST="data-db2"
PGDATA="/data/pgsql/17/data"
PGBIN="/usr/pgsql-17/bin"
REPL_USER="replicator"
SLOT="data_db2"
STAMP=$(date +%Y%m%d%H%M%S)
HOST=$(hostname -s)

if [ "$(id -u)" -ne 0 ]; then
  echo "[중단] root 로 실행한다: sudo bash $0"
  exit 1
fi

PW_FILE="/root/repl_pw"

ask_password() {
  local p1 p2
  # 비밀번호 파일이 있으면 읽고 바로 지운다 (무인 실행용). 없으면 직접 입력받는다.
  if [ -f "$PW_FILE" ]; then
    IFS= read -r p1 < "$PW_FILE" || true
    p1=${p1%$'\r'}
    rm -f "$PW_FILE"
    if [ -z "$p1" ]; then
      echo "[중단] ${PW_FILE} 가 비어 있다."
      exit 1
    fi
    echo "  비밀번호를 ${PW_FILE} 에서 읽고 파일을 지웠다."
    REPL_PW="$p1"
    return 0
  fi
  read -rsp "복제 사용자 ${REPL_USER} 비밀번호: " p1; echo
  read -rsp "한 번 더 입력: " p2; echo
  if [ -z "$p1" ] || [ "$p1" != "$p2" ]; then
    echo "[중단] 비밀번호가 비었거나 서로 다르다."
    exit 1
  fi
  REPL_PW="$p1"
}

# postgres 계정으로 psql 을 실행한다 (sudo -u postgres psql).
# PGLAB_REPL_PW 하나만 --preserve-env 로 넘긴다. 비밀번호가 명령 인자에 나오지 않게 하기 위함이다.
psql_pg() { sudo --preserve-env=PGLAB_REPL_PW -u postgres "${PGBIN}/psql" -X -v ON_ERROR_STOP=1 "$@"; }

# root 홈(/root)은 postgres 가 읽을 수 없어서 경고가 나오므로 / 에서 실행한다
cd /

# ---------------- Primary ----------------
if [ "$HOST" = "$PRIMARY_HOST" ]; then
  echo "[03] $HOST : Primary 구성"
  if [ "$(psql_pg -tAc 'SELECT pg_is_in_recovery()')" != "f" ]; then
    echo "[중단] 이 서버가 Primary 상태가 아니다."
    exit 1
  fi

  if [ "$(psql_pg -tAc "SELECT 1 FROM pg_roles WHERE rolname='${REPL_USER}'")" = "1" ]; then
    echo "  ${REPL_USER} 는 이미 있다. 비밀번호는 바꾸지 않는다."
  else
    ask_password
    # 비밀번호는 환경변수로만 넘기고 psql 의 \getenv 로 읽는다 (명령 인자와 화면에 나오지 않음)
    export PGLAB_REPL_PW="$REPL_PW"
    psql_pg -q <<EOF
\getenv repl_pw PGLAB_REPL_PW
CREATE ROLE ${REPL_USER} WITH REPLICATION LOGIN PASSWORD :'repl_pw';
EOF
    unset PGLAB_REPL_PW REPL_PW
    echo "  ${REPL_USER} 생성 완료"
  fi

  HBA="${PGDATA}/pg_hba.conf"
  if ! grep -q "data-lab replication" "$HBA"; then
    cp -p "$HBA" "${HBA}.bak.${STAMP}"          # 바꾸기 전에 백업
    cat >> "$HBA" <<EOF
# data-lab replication (장애 전환 연습을 위해 두 노드 모두 허용)
host    replication     ${REPL_USER}      192.168.56.11/32        scram-sha-256
host    replication     ${REPL_USER}      192.168.56.12/32        scram-sha-256
EOF
    psql_pg -qc "SELECT pg_reload_conf();" >/dev/null
  fi

  echo "[03] 결과"
  psql_pg -c "SELECT rolname, rolreplication, rolcanlogin FROM pg_roles WHERE rolname='${REPL_USER}';"
  psql_pg -c "SELECT line_number, type, database, user_name, address, auth_method FROM pg_hba_file_rules WHERE database::text LIKE '%replication%';"
  echo "[03] Primary 완료. 이제 ${STANDBY_HOST} 에서 이 스크립트를 실행한다."
  exit 0
fi

# ---------------- Standby ----------------
if [ "$HOST" = "$STANDBY_HOST" ]; then
  echo "[03] $HOST : Standby 구성"
  if [ -e "${PGDATA}/PG_VERSION" ]; then
    echo "[중단] ${PGDATA} 에 이미 데이터가 있다. 지우지 않고 멈춘다."
    exit 1
  fi
  if systemctl is-active --quiet postgresql-17; then
    echo "[중단] postgresql-17 이 실행 중이다."
    exit 1
  fi

  ask_password
  # .pgpass 형식에서 \ 와 : 는 이스케이프해야 한다
  PW_ESC=${REPL_PW//\\/\\\\}
  PW_ESC=${PW_ESC//:/\\:}
  PGPASS=/var/lib/pgsql/.pgpass
  if [ -e "$PGPASS" ]; then
    cp -p "$PGPASS" "${PGPASS}.bak.${STAMP}"    # 바꾸기 전에 백업
  fi
  ( umask 077; printf '%s\n' "*:5432:replication:${REPL_USER}:${PW_ESC}" > "$PGPASS" )
  chown postgres:postgres "$PGPASS"
  chmod 600 "$PGPASS"
  unset REPL_PW PW_ESC

  echo "[03] pg_basebackup 시작 (Primary 에서 전체 복사)"
  START=$(date +%s)
  sudo -u postgres "${PGBIN}/pg_basebackup" \
    -h "$PRIMARY_HOST" -p 5432 -U "$REPL_USER" -w \
    -D "$PGDATA" -X stream -C -S "$SLOT" -P
  echo "  pg_basebackup 소요: $(( $(date +%s) - START ))초"

  # -R 을 쓰지 않는다. -R 은 접속 문자열에 비밀번호를 같이 적을 수 있기 때문이다.
  # 비밀번호 없이 접속 정보만 쓰고, 비밀번호는 ~/.pgpass 에서 읽게 한다.
  cat >> "${PGDATA}/postgresql.auto.conf" <<EOF
primary_conninfo = 'host=${PRIMARY_HOST} port=5432 user=${REPL_USER} application_name=${HOST}'
primary_slot_name = '${SLOT}'
EOF
  sudo -u postgres touch "${PGDATA}/standby.signal"
  restorecon -R /data/pgsql

  systemctl enable --now postgresql-17
  sleep 3

  echo "[03] 결과"
  psql_pg -c "SELECT pg_is_in_recovery();"
  psql_pg -c "SELECT status, sender_host, slot_name FROM pg_stat_wal_receiver;"
  echo "[03] Standby 완료. data-db1 에서 pg_stat_replication 을 확인한다."
  exit 0
fi

echo "[중단] 알 수 없는 호스트: $HOST"
exit 1
