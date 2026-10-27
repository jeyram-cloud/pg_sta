# Advice catalogue

Every finding `pg_sta` can emit, with the evidence it is based on, its
default severity, the action it recommends and the kind of validation it
needs.

The catalogue is also available at runtime:

```sql
SELECT * FROM sta.advice_catalog() ORDER BY category, finding;
```

```bash
./scripts/pg_sta_ctl catalog
```

---

## Summary

| Category | Findings |
|---|---|
| **workload** | 5 |
| **plan** | 11 |
| **statistics** | 6 |
| **snapshot** | 4 |
| **rewrite** | 8 |
| **Total** | **34** |

---

## 1. Workload findings

Source: `pg_stat_statements` (or the snapshot in `sta.workload_sample`).

### `HIGH_TOTAL_TIME` — HIGH

**What it means.** The statement consumes a large share of the total
execution time of the observed window.

**Evidence.** `total_exec_time`, and the statement's `time_share_pct` of
the window.

**Recommended action.** Reduce the execution time of the statement.

**Validation kind.** `workload` — record the mean and total execution
time, apply the change, let the workload run for a comparable period, and
compare.

**Caveat.** Total time scales with call volume. A statement that is fast
but called a million times can outrank a statement that takes a second but
runs once. Look at `time_share_pct` together with `mean_exec_time`.

---

### `HIGH_MEAN_EXEC_TIME` — HIGH

**What it means.** Every single execution of the statement is slow.

**Evidence.** `mean_exec_time`.

**Recommended action.** Inspect the plan of the statement for an
access-path problem.

**Validation kind.** `plan`.

**Caveat.** This is the most stable of the workload signals: unlike the
total time it does not depend on how often the statement happens to run.
It is the one to trust when the call volume is spiky.

---

### `HIGH_FREQUENCY` — MEDIUM

**What it means.** The statement is executed very often.

**Evidence.** `calls`.

**Recommended action.** Optimise the hot path of the statement; small
per-call savings accumulate quickly.

**Validation kind.** `workload`.

**Caveat.** Frequency alone is not a problem. A statement called a
million times per second that takes 50 µs is doing its job. Pair this
finding with `HIGH_MEAN_EXEC_TIME`.

---

### `HIGH_TEMP_IO` — MEDIUM

**What it means.** The statement spills to temporary files.

**Evidence.** `temp_blks_written`.

**Recommended action.** Raise `work_mem` or reduce the size of the sorted
or hashed input.

**Validation kind.** `config`.

**Caveat.** Raising `work_mem` is a per-session and per-node setting.
Raising it globally is one of the most common ways to turn a slow query
into an out-of-memory error on a machine with many concurrent sessions.
Validate per workload, not per query.

---

### `LOW_CACHE_HIT_RATIO` — MEDIUM

**What it means.** The statement reads most of its blocks from storage
instead of the buffer cache.

**Evidence.** `shared_blks_hit / (shared_blks_hit + shared_blks_read)`.

**Recommended action.** Reduce the working set or improve locality.

**Validation kind.** `config`.

**Caveat.** The ratio is only reported once the statement has read at
least `min_shared_blks_read` (default 1000) blocks. Below that the ratio
is dominated by noise and the finding would be misleading.

---

## 2. Plan findings

Source: `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` of the statement you
asked about.

### `SEQ_SCAN_ON_LARGE_TABLE` — HIGH

**What it means.** A sequential scan reads a large relation although an
index could serve the filter.

**Evidence.** `Node Type = Seq Scan` and the estimated size of the
relation above `seq_scan_min_rows` (default 1000).

**Recommended action.** Add an index that supports the filter of this scan.

**Validation kind.** `index`.

**How to check.** `sta.index_advice()` proposes the concrete index;
`sta.validate()` measures whether it helps.

---

### `SEQ_SCAN_ON_SMALL_TABLE` — INFO

**What it means.** A sequential scan over a small relation is appropriate.

**Evidence.** `Node Type = Seq Scan` on a relation below
`seq_scan_min_rows`.

**Recommended action.** No action required.

**Validation kind.** `plan`.

**Why it exists.** A tool that only reports problems is a tool you cannot
learn to trust. This finding tells you that the advisor looked at the scan
and decided it was fine — which is exactly as useful to know.

---

### `ESTIMATE_MISMATCH` — HIGH

**What it means.** The planner estimate differs from the actual number of
rows by a large factor.

**Evidence.** `Plan Rows` vs `Actual Rows`, ratio above
`estimate_mismatch_factor` (default 10).

**Recommended action.** Refresh the statistics of the affected relation.

**Validation kind.** `analyze`.

**Why it matters.** This is the single most common cause of a bad plan.
The planner chose a join order or an access path based on a wrong number.
Fixing the statistics frequently removes the need for an index entirely.

---

### `ROWS_REMOVED_BY_FILTER` — MEDIUM

**What it means.** Most rows read by the node were discarded by the
filter.

**Evidence.** `Rows Removed by Filter` above
`min_rows_removed_by_filter` (default 1000).

**Recommended action.** Add an index that supports the filter.

**Validation kind.** `index`.

**How to check.** `sta.index_advice()` on the same statement.

---

### `NESTED_LOOP_HIGH_LOOPS` — MEDIUM

**What it means.** The nested loop ran far more often than the planner
assumed.

**Evidence.** `Actual Loops` above `nested_loop_max_loops` (default 1000).

**Recommended action.** Check the join condition and the statistics of the
inner relation.

**Validation kind.** `analyze`.

**Why it matters.** A nested loop whose inner side is re-executed
thousands of times is the classic "the planner underestimated the outer
side" symptom. It is usually a statistics problem before it is a plan
problem.

---

### `HASH_BATCHES` — MEDIUM

**What it means.** The hash join needed more than one batch, so the hash
table did not fit into memory.

**Evidence.** `Hash Batches` > 1.

**Recommended action.** Raise `work_mem`.

**Validation kind.** `config`.

**Caveat.** Same caveat as `HIGH_TEMP_IO`: `work_mem` is per node, per
query. Validate under realistic concurrency.

---

### `SORT_SPILLED_TO_DISK` — MEDIUM

**What it means.** The sort did not fit into `work_mem` and was written to
disk.

**Evidence.** `Sort Method = external disk`.

**Recommended action.** Raise `work_mem` or sort fewer rows.

**Validation kind.** `config`.

---

### `BITMAP_LOSSY_RECHECK` — MEDIUM

**What it means.** The bitmap heap scan lost pages and had to re-check rows
one by one.

**Evidence.** `Heap Blocks Lost` > 0.

**Recommended action.** Raise `work_mem` so the bitmap fits in memory.

**Validation kind.** `config`.

---

### `TEMP_BLOCKS_WRITTEN` — MEDIUM

**What it means.** The node wrote temporary blocks.

**Evidence.** `Temp Written Blocks` > 0.

**Recommended action.** Remove the spill.

**Validation kind.** `config`.

---

### `HIGH_TOTAL_COST` — LOW

**What it means.** The plan node has a very high cost estimate.

**Evidence.** `Total Cost` above `high_total_cost` (default 10000).

**Recommended action.** Look for a cheaper access path.

**Validation kind.** `plan`.

**Caveat.** Cost units are arbitrary and are *not* milliseconds. A high
cost on a node that runs once a day is not a problem; a moderate cost on
the hottest statement is. Use this finding together with the workload
findings.

---

### `SLOW_EXECUTION_TIME` — HIGH

**What it means.** The statement itself was slow when it was measured.

**Evidence.** `Execution Time` above `high_execution_time_ms` (default
1000).

**Recommended action.** Combine the measurement with the workload
statistics.

**Validation kind.** `workload`.

**Caveat.** This measures **one** execution. A statement that is fast
usually and slow occasionally is a *latency* problem, not an average-time
problem, and `mean_exec_time` will not show it. Look at
`pg_stat_statements` for the distribution.

---

## 3. Statistics findings

Source: `pg_stat_user_tables`, `pg_class`, `pg_index`.

### `NEVER_ANALYZED` — HIGH

**What it means.** The relation has never been analyzed.

**Evidence.** `last_analyze` and `last_autoanalyze` are both NULL.

**Recommended action.** Run `ANALYZE`.

**Validation kind.** `analyze`.

**Why it matters.** Without statistics the planner works with default
estimates — often a fixed fraction of the table size. This is the most
common cause of a catastrophic plan on a table that grew after it was
created.

---

### `STALE_STATISTICS` — MEDIUM

**What it means.** The relation changed a lot since it was last analyzed.

**Evidence.** `n_mod_since_analyze` compared against the autovacuum rule
(`analyze_scale_factor` = 0.1, `analyze_base_threshold` = 50).

**Recommended action.** Run `ANALYZE` (or lower
`autovacuum_analyze_scale_factor` for this table).

**Validation kind.** `analyze`.

**Note.** The rule is the same one autovacuum uses, so the tool does not
complain about tables that autovacuum is already keeping fresh. If a
table is reported here and autovacuum is enabled, the usual cause is that
autovacuum cannot keep up with the write rate.

---

### `HIGH_DEAD_TUPLES` — MEDIUM

**What it means.** The relation accumulated many dead tuples.

**Evidence.** `n_dead_tup` against `dead_tuple_ratio` (0.2) and
`dead_tuple_min` (1000).

**Recommended action.** Run `VACUUM (ANALYZE)`.

**Validation kind.** `vacuum`.

**Cost.** `VACUUM` uses I/O and CPU; a `VACUUM FULL` would lock the table
but is **not** required here. `pg_sta` never recommends `VACUUM FULL`.

---

### `NEVER_VACUUMED` — LOW

**What it means.** The relation has never been vacuumed since it was
created or last reset, so the visibility map and the free space map are
stale.

**Evidence.** `pg_stat_all_tables.last_vacuum` / `last_autovacuum` are
both NULL while `n_live_tup > 0`.

**Recommended action.** Run `VACUUM (ANALYZE)` once, then let autovacuum
keep it up to date.

**Validation kind.** `vacuum`.

**Cost.** One `VACUUM` pass over the relation. `pg_sta` never recommends
`VACUUM FULL`, because that rewrites the table and takes an exclusive
lock.

---

### `NO_PRIMARY_KEY` — LOW

**What it means.** The relation has no primary key.

**Evidence.** `pg_index.indisprimary` — no index has it set.

**Recommended action.** Consider adding a primary key if the data model
allows it.

**Validation kind.** `plan`.

**Why it matters.** A primary key gives the planner a proven unique index
and enables logical replication. It is a data-model decision, not a
performance one, which is why the severity is LOW.

---

### `NO_INDEXES` — INFO

**What it means.** The relation has no indexes at all.

**Evidence.** `pg_index` — no index on the relation.

**Recommended action.** Add indexes for the columns that are used in
`WHERE` and `JOIN` clauses.

**Validation kind.** `index`.

**Caveat.** For a small table that is only ever fully scanned, no index is
the right answer. Use `sta.index_advice()` on the statements that touch
the table before acting.

---

## 3c. Plan advice tags

The plan-advice feature has its own, separate catalogue: the *advice
tags*. A tag is not a finding — it is an instruction that tells the
planner how a statement should be planned. The catalogue is data:

```sql
SELECT * FROM sta.plan_advice_tag_view;
```

| Tag | Category | Enforcement | Planner settings |
|---|---|---|---|
| `SEQ_SCAN` | scan | approximate | `enable_indexscan=off`, `enable_indexonlyscan=off`, `enable_bitmapscan=off` |
| `INDEX_SCAN` | scan | approximate | `enable_seqscan=off`, `enable_bitmapscan=off` |
| `INDEX_ONLY_SCAN` | scan | approximate | `enable_seqscan=off`, `enable_bitmapscan=off`, `enable_indexscan=off` |
| `BITMAP_HEAP_SCAN` | scan | approximate | `enable_seqscan=off`, `enable_indexscan=off`, `enable_indexonlyscan=off` |
| `NESTED_LOOP_PLAIN` | join | approximate | `enable_hashjoin=off`, `enable_mergejoin=off` |
| `HASH_JOIN` | join | approximate | `enable_nestloop=off`, `enable_mergejoin=off` |
| `MERGE_JOIN` | join | approximate | `enable_nestloop=off`, `enable_hashjoin=off` |
| `PARTITIONWISE` | partition | approximate | `enable_partitionwise_join=on`, `enable_partitionwise_aggregate=on` |
| `NO_GATHER` | parallel | approximate | `max_parallel_workers_per_gather=0` |
| `DO_NOT_SCAN` | scan | unsupported | — |
| `JOIN_ORDER` | join | unsupported | — |
| `SEMIJOIN_UNIQUE` | join | unsupported | — |
| `SEMIJOIN_NON_UNIQUE` | join | unsupported | — |
| `GATHER` | parallel | unsupported | — |
| `GATHER_MERGE` | parallel | unsupported | — |

`exact` enforcement would mean that the tag can be applied to a single
relation without affecting the rest of the statement. That needs a
planner hook, which PostgreSQL 17 does not have. Every tag is therefore
`approximate` on PostgreSQL 17, and the six tags that have no planner
setting at all are `unsupported` — they are reported as
`TAG:unsupported` rather than silently ignored.

The full analysis is in [pg19-compatibility.md](pg19-compatibility.md).

## 3b. Snapshot findings

`sta.snapshot_diff()` compares the two most recent snapshots of a schema
and reports what changed between them. It needs at least two
`sta.collect()` calls to produce anything.

---

### `DEAD_TUPLE_GROWTH` — MEDIUM

**What it means.** Dead tuples appeared between the two snapshots and were
not reclaimed.

**Evidence.** `sta.table_stats_sample.n_dead_tup` grew between the two
snapshots, and the relation now holds more than `dead_tuple_ratio` (0.2)
dead rows.

**Recommended action.** Run `VACUUM (ANALYZE)`.

**Validation kind.** `vacuum`.

**Cost.** `VACUUM` uses I/O and CPU; it is online and does not block
readers or writers. `pg_sta` never recommends `VACUUM FULL`.

---

### `STATISTICS_GO_STALE` — MEDIUM

**What it means.** The relation changed between the two snapshots and was
not analyzed in between, so the planner is working from stale statistics.

**Evidence.** `sta.table_stats_sample.n_mod_since_analyze` is greater
than zero in the newer snapshot.

**Recommended action.** Run `ANALYZE` on the relation.

**Validation kind.** `analyze`.

**Cost.** `ANALYZE` is cheap and safe to run on a live system.

---

### `TABLE_GROWTH` — INFO

**What it means.** The relation grew noticeably between the two
snapshots.

**Evidence.** `sta.table_stats_sample.n_live_tup` grew by at least
`snapshot_growth_min_rows` (1000) rows.

**Recommended action.** Review the growth rate and make sure autovacuum
keeps up with it.

**Validation kind.** `plan`.

---

### `INDEX_NO_LONGER_USED` — LOW

**What it means.** The index was used before the previous snapshot but
has not been used during the last window.

**Evidence.** `sta.index_sample.idx_scan` did not increase between the
two snapshots, while the index was used at least `index_idle_min_scans`
(100) times before.

**Recommended action.** Review the index; drop it only if it stays
unused over several windows.

**Validation kind.** `index`.

**Caveat.** Primary key and unique-constraint indexes are never reported,
because they enforce constraints rather than serve the workload.

---

## 4. Index advice

`sta.index_advice()` does not emit findings — it emits **candidates**.

| Column | Meaning |
|---|---|
| `relation` | the relation the index would be created on |
| `columns` | the candidate columns |
| `suggested_ddl` | the ready-to-run `CREATE INDEX CONCURRENTLY` statement |
| `rationale` | why the column was chosen, with the numbers |
| `estimated_benefit` | the expected effect |
| `estimated_cost` | the price |
| `confidence` | `HIGH`, `MEDIUM` or `LOW` |
| `validation_steps` | how to check it |

**The rule.** A column is proposed only when

1. it appears in the filter of a sequential scan in the plan **or in the
   condition of a join**,
2. it is a **real column** of the relation, and
3. it is **not already the leading column** of an existing index.

Condition 3 is what keeps the tool from proposing an index that already
exists under a different name.

**The key of a join.** The condition of a join is the only place where
the key of the join is written down: a join between two relations that
have no index is read with a scan of both relations and a sort or a hash
of the join key, and the scans carry no filter at all. The advisor reads
the condition of every join of the plan (`Join Key`, `Hash Cond`,
`Merge Cond` and `Join Filter`) and proposes an index on the columns
that both sides compare.

When the condition applies a function to the column, the index is
proposed on the **column**, not on the expression, and the rationale says
so:

```
The join compares (md5((e.employee_id)::text)) with (md5((p.employee_id)::text)).
The column employee_id is a real column of employee_master, which has about
10000091 rows, and no index of the relation starts with it.  The condition
applies md5() to the column, so an index on the column cannot serve it until
the condition is rewritten to compare the columns directly; if the condition
keeps the function, the index has to be built on the expression:
CREATE INDEX CONCURRENTLY idx_employee_master_employee_id_md5
    ON public.employee_master (md5(employee_id));
```

The rewrite rule `FUNCTION_WRAPPED_JOIN_KEY` removes the function from
both sides of the condition, which is what makes the index on the column
usable.

---

## 4b. Rewrite rules

`sta.rewrite_advice()` does not emit findings about the *system* — it
emits findings about the *text* of a statement, and it emits the
**rewritten statement** that fixes the problem.

```sql
SELECT pattern, evidence, recommendation, validation_steps
FROM   sta.rewrite_advice('SELECT * FROM orders WHERE lower(customer_name) = ''x''');
```

```sql
SELECT * FROM sta.rewrite_statement(
    'SELECT * FROM orders WHERE lower(customer_name) = ''x''');
-- original_sql | rewritten_sql | applied | changed
```

| Rule | Severity | What it means | The rewrite it produces |
|---|---|---|---|
| `IMPLICIT_CAST` | HIGH | The filtered column is cast to `text` (`col::text = 'x'`), so an index on the column cannot be used. | The cast is removed and the literal is cast to the column's own type. |
| `NON_SARGABLE_PREDICATE` | HIGH | A function is applied to the filtered column (`lower(col) = 'x'`, `date(ts) = '…'`), so a B-tree index on the column cannot be used. | The function is removed from the column side, or the expression is moved to a sargable form. |
| `FUNCTION_WRAPPED_JOIN_KEY` | HIGH | The same function is applied to the columns of **both** sides of a join (`md5(a.id::text) = md5(b.id::text)`), so it is computed once for every row of both relations and the columns cannot be indexed. | The function is removed from both sides, so the columns are compared directly (`a.id = b.id`). The confidence is MEDIUM, because a function that is not injective (such as `md5`) can give the same result for two different values; the comparison of the rows before and after the rewrite proves whether that happens in this data. |
| `LEADING_WILDCARD_LIKE` | HIGH | The pattern starts with `%` (`col LIKE '%x%'`), so a B-tree index cannot be used. | A trigram index on the column is proposed (`CREATE EXTENSION IF NOT EXISTS pg_trgm;` plus the `CREATE INDEX`). |
| `OR_TO_IN` | MEDIUM | The same column is tested twice with `OR` (`col = a OR col = b`), which the planner cannot serve with one index lookup. | The `OR` becomes an `IN` list on the column. |
| `NOT_IN_TO_NOT_EXISTS` | MEDIUM | `NOT IN (SELECT …)` is evaluated as a hashed anti-join over the whole subquery. | The predicate becomes `NOT EXISTS` with a correlated subquery (the NULL semantics are checked first). |
| `SELECT_STAR` | MEDIUM | The statement reads every column, including the ones it does not use. | The column list is replaced by the columns the statement actually uses. |
| `OFFSET_PAGINATION` | MEDIUM | The statement skips rows with `OFFSET`, so the cost of a page grows with its depth. | A keyset condition on the sort key is added (`WHERE key > last_key ORDER BY key LIMIT n`). |
| `UNION_TO_UNION_ALL` | LOW | `UNION` without `ALL` forces a duplicate elimination. | `UNION ALL` — but only after the branches are known to be disjoint. |

Every rule is applied by one function, in one pass, in the order above.
`sta.rewrite_statement()` returns the original text, the rewritten text,
the list of rules that fired (`applied`) and a `changed` flag, so the
rewrite can be reviewed before it is used.

---

## 4c. Action types

`sta.action_plan()` turns findings and candidates into **actions**: the
smallest set of statements that make the next run of the workload better.
`sta.action_script()` renders the same actions as a runnable SQL script.

| Action | Priority | Produced from | What it is |
|---|---|---|---|
| `VACUUM_ANALYZE` | 5 | `NEVER_VACUUMED`, `HIGH_DEAD_TUPLES` | `VACUUM (ANALYZE) <relation>;` |
| `ANALYZE` | 10 | `NEVER_ANALYZED`, `STALE_STATISTICS` | `ANALYZE <relation>;` |
| `CREATE_INDEX` | 20 | `sta.index_advice()` | The ready-to-run `CREATE INDEX CONCURRENTLY …` statement, with the `CREATE EXTENSION IF NOT EXISTS pg_trgm;` prefix when the index needs `pg_trgm`. |
| `REWRITE` | 30 | `sta.rewrite_advice()` | The complete rewritten statement, ready to replace the original. |

```sql
SELECT action_type, priority, object_name, action_sql
FROM   sta.action_plan(p_sql => 'SELECT * FROM orders WHERE …', p_limit => 50);
```

When `p_sql` is supplied, the actions that belong to *that* statement
(`CREATE_INDEX` and `REWRITE`) are always returned, even when the limit
is reached — the workload-wide statistics actions are the ones the limit
applies to.

The script is written so that it can be run as-is:

```bash
./scripts/pg_sta_ctl script "SELECT * FROM orders WHERE …" > fix.sql
```

Every statement in it is terminated, and a statement whose text cannot be
determined is emitted as a comment, so the script never fails halfway
through.

---

## 5. Validation kinds

`sta.validation_steps(p_kind)` returns the procedure for a kind of
change. Every finding carries the steps for its kind, so the advice and
the procedure cannot drift apart.

| Kind | Procedure |
|---|---|
| `analyze` | Run `ANALYZE` on the affected relation. Re-run `EXPLAIN (ANALYZE)` and confirm the planner estimate now matches the actual row count. Check `pg_stat_statements` for the statement and confirm `total_exec_time` did not regress. |
| `vacuum` | Run `VACUUM (ANALYZE)` on the affected relation. Confirm `n_dead_tup` dropped and the visibility map was updated. Re-run the workload and compare execution time and buffer counts. |
| `index` | Capture a baseline with `EXPLAIN (ANALYZE, BUFFERS)` and record the execution time and buffer counts. Create the candidate index (use `CONCURRENTLY` in production) and re-run the same `EXPLAIN (ANALYZE, BUFFERS)`. Confirm the access path changed (Seq Scan → Index Scan) and that the buffer reads dropped. Measure application-level latency over a representative window, before and after. Keep the index only if the improvement is repeatable and the write overhead is acceptable. |
| `config` | Capture a baseline with `EXPLAIN (ANALYZE, BUFFERS)` and record the execution time and buffer counts. Apply the change. Capture `EXPLAIN (ANALYZE, BUFFERS)` after the change. Confirm both the plan shape and the execution time improved. |
| `plan` | Capture a baseline with `EXPLAIN (ANALYZE, BUFFERS)` and record the execution time and buffer counts. Apply the change. Capture `EXPLAIN (ANALYZE, BUFFERS)` after the change. Confirm both the plan shape and the execution time improved. |
| `workload` | Record the current mean and total execution time for the statement. Apply the change. Let the workload run for a comparable period. Compare mean and total execution time and the buffer hit ratio. |

---

## 6. Verdicts

`sta.validate()` returns one of six verdicts. See
[validation.md](validation.md) for the full methodology.

| Verdict | Meaning |
|---|---|
| `RECOMMENDED` | The plan changed, the row counts match and the candidate was at least 5 % faster. |
| `REJECTED` | The plan changed and the candidate was at least 5 % slower. |
| `NO_SIGNIFICANT_CHANGE` | The plan changed but the timing difference is below 5 %. |
| `NOT_USED` | The plan signature did not change: the planner did not pick the index. The timing difference is noise. |
| `NOT_COMPARABLE` | The two runs returned different row counts. The measurement is meaningless. |
| `ROWS_DIFFER` | The rewritten statement returns different rows than the original. |
| `NO_CHANGE_NEEDED` | No change is recommended for this statement. |
| `ERROR` | The candidate run failed. See `notes`. |

---

## 7. Thresholds

| Threshold | Default | Unit |
|---|---|---|
| `seq_scan_min_rows` | 1000 | rows |
| `estimate_mismatch_factor` | 10 | x |
| `sort_spill_min_kb` | 1024 | kB |
| `high_mean_exec_time_ms` | 100 | ms |
| `high_frequency_calls` | 100 | calls |
| `low_cache_hit_pct` | 90 | % |
| `min_shared_blks_read` | 1000 | blocks |
| `min_temp_blks_written` | 1000 | blocks |
| `analyze_scale_factor` | 0.1 | ratio |
| `analyze_base_threshold` | 50 | rows |
| `dead_tuple_ratio` | 0.2 | ratio |
| `dead_tuple_min` | 1000 | tuples |
| `min_rows_removed_by_filter` | 1000 | rows |
| `nested_loop_max_loops` | 1000 | loops |
| `high_total_cost` | 10000 | cost |
| `high_execution_time_ms` | 1000 | ms |
| `snapshot_growth_min_rows` | 1000 | rows |
| `index_idle_min_scans` | 100 | scans |

```sql
UPDATE sta.threshold SET value = 500 WHERE name = 'high_frequency_calls';
```
