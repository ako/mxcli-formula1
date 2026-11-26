#!/usr/bin/env python3
"""Compare the Race weekend screen's lake charts with the old ones.

    scripts/datalake/compare-weekend-charts.py shape|pace|laps [limit] [start]

The old DSJ_ microflows read the backend's fan service (F1Fan WeekendShape,
RaceSessions, LapChart), built the chart rows in a loop and wrote JSON. This
reads the same service, builds the rows the same way, and compares them, race by
race, with what the frontend's lake query returns. The lake side runs the
frontend's own SQL (05-chart-data.mdl's F1Lake queries, kept in step with the
SQL dict below), so the query is tested as well as the view.

Every parameter is compared with a column, CAST to the column's type: a bare
parameter in a SELECT list makes the lake lose the result's column names, and
Mendix then cannot map it (FINDINGS §115).

Rows are compared as multisets, numbers rounded to 3 places. Needs the backend
on :8080 and the lake on :9495. Exits 1 if anything differs.
"""
import json, sys, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor

BACKEND = "http://127.0.0.1:8080/odata/f1-fan/"
API_KEY = "f1-ops-key-2f8a1c"
LAKE = "http://127.0.0.1:9495/api/sql"
TOKEN = "duckgraphlake"

SQL = {
 "shape": """SELECT COALESCE(CAST(to_json(list({'i': session_index, 'session': session_label, 'driver': driver, 'pos': pos}
       ORDER BY session_index, rk)) AS VARCHAR), '[]') AS json
FROM gold.weekend_shape
WHERE race_id = CAST({raceId} AS BIGINT) AND pos IS NOT NULL""",
 "pace": """SELECT COALESCE(CAST(to_json(list({'driver': drv, 'session': session, 'gap': gap}
       ORDER BY o, k)) AS VARCHAR), '[]') AS json
FROM (SELECT position_order AS o, 1 AS k, abbreviation AS drv, 'FP1' AS session, fp1_gap AS gap
      FROM gold.race_sessions WHERE race_id = CAST({raceId} AS BIGINT) AND fp1_gap IS NOT NULL
      UNION ALL SELECT position_order, 2, abbreviation, 'FP2', fp2_gap
      FROM gold.race_sessions WHERE race_id = CAST({raceId} AS BIGINT) AND fp2_gap IS NOT NULL
      UNION ALL SELECT position_order, 3, abbreviation, 'FP3', fp3_gap
      FROM gold.race_sessions WHERE race_id = CAST({raceId} AS BIGINT) AND fp3_gap IS NOT NULL
      UNION ALL SELECT position_order, 4, abbreviation, 'Qualifying', qual_gap
      FROM gold.race_sessions WHERE race_id = CAST({raceId} AS BIGINT) AND qual_gap IS NOT NULL
      UNION ALL SELECT position_order, 5, abbreviation, 'Best race lap', best_lap_gap
      FROM gold.race_sessions WHERE race_id = CAST({raceId} AS BIGINT) AND best_lap_gap IS NOT NULL) p""",
 "laps": """SELECT COALESCE(CAST(to_json(list({'lap': lap, 'driver': driver, 'pos': pos}
       ORDER BY lap, rk)) AS VARCHAR), '[]') AS json
FROM gold.lap_chart
WHERE year = CAST({year} AS BIGINT) AND round = CAST({round} AS BIGINT) AND pos IS NOT NULL""",
}


def odata(path, flt):
    url = BACKEND + path + "?" + urllib.parse.urlencode({"$filter": flt})
    rows = []
    while url:
        page = json.load(urllib.request.urlopen(urllib.request.Request(url, headers={"x-api-key": API_KEY})))
        rows += page["value"]
        url = page.get("@odata.nextLink")
    return rows


def lake(sql):
    req = urllib.request.Request(LAKE, data=sql.encode(), method="POST", headers={"Authorization": f"Bearer {TOKEN}"})
    res = json.load(urllib.request.urlopen(req))
    if res.get("truncated"):            # the HTTP API stops at 1000 rows
        sys.exit("lake result truncated: page the query")
    return res["rows"]


def old_shape(race):
    out = []
    for w in odata("WeekendShape", f"raceId eq {race['raceId']}"):
        for k in range(1, 11):
            if w.get(f"s{k}name") and w.get(f"s{k}value") is not None:
                out.append({"i": w["sessionIndex"], "session": w["sessionLabel"], "driver": w[f"s{k}name"], "pos": w[f"s{k}value"]})
    return out


def old_pace(race):
    out = []
    for s in odata("RaceSessions", f"raceId eq {race['raceId']}"):
        for col, label in (("fp1Gap", "FP1"), ("fp2Gap", "FP2"), ("fp3Gap", "FP3"), ("qualGap", "Qualifying"), ("bestLapGap", "Best race lap")):
            if s.get(col) is not None:
                # The old microflow wrote this key as "drv", but the chart's spec reads
                # "driver", so every point landed on one "undefined" row. The lake
                # query writes "driver" on purpose (FINDINGS §116); compare against that.
                out.append({"driver": s["abbreviation"], "session": label, "gap": round(float(s[col]), 3)})
    return out


def old_laps(race):
    out = []
    for l in odata("LapChart", f"year eq {race['year']} and round eq {race['round']}"):
        for k in range(1, 11):
            if l.get(f"s{k}name") and l.get(f"s{k}value") is not None:
                out.append({"lap": l["lap"], "driver": l[f"s{k}name"], "pos": l[f"s{k}value"]})
    return out


def norm(rows):
    return sorted(json.dumps({k: (round(float(v), 3) if isinstance(v, (int, float)) and not isinstance(v, bool) else v)
                              for k, v in sorted(r.items())}) for r in rows)


def compare(chart, race):
    old = globals()["old_" + chart](race)
    sql = SQL[chart]
    for k, v in race.items():
        sql = sql.replace("{" + k + "}", "'" + str(v) + "'")
    rows = lake(sql)
    new = json.loads(rows[0][0]) if rows else []
    a, b = norm(old), norm(new)
    return race, a == b, len(a), len(b), (sorted(set(a) - set(b))[:2], sorted(set(b) - set(a))[:2])


def main():
    chart = sys.argv[1]
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else None
    where = "WHERE (year, round) IN (SELECT DISTINCT year, round FROM f1.laps)" if chart == "laps" else ""
    races, page = [], 0
    while True:                         # 500 at a time: the HTTP API caps a result at 1000 rows
        rows = lake(f"SELECT id, year, round FROM f1.races {where} ORDER BY id LIMIT 500 OFFSET {page * 500}")
        races += [{"raceId": r[0], "year": r[1], "round": r[2]} for r in rows]
        if len(rows) < 500:
            break
        page += 1
    start = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    races = races[start:][:limit]
    with ThreadPoolExecutor(6) as pool:
        results = list(pool.map(lambda r: compare(chart, r), races))
    bad = [r for r in results if not r[1]]
    for race, _, na, nb, (only_old, only_new) in bad[:8]:
        print(f"{race}: old {na}, lake {nb}; only old {only_old}; only lake {only_new}")
    print(f"{chart}: {len(results) - len(bad)} of {len(results)} races identical")
    sys.exit(1 if bad else 0)


main()
