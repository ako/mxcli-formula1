#!/usr/bin/env python3
"""Turn collected spans into a self-contained flame-chart page.

    python3 scripts/span-flame.py .mxcli-obs/spans.jsonl .mxcli-obs/marks.json out.html

`marks.json` is what scripts/walk writes: `[{"label": "...", "from": ms, "to": ms}]`,
one entry per screen, so spans can be attributed to the screen that caused them.

Two views per screen, because they answer different questions.

  Timeline flame — the slowest single request, laid out on real time. x is the
  offset from the request's start, width is duration, depth is the call stack.
  This is the one that shows *shape*: what waited on what.

  Merged flame — every span the screen produced, folded by call path and summed.
  x is no longer time, it is share of total work, and a frame that ran 28 times
  is 28 times wider. This is the one that shows *repetition*, which is the whole
  story on these pages.

Trace context propagates from the frontend's OData client into the backend, so a
frame can descend from a browser request through the consumed OData call into
the backend microflow and the DuckDB scan underneath it — one stack, two apps.

Colour is by what a frame *is* — request handling, application logic, or data —
on the three-slot categorical palette that passes the CVD and normal-vision
floors under all-pairs in both light and dark. Postgres and DuckDB share the
data hue and are told apart by the label, which is the honest grouping: they are
both "the query underneath".
"""
import collections
import html
import json
import sys

spans_path, marks_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
fonts_path = sys.argv[4] if len(sys.argv) > 4 else None
FONTS = open(fonts_path).read() if fonts_path else ""

spans = [json.loads(l) for l in open(spans_path) if l.strip()]
marks = json.load(open(marks_path))
by_id = {s["span_id"]: s for s in spans}

# ---------------------------------------------------------------- classifying

def kind(s):
    n, a = s["name"], s["attrs"]
    if a.get("db.system") or n.startswith(("SELECT", "INSERT", "UPDATE", "DELETE", "WITH")):
        return "data"
    if n.startswith(("GET", "POST", "PUT", "DELETE /")) or "http.route" in a:
        return "request"
    return "logic"


def label(s):
    """A stable, readable name — the URL for HTTP, the statement shape for SQL."""
    n, a = s["name"], s["attrs"]
    if "url.path" in a:
        q = a.get("url.query", "")
        import urllib.parse
        q = urllib.parse.unquote(q)
        filt = next((p[8:] for p in q.split("&") if p.startswith("$filter=")), "")
        tail = f" ? {filt}" if filt else ""
        return f"{a.get('http.request.method', 'GET')} {a['url.path']}{tail}"
    if kind(s) == "data":
        st = (a.get("db.statement") or "").strip()
        if "read_csv" in st:
            return f"{n}  (DuckDB, CSV scan)"
        return n
    return n


# ------------------------------------------------------------------- windows

def screen_of(ns):
    ms = ns / 1e6
    for m in marks:
        if m["from"] <= ms <= m["to"]:
            return m["label"]
    return None


children = collections.defaultdict(list)
for s in spans:
    children[s["parent_id"]].append(s)


def descendants(s):
    out = [s]
    for c in children.get(s["span_id"], []):
        out += descendants(c)
    return out


# ------------------------------------------------------------------ building

def timeline(root):
    """One request as nested frames on real time."""
    t0, span_ms = root["start"], root["ms"] or 1

    def node(s, depth):
        return {
            "n": label(s), "k": kind(s), "ms": round(s["ms"], 1), "svc": s["service"],
            "x": (s["start"] - t0) / 1e6 / span_ms * 100,
            "w": max(0.12, s["ms"] / span_ms * 100),
            "d": depth,
            "sql": (s["attrs"].get("db.statement") or "")[:400],
            "c": [node(c, depth + 1) for c in sorted(children.get(s["span_id"], []),
                                                     key=lambda x: x["start"])],
        }
    return node(root, 0)


def merged(roots, root_label):
    """Every span, folded by call path; width is share of summed duration."""
    agg = {}

    def fold(s, bucket):
        key = (s["service"], label(s))
        e = bucket.setdefault(key, {"n": label(s), "k": kind(s), "svc": s["service"],
                                    "ms": 0.0, "count": 0, "kids": {}})
        e["ms"] += s["ms"]
        e["count"] += 1
        for c in children.get(s["span_id"], []):
            fold(c, e["kids"])

    for r in roots:
        fold(r, agg)

    def emit(bucket, total, x0, depth):
        out, x = [], x0
        for e in sorted(bucket.values(), key=lambda e: -e["ms"]):
            w = e["ms"] / total * 100 if total else 0
            if w < 0.05:
                continue
            out.append({"n": e["n"], "k": e["k"], "svc": e["svc"],
                        "ms": round(e["ms"], 1), "count": e["count"],
                        "x": x, "w": w, "d": depth, "sql": "",
                        "c": emit(e["kids"], total, x, depth + 1)})
            x += w
        return out

    total = sum(e["ms"] for e in agg.values())
    return {"n": root_label, "k": "logic", "svc": "", "ms": round(total, 1),
            "count": 0, "x": 0, "w": 100, "d": 0, "sql": "",
            "c": emit(agg, total, 0, 1)}


screens = []
for m in marks:
    win = [s for s in spans if m["from"] <= s["start"] / 1e6 <= m["to"]]
    if not win:
        continue
    ids = {s["span_id"] for s in win}
    roots = [s for s in win if s["parent_id"] not in ids]
    # Mendix's own cluster housekeeping fires on a timer and is not the screen.
    roots = [r for r in roots if "queued task" not in r["name"].lower()
             and "ClusterManagement" not in r["name"]]
    if not roots:
        continue
    scoped = [x for r in roots for x in descendants(r)]

    be = [s for s in scoped if s["service"] == "Formula1Backend" and "url.path" in s["attrs"]]
    urls = collections.Counter(label(s) for s in be)
    slowest = max(roots, key=lambda r: r["ms"])

    # self-time table, the accessible read of the same data
    child_ms = collections.defaultdict(float)
    for s in scoped:
        if s["parent_id"] in by_id:
            child_ms[s["parent_id"]] += s["ms"]
    tbl = collections.defaultdict(lambda: [0, 0.0])
    for s in scoped:
        e = tbl[(label(s), kind(s))]
        e[0] += 1
        e[1] += max(0.0, s["ms"] - child_ms[s["span_id"]])

    screens.append({
        "label": m["label"],
        "wall": round((m["to"] - m["from"]) / 1000, 1),
        "requests": len(be),
        "distinct": len(urls),
        "backend_ms": round(sum(s["ms"] for s in be)),
        "dupes": [[u, n] for u, n in urls.most_common() if n > 1][:6],
        "timeline": timeline(slowest),
        "timeline_ms": round(slowest["ms"], 1),
        "timeline_name": label(slowest),
        "merged": merged(roots, f'{m["label"]} — {len(roots)} top-level requests'),
        "table": sorted(([n, k, c, round(ms)] for (n, k), (c, ms) in tbl.items()),
                        key=lambda r: -r[3])[:12],
    })

CSS = """
:root{
  /* The app's own Console identity: this page is about that app, so it wears
     its palette and its two typefaces rather than a generic report look.
     Light is the complement, not an inversion — the Console theme is dark-born. */
  --ground:#f7f7f5; --surface:#ffffff; --surface-2:#efefec; --line:#e2e2dd;
  --ink:#14171c; --ink-muted:#5a5f66; --ink-faint:#83878d;
  --brand:#0d9488;
  /* Data hues, validated all-pairs for CVD and normal vision on this surface,
     and stepped so all three clear 3:1 against it — no relief needed. Frames
     also carry their own labels and every screen has a table view. */
  --request:#2a78d6; --logic:#c8511f; --data:#12855c;
  /* Label ink is a token, not a constant: these mid-toned fills take white
     best on the light steps and near-black on the lighter dark steps. */
  --frame-ink:#ffffff;
  --shadow:0 8px 26px rgba(20,23,28,.14);
}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
  --ground:#0e1116; --surface:#161b22; --surface-2:#12171e; --line:#262c36;
  --ink:#e6edf3; --ink-muted:#8b949e; --ink-faint:#6e7681;
  --brand:#2dd4bf;
  --request:#3987e5; --logic:#d95926; --data:#199e70;
  --frame-ink:#0b0b0b;
  --shadow:0 8px 26px rgba(0,0,0,.45);
}}
:root[data-theme="dark"]{
  --ground:#0e1116; --surface:#161b22; --surface-2:#12171e; --line:#262c36;
  --ink:#e6edf3; --ink-muted:#8b949e; --ink-faint:#6e7681;
  --brand:#2dd4bf;
  --request:#3987e5; --logic:#d95926; --data:#199e70;
  --frame-ink:#0b0b0b;
  --shadow:0 8px 26px rgba(0,0,0,.45);
}
*{box-sizing:border-box}
body{margin:0;background:var(--ground);color:var(--ink);
  font:15px/1.6 "Space Grotesk",ui-sans-serif,system-ui,sans-serif;
  -webkit-font-smoothing:antialiased}
.wrap{max-width:1180px;margin:0 auto;padding:44px 22px 80px;
  display:flex;flex-direction:column;gap:6px}
h1{font-size:30px;font-weight:600;letter-spacing:-.02em;margin:0;text-wrap:balance}
h2{font-size:20px;font-weight:600;margin:0;letter-spacing:-.01em}
h3{font-family:"JetBrains Mono",ui-monospace,monospace;font-size:11px;font-weight:500;
  text-transform:uppercase;letter-spacing:.08em;color:var(--ink-faint);margin:20px 0 7px}
.lede{color:var(--ink-muted);max-width:68ch;margin:6px 0 0}
.meta{color:var(--ink-faint);font-size:13px;max-width:68ch;margin:2px 0 0}
.eyebrow{font-family:"JetBrains Mono",ui-monospace,monospace;font-size:11px;
  font-weight:500;letter-spacing:.1em;text-transform:uppercase;color:var(--brand);margin:0}
.screen{margin-top:40px;padding-top:24px;border-top:1px solid var(--line);
  display:flex;flex-direction:column}
.head{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap}
.head .rank{font-family:"JetBrains Mono",ui-monospace,monospace;font-size:12px;
  color:var(--ink-faint)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(136px,1fr));
  gap:10px;margin-top:16px}
.tile{background:var(--surface);border:1px solid var(--line);border-radius:6px;
  padding:11px 13px}
.tile .k{font-family:"JetBrains Mono",ui-monospace,monospace;font-size:10px;
  text-transform:uppercase;letter-spacing:.07em;color:var(--ink-faint)}
.tile .v{font-family:"JetBrains Mono",ui-monospace,monospace;font-size:23px;
  font-weight:500;font-variant-numeric:tabular-nums;margin-top:3px;line-height:1.1}
.tile .s{font-size:11px;color:var(--ink-faint);margin-top:2px}
.tile.hot .v{color:var(--logic)}
.flamebox{overflow-x:auto}
.flame{position:relative;margin:4px 0 0;user-select:none;min-width:520px}
.row{position:relative;height:21px}
.f{position:absolute;height:19px;border-radius:2px;overflow:hidden;cursor:pointer;
  font-family:"JetBrains Mono",ui-monospace,monospace;
  font-size:10.5px;line-height:19px;padding:0 5px;white-space:nowrap;color:var(--frame-ink);
  font-variant-numeric:tabular-nums}
.f:focus-visible{outline:2px solid var(--brand);outline-offset:1px}
.f:hover{filter:brightness(1.14)}
.f.request{background:var(--request)}
.f.logic{background:var(--logic)}
.f.data{background:var(--data)}
.axis{display:flex;justify-content:space-between;color:var(--ink-faint);
  font-family:"JetBrains Mono",ui-monospace,monospace;font-size:10.5px;
  font-variant-numeric:tabular-nums;margin-top:5px}
.legend{display:flex;gap:18px;flex-wrap:wrap;align-items:center;margin-top:18px;
  font-size:13px;color:var(--ink-muted)}
.legend i{width:11px;height:11px;border-radius:2px;display:inline-block;
  margin-right:7px;vertical-align:-1px}
table{border-collapse:collapse;width:100%;font-size:13px;margin-top:8px}
th{text-align:left;font-family:"JetBrains Mono",ui-monospace,monospace;font-size:10px;
  text-transform:uppercase;letter-spacing:.06em;color:var(--ink-faint);font-weight:500;
  padding:6px 8px;border-bottom:1px solid var(--line)}
td{padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
td.n{font-family:"JetBrains Mono",ui-monospace,monospace;
  font-variant-numeric:tabular-nums;text-align:right;white-space:nowrap}
td.sp{font-family:"JetBrains Mono",ui-monospace,monospace;font-size:11.5px;
  word-break:break-all}
.dot{width:8px;height:8px;border-radius:2px;display:inline-block;margin-right:8px}
.dupes{display:flex;flex-direction:column;gap:3px}
.dupe{font-family:"JetBrains Mono",ui-monospace,monospace;font-size:11.5px;
  color:var(--ink-muted);word-break:break-all}
.dupe b{color:var(--logic);font-variant-numeric:tabular-nums;margin-right:8px}
#tip{position:fixed;z-index:20;pointer-events:none;display:none;max-width:520px;
  background:var(--surface);border:1px solid var(--line);border-radius:6px;
  padding:10px 12px;font-size:12.5px;box-shadow:var(--shadow);color:var(--ink)}
#tip .t{font-family:"JetBrains Mono",ui-monospace,monospace;font-size:11.5px;
  font-weight:500;margin-bottom:4px;word-break:break-all}
#tip .m{color:var(--ink-muted);font-family:"JetBrains Mono",ui-monospace,monospace;
  font-size:11px;font-variant-numeric:tabular-nums}
#tip code{display:block;margin-top:7px;color:var(--ink-faint);font-size:10.5px;
  white-space:pre-wrap;word-break:break-all;font-family:"JetBrains Mono",ui-monospace,monospace}
details{margin-top:14px}
summary{cursor:pointer;font-size:13px;color:var(--ink-muted)}
summary:focus-visible{outline:2px solid var(--brand);outline-offset:2px}
.note{background:var(--surface-2);border:1px solid var(--line);border-radius:6px;
  padding:15px 17px;margin-top:38px;font-size:13.5px;color:var(--ink-muted);
  line-height:1.65}
.note b{color:var(--ink)}
.note code{font-family:"JetBrains Mono",ui-monospace,monospace;font-size:12px;
  color:var(--ink-muted)}
@media (prefers-reduced-motion:reduce){*{transition:none!important}}
"""

JS = """
const tip=document.getElementById('tip');
function show(e,d){
  tip.innerHTML='<div class="t">'+d.n+'</div><div class="m">'+d.ms+' ms'+
    (d.count>1?' · '+d.count+' calls':'')+(d.svc?' · '+d.svc:'')+'</div>'+
    (d.sql?'<code>'+d.sql+'</code>':'');
  tip.style.display='block';move(e);
}
function move(e){
  const p=10,w=tip.offsetWidth,h=tip.offsetHeight;
  let x=e.clientX+p,y=e.clientY+p;
  if(x+w>innerWidth-8)x=e.clientX-w-p;
  if(y+h>innerHeight-8)y=e.clientY-h-p;
  tip.style.left=x+'px';tip.style.top=y+'px';
}
function hide(){tip.style.display='none';}
function render(host,root,zoom){
  const base=zoom||root, rows=[];
  (function walk(n,off,scale){
    const x=(n.x-base.x)*scale+0, w=n.w*scale;
    if(w>0.02&&x<100.01&&x+w>-0.01){
      (rows[n.d]=rows[n.d]||[]).push({d:n,x:Math.max(0,x),w:Math.min(w,100-Math.max(0,x))});
    }
    n.c.forEach(c=>walk(c,off,scale));
  })(root,0,100/base.w);
  host.innerHTML='';
  const top=base.d;
  rows.forEach((r,depth)=>{
    if(depth<top)return;
    const row=document.createElement('div');row.className='row';
    r.forEach(f=>{
      const el=document.createElement('div');
      el.className='f '+f.d.k;
      el.style.left=f.x+'%';el.style.width=f.w+'%';
      el.textContent=f.w>3.5?(f.d.n.length>110?f.d.n.slice(0,110)+'…':f.d.n)+
        (f.d.count>1?'  ×'+f.d.count:''):'';
      el.title=f.d.n+' — '+f.d.ms+'ms';
      el.onmousemove=e=>show(e,f.d);el.onmouseleave=hide;
      el.onclick=()=>{hide();render(host,root,f.d===base?null:f.d);};
      row.appendChild(el);
    });
    host.appendChild(row);
  });
}
document.querySelectorAll('[data-flame]').forEach(h=>{
  const root=JSON.parse(h.getAttribute('data-flame'));
  h.removeAttribute('data-flame');
  h._root=root;
  render(h,root);
  // Zoom is one click in; getting back out should not depend on finding the
  // same frame again after the layout has changed under you.
  h.addEventListener('dblclick',()=>{hide();render(h,root);});
});
addEventListener('keydown',e=>{
  if(e.key==='Escape')document.querySelectorAll('.flame').forEach(h=>h._root&&render(h,h._root));
});
"""


def esc(x):
    return html.escape(str(x))


def flame_block(node, caption, axis_left, axis_right):
    return (f'<h3>{esc(caption)}</h3>'
            f'<div class="flame" data-flame=\'{json.dumps(node).replace(chr(39), "&#39;")}\'></div>'
            f'<div class="axis"><span>{esc(axis_left)}</span>'
            f'<span>{esc(axis_right)}</span></div>')


ranked = sorted(screens, key=lambda s: -s["requests"])
worst = ranked[0] if ranked else None

parts = [f'''<div class="wrap">
<p class="eyebrow">Formula 1 solution · OpenTelemetry</p>
<h1>Where the time goes, screen by screen</h1>
<p class="lede">Six screens of the fan frontend, traced end to end. The consumed
OData client propagates trace context, so a single stack runs from the browser's
request, through the service call, into the backend microflow and down to the
DuckDB scan underneath it — two apps, one flame.</p>
<p class="meta">Captured from a scripted walk with both apps under
<code>mxcli run --trace-otlp</code>, {len(spans):,} spans in all. Tracing costs
roughly 3× wall time, so the shapes and the ratios are what to read, not the
absolute milliseconds.</p>
<div class="legend">
  <span><i style="background:var(--request)"></i>Request handling</span>
  <span><i style="background:var(--logic)"></i>Application logic</span>
  <span><i style="background:var(--data)"></i>Data — Postgres and DuckDB</span>
  <span style="color:var(--ink-faint)">Click a frame to zoom · double-click or Esc to reset</span>
</div>''']

for s in sorted(screens, key=lambda x: -x["requests"]):
    dupes = "".join(
        f'<p class="dupe"><b>×{n}</b> &nbsp;{esc(u)}</p>' for u, n in s["dupes"])
    rows = "".join(
        f'<tr><td><span class="dot" style="background:var(--{k})"></span>{esc(n)}</td>'
        f'<td class="n">{c}</td><td class="n">{ms}</td></tr>'
        for n, k, c, ms in s["table"])
    parts.append(f'''
<section class="screen">
<div class="head"><h2>{esc(s["label"])}</h2>
  <span class="rank">{"heaviest screen" if s is worst else ""}</span></div>
<div class="tiles">
  <div class="tile{" hot" if s["requests"] > 3 * s["distinct"] else ""}"><div class="k">Backend calls</div><div class="v">{s["requests"]}</div>
    <div class="s">{s["distinct"]} distinct</div></div>
  <div class="tile"><div class="k">Backend time</div><div class="v">{s["backend_ms"] / 1000:.1f}s</div>
    <div class="s">summed, not wall</div></div>
  <div class="tile"><div class="k">Slowest request</div><div class="v">{s["timeline_ms"] / 1000:.1f}s</div>
    <div class="s">one call</div></div>
</div>
{dupes and '<h3>Repeated calls</h3>' + dupes}
{flame_block(s["timeline"], f'Slowest single request — {s["timeline_name"]}',
             '0 ms', f'{s["timeline_ms"]:.0f} ms')}
{flame_block(s["merged"], 'Every span this screen produced, folded by call path',
             'share of total work', f'{s["merged"]["ms"] / 1000:.1f}s summed')}
<details><summary>Same data as a table — top paths by self time</summary>
<table><thead><tr><th>Span</th><th class="n">Calls</th><th class="n">Self ms</th></tr></thead>
<tbody>{rows}</tbody></table></details>
</section>''')

parts.append('''
<div class="note"><b>Reading the two flames.</b> The first is real time: x is the
offset from the request's start, so a wide frame with a narrow child was waiting.
The second is not time but share of work — every span folded by call path and
summed — so a query issued twenty-eight times is twenty-eight times wider than
one issued once. Frames carry their own labels and a <code>×n</code> where they
repeat, and each screen's table gives the same ranking without relying on colour.
</div>
</div><div id="tip"></div>''')

open(out_path, "w").write(
    f"<title>Formula 1 — screen performance flame charts</title>\n"
    f"<style>{FONTS}</style>\n"
    f"<style>{CSS}</style>\n" + "\n".join(parts) + f"\n<script>{JS}</script>\n")
print(f"{out_path}: {len(screens)} screens, {len(spans)} spans")
