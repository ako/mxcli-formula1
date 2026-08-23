WITH laps AS (
  SELECT j.driver_number AS driver_number, j.lap_number AS lap_number,
         j.lap_duration AS lap_duration, j.is_pit_out_lap AS is_pit_out_lap,
         CAST(j.date_start AS TIMESTAMP) AS t
    FROM (SELECT unnest(from_json({lapsJson}::JSON,
          '[{"driver_number":"BIGINT","lap_number":"BIGINT","lap_duration":"DOUBLE","is_pit_out_lap":"BOOLEAN","date_start":"VARCHAR"}]')) AS j)
   WHERE j.date_start IS NOT NULL
), cut AS (
  SELECT CASE WHEN {cutLap} <= 0 THEN TIMESTAMP '2999-01-01'
              ELSE COALESCE((SELECT min(t) FROM laps WHERE lap_number = {cutLap} + 1),
                            TIMESTAMP '2999-01-01') END AS t
), st AS (
  SELECT j.driver_number AS driver_number, j.lap_start AS lap_start,
         j.lap_end AS lap_end, j.compound AS compound,
         j.tyre_age_at_start AS tyre_age_at_start
    FROM (SELECT unnest(from_json({stintsJson}::JSON,
          '[{"driver_number":"BIGINT","lap_start":"BIGINT","lap_end":"BIGINT","compound":"VARCHAR","tyre_age_at_start":"BIGINT"}]')) AS j)
), pits AS (
  SELECT j.driver_number AS driver_number, j.lap_number AS lap_number
    FROM (SELECT unnest(from_json({pitJson}::JSON,
          '[{"driver_number":"BIGINT","lap_number":"BIGINT"}]')) AS j)
),
aged AS (
  SELECT l.driver_number, l.lap_number, l.lap_duration, l.is_pit_out_lap,
         s.compound,
         COALESCE(s.tyre_age_at_start,0) + (l.lap_number - s.lap_start) AS tyre_age
    FROM laps l
    LEFT JOIN st s ON s.driver_number = l.driver_number
         AND l.lap_number BETWEEN s.lap_start AND COALESCE(s.lap_end, 9999)
   WHERE l.t < (SELECT t FROM cut)
),
notpit AS (
  SELECT a.* FROM aged a
    LEFT JOIN pits p ON p.driver_number = a.driver_number AND p.lap_number = a.lap_number
   WHERE a.lap_duration IS NOT NULL AND a.is_pit_out_lap IS NOT TRUE
     AND a.lap_number > 1 AND p.lap_number IS NULL
),
med AS (SELECT driver_number, median(lap_duration) AS m FROM notpit GROUP BY 1),
fieldmed AS (SELECT COALESCE(median(m), 90.0) AS m FROM med),
clean AS (
  SELECT n.*, n.lap_duration - d.m AS resid
    FROM notpit n JOIN med d USING (driver_number)
   WHERE n.lap_duration BETWEEN d.m * 0.93 AND d.m * 1.07
),
deg_raw AS (
  SELECT compound, regr_slope(resid, tyre_age) AS fitted, count(*) AS n
    FROM clean WHERE compound IS NOT NULL AND tyre_age IS NOT NULL GROUP BY 1
),
prior AS (
  SELECT * FROM (VALUES ('SOFT',0.060,20),('MEDIUM',0.040,30),('HARD',0.025,40),
                        ('INTERMEDIATE',0.030,30),('WET',0.030,30))
    AS t(compound, per_lap, max_life)
),
/* Every fitted quantity is passed through isfinite before it is used.
 *
 * regr_slope over a single point returns NaN, not NULL, and that is not an
 * edge case here: forecasting from lap 2 leaves exactly one clean lap, so
 * lap_number has no variance and the fuel slope comes back NaN. COALESCE does
 * not catch it and neither does greatest(0.0, x) -- NaN propagates through
 * both -- so it reached the arithmetic, made every projected time NaN, and the
 * External Database Connector rejected the result with "Character N is neither
 * a decimal digit number". Python's DuckDB had handed the same NaN back
 * without complaint, so the backtest never saw it. */
deg AS (
  SELECT r.compound,
         CASE WHEN isfinite(r.fitted)
              THEN least(0.15, greatest(0.0,
                     (r.n * r.fitted + 120 * pr.per_lap) / (r.n + 120)))
              ELSE pr.per_lap END AS per_lap
    FROM deg_raw r JOIN prior pr USING (compound)
),
fuel_raw AS (
  SELECT regr_slope(c.resid - COALESCE(d.per_lap,0) * c.tyre_age, c.lap_number) AS v
    FROM clean c LEFT JOIN deg d USING (compound)
),
fuel AS (
  SELECT CASE WHEN isfinite((SELECT v FROM fuel_raw))
              THEN greatest(-0.20, least(0.0, (SELECT v FROM fuel_raw)))
              ELSE -0.03 END AS per_lap
),
pace AS (
  SELECT c.driver_number,
         CASE WHEN isfinite(median(c.lap_duration
                                   - COALESCE(d.per_lap,0) * c.tyre_age
                                   - (SELECT per_lap FROM fuel) * c.lap_number))
              THEN median(c.lap_duration - COALESCE(d.per_lap,0) * c.tyre_age
                          - (SELECT per_lap FROM fuel) * c.lap_number)
              ELSE median(c.lap_duration) END AS base,
         CASE WHEN isfinite(stddev_samp(c.resid))
              THEN greatest(0.05, least(2.0, stddev_samp(c.resid)))
              ELSE 0.4 END AS noise,
         count(*) AS laps_used
    FROM clean c LEFT JOIN deg d USING (compound)
   GROUP BY 1
),
/* Time lost to a stop, measured from the in-lap and out-lap of the stops
 * already made. A sprint has pit records with no racing stop behind them, and
 * a red flag puts a whole field down the pit lane, so a figure outside the
 * range a real stop can occupy is rejected rather than believed: at Zandvoort
 * that arithmetic returned 653 seconds. */
pitloss AS (
  SELECT median(a.lap_duration + o.lap_duration - 2 * m.m) AS secs
    FROM pits p
    JOIN aged a ON a.driver_number = p.driver_number AND a.lap_number = p.lap_number
    JOIN aged o ON o.driver_number = p.driver_number AND o.lap_number = p.lap_number + 1
    JOIN med  m ON m.driver_number = p.driver_number
   WHERE a.lap_duration IS NOT NULL AND o.lap_duration IS NOT NULL
),
loss AS (
  SELECT CASE WHEN (SELECT secs FROM pitloss) BETWEEN 12 AND 45
              THEN (SELECT secs FROM pitloss) ELSE 20.0 END AS secs
),
/* How long a set of each compound is lasting, from the stints that ended in a
 * stop -- but only ever upward from a prior. Taken as the plain observed
 * maximum it read 2 laps for the medium during the sprint, where the only
 * stints that "ended in a stop" were cars coming in after the flag, and every
 * car in the race was then told it owed a pit stop it was never going to make.
 * Evidence can extend a tyre's life beyond what is expected of it; it should
 * not be able to collapse it. */
life AS (
  SELECT pr.compound,
         greatest(COALESCE(o.max_life, 0), pr.max_life) AS max_life
    FROM prior pr
    LEFT JOIN (
      SELECT s.compound,
             max(s.lap_end - s.lap_start + 1 + COALESCE(s.tyre_age_at_start,0)) AS max_life
        FROM st s
       WHERE EXISTS (SELECT 1 FROM pits p WHERE p.driver_number = s.driver_number
                       AND p.lap_number = s.lap_end)
       GROUP BY 1) o USING (compound)
),
last_lap AS (
  SELECT DISTINCT ON (driver_number) driver_number, lap_number, compound, tyre_age
    FROM aged WHERE lap_duration IS NOT NULL OR is_pit_out_lap
   ORDER BY driver_number, lap_number DESC
),
elapsed AS (
  SELECT a.driver_number,
         sum(COALESCE(a.lap_duration, COALESCE(m.m, (SELECT m FROM fieldmed)))) AS secs,
         count(*) AS laps_done
    FROM aged a LEFT JOIN med m USING (driver_number)
   GROUP BY 1
),
leadlap AS (SELECT max(laps_done) AS n FROM elapsed),
/* Who is leading: furthest, and quickest among those. */
leader AS (
  SELECT driver_number FROM elapsed
   WHERE laps_done = (SELECT n FROM leadlap) ORDER BY secs LIMIT 1
),
/* The leader's elapsed time at every lap of the race so far. A car's gap is
 * measured against the leader at the same number of laps, not against the
 * leader now -- otherwise a car that has completed fewer laps looks quicker
 * for the laps it has not run. */
leader_cum AS (
  SELECT a.lap_number,
         sum(COALESCE(a.lap_duration, (SELECT m FROM fieldmed)))
           OVER (ORDER BY a.lap_number) AS secs
    FROM aged a WHERE a.driver_number = (SELECT driver_number FROM leader)
),
state AS (
  SELECT ll.driver_number, ll.lap_number, ll.compound, COALESCE(ll.tyre_age, 10) AS tyre_age,
         e.laps_done,
         (SELECT n FROM leadlap) - e.laps_done AS laps_down,
         e.secs - COALESCE((SELECT c.secs FROM leader_cum c WHERE c.lap_number = e.laps_done), 0)
           AS gap_s,
         COALESCE((SELECT c.secs FROM leader_cum c WHERE c.lap_number = e.laps_done), 0) AS at_secs,
         greatest(0, {totalLaps} - e.laps_done) AS remaining
    FROM last_lap ll JOIN elapsed e USING (driver_number)
),
plan AS (
  SELECT s.*,
         COALESCE(p.base, (SELECT m FROM fieldmed) + 0.5) AS base,
         COALESCE(p.noise, 0.4) AS noise,
         COALESCE(p.laps_used, 0) AS laps_used,
         COALESCE(d.per_lap, 0.04) AS deg_per_lap,
         /* Three or more laps behind is not a car having a bad race, it is a
          * car that has stopped. One lap of slack would misread anyone who
          * simply has not crossed the line yet. */
         s.laps_down >= 3 AS retired,
         /* Both reasons to stop need laps left to stop in. Without the guard
          * a car at the flag on a set older than the compound's expected life
          * was charged twenty seconds for a stop it could not make: at the end
          * of the sprint that dropped the car that finished second to tenth.
          * The tyre-life stop needs more than a couple of laps to be worth
          * making at all; the compound rule does not, because not making it is
          * a disqualification. */
         greatest(
           CASE WHEN COALESCE(u.compounds_used,1) < 2 AND {totalLaps} > 40
                     AND s.remaining > 0 THEN 1 ELSE 0 END,
           CASE WHEN COALESCE(s.tyre_age,0) + s.remaining > COALESCE(l.max_life, 30)
                     AND s.remaining > 4 THEN 1 ELSE 0 END) AS stops
    FROM state s
    LEFT JOIN pace p USING (driver_number)
    LEFT JOIN deg d ON d.compound = s.compound
    LEFT JOIN life l ON l.compound = s.compound
    LEFT JOIN (SELECT s2.driver_number, count(DISTINCT s2.compound) AS compounds_used
                 FROM st s2 WHERE s2.compound IS NOT NULL
                  AND s2.lap_start <= (SELECT lap_number FROM last_lap l2
                                        WHERE l2.driver_number = s2.driver_number)
                GROUP BY 1) u USING (driver_number)
),
plan2 AS (
  SELECT p.*, p.tyre_age / (p.stops + 1.0) + p.remaining / (2.0 * (p.stops + 1.0)) AS mean_age
    FROM plan p
),
sims AS (SELECT unnest(generate_series(1, 2000)) AS sim),
sc AS (SELECT sim, CASE WHEN random() < 0.35 THEN 0.30 ELSE 1.0 END AS compress FROM sims),
draw AS (
  SELECT p.driver_number, s.sim,
         p.retired OR random() < 1 - pow(1 - 0.0009, p.remaining) AS out,
         /* Time to complete the full race distance: where the leader was when
          * this car finished the laps it has, plus its own gap, plus its own
          * pace over the laps it still owes -- which is one more for a car a
          * lap down, so being lapped costs a lap without a special case. */
         p.at_secs + p.gap_s * sc.compress
           + p.remaining * (p.base + p.deg_per_lap * p.mean_age
                            + p.noise * (random() * 2 - 1) * 1.7)
           + p.stops * ((SELECT secs FROM loss) + random() * 3)
           /* A fixed couple of seconds of everything a pace model cannot see:
            * a lock-up, a slow lap in traffic, a pass that does or does not
            * come off. Without it the spread is proportional to the laps left,
            * so with four laps to go the model reported a 99.6% winner and the
            * race changed hands anyway. */
           + (random() * 2 - 1) * 2.0 AS finish_time
    FROM plan2 p CROSS JOIN sims s JOIN sc ON sc.sim = s.sim
),
ranked AS (
  SELECT *, row_number() OVER (PARTITION BY sim ORDER BY out ASC, finish_time ASC) AS pos
    FROM draw
)
SELECT {sessionKey} AS sessionKey,
       r.driver_number AS driverNumber,
       pl.lap_number AS lapNow,
       pl.remaining AS lapsRemaining,
       pl.stops AS stopsLeft,
       pl.laps_used AS lapsUsed,
       round(CASE WHEN isfinite(pl.base) THEN pl.base ELSE 0 END, 3) AS basePace,
       round(CASE WHEN isfinite(pl.deg_per_lap) THEN pl.deg_per_lap ELSE 0 END, 4)
         AS degPerLap,
       (SELECT round(secs,2) FROM loss) AS pitLoss,
       round(avg(r.pos), 2) AS meanPosition,
       CAST(median(r.pos) AS BIGINT) AS medianPosition,
       round(count(*) FILTER (WHERE r.pos = 1) / 2000.0, 4) AS pWin,
       round(count(*) FILTER (WHERE r.pos <= 3) / 2000.0, 4) AS pPodium,
       round(count(*) FILTER (WHERE r.pos <= 10) / 2000.0, 4) AS pPoints,
       CAST(quantile_cont(r.pos, 0.1) AS BIGINT) AS bestCase,
       CAST(quantile_cont(r.pos, 0.9) AS BIGINT) AS worstCase,
       round(CASE WHEN isfinite(avg(r.finish_time) FILTER (WHERE NOT r.out))
                  THEN avg(r.finish_time) FILTER (WHERE NOT r.out)
                  ELSE 0 END, 1) AS projectedTime
  FROM ranked r JOIN plan2 pl ON pl.driver_number = r.driver_number
 GROUP BY r.driver_number, pl.lap_number, pl.remaining, pl.stops, pl.laps_used,
          pl.base, pl.deg_per_lap
 ORDER BY meanPosition
