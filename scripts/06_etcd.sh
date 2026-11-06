#!/usr/bin/env bash
# 06_etcd.sh : etcd 3대 클러스터 (data-db1, data-db2, data-mgmt 공통, root 로 실행)
#   GitHub 릴리스 바이너리를 SHA256 으로 검증한 뒤 /usr/local/bin 에 설치한다
#   실습용이라 TLS 와 인증은 쓰지 않는다 (Host-Only 망 안에서만 사용)
set -euo pipefail

ETCD_VER="v3.6.16"
URL="https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}"
TGZ="etcd-${ETCD_VER}-linux-amd64.tar.gz"
NAME=$(hostname -s)
IP=$(ip -4 -o addr show | awk '/192\.168\.56\./ {print $4}' | cut -d/ -f1 | head -1)
CLUSTER="data-db1=http://192.168.56.11:2380,data-db2=http://192.168.56.12:2380,data-mgmt=http://192.168.56.13:2380"

echo "[06] etcd ${ETCD_VER} 설치 (${NAME}, ${IP})"
if [ ! -x /usr/local/bin/etcd ] || ! /usr/local/bin/etcd --version | grep -q "${ETCD_VER#v}"; then
  TMP=$(mktemp -d)
  curl -fsSL -o "${TMP}/${TGZ}" "${URL}/${TGZ}"
  curl -fsSL -o "${TMP}/SHA256SUMS" "${URL}/SHA256SUMS"
  ( cd "$TMP" && grep " ${TGZ}\$" SHA256SUMS | sha256sum -c - )
  tar -xzf "${TMP}/${TGZ}" -C "$TMP"
  install -m 755 "${TMP}/etcd-${ETCD_VER}-linux-amd64/etcd"    /usr/local/bin/etcd
  install -m 755 "${TMP}/etcd-${ETCD_VER}-linux-amd64/etcdctl" /usr/local/bin/etcdctl
  install -m 755 "${TMP}/etcd-${ETCD_VER}-linux-amd64/etcdutl" /usr/local/bin/etcdutl
  rm -rf "$TMP"
fi

id etcd >/dev/null 2>&1 || useradd -r -s /sbin/nologin -d /var/lib/etcd etcd
install -d -m 700 -o etcd -g etcd /var/lib/etcd
install -d -m 755 /etc/etcd

if [ -e /etc/etcd/etcd.conf.yml ]; then
  cp -p /etc/etcd/etcd.conf.yml "/etc/etcd/etcd.conf.yml.bak.$(date +%Y%m%d%H%M%S)"
fi
cat > /etc/etcd/etcd.conf.yml <<EOF
name: ${NAME}
data-dir: /var/lib/etcd
listen-peer-urls: http://${IP}:2380
listen-client-urls: http://${IP}:2379,http://127.0.0.1:2379
advertise-client-urls: http://${IP}:2379
initial-advertise-peer-urls: http://${IP}:2380
initial-cluster: ${CLUSTER}
initial-cluster-token: data-lab-etcd
initial-cluster-state: new
EOF

cat > /etc/systemd/system/etcd.service <<'EOF'
[Unit]
Description=etcd key-value store
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=etcd
ExecStart=/usr/local/bin/etcd --config-file /etc/etcd/etcd.conf.yml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

firewall-cmd --permanent --add-port=2379/tcp --add-port=2380/tcp >/dev/null
firewall-cmd --reload >/dev/null

systemctl daemon-reload
systemctl enable etcd >/dev/null 2>&1
# 첫 멤버는 정족수(2대)가 모일 때까지 준비 완료가 되지 않으므로 기다리지 않고 시작만 한다
systemctl start --no-block etcd
echo "[06] etcd 시작 요청 완료. 세 대 모두 실행한 뒤 etcdctl endpoint health 로 확인한다."
echo "[06] 완료"
