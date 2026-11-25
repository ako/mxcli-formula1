#!/usr/bin/env bash
# Re-execute every MDL script against the already-built model and count writes.
#
# A second run of a script set that has already been applied should change
# nothing: mxcli reports Created/Modified/Dropped/Moved/Replaced/Renamed only
# when it actually writes. FINDINGS §97 is where that first reached zero, and
# §98 held it on the nightly, so any non-zero count here is a regression or a
# deliberate behaviour change -- either way it is attributable to the binary.
#
#   scripts/reexec-all.sh [path-to-mxcli]     # default: ./mxcli
#
# Writes per-script logs to a temp dir and prints a per-script table.
set -uo pipefail
cd "$(dirname "$0")/.."
MX="$(cd "$(dirname "${1:-./mxcli}")" && pwd)/$(basename "${1:-./mxcli}")"
OUT="$(mktemp -d)"
VERBS='^(Created|Modified|Dropped|Moved|Replaced|Renamed) '

echo "binary: $("$MX" version 2>&1 | tail -1)"
echo "logs:   $OUT"
printf '\n%-44s %7s %7s\n' "script" "writes" "exit"
printf -- '%.0s-' {1..62}; echo

total=0; failed=0
run() {  # run <project-dir> <mpr> <script...>
  local dir="$1" mpr="$2"; shift 2
  for s in "$@"; do
    [ -f "$s" ] || continue
    local log="$OUT/$(echo "$s" | tr '/' '_').log"
    ( cd "$dir" && MXCLI_OUTPUT_LINE_LIMIT=0 "$MX" exec -p "$mpr" \
        --continue-on-error "../$s" ) > "$log" 2>&1
    local rc=$? w
    w=$(grep -cE "$VERBS" "$log")
    total=$((total + w)); [ "$rc" -eq 0 ] || failed=$((failed + 1))
    printf '%-44s %7s %7s\n' "$(basename "$s")" "$w" "$rc"
  done
}

run Formula1Backend  Formula1Backend.mpr  model/odatapushdown/*.mdl model/backend/*.mdl
run Formula1Frontend Formula1Frontend.mpr model/frontend/*.mdl

printf -- '%.0s-' {1..62}; echo
echo "total writes: $total    non-zero exits: $failed"
[ "$total" -eq 0 ] && echo "PASS: the set is idempotent (FINDINGS §97/§98 property holds)" \
                   || echo "ATTENTION: $total write(s) -- see $OUT"
