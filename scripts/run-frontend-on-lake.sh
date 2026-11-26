#!/bin/sh
# Boot the frontend wired to DuckGraphLake: the chat agent's traces by CDC,
# and the runtime's OpenTelemetry traces, metrics and logs.
#
#   scripts/run-lake.sh                     # the lake first
#   scripts/run-frontend-on-lake.sh
#
# What each part sends, and where it lands in the lake:
#
#   Kafka.BootstrapServers   CDC of GenAI Commons' agent traces (17-agent-traces.mdl)
#                            -> formula1frontend.agenttrace, .span, .modelspan, .toolspan
#   Metrics.Registries       the runtime's metrics -> otel.metrics
#   --trace-otlp             runtime spans: microflows, the agent's Java actions,
#                            its HTTP calls to the model and to the lake's MCP
#                            -> otel.spans
#   OTEL_LOGS_EXPORTER=otlp  plus an 'opentelemetry' log subscriber -> otel.logs
#
# The chat agent (18-chat-agent.mdl) needs .mxcli/genai-text.key and
# .mxcli/encryption.key in Formula1Frontend/ (see model/frontend/README.md);
# without them the app starts and the chat answers "Error". Open the chat at
# http://localhost:8180/p/ask, not frontend.local (FINDINGS §109).
#
# Logs need the subscriber created over M2EE after boot, as in
# run-backend-on-lake.sh; `mxcli run restart` loses it, so re-run this script.
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/Formula1Frontend"
OTLP=http://127.0.0.1:4318
ADMIN_PORT=8190
ADMIN_PASS=${M2EE_ADMIN_PASS:-mxcli-local-dev}   # mxcli's default for --local

curl -sf -o /dev/null http://127.0.0.1:9495/api/otel || {
  echo "The lake is not running: start it with scripts/run-lake.sh" >&2
  exit 1
}

cd "$APP"
keys=""
[ -s .mxcli/genai-text.key ] && keys="$keys --constant Formula1Frontend.GenAIKey=@file:.mxcli/genai-text.key"
[ -s .mxcli/encryption.key ] && keys="$keys --constant Encryption.EncryptionKey=@file:.mxcli/encryption.key"
[ -z "$keys" ] && echo "note: no .mxcli/genai-text.key or encryption.key; the chat will not answer" >&2

./mxcli run stop -p Formula1Frontend.mpr >/dev/null 2>&1 || true

# shellcheck disable=SC2086
OTEL_LOGS_EXPORTER=otlp ./mxcli run --local --detach -p Formula1Frontend.mpr \
  --app-port 8180 --admin-port $ADMIN_PORT --serve-port 6643 $keys \
  --runtime-setting Kafka.BootstrapServers=127.0.0.1:9092 \
  --runtime-setting "Metrics.Registries=[{\"type\":\"opentelemetry\",\"settings\":{\"url\":\"$OTLP/v1/metrics\",\"step\":\"30s\"}}]" \
  --trace-otlp "$OTLP" --trace-service Formula1Frontend

auth=$(printf %s "$ADMIN_PASS" | base64)
resp=$(curl -s -X POST "http://127.0.0.1:$ADMIN_PORT/" \
  -H 'Content-Type: application/json' -H "X-M2EE-Authentication: $auth" \
  -d '{"action":"create_log_subscriber","params":{"type":"opentelemetry","name":"Lake","autosubscribe":"INFO"}}')
case "$resp" in
  *'"result":0'*) echo "logs: OpenTelemetry log subscriber attached" ;;
  *) echo "logs: could not attach the OpenTelemetry log subscriber: $resp" >&2 ;;
esac

echo "chat: http://localhost:8180/p/ask    lake: http://127.0.0.1:9495/"
