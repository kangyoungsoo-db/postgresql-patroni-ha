#!/usr/bin/env bash
# 11_exporters.sh : node_exporter, postgres_exporter, 백업 시각 textfile (data-db1, data-db2, root 로 실행)
#   node_exporter 9100 : --collector.textfile.directory 로 백업 지표를 읽는다
#   postgres_exporter 9187 : postgres 계정으로 unix socket 에 접속한다 (비밀번호 없음, peer)
#   lab-backup-metric.timer : 5분마다 pgbackrest info 를 읽어 마지막 성공 백업 시각을 기록한다
set -euo pipefail
cd /

NE_VER="1.12.1"
PE_VER="0.20.1"
TEXTDIR=/var/lib/node_exporter/textfile

fetch_tgz() {   # $1=저장소 $2=버전 $3=파일이름 $4=바이너리 이름
  local tmp; tmp=$(mktemp -d)
  local base="https://github.com/$1/releases/download/v$2"
  curl -fsSL -o "${tmp}/$3" "${base}/$3"
  curl -fsSL -o "${tmp}/sha256sums.txt" "${base}/sha256sums.txt"
  ( cd "$tmp" && grep " $3\$" sha256sums.txt | sha256sum -c - >/dev/null )
  tar -xzf "${tmp}/$3" -C "$tmp"
  install -m 755 "${tmp}/${3%.tar.gz}/$4" "/usr/local/bin/$4"
  rm -rf "$tmp"
  echo "  $4 $2 SHA256 확인 후 설치"
}

echo "[11] exporter 설치"
[ -x /usr/local/bin/node_exporter ]     || fetch_tgz prometheus/node_exporter "$NE_VER" "node_exporter-${NE_VER}.linux-amd64.tar.gz" node_exporter
[ -x /usr/local/bin/postgres_exporter ] || fetch_tgz prometheus-community/postgres_exporter "$PE_VER" "postgres_exporter-${PE_VER}.linux-amd64.tar.gz" postgres_exporter

id node_exporter >/dev/null 2>&1 || useradd -r -s /sbin/nologin node_exporter
install -d -m 775 -o postgres -g node_exporter "$TEXTDIR"

cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus node_exporter
After=network-online.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100 --collector.textfile.directory=${TEXTDIR}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/postgres_exporter.service <<'EOF'
[Unit]
Description=Prometheus postgres_exporter
After=network-online.target patroni.service

[Service]
User=postgres
Environment=DATA_SOURCE_NAME=postgresql://postgres@/postgres?host=/run/postgresql&sslmode=disable
ExecStart=/usr/local/bin/postgres_exporter --web.listen-address=:9187
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

echo "[11] 백업 시각 기록 스크립트와 타이머"
cat > /usr/local/bin/lab-backup-metric.sh <<'EOF'
#!/usr/bin/env bash
# pgbackrest info 를 읽어 마지막 성공 백업 시각을 node_exporter textfile 로 쓴다
OUT=/var/lib/node_exporter/textfile/pgbackrest.prom
TMP=$(mktemp "${OUT}.XXXX")
pgbackrest --stanza=lab --output=json info 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    backups = [b for s in data for b in s.get("backup", []) if not b.get("error", False)]
    ok = 1
except Exception:
    backups, ok = [], 0
print("# HELP lab_backup_info_ok pgbackrest info 를 읽었으면 1")
print("# TYPE lab_backup_info_ok gauge")
print("lab_backup_info_ok %d" % ok)
print("# HELP lab_backup_count 저장소에 있는 성공 백업 수")
print("# TYPE lab_backup_count gauge")
print("lab_backup_count %d" % len(backups))
if backups:
    last = max(backups, key=lambda b: b["timestamp"]["stop"])
    print("# HELP lab_backup_last_success_timestamp_seconds 마지막 성공 백업 종료 시각 (unix 초)")
    print("# TYPE lab_backup_last_success_timestamp_seconds gauge")
    print("lab_backup_last_success_timestamp_seconds{type=\"%s\"} %d" % (last["type"], last["timestamp"]["stop"]))
' > "$TMP"
chmod 644 "$TMP"
mv "$TMP" "$OUT"
EOF
chmod 755 /usr/local/bin/lab-backup-metric.sh

cat > /etc/systemd/system/lab-backup-metric.service <<'EOF'
[Unit]
Description=Write pgBackRest last backup time for node_exporter

[Service]
Type=oneshot
User=postgres
ExecStart=/usr/local/bin/lab-backup-metric.sh
EOF
cat > /etc/systemd/system/lab-backup-metric.timer <<'EOF'
[Unit]
Description=Run lab-backup-metric every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

firewall-cmd --permanent --add-port=9100/tcp --add-port=9187/tcp >/dev/null
firewall-cmd --reload >/dev/null
systemctl daemon-reload
systemctl enable --now node_exporter postgres_exporter lab-backup-metric.timer >/dev/null 2>&1
systemctl restart node_exporter postgres_exporter
systemctl start lab-backup-metric.service
sleep 3

echo "[11] 결과"
systemctl is-active node_exporter postgres_exporter lab-backup-metric.timer
curl -s localhost:9100/metrics | grep '^lab_backup' || echo "  lab_backup 지표 없음"
curl -s localhost:9187/metrics | grep '^pg_up'
echo "[11] 완료"
