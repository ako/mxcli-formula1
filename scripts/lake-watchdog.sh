#!/bin/sh
# Keep the lake running through a race weekend, and record its memory.
#
#   setsid nohup scripts/lake-watchdog.sh > .mxcli-obs/lake-watchdog.log 2>&1 &
#
# Every 20 s: the lake's RSS, and its health URL. Two failed checks in a row
# restart it with scripts/run-lake.sh. On 27 Nov the lake was killed for memory
# twice without a word in its log (FINDINGS §125, §128); the apps have
# scripts/keep-app-running.sh, and this is the same for the lake. A lake that is
# killed at every start (a crash loop) is restarted every 40 s and logged each
# time, which is where to look.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fails=0
while true; do
  p=$(pgrep -x duckgraphlake | head -1)
  rss=$( [ -n "$p" ] && ps -o rss= -p "$p" | tr -d ' ' )
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:9495/api/otel)
  echo "$(date -u +%FT%TZ) rss_mb=$(( ${rss:-0} / 1024 )) health=$code"
  if [ "$code" = 200 ]; then fails=0; else fails=$((fails + 1)); fi
  if [ "$fails" -ge 2 ]; then
    echo "$(date -u +%FT%TZ) lake down, restarting"
    "$ROOT/scripts/run-lake.sh" stop >/dev/null 2>&1
    "$ROOT/scripts/run-lake.sh" 2>&1 | tail -1
    fails=0
  fi
  sleep 20
done
