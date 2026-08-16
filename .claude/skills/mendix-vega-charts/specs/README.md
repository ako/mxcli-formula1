# Spec templates

Each `<name>.json` is a working Vega-Lite specification and `<name>.data.json` is a
sample of the rows it expects. Every one of them compiles and renders:

```bash
cd ../scripts && npm install && node check-spec.mjs ../specs/*.json
```

Start from the closest shape and change **fields**, not structure. The structure in each
is there because a simpler version of it was wrong — the comments in the `description`
fields say how.

| Spec | Shape | Rows it expects |
|---|---|---|
| `bar-ranked.json` | Horizontal bars, sorted by value, one row per category | `{cat, v}` — repeats per category are summed |
| `line-timeseries.json` | One line over time with the last point marked | `{t, v}` — `t` is an ISO date string |
| `sparkline-cell.json` | 126×26 sparkline for a data grid cell: value, stepped reference, shaded gap, flagged periods | `{m, a, b, u, t}` — `a` null where there is no value, `u` is a 0/1 flag from the model |
| `stacked-area-by-group.json` | Stream/stacked area, banded per category, coloured per group | `{t, grp, cat, v}` |
| `scatter-brushed.json` | Every event over time, drag to select a window | `{t, v, cat, grp, merchant}` |
| `calendar-heatmap.json` | Day-of-week by week-of-year grid | `{d, v}` — `d` is an ISO date string |
| `small-multiples-table.json` | A table of aligned faceted panels: labels, sparkline per row, a numeric column | `{k, cat, ord, t, v}` for `k:"m"`, `{k, cat, ord, current}` for `k:"s"` |

## The parts that are load-bearing

**`{"data": {"name": "table"}}`** must match the widget's `datasetName`.

**`"width": "container"`** needs the widget's stylesheet to be present, or it measures
zero and draws nothing. The checker substitutes 700px so a headless render is meaningful.

**Aggregates.** Where a spec sums, every field in every channel carries an aggregate —
including tooltips. A tooltip field without one silently joins the group-by and
re-grains the chart.

**`small-multiples-table.json`** is the fussiest and the most useful. Three things hold
it together: `"bounds": "flush"` on every panel so rows keep one pitch, the row labels
drawn as a text mark rather than as facet headers, and the sort field kept alive in the
aggregate's `groupby` so all three panels name the same row in the same position. Take
out any one and the columns drift apart while every panel insists it is correct.

## Emitting the rows

One JSON array of flat objects, built by a microflow over an OQL view entity. Numbers via
`formatDecimal(x, '0.00')`; `null` — never `0` — for "no value"; a discriminator column
(`k` above) when one payload feeds several panels.
