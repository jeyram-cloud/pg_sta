# pg_sta — PostgreSQL SQL Tuning Advisor

`pg_sta` is an open-source SQL Tuning Advisor for **PostgreSQL 17**, in the
spirit of Oracle's SQL Tuning Advisor. It inspects the workload, the
execution plans and the table statistics of a database and returns
**ranked, explainable** tuning recommendations — each one with the evidence
that produced it, the expected benefit, the cost, and the exact steps to
validate it.

`pg_sta` never changes your database on its own. It advises; you decide;
`sta.validate()` measures whether the change you are considering actually
helps.

---

## Why

DBA tooling usually answers one of two questions badly: *"what is slow?"*
(raw `pg_stat_statements` output) or *"what should I do?"* (a rewrite rule
of thumb). The gap between them is where most tuning goes wrong — an index
added for a query that the planner never used, an `ANALYZE` that was already
running, a `work_mem` bump that moved the problem somewhere else.

`pg_sta` closes the gap by always answering five questions together:

1. **What was observed?** — the plan node, the counter, the catalog value.
2. **What should be done?** — a concrete action.
3. **What does it buy?** — the expected benefit, stated honestly.
4. **What does it cost?** — the price, stated honestly.
5. **How do I check?** — a runnable validation procedure.

And it never promises that a recommendation will help. A finding that
cannot be validated is not a recommendation.

---

## Features

| Area | Capability |
|---|---|
| **Workload** | Total time, mean time, call frequency, time share, temp I/O, buffer cache hit ratio — from `pg_stat_statements` |
| **Plan** | Sequential scans, estimate/actual mismatch, nested-loop explosions, hash batching, sort spills, bitmap rechecks, temp blocks, high cost |
| **Statistics** | Never analyzed, stale statistics, dead-tuple bloat, missing primary key, missing indexes |
| **Index** | Index candidates derived from the filters of real sequential scans, with ready-to-run DDL |
| **Action plan** | `sta.action_plan()` turns the findings into runnable commands — `CREATE INDEX CONCURRENTLY …`, `ANALYZE`, `VACUUM (ANALYZE)` and the rewritten statement — ordered by priority |
| **Action script** | `sta.action_script()` returns the whole plan as one commented, runnable file: every step carries its reason, its benefit, its cost and its validation steps |
| **Rewrites** | `sta.rewrite_statement()` applies every rewrite rule to a statement at once and returns the complete, formatted SQL — `NOT IN` → `NOT EXISTS`, `OR` → `IN`, `col::text` → `col`, `OFFSET` → keyset pagination, `SELECT *` → the real columns |
| **Validation** | `sta.validate()` measures a candidate index against the current plan in a rolled-back subtransaction and returns a verdict |
| **Before / after** | `sta.plan_before_after()` shows the plan of a statement **before** a change and **after** it, with the times and the buffer counts of both; `sta.before_after_benefit()` adds the benefit, the verdict and the plan change matrix |
| **Before / after report** | `sta.before_after_report()` measures **every** recommended change against the statement it belongs to and returns the plan before, the plan after and the gain — for the whole workload, with every change rolled back |
| **Before / after detail** | `sta.before_after_detail()` measures one statement against one change and returns the whole detail row: both plans, both readings, the gain and its basis, the buffer split, the row-by-row comparison and the assumption checks |
| **Plan reading** | `sta.plan_explanation()` turns a plan into plain English — what each step does, what it costs and where the time goes; `sta.statement_explanation()` adds the statement text and the top three findings |
| **Statement ids** | `sta.sql_id()` and `sta.sql_hash()` give the Oracle-style `SQL_ID` and `SQL_HASH`; `sta.queryid_info()` gives the `pg_stat_statements` query id, the normalised text and the workload of the statement |
| **Explainability** | Every finding carries structured `evidence` (JSONB), not just prose |
| **Clear errors** | A statement that names a relation of another database is reported as `sta.explain: the statement refers to a relation or a column that does not exist here`, with the message of the server as the detail and the connected database in the hint |
| **Calibratable** | All 16 decision thresholds live in `sta.threshold` and can be tuned without recompiling |
| **Catalogue** | `sta.advice_catalog()` is the self-describing catalogue of every finding the advisor can emit |
| **PG19 plan advice** | `sta.plan_advice_string()` generates PostgreSQL 19 style advice from a plan; the advice round-trips — applying it reproduces the plan it was generated from |
| **PG19 advice stash** | `sta.create_stash()`, `sta.set_stashed_advice()`, `sta.get_stash_contents()` and friends reproduce the PostgreSQL 19 `pg_stash_advice` API on PostgreSQL 17 |
| **Interfaces** | SQL functions, a JSONB plan API, and a command line client (`scripts/pg_sta_ctl`) with text/markdown/JSON output |

---

## Quick start

```bash
# 0. get the source
git clone https://github.com/jeyram-cloud/pg_sta.git
cd pg_sta

#    no git? download the archive instead
#    curl -L -o pg_sta.tar.gz \
#      https://github.com/jeyram-cloud/pg_sta/archive/refs/heads/main.tar.gz
#    tar -xzf pg_sta.tar.gz && cd pg_sta-main

# 0b. run every command from the directory that holds the pg_sta source
#     tree -- this is where the Makefile lives.  A Makefile is NOT in
#     /var/lib/pgsql or in /usr/pgsql-17/bin, so `make` there fails with
#     "No targets specified and no makefile found".
#     On the VM the tree lives in /home/vagrant/pg_sta.

# 1. build and install into your PostgreSQL 17 tree
make PG_CONFIG=/usr/pgsql-17/bin/pg_config
sudo make PG_CONFIG=/usr/pgsql-17/bin/pg_config install

# 2. enable it
sudo -u postgres psql -d postgres -c "CREATE EXTENSION pg_sta;"
sudo -u postgres psql -d postgres -c "CREATE EXTENSION pg_stat_statements;"

# 3. snapshot the workload
sudo -u postgres psql -d appdb -c "SELECT * FROM sta.collect();"

# 4. ask for advice
sudo -u postgres psql -d appdb -c "
  SELECT severity, category, finding, finding_text, recommendation
  FROM sta.recommendations()
  ORDER BY impact_score DESC LIMIT 20;"

# 4b. turn the findings into the changes that implement them
sudo -u postgres psql -d appdb -c "
  SELECT action_type, priority, object_name, action_sql
  FROM sta.action_plan() ORDER BY priority, action_id;"

# 4c. get the whole plan as one commented, runnable script
sudo -u postgres psql -X -tA -d appdb \
  -c "SELECT sta.action_script(NULL, 'cumulative', false, 100);" > /tmp/pg_sta_actions.sql

# 4d. see the plan before and after a change, and how much it gains
sudo -u postgres psql -X -d appdb -c "
  SELECT verdict, before_ms, after_ms, improvement_pct, node_changes
  FROM sta.before_after_benefit(
      'SELECT * FROM order_details WHERE order_id = 500000',
      'CREATE INDEX idx_od_order_id ON order_details (order_id)');"

# 4d2. the plan before and after the change, for every statement of the workload
sudo -u postgres psql -X -d appdb -c "
  SELECT report_id, relation, change_type, measurement,
         improvement_pct, verdict
  FROM sta.before_after_report(NULL, 'window', 3, 10, true);"

# 4e. the Oracle-style identifiers of a statement
sudo -u postgres psql -X -d appdb -c "
  SELECT * FROM sta.queryid_info('SELECT * FROM orders WHERE customer_id = 42');"

# 5. compare two snapshots and record the run
sudo -u postgres psql -d appdb -c "SELECT * FROM sta.collect();"
sudo -u postgres psql -d appdb -c "SELECT * FROM sta.snapshot_diff('public');"
sudo -u postgres psql -d appdb -c "SELECT sta.record_run('manual', 'appdb', 0, 'first run');"
```

Or from the command line:

```bash
./scripts/pg_sta_ctl --database appdb report

# the change itself, from the command line
./scripts/pg_sta_ctl --database appdb actions "SELECT * FROM orders WHERE customer_id = 42"
./scripts/pg_sta_ctl --database appdb script  "SELECT * FROM orders WHERE customer_id = 42" > fix.sql

# the plan before and after a change, and the benefit of the change
./scripts/pg_sta_ctl --database appdb before-after \
    "SELECT * FROM order_details WHERE order_id = 500000" \
    "CREATE INDEX idx_od_order_id ON order_details (order_id)"

# the plan before and after the change, for every statement of the workload
./scripts/pg_sta_ctl --database appdb --statements 5 before-after-report

# the identifiers of a statement, the Oracle way
./scripts/pg_sta_ctl --database appdb sqlid "SELECT * FROM orders WHERE customer_id = 42"
```

No database to try it on? Load the demo fixture — two tables, a captured
workload and a ready-made plan-advice example:

```bash
./scripts/load_sample_data.sh --database appdb
./scripts/pg_sta_ctl --database appdb collect
./scripts/pg_sta_ctl --database appdb report
```

The command line client picks its transport automatically: it talks to the
development VM over SSH when the VM is reachable, and falls back to the
local `psql` client when the script runs on the database host itself. Use
`--ssh` or `--local` to force one of the two.

**Full step-by-step instructions: [docs/usage.md](docs/usage.md)**

### Download options

| Method | Command |
|---|---|
| git over HTTPS | `git clone https://github.com/jeyram-cloud/pg_sta.git` |
| git over SSH | `git clone git@github.com:jeyram-cloud/pg_sta.git` |
| tarball | `curl -L -o pg_sta.tar.gz https://github.com/jeyram-cloud/pg_sta/archive/refs/heads/main.tar.gz && tar -xzf pg_sta.tar.gz` |
| pin a commit | `curl -L -o pg_sta.tar.gz https://github.com/jeyram-cloud/pg_sta/archive/<commit-sha>.tar.gz` |
| copy to a DB host | `scp -r pg_sta vagrant@<db-host>:/home/vagrant/` |

The build must run **on the machine that owns the PostgreSQL installation**,
because the artefacts are installed into that PostgreSQL tree. See
[docs/usage.md §2](docs/usage.md#2-get-the-source) for all three methods.

---

## PostgreSQL 19 plan advice and advice stash

PostgreSQL 19 introduces two plan-advice features: `pg_plan_advice`, which
describes how a query should be planned, and `pg_stash_advice`, which stores
such advice per query id so that it can be applied later. `pg_sta`
reproduces both on PostgreSQL 17.

```sql
-- generate PostgreSQL 19 style advice from a plan
-- (the tables must exist in the database: the plan is read from the
--  live catalogue, exactly like PostgreSQL 19 does)
SELECT sta.plan_advice_string(
    'SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id
      WHERE c.region = ''eu''');
--  HASH_JOIN(c) SEQ_SCAN(o) SEQ_SCAN(c)

-- plan a statement with that advice applied, then restore the session
SELECT * FROM sta.explain_with_advice(
    'HASH_JOIN(c) SEQ_SCAN(o) SEQ_SCAN(c)',
    'SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id
      WHERE c.region = ''eu''');
--  plan | applied | restored

-- store advice for a query id in a stash, exactly like pg_stash_advice
SELECT sta.create_stash('nightly');
SELECT sta.set_stashed_advice('nightly',
       sta.queryid('SELECT * FROM orders WHERE customer_id = 42'),
       'SEQ_SCAN(orders)');
SELECT * FROM sta.get_stash_contents('nightly');
--  stash_name | query_id | advice_string
```

A ready-made fixture with `orders`, `customers` and a captured workload is
installed by `scripts/load_sample_data.sh`; see
[docs/usage.md](docs/usage.md#5-a-database-to-try-it-on).

```bash
./scripts/pg_sta_ctl --database appdb plan-advice "SELECT * FROM orders"
./scripts/pg_sta_ctl --database appdb stash create nightly
```

The advice language, the tag vocabulary, the stash API and the error
behaviour are the same as in PostgreSQL 19. The enforcement is an
approximation, because PostgreSQL 17 has no planner hook: advice is
expressed through the planner's `enable_*` settings, which are
session-wide. The exact list of what is identical and what is approximated
is in **[docs/pg19-compatibility.md](docs/pg19-compatibility.md)**.

---

## From findings to changes: the action plan and the action script

A finding that does not say what to change is only half an answer. `pg_sta`
therefore also produces the **change itself**, as a runnable statement:

```sql
SELECT action_type, priority, object_name, action_sql
FROM sta.action_plan(NULL, 'cumulative', false, 100);
```

```
 action_type   | priority |      object_name      |                 action_sql
---------------+----------+------------------------+--------------------------------------------------
 VACUUM_ANALYZE |        5 | public.sta_demo       | VACUUM (ANALYZE) public.sta_demo;
 ANALYZE        |       10 | public.sta_demo       | ANALYZE public.sta_demo;
 CREATE_INDEX   |       20 | public.orders         | CREATE INDEX CONCURRENTLY idx_orders_customer_id ON public.orders (customer_id);
 CREATE_INDEX   |       20 | public.customers      | CREATE EXTENSION IF NOT EXISTS pg_trgm;
                |          |                        | CREATE INDEX CONCURRENTLY idx_customers_email_trgm ON public.customers USING gin (email gin_trgm_ops);
 REWRITE        |       30 | orders                | SELECT order_id, customer_id, order_date FROM orders WHERE NOT EXISTS (SELECT 1 FROM customers WHERE …)
```

`sta.action_script()` returns the whole plan as one file that can be
reviewed and then run as it is:

```bash
sudo -u postgres psql -X -tA -d appdb \
  -c "SELECT sta.action_script(NULL, 'cumulative', false, 100);" > /tmp/pg_sta_actions.sql
less /tmp/pg_sta_actions.sql
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d appdb -f /tmp/pg_sta_actions.sql
```

Every step of the script states why it is there, what it buys, what it
costs, how risky it is and how to check that it worked:

```
-- ---------------------------------------------------------------------------
-- 11. [REWRITE] orders
--
-- Why:     The statement reads every column of orders, including the columns it does not use. …
--          The statement uses NOT IN with a subquery.  NOT IN is evaluated as a hashed anti-join …
--
-- Original statement:
--   SELECT *
--   FROM orders
--   WHERE customer_id NOT IN (SELECT customer_id FROM customers WHERE email LIKE '%@example.com')
--
-- Rewritten statement (NOT_IN_TO_NOT_EXISTS, SELECT_STAR):
SELECT order_id,
       customer_id,
       order_date
FROM orders
WHERE NOT EXISTS (SELECT 1 FROM customers WHERE email LIKE '%@example.com' AND customers.customer_id = orders.customer_id);
```

The rewrites come from `sta.rewrite_statement()`, which applies **every**
rule to a statement and returns the complete, formatted SQL:

```sql
SELECT original_sql, rewritten_sql, applied, changed
FROM sta.rewrite_statement(
    'SELECT * FROM orders WHERE customer_id NOT IN (SELECT customer_id FROM customers)');
```

The rules are `IMPLICIT_CAST`, `NON_SARGABLE_PREDICATE`, `OR_TO_IN`,
`NOT_IN_TO_NOT_EXISTS`, `UNION_TO_UNION_ALL`, `LEADING_WILDCARD_LIKE`,
`SELECT_STAR` and `OFFSET_PAGINATION`. Each one lists the assumption it
depends on — `NOT IN` returns no rows at all when the subquery produces a
single `NULL`, `NOT EXISTS` does not — so the rewrite can be judged before
it is used.

The full guide: [docs/usage.md §6.9–6.11](docs/usage.md#69-the-action-plan--the-change-as-a-runnable-statement)
and [§7–8](docs/usage.md#7-the-plan-before-and-after-a-change) for the
before/after report and the statement identifiers.

---

## The plan before and after a change

The Oracle SQL Tuning Advisor does not stop at a recommendation: it shows
the plan **before** the change, the plan **after** it, and how much the
change gained. `pg_sta` does the same, and it leaves the database
untouched — the change is applied in a subtransaction and rolled back.

```sql
SELECT verdict, before_ms, after_ms, improvement_pct,
       before_buffers, after_buffers, plan_changed, rows_match,
       node_changes
FROM sta.before_after_benefit(
    'SELECT * FROM order_details WHERE order_id = 500000',
    'CREATE INDEX idx_od_order_id ON order_details (order_id)',
    'AUTO', 3);
```

```
    verdict    | before_ms | after_ms | improvement_pct | before_buffers | after_buffers
--------------+-----------+----------+-----------------+----------------+---------------
 RECOMMENDED  |    13.661 |     0.014 |           99.90 |          7353 |             1
```

```
 plan changes:
  Gather  ->  Index Scan on public.order_details using idx_od_order_id
  Seq Scan on public.order_details  ->  (removed)
```

`sta.plan_before_after()` returns the two plans themselves — the readable
text and the JSON — with the times and the buffer counts of each:

```console
$ ./scripts/pg_sta_ctl --database appdb before-after \
      "SELECT * FROM order_details WHERE order_id = 500000" \
      "CREATE INDEX idx_od_order_id ON order_details (order_id)"
```

The change may be a `CREATE INDEX`, an `ANALYZE`, a `VACUUM (ANALYZE)` or
the rewritten statement; `AUTO` detects which one it is. A change that
makes the query **slower** is reported as `REJECTED`, so a bad index
candidate cannot be mistaken for a good one.

### The report for the whole workload

`sta.before_after_report()` does the same for **every statement of the
workload**: it takes the changes the advisor recommends — the index, the
rewrite and the statistics — measures each one and returns the plan
before, the plan after and the benefit.

```sql
SELECT report_id, relation, change_type, measurement,
       improvement_pct, verdict, plan_changed, rows_match
FROM sta.before_after_report(NULL, 'window', 3, 10, true);
```

```
 report_id |   relation    | change_type  | measurement | improvement_pct | verdict     | plan_changed | rows_match
-----------+---------------+--------------+-------------+-----------------+-------------+--------------+------------
         1 | orders        | REWRITE      | ESTIMATED   |          -24.2  | REJECTED    | t            | t
         2 | public.customers | CREATE_INDEX | ESTIMATED |          74.1  | RECOMMENDED | t            | t
         3 | customers     | REWRITE      | ESTIMATED   |             29.3 | RECOMMENDED | t            | t
```

Every row carries the two plans in full, in `before_plan` and
`after_plan`. Every change is **rolled back**, so the report can be run
on a production database and nothing is left behind.

The same report, with the plans printed, from the command line:

```console
$ ./scripts/pg_sta_ctl --database appdb --statements 3 before-after-report
```

A statement that uses parameter placeholders (`$1`) cannot be run as it
is; its generic plan is shown instead and the **estimated cost** is what
is compared — the report says `ESTIMATED` instead of `MEASURED`.

### The reading of the two plans

A plan is a tree of numbers. `sta.plan_explanation()` turns it into
words — what each step does, how many rows it estimated and how many it
returned, where the time went and how the buffers were used — and every
before/after measurement carries the reading of both plans:

```console
$ ./scripts/pg_sta_ctl --database appdb before-after-report \
      "SELECT employee_id, employee_name FROM employees WHERE department_id = 2"
```

```
--- reading of the plan before ------------------------------
- gather
    10,250 rows estimated, 10,000 rows returned, 14.321 ms, 7353 buffers hit
  - seq scan on public.employees
      filter: (employees.department_id = 2)
      4,271 rows estimated, 3,333 rows returned, in 3 loops, 9.451 ms, 7353 buffers hit

The plan is a parallel gather over employees. The outer side reads every row of employees. The step that costs the most is the seq scan on public.employees: 28.353 ms in total across 3 loops; the loops run at the same time, so the step can account for more than the 14.321 ms the statement took, and 7353 of the 7353 buffers. The statement returned 10,000 rows. Planning took 0.022 ms, the execution 14.511 ms, and the plan touched 7353 buffers, all of them from the cache.
--- benefit -----------------------------------------------
before:       15.214 ms
after:        5.071 ms
cost:         14586.3 -> 6315.4
gain:         66.7 % (TIME)
buffers:      7353 -> 7367 (-0.2 %)
buffer split: 7353 hit / 0 read  ->  7356 hit / 11 read
rows:         10000 -> 10000 (same number of rows: true)
row by row:   (the change does not change the rows)
assumptions:  (none)
plan changed: true
rows match:   true
verdict:      RECOMMENDED
```

The gain always says **how it was measured**: `TIME` when the statement
was really run on both sides, `COST` when only the estimated cost of
the generic plan could be compared. A rewrite is checked row by row and
its assumptions are tested — each check answers `PASS` or `FAIL`.

`sta.before_after_detail()` returns all of it in one row, for one
statement and one change.

`sta.action_script()` carries the same information: with `p_plans` (the
default) every step of the script holds the plan before the change, the
plan after it, the measured gain and the verdict:

```console
$ ./scripts/pg_sta_ctl --database appdb --statements 3 script --plans > fix.sql
$ ./scripts/pg_sta_ctl --database appdb --statements 3 script --no-plans > fix.sql
```

## Statement identifiers, the Oracle way

Oracle gives every statement a `V$SQL.SQL_ID` (a hash of the **exact**
text) and a `V$SQL.SQL_HASH` (a hash of the **normalised** text).
PostgreSQL has no built-in `SQL_ID`, but `pg_sta` provides both:

| Oracle | PostgreSQL / pg_sta | What it is |
|---|---|---|
| `V$SQL.SQL_ID` | `sta.sql_id(sql)` | A ten-digit hash of the **exact** text. Two statements that differ only in a literal have **different** ids. |
| `V$SQL.SQL_HASH` | `sta.sql_hash(sql)` | A hash of the **normalised** text. Two statements that differ only in a literal have the **same** hash. |
| — | `sta.queryid(sql)` | The canonical query id of the server — the same value as `pg_stat_statements.queryid`. |
| — | `sta.queryid_info(sql)` | All of the above, plus the workload of the statement from `pg_stat_statements`. |

```console
$ ./scripts/pg_sta_ctl --database appdb sqlid "SELECT * FROM orders WHERE customer_id = 42"
query id:     -4644307853832973059
sql id:       2556230741
sql hash:     -808386326668075698
normalized:   SELECT * FROM orders WHERE customer_id = $1
recorded:     SELECT * FROM orders WHERE customer_id = $1
in pg_stat_statements: true
calls:        5
total time:   245.194 ms
mean time:    16.372 ms
shared hit:   65547
shared read:  17288
```

The full guide: [docs/usage.md §7–8](docs/usage.md#7-the-plan-before-and-after-a-change).

---

## Example

```
pg_sta: 38 finding(s)

[HIGH] plan / SEQ_SCAN_ON_LARGE_TABLE  (confidence: HIGH)
  subject:   sta_qa.big_events
  observed:  Sequential scan over big_events (120000 rows estimated) reads the
             whole relation; an index on the filtered columns may avoid the full scan
  advice:    Add an index that supports the filter of this scan and re-check the plan.
  benefit:   Replacing a full scan with an index lookup reduces the rows read per
             execution from the whole relation to the matching rows.
  cost:      An index adds write amplification and storage; verify the gain with
             sta.validate() before keeping it.
  validate:  Capture a baseline with EXPLAIN (ANALYZE, BUFFERS) and record the
             execution time and buffer counts.
             Create the candidate index (use CONCURRENTLY in production) and re-run
             the same EXPLAIN (ANALYZE, BUFFERS).
             Confirm the access path changed (Seq Scan -> Index Scan) and that the
             buffer reads dropped.
             Measure application-level latency over a representative window, before
             and after.
```

---

## Architecture at a glance

```
  application
      │
      ▼
  pg_stat_statements ──┐
  pg_stat_all_tables  ──┼──►  sta.collect()  ──►  sta.workload_sample
  pg_index             ──┘                        sta.table_stats_sample
                                                    sta.index_sample
      │
      ▼
  ┌───────────────────────────────────────────────────────────┐
  │  C core (src/pg_sta.c)                                    │
  │    • queryid()            – canonical statement id        │
  │    • queryid_normalized() – literal-free statement text   │
  │    • explain()            – JSONB execution plan          │
  │    • server_info()        – version + configuration       │
  └───────────────────────────────────────────────────────────┘
      │
      ▼
  ┌───────────────────────────────────────────────────────────┐
  │  SQL advisory layer (sql/pg_sta--0.1.5.sql)               │
  │    workload_advice()  plan_advice()  stats_advice()      │
  │    index_advice()     validate()     recommendations()   │
  │    action_plan()      action_script()                    │
  │    rewrite_advice()   rewrite_statement()                │
  │    snapshot_diff()    record_run()                       │
  │                                                          │
  │  PostgreSQL 19 parity layer                              │
  │    plan_advice_string()   generate PG19 advice           │
  │    apply_advice()         enforce it (GUC-backed)        │
  │    restore_advice()       undo it exactly                │
  │    create_stash() …       the pg_stash_advice API        │
  └───────────────────────────────────────────────────────────┘
      │
      ▼
  scripts/pg_sta_ctl   →   text / markdown / JSON
```

Full detail: [docs/implementation.md](docs/implementation.md) and
[docs/architecture.md](docs/architecture.md).

---

## Documentation

| Document | Contents |
|---|---|
| [docs/usage.md](docs/usage.md) | **Step-by-step guide for PostgreSQL 17** — build, install, use, validate, tune thresholds, troubleshoot |
| [docs/implementation.md](docs/implementation.md) | How the extension is built, the end-to-end data flow, the C core, the SQL layer |
| [docs/architecture.md](docs/architecture.md) | Component design, data model, extension interfaces, design decisions and trade-offs |
| [docs/advice-catalog.md](docs/advice-catalog.md) | Every finding, its evidence source, default severity and recommended action |
| [docs/validation.md](docs/validation.md) | The validation methodology — how `sta.validate()` measures a change and how to read its verdict |
| [docs/pg19-compatibility.md](docs/pg19-compatibility.md) | **PostgreSQL 19 parity** — what `pg_plan_advice` and `pg_stash_advice` do exactly the same in `pg_sta`, and where PostgreSQL 17 forces a documented approximation |
| [docs/dev-environment.md](docs/dev-environment.md) | The AlmaLinux 9 / Vagrant / PostgreSQL 17 development environment and the dev loop |

---

## Project layout

```
pg_sta/
├── Makefile                 PGXS build, install, installcheck, qa
├── pg_sta.control           extension control file
├── src/pg_sta.c             C core: queryid, normalisation, EXPLAIN, server info
├── sql/
│   ├── pg_sta--0.1.5.sql    the advisory engine (schema "sta")
│   ├── pg_sta--0.1.0--0.1.5.sql   upgrade path from 0.1.0
│   ├── pg_sta--0.1.1--0.1.5.sql   upgrade path from 0.1.1
│   ├── pg_sta--0.1.2--0.1.5.sql   upgrade path from 0.1.2
│   ├── pg_sta--0.1.3--0.1.5.sql   upgrade path from 0.1.3
│   ├── pg_sta--0.1.4--0.1.5.sql   upgrade path from 0.1.4
│   ├── pg_sta--0.1.5--0.1.4.sql   downgrade path back to 0.1.4
│   ├── pg_sta.sql           regression test
│   ├── orders_workload.sql  a 10-statement workload for the demo schema
│   ├── sample_data.sql      demo schema: orders, customers, workload
│   └── sample_workload.sql  a captured workload for the demo schema
├── expected/pg_sta.out      recorded regression output
├── scripts/
│   ├── pg_sta_ctl           command line client
│   ├── pg_sta_conn.sh       shared connection helpers (SSH or local psql)
│   ├── sync.sh              copy the tree to the VM
│   ├── build.sh             compile on the VM
│   ├── install.sh           sync + build + install
│   ├── reload.sh            reload the extension
│   ├── psql.sh              psql as postgres over SSH or locally
│   ├── load_sample_data.sh  load a demo schema, workload and advice
│   ├── load_benchmark.sh    load the 10 x 1M row benchmark fixture
│   ├── gen_upgrade.py       generate the upgrade scripts from the base script
│   ├── lint_sql.py          static linter for the PL/pgSQL bodies
│   └── installcheck.sh      run the regression suite
├── test/
│   ├── qa_setup.sql         deliberate-defect fixture, split into phases
│   ├── qa_assertions.sql    232 assertions
│   └── run_qa.sh            the QA runner
├── packaging/pg_sta.spec    RPM package
└── docs/                    the documentation set
```

---

## Testing

```bash
make installcheck PG_CONFIG=/usr/pgsql-17/bin/pg_config   # regression suite
make qa                                                     # QA suite (232 assertions)
```

The QA suite seeds a database with **deliberate defects** — an unanalysed
table, a stale-statistics table, a bloated table, a hot query, a missing
index — and asserts that the advisor finds each one and does not raise
false positives. The fixture is split into phases so each phase runs in its
own session, which is what makes the PostgreSQL 17 statistics-collector
behaviour deterministic (see the header of `test/qa_setup.sql`).

---

## Safety

`pg_sta` is read-only. It never runs `ANALYZE`, `VACUUM`, `REINDEX` or
`CREATE INDEX` against your database, never modifies a user schema, and
never changes a configuration file. The only writes are into its own
`sta` schema. `sta.validate()` creates the candidate index inside a
subtransaction and **rolls it back**.

Read [docs/usage.md §10](docs/usage.md#10-safety-guarantees) for the full
guarantee table.

---

## Licence

PostgreSQL Licence. See [LICENSE](LICENSE).

The statement-normalisation code in `src/pg_sta.c` is adapted from
`pg_stat_statements` and carries the PostgreSQL attribution notice.
