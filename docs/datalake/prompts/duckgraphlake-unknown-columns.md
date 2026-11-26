# Bug: a statement with an untypeable parameter loses every result column name

You are working in the ako/DuckGraphLake repository, on the server's PostgreSQL wire protocol endpoint in `server/`. When a prepared statement contains a parameter whose type cannot be inferred from its context, the server describes **every** column of the result as `unknown` of type `text`. That is the row description sent for Describe and for execution. The values are correct; the names and types are lost.

Clients that map result columns by name then break. Mendix's External Database Connector is the case that found it: it maps columns to entity attributes by label, finds none, and fails.

## Reproduce

With any PostgreSQL JDBC driver (measured with `org.postgresql:postgresql:42.7.4`) against build `206c9e4`:

```java
PreparedStatement ps = conn.prepareStatement(sql);
ResultSetMetaData before = ps.getMetaData();      // the Describe answer
ps.setString(1, "ferrari");
ResultSetMetaData after = ps.executeQuery().getMetaData();
// print getColumnLabel(i) + ":" + getColumnTypeName(i)
```

| SQL | DuckGraphLake | PostgreSQL 16 |
| --- | --- | --- |
| `SELECT ? AS x` | `unknown:text` | `x:text` before, `x:varchar` after |
| `SELECT CAST(? AS VARCHAR) AS x` | `x:varchar` | `x:varchar` |
| `SELECT 'a' AS x WHERE 'a' = ?` | `x:varchar` | `x:text` |
| `WITH arg AS (SELECT ? AS c) SELECT CAST(count(*) AS VARCHAR) AS json FROM gold.team_season WHERE constructor_id = (SELECT c FROM arg)` | `unknown:text` (value correct: 1135) | — |
| `SELECT CAST(count(*) AS VARCHAR) AS json FROM gold.team_season WHERE constructor_id = (SELECT c FROM (SELECT ? AS c) arg)` | `unknown:text` (value correct) | — |
| `WITH t AS (SELECT * FROM gold.team_season WHERE constructor_id = ?) SELECT CAST(count(*) AS VARCHAR) AS json FROM t` | `json:varchar` | — |

The fourth and fifth rows show it is not only the parameter's own column. Their only output column is `count(*) AS json`, and it still comes back as `unknown`. The parameter's own type is reported fine (`text`) in every case. Only the result description falls back.

## What to look for

The pattern suggests that when DuckDB cannot bind a statement with an untyped parameter at Parse/Describe time, the server sends a generic fallback row description (one column, `unknown`, `text`) instead of the real one. It then keeps that fallback for execution as well, although by then the parameter's value, and so its type, is known.

PostgreSQL's own behaviour is the target: an untyped parameter is typed `unknown` or `text`, the statement is planned with that, and the row description keeps the aliases.

Find the place in `server/` where the row description is built for the extended query protocol (Parse, Describe, Bind, Execute). Then either:

- bind the statement with untyped parameters defaulted to `VARCHAR`, as PostgreSQL defaults to `text`, so DuckDB can describe it; or
- if Describe really cannot be answered before Bind, describe after binding and send the real description. Never send a placeholder for a statement that does run.

## Acceptance

- A test over the PostgreSQL endpoint, using JDBC or the protocol directly, for each of the six rows above: the labels and types before and after execution match the alias and the expression's type. `SELECT ? AS x` must at least be named `x`.
- The values stay as they are; today they are already right.
- Existing PostgreSQL-endpoint tests still pass, including the DataGrip introspection set the README mentions.
- A note in `server/guide/sql.md` if any parameter case still cannot be described.

## Context

Found in ako/mxcli-formula1, whose Mendix frontend reads the lake through Mendix's External Database Connector. Its FINDINGS §113–§115 record the investigation, including two earlier wrong explanations. The app works around it by comparing every parameter with a column, which keeps the names.
