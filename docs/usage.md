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
| What change do I make, exactly? | `sta.action_plan()` |
| How do I run the changes? | `sta.action_script()` |
| How do I rewrite this statement? | `sta.rewrite_statement()` |
| How do I validate a proposed change? | `sta.validate()` |
| Did the change help, without regressions? | `sta.validate()` |
| What does the plan look like before and after a change? | `sta.plan_before_after()` |
| How much does the change actually gain me? | `sta.before_after_benefit()` |
| What does the change do to every statement of the workload? | `sta.before_after_report()` |
| What is the Oracle-style id of my statement? | `sta.sql_id()`, `sta.sql_hash()` |
| What is the `pg_stat_statements` id of my statement? | `sta.queryid_info()` |
| Can I get the report the Oracle SQL Tuning Advisor writes? | `sta.tuning_report()` |

Every finding carries the same envelope: **what was observed**, **what to
do**, **the expected benefit**, **the cost**, and **the exact steps to
validate it**.

---

## 0.1 The eight steps, end to end

This is the shortest path from "the statement is already running in the
database" to "the statement is tuned and the gain is measured".

Throughout the examples:

```bash
CTL="sudo -u postgres /var/lib/pgsql/pg_sta/scripts/pg_sta_ctl --database appdb"
SQL="$(cat /tmp/payroll.sql)"        # the statement, exactly as the app runs it
```

### Step 1 — the extension must exist in the database that holds the data

```bash
sudo -u postgres psql -X -d appdb -c \
  "CREATE EXTENSION IF NOT EXISTS pg_sta; CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
sudo -u postgres psql -X -d appdb -c \
  "SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_sta','pg_stat_statements');"
```

`pg_stat_statements` is the workload source; `pg_sta` is the advisor.
`pg_stat_statements` must also be in `shared_preload_libraries` (see
[Prerequisites](#1-prerequisites)).

### Step 2 — run the statement in that same database

The advisor learns from `pg_stat_statements`, so the statement has to have
really run, **in the same database** (`pg_stat_statements` is filtered by
`current_database()`):

```bash
sudo -u postgres psql -X -d appdb -f /tmp/payroll.sql
```

Check that the server has seen it:

```sql
SELECT queryid, calls, round(total_exec_time::numeric, 1) AS ms
FROM pg_stat_statements
WHERE query ILIKE '%employee_master%';
```

### Step 3 — take a snapshot of the workload

```bash
$CTL collect
```

or, in SQL:

```sql
SELECT * FROM sta.collect();
```

One call writes one snapshot: the statements of `pg_stat_statements`, the
table statistics and the index list of every table. Nothing is deleted.

### Step 4 — ask the advice for that statement

```bash
$CTL index   "$SQL"     # the index candidates, with the DDL
$CTL rewrite "$SQL"     # the rewrites, with the rewritten statement
$CTL plan    "$SQL"     # what is wrong with the plan, and why
$CTL stats              # the statistics of the tables
```

The same functions are available in SQL, which is the way to read one row at
a time:

```sql
SELECT * FROM sta.index_advice($sql$SELECT ...$sql$);
SELECT * FROM sta.rewrite_advice($sql$SELECT ...$sql$);
SELECT * FROM sta.plan_advice($sql$SELECT ...$sql$);
```

The text you pass must name relations that exist in the `search_path` of
that database — otherwise pg_sta reports `relation "..." does not exist`,
because it cannot resolve what the statement reads.

### Step 5 — get the action plan and the runnable script

```bash
$CTL actions "$SQL"                 # the change: DDL, VACUUM/ANALYZE, rewrites
$CTL script  "$SQL" > /tmp/fix.sql  # the same, as one runnable file
$CTL script --no-plans "$SQL" > /tmp/fix.sql   # without the EXPLAIN plans
```

Read the whole script before running it: every step states why it is there,
what it buys, what it costs and how it is checked.

### Step 6 — measure the change: the plan before and after, and the gain

```bash
$CTL before-after "$SQL" "CREATE INDEX CONCURRENTLY idx_employee_master_employee_id ON employee_master (employee_id)"
```

or, in SQL:

```sql
SELECT * FROM sta.before_after_detail(
  $sql$SELECT ...$sql$,
  'CREATE INDEX CONCURRENTLY idx_employee_master_employee_id ON employee_master (employee_id)');
```

The change type is worked out from the change itself when it is not given
(`AUTO`), and the change is applied inside a sub-transaction and **rolled
back**: the measurement never leaves an index behind.

For the whole workload, one row per statement and per change:

```bash
$CTL before-after-report --statements 5
```

```sql
SELECT * FROM sta.before_after_report();
```

Every row carries `before_plan` / `after_plan` (the EXPLAIN output),
`before_reading` / `after_reading` (the same plan written out in words),
`before_ms` / `after_ms`, `improvement_pct` and `benefit_basis`, the buffer
split, and the row-by-row comparison (`rows_match`, `comparison`) that proves
the rewrite returns the same rows.

From 0.1.6 there is a third change type, `MIXED`: the index **and** the
rewrite are applied together and measured together. That is the row that
answers the real question when a statement needs both — for example a join
whose key is wrapped in a function such as `md5()`: the index alone cannot
serve `md5(a) = md5(b)`, and the rewrite alone still reads every row.

> **How much memory the measurement needs.** The row-by-row comparison turns
> every row of both result sets into its JSON form and hashes it, so the
> memory it needs grows with the size of the result set, not with the size
> of the table. A statement that returns six million rows needs a few
> gigabytes; on a small virtual machine the comparison swaps, and the
> measurement takes minutes instead of seconds. Give the server enough
> memory for the result set of the statement, or measure the statement on
> a smaller slice of the data.

### Step 7 — read the result

| Column | What it tells you |
|---|---|
| `before_plan`, `after_plan` | the EXPLAIN output before and after the change |
| `before_reading`, `after_reading` | the same plan in words |
| `before_ms`, `after_ms` | the measured execution time |
| `improvement_pct`, `benefit_basis` | the gain, and what it was measured on |
| `before_buffers`, `after_buffers` | the blocks read, with the hit/read split |
| `rows_match`, `comparison` | `ROWS_MATCH` or `ROWS_DIFFER` — the proof the rewrite is safe |
| `plan_changed`, `verdict` | `BENEFICIAL`, `NEUTRAL`, `REGRESSION` or `NOT_APPLICABLE` |

### Step 8 — apply the change and measure again

```bash
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d appdb -f /tmp/fix.sql
$CTL collect
$CTL before-after-report --statements 5
```

The second measurement must show the plan and the timing that the report
predicted. If it does not, the workload changed — collect again and compare.

### The identifiers, the Oracle way

```sql
SELECT sta.sql_id('SELECT * FROM orders WHERE customer_id = 42');    -- hash of the exact text
SELECT sta.sql_hash('SELECT * FROM orders WHERE customer_id = 42');  -- hash of the normalised text
SELECT sta.queryid('SELECT * FROM orders WHERE customer_id = 42');   -- pg_stat_statements.queryid
SELECT * FROM sta.queryid_info('SELECT * FROM orders WHERE customer_id = 42');
```

```bash
$CTL sqlid "$SQL"
```

See [Statement identifiers](#8-statement-identifiers-the-oracle-way).

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

`pg_sta` lives at <https://github.com/jeyram-cloud/pg_sta>. Pick whichever
of the three methods below fits your setup.

### 2.1 Clone with git (recommended)

```bash
# HTTPS
git clone https://github.com/jeyram-cloud/pg_sta.git

# or SSH, if you have a key registered on GitHub
git clone git@github.com:jeyram-cloud/pg_sta.git

cd pg_sta
```

### 2.2 Download a release tarball

No git? Download the archive directly:

```bash
curl -L -o pg_sta.tar.gz \
  https://github.com/jeyram-cloud/pg_sta/archive/refs/heads/main.tar.gz
tar -xzf pg_sta.tar.gz
cd pg_sta-main        # the directory name carries the branch name
```

To pin a specific commit, replace `main` with the commit SHA:

```bash
curl -L -o pg_sta.tar.gz \
  https://github.com/jeyram-cloud/pg_sta/archive/<commit-sha>.tar.gz
```

Verify the download (the repository is public, so this needs no token):

```bash
curl -s https://api.github.com/repos/jeyram-cloud/pg_sta/git/trees/main?recursive=1 \
  | grep -c '"path"'      # 34 entries
```

### 2.3 Copy the tree to a remote database host

The build has to happen **on the machine that owns the PostgreSQL
installation**, because the installed artefacts go into that PostgreSQL
tree. Copy the source across first:

```bash
# from your workstation
scp -r pg_sta vagrant@<db-host>:/home/vagrant/
scp -r pg_sta user@<db-host>:~/          # any account with write access

# then, on the database host
cd /home/vagrant/pg_sta
make PG_CONFIG=/usr/pgsql-17/bin/pg_config
sudo make PG_CONFIG=/usr/pgsql-17/bin/pg_config install
```

The developer scripts in `scripts/` do this automatically:

```bash
./scripts/sync.sh       # rsync the tree to the VM
./scripts/build.sh      # build on the VM
./scripts/install.sh    # build + install on the VM
```

### 2.4 What the tree contains

| Path | Purpose |
|---|---|
| `src/pg_sta.c` | the C core: plan capture, query ids, server introspection |
| `sql/pg_sta--0.1.7.sql` | the advisory engine, the catalogue and the sample tables |
| `sql/pg_sta.sql` | the regression suite (pg_regress) |
| `sql/sample_data.sql`, `sql/sample_workload.sql` | the demo schema and the demo workload |
| `scripts/pg_sta_ctl` | the command line client |
| `scripts/*.sh` | build, install, reload, sample-data and test helpers for the dev VM |
| `test/qa_setup.sql`, `test/qa_assertions.sql` | the QA suite (204 assertions) |
| `docs/` | the operational and design documentation |
| `packaging/pg_sta.spec` | an RPM spec file |


---

## 3. Build

The extension uses standard PGXS, so the normal PostgreSQL build machinery
is enough:

```bash
cd /path/to/pg_sta            # the directory that holds the Makefile
make PG_CONFIG=/usr/pgsql-17/bin/pg_config
```

> **Run `make` from the source directory.** PGXS reads the `Makefile` in
> the current directory, so `make` in `/var/lib/pgsql`, in
> `/usr/pgsql-17/bin` or in `$HOME` fails with
> `make: *** No targets specified and no makefile found.` — that message
> means "wrong directory", not "broken build".

Artefacts land in `src/pg_sta.so` and the SQL script stays in `sql/`.

### Build without a server

On a machine that has only the *devel* package (no running server) the same
command works — PGXS does not need a live cluster.

### Build inside the container/VM

```bash
cd /home/vagrant/pg_sta        # where the tree was copied to
sudo make PG_CONFIG=/usr/pgsql-17/bin/pg_config install
```

`install` places:

- `pg_sta.so` → `$(pg_config --pkglibdir)`
- `pg_sta.control` → `$(pg_config --sharedir)/extension`
- `pg_sta--0.1.7.sql` → `$(pg_config --sharedir)/extension`

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

### 4.1 A database to try it on

The examples in this document use two tables, `customers` and `orders`.
A ready-made fixture for them is included:

```bash
./scripts/load_sample_data.sh --database appdb
```

It creates the two tables, fills them with a deterministic data set and
runs a small workload, so that `pg_stat_statements` has something to
report. The transport is detected automatically, so the same command works
on the workstation and on the database host.

```
target database: appdb (transport: ssh)
==> loading the sample tables
==> running the sample workload (120 iterations per statement)
customers:                 2000
orders:                    120000
pg_stat_statements rows:  9
```

`orders` is deliberately left un-analysed, so the statistics advice has a
subject. Pass `--analyze-all` to analyse it as well, `--iterations N` to
run a longer workload, and `--force` to drop and recreate the sample
tables. Only tables carrying the `pg_sta sample data` marker comment are
ever dropped.

> The fixture writes to the `public` schema of the target database. Use a
> scratch database, never a production one.

### 4.2 Upgrading and downgrading an existing installation

The advisor is upgraded in place, so the collected workload and the audit
trail survive the upgrade:

```sql
ALTER EXTENSION pg_sta UPDATE TO '0.1.7';
```

A script is provided for every step of the way, so a database on any
older version can reach the newest one in one command:

| Script | From | To |
|---|---|---|
| `pg_sta--0.1.0--0.1.7.sql` | 0.1.0 | 0.1.7 |
| `pg_sta--0.1.1--0.1.7.sql` | 0.1.1 | 0.1.7 |
| `pg_sta--0.1.2--0.1.7.sql` | 0.1.2 | 0.1.7 |
| `pg_sta--0.1.3--0.1.7.sql` | 0.1.3 | 0.1.7 |
| `pg_sta--0.1.4--0.1.7.sql` | 0.1.4 | 0.1.7 |
| `pg_sta--0.1.5--0.1.7.sql` | 0.1.5 | 0.1.7 |
| `pg_sta--0.1.6--0.1.7.sql` | 0.1.6 | 0.1.7 |

The newest version can also be taken back one step:

```sql
ALTER EXTENSION pg_sta UPDATE TO '0.1.5';
```

The downgrade script `pg_sta--0.1.7--0.1.6.sql` restores the bodies of
the 0.1.6 functions and drops the ones that 0.1.7 added. It is needed
because a function body cannot be replaced by `CREATE OR REPLACE` when
its arguments **or its return type** changed.

> **Why the upgrade script and not `psql -f`?** The members of an
> extension cannot be replaced from outside: PostgreSQL refuses to drop
> a function that the extension owns. Only an `ALTER EXTENSION … UPDATE`
> can replace them, because it runs the upgrade script inside the
> extension's own transaction.

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

### 6.9 The action plan — the change, as a runnable statement

`sta.recommendations()` explains the findings. `sta.action_plan()` turns
them into the **commands that implement them**, ordered by priority:

```sql
SELECT action_type, priority, object_name, action_sql, finding,
       expected_benefit, estimated_cost, risk
FROM sta.action_plan()
ORDER BY priority, action_id;
```

Arguments: `(p_sql, p_window, p_analyze, p_limit)`.

* `p_sql` — analyse one statement instead of the whole workload. When it
  is given, the actions that belong to that statement are always returned,
  even when the limit is reached.
* `p_window` — `'cumulative'` (everything collected so far) or a window
  name registered with `sta.snapshot_diff()`.
* `p_analyze` — measure the statements, which produces estimate/mismatch
  findings. Measuring runs the statement, so it is off by default.
* `p_limit` — the maximum number of actions (1 … 200, default 50).

There are four action types:

| Action type | What it does | Example |
|---|---|---|
| `VACUUM_ANALYZE` | dead tuples / never vacuumed | `VACUUM (ANALYZE) public.orders;` |
| `ANALYZE` | never analyzed / stale statistics | `ANALYZE public.orders;` |
| `CREATE_INDEX` | missing index, with the full DDL | `CREATE INDEX CONCURRENTLY idx_orders_customer_id ON public.orders (customer_id);` |
| `REWRITE` | the rewritten statement itself | `SELECT order_id, customer_id … WHERE NOT EXISTS (…)` |

A trigram index needs the `pg_trgm` extension. When the extension is
missing, the action carries the `CREATE EXTENSION IF NOT EXISTS pg_trgm;`
statement with it, so the script stays runnable:

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX CONCURRENTLY idx_customers_email_trgm
    ON public.customers USING gin (email gin_trgm_ops);
```

### 6.10 The action script — everything as one runnable file

`sta.action_script()` returns the whole plan as one commented script. Every
step states why it is there, what it is expected to gain, what it costs
and how to check that it worked:

```bash
sudo -u postgres psql -X -tA -d appdb \
  -c "SELECT sta.action_script(NULL, 'cumulative', false, 100);" > /tmp/pg_sta_actions.sql

less /tmp/pg_sta_actions.sql          # read it first
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d appdb -f /tmp/pg_sta_actions.sql
```

The full signature is:

```sql
sta.action_script(
    p_sql        text    DEFAULT NULL,     -- one statement, or NULL for the whole workload
    p_window     text    DEFAULT 'window',  -- 'window', 'cumulative' or 'top'
    p_analyze    boolean DEFAULT false,     -- run EXPLAIN (ANALYZE) on the statements
    p_limit      integer DEFAULT 50,       -- how many statements the script covers
    p_plans      boolean DEFAULT true,     -- carry the plan before and after every step
    p_iterations integer DEFAULT 3)        -- how often each statement is measured
```

With `p_plans` — the default — every step of the script also carries the
**plan before the change**, the **plan after it**, the **gain that was
measured** and the **verdict**. The change is applied in a subtransaction
and rolled back, so the script shows what the change *would* do without
leaving anything behind in the database:

```
-- Plan before (generic plan, the statement could not be run):
--   Gather  (cost=1000.00..16638.71 rows=5000 width=50)
--     Workers Planned: 3
--     ->  Parallel Seq Scan on customers  (cost=0.00..15138.71 rows=1613 width=50)
--           Filter: (lower((customer_name)::text) = $1)
--
-- Plan after (generic plan, the statement could not be run):
--   Bitmap Heap Scan on customers  (cost=61.17..4311.06 rows=5000 width=50)
--     Recheck Cond: (lower((customer_name)::text) = $1)
--     ->  Bitmap Index Scan on idx_customers_customer_name_lower  (cost=0.00..59.92 rows=5000 width=0)
--           Index Cond: (lower((customer_name)::text) = $1)
--
-- Measured: estimated cost 16638.7 before, 4311.1 after
-- Gain: 74.1%
-- Verdict: RECOMMENDED
-- Plan changes:
--   -   Gather  ->  Bitmap Heap Scan on public.customers
--   -   Seq Scan on public.customers  ->  Bitmap Index Scan using idx_customers_customer_name_lower
-- Note: The change was applied in a subtransaction and rolled back; the database is unchanged.
```

A statement that comes from `pg_stat_statements` uses parameter
placeholders (`$1`), so it cannot be run as it is. Its **generic plan**
is shown instead, and the **estimated cost** is what is compared — the
script says so in the header of the block.

The script is **runnable as it is**:

* every statement is terminated with `;`,
* a rewritten statement that uses a parameter placeholder (`$1`) is
  emitted as a comment, with the instruction that says what the parameter
  means — a placeholder cannot be run by `psql`,
* `CREATE INDEX CONCURRENTLY` carries the note that it cannot run inside a
  transaction block.

The statistics come first (a correct estimate can remove the need for an
index) and the rewritten statements come last.

For one statement:

```sql
SELECT sta.action_script(
    'SELECT * FROM orders WHERE customer_id NOT IN (SELECT customer_id FROM customers)');
```

To get the script without the plan blocks — the plan of every statement
is measured, which takes time:

```sql
SELECT sta.action_script(NULL, 'cumulative', false, 100, false);
```

### 6.11 Rewritten statements

`sta.rewrite_advice()` lists the rules that apply to a statement, and
`sta.rewrite_statement()` applies all of them and returns the result:

```sql
SELECT original_sql, rewritten_sql, applied, changed
FROM sta.rewrite_statement(
    'SELECT * FROM orders WHERE customer_id NOT IN (SELECT customer_id FROM customers)');
```

```
           original_sql            |                    rewritten_sql                     |          applied
----------------------------------+---------------------------------------------------------+------------------------
 SELECT *                          | SELECT order_id,                                        | {NOT_IN_TO_NOT_EXISTS,
 FROM orders                       |        customer_id,                                     |  SELECT_STAR}
 WHERE customer_id NOT IN         |        order_date                                       |
 (SELECT customer_id FROM ...)    | FROM orders                                             |
                                  | WHERE NOT EXISTS (SELECT 1 FROM customers …)          |
```

`applied` lists the rules that fired. The rules are:

| Rule | What it changes | Why |
|---|---|---|
| `IMPLICIT_CAST` | `col::text = '1'` → `col = 1` | a cast on the column side makes the predicate non-sargable |
| `NON_SARGABLE_PREDICATE` | `col + 1 = 5` → `col = 4`, `date_col = date '…'` → `date_col BETWEEN …` | an expression on the column side cannot use an index |
| `OR_TO_IN` | `a = 1 OR a = 2` → `a IN (1, 2)` | an `OR` of the same column is one lookup |
| `NOT_IN_TO_NOT_EXISTS` | `NOT IN (subquery)` → `NOT EXISTS (…)` | `NOT IN` hashes the whole subquery and changes the NULL semantics |
| `UNION_TO_UNION_ALL` | `UNION` → `UNION ALL` | `UNION` de-duplicates the result |
| `LEADING_WILDCARD_LIKE` | `LIKE '%x'` → trigram index | a leading wildcard cannot use a B-tree index |
| `SELECT_STAR` | `SELECT *` → the columns that exist | every column of the relation is read and widened on the way out |
| `OFFSET_PAGINATION` | `OFFSET n` → `WHERE id > $n` | a deep offset reads and throws away the skipped rows |

The rewrites are **suggestions, not equivalences**. Each finding lists
the assumption it depends on (for example: `NOT IN` returns no rows at
all when the subquery produces a single `NULL`, `NOT EXISTS` does not).
Check the assumption before the rewritten statement is used.

To keep the original text of a statement — `pg_stat_statements` normalises
constants away — record it yourself:

```sql
SELECT sta.record('SELECT * FROM orders WHERE customer_id = 42');
```

`sta.record()` stores the text under its query id, and the advice is then
produced for the statement as the application really writes it.

---

## 7. The plan before and after a change

This is the Oracle SQL Tuning Advisor "before/after" report: the plan of
the statement **as it runs today**, the plan of the same statement **after
the proposed change**, and the **benefit** the change produced.

### 7.1 The two plans

```sql
SELECT phase, change_type, exec_ms, shared_hit, node_type, index_name,
       plan_text
FROM   sta.plan_before_after(
           p_sql    => 'SELECT * FROM order_details WHERE order_id = 500000',
           p_change => 'CREATE INDEX idx_od_order_id ON order_details (order_id)',
           p_iterations => 3);
```

```
 phase  | change_type | exec_ms | shared_hit | node_type  | index_name
--------+-------------+---------+------------+------------+-----------
 BEFORE | CREATE_INDEX | 21.331 |         84 | Gather     |
 AFTER  | CREATE_INDEX |  0.014 |          4 | Index Scan | idx_od_order_id
```

Both rows carry the **readable plan** in `plan_text` and the **machine
readable plan** in `plan`:

```
--- BEFORE -----------------------------------------------------
Gather  (cost=1000.00..13561.43 rows=1 width=28) (actual time=12.888..13.118 rows=1 loops=1)
  Workers Planned: 2
  Workers Launched: 2
  Buffers: shared hit=7353
  ->  Parallel Seq Scan on order_details  (cost=0.00..12561.33 rows=1 width=28) (actual time=8.008..9.875 rows=0 loops=3)
        Filter: (order_id = 500000)
        Rows Removed by Filter: 333333
        Buffers: shared hit=7353
Planning Time: 0.021 ms
Execution Time: 13.125 ms

--- AFTER ------------------------------------------------------
Index Scan using idx_od_order_id on order_details  (cost=0.42..2.64 rows=1 width=28) (actual time=0.001..0.001 rows=1 loops=1)
  Index Cond: (order_id = 500000)
  Buffers: shared hit=4
Planning Time: 0.006 ms
Execution Time: 0.004 ms
```

> The change is applied in a **subtransaction** and rolled back, so the
> database is left exactly as it was. Nothing is left behind: no index, no
> changed statistics.

### 7.2 The benefit and the plan change matrix

```sql
SELECT verdict, before_ms, after_ms, improvement_pct,
       before_buffers, after_buffers, plan_changed, rows_match,
       node_changes, notes
FROM   sta.before_after_benefit(
           p_sql    => 'SELECT * FROM order_details WHERE order_id = 500000',
           p_change => 'CREATE INDEX idx_od_order_id ON order_details (order_id)',
           p_iterations => 3);
```

```
    verdict    | before_ms | after_ms | improvement_pct | plan_changed | rows_match
--------------+-----------+----------+-----------------+--------------+------------
 RECOMMENDED  |    13.661 |     0.014 |           99.90 | t            | t
```

```
 plan changes:
  Gather  ->  Index Scan on public.order_details using idx_od_order_id
  Seq Scan on public.order_details  ->  (removed)
```

The **plan change matrix** lists every node of the plan and what it became,
so the change in the execution strategy is visible, not just its timing.

### 7.3 The change types

| `change_type` | The change is | The "after" plan is the plan of |
|---|---|---|
| `CREATE_INDEX` | `CREATE [UNIQUE] INDEX ...` | the same statement with the index in place |
| `ANALYZE` | `ANALYZE table` | the same statement with fresh statistics |
| `VACUUM_ANALYZE` | `VACUUM [ANALYZE] table` | the same statement with fresh statistics |
| `REWRITE` | the rewritten statement | the **new text** |
| `MIXED` | the rewritten statement, with the index it needs | the **new text**, with the index in place |
| `NONE` | nothing | the same statement again (the noise of a second measurement) |

`AUTO` — the default — detects the type from the text of the change.

`MIXED` is the measurement that answers the question the other two cannot:
on their own, an index does nothing for a statement that compares
`md5(column)` with `md5(column)`, and a rewrite without the index still
reads every row. The report measures the two changes together — the
rewritten statement with the index in place — because that is the change
the application really makes. The index is created inside the measurement
and rolled back afterwards.

Two restrictions apply:

* `CREATE INDEX CONCURRENTLY` is refused: it cannot run inside a
  transaction block, and the index is rolled back anyway.
* `VACUUM` cannot run inside a transaction block either, so only its
  `ANALYZE` part is executed. The note in `notes` says so. The statistics
  are refreshed, the dead tuples are not removed — measure the vacuum
  itself with `VACUUM` run outside the advisor.

### 7.4 The verdicts

| Verdict | Meaning |
|---|---|
| `RECOMMENDED` | The plan changed, the rows match and the change was faster. |
| `NOT_USED` | The planner ignored the change; the plan signature is unchanged. |
| `REJECTED` | The plan changed but the change was **slower**. |
| `NO_SIGNIFICANT_CHANGE` | The plan changed, but the timing is within the noise. |
| `NOT_COMPARABLE` | The two runs returned a different number of rows. |
| `ROWS_DIFFER` | The rewritten statement returns **different rows** than the original; it cannot be used as it is. |
| `NO_CHANGE_NEEDED` | No change is recommended for this statement, so there is no benefit to measure. |
| `ERROR` | The statement or the change failed; see `notes`. |

The report adds `NOT_MEASURED` for a row whose measurement failed.

### 7.5 The detail of one change

`sta.before_after_detail()` measures **one** statement against **one**
change and returns the whole detail in a single row: the two plans, the
reading of each plan, the gain and the basis it was measured on, the
buffer split, the row-by-row comparison and the result of the assumption
checks.

```sql
SELECT statement, change_type, change_sql,
       before_ms, after_ms, improvement_pct, benefit_basis,
       before_hit, before_read, after_hit, after_read,
       before_buffers, after_buffers, buffer_change_pct,
       rows_identical, order_preserved, rows_match,
       verdict, plan_changed, notes
FROM   sta.before_after_detail(
           p_sql        => 'SELECT employee_id, employee_name FROM employees WHERE department_id = 2',
           p_change     => 'CREATE INDEX idx_employees_department_id ON public.employees (department_id)',
           p_change_type => 'AUTO',
           p_iterations => 3);
```

| Column | What it holds |
|---|---|
| `statement` | the statement that was measured |
| `change_type` | the resolved type: `NONE`, `CREATE_INDEX`, `ANALYZE`, `VACUUM_ANALYZE` or `REWRITE` |
| `change_sql` | the change, as it was applied |
| `before_plan`, `after_plan` | the two plans, in full |
| `before_reading`, `after_reading` | the two plans written out in words (§7.7) |
| `before_ms`, `after_ms` | the measured times |
| `improvement_pct` | the gain in percent |
| `benefit_basis` | `TIME` when the gain was measured in time, `COST` when only the estimated cost could be compared, `NONE` when there is no change |
| `before_hit`, `before_read`, `after_hit`, `after_read` | the buffers of the two runs, split into cache hits and disk reads |
| `buffer_change_pct` | how much fewer buffers the change touched |
| `rows_identical`, `order_preserved` | the result of the row-by-row comparison of a rewrite |
| `comparison` | the row-by-row comparison itself, as JSONB |
| `assumptions` | the assumption checks of a rewrite, each with its `status` (`PASS`/`FAIL`), its check and its result |
| `rows_match` | whether the two runs returned the same number of rows |
| `plan_changed` | whether the plan changed at all |
| `verdict` | one of the verdicts of §7.4 |

`AUTO` resolves to the type of the change, so the function can be called
with the change alone.

### 7.6 The before/after report for the whole workload

`sta.plan_before_after()` measures **one** statement against **one**
change. `sta.before_after_report()` does the same for **every statement of
the workload**: it takes the changes the advisor recommends — the index,
the rewrite and the statistics — measures each one and reports the plan
before, the plan after and the benefit.

```sql
SELECT report_id, relation, change_type, measurement,
       improvement_pct, verdict, plan_changed, rows_match
FROM   sta.before_after_report(
           p_sql        => NULL,          -- NULL: the whole workload
           p_window     => 'window',
           p_iterations => 3,
           p_limit      => 10,            -- how many statements
           p_statistics => true);         -- include the statistics changes
```

```
 report_id |   relation   | change_type  | measurement | improvement_pct | verdict   | plan_changed | rows_match
-----------+--------------+--------------+-------------+-----------------+-----------+--------------+------------
         1 | orders       | REWRITE      | ESTIMATED   |          -24.2  | REJECTED  | t            | t
         2 | public.customers | CREATE_INDEX | ESTIMATED |          74.1  | RECOMMENDED | t          | t
         3 | customers    | REWRITE      | ESTIMATED   |             29.3 | RECOMMENDED | t         | t
         4 | big_events   | NONE         | MEASURED    |                - | NOT_USED  | f            | t
```

Every row carries the two plans in full:

```sql
SELECT report_id, before_plan, after_plan, node_changes, notes
FROM   sta.before_after_report(NULL, 'window', 3, 10, true);
```

| Column | What it holds |
|---|---|
| `report_id` | the row number of the report |
| `queryid` | the id of the statement the change belongs to |
| `statement` | the statement, as the application writes it |
| `relation` | the relation the change touches |
| `change_type` | `CREATE_INDEX`, `REWRITE`, `ANALYZE`, `VACUUM_ANALYZE` or `NONE` |
| `change_sql` | the change, as a runnable statement |
| `measurement` | `MEASURED` when the statement was run, `ESTIMATED` when only the generic plan could be compared |
| `before_plan`, `after_plan` | the two plans, in full |
| `before_ms`, `after_ms` | the measured times (empty when only the cost could be compared) |
| `before_cost`, `after_cost` | the estimated costs of the two plans |
| `improvement_pct` | the gain in percent, positive when the change is faster |
| `before_buffers`, `after_buffers` | the shared buffer hits and reads of the two runs |
| `plan_changed` | whether the plan changed at all |
| `rows_match` | whether the two runs returned the same rows |
| `verdict` | one of the verdicts of §7.4 |
| `node_changes` | the plan change matrix, node by node |
| `notes` | what was done, and what could not be measured |

**Every change is rolled back.** The index is created in a subtransaction,
the plan is measured and the subtransaction is rolled back, so the
database is exactly as it was. The report can be run on a production
database.

A statement that no change applies to still gets a row, with the change
type `NONE` and the verdict `NOT_USED`: the report covers the whole
workload, not only the statements that can be improved.

### 7.7 The reading of a plan

A plan is a tree of numbers. `sta.plan_explanation()` turns it into
words: what each step does, how many rows it estimated and how many it
returned, where the time went and how the buffers were used.

```sql
SELECT sta.plan_explanation(sta.explain(
           'SELECT employee_id, employee_name FROM employees WHERE department_id = 2',
           true));
```

```
- gather
    10,250 rows estimated, 10,000 rows returned, 14.640 ms, 7353 buffers hit
  - seq scan on public.employees
      filter: (employees.department_id = 2)
      4,271 rows estimated, 3,333 rows returned, in 3 loops, 9.116 ms, 7353 buffers hit

The plan is a parallel gather over employees. The outer side reads every row of employees. The step that costs the most is the seq scan on public.employees: 27.348 ms in total across 3 loops; the loops run at the same time, so the step can account for more than the 14.640 ms the statement took, and 7353 of the 7353 buffers. The statement returned 10,000 rows. Planning took 0.076 ms, the execution 14.832 ms, and the plan touched 7353 buffers, all of them from the cache.
```

`sta.statement_explanation()` adds the statement itself and the findings
of the advisor for that statement:

```sql
SELECT sta.statement_explanation(
           'SELECT employee_id, employee_name FROM employees WHERE department_id = 2',
           true);
```

The reading is used by the action script and by the before/after report,
so every measurement comes with its explanation.

---

## 8. Statement identifiers, the Oracle way

Oracle gives every statement two identifiers: `V$SQL.SQL_ID` (a hash of
the **exact** text) and `V$SQL.SQL_HASH` (a hash of the **normalised**
text). PostgreSQL has no built-in equivalent of `SQL_ID`, but `pg_sta`
provides both.

| Oracle | PostgreSQL / pg_sta | What it is |
|---|---|---|
| `V$SQL.SQL_ID` | `sta.sql_id(sql)` | A ten-digit hash of the **exact** text of the statement. Two statements that differ only in a literal have **different** ids. |
| `V$SQL.SQL_HASH` | `sta.sql_hash(sql)` | A hash of the **normalised** text (the literals become `$1`, `$2`, ...). Two statements that differ only in a literal have the **same** hash. |
| — | `sta.queryid(sql)` | The **canonical query id** of the server: the same value as `pg_stat_statements.queryid`. |
| — | `sta.queryid_normalized(sql)` | The normalised text, as `pg_stat_statements` stores it. |
| `V$SQL.SQL_ID` + `V$SQL.SQL_PLAN_HASH_VALUE` | `sta.queryid_info(sql)` | All of the above, plus the statistics of the statement from `pg_stat_statements`. |

```sql
SELECT sta.sql_id('SELECT * FROM orders WHERE customer_id = 42');
--  2556230741

SELECT sta.sql_id('SELECT * FROM orders WHERE customer_id = 43');
--  2556230741 is the same only for the same text; see the note below

SELECT sta.sql_hash('SELECT * FROM orders WHERE customer_id = 42');
-- -808386326668075698

SELECT sta.sql_hash('SELECT * FROM orders WHERE customer_id = 43');
-- -808386326668075698   (the same: the literals do not matter)

SELECT * FROM sta.queryid_info('SELECT * FROM orders WHERE customer_id = 42');
```

```
    queryid     |     sql_id     |            sql_hash             |   normalized
----------------+----------------+--------------------------------+------------------
 -4644307853832973059 |       2556230741 | -808386326668075698 | SELECT * FROM orders WHERE customer_id = $1
```

`sta.queryid_info()` also returns the workload of the statement: the number
of calls, the total and mean time, the block counters and whether the
statement is in `pg_stat_statements` at all.

**Why `sta.sql_id()` is useful.** `pg_stat_statements` identifies a
statement by its *normalised* text, so two statements that differ only in
a literal share one query id, and the statistics of both are mixed
together. `sta.sql_id()` gives the *exact* text its own id, so a report can
name the statement the way the application wrote it.

---

## 9. Validate a proposed change

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

## 10. Command line interface

`scripts/pg_sta_ctl` wraps the whole API.

```bash
# the transport is detected automatically: SSH to the development VM when the
# VM is reachable, the local psql client otherwise
./scripts/pg_sta_ctl --database appdb report

# force the transport
./scripts/pg_sta_ctl --ssh    --database appdb report   # over SSH to the VM
./scripts/pg_sta_ctl --local  --database appdb report   # local psql client

# machine readable output
./scripts/pg_sta_ctl -d appdb -o json report > findings.json
./scripts/pg_sta_ctl -d appdb -o markdown report > findings.md

# the change itself: the action plan and the runnable script
./scripts/pg_sta_ctl -d appdb actions "SELECT * FROM orders WHERE customer_id = 42"
./scripts/pg_sta_ctl -d appdb script  "SELECT * FROM orders WHERE customer_id = 42" > fix.sql

# the plan before and after a proposed change, and how much it gains
./scripts/pg_sta_ctl -d appdb before-after \
    "SELECT * FROM order_details WHERE order_id = 500000" \
    "CREATE INDEX idx_od_order_id ON order_details (order_id)"

# the plan before and after the change, for every statement of the workload
./scripts/pg_sta_ctl -d appdb --statements 5 before-after-report

# the plan of a statement, written out in words
./scripts/pg_sta_ctl -d appdb --analyze plan-explanation \
    "SELECT employee_id, employee_name FROM employees WHERE department_id = 2"

# the whole plan as one script, with the plan before and after every step
./scripts/pg_sta_ctl -d appdb --statements 5 script --plans > fix.sql
./scripts/pg_sta_ctl -d appdb --statements 5 script --no-plans > fix.sql

# the identifiers of a statement, the Oracle way
./scripts/pg_sta_ctl -d appdb sqlid "SELECT * FROM orders WHERE customer_id = 42"
```

The scripts work unchanged on the workstation and on the database host
itself. On the host, the local `psql` client is used and it connects
through the unix socket in `/var/run/postgresql` as the `postgres` user:

```bash
# on the database host, as the postgres user
cd /var/lib/pgsql/pg_sta
./scripts/pg_sta_ctl --database appdb report
```

> **Keep the copy on the host up to date.** The tree in
> `/var/lib/pgsql/pg_sta` is a **copy** of the source tree; it is not
> updated by `make install`. After a new version is installed, refresh it
> so that the `postgres` user runs the same code as everybody else:
>
> ```bash
> # on the database host
> sudo -u postgres rm -rf /var/lib/pgsql/pg_sta.new
> sudo -u postgres cp -a /home/vagrant/pg_sta /var/lib/pgsql/pg_sta.new
> sudo -u postgres rm -rf /var/lib/pgsql/pg_sta.old
> sudo mv /var/lib/pgsql/pg_sta /var/lib/pgsql/pg_sta.old
> sudo mv /var/lib/pgsql/pg_sta.new /var/lib/pgsql/pg_sta
> sudo chown -R postgres:postgres /var/lib/pgsql/pg_sta
> ```
>
> A quick check that the copy matches the source tree:
>
> ```bash
> diff -r /home/vagrant/pg_sta /var/lib/pgsql/pg_sta \
>   --exclude=.git --exclude='*.o' --exclude='*.so'
> ```

When the transport falls back to the local client the scripts say so once:

```
pg_sta: no SSH access to 127.0.0.1:2201; using the local psql client
```

Every command except `install`, `regress`, `qa` and `load-sample-data` first
checks that the `pg_sta` extension exists in the target database and
reports what to do when it does not:

```
pg_sta_ctl: the pg_sta extension is not installed in database 'appdb'.
             Install it with:
               sudo -u postgres psql -d 'appdb' -c 'CREATE EXTENSION pg_sta;'
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
| `actions [SQL]` | the action plan: every recommended change as a runnable statement |
| `script [SQL]` | the whole plan as one commented, runnable file (`--plans` / `--no-plans`) |
| `before-after SQL [CHANGE]` | the plan before and after a change, and the benefit of the change |
| `before-after-report [SQL]` | the plan before and after the change, for every statement of the workload |
| `tuning-report SQL [--out DIR]` | the tuning report of one statement, written as the four files of the Oracle SQL Tuning Advisor |
| `plan-explanation SQL` | the plan of a statement, written out in words |
| `queryid SQL` | the canonical query id and its normalised text |
| `sqlid SQL` | every identifier of a statement: query id, SQL id, SQL hash |
| `explain SQL` | the execution plan as JSON |
| `plan-advice SQL` | PostgreSQL 19 style plan advice for one statement |
| `advice ADVICE SQL` | plan one statement with an advice string applied |
| `stash list` | list the advice stashes |
| `stash create NAME` | create an advice stash |
| `stash drop NAME` | drop an advice stash |
| `stash show [NAME]` | show the contents of an advice stash |
| `stash set NAME QID ADVICE` | store advice for a query id in a stash |
| `stash remove NAME QID` | remove the advice stored for a query id |
| `diff [SCHEMA]` | differences between the two most recent snapshots of a schema |
| `record SCOPE [TARGET]` | record an advisory run in the audit trail |
| `catalog` | the catalogue of every finding the advisor knows |
| `server-info` | version and configuration of the server |
| `load-sample-data` | create the sample tables and generate a workload |
| `install` | build and install the extension |
| `regress` | run the regression suite |
| `qa` | run the QA suite |

### 10.1 The before/after report from the command line

```console
$ ./scripts/pg_sta_ctl -d appdb before-after \
      "SELECT * FROM order_details WHERE order_id = 500000" \
      "CREATE INDEX idx_od_order_id ON order_details (order_id)"
pg_sta: the plan before and after the change

statement:  SELECT * FROM order_details WHERE order_id = 500000
change:     CREATE INDEX idx_od_order_id ON order_details (order_id)
change type: CREATE_INDEX

--- BEFORE -----------------------------------------------------
Gather  (cost=1000.00..13561.43 rows=1 width=28) (actual time=12.888..13.118 rows=1 loops=1)
  Workers Planned: 2
  Workers Launched: 2
  Buffers: shared hit=7353
  ->  Parallel Seq Scan on order_details  (cost=0.00..12561.33 rows=1 width=28) (actual time=8.008..9.875 rows=0 loops=3)
        Filter: (order_id = 500000)
        Rows Removed by Filter: 333333
        Buffers: shared hit=7353
Planning Time: 0.021 ms
Execution Time: 13.125 ms

--- AFTER ------------------------------------------------------
Index Scan using idx_od_order_id on order_details  (cost=0.42..2.64 rows=1 width=28) (actual time=0.001..0.001 rows=1 loops=1)
  Index Cond: (order_id = 500000)
  Buffers: shared hit=4
Planning Time: 0.006 ms
Execution Time: 0.004 ms

--- reading of the plan before ---------------------------------
- gather
    1 rows estimated, 1 rows returned, 13.006 ms, 7353 buffers hit
  - parallel seq scan on public.order_details
      filter: (order_details.order_id = 500000)
      1 rows estimated, 0 rows returned, in 3 loops, 9.741 ms, 7353 buffers hit

The plan is a parallel gather over order_details. The outer side reads every row of order_details. The step that costs the most is the parallel seq scan on public.order_details: 29.223 ms in total across 3 loops; the loops run at the same time, so the step can account for more than the 13.006 ms the statement took, and 7353 of the 7353 buffers. The statement returned 1 row. Planning took 0.021 ms, the execution 13.125 ms, and the plan touched 7353 buffers, all of them from the cache.
--- reading of the plan after ----------------------------------
- index scan using idx_od_order_id on public.order_details
    index cond: (order_details.order_id = 500000)
    1 rows estimated, 1 rows returned, 0.011 ms, 4 buffers hit

The plan is an index scan using idx_od_order_id on order_details. The step that costs the most is the index scan using idx_od_order_id: 0.011 ms of the 0.011 ms in total, and 4 of the 4 buffers. The statement returned 1 row. Planning took 0.006 ms, the execution 0.004 ms, and the plan touched 4 buffers, all of them from the cache.
--- benefit ----------------------------------------------------
before:      13.661 ms
after:       0.014 ms
improvement: 99.90 % (TIME)
buffers:     7353 -> 4 total
buffer split: 7353 hit / 0 read  ->  4 hit / 0 read
rows:        1 -> 1 (same number of rows: true)
row by row:  (the change does not change the rows)
assumptions: (none)
plan changed: true
rows match:   true
verdict:      RECOMMENDED
plan changes:
  Gather  ->  Index Scan on public.order_details using idx_od_order_id
  Seq Scan on public.order_details  ->  (removed)
notes:
The change was applied in a subtransaction and rolled back; the database is unchanged.
```

For a **rewrite** the command also prints the row-by-row comparison and
the result of the assumption checks:

```console
row by row:  {"before_rows": "1", "after_rows": "1", "rows_in_both": "1",
              "only_before": "0", "only_after": "0", "rows_identical": true,
              "order_comparable": false}
assumptions: [{"pattern": "SELECT_STAR", "status": "PASS", ...}]
```

### 10.1a The plan written out in words

```console
$ ./scripts/pg_sta_ctl -d appdb --analyze plan-explanation \
      "SELECT employee_id, employee_name FROM employees WHERE department_id = 2"
- gather
    10,250 rows estimated, 10,000 rows returned, 14.640 ms, 7353 buffers hit
  - seq scan on public.employees
      filter: (employees.department_id = 2)
      4,271 rows estimated, 3,333 rows returned, in 3 loops, 9.116 ms, 7353 buffers hit

The plan is a parallel gather over employees. The outer side reads every row of employees. The step that costs the most is the seq scan on public.employees: 27.348 ms in total across 3 loops; the loops run at the same time, so the step can account for more than the 14.640 ms the statement took, and 7353 of the 7353 buffers. The statement returned 10,000 rows. Planning took 0.076 ms, the execution 14.832 ms, and the plan touched 7353 buffers, all of them from the cache.
```

### 10.2 The identifiers of a statement from the command line

```console
$ ./scripts/pg_sta_ctl -d appdb sqlid "SELECT * FROM orders WHERE customer_id = 42"
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

### 10.3 Plan advice and the advice stash

The two commands that mirror the PostgreSQL 19 plan-advice features:

```bash
# what would PostgreSQL 19 advise for this statement?
./scripts/pg_sta_ctl --database appdb plan-advice \
    "SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id
      WHERE c.region = 'eu'"

# plan it with an advice string applied
./scripts/pg_sta_ctl --database appdb advice "HASH_JOIN(c)" \
    "SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id
      WHERE c.region = 'eu'"
```

A stash stores advice per query id so that it can be applied later without
repeating the advice string:

```bash
./scripts/pg_sta_ctl --database appdb stash create nightly
./scripts/pg_sta_ctl --database appdb stash set nightly \
    "$(./scripts/pg_sta_ctl --database appdb queryid 'SELECT 1' | head -1 | cut -d: -f2 | tr -d ' ')" \
    "SEQ_SCAN(orders)"
./scripts/pg_sta_ctl --database appdb stash show nightly
./scripts/pg_sta_ctl --database appdb stash list
./scripts/pg_sta_ctl --database appdb stash remove nightly <queryid>
./scripts/pg_sta_ctl --database appdb stash drop nightly
```

The same operations from SQL are described in
[pg19-compatibility.md](pg19-compatibility.md).

### 10.4 The before/after report for the whole workload, from the command line

`before-after-report` measures every recommended change against the
statement it belongs to and prints the plan before, the plan after and
the benefit:

```console
$ ./scripts/pg_sta_ctl -d appdb --statements 3 before-after-report
pg_sta: the plan before and after the change, for every statement
database: appdb
window:   window


--- 1. orders ---
statement:    SELECT * FROM orders
 WHERE customer_id NOT IN (SELECT customer_id FROM customers WHERE email LIKE $1)
change type:  REWRITE
change:       SELECT order_id,
       customer_id,
       order_date
FROM orders
WHERE NOT EXISTS (SELECT 1 FROM customers WHERE email LIKE $1 AND customers.customer_id = orders.customer_id)
measured:     ESTIMATED

--- PLAN BEFORE --------------------------------------------
Seq Scan on orders  (cost=15844.76..34714.76 rows=500000 width=24)
  Filter: (NOT (ANY (customer_id = (hashed SubPlan 1).col1)))
  SubPlan 1
    ->  Gather  (cost=1000.00..15832.26 rows=5000 width=8)
          Workers Planned: 3
          ->  Parallel Seq Scan on customers  (cost=0.00..14332.26 rows=1613 width=8)
                Filter: ((email)::text ~~ $1)

--- PLAN AFTER ---------------------------------------------
Merge Anti Join  (cost=16139.88..43104.48 rows=995000 width=24)
  Merge Cond: (orders.customer_id = customers.customer_id)
  ->  Index Scan using idx_orders_customer_id on orders  (cost=0.42..24390.03 rows=1000000 width=24)
  ->  Sort  (cost=16139.45..16151.95 rows=5000 width=8)
        Sort Key: customers.customer_id
        ->  Gather  (cost=1000.00..15832.26 rows=5000 width=8)
              Workers Planned: 3
              ->  Parallel Seq Scan on customers  (cost=0.00..14332.26 rows=1613 width=8)
                    Filter: ((email)::text ~~ $1)

--- benefit -----------------------------------------------
before:       - ms
after:        - ms
cost:         34714.8 -> 43104.5
gain:         -24.2 % (COST)
buffers:      - -> -
buffer split: - hit / - read  ->  - hit / - read
rows:         - -> -
row by row:   (the change does not change the rows)
assumptions:  (none)
plan changed: true
rows match:   true
verdict:      REJECTED
plan changes:
  Seq Scan on public.orders  ->  Merge Join
  Gather  ->  Index Scan on public.orders using idx_orders_customer_id
  Seq Scan on public.customers  ->  Sort
  (added)  Gather
  (added)  Seq Scan on public.customers
notes:
The change is the rewritten statement, so the "after" plan is the plan of the new text.
```

The report is **read-only in effect**: every change is applied in a
subtransaction and rolled back, so nothing is left behind in the
database. The times are empty and the verdict comes from the estimated
cost when the statement uses parameter placeholders (`$1`) and cannot be
run — the measurement then says `ESTIMATED` instead of `MEASURED`.

| Flag | Meaning |
|---|---|
| `--statements N` | how many statements of the workload the report covers (default 10) |
| `--iterations N` | how often each statement is measured (default 3) |
| `--window W` | `window`, `cumulative` or `top` |
| `--no-plans` | skip the plan blocks; only the summary is printed |

Connection settings come from the environment:

| Variable | Default | Meaning |
|---|---|---|
| `PG_STA_HOST` | `127.0.0.1` | SSH host of the database server |
| `PG_STA_SSH_PORT` | `2201` | SSH port |
| `PG_STA_SSH_KEY` | `~/.vagrant.d/insecure_private_key` | SSH private key |
| `PG_STA_PGDATABASE` | `postgres` | default database |

### 10.5 The tuning report, the way Oracle writes it

The Oracle SQL Tuning Advisor writes the result of an analysis as a set of
report files.  `tuning-report` writes the same set for a statement:

```console
$ ./scripts/pg_sta_ctl -d appdb tuning-report \
      "SELECT * FROM orders WHERE customer_id = 42" \
      --out /tmp/report --iterations 3
wrote /tmp/report/2556230741.txt
wrote /tmp/report/2556230741_indx.txt
wrote /tmp/report/2556230741_multiple_plan.txt
wrote /tmp/report/2556230741_sql_profile.txt
```

| File | What it holds |
|---|---|
| `<sql_id>.txt` | the general information, every finding, the additional information and the explain plans |
| `<sql_id>_indx.txt` | the findings about the indexes and the plan that was measured with the index |
| `<sql_id>_multiple_plan.txt` | the findings about the indexes, the finding about the alternative plans and the plans themselves |
| `<sql_id>_sql_profile.txt` | the finding about the recommended change, the finding about the alternative plans and the explain plans |

The same four files can be produced from SQL:

```sql
SELECT sta.tuning_report('SELECT * FROM orders WHERE customer_id = 42', 3, 60);
```

The function returns all four files as one text, separated by the markers
`>>> FILE: <name>` and `<<< END FILE: <name>`, so that the statement is
measured once instead of four times.

| Flag | Meaning |
|---|---|
| `--out DIR` | the directory the four files are written to (default: the current directory) |
| `--iterations N` | how often each statement is measured (default 3) |
| `--time-limit N` | the time limit of the analysis, in seconds (default 60) |

Every file opens with the general information section of the Oracle report:

```
RECOMMENDATIONS
===============================================================================
GENERAL INFORMATION SECTION
-------------------------------------------------------------------------------
    SQL ID          : 2556230741
    SQL Text        : SELECT * FROM orders WHERE customer_id = 42
    Schema Name     : public
```

and closes with the sections the Oracle report carries — `FINDINGS SECTION`,
`ADDITIONAL INFORMATION SECTION`, `EXPLAIN PLANS SECTION` and
`ALTERNATIVE PLANS SECTION`.

The numbers in the report are real measurements: every candidate change is
applied in a subtransaction, the statement is measured with and without it,
and the change is rolled back.  The report says so in its additional
information section.

---

## 11. Tuning the thresholds

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
\i /usr/pgsql-17/share/extension/pg_sta--0.1.7.sql
```

### 11.1 Server settings

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

## 12. Safety guarantees

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

## 13. Complete worked example

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

## 14. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `make: *** No targets specified and no makefile found.` | Wrong directory — there is no Makefile in `/var/lib/pgsql` or in `/usr/pgsql-17/bin` | `cd` into the pg_sta source tree (on the VM: `/home/vagrant/pg_sta`) |
| `make: *** No rule to make target 'install'.` | Same as above, plus a missing `PGXS` include | `cd` into the source tree; check that `pg_config --pgxs` resolves |
| `ssh: connect to host 127.0.0.1 port 2201: Connection refused` and `Warning: Identity file .../.vagrant.d/insecure_private_key not accessible` | The CLI was run **on the database host**, where the Vagrant port forward does not exist, and the SSH key of the workstation is not present | The CLI now falls back to the local `psql` client automatically and says so. To force it: `--local`. On the host the key path is irrelevant |
| `pg_sta_ctl: the pg_sta extension is not installed in database 'appdb'.` | The extension was created in another database only | `sudo -u postgres psql -d appdb -c 'CREATE EXTENSION pg_sta;'` |
| `pg_sta: 'make install' needs root privileges and 'sudo' is not usable for the current user` | `make install` writes into the PostgreSQL tree and needs root, but the current account has no usable `sudo` | Run the build as `root`, or as `vagrant`, which has passwordless `sudo` |
| `curl: (22) The requested URL returned error: 404` | The branch or commit name in the tarball URL is wrong | Use `main`, or the exact commit SHA from `git ls-remote` |
| `ERROR: extension "pg_sta" is not available` | Not installed into the PostgreSQL tree | `sudo make PG_CONFIG=... install`, then restart nothing — `CREATE EXTENSION` picks it up |
| `ERROR: could not access file "$libdir/pg_sta"` | `pg_sta.so` missing or stale | Re-run `make install`; check `pg_config --pkglibdir` |
| `ERROR: permission denied for table workload_sample` | The calling role is not the owner | Run as the extension owner, or `GRANT USAGE ON SCHEMA sta TO <role>` |
| `workload_advice()` returns nothing | `pg_stat_statements` is not loaded | `SHOW shared_preload_libraries;` — it must contain `pg_stat_statements` |
| `ERROR: relation "orders" does not exist` from `sta.plan_advice_string()` | The advice is read from a **live** plan, so the relations of the statement must exist in the database — as in PostgreSQL 19 | Create the tables, or load the demo fixture: `./scripts/load_sample_data.sh --database appdb` |
| `ERROR: sta.explain: the statement refers to a relation or a column that does not exist here` | The statement belongs to another database — the advisor was run against a database that does not hold the relation | The hint names the database that is connected to; run the advisor against the database of the workload |
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
