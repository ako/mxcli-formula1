#!/bin/sh
# Boot both apps with runtime observation on, and expose them on the mxcli hub.
#
#   scripts/run-observed.sh              # both apps on the hub, observed
#   HUB= scripts/run-observed.sh         # local only, still observed
#
# Three things are switched on that a plain `run --local` leaves off:
#
#   --metrics      a Prometheus registry at http://127.0.0.1:<admin>/prometheus
#   --trace-otlp   the OpenTelemetry agent, exporting to the collector below
#   --runtime-log  (already the default) server stack traces and microflow LOG
#
# The console span exporter that plain --trace uses drops timestamps and parent
# ids, so it can say a span happened but not how long it took or what it was
# under. scripts/otlp-collector.py is the endpoint that keeps both, and
# scripts/span-report.py reads what it writes.
#
# Everything lands in .mxcli-obs/ (gitignored). Stop it all with
#   scripts/run-observed.sh stop
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OBS="$ROOT/.mxcli-obs"
HUB=${HUB-$MXCLI_HUB_URL}
OTLP=${OTLP:-http://127.0.0.1:4318}

stop() {
  # By pid, never by pattern: a pkill whose pattern appears in this script's own
  # command line kills the shell running it.
  for pid in $(ps -e -o pid=,args= | grep "runtimelaunche[r].*Formula1" | awk '{print $1}'); do
    par=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    kill "$pid" $par 2>/dev/null || true
  done
  for pid in $(ps -e -o pid=,args= | grep "[o]tlp-collector.py" | awk '{print $1}'); do
    kill "$pid" 2>/dev/null || true
  done

  # Wait for the ports, not for the processes. A JVM is gone from `ps` before it
  # has released its listeners, and mxcli refuses to boot onto an occupied admin
  # port — correctly, but the message names a pid that no longer exists and
  # reads like a stale-cache problem. Three seconds was not enough: the second
  # app started fine and the first lost the race.
  i=0
  while [ $i -lt 30 ]; do
    busy=""
    for port in 8080 8090 8180 8190 6643; do
      if (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null; then
        exec 3>&- 2>/dev/null || true
        busy="$busy $port"
      fi
    done
    [ -z "$busy" ] && break
    sleep 1
    i=$((i + 1))
  done
  [ -n "$busy" ] && echo "warning: still listening on$busy after ${i}s"
  echo "stopped"
}

[ "$1" = "stop" ] && { stop; exit 0; }

mkdir -p "$OBS"
stop >/dev/null 2>&1 || true

# The collector first: an app that boots with nowhere to export to logs a
# connection error per batch for as long as it runs.
: > "$OBS/spans.jsonl"
# setsid as well as nohup: this repo is often driven from a remote sandbox that
# reaps a turn's process group when the session goes idle, and a runtime killed
# that way leaves no shutdown in its log — it simply stops mid-life. Detaching
# into a new session is the part of that we can control.
setsid nohup python3 "$ROOT/scripts/otlp-collector.py" "$OBS/spans.jsonl" 4318 \
  > "$OBS/collector.log" 2>&1 &
sleep 2

hub_args=""
[ -n "$HUB" ] && hub_args="--hub $HUB --hub-solution formula1"

# shellcheck disable=SC2086
(cd "$ROOT/Formula1Backend" && setsid nohup ./mxcli run --local $hub_args \
   ${HUB:+--hub-project f1-backend} \
   -p Formula1Backend.mpr \
   --metrics --trace-otlp "$OTLP" --trace-service Formula1Backend \
   > "$OBS/backend.log" 2>&1 &)
sleep 3
# shellcheck disable=SC2086
(cd "$ROOT/Formula1Frontend" && setsid nohup ./mxcli run --local $hub_args \
   ${HUB:+--hub-project f1-frontend} \
   -p Formula1Frontend.mpr \
   --app-port 8180 --admin-port 8190 --serve-port 6643 \
   --metrics --trace-otlp "$OTLP" --trace-service Formula1Frontend \
   > "$OBS/frontend.log" 2>&1 &)

printf 'waiting for both apps'
i=0
while [ $i -lt 20 ]; do
  sleep 12
  b=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ || true)
  f=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8180/ || true)
  [ "$b" = "200" ] && [ "$f" = "200" ] && break
  printf '.'
  i=$((i + 1))
done
echo

echo "backend   http://backend.local:8080/    metrics http://127.0.0.1:8090/prometheus"
echo "frontend  http://frontend.local:8180/   metrics http://127.0.0.1:8190/prometheus"
grep -ho 'https://[a-z0-9.-]*mxcli\.org' "$OBS/backend.log" "$OBS/frontend.log" \
  | grep -v '^https://hub' | sort -u | sed 's/^/hub       /'
echo "traces    $OBS/spans.jsonl   ->  python3 scripts/span-report.py $OBS/spans.jsonl --since 60"
echo "errors    Formula1{Backend,Frontend}/.mxcli/runtime.log"
