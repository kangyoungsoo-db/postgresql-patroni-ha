#!/usr/bin/env bash
# 20_drill_etcd_quorum.sh : 장애 훈련 3 etcd 1대 중지, 이어서 2대 중지 (full 상태, root 로 실행)
#   etcd 3대는 과반(2대)이 살아 있어야 쓰기가 된다. 1대가 멈추면 그대로 돌고, 2대가 멈추면 Patroni 가 DCS 를 잃는다.
#   이때 Leader 는 Leader 자리를 보장받을 수 없으므로 스스로 읽기 전용으로 내려간다 (failsafe_mode 꺼짐, 기본값).
#   전체 흐름
#     1. data-db1  : lab_ctl.sh drill-setup
#     2. data-db1  : lab_ctl.sh watch-start r8 300           (Leader 쪽 상태 기록)
#     3. data-db2  : lab_ctl.sh watch-start r8 300 writer    (Replica 쪽 상태 기록, 쓰기 시험)
#     4. data-mgmt : 20_drill_etcd_quorum.sh stop            (1대 중지, 정족수 유지)
#     5. data-db1  : 20_drill_etcd_quorum.sh health
#     6. data-db2  : 20_drill_etcd_quorum.sh stop            (2대 중지, 정족수 잃음)
#     7. data-db1  : 20_drill_etcd_quorum.sh health
#     8. data-db2, data-mgmt : 20_drill_etcd_quorum.sh start (정족수 회복)
#     9. data-db1  : 20_drill_etcd_quorum.sh health, lab_ctl.sh wait-healthy, watch-report
set -euo pipefail
source "$(dirname "$0")/lab_lib.sh"
EPS=http://192.168.56.11:2379,http://192.168.56.12:2379,http://192.168.56.13:2379

case "${1:-}" in
stop)
  step "8" "${HOST} 의 etcd 중지"
  systemctl stop etcd
  result "$(date '+%H:%M:%S') ${HOST} etcd 중지 ($(systemctl is-active etcd || true))"
  done_ok "stop"
  ;;
start)
  step "8" "${HOST} 의 etcd 시작"
  systemctl start --no-block etcd
  sleep 3
  result "$(date '+%H:%M:%S') ${HOST} etcd 시작 ($(systemctl is-active etcd || true))"
  done_ok "start"
  ;;
health)
  step "8" "$(date '+%H:%M:%S') etcd 와 Patroni 상태 (${HOST} 에서 확인)"
  /usr/local/bin/etcdctl --endpoints="$EPS" --command-timeout=3s endpoint health 2>&1 | sed 's/^/  /' || true
  /usr/local/bin/etcdctl --endpoints="$EPS" --command-timeout=3s endpoint status -w table 2>&1 | sed 's/^/  /' || true
  timeout 15 patronictl -c "$PCONF" list 2>&1 | sed 's/^/  /' || echo "  patronictl list 실패 (DCS 에 닿지 못함)"
  echo "  이 노드 PostgreSQL 복구 중(읽기 전용) 여부: $(in_recovery)"
  done_ok "health"
  ;;
*)
  die "사용법: 20_drill_etcd_quorum.sh stop | start | health"
  ;;
esac
