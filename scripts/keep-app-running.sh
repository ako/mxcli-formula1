#!/usr/bin/env bash
#
# Keep an mxcli app running across Mendix trial-license terminations.
#
# The local runtime uses a built-in developer licence with a maximum run time.
# Observed on this machine: the frontend died after 5h07m, the backend after
# 3h52m, both with
#
#   LicenseService: Maximum run time exceeded, framework is now terminating
#
# A race weekend needs the app alive for longer than that, and there is no way
# to extend the licence from mxcli. So the app gets restarted instead, which is
# safe because the live sync keeps all of its state in the database: LiveLap and
# friends are append-only and LiveSyncState.TelemetryCursor records how far the
# backfill has walked. A restart resumes; it does not repeat and it does not
# lose anything.
#
# Health is polled rather than waiting for mxcli to exit, because it does not
# exit. When its runtime child dies, `mxcli run --hub` spins every core at 100%
# and leaves the child unreaped -- 10 threads and eight hours of CPU on the run
# that prompted this script. So the supervisor kills the whole process group.
#
# Poll /dist/index.js, not /. The root path is served by the runtime itself and
# answers 200 with the SPA shell whether or not the app behind it works: a
# frontend whose web-client bundle had been stripped served a black page and a
# cheerful 200 for twenty minutes. /dist/index.js is the bundle that shell
# loads, so a 404 there is precisely the failure a visitor sees.
#
# Usage:
#   scripts/keep-app-running.sh <app-dir> <health-url> <log> -- <mxcli run args...>
#
# Example:
#   scripts/keep-app-running.sh Formula1Backend http://localhost:8080/ /tmp/be.log \
#     -- --local -p Formula1Backend.mpr --runtime-setting 'ScheduledEventExecution=ALL'
set -u

APP_DIR=${1:?app dir}; HEALTH_URL=${2:?health url}; LOG=${3:?log path}; shift 3
[ "${1:-}" = "--" ] && shift
ARGS=("$@")

BOOT_GRACE=${BOOT_GRACE:-150}   # seconds to allow for a cold build + boot
POLL=${POLL:-20}
FAIL_LIMIT=${FAIL_LIMIT:-3}     # consecutive failed polls before a restart

say() { printf '[supervisor %s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"; }

MXPID=""
start() {
  ( cd "$APP_DIR" && exec setsid ./mxcli run "${ARGS[@]}" ) >>"$LOG" 2>&1 &
  MXPID=$!
  say "started pid $MXPID: mxcli run ${ARGS[*]}"
}

stop() {
  [ -n "$MXPID" ] || return 0
  # Negative pid = the whole group, because mxcli leaves children behind.
  kill -TERM -"$MXPID" 2>/dev/null || kill -TERM "$MXPID" 2>/dev/null
  sleep 5
  kill -KILL -"$MXPID" 2>/dev/null || kill -KILL "$MXPID" 2>/dev/null
  wait "$MXPID" 2>/dev/null
  MXPID=""
}

trap 'say "supervisor stopping"; stop; exit 0' INT TERM

start
sleep "$BOOT_GRACE"

fails=0
while true; do
  sleep "$POLL"
  if curl -sf -o /dev/null --max-time 10 "$HEALTH_URL"; then
    fails=0
    continue
  fi
  fails=$((fails + 1))
  say "health check failed ($fails/$FAIL_LIMIT) on $HEALTH_URL"
  if [ "$fails" -ge "$FAIL_LIMIT" ]; then
    grep -q "Maximum run time exceeded" "$APP_DIR/.mxcli/runtime.log" 2>/dev/null \
      && say "runtime log shows the licence run-time limit"
    stop
    sleep 5
    start
    fails=0
    sleep "$BOOT_GRACE"
  fi
done
