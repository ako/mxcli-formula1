# Formula1Frontend

<!-- mxcli-brain -->

Decisions anchored to the Formula1Frontend module. Loaded when Formula1Frontend is in play,
not otherwise.

## A datasource microflow that takes no parameters never refreshes. Mendix ties a data widget's redraw to its datasource parameters, so one that fetches its state itself has nothing to invalidate it and serves the first answer it ever gave for as long as the page is open. The awkward signature -- passing the state object in -- is the working one.

Anchors: `@Formula1Frontend.DS_ReplayOrder` · id `63722b` · 2026-09-04

## The event column is a Vega chart rather than a list view because a list view's rows flow and cannot be pinned to a lap. All three panels are drawn on one lap axis at one height, which is the design's whole claim: a row means the same lap in each. It costs wrapped two-line event text, since a Vega text mark does not wrap.

Anchors: `@Formula1Frontend.DSJ_NarrativeEvents` · id `29eda2` · 2026-09-04
