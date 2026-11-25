#!/bin/sh
# Boot the backend wired to DuckGraphLake: CDC, metrics, traces and logs.
#
#   scripts/run-lake.sh                       # the lake first
#   scripts/run-backend-on-lake.sh            # backend against the real OpenF1
#   scripts/run-backend-on-lake.sh --mock     # backend against scripts/openf1-mock.py
#
# What each part sends, and where it lands in the lake:
#
#   Kafka.BootstrapServers   CDC of LiveSyncState (27-cdc-stream.mdl)
#                            -> formula1backend.livesyncstate, _history
#   Metrics.Registries       the metrics activities in Sync_Fetch / Sync_Live
#                            (f1.openf1.*, f1.sync.*) -> otel.metrics
#   --trace-otlp             runtime spans -> otel.spans
#   OTEL_LOGS_EXPORTER=otlp  plus an 'opentelemetry' log subscriber -> otel.logs
#
# Logs need both halves. mxcli sets OTEL_LOGS_EXPORTER=none unless it is already
# set, and even with the exporter on, the runtime only hands its log lines to
# OpenTelemetry through a log subscriber of type 'opentelemetry'. Studio Pro
# creates that from App Settings > Configuration > OpenTelemetry > Logs; mxcli
# has no flag for it, so this script creates it over the M2EE admin API once the
# app is up. It lasts until the runtime stops: `mxcli run restart` loses it, so
# re-run this script instead.
#
# --mock points OpenF1 (base and token URLs) at the local stand-in on :8099 and
# blanks the username, so no request and no credential leaves the machine. The
# overrides are for this run only and never written to the project.
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/Formula1Backend"
OTLP=http://127.0.0.1:4318
ADMIN_PORT=8090
ADMIN_PASS=${M2EE_ADMIN_PASS:-mxcli-local-dev}   # mxcli's default for --local

curl -sf -o /dev/null http://127.0.0.1:9495/api/otel || {
  echo "The lake is not running: start it with scripts/run-lake.sh" >&2
  exit 1
}

mock_args=""
if [ "$1" = "--mock" ]; then
  if ! curl -sf -o /dev/null "http://127.0.0.1:8099/v1/sessions"; then
    mkdir -p "$ROOT/.mxcli-obs"
    setsid nohup python3 -I "$ROOT/scripts/openf1-mock.py" --port 8099 \
      > "$ROOT/.mxcli-obs/openf1-mock.log" 2>&1 &
    sleep 2
  fi
  mock_args="--constant Formula1Backend.OpenF1BaseUrl=http://127.0.0.1:8099/v1
             --constant Formula1Backend.OpenF1TokenUrl=http://127.0.0.1:8099/token
             --constant Formula1Backend.OpenF1Username="
fi

cd "$APP"
./mxcli run stop -p Formula1Backend.mpr >/dev/null 2>&1 || true

# shellcheck disable=SC2086
OTEL_LOGS_EXPORTER=otlp ./mxcli run --local --detach -p Formula1Backend.mpr $mock_args \
  --runtime-setting Kafka.BootstrapServers=127.0.0.1:9092 \
  --runtime-setting "Metrics.Registries=[{\"type\":\"opentelemetry\",\"settings\":{\"url\":\"$OTLP/v1/metrics\",\"step\":\"30s\"}}]" \
  --trace-otlp "$OTLP" --trace-service Formula1Backend

auth=$(printf %s "$ADMIN_PASS" | base64)
resp=$(curl -s -X POST "http://127.0.0.1:$ADMIN_PORT/" \
  -H 'Content-Type: application/json' -H "X-M2EE-Authentication: $auth" \
  -d '{"action":"create_log_subscriber","params":{"type":"opentelemetry","name":"Lake","autosubscribe":"INFO"}}')
case "$resp" in
  *'"result":0'*) echo "logs: OpenTelemetry log subscriber attached" ;;
  *) echo "logs: could not attach the OpenTelemetry log subscriber: $resp" >&2 ;;
esac

echo "dashboard: http://127.0.0.1:9495/#dashboards"
