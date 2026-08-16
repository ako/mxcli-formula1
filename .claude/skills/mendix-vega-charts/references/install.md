# Getting the widget into a Mendix project

## What you need

- Node 18+ and npm. The build uses `@mendix/pluggable-widgets-tools`.
- A Mendix project whose version matches the tools version. This widget is built with
  `@mendix/pluggable-widgets-tools` 11.12.1 against a Mendix 11.13.0 app. Match the
  major version to your project's.

## 1. Install the pack

```bash
mxcli skill add mendix-vega-charts -p MyApp.mpr
```

That writes the pack into `.claude/skills/mendix-vega-charts/`, widget source
included, **with the namespace already substituted for this project**. Steps 1
and 2 of the old manual procedure are what this replaces.

## 2. The namespace is chosen at install, not after

A widget id looks like `acme.widget.web.vegachart.VegaChart`, and the first
segment identifies whoever built it. `skill add` derives it from the project name
and prints what it chose; `--namespace acme` overrides:

```bash
mxcli skill add mendix-vega-charts -p MyApp.mpr --namespace acme
```

Three files carry it — `package.json` (`packagePath`), `src/package.xml` (the
file path) and `src/VegaChart.xml` (the id) — and they are substituted together
from one value, so they cannot drift apart. The source ships with placeholders
rather than a real namespace, so a substitution that did not happen is an error
rather than somebody else's namespace quietly shipping.

`mxcli skill upgrade` re-substitutes what the install recorded in
`pack.lock.yaml` rather than re-deriving, because a changed widget id is not a
build error — it is every page in the app pointing at a widget that no longer
exists under that name.

Getting it right **before** the build is the whole point. Renaming afterwards
means re-applying every page that carries the widget.

## 3. Build

```bash
cd .claude/skills/mendix-vega-charts/widget
npm ci
npm run build          # -> dist/1.0.0/<namespace>.VegaChart.mpk
```

The `.mpk` lands in the project's `widgets/` directly — `skill add` wrote the
build's `projectPath` relative to where the source went, so there is nothing to
copy. Verified end to end on a Mendix 11.12.1 app: every path inside the built
package is under the new namespace, and so is the id in `VegaChart.xml`.

## 3a. Let mxcli discover it

```bash
mxcli widget init -p MyApp.mpr
```

Without this, authoring a page against the widget fails with
`no definition for widget <ns>.widget.web.vegachart.VegaChart` — mxcli reads
widget definitions from `widgets/*.mpk` and has not seen the new one yet. This
is a step, not an error to debug.

The bundle carries Vega, Vega-Lite and vega-embed, so it is large (megabytes, not
kilobytes). That is the cost of the whole grammar being available client-side.

## 4. Commit the .mpk

**Commit `MyApp/widgets/*.mpk`.** A `widgets/` folder in `.gitignore` looks tidy and
makes every other clone of the repository unbuildable — the project references a widget
nobody else has, and the error names a missing widget rather than a missing file.

The widget definition cache (`MyApp/.mendix-cache/`, `deployment/`) is a different
matter and should stay ignored.

## 5. After changing the widget's XML

Changing a property definition invalidates every placed instance:

```
[error] [CE0463] "The definition of this widget has changed. Update this widget by
right-clicking it and selecting 'Update widget'..." at Vega Chart 'chartSpark'
```

In Studio Pro that is "Update all widgets". From MDL, re-apply the page files that carry
the widget — recreating the page writes the instance against the new definition. Pages
recreated after the rebuild are already correct; only ones written before it are flagged.

## 6. Check it landed

```bash
mx check MyApp.mpr          # 0 errors
```

A widget that is present but not registered fails at build, not at run. Get the project
to 0 errors before writing any spec — otherwise a spec problem and a packaging problem
look identical from the browser.
