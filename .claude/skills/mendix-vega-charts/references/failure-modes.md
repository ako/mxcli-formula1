# When the chart looks wrong

Each of these cost real time on a real project. Symptom first, because that is what you
have when you arrive.

---

## The chart is empty and nothing errored

**Cause A — the spec uses `"width": "container"` and the stylesheet is missing.** The
container measures zero, so the chart draws at zero. An empty chart is not an error.
Check that `VegaChart.tsx` still imports `./ui/VegaChart.css`.

**Cause B — `datasetName` does not match the spec.** The widget injects
`datasets: {<datasetName>: rows}`; the spec must say `{"data": {"name": "<same>"}}`.
A mismatch leaves the spec's own (absent) data in place. No error either.

**Cause C — the data attribute is empty.** Check the microflow actually wrote it; an
empty string parses as nothing and the widget renders an empty chart rather than an
error.

---

## Numbers in the chart are smaller than the numbers in the database

**A field named in a tooltip without an aggregate becomes part of the group-by.** This is
the nastiest one here, because the chart still looks plausible and the tooltip is
*consistent with what it drew*.

```json
{"field": "v", "title": "Amount", "format": ",.2f"}          // splits the chart
{"field": "v", "aggregate": "sum", "title": "Amount", ...}   // correct
```

A stacked area grouped by month and category was silently also grouped by account,
because the tooltip named the raw value. Bands had hairline gaps where the sub-rows did
not add up, and the tooltip reported one account's share of a month — the chart was
telling the truth about its own broken grouping.

**The rule: in a chart that aggregates, every field in every channel needs an aggregate —
including the ones that exist only to be read by a human.** The tell is a tooltip whose
number is smaller than the mark it is attached to.

---

## Rows in a faceted table drift out of alignment

Vega-Lite sizes a facet row to its **content bounds**, not to the declared height. A
panel whose marks overflow the declared 26px — an outlier dot straddling the top, a rule
drawn to the row edge — gets taller rows than a panel of plain text beside it. Four
panels, three different row pitches, and by the fourteenth row the labels sit a full row
below their numbers.

Fix: `"bounds": "flush"` on **every** panel, not just the offending one.

Then the second half of the same problem: flush layout does not measure the row header
either, so each header group comes to rest at its own text width — labels ragged across
sixty pixels while the DOM insists every one is `text-anchor="end"`. Fix: draw the labels
as a text mark in a panel of their own. They are a column of the table, not decoration.

---

## A row's sort silently differs between panels

An `aggregate` transform drops any field it is not told to keep. Aggregating away the
field a facet sorts on makes the row domain fall back to alphabetical — in *that panel
only*, so panels that shared a sort now name different rows in the same position.

Fix: keep the sort field alive in the transform's `groupby`, even when nothing in that
panel plots it.

---

## The chart overflows its card, or a gap appears under it

`chartHeight` is a fixed container height. A chart sized by its data outgrows it. Measured
on a five-panel faceted table: 14 rows = 592px inside a 620px container, 15 rows = 620px
exactly, 16 rows = 649px — 29px past it, absorbed by the card's padding until it is not.

Fix: `chartHeight: 0`, which lets the container take the rendered height. Use a fixed
height only when the spec itself declares one.

---

## A line dives to the floor at the end

The data emitted `0` for months that have not happened. Zero against a full budget reads
as maximally under budget — a lie the chart tells convincingly.

Fix: emit `null`, which breaks the line instead. And filter the layers that would still
close over it: an area with a null `y` still closes one step past the last point, which
draws a small block into the following month that looks like data. `{"filter":
"isValid(datum.a)"}` on that layer removes it.

---

## A "one-month" value looks like a ramp

A monthly quantity drawn with the default linear interpolation ramps up through the month
before and back down the month after. A budget, a plan, a target — anything that is a
level held for a period — needs `"interpolate": "step-after"`.

---

## Stacked bands show hairline gaps between them

`"interpolate": "monotone"` smooths each band independently, so the curve fitted to a
band's top and the curve fitted to the next band's bottom — the same numbers — come out
as two different curves between data points, and the background shows through.

Fix: `linear` on stacked areas. It is the only interpolation guaranteed to be identical
on both edges.

---

## The category tint says one thing and the marks say another

If a mark's colour or a dot's presence encodes "good/bad", compute the flag in the model,
not in the spec. `datum.actual > datum.budget` is wrong the moment a row is income, where
above budget is good news. Emitting a `u: 0|1` flag from the builder — using the same
rule the rest of the screen uses — makes the chart checkable against the table beside it,
row by row.

---

## `DESCRIBE PAGE` output will not re-parse

A page carrying a pluggable widget does not round-trip. Every string property comes back
unquoted (`spec: {"a": 1}`, `datasetName: table`) and boolean properties are omitted
entirely, so feeding a description back through the checker fails from the first widget
onward. The model is fine — the `.mxunit` contains the boolean — it is the output that is
lossy.

Consequence: the MDL source file is the source of truth for any page with a chart on it.
Never rebuild such a page from `DESCRIBE`.

---

## Playwright says the chart is the wrong size

`browser.newPage({viewportSize})` is silently ignored in some versions — the page renders
at the default 1280×720 and the "broken" layout is the harness's, not the app's. Use
`page.setViewportSize()` explicitly, and read the SVG's own `width`/`height` attributes
rather than trusting the screenshot.

---

## General

**Measure the scenegraph; do not reason about the spec.** `scripts/check-spec.mjs`
renders headless and gives you mark positions, band edges, row pitches and the rendered
size. On this project the first hypothesis was wrong more than once — a stream graph's
gaps were blamed on interpolation, and changing it fixed nothing; measuring the band
edges found the tooltip re-graining the chart in one command.
