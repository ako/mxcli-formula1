# Theme & Styling — SCSS Workflow and Caveats

## When to Use This Skill

Use this skill when working with:
- SCSS compilation, `custom-variables.scss`, or `themesource/` directories
- CSS hot-reload during Docker development
- Debugging styling crashes or design property issues

For **MDL styling commands** (`show design properties`, `describe styling`, `alter styling`, inline `designproperties:`, `update widgets`), see:
- Existing proposal: `docs/11-proposals/page-styling-support.md`
- Working examples: `mdl-examples/doctype-tests/12-styling-examples.mdl` (595 lines)
- Implementation: `mdl/executor/cmd_styling.go`, `mdl/executor/theme_reader.go`

## SCSS Compilation Chain

### Directory Structure

```
MyProject/
├── theme/                          # project-level overrides
│   └── web/
│       ├── main.scss               # SCSS entry point (import chain)
│       ├── custom-variables.scss   # project variable overrides
│       ├── exclusion-variables.scss # Exclude unwanted Atlas components
│       └── settings.json           # Theme settings
│
├── themesource/                    # module-level theme definitions
│   ├── atlas_core/                 # base framework (always present)
│   │   └── web/
│   │       ├── design-properties.json  # widget design properties
│   │       ├── variables.scss          # Color/spacing/font variables
│   │       └── ...                     # Component SCSS files
│   ├── datawidgets/                # DataGrid2, gallery, etc.
│   ├── atlas_web_content/          # Web content styles
│   └── <module_name>/              # Each module can contribute styles
│       └── web/design-properties.json
│
└── theme-cache/web/                # Compiled CSS output (build artifact)
```

### Compilation Order

`atlas_core/web/main.scss` imports in order:
1. Default variables (`atlas_core`)
2. Exclusion variables (disable Atlas components)
3. Project custom variables (`theme/web/custom-variables.scss`)
4. Bootstrap framework
5. MXUI components
6. Core styles (base, animations, spacing, flex)
7. Widget-specific styles

Then each **module's** `themesource/<module>/web/main.scss`, and **last of all**
`theme/web/main.scss`.

Variables declared earlier are overridden by later declarations (with `!default` flag). This means `custom-variables.scss` overrides `atlas_core/web/variables.scss` values.

### Where to put app-level styling — three rules that are not obvious

Verified against a real Mendix 11.13 project (probe rules compiled with
`mxbuild --target=deploy`, then grepped out of `theme-cache/web/theme.compiled.css`).

**1. `theme/web/main.scss` compiles LAST — it is the right home for app styling.**
After Atlas Core *and* after every module theme source, so a partial imported
here overrides any Atlas rule with **no `!important`**. It is a three-line file of
Mendix's own imports, not an Atlas-owned file; appending one `@import` is safe:

```scss
@import "custom-variables";
@import "theme-dark";
@import "theme-neutral";
@import "my-app";          // -> theme/web/_my-app.scss
```

**2. A `themesource/<name>/` folder is only compiled when `<name>` is a real module.**
mxbuild walks the model's modules and pulls each one's theme source; it never
globs the directory. An invented folder (`themesource/my_theme/`) is **silently
skipped** — build succeeds, rules simply absent. Use a module's theme source only
when the styling belongs to that module (it then exports with the `.mpk`).

> Debugging "my CSS doesn't apply": first prove the file is compiled *at all* —
> grep a unique probe selector in `theme-cache/web/theme.compiled.css`. Absent and
> overridden look identical in the browser, and only one of them is a
> specificity problem.

**3. `theme/web/custom-variables.scss` is imported once PER MODULE** (8× in a
blank app). It must hold **declarations only** — a CSS rule there is emitted once
per module. Tokens go here; rules go in the Layer-2 partial.

### Mendix 11: CSS custom properties, not SCSS variables

The stock `theme/web/custom-variables.scss` is a `:root { --brand-primary: … }`
block plus a few SCSS switches (`$font-family-import`, `$btn-bordered`,
`$use-css-variables`). Legacy Sass variables are still mapped
(`_css-variables-mappings.scss`), but the modern idiom is `:root` declarations.
The derived ramp (`--brand-primary-50…900`) is built with CSS `color-mix()`
against `var(--brand-primary)`, so retuning the primary re-derives the whole ramp
live — no SCSS recompilation of variants needed.

### Fonts: vendor them under `theme/web/`

`theme/web/<subdir>/` is copied to the deployment web root, and
`theme.compiled.css` is served from that root — so fonts at
`theme/web/fonts/x.woff2` are referenced as `url("./fonts/x.woff2")`. Prefer this
over `@import url('…fonts.googleapis…')`: no `@import`-ordering trap, no
third-party request per page load, and the app renders correctly air-gapped.

`mxcli theme apply` does exactly this — see `mxcli theme show signal`.

### Light/dark: Mendix ships the slot, not the switcher

`theme/web/_theme-dark.scss` and `_theme-neutral.scss` declare `:root.theme-dark`
and `:root.theme-neutral`. **Nothing in Atlas ever applies those classes** — grep
`themesource/` and you will find no reference. They are a slot for you to drive.

Three consequences worth knowing before building any light/dark support:

1. **A token flip really does repaint Atlas.** Adding `theme-dark` to `<html>` on
   a running Mendix 11 app turns the page ground, cards, form controls, sidebar,
   buttons and DataGrid2 dark, with no per-widget CSS. This is materially better
   than Atlas 3, where the same trick left widgets light. And because the class
   is on `<html>`, popups and modals rendered at `<body>` follow it too.
2. **Your dark block must come after Mendix's.** `_theme-dark.scss` hardcodes
   stock Mendix blue at `:root.theme-dark`. Declare the same selector from a file
   imported later in `theme/web/main.scss` — same specificity, later wins — or
   your brand vanishes the moment the class appears.
3. **Never pin an Atlas variable to a literal colour.** Map it to a token
   (`--bg-color: var(--my-ground)`) so a variant restates the tokens, not the
   wiring. A hardcoded `--font-color-default` is invisible on a dark ground.

The rail is the one place Atlas still assumes: several topbar widgets paint text
with `--color-base`, expecting white, because they expect a dark navigation rail.
Keep the rail dark in both variants, or force `color: inherit` on those widgets.

For a working implementation of all of the above, read the generated
`theme/web/_mxcli-atlas-map.scss` in any themed project.

## CSS Hot-Reload Workflow

For theme/styling changes during Docker development:

```bash
# 1. Compile SCSS into deployment package (~55s)
mxcli docker build -p app.mpr

# 2. Push compiled CSS to browsers (instant, no page reload)
mxcli docker reload -p app.mpr --css
```

The `--css` flag calls the M2EE `update_styling` action, which pushes CSS via WebSocket to all connected browsers. **It does NOT compile SCSS** — always run `docker build` first.

For non-CSS changes (Class, Style, DesignProperties on widgets), use normal reload:
```bash
mxcli docker reload -p app.mpr
```

## Caveats

### DYNAMICTEXT + Style Crash

**Never** apply `style` directly to a DYNAMICTEXT widget — it crashes MxBuild with a NullReferenceException. Wrap in a CONTAINER:

```sql
-- WRONG: crashes MxBuild
dynamictext txt (content: 'Hello', style: 'color: red;')

-- CORRECT: style the container
container ctn (style: 'color: red;') {
  dynamictext txt (content: 'Hello')
}
```

This also applies to `alter styling` and `alter page set style` — never target a DYNAMICTEXT widget with Style.

### Clipped navigation labels are the CLOSED sidebar, not the theme

A sidebar item reading `All task` instead of `All tasks` is Atlas's **closed**
sidebar, which is an icon rail: `--navsidebar-width-closed: 48px`, set in Atlas's
own `themesource/atlas_core/web/themes/_theme-default.scss`. Measured against a
real compiled theme in a browser, the `<a>` for "All tasks" is **57px wide inside
a 48px rail** — the same overflow reported from a live app (56 in 48).

No mxcli theme sets any navigation *width*; the themes map colours only. So this
reproduces identically under `signal`, `ledger` and `console`, in both variants —
a layout constant, not a palette.

The fix is in the app, not the theme:

- **Give each nav item an icon.** That is what the closed rail is for; the icon is
  what stays visible when the sidebar is closed.
- **Or keep the sidebar open**, where the label has room.
- Shorter labels help, but only until the next one is too long.

Do **not** reach for `text-overflow: ellipsis` on the nav item as a blanket fix.
Tried and rejected: where Atlas does not also set `white-space: nowrap`, the label
wraps to two lines and reads fine — and the ellipsis rule turns that readable
`All / tasks` into `All / t…`. It trades one truncation for a worse one.

### DataGrid2 Renders ARIA `<div>`s, Not a `<table>` — and `Size` Is a Flex Weight

Two surprises when styling a **DataGrid2** matrix/pivot (ledger finding #46):

1. **It is not a `<table>`.** DataGrid2 emits `role="grid"` / `role="row"` /
   `role="gridcell"` **`<div>`s**, so `th, td { … }` selectors match nothing. A
   `td { white-space: nowrap }` intended to keep `€ 5,200` on one line does not
   apply, and amounts wrap. Target the ARIA roles instead:

   ```scss
   .ledger-matrix [role='gridcell'] { white-space: nowrap; }
   ```

   Playwright/tests see the same DOM: assert on `[role="row"]`, not `tr`.

2. **`Size` is a flex weight, not pixels.** On a column, `ColumnWidth: manual,
   Size: 132` does **not** set a 132px width — it divides available width by the
   weights across all columns. To give a wide matrix room, set a min-width on the
   grid and let it scroll:

   ```scss
   .ledger-matrix [role='grid'] { min-width: 1320px; }
   .ledger-matrix { overflow-x: auto; }
   ```

### Design Property Keys Are Case-Sensitive

Keys must match the `name` field in `design-properties.json` exactly:
```sql
-- CORRECT
designproperties: ['Spacing top': 'Large']

-- WRONG (case mismatch — silently ignored)
designproperties: ['spacing top': 'Large']
```

### Compound (Nested) Design Properties

Besides **flat** properties (a key with a single value — an option/dropdown
string or a toggle), `designproperties:` also supports **compound** properties:
one whose value is itself a set of sub-properties (e.g. Atlas's `Spacing` →
`margin-top`, `margin-bottom`, …). A compound value is written as a nested list:

```sql
designproperties: [
  'Column gap': 'Medium',                                       -- flat option
  'Cards style': ON,                                            -- flat toggle
  'Spacing': ['margin-top': 'Large', 'margin-bottom': 'Medium'] -- compound
]
```

Supported on the **modelsdk** (`.mpr`) and **MCP** (live Studio Pro) backends.
Sub-property keys are case-sensitive, same as flat keys.

### ALTER STYLING Limitation with Builder-Created Pages

`alter styling` cannot find widgets in pages created by the MDL page builder because `walkPageWidgets` traverses `LayoutCall.Arguments` but the page parser doesn't fully reconstruct the widget tree when re-reading builder-created pages. These commands work on pages originally created in Studio Pro.

## Validation with `mxcli check -p`

When a project is supplied (`mxcli check page.mdl -p app.mpr`), design properties are
validated against the project's theme registry (`themesource/*/web/design-properties.json`):

- **MDL-WIDGET11** — a design-property key not defined for that widget type (with a
  case-sensitivity hint, or the list of valid keys).
- **MDL-WIDGET12** — an option value that isn't allowed; the message **lists the
  allowed values** (case-sensitive), which is the fastest way to fix a casing typo.

Both are warnings (a newer theme may add keys/values), so they inform without blocking.
`show design properties <widget>` lists the same allowed keys/values up front. On the
write side, the value's BSON type is taken from the registry (a `ColorPicker` /
`ToggleButtonGroup` property serializes as a custom value, not a plain option).

## Checklist

- [ ] Never apply `style` directly to DYNAMICTEXT — wrap in a CONTAINER
- [ ] Design property keys are case-sensitive — match `design-properties.json` exactly (`check -p` flags mismatches as MDL-WIDGET11/12)
- [ ] Compound/nested design properties (e.g. grouped Spacing) use a nested list: `'Spacing': ['margin-top': 'Large']`
- [ ] For CSS changes, run `docker build` then `docker reload --css`
- [ ] Use `describe styling` to verify changes after modification
- [ ] Check `docs/11-proposals/page-styling-support.md` for BSON format details
