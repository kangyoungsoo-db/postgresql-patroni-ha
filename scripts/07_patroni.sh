#!/usr/bin/env bash
# 07_patroni.sh : 기존 스트리밍 복제를 Patroni 관리로 넘긴다 (data-db1 먼저, 그다음 data-db2, root 로 실행)
#   - 데이터 디렉터리(/data/pgsql/17/data)는 그대로 쓴다. lab_tuning 데이터는 유지된다.
#   - watchdog: softdog 모듈, mode=required, device=/dev/watchdog 를 명시한다.
#     (하드웨어 watchdog(iTCO)이 /dev/watchdog 를 차지해 승격이 막히는 일을 피하려고 iTCO 는 막는다)
#   - postgresql-17 서비스는 끄고, 이후로는 patroni 서비스가 PostgreSQL 을 띄운다.
# 비밀번호는 /etc/lab-secrets 에서 읽고 화면에 출력하지 않는다.
set -euo pipefail
set +x

NAME=$(hostname -s)
IP=$(ip -4 -o addr show | awk '/192\.168\.56\./ {print $4}' | cut -d/ -f1 | head -1)
PGDATA=/data/pgsql/17/data
PGBIN=/usr/pgsql-17/bin
CONF=/etc/patroni/patroni.yml
STAMP=$(date +%Y%m%d%H%M%S)
PCTL="patronictl -c ${CONF}"
cd /

echo "[07] 사전 확인: etcd 클러스터"
/usr/local/bin/etcdctl --endpoints=http://127.0.0.1:2379 endpoint health --cluster

echo "[07] Patroni 설치"
dnf install -y -q patroni python3-pip python3-urllib3 python3-dns
if ! python3 -c 'import etcd' 2>/dev/null; then
  # EL10 저장소에 python3-etcd 가 없어서 PyPI 에서 설치한다 (의존성은 OS 패키지로 이미 설치)
  python3 -m pip install -q --no-deps python-etcd==0.4.5
fi
patroni --version

echo "[07] watchdog (softdog)"
echo softdog > /etc/modules-load.d/softdog.conf
cat > /etc/modprobe.d/lab-watchdog.conf <<'EOF'
# /dev/watchdog 를 softdog 가 차지하도록 하드웨어 watchdog 드라이버는 막는다
blacklist iTCO_wdt
blacklist iTCO_vendor_support
install iTCO_wdt /bin/false
install iTCO_vendor_support /bin/false
EOF
# VirtualBox ICH9 칩셋은 iTCO 를 흉내 내서 iTCO_wdt 가 먼저 /dev/watchdog 를 차지한다.
# 이미 올라와 있으면 내리고, softdog 를 다시 올려 /dev/watchdog (watchdog0) 를 차지하게 한다.
if lsmod | grep -E '^iTCO_(wdt|vendor_support) ' >/dev/null; then
  echo "  iTCO_wdt 가 올라와 있어 내린다"
  modprobe -r iTCO_wdt iTCO_vendor_support
  lsmod | grep '^softdog ' >/dev/null && modprobe -r softdog
fi
if lsinitrd 2>/dev/null | grep iTCO >/dev/null; then
  echo "  initramfs 에 iTCO 가 있어 다시 만든다"
  dracut -f
fi
cat > /etc/udev/rules.d/61-watchdog.rules <<'EOF'
KERNEL=="watchdog*", OWNER="postgres", GROUP="postgres", MODE="0600"
EOF
modprobe softdog
udevadm control --reload-rules
udevadm trigger --subsystem-match=watchdog --action=add
chown postgres:postgres /dev/watchdog /dev/watchdog0
WD_COUNT=$(ls -d /sys/class/watchdog/watchdog* | wc -l)
WD_ID=$(cat /sys/class/watchdog/watchdog0/identity)
echo "  watchdog 장치 수=${WD_COUNT}, watchdog0=${WD_ID}"
if [ "$WD_COUNT" -ne 1 ] || [ "$WD_ID" != "Software Watchdog" ]; then
  echo "[중단] /dev/watchdog 가 softdog 하나가 아니다."
  exit 1
fi
ls -l /dev/watchdog

# shared_buffers 는 메모리의 25% (02 와 같은 계산)
SB_MB=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024 / 4 ))

DCS=$(cat <<EOF
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 100
        shared_buffers: ${SB_MB}MB
        wal_level: replica
        wal_log_hints: 'on'
        hot_standby: 'on'
        max_wal_senders: 10
        max_replication_slots: 10
        max_slot_wal_keep_size: 10GB
        archive_mode: 'on'
        archive_command: 'pgbackrest --stanza=lab archive-push %p'
EOF
)

echo "[07] ${CONF} 작성"
install -d -m 750 -o postgres -g postgres /etc/patroni
[ -e "$CONF" ] && cp -p "$CONF" "${CONF}.bak.${STAMP}"
(
  umask 077
  REPL_PW=$(< /etc/lab-secrets/repl_pw)
  PG_PW=$(< /etc/lab-secrets/postgres_pw)
  cat > "$CONF" <<EOF
scope: lab
namespace: /service/
name: ${NAME}

restapi:
  listen: ${IP}:8008
  connect_address: ${IP}:8008

etcd3:
  hosts: 192.168.56.11:2379,192.168.56.12:2379,192.168.56.13:2379

bootstrap:
  dcs:
${DCS}

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${IP}:5432
  data_dir: ${PGDATA}
  bin_dir: ${PGBIN}
  pgpass: /var/lib/pgsql/.pgpass_patroni
  authentication:
    superuser:
      username: postgres
      password: '${PG_PW}'
    replication:
      username: replicator
      password: '${REPL_PW}'
  parameters:
    unix_socket_directories: /run/postgresql
  pg_hba:
    - local   all          all                           peer
    - host    all          all         127.0.0.1/32      scram-sha-256
    - host    all          all         ::1/128           scram-sha-256
    - host    replication  replicator  192.168.56.11/32  scram-sha-256
    - host    replication  replicator  192.168.56.12/32  scram-sha-256
    - host    all          all         192.168.56.0/24   scram-sha-256

watchdog:
  mode: required
  device: /dev/watchdog
  safety_margin: 5

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF
)
chown postgres:postgres "$CONF"
chmod 600 "$CONF"

echo "[07] patroni 서비스 설정 (drop-in)"
mkdir -p /etc/systemd/system/patroni.service.d
cat > /etc/systemd/system/patroni.service.d/lab.conf <<EOF
[Service]
User=postgres
Group=postgres
ExecStart=
ExecStart=/usr/bin/patroni ${CONF}
KillMode=process
EOF
systemctl daemon-reload

firewall-cmd --permanent --add-port=8008/tcp >/dev/null
firewall-cmd --reload >/dev/null

psql_pg() { sudo --preserve-env=PGLAB_PW -u postgres "${PGBIN}/psql" -X -At -v ON_ERROR_STOP=1 "$@"; }

if systemctl is-active --quiet patroni; then
  echo "[07] patroni 가 이미 실행 중이다. 전환 단계는 건너뛴다."
else
  if ! systemctl is-active --quiet postgresql-17; then
    echo "[중단] postgresql-17 이 실행 중이 아니다. 전환 전 상태가 아니다."
    exit 1
  fi
  IN_RECOVERY=$(psql_pg -c 'SELECT pg_is_in_recovery()')

  if [ "$IN_RECOVERY" = "f" ]; then
    echo "[07] Primary: postgres 비밀번호 설정 (Patroni superuser, pg_rewind 용)"
    export PGLAB_PW="$(< /etc/lab-secrets/postgres_pw)"
    psql_pg -q <<'SQL'
\getenv pw PGLAB_PW
ALTER ROLE postgres PASSWORD :'pw';
SQL
    unset PGLAB_PW
  fi

  echo "[07] 설정 파일 백업: ${PGDATA}/../conf-backup-${STAMP}"
  BK="/data/pgsql/17/conf-backup-${STAMP}"
  install -d -m 700 -o postgres -g postgres "$BK"
  cp -p "${PGDATA}/postgresql.conf" "${PGDATA}/pg_hba.conf" "${PGDATA}/postgresql.auto.conf" "$BK/"

  echo "[07] ALTER SYSTEM 값 초기화 (이제 Patroni 설정으로 관리)"
  psql_pg -q -c 'ALTER SYSTEM RESET ALL'

  echo "[07] postgresql-17 서비스 중지와 비활성화, patroni 시작"
  systemctl stop postgresql-17
  systemctl disable postgresql-17 >/dev/null 2>&1
  systemctl enable --now patroni
fi

echo "[07] Patroni 상태 대기 (최대 180초)"
for i in $(seq 1 36); do
  STATE=$($PCTL list -f json 2>/dev/null | python3 -c "
import json,sys
for m in json.load(sys.stdin):
    if m['Member']=='${NAME}': print(m['Role'], m['State'])
" || true)
  case "$STATE" in
    "Leader running"|"Replica streaming"|"Sync Standby streaming") break ;;
  esac
  sleep 5
done
echo "  ${NAME}: ${STATE:-알 수 없음}"

# 기존 클러스터를 넘겨받으면 bootstrap.dcs 가 DCS 에 안 들어갈 수 있으므로 확인하고 없으면 넣는다
if [ "${STATE%% *}" = "Leader" ] && ! $PCTL show-config 2>/dev/null | grep -q 'archive_command'; then
  echo "[07] DCS 설정이 비어 있어 bootstrap.dcs 내용을 적용한다"
  printf '%s\n' "$DCS" | sed 's/^    //' > /tmp/lab-dcs.yml
  $PCTL edit-config --apply /tmp/lab-dcs.yml --force >/dev/null
  rm -f /tmp/lab-dcs.yml
  sleep 12
fi

# 재시작이 필요한 설정(archive_mode, shared_buffers 등)이 남아 있으면 이 노드만 재시작한다
if $PCTL list -f json | python3 -c "
import json,sys
sys.exit(0 if any(m['Member']=='${NAME}' and m.get('Pending restart') for m in json.load(sys.stdin)) else 1)"; then
  echo "[07] Pending restart 가 있어 ${NAME} 를 재시작한다"
  $PCTL restart lab "$NAME" --pending --force
  sleep 10
fi

echo "[07] 결과"
$PCTL list
$PCTL show-config | grep -E 'wal_log_hints|archive_mode|shared_buffers|max_slot_wal_keep_size|use_pg_rewind'
journalctl -u patroni --no-pager | grep -i watchdog | tail -3 || true
echo "[07] 완료"
