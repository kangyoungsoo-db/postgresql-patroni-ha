#!/usr/bin/env bash
# 12_monitoring.sh : Prometheus, Grafana (data-mgmt, root 로 실행)
#   Prometheus 9090 : node(9100), postgres(9187) 수집, 경보 규칙 "마지막 성공 백업이 26시간보다 오래됨"
#   Grafana 3000    : Prometheus 데이터 소스, PostgreSQL 기본 대시보드(grafana.com 9628) 하나
#   Grafana 관리자 비밀번호는 /etc/grafana/admin_pw 파일에서 읽게 한다 (설정 파일에 평문을 쓰지 않음)
set -euo pipefail
set +x
cd /

PROM_VER="3.5.5"
STAMP=$(date +%Y%m%d%H%M%S)

echo "[12] Prometheus ${PROM_VER} 설치"
if [ ! -x /usr/local/bin/prometheus ]; then
  TMP=$(mktemp -d)
  F="prometheus-${PROM_VER}.linux-amd64.tar.gz"
  B="https://github.com/prometheus/prometheus/releases/download/v${PROM_VER}"
  curl -fsSL -o "${TMP}/${F}" "${B}/${F}"
  curl -fsSL -o "${TMP}/sha256sums.txt" "${B}/sha256sums.txt"
  ( cd "$TMP" && grep " ${F}\$" sha256sums.txt | sha256sum -c - >/dev/null )
  tar -xzf "${TMP}/${F}" -C "$TMP"
  install -m 755 "${TMP}/${F%.tar.gz}/prometheus" /usr/local/bin/prometheus
  install -m 755 "${TMP}/${F%.tar.gz}/promtool"   /usr/local/bin/promtool
  rm -rf "$TMP"
  echo "  SHA256 확인 후 설치"
fi
id prometheus >/dev/null 2>&1 || useradd -r -s /sbin/nologin prometheus
install -d -m 755 /etc/prometheus /etc/prometheus/rules
install -d -m 750 -o prometheus -g prometheus /data/prometheus

[ -e /etc/prometheus/prometheus.yml ] && cp -p /etc/prometheus/prometheus.yml "/etc/prometheus/prometheus.yml.bak.${STAMP}"
cat > /etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 30s

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']
  - job_name: node
    static_configs:
      - targets: ['192.168.56.11:9100', '192.168.56.12:9100']
  - job_name: postgres
    static_configs:
      - targets: ['192.168.56.11:9187', '192.168.56.12:9187']
EOF

cat > /etc/prometheus/rules/backup.yml <<'EOF'
groups:
  - name: backup
    rules:
      - alert: PgBackRestBackupTooOld
        # 마지막 성공 백업이 26시간(93600초)보다 오래되었거나, 백업 지표 자체가 없을 때
        expr: (time() - max(lab_backup_last_success_timestamp_seconds)) > 93600 or absent(lab_backup_last_success_timestamp_seconds)
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "마지막 성공 백업이 26시간보다 오래됨"
          description: "pgBackRest 마지막 성공 백업 이후 {{ $value | humanizeDuration }} 지났다."
EOF
/usr/local/bin/promtool check config /etc/prometheus/prometheus.yml

cat > /etc/systemd/system/prometheus.service <<'EOF'
[Unit]
Description=Prometheus
After=network-online.target

[Service]
User=prometheus
ExecStart=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/data/prometheus --storage.tsdb.retention.time=15d --web.listen-address=:9090 --web.enable-lifecycle
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

echo "[12] Grafana 설치 (rpm.grafana.com)"
cat > /etc/yum.repos.d/grafana.repo <<'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF
dnf install -y -q grafana
rpm -q grafana

echo "[12] Grafana 관리자 비밀번호 파일 연결 (첫 기동 전에)"
install -m 640 -o root -g grafana /etc/lab-secrets/grafana_admin_pw /etc/grafana/admin_pw
SYSCONF=/etc/sysconfig/grafana-server
[ -e "$SYSCONF" ] && cp -p "$SYSCONF" "${SYSCONF}.bak.${STAMP}"
grep -q '^GF_SECURITY_ADMIN_PASSWORD__FILE=' "$SYSCONF" 2>/dev/null || echo 'GF_SECURITY_ADMIN_PASSWORD__FILE=/etc/grafana/admin_pw' >> "$SYSCONF"

install -d -m 755 /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards
install -d -m 755 -o grafana -g grafana /var/lib/grafana/dashboards
cat > /etc/grafana/provisioning/datasources/lab.yml <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
EOF
cat > /etc/grafana/provisioning/dashboards/lab.yml <<'EOF'
apiVersion: 1
providers:
  - name: lab
    folder: data-lab
    type: file
    options:
      path: /var/lib/grafana/dashboards
EOF
echo "[12] PostgreSQL 대시보드 (grafana.com 9628) 내려받기"
curl -fsSL "https://grafana.com/api/dashboards/9628/revisions/latest/download" \
  | sed 's/\${DS_PROMETHEUS}/prometheus/g' > /var/lib/grafana/dashboards/postgresql.json
chown grafana:grafana /var/lib/grafana/dashboards/postgresql.json
python3 -c 'import json; d=json.load(open("/var/lib/grafana/dashboards/postgresql.json")); print("  대시보드:", d.get("title"))'

firewall-cmd --permanent --add-port=9090/tcp --add-port=3000/tcp >/dev/null
firewall-cmd --reload >/dev/null
# Rocky 기본 cockpit 이 9090 을 쓰므로 끈다 (방화벽에서는 01 에서 이미 막았다)
if systemctl is-enabled cockpit.socket >/dev/null 2>&1; then
  systemctl disable --now cockpit.socket >/dev/null 2>&1
  systemctl stop cockpit.service >/dev/null 2>&1 || true
  echo "  cockpit.socket 을 끄고 9090 을 Prometheus 에 넘긴다"
fi
systemctl daemon-reload
systemctl reset-failed prometheus >/dev/null 2>&1 || true
systemctl enable --now prometheus grafana-server >/dev/null 2>&1
systemctl restart prometheus grafana-server

echo "[12] 기동 대기"
for i in $(seq 1 30); do
  curl -sf localhost:9090/-/ready >/dev/null && curl -sf localhost:3000/api/health >/dev/null && break
  sleep 2
done

# 환경변수 방식이 적용되지 않는 경우가 있어, 파일을 stdin 으로 넣어 관리자 비밀번호를 확정한다 (명령 인자에 남지 않음)
sudo -u grafana /usr/share/grafana/bin/grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini \
  --configOverrides "cfg:default.paths.data=/var/lib/grafana cfg:default.paths.logs=/var/log/grafana" \
  admin reset-admin-password --password-from-stdin < /etc/grafana/admin_pw >/dev/null
echo "  Grafana 관리자 비밀번호를 /etc/grafana/admin_pw 기준으로 맞췄다"

echo "[12] 결과"
systemctl is-active prometheus grafana-server
curl -s localhost:3000/api/health | tr -d '\n'; echo
echo "[12] 완료"
