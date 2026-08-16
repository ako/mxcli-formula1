# The frontend model

Run in order against `Formula1Frontend`:

```bash
cd Formula1Frontend
for f in ../model/frontend/0*.mdl; do ./mxcli exec "$f" -p Formula1Frontend.mpr; done
```

| Script | What it adds |
|---|---|
| `01-odata-clients.mdl` | Modules `F1Live` and `F1Cached`, their URL/credential constants, and one OData client each. |
| `02-external-entities.mdl` | 16 external entities generated from the cached contracts. |
| `03-smoke.mdl` | Retrieval microflows behind `tests/external-entities.test.mdl` and `tests/name-mapping.test.mdl`. |
| `04-pages.mdl` | The seven browsing pages. |
| `05-navigation-security.mdl` | Roles, entity/page access, the Responsive navigation profile. |
| `06-demo-user.mdl` | `fan`. Separate because 05 is not re-runnable. |
| `07-fan-pages.mdl` | Driver career, constructor and season summary, built to the design comp. |
| `08-race-weekend.mdl` | The weekend page: round nav, highlight cards, session tables. |
| `09-live-race.mdl` | Near-live timing from `F1Now`. |
| `10-vega-charts.mdl` | The data behind every chart — `Formula1Frontend.Chart` and ten `DSJ_` microflows emitting long-format JSON. The specs themselves live beside the widgets in 07 and 08. |

**Charts are Vega, not the Mendix chart widgets.** The widget comes from the
`mendix-vega-charts` skill pack, installed at namespace `f1` and built into
`Formula1Frontend/widgets/f1.widget.web.VegaChart.mpk` (committed — a gitignored
`widgets/` makes every other clone unbuildable). Rebuild it with:

```bash
cd .claude/skills/mendix-vega-charts/widget && npm install && npm run build
./Formula1Frontend/mxcli widget init -p Formula1Frontend/Formula1Frontend.mpr
```

Use `mxcli widget init`, **not** `mx update-widgets`: the latter rewrites the
project as MPR v1 and deletes `mprcontents/` (FINDINGS §56).

## Two modules, not one

Both backend services publish identically named resources (`Drivers`, `Races`,
…), so importing them into a single module would collide. `F1Live.Drivers` and
`F1Cached.Drivers` are the same 917 rows reached two different ways, and having
both in the domain model is what lets a page switch between them.

The contrast shows up in the model: `F1Cached` carries six navigation
associations (`season`, `circuit`, `driver`, `constructor`); `F1Live` has none,
because its rows are flat and DuckDB did the joins.

## The contracts are committed, on purpose

`MetadataUrl` points at `contracts/*.xml`, not at the service.

`CREATE ODATA CLIENT` fetches `$metadata` over plain HTTP with **no credentials**
even when the statement carries them, so against these services it gets 401,
warns, and creates a client with no entity types — the import that follows then
silently produces an empty module (FINDINGS §23).

Pointing at a file avoids that, and is better anyway: the frontend model rebuilds
with the backend down, and a change to the published surface arrives as a
reviewable diff rather than silently reshaping the generated entities.

Refresh them when the backend's published surface changes:

```bash
cd Formula1Frontend
for s in f1-live f1; do
  curl -u f1api:<pw> "http://backend.local:8080/odata/$s/\$metadata" \
    -o "contracts/${s}-metadata.xml"
done
./mxcli -p Formula1Frontend.mpr -c "drop module F1Live;"
./mxcli -p Formula1Frontend.mpr -c "drop module F1Cached;"
./mxcli exec ../model/frontend/01-odata-clients.mdl -p Formula1Frontend.mpr
./mxcli exec ../model/frontend/02-external-entities.mdl -p Formula1Frontend.mpr
```

## Regenerate, never patch

Generated external entities default every capability to `true` regardless of what
the contract says, so a service restricting `Countable` or `Filterable` yields a
project that will not build (FINDINGS §24).

The tempting fix — `create or modify external entity … (Countable: false)` —
**corrupted the entity**: it renamed an attribute (`name` became
`Stg_Circuitname`) and stripped every remote mapping (FINDINGS §25). `c76d4b7`
fixes the mapping read-back, but this project has not re-tested it: regenerating
from a corrected contract is the cheaper habit either way.

Fix the published contract instead and regenerate. That is why all eight live
resources are `Countable`: each read microflow takes a `System.ODataResponse` and
reports a count, so the generator's optimistic default happens to be correct.

## The fan pages

`07-fan-pages.mdl` adds three parameterised pages — a driver's career, a
season's summary, a constructor's reliability record — plus the microflows that
feed them. Three things about them are worth knowing before editing:

- **Every grid binds a microflow, not a database source.** The constraint has to
  reach the backend: a retrieve constrained on the page parameter becomes
  `$filter=driverId eq '...'` on the OData request, which the read microflow
  turns into SQL. An unconstrained retrieve would pull the whole resource.
- **A page with a parameter needs it in the URL** — `url: 'driver/{Driver}'`.
  Without the segment the build fails.
- **A live resource silently ignores the constraint you put on it.** This one
  shipped a wrong page: the season standings grids were bound to
  `F1Live.DriverStandings`, whose read microflow does not parse query options,
  so `$filter=year eq 1957` was dropped, all 1680 rows came back newest-first,
  and 1957 showed the 2026 grid. Nothing errored. Only `Drivers`,
  `RaceResults` and the five `F1Fan` resources parse `$filter`; everything else
  on the live service returns its whole list. Constrain against the **cached**
  service, or against a resource you know pushes down.
- **XPath wants lowercase `and`.** MDL passes the operator through verbatim, so
  `WHERE scope = 'driver' AND entityId = ...` compiles and then fails the build
  with CE0161.

The chart's five lines are bound to positions in the final standings, not to
named drivers: a series binds its Y attribute when the page is authored, and one
page serves all 77 seasons.

## Testing

`tests/external-entities.test.mdl` needs the **backend running** — it retrieves
through both clients for real.

```bash
cd Formula1Backend && ./mxcli run --local -p Formula1Backend.mpr    # terminal 1
cd Formula1Frontend && ./mxcli test tests/ -p Formula1Frontend.mpr --local
```


## The pages

Home, Seasons, Drivers ×2 (one per service), Constructors, Circuits, Race
results. Every grid is paged, sortable and text-filterable, so every interaction
is an OData request to the backend.

There is deliberately **no navigation snippet**. The `Responsive` profile already
renders a menu rail; an in-page menu was a second copy of it, taking 2/12 of the
width from the grid.

Two things to know before editing a grid column:

- **`name` is called `name` again.** The generator used to prefix it with the
  remote type, and differently per service — `Stg_Drivername` live, `Drivername`
  cached (FINDINGS §28). Fixed in mxcli `c76d4b7`; both modules were regenerated
  and the page bindings now read `name`. Anything still referring to the old
  spellings is stale.
- **Design properties that `mxcli check` accepts can still fail the build.** The
  lint rule knows the widget's catalogue, not which subset the `console` theme
  implements: `Row size` and `Hover style` pass `check` and are rejected by
  `mxbuild` (FINDINGS §29). None are used here.

## Seeing it work

```bash
cd Formula1Backend  && ./mxcli run --local -p Formula1Backend.mpr
cd Formula1Frontend && ./mxcli run --local -p Formula1Frontend.mpr \
    --app-port 8180 --admin-port 8190 --serve-port 6643
```

Then `http://frontend.local:8180/`, logging in as `fan` / `F1Enthusiast!2345`.

`--screenshot --screenshot-user fan --screenshot-password … --screenshot-url /p/drivers-live`
logs in and captures the page without a browser of your own.
