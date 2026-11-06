#!/usr/bin/env bash
# lab_ctl.sh : 스냅샷을 되돌린 뒤 VM 을 실습할 수 있는 상태로 맞춘다 (root 로 실행)
#   timesync <epoch>   : 시계를 호스트 시각으로 맞춘다 (실행 중 스냅샷을 되돌리면 시계가 스냅샷 시각에 머문다)
#   full-ready         : etcd 정족수를 기다리고, Patroni pause 를 풀고, Leader + Replica streaming 을 기다린다 (Patroni 노드에서)
#   baseline-ready     : 수동 스트리밍 복제(baseline) 상태가 정상인지 확인한다 (data-db1 에서)
#   status             : 지금 상태를 보여 준다
set -euo pipefail
source "$(dirname "$0")/lab_lib.sh"

case "${1:-}" in
timesync)
  EPOCH=${2:?epoch 필요}
  log "시계 맞추기 전: $(date '+%F %T')"
  date -s "@${EPOCH}" >/dev/null
  chronyc -a makestep >/dev/null 2>&1 || true
  log "시계 맞춘 뒤: $(date '+%F %T')"
  done_ok "timesync ${HOST}"
  ;;

full-ready)
  step "준비" "full 상태 확인 (${HOST})"
  log "etcd 정족수 대기 (최대 180초)"
  for i in $(seq 1 90); do
    if /usr/local/bin/etcdctl --endpoints=http://127.0.0.1:2379 endpoint health --cluster >/tmp/lab_etcd 2>&1; then break; fi
    sleep 2
  done
  cat /tmp/lab_etcd || true
  log "Patroni pause 해제 (resume, pause 상태일 때만)"
  for i in $(seq 1 30); do
    if L=$(pctl list 2>/dev/null); then
      if echo "$L" | grep -qi 'maintenance mode'; then
        pctl resume lab >/dev/null 2>&1 || true
      else
        break
      fi
    fi
    sleep 3
  done
  log "Leader running + Replica streaming 대기 (최대 240초)"
  if ! wait_healthy 240; then
    pctl list || true
    die "클러스터가 정상 상태가 되지 않았다"
  fi
  pctl list
  if pctl list 2>/dev/null | grep -qi 'maintenance mode'; then die "아직 pause 상태이다"; fi
  done_ok "full-ready"
  ;;

baseline-ready)
  step "준비" "baseline 상태 확인 (${HOST})"
  systemctl is-active --quiet postgresql-17 || die "postgresql-17 이 실행 중이 아니다"
  systemctl is-active --quiet patroni 2>/dev/null && die "patroni 가 실행 중이다. baseline 이 아니다"
  for i in $(seq 1 60); do
    [ "$(psql_q -c "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming'")" = "1" ] && break
    sleep 2
  done
  psql_pg -c "SELECT application_name, client_addr, state, sync_state, replay_lag FROM pg_stat_replication;"
  [ "$(psql_q -c "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming'")" = "1" ] || die "복제가 streaming 이 아니다"
  done_ok "baseline-ready"
  ;;

status)
  if systemctl is-active --quiet patroni; then pctl list || true; else psql_pg -c "SELECT pg_is_in_recovery();" || true; fi
  done_ok "status"
  ;;

leader)
  echo "LEADER=$(leader_name)"
  done_ok "leader"
  ;;

drill-setup)
  # 장애 훈련용 표를 만든다 (Leader 에서)
  [ "$(in_recovery)" = "f" ] || die "${HOST} 는 Leader 가 아니다"
  ensure_drill_table
  pctl list
  done_ok "drill-setup"
  ;;

watch-start)
  # 이 노드에서 상태 기록(1초)과, 'writer' 를 주면 쓰기 시험(0.5초)을 백그라운드로 시작한다
  RUN=${2:?run_id}; SECS=${3:?초}; SELF=$(readlink -f "$0")
  rm -f "${RESULTS}/${RUN}_${HOST}_monitor.csv" "${RESULTS}/${RUN}_${HOST}_writer.csv"
  bg_run "lab-mon-${RUN}" /usr/bin/bash "$SELF" _monitor "${RESULTS}/${RUN}_${HOST}_monitor.csv" "$SECS"
  log "상태 기록 시작: ${SECS}초 (${RESULTS}/${RUN}_${HOST}_monitor.csv)"
  if [ "${4:-}" = "writer" ]; then
    bg_run "lab-writer-${RUN}" /usr/bin/bash "$SELF" _writer "$RUN" "$SECS" "${RESULTS}/${RUN}_${HOST}_writer.csv"
    log "쓰기 시험 시작: ${SECS}초, 0.5초마다 1건 (${RESULTS}/${RUN}_${HOST}_writer.csv)"
  fi
  done_ok "watch-start"
  ;;

watch-report)
  # 백그라운드 기록이 끝나기를 기다린 뒤(최대 $3 초) 바뀐 상태와 쓰기 결과를 요약한다
  RUN=${2:?run_id}; MAXW=${3:-60}
  bg_wait "lab-mon-${RUN}" "$MAXW" || systemctl stop "lab-mon-${RUN}" >/dev/null 2>&1 || true
  bg_wait "lab-writer-${RUN}" "$MAXW" || systemctl stop "lab-writer-${RUN}" >/dev/null 2>&1 || true
  step "기록" "${HOST} 의 상태 변화 (${RUN})"
  [ -f "${RESULTS}/${RUN}_${HOST}_monitor.csv" ] && monitor_report "${RESULTS}/${RUN}_${HOST}_monitor.csv" || echo "  상태 기록 파일 없음"
  if [ -f "${RESULTS}/${RUN}_${HOST}_writer.csv" ]; then
    step "기록" "${HOST} 에서 본 쓰기 시험 (${RUN})"
    writer_report "$RUN" "${RESULTS}/${RUN}_${HOST}_writer.csv"
    log "실패 구간 원본 (앞뒤 포함 최대 12줄)"
    awk -F, 'NR > 1 && $3 != "ok" { print NR }' "${RESULTS}/${RUN}_${HOST}_writer.csv" | head -1 | while read -r first; do
      sed -n "$(( first > 3 ? first - 2 : 2 )),$(( first + 9 ))p" "${RESULTS}/${RUN}_${HOST}_writer.csv"
    done
  fi
  done_ok "watch-report"
  ;;

wait-healthy)
  # Leader running + Replica streaming 이 될 때까지 기다리고 걸린 시간을 보여 준다
  MAXW=${2:-240}; T0=$(now_ms)
  if wait_healthy "$MAXW"; then
    result "정상 상태까지 $(secs "$T0" "$(now_ms)")초"
  else
    result "${MAXW}초 안에 정상 상태가 되지 않았다"
  fi
  pctl list || true
  pctl history 2>/dev/null | tail -4 || true
  cluster_healthy || die "정상 상태가 아니다"
  done_ok "wait-healthy"
  ;;

_monitor) monitor_loop "$2" "$3" ;;
_writer)  writer_loop "$2" "$3" "$4" ;;

*)
  die "사용법: lab_ctl.sh timesync <epoch> | full-ready | baseline-ready | status | drill-setup | watch-start <run> <초> [writer] | watch-report <run> [최대 초] | wait-healthy [최대 초]"
  ;;
esac
