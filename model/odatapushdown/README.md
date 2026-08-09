# ODataPushdown

Serve an OData resource from SQL you did not write.

Mendix will publish any entity over OData, including one with no table behind
it: declare the resource non-persistable, give it a read microflow, done. What
the documentation does not say is that Mendix then applies **none** of the query
options to your answer. `$filter`, `$orderby`, `$top`, `$skip`, `$count` and the
key lookup all arrive on the request URI and all stay there. Whatever the
microflow returns is exactly what the client gets.

That is not a 500 and not an empty grid. It is a 200 with the wrong rows:

- `?$top=5` returns all 917 rows and the widget shows five of them, so paging
  looks fine while every page ships the whole table.
- A client re-reading one held row by key gets the collection back, adopts the
  first row as that object's identity, and **keeps it**. The season page for
  1957 lists the 2024 grid, and nothing logs a word.

This module is the part of doing it properly that is the same for everybody.
Nothing in it is Formula 1, or DuckDB, or the app it was extracted from. Point
it at a warehouse table, a legacy view, a Databricks catalogue or a stored
procedure's result set and it does the same job.

## Install

```bash
cp -r Formula1Backend/javasource/odatapushdown  <target>/javasource/
mxcli exec model/odatapushdown/module.mdl -p <target>/App.mpr
```

Then add `ODataPushdown.User` to whichever user roles your published service
runs as — the module cannot do that itself without knowing your role names.

Two files and a script. No jar, no dependency.

## The API

```
ODataPushdown.Parse(Uri, Columns, Dialect, MaxTop, DefaultTop,
                    DefaultOrderBy, KeyField, RejectUnsupported)
                                              -> ODataPushdown.Query
ODataPushdown.Key(Uri, KeyField)              -> String
ODataPushdown.FilterNumber(Uri, Field, Fallback) -> Long
```

`Parse` is the whole thing. `Key` and `FilterNumber` are the short forms for the
common case — a resource reachable one way only ("the sessions of this weekend"),
whose entire contract is one value out of `$filter`.

### `ODataPushdown.Query`

| Field | Style | What it is |
|---|---|---|
| `FilterSql` | splice | `" WHERE …"`, or empty |
| `OrderBySql` | splice | `" ORDER BY … LIMIT n OFFSET m"` |
| `Key` | bind | the key the client is re-reading one row by; empty for a collection |
| `Top`, `Skip` | bind | the page, already clamped to `MaxTop` |
| `SortColumn1/2`, `SortDirection1/2` | bind | the sort, as exposed names and `A`/`D` |
| `WantsCount` | both | `$count=true` — the client wants the size of the set, not the page |
| `Rejected`, `RejectReason` | both | the request asked for something untranslatable |

### Two ways to spend it

Which one you get is decided by whether you own the SQL.

**Splice** — you build the statement, so concatenate `FilterSql` and
`OrderBySql` into it. One parse, one statement, everything pushed down.

```
$Q = CALL JAVA ACTION ODataPushdown.Parse(
  Uri = $Request/Uri, Columns = $Cols, Dialect = 'duckdb',
  MaxTop = 500, DefaultTop = 500, DefaultOrderBy = 'name ASC',
  KeyField = 'driverId', RejectUnsupported = true);

DECLARE $Sql String = $Select + $Q/FilterSql + $Q/OrderBySql;
```

**Bind** — the SQL lives somewhere you cannot rewrite: a named query on a
database connection, a view, a procedure. Take the values and pass them as
parameters.

```
$Rows = execute database query MyMod.Warehouse.GetSeasons
  (keyFilter = $Q/Key, topN = toString($Q/Top), skipN = toString($Q/Skip),
   sortCol = $Q/SortColumn1, sortDir = $Q/SortDirection1);
```

The SQL has to be written to expect them — the pattern this app uses is

```sql
SELECT * FROM ( <the real query> ) t
WHERE {keyFilter} = '' OR CAST(t.id AS VARCHAR) = {keyFilter}
ORDER BY
  CASE WHEN {sortDir} = 'A' THEN (CASE {sortCol} WHEN 'name' THEN t.name END) END ASC NULLS LAST,
  CASE WHEN {sortDir} = 'D' THEN (CASE {sortCol} WHEN 'name' THEN t.name END) END DESC NULLS LAST,
  <the default order>
LIMIT CAST({topN} AS BIGINT) OFFSET CAST({skipN} AS BIGINT)
```

— but the parameters travel as values, so nothing of yours reaches the parser on
the far side. This style is why the module is not simply a SQL builder: most of
the data worth exposing this way is behind SQL somebody else owns.

## `Columns` — the whitelist

`exposedName:sqlExpression:type`, comma-separated:

```
'name:d.name:text,wins:d.race_wins:number,active:d.is_active:bool,born:d.dob:date'
```

Nothing outside this list can be filtered or sorted on, and a filter naming
something outside it is a **rejection**, not an omission.

The type is not decoration. Mendix quotes a literal according to what the
*widget* believes the attribute is, which is not always what the column is: a
combo box on a numeric key sends `year eq '1957'` while the grid header above it
sends `year eq 1957`. Passing the quotes through gives the engine
`year = '1957'` against a BIGINT — zero rows, status 200. The type is what makes
both spellings mean the same thing. An unrecognised type is an error, because
the alternative is a typo that quietly returns nothing.

For a bind-style caller the map is usually `name:name:type`, because the sort
travels as the exposed name that the query's own `CASE` matches on.

## What it understands

Everything Mendix's OData client emits, and nothing else.

| | |
|---|---|
| comparisons | `eq` `ne` `gt` `ge` `lt` `le` |
| functions | `contains` `startswith` `endswith` |
| logic | `and` `or` `not`, parentheses, correct precedence |
| literals | text, numbers, decimals, `true`/`false`, `null`, ISO instants |
| options | `$filter` `$orderby` (two terms) `$top` `$skip` `$count` |
| the key | `?$filter=k eq 'v'`, `/Res('v')`, `/Res(k='v')` |

That set is not read off the OData specification. Mendix's
[consumed OData service requirements](https://docs.mendix.com/refguide/consumed-odata-service-requirements/)
names the query options a service must support and not one operator or function,
so it was captured off the wire instead: a running app driving real datagrids,
with `OData Publish` logging at TRACE, plus fourteen XPath probe microflows to
force each shape. See `FINDINGS.md §45`.

OData itself is far larger — arithmetic, lambdas, `$apply`, `any`/`all`, date
functions. None of it is emitted by a Mendix client, so none of it is here.

### Rejection is the point

A request outside the grammar comes back with `Rejected = true`. With
`RejectUnsupported = true` the action throws instead.

Splice callers should pass `true`: their `WHERE` *is* `FilterSql`, so an
untranslated filter means no `WHERE` at all — every row in the table, under a
200, in answer to a request for a handful. Bind callers can pass `false`; they
never look at `FilterSql`, so failing a request over a filter they were never
going to apply trades one wrong answer for another.

`$orderby` is the one thing that is dropped rather than rejected: a wrong order
is cosmetic, a wrong row count is not.

## Dialects

`postgresql` (default) `duckdb` `sqlserver` `oracle` `mysql`. They differ in
exactly two places — how a case-insensitive `LIKE` is spelled, and how a page is:

| | LIKE | page |
|---|---|---|
| postgresql, duckdb | `col ILIKE '%x%'` | `LIMIT n OFFSET m` |
| sqlserver, oracle | `LOWER(col) LIKE LOWER('%x%')` | `OFFSET m ROWS FETCH NEXT n ROWS ONLY` |
| mysql | `LOWER(col) LIKE LOWER('%x%')` | `LIMIT m, n` |

SQL Server and Oracle refuse `OFFSET` without an `ORDER BY`, which is why
`DefaultOrderBy` is not optional in practice. A page without a total order is a
different set each time it is asked for anyway.

## Injection

Column names come from the client and are resolved through the whitelist;
nothing else reaches the SQL. Literals are escaped (`'` → `''`), numerics must
parse as numbers, and a key must match `[A-Za-z0-9_.-]{1,128}` — keys are
usually interpolated by the caller rather than bound, so their *shape* is
whitelisted rather than their content escaped.

`DefaultOrderBy` is spliced verbatim. It is yours, not the client's.

## Layout

```
javasource/odatapushdown/ODataQueryParser.java   the parser — plain Java, no Mendix
javasource/odatapushdown/QueryObject.java        the binding — Core.instantiate and setValue
model/odatapushdown/module.mdl                   entity, three actions, module role
```

The split is deliberate: `ODataQueryParser` is strings in, strings out, so it
runs under jshell or a JUnit test with no runtime around it. That is how the
grammar above was checked term by term.

## Roadmap

**Stored procedures, through OData actions.** The bind style already reaches a
procedure's *result set* — point a named query at `CALL sp_x(?)` and the module
supplies the arguments. What it cannot do is expose the procedure as something a
client can *invoke*: an OData action or function, `POST /odata/x/RunReport`. That
is the other half of putting an existing RDBMS behind an OData surface, and the
piece that turns this from a read-only projection into a two-way integration.

**Everything Mendix emits, as Mendix grows.** The grammar here is a snapshot of
one client version, captured empirically because there is nothing to read. When
Studio Pro starts emitting a shape this rejects, the rejection is visible — which
is the whole reason it rejects rather than drops.
