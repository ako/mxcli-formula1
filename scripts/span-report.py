#!/usr/bin/env python3
"""Read the collector's spans and say where the time went.

    python3 scripts/span-report.py [spans.jsonl] [--since N] [--trace ID] [--top N]

`--since N` reports only the last N seconds, which is how you attribute a slow
page: reload it, then ask what the last twenty seconds did.

Four questions, in the order they are usually asked:

  1. Did anything fail?          — spans with status ERROR, and the JDBC spans
                                   that carry an exception attribute.
  2. What is slow overall?       — total time by span name. A 4ms query run
                                   three hundred times costs more than a 900ms
                                   one run once, and only a total shows it.
  3. What is slow individually?  — the longest single spans.
  4. Where did one request go?   — `--trace <id>` prints that trace as a tree
                                   with each span's own time, so a request that
                                   took 2s is attributed rather than guessed at.

Self-time (the "own" column) is a span's duration minus the duration of its
children: it is what that span did rather than what it waited for, and it is the
number that identifies a bottleneck. A parent with 2000ms total and 3ms own time
is not slow — something under it is.
"""
import collections
import json
import sys
import time

args = [a for a in sys.argv[1:]]


def opt(name, default=None):
    if name in args:
        i = args.index(name)
        v = args[i + 1]
        del args[i:i + 2]
        return v
    return default


since = opt("--since")
only_trace = opt("--trace")
top = int(opt("--top", "15"))
path = args[0] if args else "/tmp/spans.jsonl"

spans = []
with open(path) as f:
    for line in f:
        line = line.strip()
        if line:
            spans.append(json.loads(line))

if since:
    cutoff = (time.time() - float(since)) * 1e9
    spans = [s for s in spans if s["start"] >= cutoff]

if not spans:
    print(f"no spans in {path}" + (f" in the last {since}s" if since else ""))
    print("  the app has to be running with --trace-otlp http://127.0.0.1:4318,")
    print("  and something has to have exercised it — load a page first.")
    sys.exit(0)

by_id = {s["span_id"]: s for s in spans}

# Self-time: a span's own duration less whatever its children accounted for.
child_ms = collections.defaultdict(float)
for s in spans:
    if s["parent_id"] and s["parent_id"] in by_id:
        child_ms[s["parent_id"]] += s["ms"]
for s in spans:
    s["own"] = max(0.0, s["ms"] - child_ms[s["span_id"]])


def bar(frac, width=22):
    return "█" * max(1, round(frac * width)) if frac > 0 else ""


if only_trace:
    members = [s for s in spans if s["trace_id"] == only_trace]
    if not members:
        print(f"no spans for trace {only_trace}")
        sys.exit(1)
    kids = collections.defaultdict(list)
    roots = []
    ids = {s["span_id"] for s in members}
    for s in members:
        (kids[s["parent_id"]] if s["parent_id"] in ids else roots).append(s)

    def walk(s, depth):
        print(f"  {'  ' * depth}{s['ms']:8.1f}ms  own {s['own']:7.1f}ms  {s['name'][:90]}")
        st = s["attrs"].get("db.statement")
        if st:
            print(f"  {'  ' * depth}            {' ' * 16}{st[:110]}")
        for c in sorted(kids[s["span_id"]], key=lambda x: x["start"]):
            walk(c, depth + 1)

    print(f"\ntrace {only_trace} — {len(members)} spans, "
          f"{max(s['end'] for s in members) - min(s['start'] for s in members):.0f}ns wall\n")
    for r in sorted(roots, key=lambda x: x["start"]):
        walk(r, 0)
    sys.exit(0)

window = f" (last {since}s)" if since else ""
services = collections.Counter(s["service"] for s in spans)
print(f"\n{len(spans)} spans{window} across {len(set(s['trace_id'] for s in spans))} traces")
print("  " + " · ".join(f"{k} {v}" for k, v in services.most_common()))

# 1. failures
errs = [s for s in spans
        if s.get("status") == 2 or "exception.message" in s["attrs"]]
print(f"\n── errors ── {len(errs)}")
if not errs:
    print("  none")
for s in errs[:top]:
    msg = s["attrs"].get("exception.message") or s["attrs"].get("error.message") or ""
    print(f"  {s['service']:18} {s['name'][:60]:60} {msg[:70]}")

# 2. total time by name — the one that finds a chatty query
agg = collections.defaultdict(lambda: [0, 0.0, 0.0])   # count, total own, max
for s in spans:
    a = agg[(s["service"], s["name"])]
    a[0] += 1
    a[1] += s["own"]
    a[2] = max(a[2], s["ms"])
rows = sorted(agg.items(), key=lambda kv: -kv[1][1])[:top]
worst = rows[0][1][1] if rows else 1
print(f"\n── total self-time by span ── top {len(rows)}")
print(f"  {'own ms':>9} {'calls':>6} {'max ms':>8}  {'':22} span")
for (svc, name), (n, own, mx) in rows:
    print(f"  {own:9.1f} {n:6d} {mx:8.1f}  {bar(own / worst):22} {svc[:12]}·{name[:64]}")

# 3. slowest individual spans
print(f"\n── slowest single spans ── top {top}")
for s in sorted(spans, key=lambda x: -x["ms"])[:top]:
    print(f"  {s['ms']:9.1f}ms own {s['own']:8.1f}ms  {s['service'][:12]}·{s['name'][:70]}")
    st = s["attrs"].get("db.statement")
    if st:
        print(f"              {st[:110]}")

# 4. the traces worth opening
tr = collections.defaultdict(float)
tname = {}
for s in spans:
    tr[s["trace_id"]] += s["own"]
    if not s["parent_id"] or s["parent_id"] not in by_id:
        tname[s["trace_id"]] = f"{s['service']}·{s['name']}"
print(f"\n── slowest traces ── open one with --trace <id>")
for tid, ms in sorted(tr.items(), key=lambda kv: -kv[1])[:min(top, 8)]:
    print(f"  {ms:9.1f}ms  {tid}  {tname.get(tid, '?')[:70]}")
print()
