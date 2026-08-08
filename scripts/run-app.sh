#!/bin/sh
# Boot an app and make sure the browser client survives the boot.
#
# `mxcli run --local` bundles the web client (deployment/web/dist) after the
# model build and before starting the runtime — deliberately, because without it
# the app 404s on /dist/index.js and renders a blank page. But the runtime boot
# then runs a Gradle `clean-custom-classes compile package` pass, and that
# repopulates deployment/web *without* dist/. The bundle is deleted a minute
# after it was written, mxcli reports success, and every page is black.
#
# It only bites when Gradle actually has work to do — adding a Java action is
# enough — which is why the app booted fine for most of this project's life and
# then stopped.
#
# So: start the app, wait for it to answer, and re-run mxcli's own bundler
# (mxbuild's bundled node + rollup-runner.mjs, the exact command from
# cmd/mxcli/docker/webclient.go) against the deployment directory. ~30s.
#
#   sh scripts/run-app.sh Formula1Backend
#   sh scripts/run-app.sh Formula1Frontend -- --app-port 8180 --admin-port 8190 \
#       --serve-port 6643
#
# Everything after `--` is passed through to `mxcli run`. FINDINGS §35.
set -e

DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP="${1:?usage: run-app.sh <AppFolder> [-- <extra mxcli run args>]}"
shift
[ "${1:-}" = "--" ] && shift

APP_DIR="$DIR/$APP"
DEPLOY="$APP_DIR/deployment"
[ -d "$APP_DIR" ] || { echo "No such app: $APP_DIR" >&2; exit 1; }

PORT=8080
case " $* " in *" --app-port "*) PORT=$(echo " $* " | sed 's/.*--app-port \([0-9]*\).*/\1/');; esac

echo "Starting $APP on :$PORT ..."
cd "$APP_DIR"
"$DIR/mxcli" run --local -p "$APP.mpr" "$@" &
RUN_PID=$!

# Wait for the runtime, which is also what tells us Gradle has finished with
# deployment/web.
i=0
while [ $i -lt 60 ]; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORT/" 2>/dev/null || true)
  [ "$code" = "200" ] && break
  kill -0 "$RUN_PID" 2>/dev/null || { echo "mxcli exited before the app came up." >&2; wait "$RUN_PID"; exit 1; }
  i=$((i + 1))
  sleep 5
done
[ "$code" = "200" ] || { echo "App did not answer on :$PORT" >&2; exit 1; }

if [ -f "$DEPLOY/web/dist/index.js" ]; then
  echo "Web client bundle intact — nothing to redo."
else
  echo "Web client bundle was wiped by the boot; rebuilding it ..."
  MODELER=$(dirname "$(find "$HOME/.mxcli/mxbuild" -name mxbuild -type f 2>/dev/null | head -1)")
  NODE=$(find "$MODELER/tools/node" -name node -type f 2>/dev/null | head -1)
  RUNNER="$MODELER/tools/node/rollup-runner.mjs"
  if [ -z "$NODE" ] || [ ! -f "$RUNNER" ]; then
    echo "  Cannot find mxbuild's bundled node/rollup runner; the app will render blank." >&2
  else
    ( cd "$DEPLOY/web" && NODE_ENV=production \
        MX_WEB_CLIENT_BUILD_LOG="$DEPLOY/log/web-client-build.log" \
        "$NODE" "$RUNNER" >/dev/null 2>&1 ) \
      && echo "  Rebuilt $DEPLOY/web/dist" \
      || echo "  Bundle rebuild failed; see $DEPLOY/log/web-client-build.log" >&2
  fi
fi

echo "$APP is up on http://127.0.0.1:$PORT/ (mxcli pid $RUN_PID)"
wait "$RUN_PID"
