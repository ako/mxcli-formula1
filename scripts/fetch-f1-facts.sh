#!/bin/sh
# Fetch one-paragraph Wikipedia summaries for the seasons, drivers and
# constructors in data/f1db, and write them as a CSV the backend reads with
# DuckDB like every other file.
#
# Why Wikipedia's REST summary endpoint and not scraping: it returns a clean
# lead paragraph plus the canonical page URL as JSON, it is rate-friendly, and
# the licence is unambiguous. Text is CC BY-SA 4.0 — the CSV carries the article
# title, the page URL and the licence on every row, and the app shows the link.
#
# Which entities: every season, every driver who ever led a championship or won
# a race, and every constructor that ever won one. Roughly 350 requests at ~0.15s
# apart. Wikipedia titles are guessed from f1db names, so a lookup can miss or —
# worse — hit the wrong article; a summary that never mentions motor racing is
# dropped rather than shown. Misses are normal and the pages degrade to the
# numbers.
#
# The file is ALWAYS written, even with no network: the backend's read_csv()
# needs something to open, and a header-only file yields an empty Facts
# resource rather than a 500.
set -e

DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DATA="$DIR/data/f1db"
OUT_DIR="$DIR/data/facts"
OUT="$OUT_DIR/f1db-facts.csv"
API="https://en.wikipedia.org/api/rest_v1/page/summary"

[ -f "$DATA/f1db-seasons.csv" ] || {
  echo "No f1db data at $DATA — run scripts/fetch-f1-data.sh first." >&2
  exit 1
}

mkdir -p "$OUT_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Work out who is worth a lookup. duckdb is not a dependency of this repo, so
# the selection is done in Python against the CSVs.
# ---------------------------------------------------------------------------
python3 - "$DATA" "$TMP/targets.tsv" <<'PY'
import csv, sys, pathlib
data, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

def rows(name):
    with (data / name).open(newline="", encoding="utf-8") as f:
        yield from csv.DictReader(f)

targets = []

for s in rows("f1db-seasons.csv"):
    year = s["year"]
    # Wikipedia names season articles two ways and switches between them by era,
    # so both are offered and the first that resolves wins.
    targets.append(("season", year,
                    f"{year} Formula One World Championship",
                    f"{year} Formula One season"))

for d in rows("f1db-drivers.csv"):
    if int(d["totalRaceWins"] or 0) > 0 or int(d["totalChampionshipWins"] or 0) > 0:
        targets.append(("driver", d["id"], d["name"], f"{d['name']} (racing driver)"))

for c in rows("f1db-constructors.csv"):
    if int(c["totalRaceWins"] or 0) > 0:
        # fullName disambiguates: "Scuderia Ferrari", not "Ferrari" the carmaker.
        targets.append(("constructor", c["id"], c["fullName"] or c["name"],
                        f"{c['name']} in Formula One"))

with out.open("w", newline="", encoding="utf-8") as f:
    w = csv.writer(f, delimiter="\t")
    w.writerows(targets)
print(f"{len(targets)} lookups", file=sys.stderr)
PY

# ---------------------------------------------------------------------------
# Fetch. One request per target, sequential and unhurried — this is someone
# else's free API.
# ---------------------------------------------------------------------------
: > "$TMP/raw.jsonl"
total=$(wc -l < "$TMP/targets.tsv" | tr -d ' ')
n=0
while IFS="$(printf '\t')" read -r scope id title alt; do
  n=$((n + 1))
  [ $((n % 50)) -eq 0 ] && echo "  $n/$total ..." >&2
  for candidate in "$title" "$alt"; do
    [ -n "$candidate" ] || continue
    slug=$(printf '%s' "$candidate" | sed 's/ /_/g' | python3 -c \
      'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip(), safe=""))')
    body=$(curl -sS --max-time 20 -H 'Accept: application/json' \
        -A 'mxcli-formula1/1.0 (sample app; https://github.com/ako/mxcli-formula1)' \
        "$API/$slug" 2>/dev/null || true)
    sleep 0.15
    case "$body" in
      *'"type":"standard"'*)
        printf '%s\t%s\t%s\n' "$scope" "$id" "$body" >> "$TMP/raw.jsonl"
        break
        ;;
    esac
  done
done < "$TMP/targets.tsv"

# ---------------------------------------------------------------------------
# Filter and write. A summary is kept only if the article is a normal page and
# the text actually talks about motor racing — the cheapest guard against a
# name that resolves to a footballer.
# ---------------------------------------------------------------------------
python3 - "$TMP/raw.jsonl" "$OUT" <<'PY'
import csv, json, pathlib, re, sys
src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

RACING = re.compile(
    r"formula one|formula 1|grand prix|racing driver|motor rac|world championship",
    re.I)

kept, dropped = [], 0
if src.exists():
    for line in src.read_text(encoding="utf-8").splitlines():
        try:
            scope, entity_id, body = line.split("\t", 2)
            d = json.loads(body)
        except ValueError:
            dropped += 1
            continue
        extract = (d.get("extract") or "").strip()
        if d.get("type") != "standard" or not extract or not RACING.search(extract):
            dropped += 1
            continue
        kept.append({
            "scope": scope,
            "entityId": entity_id,
            "title": d.get("title", ""),
            "extract": extract,
            "sourceUrl": d.get("content_urls", {}).get("desktop", {}).get("page", ""),
            "license": "CC BY-SA 4.0 (Wikipedia)",
        })

out.parent.mkdir(parents=True, exist_ok=True)
with out.open("w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, ["scope", "entityId", "title", "extract", "sourceUrl", "license"],
                       quoting=csv.QUOTE_ALL)
    w.writeheader()
    w.writerows(kept)
print(f"{len(kept)} facts written, {dropped} dropped", file=sys.stderr)
PY

echo "Facts written to $OUT ($(($(wc -l < "$OUT") - 1)) rows)."
