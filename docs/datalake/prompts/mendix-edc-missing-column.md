# Bug report: External Database Connector throws a NullPointerException when a mapped column is missing

For the Mendix team that owns the External Database Connector, which has been built into the runtime since 11.12.

## Summary

When a database query's result does not contain a column that the query's mapping names, `Execute database query` fails with:

```
Cannot invoke "String.contains(java.lang.CharSequence)" because "<parameter2>" is null
```

The message names neither the query, the mapping nor the missing column. It looks like an internal error, not a modelling mistake, so it took several wrong guesses to find the cause. A missing column should be a clear error, or a validation at build time where the columns are known.

## Environment

- Mendix 11.16.1, runtime started standalone (no Studio Pro). The same NullPointerException appeared on 11.17.0.
- A database connection of type `PostgreSQL`, PostgreSQL JDBC driver 42.7.4, PostgreSQL 16.
- A query that returns a non-persistent entity with one String attribute, `json`, mapped as `json = json`.

## Reproduce

Two queries on the same connection, the same entity, the same mapping (`json = json`), and the parameter `c = 'ferrari'`:

| Query SQL | Result |
| --- | --- |
| `SELECT CAST({c} AS VARCHAR) AS json` | one object, `json = 'ferrari'` |
| `SELECT CAST({c} AS VARCHAR) AS other` | NullPointerException as above |

The only difference is the column's name. Both run without error in any SQL client.

The same happens when the driver labels a column differently from the alias in the SQL. That is how it was first hit: a PostgreSQL-wire server described every column as `unknown`, so no mapped name matched and every query failed with this message.

## Expected

- At run time: an error that names the query and the column, such as "Query `F1Lake.GetSeasonTeams` returned no column `json` for attribute `Chart.json`; it returned `unknown`."
- Where possible, at design time: Studio Pro validating the mapping against the query's described columns.

## Notes for the investigation

- `<parameter2>` is a compiler-generated name, so the null is the second parameter of an internal method. It looks like the column name looked up for a mapped attribute is null, and `String.contains` is called on it.
- What was ruled out on the way: the SQL's shape (`WITH`, subqueries and `SELECT * FROM (WITH …)` all work when the columns are named as mapped) and the parameter's type (the driver reports `text` or `varchar` in every case).
