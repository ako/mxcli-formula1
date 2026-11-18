#!/usr/bin/env bash
# One DuckGraphLake view per CSV, across all of data/'s folders.
#
# Discovery makes one *glob* view per folder, which collapses the 47
# different-schema CSVs in data/f1db into a single unusable view. Feed the output
# of this script to the server's --init flag instead. See FINDINGS §99.
set -euo pipefail
DATA="${1:-$(cd "$(dirname "$0")/../.." && pwd)/data}"
for f in "$DATA"/f1db/*.csv "$DATA"/facts/*.csv "$DATA"/laps/*.csv "$DATA"/live/*.csv; do
  [ -f "$f" ] || continue
  v=$(basename "$f" .csv | tr '-' '_')
  echo "CREATE OR REPLACE VIEW \"$v\" AS SELECT * FROM read_csv('$f');"
done
