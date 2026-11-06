#!/usr/bin/env bash
# lab_lib.sh : 실습 스크립트(14 ~ 22, lab_ctl)가 같이 쓰는 함수 모음. 직접 실행하지 않고 source 한다.
#   - 비밀번호는 화면, 로그, 명령 인자에 남기지 않는다 (임시 pgpass 파일을 root 600 으로 만들고 끝나면 지운다)
#   - 모든 기다리기에는 시간 제한이 있다 (무한 대기 없음)

PGBIN=/usr/pgsql-17/bin
PGDATA=/data/pgsql/17/data
PCONF=/etc/patroni/patroni.yml
DB=lab_tuning
RESULTS=/home/vagrant/lab-results
WORK=/data/pgsql/lab-work          # 덤프, 복구 시험 폴더 (SELinux 라벨 postgresql_db_t 가 붙는 경로)
HOST=$(hostname -s)
APP_CONN="host=data-db1,data-db2 port=6432 dbname=lab_tuning user=lab_app target_session_attrs=read-write connect_timeout=2"
cd /
# set -e 로 예상하지 못한 곳에서 멈추면 어느 줄인지 남긴다
trap 'rc=$?; echo "[실패] $(basename "$0") ${LINENO}행의 명령이 실패해 멈췄다 (종료 코드 ${rc})"' ERR

mkdir -p "$RESULTS"
chown vagrant:vagrant "$RESULTS" 2>/dev/null || true

# ---------- 출력 ----------
now_ms()  { date +%s%3N; }
log()     { echo "[$(date '+%H:%M:%S')] $*"; }
step()    { echo; echo "=================================================================="; echo "[$1] $2"; echo "=================================================================="; }
result()  { echo "[결과] $*"; }
done_ok() { echo "[완료] $*"; exit 0; }
die()     { echo "[실패] $*"; exit 1; }
secs()    { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", (b - a) / 1000 }'; }   # ms 두 개 -> 초

# ---------- PostgreSQL ----------
psql_pg() { runuser -u postgres -- "${PGBIN}/psql" -X -v ON_ERROR_STOP=1 "$@"; }      # 로컬 소켓, peer 인증
psql_q()  { runuser -u postgres -- "${PGBIN}/psql" -X -v ON_ERROR_STOP=1 -Atq "$@"; }
in_recovery() { timeout 5 runuser -u postgres -- "${PGBIN}/psql" -X -Atq -c 'SELECT pg_is_in_recovery()' 2>/dev/null || echo "-"; }

# 복구용 임시 인스턴스(소켓 /run/postgresql, 포트 5433)가 접속을 받을 때까지 기다린다
wait_tmp_instance() {   # $1=최대 초
  local i
  for i in $(seq 1 $(( $1 * 2 ))); do
    runuser -u postgres -- "${PGBIN}/psql" -X -Atq -p 5433 -h /run/postgresql -d postgres -c 'SELECT 1' >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

# ---------- Patroni ----------
pctl() { patronictl -c "$PCONF" "$@"; }
# Patroni 회원 상태를 "이름 역할 상태 지연" 줄로 출력한다
patroni_members() {
  pctl list -f json 2>/dev/null | python3 -c '
import json, sys
try:
    for m in json.load(sys.stdin):
        lag = 0
        for k in ("Lag in MB", "Replay Lag", "Receive Lag"):
            if k in m:
                lag = m[k]
                break
        if lag in ("", None):
            lag = 0
        print(m.get("Member"), m.get("Role"), m.get("State"), str(lag).replace(" ", ""))
except Exception:
    pass'
}
leader_name() { patroni_members | awk '$2 == "Leader" && $3 == "running" { print $1 }' | head -1; }
# 정상: Leader running 1대 + Replica streaming 1대, 지연 0
cluster_healthy() {
  local m; m=$(patroni_members)
  [ "$(echo "$m" | awk '$2 == "Leader" && $3 == "running"' | wc -l)" = "1" ] &&
  [ "$(echo "$m" | awk '($2 == "Replica" || $2 == "Sync Standby") && $3 == "streaming" && $4 == 0' | wc -l)" = "1" ]
}
wait_healthy() {   # $1=최대 초
  local max=$1 i
  for i in $(seq 1 "$max"); do
    cluster_healthy && return 0
    sleep 1
  done
  return 1
}

# ---------- lab_app 접속 (PgBouncer, Primary 자동 찾기) ----------
LAB_PGPASS=""
make_app_pgpass() {
  local pw
  LAB_PGPASS=$(umask 077; mktemp /root/.lab_pgpass.XXXXXX)
  IFS= read -r pw < /etc/lab-secrets/lab_app_pw || true
  pw=${pw%$'\r'}
  pw=${pw//\\/\\\\}; pw=${pw//:/\\:}
  printf '*:6432:*:lab_app:%s\n' "$pw" > "$LAB_PGPASS"
  unset pw
}
drop_app_pgpass() { [ -n "$LAB_PGPASS" ] && rm -f "$LAB_PGPASS"; LAB_PGPASS=""; }
app_psql() { PGPASSFILE="$LAB_PGPASS" timeout 8 "${PGBIN}/psql" -X -At "$APP_CONN" "$@"; }

# ---------- 장애 훈련 공통 : 상태 기록, 쓰기 시험 ----------
# 1초마다 이 노드의 Patroni 역할, 상태, 타임라인, PostgreSQL 복구 여부를 CSV 로 남긴다
monitor_loop() {   # $1=출력 파일 $2=초
  local out=$1 dur=$2 end j line rec
  end=$(( $(date +%s) + dur ))
  echo "epoch_ms,node,role,state,timeline,in_recovery" > "$out"
  while [ "$(date +%s)" -lt "$end" ]; do
    j=$(curl -s -m 1 http://127.0.0.1:8008/patroni 2>/dev/null || true)
    line=$(printf '%s' "$j" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print("%s,%s,%s" % (d.get("role", "-"), d.get("state", "-"), d.get("timeline", "-")))
except Exception:
    print("-,-,-")')
    rec=$(in_recovery)
    echo "$(now_ms),${HOST},${line},${rec}" >> "$out"
    sleep 1
  done
}

# 0.5초마다 PgBouncer 다중 호스트 접속으로 한 건씩 INSERT 하고 결과를 CSV 로 남긴다
writer_loop() {   # $1=run_id $2=초 $3=출력 파일
  local run=$1 dur=$2 out=$3 n=0 end t res hostn
  end=$(( $(date +%s) + dur ))
  make_app_pgpass
  echo "seq,epoch_ms,result,host" > "$out"
  while [ "$(date +%s)" -lt "$end" ]; do
    n=$((n + 1)); t=$(now_ms)
    if res=$(app_psql -c "INSERT INTO lab_drill (run_id, seq) VALUES ('${run}', ${n})" -c '\conninfo' 2>&1); then
      hostn=$(printf '%s' "$res" | sed -n 's/.* on host "\([^"]*\)".*/\1/p' | head -1)
      echo "${n},${t},ok,${hostn}" >> "$out"
    else
      echo "${n},${t},fail,$(printf '%s' "$res" | tr '\n,' '  ' | cut -c1-90)" >> "$out"
    fi
    sleep 0.5
  done
  drop_app_pgpass
}

# systemd-run 으로 백그라운드 작업을 띄운다 (vagrant ssh 가 끝나도 계속 돈다)
bg_run() {   # $1=유닛 이름, 나머지=명령
  local unit=$1; shift
  systemctl stop "$unit" >/dev/null 2>&1 || true
  systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  systemd-run --quiet --unit="$unit" --collect "$@"
}
bg_wait() {   # $1=유닛 이름 $2=최대 초
  local i
  for i in $(seq 1 "$2"); do
    systemctl is-active --quiet "$1" || return 0
    sleep 1
  done
  return 1
}

# 상태 기록 CSV 에서 값이 바뀐 줄만 보여 준다 (기준 시각 대비 초 포함)
monitor_report() {   # $1=CSV $2=기준 epoch_ms (없으면 첫 줄)
  python3 - "$1" "${2:-0}" <<'PY'
import csv, sys, time
path, base = sys.argv[1], int(sys.argv[2])
hms = lambda ms: time.strftime("%H:%M:%S", time.localtime(int(ms) / 1000))
rows = list(csv.DictReader(open(path)))
if not rows:
    print("  기록 없음"); sys.exit(0)
if base == 0:
    base = int(rows[0]["epoch_ms"])
prev = None
print("  %-8s %8s  %-9s %-10s %-22s %-4s %s" % ("시각", "초", "노드", "역할", "상태", "TL", "복구중"))
for r in rows:
    key = (r["role"], r["state"], r["timeline"], r["in_recovery"])
    if key != prev:
        print("  %-8s %8.1f  %-9s %-10s %-22s %-4s %s" % (hms(r["epoch_ms"]), (int(r["epoch_ms"]) - base) / 1000, r["node"], r["role"], r["state"], r["timeline"], r["in_recovery"]))
        prev = key
print("  마지막 기록: %.1f초" % ((int(rows[-1]["epoch_ms"]) - base) / 1000))
PY
}

# 쓰기 시험 결과 요약 : 성공, 실패, 쓰기 중단 시간, 응답을 받았는데 사라진 행
writer_report() {   # $1=run_id $2=CSV
  local run=$1 csvf=$2 present
  make_app_pgpass
  present=$(mktemp)
  app_psql -c "SELECT seq FROM lab_drill WHERE run_id = '${run}' ORDER BY seq" > "$present" 2>/dev/null || echo "  (현재 Primary 에서 lab_drill 을 읽지 못했다)"
  drop_app_pgpass
  python3 - "$csvf" "$present" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
present = set()
for line in open(sys.argv[2]):
    line = line.strip()
    if line.isdigit():
        present.add(int(line))
ok = [r for r in rows if r["result"] == "ok"]
fail = [r for r in rows if r["result"] != "ok"]
print("  시도 %d건, 성공 %d건, 실패 %d건" % (len(rows), len(ok), len(fail)))
if ok:
    gaps = []
    for a, b in zip(ok, ok[1:]):
        gaps.append(((int(b["epoch_ms"]) - int(a["epoch_ms"])) / 1000, a, b))
    g = max(gaps, key=lambda x: x[0]) if gaps else None
    if g:
        hms = lambda ms: __import__("time").strftime("%H:%M:%S", __import__("time").localtime(int(ms) / 1000))
        print("  가장 긴 쓰기 중단: %.1f초 (%s seq %s 성공 뒤 %s seq %s 성공까지)" % (g[0], hms(g[1]["epoch_ms"]), g[1]["seq"], hms(g[2]["epoch_ms"]), g[2]["seq"]))
    hosts = []
    for r in ok:
        if not hosts or hosts[-1][0] != r["host"]:
            hosts.append([r["host"], r["seq"]])
    print("  쓰기가 간 서버 순서: " + " -> ".join("%s(seq %s부터)" % (h, s) for h, s in hosts))
lost = sorted(int(r["seq"]) for r in ok if int(r["seq"]) not in present)
print("  성공 응답을 받았는데 지금 Primary 에 없는 행: %d건 %s" % (len(lost), lost[:20] if lost else ""))
if fail:
    print("  첫 실패 메시지: " + fail[0]["host"][:90])
PY
  rm -f "$present"
}

# 장애 훈련용 표 (Leader 에서 한 번)
ensure_drill_table() {
  psql_pg -d "$DB" -q <<'SQL'
CREATE TABLE IF NOT EXISTS lab_drill (
    run_id     text        NOT NULL,
    seq        integer     NOT NULL,
    written_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, seq)
);
GRANT SELECT, INSERT ON lab_drill TO lab_app;
SQL
}
