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
-- its parameter. (FINDINGS §113–§115: a parameter the lake cannot type, such as
-- one in a SELECT list, makes it lose every result column's name, and Mendix then
-- fails to map the result. Compare each parameter with a column, or CAST it.)
CREATE OR REPLACE VIEW gold.team_latest_season AS
SELECT t.* FROM gold.team_season t
WHERE t.year = (SELECT max(x.year) FROM gold.team_season x WHERE x.constructor_id = t.constructor_id);

CREATE OR REPLACE VIEW gold.driver_latest_races AS
SELECT r.* FROM gold.driver_races r
WHERE r.year = (SELECT max(x.year) FROM gold.driver_races x WHERE x.driver_id = r.driver_id);


-- ------------------------------------------------------ the race weekend --
-- History, not live data: f1db's session results, and Jolpica's lap-by-lap
-- positions (data/laps, 2024 so far). The live OpenF1 feeds are another lane.

CREATE OR REPLACE VIEW f1.fp1_results AS
  SELECT * FROM read_csv('f1db/f1db-races-free-practice-1-results.csv');
CREATE OR REPLACE VIEW f1.fp2_results AS
  SELECT * FROM read_csv('f1db/f1db-races-free-practice-2-results.csv');
CREATE OR REPLACE VIEW f1.fp3_results AS
  SELECT * FROM read_csv('f1db/f1db-races-free-practice-3-results.csv');
-- The column spec is the backend's own (Read_LapChart): inference would read
-- driverRef fine, but the model states the types, and §99 showed that the
-- declared specs are load-bearing for the files that have one.
CREATE OR REPLACE VIEW f1.laps AS
  SELECT * FROM read_csv('laps/f1db-laps.csv', header = true,
    columns = {'year': 'BIGINT', 'round': 'BIGINT', 'lap': 'BIGINT', 'driverRef': 'VARCHAR',
               'position': 'BIGINT', 'time': 'VARCHAR', 'timeMillis': 'BIGINT'});

-- Where the race's top ten placed in each session of the weekend. Ported from
-- the backend's Read_WeekendShape (14-weekend.mdl): the top ten by the race's
-- display order, named by abbreviation (else name, else id), their position in
-- FP1, FP2, FP3, qualifying and the race. Long form, every race at once; the
-- backend pivoted to s1..s10 for the Mendix chart widget, and the frontend's
-- DSJ_WeekendShape unpivoted it again.
CREATE OR REPLACE VIEW gold.weekend_shape AS
WITH top10 AS (
  SELECT raceId, driverId,
         row_number() OVER (PARTITION BY raceId ORDER BY positionDisplayOrder) AS rk
  FROM f1.race_results
  QUALIFY rk <= 10
),
sess AS (
  SELECT 1 AS idx, 'FP1' AS label, raceId, driverId, positionNumber AS pos FROM f1.fp1_results
  UNION ALL SELECT 2, 'FP2', raceId, driverId, positionNumber FROM f1.fp2_results
  UNION ALL SELECT 3, 'FP3', raceId, driverId, positionNumber FROM f1.fp3_results
  UNION ALL SELECT 4, 'Quali', raceId, driverId, positionNumber FROM f1.qualifying_results
  UNION ALL SELECT 5, 'Race', raceId, driverId, positionNumber FROM f1.race_results
)
SELECT s.raceId AS race_id, s.idx AS session_index, s.label AS session_label, t.rk,
       COALESCE(d.abbreviation, d.name, t.driverId) AS driver, max(s.pos) AS pos
FROM sess s
JOIN top10 t ON t.raceId = s.raceId AND t.driverId = s.driverId
LEFT JOIN f1.drivers d ON d.id = t.driverId
GROUP BY ALL;

-- Each driver's gap to the fastest of each session: FP1-3, qualifying (the
-- best of Q3, Q2, Q1, or the single-session time) and the best race lap.
-- Ported from the backend's Read_RaceSessions, the columns the pace chart reads,
-- with the same joins, so a driver with two rows in a session file has two
-- here too. Seconds, rounded to milliseconds.
CREATE OR REPLACE VIEW gold.race_sessions AS
WITH b1 AS (SELECT raceId, min(timeMillis) AS m FROM f1.fp1_results GROUP BY 1),
     b2 AS (SELECT raceId, min(timeMillis) AS m FROM f1.fp2_results GROUP BY 1),
     b3 AS (SELECT raceId, min(timeMillis) AS m FROM f1.fp3_results GROUP BY 1),
     bq AS (SELECT raceId, min(COALESCE(q3Millis, q2Millis, q1Millis, timeMillis)) AS m
            FROM f1.qualifying_results GROUP BY 1),
     bf AS (SELECT raceId, min(timeMillis) AS m FROM f1.fastest_laps GROUP BY 1)
SELECT rr.raceId AS race_id, rr.positionDisplayOrder AS position_order, rr.driverId AS driver_id,
       COALESCE(d.abbreviation, '') AS abbreviation,
       round((fp1.timeMillis - b1.m) / 1000.0, 3) AS fp1_gap,
       round((fp2.timeMillis - b2.m) / 1000.0, 3) AS fp2_gap,
       round((fp3.timeMillis - b3.m) / 1000.0, 3) AS fp3_gap,
       round((COALESCE(q.q3Millis, q.q2Millis, q.q1Millis, q.timeMillis) - bq.m) / 1000.0, 3) AS qual_gap,
       round((f.timeMillis - bf.m) / 1000.0, 3) AS best_lap_gap
FROM f1.race_results rr
LEFT JOIN f1.drivers d ON d.id = rr.driverId
LEFT JOIN f1.fp1_results fp1 ON fp1.raceId = rr.raceId AND fp1.driverId = rr.driverId
LEFT JOIN f1.fp2_results fp2 ON fp2.raceId = rr.raceId AND fp2.driverId = rr.driverId
LEFT JOIN f1.fp3_results fp3 ON fp3.raceId = rr.raceId AND fp3.driverId = rr.driverId
LEFT JOIN f1.qualifying_results q ON q.raceId = rr.raceId AND q.driverId = rr.driverId
LEFT JOIN f1.fastest_laps f ON f.raceId = rr.raceId AND f.driverId = rr.driverId
LEFT JOIN b1 ON b1.raceId = rr.raceId LEFT JOIN b2 ON b2.raceId = rr.raceId
LEFT JOIN b3 ON b3.raceId = rr.raceId LEFT JOIN bq ON bq.raceId = rr.raceId
LEFT JOIN bf ON bf.raceId = rr.raceId;

-- Position by lap for the drivers who were the top ten on the last lap. Ported
-- from the backend's Read_LapChart, every race in the lap file at once:
--   * "the last lap" is the race's highest lap number, so a lapped car is not on
--     it and is not in the ten;
--   * Jolpica names a driver by driverRef ('max_verstappen', 'leclerc'), matched
--     to f1db's abbreviation by id ('_' -> '-'), else by last name among that
--     race's starters, else the driverRef upper-cased.
CREATE OR REPLACE VIEW gold.lap_chart AS
WITH last AS (SELECT year, round, max(lap) AS maxlap FROM f1.laps GROUP BY ALL),
final AS (
  SELECT l.year, l.round, l.driverRef, l.position
  FROM f1.laps l JOIN last m ON m.year = l.year AND m.round = l.round
  WHERE l.lap = m.maxlap
),
dref AS (
  SELECT x.year, x.round, x.driverRef, COALESCE(
    (SELECT d.abbreviation FROM f1.drivers d WHERE d.id = replace(x.driverRef, '_', '-') LIMIT 1),
    (SELECT d.abbreviation FROM f1.drivers d JOIN f1.race_results rr ON rr.driverId = d.id
      WHERE rr.year = x.year AND rr.round = x.round
        AND lower(strip_accents(d.lastName)) = x.driverRef LIMIT 1),
    upper(x.driverRef)) AS who
  FROM (SELECT DISTINCT year, round, driverRef FROM f1.laps) x
),
top10 AS (
  SELECT f.year, f.round, f.driverRef, dref.who,
         row_number() OVER (PARTITION BY f.year, f.round ORDER BY f.position) AS rk
  FROM final f
  JOIN dref ON dref.year = f.year AND dref.round = f.round AND dref.driverRef = f.driverRef
  QUALIFY rk <= 10
)
SELECT l.year, l.round, l.lap, x.rk, x.who AS driver, max(l.position) AS pos
FROM f1.laps l
JOIN top10 x ON x.year = l.year AND x.round = l.round AND x.driverRef = l.driverRef
GROUP BY ALL;


-- ---------------------------------------------------------- OpenF1, silver --
-- The newest response the backend posted for each OpenF1 request, unpacked.
-- The backend posts every changed response to the topic `openf1` (19-live-sync's
-- Sync_LakePost), one event type per feed, the request path as the subject, so
-- openf1.<feed> holds every version of 'laps?session_key=11420'; a finished
-- session's last version is the whole session. The column specs are the
-- backend's own (GetOpenF1Laps and friends in 01-foundation.mdl).
--
-- These read openf1.*, which the server makes from the topic during discovery,
-- before this file runs. The topic exists once the backend has posted anything
-- (scripts/run-weekend.sh, or the season backfill, FINDINGS §118); a lake
-- started without it stops on the first of these views.

CREATE SCHEMA IF NOT EXISTS timing;

CREATE OR REPLACE VIEW timing.sessions AS
SELECT DISTINCT ON (j.session_key)
       j.session_key, j.session_name, j.session_type, j.meeting_key, j.location,
       j.country_name, j.circuit_short_name, j.year,
       CAST(j.date_start AS TIMESTAMPTZ) AS date_start,
       CAST(j.date_end AS TIMESTAMPTZ) AS date_end,
       -- f1db dates the day by the track's calendar (mostly; see replay.sessions)
       CAST(CAST(j.date_start AS TIMESTAMPTZ) AT TIME ZONE 'UTC'
            + CAST(j.gmt_offset AS INTERVAL) AS DATE) AS local_date,
       COALESCE(j.is_cancelled, false) AS is_cancelled
  FROM (SELECT event_time, kafka_offset,
               unnest(from_json(payload, '[{"session_key":"BIGINT","session_name":"VARCHAR","session_type":"VARCHAR","meeting_key":"BIGINT","location":"VARCHAR","country_name":"VARCHAR","circuit_short_name":"VARCHAR","year":"BIGINT","date_start":"VARCHAR","date_end":"VARCHAR","gmt_offset":"VARCHAR","is_cancelled":"BOOLEAN"}]')) AS j
          FROM openf1.sessions)
 WHERE j.session_key IS NOT NULL
 ORDER BY j.session_key, event_time DESC, kafka_offset DESC;

CREATE OR REPLACE VIEW timing.drivers AS
SELECT sk AS session_key, j.driver_number,
       COALESCE(j.name_acronym, '') AS code,
       COALESCE(j.full_name, j.broadcast_name, '') AS driver_name,
       COALESCE(j.team_name, '') AS team, j.team_colour
  FROM (SELECT CAST(regexp_extract(subject, 'session_key=(\d+)', 1) AS BIGINT) AS sk,
               unnest(from_json(payload, '[{"driver_number":"BIGINT","name_acronym":"VARCHAR","full_name":"VARCHAR","broadcast_name":"VARCHAR","team_name":"VARCHAR","team_colour":"VARCHAR"}]')) AS j
          FROM openf1.drivers
         WHERE regexp_matches(subject, '^drivers\?session_key=\d+$')
       QUALIFY row_number() OVER (PARTITION BY subject ORDER BY event_time DESC, kafka_offset DESC) = 1);

CREATE OR REPLACE VIEW timing.laps AS
SELECT sk AS session_key, j.driver_number, j.lap_number, j.lap_duration,
       j.duration_sector_1 AS sector_1, j.duration_sector_2 AS sector_2,
       j.duration_sector_3 AS sector_3, j.i2_speed AS speed_trap, j.is_pit_out_lap,
       CAST(j.date_start AS TIMESTAMP) AS date_start
  FROM (SELECT CAST(regexp_extract(subject, 'session_key=(\d+)', 1) AS BIGINT) AS sk,
               unnest(from_json(payload, '[{"driver_number":"BIGINT","lap_number":"BIGINT","lap_duration":"DOUBLE","duration_sector_1":"DOUBLE","duration_sector_2":"DOUBLE","duration_sector_3":"DOUBLE","i2_speed":"BIGINT","is_pit_out_lap":"BOOLEAN","date_start":"VARCHAR"}]')) AS j
          FROM openf1.laps
         WHERE regexp_matches(subject, '^laps\?session_key=\d+$')
       QUALIFY row_number() OVER (PARTITION BY subject ORDER BY event_time DESC, kafka_offset DESC) = 1);

CREATE OR REPLACE VIEW timing.positions AS
SELECT sk AS session_key, j.driver_number, CAST(j.date AS TIMESTAMP) AS date, j.position
  FROM (SELECT CAST(regexp_extract(subject, 'session_key=(\d+)', 1) AS BIGINT) AS sk,
               unnest(from_json(payload, '[{"driver_number":"BIGINT","date":"VARCHAR","position":"BIGINT"}]')) AS j
          FROM openf1.position
         WHERE regexp_matches(subject, '^position\?session_key=\d+$')
       QUALIFY row_number() OVER (PARTITION BY subject ORDER BY event_time DESC, kafka_offset DESC) = 1);

-- gap_to_leader stays text: a lapped car's is '+1 LAP', not seconds.
CREATE OR REPLACE VIEW timing.intervals AS
SELECT sk AS session_key, j.driver_number, CAST(j.date AS TIMESTAMP) AS date,
       j.gap_to_leader, j."interval"
  FROM (SELECT CAST(regexp_extract(subject, 'session_key=(\d+)', 1) AS BIGINT) AS sk,
               unnest(from_json(payload, '[{"driver_number":"BIGINT","date":"VARCHAR","gap_to_leader":"VARCHAR","interval":"VARCHAR"}]')) AS j
          FROM openf1.intervals
         WHERE regexp_matches(subject, '^intervals\?session_key=\d+$')
       QUALIFY row_number() OVER (PARTITION BY subject ORDER BY event_time DESC, kafka_offset DESC) = 1);

CREATE OR REPLACE VIEW timing.stints AS
SELECT sk AS session_key, j.driver_number, j.stint_number, j.compound,
       j.lap_start, j.lap_end, j.tyre_age_at_start
  FROM (SELECT CAST(regexp_extract(subject, 'session_key=(\d+)', 1) AS BIGINT) AS sk,
               unnest(from_json(payload, '[{"driver_number":"BIGINT","stint_number":"BIGINT","compound":"VARCHAR","lap_start":"BIGINT","lap_end":"BIGINT","tyre_age_at_start":"BIGINT"}]')) AS j
          FROM openf1.stints
         WHERE regexp_matches(subject, '^stints\?session_key=\d+$')
       QUALIFY row_number() OVER (PARTITION BY subject ORDER BY event_time DESC, kafka_offset DESC) = 1);

CREATE OR REPLACE VIEW timing.pits AS
SELECT sk AS session_key, j.driver_number, j.lap_number, j.lane_duration
  FROM (SELECT CAST(regexp_extract(subject, 'session_key=(\d+)', 1) AS BIGINT) AS sk,
               unnest(from_json(payload, '[{"driver_number":"BIGINT","lap_number":"BIGINT","lane_duration":"DOUBLE"}]')) AS j
          FROM openf1.pit
         WHERE regexp_matches(subject, '^pit\?session_key=\d+$')
       QUALIFY row_number() OVER (PARTITION BY subject ORDER BY event_time DESC, kafka_offset DESC) = 1);


-- ------------------------------------------------------------- replay, gold --
-- What the frontend's Replay screen reads (14-replay.mdl): the races, the
-- classification lap by lap, and the forecast as it would have been made at
-- every lap. Materialized on a timer, not on change (lake/server.toml): the
-- topic changes every minute during a session, and these are for races that
-- have finished.

CREATE SCHEMA IF NOT EXISTS replay;

-- Races and sprints with laps, and how long each was scheduled to be. f1db is
-- matched on the year and the nearest date within a day: it dates most races by
-- the track's calendar, but Las Vegas by UTC. A session f1db does not have
-- falls back to the laps run. A sprint's distance is f1db's sprintRaceLaps.
CREATE OR REPLACE VIEW replay.sessions AS
WITH ran AS (SELECT session_key, max(lap_number) AS last_lap FROM timing.laps GROUP BY ALL),
races AS (
  SELECT s.*, r.last_lap, s.session_name ILIKE '%sprint%' AS sprint
    FROM timing.sessions s JOIN ran r USING (session_key)
   WHERE s.session_type = 'Race'
),
sized AS (
  SELECT x.*,
         COALESCE((SELECT CASE WHEN x.sprint THEN f.sprintRaceLaps ELSE f.laps END
                     FROM f1.races f
                    WHERE f.year = x.year
                      AND abs(date_diff('day', CASE WHEN x.sprint THEN f.sprintRaceDate ELSE f.date END, x.local_date)) <= 1
                    ORDER BY abs(date_diff('day', CASE WHEN x.sprint THEN f.sprintRaceDate ELSE f.date END, x.local_date))
                    LIMIT 1),
                  x.last_lap) AS total_laps
    FROM races x
)
SELECT session_key, session_name, location, country_name, year, date_start,
       session_name || ' · ' || location || ' · ' || year AS label,
       total_laps, last_lap,
       least(last_lap, total_laps) AS max_lap
  FROM sized;

-- The entry list of each race on the Replay screen, materialized beside the
-- rest so a step of the screen does not unpack the drivers' JSON again.
CREATE OR REPLACE VIEW replay.drivers AS
SELECT * FROM timing.drivers
 WHERE session_key IN (SELECT session_key FROM replay.sessions);

-- Each car's state at the end of each lap: the backend's GetOpenF1Laps, over
-- every session in the lake at once. Position and gap are the newest samples at
-- or before the lap ended (ASOF), the tyre comes from the stint the lap is in.
-- Checked against the backend's LiveLap for Las Vegas: 988 of 988 rows identical
-- (FINDINGS §120).
CREATE OR REPLACE VIEW replay.laps AS
WITH laps AS (
  SELECT *, date_start + INTERVAL (COALESCE(lap_duration, 0)) SECOND AS t1
    FROM timing.laps WHERE date_start IS NOT NULL
),
pits AS (SELECT * FROM timing.pits WHERE COALESCE(lane_duration, 0) BETWEEN 1 AND 180)
SELECT l.session_key, l.driver_number, l.lap_number, p.position,
       i.gap_to_leader, TRY_CAST(i.gap_to_leader AS DOUBLE) AS gap_seconds,
       l.lap_duration AS lap_seconds, l.sector_1, l.sector_2, l.sector_3, l.speed_trap,
       s.compound,
       CASE WHEN s.lap_start IS NULL THEN NULL
            ELSE COALESCE(s.tyre_age_at_start, 0) + (l.lap_number - s.lap_start) END AS tyre_age,
       (SELECT count(*) FROM pits x
         WHERE x.session_key = l.session_key AND x.driver_number = l.driver_number
           AND x.lap_number <= l.lap_number) AS pit_stops,
       d.code, d.driver_name, d.team
  FROM laps l
  ASOF LEFT JOIN timing.positions p
         ON p.session_key = l.session_key AND p.driver_number = l.driver_number AND p.date <= l.t1
  ASOF LEFT JOIN timing.intervals i
         ON i.session_key = l.session_key AND i.driver_number = l.driver_number AND i.date <= l.t1
  LEFT JOIN timing.stints s
         ON s.session_key = l.session_key AND s.driver_number = l.driver_number
        AND l.lap_number BETWEEN s.lap_start AND COALESCE(s.lap_end, 9999)
  LEFT JOIN timing.drivers d
         ON d.session_key = l.session_key AND d.driver_number = l.driver_number;

-- The race forecaster (the backend's GetOpenF1Forecast, kept in
-- spikes/forecaster/forecast.sql) at every lap of every race: what it would have
-- said had it been running, from the laps completed before lap at_lap + 1
-- started and nothing after. The model is unchanged; each step is keyed by
-- (session, at_lap) so that one statement makes every forecast, where the
-- backend ran it once per lap. As in the original, tyre life reads every stint
-- of the session.
--
-- Two thousand simulations each, so a second run differs by sampling noise:
-- for Las Vegas, the lake against itself and against the backend's stored
-- forecasts differ by the same amount (mean |Δ| of win probability 0.003), and
-- laps used, laps remaining and stops left agree exactly (FINDINGS §120).
CREATE OR REPLACE VIEW replay.forecast AS
WITH cuts AS (
  SELECT r.session_key AS sk, c.cut, r.total_laps AS total,
         COALESCE((SELECT min(l.date_start) FROM timing.laps l
                    WHERE l.session_key = r.session_key AND l.lap_number = c.cut + 1),
                  TIMESTAMP '2999-01-01') AS cut_t
    FROM replay.sessions r, LATERAL (SELECT unnest(generate_series(2, r.max_lap)) AS cut) c
),
laps AS (
  SELECT session_key AS sk, driver_number, lap_number, lap_duration, is_pit_out_lap, date_start AS t
    FROM timing.laps
   WHERE date_start IS NOT NULL AND session_key IN (SELECT session_key FROM replay.sessions)
),
st AS (
  SELECT session_key AS sk, driver_number, lap_start, lap_end, compound, tyre_age_at_start
    FROM timing.stints WHERE session_key IN (SELECT session_key FROM replay.sessions)
),
pits AS (
  SELECT session_key AS sk, driver_number, lap_number
    FROM timing.pits
   WHERE COALESCE(lane_duration, 0) BETWEEN 1 AND 180
     AND session_key IN (SELECT session_key FROM replay.sessions)
),
-- pits(sk, driver_number, lap_number), cuts(sk, cut, total, cut_t).
aged AS (
  SELECT c.sk, c.cut, l.driver_number, l.lap_number, l.lap_duration, l.is_pit_out_lap,
         s.compound,
         COALESCE(s.tyre_age_at_start,0) + (l.lap_number - s.lap_start) AS tyre_age
    FROM cuts c
    JOIN laps l ON l.sk = c.sk AND l.t < c.cut_t
    LEFT JOIN st s ON s.sk = l.sk AND s.driver_number = l.driver_number
         AND l.lap_number BETWEEN s.lap_start AND COALESCE(s.lap_end, 9999)
),
notpit AS (
  SELECT a.* FROM aged a
    LEFT JOIN pits p ON p.sk = a.sk AND p.driver_number = a.driver_number AND p.lap_number = a.lap_number
   WHERE a.lap_duration IS NOT NULL AND a.is_pit_out_lap IS NOT TRUE
     AND a.lap_number > 1 AND p.lap_number IS NULL
),
med AS (SELECT sk, cut, driver_number, median(lap_duration) AS m FROM notpit GROUP BY ALL),
fieldmed AS (
  SELECT c.sk, c.cut, COALESCE(median(d.m), 90.0) AS m
    FROM cuts c LEFT JOIN med d ON d.sk = c.sk AND d.cut = c.cut GROUP BY ALL
),
clean AS (
  SELECT n.*, n.lap_duration - d.m AS resid
    FROM notpit n JOIN med d USING (sk, cut, driver_number)
   WHERE n.lap_duration BETWEEN d.m * 0.93 AND d.m * 1.07
),
deg_raw AS (
  SELECT sk, cut, compound, regr_slope(resid, tyre_age) AS fitted, count(*) AS n
    FROM clean WHERE compound IS NOT NULL AND tyre_age IS NOT NULL GROUP BY ALL
),
prior AS (
  SELECT * FROM (VALUES ('SOFT',0.060,20),('MEDIUM',0.040,30),('HARD',0.025,40),
                        ('INTERMEDIATE',0.030,30),('WET',0.030,30))
    AS t(compound, per_lap, max_life)
),
deg AS (
  SELECT r.sk, r.cut, r.compound,
         CASE WHEN isfinite(r.fitted)
              THEN least(0.15, greatest(0.0,
                     (r.n * r.fitted + 120 * pr.per_lap) / (r.n + 120)))
              ELSE pr.per_lap END AS per_lap
    FROM deg_raw r JOIN prior pr USING (compound)
),
fuel_raw AS (
  SELECT c.sk, c.cut, regr_slope(c.resid - COALESCE(d.per_lap,0) * c.tyre_age, c.lap_number) AS v
    FROM clean c LEFT JOIN deg d USING (sk, cut, compound) GROUP BY ALL
),
fuel AS (
  SELECT c.sk, c.cut,
         CASE WHEN isfinite(f.v) THEN greatest(-0.20, least(0.0, f.v)) ELSE -0.03 END AS per_lap
    FROM cuts c LEFT JOIN fuel_raw f USING (sk, cut)
),
pace AS (
  SELECT c.sk, c.cut, c.driver_number,
         CASE WHEN isfinite(median(c.lap_duration - COALESCE(d.per_lap,0) * c.tyre_age - f.per_lap * c.lap_number))
              THEN median(c.lap_duration - COALESCE(d.per_lap,0) * c.tyre_age - f.per_lap * c.lap_number)
              ELSE median(c.lap_duration) END AS base,
         CASE WHEN isfinite(stddev_samp(c.resid))
              THEN greatest(0.05, least(2.0, stddev_samp(c.resid)))
              ELSE 0.4 END AS noise,
         count(*) AS laps_used
    FROM clean c LEFT JOIN deg d USING (sk, cut, compound) JOIN fuel f USING (sk, cut)
   GROUP BY ALL
),
pitloss AS (
  SELECT a.sk, a.cut, median(a.lap_duration + o.lap_duration - 2 * m.m) AS secs
    FROM pits p
    JOIN aged a ON a.sk = p.sk AND a.driver_number = p.driver_number AND a.lap_number = p.lap_number
    JOIN aged o ON o.sk = a.sk AND o.cut = a.cut AND o.driver_number = p.driver_number AND o.lap_number = p.lap_number + 1
    JOIN med  m ON m.sk = a.sk AND m.cut = a.cut AND m.driver_number = p.driver_number
   WHERE a.lap_duration IS NOT NULL AND o.lap_duration IS NOT NULL
   GROUP BY ALL
),
loss AS (
  SELECT c.sk, c.cut, CASE WHEN p.secs BETWEEN 12 AND 45 THEN p.secs ELSE 20.0 END AS secs
    FROM cuts c LEFT JOIN pitloss p USING (sk, cut)
),
-- Like the original, tyre life reads every stint of the session, not only those before the cut.
life AS (
  SELECT ss.sk, pr.compound, greatest(COALESCE(o.max_life, 0), pr.max_life) AS max_life
    FROM (SELECT DISTINCT sk FROM cuts) ss CROSS JOIN prior pr
    LEFT JOIN (
      SELECT s.sk, s.compound,
             max(s.lap_end - s.lap_start + 1 + COALESCE(s.tyre_age_at_start,0)) AS max_life
        FROM st s
       WHERE EXISTS (SELECT 1 FROM pits p WHERE p.sk = s.sk AND p.driver_number = s.driver_number
                       AND p.lap_number = s.lap_end)
       GROUP BY ALL) o ON o.sk = ss.sk AND o.compound = pr.compound
),
last_lap AS (
  SELECT DISTINCT ON (sk, cut, driver_number) sk, cut, driver_number, lap_number, compound, tyre_age
    FROM aged WHERE lap_duration IS NOT NULL OR is_pit_out_lap
   ORDER BY sk, cut, driver_number, lap_number DESC
),
elapsed AS (
  SELECT a.sk, a.cut, a.driver_number,
         sum(COALESCE(a.lap_duration, COALESCE(m.m, fm.m))) AS secs,
         count(*) AS laps_done
    FROM aged a LEFT JOIN med m USING (sk, cut, driver_number) JOIN fieldmed fm USING (sk, cut)
   GROUP BY ALL
),
leadlap AS (SELECT sk, cut, max(laps_done) AS n FROM elapsed GROUP BY ALL),
leader AS (
  SELECT e.sk, e.cut, arg_min(e.driver_number, e.secs) AS driver_number
    FROM elapsed e JOIN leadlap n USING (sk, cut)
   WHERE e.laps_done = n.n GROUP BY ALL
),
leader_cum AS (
  SELECT a.sk, a.cut, a.lap_number,
         sum(COALESCE(a.lap_duration, fm.m)) OVER (PARTITION BY a.sk, a.cut ORDER BY a.lap_number) AS secs
    FROM aged a JOIN leader ld USING (sk, cut, driver_number) JOIN fieldmed fm USING (sk, cut)
),
state AS (
  SELECT ll.sk, ll.cut, ll.driver_number, ll.lap_number, ll.compound, COALESCE(ll.tyre_age, 10) AS tyre_age,
         e.laps_done,
         n.n - e.laps_done AS laps_down,
         e.secs - COALESCE(lc.secs, 0) AS gap_s,
         COALESCE(lc.secs, 0) AS at_secs,
         greatest(0, c.total - e.laps_done) AS remaining,
         c.total
    FROM last_lap ll JOIN elapsed e USING (sk, cut, driver_number)
    JOIN leadlap n USING (sk, cut) JOIN cuts c USING (sk, cut)
    LEFT JOIN leader_cum lc ON lc.sk = e.sk AND lc.cut = e.cut AND lc.lap_number = e.laps_done
),
plan AS (
  SELECT s.*,
         COALESCE(p.base, fm.m + 0.5) AS base,
         COALESCE(p.noise, 0.4) AS noise,
         COALESCE(p.laps_used, 0) AS laps_used,
         COALESCE(d.per_lap, 0.04) AS deg_per_lap,
         s.laps_down >= 3 AS retired,
         greatest(
           CASE WHEN COALESCE(u.compounds_used,1) < 2 AND s.total > 40
                     AND s.remaining > 0 THEN 1 ELSE 0 END,
           CASE WHEN COALESCE(s.tyre_age,0) + s.remaining > COALESCE(l.max_life, 30)
                     AND s.remaining > 4 THEN 1 ELSE 0 END) AS stops
    FROM state s
    JOIN fieldmed fm USING (sk, cut)
    LEFT JOIN pace p USING (sk, cut, driver_number)
    LEFT JOIN deg d ON d.sk = s.sk AND d.cut = s.cut AND d.compound = s.compound
    LEFT JOIN life l ON l.sk = s.sk AND l.compound = s.compound
    LEFT JOIN (SELECT l2.sk, l2.cut, l2.driver_number, count(DISTINCT s2.compound) AS compounds_used
                 FROM last_lap l2 JOIN st s2 ON s2.sk = l2.sk AND s2.driver_number = l2.driver_number
                WHERE s2.compound IS NOT NULL AND s2.lap_start <= l2.lap_number
                GROUP BY ALL) u USING (sk, cut, driver_number)
),
plan2 AS (
  SELECT p.*, p.tyre_age / (p.stops + 1.0) + p.remaining / (2.0 * (p.stops + 1.0)) AS mean_age
    FROM plan p
),
-- The simulation, shaped to stream. The original draws every car in every
-- simulation as a row and ranks them with a window: for a season that is
-- fifty million rows held at once, more than the machine has. Here a
-- simulation is one row whose cars are a list: the finishing times are drawn
-- inside it (random() is drawn afresh per element), sorted there (retired cars
-- last, then by time, as the original orders them), and the positions are
-- counted straight into a histogram per car and position. The same draws as the
-- original's, the same statistics, taken from the histogram.
cars AS (
  SELECT sk, cut,
         list({'d': driver_number, 'retired': retired, 'remaining': remaining,
               'at_secs': at_secs, 'gap_s': gap_s, 'base': base, 'deg': deg_per_lap,
               'mean_age': mean_age, 'noise': noise, 'stops': stops}) AS cars
    FROM plan2 GROUP BY ALL
),
sims AS (SELECT unnest(generate_series(1, 2000)) AS sim),
runs AS (
  SELECT c.sk, c.cut,
         list_sort(list_transform(c.cars, lambda x: {
           'out': x.retired OR random() < 1 - pow(1 - 0.0009, x.remaining),
           'finish': x.at_secs + x.gap_s * compress
                     + x.remaining * (x.base + x.deg * x.mean_age
                                      + x.noise * (random() * 2 - 1) * 1.7)
                     + x.stops * (ls.secs + random() * 3)
                     + (random() * 2 - 1) * 2.0,
           'd': x.d})) AS result
    FROM cars c JOIN loss ls USING (sk, cut)
    CROSS JOIN (SELECT sim, CASE WHEN random() < 0.35 THEN 0.30 ELSE 1.0 END AS compress FROM sims)
),
placed AS (
  SELECT sk, cut, unnest(result) AS r, generate_subscripts(result, 1) AS pos FROM runs
),
hist AS (
  SELECT sk, cut, r.d AS driver_number, pos, count(*) AS n,
         sum(r.finish) FILTER (WHERE NOT r.out) AS finish_sum,
         count(*) FILTER (WHERE NOT r.out) AS finishes
    FROM placed GROUP BY ALL
),
cum AS (
  SELECT *, sum(n) OVER (PARTITION BY sk, cut, driver_number ORDER BY pos) AS upto
    FROM hist
),
-- quantile_cont over 2,000 positions, from the histogram: the k-th smallest
-- (from 0) is the first position whose running count passes k, and h = 1999 q
-- interpolates between the values at floor(h) and floor(h) + 1.
stats AS (
  SELECT sk, cut, driver_number,
         sum(pos * n) / 2000.0 AS mean_pos,
         min(pos) FILTER (WHERE upto > 999)  * 0.5 + min(pos) FILTER (WHERE upto > 1000) * 0.5 AS q50,
         min(pos) FILTER (WHERE upto > 199)  * 0.1 + min(pos) FILTER (WHERE upto > 200)  * 0.9 AS q10,
         min(pos) FILTER (WHERE upto > 1799) * 0.9 + min(pos) FILTER (WHERE upto > 1800) * 0.1 AS q90,
         sum(n) FILTER (WHERE pos = 1)  AS wins,
         sum(n) FILTER (WHERE pos <= 3) AS podiums,
         sum(n) FILTER (WHERE pos <= 10) AS points,
         sum(finish_sum) / nullif(sum(finishes), 0) AS finish_avg
    FROM cum GROUP BY ALL
)
SELECT s.sk AS session_key, s.cut AS at_lap, s.driver_number,
       pl.lap_number AS lap_now,
       pl.remaining AS laps_remaining,
       pl.stops AS stops_left,
       pl.laps_used,
       round(CASE WHEN isfinite(pl.base) THEN pl.base ELSE 0 END, 3) AS base_pace,
       round(CASE WHEN isfinite(pl.deg_per_lap) THEN pl.deg_per_lap ELSE 0 END, 4) AS deg_per_lap,
       round(ls.secs, 2) AS pit_loss,
       round(s.mean_pos, 2) AS mean_position,
       CAST(s.q50 AS BIGINT) AS median_position,
       round(COALESCE(s.wins, 0) / 2000.0, 4) AS p_win,
       round(COALESCE(s.podiums, 0) / 2000.0, 4) AS p_podium,
       round(COALESCE(s.points, 0) / 2000.0, 4) AS p_points,
       CAST(s.q10 AS BIGINT) AS best_case,
       CAST(s.q90 AS BIGINT) AS worst_case,
       round(CASE WHEN isfinite(s.finish_avg) THEN s.finish_avg ELSE 0 END, 1) AS projected_time
  FROM stats s
  JOIN plan2 pl USING (sk, cut, driver_number)
  JOIN loss ls USING (sk, cut)
;
