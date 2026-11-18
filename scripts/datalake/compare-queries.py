#!/usr/bin/env python3
"""Prove read_csv(...) and the lake's per-file views return the same rows.

For each F1Warehouse query that really reads a CSV, run its SQL twice against the
SAME DuckGraphLake connection -- once exactly as the Mendix model has it, once
with every read_csv(...) swapped for the matching view -- and compare the rows.
Nothing in the Mendix model is touched.
"""
import os, re, subprocess, sys

DUMP = sys.argv[1]
DATA = "/home/user/mxcli-formula1/data"
REAL = """GetSeasons GetCircuits GetConstructors GetDrivers GetRaces GetRaceResults
GetDriverCount GetRaceResultCount GetDriverStandings GetConstructorStandings
GetDriverSeasons GetDriverRaces GetRetirements GetFacts GetLiveOrder
GetLiveMessages GetLiveSession GetLiveTrace GetLiveStints
GetCircuitOutlines GetCircuitPoints""".split()

BIND = {"dataDir": f"'{DATA}/f1db'", "keyFilter": "''", "topN": "'100000'",
        "skipN": "'0'", "sortCol": "'year'", "sortDir": "'A'"}

text = open(DUMP).read()
starts = [(m.start(), m.group(1)) for m in re.finditer(r"^  query (\w+) \(", text, re.M)]

def sql_of(body):
    m = re.search(r"Sql: '(.*?)',\n    (?:Parameters|Returns):", body, re.S)
    return m.group(1).replace("''", "'") if m else None

# read_csv({dataDir} || '/a/b-c.csv')  ->  view name b_c
def swap_reads(sql):
    """Replace every read_csv(...) call -- any option list -- with its view name."""
    out = []; i = 0
    while True:
        j = sql.find("read_csv(", i)
        if j < 0:
            out.append(sql[i:]); break
        out.append(sql[i:j])
        k = j + len("read_csv("); depth = 1
        while depth:                      # walk to the matching close paren
            if sql[k] in "({": depth += 1
            elif sql[k] in ")}": depth -= 1
            k += 1
        call = sql[j:k]
        m = re.search(r"\|\|\s*'([^']+)'", call)
        stem = os.path.basename(m.group(1))
        for ext in (".csv", ".tsv"):
            if stem.endswith(ext): stem = stem[:-len(ext)]
        out.append('"%s"' % stem.replace("-", "_"))
        i = k
    return "".join(out)

def run(sql):
    p = subprocess.run(["psql", "-h", "127.0.0.1", "-p", "5433", "-U", "lake",
                        "-d", "lake", "-At", "-F", "\x1f", "-c", sql],
                       capture_output=True, text=True,
                       env={**os.environ, "PGPASSWORD": "duckgraphlake"})
    return p.returncode, p.stdout, p.stderr.strip().splitlines()[:1]

print(f"{'query':<24} {'csv rows':>9} {'view rows':>9}  verdict")
print("-" * 76)
tally = {}
for i, (pos, name) in enumerate(starts):
    if name not in REAL: continue
    end = starts[i + 1][0] if i + 1 < len(starts) else len(text)
    sql = sql_of(text[pos:end])
    if sql is None:
        print(f"{name:<24} {'':>9} {'':>9}  NO SQL PARSED"); tally["parse"] = tally.get("parse",0)+1; continue
    a = sql; b = swap_reads(sql)
    for k, v in BIND.items():
        a = a.replace("{%s}" % k, v); b = b.replace("{%s}" % k, v)
    if "read_csv" in b:
        print(f"{name:<24} {'':>9} {'':>9}  UNSWAPPED read_csv REMAINS"); continue
    ra, oa, ea = run(a); rb, ob, eb = run(b)
    if ra != 0 or rb != 0:
        which = "csv" if ra != 0 else "view"
        msg = (ea or eb or ["?"])[0][:40]
        print(f"{name:<24} {'err' if ra else '-':>9} {'err' if rb else '-':>9}  {which} ERROR: {msg}")
        tally["error"] = tally.get("error", 0) + 1; continue
    la, lb = oa.splitlines(), ob.splitlines()
    if oa == ob:
        v = "IDENTICAL (rows and order)"; tally["identical"] = tally.get("identical",0)+1
    elif sorted(la) == sorted(lb):
        v = "SAME ROWS, order differs"; tally["sameset"] = tally.get("sameset",0)+1
    else:
        only_a = len(set(la) - set(lb)); only_b = len(set(lb) - set(la))
        v = f"DIFFERS (+{only_b}/-{only_a})"; tally["differs"] = tally.get("differs",0)+1
    print(f"{name:<24} {len(la):>9} {len(lb):>9}  {v}")

print("-" * 76)
print("tally:", ", ".join(f"{k}={v}" for k, v in sorted(tally.items())))
