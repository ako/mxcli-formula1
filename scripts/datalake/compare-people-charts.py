#!/usr/bin/env python3
"""Compare the Constructor and Driver screens' lake charts with the old ones.

    scripts/datalake/compare-people-charts.py teampoints|teamposition|career|qualrace [limit]

The old DSJ_ microflows read the backend's fan service (F1Fan TeamSeason,
DriverSeasons, DriverRaces) and built the chart rows in a loop. This reads the
same service, builds the rows the same way, and compares them, constructor by
constructor or driver by driver, with what the frontend's lake query returns.
The lake side runs the frontend's own SQL (05-chart-data.mdl's F1Lake queries,
copied below with the parameter filled in), so the query is tested too, not
only the gold view.

Rows are compared as multisets; the specs do not depend on order. Needs the
backend on :8080 and the lake on :9495. Exits 1 if anything differs.
"""
import json, sys, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor

BACKEND = "http://127.0.0.1:8080/odata/"
API_KEY = "f1-ops-key-2f8a1c"
LAKE = "http://127.0.0.1:9495/api/sql"
TOKEN = "duckgraphlake"


def odata(path, flt):
    url = BACKEND + path + "?" + urllib.parse.urlencode({"$filter": flt})
    rows = []
    while url:
        page = json.load(urllib.request.urlopen(urllib.request.Request(url, headers={"x-api-key": API_KEY})))
        rows += page["value"]
        url = page.get("@odata.nextLink")
    return rows


def lake_json(sql):
    req = urllib.request.Request(LAKE, data=sql.encode(), method="POST", headers={"Authorization": f"Bearer {TOKEN}"})
    rows = json.load(urllib.request.urlopen(req))["rows"]
    return json.loads(rows[0][0]) if rows else []


def q(s):
    return "'" + s.replace("'", "''") + "'"


# --- the frontend's queries (keep in step with 05-chart-data.mdl) -----------
# Every {c} is compared with a column. With a parameter the lake cannot type --
# one in a SELECT list, like SELECT {c} AS c -- the lake labels every result
# column 'unknown', and Mendix cannot map the result (FINDINGS §115).
SQL = {
 "teampoints": """SELECT COALESCE(CAST(to_json(list({'code': code, 'round': round, 'driver': driver, 'seat': seat, 'pts': round(pts, 2)}
       ORDER BY round, seat)) AS VARCHAR), '[]') AS json
FROM (SELECT code, round, driver1_name AS driver, 'Seat 1' AS seat, driver1_points AS pts
      FROM gold.team_latest_season WHERE constructor_id = {c} AND driver1_name IS NOT NULL
      UNION ALL
      SELECT code, round, driver2_name, 'Seat 2', driver2_points
      FROM gold.team_latest_season WHERE constructor_id = {c} AND driver2_name IS NOT NULL) p""",
 "teamposition": """SELECT COALESCE(CAST(to_json(list({'code': code, 'round': round, 'race': race_name, 'pos': standing_position}
       ORDER BY round)) AS VARCHAR), '[]') AS json
FROM gold.team_latest_season WHERE constructor_id = {c} AND standing_position IS NOT NULL""",
 "career": """SELECT COALESCE(CAST(to_json(list({'year': year, 's': s, 'v': v} ORDER BY year, s)) AS VARCHAR), '[]') AS json
FROM (SELECT year, 'Points' AS s, round(points, 2) AS v FROM gold.driver_seasons WHERE driver_id = {c}
      UNION ALL
      SELECT year, 'Finish', standing_order FROM gold.driver_seasons
      WHERE driver_id = {c} AND standing_position <> '-' AND standing_order < 100) p""",
 "qualrace": """SELECT COALESCE(CAST(to_json(list({'q': qualifying_position, 'r': finish_position, 'race': race_name, 'round': round}
       ORDER BY round)) AS VARCHAR), '[]') AS json
FROM gold.driver_latest_races
WHERE driver_id = {c} AND qualifying_position IS NOT NULL AND finish_position IS NOT NULL""",
}


# --- the old microflows, rebuilt over the backend's fan service --------------
def old_teampoints(c):
    out = []
    for r in odata("f1-fan/TeamSeason", f"constructorId eq {q(c)}"):
        for k, seat in ((1, "Seat 1"), (2, "Seat 2")):
            if r.get(f"driver{k}Name") and r.get(f"driver{k}Points") is not None:
                out.append({"code": r["code"], "round": r["round"], "driver": r[f"driver{k}Name"],
                            "seat": seat, "pts": round(float(r[f"driver{k}Points"]), 2)})
    return out


def old_teamposition(c):
    return [{"code": r["code"], "round": r["round"], "race": r["raceName"], "pos": r["standingPosition"]}
            for r in odata("f1-fan/TeamSeason", f"constructorId eq {q(c)}") if r.get("standingPosition") is not None]


def old_career(d):
    out = []
    for s in odata("f1-fan/DriverSeasons", f"driverId eq {q(d)}"):
        out.append({"year": s["year"], "s": "Points", "v": round(float(s["points"]), 2)})
        if (s.get("standingOrder") is not None and s.get("standingPosition") not in (None, "-")
                and s["standingOrder"] < 100):
            out.append({"year": s["year"], "s": "Finish", "v": s["standingOrder"]})
    return out


def old_qualrace(d):
    seasons = odata("f1-fan/DriverSeasons", f"driverId eq {q(d)}")
    year = max((s["year"] for s in seasons), default=0)
    return [{"q": r["qualifyingPosition"], "r": r["finishPosition"], "race": r["raceName"], "round": r["round"]}
            for r in odata("f1-fan/DriverRaces", f"driverId eq {q(d)} and year eq {year}")
            if r.get("qualifyingPosition") is not None and r.get("finishPosition") is not None]


def norm(rows):
    return sorted(json.dumps({k: (round(float(v), 2) if isinstance(v, (int, float)) and not isinstance(v, bool) else v)
                              for k, v in sorted(r.items())}) for r in rows)


def compare(chart, key):
    old = globals()["old_" + chart](key)
    new = lake_json(SQL[chart].replace("{c}", q(key)))
    a, b = norm(old), norm(new)
    return key, a == b, len(a), len(b), (sorted(set(a) - set(b))[:2], sorted(set(b) - set(a))[:2])


def main():
    chart = sys.argv[1]
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else None
    table = "f1.constructors" if chart.startswith("team") else "f1.drivers"
    keys = [r[0] for r in json.load(urllib.request.urlopen(urllib.request.Request(
        LAKE, data=f"SELECT id FROM {table} ORDER BY id".encode(), method="POST",
        headers={"Authorization": f"Bearer {TOKEN}"})))["rows"]][:limit]
    with ThreadPoolExecutor(6) as pool:
        results = list(pool.map(lambda k: compare(chart, k), keys))
    bad = [r for r in results if not r[1]]
    for key, _, na, nb, (only_old, only_new) in bad[:10]:
        print(f"{key}: old {na}, lake {nb}; only old {only_old}; only lake {only_new}")
    print(f"{chart}: {len(results) - len(bad)} of {len(results)} identical")
    sys.exit(1 if bad else 0)


main()
