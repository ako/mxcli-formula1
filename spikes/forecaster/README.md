# A race-result forecaster

One DuckDB statement, run once per sync cycle, that turns the race so far into
a distribution over finishing positions.

    python3 spikes/forecaster/forecast.py 11342 --at 21
    python3 spikes/forecaster/forecast.py --backtest

## Why it is a spike first

The plumbing is not the risky part. The forecaster reads exactly the payloads
`Sync_Live` already holds in memory every cycle — `laps`, `stints`, `pit`,
`intervals` — so wiring it in is one more statement against JSON that has
already been fetched. The model is the risky part, and a model is only worth
wiring in once it has been measured against races whose results are known.

That is what the archive is for. `session_result.json.gz` carries the finishing
order, so the same script can forecast from lap *N* and score itself against
what actually happened.

## The model

**Pace.** Take each driver's laps, drop the ones that are not about pace: lap 1,
the in-lap, the out-lap, anything more than 7% off that driver's own median
(which removes safety cars and traffic without having to identify them), and
anything run with less than 2.0s of clear air to the car ahead. Fit tyre
degradation per compound *pooled across the field* — one driver has a handful
of laps, the field has hundreds — and fuel burn pooled over everything. What is
left per driver is their pace on a fresh tyre with a full car, which is the only
pace that can be projected onto a lap they have not run.

**Position.** Rebuild the gap to the leader from the sum of each car's own lap
times rather than reading the intervals feed, so a car caught mid-stop is not
compared against one in clear air.

**Strategy.** Stops still to come, from the two-compound rule and from whether
the current set will reach the end at the stint lengths this race is actually
producing. Time lost per stop is measured from the in-lap and out-lap of the
stops already made.

**Simulation.** 2,000 runs. Each draws per-driver pace noise, a retirement
hazard over the remaining laps, a bad-stop penalty, and one safety car for the
whole field that compresses the gaps. Rank each run, then count.

Output is one row per driver: mean and median finishing position, P(win),
P(podium), P(points), projected gap, stops left, and how many clean laps the
estimate rests on.

## What it costs

**18 ms** for 2,000 simulations, over data already in memory. The cycle budget
is 45s of a 60s schedule and currently uses 49s across three passes, so this is
one extra round trip, not a new fetch.

## How well it works

Spearman ρ between forecast order and final classification, and mean absolute
position error, forecasting from each lap of two archived races:

| | lap 2 | lap 4 | lap 10 | lap 20 | lap 35 | lap 55 |
|---|---|---|---|---|---|---|
| Hungary (70 laps) ρ | 0.22 | 0.92 | 0.93 | 0.98 | 0.95 | 0.95 |
| Hungary MAE | 4.5 | 2.2 | 1.7 | 1.5 | 1.9 | 1.7 |
| Zandvoort sprint (24) ρ | −0.27 | 0.98 | 0.99 | 0.99 | — | — |
| sprint MAE | 5.6 | 1.1 | 0.7 | 0.5 | — | — |

Lap 2 is noise and should be shown as such: only lap 2 itself survives the
filters, so there is nothing to fit. From roughly lap 4 the order is stable and
the error sits around one and a half to two positions for a grand prix.

## Two bugs worth remembering

**A NULL that looked like humility.** Before the first pit stop there is no
in-lap to measure, so the measured pit loss was NULL, and `stops * NULL` made
every projected finish time NULL. The ranking then fell back to row order and
gave all twenty-two cars a mean finishing position of 11.0 with a 5% win
chance each. It reads exactly like a model honestly reporting that it does not
know yet. It was arithmetic failure, and giving pit loss a prior took the
sprint's lap-3 forecast from ρ = −0.22 to ρ = 0.98.

**A fitted slope with nothing behind it.** Early in a race the per-compound
degradation fit runs on a few dozen laps. At Hungary lap 21 it came back as
−0.026 s/lap for the soft: tyres getting *faster* as they age. Extrapolated
over 49 remaining laps that handed two midfielders a minute they had not earned
and put them on the podium; both finished a lap down. Shrinking the fit toward
a per-compound prior by sample size, and clamping it at zero, took that lap from
ρ = 0.55 to ρ = 0.97.

Both share a shape: **the forecast is least reliable exactly where the data is
thinnest, and that is where it looks most confident.**

## What it does not model

- **Overtaking.** Cars are ranked on projected time, so a car three seconds a
  lap quicker is assumed to get past. At Zandvoort, where passing is genuinely
  hard, that will read optimistically for anyone stuck behind a slower car.
- **Why cars retire.** Retirement is a flat hazard per lap. A car limping with
  a problem looks the same as a healthy one.
- **Weather changes.** A dry-to-wet transition invalidates every pace estimate
  it has. Rainfall is in the weather feed and is not read.
- **Non-linear degradation.** A cliff is a step, and this fits a line.
