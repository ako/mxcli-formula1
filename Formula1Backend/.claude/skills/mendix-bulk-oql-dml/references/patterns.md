# Patterns

Every statement below was run against real data. Row counts are what the
statements returned, checked against the database afterwards.

## What the grammar accepts

Sixteen probe statements, one pass:

```
update E set col = <literal | expression | $var> where …           OK
update E as t set t.col = …                                        OK   alias
update E set Module.E_Assoc = <id | /id path | subquery | null>    OK
update E set col = (select … where … Module.E/Col = …)             OK   correlated
delete from E where …                                              OK
insert into E (cols) values (…)                                    OK   11.13+
insert into E (cols) select … from …                               OK
where … like '%x%' | in (…) | exists (select …) | id in (select …) OK
select …                                                           ERR  "Unexpected statement type READ"
$var with no setVariable                                           ERR  "No value supplied for the parameter"
```

Reads keep going through `Core.retrieveOQLDataTable`. These are statements.

---

## First-match-wins rules, without a loop

The loop version retrieves every unclaimed row, walks the rules for each, and
commits per match. The set version is one `UPDATE` per rule, in rule order.

**The precedence lives in the WHERE clause.** Each statement only touches rows
that are still unclaimed, so a later rule cannot take a row an earlier rule took.
Nothing tracks "already matched" because nothing needs to:

```sql
update Ledger.Transaction set
  Ledger.Transaction_Category = $cat,
  Ledger.Transaction_CategoryRule = $rule,
  SignedAmount = 0 - Amount            -- or 'Amount', decided before the statement
where Ledger.Transaction_Category = null
  and IsMirror = false
  and UPPER(Merchant) like UPPER($v)   -- the rule's own predicate
```

Notes that transfer:

- **The sign expression is chosen by the caller, not by the statement.** Whether
  a category is income is known before the statement runs, so it goes in as text
  rather than as a `case` the database evaluates per row.
- **The predicate is built per rule** — `= $v`, `like $v || '%'`, `like '%' || $v
  || '%'`, `in (…)` — while the *value* stays bound. Concatenating the value into
  the statement text breaks on an apostrophe and invites worse.
- One statement per rule, N rules, instead of one commit per matched row.

---

## Copy a window of records

`INSERT … SELECT`, made idempotent by clearing the target first, in the same
transaction:

```sql
delete from Ledger.BudgetOverride where MonthKey like $y            -- '2027-%'

insert into Ledger.BudgetOverride
       (MonthKey, Amount, Ledger.BudgetOverride_Category)
select $to, o.Amount, o/Ledger.BudgetOverride_Category/Ledger.Category/id
from   Ledger.BudgetOverride as o
where  o.MonthKey = $from
```

- **The association column is written by its qualified name** and read as a path
  ending in `/id`. `BudgetOverride_Category` alone fails with *"Member
  BudgetOverride_Category of entity Ledger.BudgetOverride not found"*.
- **Twelve statements, not one**, because `MonthKey` is `'YYYY-MM'` text and OQL
  has no `substring` to build the target key from the source key. Each statement
  still copies every category for its month. Verified: 5 copied, 5 again on a
  second run, 5 in the database.

If your key is a real date or an integer year, this collapses to one statement —
the arithmetic OQL does have.

---

## Stage, validate, promote

The strongest of the three, and the one worth copying wholesale. Rows land in a
loader entity, are checked **where they landed**, and only survivors are
promoted.

**1. Land** — ordinary object creates, or a bulk insert if the source is a table.

**2. Resolve names to associations** with a correlated subquery in `SET`:

```sql
update Ledger.ImportRow set Ledger.ImportRow_Account =
  (select a.id from Ledger.Account as a
   where UPPER(a.Name) = UPPER(Ledger.ImportRow/AccountName))
where Batch = $b
```

The correlation back to the row being updated is written as the fully qualified
entity path, `Ledger.ImportRow/AccountName`.

**3. Validate — one statement per check**, each stamping a reason:

```sql
update Ledger.ImportRow set IsValid = false, Problem = 'Amount must be positive'
where Batch = $b and IsValid = true and Amount <= 0

update Ledger.ImportRow set IsValid = false, Problem = 'Unknown account: ' + AccountName
where Batch = $b and IsValid = true
  and not exists (select 1 from Ledger.Account as a
                  where UPPER(a.Name) = UPPER(Ledger.ImportRow/AccountName))
```

`and IsValid = true` in every check means a row keeps the **first** reason it
failed, rather than the last — the same first-match-wins trick as the rules.

**Do not write the resolution check as `Ledger.ImportRow_Account = null`.** It
matches nothing. See `gotchas.md`; this is the one that wrote bad data.

**4. Promote** — one statement, every column aliased:

```sql
insert into Ledger.Transaction
       (TxDate, Merchant, Description, Amount, SignedAmount, IsMirror,
        Ledger.Transaction_Account, Ledger.Transaction_Category)
select DATEPARSE(r.TxDateText, 'yyyy-MM-dd') as TxDate,
       r.Merchant as Merchant, r.Description as Description, r.Amount as Amount,
       case when r/Ledger.ImportRow_Category/Ledger.Category
                  /Ledger.Category_CategoryGroup/Ledger.CategoryGroup/GroupType = 'Income'
            then r.Amount else 0 - r.Amount end as SignedAmount,
       false as IsMirror,
       r/Ledger.ImportRow_Account/Ledger.Account/id as AccountId,
       r/Ledger.ImportRow_Category/Ledger.Category/id as CategoryId
from Ledger.ImportRow as r
where r.Batch = $b and r.IsValid = true
```

`DATEPARSE` turns landed text into a date inside the statement. A `case` over a
path several associations long computes the sign. Both mean the loader entity can
hold text and the target can hold types.

**5. Clear the promoted rows, keep the rejects:**

```sql
delete from Ledger.ImportRow where Batch = $b and IsValid = true
```

The rejects stay, each with its reason, which is the entire argument for a loader
table over an import that half-succeeds and reports a number.

Verified end to end: 6 rows in, 2 rejected with reasons, 4 promoted, 932 → 936
transactions.
