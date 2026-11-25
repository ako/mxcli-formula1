#!/usr/bin/env bash
# One DuckGraphLake view per CSV, across all of data/'s folders.
#
# Discovery merges every file in a folder into one view with
# read_csv(..., union_by_name = true) and no filename column, so data/f1db's 47
# distinct tables become one view of 151 columns and 248,287 rows in which no row
# can be traced back to its file. Feed the output of this script to the server's
# --init flag instead. See FINDINGS §99 and ako/DuckGraphLake#31.
set -euo pipefail
DATA="${1:-$(cd "$(dirname "$0")/../.." && pwd)/data}"
for f in "$DATA"/f1db/*.csv "$DATA"/facts/*.csv "$DATA"/laps/*.csv "$DATA"/live/*.csv; do
  [ -f "$f" ] || continue
  v=$(basename "$f" .csv | tr '-' '_')
  echo "CREATE OR REPLACE VIEW \"$v\" AS SELECT * FROM read_csv('$f');"
done
