# Implementation

How `pg_sta` is put together and how data flows through it.

---

## 1. Two layers, one contract

`pg_sta` is split into two layers with a strict dependency rule:

```
┌──────────────────────────────────────────────────────────────┐
│  Layer 1 — C core            src/pg_sta.c        (903 lines) │
│                                                              │
│  Everything that needs access to server internals:           │
│    • raw query text of a statement                            │
│    • the canonical query id (jumble)                          │
│    • literal-free normalisation of the statement             │
│    • a JSONB execution plan                                  │
│    • server version and configuration                         │
└──────────────────────────┬───────────────────────────────────┘
                           │  narrow C ABI (5 functions)
┌──────────────────────────▼───────────────────────────────────┐
│  Layer 2 — SQL advisory engine   sql/pg_sta--0.1.0.sql      │
│                                                     (2070 lines)│
│  Everything that is policy:                                   │
│    • which observations matter                                │
│    • how severe they are                                      │
│    • what to recommend                                        │
│    • how to validate                                          │
└──────────────────────────────────────────────────────────────┘
```

The C core **never makes a recommendation**. It only reports facts. The SQL
layer **never touches a server internal** — it only reads catalogs and the
values the C core produced. This split is what keeps the interesting part
(policy) in a language where it can be read, tested and changed without a
compiler, and keeps the fragile part (server internals) as small as
possible.

---

## 2. The C core (`src/pg_sta.c`)

Five exported SQL-callable functions, declared in `pg_sta.control` as
`MODULE_PATHNAME` so they resolve to `pg_sta.so`.

### 2.1 `pg_sta_queryid(text) → bigint`

Returns the **canonical query id** of a statement.

The id is computed by PostgreSQL's own query jumble mechanism
(`pgstat_get_my_query_id` / `GenerateQueryId`), so the value matches what
`pg_stat_statements.queryid` contains for the same statement. That
alignment is the whole point: it is what lets `pg_sta` join a statement it
was handed with the workload statistics that `pg_stat_statements`
recorded for it.

Implementation notes:

- The statement is parsed with `pg_parse_query()` inside a `MemoryContext`
  that is reset after the call, so a parse error surfaces as a normal
  PostgreSQL error rather than a crash.
- A statement that cannot be jumbled (utility commands, or a parse that
  fails) returns `NULL` rather than a fabricated number.

### 2.2 `pg_sta_queryid_normalized(text) → text`

Returns the statement with its **constants replaced by parameters**.

```
SELECT * FROM orders WHERE customer_id = 42
   →  SELECT * FROM orders WHERE customer_id = $1
```

This is the "shape" of a statement. Two statements that differ only in
their literals have the same shape, which is what makes it possible to say
*"this template is slow"* rather than *"this one string was slow"*.

The implementation is adapted from `pg_stat_statements`'s
`pgss_store`/`JumbleQuery` normalisation, with two deliberate differences:

- it never writes to `pg_stat_statements` — it returns the normalised text
  to the caller instead;
- the constant-length filling step uses `fill_constant_lengths()` from
  `pg_stat_statements` semantics, so a literal of unknown length (a
  function call) is left in place rather than replaced by a placeholder
  that could not be substituted back.

### 2.3 `pg_sta_explain(text, boolean) → jsonb`

Runs `EXPLAIN (FORMAT JSON)` on the given statement and returns the
result as `jsonb`.

- `p_analyze = false` → `EXPLAIN (FORMAT JSON)`. Cheap, safe, no execution.
- `p_analyze = true` → `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`. Executes
  the statement.

Safety checks performed before execution:

| Check | Why |
|---|---|
| the statement must parse | a bad statement must not reach the executor |
| the command type must be `SELECT` (or `EXPLAIN` of a select) | `pg_sta` must never modify data |
| the statement must be *analyzable* | `EXPLAIN ANALYZE` refuses utility commands anyway; catching it early gives a better message |

When `p_analyze = true`, the statement runs **inside the caller's
transaction and with the caller's rights**. A `SELECT` is harmless, which
is why the function refuses anything else.

The result is `jsonb`, not text, so the SQL layer can address
`plan->0->'Plan'->'Node Type'` directly instead of parsing text.

### 2.4 `pg_sta_server_info() → jsonb`

Returns a JSON document with the server version, the `compute_query_id`
setting, whether query ids are enabled, whether `pg_stat_statements` is
installed, the extension version, and the two GUCs that control the
advisor:

| GUC | Default | Meaning |
|---|---|---|
| `pg_sta.enable_analyze` | `on` | whether `EXPLAIN ANALYZE` may be used |
| `pg_sta.max_findings` | `200` | the maximum number of findings one call may return — **enforced** by every advisory function |

---

## 3. The SQL advisory engine (`sql/pg_sta--0.1.0.sql`)

### 3.1 Schema and objects

The extension installs its own schema `sta` with:

| Table | Written by | Read by |
|---|---|---|
| `sta.workload_sample` | `sta.collect()` | `sta.workload_advice()` |
| `sta.table_stats_sample` | `sta.collect()` | `sta.snapshot_diff()` |
| `sta.index_sample` | `sta.collect()` | `sta.snapshot_diff()` |
| `sta.advice_run` | `sta.record_run()` | audit trail |
| `sta.threshold` | the extension script | every advice function |

The advisory functions are **read-only**. Selecting from
`sta.recommendations()` never writes a row. The audit trail is written
only by an explicit call to `sta.record_run()`, so the caller decides
what counts as an advisory run.

Public functions:

| Function | Returns |
|---|---|
| `sta.queryid(text)` | `bigint` |
| `sta.queryid_normalized(text)` | `text` |
| `sta.explain(text, boolean)` | `jsonb` |
| `sta.server_info()` | `jsonb` |
| `sta.identifiers(text)` | `text[]` |
| `sta.plan_signature(jsonb)` | `text` |
| `sta.statement_text(bigint)` | `text` |
| `sta.collect(bigint[])` | snapshot summary |
| `sta.reset()` | `void` |
| `sta.validation_steps(text)` | `text[]` |
| `sta.workload_advice(...)` | workload findings |
| `sta.plan_advice(text, boolean, integer)` | plan findings |
| `sta.stats_advice(text, integer)` | statistics findings |
| `sta.snapshot_diff(text, integer)` | snapshot-difference findings |
| `sta.record_run(text, text, integer, text)` | the new `run_id` |
| `sta.index_advice(text)` | index candidates |
| `sta.validate(text, text, integer)` | measurement verdict |
| `sta.recommendations(...)` | all findings, ranked |
| `sta.statement_advice(bigint, boolean)` | findings for one query id |
| `sta.explain_by_queryid(bigint, boolean)` | `jsonb` |
| `sta.advice_catalog()` | the self-describing catalogue |

### 3.1a The PostgreSQL 19 parity layer

A second group of functions reproduces the plan-advice features that
PostgreSQL 19 introduces. They live in the same `sta` schema and follow
the PostgreSQL 19 naming as closely as a schema prefix allows.

| Function | Returns | PostgreSQL 19 counterpart |
|---|---|---|
| `sta.plan_advice_string(text, boolean)` | `text` | `pg_plan_advice` |
| `sta._advice_split(text)` | `text[]` | the advice lexer |
| `sta._advice_parse(text)` | `(item, tag, targets)` | the advice parser |
| `sta.apply_advice(text)` | `text[]` | — (PG19 hooks the planner) |
| `sta.restore_advice()` | `text[]` | — |
| `sta.explain_with_advice(text, text, boolean)` | `(plan, applied, restored)` | — |
| `sta.run_with_advice(text, text, boolean)` | `jsonb` | — |
| `sta.create_stash(text)` | `void` | `pg_create_advice_stash` |
| `sta.drop_stash(text)` | `void` | `pg_drop_advice_stash` |
| `sta.set_stashed_advice(text, bigint, text)` | `void` | `pg_set_stashed_advice` |
| `sta.get_stashes()` | `(stash_name, num_entries)` | `pg_get_advice_stashes` |
| `sta.get_stash_contents(text)` | `(stash_name, query_id, advice_string)` | `pg_get_advice_stash_contents` |
| `sta.get_stashed_advice(bigint, text)` | `text` | — |
| `sta.explain_with_stashed_advice(text, bigint, text, boolean)` | `(plan, applied, restored, advice)` | — |

The tag catalogue is **data**, not code: `sta.plan_advice_tag` holds the 15
tags with their category, description and enforcement level, and
`sta.plan_advice_guc` maps each enforceable tag to the planner settings
that implement it. `sta.plan_advice_tag_view` joins the two.

Applying advice is a two-step operation that is always symmetric:

1. `sta.apply_advice(advice)` translates the advice into planner settings,
   records the previous values of the settings it changed in the
   `pg_sta.advice_state` GUC, and returns the list of settings it changed.
2. `sta.restore_advice()` puts the session back exactly as it was and
   returns the list of settings it restored.

Because the previous values are recorded rather than assumed, applying
advice twice, or applying advice after the caller has changed a setting
itself, still restores the session correctly.

The advice string is derived from a **live** plan: the statement is
explained and every node that names a relation is translated into the
advice item that reproduces it (`SEQ_SCAN(t)`, `HASH_JOIN(c)`, …). A hash
join is named after the relation that is built into the hash table, which
is the child that carries the `Hash` node — not simply the first child.
The nodes that do not name a relation (joins, gathers) are kept in the
walk as well, otherwise the join advice would be lost.

The list that `sta.apply_advice()` returns names every **distinct**
setting that was changed, in the form `TAG:guc=value`. The same advice
tag may appear more than once in one advice string (one item per
relation); the setting is still written once and reported once.

The full parity analysis — what is identical to PostgreSQL 19 and what is
an approximation forced by the absence of a planner hook — is in
[pg19-compatibility.md](pg19-compatibility.md).

### 3.2 The end-to-end data flow

```
    ┌─ application traffic ─────────────────────────────────────────┐
    │                                                              │
    ▼                                                              │
  PostgreSQL 17                                                   │
    │                                                              │
    ├── pg_stat_statements ──┐                                    │
    ├── pg_stat_user_tables ─┤                                    │
    ├── pg_stat_user_indexes ┤                                    │
    ├── pg_class / pg_index ──┤                                    │
    │                        │                                    │
    │   (1) sta.collect()  ◄──┘                                    │
    │        │                                                    │
    │        ├──► sta.workload_sample                             │
    │        ├──► sta.table_stats_sample                          │
    │        └──► sta.index_sample                                │
    │                                                              │
    │   (2) sta.explain(sql, analyze) ──► C core ──► jsonb plan     │
    │                                                              │
    │   (3) advice functions                                       │
    │        ├── sta.workload_advice()  ── workload_sample         │
    │        │       + pg_stat_statements                         │
    │        ├── sta.plan_advice()      ── explain() → plan nodes  │
    │        ├── sta.stats_advice()     ── table/index samples     │
    │        │                          + pg_class/pg_index        │
    │        └── sta.index_advice()     ── plan scans + catalog    │
    │                                                              │
    │   (4) sta.recommendations()  ── merges (3) and ranks         │
    │                                                              │
    │   (5) sta.validate(ddl, sql)  ── measure before/after        │
    │                                                              │
    ▼                                                              │
  finding set (severity, evidence, recommendation, validation steps)│
    │                                                              │
    ▼                                                              │
  scripts/pg_sta_ctl  →  text / markdown / JSON                    │
```

Step by step:

1. **Collect.** `sta.collect()` snapshots `pg_stat_statements` into
   `sta.workload_sample`, `pg_stat_user_tables` into
   `sta.table_stats_sample`, and `pg_index` joined with
   `pg_stat_user_indexes` into `sta.index_sample`. The snapshot is what
   makes "before and after" possible: `pg_stat_statements` is cumulative,
   so without a snapshot you cannot tell whether a number went up or down.

   The snapshot functions project their source views through
   `to_jsonb()`, which is how they stay compatible across PostgreSQL
   versions whose catalog columns differ (the `blk_*_time` columns were
   split in 17; the per-table block I/O columns were removed in 16).

   `sta.collect()` reports the id of the workload row it inserted. When
   `pg_stat_statements` is missing, or holds no statement for the current
   database yet, no row is inserted and the id is reported as `0` rather
   than raising an error.

2. **Explain.** `sta.explain()` calls the C core, which returns the plan as
   `jsonb`.

3. **Advise.** Each advice function walks its source and emits findings.
   A finding is a row with a fixed shape:

   ```sql
   (finding_id    integer,
    category      text,     -- workload | plan | statistics
    severity      text,     -- HIGH | MEDIUM | LOW | INFO
    confidence    text,     -- HIGH | MEDIUM | LOW
    impact_score  integer,  -- the ranking number
    finding       text,     -- the machine-readable code
    finding_text  text,     -- what was observed, in prose
    evidence      jsonb,    -- the raw numbers the finding is based on
    recommendation       text,   -- what to do
    expected_benefit     text,   -- what it buys
    estimated_cost       text,   -- what it costs
    validation_steps     text[]) -- how to check it
   ```

4. **Rank.** `sta.recommendations()` merges the three advice sources into
   one stream and orders it by `impact_score`. The score combines the
   severity with the magnitude of the observation, so a 40-second query
   with a bad plan outranks a 40-millisecond one with the same defect.

5. **Validate.** `sta.validate()` measures. See
   [validation.md](validation.md).

### 3.3 The policy layer

Three things make the advice layer *policy* rather than *mechanism*:

**Thresholds live in a table.** `sta.threshold` holds all 16 decision
thresholds with a unit and a description. An operator can recalibrate the
advisor for a workload without recompiling:

```sql
UPDATE sta.threshold SET value = 1000 WHERE name = 'high_frequency_calls';
```

**Validation steps are generated, not hard-coded.** `sta.validation_steps(p_kind)`
returns the procedure for a kind of change (`analyze`, `vacuum`, `index`,
`config`, `plan`, `workload`). Each finding carries the steps for its
kind, so the advice and the procedure can never drift apart.

**The catalogue is data.** `sta.advice_catalog()` is a table of every
finding the advisor can emit, with its default severity, the evidence
source it comes from, the recommended action and the kind of validation it
needs. The advisor reads it to decide severity, and the CLI can print it
so a user can see the whole vocabulary up front.

---

## 4. The `evidence` column

Every finding carries its own proof in a `jsonb` column. This is what
makes a finding auditable rather than merely plausible.

```sql
SELECT finding, evidence FROM sta.plan_advice(
    'SELECT * FROM big_events WHERE customer_id = 17', true);
```

```json
{
  "node_type": "Seq Scan",
  "relation": "big_events",
  "estimated_rows": 239,
  "actual_rows": 239,
  "total_cost": 4000.00
}
```

A finding you cannot check is a finding you cannot act on.

---

## 5. Ranking: `impact_score`

The score is what turns a list of findings into a work queue.

| Component | Effect |
|---|---|
| Severity | `HIGH` findings rank above `MEDIUM`, `LOW`, `INFO` |
| Magnitude | the worse the observation, the higher the score — a 40 s statement outranks a 40 ms one |
| Confidence | a `HIGH`-confidence finding outranks a `LOW`-confidence one at the same severity |
| Category | a plan defect on a hot statement outranks the same defect on a cold one |

The exact weights live in the advice functions, not in a table, because
they combine several sources. The *decision* thresholds (what counts as
"too slow", "too many rows") are in `sta.threshold`, because those are the
ones operators actually want to change.

---

## 6. Build system

Standard PGXS. `Makefile`:

```make
EXTENSION   = pg_sta
MODULE_big  = pg_sta
OBJS        = src/pg_sta.o
DATA        = sql/pg_sta--0.1.0.sql
REGRESS     = pg_sta
REGRESS_OPTS ?= --dbname=pg_sta_regress
```

```bash
make PG_CONFIG=/usr/pgsql-17/bin/pg_config              # compile
make PG_CONFIG=/usr/pgsql-17/bin/pg_config install      # install
make PG_CONFIG=/usr/pgsql-17/bin/pg_config installcheck # regression suite
make qa                                               # QA suite
```

`regression.diffs` is written by `installcheck` and is empty when the
suite passes.

---

## 7. Developer scripts

| Script | Purpose |
|---|---|
| `scripts/sync.sh` | copy the working tree to the VM over SSH (`rsync`, excluding `.git`) |
| `scripts/build.sh [target]` | run `make` on the VM; with no argument it compiles only |
| `scripts/install.sh` | `sync.sh` + `build.sh install` |
| `scripts/reload.sh` | re-create the extension on the VM |
| `scripts/psql.sh` | `psql` as the `postgres` user over SSH |
| `scripts/installcheck.sh` | sync, install and run the regression suite, then copy the diffs back |
| `scripts/pg_sta_ctl` | the command line client |

---

## 8. Test strategy

### 8.1 Regression suite

`sql/pg_sta.sql` exercises the API against a scratch schema and drops it
again. The recorded output is `expected/pg_sta.out`; `installcheck` fails
when the output differs. This catches *behavioural* changes.

### 8.2 QA suite

`test/qa_setup.sql` builds a fixture with **deliberate defects**:

| Object | Defect | Expected finding |
|---|---|---|
| `sta_qa.unanalysed` | never analyzed | `NEVER_ANALYZED` |
| `sta_qa.stale_stats` | 60 % of rows changed since the last `ANALYZE` | `STALE_STATISTICS` |
| `sta_qa.stale_stats` | 12 000 dead tuples | `HIGH_DEAD_TUPLES` |
| `sta_qa.big_events` | 120 000 rows, hot query, no supporting index | `SEQ_SCAN_ON_LARGE_TABLE` |
| `sta_qa.hot_path` | very high call count | `HIGH_FREQUENCY` |

`test/qa_assertions.sql` contains 89 assertions in a machine-readable
`assertion | expected | actual | passed` form. `test/run_qa.sh` runs the
setup, then evaluates the assertions and reports the pass count.

**Why the fixture is split into phases.** The fixture is marked with
`-- @phase N` markers and the runner executes each phase in its **own
`psql` session**. This is not cosmetic: in PostgreSQL 17 the per-backend
statistics entry is flushed into shared memory only when the backend goes
idle or the session ends, and the flush *adds deltas*. If the fixture DML
and the `ANALYZE` share one session, the later flush overwrites the
`ANALYZE`'s absolute values and the fixture no longer contains the
defects it is supposed to contain. Splitting the phases makes the
statistics deterministic. The header of `test/qa_setup.sql` explains this
in detail.

---

## 9. Performance characteristics

| Operation | Cost |
|---|---|
| `sta.collect()` | one pass over `pg_stat_statements`, `pg_stat_user_tables` and `pg_index` |
| `sta.workload_advice()` | reads the snapshot; O(statements in the window) |
| `sta.plan_advice(sql, false)` | one `EXPLAIN` — the planner only, no execution |
| `sta.plan_advice(sql, true)` | one `EXPLAIN ANALYZE` — the statement **is executed** |
| `sta.stats_advice()` | reads the snapshot; O(tables) |
| `sta.index_advice(sql)` | one `EXPLAIN` plus a catalog lookup |
| `sta.validate(ddl, sql, n)` | `2 × n` executions of the statement plus one index build that is rolled back |

The advisor is designed to be run **periodically and offline** (or at least
outside the hot path of an application), not to be called per request.

---

## 10. Extension interfaces used

`pg_sta` deliberately uses only supported extension interfaces:

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
