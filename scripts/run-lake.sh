#!/bin/sh
# Start DuckGraphLake over data/ and load this solution's dashboards.
#
#   scripts/run-lake.sh          # start (or reuse a running one), then load dashboards
#   scripts/run-lake.sh stop
#
# The lake serves data/ on SQL :5433, HTTP :9495 (web UI, OData, SPARQL, MCP),
# Kafka :9092 and OTLP :4318. Point the backend at it with
#
#   ./mxcli run --local -p Formula1Backend.mpr \
#     --runtime-setting Kafka.BootstrapServers=127.0.0.1:9092 \
#     --runtime-setting 'Metrics.Registries=[{"type":"opentelemetry","settings":{"url":"http://127.0.0.1:4318/v1/metrics","step":"30s"}}]' \
#     --trace-otlp http://127.0.0.1:4318 --trace-service Formula1Backend
#
# Dashboards live in lake/dashboards/ because the lake keeps its own copy under
# data/.duckgraphlake/, which is gitignored; this uploads each one by id
# (the file name), so re-running it overwrites the lake's copy with the repo's.
#
# Needs the duckgraphlake binary on PATH: the packaged release, with its iceberg
# and avro extensions beside it (a source build without them fails to start
# with Kafka on, ako/DuckGraphLake#27).
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOG="$ROOT/.mxcli-obs/lake.log"
API=http://127.0.0.1:9495
TOKEN=${DUCKGRAPHLAKE_TOKEN:-duckgraphlake}

pids() { ps -e -o pid=,args= | grep "[d]uckgraphlake $ROOT/data" | awk '{print $1}'; }

if [ "$1" = "stop" ]; then
  for pid in $(pids); do kill "$pid"; done
  echo "stopped"
  exit 0
fi

command -v duckgraphlake >/dev/null 2>&1 || {
  echo "duckgraphlake is not on PATH." >&2
  exit 1
}

if curl -sf -o /dev/null "$API/api/guide"; then
  echo "lake already running at $API"
else
  mkdir -p "$(dirname "$LOG")"
  # setsid, like run-observed.sh: survive the session that started it.
  # No --init script: a failing statement in it stops the server, and the
  # otel.* views only exist once telemetry has arrived, so anything over them
  # fails on a fresh data folder. The dashboard queries carry their own
  # counter-delta CTE instead.
  setsid nohup duckgraphlake "$ROOT/data" > "$LOG" 2>&1 &
  i=0
  until curl -sf -o /dev/null "$API/api/guide"; do
    i=$((i + 1))
    [ $i -gt 60 ] && { echo "lake did not start; see $LOG" >&2; tail -20 "$LOG" >&2; exit 1; }
    sleep 1
  done
  echo "lake started at $API (log: $LOG)"
fi

for f in "$ROOT"/lake/dashboards/*.json; do
  [ -f "$f" ] || continue
  id=$(basename "$f" .json)
  curl -sf -X PUT "$API/api/dashboards/$id" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data-binary "@$f" > /dev/null
  echo "dashboard $id -> $API/#dashboards  (loaded from lake/dashboards/$id.json)"
done
