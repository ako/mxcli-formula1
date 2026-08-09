#!/usr/bin/env bash
#
# f1ops — a Postgres database with stored procedures in it.
#
# Everything else in this repo reads flat files. This one exists to be the
# thing you cannot rewrite: somebody else's RDBMS, with the business logic
# already inside it as procedures, which you have been asked to put behind an
# OData surface without touching. That is the case ODataPushdown's bind style
# and its CallSql renderer are for, and it cannot be demonstrated against a
# CSV.
#
# Two objects, deliberately of the two different kinds:
#
#   f1ops.driver_form(...)        a table-valued FUNCTION — read-only, returns
#                                 rows, reached with SELECT * FROM. It is
#                                 plpgsql with a loop and a running average, so
#                                 it is procedural rather than a view wearing a
#                                 hat.
#
#   f1ops.record_prediction(...)  a PROCEDURE with INOUT parameters — it writes,
#                                 and is reached with CALL. This is the one that
#                                 wants an OData action rather than an entity
#                                 set, because invoking it changes something.
#
# Re-runnable: drops and recreates the schema every time.
#
#   scripts/create-f1ops-db.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$HERE/data/f1db"
DB="${F1OPS_DB:-f1ops}"
PSQL=(sudo -u postgres psql -v ON_ERROR_STOP=1 -q)

if [ ! -f "$DATA/f1db-races-race-results.csv" ]; then
  echo "no F1 data at $DATA — run scripts/fetch-f1-data.sh first" >&2
  exit 1
fi

echo "creating database $DB"
# A running app holds a pooled connection, and DROP DATABASE will not wait.
sudo -u postgres psql -q -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB';" >/dev/null 2>&1 || true
sudo -u postgres psql -q -c "DROP DATABASE IF EXISTS $DB;" >/dev/null
sudo -u postgres psql -q -c "CREATE DATABASE $DB;" >/dev/null
# The app connects as the same role the Mendix databases use.
sudo -u postgres psql -q -c "GRANT ALL ON DATABASE $DB TO mendix;" >/dev/null 2>&1 || true

# ---------------------------------------------------------------- extract
# Trim the two CSVs to the columns the procedures need. COPY wants exactly the
# columns of the target table, and the source has 30+.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$DATA" "$TMP" <<'PY'
import csv, sys, os
data, tmp = sys.argv[1], sys.argv[2]

def num(v):
    return v if v not in ('', 'NULL') else ''

with open(os.path.join(data, 'f1db-drivers.csv'), newline='') as f, \
     open(os.path.join(tmp, 'driver.csv'), 'w', newline='') as o:
    w = csv.writer(o)
    for r in csv.DictReader(f):
        w.writerow([r['id'], r['name'], r['nationalityCountryId']])

with open(os.path.join(data, 'f1db-races.csv'), newline='') as f, \
     open(os.path.join(tmp, 'race.csv'), 'w', newline='') as o:
    w = csv.writer(o)
    for r in csv.DictReader(f):
        w.writerow([r['id'], r['year'], r['round'], r['date'],
                    r.get('officialName') or ''])

with open(os.path.join(data, 'f1db-races-race-results.csv'), newline='') as f, \
     open(os.path.join(tmp, 'race_result.csv'), 'w', newline='') as o:
    w = csv.writer(o)
    for r in csv.DictReader(f):
        w.writerow([r['raceId'], r['year'], r['round'], r['driverId'],
                    num(r['positionNumber']), r['positionText'],
                    num(r['gridPositionNumber']), num(r['points']),
                    r.get('reasonRetired') or ''])
PY

# ---------------------------------------------------------------- schema
"${PSQL[@]}" -d "$DB" <<'SQL'
CREATE SCHEMA IF NOT EXISTS f1ops;

CREATE TABLE f1ops.driver (
  id            text PRIMARY KEY,
  name          text NOT NULL,
  nationality   text
);

CREATE TABLE f1ops.race (
  id            integer PRIMARY KEY,
  year          integer NOT NULL,
  round         integer NOT NULL,
  race_date     date,
  official_name text
);

CREATE TABLE f1ops.race_result (
  race_id       integer NOT NULL,
  year          integer NOT NULL,
  round         integer NOT NULL,
  driver_id     text    NOT NULL,
  finish_position integer,
  position_text text,
  grid_position integer,
  points        numeric,
  reason_retired text
);
CREATE INDEX ON f1ops.race_result (driver_id, year, round);

-- The side-effect target. A procedure that only reads is a query with extra
-- steps; this is what makes record_prediction worth being a procedure.
CREATE TABLE f1ops.prediction (
  id            bigserial PRIMARY KEY,
  driver_id     text    NOT NULL REFERENCES f1ops.driver(id),
  race_id       integer NOT NULL REFERENCES f1ops.race(id),
  finish_position integer NOT NULL,
  submitted_by  text    NOT NULL,
  submitted_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (driver_id, race_id, submitted_by)
);
SQL

# Fed on stdin rather than by path: psql runs as the postgres user, which
# cannot read a mktemp directory owned by someone else.
echo "loading tables"
for t in driver race race_result; do
  "${PSQL[@]}" -d "$DB" \
    -c "\copy f1ops.$t FROM STDIN WITH (FORMAT csv, NULL '')" < "$TMP/$t.csv"
done

# ---------------------------------------------------------------- routines
"${PSQL[@]}" -d "$DB" <<'SQL'
/*
 * A driver's recent form: the last N races, each with the rolling average
 * finishing position up to and including that race.
 *
 * Written as a loop rather than a window function on purpose — this stands in
 * for the kind of routine that is in a warehouse because it was too awkward to
 * express as a view, which is exactly the kind you cannot lift out into the
 * calling application.
 */
CREATE OR REPLACE FUNCTION f1ops.driver_form(
  p_driver_id text,
  p_last_n    integer DEFAULT 5
)
RETURNS TABLE (
  form_key      text,
  race_id       integer,
  year          integer,
  round         integer,
  race_name     text,
  finish_position integer,
  position_text text,
  grid_position integer,
  points        numeric,
  places_gained integer,
  rolling_avg   numeric
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  r            record;
  seen         integer := 0;
  total        numeric := 0;
BEGIN
  IF p_driver_id IS NULL OR p_driver_id = '' THEN
    RETURN;
  END IF;
  IF p_last_n IS NULL OR p_last_n < 1 THEN
    p_last_n := 5;
  END IF;

  FOR r IN
    SELECT rr.race_id, rr.year, rr.round, rr.finish_position, rr.position_text,
           rr.grid_position, rr.points, rr.reason_retired,
           COALESCE(ra.official_name, 'Round ' || rr.round) AS race_name
    FROM   f1ops.race_result rr
    JOIN   f1ops.race ra ON ra.id = rr.race_id
    WHERE  rr.driver_id = p_driver_id
    ORDER  BY rr.year DESC, rr.round DESC
    LIMIT  p_last_n
  LOOP
    seen  := seen + 1;
    total := total + COALESCE(r.finish_position, 30);   -- a DNF counts as last+
    form_key      := r.race_id || '-' || p_driver_id;
    race_id       := r.race_id;
    year          := r.year;
    round         := r.round;
    race_name     := r.race_name;
    finish_position := r.finish_position;
    position_text := r.position_text;
    grid_position := r.grid_position;
    points        := COALESCE(r.points, 0);
    places_gained := COALESCE(r.grid_position, 0) - COALESCE(r.finish_position, 0);
    rolling_avg   := round(total / seen, 2);
    RETURN NEXT;
  END LOOP;
END;
$$;

/*
 * Record a prediction. Writes, so it is a PROCEDURE and is reached with CALL.
 *
 * The INOUT parameters are how a Postgres procedure answers: CALL returns one
 * row carrying them. That row is what the calling microflow maps, and it is
 * why the module renders a procedure differently from a table function.
 *
 * It validates rather than trusting the caller, because that is the other
 * reason logic sits in the database — the rule lives next to the data and
 * every caller gets it.
 */
CREATE OR REPLACE PROCEDURE f1ops.record_prediction(
  p_driver_id    text,
  p_race_id      integer,
  p_position     integer,
  p_submitted_by text,
  INOUT o_prediction_id bigint DEFAULT NULL,
  INOUT o_accepted      boolean DEFAULT NULL,
  INOUT o_message       text    DEFAULT NULL
)
LANGUAGE plpgsql AS $$
DECLARE
  v_exists boolean;
BEGIN
  o_prediction_id := NULL;
  o_accepted      := false;

  IF p_position IS NULL OR p_position < 1 OR p_position > 20 THEN
    o_message := 'position must be between 1 and 20';
    RETURN;
  END IF;

  SELECT EXISTS (SELECT 1 FROM f1ops.driver WHERE id = p_driver_id) INTO v_exists;
  IF NOT v_exists THEN
    o_message := 'no such driver: ' || COALESCE(p_driver_id, '(null)');
    RETURN;
  END IF;

  SELECT EXISTS (SELECT 1 FROM f1ops.race WHERE id = p_race_id) INTO v_exists;
  IF NOT v_exists THEN
    o_message := 'no such race: ' || COALESCE(p_race_id::text, '(null)');
    RETURN;
  END IF;

  INSERT INTO f1ops.prediction (driver_id, race_id, finish_position, submitted_by)
  VALUES (p_driver_id, p_race_id, p_position, COALESCE(NULLIF(p_submitted_by,''), 'anonymous'))
  ON CONFLICT (driver_id, race_id, submitted_by)
  DO UPDATE SET finish_position = EXCLUDED.finish_position, submitted_at = now()
  RETURNING id INTO o_prediction_id;

  o_accepted := true;
  o_message  := 'recorded';
END;
$$;

/*
 * The same procedure, wrapped as a function — because Mendix cannot call the
 * procedure directly.
 *
 * Mendix's External Database Connector inspects the statement and sends a CALL
 * down JDBC executeUpdate (QueryDispatcher:153). A Postgres CALL with INOUT
 * parameters answers with a row, so the driver refuses:
 * "A result was returned when none was expected". There is no
 * `execute database statement` activity to reach for — the only door is
 * `execute database query`, and it wants a SELECT. FINDINGS §47.
 *
 * So this exists purely so the invocation begins with SELECT. It is one CALL
 * and a RETURN, adds no logic, and is the wrapper every Mendix app that needs a
 * returning procedure will end up writing. The procedure above is untouched and
 * is still what runs.
 */
CREATE OR REPLACE FUNCTION f1ops.record_prediction_fn(
  p_driver_id    text,
  p_race_id      integer,
  p_position     integer,
  p_submitted_by text
)
RETURNS TABLE (
  prediction_id bigint,
  accepted      boolean,
  message       text
)
LANGUAGE plpgsql AS $$
BEGIN
  CALL f1ops.record_prediction(p_driver_id, p_race_id, p_position, p_submitted_by,
                               prediction_id, accepted, message);
  RETURN NEXT;
END;
$$;
SQL

echo "granting"
"${PSQL[@]}" -d "$DB" <<'SQL'
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mendix') THEN
    EXECUTE 'GRANT USAGE ON SCHEMA f1ops TO mendix';
    EXECUTE 'GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA f1ops TO mendix';
    EXECUTE 'GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA f1ops TO mendix';
    EXECUTE 'GRANT EXECUTE ON ALL ROUTINES IN SCHEMA f1ops TO mendix';
  END IF;
END $$;
SQL

echo
echo "f1ops ready:"
"${PSQL[@]}" -d "$DB" -c "SELECT 'drivers' AS t, count(*) FROM f1ops.driver
                          UNION ALL SELECT 'races', count(*) FROM f1ops.race
                          UNION ALL SELECT 'results', count(*) FROM f1ops.race_result;"
"${PSQL[@]}" -d "$DB" -c "SELECT form_key, race_name, finish_position, rolling_avg
                          FROM f1ops.driver_form('ayrton-senna', 3);"
"${PSQL[@]}" -d "$DB" -c "SELECT * FROM f1ops.record_prediction_fn('ayrton-senna', 551, 3, 'setup-check');"
