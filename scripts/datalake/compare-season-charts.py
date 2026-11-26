#!/usr/bin/env python3
"""Compare the Season screen's lake charts with what the frontend used to draw.

    scripts/datalake/compare-season-charts.py teams|multiples [first_year] [last_year]

The old DSJ_ microflows read the backend's cached OData (F1Cached), built the
chart's rows in a loop and wrote them as JSON. This reads the same OData,
builds the same rows the same way, and compares them, season by season, with
the rows the frontend's new lake query serialises (gold.season_teams,
gold.season_multiples). Rows are compared as sets: neither old microflow
sorted, and the Vega specs do not depend on row order.

Needs the backend on :8080 and the lake on :9495. Exits 1 if any season differs.
"""
import json, sys, urllib.parse, urllib.request

BACKEND = "http://127.0.0.1:8080/odata/f1/"
API_KEY = "f1-ops-key-2f8a1c"          # Formula1Backend.ApiKey's dev default
LAKE = "http://127.0.0.1:9495/api/sql"
TOKEN = "duckgraphlake"                 # the lake's default on loopback


def odata(entity_set, flt):
    url = BACKEND + entity_set + "?" + urllib.parse.urlencode({"$filter": flt})
    rows = []
    while url:
        page = json.load(urllib.request.urlopen(urllib.request.Request(url, headers={"x-api-key": API_KEY})))
        rows += page["value"]
        url = page.get("@odata.nextLink")
    return rows


def lake(sql):
    req = urllib.request.Request(LAKE, data=sql.encode(), method="POST",
                                 headers={"Authorization": f"Bearer {TOKEN}"})
    res = json.load(urllib.request.urlopen(req))
    if res.get("truncated"):
        sys.exit("lake result truncated")
    return res["rows"]


COLOURS = {"red-bull": "#3671C6", "mclaren": "#FF8000", "ferrari": "#E8002D", "mercedes": "#27F4D2",
           "aston-martin": "#229971", "alpine": "#FF87BC", "haas": "#B6BABD", "rb": "#6692FF",
           "racing-bulls": "#6692FF", "williams": "#64C4FF", "sauber": "#52E252", "alphatauri": "#5E8FAA",
           "alfa-romeo": "#C92D4B", "audi": "#BB0A30", "cadillac": "#C9B037"}


def old_teams(year):
    # DS_SeasonTeamRows + DSJ_SeasonTeams: {team, pts: round(points, 2), colour}
    return sorted((r["constructorName"], round(float(r["points"] or 0), 2), COLOURS.get(r["constructorId"], "#2DD4BF"))
                  for r in odata("ConstructorStandings", f"year eq {year}"))


def new_teams(year):
    return sorted((t, round(float(p or 0), 2), c) for t, p, c in
                  lake(f"SELECT team, points, colour FROM gold.season_teams WHERE year = {year}"))


def old_multiples(year):
    # DSJ_SeasonMultiples: top ten by positionOrder, matched to RaceResults by name
    top = sorted(odata("DriverStandings", f"year eq {year}"), key=lambda r: r["positionOrder"])[:10]
    names = {r["driverName"] for r in top}
    out = []
    for r in odata("RaceResults", f"year eq {year}"):
        if r["driverName"] and r["driverName"] in names:
            pos = r["position"]
            out.append((r["driverName"], r["round"], pos, 0 if pos is not None else 1))
    return sorted(out, key=str)


def new_multiples(year):
    return sorted(((n, r, p, d) for n, r, p, d in
                   lake(f"SELECT driver_name, round, pos, dnf FROM gold.season_multiples WHERE year = {year}")), key=str)


def main():
    chart = sys.argv[1]
    first = int(sys.argv[2]) if len(sys.argv) > 2 else 1950
    last = int(sys.argv[3]) if len(sys.argv) > 3 else 2026
    old, new = {"teams": (old_teams, new_teams), "multiples": (old_multiples, new_multiples)}[chart]
    differ = 0
    for year in range(first, last + 1):
        a, b = old(year), new(year)
        if a == b:
            continue
        differ += 1
        print(f"{year}: old {len(a)} rows, lake {len(b)}; only old: {sorted(set(a) - set(b), key=str)[:3]}; "
              f"only lake: {sorted(set(b) - set(a), key=str)[:3]}")
    total = last - first + 1
    print(f"{chart}: {total - differ} of {total} seasons identical")
    sys.exit(1 if differ else 0)


main()
