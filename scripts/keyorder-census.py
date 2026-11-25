#!/usr/bin/env python3
"""How many stored elements have their keys out of Studio Pro's order?

    scripts/keyorder-census.py Formula1Backend/mprcontents

Needs an interpreter with pymongo's bson (python3.13 here; `pip install pymongo`).
Studio Pro rewrites every unit whose keys are not in its own order, so this
counts what a first Studio Pro open would touch. mxcli wrote metamodel order
until ako/mxcli#2467; units written before that stay as they are until each one
next really changes. FINDINGS §102 has the measurement for this solution.

Studio Pro writes $ID, $Type, then the remaining keys of an element sorted
case-insensitively (ako/mxcli#2467). mxcli wrote metamodel order, so a Studio
Pro open rewrites every unit mxcli touched. This walks the BSON of each .mxunit
and reports, per $Type, how many elements are out of that order.
"""
import collections, pathlib, sys, bson

root = pathlib.Path(sys.argv[1])
bad = collections.Counter(); total = collections.Counter()
badunits = set(); units = 0

def walk(doc, unit):
    if not isinstance(doc, dict):
        return
    t = doc.get("$Type")
    if isinstance(t, str):
        keys = [k for k in doc.keys() if k not in ("$ID", "$Type")]
        total[t] += 1
        if keys != sorted(keys, key=str.lower):
            bad[t] += 1
            badunits.add(unit)
    for v in doc.values():
        if isinstance(v, dict):
            walk(v, unit)
        elif isinstance(v, list):
            for i in v:
                walk(i, unit)

for p in sorted(root.rglob("*.mxunit")):
    units += 1
    try:
        walk(bson.decode(p.read_bytes()), p.name)
    except Exception as e:
        print(f"  !! {p.name}: {e}", file=sys.stderr)

print(f"{root}: {units} units, {sum(total.values())} elements")
print(f"  elements out of Studio Pro key order: {sum(bad.values())}")
print(f"  $Types affected:                      {len(bad)}")
print(f"  units affected:                       {len(badunits)}")
if bad:
    print("\n  worst types (out-of-order / total):")
    for t, n in bad.most_common(10):
        print(f"    {n:>5} / {total[t]:<6} {t}")
