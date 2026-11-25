# Datalake equivalence harness

Proves that `F1Warehouse`'s queries return the same rows when they read from
DuckGraphLake views instead of re-parsing CSVs with `read_csv`. Nothing here
modifies the Mendix model: both variants are plain SQL over the same server.

Result as of FINDINGS §99: 19 identical (rows and order), 1 non-deterministic in
both variants, 2 reading CSVs absent from the repository.

## Running it

    # 0. nothing needed -- step 2 passes --kafka-port 0, which avoids the
    #    startup failure in ako/DuckGraphLake#27 (see FINDINGS §99). If you
    #    do want the Kafka endpoint, a source build needs avro installed first:
    #      curl -sSL -o /tmp/avro.gz \
    #        http://extensions.duckdb.org/v2.0.0/linux_amd64/avro.duckdb_extension.gz
    #      gunzip -c /tmp/avro.gz > ~/.duckdb/extensions/v2.0.0/linux_amd64/avro.duckdb_extension

    # 1. the view definitions: one per file, then the declared specs on top
    # the connection name must be qualified, and the line limit lifted or the
    # dump is truncated to 10,000 lines and the comparison silently shrinks
    cd Formula1Backend && MXCLI_OUTPUT_LINE_LIMIT=0 ../mxcli -p Formula1Backend.mpr \
      -c "describe database connection Formula1Backend.F1Warehouse" > /tmp/dbc.txt
    cd ..
    scripts/datalake/gen-file-views.sh            >  /tmp/init.sql
    scripts/datalake/gen-typed-views.py /tmp/dbc.txt >> /tmp/init.sql
    # 62 statements: 55 per-file, 7 carrying declared specs; 2 skipped as absent

    # 2. serve the folder
    duckgraphlake ./data --kafka-port 0 --init /tmp/init.sql

    # 3. compare
    scripts/datalake/compare-queries.py /tmp/dbc.txt

## Why the typed views are separate

Eight queries read with an explicit `columns = {...}` spec. DuckDB's own
inference does not reproduce it — `live-order.csv` declares `sessionKey` as
VARCHAR, inference yields BIGINT — and all five live queries fail outright on
inferred views. `gen-typed-views.py` re-emits those views from the model's
declared specs, which is what makes them agree.

## A caution about the control

`GetDriverSeasons` ends `ORDER BY rr.year DESC LIMIT 1` over a 25-way tie, so it
returns an arbitrary row. Repeating a variant *within one warm process* cannot
detect this: the scan order is stable there, and a csv-vs-csv control comes back
clean while the defect is real. Establish the noise floor across process
restarts. §99 records how this nearly became a false bug report.
