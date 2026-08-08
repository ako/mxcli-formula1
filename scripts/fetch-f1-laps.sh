#!/bin/sh
# Fetch lap-by-lap timings and write them as a CSV the backend reads with DuckDB
# like every other file.
#
# f1db has every session's *result* — practice, qualifying, the race, the
# fastest lap, every pit stop — but not a row per driver per lap. Ergast had
# that, and Ergast is gone (ergast.com now redirects). Jolpica-F1 continues it:
# same API shape, same driver ids, community-maintained. https://jolpi.ca
#
# This is the project's only network-fed dataset besides the Wikipedia
# summaries, so it is scoped rather than complete:
#
#   - Default is the single season in LAP_SEASONS. The API caps a page at 100
#     timings, so one race is ~12 requests and a 24-race season is ~290 — inside
#     Jolpica's 500/hour unauthenticated budget, two seasons would not be.
#   - Requests are spaced 0.3s apart, well under the 4/second burst limit.
#   - A 429 backs off and retries once, then that race is skipped rather than
#     hammering someone else's free service.
#
# Override the range: LAP_SEASONS="2023 2024" sh scripts/fetch-f1-laps.sh
#
# The file is ALWAYS written, even with no network — read_csv() needs something
# to open, and a header-only file yields an empty resource rather than a 500.
set -e

DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_DIR="$DIR/data/laps"
OUT="$OUT_DIR/f1db-laps.csv"
API="https://api.jolpi.ca/ergast/f1"
SEASONS="${LAP_SEASONS:-2024}"

mkdir -p "$OUT_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/raw.jsonl"

fetch_page() {
  # $1 season, $2 round, $3 offset — echoes the body, empty on failure.
  body=$(curl -sS --max-time 30 -H 'Accept: application/json' \
    -A 'mxcli-formula1/1.0 (sample app; https://github.com/ako/mxcli-formula1)' \
    -w '\n%{http_code}' "$API/$1/$2/laps.json?limit=100&offset=$3" 2>/dev/null || true)
  code=$(printf '%s' "$body" | tail -n1)
  payload=$(printf '%s' "$body" | sed '$d')
  if [ "$code" = "429" ]; then
    echo "  rate limited, backing off 60s ..." >&2
    sleep 60
    body=$(curl -sS --max-time 30 -H 'Accept: application/json' \
      -A 'mxcli-formula1/1.0 (sample app; https://github.com/ako/mxcli-formula1)' \
      -w '\n%{http_code}' "$API/$1/$2/laps.json?limit=100&offset=$3" 2>/dev/null || true)
    code=$(printf '%s' "$body" | tail -n1)
    payload=$(printf '%s' "$body" | sed '$d')
  fi
  [ "$code" = "200" ] && printf '%s' "$payload"
}

for season in $SEASONS; do
  echo "Season $season ..." >&2
  round=1
  while [ "$round" -le 30 ]; do
    first=$(fetch_page "$season" "$round" 0)
    [ -n "$first" ] || { round=$((round + 1)); continue; }

    total=$(printf '%s' "$first" | python3 -c \
      'import json,sys; d=json.load(sys.stdin)["MRData"]; print(d["total"] if d["RaceTable"]["Races"] else 0)' \
      2>/dev/null || echo 0)
    [ "$total" -gt 0 ] || { round=$((round + 1)); continue; }

    printf '%s\t%s\t%s\n' "$season" "$round" "$first" >> "$TMP/raw.jsonl"
    offset=100
    while [ "$offset" -lt "$total" ]; do
      sleep 0.3
      page=$(fetch_page "$season" "$round" "$offset")
      [ -n "$page" ] || break
      printf '%s\t%s\t%s\n' "$season" "$round" "$page" >> "$TMP/raw.jsonl"
      offset=$((offset + 100))
    done
    echo "  round $round: $total timings" >&2
    round=$((round + 1))
    sleep 0.3
  done
done

python3 - "$TMP/raw.jsonl" "$OUT" <<'PY'
import csv, json, pathlib, sys

src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

def millis(t):
    """'1:37.284' -> 97284. Ergast never emits hours in a lap time."""
    try:
        mins, _, rest = t.partition(":")
        return int(round((int(mins) * 60 + float(rest)) * 1000))
    except (ValueError, AttributeError):
        return ""

rows = []
if src.exists():
    for line in src.read_text(encoding="utf-8").splitlines():
        try:
            season, rnd, body = line.split("\t", 2)
            races = json.loads(body)["MRData"]["RaceTable"]["Races"]
        except (ValueError, KeyError):
            continue
        for race in races:
            for lap in race.get("Laps", []):
                for t in lap.get("Timings", []):
                    rows.append({
                        "year": season,
                        "round": rnd,
                        "lap": lap["number"],
                        "driverRef": t["driverId"],
                        "position": t["position"],
                        "time": t["time"],
                        "timeMillis": millis(t["time"]),
                    })

out.parent.mkdir(parents=True, exist_ok=True)
with out.open("w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, ["year", "round", "lap", "driverRef", "position", "time",
                           "timeMillis"], quoting=csv.QUOTE_ALL)
    w.writeheader()
    w.writerows(rows)
print(f"{len(rows)} lap timings written", file=sys.stderr)
PY

echo "Lap timings written to $OUT ($(($(wc -l < "$OUT") - 1)) rows)."
