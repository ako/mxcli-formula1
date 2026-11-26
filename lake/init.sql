-- DuckGraphLake start-up SQL: the silver and gold layers the frontend reads.
--
-- Loaded through lake/server.toml (init_sql), run after discovery and again
-- whenever this file changes. Every statement must be re-runnable, and every
-- statement must succeed: one failure stops the server (FINDINGS §105). So
-- nothing here may reference a view the server only creates later, such as
-- otel.* or a CDC schema.
--
-- Paths are relative to the server's working directory, not to the data
-- folder; scripts/run-lake.sh starts the server inside data/ so that
-- 'f1db/...' resolves. SQL clients cannot read files at all (lock_down), which
-- is why the views over files live here and nowhere else.


-- ---------------------------------------------------------------- silver --
-- One view per f1db file, under the name the frontend uses. f1db's own column
-- names are kept: renaming them here would make every gold view a translation
-- exercise, and the backend's SQL already speaks them.
--
-- Plain inference, as the backend's read_csv calls over f1db use: none of them
-- declares a column spec (only the live files do), so inference is what the
-- model already relies on.

CREATE SCHEMA IF NOT EXISTS f1;

CREATE OR REPLACE VIEW f1.races AS
  SELECT * FROM read_csv('f1db/f1db-races.csv');
CREATE OR REPLACE VIEW f1.race_results AS
  SELECT * FROM read_csv('f1db/f1db-races-race-results.csv');
CREATE OR REPLACE VIEW f1.sprint_results AS
  SELECT * FROM read_csv('f1db/f1db-races-sprint-race-results.csv');
CREATE OR REPLACE VIEW f1.drivers AS
  SELECT * FROM read_csv('f1db/f1db-drivers.csv');
CREATE OR REPLACE VIEW f1.constructors AS
  SELECT * FROM read_csv('f1db/f1db-constructors.csv');
CREATE OR REPLACE VIEW f1.season_driver_standings AS
  SELECT * FROM read_csv('f1db/f1db-seasons-driver-standings.csv');

-- The rest of what a question about F1 usually touches, for the chat agent
-- (model/frontend/17-chat-agent.mdl), which reads the lake over MCP. Each one
-- is a view per f1db file, so a row can always be traced to its source; the
-- merged `f1db` view discovery makes cannot (ako/DuckGraphLake#31).
CREATE OR REPLACE VIEW f1.seasons AS
  SELECT * FROM read_csv('f1db/f1db-seasons.csv');
CREATE OR REPLACE VIEW f1.circuits AS
  SELECT * FROM read_csv('f1db/f1db-circuits.csv');
CREATE OR REPLACE VIEW f1.countries AS
  SELECT * FROM read_csv('f1db/f1db-countries.csv');
CREATE OR REPLACE VIEW f1.grands_prix AS
  SELECT * FROM read_csv('f1db/f1db-grands-prix.csv');
CREATE OR REPLACE VIEW f1.season_constructor_standings AS
  SELECT * FROM read_csv('f1db/f1db-seasons-constructor-standings.csv');
CREATE OR REPLACE VIEW f1.race_driver_standings AS
  SELECT * FROM read_csv('f1db/f1db-races-driver-standings.csv');
CREATE OR REPLACE VIEW f1.race_constructor_standings AS
  SELECT * FROM read_csv('f1db/f1db-races-constructor-standings.csv');
CREATE OR REPLACE VIEW f1.qualifying_results AS
  SELECT * FROM read_csv('f1db/f1db-races-qualifying-results.csv');
CREATE OR REPLACE VIEW f1.starting_grid AS
  SELECT * FROM read_csv('f1db/f1db-races-starting-grid-positions.csv');
CREATE OR REPLACE VIEW f1.fastest_laps AS
  SELECT * FROM read_csv('f1db/f1db-races-fastest-laps.csv');
CREATE OR REPLACE VIEW f1.pit_stops AS
  SELECT * FROM read_csv('f1db/f1db-races-pit-stops.csv');


-- One winner per race, for the graph's Race -> Driver link (mapping/f1.ttl).
-- positionNumber 1 is not unique: in the 1950s a shared drive classified both
-- drivers first, and a single-valued link needs exactly one. The first by
-- positionDisplayOrder is the one f1db lists first.
CREATE OR REPLACE VIEW f1.race_winners AS
  SELECT raceId, driverId
  FROM f1.race_results
  WHERE positionNumber = 1
  QUALIFY row_number() OVER (PARTITION BY raceId ORDER BY positionDisplayOrder) = 1;


-- ------------------------------------------------------------------ gold --
-- One view per chart, every season at once, materialized in server.toml so a
-- read is a lookup rather than a re-derivation.

CREATE SCHEMA IF NOT EXISTS gold;

-- A season's title fight, round by round: the running points total of the
-- five drivers who ended the year on top of the championship.
--
-- Ported from the backend's Read_SeasonProgress (13-fan-resources.mdl), which
-- computed one year per request. The rules are the same:
--   * the five are the season's final standings, by positionDisplayOrder;
--   * every round is crossed with all five, so a driver who missed a race
--     holds their total instead of leaving a hole in the line;
--   * points are summed per (round, driver), and a missing value counts as 0.
-- With one deliberate difference: sprint points count. f1db keeps sprints in a
-- file of their own, the backend never read it, and so from 2021 on every
-- curve fell short of the championship -- 2021 ended Verstappen 388.5 and
-- Hamilton 385.5 against a real 395.5 and 387.5. A sprint is scored in the
-- round it belongs to, so the weekend's step includes it.
-- What changed is the shape. The backend pivoted to d1..d5 columns because a
-- Mendix chart series binds a column; Vega reads long form, which is what the
-- frontend's DSJ_SeasonProgress turned the pivot back into. So this is long
-- form from the start: one row per (year, round, driver).
CREATE OR REPLACE VIEW gold.season_progress AS
WITH top5 AS (
  SELECT ds.year, ds.driverId,
         row_number() OVER (PARTITION BY ds.year ORDER BY ds.positionDisplayOrder) AS rk
  FROM f1.season_driver_standings ds
  JOIN f1.drivers d ON d.id = ds.driverId
  QUALIFY rk <= 5
),
rounds AS (
  SELECT r.year, r.round, COALESCE(r.officialName, 'Round ' || r.round) AS race_name
  FROM f1.races r
),
scored AS (
  SELECT year, round, driverId, sum(COALESCE(points, 0)) AS pts
  FROM (SELECT year, round, driverId, points FROM f1.race_results
        UNION ALL
        SELECT year, round, driverId, points FROM f1.sprint_results)
  GROUP BY ALL
)
SELECT g.year, g.round, g.race_name, g.rk, d.name AS driver_name,
       sum(COALESCE(s.pts, 0)) OVER (
         PARTITION BY g.year, g.driverId ORDER BY g.round) AS points
FROM (SELECT r.year, r.round, r.race_name, t.rk, t.driverId
      FROM rounds r JOIN top5 t USING (year)) g
LEFT JOIN scored s ON s.year = g.year AND s.round = g.round AND s.driverId = g.driverId
JOIN f1.drivers d ON d.id = g.driverId;


-- Team colours: the comp's map, which is the FIA's for the current teams and
-- the two that just left. f1db has no livery. Every other constructor falls
-- through to the brand colour in the views that use this (#2DD4BF), as the
-- frontend's DS_SeasonTeamRows did: a season of teal bars is honest about
-- there being no colour to give, where invented ones would not be.
CREATE OR REPLACE VIEW f1.constructor_colours AS
SELECT * FROM (VALUES
  ('red-bull', '#3671C6'), ('mclaren', '#FF8000'), ('ferrari', '#E8002D'),
  ('mercedes', '#27F4D2'), ('aston-martin', '#229971'), ('alpine', '#FF87BC'),
  ('haas', '#B6BABD'), ('rb', '#6692FF'), ('racing-bulls', '#6692FF'),
  ('williams', '#64C4FF'), ('sauber', '#52E252'), ('alphatauri', '#5E8FAA'),
  ('alfa-romeo', '#C92D4B'), ('audi', '#BB0A30'), ('cadillac', '#C9B037')
) AS t(constructorId, colour);

-- The constructors' championship as a bar per team, in the team's colour.
-- Ported from the frontend's DS_SeasonTeamRows + DSJ_SeasonTeams, which read
-- the backend's cached ConstructorStandings: name, points, colour, final order.
CREATE OR REPLACE VIEW gold.season_teams AS
SELECT s.year, s.positionDisplayOrder AS position_order, s.constructorId AS constructor_id,
       c.name AS team, s.points, COALESCE(k.colour, '#2DD4BF') AS colour
FROM f1.season_constructor_standings s
JOIN f1.constructors c ON c.id = s.constructorId
LEFT JOIN f1.constructor_colours k ON k.constructorId = s.constructorId;

-- Finishing position by round for the season's top ten: one row per race of
-- each of them, pos empty and dnf 1 when they were not classified. Ported from
-- DSJ_SeasonMultiples, which took the top ten of the backend's cached
-- DriverStandings by positionOrder and their RaceResults (races only; sprints
-- are not finishing positions of a Grand Prix).
CREATE OR REPLACE VIEW gold.season_multiples AS
WITH top10 AS (
  SELECT year, driverId
  FROM f1.season_driver_standings
  QUALIFY row_number() OVER (PARTITION BY year ORDER BY positionDisplayOrder) <= 10
)
SELECT rr.year, rr.round, d.name AS driver_name, rr.positionNumber AS pos,
       CASE WHEN rr.positionNumber IS NULL THEN 1 ELSE 0 END AS dnf
FROM f1.race_results rr
JOIN top10 t ON t.year = rr.year AND t.driverId = rr.driverId
JOIN f1.drivers d ON d.id = rr.driverId;

-- A team's season round by round: each of its two seats' points per race, and
-- the team's championship position after the race. Ported from the backend's
-- Read_TeamSeason (13-fan-resources.mdl), which computed one constructor-year
-- per request; this is every constructor-year at once. The rules are the same:
--   * the seats are the team's two highest scorers of the year, by points,
--     then by number of starts, then by driver id;
--   * points are race points only -- like Read_TeamSeason, sprints are not in
--     this view (gold.season_progress counts them; this one does not yet);
--   * the code is the Grand Prix's abbreviation, upper-cased, or R<round>.
CREATE OR REPLACE VIEW gold.team_season AS
WITH seats AS (
  SELECT constructorId, year, driverId,
         row_number() OVER (PARTITION BY constructorId, year
           ORDER BY sum(COALESCE(points, 0)) DESC, count(*) DESC, driverId) AS seat
  FROM f1.race_results
  GROUP BY constructorId, year, driverId
),
seat_names AS (
  SELECT s.constructorId, s.year,
         max(CASE WHEN s.seat = 1 THEN COALESCE(d.name, s.driverId) END) AS driver1_name,
         max(CASE WHEN s.seat = 2 THEN COALESCE(d.name, s.driverId) END) AS driver2_name
  FROM seats s LEFT JOIN f1.drivers d ON d.id = s.driverId
  GROUP BY ALL
)
SELECT rr.constructorId AS constructor_id, rr.year, rr.round,
       upper(COALESCE(max(g.abbreviation), 'R' || rr.round)) AS code,
       COALESCE(max(r.officialName), 'Round ' || rr.round) AS race_name,
       max(n.driver1_name) AS driver1_name,
       COALESCE(sum(CASE WHEN s.seat = 1 THEN rr.points END), 0) AS driver1_points,
       max(n.driver2_name) AS driver2_name,
       COALESCE(sum(CASE WHEN s.seat = 2 THEN rr.points END), 0) AS driver2_points,
       max(cs.positionNumber) AS standing_position
FROM f1.race_results rr
LEFT JOIN seats s ON s.constructorId = rr.constructorId AND s.year = rr.year AND s.driverId = rr.driverId
LEFT JOIN seat_names n ON n.constructorId = rr.constructorId AND n.year = rr.year
LEFT JOIN f1.races r ON r.id = rr.raceId
LEFT JOIN f1.grands_prix g ON g.id = r.grandPrixId
LEFT JOIN f1.race_constructor_standings cs ON cs.raceId = rr.raceId AND cs.constructorId = rr.constructorId
GROUP BY rr.constructorId, rr.year, rr.round;

-- A driver's seasons: points and championship order per year. Ported from the
-- backend's Read_DriverSeasons, the columns the career chart reads: the official
-- points when the driver is in the final standings, else the sum of race points;
-- the standing's display order, 999 when not classified; its text, '-' when not.
CREATE OR REPLACE VIEW gold.driver_seasons AS
SELECT rr.driverId AS driver_id, rr.year,
       COALESCE(max(ds.points), sum(COALESCE(rr.points, 0))) AS points,
       COALESCE(max(ds.positionDisplayOrder), 999) AS standing_order,
       COALESCE(max(ds.positionText), '-') AS standing_position
FROM f1.race_results rr
LEFT JOIN f1.season_driver_standings ds ON ds.year = rr.year AND ds.driverId = rr.driverId
GROUP BY rr.year, rr.driverId;

-- A driver's races: where they qualified and where they finished. Ported from
-- the backend's Read_DriverRaces, the columns the qualifying-versus-race chart
-- reads.
CREATE OR REPLACE VIEW gold.driver_races AS
SELECT rr.driverId AS driver_id, rr.year, rr.round,
       COALESCE(r.officialName, 'Round ' || rr.round) AS race_name,
       rr.qualificationPositionNumber AS qualifying_position,
       rr.positionNumber AS finish_position
FROM f1.race_results rr
LEFT JOIN f1.races r ON r.id = rr.raceId;

-- The latest season per team and per driver, which is what the Constructor and
-- Driver screens chart. Views, so that each frontend query only filters one by
-- its parameter. (FINDINGS §113 blamed WITH for a connector failure; §114 found
-- the real cause: a parameter in a SELECT list, which the lake cannot type. A
-- comparison with a column, or a CAST, types it.)
CREATE OR REPLACE VIEW gold.team_latest_season AS
SELECT t.* FROM gold.team_season t
WHERE t.year = (SELECT max(x.year) FROM gold.team_season x WHERE x.constructor_id = t.constructor_id);

CREATE OR REPLACE VIEW gold.driver_latest_races AS
SELECT r.* FROM gold.driver_races r
WHERE r.year = (SELECT max(x.year) FROM gold.driver_races x WHERE x.driver_id = r.driver_id);
