
## 74. The race, captured whole — and the one row that was wrong all day

Zandvoort, 72 laps, synced live by the app for two hours. Diffed against
OpenF1's own record afterwards:

```
ours 1369   OpenF1 1369   missing 0   extra 0
drivers whose final lap matches: 22 of 22
```

138 cycles, all completed, averaging 47 seconds of a 60-second schedule. The
final classification matches the official result exactly, including the gaps to
the millisecond: 11.536, 15.906, 16.755, 17.258, 32.332, 79.915.

That is §71 paying for itself. The watermark fix — fetch the whole lap table
every cycle, merge over what is stored — means a missed cycle is a delay rather
than a hole. Under the old narrowing this race would have quietly lost every
lapped car, and there were five of them.

### The entry list was written once and could not be corrected

`Sync_Entry` opened with a guard:

```
RETRIEVE $Have FROM Formula1Backend.LiveDriver WHERE SessionKey = $Key LIMIT 1;
IF $Have != empty THEN
  SET $Result = 'entry list already captured';
  RETURN $Result;
END IF;
```

An entry list does not change, so read it once. It does change. The sync was
parked on the race the night before — which is the sensible thing to do and is
what made this happen — and captured the provisional entry, which had **car 6
in the second Racing Bulls**. The race was driven by **car 22**.

So the whole race was stored against an entry list containing a driver who
never started and missing one who finished eleventh, and a classification
cannot show a name it does not have. `LiveLap` had car 22 in all 72 laps;
`LiveDriver` had car 6 and no car 22.

The tell was arithmetic, not appearance: the classification ran 1…10, then 12.
**A gap in a sequence that should be dense is worth more than a glance at the
rows.** Position 11 was not missing — it had nothing to join to.

Now re-read every pass, updated in place rather than deleted and recreated
(RowId is an autonumber and this table's OData key, so recreating would hand a
client a new identity for the same driver every minute), with cars no longer
entered removed. It corrected itself one cycle after the restart: car 6 out,
car 22 in, 22 of 22 cars named.

The cost of re-reading is one request per cycle on a tier that already carries
two. The cost of not re-reading was a race.

**This is the third time a once-only capture has been wrong** — §63 was the
entry list not being fetched at all, §71 was a watermark that only rose. The
pattern: *anything derived from "we already have it" is a bet that the source
is immutable*, and for a live feed that bet keeps losing.

### What the forecaster did, and where it is still wrong

| lap | the model's call |
|---|---|
| 2 | NOR 83% |
| 4 | **LIN 83%**, BEA 17% |
| 6 | **PER 15%**, SAI 10% |
| 15 | ANT 44%, NOR 38% |
| 25 | ANT 49%, NOR 19% |
| 45 | ANT 53%, NOR 17% |
| 55 | LEC 47%, NOR 26% |
| 65 | NOR 74% |
| 71 | NOR 99% |

Norris won and Antonelli was second, so from lap 10 on this is a reasonable
account of a race that was genuinely between those two. Laps 2–6 are not:
Lindblad at 83% and Bearman at 17% on lap 4, when Bearman retired on lap 2.

The `isfinite` guards in §73 fixed the *arithmetic* of the early laps, and I
took the improved backtest numbers as evidence the early laps were now sound.
They were not, and the two archived races did not show it because neither had a
first-lap incident. **A model can be numerically correct and still absurd.**

The missing piece is specific and worth naming: the simulation's noise term is
`stddev_samp` of a driver's lap-time residuals — the scatter *between* their
laps. With two laps that statistic is meaningless, and more importantly it is
the wrong quantity: what is uncertain early on is **the pace estimate itself**,
which shrinks as `1/sqrt(n)`. There is no term for it, so two laps of data
produce the same confidence as forty. `LapsUsed` is carried to the screen and
says 2, which is honest reporting of an unreliable number rather than a
reliable one.

### The tail of the classification is the position feed, not the result

Ours shows two cars at 14, two at 15, two at 16. In each pair the officially
classified car is correct and the duplicate is a retirement holding the
position it had when it stopped — `Position` is ASOF-joined from the position
feed at each car's last lap, and a car that stopped on lap 52 keeps lap 52's
answer. Official classification ranks by laps completed, then time, and marks
the rest as not classified. The data is right; the ordering rule is the live
timing screen's, not the stewards'.
