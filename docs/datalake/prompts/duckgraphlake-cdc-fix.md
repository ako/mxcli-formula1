# Task: apply Mendix CDC updates field by field, not as whole rows

You are working in the ako/DuckGraphLake repository, on the server in `server/`. Fix how it turns Mendix entity CDC events into current state and history. Right now a `u` event's `after` image replaces the whole row. It should apply only the attributes where `before` and `after` differ. Today the lake can show a value that the source database never held.

## Background: what Mendix actually sends

The Mendix runtime (verified on 11.14.0 and 11.16.1) publishes CDC through a transactional outbox. Each change becomes one row in `mendixsystem$data_change_event`, written in the app's own transaction, and is published to `cdc.<App>.<Entity>.<major>.<space>` after commit. The message is a Debezium envelope with its schema embedded. The payload has the keys `before`, `after`, `op`, `source`, `ts_ms`, `ts_ns` and `ts_us`.

Both `before` and `after` are full images of **every** attribute, and both come from the runtime's **in-memory copy of the object** in the committing transaction, not from the stored row. The runtime's SQL `UPDATE`, though, writes only the columns that transaction changed. When two transactions change the same object concurrently, an event's images can therefore carry stale values for the attributes it didn't touch.

A real case, captured from a running app:

| Time | What happened |
|---|---|
| 20:59:00 | Transaction B (a scheduled sync run) loads `LiveSyncState`; `SessionKey` is `11343` |
| 20:59:05 | Transaction A changes `SessionKey` to `11344` and commits |
| 20:59:06 | B changes `LastRunAt` and `RunCount`, and commits at 20:59:21. The database row now holds `SessionKey = 11344` |

The two events, with only the relevant fields shown:

```json
// A, op "u"
"before": {"SessionKey": "11343", "LastRunAt": "2026-11-25T20:57:06.274Z", "RunCount": 96226, ...},
"after":  {"SessionKey": "11344", "LastRunAt": "2026-11-25T20:57:06.274Z", "RunCount": 96226, ...}

// B, op "u", published after A
"before": {"SessionKey": "11343", "LastRunAt": "2026-11-25T20:57:06.274Z", "RunCount": 96226, ...},
"after":  {"SessionKey": "11343", "LastRunAt": "2026-11-25T20:59:06.877Z", "RunCount": 96227, ...}
```

The server currently takes B's `after` as the new row. So `<app>.<entity>` showed `SessionKey = 11343` until the next event, and `<app>.<entity>_history` recorded a change back to `11343` that never happened. The row `{SessionKey 11343, LastRunAt 20:59:06.877}` never existed in the database. B's own images show it didn't change `SessionKey`, because `before` equals `after` there.

## The rule to implement

For each object id, events in order (topic offset; `cdc.sequence` within a transaction):

- `c` and `r`: the full `after` image is the state. A snapshot has no `before`.
- `u`: for each attribute where `before` and `after` differ, take the `after` value. Leave every other attribute as it was.
- `d`: the object is deleted.
- An attribute present in `after` but missing from `before`, for example one added by a later revision, counts as changed.
- If a `u` event has no `before` at all, fall back to the full `after`.

This reproduces the database exactly. The runtime writes only changed columns, and when two transactions change the same column, the last commit wins both in the database and in this fold.

Compare decoded values, not raw JSON text. Timestamps and decimals must compare equal when they encode the same value. A null compares equal to null, and null is not equal to the empty string.

## Where it has to change

Find each of these in `server/` before changing anything; don't assume the names.

1. **Ingest.** The topic table currently unwraps only `after` into columns. It also has to keep what changed. Recommended: add `changed LIST(VARCHAR)` to the `cdc` struct, computed once at ingest from the diff. Readers shouldn't have to re-decode `warpstream.value`, although the raw message is in there if you need it.
2. **Current state.** Update these to fold per attribute: the `<app>.<entity>` view, the raw `"local__cdc.…"_current` view, and the incremental `[[materialize]] views = "<app>.*"` path. That path merges events after the last offset, so it must merge per attribute too, not replace keys. One shape that works in SQL: for each attribute, `arg_max(attr, (offset, sequence)) FILTER (WHERE op IN ('c','r') OR list_contains(changed, 'Attr'))`. Then drop ids whose last event is `d`.
3. **History.** Keep `<app>.<entity>_history`'s existing columns, so dashboards over it still work, and add `changed_fields`. Then the history no longer appears to record changes that didn't happen.
4. **Downstream.** The generated mapping, OData and SPARQL read the current-state view, so they should follow. Check that they do.

## Acceptance

- A test that produces the three messages above (an `r` snapshot of the object, then A, then B), using the format of the existing CDC test fixtures. After the test, `<app>.<entity>` holds `SessionKey = 11344`, `LastRunAt = 2026-11-25T20:59:06.877Z` and `RunCount = 96227`. `_history` shows B's `changed_fields` as `[LastRunAt, RunCount]`.
- The same result through the materialized path, with refreshes between the events, not only at the end.
- The existing CDC tests still pass.
- Update `server/guide/cdc.md` (shown by `duckgraphlake help cdc`) and the README's CDC section: state that updates are applied per attribute, and why.

## Out of scope

Don't change Kafka storage, the Iceberg layout or topic naming. Two other issues found in the same session (an `--init` failure is fatal, and dashboards render nothing for TIMESTAMPTZ axes) are filed separately.
