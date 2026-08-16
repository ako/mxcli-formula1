# The two patterns, end to end

Which one applies is decided by one question: **do you own the SQL?**

---

## Splice — you build the statement

Concatenate the fragments. One parse, one statement, everything pushed down.

```
$Q = CALL JAVA ACTION {{MODULE}}.Parse(
  Uri               = $Request/Uri,
  Columns           = 'name:d.name:text,wins:d.race_wins:number,born:d.dob:date',
  Dialect           = 'postgresql',
  MaxTop            = 500,
  DefaultTop        = 500,
  DefaultOrderBy    = 'd.name ASC',
  KeyField          = 'driverId',
  RejectUnsupported = true);

IF $Q/Rejected THEN
  -- fail the request; do not answer it with unfiltered rows
END

DECLARE $Sql String = 'SELECT d.* FROM drivers d' + $Q/FilterSql + $Q/OrderBySql;
```

**Splice callers should pass `RejectUnsupported = true`.** Their `WHERE` *is*
`FilterSql`, so an untranslated filter means no `WHERE` at all — every row in
the table, under a 200, in answer to a request for a handful.

---

## Bind — the SQL is somebody else's

A named query on a database connection, a view, a procedure. Take the values and
pass them as parameters; nothing of yours reaches the far side as text.

```
$Rows = execute database query MyMod.Warehouse.GetSeasons
  (keyFilter = $Q/Key,
   topN      = toString($Q/Top),
   skipN     = toString($Q/Skip),
   sortCol   = $Q/SortColumn1,
   sortDir   = $Q/SortDirection1);
```

Bind callers can pass `RejectUnsupported = false`: they never look at
`FilterSql`, so failing a request over a filter they were never going to apply
trades one wrong answer for another.

For a bind-style caller the column map is usually `name:name:type`, because the
sort travels as the exposed name the query's own `CASE` matches on.

### Making a fixed statement sortable by a parameter

The statement cannot be rewritten, so the ordering has to be data. Wrap the real
query and drive both direction and column from bound values:

```sql
SELECT * FROM ( <the real query> ) t
WHERE {keyFilter} = '' OR CAST(t.id AS VARCHAR) = {keyFilter}
ORDER BY
  CASE WHEN {sortDir} = 'A' THEN (CASE {sortCol} WHEN 'name' THEN t.name END) END ASC  NULLS LAST,
  CASE WHEN {sortDir} = 'D' THEN (CASE {sortCol} WHEN 'name' THEN t.name END) END DESC NULLS LAST,
  <the default order>
LIMIT CAST({topN} AS BIGINT) OFFSET CAST({skipN} AS BIGINT)
```

One `CASE` arm per sortable column. The `{keyFilter} = '' OR …` shape is what
makes the same statement serve both the collection and the single-row re-read.

---

## The short forms

Plenty of resources are reachable one way only — the sessions of this weekend,
the laps of this race — and their entire contract is one value out of `$filter`.
Making those declare a column map and a dialect to reach one string is a tax on
the common case.

```
$Key   = CALL JAVA ACTION {{MODULE}}.Key(Uri = $Request/Uri, KeyField = 'raceId');
$Year  = CALL JAVA ACTION {{MODULE}}.FilterNumber(Uri = $Request/Uri, Field = 'year', Fallback = 0);
```

**They are not interchangeable.** `Key` falls back to the path segment
(`/Res('v')`), because that is how a client re-reads one row. `FilterNumber`
must not: reading `1036` out of `/Calendar('1036-c')` as if it were a year
answers a question nobody asked, which is the failure mode the module exists to
stop.

Guard the comparison — an unset number thrown at `>` fails at render time in the
browser, not in `mx check`:

```
IF $Year != empty AND $Year > 0 THEN …
```

---

## Stored routines

`CallStatement` renders the invocation for the engine you are on and never
renders a value:

```
CallStatement('f1ops.driver_form', 'table', 'driverId,lastN', 'postgresql')
  -> SELECT * FROM f1ops.driver_form({driverId}, {lastN})
```

`Parameters` is a comma-separated list of **Mendix query-parameter names**, in
the routine's own argument order. What comes back is a template full of
`{placeholders}` for `execute database query` to bind. The literal `null` passes
through as SQL `NULL`, which is how a Postgres procedure's INOUT slots are
filled.

This is a stronger position than the `$filter` translation can take. A `WHERE`
clause must be built as text because its *shape* comes from the client; a
routine call's shape is fixed by the routine and only its values vary. The only
text emitted is the routine name, checked against an identifier pattern rather
than escaped.

| `Kind` | postgresql / duckdb | sqlserver | oracle | mysql |
|---|---|---|---|---|
| `table` | `SELECT * FROM f(a,b)` | `SELECT * FROM f(a,b)` | `SELECT * FROM TABLE(f(a,b))` | refused — MySQL has none |
