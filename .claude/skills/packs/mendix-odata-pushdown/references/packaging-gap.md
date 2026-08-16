# Why this pack does not install yet

This pack is the third one `docs/11-proposals/PROPOSAL_skill_packs.md` asks for:

> A third is wanted (`mendix-odata-pushdown`, Java actions that push `$filter` /
> `$orderby` / `$top` / `$skip` into database-connector SQL) and there will be
> more.

It is also the one that needs a target the mechanism does not have.

## The shape of the problem

The four Java actions are declared in `mdl/module.mdl` with inline bodies, which
mxcli writes out as `.java` files itself. But every body is a two-line
delegation:

```
AS $$
return {{MODULE_PATH}}.QueryObject.parse(getContext(), Uri, Columns, Dialect,
        MaxTop, DefaultTop, DefaultOrderBy, KeyField, RejectUnsupported);
$$;
```

The work is in three helper classes that MDL cannot author at all:

| File | Lines | What it is |
|---|---|---|
| `java/ODataQueryParser.java` | 633 | the parser — strings in, strings out, no Mendix types |
| `java/RoutineCall.java` | 185 | stored-routine invocation, per engine |
| `java/QueryObject.java` | 64 | the binding — `Core.instantiate` and `setValue` |

882 lines that have to land in `javasource/{{MODULE_PATH}}/`. Three independent
mechanisms say a pack cannot put them there:

1. **`Installs` has two fields.** `cmd/mxcli/skillpack/skillpack.go`:
   `Widgets []string` and `MDL []string`. There is no third.
2. **Pack files land inside the skills directory.** `Install` writes to
   `destDir/<pack-name>/`. Installing `mendix-bulk-oql-dml` puts all five of its
   files under `.claude/skills/mendix-bulk-oql-dml/` and nothing outside it.
3. **MDL has no standalone-class form.** `createJavaActionStatement` in
   `mdl/grammar/domains/MDLMicroflow.g4` accepts `AS DOLLAR_STRING` and nothing
   else — a method body, no class declaration, no imports clause.

So a pack today ships the prose and the MDL, and the reader still copies a
directory by hand. **That is exactly the manual step the pack existed to
remove**, which is why this is worth fixing rather than working around.

## The proposed target

```yaml
installs:
  java:
    - java          # -> javasource/{{MODULE_PATH}}/, preserving actions/
```

The interesting part is that it needs the *same* discipline the widget path
already has, for the same reason. A widget id is its identity; a Java `package`
declaration is the exact analogue. Two projects whose classes share a package
are two projects claiming the same class, and the symptom is a compile error in
somebody else's module.

The three properties the proposal already argues for transfer unchanged:

- **Placeholders, not a real namespace.** These files ship as `{{MODULE_PATH}}`,
  not `odatapushdown`. Leaving the harvested project's name in place means a bug
  ships *their* namespace silently; an unsubstituted `{{MODULE_PATH}}` fails to
  compile, loudly.
- **A whitelist, not a scan.** All eight files are named in `rewrite.files`.
- **Drift in either direction is an error** — a declared file with no token, or
  a declared file the pack does not ship, refuses the install.

One implementation question worth deciding rather than defaulting: `java/actions/`
is shipped here for review, but on `--apply` mxcli generates those four classes
from the MDL itself. Writing both means the pack's copy is overwritten
immediately. Skipping `actions/` when MDL is applied, and writing it when it is
not, is probably right — but it is a real branch, not an obvious one.

## Rejected alternatives

**Inline the helpers into the action bodies.** Java local classes cannot be
shared between methods, so 882 lines would be duplicated four times. The
one-fat-action-plus-microflow-wrappers variant avoids the duplication by
distorting the public API to fit the packaging, which is the wrong way round.

**Ship the `.java` as inert assets plus a copy step in `SKILL.md`.** Works
today, and is what this pack does in the meantime. It gets none of the three
things that make a pack better than a tarball: no pruning when a file is
dropped in v2, no digest fence refusing a locally-edited file, no namespace
rewrite.

## Applying it by hand, until then

```bash
mxcli skill add mendix-odata-pushdown -p App.mpr        # copies, does not apply

# substitute the destination module's names yourself
cd .claude/skills/mendix-odata-pushdown
sed -i 's/{{MODULE}}/ODataPushdown/g; s/{{MODULE_PATH}}/odatapushdown/g' \
  mdl/module.mdl java/*.java java/actions/*.java

mkdir -p <app>/javasource/odatapushdown
cp java/*.java <app>/javasource/odatapushdown/
mxcli exec mdl/module.mdl -p <app>/App.mpr
```

`java/actions/` can be skipped — `mxcli exec` generates those four classes from
the MDL. Then add `ODataPushdown.User` to whichever user roles run your read
microflows.

## One more thing the proposal already flags

> **Verifying a pack in CI.** [...] A pack whose own verifier is not run in CI
> is a pack that rots.

This pack wants that more than the other two. It is 882 lines of parser across
five dialects, and it has a real test surface: `ODataQueryParser` takes no
Mendix types, so it runs under `jshell` or JUnit with no runtime. A
`verify:` script that exercises the grammar term by term would be cheap and
would catch a dialect regression that no `mx check` can see.
