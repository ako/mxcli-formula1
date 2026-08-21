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
# Two traps worth knowing.
#
# OpenF1 404s the whole request if you pass `limit`. Filter with
# session_key/driver_number instead — every call here does.
#
# And free access is switched off *while a session is running*: every endpoint,
# past sessions included, answers 401 with "Live F1 session in progress. Global
# API access ... is restricted to authenticated users until the session ends."
# So the one moment a live page most wants a refresh is the one moment an
# unauthenticated fetch cannot get one.
#
# With an OpenF1 account it can. Authentication is OAuth2's *password* grant and
# nothing more: form-POST a username and password to /token, get a bearer token
# good for an hour, send it as Authorization: Bearer. There is no authorize
# endpoint, no redirect and no consent screen, so there is no login page to
# build -- credentials come from the environment, the way the hub key does:
#
#   export OPENF1_USERNAME='...'
#   export OPENF1_PASSWORD='...'      # or OPENF1_TOKEN=<token> to skip the grant
#   sh scripts/fetch-f1-live.sh
#
# The token is cached in $HOME/.mxcli/openf1-token (mode 600) with its expiry, so
# a fetch on a timer re-uses one token rather than re-sending the password every
# run. Nothing is written into the repo, and the password is never passed on a
# command line where `ps` would show it.
#
# Without credentials the script behaves as before: it says what happened, keeps
# the snapshot it already had, and leaves the page showing the timestamp of the
# last fetch that succeeded.
#
# A file is always PRESENT, even with no network: read_csv() needs something to
# open, and a header-only file yields an empty resource rather than a 500. It is
# not always REWRITTEN -- a fetch that returns no rows leaves an existing
# snapshot in place rather than blanking it, because the usual reason for an
# empty result is a rate limit or a dropped connection, not an empty session.
#
# Six files come out. Four are the snapshot -- session, order, weather,
# messages. The other two are the history behind it: live-trace.csv carries one
# row per driver per lap with position and gap to leader, and live-stints.csv
# every stint rather than only the one running. OpenF1 returns every endpoint
# as a time series, so the history is already in hand; the snapshot is just its
# last sample.
set -e

DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$DIR/data/live"
API="https://api.openf1.org/v1"
TOKEN_URL="https://api.openf1.org/token"
UA='mxcli-formula1/1.0 (sample app; https://github.com/ako/mxcli-formula1)' 
SESSION="${SESSION:-}"

mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# The token.
#
# OAuth2 password grant: username and password in a form body, a bearer token
# back, an hour of validity, no refresh token. Re-authenticating every run would
# work and would also mean sending the password sixty times an hour on a race
# Sunday, so the token is cached with its expiry and only re-minted when it has
# actually run out.
#
# An hour is shorter than a Grand Prix. A race is ninety minutes of running plus
# the formation lap, and a red flag can push it past three hours, so a token
# minted at lights-out expires somewhere around lap 50. Two things cover that:
#
#   between runs -- every invocation re-reads the cached token, and mints a new
#   one the moment the old is inside FRESH_SLACK of expiry. On a timer that is
#   the whole answer: the run that straddles the hour mark just pays for one
#   extra round trip;
#
#   within a run -- the slack cannot cover a run that outlives it, so a 401 in
#   the middle of a fetch re-mints once and retries that request. Without this
#   the failure is silent rather than loud: every remaining endpoint returns
#   nothing, the write guard below keeps the previous snapshot, and the page
#   shows a stale timestamp with no error anywhere to explain it.
#
# --data-urlencode keeps the credentials out of the URL and out of the process
# table; curl reads them from the argument list of this function, not from a
# shell expansion that ps could show mid-request.
# ---------------------------------------------------------------------------
TOKEN_FILE="${OPENF1_TOKEN_FILE:-$HOME/.mxcli/openf1-token}"
TOKEN=""
REAUTHED=0

# How much life a cached token must have left to be worth starting a fetch with.
# One full run is nine endpoints plus a per-driver car_data pass, and every one
# of them can retry through a 429 backoff, so the worst case is minutes rather
# than seconds. Five covers it; a token with less left is replaced up front,
# which is cheaper than discovering it half way down the list.
FRESH_SLACK="${OPENF1_FRESH_SLACK:-300}"

now_epoch() { date -u +%s; }

have_credentials() {
  [ -n "$OPENF1_USERNAME" ] && [ -n "$OPENF1_PASSWORD" ]
}

load_cached_token() {
  [ -r "$TOKEN_FILE" ] || return 1
  _exp=$(sed -n '1p' "$TOKEN_FILE" 2>/dev/null)
  _tok=$(sed -n '2p' "$TOKEN_FILE" 2>/dev/null)
  [ -n "$_exp" ] && [ -n "$_tok" ] || return 1
  [ "$_exp" -gt "$(( $(now_epoch) + FRESH_SLACK ))" ] 2>/dev/null || return 1
  TOKEN="$_tok"
  return 0
}

mint_token() {
  have_credentials || return 1
  echo "Authenticating to OpenF1 as $OPENF1_USERNAME ..." >&2
  _body=$(curl -sS --max-time 30 -X POST "$TOKEN_URL" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -A "$UA" \
    --data-urlencode "username=$OPENF1_USERNAME" \
    --data-urlencode "password=$OPENF1_PASSWORD" 2>/dev/null || true)
  TOKEN=$(printf '%s' "$_body" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("access_token", ""))
except Exception:
    print("")' 2>/dev/null)
  if [ -z "$TOKEN" ]; then
    echo "  could not obtain a token; continuing unauthenticated" >&2
    return 1
  fi
  _ttl=$(printf '%s' "$_body" | python3 -c '
import json, sys
try:
    print(int(json.load(sys.stdin).get("expires_in", 3600)))
except Exception:
    print(3600)' 2>/dev/null)
  # Written to a neighbouring temp file and moved into place, because a timer
  # can have two runs overlapping and a half-written token file is a token that
  # fails for both of them. rename(2) within a directory is atomic.
  mkdir -p "$(dirname "$TOKEN_FILE")"
  ( umask 077; printf '%s\n%s\n' "$(( $(now_epoch) + _ttl ))" "$TOKEN" > "$TOKEN_FILE.$$" )
  chmod 600 "$TOKEN_FILE.$$" 2>/dev/null || true
  mv -f "$TOKEN_FILE.$$" "$TOKEN_FILE"
  echo "  token good for $(( _ttl / 60 )) minutes" >&2
  return 0
}

# OPENF1_TOKEN is a starting value, not a ceiling: it is used as given, and if
# it expires mid-race the 401 path above renews it from credentials when there
# are any. Set it alone and the fetch simply stops working after an hour, which
# the message there says out loud rather than leaving to be discovered.
if [ -n "$OPENF1_TOKEN" ]; then
  TOKEN="$OPENF1_TOKEN"
elif ! load_cached_token; then
  mint_token || true
fi

# OpenF1 rate-limits, and does it per burst rather than per hour: fetching the
# nine endpoints back to back reliably earns a 429 partway down the list. A 429
# body is JSON too, so it lands in the output file and parses to nothing --
# which is how a snapshot ends up with a running order and no weather. Retry
# with a widening pause and the whole set comes back.
get() { # $1 endpoint+query -> body on stdout, empty on failure
  _try=1
  while [ "$_try" -le 5 ]; do
    if [ -n "$TOKEN" ]; then
      _code=$(curl -sS --max-time 45 -H 'Accept: application/json' \
        -H "Authorization: Bearer $TOKEN" -A "$UA" \
        -o "$TMP/.get.body" -w '%{http_code}' "$API/$1" 2>/dev/null || echo 000)
    else
      _code=$(curl -sS --max-time 45 -H 'Accept: application/json' -A "$UA" \
        -o "$TMP/.get.body" -w '%{http_code}' "$API/$1" 2>/dev/null || echo 000)
    fi
    case "$_code" in
      200) cat "$TMP/.get.body"; return 0 ;;
      401)
           # The token ran out mid-race, or was never good enough. Re-mint once
           # and try this request again; REAUTHED is global rather than local to
           # the call so one refresh serves every endpoint that follows, and so a
           # genuinely rejected account cannot spin.
           if [ "$REAUTHED" -eq 0 ] && have_credentials; then
             REAUTHED=1
             echo "  token rejected mid-fetch; re-authenticating" >&2
             if mint_token; then
               continue
             fi
           fi
           [ -n "$_warned401" ] || {
             echo "  OpenF1 returned 401: $(sed -n 's/.*\"detail\":\"\([^\"]*\)\".*/\1/p' "$TMP/.get.body")" >&2
             if [ "$REAUTHED" -eq 1 ] && [ -z "$TOKEN" ]; then
               echo "  re-authentication failed -- check OPENF1_USERNAME and OPENF1_PASSWORD" >&2
             elif have_credentials; then
               echo "  the token was accepted but the account may not cover live access" >&2
             elif [ -n "$TOKEN" ]; then
               echo "  OPENF1_TOKEN has expired and there are no credentials to renew it;" >&2
               echo "  set OPENF1_USERNAME and OPENF1_PASSWORD so a long session can refresh" >&2
             else
               echo "  set OPENF1_USERNAME and OPENF1_PASSWORD to authenticate" >&2
             fi
             _warned401=1
           }
           return 0 ;;
      429|5*) sleep "$_try"; _try=$((_try + 1)) ;;
      *) return 0 ;;   # 404 and friends: the caller falls back to an empty list
    esac
  done
  echo "  giving up on $1 after $((_try - 1)) attempts (HTTP $_code)" >&2
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
  # No 2>/dev/null here. Every curl inside get() already silences its own
  # stderr, so the only thing that reaches this call site is a message get()
  # meant to be read -- a 401, a re-authentication, a mirror it gave up on.
  # Discarding it hid the whole auth path: the token refresh worked and said so,
  # into /dev/null.
  get "$q" > "$TMP/$ep.json" || echo '[]' > "$TMP/$ep.json"
  [ -s "$TMP/$ep.json" ] || echo '[]' > "$TMP/$ep.json"
  sleep 1
done

# ---------------------------------------------------------------------------
# DRS lives in car_data, which is telemetry at roughly 3.7 Hz per car -- a whole
# session of it for twenty cars is far more than this page needs. Ask only for
# the window since the last lap started, one request per driver, and keep the
# newest sample. `date>=` is the only way to bound a response here: `limit`
# 404s the request, as the note at the top says.
#
# OpenF1 carries the drs column but does not always fill it -- for session
# 11342 every other telemetry field is populated and drs is null throughout.
# So probe one car first and skip the other nineteen requests when the answer
# is empty, rather than spending twenty round trips to learn the same thing.
# ---------------------------------------------------------------------------
CAR_FLOOR=$(python3 -c '
import json, sys
try:
    rows = json.load(open(sys.argv[1]))
except Exception:
    rows = []
starts = [r.get("date_start") for r in rows if r.get("date_start")]
print(max(starts) if starts else "")' "$TMP/laps.json" 2>/dev/null || true)

CAR_NUMS=$(python3 -c '
import json, sys
try:
    rows = json.load(open(sys.argv[1]))
except Exception:
    rows = []
print(" ".join(str(d["driver_number"]) for d in rows if d.get("driver_number")))' \
  "$TMP/drivers.json" 2>/dev/null || true)

has_drs() { # $1 car_data file -> 0 when at least one sample carries a drs value
  python3 -c '
import json, sys
try:
    rows = json.load(open(sys.argv[1]))
except Exception:
    rows = []
sys.exit(0 if any(r.get("drs") is not None for r in rows) else 1)' "$1" 2>/dev/null
}

if [ -n "$CAR_FLOOR" ] && [ -n "$CAR_NUMS" ]; then
  probed=0
  for num in $CAR_NUMS; do
    get "car_data?session_key=$SESSION&driver_number=$num&date>=$CAR_FLOOR" \
      > "$TMP/car_$num.json" || true
    [ -s "$TMP/car_$num.json" ] || echo '[]' > "$TMP/car_$num.json"
    if [ "$probed" -eq 0 ]; then
      probed=1
      if ! has_drs "$TMP/car_$num.json"; then
        echo "  car_data carries no drs for this session; skipping the rest" >&2
        break
      fi
    fi
    sleep 1
  done
fi

python3 - "$TMP" "$OUT" "$SESSION" <<'PY'
import bisect, csv, datetime, json, pathlib, sys

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

# DRS: newest telemetry sample per car, in the narrow window fetched above.
# OpenF1 encodes it as a small integer; 8 means the car is inside a second of
# the one ahead at a detection point, 10/12/14 that the flap is actually open.
drs_now = {}
for num in drivers:
    try:
        rows = json.loads((tmp / f"car_{num}.json").read_text(encoding="utf-8"))
    except Exception:
        continue
    if not isinstance(rows, list) or not rows:
        continue
    latest = max(rows, key=lambda r: r.get("date") or "")
    code = latest.get("drs")
    drs_now[num] = "on" if code in (10, 12, 14) else "eligible" if code == 8 else ""

# Sector marks. Purple is the best anyone has set this session, green the best
# this driver has set -- the convention the timing screens use, so the page can
# colour a sector without knowing what the numbers mean.
SECTORS = ("duration_sector_1", "duration_sector_2", "duration_sector_3")
session_best = {}
personal_best = {}
for l in laps_all:
    n = l.get("driver_number")
    for si, key in enumerate(SECTORS):
        v = l.get(key)
        if not isinstance(v, (int, float)) or v <= 0:
            continue
        if si not in session_best or v < session_best[si]:
            session_best[si] = v
        pb = personal_best.setdefault(n, {})
        if si not in pb or v < pb[si]:
            pb[si] = v

def sector_mark(num, si, value):
    if not isinstance(value, (int, float)) or value <= 0:
        return ""
    if si in session_best and value <= session_best[si]:
        return "p"
    if value <= personal_best.get(num, {}).get(si, float("inf")):
        return "g"
    return ""

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
        "drs": drs_now.get(num, ""),
        "sector1Mark": sector_mark(num, 0, lap.get("duration_sector_1")),
        "sector2Mark": sector_mark(num, 1, lap.get("duration_sector_2")),
        "sector3Mark": sector_mark(num, 2, lap.get("duration_sector_3")),
    })
order.sort(key=lambda r: (r["position"] == "", r["position"] or 999))

# A fetch that came back with nothing must not overwrite a snapshot that has
# something. Rate limiting, a dropped connection or a session key that resolved
# to nothing all produce an empty result set, and writing that out replaces a
# good snapshot with an empty page -- which is how a transient 429 turned into
# a blank running order. So: write a file that does not exist yet (read_csv
# needs something to open, and a header-only file yields an empty resource
# rather than a 500), write it whenever there are rows, and otherwise leave
# what is already there alone.
kept = []

def write(name, fields, rows):
    target = out / name
    if not rows and target.exists():
        kept.append(name)
        return
    with target.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fields, quoting=csv.QUOTE_ALL, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    print(f"  {name}: {len(rows)} rows", file=sys.stderr)

write("live-order.csv",
      ["sessionKey", "driverNumber", "code", "driverName", "team", "teamColour",
       "position", "gapToLeader", "interval", "lapNumber", "lastLapSeconds",
       "sector1", "sector2", "sector3", "speedTrap", "compound", "tyreAge",
       "pitStops", "drs", "sector1Mark", "sector2Mark", "sector3Mark"], order)

# ---------------------------------------------------------------------------
# The history. Everything above is the last sample of a time series; this is
# the series, resampled onto laps so it can be drawn. For each lap a driver
# completed, take the position and gap standing when that lap ended.
#
# Position and interval samples arrive on their own clocks, unaligned with lap
# boundaries and with each other, so each lap end is a lookup: the newest
# sample at or before it. Sorting once per driver and bisecting keeps that
# linear rather than quadratic.
# ---------------------------------------------------------------------------
def when(row):
    try:
        return datetime.datetime.fromisoformat(row["date"])
    except Exception:
        return None

def series(rows, field):
    """{driver: ([sorted datetimes], [values])} for one field of one endpoint."""
    by_driver = {}
    for r in rows:
        n, t = r.get("driver_number"), when(r)
        if n is None or t is None or r.get(field) is None:
            continue
        by_driver.setdefault(n, []).append((t, r[field]))
    out = {}
    for n, pairs in by_driver.items():
        pairs.sort(key=lambda x: x[0])
        out[n] = ([t for t, _ in pairs], [v for _, v in pairs])
    return out

def at(sampled, num, moment):
    """The newest sample at or before `moment`, or '' if the car has none yet."""
    got = sampled.get(num)
    if not got or moment is None:
        return ""
    times, values = got
    i = bisect.bisect_right(times, moment)
    return values[i - 1] if i else ""

pos_series = series(load("position"), "position")
gap_series = series(load("intervals"), "gap_to_leader")
code_of = {n: (d.get("name_acronym") or "") for n, d in drivers.items()}

trace = []
for l in laps_all:
    num, lap_no = l.get("driver_number"), l.get("lap_number")
    if num is None or not lap_no:
        continue
    start = when({"date": l.get("date_start")}) if l.get("date_start") else None
    end = start
    if start is not None and isinstance(l.get("lap_duration"), (int, float)):
        end = start + datetime.timedelta(seconds=l["lap_duration"])
    gap = at(gap_series, num, end)
    trace.append({
        "sessionKey": session,
        "driverNumber": num,
        "code": code_of.get(num, ""),
        "lapNumber": lap_no,
        "position": at(pos_series, num, end),
        "gapToLeader": gap,
        # The same gap as a number, or nothing. OpenF1 reports seconds until a
        # car is lapped and then switches to "+1 LAP", so the text column is the
        # one a page shows and this one is the one a chart plots -- a chart that
        # coerced "+1 LAP" would draw it as zero, at the front of the race.
        "gapSeconds": gap if isinstance(gap, (int, float)) else "",
        "lapSeconds": l.get("lap_duration") if l.get("lap_duration") is not None else "",
    })
trace.sort(key=lambda r: (r["lapNumber"], r["position"] == "", r["position"] or 999))

write("live-trace.csv",
      ["sessionKey", "driverNumber", "code", "lapNumber", "position",
       "gapToLeader", "gapSeconds", "lapSeconds"], trace)

# Every stint, not just the one running. The order file carries the current
# compound because that is what a standings row shows; the strategy panel wants
# the whole set, and OpenF1 has already handed it over in the same response.
stint_rows = []
for st in stints:
    num = st.get("driver_number")
    if num is None or not st.get("stint_number"):
        continue
    stint_rows.append({
        "sessionKey": session,
        "driverNumber": num,
        "code": code_of.get(num, ""),
        "stintNumber": st.get("stint_number"),
        "compound": st.get("compound") or "",
        "lapStart": st.get("lap_start") if st.get("lap_start") is not None else "",
        "lapEnd": st.get("lap_end") if st.get("lap_end") is not None else "",
        "tyreAgeAtStart": st.get("tyre_age_at_start") if st.get("tyre_age_at_start") is not None else "",
    })
stint_rows.sort(key=lambda r: (r["driverNumber"], r["stintNumber"]))
write("live-stints.csv",
      ["sessionKey", "driverNumber", "code", "stintNumber", "compound",
       "lapStart", "lapEnd", "tyreAgeAtStart"], stint_rows)

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

# Guarded like the rest: a fetch that could not even identify the session must
# not replace a real one with a row of blanks.
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
            __import__("datetime").timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")}]
      if s else [])

if kept:
    print(f"  kept the previous {', '.join(kept)} -- this fetch returned no rows",
          file=sys.stderr)
PY

echo "Live snapshot written to $OUT."
