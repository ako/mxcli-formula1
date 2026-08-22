# The frontend model

Run in order against `Formula1Frontend`:

```bash
cd Formula1Frontend
for f in ../model/frontend/[0-9]*.mdl; do ./mxcli exec "$f" -p Formula1Frontend.mpr; done
```

| Script | What it adds |
|---|---|
| `01-odata-clients.mdl` | Modules `F1Live`, `F1Cached`, `F1Fan` and `F1Now`, their URL/credential constants, and one OData client each. |
| `02-external-entities.mdl` | The external entities, generated from the cached contracts. |
| `03-smoke.mdl` | Retrieval microflows behind `tests/external-entities.test.mdl` and `tests/name-mapping.test.mdl`. |
| `04-datasources.mdl` | Every `DS_` and `ACT_` microflow, and the three view-model entities. Shared by all five screens, so it belongs to none of them. |
| `05-chart-data.mdl` | `Formula1Frontend.Chart` and the `DSJ_` microflows that emit long-format JSON. Ahead of the pages, because every chart binds to one. |
| `06-narrate.mdl` | Screen 1 — the race as it stands, from the OpenF1 snapshot. |
| `07-season.mdl` | Screen 2 — a championship, from the title fight down to the calendar. |
| `08-weekend.mdl` | Screen 3 — one Grand Prix, every session. |
| `09-constructor.mdl` | Screen 4 — a team's season, mostly as comparisons between its two drivers. |
| `10-driver.mdl` | Screen 5 — one driver, a season strip and a career. |
| `11-navigation-security.mdl` | Roles, entity/page access, the four default-entry microflows, and the five-item rail. |
| `12-demo-user.mdl` | `fan`. Separate because 11 is not re-runnable. |

## Five screens and no overviews

The app is the five screens of the v2 design comp — Narrate, Season, Weekend,
Constructor, Driver — and nothing else. The twelve pages that came before it,
including Home and the five overview lists, are gone.

That is a navigation decision, not a tidying one. Every screen is an overview of
the next: a season's standings row opens the driver, its constructor row opens
the constructor, its calendar card opens the weekend; a weekend's classification
row opens the driver; a driver's career row opens the season. Chip rows along
the top of three screens move sideways between siblings. An overview page is
what you need when screens are dead ends, and none of these are.

Four of the five take a parameter, and a Mendix menu item cannot supply one, so
the rail's four lower items are microflows — `NAV_Season`, `NAV_Weekend`,
`NAV_Constructor`, `NAV_Driver` — each picking the most recent thing of its kind
and opening the page with it. Narrate needs no parameter and is the home page.

### What the comp asks for and this does not have

Two panels of the Narrate screen are deliberately absent rather than pending,
and `06-narrate.mdl` says so in its header:

* **the track map**, which wants an (x, y) per car against a drawn circuit
  outline. The snapshot carries positions in the running order, not positions in
  space, and the outline is a hand-drawn path per venue;
* **the story panel**, which wants precedents and streaks read out of
  seventy-five years of results by an agent pass. There is no such resource, and
  writing the sentences into the page is the exact failure its own comp warns
  about.

One panel is drawn differently. The comp puts a position sparkline in every row
of the classification; a Mendix data grid column holds an attribute and not a
widget, so the same information is drawn once for everybody as the position-by-lap
chart underneath.

## Two modules, not one

Both backend services publish identically named resources (`Drivers`, `Races`,
…), so importing them into a single module would collide. `F1Live.Drivers` and
`F1Cached.Drivers` are the same 917 rows reached two different ways.

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

## Refreshing a contract

`create or modify odata client` does **not** re-read `$metadata` — the modify
path updates the URL and leaves the cached contract alone, so a backend that
gained a resource is invisible to the frontend. Until that is fixed upstream,
drop the client and let the script recreate it:

```bash
./mxcli -c "CONNECT LOCAL 'Formula1Frontend.mpr'; DROP ODATA CLIENT F1Now.NowApi;"
./mxcli exec ../model/frontend/01-odata-clients.mdl -p Formula1Frontend.mpr
./mxcli -c "CONNECT LOCAL 'Formula1Frontend.mpr'; create or modify external entities from F1Now.NowApi into F1Now;"
```

Fetch the contract itself from a running backend first:

```bash
curl -s -H 'X-Api-Key: f1-ops-key-2f8a1c' \
  'http://localhost:8080/odata/f1-now/$metadata' -o Formula1Frontend/contracts/f1-now-metadata.xml
```

## Check both checkers

`mxcli check` resolves references and types expressions, but it does not
validate an attribute named in a `SORT BY`. `mx check` does. Run both:

```bash
./mxcli check ../model/frontend/07-season.mdl -p Formula1Frontend.mpr
~/.mxcli/mxbuild/*/modeler/mx check Formula1Frontend.mpr
```

`mxcli lint` catches a third class again — an empty container passes both
checkers and crashes at render (MPR006).
