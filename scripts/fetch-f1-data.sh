#!/bin/sh
# Fetch the historical Formula 1 CSV dataset into data/f1db/.
#
# The CSVs (~25 MB, 47 files) are git-ignored and re-fetched by the SessionStart
# hook, the same way the mxcli binary is. Source: https://github.com/f1db/f1db
# (CC-BY-4.0), which publishes a f1db-csv.zip on every release. Ergast, the
# dataset most F1 tutorials point at, was shut down and its domain no longer
# serves the dump — do not switch back to it.
#
# Pin a release with F1DB_TAG=v2025.x.y (default: latest).
set -e

DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DEST="$DIR/data/f1db"
TAG="${F1DB_TAG:-latest}"

if [ "$TAG" = latest ]; then
  URL="https://github.com/f1db/f1db/releases/latest/download/f1db-csv.zip"
else
  URL="https://github.com/f1db/f1db/releases/download/${TAG}/f1db-csv.zip"
fi

# f1db-races.csv is the smallest file guaranteed present in every release, so
# its absence means the folder is missing or half-extracted.
if [ -f "$DEST/f1db-races.csv" ] && [ "${F1DB_FORCE:-0}" != 1 ]; then
  echo "F1 data already present in data/f1db ($(ls "$DEST" | wc -l | tr -d ' ') files)"
  exit 0
fi

echo "Fetching F1 CSV dataset (${TAG}) ..."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if ! curl -fsSL --max-time 300 -o "$tmp/f1db-csv.zip" "$URL"; then
  echo "Could not download $URL" >&2
  exit 1
fi
mkdir -p "$DEST"
unzip -oq "$tmp/f1db-csv.zip" -d "$DEST"
echo "F1 data ready: $DEST ($(ls "$DEST" | wc -l | tr -d ' ') CSV files)"
