# Formula1Backend

<!-- mxcli-brain -->

Decisions anchored to the Formula1Backend module. Loaded when Formula1Backend is in play,
not otherwise.

## DuckDB is reached through a connection typed 'BYOD', which is not in Mendix's own documented picker for the External Database Connector. It is what the 11.13+ runtime actually accepts for a jdbc:duckdb: URL, and it is the only reason this app has a transformation layer at all. Changing the type to anything documented breaks every derived resource.

Anchors: `@Formula1Backend.F1Warehouse` · id `e51310` · 2026-09-04

## Every cycle re-fetches the whole session rather than only new laps. The obvious incremental filter -- lap_number >= (highest lap stored) - 1 -- takes a maximum across all cars and only ever rises, so the window closes over anyone who falls behind and their laps are never requested again. It cost a qualifying session 122 of 377 laps and a sprint one lapped car's entire race. Refetching everything costs 13% more bytes: intervals is already unfiltered at 29,593 rows against 1,423 laps.

Anchors: `@Formula1Backend.Sync_Live` · id `9fe68d` · 2026-09-04

## The forecaster runs on its own scheduled event with its own three fetches rather than as another tier of the capture cycle. The cycle is what captures a race, and a race happens once; a forecaster reading pace out of a regression can fail in ways nobody has enumerated, and it must not be able to take the timing screen down with it. Separate microflow, separate schedule, separate transaction.

Anchors: `@Formula1Backend.SE_LiveForecast` · id `a05d4b` · 2026-09-04

## GetOpenF1Forecast's SQL is generated, not authored in the model. It lives in spikes/forecaster/forecast.sql and is embedded by spikes/forecaster/embed.py, which strips comments and doubles quotes. Editing the copy here silently breaks the offline backtest, which drives the file directly so that it scores the exact text the model runs. Change the file, run backtest.py, then embed.py.

Anchors: `@Formula1Backend.F1Warehouse` · id `a4552b` · 2026-09-04

## LiveToken is deliberately not published on the admin service, which otherwise exposes every raw table. It holds an OpenF1 bearer token. Every other admin grant is READ-only for the same reason; the service is a debugging surface, not an API.

Anchors: `@Formula1Backend.LiveToken` · id `b7471b` · 2026-09-04

## A pit record is only a stop if its lane_duration is plausible. OpenF1 files the drive to parc fermé after the chequered flag as a pit entry dated to lap 2 -- 21 of them in one grand prix, each about 1,570 seconds against a real stop's 12 to 18. Counted at face value every car gains a phantom stop, which inflates the classification and tells the forecaster cars have served stops they still owe.

Anchors: `@Formula1Backend.F1Warehouse` · id `6a36e2` · 2026-09-04

## The overtakes endpoint sends no lap number, only a timestamp. Reading lap_number from the payload returns null for every pass -- 292 of them in one race -- and stores null, with no error anywhere; the only symptom was the story panel rendering 'passed ALB for P16 on lap' with nothing after it. The lap is derived by ASOF-joining the pass timestamp to the overtaking car's lap table.

Anchors: `@Formula1Backend.Sync_Slow` · id `eb1572` · 2026-09-04
