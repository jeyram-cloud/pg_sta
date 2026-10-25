# Using pg_sta on PostgreSQL 17

This is the operational guide: how to build the extension, install it into a
PostgreSQL 17 cluster, create the extension and use the advisor safely.

Everything below is written for **PostgreSQL 17** (verified on 17.11,
AlmaLinux 9 aarch64). It also works on 16 and 18 with minor adjustments
noted in [Compatibility](#compatibility).

---

## 0. What you get

`pg_sta` answers the questions an Oracle SQL Tuning Advisor answers, using
only the extension interfaces PostgreSQL provides:

| Question | Function |
|---|---|
| Which statements consume the most execution time? | `sta.workload_advice()` |
| Which statements run most often? | `sta.workload_advice()` |
| Which statements are slow per call? | `sta.workload_advice()` |
| Are table statistics missing or stale? | `sta.stats_advice()` |
| Are tables accumulating dead tuples? | `sta.stats_advice()` |
| Could an index improve this query? | `sta.index_advice()` |
| Is a sequential scan reasonable for this table? | `sta.plan_advice()` |
| Are joins, filters, sorts or aggregations expensive? | `sta.plan_advice()` |
| Are estimates far from reality? | `sta.plan_advice()` |
| Which recommendations are worth testing? | `sta.recommendations()` |
| How do I validate a proposed change? | `sta.validate()` |
| Did the change help, without regressions? | `sta.validate()` |

Every finding carries the same envelope: **what was observed**, **what to
do**, **the expected benefit**, **the cost**, and **the exact steps to
validate it**.

---

## 1. Prerequisites

| Requirement | Version | How to check |
|---|---|---|
| PostgreSQL | 17.x | `pg_config --version` |
| Server headers | 17.x | `pg_config --includedir-server` exists |
| Compiler | gcc/clang | `gcc --version` |
| PGXS | matching | `pg_config --pgxs` |
| `pg_stat_statements` | 17.x | `CREATE EXTENSION pg_stat_statements;` |

On AlmaLinux 9 the packages are:

```bash
sudo dnf install -y postgresql17-server postgresql17-devel gcc make
```

`pg_stat_statements` ships with the server package but must be enabled once:

```sql
-- in postgresql.conf
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = top
```

A restart is required for `shared_preload_libraries`.

---

## 2. Get the source

```bash
git clone <repository-url> pg_sta
cd pg_sta
```

Or copy the tree over SSH to the database host (this is what the developer
scripts in `scripts/` do automatically).

---

## 3. Build

The extension uses standard PGXS, so the normal PostgreSQL build machinery
is enough:

```bash
make PG_CONFIG=/usr/pgsql-17/bin/pg_config
```

Artefacts land in `src/pg_sta.so` and the SQL script stays in `sql/`.

### Build without a server

On a machine that has only the *devel* package (no running server) the same
command works — PGXS does not need a live cluster.

### Build inside the container/VM

```bash
sudo make PG_CONFIG=/usr/pgsql-17/bin/pg_config install
```

`install` places:

- `pg_sta.so` → `$(pg_config --pkglibdir)`
- `pg_sta.control` → `$(pg_config --sharedir)/extension`
- `pg_sta--0.1.0.sql` → `$(pg_config --sharedir)/extension`

---

## 4. Create the extension

```bash
sudo -u postgres psql -d postgres
```

```sql
CREATE EXTENSION pg_stat_statements;   -- workload source
CREATE EXTENSION pg_sta;                -- the advisor
```

Verify:

```sql
SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_sta','pg_stat_statements');
```

```
    extname     | extversion
----------------+------------
 pg_stat_statements | 1.10
 pg_sta         | 0.1.0
```

`pg_sta` creates its own schema `sta` with five tables and the advisory
functions. It never touches user schemas.

---

## 5. Collect a workload snapshot

`pg_stat_statements` is cumulative since the server started. `sta.collect()`
takes a **snapshot** of the current counters into `sta.workload_sample`,
`sta.table_stats_sample` and `sta.index_sample`, so you can compare
"before" and "after" a change.

```sql
-- take a snapshot
SELECT * FROM sta.collect();
```

```
 sample_id |       captured_at       | statements | tables
-----------+------------------------+------------+-------
       390 | 2026-10-25 17:33:10+00 |        358 |     24
```

Give the workload time to accumulate before you snapshot:

```sql
-- let the application run for a while, then:
SELECT pg_sleep(300);
SELECT * FROM sta.collect();
```

Snapshots are additive. `sta.reset()` empties them:

```sql
SELECT sta.reset();
```

> `sta.reset()` deletes rows from `sta.workload_sample`,
> `sta.table_stats_sample`, `sta.index_sample` and `sta.advice_run`.
> It never touches `pg_stat_statements` itself and never touches user data.

---

## 6. Get the advice

### 6.1 Everything at once

```sql
SELECT severity, category, object_name, finding, finding_text,
       recommendation, expected_benefit, estimated_cost, confidence
FROM sta.recommendations()
ORDER BY impact_score DESC, finding_id;
```

`sta.recommendations()` merges workload, plan and statistics findings into
one ranked list. Pass a statement to focus it:

```sql
SELECT * FROM sta.recommendations(
    p_sql => 'SELECT * FROM orders WHERE customer_id = 42');
```

### 6.2 Workload findings

```sql
SELECT queryid, calls, total_exec_time, mean_exec_time, time_share_pct,
       finding, finding_text, recommendation
FROM sta.workload_advice(p_min_calls => 100)
ORDER BY impact_score DESC;
```

Arguments: `(p_window, p_min_calls, p_min_total_time, p_limit)`.

### 6.3 Plan findings

```sql
SELECT node_type, node_path, finding, finding_text, evidence, recommendation
FROM sta.plan_advice(
    p_sql     => 'SELECT * FROM orders WHERE customer_id = 42',
    p_analyze => true);
```

`p_analyze => true` executes the statement so the plan contains real
row counts. It runs as the calling user, inside your transaction, and
**rolls back** — the statement must be a `SELECT`.

### 6.4 Statistics findings

```sql
SELECT object_name, finding, finding_text, recommendation
FROM sta.stats_advice(p_schema => 'public')
ORDER BY impact_score DESC;
```

`p_schema => NULL` (the default) inspects every schema.

### 6.5 Index candidates

```sql
SELECT relation, columns, suggested_ddl, rationale, estimated_benefit, confidence
FROM sta.index_advice(
    'SELECT * FROM orders WHERE customer_id = 42');
```

`pg_sta` only proposes a column when it is a real column of the relation
**and** is not already the leading column of an existing index.

### 6.6 Statement-level advice

```sql
SELECT * FROM sta.statement_advice(
    p_queryid => 6654355087745057316,
    p_analyze => true);
```

### 6.7 Snapshot differences

`sta.snapshot_diff()` compares the **two most recent** snapshots of a
schema and reports what changed between them. It is the only function
that reads `sta.table_stats_sample` and `sta.index_sample`, so it is how
you turn the collected snapshots into findings.

```sql
SELECT severity, category, object_name, finding, finding_text,
       recommendation, expected_benefit, estimated_cost, confidence
FROM sta.snapshot_diff(p_schema => 'public')
ORDER BY impact_score DESC, finding_id;
```

| Argument | Default | Meaning |
|---|---|---|
| `p_schema` | `NULL` | the schema to compare; `NULL` compares every schema |
| `p_limit` | `50` | maximum number of findings to return |

A snapshot is one `sta.collect()` call. Each call writes one
`captured_at` timestamp shared by all of its rows, so two snapshots can
be paired reliably.

**This function needs two snapshots.** Call `sta.collect()` once, let the
workload change, then call it again:

```sql
-- snapshot A
SELECT sta.collect();

-- ... the workload runs, rows are inserted, updated or deleted ...

-- snapshot B
SELECT sta.collect();

-- what changed?
SELECT * FROM sta.snapshot_diff('public');
```

The findings it can emit:

| Finding | Severity | Trigger |
|---|---|---|
| `DEAD_TUPLE_GROWTH` | MEDIUM | dead tuples appeared and were not reclaimed |
| `STATISTICS_GO_STALE` | MEDIUM | the relation changed and was not analyzed in between |
| `TABLE_GROWTH` | INFO | the relation grew by at least `snapshot_growth_min_rows` rows |
| `INDEX_NO_LONGER_USED` | LOW | the index was used before but not during the window |

### 6.8 Audit trail

The advisory functions are **read-only** — selecting from them never
writes anything. The audit trail is therefore written explicitly:

```sql
SELECT sta.record_run(
    p_scope        => 'nightly',
    p_target       => 'orders',
    p_finding_count => 12,
    p_notes        => 'after the weekly VACUUM');
```

`sta.record_run()` returns the new `run_id` and inserts one row into
`sta.advice_run`:

```sql
SELECT run_id, created_at, tool, scope, target, finding_count, notes
FROM sta.advice_run
ORDER BY run_id DESC;
```

Use it to keep a record of what the advisor said, and whether the
recommended change helped, across maintenance windows.

---

## 7. Validate a proposed change

This is the most important step: `pg_sta` never applies a change. It
*measures* a change.

```sql
SELECT verdict,
       round(baseline_ms::numeric, 3)  AS baseline_ms,
       round(candidate_ms::numeric, 3) AS candidate_ms,
       round(improvement_pct::numeric, 2) AS improvement_pct,
       plan_changed, rows_match, notes
FROM sta.validate(
    p_index_ddl => 'CREATE INDEX idx_orders_customer_id ON orders (customer_id)',
    p_sql       => 'SELECT * FROM orders WHERE customer_id = 42',
    p_iterations => 5);
```

```
    verdict    | baseline_ms | candidate_ms | improvement_pct | plan_changed | rows_match
--------------+-------------+--------------+-----------------+--------------+------------
 RECOMMENDED  |       2.643 |        0.110 |           95.84 | t            | t
```

`sta.validate()` works like this:

1. It runs the statement `p_iterations` times and records the **baseline**
   plan and timing.
2. It creates the index inside a **subtransaction** and rolls it back, so
   the database is left unchanged.
3. It runs the statement again and compares.

The verdict is one of:

| Verdict | Meaning |
|---|---|
| `RECOMMENDED` | The plan changed, the row counts match and the candidate was faster. |
| `NOT_USED` | The planner did **not** pick the index — the plan signature is unchanged. Any timing difference is noise. |
| `REJECTED` | The plan changed but the candidate was slower. |
| `NO_SIGNIFICANT_CHANGE` | The plan changed but the timing difference is within noise. |
| `NOT_COMPARABLE` | The two runs returned different row counts; the comparison is meaningless. |
| `ERROR` | The statement or the DDL failed; see `notes`. |

> The index is created in a subtransaction and rolled back. `sta.validate()`
> never leaves an index behind. The only requirement is that the calling
> user may create an index on the target relation.

---

## 8. Command line interface

`scripts/pg_sta_ctl` wraps the whole API.

```bash
# over SSH to the development VM (default)
./scripts/pg_sta_ctl --database appdb report

# against a local server
./scripts/pg_sta_ctl --local --database appdb report

# machine readable output
./scripts/pg_sta_ctl --local -d appdb -o json report > findings.json
./scripts/pg_sta_ctl --local -d appdb -o markdown report > findings.md
```

| Command | What it does |
|---|---|
| `collect` | take a workload snapshot |
| `reset` | discard the collected snapshots |
| `report [--sql SQL]` | all findings, ranked by impact |
| `workload` | workload findings only |
| `plan SQL` | plan findings for one statement |
| `stats [SCHEMA]` | statistics findings |
| `index SQL` | index candidates for one statement |
| `validate DDL SQL` | measure a proposed index against the current plan |
| `queryid SQL` | the canonical query id and its normalised text |
| `explain SQL` | the execution plan as JSON |
| `diff [SCHEMA]` | differences between the two most recent snapshots of a schema |
| `record SCOPE [TARGET]` | record an advisory run in the audit trail |
| `catalog` | the catalogue of every finding the advisor knows |
| `server-info` | version and configuration of the server |
| `install` | build and install the extension |
| `regress` | run the regression suite |
| `qa` | run the QA suite |

Connection settings come from the environment:

| Variable | Default | Meaning |
|---|---|---|
| `PG_STA_HOST` | `127.0.0.1` | SSH host of the database server |
| `PG_STA_SSH_PORT` | `2201` | SSH port |
| `PG_STA_SSH_KEY` | `~/.vagrant.d/insecure_private_key` | SSH private key |
| `PG_STA_PGDATABASE` | `postgres` | default database |

---

## 9. Tuning the thresholds

Every decision threshold lives in `sta.threshold`, so the advisor can be
calibrated for your workload without recompiling.

```sql
SELECT * FROM sta.threshold ORDER BY name;
```

| Threshold | Default | Meaning |
|---|---|---|
| `seq_scan_min_rows` | 1000 | Relation size above which a sequential scan is reported |
| `estimate_mismatch_factor` | 10 | Plan/actual row ratio above which the estimate is called wrong |
| `sort_spill_min_kb` | 1024 | Sort spill size above which an external sort is reported |
| `high_mean_exec_time_ms` | 100 | Mean execution time above which a statement is reported |
| `high_frequency_calls` | 100 | Call count above which a statement is reported as frequent |
| `low_cache_hit_pct` | 90 | Buffer cache hit ratio below which the workload is reported |
| `min_shared_blks_read` | 1000 | Shared block reads above which a cache-hit ratio is meaningful |
| `min_temp_blks_written` | 1000 | Temp blocks written above which temp I/O is reported |
| `analyze_scale_factor` | 0.1 | Autovacuum scale factor assumed for staleness detection |
| `analyze_base_threshold` | 50 | Autovacuum threshold assumed for staleness detection |
| `dead_tuple_ratio` | 0.2 | Dead/live tuple ratio above which a vacuum is recommended |
| `dead_tuple_min` | 1000 | Absolute dead tuples above which a vacuum is recommended |
| `min_rows_removed_by_filter` | 1000 | Rows discarded by a filter above which an index is recommended |
| `nested_loop_max_loops` | 1000 | Actual loops above which a nested loop is reported |
| `high_total_cost` | 10000 | Total cost above which a plan node is reported |
| `high_execution_time_ms` | 1000 | Total execution time above which a plan is reported |

To raise the bar for a noisy production database:

```sql
UPDATE sta.threshold SET value = 500 WHERE name = 'high_frequency_calls';
UPDATE sta.threshold SET value = 0.05 WHERE name = 'dead_tuple_ratio';
```

To restore the defaults, re-run the extension script:

```sql
\i /usr/pgsql-17/share/extension/pg_sta--0.1.0.sql
```

### 9.1 Server settings

Two GUCs are registered by the C core. Both are `USERSET`, so they can be
changed per session or per role — not globally in `postgresql.conf`
unless you really want to.

| GUC | Default | Range | Meaning |
|---|---|---|---|
| `pg_sta.enable_analyze` | `on` | `on` / `off` | whether `sta.explain()` may execute `EXPLAIN ANALYZE` |
| `pg_sta.max_findings` | `200` | 1 – 100000 | the maximum number of rows one advisory call returns |

```sql
-- turn off statement execution for a role that may only read
ALTER ROLE readonly SET pg_sta.enable_analyze = off;
```

With `pg_sta.enable_analyze = off`, `sta.plan_advice(sql, true)` and
`sta.validate()` fall back to plan-only analysis. The findings that need
real row counts are then not reported, because the tool will not guess.

```sql
SHOW pg_sta.enable_analyze;
SHOW pg_sta.max_findings;
```

`pg_sta.max_findings` is **enforced**, not merely reported. Every
advisory call caps its result at the lower of the limit you asked for and
the GUC, so a role can be given a hard ceiling on how much advice it can
pull in one call:

```sql
SET pg_sta.max_findings = 3;
SELECT count(*) FROM sta.recommendations();   -- never more than 3
```

---

## 10. Safety guarantees

`pg_sta` is read-only by design.

| Action | Effect |
|---|---|
| `CREATE EXTENSION pg_sta` | creates schema `sta` and its own tables |
| advice functions | **read only** — they query `pg_stat_*`, `pg_catalog` and `pg_stat_statements` |
| `sta.explain(..., true)` | executes the given `SELECT` in the caller's session |
| `sta.validate()` | creates the index **in a subtransaction and rolls it back** |
| `sta.collect()` | inserts rows into `sta.workload_sample` / `sta.table_stats_sample` / `sta.index_sample` |
| `sta.record_run()` | inserts **one** row into `sta.advice_run` |
| `sta.reset()` | deletes rows from those four tables only |

Explicitly **not** done by `pg_sta`:

- no `ANALYZE`, no `VACUUM`, no `REINDEX` is ever executed;
- no index, constraint or setting is created in the database;
- no user table or schema is modified, dropped or truncated;
- no configuration file is touched;
- no `pg_stat_statements` data is deleted.

`sta.plan_advice(..., p_analyze => true)` and `sta.validate()` execute the
statement you give them. Only pass `SELECT` statements.

---

## 11. Complete worked example

```sql
-- 1. one snapshot of the current workload
SELECT * FROM sta.collect();

-- 2. what is the advisor's verdict on this statement?
SELECT severity, finding, finding_text, recommendation, expected_benefit
FROM sta.plan_advice(
    p_sql     => 'SELECT count(*) FROM orders WHERE customer_id = 42',
    p_analyze => true);

-- 3. what index would help?
SELECT relation, columns, suggested_ddl, rationale
FROM sta.index_advice('SELECT count(*) FROM orders WHERE customer_id = 42');

-- 4. does the index actually help?
SELECT verdict, baseline_ms, candidate_ms, improvement_pct, plan_changed, rows_match
FROM sta.validate(
    'CREATE INDEX idx_orders_customer_id ON orders (customer_id)',
    'SELECT count(*) FROM orders WHERE customer_id = 42',
    5);

-- 5. what else is worth knowing?
SELECT severity, category, object_name, finding, recommendation
FROM sta.recommendations()
ORDER BY impact_score DESC
LIMIT 20;
```

---

## 12. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR: extension "pg_sta" is not available` | Not installed into the PostgreSQL tree | `sudo make PG_CONFIG=... install`, then restart nothing — `CREATE EXTENSION` picks it up |
| `ERROR: could not access file "$libdir/pg_sta"` | `pg_sta.so` missing or stale | Re-run `make install`; check `pg_config --pkglibdir` |
| `ERROR: permission denied for table workload_sample` | The calling role is not the owner | Run as the extension owner, or `GRANT USAGE ON SCHEMA sta TO <role>` |
| `workload_advice()` returns nothing | `pg_stat_statements` is not loaded | `SHOW shared_preload_libraries;` — it must contain `pg_stat_statements` |
| `plan_advice()` returns nothing for a slow query | `p_analyze` was false | pass `p_analyze => true` |
| `validate()` returns `NOT_USED` | The planner ignored the index | The index does not match the predicate; check `EXPLAIN` |
| `validate()` returns `NOT_COMPARABLE` | Different row counts between runs | The statement is not deterministic; wrap it or use a stable predicate |

---

## Compatibility

| PostgreSQL | Status |
|---|---|
| 17 | Primary target. Verified on 17.11. |
| 16 | Works; the C core uses APIs available since 14. |
| 18 | Works; the query-jumble API is unchanged in 18. |
| 15 and older | Not supported — `pg_stat_statements` column names differ. |
| 19 | Planned. The advisory layer is version independent; only the C core needs the PG19 jumble/EXPLAIN changes. |

The SQL advisory layer uses no version-specific features. The C core calls
`pgstat`/jumble APIs that have been stable since PostgreSQL 14.

See [implementation.md](implementation.md) for how the pieces fit together
and [advice-catalog.md](advice-catalog.md) for the full catalogue of
findings.
