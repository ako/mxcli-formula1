#!/usr/bin/env bash
#
# Archive one OpenF1 session as raw responses, for keeps.
#
# Two problems, one artefact.
#
# The capture lives in Postgres, and a `mxcli setup` that recreates the database
# takes a race weekend with it. Worse, what is stored is *derived* -- LiveLap is
# an ASOF join of five endpoints, LiveCarNow is a downsample -- so a dump of our
# tables cannot rebuild anything we did not already think to keep. The raw
# responses can.
#
# And a recording of the API is exactly what a mock service needs. OpenF1BaseUrl
# already says "override to point at a mirror or a recording", so a directory of
# these files plus a static file server is a complete stand-in for the live API:
# no rate limit, no live-session gate, no waiting for a race to develop against.
#
# Sessions are only fetchable as history from 30 minutes after they end, and
# only while OpenF1 keeps them. Run this the same day.
#
# Usage:  scripts/archive-session.sh <session_key> [outdir]
set -euo pipefail

KEY=${1:?session key}
OUT=${2:-data/openf1/$KEY}
BASE=${OPENF1_BASE:-https://api.openf1.org/v1}
mkdir -p "$OUT"

# Whole-session endpoints: one request, one file.
# `meetings` is keyed by meeting, not session, and `starting_grid` does not
# exist for every session type -- both are fetched separately below rather than
# 404ing in this loop.
WHOLE=(sessions drivers laps position intervals stints pit
       race_control team_radio weather overtakes session_result)

# car_data and location are hundreds of thousands of rows a session, so they are
# fetched in windows and stored as one file per window. The window bounds are
# part of the filename because the mock has to answer date-filtered requests
# from them.
WINDOW_MIN=${WINDOW_MIN:-5}

# Fetch one URL into a file, retrying a 429 rather than accepting it.
#
# The first version of this script treated "could not parse a row count" as
# "zero rows" and deleted the file. Running four sessions back to back tripped
# the rate limit, and the archive came out missing an entire location feed --
# 185,306 rows on the first run, silently nothing on the second. That is exactly
# the failure the live sync had (FINDINGS 58): an error swallowed, and a default
# that parses, are indistinguishable from an empty API.
#
# Prints the row count on success; returns non-zero and says why on failure.
fetch() {
  local url=$1 out=$2 tries=${3:-5} n=0 code delay=2
  while [ $n -lt "$tries" ]; do
    n=$((n+1))
    sleep "${PACE:-0.7}"          # 3 req/s unauthenticated; stay well under
    code=$(curl -sS --compressed --max-time 300 -H 'Accept: application/json' \
                -o "$out" -w '%{http_code}' "$url" || echo 000)
    case "$code" in
      200)
        if rows=$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(1) if not isinstance(d,list) else print(len(d))" "$out" 2>/dev/null); then
          echo "$rows"; return 0
        fi
        echo "  !! $url returned 200 with a non-list body" >&2; return 1 ;;
      404)
        rm -f "$out"; echo "404"; return 0 ;;   # a real "no rows here"
      429|500|502|503|504)
        echo "  .. HTTP $code on attempt $n, waiting ${delay}s" >&2
        sleep "$delay"; delay=$((delay*2)) ;;
      *)
        echo "  !! HTTP $code for $url" >&2; rm -f "$out"; return 1 ;;
    esac
  done
  echo "  !! gave up after $tries attempts: $url" >&2; rm -f "$out"; return 1
}

echo "archiving session $KEY -> $OUT"
FAILED=0
for ep in "${WHOLE[@]}"; do
  if n=$(fetch "$BASE/$ep?session_key=$KEY" "$OUT/$ep.json"); then
    printf '  %-16s %6s\n' "$ep" "$n"
  else
    printf '  %-16s FAILED\n' "$ep"; FAILED=$((FAILED+1))
  fi
done

# The meeting the session belongs to: circuit name, country, official name.
MEET=$(python3 -c "import json;print(json.load(open('$OUT/sessions.json'))[0]['meeting_key'])" 2>/dev/null || echo '')
if [ -n "$MEET" ]; then
  n=$(fetch "$BASE/meetings?meeting_key=$MEET" "$OUT/meetings.json") \
    && printf '  %-16s %6s\n' meetings "$n" || { printf '  %-16s FAILED\n' meetings; FAILED=$((FAILED+1)); }
fi

# Session bounds drive the telemetry windows.
read -r START END < <(python3 - "$OUT/sessions.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))[0]
print(s["date_start"][:19], s["date_end"][:19])
PY
)
echo "  session runs $START .. $END, windowing telemetry at ${WINDOW_MIN}min"

python3 - "$START" "$END" "$WINDOW_MIN" > "$OUT/.windows" <<'PY'
import sys,datetime
fmt="%Y-%m-%dT%H:%M:%S"
a=datetime.datetime.strptime(sys.argv[1],fmt); b=datetime.datetime.strptime(sys.argv[2],fmt)
step=datetime.timedelta(minutes=int(sys.argv[3]))
# half an hour of margin each side: cars circulate before the lights and after the flag
a-=datetime.timedelta(minutes=30); b+=datetime.timedelta(minutes=30)
while a<b:
    print(a.strftime(fmt), min(a+step,b).strftime(fmt)); a+=step
PY

for ep in car_data location; do
  mkdir -p "$OUT/$ep"
  total=0
  while read -r f t; do
    file="$OUT/$ep/${f//:/}_${t//:/}.json"
    if n=$(fetch "$BASE/$ep?session_key=$KEY&date%3E=$f&date%3C=$t" "$file"); then
      # 404 means the window genuinely holds nothing; drop the empty file.
      if [ "$n" = "404" ] || [ "$n" = "0" ]; then rm -f "$file"; else total=$((total+n)); fi
    else
      printf '  !! %s window %s FAILED\n' "$ep" "$f"; FAILED=$((FAILED+1))
    fi
  done < "$OUT/.windows"
  printf '  %-16s %6s rows in %s windows\n' "$ep" "$total" "$(ls "$OUT/$ep" 2>/dev/null | wc -l)"
done
rm -f "$OUT/.windows"

echo "  gzipping"
find "$OUT" -name '*.json' -exec gzip -9 -f {} +
printf '  archived: %s\n' "$(du -sh "$OUT" | cut -f1)"

if [ "$FAILED" -gt 0 ]; then
  echo "  INCOMPLETE: $FAILED request(s) failed -- re-run before trusting this archive" >&2
  exit 1
fi
