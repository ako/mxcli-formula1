#!/usr/bin/env python3
"""Emit CREATE VIEW statements that carry the MDL's declared column specs.

Any F1Warehouse read_csv(..., columns = {...}) call states its own types. A view
built by plain inference does not necessarily agree, so emit those views with
the declared spec instead of letting DuckDB guess.
"""
import os, re, sys

text = open(sys.argv[1]).read().replace("''", "'")
DATA = "/home/user/mxcli-formula1/data/f1db"
seen = {}
for m in re.finditer(r"read_csv\(\{dataDir\}\s*\|\|\s*'([^']+)'\s*,\s*header = true\s*,\s*columns = \{", text):
    path = m.group(1)
    k = m.end()                     # walk the brace-balanced column spec
    depth, start = 1, k
    while depth:
        if text[k] == "{": depth += 1
        elif text[k] == "}": depth -= 1
        k += 1
    spec = text[start:k-1]
    cols = re.findall(r"'(\w+)'\s*:\s*'([A-Z0-9()\[\], ]+?)'", spec)
    real = os.path.normpath(os.path.join(DATA, path.lstrip("/")))
    stem = os.path.basename(real)
    for e in (".csv", ".tsv"):
        if stem.endswith(e): stem = stem[:-len(e)]
    view = stem.replace("-", "_")
    if view in seen: continue
    seen[view] = (real, cols, os.path.exists(real))

for view, (real, cols, exists) in sorted(seen.items()):
    flag = "" if exists else "   -- FILE MISSING, view not emitted"
    print(f"-- {view}: {len(cols)} declared columns{flag}", file=sys.stderr)
    if not exists: continue
    spec = ", ".join(f"'{c}': '{t}'" for c, t in cols)
    print(f"CREATE OR REPLACE VIEW \"{view}\" AS SELECT * FROM "
          f"read_csv('{real}', header = true, columns = {{{spec}}});")
