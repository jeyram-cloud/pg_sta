# Architecture

Component design, data model, and the design decisions behind them.

---

## 1. Design goals

1. **Explainability over cleverness.** Every finding must carry the
   evidence that produced it. A DBA must be able to disagree with a
   recommendation, and to do that they must see the numbers.
2. **Safety by construction.** The advisor cannot change a database. It
   cannot apply a recommendation, because applying it is the decision the
   DBA has to make.
3. **No promises without measurement.** A recommendation that cannot be
   validated is not a recommendation. `sta.validate()` exists so that
   "will this help?" has an answer that is a measurement, not an opinion.
4. **Calibratable.** A threshold that is wrong for one workload is wrong
   for every workload if it is hard-coded.
5. **Small C surface.** Server internals are unstable. Everything that
   does not need them stays in SQL.

---

## 2. Component map

```
                    ┌───────────────────────────────────────────┐
                    │              PostgreSQL 17                 │
                    │                                           │
   application ───▶ │  ┌──────────────┐   ┌─────────────────┐  │
                    │  │ pg_stat_     │   │ pg_stat_user_   │  │
                    │  │ statements   │   │ tables / idx    │  │
                    │  └──────┬───────┘   └────────┬────────┘  │
                    │         │                    │           │
                    └─────────┼────────────────────┼───────────┘
                              │                    │
                    (1) collect│                    │
                              ▼                    ▼
                    ┌───────────────────────────────────────────┐
                    │            sta schema (SQL)               │
                    │                                           │
                    │  workload_sample   table_stats_sample     │
                    │  index_sample      advice_run            │
                    │  threshold                                │
                    │                                           │
                    │  workload_advice()  plan_advice()         │
                    │  stats_advice()     index_advice()        │
                    │  recommendations()  validate()            │
                    │  snapshot_diff()    record_run()          │
                    │  advice_catalog()   validation_steps()    │
                    └────────────────────┬──────────────────────┘
                                         │
                          (C ABI)        │
                    ┌────────────────────▼──────────────────────┐
                    │            pg_sta.so (C core)              │
                    │  queryid  queryid_normalized              │
                    │  explain   server_info                     │
                    └───────────────────────────────────────────┘
                                         │
                                         ▼
                    ┌───────────────────────────────────────────┐
                    │           scripts/pg_sta_ctl               │
                    │            text / markdown / JSON         │
                    └───────────────────────────────────────────┘
```

---

## 3. The data model

### 3.1 Snapshot tables

`pg_stat_statements` and `pg_stat_user_tables` are **cumulative**: they
hold the totals since the server started. A cumulative counter can tell you
that a query is slow, but it cannot tell you whether it got faster or
slower, because you do not know where "now" is relative to your change.

`pg_sta` therefore takes snapshots.

| Table | Grain | Key columns |
|---|---|---|
| `sta.workload_sample` | one row per statement per snapshot | `captured_at`, `queryid`, `calls`, `total_exec_time`, `mean_exec_time`, `rows`, `shared_blks_hit/read`, `temp_blks_read/written`, `blk_read_time`, `blk_write_time`, `wal_records` |
| `sta.table_stats_sample` | one row per relation per snapshot | `captured_at`, `schemaname`, `relname`, `n_live_tup`, `n_dead_tup`, `n_mod_since_analyze`, `last_analyze`, `seq_scan`, `idx_scan`, `reltuples`, `relpages` |
| `sta.index_sample` | one row per index per snapshot | `captured_at`, `schemaname`, `tablename`, `indexname`, `indexdef`, `is_unique`, `is_primary`, `idx_scan`, `idx_tup_read`, `idx_tup_fetch` |

`sta.advice_run` is an audit trail: `run_id`, `created_at`, `scope`,
`target`, `finding_count`, `tool`, `notes`. It is written **only** by
`sta.record_run()` — the advisory functions are read-only and never
append to it.

`sta.table_stats_sample` and `sta.index_sample` are read by
`sta.snapshot_diff()`, which pairs the two most recent snapshots and
reports what changed between them: dead tuples that appeared and were not
reclaimed, statistics that went stale, tables that grew, and indexes that
stopped being used.

Two indexes support the common access paths:
`workload_sample (captured_at)`, `workload_sample (queryid)`,
`table_stats_sample (captured_at)`, `table_stats_sample (schemaname,
relname)`, `index_sample (captured_at)`.

### 3.2 The threshold table

`sta.threshold(name, value, unit, description)` holds all 16 decision
thresholds. Each advice function reads the threshold it needs instead of
hard-coding a number, so the whole advisory policy can be recalibrated
with `UPDATE` statements.

```
UPDATE sta.threshold SET value = 500 WHERE name = 'high_frequency_calls';
```

This is the single most important operator-facing knob, and it exists
because the right value is a property of the workload, not of the tool.

---

## 4. The finding contract

All three advice functions return the same row shape, so they can be
unioned and ranked together.

| Column | Type | Meaning |
|---|---|---|
| `finding_id` | `integer` | stable identifier within one call |
| `category` | `text` | `workload`, `plan` or `statistics` |
| `severity` | `text` | `HIGH`, `MEDIUM`, `LOW`, `INFO` |
| `confidence` | `text` | `HIGH`, `MEDIUM`, `LOW` |
| `impact_score` | `integer` | the ranking number |
| `finding` | `text` | the machine-readable code, e.g. `SEQ_SCAN_ON_LARGE_TABLE` |
| `finding_text` | `text` | what was observed, in prose, with the numbers in it |
| `evidence` | `jsonb` | the raw observation |
| `recommendation` | `text` | what to do |
| `expected_benefit` | `text` | what it buys |
| `estimated_cost` | `text` | what it costs |
| `validation_steps` | `text[]` | how to check it |

`workload_advice()` adds `queryid`, `query`, `calls`, `total_exec_time`,
`mean_exec_time`, `time_share_pct`.
`plan_advice()` adds `object_name`, `node_type`, `node_path`.
`index_advice()` has a different shape — it returns candidates, not
findings — with `relation`, `columns`, `suggested_ddl`, `rationale`,
`estimated_benefit`, `estimated_cost`, `confidence`, `validation_steps`.

### 4.1 Severity and confidence are different

**Severity** answers *"how much does this matter?"*.
**Confidence** answers *"how sure are we?"*.

A finding can be severe but not confident — for example, a sequential scan
on a 2 000-row table that is executed 200 000 times a second is a real
problem, but the tool cannot know the workload's cost model. Conflating
the two would let a confident-but-trivial finding outrank an uncertain
but expensive one. They are kept separate and both feed the ranking.

---

## 5. The advice sources

### 5.1 Workload advice — `sta.workload_advice()`

Reads `sta.workload_sample` (or the live `pg_stat_statements` when no
snapshot exists) and looks at:

| Finding | Evidence |
|---|---|
| `HIGH_TOTAL_TIME` | `total_exec_time` and the statement's share of the window |
| `HIGH_MEAN_EXEC_TIME` | `mean_exec_time` |
| `HIGH_FREQUENCY` | `calls` |
| `HIGH_TEMP_IO` | `temp_blks_written` |
| `LOW_CACHE_HIT_RATIO` | `shared_blks_hit / (shared_blks_hit + shared_blks_read)` |

The cache-hit ratio is only computed once the statement has read at least
`min_shared_blks_read` blocks; below that the ratio is dominated by noise.

### 5.2 Plan advice — `sta.plan_advice()`

Runs `sta.explain()` and walks the plan tree with `sta._plan_nodes()`,
which flattens the nested JSON into `(node_path, node)` pairs. Each plan
node can then be tested against a rule.

| Finding | Evidence in the plan |
|---|---|
| `SEQ_SCAN_ON_LARGE_TABLE` | `Node Type = Seq Scan` and the relation is large |
| `SEQ_SCAN_ON_SMALL_TABLE` | `Node Type = Seq Scan` and the relation is small (informational) |
| `ESTIMATE_MISMATCH` | `Plan Rows` vs `Actual Rows` |
| `ROWS_REMOVED_BY_FILTER` | `Rows Removed by Filter` |
| `NESTED_LOOP_HIGH_LOOPS` | `Actual Loops` |
| `HASH_BATCHES` | `Hash Batches` > 1 |
| `SORT_SPILLED_TO_DISK` | `Sort Method = external disk` |
| `BITMAP_LOSSY_RECHECK` | `Heap Blocks Lost` > 0 |
| `TEMP_BLOCKS_WRITTEN` | `Temp Written Blocks` > 0 |
| `HIGH_TOTAL_COST` | `Total Cost` |
| `SLOW_EXECUTION_TIME` | `Execution Time` |

Rules that need real row counts (`ESTIMATE_MISMATCH`,
`ROWS_REMOVED_BY_FILTER`, `NESTED_LOOP_HIGH_LOOPS`,
`SLOW_EXECUTION_TIME`) only fire when `p_analyze = true`. Without it the
tool cannot know the actual values, so it does not guess.

### 5.3 Statistics advice — `sta.stats_advice()`

Reads the relation statistics and the index catalogue.

| Finding | Evidence |
|---|---|
| `NEVER_ANALYZED` | `last_analyze` and `last_autoanalyze` are both NULL |
| `STALE_STATISTICS` | `n_mod_since_analyze` against `analyze_scale_factor` / `analyze_base_threshold` |
| `HIGH_DEAD_TUPLES` | `n_dead_tup` against `dead_tuple_ratio` and `dead_tuple_min` |
| `NO_PRIMARY_KEY` | no index with `indisprimary` |
| `NO_INDEXES` | no index at all on the relation |

Staleness is detected with the *same* rule autovacuum uses, so the tool
does not nag you about a table that autovacuum is already keeping fresh.

### 5.4 Index advice — `sta.index_advice()`

Derives candidates from the filters of the sequential scans in the plan:

1. Extract identifier-like tokens from the filter expression
   (`sta.identifiers()`).
2. Intersect them with the real column list of the relation
   (`pg_attribute`) — a token that is not a column is discarded.
3. Discard any column that is already the leading column of an existing
   index — an index on it would be redundant.
4. Emit the DDL, the rationale, the expected benefit and the cost.

The output is a *candidate*, never a decision.

---

## 6. The C core

Five functions, listed in [implementation.md §2](implementation.md#2-the-c-core-srcpg_stac).
The important architectural property is that **none of them makes a
judgement**. They report facts: the query id, the normalised text, the
plan, the server configuration.

The core is written defensively:

- the statement is parsed in a dedicated `MemoryContext` that is reset
  after each call;
- `pg_sta_check_select_only()` refuses anything that is not a `SELECT`
  before it can reach the executor;
- `pg_sta_check_analyzable()` refuses statements that `EXPLAIN ANALYZE`
  cannot run;
- `pg_sta_scan_params()` finds the parameter references in the raw parse
  tree for the normaliser.

Two GUCs are registered in `_PG_init()`:

| GUC | Default | Context | Meaning |
|---|---|---|---|
| `pg_sta.enable_analyze` | `on` | `PGC_USERSET` | whether `sta.explain()` may execute `EXPLAIN ANALYZE` |
| `pg_sta.max_findings` | `200` | `PGC_USERSET` | the maximum number of rows one advisory call returns (enforced) |

`_PG_init()` also calls `EnableQueryId()`, which is what makes
`sta.queryid()` agree with `pg_stat_statements.queryid` even when
`compute_query_id = auto` and nothing else has claimed the feature.

---

## 7. The interface layer

### 7.1 SQL

The whole advisory surface is available as SQL functions. A DBA can write
their own queries against `sta.workload_sample`, `sta.table_stats_sample`
and `sta.index_sample` — they are ordinary tables in an ordinary schema.

### 7.2 The command line client

`scripts/pg_sta_ctl` maps one-to-one onto the SQL API:

```
pg_sta_ctl [--database DB] [--output text|markdown|json] <command> [args]
```

It connects either to a local server (`--local`) or over SSH to a remote
one (`--ssh`, the default). Two details make it robust:

- **Dollar-quoted literals.** A user-supplied SQL statement is embedded
  with a dollar-quote tag derived from the content of the statement and
  extended until it cannot collide. A statement that itself contains
  dollar quotes is therefore safe.
- **One projection, three formats.** `text`, `markdown` and `json` are
  rendered from the *same* projection, so they can never disagree about
  what a finding says.

---

## 8. Design decisions and trade-offs

### 8.1 Snapshots instead of live counters

**Decision:** the advisor reads its own snapshot tables.

**Why:** a cumulative counter cannot express "before and after", and
"before and after" is the whole point of a tuning advisor. The cost is
that the user has to call `sta.collect()`.

**Alternative rejected:** reading `pg_stat_statements` directly. It
reports the totals since startup, which conflates the effect of a change
with the effect of everything that happened before it.

### 8.2 The C core reports, the SQL layer decides

**Decision:** no policy in C.

**Why:** policy is what changes. When a user wants "only report
sequential scans on tables above 500 000 rows", that must be a one-line
change in SQL, not a recompile. It also means the entire advisory
behaviour is covered by the SQL test suites.

### 8.3 `EXPLAIN ANALYZE` is opt-in per call

**Decision:** `p_analyze` defaults to `false` and the tool refuses
anything but a `SELECT` before executing.

**Why:** `EXPLAIN ANALYZE` *runs* the statement. A tuning advisor that
silently executed arbitrary SQL would be a liability. The `SELECT`-only
check plus the `pg_sta.enable_analyze` GUC makes the dangerous path
explicit and disableable.

### 8.4 Thresholds in a table, weights in code

**Decision:** the *decision thresholds* are in `sta.threshold`; the
*ranking weights* are in the function bodies.

**Why:** operators want to change "what counts as too slow" and do not
want to change "how findings are ordered". Separating the two keeps the
common change easy and the rare change possible.

### 8.5 `validate()` rolls the index back

**Decision:** the candidate index is created inside an exception block and
removed by the rollback.

**Why:** an advisor that leaves indexes behind is an advisor that fills
your disk. The rollback makes the function safe to run against a
production database. The trade-off is that `CREATE INDEX CONCURRENTLY` is
not possible (it cannot run in a transaction block) — the function rejects
it with a clear message rather than failing obscurely.

### 8.6 Version tolerance through `to_jsonb()`

**Decision:** the catalog views are projected through `to_jsonb()` before
the columns are read.

**Why:** PostgreSQL moved and split catalog columns between versions — the
`blk_*_time` columns in 17, the per-table block I/O columns in 16. Reading
through `to_jsonb()` means a column that does not exist is simply absent
(`NULL`) instead of being a syntax error, and the same SQL works across
versions.

### 8.7 The finding is not a verdict

**Decision:** the tool states an observation, an action, a benefit, a cost
and a validation procedure. It does not say "apply this".

**Why:** an advisor that says "apply this" is wrong often enough to be
dangerous, and the user cannot tell when it is wrong. A finding with a
validation procedure is useful even when it is wrong, because the
procedure will reveal that.

---

## 9. Extension interfaces used

| Interface | Used for |
|---|---|
| `MODULE_PATHNAME` C functions | the query jumble, EXPLAIN and server-info core |
| `pg_stat_statements` | the workload counters |
| `pg_stat_user_tables` / `pg_stat_user_indexes` | the statistics counters |
| `pg_catalog` (`pg_class`, `pg_index`, `pg_namespace`, `pg_attribute`) | relation and index metadata |
| `to_jsonb(view)` projection | version-tolerant reading of catalog views |
| A dedicated schema with its own tables | the snapshots and the thresholds |

No configuration file is read or written, no background worker is
started, no shared memory is claimed and no GUC is created outside the
extension's own namespace.

---

## 10. Known limitations

| Limitation | Consequence |
|---|---|
| The plan is analysed **per statement**, not per workload | A workload-wide access-path analysis (which index would help the most statements) is not implemented |
| `index_advice()` only considers **sequential scan filters** | An index that would help a join, an order-by or a bitmap is not proposed |
| The normaliser is **shape-based** | Two statements with the same shape but different semantics are merged; the SQL layer avoids this by keeping `queryid` and the raw text alongside the normalised text |
| `sta.collect()` requires `pg_stat_statements` for workload data | Without it, only the plan and statistics sources work |
| The ranking weights are **not** operator-tunable | Only the decision thresholds are |
| `sta.table_stats_sample` and `sta.index_sample` are written but not read by the advice functions | The snapshots exist for future before/after comparisons; today the statistics advice reads the live catalogs |

---

## 11. Extension roadmap

| Idea | Notes |
|---|---|
| PostgreSQL 19 parity | The advisory layer is version independent; only the C core needs the PG19 jumble/EXPLAIN changes |
| Workload-wide index ranking | Rank candidates by how many statements in the window they would help |
| `pg_sta--1.0.sql` upgrade path | The current extension has no upgrade script; it needs one before a version bump |
| Reading the snapshot tables in the advice functions | This is what would make the before/after comparison a first-class feature |
