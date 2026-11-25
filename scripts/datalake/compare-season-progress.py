#!/usr/bin/env python3
"""Compare the backend's SeasonProgress with the lake's gold.season_progress.

    scripts/datalake/compare-season-progress.py [first_year] [last_year]

The backend computes one season per request (Read_SeasonProgress, a pivot with
d1..d5 columns); the lake has every season in long form. This unpivots the
backend's rows the way the frontend's DSJ_SeasonProgress does -- a (round,
driver, points) entry per non-empty seat -- and compares them with the lake's,
season by season: same rounds, same race names, same five drivers in the same
seats, same running totals.

Needs the backend on :8080 (its fan service takes the x-api-key the model
defines) and the lake on :9495. Exits 1 if any season differs.
"""
import json, sys, urllib.parse, urllib.request

BACKEND = "http://127.0.0.1:8080/odata/f1-fan/SeasonProgress"
API_KEY = "f1-ops-key-2f8a1c"          # Formula1Backend.ApiKey's dev default
LAKE = "http://127.0.0.1:9495/api/sql"
TOKEN = "duckgraphlake"                 # the lake's default on loopback


def backend(year):
    q = urllib.parse.urlencode({"$filter": f"year eq {year}", "$orderby": "round"})
    req = urllib.request.Request(f"{BACKEND}?{q}", headers={"x-api-key": API_KEY})
    rows = json.load(urllib.request.urlopen(req))["value"]
    out = []
    for r in rows:
        for k in range(1, 6):
            name, pts = r.get(f"d{k}Name"), r.get(f"d{k}Points")
            if name and pts is not None:
                out.append((r["round"], k, r["raceName"], name, round(float(pts), 2)))
    return sorted(out)


def lake(first, last):
    sql = ("SELECT year, round, rk, race_name, driver_name, points FROM gold.season_progress "
           f"WHERE year BETWEEN {first} AND {last} ORDER BY year, round, rk")
    req = urllib.request.Request(LAKE, data=sql.encode(), method="POST",
                                 headers={"Authorization": f"Bearer {TOKEN}"})
    res = json.load(urllib.request.urlopen(req))
    if res.get("truncated"):
        sys.exit("lake result truncated: narrow the year range")
    by_year = {}
    for y, rnd, rk, race, name, pts in res["rows"]:
        by_year.setdefault(y, []).append((rnd, rk, race, name, round(float(pts), 2)))
    return {y: sorted(v) for y, v in by_year.items()}


def main():
    first = int(sys.argv[1]) if len(sys.argv) > 1 else 1950
    last = int(sys.argv[2]) if len(sys.argv) > 2 else 2026
    differ = 0
    for lo in range(first, last + 1, 10):       # the lake's HTTP API caps at 1000 rows
        hi = min(lo + 9, last)
        lk = lake(lo, hi)
        for year in range(lo, hi + 1):
            b, l = backend(year), lk.get(year, [])
            if b == l:
                continue
            differ += 1
            first_diff = next((i for i, (x, y) in enumerate(zip(b, l)) if x != y), min(len(b), len(l)))
            print(f"{year}: backend {len(b)} entries, lake {len(l)}; first difference at {first_diff}:")
            print(f"   backend {b[first_diff] if first_diff < len(b) else None}")
            print(f"   lake    {l[first_diff] if first_diff < len(l) else None}")
    total = last - first + 1
    print(f"{total - differ} of {total} seasons identical")
    sys.exit(1 if differ else 0)


main()
