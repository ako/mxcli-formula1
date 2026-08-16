
---

## 52. What the traces said: 129 backend calls for four pages, and why

*Measured 2026-08-10 on `38a1137`, both apps under `--trace-otlp`, one Playwright
walk of the four redesigned pages.*

The observation setup went in to answer "are there errors and bottlenecks". No
errors. One bottleneck, and it is structural rather than a slow query.

**A four-page walk made 131 inbound OData requests and spent 69.8s in
DuckDB.** Split by page:

| page | backend requests | backend time |
|---|---|---|
| Driver career | 24 | 8.5s |
| Season summary | 29 | 7.5s |
| **Race weekend** | **56** | **49.6s** |
| Constructor | 20 | 9.0s |

Almost none of it is distinct work. The weekend page's 56 requests are seven
distinct queries:

```
  28x  19884ms  Calendar ? calendarKey eq '1119-c'
  10x  10715ms  WeekendShape ? raceId eq 1119
  10x   5400ms  LapChart ? (year eq 2024) and (round eq 18)
   6x  10593ms  RaceSessions ? raceId eq 1119
   1x   2313ms  RaceWeekend ? raceId eq 1119
   1x    719ms  Calendar ? year eq 2024
```

### The 28

`Calendar ? calendarKey eq '1119-c'` is the page *parameter* — the row the page
was opened with. It is read twenty-eight times to draw one page.

The page has exactly twenty-eight datasources that mention `$Race`: ten chart
series on the weekend-shape chart, ten on the lap chart, six on the pace chart
and its table, plus the banner data view and the round chips. Twenty-eight
datasources, twenty-eight reads. `describe page` confirms the count:

```
     10 Formula1Frontend.DS_WeekendShape
     10 Formula1Frontend.DS_LapChart
      6 Formula1Frontend.DS_WeekendSessions
      1 Formula1Frontend.DS_WeekendRounds
      1 Formula1Frontend.DS_Weekend
```

So: **a page parameter that is an external entity is re-fetched from the remote
service once per datasource that references it.** A local persistent object
would be read from the cache; an external one goes back over HTTP, runs the
read microflow, and scans the CSVs again. Nineteen seconds of the page's
forty-nine are one row, fetched twenty-eight times.

Both multipliers have the same root: **every chart series carries its own
datasource.** Ten lines is ten identical calls to the same microflow with the
same argument, and each of those ten first re-resolves the page parameter. The
season page shows the same shape in miniature — `SeasonProgress ? year eq 2024`
six times, `Seasons ? year eq 2024` thirteen times.

### The fix is the one already used on the constructors' bar chart

A **dynamic** series takes one datasource and splits it into traces by a
group-by attribute. `§51` reached for it to get per-bar colours; it is also the
answer here. Ten static series become one dynamic series, and the page's
datasource count — and therefore its page-parameter reads — falls with it:

```
weekend page   28 datasources -> 6      56 requests -> ~11
```

It needs the resources reshaped from wide to long: `WeekendShape` and
`LapChart` currently return `s1name … s10name` / `s1value … s10value` columns
per row, and a dynamic series wants one row per point with a name column. That
reshape pays a third dividend — `dynamicName` **is** bound to the series
datasource where `staticName` is not (§51), so the legend could finally carry
driver names instead of "P1".."P10", and the compromise that section documents
would go away.

### Two smaller things

**Authentication costs five Postgres round trips per request.** Every inbound
OData call runs `AuthenticateApiClient`, which retrieves `System.User` by name:
131 requests, 655 SELECTs, 1515ms. Correct, and cheap per call — but it scales
with the request count, so it is another reason the number above matters. A
cache keyed on the API key would remove it; at this volume it is not the
problem.

**Tracing itself is not free.** The same walk takes roughly three times as long
with `--trace-otlp` attached as without — the login step alone went from ~12s to
~20s. mxcli's help says unfiltered tracing is ~10x and applies default span
filters; even filtered, timings read under tracing are the shape of the problem,
not its magnitude. The *ratios* above are what to trust.

### What made it visible

Nothing in `mx check`, the lint rules, the runtime log or the page itself says
"this datasource will be evaluated twenty-eight times". The count only exists
once spans carry parent ids and durations, which is the whole argument for
`--trace-otlp` over `--trace`: the console exporter would have shown twenty-eight
`GET /*` spans with no way to tell they were the same row.
