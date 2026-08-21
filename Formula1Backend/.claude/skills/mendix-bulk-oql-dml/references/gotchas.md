# What goes wrong

Symptom first, because that is what you have when you arrive.

---

## Nothing is ever rejected, and the input is not that clean

**An association compared to `null` in a WHERE matches no rows, in either
spelling, with no error.**

A loader resolved an account name into an association, then rejected the rows
where that failed:

```sql
update Ledger.ImportRow set IsValid = false, Problem = 'Unknown account'
where Batch = $b and Ledger.ImportRow_Account = null
```

Six rows in, one naming an account that does not exist. One rejection was
reported — a different row, for a different reason — and the unresolvable row was
promoted into the target table **with no account at all**.

Three idioms, same batch, same row, counted by the statements themselves:

```
where Ledger.ImportRow_Account = null                                rows=0
where Ledger.ImportRow/Ledger.ImportRow_Account/…/id = null           rows=0
where not exists (select 1 from Ledger.Account as a
                  where UPPER(a.Name) = UPPER(Ledger.ImportRow/AccountName))
                                                                      rows=1
```

**Test the source, not the association.** Ask whether a matching row exists in
the table you are resolving against. With `not exists` the same batch rejects 2
of 6 and promotes 4, which was the planted answer.

The reason this is dangerous rather than annoying: a validation written the wrong
way passes every row it is given, and "nothing was rejected" is exactly what
clean input looks like.

---

## `Duplicate column name: ID`, and there is no column called ID

An `INSERT … SELECT` whose select list contains two association paths:

```sql
select …, r/Ledger.ImportRow_Account/Ledger.Account/id,
          r/Ledger.ImportRow_Category/Ledger.Category/id
```

Both arrive named `ID`. The error is raised at analysis time by
`com.mendix.datastorage.oqltree.AnalysisException` and names nothing that appears
in the statement text.

**Alias every column in the list**, from the first version onward — not when the
second association is added, because that is when it starts failing and the error
does not say which pair collided.

---

## "Member X of entity Y not found" on a column that exists

Association columns are written **module-qualified**:

```sql
insert into Ledger.BudgetOverride (MonthKey, Amount, Ledger.BudgetOverride_Category)
--                                             not:  BudgetOverride_Category
```

The value is a path ending in `/id`, a bound `id` variable, a scalar subquery
selecting `id`, or `null`.

---

## The screen still shows the old rows

Expected, and the most common surprise. A statement does not pass through the
object cache: **no event handlers fire, no validation rules run, an object
already retrieved keeps its old values, and a client holding one is not
refreshed.**

The fix that works with a data grid:

1. A small non-persistent context object for the screen.
2. The grid on a **database** datasource constrained on it —
   `where [Batch = $currentObject/Batch]`.
3. The action ends `commit $Context refresh;`.

Refreshing the context re-runs the grid's query. It is the same mechanism a
master-detail screen already uses, pointed at a different problem.

---

## No `substring`

OQL has arithmetic, `UPPER`, `DATEPARSE`, `case`, `like`, `in`, `exists`,
subqueries and correlated subqueries. It has no `substring`, so anything that
needs to take a key apart has to be done by the caller — which is why "copy a
year" whose key is `'YYYY-MM'` text becomes twelve statements rather than one.

Check what you actually need before designing around a single statement.

---

## The app will not start, and the work that logged success is gone

Only if you use the after-startup microflow as a probe harness — which is
otherwise an excellent loop, since it needs no UI and writes to the log.

A statement that throws there does not just fail its own step:

```
ERROR - Core: An exception occurred while running the after-startup-action.
ERROR - M2EE: Starting Mendix Runtime failed.
```

The app does not start at all. And the whole action is one transaction, so a
failure at the end **rolls back everything before it** — two statements that had
already logged "copied 5" left zero rows behind.

Probe with an action that catches its own exceptions and returns them as text
(`OQL_Try`). Never with one that throws.

---

## General

The grammar is not visible from the model and the error messages are written for
someone holding the parse tree. Run statements whose WHERE cannot match, log what
comes back, and read the errors — sixteen of them in one pass is what produced
`patterns.md`. Guessing costs a rebuild each time; probing costs one.
