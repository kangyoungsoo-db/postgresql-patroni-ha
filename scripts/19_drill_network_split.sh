#!/usr/bin/env bash
# 19_drill_network_split.sh : 장애 훈련 2 망 분리 (full 상태, root 로 실행)
#   data-db1(Leader) 의 Host-Only 망(192.168.56.x) 만 nftables 로 끊어 etcd, data-db2, PgBouncer 접속에서 고립시킨다.
#   vagrant ssh 는 NAT 망을 쓰므로 계속 들어갈 수 있다. 끊는 규칙은 별도 표(inet lab_split)라 firewalld 설정과 섞이지 않고,
#   재부팅하면 사라진다.
#   전체 흐름
#     1. data-db1 : lab_ctl.sh drill-setup
#     2. data-db2 : lab_ctl.sh watch-start r7 220 writer
#     3. data-db1 : 19_drill_network_split.sh start r7 15 90 220   (15초 뒤 끊고, 90초 뒤 다시 잇는다. 상태 기록 220초)
#     4. 호스트   : 기다린다
#     5. data-db1 : 19_drill_network_split.sh cleanup, lab_ctl.sh watch-report r7
#     6. data-db2 : lab_ctl.sh wait-healthy, lab_ctl.sh watch-report r7
#   확인할 것: 고립된 옛 Leader 가 스스로 읽기 전용(Replica)으로 내려가는 시각, data-db2 가 승격되는 시각,
#              그 사이 Leader 가 둘인 순간이 있었는지, 다시 이었을 때 옛 Leader 가 Replica 로 붙는지
set -euo pipefail
source "$(dirname "$0")/lab_lib.sh"

IFACE=$(ip -4 -o addr show | awk '/192\.168\.56\./ { print $2 }' | head -1)
split_on()  {
  nft add table inet lab_split
  nft add chain inet lab_split input  '{ type filter hook input priority -10; policy accept; }'
  nft add chain inet lab_split output '{ type filter hook output priority -10; policy accept; }'
  nft add rule inet lab_split input  iifname "$IFACE" drop
  nft add rule inet lab_split output oifname "$IFACE" drop
}
split_off() { nft delete table inet lab_split 2>/dev/null || true; }

case "${1:-}" in
start)
  RUN=${2:?run_id}; AFTER=${3:?초}; HOLD=${4:?초}; SECS=${5:?초}; SELF=$(readlink -f "$0")
  [ "$HOST" = "data-db1" ] || die "data-db1 에서 실행한다"
  split_off
  rm -f "${RESULTS}/${RUN}_${HOST}_monitor.csv" "${RESULTS}/${RUN}_split.txt"
  bg_run "lab-mon-${RUN}" /usr/bin/bash "$(dirname "$SELF")/lab_ctl.sh" _monitor "${RESULTS}/${RUN}_${HOST}_monitor.csv" "$SECS"
  bg_run "lab-split-${RUN}" /usr/bin/bash "$SELF" _split "$RUN" "$AFTER" "$HOLD"
  log "상태 기록 ${SECS}초 시작, ${AFTER}초 뒤 ${IFACE} 를 끊고 ${HOLD}초 뒤 다시 잇는다"
  done_ok "start"
  ;;
_split)
  RUN=$2; AFTER=$3; HOLD=$4
  trap split_off EXIT
  trap 'split_off; exit 1' TERM INT
  sleep "$AFTER"
  split_on
  echo "split_on=$(now_ms) $(date '+%H:%M:%S')" >> "${RESULTS}/${RUN}_split.txt"
  sleep "$HOLD"
  split_off
  echo "split_off=$(now_ms) $(date '+%H:%M:%S')" >> "${RESULTS}/${RUN}_split.txt"
  ;;
cleanup)
  RUN=${2:?run_id}
  step "7-4" "망 분리 기록과 정리"
  bg_wait "lab-split-${RUN}" 30 || systemctl stop "lab-split-${RUN}" >/dev/null 2>&1 || true
  split_off
  cat "${RESULTS}/${RUN}_split.txt" 2>/dev/null || echo "  분리 기록 없음 (재부팅되었을 수 있다)"
  log "이번 부팅 시각: $(uptime -s)"
  log "Patroni 로그 (DCS 끊김, 강등)"
  journalctl -u patroni --no-pager --since "-10 min" 2>/dev/null | grep -Ei 'demot|dcs|lock|leader|watchdog|follow|rewind' | tail -12 || true
  nft list tables
  done_ok "cleanup"
  ;;
*)
  die "사용법: 19_drill_network_split.sh start <run> <끊기까지 초> <끊는 시간 초> <기록 초> | cleanup <run>"
  ;;
esac
