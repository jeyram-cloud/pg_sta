# Validation methodology

How `pg_sta` measures a proposed change, and how to read the result.

This is the most important document in the project: a tuning advisor is
only useful if its recommendations can be checked.

---

## 1. The principle

`pg_sta` never applies a change. It **measures** one.

The workflow is always:

```
observe  →  recommend  →  you apply it  →  pg_sta measures it
```

A recommendation is a hypothesis. `sta.validate()` is the experiment.

---

## 2. `sta.validate()`

```sql
SELECT * FROM sta.validate(
    p_index_ddl  => 'CREATE INDEX idx_orders_customer ON orders (customer_id)',
    p_sql        => 'SELECT * FROM orders WHERE customer_id = 42',
    p_iterations => 5);
```

| Argument | Type | Meaning |
|---|---|---|
| `p_index_ddl` | `text` | exactly one `CREATE [UNIQUE] INDEX` statement |
| `p_sql` | `text` | the statement to measure |
| `p_iterations` | `integer` | how many times to run each side (1–100, default 3) |

| Return column | Type | Meaning |
|---|---|---|
| `baseline_ms` | `double precision` | the mean execution time before the change |
| `candidate_ms` | `double precision` | the mean execution time with the index |
| `improvement_pct` | `double precision` | `100 × (baseline − candidate) / baseline` |
| `plan_changed` | `boolean` | whether the plan *signature* changed |
| `rows_match` | `boolean` | whether both runs returned the same number of rows |
| `verdict` | `text` | the summary verdict |
| `baseline_plan` | `jsonb` | the plan of the first baseline run |
| `candidate_plan` | `jsonb` | the plan of the first candidate run |
| `notes` | `text[]` | what happened, in prose |

### 2.1 How it works

```
  ┌─ baseline ──────────────────────────────────────────┐
  │  for i in 1..p_iterations:                           │
  │      plan := sta.explain(p_sql, analyze => true)      │
  │      times := times || Execution Time                │
  │      (first run also captures the plan signature     │
  │       and the actual row count)                      │
  └──────────────────────────────────────────────────────┘
                              │
  ┌─ candidate (inside a subtransaction) ───────────────┐
  │  EXECUTE p_index_ddl;                                │
  │  for i in 1..p_iterations:                           │
  │      plan := sta.explain(p_sql, analyze => true)      │
  │      times := times || Execution Time                │
  │  RAISE EXCEPTION 'pg_sta_validate_rollback';  ──────┼──┐
  └──────────────────────────────────────────────────────┘  │
                                                            │
  ◄─────────────────────────────────────────────────────────┘
  the exception rolls the subtransaction back: the index is gone
```

The index is created inside a `BEGIN … EXCEPTION` block and removed by the
rollback that the deliberate exception triggers. **The database is left
exactly as it was.** The `notes` column says so explicitly:

```
The candidate index was created in a subtransaction and rolled back;
the database is unchanged.
```

### 2.2 Input validation

`sta.validate()` refuses bad input early, with a message that says what
to do:

| Input | Rejected with |
|---|---|
| empty `p_index_ddl` | `p_index_ddl must not be empty` |
| something that is not `CREATE [UNIQUE] INDEX` | `p_index_ddl must be a CREATE [UNIQUE] INDEX statement` |
| `CREATE INDEX CONCURRENTLY` | `CREATE INDEX CONCURRENTLY cannot be used here because it cannot run inside a transaction block. Remove CONCURRENTLY; sta.validate always rolls the index back.` |
| more than one statement | `p_index_ddl must contain exactly one statement` |
| `p_iterations` outside 1–100 | `p_iterations must be between 1 and 100` |

The `CONCURRENTLY` rejection is deliberate: `CREATE INDEX CONCURRENTLY`
cannot run inside a transaction block, and `sta.validate()` needs the
transaction to roll the index back. This is a genuine trade-off — a
concurrent index build is gentler on a live system — and the tool states
it rather than failing obscurely. On a live system, build the index
concurrently by hand and use the `index` validation steps.

### 2.3 The plan signature

`sta.plan_signature(jsonb)` reduces a plan to a comparable shape. It walks
the plan tree and keeps the parts that describe *how* the statement is
executed:

- node type
- relation name
- join type
- sort/merge keys
- index name, when the node is an index scan

It deliberately **excludes** the values that change between two runs of
the same statement: costs, row estimates, actual rows, timings. Without
that exclusion, every plan would look "changed" and the comparison would
be worthless.

```sql
SELECT sta.plan_signature(sta.explain('SELECT * FROM orders WHERE id = 1'));
```

```
Seq Scan on orders
```

```sql
-- after creating an index on (id)
SELECT sta.plan_signature(sta.explain('SELECT * FROM orders WHERE id = 1'));
```

```
Index Scan using idx_orders_id on orders
```

---

## 3. The verdicts

### `RECOMMENDED`

The plan changed, the row counts match, and the candidate was at least 5 %
faster.

```
verdict:        RECOMMENDED
baseline:       2.643 ms
candidate:      0.110 ms
improvement:    95.84 %
plan changed:   true
rows match:     true
```

**What to do.** Apply the change for real (with `CONCURRENTLY` on a live
system), then re-measure the workload to confirm the improvement shows up
in `pg_stat_statements` and not only in the plan.

---

### `REJECTED`

The plan changed and the candidate was at least 5 % slower.

**What to do.** Do not apply the change. Look at `candidate_plan` — the
index was probably chosen but the table is now over-indexed, or the index
is wider than the row it selects.

---

### `NO_SIGNIFICANT_CHANGE`

The plan changed but the timing difference is below 5 %.

**What to do.** The change is not worth its cost on its own. Apply it only
if there is another reason to (a uniqueness constraint, a foreign key, a
reporting requirement).

---

### `NOT_USED`

The plan signature did not change: **the planner did not pick the index.**

This verdict comes *before* the timing comparison, and that ordering
matters. If the planner ignored the index, the two runs executed the same
plan, so any difference between the timings is measurement noise. Reporting
a 3 % "improvement" here would be a false positive.

```
verdict:        NOT_USED
notes:          The plan shape did not change: the planner did not pick the candidate index.
                The measured difference is therefore noise and not an effect of the index.
```

**What to do.** The index does not match the predicate. Check:

- is the indexed column the one the filter actually uses?
- is the filter wrapped in a function (`WHERE lower(col) = ...` needs an
  expression index)?
- is the column type mismatched (a `text` column compared to an `int`
  literal needs a cast)?
- is the column statistics so wrong that the planner believes the index
  is useless? (then `ANALYZE` first)

---

### `NOT_COMPARABLE`

The two runs returned a different number of rows.

```
verdict:        NOT_COMPARABLE
notes:          The statement returned a different number of rows before and after;
                the measurement is not comparable.
```

**What to do.** The statement is not deterministic — a `LIMIT` without
`ORDER BY`, a `NOW()` in the predicate, a concurrent write. Make it
deterministic and measure again.

Reporting a number here would be actively misleading: you would be
comparing the time of two *different* queries.

---

### `ERROR`

The candidate run failed. `notes` contains the error message.

```sql
SELECT verdict, notes FROM sta.validate(
    'CREATE INDEX i ON no_such_table (x)',
    'SELECT * FROM no_such_table');
```

**What to do.** Read the error. The usual cause is a permission problem
or a DDL error.

---

## 4. Reading the numbers

### 4.1 `improvement_pct` is not an SLA

It is the difference between the mean of `p_iterations` runs before and
after. It says nothing about:

- **the workload around it.** An index that speeds one statement by 95 %
  can slow every `INSERT` on that table by 10 %.
- **the variance.** A single fast run in the baseline can manufacture a
  90 % "improvement" out of nothing. Raise `p_iterations` when the
  numbers look too good.
- **concurrency.** `EXPLAIN ANALYZE` runs the statement alone. Under
  concurrency the picture can be completely different.

### 4.2 Raise `p_iterations` for a noisy statement

```sql
SELECT verdict, baseline_ms, candidate_ms, improvement_pct
FROM sta.validate(
    'CREATE INDEX idx_orders_customer ON orders (customer_id)',
    'SELECT * FROM orders WHERE customer_id = 42',
    20);   -- more iterations -> more stable mean
```

Each iteration is one execution of your statement, so use a statement that
is cheap enough to run 20 times.

### 4.3 `EXPLAIN ANALYZE` runs the statement

`sta.validate()` and `sta.plan_advice(..., p_analyze => true)` **execute**
the statement. Only pass `SELECT` statements. The C core refuses anything
else, and `pg_sta.enable_analyze = off` disables the whole path.

---

## 5. Validating the non-index findings

`sta.validate()` measures an **index**. The other finding kinds have
their own procedures, returned by `sta.validation_steps(p_kind)`.

### 5.1 `analyze` (statistics findings)

```sql
-- 1. baseline
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE customer_id = 42;

-- 2. the change
ANALYZE orders;

-- 3. measure again
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE customer_id = 42;

-- 4. the workload effect
SELECT calls, total_exec_time, mean_exec_time
FROM pg_stat_statements
WHERE queryid = sta.queryid('SELECT * FROM orders WHERE customer_id = 42');
```

**What to look for.** The planner estimate (`Plan Rows`) should now match
the actual rows (`Actual Rows`). If the estimate was wrong and now is
right, the finding was correct.

**Note.** `ANALYZE` is cheap and safe. It is also the change most likely
to make the *index* recommendation unnecessary — always try it before
building an index.

### 5.2 `vacuum` (dead tuples)

```sql
-- 1. baseline
SELECT n_live_tup, n_dead_tup, last_vacuum FROM pg_stat_user_tables
WHERE relname = 'orders';

-- 2. the change
VACUUM (ANALYZE) orders;

-- 3. confirm
SELECT n_live_tup, n_dead_tup, last_vacuum FROM pg_stat_user_tables
WHERE relname = 'orders';
```

**What to look for.** `n_dead_tup` drops and `last_vacuum` is set.

**Note.** `VACUUM FULL` is not recommended and `pg_sta` never suggests
it: it takes an `ACCESS EXCLUSIVE` lock and rewrites the whole table.

### 5.3 `config` (`work_mem` and friends)

```sql
-- 1. baseline, in the session that matters
SET work_mem = '4MB';
EXPLAIN (ANALYZE, BUFFERS) SELECT ... ;

-- 2. the change
SET work_mem = '64MB';
EXPLAIN (ANALYZE, BUFFERS) SELECT ... ;
```

**What to look for.** `Sort Method` changes from `external disk` to `quicksort`,
and `Temp Written Blocks` drops to 0.

**Note.** Never raise `work_mem` globally without checking the concurrency
level. `work_mem` is allocated **per sort/hash node per query**; a global
increase multiplied by the number of concurrent queries can exhaust the
memory of the machine.

### 5.4 `workload` (the before/after loop)

This is the one that matters most, and the slowest.

```sql
-- 1. snapshot before the change
SELECT * FROM sta.collect();

-- 2. apply the change

-- 3. let the workload run for a comparable period
SELECT pg_sleep(3600);

-- 4. snapshot after
SELECT * FROM sta.collect();

-- 5. compare
SELECT a.queryid,
       a.mean_exec_time AS before_ms,
       b.mean_exec_time AS after_ms,
       round(100 * (a.mean_exec_time - b.mean_exec_time)
             / a.mean_exec_time, 2) AS improvement_pct
FROM sta.workload_sample a
JOIN sta.workload_sample b USING (queryid)
WHERE a.sample_id = (SELECT max(sample_id) FROM sta.workload_sample) - 1
  AND b.sample_id = (SELECT max(sample_id) FROM sta.workload_sample);
```

**What to look for.** The mean execution time of the affected statement
fell, and the total execution time of the *other* statements did not rise.

That second condition is the one people forget. An "improvement" that
moves work onto other statements is a regression somewhere else.

---

## 6. A validation checklist

For any recommendation, before you apply it:

- [ ] Have I recorded a **baseline** — the plan, the timing and the buffer
      counts — before changing anything?
- [ ] Have I identified the **statement** the change is supposed to help?
- [ ] Have I checked whether a **cheaper change** (an `ANALYZE`, a
      statistic target, a different plan) would achieve the same thing?
- [ ] Have I validated the change **per statement** (`sta.validate()`)?
- [ ] Have I validated the change **per workload** (the snapshot
      comparison above)?
- [ ] Have I checked that **other statements** did not regress?
- [ ] Have I checked the **cost side** — write amplification, storage,
      memory, lock duration?
- [ ] Do I have a **rollback**? (`DROP INDEX` is the rollback for an
      index; restoring the old statistics is the rollback for an `ANALYZE`.)
- [ ] Have I made the change **reversibly** — `CREATE INDEX CONCURRENTLY`,
      not `CREATE INDEX`; a session-level `SET work_mem`, not a global
      one?

---

## 7. What `pg_sta` does not validate

| Not validated | Why |
|---|---|
| Whether the index survives a `VACUUM`/`REINDEX` cycle | Not an index-design question |
| The behaviour under real concurrency | `EXPLAIN ANALYZE` runs alone; a concurrency test is a separate exercise |
| The effect on replication lag | Outside the scope of a single-node advisor |
| Long-term plan drift as the data changes | `pg_sta` measures a moment; re-run it periodically |
| Whether the *application* got faster | The database is one part of the latency budget |

For the last one, measure the application: the tool can tell you the
statement got cheaper, not that the page got faster.
