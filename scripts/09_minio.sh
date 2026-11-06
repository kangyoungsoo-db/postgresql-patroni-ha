#!/usr/bin/env bash
# 09_minio.sh : MinIO (data-mgmt, root 로 실행)
#   주의: MinIO 커뮤니티판은 개발이 끝나(archived) 공식 다운로드가 막혔다.
#         GitHub 에 남은 마지막 바이너리 릴리스를 SHA256 으로 검증해서 쓴다. 실습 전용이다.
#   자체 서명 인증서로 HTTPS(9000), 콘솔(9001). 데이터는 /data/minio.
#   pgBackRest 용 버킷 pgbackrest 를 만든다.
set -euo pipefail
set +x
cd /

MINIO_REL="RELEASE.2025-09-07T16-13-09Z"
MC_REL="RELEASE.2025-08-13T08-35-41Z"
MINIO_URL="https://github.com/minio/minio/releases/download/${MINIO_REL}/minio.linux-amd64.${MINIO_REL}"
MC_URL="https://github.com/minio/mc/releases/download/${MC_REL}/mc.linux-amd64.${MC_REL}"
STAMP=$(date +%Y%m%d%H%M%S)

fetch_verify() {   # $1=URL $2=설치 경로
  local tmp; tmp=$(mktemp -d)
  curl -fsSL -o "${tmp}/bin" "$1"
  curl -fsSL -o "${tmp}/sum" "$1.sha256sum"
  local want; want=$(awk '{print $1}' "${tmp}/sum")
  echo "${want}  ${tmp}/bin" | sha256sum -c - >/dev/null
  install -m 755 "${tmp}/bin" "$2"
  rm -rf "$tmp"
  echo "  $(basename "$2") SHA256 확인 후 설치"
}

echo "[09] MinIO, mc 설치"
[ -x /usr/local/bin/minio ] || fetch_verify "$MINIO_URL" /usr/local/bin/minio
[ -x /usr/local/bin/mc ]    || fetch_verify "$MC_URL"    /usr/local/bin/mc
/usr/local/bin/minio --version | head -1

id minio-user >/dev/null 2>&1 || useradd -r -s /sbin/nologin -d /data/minio minio-user
install -d -m 750 -o minio-user -g minio-user /data/minio
install -d -m 750 -o minio-user -g minio-user /etc/minio/certs

echo "[09] 자체 서명 인증서 (data-mgmt, 192.168.56.13)"
if [ ! -s /etc/minio/certs/public.crt ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout /etc/minio/certs/private.key -out /etc/minio/certs/public.crt \
    -subj "/CN=data-mgmt" \
    -addext "subjectAltName=DNS:data-mgmt,IP:192.168.56.13,IP:127.0.0.1" 2>/dev/null
  chown minio-user:minio-user /etc/minio/certs/private.key /etc/minio/certs/public.crt
  chmod 600 /etc/minio/certs/private.key
fi

echo "[09] 환경 파일 /etc/default/minio (root 600)"
[ -e /etc/default/minio ] && cp -p /etc/default/minio "/etc/default/minio.bak.${STAMP}"
(
  umask 077
  AK=$(< /etc/lab-secrets/minio_access_key)
  SK=$(< /etc/lab-secrets/minio_secret_key)
  printf '%s\n' \
    "MINIO_ROOT_USER=${AK}" \
    "MINIO_ROOT_PASSWORD=${SK}" \
    "MINIO_VOLUMES=/data/minio" \
    'MINIO_OPTS="--address :9000 --console-address :9001 --certs-dir /etc/minio/certs"' \
    > /etc/default/minio
)

cat > /etc/systemd/system/minio.service <<'EOF'
[Unit]
Description=MinIO object storage (lab)
After=network-online.target
Wants=network-online.target

[Service]
User=minio-user
Group=minio-user
EnvironmentFile=/etc/default/minio
ExecStart=/usr/local/bin/minio server $MINIO_OPTS $MINIO_VOLUMES
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

firewall-cmd --permanent --add-port=9000/tcp --add-port=9001/tcp >/dev/null
firewall-cmd --reload >/dev/null
systemctl daemon-reload
systemctl enable --now minio >/dev/null 2>&1
systemctl restart minio

echo "[09] MinIO 준비 대기"
for i in $(seq 1 30); do
  curl -ksf https://127.0.0.1:9000/minio/health/live >/dev/null && break
  sleep 2
done
curl -ks -o /dev/null -w "  health/live HTTP %{http_code}\n" https://127.0.0.1:9000/minio/health/live

echo "[09] 버킷 pgbackrest 생성 (자격 증명은 환경변수로만 전달)"
(
  AK=$(< /etc/lab-secrets/minio_access_key)
  SK=$(< /etc/lab-secrets/minio_secret_key)
  export MC_HOST_lab="https://${AK}:${SK}@127.0.0.1:9000"
  export MC_CONFIG_DIR=/root/.mc
  /usr/local/bin/mc --insecure mb --ignore-existing lab/pgbackrest
  /usr/local/bin/mc --insecure ls lab
)
echo "[09] 완료"
