#!/usr/bin/env bash
# 16_patroni_basics.sh : 실습 4 자동 페일오버 기본 (full 스냅샷 상태, root 로 실행)
#   info        : patronictl list, topology, show-config, history, REST API(/patroni, /primary, /replica)
#   route       : PgBouncer 다중 호스트 접속(target_session_attrs=read-write)이 어느 서버로 가는지
#   switchover <현재 Leader> <후보> : 계획 전환과 걸린 시간 (Leader 노드에서 실행)
set -euo pipefail
source "$(dirname "$0")/lab_lib.sh"
systemctl is-active --quiet patroni || die "patroni 가 실행 중이 아니다 (full 상태에서 실행한다)"

case "${1:-}" in
info)
  step "4-1" "Patroni 클러스터 상태"
  pctl list
  pctl topology
  log "DCS(etcd)에 저장된 클러스터 설정"
  pctl show-config
  log "타임라인 기록 (전환할 때마다 1씩 늘어난다)"
  pctl history || true
  step "4-2" "Patroni REST API (8008)"
  for n in data-db1 data-db2; do
    for p in primary replica; do
      echo "  http://${n}:8008/${p} -> HTTP $(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://${n}:8008/${p}")"
    done
  done
  curl -s -m 3 http://127.0.0.1:8008/patroni | python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in ("state", "role", "server_version", "timeline", "patroni"):
    print("  %-15s %s" % (k, d.get(k)))
print("  %-15s %s" % ("replication", [(r.get("application_name"), r.get("state")) for r in d.get("replication", [])]))'
  log "etcd 회원과 상태"
  /usr/local/bin/etcdctl --endpoints=http://127.0.0.1:2379 member list -w table
  /usr/local/bin/etcdctl --endpoints=http://127.0.0.1:2379 endpoint status --cluster -w table
  log "watchdog"
  cat /sys/class/watchdog/watchdog0/identity
  journalctl -u patroni --no-pager 2>/dev/null | grep -i watchdog | tail -2 || true
  done_ok "info"
  ;;

route)
  step "4-3" "PgBouncer 다중 호스트 접속이 가는 곳 (${HOST} 에서 접속)"
  log "접속 문자열: ${APP_CONN} (비밀번호는 임시 pgpass)"
  make_app_pgpass
  app_psql -c '\conninfo' -c 'SELECT pg_is_in_recovery() AS in_recovery' || true
  log "읽기 전용 쪽 (target_session_attrs=standby)"
  PGPASSFILE="$LAB_PGPASS" timeout 8 "${PGBIN}/psql" -X -At "host=data-db1,data-db2 port=6432 dbname=lab_tuning user=lab_app target_session_attrs=standby connect_timeout=2" -c '\conninfo' -c 'SELECT pg_is_in_recovery()' || true
  drop_app_pgpass
  done_ok "route"
  ;;

switchover)
  FROM=${2:?현재 Leader}; TO=${3:?후보}
  step "4-4" "계획 전환 (switchover) ${FROM} -> ${TO}"
  [ "$(leader_name)" = "$FROM" ] || die "지금 Leader 가 ${FROM} 가 아니다: $(leader_name)"
  pctl list
  T0=$(now_ms)
  pctl switchover lab --leader "$FROM" --candidate "$TO" --force
  for i in $(seq 1 120); do
    [ "$(leader_name)" = "$TO" ] && break
    sleep 0.5
  done
  T1=$(now_ms)
  wait_healthy 120 || true
  T2=$(now_ms)
  pctl list
  result "새 Leader(${TO}) running 까지 $(secs "$T0" "$T1")초, 옛 Leader(${FROM}) 가 Replica streaming 으로 붙기까지 $(secs "$T0" "$T2")초"
  cluster_healthy || die "전환 뒤 정상 상태가 아니다"
  done_ok "switchover"
  ;;

*)
  die "사용법: 16_patroni_basics.sh info | route | switchover <현재 Leader> <후보>"
  ;;
esac
