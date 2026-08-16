#!/usr/bin/env bash
#
# A semantic fingerprint of both apps, for verifying a rebuild.
#
# A rebuild from model/ cannot produce a byte-identical .mpr: Mendix keys every
# document by UUID, so dropping a module and recreating it mints a fresh id for
# every entity, attribute, microflow and page. `git diff mprcontents/` after a
# rebuild is thousands of files and proves nothing either way.
#
# What must not change is the MEANING. Everything below is emitted by DESCRIBE,
# which round-trips a document back to MDL and carries no identity, or by the
# published $metadata, which is the contract a consumer actually sees. Diff two
# runs of this and a clean result is a real result.
#
#   scripts/fingerprint.sh before
#   ... rebuild ...
#   scripts/fingerprint.sh after
#   diff -ru fingerprint/before fingerprint/after
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$HERE/fingerprint/${1:?usage: fingerprint.sh <label>}"
rm -rf "$OUT"; mkdir -p "$OUT"

# Strip the banner mxcli prints on every invocation, and anything carrying a
# path or a timestamp — none of it is model.
clean() { grep -v "^Using project:\|^Connected to:\|^Checking syntax:" | sed 's#/home/[^ ]*/##g'; }

dump() {  # dump <app> <mpr>
  app="$1"; mpr="$2"; cli="$HERE/$app/mxcli"
  d="$OUT/$app"; mkdir -p "$d"
  cd "$HERE/$app" || return

  for kind in MODULES ENTITIES ASSOCIATIONS MICROFLOWS NANOFLOWS PAGES SNIPPETS \
              ENUMERATIONS CONSTANTS JAVA\ ACTIONS "ODATA SERVICES" "ODATA CLIENTS" \
              "DATABASE CONNECTIONS" "MODULE ROLES" "USER ROLES" "DEMO USERS"; do
    echo "== SHOW $kind"
    "$cli" -p "$mpr" -c "SHOW $kind" 2>&1 | clean
  done > "$d/inventory.txt"

  "$cli" -p "$mpr" -c "DESCRIBE SETTINGS"   2>&1 | clean > "$d/settings.txt"
  "$cli" -p "$mpr" -c "DESCRIBE NAVIGATION" 2>&1 | clean > "$d/navigation.txt"
  "$cli" -p "$mpr" -c "SHOW SECURITY MATRIX" 2>&1 | clean > "$d/security.txt"

  # Every document, round-tripped back to MDL.
  for spec in "ENTITY:ENTITIES" "MICROFLOW:MICROFLOWS" "NANOFLOW:NANOFLOWS" \
              "PAGE:PAGES" "SNIPPET:SNIPPETS" "ENUMERATION:ENUMERATIONS" \
              "JAVA ACTION:JAVA ACTIONS" "ODATA SERVICE:ODATA SERVICES" \
              "ODATA CLIENT:ODATA CLIENTS" "DATABASE CONNECTION:DATABASE CONNECTIONS"; do
    one="${spec%%:*}"; many="${spec##*:}"
    file="$d/$(echo "$one" | tr ' A-Z' '-a-z').txt"
    : > "$file"
    "$cli" -p "$mpr" -c "SHOW $many" 2>/dev/null \
      | awk -F'|' '/\|/{for(i=2;i<=NF;i++){gsub(/ /,"",$i);
             if ($i ~ /^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*$/){print $i; break}}}' | sort -u \
      | while read -r name; do
          echo "======== $name" >> "$file"
          "$cli" -p "$mpr" -c "DESCRIBE $one $name" 2>&1 | clean >> "$file"
        done
  done
  cd "$HERE" || return
}

dump Formula1Backend  Formula1Backend.mpr
dump Formula1Frontend Formula1Frontend.mpr

# The published contracts, if the backend happens to be up. These are the
# strongest single artefact: GUID-free, and exactly what a consumer binds to.
if curl -s -o /dev/null --max-time 3 http://127.0.0.1:8080/ 2>/dev/null; then
  mkdir -p "$OUT/metadata"
  for s in f1-live f1 f1-fan f1-now f1-ops; do
    curl -s -H "X-Api-Key: ${F1_API_KEY:-f1-ops-key-2f8a1c}" \
      "http://127.0.0.1:8080/odata/$s/\$metadata" \
      | sed 's#http://[^"<]*##g' > "$OUT/metadata/$s.xml"
  done
else
  echo "(backend not running — \$metadata not captured)" > "$OUT/metadata-skipped.txt"
fi

echo "fingerprint written to fingerprint/$1"
find "$OUT" -type f | wc -l | xargs echo "  files:"
cat "$OUT"/*/*.txt 2>/dev/null | wc -l | xargs echo "  lines:"
