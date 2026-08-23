#!/usr/bin/env python3
"""
A race-result forecaster, prototyped offline against the archived sessions.

The point of doing it here first is that the model is the risky part and the
plumbing is not: this reads exactly the five OpenF1 payloads the in-app sync
already holds in memory every cycle (laps, stints, pit, intervals,
race_control), computes in DuckDB, and returns one row per driver. Porting it
means moving the SQL into Sync_Live's existing derivation and writing the
result to an entity -- no new fetches, no new dependencies.

Run:
    python3 spikes/forecaster/forecast.py 11342 --at 20
    python3 spikes/forecaster/forecast.py --backtest
"""
import argparse, gzip, json, sys
import duckdb

ARCHIVE = 'data/openf1'
EPS = ('laps', 'stints', 'pit', 'intervals', 'race_control', 'session_result')


# gap_to_leader is a number until a car is lapped, when it becomes "+1 LAP".
# Sampled inference picks DOUBLE and then fails 21,898 records in. Reading the
# column as text and casting per row is the only thing that survives both.
COLUMNS = {
    'intervals': "{date:'TIMESTAMP', session_key:'BIGINT', driver_number:'BIGINT',"
                 " gap_to_leader:'VARCHAR', interval:'VARCHAR'}",
}


def load(con, key):
    for ep in EPS:
        src = f'{ARCHIVE}/{key}/{ep}.json.gz'
        cols = COLUMNS.get(ep)
        opt = f", columns = {cols}" if cols else ''
        con.execute(f"create or replace table {ep} as "
                    f"select * from read_json(?, format='array'{opt})", [src])
    return con


# ---------------------------------------------------------------- the model --

FORECAST_SQL = """
-- The moment we are forecasting from: the leader starting lap $L+1, i.e. the
-- instant the leader completed lap $L. Everything after it is unknown.
with cut as (
  select min(date_start) as t from laps where lap_number = $L + 1
),
-- Tyre age per lap, from the stint table. A stint carries its age at the start,
-- so a set that has already done laps elsewhere is not treated as new.
aged as (
  select l.driver_number, l.lap_number, l.lap_duration, l.is_pit_out_lap,
         l.date_start, s.compound,
         s.tyre_age_at_start + (l.lap_number - s.lap_start) as tyre_age
  from laps l
  left join stints s
    on s.driver_number = l.driver_number
   and l.lap_number between s.lap_start and s.lap_end
  where l.date_start < (select t from cut)
),
-- The in-lap is the lap the car entered the pits on; the out-lap is flagged.
-- Lap 1 is a standing start. None of the three says anything about pace.
notpit as (
  select a.* from aged a
  left join pit p on p.driver_number = a.driver_number and p.lap_number = a.lap_number
  where a.lap_duration is not null and a.is_pit_out_lap is not true
    and a.lap_number > 1 and p.lap_number is null
),
-- Safety cars, red flags and traffic are not filtered by name but by size: a
-- lap more than 7% off that driver's own median is not a lap they were racing.
-- (The 107% rule is F1's own threshold for the same judgement.)
med as (
  select driver_number, median(lap_duration) as m from notpit group by driver_number
),
-- Traffic is the other thing that makes a lap time not a pace. A car two
-- tenths behind another is running the car ahead's race, not its own, and
-- averaging those laps in reports the whole train at the pace of its slowest
-- member. The intervals feed carries the gap to the car in front, so laps run
-- with less than 2.0s of clear air are dropped -- and if that leaves a driver
-- with almost nothing, their unfiltered laps are used rather than none.
air as (
  select n.driver_number, n.lap_number,
         max(try_cast(i.interval as double)) as clear
  from notpit n
  left join intervals i
    on i.driver_number = n.driver_number
   and i.date between n.date_start and n.date_start + interval 90 second
  group by 1, 2
),
inrange as (
  select n.*, n.lap_duration - d.m as resid, coalesce(a.clear, 99) as clear
  from notpit n join med d using (driver_number)
  left join air a using (driver_number, lap_number)
  where n.lap_duration between d.m * 0.93 and d.m * 1.07
),
enough as (
  select driver_number, count(*) filter (where clear >= 2.0) as free
  from inrange group by 1
),
clean as (
  select i.* from inrange i join enough e using (driver_number)
  where i.clear >= 2.0 or e.free < 4
),
-- Degradation, pooled across the field per compound. Per driver there are far
-- too few laps to fit a slope; pooled there are hundreds. Pace differences are
-- already removed by the residual, so what is left is the tyre.
--
-- The raw slope is then shrunk toward a prior, because early in a race it is
-- fitted on a few dozen laps and is wildly unstable. At Hungary lap 21 it came
-- back as -0.026 s/lap for the soft on 33 samples -- tyres getting faster as
-- they age -- and projected over 49 remaining laps that handed two midfielders
-- a minute they had not earned and put them on the podium. Clamped at zero and
-- pulled toward a plausible prior by sample size, the same fit is harmless
-- when it is thin and takes over when it is not.
deg_raw as (
  select compound, regr_slope(resid, tyre_age) as fitted, count(*) as n
  from clean where compound is not null and tyre_age is not null
  group by compound
),
prior as (
  select * from (values ('SOFT', 0.060), ('MEDIUM', 0.040), ('HARD', 0.025),
                        ('INTERMEDIATE', 0.030), ('WET', 0.030))
    as t(compound, per_lap)
),
deg as (
  select r.compound,
         least(0.15, greatest(0.0,
           (r.n * r.fitted + $KDEG * pr.per_lap) / (r.n + $KDEG))) as per_lap,
         r.n
  from deg_raw r join prior pr using (compound)
),
-- Fuel burn, pooled over everything with the tyre effect taken back out.
-- Negative: the car gets lighter and faster as the race runs.
fuel as (
  select regr_slope(resid - coalesce(d.per_lap, 0) * c.tyre_age, c.lap_number) as per_lap
  from clean c left join deg d using (compound)
),
-- Each driver's pace on a fresh tyre with a full car, which is the only pace
-- that can be projected onto a lap they have not run yet.
pace as (
  select c.driver_number,
         median(c.lap_duration
                - coalesce(d.per_lap, 0) * c.tyre_age
                - (select per_lap from fuel) * c.lap_number) as base,
         stddev_samp(c.resid) as noise,
         count(*) as laps_used
  from clean c left join deg d using (compound)
  group by c.driver_number
),
-- Time lost to a stop, measured rather than assumed: the in-lap and the
-- out-lap against two of that driver's normal laps.
--
-- Before anyone has stopped there is nothing to measure, and this returned
-- NULL -- which propagated through the projection and made every finish time
-- NULL, so the ranking fell back to row order and handed all twenty-two cars a
-- mean finishing position of 11.0. The forecast looked like honest uncertainty
-- and was arithmetic failure. A prior keeps the early laps meaningful, and the
-- measurement takes over the moment the first car stops.
pitloss as (
  select coalesce(median(a.lap_duration + o.lap_duration - 2 * m.m), 20.0) as secs
  from pit p
  join aged a on a.driver_number = p.driver_number and a.lap_number = p.lap_number
  join aged o on o.driver_number = p.driver_number and o.lap_number = p.lap_number + 1
  join med m on m.driver_number = p.driver_number
  where a.lap_duration is not null and o.lap_duration is not null
),
-- `pitloss` is empty, not NULL, when the joins match no rows at all.
loss as (select coalesce((select secs from pitloss), 20.0) as secs),
-- How long a set of each compound is lasting in this race, taken from the
-- longest stints anyone has completed on it.
life as (
  select compound, max(lap_end - lap_start + 1 + tyre_age_at_start) as max_life
  from stints s
  where exists (select 1 from pit p
                where p.driver_number = s.driver_number and p.lap_number = s.lap_end)
  group by compound
),
-- Where everyone actually is: last lap run, tyre on the car, gap to the leader.
last_lap as (
  select distinct on (driver_number) driver_number, lap_number, compound, tyre_age
  from aged where lap_duration is not null or is_pit_out_lap
  order by driver_number, lap_number desc
),
-- The gap to the leader, rebuilt from elapsed race time rather than read from
-- the intervals feed.
--
-- This is what fixed the mid-race collapse. Taken from the feed, the gap is
-- whatever it was at the instant of the last sample, and in the pit window
-- that instant is often an in-lap, an out-lap or the moment a rival is
-- stationary -- so the model compared cars caught in incompatible states and
-- ranked them confidently wrong. The sum of a car's own lap times has the
-- stops already inside it and cannot be caught mid-manoeuvre.
elapsed as (
  select a.driver_number,
         sum(coalesce(a.lap_duration, m.m)) as secs,
         count(*) as laps_done
  from aged a join med m using (driver_number)
  group by a.driver_number
),
lead_pace as (select min(m) as lap_s from med),
last_gap as (
  select e.driver_number,
         e.secs - (select min(secs) from elapsed
                   where laps_done = (select max(laps_done) from elapsed))
           + ((select max(laps_done) from elapsed) - e.laps_done)
             * (select lap_s from lead_pace) as gap_s,
         '' as gap_raw
  from elapsed e
),
used as (
  select driver_number, count(distinct compound) as compounds_used
  from stints s where compound is not null
    and s.lap_start <= (select max(lap_number) from last_lap where driver_number = s.driver_number)
  group by driver_number
),
leadlap as (select max(lap_number) as n from last_lap),
state as (
  select ll.driver_number, ll.lap_number, ll.compound, ll.tyre_age,
         -- A lapped car has no gap in seconds. One lap down is one lap of the
         -- leader's pace, which is the only honest conversion available.
         coalesce(lg.gap_s,
                  case when lg.gap_raw like '%LAP%'
                       then cast(regexp_extract(lg.gap_raw, '(\\d+)', 1) as double)
                            * (select min(base) from pace)
                       else null end,
                  0) as gap_s,
         $TOTAL - (select n from leadlap) as remaining,
         coalesce(u.compounds_used, 1) as compounds_used
  from last_lap ll
  left join last_gap lg using (driver_number)
  left join used u using (driver_number)
),
-- Stops still to come. Two reasons to stop: the rule that says two compounds
-- must be used, and a tyre that will not reach the end.
plan as (
  select s.*,
         p.base, coalesce(p.noise, 0.4) as noise,
         coalesce(d.per_lap, 0.05) as deg_per_lap,
         greatest(
           case when s.compounds_used < 2 then 1 else 0 end,
           case when s.tyre_age + s.remaining
                     > coalesce(l.max_life, 40) then 1 else 0 end
         ) as stops
  from state s
  join pace p using (driver_number)
  left join deg d on d.compound = s.compound
  left join life l on l.compound = s.compound
),
-- The average tyre age over the laps that are left, which is what the
-- degradation slope has to be multiplied by. A car that will stop again spends
-- most of the remaining race on rubber it has not fitted yet, so its current
-- tyre only counts for the fraction of the race run on it. Without this the
-- projection charged every car for ageing one set across fifty laps and buried
-- whoever had just taken a hard tyre -- at Hungary that was the eventual
-- winner, forecast fifth.
plan2 as (
  select p.*,
         p.tyre_age / (p.stops + 1.0)
           + p.remaining / (2.0 * (p.stops + 1.0)) as mean_age
  from plan p
),
sims as (select unnest(generate_series(1, $SIMS)) as sim),
-- One safety car draw per simulation, applied to the whole field: it bunches
-- the pack, which is the single largest thing that can happen to a projected
-- gap and the one most often left out.
sc as (
  select sim,
         case when random() < $PSC then 0.30 else 1.0 end as compress
  from sims
),
draw as (
  select p.driver_number, s.sim,
         -- retirement: a small per-lap hazard over the laps that are left
         random() < 1 - pow(1 - $HAZARD, p.remaining) as dnf,
         p.gap_s * sc.compress
           + p.remaining * (p.base
                            + p.deg_per_lap * p.mean_age
                            + p.noise * (random() * 2 - 1) * 1.7)
           + p.stops * (select secs from loss)
           + p.stops * (random() * 3)         -- a stop can go wrong
           as finish_time
  from plan2 p cross join sims s join sc on sc.sim = s.sim
),
ranked as (
  select *, row_number() over (partition by sim
              order by dnf asc, finish_time asc) as pos
  from draw
)
select r.driver_number,
       (select lap_number from state st where st.driver_number = r.driver_number) as lap_now,
       round(avg(r.pos), 2) as mean_pos,
       cast(median(r.pos) as int) as median_pos,
       round(count(*) filter (where r.pos = 1) / cast($SIMS as double), 3) as p_win,
       round(count(*) filter (where r.pos <= 3) / cast($SIMS as double), 3) as p_podium,
       round(count(*) filter (where r.pos <= 10) / cast($SIMS as double), 3) as p_points,
       round(avg(r.finish_time) filter (where not r.dnf), 1) as proj_gap,
       (select stops from plan2 pl where pl.driver_number = r.driver_number) as stops_left,
       -- How much the driver's own pace estimate rests on. Under about eight
       -- clean laps the forecast is a guess with a decimal point on it, and
       -- the screen should say so rather than draw it.
       (select laps_used from pace pc where pc.driver_number = r.driver_number) as laps_used
from ranked r
group by r.driver_number
order by mean_pos
"""


COLS = ['driver_number', 'lap_now', 'mean_pos', 'median_pos', 'p_win',
        'p_podium', 'p_points', 'proj_gap', 'stops_left', 'laps_used']


def forecast(con, at_lap, total_laps, sims=2000, psc=0.35, hazard=0.0009,
             kdeg=120):
    sql = (FORECAST_SQL
           .replace('$L', str(at_lap)).replace('$TOTAL', str(total_laps))
           .replace('$SIMS', str(sims)).replace('$PSC', str(psc))
           .replace('$KDEG', str(kdeg))
           .replace('$HAZARD', str(hazard)))
    return [dict(zip(COLS, r)) for r in con.execute(sql).fetchall()]


def truth(con):
    rows = con.execute("""
        select driver_number, position, dnf from session_result
        where position is not null order by position""").fetchall()
    return [dict(driver_number=r[0], position=r[1], dnf=r[2]) for r in rows]


# ------------------------------------------------------------- measuring it --

def _rank(vals):
    order = sorted(range(len(vals)), key=lambda i: vals[i])
    r = [0.0] * len(vals)
    for pos, i in enumerate(order):
        r[i] = pos + 1
    return r


def score(pred, act):
    """Spearman on order, plus how often the winner and the podium are right."""
    apos = {a['driver_number']: a['position'] for a in act if not a['dnf']}
    m = [p for p in pred if p['driver_number'] in apos]
    n = len(m)
    if n < 5:
        return None
    pr = _rank([p['mean_pos'] for p in m])
    ar = _rank([apos[p['driver_number']] for p in m])
    d2 = sum((pr[i] - ar[i]) ** 2 for i in range(n))
    rho = 1 - 6 * d2 / (n * (n * n - 1))
    winner = act[0]['driver_number']
    pod_p = {p['driver_number'] for p in pred[:3]}
    pod_a = {a['driver_number'] for a in act[:3]}
    brier = sum((p['p_win'] - (1.0 if p['driver_number'] == winner else 0.0)) ** 2
                for p in pred) / len(pred)
    mae = sum(abs(p['mean_pos'] - apos[p['driver_number']]) for p in m) / n
    return dict(rho=round(rho, 3), winner_right=pred[0]['driver_number'] == winner,
                podium_hit=len(pod_p & pod_a), brier=round(brier, 4),
                mae=round(mae, 2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('session', nargs='?', default='11342')
    ap.add_argument('--at', type=int, default=20)
    ap.add_argument('--sims', type=int, default=2000)
    ap.add_argument('--backtest', action='store_true')
    a = ap.parse_args()

    con = duckdb.connect()
    if a.backtest:
        for key in ('11342', '11348'):
            load(con, key)
            total = con.execute(
                "select max(number_of_laps) from session_result").fetchone()[0]
            print(f'\n=== session {key} -- {total} laps ===')
            print(f'{"at lap":>7} {"rho":>6} {"MAE":>5} {"winner":>7} {"podium":>7} {"brier":>7}')
            for frac in (0.15, 0.3, 0.5, 0.7, 0.85):
                L = max(3, int(total * frac))
                p = forecast(con, L, total, a.sims)
                s = score(p, truth(con))
                if s:
                    print(f'{L:>7} {s["rho"]:>6} {s["mae"]:>5} '
                          f'{"yes" if s["winner_right"] else "no":>7} '
                          f'{str(s["podium_hit"])+"/3":>7} {s["brier"]:>7}')
        return

    load(con, a.session)
    total = con.execute("select max(number_of_laps) from session_result").fetchone()[0]
    p = forecast(con, a.at, total, a.sims)
    hdr = (f'{"car":>4} {"lap":>4} {"mean":>6} {"med":>4} {"P(win)":>7} '
           f'{"P(pod)":>7} {"P(pts)":>7} {"proj gap":>9} {"stops":>6} {"laps":>5}')
    print(hdr)
    for r in p:
        print(f'{r["driver_number"]:>4} {r["lap_now"]:>4} {r["mean_pos"]:>6} '
              f'{r["median_pos"]:>4} {r["p_win"]:>7} {r["p_podium"]:>7} '
              f'{r["p_points"]:>7} {r["proj_gap"]:>9} {r["stops_left"]:>6} '
              f'{r["laps_used"]:>5}')
    act = truth(con)
    print()
    print('actual :', ' '.join(str(int(a["driver_number"])) for a in act[:10]))
    print('forecast:', ' '.join(str(int(r["driver_number"])) for r in p[:10]))
    print('score  :', score(p, act))


if __name__ == '__main__':
    main()
