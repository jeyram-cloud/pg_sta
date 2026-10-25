-- =========================================================================
-- pg_sta QA suite -- synthetic workload with known, deliberate defects
-- =========================================================================
--
-- The QA suite differs from the regression suite in intent:
--
--   * the regression suite (sql/pg_sta.sql) asserts *contract* behaviour:
--     deterministic output, stable types, no crashes, documented errors.
--   * the QA suite asserts *detection capability*: for a workload that was
--     built on purpose to contain a known set of defects, pg_sta must
--     actually report those defects.
--
-- Every defect injected below is listed in the "expected findings" table in
-- test/qa_assertions.sql, which cross-checks the findings that were
-- actually produced against that table.
--
-- The QA suite runs entirely inside its own schema (sta_qa) of a dedicated
-- QA database.  It never touches objects outside that schema.
--
-- Determinism
-- -----------
-- The advisory functions read the live statistics of the server, and the
-- statistics of the current backend are only published when its
-- transaction ends.  The suite therefore
--
--   * disables autovacuum on the fixture tables, so that neither a
--     background VACUUM nor a background ANALYZE can change the state the
--     suite deliberately created,
--   * resets the per-relation counters of every fixture table, so that a
--     repeated run cannot inherit the row counts of a previous one,
--   * runs the steps in several *phases*, and every phase in its own
--     session (see test/run_qa.sh).  A phase boundary is a session
--     boundary, and a session boundary forces the pending statistics of
--     the session to be published.
--
-- Why the phase boundary matters
-- ------------------------------
-- PostgreSQL 17 keeps the relation counters of a backend in a pending
-- entry and publishes them to the shared statistics only when the backend
-- flushes them, which happens when it goes idle (and at the latest when
-- the session ends).  ANALYZE, in contrast, writes the row counts it
-- computes *directly* into the shared statistics.  If the DML and the
-- ANALYZE run in the same session and the pending entry has not been
-- flushed yet, the later flush adds the DML deltas on top of the values
-- that ANALYZE has just written: n_live_tup ends up at twice the real row
-- count and n_mod_since_analyze stays at the number of changed rows even
-- though the table was just analyzed.  Splitting the fixture into phases
-- -- one session each -- removes that race and makes the statistics
-- deterministic.
-- =========================================================================

-- =========================================================================
-- Phase 1 -- clean slate and fixture data
-- =========================================================================
-- @phase 1

\set ON_ERROR_STOP on

SET client_min_messages = warning;

-- -------------------------------------------------------------------------
-- 0. Clean slate
-- -------------------------------------------------------------------------
DROP SCHEMA IF EXISTS sta_qa CASCADE;
CREATE SCHEMA sta_qa;

SET search_path = sta_qa, public;

-- =========================================================================
-- 1. Fixture tables
-- =========================================================================

-- 1a. "big_events": a large table whose filter column is not indexed.
--     Expected to trigger SEQ_SCAN_ON_LARGE_TABLE and an index proposal.
CREATE TABLE big_events (
    id           bigserial PRIMARY KEY,
    customer_id  bigint      NOT NULL,
    status       text        NOT NULL,
    amount       numeric(12,2) NOT NULL,
    payload      text        NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- 1b. "unanalysed": 5000 rows, never analyzed, no primary key, no indexes.
--     Expected to trigger NEVER_ANALYZED, NO_PRIMARY_KEY and NO_INDEXES.
CREATE TABLE unanalysed (
    id     integer,
    label  text
);

-- 1c. "stale_stats": analyzed, then most of its rows deleted, so that the
--     planner works with out-of-date statistics and the table accumulates
--     dead tuples.  Expected to trigger STALE_STATISTICS and
--     HIGH_DEAD_TUPLES.
CREATE TABLE stale_stats (
    id      integer PRIMARY KEY,
    payload text
);

-- 1d. "hot_path": a small table with a frequently filtered, unindexed
--     column.  A sequential scan over it is appropriate, so the advisor
--     must report SEQ_SCAN_ON_SMALL_TABLE and not a high-severity problem.
CREATE TABLE hot_path (
    id    integer PRIMARY KEY,
    value text
);

-- 1e. "lookup": the inner side of a join.
CREATE TABLE lookup (
    id    integer PRIMARY KEY,
    label text
);

-- Autovacuum must not touch the fixture tables: a background VACUUM would
-- remove the dead tuples and a background ANALYZE would refresh the
-- statistics, both of which would erase the defects under test.
ALTER TABLE big_events   SET (autovacuum_enabled = false);
ALTER TABLE unanalysed   SET (autovacuum_enabled = false);
ALTER TABLE stale_stats  SET (autovacuum_enabled = false);
ALTER TABLE hot_path     SET (autovacuum_enabled = false);
ALTER TABLE lookup       SET (autovacuum_enabled = false);

-- The statistics collector keeps the counters of a dropped relation under
-- its OID.  When PostgreSQL hands that OID out again -- which is exactly
-- what happens when the fixture is recreated for a second QA run -- the
-- new relation inherits the row counts of the old one and the suite
-- measures stale numbers.  Resetting the counters of each freshly created
-- fixture table makes the setup reproducible, no matter how often it runs.
SELECT pg_stat_reset_single_table_counters('sta_qa.big_events'::regclass);
SELECT pg_stat_reset_single_table_counters('sta_qa.unanalysed'::regclass);
SELECT pg_stat_reset_single_table_counters('sta_qa.stale_stats'::regclass);
SELECT pg_stat_reset_single_table_counters('sta_qa.hot_path'::regclass);
SELECT pg_stat_reset_single_table_counters('sta_qa.lookup'::regclass);

INSERT INTO hot_path (id, value)
SELECT g, 'value-' || g FROM generate_series(1, 200) g;

INSERT INTO lookup (id, label)
SELECT g, 'label-' || g FROM generate_series(1, 200) g;

-- Fill big_events with enough rows that a sequential scan is measurably
-- more expensive than an index lookup.
INSERT INTO big_events (customer_id, status, amount, payload)
SELECT (g % 500),
       (ARRAY['new','paid','cancelled','refunded'])[1 + (g % 4)],
       (g % 10000)::numeric / 100,
       repeat('x', 100)
FROM generate_series(1, 120000) g;

-- The never-analyzed table needs a realistic size, otherwise the size
-- thresholds of the advisor would (correctly) not fire.
INSERT INTO unanalysed (id, label)
SELECT g, 'label-' || g FROM generate_series(1, 5000) g;

-- stale_stats: analyze first, then delete most of the rows.  The planner
-- statistics stay at 20000 rows while only 8000 remain, and the deleted
-- row versions are counted as dead tuples.
INSERT INTO stale_stats (id, payload)
SELECT g, 'old-' || g FROM generate_series(1, 20000) g;

-- =========================================================================
-- Phase 2 -- make stale_stats stale
-- =========================================================================
-- The ANALYZE and the DELETE must not share a session with the INSERTs
-- above: the pending row-count deltas of that session would be published
-- *after* the ANALYZE and would overwrite the values it has just written.
-- @phase 2

SET client_min_messages = warning;

ANALYZE sta_qa.stale_stats;

DELETE FROM sta_qa.stale_stats WHERE id <= 12000;

-- =========================================================================
-- Phase 3 -- analyze the healthy control group
-- =========================================================================
-- These tables are analyzed on purpose: they are the "healthy" control
-- group of the suite and must not be reported as stale.
-- @phase 3

SET client_min_messages = warning;

ANALYZE sta_qa.big_events;
ANALYZE sta_qa.hot_path;
ANALYZE sta_qa.lookup;

-- =========================================================================
-- Phase 4 -- capture a workload into sta.workload_sample
-- =========================================================================
-- @phase 4

SET client_min_messages = warning;

-- sta.collect() reads pg_stat_statements.  In the QA database the
-- statistics may be empty, so we seed a deterministic, synthetic workload
-- directly into sta.workload_sample.  That is exactly the table the
-- workload advice reads from, so the end-to-end path is still exercised.
TRUNCATE sta.workload_sample;
TRUNCATE sta.table_stats_sample;
TRUNCATE sta.index_sample;
TRUNCATE sta.advice_run;

-- All rows share one timestamp: sta._workload_delta() selects the snapshot
-- by exact equality on captured_at, so per-row clock_timestamp() values
-- would split the workload into four one-row snapshots.
INSERT INTO sta.workload_sample
    (captured_at, queryid, query, calls, total_exec_time, mean_exec_time,
     rows, shared_blks_hit, shared_blks_read, temp_blks_read,
     temp_blks_written, blk_read_time, blk_write_time, wal_records, source)
SELECT now(), v.*
FROM (VALUES
    -- The dominant statement: slow in total.
    (1001::bigint,
     'SELECT * FROM sta_qa.big_events WHERE status = ''paid''',
     1200::bigint, 96000.0, 80.0, 36000::bigint, 100::bigint, 9000::bigint,
     0::bigint, 0::bigint, 0.0, 0.0, 0::bigint, 'qa-synthetic'),
    -- The most frequent statement: cheap individually, but hot.
    (1002::bigint,
     'SELECT * FROM sta_qa.hot_path WHERE id = 42',
     95000::bigint, 19000.0, 0.2, 1::bigint, 95000::bigint, 0::bigint,
     0::bigint, 0::bigint, 0.0, 0.0, 0::bigint, 'qa-synthetic'),
    -- Cache-hostile: almost every block comes from storage.
    (1003::bigint,
     'SELECT * FROM sta_qa.big_events WHERE customer_id = 17',
     40::bigint, 24000.0, 600.0, 240::bigint, 10::bigint, 8900::bigint,
     0::bigint, 0::bigint, 0.0, 0.0, 0::bigint, 'qa-synthetic'),
    -- Temp-file heavy: sorts far more than fits in work_mem.
    (1004::bigint,
     'SELECT id, payload FROM sta_qa.big_events ORDER BY payload, id',
     15::bigint, 30000.0, 2000.0, 120000::bigint, 500::bigint, 40000::bigint,
     1200::bigint, 3400::bigint, 0.0, 0.0, 0::bigint, 'qa-synthetic')
) AS v(queryid, query, calls, total_exec_time, mean_exec_time, rows,
       shared_blks_hit, shared_blks_read, temp_blks_read, temp_blks_written,
       blk_read_time, blk_write_time, wal_records, source);

-- =========================================================================
-- 3. Publish the statistics of this session
-- =========================================================================
-- The fixture tables were already published by the phase boundaries; this
-- only makes the counters of sta.workload_sample visible right away
-- instead of at the end of the session.
SELECT pg_stat_force_next_flush();

-- =========================================================================
-- Phase 5 -- snapshot-diff fixture: build the relation
-- =========================================================================
-- sta.snapshot_diff() compares two sta.collect() snapshots.  The fixture
-- lives in its own schema so that it cannot interfere with the workload
-- assertions, which read the synthetic snapshot created in phase 4.
--
-- Every phase below runs in its own session.  A session publishes its
-- pending row-count deltas when it goes idle, and a session that both
-- changes a relation and captures its statistics would report the
-- pending delta on top of the captured value.
-- @phase 5

SET client_min_messages = warning;

DROP SCHEMA IF EXISTS sta_diff CASCADE;
CREATE SCHEMA sta_diff;

CREATE TABLE sta_diff.churn (
    id  integer PRIMARY KEY,
    val text
);

INSERT INTO sta_diff.churn (id, val)
SELECT g, 'v' || g FROM generate_series(1, 5000) g;

CREATE INDEX churn_val_idx ON sta_diff.churn (val);

ANALYZE sta_diff.churn;

-- =========================================================================
-- Phase 6 -- first snapshot
-- =========================================================================
-- The index is used before the snapshot is taken, so that the later
-- snapshot shows an index that has stopped being used.  ANALYZE resets
-- "modified since analyze" to zero, which makes the later staleness
-- finding deterministic.
-- @phase 6

SET client_min_messages = warning;
SET enable_seqscan = off;

ANALYZE sta_diff.churn;

DO $$
DECLARE
    i integer;
BEGIN
    FOR i IN 1..120 LOOP
        PERFORM count(*) FROM sta_diff.churn WHERE val = 'v42';
    END LOOP;
END
$$;

SELECT pg_stat_force_next_flush();

SELECT * FROM sta.collect();

-- The workload sample belongs to the synthetic fixture of phase 4.  The
-- diff fixture only needs the relation and index snapshots, so the real
-- pg_stat_statements rows of this collect() are removed again; the
-- workload assertions must keep seeing exactly the four synthetic rows.
DELETE FROM sta.workload_sample
 WHERE captured_at = (SELECT max(captured_at) FROM sta.workload_sample);

-- =========================================================================
-- Phase 7 -- churn between the two snapshots
-- =========================================================================
-- 3000 deletes create dead tuples and 5000 row changes make the
-- statistics stale.  No snapshot is taken here; that happens in phase 8.
-- @phase 7

SET client_min_messages = warning;

DELETE FROM sta_diff.churn WHERE id <= 3000;
UPDATE sta_diff.churn SET val = val || '-updated' WHERE id > 3000;

-- =========================================================================
-- Phase 8 -- second snapshot
-- =========================================================================
-- @phase 8

SET client_min_messages = warning;

SELECT pg_stat_force_next_flush();

SELECT * FROM sta.collect();

DELETE FROM sta.workload_sample
 WHERE captured_at = (SELECT max(captured_at) FROM sta.workload_sample);
