// Compile a Vega-Lite spec with sample rows, render it headless, and report what
// came out. No build, no browser, about a second per spec.
//
//   node check-spec.mjs ../specs/line-timeseries.json          # spec + its .data.json
//   node check-spec.mjs ../specs/*.json                        # all of them
//   node check-spec.mjs my-spec.json rows.json                 # explicit data file
//   node check-spec.mjs my-spec.json rows.json --rows          # dump the post-transform rows
//
// The point is not pass/fail. The scenegraph answers questions a screenshot cannot:
// how tall does this get with fifteen categories rather than thirteen, do these facet
// rows share a pitch, where did that band edge actually land.
import * as vl from "vega-lite";
import * as vega from "vega";
import fs from "fs";
import path from "path";

const argv = process.argv.slice(2);
const dumpRows = argv.includes("--rows");
const files = argv.filter(a => !a.startsWith("--"));

if (files.length === 0) {
    console.error("usage: node check-spec.mjs <spec.json> [data.json] [--rows]");
    process.exit(2);
}

// A spec is paired with <name>.data.json unless a second file is given. That convention
// is what lets a whole directory be checked in one command.
const pairs = [];
if (files.length === 2 && !files[1].endsWith(".data.json") && files[1].includes("data")) {
    pairs.push([files[0], files[1]]);
} else {
    for (const f of files.filter(f => !f.endsWith(".data.json"))) {
        pairs.push([f, f.replace(/\.json$/, ".data.json")]);
    }
}

let failed = 0;

for (const [specFile, dataFile] of pairs) {
    const name = path.basename(specFile);
    try {
        const spec = JSON.parse(fs.readFileSync(specFile, "utf8"));
        const rows = fs.existsSync(dataFile) ? JSON.parse(fs.readFileSync(dataFile, "utf8")) : null;

        // The widget injects data under `datasetName`; do the same so what is compiled
        // here is what the browser gets.
        const datasetName = Object.keys(spec.datasets ?? {})[0] ?? spec.data?.name ?? "table";
        if (rows) {
            spec.datasets = { ...(spec.datasets ?? {}), [datasetName]: rows };
        }

        // A spec written for a Mendix card usually sizes itself to its container, which
        // is zero wide here. Give it something to measure so the render is meaningful.
        if (spec.width === "container") spec.width = 700;
        if (spec.height === "container") spec.height = 300;

        // "Can not resolve event source: window" is what an interval selection says when
        // there is no DOM to bind to. It is a fact about running headless, not about the
        // spec, so it is not counted against it.
        const headlessNoise = /Can not resolve event source/;
        const warnings = [];
        const note = (level, args) => {
            const text = args.join(" ");
            if (!headlessNoise.test(text)) warnings.push(`${level} ${text}`);
        };
        const logger = {
            level: () => logger,
            error: (...a) => note("ERROR", a),
            warn: (...a) => note("warn", a),
            info: () => {},
            debug: () => {}
        };

        const compiled = vl.compile(spec, { logger });
        const view = new vega.View(vega.parse(compiled.spec), { renderer: "none", logger });
        await view.runAsync();
        const svg = await view.toSVG();

        const size = svg.match(/width="(\d+)" height="(\d+)"/);
        const marks = {};
        for (const m of svg.matchAll(/class="mark-(\w+)/g)) {
            marks[m[1]] = (marks[m[1]] ?? 0) + 1;
        }

        // Row counts per dataset say whether a transform dropped or fanned out data —
        // the usual cause of a chart that is subtly wrong rather than broken.
        const datasets = {};
        for (const d of compiled.spec.data ?? []) {
            try {
                const v = view.data(d.name);
                if (Array.isArray(v) && v.length) datasets[d.name] = v.length;
            } catch {
                /* not a materialised dataset */
            }
        }

        console.log(
            `${name.padEnd(30)} ${size ? `${size[1]}x${size[2]}`.padEnd(11) : "no size   "} ` +
                `marks ${Object.entries(marks).map(([k, v]) => `${k}:${v}`).join(" ") || "none"}`
        );
        console.log(
            `${"".padEnd(30)} rows in ${rows ? rows.length : 0}` +
                `  datasets ${Object.entries(datasets).map(([k, v]) => `${k}=${v}`).join(" ")}`
        );
        if (warnings.length) {
            failed++;
            for (const w of warnings) console.log(`${"".padEnd(30)} ${w}`);
        }
        if (dumpRows) {
            const last = Object.keys(datasets).pop();
            console.log(JSON.stringify(view.data(last).slice(0, 5), null, 1));
        }
    } catch (e) {
        failed++;
        console.log(`${name.padEnd(30)} FAILED  ${e.message.split("\n")[0]}`);
    }
}

process.exit(failed ? 1 : 0);
