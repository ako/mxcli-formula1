# Mendix MDL Skills

Skills for writing Mendix Definition Language (MDL) code correctly.

Each skill is a directory holding a `SKILL.md` with `name` and `description`
frontmatter, following the [Agent Skills](https://agentskills.io) standard — so
an assistant that reads skills finds the whole set on its own. **This index is a
convenience for humans, not the discovery mechanism**, and it does not list every
skill; the directory does.

## Quick Reference (Cheat Sheets)

Start here for quick syntax lookups:

| Skill | Purpose | Use When |
|-------|---------|----------|
| [cheatsheet-variables](cheatsheet-variables/SKILL.md) | Variable declaration syntax | Declaring variables, fixing declaration errors |
| [cheatsheet-errors](cheatsheet-errors/SKILL.md) | Common errors and fixes | Debugging MDL syntax errors |

## Syntax Reference (By Document Type)

Detailed syntax for each MDL document type:

| Skill | Purpose | Use When |
|-------|---------|----------|
| [mdl-entities](mdl-entities/SKILL.md) | Entity, attribute, association syntax | Creating domain models |
| [write-microflows](write-microflows/SKILL.md) | Microflow syntax reference | Writing microflow logic |
| [write-nanoflows](write-nanoflows/SKILL.md) | Nanoflow syntax reference | Writing client-side nanoflow logic |
| [write-rules](write-rules/SKILL.md) | Rule syntax reference | Writing reusable decision logic a decision calls |
| [write-oql-queries](write-oql-queries/SKILL.md) | OQL query syntax | Creating VIEW entities |
| [translations](translations/SKILL.md) | Bulk translation, one file per language | Localising an app, or working out why a translation never appears |
| [create-page](create-page/SKILL.md) | Page and widget syntax | Creating pages |
| [fragments](fragments/SKILL.md) | Fragment (reusable widget group) syntax | Reusing widget patterns across pages |
| [scheduled-events-and-queues](scheduled-events-and-queues/SKILL.md) | Scheduled event (cron) and task queue syntax | Running a microflow on a schedule; bounding background concurrency |
| [regular-expressions](regular-expressions/SKILL.md) | Named validation patterns | Adding an email/phone/identifier regex; changing a shared pattern |

## Patterns (By Use Case)

Common implementation patterns:

| Skill | Purpose | Use When |
|-------|---------|----------|
| [patterns-crud](patterns-crud/SKILL.md) | Create/Read/Update/Delete patterns | Building CRUD functionality |
| [patterns-data-processing](patterns-data-processing/SKILL.md) | Loops, aggregates, batch processing | Processing lists of data |
| [validation-microflows](validation-microflows/SKILL.md) | Validation feedback patterns | Building form validation |

## Integration Skills

External system integration:

| Skill | Purpose | Use When |
|-------|---------|----------|
| [database-connections](database-connections/SKILL.md) | Mendix Database Connector | Connecting to Oracle, PostgreSQL, etc. via JDBC |
| [demo-data](demo-data/SKILL.md) | Demo data & IMPORT | Seeding data, `import from` bulk import from external DB |
| [rest-client](rest-client/SKILL.md) | REST API consumption | Calling external REST APIs via consumed REST client documents |
| [rest-call-from-json](rest-call-from-json/SKILL.md) | REST CALL end-to-end | JSON Structure → Entities → Import Mapping → REST CALL microflow |
| [mock-rest-apis](mock-rest-apis/SKILL.md) | Mock a REST dependency | Building or debugging a REST integration without the live API; forcing 404/500; running offline or in CI |
| [json-structures-and-mappings](json-structures-and-mappings/SKILL.md) | JSON structures & mappings | CREATE/DESCRIBE JSON structures, import/export mappings, domain model patterns |
| [java-actions](java-actions/SKILL.md) | Custom Java actions | Extending with Java code |
| [download-marketplace-content](download-marketplace-content/SKILL.md) | Marketplace download & install | Adding a marketplace module/widget; downloading a `.mpk`; module-update caveat |

## Page Patterns

Page-specific patterns:

| Skill | Purpose | Use When |
|-------|---------|----------|
| [overview-pages](overview-pages/SKILL.md) | List/grid pages | Building overview screens |
| [master-detail-pages](master-detail-pages/SKILL.md) | Master-detail layouts | Building selection-based UIs |
| [bulk-widget-updates](bulk-widget-updates/SKILL.md) | Bulk widget property updates | Changing widget settings across pages |

## Specialized Skills

| Skill | Purpose | Use When |
|-------|---------|----------|
| [bootstrap-app](bootstrap-app/SKILL.md) | Provision a new Mendix app in an empty repo | Starting from nothing: interview, `mxcli new`, hook + brief, commit, boot |
| [generate-domain-model](generate-domain-model/SKILL.md) | Complete domain model generation | Generating full domain models |
| [create-custom-widget](create-custom-widget/SKILL.md) | Custom pluggable widget AIGC | Creating custom React widgets from scratch |
| [migrate-design-prototype](migrate-design-prototype/SKILL.md) | Turn a Claude Design prototype into a themed Mendix app | Reproducing a design handoff/prototype as an SCSS theme + styled pages |
| [debug-bson](debug-bson/SKILL.md) | BSON debugging | Troubleshooting SDK issues |
| [analyze-runtime](analyze-runtime/SKILL.md) | Analyze runtime behavior — logs, metrics, traces, catalog, and cross-source joins | Profiling a slow page/microflow, finding what hits the DB, correlating cost with model shape |
| [upgrade-mendix-version](upgrade-mendix-version/SKILL.md) | Move a project to a newer Mendix version headlessly | Raising the Mendix version; a build says the project version does not match MxBuild |

---

## Skill Loading Guide

### For LLMs (Claude Code)

Load skills based on the task:

| User Request | Load These Skills |
|--------------|-------------------|
| "Set this empty repo up as a Mendix app" | `bootstrap-app` |
| "Create entity/domain model" | `mdl-entities` |
| "Write microflow" | `write-microflows`, `cheatsheet-variables` |
| "Change an existing page / microflow / entity" | `choose-edit-mode`, then the doctype skill |
| "Create validation" | `validation-microflows`, `patterns-crud` |
| "Add CRUD operations" | `patterns-crud` |
| "Process list of items" | `patterns-data-processing` |
| "Fix MDL error" | `cheatsheet-errors` |
| "Import data from database" | `demo-data` |
| "Call a REST API / integrate JSON endpoint" | `rest-call-from-json` |
| "Create JSON structure / import mapping" | `json-structures-and-mappings` |
| "Create export mapping" | `json-structures-and-mappings` |
| "Map JSON to entities" | `json-structures-and-mappings` |
| "Seed/populate test data" | `demo-data` |
| "Run a microflow nightly / hourly / on a schedule" | `scheduled-events-and-queues` |
| "Add a cron job / batch job / recurring task" | `scheduled-events-and-queues` |
| "Limit how many background tasks run at once" | `scheduled-events-and-queues` |
| "Add a validation pattern / email regex" | `regular-expressions` |
| "Update widget properties" | `bulk-widget-updates` |
| "Change widgets in bulk" | `bulk-widget-updates` |
| "Reuse widgets across pages" | `fragments` |
| "Define a fragment" | `fragments` |
| "Create custom widget" | `create-custom-widget` |
| "Build a pluggable widget" | `create-custom-widget` |
| "Turn a design prototype/handoff into a Mendix app" | `migrate-design-prototype`, `theme-styling`, `create-page` |
| "Build/apply a theme from a design" | `migrate-design-prototype`, `theme-styling` |
| "Why is this slow / profile the app / what hits the database" | `analyze-runtime`, `run-local` |
| "Trace / metrics / flame chart / correlate cost with model" | `analyze-runtime` |
| "Upgrade Mendix version / move to 11.x" | `upgrade-mendix-version` |
| "Project version does not match MxBuild" | `upgrade-mendix-version` |

### For Error Recovery

When encountering errors:

| Error Type | Load This Skill |
|------------|-----------------|
| Variable not declared | `cheatsheet-variables` |
| Entity type syntax | `cheatsheet-errors` |
| Association path error | `cheatsheet-errors` |
| Microflow structure error | `write-microflows` |
| OQL syntax error | `write-oql-queries` |

---

## Common Mistakes Summary

| Mistake | Frequency | Quick Fix |
|---------|-----------|-----------|
| SET without DECLARE | High | Add `declare $var type = value;` before SET |
| Declaring an object/list variable | High | Use a parameter, retrieve, create, or loop — never declare an object (MDL043) or list (MDL040) |
| Unqualified association | Medium | Use `$var/Module.Assoc/attr` |
| String enum comparison | Medium | Use `Module.Enum.Value` not `'string'` |
| Missing RETURN | Low | Add `return $value;` at end |

---

## Integration Points

### REPL Integration
```bash
mdl> help variables    # Load cheatsheet-variables
mdl> help errors       # Load cheatsheet-errors
mdl> help crud         # Load patterns-crud
```

### Check Command
```bash
mxcli check script.mdl -p app.mpr --references
```

### Linter
```bash
mxcli lint script.mdl
```

---

## Maintenance

When updating skills:
1. Keep each skill focused (100-200 lines target)
2. Include working code examples
3. Document common mistakes with fixes
4. Update this README when adding new skills
5. Test examples with actual MDL execution
