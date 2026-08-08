#!/usr/bin/env python3
"""Reconstruct call trees from the collected OTLP spans."""
import json
import sys
from collections import defaultdict

S = "/tmp/claude-0/-home-user-mxcli-formula1/2417dbdb-fec6-5ec9-a108-f924d46aa801/scratchpad"
NEEDLE = sys.argv[1] if len(sys.argv) > 1 else "RaceResults"
LIMIT = int(sys.argv[2]) if len(sys.argv) > 2 else 2

spans = [json.loads(l) for l in open(f"{S}/spans.jsonl")]
by_trace = defaultdict(list)
for s in spans:
    by_trace[s["trace_id"]].append(s)

# Traces that contain the retrieve we care about, newest last.
hits = [
    (min(s["start"] for s in v), t)
    for t, v in by_trace.items()
    if any(NEEDLE in s["name"] for s in v)
]
hits.sort()
print(f"{len(hits)} trace(s) touching {NEEDLE!r}\n")

SKIP = ("system$queuedtask", "system$processedqueuetask")


def show(trace_id):
    rows = sorted(by_trace[trace_id], key=lambda s: s["start"])
    rows = [r for r in rows if not any(k in r["name"] for k in SKIP)]
    if not rows:
        return
    kids = defaultdict(list)
    ids = {r["span_id"] for r in rows}
    roots = []
    for r in rows:
        if r["parent_id"] and r["parent_id"] in ids:
            kids[r["parent_id"]].append(r)
        else:
            roots.append(r)
    t0 = min(r["start"] for r in rows)
    total = max(r["end"] for r in rows) - t0

    print(f"trace {trace_id[:16]}…   wall {total/1e6:.0f} ms   {len(rows)} spans")
    print(f"  {'offset':>8} {'dur':>9}  {'service':<18} span")

    def walk(node, depth):
        off = (node["start"] - t0) / 1e6
        svc = node["service"].replace("Formula1", "")
        name = node["name"]
        extra = ""
        a = node["attrs"]
        for k in ("http.url", "url.full", "http.target", "url.path", "db.statement"):
            if k in a:
                extra = "  " + str(a[k])[:150]
                break
        print(
            f"  {off:8.1f} {node['ms']:8.1f}ms  {svc:<18} {'  '*depth}{name}{extra}"
        )
        for c in sorted(kids[node["span_id"]], key=lambda s: s["start"]):
            walk(c, depth + 1)

    for r in roots:
        walk(r, 0)
    print()


for _, t in hits[-LIMIT:]:
    show(t)
