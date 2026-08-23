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
# A local poll cannot see a dead tunnel, though, and that is a real failure:
# `mxcli run --hub` publishes the app through hub.mxcli.org, and after an
# abnormal websocket close the hub kept the remote port bound to the session
# that had just died --
#
#   client: Connection error: websocket: close 1006 (abnormal closure)
#   client: Connection error: server: Server cannot listen on R:9001=>8180
#
# -- and retried, forever, thirty seconds apart. The runtime was healthy the
# whole time and localhost:8180 answered 200, so the supervisor had nothing to
# act on while the app was unreachable to anyone outside this machine. The hub
# answers its own login redirect for every path whether or not a tunnel is
# behind it, so it cannot be polled from outside either. The signal that exists
# is the client's own log line, so FAIL_PATTERN watches for it.
#
#   FAIL_PATTERN='cannot listen' scripts/keep-app-running.sh ...
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
FAIL_PATTERN=${FAIL_PATTERN:-}  # if this appears in recent log output, restart
FAIL_TAIL=${FAIL_TAIL:-40}      # how much of the log counts as "recent"

say() { printf '[supervisor %s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"; }

# Only what the current run has written.
#
# FAIL_PATTERN scans for a failure the local poll cannot see, and the log is
# append-only across restarts -- so scanning its tail unscoped would find the
# error that caused the *previous* restart and restart again immediately,
# forever. `started pid` is the line start() writes, so everything after the
# last one is this run and nothing else.
this_run() {
  local from
  from=$(awk '/\] started pid /{n=NR} END{print n+1}' "$LOG" 2>/dev/null)
  [ -n "$from" ] && tail -n "+$from" "$LOG" 2>/dev/null | tail -n "$FAIL_TAIL"
}

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
  reason=""
  if ! curl -sf -o /dev/null --max-time 10 "$HEALTH_URL"; then
    reason="no answer on $HEALTH_URL"
  elif [ -n "$FAIL_PATTERN" ] && this_run | grep -q -- "$FAIL_PATTERN"; then
    reason="log shows '$FAIL_PATTERN'"
  fi

  if [ -z "$reason" ]; then
    fails=0
    continue
  fi
  fails=$((fails + 1))
  say "health check failed ($fails/$FAIL_LIMIT): $reason"
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
