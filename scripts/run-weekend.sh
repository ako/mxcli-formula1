#!/bin/sh
# A race weekend, unattended: the lake, and both apps supervised against the
# real OpenF1, with every ingestion path into the lake switched on.
#
#   scripts/run-weekend.sh          # start (stops any app already running first)
#   scripts/run-weekend.sh status
#   scripts/run-weekend.sh stop
#
# What runs:
#   - the lake (scripts/run-lake.sh), which takes it all in;
#   - the backend under scripts/keep-app-running.sh, against api.openf1.org with
#     this machine's OpenF1 credentials (`mxcli constant set` values), and:
#       * every changed OpenF1 response posted to the lake's events endpoint
#         (Sync_LakePost in 19-live-sync.mdl): bronze, topic `openf1`, one event
#         type per feed, views openf1.<feed>;
#       * CDC of LiveSyncState (27-cdc-stream.mdl);
#       * OpenTelemetry metrics, traces and logs;
#   - the frontend under the same supervisor, with the chat keys when present,
#     its CDC of agent turns and its OpenTelemetry.
#
# The supervisor restarts an app when its health URL stops answering, which is
# how the trial licence's run-time limit is survived; the live sync keeps its
# state in the database and resumes. After each start it re-attaches the
# OpenTelemetry log subscriber, which does not survive a restart.
#
# The live sync follows the current session by itself while LiveSyncState is
# Enabled with an empty SessionKey ('latest'). This script does not change it;
# check with `scripts/run-weekend.sh status`.
#
# Logs: .mxcli-obs/{backend,frontend}-supervisor.log and each app's
# .mxcli/runtime.log. The lake's sync and agent dashboards are at
# http://127.0.0.1:9495/.
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OBS="$ROOT/.mxcli-obs"
OTLP=http://127.0.0.1:4318
METRICS="Metrics.Registries=[{\"type\":\"opentelemetry\",\"settings\":{\"url\":\"$OTLP/v1/metrics\",\"step\":\"30s\"}}]"

supervisors() { ps -e -o pid=,args= | grep "[k]eep-app-running.sh $1" | awk '{print $1}'; }

if [ "${1:-}" = "stop" ]; then
  for app in Formula1Backend Formula1Frontend; do
    for pid in $(supervisors "$app"); do kill -TERM "$pid"; done
  done
  echo "supervisors stopped (they stop their apps); the lake keeps running: scripts/run-lake.sh stop"
  exit 0
fi

if [ "${1:-}" = "status" ]; then
  for app in Formula1Backend Formula1Frontend; do
    printf '%-17s supervisor %s\n' "$app" "$(supervisors "$app" | tr '\n' ' ' | sed 's/^$/not running/')"
  done
  for u in "backend http://127.0.0.1:8080/dist/index.js" "frontend http://127.0.0.1:8180/dist/index.js" "lake http://127.0.0.1:9495/api/otel"; do
    set -- $u; printf '%-9s %s\n' "$1" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$2")"
  done
  psql -h 127.0.0.1 -U postgres -d formula1backend -At -F ' | ' -c \
    'select enabled, sessionkey, runcount, lastrunat, left(lastresult, 70) from "formula1backend$livesyncstate"' 2>/dev/null \
    | sed 's/^/sync (enabled | session | runs | last run | result): /' || true
  curl -s -X POST http://127.0.0.1:9495/api/sql -H 'Authorization: Bearer duckgraphlake' --data-binary \
    "SELECT 'lake: ' || count(*) || ' OpenF1 events, last ' || CAST(max(warpstream.timestamp) AS VARCHAR) FROM main.local__openf1" \
    | python3 -I -c "import json,sys; d=json.load(sys.stdin); print(d['rows'][0][0] if d.get('rows') else d.get('error'))" 2>/dev/null || true
  exit 0
fi

mkdir -p "$OBS"
"$ROOT/scripts/run-lake.sh"

# One run per app: stop what is running now (a detached `mxcli run`, or an
# older supervisor) before the supervisors take over the ports.
"$0" stop >/dev/null 2>&1 || true
for app in Formula1Backend Formula1Frontend; do
  (cd "$ROOT/$app" && ./mxcli run stop -p "$app.mpr" >/dev/null 2>&1) || true
done
sleep 3

# The backend: real OpenF1, the lake for everything.
(cd "$ROOT" && OTEL_LOGS_EXPORTER=otlp POST_START="$ROOT/scripts/attach-otel-logs.sh 8090" \
  setsid nohup "$ROOT/scripts/keep-app-running.sh" Formula1Backend \
    http://127.0.0.1:8080/dist/index.js "$OBS/backend-supervisor.log" -- \
    --local -p Formula1Backend.mpr \
    --runtime-setting Kafka.BootstrapServers=127.0.0.1:9092 \
    --runtime-setting "$METRICS" \
    --trace-otlp "$OTLP" --trace-service Formula1Backend \
    >/dev/null 2>&1 &)

# The frontend: the chat keys when this machine has them (model/frontend/README.md).
keys=""
[ -s "$ROOT/Formula1Frontend/.mxcli/genai-text.key" ] && keys="$keys --constant Formula1Frontend.GenAIKey=@file:.mxcli/genai-text.key"
[ -s "$ROOT/Formula1Frontend/.mxcli/encryption.key" ] && keys="$keys --constant Encryption.EncryptionKey=@file:.mxcli/encryption.key"
# shellcheck disable=SC2086
(cd "$ROOT" && OTEL_LOGS_EXPORTER=otlp POST_START="$ROOT/scripts/attach-otel-logs.sh 8190" \
  setsid nohup "$ROOT/scripts/keep-app-running.sh" Formula1Frontend \
    http://127.0.0.1:8180/dist/index.js "$OBS/frontend-supervisor.log" -- \
    --local -p Formula1Frontend.mpr --app-port 8180 --admin-port 8190 --serve-port 6643 $keys \
    --runtime-setting Kafka.BootstrapServers=127.0.0.1:9092 \
    --runtime-setting "$METRICS" \
    --trace-otlp "$OTLP" --trace-service Formula1Frontend \
    >/dev/null 2>&1 &)

echo "supervisors started; the apps take a few minutes to build and boot."
echo "  status:  scripts/run-weekend.sh status"
echo "  logs:    $OBS/backend-supervisor.log, $OBS/frontend-supervisor.log"
