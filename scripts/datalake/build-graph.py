#!/usr/bin/env python3
"""Build the lake's graph: lake/mapping/f1.ttl (R2RML) and lake/ontology/f1.ttl.

    scripts/datalake/build-graph.py          # writes both files; needs the lake on :9495

The graph covers all of f1db and the OpenF1 timing the backend posts: one class
per kind of thing, one triples map per view. The spec below says, per class,
which view it reads, its IRI, and how columns become properties; the rest is
derived:

  * datatypes come from the view's column types, read from the running lake, so
    a mapping never claims xsd:integer for a VARCHAR;
  * a column `<x>Id` (driverId, raceId, ...) is a link to that class, not a
    literal, through LINKS below;
  * f1db's `total<X>` columns become `<x>` (totalRaceWins -> raceWins), with the
    renames in RENAME, so the same measure has one name everywhere.

Kept from the first version of the graph, because the frontend's F1Graph OData
client reads them (model/frontend/16-lake-graph.mdl): Driver's name,
abbreviation, nationality (the country id as a string), dateOfBirth,
championships, raceWins, podiums, careerPoints; Race's name, year, round, date
and winner; Constructor's name, fullName, country, championships, raceWins.
Their names and types do not change.

The ontology is applied to queries (subClassOf, domain/range, inverseOf,
symmetric and transitive properties), so it is kept careful: a domain is only
declared for a property one class owns, since `rdfs:domain` makes every subject
of the property an instance of the class.
"""
import json, re, sys, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LAKE = "http://127.0.0.1:9495/api/sql"
DATA = "http://data.formula1.local/"
NS = "http://formula1.local/ns#"

# ----------------------------------------------------------------- classes --
# name: (label, comment, superclass or None)
CLASSES = {
    "Continent": ("Continent", "A continent, as f1db groups countries.", None),
    "Country": ("Country", "A country: where a circuit is, what nationality a driver holds, where a team is based.", None),
    "Circuit": ("Circuit", "A circuit that has held a championship race.", None),
    "CircuitLayout": ("Circuit layout", "One configuration of a circuit, in use from a given year, with its length and number of turns.", None),
    "GrandPrix": ("Grand Prix", "A Grand Prix as a recurring event (the British Grand Prix), across seasons.", None),
    "Season": ("Season", "A championship season, named by its year.", None),
    "Race": ("Race", "One Grand Prix of one season: a round of the championship, and the weekend of sessions around it.", None),
    "Driver": ("Driver", "A person who entered at least one Formula One World Championship race.", None),
    "Constructor": ("Constructor", "A team that built and entered cars in the championship.", None),
    "EngineManufacturer": ("Engine manufacturer", "A company that supplied engines to championship teams.", None),
    "TyreManufacturer": ("Tyre manufacturer", "A company that supplied tyres to championship teams.", None),
    "Engine": ("Engine", "One engine design of an engine manufacturer.", None),
    "Chassis": ("Chassis", "One car design of a constructor.", None),
    "Entrant": ("Entrant", "The organisation that entered cars in a season, under its entry name.", None),
    "FamilyRelationship": ("Family relationship", "How one driver is related to another (parent, sibling, ...), as f1db records it.", None),
    "ConstructorLineageEntry": ("Constructor lineage entry", "One step in a team's history: which constructor raced under it, from which year to which.", None),
    # A season's records
    "SeasonEntrant": ("Season entrant", "An entrant in one season, with the country it entered under.", None),
    "Entry": ("Entry", "An entrant's entry in one season with one constructor and engine manufacturer: the team as it raced, with its chassis, engines and tyres.", None),
    "EntryDriver": ("Entry driver", "A driver of an entry, for the rounds the entry used them.", None),
    "SeasonParticipant": ("Season record", "How a driver, constructor or supplier did over one season.", None),
    "SeasonDriver": ("Season driver", "A driver's season: championship position, starts, wins, points.", "SeasonParticipant"),
    "SeasonConstructor": ("Season constructor", "A constructor's season.", "SeasonParticipant"),
    "SeasonEngineManufacturer": ("Season engine manufacturer", "An engine manufacturer's season.", "SeasonParticipant"),
    "SeasonTyreManufacturer": ("Season tyre manufacturer", "A tyre manufacturer's season.", "SeasonParticipant"),
    "Standing": ("Standing", "A place in a championship table.", None),
    "DriverStanding": ("Driver standing", "A place in the drivers' championship at the end of a season.", "Standing"),
    "ConstructorStanding": ("Constructor standing", "A place in the constructors' championship at the end of a season.", "Standing"),
    "RaceDriverStanding": ("Driver standing after a race", "A place in the drivers' championship after a race.", "Standing"),
    "RaceConstructorStanding": ("Constructor standing after a race", "A place in the constructors' championship after a race.", "Standing"),
    # Sessions of a race weekend, as f1db records them
    "SessionResult": ("Session result", "A car's result in one session of a race weekend: practice, qualifying, the grid, the race, or a record of it such as a pit stop.", None),
    "RaceResult": ("Race result", "A car's classification in the race.", "SessionResult"),
    "SprintRaceResult": ("Sprint result", "A car's classification in the sprint race.", "SessionResult"),
    "QualifyingResult": ("Qualifying result", "A car's place in qualifying, with its Q1, Q2 and Q3 times.", "SessionResult"),
    "Qualifying1Result": ("First qualifying result", "A car's place in the first of two qualifying sessions (older formats).", "SessionResult"),
    "Qualifying2Result": ("Second qualifying result", "A car's place in the second of two qualifying sessions (older formats).", "SessionResult"),
    "PreQualifyingResult": ("Pre-qualifying result", "A car's place in pre-qualifying (late 1980s and early 1990s).", "SessionResult"),
    "SprintQualifyingResult": ("Sprint qualifying result", "A car's place in sprint qualifying (sprint shootout).", "SessionResult"),
    "PracticeResult": ("Practice result", "A car's place in a free practice session.", "SessionResult"),
    "FirstPracticeResult": ("FP1 result", "A car's place in the first free practice.", "PracticeResult"),
    "SecondPracticeResult": ("FP2 result", "A car's place in the second free practice.", "PracticeResult"),
    "ThirdPracticeResult": ("FP3 result", "A car's place in the third free practice.", "PracticeResult"),
    "FourthPracticeResult": ("FP4 result", "A car's place in a fourth free practice (some older weekends).", "PracticeResult"),
    "WarmUpResult": ("Warm-up result", "A car's place in the race-morning warm-up (until 2002).", "SessionResult"),
    "GridPosition": ("Grid position", "A car's place on the starting grid of the race, after penalties.", "SessionResult"),
    "SprintGridPosition": ("Sprint grid position", "A car's place on the starting grid of the sprint.", "SessionResult"),
    "FastestLap": ("Fastest lap", "A car's fastest lap of the race, ranked.", "SessionResult"),
    "PitStop": ("Pit stop", "One pit stop of a car in the race.", "SessionResult"),
    "DriverOfTheDayVote": ("Driver of the Day vote", "A driver's share of the fans' Driver of the Day vote.", "SessionResult"),
    "LapPosition": ("Lap position", "A driver's position and lap time at the end of a lap of a race (Jolpica, the seasons fetched).", None),
    # OpenF1 timing
    "Session": ("Session", "A session as OpenF1 timed it (practice, qualifying, sprint, race), linked to its f1db race weekend.", None),
    "SessionEntry": ("Session entry", "A car in an OpenF1 session: number, code, team, and the f1db driver it is.", None),
    "SessionLap": ("Session lap", "A car's state at the end of a lap of an OpenF1 session: position, gap, lap and sector times, tyre.", None),
    "Stint": ("Stint", "A run on one set of tyres in an OpenF1 session.", None),
    "PitLaneVisit": ("Pit lane visit", "A car's trip through the pit lane in an OpenF1 session.", None),
    "RaceControlMessage": ("Race control message", "A message from race control: flags, safety car, penalties, track limits.", None),
    "WeatherObservation": ("Weather observation", "The weather at the track at a moment of an OpenF1 session.", None),
    "LapForecast": ("Lap forecast", "The race forecaster's call for a car at a lap of a race: how it would have finished, from the laps run until then (replay.forecast).", None),
}

# ----------------------------------------------------- columns to properties --
# A column named here becomes a link to the class, with the predicate given.
# `None` drops the column (it is the subject's own id, or carried by another link).
LINKS = {
    "driverId": ("driver", "Driver"),
    "constructorId": ("constructor", "Constructor"),
    "engineManufacturerId": ("engineManufacturer", "EngineManufacturer"),
    "tyreManufacturerId": ("tyreManufacturer", "TyreManufacturer"),
    "raceId": ("race", "Race"),
    "circuitId": ("circuit", "Circuit"),
    "circuitLayoutId": ("circuitLayout", "CircuitLayout"),
    "grandPrixId": ("grandPrix", "GrandPrix"),
    "continentId": ("continent", "Continent"),
    "chassisId": ("chassis", "Chassis"),
    "engineId": ("engine", "Engine"),
    "entrantId": ("entrant", "Entrant"),
}
# Templates per class (subject IRIs), also used to build links to them.
IRI = {
    "Continent": "continent/{id}", "Country": "country/{id}", "Circuit": "circuit/{id}",
    "CircuitLayout": "circuit-layout/{id}", "GrandPrix": "grand-prix/{id}", "Season": "season/{year}",
    "Race": "race/{id}", "Driver": "driver/{id}", "Constructor": "constructor/{id}",
    "EngineManufacturer": "engine-manufacturer/{id}", "TyreManufacturer": "tyre-manufacturer/{id}",
    "Engine": "engine/{id}", "Chassis": "chassis/{id}", "Entrant": "entrant/{id}",
    "Session": "openf1/session/{session_key}",
}
def link_template(cls, col):
    """The IRI template of a link to `cls`, filled from column `col`."""
    t = IRI[cls]
    return DATA + re.sub(r"\{[^}]+\}", "{" + col + "}", t)

RENAME = {
    "positionDisplayOrder": "positionOrder", "positionNumber": "position", "driverNumber": "carNumber",
    "qualificationPositionNumber": "qualificationPosition", "gridPositionNumber": "gridPosition",
    "totalChampionshipWins": "championships", "totalPoints": "careerPoints",
    "officialName": "name", "type": "circuitType", "totalRacesHeld": "racesHeld",
    "nationalityCountryId": "nationality", "lap_number": "lap", "lap_seconds": "lapSeconds",
}
def predicate(col):
    if col in RENAME:
        return RENAME[col]
    if col.startswith("total") and len(col) > 5:
        rest = col[5:]
        return rest[0].lower() + rest[1:]
    if "_" in col:                      # OpenF1's snake_case
        head, *tail = col.split("_")
        return head + "".join(t[:1].upper() + t[1:] for t in tail)
    return col

# ------------------------------------------------------------ triples maps --
# Each: class, source (a view, or SQL), subject template (relative to DATA),
# extra links {column: (predicate, class)}, columns to drop, renames for this map.
SEASON_LINK = {"year": ("season", "Season")}
RESULT = dict(links=SEASON_LINK, drop={"raceId_unused"})
MAPS = [
    dict(cls="Continent", src="f1.continents", iri="continent/{id}", drop={"id"}),
    dict(cls="Country", src="f1.countries", iri="country/{id}", drop={"id"}),
    dict(cls="Circuit", src="f1.circuits", iri="circuit/{id}", drop={"id"},
         links={"countryId": ("inCountry", "Country")}),
    dict(cls="CircuitLayout", src="f1.circuit_layouts", iri="circuit-layout/{id}", drop={"id"}),
    dict(cls="GrandPrix", src="f1.grands_prix", iri="grand-prix/{id}", drop={"id"},
         links={"countryId": ("inCountry", "Country")}),
    dict(cls="Season", src="f1.seasons", iri="season/{year}"),
    dict(cls="Race", src="""SELECT r.*, w.driverId AS winnerId
            FROM f1.races r LEFT JOIN f1.race_winners w ON w.raceId = r.id""",
         iri="race/{id}", drop={"id"},
         links={"winnerId": ("winner", "Driver"), "year": ("season", "Season")}),
    # Driver: nationality stays the country id as a string (F1Graph reads it);
    # the country links are new and named for what they are.
    dict(cls="Driver", src="""SELECT *, nationalityCountryId AS nationalityCountryRef FROM f1.drivers""",
         iri="driver/{id}", drop={"id"},
         rename={"totalPodiums": "podiums", "totalRaceWins": "raceWins"},
         links={"countryOfBirthCountryId": ("countryOfBirth", "Country"),
                "nationalityCountryRef": ("nationalityCountry", "Country"),
                "secondNationalityCountryId": ("secondNationalityCountry", "Country")}),
    # Constructor: `country` stays the country id as a string, as before.
    dict(cls="Constructor", src="""SELECT *, countryId AS countryRef FROM f1.constructors""",
         iri="constructor/{id}", drop={"id"}, rename={"countryId": "country"},
         links={"countryRef": ("baseCountry", "Country")}),
    dict(cls="EngineManufacturer", src="f1.engine_manufacturers", iri="engine-manufacturer/{id}", drop={"id"},
         links={"countryId": ("baseCountry", "Country")}),
    dict(cls="TyreManufacturer", src="f1.tyre_manufacturers", iri="tyre-manufacturer/{id}", drop={"id"},
         links={"countryId": ("baseCountry", "Country")}),
    dict(cls="Engine", src="f1.engines", iri="engine/{id}", drop={"id"}),
    dict(cls="Chassis", src="f1.chassis", iri="chassis/{id}", drop={"id"}),
    dict(cls="Entrant", src="f1.entrants", iri="entrant/{id}", drop={"id"}),
    dict(cls="FamilyRelationship", src="f1.driver_family_relationships",
         iri="driver/{parentDriverId}/relative/{driverId}", rename={"type": "relationshipType"},
         links={"parentDriverId": ("driver", "Driver"), "driverId": ("relatedDriver", "Driver")}),
    dict(cls="ConstructorLineageEntry", src="f1.constructor_chronology",
         iri="constructor/{parentConstructorId}/lineage/{positionDisplayOrder}",
         links={"parentConstructorId": ("lineageOf", "Constructor")}),
    dict(cls="SeasonEntrant", src="f1.season_entrants", iri="season/{year}/entrant/{entrantId}",
         links={**SEASON_LINK, "countryId": ("entryCountry", "Country")}),
    dict(cls="Entry", src="f1.season_entrant_constructors",
         iri="season/{year}/entry/{entrantId}/{constructorId}/{engineManufacturerId}", links=SEASON_LINK),
    # The entry's chassis, engines and tyres: more links on the same subjects.
    dict(cls="Entry", src="f1.season_entrant_chassis", only={"chassisId"},
         iri="season/{year}/entry/{entrantId}/{constructorId}/{engineManufacturerId}"),
    dict(cls="Entry", src="f1.season_entrant_engines", only={"engineId"},
         iri="season/{year}/entry/{entrantId}/{constructorId}/{engineManufacturerId}"),
    dict(cls="Entry", src="f1.season_entrant_tyre_manufacturers", only={"tyreManufacturerId"},
         iri="season/{year}/entry/{entrantId}/{constructorId}/{engineManufacturerId}"),
    dict(cls="EntryDriver", src="""SELECT *, year AS y2, entrantId AS e2, constructorId AS c2,
                engineManufacturerId AS m2 FROM f1.season_entrant_drivers""",
         iri="season/{year}/entry/{entrantId}/{constructorId}/{engineManufacturerId}/driver/{driverId}",
         drop={"y2", "e2", "c2", "m2"}, links=SEASON_LINK,
         templates={"entry": ("Entry", DATA + "season/{y2}/entry/{e2}/{c2}/{m2}")}),
    dict(cls="SeasonDriver", src="f1.season_drivers", iri="season/{year}/driver/{driverId}",
         links=SEASON_LINK, rename={"totalPoints": "points"}),
    dict(cls="SeasonConstructor", src="f1.season_constructors", iri="season/{year}/constructor/{constructorId}",
         links=SEASON_LINK, rename={"totalPoints": "points"}),
    dict(cls="SeasonEngineManufacturer", src="f1.season_engine_manufacturers",
         iri="season/{year}/engine-manufacturer/{engineManufacturerId}", links=SEASON_LINK, rename={"totalPoints": "points"}),
    dict(cls="SeasonTyreManufacturer", src="f1.season_tyre_manufacturers",
         iri="season/{year}/tyre-manufacturer/{tyreManufacturerId}", links=SEASON_LINK),
    dict(cls="DriverStanding", src="f1.season_driver_standings", iri="season/{year}/driver-standing/{positionDisplayOrder}", links=SEASON_LINK),
    dict(cls="ConstructorStanding", src="f1.season_constructor_standings", iri="season/{year}/constructor-standing/{positionDisplayOrder}", links=SEASON_LINK),
    dict(cls="RaceDriverStanding", src="f1.race_driver_standings", iri="race/{raceId}/driver-standing/{positionDisplayOrder}", links=SEASON_LINK),
    dict(cls="RaceConstructorStanding", src="f1.race_constructor_standings", iri="race/{raceId}/constructor-standing/{positionDisplayOrder}", links=SEASON_LINK),
]
for cls, view, slug in [
    ("RaceResult", "f1.race_results", "race-result"), ("SprintRaceResult", "f1.sprint_results", "sprint-result"),
    ("QualifyingResult", "f1.qualifying_results", "qualifying-result"),
    ("Qualifying1Result", "f1.qualifying_1_results", "qualifying-1-result"),
    ("Qualifying2Result", "f1.qualifying_2_results", "qualifying-2-result"),
    ("PreQualifyingResult", "f1.pre_qualifying_results", "pre-qualifying-result"),
    ("SprintQualifyingResult", "f1.sprint_qualifying_results", "sprint-qualifying-result"),
    ("FirstPracticeResult", "f1.fp1_results", "fp1-result"), ("SecondPracticeResult", "f1.fp2_results", "fp2-result"),
    ("ThirdPracticeResult", "f1.fp3_results", "fp3-result"), ("FourthPracticeResult", "f1.fp4_results", "fp4-result"),
    ("WarmUpResult", "f1.warming_up_results", "warm-up-result"),
    ("GridPosition", "f1.starting_grid", "grid-position"), ("SprintGridPosition", "f1.sprint_starting_grid", "sprint-grid-position"),
    ("FastestLap", "f1.fastest_laps", "fastest-lap"), ("PitStop", "f1.pit_stops", "pit-stop"),
    ("DriverOfTheDayVote", "f1.driver_of_the_day", "driver-of-the-day"),
]:
    MAPS.append(dict(cls=cls, src=view, iri="race/{raceId}/" + slug + "/{positionDisplayOrder}", links=SEASON_LINK))
MAPS += [
    dict(cls="LapPosition", src="f1.lap_positions", iri="race/{raceId}/lap/{lap}/{driverRef}", links=SEASON_LINK),
    # OpenF1
    dict(cls="Session", src="""SELECT s.*, r.race_id AS raceId FROM timing.sessions s
            LEFT JOIN timing.session_races r USING (session_key)""",
         iri="openf1/session/{session_key}", rename={"is_cancelled": "cancelled"}, links=SEASON_LINK),
    dict(cls="SessionEntry", src="""SELECT d.*, d.driver_id AS driverId FROM timing.session_drivers d""",
         iri="openf1/session/{session_key}/entry/{driver_number}", drop={"driver_id"},
         rename={"driver_number": "carNumber"}, links={"session_key": ("session", "Session")}),
    dict(cls="SessionLap", src="""SELECT l.*, d.driver_id AS driverId, l.session_key AS sk2, l.driver_number AS dn2
            FROM replay.laps l LEFT JOIN timing.session_drivers d USING (session_key, driver_number)""",
         iri="openf1/session/{session_key}/lap/{lap_number}/{driver_number}",
         drop={"code", "driver_name", "team", "sk2", "dn2"}, rename={"driver_number": "carNumber"},
         links={"session_key": ("session", "Session")},
         templates={"entry": ("SessionEntry", DATA + "openf1/session/{sk2}/entry/{dn2}")}),
    dict(cls="Stint", src="""SELECT s.*, d.driver_id AS driverId FROM timing.stints s
            LEFT JOIN timing.session_drivers d USING (session_key, driver_number)""",
         iri="openf1/session/{session_key}/stint/{driver_number}/{stint_number}",
         rename={"driver_number": "carNumber"}, links={"session_key": ("session", "Session")}),
    dict(cls="PitLaneVisit", src="""SELECT p.*, d.driver_id AS driverId,
                row_number() OVER (PARTITION BY p.session_key, p.driver_number ORDER BY p.lap_number) AS visit
            FROM timing.pits p LEFT JOIN timing.session_drivers d USING (session_key, driver_number)""",
         iri="openf1/session/{session_key}/pit/{driver_number}/{visit}",
         rename={"driver_number": "carNumber"}, links={"session_key": ("session", "Session")}),
    dict(cls="RaceControlMessage", src="timing.race_control", iri="openf1/session/{session_key}/race-control/{seq}",
         rename={"driver_number": "carNumber"}, links={"session_key": ("session", "Session")}),
    dict(cls="WeatherObservation", src="""SELECT *, row_number() OVER (PARTITION BY session_key ORDER BY date) AS seq
            FROM timing.weather""", iri="openf1/session/{session_key}/weather/{seq}",
         links={"session_key": ("session", "Session")}),
    dict(cls="LapForecast", src="""SELECT f.*, d.driver_id AS driverId FROM replay.forecast f
            LEFT JOIN timing.session_drivers d USING (session_key, driver_number)""",
         iri="openf1/session/{session_key}/forecast/{at_lap}/{driver_number}",
         rename={"driver_number": "carNumber"}, links={"session_key": ("session", "Session")}),
]

# ---------------------------------------------------------- the ontology --
# Object properties beyond the links' own: inverses and relations between
# drivers and constructors. (predicate: (label, comment, domain, range, extra))
OBJECT_EXTRA = {
    "relative": ("relative", "Another driver this driver is related to; symmetric.", "Driver", "Driver", ["owl:SymmetricProperty"]),
    "raceRecord": ("race record", "Anything recorded for this race: results, standings, laps, pit stops, sessions. The inverse of race.", "Race", None, []),
    "driverRecord": ("driver record", "Anything recorded for this driver: results, standings, entries, laps. The inverse of driver.", "Driver", None, []),
    "constructorRecord": ("constructor record", "Anything recorded for this constructor. The inverse of constructor.", "Constructor", None, []),
    "seasonRecord": ("season record", "Anything recorded for this season. The inverse of season.", "Season", None, []),
    "sessionRecord": ("session record", "Anything recorded for this OpenF1 session. The inverse of session.", "Session", None, []),
}
INVERSE = {"race": "raceRecord", "driver": "driverRecord", "constructor": "constructorRecord",
           "season": "seasonRecord", "session": "sessionRecord"}
COMMENTS = {
    "winner": "The driver classified first. One per race; shared drives keep the first listed.",
    "championships": "World championships won.",
    "nationality": "The f1db id of the driver's nationality, as text; nationalityCountry is the link.",
    "country": "The f1db id of the constructor's country, as text; baseCountry is the link.",
    "careerPoints": "Points scored over a career.",
    "position": "The classified position, empty when not classified.",
    "positionText": "The position as f1db writes it: a number, or DNF, DSQ, NC, ...",
    "positionOrder": "The order f1db lists the rows in, classified or not.",
    "carNumber": "The car's race number.",
    "relationshipType": "How the related driver is related: PARENT, CHILD, SIBLING, ...",
    "relatedDriver": "The driver this relationship is to. Driver to driver, the link is f1:relative.",
    "lineageOf": "The team this lineage entry belongs to.",
    "entry": "The entry this row belongs to.",
}
# Properties only one class has, so a domain is safe to declare. Not
# careerPoints, which the first graph declared on Driver: constructors and
# suppliers have career points too, and the domain made every one of them a
# Driver (the OData Driver set listed Ferrari).
DOMAIN = {"winner": "Race", "dateOfBirth": "Driver", "relationshipType": "FamilyRelationship"}

XSD = {"BIGINT": "integer", "INTEGER": "integer", "HUGEINT": "integer", "SMALLINT": "integer", "TINYINT": "integer",
       "DOUBLE": "decimal", "FLOAT": "decimal", "DATE": "date", "TIMESTAMP": "dateTime",
       "TIMESTAMP WITH TIME ZONE": "dateTime", "BOOLEAN": "boolean", "VARCHAR": "string", "TIME": "string"}
KEEP_TYPES = {"careerPoints": "decimal"}   # as the first version declared them


def columns(src):
    sql = src if src.lstrip().upper().startswith("SELECT") else f"SELECT * FROM {src}"
    req = urllib.request.Request(LAKE, data=f"SELECT * FROM ({sql}) LIMIT 0".encode(), method="POST",
                                 headers={"Authorization": "Bearer duckgraphlake"})
    d = json.load(urllib.request.urlopen(req))
    if "error" in d:
        sys.exit(f"{src[:60]}: {d['error']}")
    return [(c["name"], c["type"]) for c in d["columns"]]


def xsd_of(t):
    if t.startswith("DECIMAL"):
        return "decimal"
    return XSD.get(t, "string")


def ttl_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    out, datatype_props, object_props = [], {}, {}
    for i, m in enumerate(MAPS):
        cls = m["cls"]
        cols = columns(m["src"])
        names = {c for c, _ in cols}
        iri_cols = set(re.findall(r"\{([^}]+)\}", m["iri"]))
        links = {**{k: v for k, v in LINKS.items() if k in names}, **m.get("links", {})}
        rename = {**RENAME, **m.get("rename", {})}
        drop = set(m.get("drop", set()))
        only = m.get("only")
        src = m["src"]
        logical = (f'rr:logicalTable [ rr:sqlQuery """{src}""" ]' if src.lstrip().upper().startswith("SELECT")
                   else f'rr:logicalTable [ rr:tableName "{src}" ]')
        pom = []
        for col, typ in cols:
            if only is not None and col not in only:
                continue
            if col in drop:
                continue
            if col in links:
                pred, target = links[col]
                pom.append(f'  rr:predicateObjectMap [ rr:predicate f1:{pred} ;\n'
                           f'      rr:objectMap [ rr:template "{link_template(target, col)}" ] ]')
                object_props.setdefault(pred, set()).add(target)
                if col in ("year",):    # the season link keeps the year itself too
                    pom.append(f'  rr:predicateObjectMap [ rr:predicate f1:year ;\n'
                               f'      rr:objectMap [ rr:column "{col}" ; rr:datatype xsd:integer ] ]')
                    datatype_props.setdefault("year", "integer")
                continue
            pred = rename.get(col) or predicate(col)
            dt = KEEP_TYPES.get(pred) or xsd_of(typ)
            pom.append(f'  rr:predicateObjectMap [ rr:predicate f1:{pred} ;\n'
                       f'      rr:objectMap [ rr:column "{col}" ; rr:datatype xsd:{dt} ] ]')
            datatype_props.setdefault(pred, dt)
        for pred, (target, tpl) in m.get("templates", {}).items():
            pom.append(f'  rr:predicateObjectMap [ rr:predicate f1:{pred} ;\n'
                       f'      rr:objectMap [ rr:template "{tpl}" ] ]')
            object_props.setdefault(pred, set()).add(target)
        if cls == "FamilyRelationship":   # and the direct link between the two drivers
            out.append(f'<#{cls}Direct>\n  {logical} ;\n'
                       f'  rr:subjectMap [ rr:template "{DATA}driver/{{parentDriverId}}" ] ;\n'
                       f'  rr:predicateObjectMap [ rr:predicate f1:relative ;\n'
                       f'      rr:objectMap [ rr:template "{DATA}driver/{{driverId}}" ] ] .\n')
        out.append(f'<#{cls}{i}>\n  {logical} ;\n'
                   f'  rr:subjectMap [ rr:template "{DATA}{m["iri"]}" ; rr:class f1:{cls} ] ;\n'
                   + " ;\n".join(pom) + " .\n")

    header = '''# R2RML: all of f1db and the OpenF1 timing in the lake, as one graph. It is
# also what the lake's OData serves: one entity set per class, one property per
# literal predicate, one navigation property per link to another class.
#
# GENERATED by scripts/datalake/build-graph.py from the views in lake/init.sql;
# edit the script, not this file. Nothing is copied: SPARQL and OData are
# translated to SQL over the views. Reloaded when this file changes.
#
# IRIs: data under http://data.formula1.local/, vocabulary under
# http://formula1.local/ns#. f1db ids (max-verstappen, ferrari) make the tails
# of reference data; a race's records hang under the race
# (race/1100/race-result/1), a season's under the season, an OpenF1 session's
# under openf1/session/<session_key>.

@prefix rr:  <http://www.w3.org/ns/r2rml#> .
@prefix f1:  <http://formula1.local/ns#> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

'''
    (ROOT / "lake/mapping/f1.ttl").write_text(header + "\n".join(out))

    def label(p):
        return re.sub(r"(?<!^)(?=[A-Z])", " ", p).lower()
    onto = ['''# The F1 vocabulary of the graph (lake/mapping/f1.ttl): classes and their
# hierarchy, labels and comments for the catalog, MCP and agents, and the ranges
# that make links OData navigation properties. The lake applies subClassOf,
# domain/range, inverseOf and symmetric properties to queries, so a query for
# f1:SessionResult finds every kind of result, and f1:raceRecord lists what was
# recorded for a race.
#
# GENERATED by scripts/datalake/build-graph.py; edit the script, not this file.

@prefix f1:   <http://formula1.local/ns#> .
@prefix rdf:  <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix owl:  <http://www.w3.org/2002/07/owl#> .
@prefix xsd:  <http://www.w3.org/2001/XMLSchema#> .
''']
    for c, (lab, com, sup) in CLASSES.items():
        onto.append(f"f1:{c} a owl:Class ;\n  rdfs:label {ttl_str(lab)} ;\n  rdfs:comment {ttl_str(com)}"
                    + (f" ;\n  rdfs:subClassOf f1:{sup}" if sup else "") + " .\n")
    for p, targets in sorted(object_props.items()):
        lines = [f"f1:{p} a owl:ObjectProperty", f"rdfs:label {ttl_str(label(p))}"]
        if p in COMMENTS:
            lines.append(f"rdfs:comment {ttl_str(COMMENTS[p])}")
        # No rdfs:range. The lake applies it to queries, so with a range on
        # every link, "the drivers" meant every IRI any table links to as a
        # driver -- a union over results, standings, entries and laps, three
        # seconds for Driver/$count. A link's OData target comes from its IRI
        # template's shape anyway (driver/{driverId} is a Driver), so the
        # target class goes in the comment instead.
        if len(targets) == 1:
            lines.append(f"rdfs:seeAlso f1:{next(iter(targets))}")
        if p in DOMAIN:
            lines.append(f"rdfs:domain f1:{DOMAIN[p]}")
        if p in INVERSE:
            lines.append(f"owl:inverseOf f1:{INVERSE[p]}")
        onto.append(" ;\n  ".join(lines) + " .\n")
    for p, (lab, com, dom, rng, extra) in OBJECT_EXTRA.items():
        # No domain or range here either: on an inverse (driverRecord of driver)
        # a domain re-derives "is a Driver" from every row that links to one,
        # which is what made Driver/$count take seconds. The class it belongs to
        # is in the comment.
        lines = [f"f1:{p} a owl:ObjectProperty" + "".join(", " + e for e in extra), f"rdfs:label {ttl_str(lab)}",
                 f"rdfs:comment {ttl_str(com + ' (On ' + dom + '.)')}"]
        onto.append(" ;\n  ".join(lines) + " .\n")
    for p, dt in sorted(datatype_props.items()):
        if p in object_props:
            sys.exit(f"{p} is both a link and a literal")
        lines = [f"f1:{p} a owl:DatatypeProperty", f"rdfs:label {ttl_str(label(p))}"]
        if p in COMMENTS:
            lines.append(f"rdfs:comment {ttl_str(COMMENTS[p])}")
        if p in DOMAIN:
            lines.append(f"rdfs:domain f1:{DOMAIN[p]}")
        onto.append(" ;\n  ".join(lines) + " .\n")
    (ROOT / "lake/ontology/f1.ttl").write_text("\n".join(onto))
    print(f"{len(MAPS)} triples maps, {len(CLASSES)} classes, {len(object_props)} links, "
          f"{len(datatype_props)} literal properties")


main()
