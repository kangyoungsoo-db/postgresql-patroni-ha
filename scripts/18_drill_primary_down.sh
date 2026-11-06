#!/usr/bin/env bash
# 18_drill_primary_down.sh : 장애 훈련 1 Primary 강제 종료 (full 상태, root 로 실행)
#   전체 흐름 (호스트 실행 파일이 순서대로 부른다)
#     1. data-db1 : lab_ctl.sh drill-setup                 (훈련용 표 lab_drill)
#     2. data-db2 : lab_ctl.sh watch-start r6 150 writer   (data-db2 에서 1초마다 상태 기록, 0.5초마다 쓰기)
#     3. 호스트   : vagrant halt -f data-db1               (전원을 뽑은 것과 같은 강제 종료)
#     4. 호스트   : 70초 기다린 뒤 vagrant up data-db1      (옛 Primary 를 다시 켠다)
#     5. data-db2 : 18_drill_primary_down.sh rejoin         (옛 Primary 가 Replica 로 다시 붙는지, pg_rewind 여부)
#     6. data-db2 : lab_ctl.sh watch-report r6              (승격 시각, 쓰기 중단 시간, 사라진 행)
#   손으로 할 때는 3 대신 data-db1 에서 sudo kill -9 <postmaster PID> 나 VirtualBox 전원 끄기를 써도 된다.
set -euo pipefail
source "$(dirname "$0")/lab_lib.sh"

case "${1:-}" in
rejoin)
  step "6-5" "옛 Primary(data-db1) 가 Replica 로 다시 붙는지"
  T0=$(now_ms)
  if wait_healthy 300; then
    result "data-db1 이 켜진 뒤 Replica streaming 까지 (이 단계 시작부터) $(secs "$T0" "$(now_ms)")초"
  else
    result "300초 안에 정상 상태가 되지 않았다"
  fi
  pctl list || true
  log "타임라인 기록"
  pctl history 2>/dev/null | tail -3 || true
  log "data-db2 의 Patroni 로그 (승격 관련)"
  journalctl -u patroni --no-pager --since "-10 min" 2>/dev/null | grep -Ei 'promot|acquire|leader|lock' | tail -8 || true
  done_ok "rejoin"
  ;;
rejoin-log)
  step "6-6" "data-db1 의 Patroni 로그 (다시 붙는 과정, pg_rewind)"
  journalctl -u patroni --no-pager -b 2>/dev/null | grep -Ei 'rewind|replica|follow|bootstrap|starting|demot|leader' | tail -12 || true
  done_ok "rejoin-log"
  ;;
*)
  die "사용법: 18_drill_primary_down.sh rejoin | rejoin-log"
  ;;
esac
