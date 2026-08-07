# Spike: reading the F1 CSVs through DuckDB, from inside the Mendix runtime

**This is not part of the model.** It is a throwaway probe that proves the backend
architecture works before any of it is committed to `Formula1Backend`. The probe
module was dropped and the `.mpr` restored after it passed; these files are kept so
the result can be reproduced rather than taken on trust.

It closes the item `FINDINGS.md` used to list as unproven: §7 verified DuckDB JDBC
standalone, §10 verified OData publishing with a stub microflow, and nothing had yet
carried an actual CSV row through the Mendix runtime.

## What it proves

A Mendix microflow, using the **External Database Connector** with
`type 'BYOD'` and connection string `jdbc:duckdb:`, calling `read_csv()` on the
files in `data/f1db/`, returns real rows:

| Test | Expectation | Source |
|---|---|---|
| Ayrton Senna race wins | 41 | `f1db-drivers.csv` |
| Lewis Hamilton race wins | 106 | `f1db-drivers.csv` |
| Unknown driver id | `-1` sentinel | (the microflow's empty branch) |
| Driver row count | 917 | `f1db-drivers.csv` |

No data is copied into Postgres. The CSVs are read in place, per query.

## Reproducing it

Needs the DuckDB JDBC driver in `Formula1Backend/userlib/` — it is git-ignored
(82 MB) and fetched by `scripts/fetch-duckdb-driver.sh`, which the SessionStart
hook runs.

```bash
cd Formula1Backend
../scripts/fetch-duckdb-driver.sh

./mxcli exec ../spikes/duckdb-readpath/01-connection.mdl -p Formula1Backend.mpr
./mxcli exec ../spikes/duckdb-readpath/02-microflows.mdl -p Formula1Backend.mpr

mkdir -p tests && cp ../spikes/duckdb-readpath/duckdb.test.mdl tests/
./mxcli test tests/ -p Formula1Backend.mpr --local
```

Then put the project back:

```bash
./mxcli -p Formula1Backend.mpr -c "drop module DuckProbe;"
rm -rf tests
```

`01-connection.mdl` hardcodes an absolute `DataDir` default
(`/home/user/mxcli-formula1/data/f1db`). Change it if the repo lives elsewhere —
the real model will make this a per-environment constant.

## The fast loop

The point of keeping this is the inner loop, not the one-off result. Measured on
this container, Mendix 11.13.0, mxcli `1bdd46a`:

| | Wall clock |
|---|---|
| `mxcli test --local` (cold boot each run) | **33.7 s** |
| `mxcli test --attach` against a warm `run --local --test-endpoint` | **2.2 s** |
| edit the microflow under test → verdict on screen, via `--attach` | **2.0 s** |

So:

```bash
# terminal 1 — leave it up
./mxcli run --local -p Formula1Backend.mpr --test-endpoint

# terminal 2 — 2 seconds per iteration
./mxcli test tests/ -p Formula1Backend.mpr --attach
```

`--attach` runs against the host app's own database rather than a scratch one, so a
test that writes leaves data behind. These tests are all reads, so it does not
matter here.
