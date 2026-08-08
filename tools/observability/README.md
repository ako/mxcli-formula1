# Tracing a page turn end to end

`mxcli run --trace` uses a console exporter that **drops start/end timestamps and
parent span ids**, so it gives span names but no durations and no call tree.
`--trace-otlp` fixes that but needs a collector. These three scripts are that
collector plus the driver and the analysis.

```bash
# 1. collector on :4318, one JSON object per span
python3 tools/observability/otlpcollector.py /tmp/spans.jsonl 4318 &

# 2. both apps, traced, with distinct service names so the two sides separate
cd Formula1Backend && ./mxcli run --local -p Formula1Backend.mpr \
  --metrics --trace-otlp http://127.0.0.1:4318 --trace-service Formula1Backend &
cd Formula1Frontend && ./mxcli run --local -p Formula1Frontend.mpr \
  --app-port 8180 --admin-port 8190 --serve-port 6643 \
  --metrics --trace-otlp http://127.0.0.1:4318 --trace-service Formula1Frontend &

# 3. log in and click the pager (needs `pip install playwright`; the container
#    already ships Chromium under /opt/pw-browsers)
python3 tools/observability/page_grid.py /tmp/marks.json 4

# 4. reconstruct the call tree
python3 tools/observability/analyse.py "F1Live.Drivers" 1
```

Trace context propagates across the app boundary on its own, so one trace covers
browser → frontend → OData → backend → DuckDB. Findings §31 has the numbers.

Two things that will bite:

- **Log out at the end.** An unlicensed runtime caps concurrent sessions, and an
  abandoned Playwright login holds one until the runtime restarts —
  `Maximum number of sessions exceeded! (You are currently using a trial license)`
  arrives as a bare "Sign in failed." in the browser.
- **`networkidle` fires before Mendix has booted its client.** Wait for
  `#usernameInput`, and after login wait for it to disappear, not for a URL.
