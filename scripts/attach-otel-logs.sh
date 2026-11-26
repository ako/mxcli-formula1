#!/bin/sh
# Attach an OpenTelemetry log subscriber to a running Mendix runtime, so its log
# lines reach the OTLP endpoint (the lake) -- see FINDINGS §105 for why mxcli's
# --trace-otlp alone is not enough.
#
#   scripts/attach-otel-logs.sh <admin-port>      # 8090 backend, 8190 frontend
#
# The runtime also needs OTEL_LOGS_EXPORTER=otlp in its environment. The
# subscriber lives until the runtime stops, so it is attached again after every
# start (keep-app-running.sh's POST_START does that).
set -e
PORT=${1:?admin port}
PASS=${M2EE_ADMIN_PASS:-mxcli-local-dev}   # mxcli's default for --local
auth=$(printf %s "$PASS" | base64)
resp=$(curl -s -X POST "http://127.0.0.1:$PORT/" \
  -H 'Content-Type: application/json' -H "X-M2EE-Authentication: $auth" \
  -d '{"action":"create_log_subscriber","params":{"type":"opentelemetry","name":"Lake","autosubscribe":"INFO"}}')
case "$resp" in
  *'"result":0'*) echo "logs: OpenTelemetry log subscriber attached on :$PORT" ;;
  *) echo "logs: could not attach the subscriber on :$PORT: $resp" >&2; exit 1 ;;
esac
