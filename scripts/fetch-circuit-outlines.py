#!/usr/bin/env python3
"""Trace every circuit outline from OpenStreetMap into an SVG path.

Not from the Wikipedia diagrams. Those are drawings -- each one hand-authored
with its own viewBox, its own stroke weights, embedded corner labels and DRS
markers -- so using them means downloading seventy files under CC BY-SA and
cleaning each one by hand, and the result is still a picture rather than a
measurement.

OpenStreetMap maps a circuit as what it is: a chain of one-way ways carrying
real coordinates, usually one per named corner. Stitching them in racing order
gives a closed loop of lat/long, which projects to an SVG path -- and, because
it is geometry rather than artwork, it can be checked. Every outline here is
measured against the length f1db records for that circuit and rejected if it
disagrees by more than a few per cent, which is what catches a loop that
followed the pit lane or an old layout.

    python3 scripts/fetch-circuit-outlines.py                # the current calendar
    python3 scripts/fetch-circuit-outlines.py --all          # every circuit f1db has
    python3 scripts/fetch-circuit-outlines.py zandvoort monza

Responses are cached under data/circuits/.cache/, so a re-run costs nothing and
the shared Overpass service is asked once per circuit. Output is
data/circuits/f1db-circuit-paths.csv plus one SVG per circuit for inspection.

Licence: OpenStreetMap data, ODbL 1.0, (c) OpenStreetMap contributors. The
attribution travels in the CSV so whatever renders it can show it.
"""
import argparse, csv, json, math, pathlib, sys, time, urllib.parse, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
F1DB = ROOT / "data" / "f1db" / "f1db-circuits.csv"
RACES = ROOT / "data" / "f1db" / "f1db-races.csv"
OUT = ROOT / "data" / "circuits"
CACHE = OUT / ".cache"

# Overpass is free and shared. Three mirrors, a widening pause, and a cache so
# a re-run asks nothing at all.
MIRRORS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]
UA = "mxcli-formula1/1.0 (sample app; https://github.com/ako/mxcli-formula1)"

# A pit lane is a raceway too, and it branches off the racing line at both ends,
# so a naive walk can take it and come back with a loop that is short by a third.
PIT_WORDS = ("pit", "pitstraat", "boxen", "voie des stands", "boxes", "paddock")


def overpass(circuit_id, lat, lon, radius=3500):
    cached = CACHE / f"{circuit_id}.json"
    if cached.exists():
        return json.loads(cached.read_text())
    query = (f"[out:json][timeout:90];way(around:{radius},{lat},{lon})"
             f"[highway=raceway];out geom;")
    # Keep the per-request timeout short and move on. A generous timeout is the
    # wrong instinct against a pool of mirrors: waiting three minutes on a
    # struggling one costs far more than failing over to the next in forty-five
    # seconds, and one slow mirror otherwise stalls the whole calendar.
    last = None
    for attempt in range(6):
        url = MIRRORS[attempt % len(MIRRORS)]
        try:
            req = urllib.request.Request(
                url, data=urllib.parse.urlencode({"data": query}).encode(),
                headers={"User-Agent": UA})
            body = urllib.request.urlopen(req, timeout=45).read()
            elements = json.loads(body).get("elements", [])
            CACHE.mkdir(parents=True, exist_ok=True)
            cached.write_text(json.dumps(elements))
            return elements
        except Exception as exc:                       # 429, 504, a slow mirror
            last = exc
            time.sleep(2 + attempt * 2)
    print(f"  {circuit_id:24s} overpass unreachable ({type(last).__name__})",
          file=sys.stderr, flush=True)
    return []


def is_pit(way):
    name = (way.get("tags", {}).get("name") or "").lower()
    return any(word in name for word in PIT_WORDS)


def stitch(ways):
    """Follow the one-way racing direction from way to way until it closes.

    Every candidate start is tried and the longest closed loop wins, because a
    circuit with an alternative layout maps both and only one of them is the
    Grand Prix track.
    """
    ways = [w for w in ways if w.get("geometry")]
    by_start = {}
    for w in ways:
        head = w["geometry"][0]
        by_start.setdefault((round(head["lat"], 7), round(head["lon"], 7)), []).append(w)

    best = []
    for seed in sorted(ways, key=lambda w: -len(w["geometry"])):
        if is_pit(seed):
            continue
        chain, seen, cur = [seed], {seed["id"]}, seed
        for _ in range(500):
            tail = cur["geometry"][-1]
            key = (round(tail["lat"], 7), round(tail["lon"], 7))
            nxt = [w for w in by_start.get(key, []) if w["id"] not in seen]
            on_track = [w for w in nxt if not is_pit(w)]
            nxt = on_track or nxt
            if not nxt:
                break
            cur = max(nxt, key=lambda w: len(w["geometry"]))
            chain.append(cur)
            seen.add(cur["id"])
        pts = [p for w in chain for p in w["geometry"]]
        # only a loop that came back to where it started is a lap
        if len(pts) > len(best) and close(pts[0], pts[-1], 40):
            best = pts
    return best


def close(a, b, metres):
    return haversine(a, b) * 1000 <= metres


def haversine(a, b):
    R = 6371.0088
    p1, p2 = math.radians(a["lat"]), math.radians(b["lat"])
    dp, dl = p2 - p1, math.radians(b["lon"] - a["lon"])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))


def length_km(pts):
    return sum(haversine(a, b) for a, b in zip(pts, pts[1:]))


def project(pts, size=1000, pad=16):
    """Project lat/long to a local planar frame fitted to a square viewBox.

    Longitude degrees shrink with latitude, so scaling them by cos(lat) is what
    keeps Spa from looking like it was drawn on a different projection to Monza.
    Latitude is negated because SVG's y grows downward and the world's does not.
    """
    lat0 = sum(p["lat"] for p in pts) / len(pts)
    k = math.cos(math.radians(lat0))
    xs = [p["lon"] * k for p in pts]
    ys = [-p["lat"] for p in pts]
    minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)
    span = max(maxx - minx, maxy - miny) or 1
    scale = (size - 2 * pad) / span
    ox = pad + (span - (maxx - minx)) * scale / 2
    oy = pad + (span - (maxy - miny)) * scale / 2
    return [((x - minx) * scale + ox, (y - miny) * scale + oy)
            for x, y in zip(xs, ys)]


def _rdp(xy, tol):
    """Ramer-Douglas-Peucker over an open polyline."""
    if len(xy) < 3:
        return xy
    keep = [False] * len(xy)
    keep[0] = keep[-1] = True
    stack = [(0, len(xy) - 1)]
    while stack:
        i, j = stack.pop()
        ax, ay = xy[i]
        bx, by = xy[j]
        dx, dy = bx - ax, by - ay
        norm = math.hypot(dx, dy) or 1
        worst, at = 0.0, None
        for m in range(i + 1, j):
            px, py = xy[m]
            d = abs(dy * px - dx * py + bx * ay - by * ax) / norm
            if d > worst:
                worst, at = d, m
        if at is not None and worst > tol:
            keep[at] = True
            stack += [(i, at), (at, j)]
    return [p for p, k in zip(xy, keep) if k]


def simplify(xy, tol=2.0):
    """Ramer-Douglas-Peucker over a *closed* loop, in viewBox units.

    Six hundred points is more than a 1000-unit box can show and more than a
    chart wants to carry; dropping the ones that sit within a couple of units of
    the line between their neighbours keeps every corner and roughly quarters
    the row count.

    The closed part is the catch. RDP anchors on the first and last point and
    measures everything against the line between them -- and on a loop those are
    the same point, so that line has no length, every distance from it computes
    as zero, and the whole circuit simplifies to the two anchors. A lap has to be
    cut before it can be simplified: anchor on the start and on the point
    furthest from it, simplify the two arcs separately, and join them back up.
    """
    if len(xy) < 4:
        return xy
    start = xy[0]
    far = max(range(len(xy)), key=lambda m: math.hypot(xy[m][0] - start[0],
                                                       xy[m][1] - start[1]))
    if far in (0, len(xy) - 1):
        return _rdp(xy, tol)
    return _rdp(xy[:far + 1], tol) + _rdp(xy[far:], tol)[1:]


def to_path(pts, size=1000, pad=16):
    """The outline as an SVG path, and as the points it was drawn from."""
    xy = simplify(project(pts, size, pad))
    out = [f"{'M' if i == 0 else 'L'}{x:.1f},{y:.1f}" for i, (x, y) in enumerate(xy)]
    return "".join(out) + "Z", xy


SVG = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" '
       'role="img" aria-label="{name} circuit outline">'
       '<title>{name}</title>'
       '<desc>Traced from OpenStreetMap way geometry. (c) OpenStreetMap '
       'contributors, ODbL 1.0. Traced {traced:.3f} km against {official:.3f} km '
       'recorded by f1db.</desc>'
       '<path d="{d}" fill="none" stroke="#2DD4BF" stroke-width="7" '
       'stroke-linejoin="round" stroke-linecap="round"/></svg>')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("circuits", nargs="*", help="circuit ids; default is the current calendar")
    ap.add_argument("--all", action="store_true", help="every circuit that has held a race")
    ap.add_argument("--tolerance", type=float, default=6.0,
                    help="reject an outline more than this %% from f1db's length")
    args = ap.parse_args()

    circuits = {r["id"]: r for r in csv.DictReader(F1DB.open(encoding="utf-8"))}

    if args.circuits:
        wanted = [c for c in args.circuits if c in circuits]
        missing = set(args.circuits) - set(wanted)
        for m in missing:
            print(f"  unknown circuit id: {m}", file=sys.stderr)
    elif args.all:
        wanted = [i for i, r in circuits.items() if int(r["totalRacesHeld"] or 0) > 0]
    else:
        years = {r["year"] for r in csv.DictReader(RACES.open(encoding="utf-8"))}
        recent = str(max(int(y) for y in years))
        wanted = sorted({r["circuitId"] for r in csv.DictReader(RACES.open(encoding="utf-8"))
                         if r["year"] == recent})
        print(f"the {recent} calendar: {len(wanted)} circuits")

    OUT.mkdir(parents=True, exist_ok=True)
    rows, point_rows, rejected = [], [], []

    for cid in wanted:
        c = circuits.get(cid)
        if not c or not c["latitude"]:
            continue
        print(f"  {cid:24s} ...", end="\r", flush=True)
        ways = overpass(cid, c["latitude"], c["longitude"])
        pts = stitch(ways)
        if not pts:
            rejected.append((cid, "no closed loop in the OSM data"))
            continue

        traced = length_km(pts)
        official = float(c["length"] or 0)
        delta = abs(traced - official) / official * 100 if official else 999
        if delta > args.tolerance:
            rejected.append((cid, f"traced {traced:.3f} km vs f1db {official:.3f} km "
                                  f"({delta:.1f}% out)"))
            continue

        d, xy = to_path(pts)
        (OUT / f"{cid}.svg").write_text(
            SVG.format(size=1000, name=c["fullName"] or c["name"], d=d,
                       traced=traced, official=official))
        rows.append({
            "circuitId": cid, "name": c["name"], "fullName": c["fullName"],
            "viewBox": "0 0 1000 1000", "pathD": d, "points": len(xy),
            "tracedKm": f"{traced:.3f}", "officialKm": f"{official:.3f}",
            "deltaPercent": f"{delta:.2f}",
            "source": "OpenStreetMap", "license": "ODbL 1.0",
            "attribution": "© OpenStreetMap contributors",
        })
        point_rows.extend({"circuitId": cid, "i": i, "x": f"{x:.1f}", "y": f"{y:.1f}"}
                          for i, (x, y) in enumerate(xy))
        print(f"  {cid:24s} {len(xy):4d} pts  {traced:6.3f} km  "
              f"({delta:.1f}% from f1db)", flush=True)

    with (OUT / "f1db-circuit-paths.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, ["circuitId", "name", "fullName", "viewBox", "pathD",
                               "points", "tracedKm", "officialKm", "deltaPercent",
                               "source", "license", "attribution"],
                           quoting=csv.QUOTE_ALL)
        w.writeheader()
        w.writerows(rows)

    # The same outline again, one row per vertex.
    #
    # The path string is what makes the CSV self-contained and what the SVG
    # files are drawn from, but this app charts through Vega and a Vega mark
    # takes rows, not a path. Rather than teach the page to parse SVG, the
    # fetcher writes both representations of the one thing it measured.
    with (OUT / "f1db-circuit-points.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, ["circuitId", "i", "x", "y"], quoting=csv.QUOTE_ALL)
        w.writeheader()
        w.writerows(point_rows)

    print(f"\n{len(rows)} outlines written to {OUT} "
          f"({len(point_rows)} points)")
    if rejected:
        print(f"{len(rejected)} rejected -- an outline that does not measure up is "
              f"left out rather than shown:")
        for cid, why in rejected:
            print(f"  {cid:24s} {why}")


if __name__ == "__main__":
    main()
