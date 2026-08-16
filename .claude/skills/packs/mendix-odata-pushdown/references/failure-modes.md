# What goes wrong

Symptom first, because that is what you have when you arrive. Every one of these
returns **200**.

---

## A detail page shows a different record's data

**The client re-read one row by key and got the collection back.**

Mendix does not apply the key lookup to a resource served by a read microflow.
The client asks for `/Drivers('hamilton')`, receives every driver, adopts the
first row as that object's identity, and **keeps it** — the wrong values persist
in the client's cache until the page is left.

The fix is `KeyField`. `Parse` fills `Query/Key` from `?$filter=k eq 'v'`,
`/Res('v')` and `/Res(k='v')` alike; `Key` is the short form. A resource with no
`KeyField` cannot answer a single-row read correctly, whatever else it does.

---

## Paging looks right and every page ships the whole table

`?$top=5` returns all rows; the widget renders five. Nothing is visibly broken
until the table is large enough to notice, and then it looks like a database
problem rather than a contract problem.

`Query/Top` and `Query/Skip` are clamped to `MaxTop` before you see them. For
splice callers they are already in `OrderBySql`.

---

## A filter returns zero rows against a column that clearly has them

**The literal arrived quoted and the column is numeric.**

Mendix quotes according to what the *widget* believes the attribute is. A combo
box on a numeric key sends `year eq '1957'`; the grid header above it sends
`year eq 1957`. Passing the quotes through hands the engine `year = '1957'`
against a BIGINT.

This is what the third field of the `Columns` map is for. An unrecognised type
is an error rather than a default, because the alternative is a typo that
quietly returns nothing.

---

## `OFFSET` fails on SQL Server or Oracle

Both refuse `OFFSET` without an `ORDER BY`. That is why `DefaultOrderBy` is not
optional in practice — and a page without a total order is a different set each
time it is asked for anyway, so the requirement is doing you a favour.

---

## The whole table comes back under a request for a handful

**An untranslated filter, on a splice caller that passed `RejectUnsupported = false`.**

The splice caller's `WHERE` *is* `FilterSql`. If the filter could not be
translated and was dropped, there is no `WHERE`. Pass `true`: `Rejected` comes
back set, and the caller is expected to fail the request.

`$orderby` is the one thing dropped rather than rejected. A wrong order is
cosmetic; a wrong row count is not.

---

## The grammar is smaller than OData, deliberately

Everything below is what a Mendix client actually emits. That set was not read
off the OData specification — Mendix's
[consumed OData service requirements](https://docs.mendix.com/refguide/consumed-odata-service-requirements/)
names the query options a service must support and **not one operator or
function**. It was captured off the wire instead: a running app driving real
datagrids with `OData Publish` at TRACE, plus fourteen XPath probe microflows to
force each shape.

Anything outside it — arithmetic, lambdas, `$apply`, date functions, `any`/`all`
— is rejected rather than approximated.

---

## Injection

Column names come from the client and are resolved through the whitelist;
nothing else reaches the SQL. Literals are escaped (`'` → `''`), numerics must
parse as numbers, and a key must match `[A-Za-z0-9_.-]{1,128}` — keys are
usually interpolated by the caller rather than bound, so their *shape* is
whitelisted rather than their content escaped.

`DefaultOrderBy` is spliced verbatim. It is yours, not the client's.

---

## Dialects differ in exactly two places

| | case-insensitive LIKE | page |
|---|---|---|
| postgresql, duckdb | `col ILIKE '%x%'` | `LIMIT n OFFSET m` |
| sqlserver, oracle | `LOWER(col) LIKE LOWER('%x%')` | `OFFSET m ROWS FETCH NEXT n ROWS ONLY` |
| mysql | `LOWER(col) LIKE LOWER('%x%')` | `LIMIT m, n` |

---

## Testing the parser without a runtime

`ODataQueryParser` is strings in, strings out, with no Mendix types in its
signature. It runs under `jshell` or a plain JUnit test with no runtime around
it, which is how the grammar above was checked term by term. Keep it that way:
the moment it takes an `IContext`, the cheap test disappears.
