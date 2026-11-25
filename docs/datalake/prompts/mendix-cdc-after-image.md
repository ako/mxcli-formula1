# Investigation request: Mendix CDC `after` images can contain values that were never stored

For the team that owns entity Change Data Capture and the event broker in the Mendix runtime.

## Summary

When two transactions change the same object at the same time, the runtime can publish a CDC event whose `after` image never existed in the database. The event is written atomically through the outbox, and delivery and ordering are both correct. The problem is the payload: `before` and `after` are both built from the committing transaction's in-memory object, while the SQL `UPDATE` writes only the columns that transaction changed. A consumer following the Debezium convention that `after` is the row as stored will show a wrong value until the next event.

Please investigate whether this is intended, whether it is documented, and whether the runtime should change it.

## Environment

- Mendix 11.14.0, PostgreSQL, runtime started standalone (no Studio Pro)
- One CDC service on one entity, `LiveSyncState`: eight attributes, no associations
- `Kafka.BootstrapServers` pointed at a local Kafka-protocol broker. The broker isn't involved, because the payload below was read straight from the runtime's outbox table before publication.

## What the runtime produces

Outbox table `mendixsystem$data_change_event`, with columns `sequence`, `event_time`, `change_type`, `data`, `transaction_id` and `execution_id`. One `data` value, as captured:

```json
[{"entity":"Formula1Backend.LiveSyncState","objectId":30117822508040565,
  "before":{"associations":[],"attributes":[
     {"dataType":"String","name":"SessionKey","value":""},
     {"dataType":"DateTime","name":"LastRunAt","value":1795641846260},
     {"dataType":"Long","name":"RunCount","value":96249}, ...]},
  "after":{"associations":[],"attributes":[
     {"dataType":"String","name":"SessionKey","value":""},
     {"dataType":"DateTime","name":"LastRunAt","value":1795641905800},
     {"dataType":"Long","name":"RunCount","value":96250}, ...]}}]
```

Every attribute appears in both images, including the unchanged ones.

## The race, as observed

Two code paths write the same single object:

- **B**, a scheduled event every minute: retrieves the object at the start of a run of about 20 seconds, later changes `LastRunAt` and `RunCount`, and commits.
- **A**, a published OData action: changes `SessionKey` and commits.

| Time | Event |
|---|---|
| 20:59:00 | B retrieves the object: `SessionKey = 11343` |
| 20:59:05 | A sets `SessionKey = 11344` and commits. Its event: `before 11343` → `after 11344`. Correct. |
| 20:59:06 | B changes `LastRunAt` and `RunCount`; its transaction ends at 20:59:21 |
| after B | The database row holds `SessionKey = 11344` and `LastRunAt = 20:59:06.877`. B's `UPDATE` did not touch `SessionKey`. |

B's published event:

```
before: SessionKey 11343, LastRunAt 20:57:06.274, RunCount 96226
after:  SessionKey 11343, LastRunAt 20:59:06.877, RunCount 96227
```

B's `after` (`SessionKey 11343` with `LastRunAt 20:59:06.877`) is a state the row never had. B's `before` isn't the stored row either: when B wrote, the stored row already held `11344`. A downstream current-state view showed `11343` for one cycle, until B's next run loaded the row again. It was reproduced on purpose, by changing `SessionKey` five seconds into a run.

## Why it matters

- **The Debezium convention.** Consumers built for log-based CDC treat `after` as the stored row. Log-based CDC over PostgreSQL's write-ahead log would have reported `11344` here.
- **Silent and self-healing.** The error lasts only until the object changes again, so it's easy to miss and hard to reproduce.
- **Exposure.** Any entity written from two places is affected: a scheduled event plus a UI or API path, or two users editing the same object. Mendix has no optimistic locking by default, so the application can't prevent it.

## How to reproduce in a minimal app

These steps reduce the race above to its essentials. They haven't been run as a separate app; the observation above comes from the real one.

1. Create an entity `Thing` with `A: String` and `B: Integer`, publish it in a CDC service, and point `Kafka.BootstrapServers` at any broker.
2. Microflow `Slow`: retrieve the `Thing`, call a Java action that sleeps 10 seconds, set `B = B + 1`, commit.
3. Microflow `Fast`: retrieve the `Thing`, set `A = 'new'`, commit.
4. Start `Slow`. While it sleeps, run `Fast`.
5. The database holds `A = 'new'`, but `Slow`'s event has `after.A` set to the old value. Read the outbox row before it's published, or the topic.

## Questions for the team

1. Is building `before` and `after` from the in-memory object intended, and is it documented anywhere consumers would see it?
2. Should `after` be the stored row? One option is to read the row back inside the transaction after the `UPDATE`. Under READ COMMITTED, PostgreSQL applies the `UPDATE` to the newest committed version of the row, so a read-back in the same transaction returns the true combined state, at the cost of one `SELECT` per changed object.
3. Alternatively, should the envelope say which attributes the transaction changed, by listing them or by including only those in `after`? Consumers could then apply patches safely without diffing.
4. If the current behaviour stays, documenting the rule would be enough for consumers to be correct: apply only the attributes where `before` ≠ `after`. That matches the database exactly, because the runtime writes only changed columns. Do Mendix's own CDC consumers (Tableflow, Data Hub, other Mendix apps) already work this way?

## What is not the problem

- The outbox's atomicity: the event exists if and only if the transaction committed.
- Ordering: events are published in commit order.
- The broker: the payload was captured from the outbox table before it reached any broker.
