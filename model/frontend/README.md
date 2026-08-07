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
| `03-smoke.mdl` | Retrieval microflows behind `tests/external-entities.test.mdl`. |

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
**corrupts the entity**: it renames an attribute (`name` became
`Stg_Circuitname`) and strips every remote mapping (FINDINGS §25). Do not do it.

Fix the published contract instead and regenerate. That is why all eight live
resources are `Countable`: each read microflow takes a `System.ODataResponse` and
reports a count, so the generator's optimistic default happens to be correct.

## Testing

`tests/external-entities.test.mdl` needs the **backend running** — it retrieves
through both clients for real.

```bash
cd Formula1Backend && ./mxcli run --local -p Formula1Backend.mpr    # terminal 1
cd Formula1Frontend && ./mxcli test tests/ -p Formula1Frontend.mpr --local
```
