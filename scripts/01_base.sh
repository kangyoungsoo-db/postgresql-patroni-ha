#!/usr/bin/env bash
# 01_base.sh : 기본 설정 (두 VM 공통, root 로 실행)
#   1) 시간대 Asia/Seoul
#   2) /etc/hosts 에 data-db1, data-db2 등록
#   3) 기본 패키지 vim, git, chrony (+ firewalld, semanage 도구)
#   4) 방화벽: 켜 두고 22(ssh), 5432(postgresql) 만 허용
#   5) 데이터 디스크를 /data 에 마운트하고 /data/pgsql 에 SELinux 라벨 등록
# 여러 번 실행해도 결과가 같도록 만들었다.
set -euo pipefail

STAMP=$(date +%Y%m%d%H%M%S)
DISK_BYTES=$((50 * 1024 * 1024 * 1024))   # Vagrantfile 의 DATA_DISK_GB 와 맞춘다
FS_LABEL="pgdata"

echo "[01] 시간대 설정"
timedatectl set-timezone Asia/Seoul

echo "[01] /etc/hosts 등록"
# IP 로 시작하는 줄이 없을 때만 추가한다 (Vagrant 가 넣는 127.0.1.1 줄과 헷갈리지 않도록 IP 기준)
for entry in "192.168.56.11 data-db1" "192.168.56.12 data-db2" "192.168.56.13 data-mgmt"; do
  if ! grep -q "^${entry%% *} " /etc/hosts; then
    [ -e "/etc/hosts.bak.${STAMP}" ] || cp -p /etc/hosts "/etc/hosts.bak.${STAMP}"   # 바꾸기 전에 백업
    echo "$entry" >> /etc/hosts
  fi
done

echo "[01] 기본 패키지 설치"
dnf install -y vim git chrony firewalld policycoreutils-python-utils
systemctl enable --now chronyd

echo "[01] 방화벽 설정 (22, 5432 만 허용)"
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --add-service=postgresql
for svc in cockpit dhcpv6-client; do
  if firewall-cmd --permanent --query-service="$svc" >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-service="$svc"
  fi
done
firewall-cmd --reload

echo "[01] 데이터 디스크 마운트"
# 안전 규칙: 아래 조건을 "모두" 만족하는 디스크만 포맷한다.
#   - TYPE 이 disk 이다
#   - 파티션이 하나도 없다 (자식 장치 없음)
#   - 파일시스템 서명이 없다 (blkid 결과 없음)
#   - 크기가 정확히 50 GiB 이다
# 조건에 맞는 디스크가 정확히 1개가 아니면 아무것도 하지 않고 멈춘다.
# 이미 pgdata 라벨 파일시스템이 있으면 포맷하지 않고 마운트만 한다 (재실행해도 데이터 유지).
mkdir -p /data
if mountpoint -q /data; then
  echo "  /data 는 이미 마운트되어 있다. 건너뛴다."
else
  DEV=$(blkid -L "$FS_LABEL" || true)
  if [ -n "$DEV" ]; then
    echo "  기존 $FS_LABEL 파일시스템 발견: $DEV (포맷하지 않음)"
  else
    CANDIDATES=()
    while read -r name type size; do
      [ "$type" = "disk" ] || continue
      [ "$size" = "$DISK_BYTES" ] || continue
      [ "$(lsblk -nro NAME "$name" | wc -l)" -eq 1 ] || continue   # 파티션이 있으면 제외
      [ -z "$(blkid -o value -s TYPE "$name" || true)" ] || continue  # 파일시스템이 있으면 제외
      CANDIDATES+=("$name")
    done < <(lsblk -dbnpo NAME,TYPE,SIZE)

    if [ "${#CANDIDATES[@]}" -ne 1 ]; then
      echo "  [중단] 포맷 조건에 맞는 빈 디스크가 ${#CANDIDATES[@]}개다. 1개여야 한다."
      lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS
      exit 1
    fi
    DEV="${CANDIDATES[0]}"
    echo "  빈 디스크 $DEV 를 XFS 로 포맷한다"
    mkfs.xfs -L "$FS_LABEL" "$DEV"
  fi

  UUID=$(blkid -s UUID -o value "$DEV")
  if ! grep -q "$UUID" /etc/fstab; then
    cp -p /etc/fstab "/etc/fstab.bak.${STAMP}"    # 바꾸기 전에 백업
    echo "UUID=${UUID} /data xfs defaults,nofail 0 0" >> /etc/fstab
  fi
  systemctl daemon-reload
  mount /data
fi

echo "[01] /data/pgsql SELinux 라벨 등록"
# PGDATA 를 기본 경로(/var/lib/pgsql)가 아닌 곳에 두므로 postgresql_db_t 라벨이 필요하다.
mkdir -p /data/pgsql
if ! semanage fcontext -l | grep -F '/data/pgsql(/.*)?' >/dev/null; then
  semanage fcontext -a -t postgresql_db_t '/data/pgsql(/.*)?'
fi
restorecon -R /data/pgsql

echo "[01] 결과"
timedatectl | grep "Time zone"
df -h /data
ls -Zd /data/pgsql
echo "[01] 완료"
