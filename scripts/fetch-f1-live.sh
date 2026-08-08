#!/bin/sh
# Snapshot one session's running order from OpenF1 into CSVs the backend reads
# with DuckDB like every other file.
#
# OpenF1 (https://openf1.org) is an unofficial, free, key-less API carrying what
# f1db and Jolpica do not: live timing. Per-lap sector times and speed traps,
# position changes, gap to leader and to the car ahead, tyre stints, pit stops,
# race-control messages, weather. It documents a ~3 second delay during a live
# session, so this is near-live rather than live.
#
#   SESSION=latest sh scripts/fetch-f1-live.sh   # the running/most recent session
#   SESSION=11342  sh scripts/fetch-f1-live.sh   # a specific session_key
#
# Default is the most recent completed race, so the page has real data outside a
# race weekend. Re-run it to refresh; on a live Sunday, run it on a timer.
#
# One trap worth knowing: OpenF1 404s the whole request if you pass `limit`.
# Filter with session_key/driver_number instead — every call here does.
#
# Files are ALWAYS written, even with no network: read_csv() needs something to
# open, and header-only files yield empty resources rather than a 500.
set -e

DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$DIR/data/live"
API="https://api.openf1.org/v1"
SESSION="${SESSION:-}"

mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

get() { # $1 endpoint+query -> body on stdout, empty on failure
  curl -sS --max-time 45 -H 'Accept: application/json' \
    -A 'mxcli-formula1/1.0 (sample app; https://github.com/ako/mxcli-formula1)' \
    "$API/$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Pick the session. "latest" is OpenF1's own alias and is what a live page uses;
# with nothing set, take the most recent race that has already started.
# ---------------------------------------------------------------------------
if [ -z "$SESSION" ]; then
  YEAR=$(date -u +%Y)
  SESSION=$(get "sessions?year=$YEAR&session_type=Race" | python3 -c '
import json, sys, datetime
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
past = [s for s in rows if s.get("date_start", "") < now]
print(past[-1]["session_key"] if past else "")' 2>/dev/null || true)
fi
[ -n "$SESSION" ] || { echo "No session to snapshot (no network, or none started yet)." >&2; SESSION=none; }
echo "Snapshotting session $SESSION ..." >&2

for ep in sessions drivers position intervals laps stints pit race_control weather; do
  case "$ep" in
    sessions) q="sessions?session_key=$SESSION" ;;
    *)        q="$ep?session_key=$SESSION" ;;
  esac
  get "$q" > "$TMP/$ep.json" 2>/dev/null || echo '[]' > "$TMP/$ep.json"
  [ -s "$TMP/$ep.json" ] || echo '[]' > "$TMP/$ep.json"
done

python3 - "$TMP" "$OUT" "$SESSION" <<'PY'
import csv, json, pathlib, sys

tmp, out, session = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]

def load(name):
    try:
        rows = json.loads((tmp / f"{name}.json").read_text(encoding="utf-8"))
        return rows if isinstance(rows, list) else []
    except Exception:
        return []

def newest(rows, key="driver_number", stamp="date"):
    """OpenF1 returns a time series; a running order wants the last sample per car."""
    best = {}
    for r in rows:
        k = r.get(key)
        if k is None:
            continue
        if k not in best or (r.get(stamp) or "") >= (best[k].get(stamp) or ""):
            best[k] = r
    return best

drivers   = {d["driver_number"]: d for d in load("drivers") if d.get("driver_number")}
positions = newest(load("position"))
intervals = newest(load("intervals"))
laps_all  = load("laps")
stints    = load("stints")
pits      = load("pit")

last_lap = newest(laps_all, stamp="lap_number")
lap_count = {}
for l in laps_all:
    n = l.get("driver_number")
    lap_count[n] = max(lap_count.get(n, 0), l.get("lap_number") or 0)

stint_now = {}
for s in stints:
    n = s.get("driver_number")
    if n not in stint_now or (s.get("stint_number") or 0) >= (stint_now[n].get("stint_number") or 0):
        stint_now[n] = s

pit_count = {}
for p in pits:
    n = p.get("driver_number")
    pit_count[n] = pit_count.get(n, 0) + 1

order = []
for num, d in drivers.items():
    pos = positions.get(num, {})
    itv = intervals.get(num, {})
    lap = last_lap.get(num, {})
    st  = stint_now.get(num, {})
    order.append({
        "sessionKey": session,
        "driverNumber": num,
        "code": d.get("name_acronym") or "",
        "driverName": d.get("full_name") or "",
        "team": d.get("team_name") or "",
        "teamColour": ("#" + d["team_colour"]) if d.get("team_colour") else "",
        "position": pos.get("position") or "",
        "gapToLeader": itv.get("gap_to_leader") if itv.get("gap_to_leader") is not None else "",
        "interval": itv.get("interval") if itv.get("interval") is not None else "",
        "lapNumber": lap_count.get(num, "") or "",
        "lastLapSeconds": lap.get("lap_duration") if lap.get("lap_duration") is not None else "",
        "sector1": lap.get("duration_sector_1") if lap.get("duration_sector_1") is not None else "",
        "sector2": lap.get("duration_sector_2") if lap.get("duration_sector_2") is not None else "",
        "sector3": lap.get("duration_sector_3") if lap.get("duration_sector_3") is not None else "",
        "speedTrap": lap.get("i2_speed") if lap.get("i2_speed") is not None else "",
        "compound": st.get("compound") or "",
        "tyreAge": st.get("tyre_age_at_start") if st.get("tyre_age_at_start") is not None else "",
        "pitStops": pit_count.get(num, 0),
    })
order.sort(key=lambda r: (r["position"] == "", r["position"] or 999))

def write(name, fields, rows):
    with (out / name).open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fields, quoting=csv.QUOTE_ALL, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    print(f"  {name}: {len(rows)} rows", file=sys.stderr)

write("live-order.csv",
      ["sessionKey", "driverNumber", "code", "driverName", "team", "teamColour",
       "position", "gapToLeader", "interval", "lapNumber", "lastLapSeconds",
       "sector1", "sector2", "sector3", "speedTrap", "compound", "tyreAge",
       "pitStops"], order)

msgs = [{"sessionKey": session, "at": (m.get("date") or "")[11:19], "category": m.get("category") or "",
         "flag": m.get("flag") or "", "scope": m.get("scope") or "",
         "lap": m.get("lap_number") if m.get("lap_number") is not None else "",
         "message": m.get("message") or ""}
        for m in load("race_control")]
msgs.reverse()
write("live-messages.csv",
      ["sessionKey", "at", "category", "flag", "scope", "lap", "message"], msgs)

w_rows = load("weather")
w_last = w_rows[-1] if w_rows else {}
write("live-weather.csv",
      ["sessionKey", "at", "airTemperature", "trackTemperature", "humidity",
       "rainfall", "windSpeed"],
      [{"sessionKey": session, "at": (w_last.get("date") or "")[11:19],
        "airTemperature": w_last.get("air_temperature", ""),
        "trackTemperature": w_last.get("track_temperature", ""),
        "humidity": w_last.get("humidity", ""),
        "rainfall": w_last.get("rainfall", ""),
        "windSpeed": w_last.get("wind_speed", "")}] if w_last else [])

s_rows = load("sessions")
s = s_rows[0] if s_rows else {}
write("live-session.csv",
      ["sessionKey", "sessionName", "sessionType", "location", "countryName",
       "circuitName", "dateStart", "year", "driverCount", "leadLap", "fetchedAt"],
      [{"sessionKey": session,
        "sessionName": s.get("session_name", ""), "sessionType": s.get("session_type", ""),
        "location": s.get("location", ""), "countryName": s.get("country_name", ""),
        "circuitName": s.get("circuit_short_name", ""),
        "dateStart": s.get("date_start", ""), "year": s.get("year", ""),
        "driverCount": len(order),
        "leadLap": max([r["lapNumber"] for r in order if r["lapNumber"]] or [0]),
        "fetchedAt": __import__("datetime").datetime.now(
            __import__("datetime").timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")}])
PY

echo "Live snapshot written to $OUT."
