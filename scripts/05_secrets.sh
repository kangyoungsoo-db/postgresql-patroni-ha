#!/usr/bin/env bash
# 05_secrets.sh : 00_secrets 로 올라온 비밀값 파일을 /etc/lab-secrets (root 전용) 로 옮긴다 (세 VM 공통)
# 파일 내용은 출력하지 않는다. 옮긴 뒤 /home/vagrant/lab-secrets 는 지운다.
set -euo pipefail
set +x

SRC=/home/vagrant/lab-secrets
DST=/etc/lab-secrets

if [ ! -d "$SRC" ]; then
  echo "[05] $SRC 가 없다. 먼저 vagrant provision <VM> --provision-with 00_secrets 를 실행한다."
  exit 1
fi
install -d -m 700 -o root -g root "$DST"
for f in "$SRC"/*; do
  install -m 600 -o root -g root "$f" "$DST/$(basename "$f")"
done
rm -rf "$SRC"
echo "[05] 결과 (파일 이름과 크기만)"
stat -c '%a %U %s %n' "$DST"/*
echo "[05] 완료"
