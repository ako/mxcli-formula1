import { useEffect, useMemo, useRef, useState, ReactElement } from "react";
import embed, { Result as EmbedResult, VisualizationSpec } from "vega-embed";

import { VegaChartContainerProps } from "../typings/VegaChartProps";

// Not decoration: a spec using `"width": "container"` measures this element, and
// without the width rule below it measures zero and the chart draws nothing —
// silently, since an empty chart is not an error. The stylesheet only reaches
// the bundle if it is imported here.
import "./ui/VegaChart.css";

/**
 * Parse a JSON string, returning the message rather than throwing.
 *
 * Both the spec and the data arrive as text — the spec authored by hand, the
 * data built by a microflow — so a syntax error in either is a normal thing to
 * hit while authoring, not an exceptional one. Showing where it broke beats a
 * blank chart and a console trace.
 */
function parseJson<T>(raw: string, label: string): { value?: T; error?: string } {
    try {
        return { value: JSON.parse(raw) as T };
    } catch (e) {
        return { error: `${label} is not valid JSON: ${(e as Error).message}` };
    }
}

/**
 * A clicked mark's datum, reduced to what the model would recognise.
 *
 * Vega hangs its own bookkeeping on every datum — a numeric `_vgsid_`, and for
 * aggregated marks the whole source array under `_source_`. Passing that back
 * would be noise at best and, in the aggregate case, the entire dataset in a
 * string attribute. Only own scalar fields survive.
 */
function cleanDatum(datum: Record<string, unknown>): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(datum)) {
        if (key.startsWith("_")) {
            continue;
        }
        const value = datum[key];
        const type = typeof value;
        if (value === null || type === "string" || type === "number" || type === "boolean") {
            out[key] = value;
        } else if (value instanceof Date) {
            out[key] = value.toISOString().slice(0, 10);
        }
    }
    return out;
}

export function VegaChart(props: VegaChartContainerProps): ReactElement {
    const { spec, chartData, datasetName, chartHeight, renderer, showActions, selection, onClick } = props;
    const hostRef = useRef<HTMLDivElement>(null);
    const viewRef = useRef<EmbedResult | null>(null);
    const [error, setError] = useState<string>();

    // The click handler is attached once per embed but reads the current props,
    // so it is held in a ref rather than captured — re-embedding on every render
    // just to refresh a callback would rebuild the whole scenegraph.
    const clickRef = useRef({ selection, onClick });
    clickRef.current = { selection, onClick };

    const dataValue = chartData?.status === "available" ? chartData.value : undefined;

    // The spec is static and the data is not, so they are parsed apart. Only the
    // data changes between renders, and re-parsing a spec on every model update
    // would be wasted work.
    const parsedSpec = useMemo(() => parseJson<VisualizationSpec>(spec, "Specification"), [spec]);
    const parsedData = useMemo(
        () => (dataValue ? parseJson<unknown[]>(dataValue, "Data") : { value: undefined }),
        [dataValue]
    );

    // Fold the data into the spec. A named dataset goes into `datasets`, which is
    // how Vega-Lite expects a spec to reference data it does not carry itself;
    // without a name the top-level `data` is replaced instead.
    const resolvedSpec = useMemo(() => {
        if (!parsedSpec.value) {
            return undefined;
        }
        if (!parsedData.value) {
            return parsedSpec.value;
        }
        const next = { ...(parsedSpec.value as Record<string, unknown>) };
        if (datasetName) {
            next.datasets = { ...((next.datasets as object) ?? {}), [datasetName]: parsedData.value };
        } else {
            next.data = { values: parsedData.value };
        }
        return next as VisualizationSpec;
    }, [parsedSpec.value, parsedData.value, datasetName]);

    useEffect(() => {
        const message = parsedSpec.error ?? parsedData.error;
        if (message) {
            setError(message);
            return;
        }
        if (!hostRef.current || !resolvedSpec) {
            return;
        }

        let disposed = false;
        // vega-embed decides between Vega and Vega-Lite from the spec's own
        // $schema, so one widget serves both languages with no switch here.
        embed(hostRef.current, resolvedSpec, {
            actions: showActions,
            renderer,
            // The app supplies its own type scale and palette; letting Vega apply
            // a theme on top would fight it.
            config: { background: "transparent" }
        })
            .then(result => {
                if (disposed) {
                    result.finalize();
                    return;
                }
                viewRef.current?.finalize();
                viewRef.current = result;
                setError(undefined);

                // Clicks on the chart background arrive with no item, and clicks
                // on axes and legends arrive with an item that has no datum;
                // neither is a selection. A chart with no onClick configured
                // ignores clicks entirely rather than writing a value nothing
                // reads.
                result.view.addEventListener("click", (_event, item) => {
                    const { selection: sel, onClick: act } = clickRef.current;
                    if (!act?.canExecute || !item?.datum) {
                        return;
                    }
                    sel?.setValue(JSON.stringify(cleanDatum(item.datum as Record<string, unknown>)));
                    act.execute();
                });
            })
            .catch((e: Error) => !disposed && setError(e.message));

        return () => {
            disposed = true;
        };
    }, [resolvedSpec, renderer, showActions, parsedSpec.error, parsedData.error]);

    // Finalize on unmount only. Vega registers listeners and, with the canvas
    // renderer, holds a backing surface; dropping the node without finalizing
    // leaks both.
    useEffect(() => () => viewRef.current?.finalize(), []);

    if (error) {
        return (
            <div className="vega-chart vega-chart-error" role="alert">
                {error}
            </div>
        );
    }

    // Zero means "as tall as it comes out". A chart whose height is decided by
    // its data — a facet row per category, a legend entry per series — has no
    // number the page can be told in advance, and a fixed container silently
    // stops matching the moment the data grows.
    return <div className="vega-chart" ref={hostRef} style={{ height: chartHeight > 0 ? chartHeight : undefined }} />;
}
