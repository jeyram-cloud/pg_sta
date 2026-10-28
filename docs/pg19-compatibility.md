# PostgreSQL 19 compatibility

`pg_sta` reimplements, on PostgreSQL 17, the two plan-advice features that
PostgreSQL 19 introduces:

| PostgreSQL 19 | pg_sta (PostgreSQL 17) | Schema |
|---|---|---|
| `pg_plan_advice` | `sta.plan_advice_string()` | `sta` |
| `pg_stash_advice` | `sta.create_stash()` … `sta.get_stashed_advice()` | `sta` |

This document says exactly what is the same and what is different. Nothing
here is "planned for later": everything described as supported is
implemented, tested by the QA suite, and shipped.

---

## 1. Summary

| Area | Parity | Notes |
|---|---|---|
| Advice string format | **Exact** | Same tag names, same `TAG(target target)` syntax, same `@qualifier` suffix, tags are case-insensitive. |
| Tag vocabulary | **Exact** | The same 15 tags, with the same meaning. |
| Stash API shape | **Exact** | Same function names, same argument order, same return columns, same error conditions and SQLSTATEs. |
| Stash storage | **Approximate** | PostgreSQL 19 keeps stashes in dynamic shared memory and applies them from a background worker. `pg_sta` keeps them in ordinary tables and applies them on demand. |
| Advice enforcement | **Approximate** | PostgreSQL 19 hooks the planner and can enforce advice per relation. PostgreSQL 17 has no such hook, so `pg_sta` expresses advice through the planner's `enable_*` GUCs, which are session-wide. |
| Relation identifiers | **Simplified** | PostgreSQL 19 writes `alias#occurrence/partition_schema.partition_name@plan_name`. `pg_sta` writes the plan alias, with `#n` appended when an alias occurs more than once. |
| Automatic application | **Not available** | PostgreSQL 19 can start a background worker that applies a stash to every matching query. `pg_sta` has no equivalent; advice is applied by the caller. |

---

## 2. The advice language

### 2.1 Syntax

```
advice      := item (WS item)*
item        := TAG [ "(" target [WS target]* ")" ]
target      := alias [ "@" qualifier ]
```

* `TAG` is an identifier. **Tags are case-insensitive**: `join_order(f d1 d2)`
  and `JOIN_ORDER(f d1 d2)` are the same advice.
* A tag **may** be written without a target list (`NO_GATHER`). Tags whose
  meaning depends on a target list (`SEQ_SCAN`, `HASH_JOIN`, …) ignore the
  target when it is absent and apply to the whole statement.
* A target may be qualified with `@`, which in PostgreSQL 19 identifies a
  partition or a sub-plan. `pg_sta` parses and preserves the qualifier but
  does not act on it, because PostgreSQL 17 cannot address a partition in a
  planner setting.
* Whitespace between items is free-form.

### 2.2 Parsing

```sql
SELECT * FROM sta._advice_split('SEQ_SCAN(foo) HASH_JOIN(bar@ss)');
--  {SEQ_SCAN(foo),HASH_JOIN(bar@ss)}

SELECT * FROM sta._advice_parse('join_order(f d1 d2)');
--  item  = JOIN_ORDER(f d1 d2)
--  tag   = JOIN_ORDER
--  targets = {f,d1,d2}
```

Both functions are `IMMUTABLE`, so the parser can be used inside an index
expression or a generated column if you want to.

### 2.3 Tags

| Tag | Meaning | Enforcement on PostgreSQL 17 |
|---|---|---|
| `SEQ_SCAN` | Use a sequential scan | `enable_indexscan=off`, `enable_indexonlyscan=off`, `enable_bitmapscan=off` |
| `INDEX_SCAN` | Use an index scan | `enable_seqscan=off`, `enable_bitmapscan=off` |
| `INDEX_ONLY_SCAN` | Use an index-only scan | `enable_seqscan=off`, `enable_bitmapscan=off`, `enable_indexscan=off` |
| `BITMAP_HEAP_SCAN` | Use a bitmap heap scan | `enable_seqscan=off`, `enable_indexscan=off`, `enable_indexonlyscan=off` |
| `NESTED_LOOP_PLAIN` | Use a plain nested loop | `enable_hashjoin=off`, `enable_mergejoin=off` |
| `HASH_JOIN` | Use a hash join | `enable_nestloop=off`, `enable_mergejoin=off` |
| `MERGE_JOIN` | Use a merge join | `enable_nestloop=off`, `enable_hashjoin=off` |
| `PARTITIONWISE` | Plan partition-wise | `enable_partitionwise_join=on`, `enable_partitionwise_aggregate=on` |
| `NO_GATHER` | Do not gather parallel workers | `max_parallel_workers_per_gather=0` |
| `DO_NOT_SCAN` | Do not scan the target at all | **unsupported** |
| `JOIN_ORDER` | Reorder the joins | **unsupported** |
| `SEMIJOIN_UNIQUE` | Use a unique semi join | **unsupported** |
| `SEMIJOIN_NON_UNIQUE` | Use a non-unique semi join | **unsupported** |
| `GATHER` | Gather parallel workers | **unsupported** |
| `GATHER_MERGE` | Gather merged parallel workers | **unsupported** |

The catalogue is data, not code:

```sql
SELECT * FROM sta.plan_advice_tag_view;
--  tag | category | enforcement | guc_settings
```

An unsupported tag is **not** silently ignored. `sta.apply_advice()`
reports it as `TAG:unsupported` in its return value, so a caller can tell
the difference between "applied" and "cannot be applied on this server".

### 2.4 Generating advice from a plan

```sql
SELECT sta.plan_advice_string(
    'SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id
      WHERE c.region = ''eu''');
--  HASH_JOIN(c) SEQ_SCAN(o) SEQ_SCAN(c)
```

The advice is read from a **live** plan of the statement, exactly as
PostgreSQL 19 does: the relations named in the statement must exist in the
database, and the advice therefore describes the plan the planner actually
chose.  A statement that names a missing relation fails with
`relation "..." does not exist` — that is the intended behaviour, not a
defect.

The generated string is written in the PostgreSQL 19 advice language and can
be fed straight back into `sta.explain_with_advice()`.

**The round-trip property is the contract.** The advice generated from a
plan reproduces that plan when it is applied:

```sql
WITH q AS (SELECT 'SELECT ...' AS sql),
     a AS (SELECT sta.plan_advice_string(sql) AS advice FROM q)
SELECT (sta.explain(sql,false)->0->'Plan')
    = (sta.run_with_advice(advice, sql, false)->0->'Plan') AS identical
FROM q;
--  identical = t
```

This is asserted by the QA suite
(*"advice: applying the generated advice reproduces the plan"*).

---

## 3. The advice stash

### 3.1 API

| PostgreSQL 19 | pg_sta | Returns |
|---|---|---|
| `pg_create_advice_stash(name)` | `sta.create_stash(name)` | `void` |
| `pg_drop_advice_stash(name)` | `sta.drop_stash(name)` | `void` |
| `pg_set_stashed_advice(stash, qid, advice)` | `sta.set_stashed_advice(stash, qid, advice)` | `void` |
| `pg_get_advice_stashes()` | `sta.get_stashes()` | `(stash_name text, num_entries bigint)` |
| `pg_get_advice_stash_contents(stash)` | `sta.get_stash_contents(stash)` | `(stash_name text, query_id bigint, advice_string text)` |
| — (PG19 reads the stash through a GUC) | `sta.get_stashed_advice(qid, stash)` | `text` |

### 3.2 Semantics

These behaviours match PostgreSQL 19 exactly:

* Creating a stash that already exists is an error
  (`duplicate_object`), with the message `advice stash "x" already exists`.
* Dropping a stash that does not exist is an error
  (`undefined_object`), with the message `advice stash "x" does not exist`.
* A stash name must be a non-empty identifier of at most 63 characters;
  `99bottles` is rejected.
* Storing advice for a query id that is not in the stash is an error.
* The query id `0` is rejected.
* Storing the same query id twice replaces the previous advice.
* A `NULL` advice removes the entry.
* Reading the contents of an unknown stash returns **no rows** instead of
  an error.
* `sta.get_stashes()` reports the number of entries of each stash.

### 3.3 Where the difference is

**PostgreSQL 19** stores a stash in dynamic shared memory, so it is visible
to every backend without a round trip to a table, and a background worker
(`pg_start_stash_advice_worker()`) watches the shared memory and applies
the stored advice to matching queries automatically.

**`pg_sta`** stores a stash in the ordinary table `sta.advice_stash` and
its entries in `sta.advice_stash_entry`. This has three consequences:

1. The stash is durable: it survives a restart and it can be inspected with
   plain SQL.
2. The stash is visible to every session, including sessions that were
   connected before it was created.
3. **There is no background worker.** Advice is applied by the caller, with
   `sta.explain_with_stashed_advice()` or `sta.apply_advice()`. A deployment
   that wants PostgreSQL 19's automatic behaviour has to call the advisor
   from its own worker.

`pg_sta.advice_stash` is a session GUC that names the stash
`sta.get_stashed_advice()` reads when no stash name is passed explicitly.
It is the counterpart of PostgreSQL 19's `pg_stash_advice.stash_name`.

---

## 4. Applying advice

```sql
SELECT sta.apply_advice('SEQ_SCAN(d1)');
--  {SEQ_SCAN:enable_indexscan=off,
--   SEQ_SCAN:enable_indexonlyscan=off,
--   SEQ_SCAN:enable_bitmapscan=off}

SELECT sta.restore_advice();
--  {enable_indexscan=on,enable_indexonlyscan=on,enable_bitmapscan=on}
```

* `sta.apply_advice(advice)` applies the advice and records the previous
  values of the settings it changed in the `pg_sta.advice_state` GUC.
* `sta.restore_advice()` puts the session back exactly as it was and
  returns the settings it restored.
* Applying advice twice is safe: the second call restores the baseline
  first, so the restore list is always exact.
* Several advice items may touch the same planner setting. Only the value
  that was in force **before the first item was applied** is recorded, so
  `sta.restore_advice()` always puts back the original value and never the
  advised one.
* An unknown tag raises an error (`unknown plan advice tag: X`).
* An unsupported tag is reported in the return value as `TAG:unsupported`
  and changes nothing.

Two convenience wrappers do the apply/plan/restore cycle in one call:

```sql
SELECT * FROM sta.explain_with_advice('SEQ_SCAN(d1)', 'SELECT ...');
--  plan | applied | restored

SELECT sta.run_with_advice('SEQ_SCAN(d1)', 'SELECT ...');
--  the plan only
```

And the stash-aware variant:

```sql
SELECT * FROM sta.explain_with_stashed_advice(
    'nightly', sta.queryid('SELECT ...'), 'SELECT ...');
--  plan | applied | restored | advice
```

### 4.1 The session-wide limitation

This is the one difference that matters most in practice.

PostgreSQL 19 hooks the planner, so `SEQ_SCAN(d1)` can force a sequential
scan of `d1` while the rest of the statement is planned normally.
PostgreSQL 17 has no planner hook, so `pg_sta` has to express the advice
through `enable_seqscan`, `enable_indexscan` and friends — and those are
**session-wide** settings.

The practical consequence:

> `SEQ_SCAN(d1)` in `pg_sta` means "plan this statement without any index
> scan", not "plan this statement with a sequential scan of `d1` and an
> index scan of everything else".

This is why the QA suite checks the round-trip property rather than the
per-relation precision: what `pg_sta` guarantees is that the advice it
generates reproduces the plan it was generated from, and that the advice it
accepts has the documented effect.

The advice is applied to the current session only, and `pg_sta` never
changes a server-wide or a database-wide setting.

---

## 5. Command line interface

```bash
# generate advice for a statement
./scripts/pg_sta_ctl --database appdb plan-advice \
    "SELECT * FROM orders WHERE customer_id = 42"

# plan a statement with an advice string applied
./scripts/pg_sta_ctl --database appdb advice "SEQ_SCAN(orders)" \
    "SELECT * FROM orders WHERE customer_id = 42"

# manage a stash
./scripts/pg_sta_ctl --database appdb stash create nightly
./scripts/pg_sta_ctl --database appdb stash set nightly 6286871504391978581 "SEQ_SCAN(orders)"
./scripts/pg_sta_ctl --database appdb stash show nightly
./scripts/pg_sta_ctl --database appdb stash list
./scripts/pg_sta_ctl --database appdb stash remove nightly 6286871504391978581
./scripts/pg_sta_ctl --database appdb stash drop nightly
```

---

## 6. What pg_sta deliberately does not do

* It does not start a background worker (PostgreSQL 19's
  `pg_start_stash_advice_worker()`).
* It does not modify `postgresql.conf` or run `ALTER SYSTEM`.
* It does not enforce advice across sessions; advice applies to the session
  that applies it.
* It does not act on the `@qualifier` of a target, because PostgreSQL 17
  cannot address a partition through a planner setting.
* It does not re-order joins (`JOIN_ORDER`) or eliminate a scan
  (`DO_NOT_SCAN`); PostgreSQL 17 offers no way to express either.

---

## 7. Where to look in the source

| Artefact | Location |
|---|---|
| Tag catalogue and GUC mapping | `sql/pg_sta--0.1.7.sql`, section "Plan advice tags" |
| Advice parser | `sta._advice_split()`, `sta._advice_parse()` |
| Advice generator | `sta.plan_advice_string()` |
| Stash tables and API | `sta.advice_stash`, `sta.advice_stash_entry`, `sta.create_stash()` … |
| Apply/restore | `sta.apply_advice()`, `sta.restore_advice()` |
| GUCs | `pg_sta.advice_state`, `pg_sta.advice_stash` in `src/pg_sta.c` |
| Tests | `test/qa_assertions.sql`, sections 8, 9 and 10 |
