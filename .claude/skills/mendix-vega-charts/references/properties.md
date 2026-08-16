# Widget properties, and how to write them from MDL

## The properties

| Key | Type | Required | What it does |
|---|---|---|---|
| `spec` | string, multiline | yes | Vega-Lite or Vega JSON. `vega-embed` chooses the language from the spec's `$schema`. |
| `chartData` | attribute (String) | no | A JSON array of row objects. |
| `datasetName` | string | no | The name the spec refers to the data by. Default `table`. Empty replaces the spec's top-level `data` instead. |
| `chartHeight` | integer | yes | Container height in px. **0 means take the height the chart renders at.** |
| `renderer` | enum `svg` / `canvas` | yes | SVG keeps marks in the DOM — selectable, styleable, and measurable by a test. Canvas is faster for very dense charts. |
| `showActions` | boolean | yes | Vega's own export/view-source menu. Off by default so the chart carries no chrome of its own. |
| `selection` | attribute (String) | no | Written with the clicked mark's datum as JSON. |
| `onClick` | action | no | Runs after `selection` is written. Leave empty and clicks are ignored entirely. |

With a `datasetName`, the data is injected as `datasets: {<name>: rows}` and the spec
refers to it as `{"data": {"name": "table"}}`. That is the form to use — it keeps the
spec readable and lets the same spec be compiled locally against a sample file.

## The MDL invocation

```
dataview dvChart (datasource: microflow MyModule.DS_ChartData) {
  pluggablewidget 'acme.widget.web.vegachart.VegaChart' chartSpend (
    chartData: ChartData,
    datasetName: 'table',
    chartHeight: 0,
    renderer: 'svg',
    showActions: false,
    spec: '{
  "$schema": "https://vega.github.io/schema/vega-lite/v6.json",
  "data": {"name": "table"},
  ...
}')
}
```

The widget needs an entity context (`needsEntityContext="true"`), so it must sit inside a
data view over the object holding the attribute.

## Writing JSON inside an MDL string

MDL strings are single-quoted, and the spec is one long string. Two consequences:

**Single quotes double.** A Vega expression that quotes a literal —
`[ 'Jan','Feb' ][datum.m - 1]` — is written in MDL as:

```
{"calculate": "[''Jan'',''Feb''][datum.m - 1]", "as": "mon"}
```

and is stored unescaped. Verified by reading the model back.

**Newlines are fine.** A multiline spec property parses and applies. But note that
`DESCRIBE PAGE` will not round-trip it (see `failure-modes.md`), so keep the MDL file the
source of truth and never rebuild a page from a description of it.

## Click-back

To let a click select something:

```
selection: SelectedPoint,
onClick: microflow MyModule.ACT_SelectPoint(Context: $currentObject)
```

`selection` receives the clicked datum as JSON, reduced to its own scalar fields — Vega's
internal bookkeeping (`_vgsid_`, and for aggregated marks the entire `_source_` array) is
stripped before it is written.

**The datum is not the row you sent.** For an aggregated mark it is the aggregate, so a
clicked bar carries `{"cat":"Groceries","sum_v":11783.2}` and no id. Design the payload
so the fields you need to act on survive aggregation — carry a key in the `groupby`, or
key the follow-up query on the category name you can see. A clicked mark on a raw
(unaggregated) layer does carry the row's own fields.

## The stylesheet

`src/ui/VegaChart.css` gives `.vega-chart` a `width: 100%`. Without it, a spec using
`"width": "container"` measures zero and draws nothing — silently, because an empty chart
is not an error. The stylesheet only reaches the bundle because `VegaChart.tsx` imports
it. Do not remove that import as "unused".
