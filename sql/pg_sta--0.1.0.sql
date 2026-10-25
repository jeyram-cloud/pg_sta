/* pg_sta--0.1.0.sql -- PostgreSQL SQL Tuning Advisor */

\echo Use "CREATE EXTENSION pg_sta" to load this file. \quit

------------------------------------------------------------------------------
-- Schema
------------------------------------------------------------------------------
CREATE SCHEMA sta;

COMMENT ON SCHEMA sta IS
  'PostgreSQL SQL Tuning Advisor: workload, plan, statistics and index advice.';

------------------------------------------------------------------------------
-- C module entry points
--
-- These four functions are implemented in src/pg_sta.c.  They are the only
-- part of pg_sta that touches the query parser, the planner or the raw
-- pg_stat_statements catalogue.
------------------------------------------------------------------------------

CREATE FUNCTION sta.queryid(p_sql text)
RETURNS bigint
AS 'MODULE_PATHNAME', 'pg_sta_queryid'
LANGUAGE C
STRICT
PARALLEL SAFE;

COMMENT ON FUNCTION sta.queryid(text) IS
  'Canonical PostgreSQL query id of a statement, computed by the same machinery that '
  'pg_stat_statements uses, so the value matches pg_stat_statements.queryid exactly.';

CREATE FUNCTION sta.queryid_normalized(p_sql text)
RETURNS text
AS 'MODULE_PATHNAME', 'pg_sta_queryid_normalized'
LANGUAGE C
STRICT
PARALLEL SAFE;

COMMENT ON FUNCTION sta.queryid_normalized(text) IS
  'Statement text with every literal constant replaced by $n, matching the rendering '
  'used by pg_stat_statements.';

CREATE FUNCTION sta.explain(p_sql text, p_analyze boolean DEFAULT false)
RETURNS jsonb
AS 'MODULE_PATHNAME', 'pg_sta_explain'
LANGUAGE C
STRICT
PARALLEL SAFE
VOLATILE;

COMMENT ON FUNCTION sta.explain(text, boolean) IS
  'EXPLAIN (FORMAT JSON, VERBOSE, SETTINGS) of a single statement, optionally with '
  'ANALYZE and BUFFERS.  Only SELECT statements can be analysed.';

CREATE FUNCTION sta.server_info()
RETURNS jsonb
AS 'MODULE_PATHNAME', 'pg_sta_server_info'
LANGUAGE C
STRICT
PARALLEL SAFE;

COMMENT ON FUNCTION sta.server_info() IS
  'Server and extension metadata: versions, configuration and availability of the '
  'pg_stat_statements counters that pg_sta relies on.';

------------------------------------------------------------------------------
-- Snapshot storage
--
-- pg_sta never mutates the database it advises on.  It only records
-- observations (workload counters and table statistics) so that advice can
-- be based on a time window rather than on cumulative-since-forever totals.
------------------------------------------------------------------------------
CREATE TABLE sta.workload_sample (
    sample_id         bigserial PRIMARY KEY,
    captured_at       timestamptz NOT NULL DEFAULT clock_timestamp(),
    queryid           bigint      NOT NULL,
    query             text        NOT NULL,
    calls             bigint      NOT NULL,
    total_exec_time   double precision NOT NULL,
    mean_exec_time    double precision NOT NULL,
    rows              bigint      NOT NULL,
    shared_blks_hit   bigint,
    shared_blks_read  bigint,
    temp_blks_read    bigint,
    temp_blks_written bigint,
    blk_read_time     double precision,
    blk_write_time    double precision,
    wal_records       bigint,
    source            text        NOT NULL DEFAULT 'pg_stat_statements'
);

CREATE INDEX workload_sample_captured_at_idx
    ON sta.workload_sample (captured_at);
CREATE INDEX workload_sample_queryid_idx
    ON sta.workload_sample (queryid);

CREATE TABLE sta.table_stats_sample (
    sample_id           bigserial PRIMARY KEY,
    captured_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    schemaname          text   NOT NULL,
    relname             text   NOT NULL,
    reltuples           double precision,
    relpages            bigint,
    n_live_tup          bigint,
    n_dead_tup          bigint,
    n_mod_since_analyze bigint,
    last_analyze        timestamptz,
    last_autoanalyze    timestamptz,
    last_vacuum         timestamptz,
    last_autovacuum     timestamptz,
    seq_scan            bigint,
    seq_tup_read        bigint,
    idx_scan            bigint,
    idx_tup_fetch       bigint,
    heap_blks_hit       bigint,
    heap_blks_read      bigint,
    idx_blks_hit        bigint,
    idx_blks_read       bigint,
    write_tuples        bigint,
    analyze_count       bigint
);

CREATE INDEX table_stats_sample_captured_at_idx
    ON sta.table_stats_sample (captured_at);
CREATE INDEX table_stats_sample_rel_idx
    ON sta.table_stats_sample (schemaname, relname);

CREATE TABLE sta.index_sample (
    sample_id   bigserial PRIMARY KEY,
    captured_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    schemaname  text NOT NULL,
    tablename   text NOT NULL,
    indexname   text NOT NULL,
    indexdef    text NOT NULL,
    is_unique   boolean,
    is_primary  boolean,
    idx_scan    bigint,
    idx_tup_read bigint,
    idx_tup_fetch bigint
);

CREATE INDEX index_sample_captured_at_idx
    ON sta.index_sample (captured_at);

CREATE TABLE sta.advice_run (
    run_id        bigserial PRIMARY KEY,
    created_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
    scope         text NOT NULL,
    target        text,
    finding_count integer NOT NULL,
    tool          text NOT NULL DEFAULT 'pg_sta',
    notes         text
);

------------------------------------------------------------------------------
-- Small internal helpers
------------------------------------------------------------------------------

/*
 * Extract identifier-like tokens from a piece of SQL text.  Used to turn an
 * EXPLAIN filter expression into candidate index columns; the candidate list
 * is later intersected with the real column list of the relation, so this
 * function only has to be generous, not precise.
 */
CREATE FUNCTION sta.identifiers(p_text text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
    SELECT COALESCE(array_agg(DISTINCT m[1]), ARRAY[]::text[])
    FROM regexp_matches(p_text, '([A-Za-z_][A-Za-z0-9_$]*)', 'g') AS m
$$;

COMMENT ON FUNCTION sta.identifiers(text) IS
  'Identifier-like tokens found in a piece of SQL text.';

/*
 * A stable, comparable signature of a plan: the multiset of node types in
 * the plan tree.  Two plans with the same signature are considered to use
 * the same access paths.
 */
CREATE FUNCTION sta.plan_signature(p_plan jsonb)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE root AS (
        /*
         * Accept every shape the caller may have on hand: the full
         * EXPLAIN (FORMAT JSON) document (an array with one element), the
         * element itself, or a bare plan node.
         */
        SELECT CASE
                   WHEN jsonb_typeof(p_plan) = 'array'
                        THEN COALESCE((p_plan->0)->'Plan', p_plan->0)
                   WHEN jsonb_typeof(p_plan) = 'object' AND p_plan ? 'Plan'
                        THEN p_plan->'Plan'
                   ELSE p_plan
               END AS node
    ),
    nodes AS (
        SELECT node FROM root
        UNION ALL
        SELECT c.child
        FROM nodes n
        CROSS JOIN LATERAL jsonb_array_elements(
                CASE WHEN jsonb_typeof(n.node -> 'Plans') = 'array'
                     THEN n.node -> 'Plans' ELSE '[]'::jsonb END) AS c(child)
    )
    SELECT COALESCE(string_agg(t.node_type, ', ' ORDER BY t.node_type), '')
    FROM (SELECT node ->> 'Node Type' AS node_type
          FROM nodes
          WHERE node IS NOT NULL) t
$$;

COMMENT ON FUNCTION sta.plan_signature(jsonb) IS
  'Comparable signature of an EXPLAIN plan: sorted node types.  Accepts a full '
  'EXPLAIN (FORMAT JSON) document, its single element, or a bare plan node.';

/*
 * The text of a statement, looked up by canonical query id.  pg_stat_
-- statements is consulted first (it is authoritative), then pg_sta's own
-- samples.
 */
CREATE FUNCTION sta.statement_text(p_queryid bigint)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_text text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
    THEN
        SELECT s.query INTO v_text
        FROM pg_stat_statements s
        WHERE s.queryid = p_queryid
          AND s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
        ORDER BY s.calls DESC
        LIMIT 1;
    END IF;

    IF v_text IS NULL THEN
        SELECT w.query INTO v_text
        FROM sta.workload_sample w
        WHERE w.queryid = p_queryid
        ORDER BY w.sample_id DESC
        LIMIT 1;
    END IF;

    RETURN v_text;
END
$$;

COMMENT ON FUNCTION sta.statement_text(bigint) IS
  'Text of the statement identified by the given canonical query id.';

------------------------------------------------------------------------------
-- Advisory limits
--
-- pg_sta.max_findings is a GUC registered by the C core.  It caps how many
-- rows a single advisory call may return, so a caller cannot accidentally
-- pull the whole catalogue into memory.  The cap is applied on top of the
-- p_limit argument: the effective limit is the smaller of the two.
------------------------------------------------------------------------------

CREATE FUNCTION sta._max_findings()
RETURNS integer
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        NULLIF(current_setting('pg_sta.max_findings', true), '')::integer,
        200);
$$;

COMMENT ON FUNCTION sta._max_findings() IS
  'The effective cap on the number of rows an advisory function returns (pg_sta.max_findings).';

------------------------------------------------------------------------------
-- Snapshot collection
------------------------------------------------------------------------------

CREATE FUNCTION sta.collect(p_queryids bigint[] DEFAULT NULL)
RETURNS TABLE (
    sample_id   bigint,
    captured_at timestamptz,
    statements  integer,
    tables      integer
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_ts        timestamptz := clock_timestamp();
    v_has_pgss  boolean;
    v_statements integer := 0;
    v_tables     integer := 0;
    v_sample_id  bigint := 0;
BEGIN
    v_has_pgss := EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements');

    IF v_has_pgss THEN
        /*
         * pg_stat_statements changed its timing columns in PostgreSQL 17:
         * the single blk_read_time/blk_write_time counters were split into
         * shared_/local_/temp_ variants.  Projecting the view through
         * to_jsonb() keeps this function working on every supported
         * server version without version-specific SQL.
         */
        INSERT INTO sta.workload_sample
            (captured_at, queryid, query, calls, total_exec_time, mean_exec_time,
             rows, shared_blks_hit, shared_blks_read, temp_blks_read,
             temp_blks_written, blk_read_time, blk_write_time, wal_records)
        SELECT v_ts,
               (j->>'queryid')::bigint,
               j->>'query',
               (j->>'calls')::bigint,
               (j->>'total_exec_time')::double precision,
               (j->>'mean_exec_time')::double precision,
               (j->>'rows')::bigint,
               (j->>'shared_blks_hit')::bigint,
               (j->>'shared_blks_read')::bigint,
               (j->>'temp_blks_read')::bigint,
               (j->>'temp_blks_written')::bigint,
               CASE WHEN j ? 'blk_read_time'
                    THEN (j->>'blk_read_time')::double precision
                    ELSE COALESCE((j->>'shared_blk_read_time')::double precision, 0)
                       + COALESCE((j->>'local_blk_read_time')::double precision, 0)
                       + COALESCE((j->>'temp_blk_read_time')::double precision, 0)
               END,
               CASE WHEN j ? 'blk_write_time'
                    THEN (j->>'blk_write_time')::double precision
                    ELSE COALESCE((j->>'shared_blk_write_time')::double precision, 0)
                       + COALESCE((j->>'local_blk_write_time')::double precision, 0)
                       + COALESCE((j->>'temp_blk_write_time')::double precision, 0)
               END,
               (j->>'wal_records')::bigint
        FROM pg_stat_statements s
             CROSS JOIN LATERAL to_jsonb(s) j
        WHERE s.queryid IS NOT NULL
          AND s.queryid <> 0
          AND s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
          AND (p_queryids IS NULL OR s.queryid = ANY (p_queryids));

        GET DIAGNOSTICS v_statements = ROW_COUNT;
    ELSE
        RAISE NOTICE 'sta.collect: pg_stat_statements is not installed, '
                     'no workload counters were captured';
    END IF;

    /*
     * The per-table block I/O counters (heap_blks_hit and friends) were
     * removed from pg_stat_user_tables in PostgreSQL 16; the information
     * moved to pg_stat_io, which cannot be broken down per relation.
     * Projecting the view through to_jsonb() keeps this function working
     * on every supported server version: the columns are simply NULL on
     * servers that do not expose them.
     */
    INSERT INTO sta.table_stats_sample
        (captured_at, schemaname, relname, reltuples, relpages, n_live_tup,
         n_dead_tup, n_mod_since_analyze, last_analyze, last_autoanalyze,
         last_vacuum, last_autovacuum, seq_scan, seq_tup_read, idx_scan,
         idx_tup_fetch, heap_blks_hit, heap_blks_read, idx_blks_hit,
         idx_blks_read, write_tuples, analyze_count)
    SELECT v_ts, j->>'schemaname', j->>'relname', c.reltuples, c.relpages,
           (j->>'n_live_tup')::bigint,
           (j->>'n_dead_tup')::bigint,
           (j->>'n_mod_since_analyze')::bigint,
           (j->>'last_analyze')::timestamptz,
           (j->>'last_autoanalyze')::timestamptz,
           (j->>'last_vacuum')::timestamptz,
           (j->>'last_autovacuum')::timestamptz,
           (j->>'seq_scan')::bigint,
           (j->>'seq_tup_read')::bigint,
           (j->>'idx_scan')::bigint,
           (j->>'idx_tup_fetch')::bigint,
           (j->>'heap_blks_hit')::bigint,
           (j->>'heap_blks_read')::bigint,
           (j->>'idx_blks_hit')::bigint,
           (j->>'idx_blks_read')::bigint,
           COALESCE((j->>'n_tup_ins')::bigint, 0)
             + COALESCE((j->>'n_tup_upd')::bigint, 0)
             + COALESCE((j->>'n_tup_del')::bigint, 0),
           COALESCE((j->>'analyze_count')::bigint, 0)
             + COALESCE((j->>'autoanalyze_count')::bigint, 0)
    FROM pg_stat_user_tables s
         CROSS JOIN LATERAL to_jsonb(s) j
         JOIN pg_class c ON c.oid = s.relid;

    GET DIAGNOSTICS v_tables = ROW_COUNT;

    INSERT INTO sta.index_sample
        (captured_at, schemaname, tablename, indexname, indexdef, is_unique,
         is_primary, idx_scan, idx_tup_read, idx_tup_fetch)
    SELECT v_ts, ns.nspname, t.relname, i.relname,
           pg_get_indexdef(x.indexrelid), x.indisunique, x.indisprimary,
           COALESCE(s.idx_scan, 0), COALESCE(s.idx_tup_read, 0),
           COALESCE(s.idx_tup_fetch, 0)
    FROM pg_index x
    JOIN pg_class i ON i.oid = x.indexrelid
    JOIN pg_class t ON t.oid = x.indrelid
    JOIN pg_namespace ns ON ns.oid = t.relnamespace
    LEFT JOIN pg_stat_user_indexes s ON s.indexrelid = x.indexrelid;

    /*
     * currval() only works once the sequence has been advanced in this
     * session.  When pg_stat_statements is missing, or when it holds no
     * statement for this database yet, no workload row was inserted and the
     * sequence was never touched, so currval() would raise
     * "currval of sequence ... is not yet defined in this session".  The
     * row count tells us whether the sequence was advanced, so the sample
     * id is only read when there is one to report.
     */
    IF v_statements > 0 THEN
        v_sample_id := currval(pg_get_serial_sequence('sta.workload_sample', 'sample_id'));
    END IF;

    RETURN QUERY SELECT v_sample_id,
                        v_ts, v_statements, v_tables;
END
$$;

COMMENT ON FUNCTION sta.collect(bigint[]) IS
  'Capture a snapshot of workload counters, table statistics and index usage.';

CREATE FUNCTION sta.reset()
RETURNS void
LANGUAGE sql
AS $$
    TRUNCATE sta.workload_sample,
             sta.table_stats_sample,
             sta.index_sample,
             sta.advice_run;
$$;

COMMENT ON FUNCTION sta.reset() IS
  'Delete every snapshot and advice run recorded by sta.';

------------------------------------------------------------------------------
-- Audit trail
--
-- The advisory functions themselves stay read-only: writing a row for every
-- call would make a "SELECT ... FROM sta.recommendations()" a modifying
-- statement, which is a surprising property for an advisor.  Recording a
-- run is therefore an explicit, separate action.
------------------------------------------------------------------------------
CREATE FUNCTION sta.record_run(
    p_scope         text,
    p_target        text DEFAULT NULL,
    p_finding_count integer DEFAULT 0,
    p_notes         text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id bigint;
BEGIN
    INSERT INTO sta.advice_run (scope, target, finding_count, tool, notes)
    VALUES (p_scope, p_target, p_finding_count, 'pg_sta', p_notes)
    RETURNING run_id INTO v_run_id;

    RETURN v_run_id;
END
$$;

COMMENT ON FUNCTION sta.record_run(text, text, integer, text) IS
  'Record an advisory run in sta.advice_run and return its run_id.  '
  'The advisory functions do not write to the audit trail themselves, so that they stay read-only.';

------------------------------------------------------------------------------
-- Tunable thresholds
--
-- Keeping the decision thresholds in a table rather than hard-coded in the
-- function bodies lets an operator calibrate pg_sta for its own workload
-- without recompiling the extension.
------------------------------------------------------------------------------
CREATE TABLE sta.threshold (
    name        text PRIMARY KEY,
    value       double precision NOT NULL,
    unit        text,
    description text
);

INSERT INTO sta.threshold (name, value, unit, description) VALUES
 ('seq_scan_min_rows',            1000,   'rows',  'Relation size above which a sequential scan is reported'),
 ('estimate_mismatch_factor',     10,     'x',     'Plan/actual row ratio above which the estimate is reported as wrong'),
 ('sort_spill_min_kb',            1024,   'kB',    'Sort spill size above which an external sort is reported'),
 ('high_mean_exec_time_ms',       100,    'ms',    'Mean execution time above which a statement is reported'),
 ('high_frequency_calls',         100,    'calls', 'Call count above which a statement is reported as frequent'),
 ('low_cache_hit_pct',            90,     '%',     'Buffer cache hit ratio below which the workload is reported'),
 ('min_shared_blks_read',         1000,   'blocks','Shared block reads above which a cache hit ratio is meaningful'),
 ('min_temp_blks_written',        1000,   'blocks','Temp blocks written above which temp I/O is reported'),
 ('analyze_scale_factor',         0.1,    'ratio', 'Default autovacuum_analyze_scale_factor used for staleness detection'),
 ('analyze_base_threshold',       50,     'rows',  'Default autovacuum_analyze_threshold used for staleness detection'),
 ('dead_tuple_ratio',             0.2,    'ratio', 'Dead/live tuple ratio above which a vacuum is recommended'),
 ('dead_tuple_min',               1000,   'tuples','Absolute number of dead tuples above which a vacuum is recommended'),
 ('min_rows_removed_by_filter',   1000,   'rows',  'Rows discarded by a filter above which an index is recommended'),
 ('nested_loop_max_loops',        1000,   'loops', 'Actual loops above which a nested loop is reported'),
 ('high_total_cost',              10000,  'cost',  'Total cost above which a plan node is reported'),
 ('high_execution_time_ms',       1000,   'ms',    'Total execution time above which a plan is reported'),
 ('snapshot_growth_min_rows',     1000,   'rows',  'Row growth between two snapshots above which the growth is reported'),
 ('index_idle_min_scans',         100,    'scans', 'Scans an index had before it stopped being used, before it is reported');

COMMENT ON TABLE sta.threshold IS
  'Decision thresholds used by the advisory functions.  Adjust to match your workload.';

------------------------------------------------------------------------------
-- Validation playbook
------------------------------------------------------------------------------
CREATE FUNCTION sta.validation_steps(p_kind text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE p_kind
        WHEN 'index' THEN ARRAY[
            'Capture a baseline with EXPLAIN (ANALYZE, BUFFERS) and record the execution time and buffer counts.',
            'Create the candidate index (use CONCURRENTLY in production) and re-run the same EXPLAIN (ANALYZE, BUFFERS).',
            'Confirm the access path changed (Seq Scan -> Index Scan) and that the buffer reads dropped.',
            'Measure application-level latency over a representative window, before and after.',
            'Keep the index only if the improvement is repeatable and the write overhead is acceptable.']
        WHEN 'analyze' THEN ARRAY[
            'Run ANALYZE on the affected relation.',
            'Re-run EXPLAIN (ANALYZE) and confirm the planner estimate now matches the actual row count.',
            'Check pg_stat_statements for the statement and confirm total_exec_time did not regress.']
        WHEN 'vacuum' THEN ARRAY[
            'Run VACUUM (ANALYZE) on the affected relation.',
            'Confirm n_dead_tup dropped and the visibility map was updated.',
            'Re-run the workload and compare execution time and buffer counts.']
        WHEN 'config' THEN ARRAY[
            'Change the setting in a way that can be reverted immediately.',
            'Measure before and after over the same workload window.',
            'Confirm no regression in other statements before making the change permanent.']
        WHEN 'plan' THEN ARRAY[
            'Capture EXPLAIN (ANALYZE, BUFFERS) before the change.',
            'Apply the change.',
            'Capture EXPLAIN (ANALYZE, BUFFERS) after the change.',
            'Confirm both the plan shape and the execution time improved.']
        WHEN 'workload' THEN ARRAY[
            'Record the current mean and total execution time for the statement.',
            'Apply the change.',
            'Let the workload run for a comparable period.',
            'Compare mean and total execution time and the buffer hit ratio.']
        ELSE ARRAY['Measure before and after with the same workload.']
    END
$$;

COMMENT ON FUNCTION sta.validation_steps(text) IS
  'Standard validation procedure for a given kind of recommendation.';

------------------------------------------------------------------------------
-- Workload delta helper
------------------------------------------------------------------------------
CREATE FUNCTION sta._workload_delta(p_window text DEFAULT 'window')
RETURNS TABLE (
    queryid           bigint,
    query             text,
    calls             bigint,
    total_exec_time   double precision,
    mean_exec_time    double precision,
    rows              bigint,
    shared_blks_hit   bigint,
    shared_blks_read  bigint,
    temp_blks_read    bigint,
    temp_blks_written bigint,
    blk_read_time     double precision,
    blk_write_time    double precision
)
LANGUAGE sql
STABLE
AS $$
    WITH bounds AS (
        SELECT max(captured_at) AS latest FROM sta.workload_sample
    ),
    prev AS (
        SELECT max(captured_at) AS prev_at
        FROM sta.workload_sample
        WHERE captured_at < (SELECT latest FROM bounds)
    ),
    latest_snap AS (
        SELECT w.*
        FROM sta.workload_sample w
        WHERE w.captured_at = (SELECT latest FROM bounds)
    ),
    prev_snap AS (
        SELECT w.*
        FROM sta.workload_sample w
        WHERE w.captured_at = (SELECT prev_at FROM prev)
          AND (SELECT prev_at FROM prev) IS NOT NULL
    ),
    merged AS (
        SELECT
            l.queryid,
            l.query,
            CASE WHEN p_window = 'cumulative' OR pr.sample_id IS NULL
                 THEN l.calls
                 ELSE GREATEST(l.calls - COALESCE(pr.calls, 0), 0) END                       AS calls,
            CASE WHEN p_window = 'cumulative' OR pr.sample_id IS NULL
                 THEN l.total_exec_time
                 ELSE GREATEST(l.total_exec_time - COALESCE(pr.total_exec_time, 0), 0) END     AS total_exec_time,
            CASE WHEN p_window = 'cumulative' OR pr.sample_id IS NULL
                 THEN l.mean_exec_time
                 ELSE GREATEST(l.total_exec_time - COALESCE(pr.total_exec_time, 0), 0) END     AS total_exec_time_raw,
            CASE WHEN p_window = 'cumulative' OR pr.sample_id IS NULL
                 THEN l.rows
                 ELSE GREATEST(l.rows - COALESCE(pr.rows, 0), 0) END                           AS rows,
            CASE WHEN p_window = 'cumulative' OR pr.sample_id IS NULL
                 THEN l.shared_blks_hit
                 ELSE GREATEST(l.shared_blks_hit - COALESCE(pr.shared_blks_hit, 0), 0) END      AS shared_blks_hit,
            CASE WHEN p_window = 'cumulative' OR pr.sample_id IS NULL
                 THEN l.shared_blks_read
                 ELSE GREATEST(l.shared_blks_read - COALESCE(pr.shared_blks_read, 0), 0) END    AS shared_blks_read,
            CASE WHEN p_window = 'cumulative' OR pr.sample_id IS NULL
                 THEN l.temp_blks_read
                 ELSE GREATEST(l.temp_blks_read - COALESCE(pr.temp_blks_read, 0), 0) END        AS temp_blks_read,
            CASE WHEN p_window = 'cumulative' OR pr.sample_id IS NULL
                 THEN l.temp_blks_written
                 ELSE GREATEST(l.temp_blks_written - COALESCE(pr.temp_blks_written, 0), 0) END  AS temp_blks_written,
            CASE WHEN p_window = 'cumulative' OR pr.sample_id IS NULL
                 THEN l.blk_read_time
                 ELSE GREATEST(l.blk_read_time - COALESCE(pr.blk_read_time, 0), 0) END          AS blk_read_time,
            CASE WHEN p_window = 'cumulative' OR pr.sample_id IS NULL
                 THEN l.blk_write_time
                 ELSE GREATEST(l.blk_write_time - COALESCE(pr.blk_write_time, 0), 0) END        AS blk_write_time
        FROM latest_snap l
        LEFT JOIN prev_snap pr ON pr.queryid = l.queryid
    )
    SELECT
        m.queryid,
        m.query,
        m.calls,
        m.total_exec_time,
        CASE WHEN m.calls > 0 THEN m.total_exec_time / m.calls ELSE m.total_exec_time END,
        m.rows,
        m.shared_blks_hit,
        m.shared_blks_read,
        m.temp_blks_read,
        m.temp_blks_written,
        m.blk_read_time,
        m.blk_write_time
    FROM merged m
$$;

COMMENT ON FUNCTION sta._workload_delta(text) IS
  'Workload counters for the most recent snapshot, or the delta between the two most recent snapshots.';

------------------------------------------------------------------------------
-- Workload advice
------------------------------------------------------------------------------
CREATE FUNCTION sta.workload_advice(
    p_window         text    DEFAULT 'window',
    p_min_calls      bigint  DEFAULT 0,
    p_min_total_time double precision DEFAULT 0,
    p_limit          integer DEFAULT 50
)
RETURNS TABLE (
    finding_id       integer,
    category         text,
    severity         text,
    confidence       text,
    impact_score     integer,
    queryid          bigint,
    query            text,
    calls            bigint,
    total_exec_time  double precision,
    mean_exec_time   double precision,
    time_share_pct   double precision,
    finding          text,
    finding_text     text,
    evidence         jsonb,
    recommendation   text,
    expected_benefit text,
    estimated_cost   text,
    validation_steps text[]
)
LANGUAGE sql
STABLE
AS $$
    WITH cap AS (
        SELECT LEAST(GREATEST(p_limit, 1), sta._max_findings()) AS lim
    ),
    d AS (
        SELECT * FROM sta._workload_delta(p_window)
    ),
    agg AS (
        SELECT d.*,
               SUM(d.total_exec_time) OVER () AS grand_total_time
        FROM d
        WHERE d.calls >= p_min_calls
          AND d.total_exec_time >= p_min_total_time
    ),
    scored AS (
        SELECT a.*,
               CASE WHEN a.grand_total_time > 0
                    THEN round((100.0 * a.total_exec_time / a.grand_total_time)::numeric, 2)
                    ELSE 0 END AS time_share_pct,
               CASE WHEN COALESCE(a.shared_blks_hit, 0) + COALESCE(a.shared_blks_read, 0) > 0
                    THEN round((100.0 * COALESCE(a.shared_blks_hit, 0)
                               / (COALESCE(a.shared_blks_hit, 0) + COALESCE(a.shared_blks_read, 0)))::numeric, 2)
                    ELSE NULL END AS cache_hit_pct
        FROM agg a
    ),
    ranked AS (
        SELECT s.*,
               ROW_NUMBER() OVER (ORDER BY s.total_exec_time DESC) AS rn_time,
               ROW_NUMBER() OVER (ORDER BY s.calls DESC)             AS rn_calls,
               ROW_NUMBER() OVER (ORDER BY s.mean_exec_time DESC)   AS rn_mean
        FROM scored s
    ),
    signals AS (
        SELECT r.queryid, r.query, r.calls, r.total_exec_time, r.mean_exec_time,
               r.time_share_pct, r.cache_hit_pct, r.shared_blks_read, r.temp_blks_written,
               r.blk_read_time,
               'HIGH_TOTAL_TIME'::text AS finding,
               'HIGH'::text AS severity,
               'The statement accounts for a large share of the total execution time in the observed window.'
                 AS finding_text,
               jsonb_build_object(
                   'total_exec_time_ms', round(r.total_exec_time::numeric, 3),
                   'mean_exec_time_ms',  round(r.mean_exec_time::numeric, 3),
                   'calls',              r.calls,
                   'time_share_pct',     r.time_share_pct,
                   'rank_by_total_time', r.rn_time) AS evidence,
               'Reduce the execution time of the statement; start with its access path and indexes.'
                 AS recommendation,
               'Reducing the execution time of this statement reduces total database time proportionally.'
                 AS expected_benefit,
               'Effort is proportional to how expensive the statement is to rewrite.' AS estimated_cost
        FROM ranked r
        WHERE r.rn_time <= (SELECT lim FROM cap)
          AND r.total_exec_time > 0
          AND r.time_share_pct >= 5

        UNION ALL
        SELECT r.queryid, r.query, r.calls, r.total_exec_time, r.mean_exec_time,
               r.time_share_pct, r.cache_hit_pct, r.shared_blks_read, r.temp_blks_written,
               r.blk_read_time,
               'HIGH_MEAN_EXEC_TIME',
               CASE WHEN r.mean_exec_time >= 1000 THEN 'CRITICAL'
                    WHEN r.mean_exec_time >= 100  THEN 'HIGH' ELSE 'MEDIUM' END,
               'Every single execution of the statement is slow.'
                 AS finding_text,
               jsonb_build_object(
                   'mean_exec_time_ms', round(r.mean_exec_time::numeric, 3),
                   'total_exec_time_ms', round(r.total_exec_time::numeric, 3),
                   'calls',              r.calls,
                   'rank_by_mean_time',  r.rn_mean) AS evidence,
               'Inspect the plan of the statement for an access-path problem.'
                 AS recommendation,
               'A per-execution improvement is multiplied by the call count.' AS expected_benefit,
               'Depends on the cause: an index is cheap to add, a rewrite may not be.' AS estimated_cost
        FROM ranked r
        WHERE r.rn_mean <= (SELECT lim FROM cap)
          AND r.mean_exec_time >= (SELECT value FROM sta.threshold WHERE name = 'high_mean_exec_time_ms')

        UNION ALL
        SELECT r.queryid, r.query, r.calls, r.total_exec_time, r.mean_exec_time,
               r.time_share_pct, r.cache_hit_pct, r.shared_blks_read, r.temp_blks_written,
               r.blk_read_time,
               'HIGH_FREQUENCY',
               CASE WHEN r.calls >= 10000 THEN 'HIGH' ELSE 'MEDIUM' END,
               'The statement is executed very often.'
                 AS finding_text,
               jsonb_build_object(
                   'calls',              r.calls,
                   'mean_exec_time_ms',  round(r.mean_exec_time::numeric, 3),
                   'total_exec_time_ms', round(r.total_exec_time::numeric, 3),
                   'rank_by_calls',      r.rn_calls) AS evidence,
               'Optimise the hot path of the statement; small per-call savings accumulate quickly.'
                 AS recommendation,
               'Optimising a hot statement has an outsized effect on total database CPU time.'
                 AS expected_benefit,
               'Usually a small, targeted change (index, plan fix, parameterisation).' AS estimated_cost
        FROM ranked r
        WHERE r.rn_calls <= (SELECT lim FROM cap)
          AND r.calls >= (SELECT value FROM sta.threshold WHERE name = 'high_frequency_calls')

        UNION ALL
        SELECT r.queryid, r.query, r.calls, r.total_exec_time, r.mean_exec_time,
               r.time_share_pct, r.cache_hit_pct, r.shared_blks_read, r.temp_blks_written,
               r.blk_read_time,
               'LOW_CACHE_HIT_RATIO',
               'MEDIUM',
               'The statement reads most of its blocks from storage instead of the buffer cache.'
                 AS finding_text,
               jsonb_build_object(
                   'cache_hit_pct',    r.cache_hit_pct,
                   'shared_blks_read', r.shared_blks_read,
                   'shared_blks_hit',  r.shared_blks_hit,
                   'total_exec_time_ms', round(r.total_exec_time::numeric, 3)) AS evidence,
               'Reduce the working set or improve locality; consider a covering index or a larger shared_buffers budget.'
                 AS recommendation,
               'More buffer-cache hits mean less physical I/O per execution.' AS expected_benefit,
               'Raising shared_buffers competes with other memory consumers; measure before committing.' AS estimated_cost
        FROM ranked r
        WHERE r.rn_time <= (SELECT lim FROM cap)
          AND r.cache_hit_pct IS NOT NULL
          AND r.cache_hit_pct < (SELECT value FROM sta.threshold WHERE name = 'low_cache_hit_pct')
          AND r.shared_blks_read >= (SELECT value FROM sta.threshold WHERE name = 'min_shared_blks_read')

        UNION ALL
        SELECT r.queryid, r.query, r.calls, r.total_exec_time, r.mean_exec_time,
               r.time_share_pct, r.cache_hit_pct, r.shared_blks_read, r.temp_blks_written,
               r.blk_read_time,
               'HIGH_TEMP_IO',
               'MEDIUM',
               'The statement spills to temporary files.'
                 AS finding_text,
               jsonb_build_object(
                   'temp_blks_written', r.temp_blks_written,
                   'calls',              r.calls,
                   'total_exec_time_ms', round(r.total_exec_time::numeric, 3)) AS evidence,
               'Raise work_mem or reduce the size of the sorted or hashed input so the spill disappears.'
                 AS recommendation,
               'Avoiding temp file writes removes a large part of the I/O and latency of the statement.'
                 AS expected_benefit,
               'work_mem is allocated per sort/hash node and per worker; raising it can exhaust RAM.' AS estimated_cost
        FROM ranked r
        WHERE r.rn_time <= (SELECT lim FROM cap)
          AND r.temp_blks_written >= (SELECT value FROM sta.threshold WHERE name = 'min_temp_blks_written')
    )
    SELECT
        (ROW_NUMBER() OVER (ORDER BY s.total_exec_time DESC, s.finding))::integer,
        'workload'::text,
        s.severity,
        CASE WHEN s.finding = 'HIGH_TOTAL_TIME'   THEN 'HIGH'
             WHEN s.finding = 'HIGH_MEAN_EXEC_TIME' THEN 'HIGH'
             WHEN s.finding = 'HIGH_FREQUENCY'    THEN 'HIGH'
             WHEN s.finding = 'LOW_CACHE_HIT_RATIO' THEN 'MEDIUM'
             ELSE 'MEDIUM' END,
        (CASE s.finding
            WHEN 'HIGH_TOTAL_TIME'      THEN 70
            WHEN 'HIGH_MEAN_EXEC_TIME'  THEN 75
            WHEN 'HIGH_FREQUENCY'       THEN 60
            WHEN 'LOW_CACHE_HIT_RATIO'  THEN 45
            WHEN 'HIGH_TEMP_IO'         THEN 50
            ELSE 30 END)::integer,
        s.queryid,
        s.query,
        s.calls,
        s.total_exec_time,
        s.mean_exec_time,
        s.time_share_pct,
        s.finding,
        s.finding_text,
        s.evidence,
        s.recommendation,
        s.expected_benefit,
        s.estimated_cost,
        sta.validation_steps(CASE WHEN s.finding = 'HIGH_TEMP_IO' THEN 'config' ELSE 'workload' END)
    FROM signals s
    ORDER BY s.total_exec_time DESC, s.finding
    LIMIT (SELECT lim FROM cap) * 5
$$;

COMMENT ON FUNCTION sta.workload_advice(text, bigint, double precision, integer) IS
  'Advice derived from observed workload counters: top time consumers, hot statements, cache and temp I/O behaviour.';

------------------------------------------------------------------------------
-- Relation resolution helper
--
-- PostgreSQL 17 reports the schema of a scanned relation in the EXPLAIN JSON
-- document ("Schema"), so the relation can be resolved exactly.  Older
-- documents, and node types that carry no relation, fall back to resolving
-- the name against the current search_path, which matches what the planner
-- would most likely have used.
------------------------------------------------------------------------------
CREATE FUNCTION sta._resolve_relation(p_relname text, p_schema text DEFAULT NULL)
RETURNS TABLE (
    oid              oid,
    schema           text,
    relname          text,
    reltuples        bigint,
    est_rows         bigint,
    relpages         bigint,
    total_bytes      bigint,
    n_live_tup       bigint,
    n_dead_tup       bigint,
    n_mod_since_analyze bigint,
    last_analyze     timestamptz,
    last_autoanalyze timestamptz,
    last_vacuum      timestamptz,
    last_autovacuum  timestamptz
)
LANGUAGE sql
STABLE
AS $$
    SELECT c.oid,
           ns.nspname,
           c.relname,
           c.reltuples::bigint,
           -- The planner statistics of a relation that was never analyzed
           -- are useless: pg_class.reltuples is -1 and pg_class.relpages is
           -- 0, so both the row count and the size would be reported as
           -- "empty".  The advisory functions need a usable estimate:
           --
           --   * reltuples >= 0  -> the catalog value is authoritative.
           --   * otherwise       -> fall back to the live tuple count that
           --                        the statistics system maintains, and
           --                        to at least one row when the relation
           --                        occupies at least one page.
           --
           -- pg_relation_size() is used for the size because it is exact
           -- and immediate, while relpages is only refreshed by VACUUM and
           -- ANALYZE.
           CASE
               WHEN c.reltuples >= 0 THEN c.reltuples::bigint
               ELSE GREATEST(COALESCE(s.n_live_tup, 0),
                             CASE WHEN pg_relation_size(c.oid) > 0 THEN 1 ELSE 0 END)
           END,
           c.relpages::bigint,
           pg_relation_size(c.oid)::bigint,
           COALESCE(s.n_live_tup, 0),
           COALESCE(s.n_dead_tup, 0),
           COALESCE(s.n_mod_since_analyze, 0),
           s.last_analyze,
           s.last_autoanalyze,
           s.last_vacuum,
           s.last_autovacuum
    FROM pg_class c
    JOIN pg_namespace ns ON ns.oid = c.relnamespace
    LEFT JOIN pg_stat_all_tables s ON s.relid = c.oid
    WHERE c.relname = p_relname
      AND c.relkind IN ('r', 'm', 'p')
      AND (p_schema IS NULL OR ns.nspname = p_schema)
      AND (p_schema IS NOT NULL OR ns.nspname = ANY (current_schemas(false)))
    ORDER BY array_position(current_schemas(false), ns.nspname)
    LIMIT 1
$$;

COMMENT ON FUNCTION sta._resolve_relation(text, text) IS
  'Resolve a relation name, optionally qualified by schema, and return its size and statistics.';

------------------------------------------------------------------------------
-- Plan flattening
--
-- Turns the nested EXPLAIN JSON document into a flat list of nodes, each one
-- carrying the path that leads to it.
------------------------------------------------------------------------------
CREATE FUNCTION sta._plan_nodes(p_plan jsonb)
RETURNS TABLE (node_path text, node jsonb)
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE tree AS (
        SELECT (p_plan->0)->'Plan' AS node, ''::text AS node_path
        UNION ALL
        SELECT child.node,
               CASE WHEN t.node_path = '' THEN COALESCE(child.node->>'Node Type', '?')
                    ELSE t.node_path || ' > ' || COALESCE(child.node->>'Node Type', '?') END
        FROM tree t
        CROSS JOIN LATERAL jsonb_array_elements(
            CASE WHEN jsonb_typeof(t.node->'Plans') = 'array'
                 THEN t.node->'Plans' ELSE '[]'::jsonb END) AS child(node)
    )
    SELECT node_path, node FROM tree WHERE node IS NOT NULL
$$;

COMMENT ON FUNCTION sta._plan_nodes(jsonb) IS
  'Flatten an EXPLAIN (FORMAT JSON) document into one row per plan node.';

------------------------------------------------------------------------------
-- Plan advice
------------------------------------------------------------------------------
CREATE FUNCTION sta.plan_advice(
    p_sql     text,
    p_analyze boolean DEFAULT false,
    p_limit   integer DEFAULT 100
)
RETURNS TABLE (
    finding_id       integer,
    category         text,
    severity         text,
    confidence       text,
    impact_score     integer,
    object_name      text,
    node_type        text,
    node_path        text,
    finding          text,
    finding_text     text,
    evidence         jsonb,
    recommendation   text,
    expected_benefit text,
    estimated_cost   text,
    validation_steps text[]
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_plan  jsonb;
    v_nodes jsonb;
BEGIN
    v_plan := sta.explain(p_sql, p_analyze);

    SELECT COALESCE(jsonb_agg(jsonb_build_object('path', n.node_path, 'node', n.node)), '[]'::jsonb)
      INTO v_nodes
      FROM sta._plan_nodes(v_plan) n;

    RETURN QUERY
    WITH nodes AS (
        SELECT e->>'path' AS node_path, e->'node' AS node
        FROM jsonb_array_elements(v_nodes) AS e
    ),
    resolved AS (
        SELECT n.node_path,
               n.node,
               r.oid, r.schema, r.relname, r.reltuples, r.est_rows, r.relpages, r.total_bytes
        FROM nodes n
        LEFT JOIN LATERAL sta._resolve_relation(n.node->>'Relation Name', n.node->>'Schema') r ON TRUE
    ),
    findings AS (
        -- 1. sequential scan over a large relation
        SELECT 'SEQ_SCAN_ON_LARGE_TABLE'::text AS finding,
               'HIGH'::text  AS severity,
               'HIGH'::text  AS confidence,
               70::integer   AS impact,
               COALESCE(n.schema || '.' || n.relname, n.node->>'Relation Name')::text AS object_name,
               (n.node->>'Node Type')::text AS node_type,
               n.node_path::text,
               format('Sequential scan over %s (%s rows estimated) reads the whole relation; '
                      'an index on the filtered columns may avoid the full scan',
                      COALESCE(n.relname, n.node->>'Relation Name'),
                      COALESCE(n.est_rows::text, 'unknown'))::text AS finding_text,
               jsonb_build_object(
                   'relation',          COALESCE(n.schema || '.' || n.relname, n.node->>'Relation Name'),
                   'reltuples',         n.reltuples,
                   'rows_estimated',    n.est_rows,
                   'relation_bytes',    n.total_bytes,
                   'filter',            n.node->>'Filter',
                   'plan_rows',         n.node->>'Plan Rows',
                   'total_cost',        n.node->>'Total Cost') AS evidence,
               'Add an index that supports the filter of this scan and re-check the plan.'
                 AS recommendation,
               'Replacing a full scan with an index lookup reduces the rows read per execution '
                 'from the whole relation to the matching rows.' AS expected_benefit,
               'An index adds write amplification and storage; verify the gain with sta.validate() '
                 'before keeping it.' AS estimated_cost,
               'index'::text AS vkind
        FROM resolved n
        WHERE n.node->>'Node Type' = 'Seq Scan'
          AND n.est_rows >= (SELECT value FROM sta.threshold WHERE name = 'seq_scan_min_rows')
          AND (n.node->>'Filter' IS NOT NULL OR n.node->>'Index Cond' IS NOT NULL)

        UNION ALL
        -- 2. sequential scan over a small relation is fine
        SELECT 'SEQ_SCAN_ON_SMALL_TABLE',
               'INFO', 'HIGH', 0,
               COALESCE(n.schema || '.' || n.relname, n.node->>'Relation Name'),
               n.node->>'Node Type',
               n.node_path,
               format('Sequential scan over %s is appropriate: the relation is small enough to read in full',
                      COALESCE(n.relname, n.node->>'Relation Name')),
               jsonb_build_object(
                   'relation',   COALESCE(n.schema || '.' || n.relname, n.node->>'Relation Name'),
                   'reltuples',  n.reltuples,
                   'rows_estimated', n.est_rows,
                   'seq_scan_rows_estimated', n.node->>'Plan Rows'),
               'No action required for this scan.',
               'Avoids spending effort on an index that would not pay for itself.',
               'None.',
               'plan'::text
        FROM resolved n
        WHERE n.node->>'Node Type' = 'Seq Scan'
          AND n.est_rows IS NOT NULL
          AND n.est_rows < (SELECT value FROM sta.threshold WHERE name = 'seq_scan_min_rows')

        UNION ALL
        -- 3. planner estimate far away from reality
        SELECT 'ESTIMATE_MISMATCH',
               CASE WHEN COALESCE(NULLIF(n.node->>'Plan Rows','')::numeric, 0)
                         >= 10 * COALESCE(NULLIF(n.node->>'Actual Rows','')::numeric, 1)
                    THEN 'HIGH' ELSE 'MEDIUM' END,
               'HIGH', 65,
               COALESCE(n.schema || '.' || n.relname, n.node->>'Relation Name'),
               n.node->>'Node Type',
               n.node_path,
               format('The planner estimated %s rows but the node actually produced %s rows; '
                      'stale statistics make the planner choose a bad access path',
                      n.node->>'Plan Rows', n.node->>'Actual Rows'),
               jsonb_build_object(
                   'plan_rows',      n.node->>'Plan Rows',
                   'actual_rows',    n.node->>'Actual Rows',
                   'actual_loops',   n.node->>'Actual Loops',
                   'relation',       COALESCE(n.schema || '.' || n.relname, n.node->>'Relation Name'),
                   'node_type',      n.node->>'Node Type'),
               'Refresh the statistics of the affected relation with ANALYZE and re-check the plan.',
               'A correct estimate lets the planner pick the right join order and access path, '
                 'which usually changes the execution time by an order of magnitude.' AS expected_benefit,
               'ANALYZE is cheap and can be run online.' AS estimated_cost,
               'analyze'::text AS vkind
        FROM resolved n
        WHERE p_analyze
          AND n.node->>'Actual Rows' IS NOT NULL
          AND NULLIF(n.node->>'Plan Rows','') IS NOT NULL
          AND NULLIF(n.node->>'Actual Rows','')::numeric > 0
          AND NULLIF(n.node->>'Plan Rows','')::numeric > 0
          AND GREATEST(NULLIF(n.node->>'Plan Rows','')::numeric,
                       NULLIF(n.node->>'Actual Rows','')::numeric)
              / LEAST(NULLIF(n.node->>'Plan Rows','')::numeric,
                      NULLIF(n.node->>'Actual Rows','')::numeric)
              >= (SELECT value FROM sta.threshold WHERE name = 'estimate_mismatch_factor')

        UNION ALL
        -- 4. sort spilled to disk
        SELECT 'SORT_SPILLED_TO_DISK',
               'MEDIUM', 'HIGH', 50,
               n.node->>'Relation Name',
               n.node->>'Node Type',
               n.node_path,
               format('The sort spilled %s to disk instead of staying in memory',
                      COALESCE(n.node->>'Sort Space Used', 'an unknown amount of space')),
               jsonb_build_object(
                   'sort_method',       n.node->>'Sort Method',
                   'sort_space_used_kb', n.node->>'Sort Space Used',
                   'sort_space_type',   n.node->>'Sort Space Type'),
               'Raise work_mem for this statement, or reduce the number of rows entering the sort.',
               'Removing the spill removes the temporary file writes and the associated latency.',
               'work_mem is per sort node and per parallel worker; raising it can exhaust memory.',
               'config'::text
        FROM resolved n
        WHERE n.node->>'Sort Method' LIKE 'external%'
          AND COALESCE(NULLIF(n.node->>'Sort Space Used','')::numeric, 0)
              >= (SELECT value FROM sta.threshold WHERE name = 'sort_spill_min_kb')

        UNION ALL
        -- 5. hash join spilled into several batches
        SELECT 'HASH_BATCHES',
               'MEDIUM', 'HIGH', 45,
               n.node->>'Relation Name',
               n.node->>'Node Type',
               n.node_path,
               format('The hash join ran in %s batches, which means the hash table did not fit in memory',
                      n.node->>'Hash Batches'),
               jsonb_build_object(
                   'hash_batches',      n.node->>'Hash Batches',
                   'original_batches',  n.node->>'Original Hash Batches',
                   'hash_buckets',      n.node->>'Hash Buckets',
                   'peak_memory_usage_kb', n.node->>'Peak Memory Usage'),
               'Raise work_mem so the hash table is built in a single batch.',
               'A single-batch hash join avoids repeated partitioning and re-reading of the outer relation.',
               'More memory per hash node; measure under concurrent load.',
               'config'::text
        FROM resolved n
        WHERE COALESCE(NULLIF(n.node->>'Hash Batches','')::int, 0) > 1

        UNION ALL
        -- 6. most rows discarded by the filter
        SELECT 'ROWS_REMOVED_BY_FILTER',
               'MEDIUM', 'HIGH', 50,
               COALESCE(n.schema || '.' || n.relname, n.node->>'Relation Name'),
               n.node->>'Node Type',
               n.node_path,
               format('The node read %s rows but discarded %s of them in the filter',
                      (COALESCE(NULLIF(n.node->>'Actual Rows','')::numeric, 0)
                       + COALESCE(NULLIF(n.node->>'Rows Removed by Filter','')::numeric, 0))::text,
                      n.node->>'Rows Removed by Filter'),
               jsonb_build_object(
                   'actual_rows',          n.node->>'Actual Rows',
                   'rows_removed_by_filter', n.node->>'Rows Removed by Filter',
                   'filter',               n.node->>'Filter',
                   'relation',             COALESCE(n.schema || '.' || n.relname, n.node->>'Relation Name')),
               'Add an index that supports the filter so the unwanted rows are never read.',
               'Only the matching rows are read instead of the whole relation.',
               'Write amplification and storage for the new index.',
               'index'::text
        FROM resolved n
        WHERE COALESCE(NULLIF(n.node->>'Rows Removed by Filter','')::numeric, 0)
              >= (SELECT value FROM sta.threshold WHERE name = 'min_rows_removed_by_filter')
          AND COALESCE(NULLIF(n.node->>'Rows Removed by Filter','')::numeric, 0)
              > COALESCE(NULLIF(n.node->>'Actual Rows','')::numeric, 0)

        UNION ALL
        -- 7. lossy bitmap heap scan
        SELECT 'BITMAP_LOSSY_RECHECK',
               'MEDIUM', 'MEDIUM', 45,
               COALESCE(n.schema || '.' || n.relname, n.node->>'Relation Name'),
               n.node->>'Node Type',
               n.node_path,
               format('The bitmap heap scan lost %s pages, so rows had to be re-checked one by one',
                      n.node->>'Heap Blocks Lost'),
               jsonb_build_object(
                   'heap_blocks_lost', n.node->>'Heap Blocks Lost',
                   'heap_blocks_read', n.node->>'Heap Blocks Read',
                   'recheck_cond',     n.node->>'Recheck Cond'),
               'Increase work_mem so the bitmap fits in memory, or add an index that the planner can use directly.',
               'Removes the per-row recheck and turns the access path into a plain index scan.',
               'work_mem is per node; a larger value can affect concurrency.',
               'config'::text
        FROM resolved n
        WHERE n.node->>'Node Type' = 'Bitmap Heap Scan'
          AND COALESCE(NULLIF(n.node->>'Heap Blocks Lost','')::numeric, 0) > 0

        UNION ALL
        -- 8. nested loop executed far more often than expected
        SELECT 'NESTED_LOOP_HIGH_LOOPS',
               'MEDIUM', 'MEDIUM', 45,
               n.node->>'Relation Name',
               n.node->>'Node Type',
               n.node_path,
               format('The nested loop ran %s times, which is much more than the planner assumed',
                      n.node->>'Actual Loops'),
               jsonb_build_object(
                   'actual_loops', n.node->>'Actual Loops',
                   'plan_rows',    n.node->>'Plan Rows',
                   'actual_rows',  n.node->>'Actual Rows'),
               'Check the join condition and the statistics of the inner relation; a hash join is usually '
                 'cheaper once the outer row count is large.',
               'Replacing the nested loop with a hash join removes the repeated per-row work.',
               'A hash join consumes more memory and can change the join order.',
               'analyze'::text
        FROM resolved n
        WHERE n.node->>'Node Type' = 'Nested Loop'
          AND COALESCE(NULLIF(n.node->>'Actual Loops','')::numeric, 0)
              >= (SELECT value FROM sta.threshold WHERE name = 'nested_loop_max_loops')

        UNION ALL
        -- 9. temporary files written
        SELECT 'TEMP_BLOCKS_WRITTEN',
               'MEDIUM', 'HIGH', 45,
               n.node->>'Relation Name',
               n.node->>'Node Type',
               n.node_path,
               format('The node wrote %s temporary blocks',
                      COALESCE(n.node->>'Temp Written Blocks', '0')),
               jsonb_build_object(
                   'temp_written_blocks', n.node->>'Temp Written Blocks',
                   'temp_read_blocks',    n.node->>'Temp Read Blocks',
                   'sort_method',         n.node->>'Sort Method',
                   'hash_batches',        n.node->>'Hash Batches'),
               'Remove the spill by raising work_mem or by reducing the size of the sorted/hashed input.',
               'Avoids temporary file I/O, which is usually the dominant cost of the node.',
               'Higher memory usage per operation.',
               'config'::text
        FROM resolved n
        WHERE COALESCE(NULLIF(n.node->>'Temp Written Blocks','')::numeric, 0) > 0

        UNION ALL
        -- 10. very expensive plan
        SELECT 'HIGH_TOTAL_COST',
               'LOW', 'MEDIUM', 25,
               n.node->>'Relation Name',
               n.node->>'Node Type',
               n.node_path,
               format('The node has a total cost of %s, which is high relative to a typical statement',
                      n.node->>'Total Cost'),
               jsonb_build_object(
                   'total_cost',   n.node->>'Total Cost',
                   'startup_cost', n.node->>'Startup Cost'),
               'Look for a cheaper access path for this node.',
               'A cheaper plan uses fewer resources for the same result.',
               'Depends on the change that is required.',
               'plan'::text
        FROM resolved n
        WHERE COALESCE(NULLIF(n.node->>'Total Cost','')::numeric, 0)
              >= (SELECT value FROM sta.threshold WHERE name = 'high_total_cost')

        UNION ALL
        -- 11. measured execution time
        SELECT 'SLOW_EXECUTION_TIME',
               CASE WHEN (v_plan->0->>'Execution Time')::numeric >= 5000 THEN 'CRITICAL'
                    ELSE 'HIGH' END,
               'HIGH', 75,
               NULL,
               NULL,
               'Query',
               format('The statement took %s ms to execute',
                      (v_plan->0)->>'Execution Time'),
               jsonb_build_object(
                   'execution_time_ms', (v_plan->0)->>'Execution Time',
                   'planning_time_ms',  (v_plan->0)->>'Planning Time',
                   'plan_rows',         (v_plan->0)->'Plan'->>'Plan Rows',
                   'actual_rows',       (v_plan->0)->'Plan'->>'Actual Rows'),
               'Combine this measurement with the workload statistics before choosing a fix.',
               'Identifies the statements that dominate response time.',
               'No cost by itself; the linked finding carries the cost.',
               'workload'::text
        WHERE p_analyze
          AND COALESCE(NULLIF((v_plan->0)->>'Execution Time','')::numeric, 0)
              >= (SELECT value FROM sta.threshold WHERE name = 'high_execution_time_ms')
    )
    SELECT (ROW_NUMBER() OVER (ORDER BY f.impact DESC, f.finding))::integer,
           'plan'::text,
           f.severity,
           f.confidence,
           f.impact,
           f.object_name,
           f.node_type,
           f.node_path,
           f.finding,
           f.finding_text,
           f.evidence,
           f.recommendation,
           f.expected_benefit,
           f.estimated_cost,
           sta.validation_steps(f.vkind)
    FROM findings f
    ORDER BY f.impact DESC, f.finding
    LIMIT LEAST(GREATEST(p_limit, 1), sta._max_findings());
END
$$;

COMMENT ON FUNCTION sta.plan_advice(text, boolean, integer) IS
  'Advice derived from the execution plan: access paths, estimate accuracy, spilling and I/O behaviour.';

------------------------------------------------------------------------------
-- Statistics advice
------------------------------------------------------------------------------
CREATE FUNCTION sta.stats_advice(
    p_schema text    DEFAULT NULL,
    p_limit  integer DEFAULT 100
)
RETURNS TABLE (
    finding_id       integer,
    category         text,
    severity         text,
    confidence       text,
    impact_score     integer,
    object_name      text,
    finding          text,
    finding_text     text,
    evidence         jsonb,
    recommendation   text,
    expected_benefit text,
    estimated_cost   text,
    validation_steps text[]
)
LANGUAGE sql
STABLE
AS $$
    WITH tables AS (
        SELECT c.oid,
               ns.nspname AS schema,
               c.relname,
               c.reltuples::bigint AS reltuples,
               c.relpages::bigint AS relpages,
               pg_relation_size(c.oid)::bigint AS total_bytes,
               COALESCE(st.n_live_tup, 0) AS n_live_tup,
               COALESCE(st.n_dead_tup, 0) AS n_dead_tup,
               COALESCE(st.n_mod_since_analyze, 0) AS n_mod_since_analyze,
               st.last_analyze,
               st.last_autoanalyze,
               st.last_vacuum,
               st.last_autovacuum,
               -- A relation that was never analyzed has reltuples = -1, and
               -- the statistics collector may not have run yet, so the live
               -- tuple count cannot be trusted on its own.  A relation that
               -- occupies at least one page is known to hold rows, which is
               -- enough to tell "empty" from "not empty" without depending
               -- on the collector.
               CASE
                   WHEN c.reltuples >= 0 THEN c.reltuples::bigint
                   ELSE GREATEST(COALESCE(st.n_live_tup, 0),
                                 CASE WHEN pg_relation_size(c.oid) > 0 THEN 1 ELSE 0 END)
               END AS est_rows
        FROM pg_class c
        JOIN pg_namespace ns ON ns.oid = c.relnamespace
        LEFT JOIN pg_stat_all_tables st ON st.relid = c.oid
        WHERE c.relkind IN ('r', 'm', 'p')
          AND (p_schema IS NULL OR ns.nspname = p_schema)
          AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
          AND ns.nspname !~ '^pg_toast'
          -- Skip relations owned by an extension (e.g. pg_sta's own sample
          -- tables).  The extension schema itself is not registered as
          -- extension-owned, so membership has to be tested per relation.
          AND NOT EXISTS (
                SELECT 1
                FROM pg_depend d
                WHERE d.classid = 'pg_class'::regclass
                  AND d.objid = c.oid
                  AND d.deptype = 'e'
                  AND d.refclassid = 'pg_extension'::regclass
          )
    ),
    findings AS (
        SELECT 'NEVER_ANALYZED'::text AS finding,
               'HIGH'::text AS severity,
               'HIGH'::text AS confidence,
               60::integer AS impact,
               (t.schema || '.' || t.relname)::text AS object_name,
               format('The relation has never been analyzed, so the planner works with default estimates')
                 AS finding_text,
               jsonb_build_object(
                   'relation',        t.schema || '.' || t.relname,
                   'reltuples',       t.reltuples,
                   'total_bytes',     t.total_bytes,
                   'last_analyze',    t.last_analyze,
                   'last_autoanalyze', t.last_autoanalyze,
                   'n_live_tup',      t.n_live_tup) AS evidence,
               'Run ANALYZE on the relation so the planner has real statistics.' AS recommendation,
               'Correct statistics usually remove the need for a new index, because many "bad plans" '
                 'are caused by default estimates.' AS expected_benefit,
               'ANALYZE is cheap and safe to run on a live system.' AS estimated_cost,
               'analyze'::text AS vkind
        FROM tables t
        WHERE (t.last_analyze IS NULL AND t.last_autoanalyze IS NULL)
          AND t.est_rows > 0

        UNION ALL
        SELECT 'STALE_STATISTICS',
               'MEDIUM', 'MEDIUM', 50,
               (t.schema || '.' || t.relname),
               format('The relation changed %s rows since it was last analyzed, which is %s%% of its rows',
                      t.n_mod_since_analyze,
                      CASE WHEN t.reltuples > 0
                           THEN round((100.0 * t.n_mod_since_analyze / t.reltuples)::numeric, 1)::text
                           ELSE 'unknown' END),
               jsonb_build_object(
                   'relation',           t.schema || '.' || t.relname,
                   'n_mod_since_analyze', t.n_mod_since_analyze,
                   'reltuples',          t.reltuples,
                   'last_analyze',       t.last_analyze,
                   'last_autoanalyze',   t.last_autoanalyze,
                   'autovacuum_analyze_threshold',
                       current_setting('autovacuum_analyze_threshold'),
                   'autovacuum_analyze_scale_factor',
                       current_setting('autovacuum_analyze_scale_factor')),
               'Run ANALYZE on the relation (or lower autovacuum_analyze_scale_factor for this table).',
               'Fresh statistics reduce the number of wrong plans caused by mis-estimation.',
               'ANALYZE is cheap; a more aggressive autovacuum setting costs some background work.',
               'analyze'::text
        FROM tables t
        WHERE t.n_mod_since_analyze > 0
          AND (t.last_analyze IS NOT NULL OR t.last_autoanalyze IS NOT NULL)
          AND t.n_mod_since_analyze > (
                GREATEST(
                    (SELECT value FROM sta.threshold WHERE name = 'analyze_base_threshold'),
                    COALESCE(t.reltuples, 0)
                        * COALESCE(NULLIF(current_setting('autovacuum_analyze_scale_factor'),'')::numeric, 0.1)
                )::numeric)

        UNION ALL
        SELECT 'HIGH_DEAD_TUPLES',
               CASE WHEN t.n_dead_tup > 10000 THEN 'HIGH' ELSE 'MEDIUM' END,
               'HIGH', 45,
               (t.schema || '.' || t.relname),
               format('The relation has %s dead tuples (%s%% of all tuples); table bloat makes scans more expensive',
                      t.n_dead_tup,
                      CASE WHEN (t.n_live_tup + t.n_dead_tup) > 0
                           THEN round((100.0 * t.n_dead_tup / (t.n_live_tup + t.n_dead_tup))::numeric, 1)::text
                           ELSE '0' END),
               jsonb_build_object(
                   'relation',       t.schema || '.' || t.relname,
                   'n_dead_tup',     t.n_dead_tup,
                   'n_live_tup',     t.n_live_tup,
                   'total_bytes',    t.total_bytes,
                   'last_vacuum',    t.last_vacuum,
                   'last_autovacuum', t.last_autovacuum),
               'Run VACUUM (ANALYZE) on the relation.',
               'Vacuuming removes dead row versions, shortens index scans and lets the visibility map '
                 'skip pages.' AS expected_benefit,
               'VACUUM uses I/O and CPU; a VACUUM FULL would lock the table but is not required here.',
               'vacuum'::text
        FROM tables t
        WHERE t.n_dead_tup >= (SELECT value FROM sta.threshold WHERE name = 'dead_tuple_min')
          AND (t.n_dead_tup::numeric / NULLIF(t.n_live_tup + t.n_dead_tup, 0))
              >= (SELECT value FROM sta.threshold WHERE name = 'dead_tuple_ratio')

        UNION ALL
        SELECT 'NO_PRIMARY_KEY',
               'LOW', 'HIGH', 20,
               (t.schema || '.' || t.relname),
               'The relation has no primary key; logical replication and row-level security have no key to work with',
               jsonb_build_object(
                   'relation',   t.schema || '.' || t.relname,
                   'reltuples',  t.reltuples,
                   'total_bytes', t.total_bytes),
               'Consider adding a primary key if the data model allows it.',
               'A primary key gives the planner a proven unique index and enables logical replication.',
               'Adding a primary key requires a unique index and an ACCESS EXCLUSIVE lock.',
               'plan'::text
        FROM tables t
        WHERE t.est_rows > 0
          AND NOT EXISTS (
                SELECT 1 FROM pg_index i
                WHERE i.indrelid = t.oid AND i.indisprimary)

        UNION ALL
        SELECT 'NO_INDEXES',
               'INFO', 'HIGH', 10,
               (t.schema || '.' || t.relname),
               format('The relation has no indexes at all and %s rows; every access is a full scan',
                      t.reltuples),
               jsonb_build_object(
                   'relation',   t.schema || '.' || t.relname,
                   'reltuples',  t.reltuples,
                   'total_bytes', t.total_bytes),
               'Add indexes for the columns that are used in WHERE and JOIN clauses.',
               'Index lookups replace full scans.',
               'Write amplification and storage.',
               'index'::text
        FROM tables t
        WHERE t.est_rows >= (SELECT value FROM sta.threshold WHERE name = 'seq_scan_min_rows')
          AND NOT EXISTS (
                SELECT 1 FROM pg_index i WHERE i.indrelid = t.oid)
    )
    SELECT (ROW_NUMBER() OVER (ORDER BY f.impact DESC, f.object_name))::integer,
           'statistics'::text,
           f.severity,
           f.confidence,
           f.impact,
           f.object_name,
           f.finding,
           f.finding_text,
           f.evidence,
           f.recommendation,
           f.expected_benefit,
           f.estimated_cost,
           sta.validation_steps(f.vkind)
    FROM findings f
    ORDER BY f.impact DESC, f.object_name
    LIMIT LEAST(GREATEST(p_limit, 1), sta._max_findings())
$$;

COMMENT ON FUNCTION sta.stats_advice(text, integer) IS
  'Advice derived from relation statistics: missing, stale or bloated statistics and missing keys.';

------------------------------------------------------------------------------
-- Snapshot diff advice
--
-- sta.collect() records the state of every relation and every index.  All
-- the other advice functions work on the live catalog and therefore cannot
-- tell "this table was always like this" from "this table changed since
-- last night".  This function closes that gap: it compares the two most
-- recent snapshots of the same schema and reports what changed in between.
--
-- It is the only advice function that reads sta.table_stats_sample and
-- sta.index_sample.
------------------------------------------------------------------------------
CREATE FUNCTION sta.snapshot_diff(
    p_schema text DEFAULT NULL,
    p_limit  integer DEFAULT 50
)
RETURNS TABLE (
    finding_id       integer,
    category         text,
    severity         text,
    confidence       text,
    impact_score     integer,
    object_name      text,
    finding          text,
    finding_text     text,
    evidence         jsonb,
    recommendation   text,
    expected_benefit text,
    estimated_cost   text,
    validation_steps text[]
)
LANGUAGE sql
STABLE
AS $$
    -- The two most recent distinct capture timestamps.  Every row written by
    -- one call of sta.collect() carries the same captured_at, so a timestamp
    -- identifies a snapshot reliably.
    WITH snaps AS (
        SELECT captured_at,
               row_number() OVER (ORDER BY captured_at DESC) AS rn
        FROM (
            SELECT DISTINCT captured_at
            FROM sta.table_stats_sample
            WHERE p_schema IS NULL OR schemaname = p_schema
        ) d
    ),
    -- The same relation in the older and in the newer snapshot.
    paired AS (
        SELECT cur.schemaname,
               cur.relname,
               old.captured_at AS from_at,
               cur.captured_at AS to_at,
               cur.reltuples,
               cur.n_live_tup,  old.n_live_tup  AS old_n_live_tup,
               cur.n_dead_tup,  old.n_dead_tup  AS old_n_dead_tup,
               cur.n_mod_since_analyze,
               old.n_mod_since_analyze AS old_n_mod_since_analyze,
               cur.analyze_count, old.analyze_count AS old_analyze_count,
               cur.last_autovacuum
        FROM sta.table_stats_sample cur
        JOIN snaps sn ON sn.captured_at = cur.captured_at AND sn.rn = 1
        JOIN sta.table_stats_sample old
             ON old.schemaname = cur.schemaname
            AND old.relname    = cur.relname
        JOIN snaps so ON so.captured_at = old.captured_at AND so.rn = 2
        WHERE p_schema IS NULL OR cur.schemaname = p_schema
    ),
    table_findings AS (
        -- Dead tuples appeared and were not reclaimed by an autovacuum.
        SELECT 'DEAD_TUPLE_GROWTH'::text AS finding,
               CASE WHEN p.n_dead_tup::numeric / NULLIF(p.n_live_tup + p.n_dead_tup, 0)
                         >= 2 * (SELECT value FROM sta.threshold WHERE name = 'dead_tuple_ratio')
                    THEN 'HIGH'::text ELSE 'MEDIUM'::text END AS severity,
               'HIGH'::text AS confidence,
               50::integer AS impact,
               (p.schemaname || '.' || p.relname)::text AS object_name,
               format('The relation gained %s dead tuples since the previous snapshot and now holds %s%% dead rows',
                      p.n_dead_tup - p.old_n_dead_tup,
                      CASE WHEN (p.n_live_tup + p.n_dead_tup) > 0
                           THEN round((100.0 * p.n_dead_tup / (p.n_live_tup + p.n_dead_tup))::numeric, 1)::text
                           ELSE '0' END) AS finding_text,
               jsonb_build_object(
                   'relation',           p.schemaname || '.' || p.relname,
                   'from_at',            p.from_at,
                   'to_at',              p.to_at,
                   'dead_tuple_delta',   p.n_dead_tup - p.old_n_dead_tup,
                   'n_dead_tup',         p.n_dead_tup,
                   'n_live_tup',         p.n_live_tup,
                   'last_autovacuum',    p.last_autovacuum) AS evidence,
               'Run VACUUM (ANALYZE) on the relation, or lower the autovacuum thresholds for it.'
                 AS recommendation,
               'Removing dead row versions shortens scans and lets the visibility map skip pages.'
                 AS expected_benefit,
               'VACUUM uses I/O and CPU; it is online and does not block readers or writers.'
                 AS estimated_cost,
               'vacuum'::text AS vkind
        FROM paired p
        WHERE p.n_dead_tup > p.old_n_dead_tup
          AND p.n_dead_tup >= (SELECT value FROM sta.threshold WHERE name = 'dead_tuple_min')
          AND (p.n_dead_tup::numeric / NULLIF(p.n_live_tup + p.n_dead_tup, 0))
              >= (SELECT value FROM sta.threshold WHERE name = 'dead_tuple_ratio')

        UNION ALL
        -- The relation changed but nobody analyzed it in the meantime.
        SELECT 'STATISTICS_GO_STALE',
               'MEDIUM', 'HIGH', 45,
               (p.schemaname || '.' || p.relname),
               format('The relation changed %s rows since the previous snapshot and was not analyzed in between',
                      p.n_mod_since_analyze - p.old_n_mod_since_analyze),
               jsonb_build_object(
                   'relation',         p.schemaname || '.' || p.relname,
                   'from_at',          p.from_at,
                   'to_at',            p.to_at,
                   'changed_rows',     p.n_mod_since_analyze - p.old_n_mod_since_analyze,
                   'n_mod_since_analyze', p.n_mod_since_analyze,
                   'analyze_count_delta', p.analyze_count - p.old_analyze_count),
               'Run ANALYZE on the relation.',
               'Fresh statistics keep the planner estimates close to reality, which prevents '
                 'wrong plans that look like missing indexes.',
               'ANALYZE is cheap and safe to run on a live system.',
               'analyze'::text
        FROM paired p
        WHERE (p.n_mod_since_analyze - p.old_n_mod_since_analyze) > 0
          AND (p.analyze_count - p.old_analyze_count) = 0
          AND (p.n_mod_since_analyze - p.old_n_mod_since_analyze)
              >= GREATEST(
                    (SELECT value FROM sta.threshold WHERE name = 'analyze_base_threshold'),
                    COALESCE(p.reltuples, 0)::numeric
                      * COALESCE(NULLIF(current_setting('autovacuum_analyze_scale_factor'),'')::numeric, 0.1))

        UNION ALL
        -- The relation grew noticeably during the window.
        SELECT 'TABLE_GROWTH',
               'INFO', 'HIGH', 15,
               (p.schemaname || '.' || p.relname),
               format('The relation grew by %s rows between the two snapshots',
                      p.n_live_tup - p.old_n_live_tup),
               jsonb_build_object(
                   'relation',       p.schemaname || '.' || p.relname,
                   'from_at',        p.from_at,
                   'to_at',          p.to_at,
                   'live_tuple_delta', p.n_live_tup - p.old_n_live_tup,
                   'n_live_tup',     p.n_live_tup,
                   'old_n_live_tup', p.old_n_live_tup),
               'Review the growth rate and make sure autovacuum and capacity planning keep up with it.',
               'Early detection of runaway growth prevents emergency maintenance later.',
               'No cost; the finding is informational.',
               'plan'::text
        FROM paired p
        WHERE (p.n_live_tup - p.old_n_live_tup)
              >= (SELECT value FROM sta.threshold WHERE name = 'snapshot_growth_min_rows')
    ),
    -- The same index in the older and in the newer snapshot.
    index_pairs AS (
        SELECT cur.schemaname, cur.tablename, cur.indexname, cur.indexdef,
               cur.is_unique, cur.is_primary,
               old.idx_scan AS old_idx_scan, cur.idx_scan,
               old.captured_at AS from_at, cur.captured_at AS to_at
        FROM sta.index_sample cur
        JOIN snaps sn ON sn.captured_at = cur.captured_at AND sn.rn = 1
        JOIN sta.index_sample old
             ON old.schemaname = cur.schemaname
            AND old.tablename = cur.tablename
            AND old.indexname = cur.indexname
        JOIN snaps so ON so.captured_at = old.captured_at AND so.rn = 2
        WHERE p_schema IS NULL OR cur.schemaname = p_schema
    ),
    index_findings AS (
        -- The index was used before, but has not been used during the window.
        SELECT 'INDEX_NO_LONGER_USED'::text AS finding,
               'LOW'::text AS severity,
               'MEDIUM'::text AS confidence,
               30::integer AS impact,
               (i.schemaname || '.' || i.tablename || '.' || i.indexname)::text AS object_name,
               format('The index was used %s times before the previous snapshot but has not been used since',
                      i.old_idx_scan) AS finding_text,
               jsonb_build_object(
                   'relation',    i.schemaname || '.' || i.tablename,
                   'index',       i.indexname,
                   'indexdef',    i.indexdef,
                   'scans_before', i.old_idx_scan,
                   'scans_now',   i.idx_scan,
                   'from_at',     i.from_at,
                   'to_at',       i.to_at) AS evidence,
               'Review whether the index is still needed; drop it only if it stays unused over several windows.'
                 AS recommendation,
               'Unused indexes still cost write amplification and occupy storage.',
               'Dropping an index is fast, but an index that is needed again has to be rebuilt.',
               'index'::text AS vkind
        FROM index_pairs i
        WHERE i.old_idx_scan >= (SELECT value FROM sta.threshold WHERE name = 'index_idle_min_scans')
          AND i.idx_scan = i.old_idx_scan
          AND NOT i.is_primary
          AND NOT i.is_unique
    ),
    findings AS (
        SELECT * FROM table_findings
        UNION ALL
        SELECT * FROM index_findings
    )
    SELECT (ROW_NUMBER() OVER (ORDER BY f.impact DESC, f.object_name))::integer,
           'snapshot'::text,
           f.severity,
           f.confidence,
           f.impact,
           f.object_name,
           f.finding,
           f.finding_text,
           f.evidence,
           f.recommendation,
           f.expected_benefit,
           f.estimated_cost,
           sta.validation_steps(f.vkind)
    FROM findings f
    ORDER BY f.impact DESC, f.object_name
    LIMIT LEAST(GREATEST(p_limit, 1), sta._max_findings())
$$;

COMMENT ON FUNCTION sta.snapshot_diff(text, integer) IS
  'Advice derived by comparing the two most recent sta.collect() snapshots of a schema: '
  'dead-tuple growth, statistics that went stale, table growth and indexes that stopped being used.';

------------------------------------------------------------------------------
-- Index advice
--
-- Index candidates are derived from the filters of sequential scans in the
-- plan.  A column is only proposed when it is a real column of the relation
-- and is not already the leading column of an existing index.
------------------------------------------------------------------------------
CREATE FUNCTION sta.index_advice(p_sql text)
RETURNS TABLE (
    relation          text,
    columns           text[],
    suggested_ddl     text,
    rationale         text,
    estimated_benefit text,
    estimated_cost    text,
    confidence        text,
    validation_steps  text[]
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_plan  jsonb;
    v_nodes jsonb;
BEGIN
    v_plan := sta.explain(p_sql, false);

    SELECT COALESCE(jsonb_agg(jsonb_build_object('path', n.node_path, 'node', n.node)), '[]'::jsonb)
      INTO v_nodes
      FROM sta._plan_nodes(v_plan) n;

    RETURN QUERY
    WITH scans AS (
        SELECT e->>'path' AS node_path,
               e->'node'  AS node
        FROM jsonb_array_elements(v_nodes) e
        WHERE e->'node'->>'Node Type' = 'Seq Scan'
          AND e->'node'->>'Filter' IS NOT NULL
    ),
    resolved AS (
        SELECT s.node_path,
               s.node,
               r.oid, r.schema, r.relname, r.reltuples, r.est_rows, r.total_bytes
        FROM scans s
        JOIN LATERAL sta._resolve_relation(s.node->>'Relation Name', s.node->>'Schema') r ON TRUE
    ),
    cols AS (
        SELECT rs.oid,
               rs.schema,
               rs.relname,
               rs.reltuples,
               rs.est_rows,
               rs.total_bytes,
               rs.node,
               a.attnum AS colid,
               a.attname AS colname,
               (rs.node->>'Filter' ~ ('\y' || a.attname || '\y[[:space:]]*=')) AS has_equality,
               position(' ' || a.attname || ' ' in rs.node->>'Filter') AS filter_pos
        FROM resolved rs
        JOIN pg_attribute a
          ON a.attrelid = rs.oid
         AND a.attnum > 0
         AND NOT a.attisdropped
        WHERE a.attname = ANY (sta.identifiers(rs.node->>'Filter'))
          AND rs.est_rows >= (SELECT value FROM sta.threshold WHERE name = 'seq_scan_min_rows')
    ),
    usable AS (
        SELECT c.*
        FROM cols c
        WHERE NOT EXISTS (
            SELECT 1
            FROM pg_index i
            CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
            WHERE i.indrelid = c.oid
              AND k.ord = 1
              AND k.attnum = c.colid
        )
    ),
    singles AS (
        SELECT DISTINCT ON (u.oid, u.colname)
               u.oid, u.schema, u.relname, u.reltuples, u.est_rows, u.total_bytes, u.node,
               u.colname, u.has_equality
        FROM usable u
        ORDER BY u.oid, u.colname, u.has_equality DESC
    ),
    composites AS (
        SELECT u.oid,
               u.schema,
               u.relname,
               u.reltuples,
               u.est_rows,
               u.total_bytes,
               u.node,
               array_agg(u.colname::text ORDER BY u.filter_pos NULLS LAST, u.colname::text) AS cols
        FROM usable u
        WHERE u.has_equality
        GROUP BY u.oid, u.schema, u.relname, u.reltuples, u.est_rows, u.total_bytes, u.node
        HAVING count(*) >= 2
    ),
    proposals AS (
        SELECT s.schema || '.' || s.relname AS relation,
               ARRAY[s.colname::text] AS columns,
               format('CREATE INDEX CONCURRENTLY %s ON %s.%s (%s);',
                      left(lower('idx_' || s.relname || '_' || s.colname), 63),
                      s.schema, s.relname, s.colname) AS suggested_ddl,
               format('The plan scans %s sequentially with the filter %s; the column %s is a real column '
                      'of the relation and is not the leading column of any existing index',
                      s.relname, COALESCE(s.node->>'Filter', '<none>'), s.colname) AS rationale,
               format('The scan currently reads about %s rows and returns about %s; an index on (%s) '
                      'is expected to read only the matching rows',
                      s.est_rows, COALESCE(s.node->>'Plan Rows', 'unknown'), s.colname) AS estimated_benefit,
               'Each index adds storage and slows down INSERT/UPDATE/DELETE on the relation.' AS estimated_cost,
               CASE WHEN s.has_equality AND s.est_rows >= 10000 THEN 'HIGH'
                    WHEN s.has_equality THEN 'MEDIUM'
                    ELSE 'LOW' END::text AS confidence
        FROM singles s
        UNION ALL
        SELECT c.schema || '.' || c.relname,
               c.cols,
               format('CREATE INDEX CONCURRENTLY %s ON %s.%s (%s);',
                      left(lower('idx_' || c.relname || '_'
                                 || regexp_replace(array_to_string(c.cols, '_'), '[^a-z0-9_]', '', 'g')),
                           63),
                      c.schema, c.relname, array_to_string(c.cols, ', ')),
               format('The plan scans %s sequentially with the filter %s; the equality columns %s can be '
                      'combined in a composite index',
                      c.relname, COALESCE(c.node->>'Filter', '<none>'), array_to_string(c.cols, ', ')),
               format('The scan currently reads about %s rows; a composite index on (%s) narrows the scan '
                      'to the rows that match all equality predicates',
                      c.est_rows, array_to_string(c.cols, ', ')),
               'A composite index costs more to maintain than a single-column index, but supports the '
                 'whole equality prefix of the filter.' AS estimated_cost,
               'HIGH'::text
        FROM composites c
    )
    SELECT p.relation,
           p.columns,
           p.suggested_ddl,
           p.rationale,
           p.estimated_benefit,
           p.estimated_cost,
           p.confidence,
           sta.validation_steps('index')
    FROM proposals p
    ORDER BY p.confidence DESC, p.relation, p.columns;
END
$$;

COMMENT ON FUNCTION sta.index_advice(text) IS
  'Index candidates for a statement, derived from the filters of sequential scans in its plan.';

------------------------------------------------------------------------------
-- Validation of a proposed change
--
-- The candidate index is created inside a subtransaction that is rolled back
-- again, so the validation never leaves anything behind in the database.
-- CREATE INDEX CONCURRENTLY is rejected because it cannot run inside a
-- transaction block.
------------------------------------------------------------------------------
CREATE FUNCTION sta.validate(
    p_index_ddl  text,
    p_sql        text,
    p_iterations integer DEFAULT 3
)
RETURNS TABLE (
    baseline_ms     double precision,
    candidate_ms    double precision,
    improvement_pct double precision,
    plan_changed    boolean,
    rows_match      boolean,
    verdict         text,
    baseline_plan   jsonb,
    candidate_plan  jsonb,
    notes           text[]
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_plan       jsonb;
    v_base_times double precision[] := ARRAY[]::double precision[];
    v_cand_times double precision[] := ARRAY[]::double precision[];
    v_base_plan  jsonb;
    v_cand_plan  jsonb;
    v_base_sig   text;
    v_cand_sig   text;
    v_base_rows  numeric;
    v_cand_rows  numeric;
    v_base_avg   double precision;
    v_cand_avg   double precision;
    v_improvement double precision := NULL;
    v_verdict    text;
    v_notes      text[] := ARRAY[]::text[];
    i            integer;
BEGIN
    IF p_index_ddl IS NULL OR btrim(p_index_ddl) = '' THEN
        RAISE EXCEPTION 'sta.validate: p_index_ddl must not be empty';
    END IF;
    IF p_index_ddl !~* '^\s*CREATE\s+(UNIQUE\s+)?INDEX([[:space:]]|$)' THEN
        RAISE EXCEPTION 'sta.validate: p_index_ddl must be a CREATE [UNIQUE] INDEX statement';
    END IF;
    IF p_index_ddl ~* '\bCONCURRENTLY\b' THEN
        RAISE EXCEPTION 'sta.validate: CREATE INDEX CONCURRENTLY cannot be used here because it cannot run inside a transaction block. Remove CONCURRENTLY; sta.validate always rolls the index back.';
    END IF;
    IF p_index_ddl ~ ';' AND p_index_ddl !~ ';\s*$' THEN
        RAISE EXCEPTION 'sta.validate: p_index_ddl must contain exactly one statement';
    END IF;
    IF p_iterations < 1 OR p_iterations > 100 THEN
        RAISE EXCEPTION 'sta.validate: p_iterations must be between 1 and 100';
    END IF;

    -- Baseline: run the statement without any change.
    FOR i IN 1..p_iterations LOOP
        v_plan := sta.explain(p_sql, true);
        v_base_times := array_append(v_base_times,
            COALESCE(NULLIF((v_plan->0)->>'Execution Time','')::double precision, 0));
        IF i = 1 THEN
            v_base_plan := v_plan;
            v_base_sig  := sta.plan_signature(v_plan);
            v_base_rows := NULLIF(v_base_plan->0->'Plan'->>'Actual Rows','')::numeric;
        END IF;
    END LOOP;

    -- Candidate: create the index, measure, then roll everything back.
    BEGIN
        EXECUTE p_index_ddl;

        FOR i IN 1..p_iterations LOOP
            v_plan := sta.explain(p_sql, true);
            v_cand_times := array_append(v_cand_times,
                COALESCE(NULLIF((v_plan->0)->>'Execution Time','')::double precision, 0));
            IF i = 1 THEN
                v_cand_plan := v_plan;
                v_cand_sig  := sta.plan_signature(v_plan);
                v_cand_rows := NULLIF(v_cand_plan->0->'Plan'->>'Actual Rows','')::numeric;
            END IF;
        END LOOP;

        RAISE EXCEPTION 'pg_sta_validate_rollback';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM = 'pg_sta_validate_rollback' THEN
                v_notes := array_append(v_notes,
                    'The candidate index was created in a subtransaction and rolled back; the database is unchanged.');
            ELSE
                v_notes := array_append(v_notes, 'The candidate run failed: ' || SQLERRM);
                v_cand_times := ARRAY[]::double precision[];
                v_cand_plan  := NULL;
                v_cand_sig   := NULL;
                v_cand_rows  := NULL;
            END IF;
    END;

    v_base_avg := (SELECT avg(x) FROM unnest(v_base_times) AS x);
    v_cand_avg := (SELECT avg(x) FROM unnest(v_cand_times) AS x);

    IF v_cand_avg IS NULL THEN
        v_verdict := 'ERROR';
        v_notes := array_append(v_notes,
            'The candidate run did not produce a usable measurement, so no verdict could be reached.');
    ELSE
        v_improvement := CASE WHEN v_base_avg > 0
                              THEN 100.0 * (v_base_avg - v_cand_avg) / v_base_avg
                              ELSE 0 END;

        IF v_base_rows IS NOT NULL AND v_cand_rows IS NOT NULL AND v_base_rows <> v_cand_rows THEN
            /*
             * The statement is not deterministic, so the two measurements
             * cannot be compared at all.  Report that instead of a number
             * that looks meaningful but is not.
             */
            v_verdict := 'NOT_COMPARABLE';
            v_notes := array_append(v_notes,
                'The statement returned a different number of rows before and after; the measurement is not comparable.');
        ELSIF v_base_sig IS NOT DISTINCT FROM v_cand_sig THEN
            /*
             * The plan did not change, which means the planner did not pick
             * the candidate index.  Any timing difference is measurement
             * noise and must not be reported as an improvement.
             */
            v_verdict := 'NOT_USED';
            v_notes := array_append(v_notes,
                'The plan shape did not change: the planner did not pick the candidate index.');
            v_notes := array_append(v_notes,
                'The measured difference is therefore noise and not an effect of the index.');
        ELSIF v_improvement >= 5 THEN
            v_verdict := 'RECOMMENDED';
        ELSIF v_improvement <= -5 THEN
            v_verdict := 'REJECTED';
        ELSE
            v_verdict := 'NO_SIGNIFICANT_CHANGE';
        END IF;
    END IF;

    RETURN QUERY
    SELECT v_base_avg,
           v_cand_avg,
           v_improvement,
           (v_cand_sig IS NOT NULL AND v_base_sig IS DISTINCT FROM v_cand_sig),
           (v_base_rows IS NOT DISTINCT FROM v_cand_rows),
           v_verdict,
           v_base_plan,
           v_cand_plan,
           v_notes;
END
$$;

COMMENT ON FUNCTION sta.validate(text, text, integer) IS
  'Measure a proposed index against the current plan and report the improvement. '
  'The index is created and rolled back again, so nothing is left in the database. '
  'The verdict is one of RECOMMENDED (plan changed and at least 5% faster), '
  'REJECTED (plan changed and at least 5% slower), NO_SIGNIFICANT_CHANGE (plan changed, '
  'but the timing difference is below the threshold), NOT_USED (the planner did not pick '
  'the index, so the measurement is noise), NOT_COMPARABLE (the statement returned a '
  'different number of rows) or ERROR (the candidate run failed).';

------------------------------------------------------------------------------
-- Combined recommendations
------------------------------------------------------------------------------
CREATE FUNCTION sta.recommendations(
    p_sql     text    DEFAULT NULL,
    p_window  text    DEFAULT 'window',
    p_analyze boolean DEFAULT false,
    p_limit   integer DEFAULT 50
)
RETURNS TABLE (
    finding_id       integer,
    category         text,
    severity         text,
    confidence       text,
    impact_score     integer,
    object_name      text,
    queryid          bigint,
    query            text,
    finding          text,
    finding_text     text,
    evidence         jsonb,
    recommendation   text,
    expected_benefit text,
    estimated_cost   text,
    validation_steps text[]
)
LANGUAGE sql
STABLE
AS $$
    WITH w AS (
        SELECT * FROM sta.workload_advice(p_window, 0, 0, p_limit)
    ),
    p AS (
        SELECT * FROM sta.plan_advice(p_sql, p_analyze, p_limit) WHERE p_sql IS NOT NULL
    ),
    s AS (
        SELECT * FROM sta.stats_advice(NULL, p_limit)
    ),
    all_findings AS (
        SELECT w.category, w.severity, w.confidence, w.impact_score,
               NULL::text AS object_name, w.queryid, w.query, w.finding, w.finding_text, w.evidence,
               w.recommendation, w.expected_benefit, w.estimated_cost, w.validation_steps
        FROM w
        UNION ALL
        SELECT pl.category, pl.severity, pl.confidence, pl.impact_score,
               pl.object_name, NULL::bigint, NULL::text, pl.finding, pl.finding_text, pl.evidence,
               pl.recommendation, pl.expected_benefit, pl.estimated_cost, pl.validation_steps
        FROM p pl
        UNION ALL
        SELECT st.category, st.severity, st.confidence, st.impact_score,
               st.object_name, NULL::bigint, NULL::text, st.finding, st.finding_text, st.evidence,
               st.recommendation, st.expected_benefit, st.estimated_cost, st.validation_steps
        FROM s st
    )
    SELECT (ROW_NUMBER() OVER (ORDER BY f.impact_score DESC,
                               CASE f.severity
                                   WHEN 'CRITICAL' THEN 0 WHEN 'HIGH' THEN 1
                                   WHEN 'MEDIUM'   THEN 2 WHEN 'LOW'    THEN 3 ELSE 4 END))::integer,
           f.category,
           f.severity,
           f.confidence,
           f.impact_score,
           f.object_name,
           f.queryid,
           f.query,
           f.finding,
           f.finding_text,
           f.evidence,
           f.recommendation,
           f.expected_benefit,
           f.estimated_cost,
           f.validation_steps
    FROM all_findings f
    ORDER BY f.impact_score DESC,
             CASE f.severity
                 WHEN 'CRITICAL' THEN 0 WHEN 'HIGH' THEN 1
                 WHEN 'MEDIUM'   THEN 2 WHEN 'LOW'    THEN 3 ELSE 4 END
    LIMIT LEAST(GREATEST(p_limit, 1), sta._max_findings())
$$;

COMMENT ON FUNCTION sta.recommendations(text, text, boolean, integer) IS
  'All findings from the workload, plan and statistics advisors, ranked by impact.';

------------------------------------------------------------------------------
-- Everything that is known about a single statement
------------------------------------------------------------------------------
CREATE FUNCTION sta.statement_advice(p_queryid bigint, p_analyze boolean DEFAULT false)
RETURNS TABLE (
    finding_id       integer,
    category         text,
    severity         text,
    confidence       text,
    impact_score     integer,
    object_name      text,
    finding          text,
    finding_text     text,
    evidence         jsonb,
    recommendation   text,
    expected_benefit text,
    estimated_cost   text,
    validation_steps text[]
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_text text;
BEGIN
    v_text := sta.statement_text(p_queryid);
    IF v_text IS NULL THEN
        RAISE NOTICE 'sta.statement_advice: no statement found for query id %', p_queryid;
        RETURN;
    END IF;

    RETURN QUERY
    WITH plan_rows AS (
        SELECT * FROM sta.plan_advice(v_text, p_analyze, 100)
    ),
    workload_rows AS (
        SELECT * FROM sta.workload_advice('cumulative', 0, 0, 200) WHERE queryid = p_queryid
    ),
    plan_rels AS (
        SELECT DISTINCT r.schema, r.relname
        FROM sta._plan_nodes(sta.explain(v_text, false)) n
        JOIN LATERAL sta._resolve_relation(n.node->>'Relation Name', n.node->>'Schema') r ON TRUE
    ),
    stats_rows AS (
        SELECT st.*
        FROM sta.stats_advice(NULL, 1000) st
        JOIN plan_rels pr ON pr.schema || '.' || pr.relname = st.object_name
    ),
    all_rows AS (
        SELECT p.category, p.severity, p.confidence, p.impact_score, p.object_name,
               p.finding, p.finding_text, p.evidence, p.recommendation, p.expected_benefit,
               p.estimated_cost, p.validation_steps
        FROM plan_rows p
        UNION ALL
        SELECT w.category, w.severity, w.confidence, w.impact_score, NULL::text,
               w.finding, w.finding_text, w.evidence, w.recommendation, w.expected_benefit,
               w.estimated_cost, w.validation_steps
        FROM workload_rows w
        UNION ALL
        SELECT s.category, s.severity, s.confidence, s.impact_score, s.object_name,
               s.finding, s.finding_text, s.evidence, s.recommendation, s.expected_benefit,
               s.estimated_cost, s.validation_steps
        FROM stats_rows s
    )
    SELECT (ROW_NUMBER() OVER (ORDER BY a.impact_score DESC,
                               CASE a.severity
                                   WHEN 'CRITICAL' THEN 0 WHEN 'HIGH' THEN 1
                                   WHEN 'MEDIUM'   THEN 2 WHEN 'LOW'    THEN 3 ELSE 4 END))::integer,
           a.category, a.severity, a.confidence, a.impact_score, a.object_name,
           a.finding, a.finding_text, a.evidence, a.recommendation, a.expected_benefit,
           a.estimated_cost, a.validation_steps
    FROM all_rows a
    ORDER BY a.impact_score DESC,
             CASE a.severity
                 WHEN 'CRITICAL' THEN 0 WHEN 'HIGH' THEN 1
                 WHEN 'MEDIUM'   THEN 2 WHEN 'LOW'    THEN 3 ELSE 4 END;
END
$$;

COMMENT ON FUNCTION sta.statement_advice(bigint, boolean) IS
  'All findings that relate to one statement: plan, workload and relation statistics.';

------------------------------------------------------------------------------
-- EXPLAIN by canonical query id
------------------------------------------------------------------------------
CREATE FUNCTION sta.explain_by_queryid(p_queryid bigint, p_analyze boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_text text;
BEGIN
    v_text := sta.statement_text(p_queryid);
    IF v_text IS NULL THEN
        RAISE EXCEPTION 'sta.explain_by_queryid: no statement found for query id %', p_queryid;
    END IF;
    RETURN sta.explain(v_text, p_analyze);
END
$$;

COMMENT ON FUNCTION sta.explain_by_queryid(bigint, boolean) IS
  'EXPLAIN of the statement identified by a canonical query id.';

------------------------------------------------------------------------------
-- Catalogue of all findings
------------------------------------------------------------------------------
CREATE FUNCTION sta.advice_catalog()
RETURNS TABLE (
    category           text,
    finding            text,
    default_severity   text,
    description        text,
    evidence_source    text,
    recommended_action text,
    validation_kind    text
)
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT * FROM (VALUES
      ('workload', 'HIGH_TOTAL_TIME', 'HIGH',
       'The statement consumes a large share of the total execution time of the observed window.',
       'pg_stat_statements.total_exec_time',
       'Reduce the execution time of the statement.', 'workload'),
      ('workload', 'HIGH_MEAN_EXEC_TIME', 'HIGH',
       'Every single execution of the statement is slow.',
       'pg_stat_statements.mean_exec_time',
       'Inspect the plan of the statement for an access-path problem.', 'plan'),
      ('workload', 'HIGH_FREQUENCY', 'MEDIUM',
       'The statement is executed very often.',
       'pg_stat_statements.calls',
       'Optimise the hot path of the statement.', 'workload'),
      ('workload', 'LOW_CACHE_HIT_RATIO', 'MEDIUM',
       'The statement reads most of its blocks from storage instead of the buffer cache.',
       'pg_stat_statements.shared_blks_hit / shared_blks_read',
       'Reduce the working set or improve locality.', 'config'),
      ('workload', 'HIGH_TEMP_IO', 'MEDIUM',
       'The statement spills to temporary files.',
       'pg_stat_statements.temp_blks_written',
       'Raise work_mem or reduce the size of the sorted or hashed input.', 'config'),
      ('plan', 'SEQ_SCAN_ON_LARGE_TABLE', 'HIGH',
       'A sequential scan reads a large relation although an index could serve the filter.',
       'EXPLAIN Plan Node Type = Seq Scan',
       'Add an index that supports the filter.', 'index'),
      ('plan', 'SEQ_SCAN_ON_SMALL_TABLE', 'INFO',
       'A sequential scan over a small relation is appropriate.',
       'EXPLAIN Plan Node Type = Seq Scan',
       'No action required.', 'plan'),
      ('plan', 'ESTIMATE_MISMATCH', 'HIGH',
       'The planner estimate differs from the actual number of rows by a large factor.',
       'EXPLAIN Plan Rows vs Actual Rows',
       'Refresh the statistics of the affected relation.', 'analyze'),
      ('plan', 'SORT_SPILLED_TO_DISK', 'MEDIUM',
       'The sort did not fit into work_mem and was written to disk.',
       'EXPLAIN Sort Method = external disk',
       'Raise work_mem or sort fewer rows.', 'config'),
      ('plan', 'HASH_BATCHES', 'MEDIUM',
       'The hash join needed more than one batch, so the hash table did not fit into memory.',
       'EXPLAIN Hash Batches',
       'Raise work_mem.', 'config'),
      ('plan', 'ROWS_REMOVED_BY_FILTER', 'MEDIUM',
       'Most rows read by the node were discarded by the filter.',
       'EXPLAIN Rows Removed by Filter',
       'Add an index that supports the filter.', 'index'),
      ('plan', 'BITMAP_LOSSY_RECHECK', 'MEDIUM',
       'The bitmap heap scan lost pages and had to re-check rows one by one.',
       'EXPLAIN Heap Blocks Lost',
       'Raise work_mem so the bitmap fits in memory.', 'config'),
      ('plan', 'NESTED_LOOP_HIGH_LOOPS', 'MEDIUM',
       'The nested loop ran far more often than the planner assumed.',
       'EXPLAIN Actual Loops',
       'Check the join condition and the statistics of the inner relation.', 'analyze'),
      ('plan', 'TEMP_BLOCKS_WRITTEN', 'MEDIUM',
       'The node wrote temporary blocks.',
       'EXPLAIN Temp Written Blocks',
       'Remove the spill.', 'config'),
      ('plan', 'HIGH_TOTAL_COST', 'LOW',
       'The plan node has a very high cost estimate.',
       'EXPLAIN Total Cost',
       'Look for a cheaper access path.', 'plan'),
      ('plan', 'SLOW_EXECUTION_TIME', 'HIGH',
       'The statement itself was slow when it was measured.',
       'EXPLAIN Execution Time',
       'Combine the measurement with the workload statistics.', 'workload'),
      ('statistics', 'NEVER_ANALYZED', 'HIGH',
       'The relation has never been analyzed.',
       'pg_stat_all_tables.last_analyze / last_autoanalyze',
       'Run ANALYZE.', 'analyze'),
      ('statistics', 'STALE_STATISTICS', 'MEDIUM',
       'The relation changed a lot since it was last analyzed.',
       'pg_stat_all_tables.n_mod_since_analyze',
       'Run ANALYZE.', 'analyze'),
      ('statistics', 'HIGH_DEAD_TUPLES', 'MEDIUM',
       'The relation accumulated many dead tuples.',
       'pg_stat_all_tables.n_dead_tup',
       'Run VACUUM (ANALYZE).', 'vacuum'),
      ('statistics', 'NO_PRIMARY_KEY', 'LOW',
       'The relation has no primary key.',
       'pg_index.indisprimary',
       'Consider adding a primary key.', 'plan'),
      ('statistics', 'NO_INDEXES', 'INFO',
       'The relation has no indexes at all.',
       'pg_index',
       'Index the columns used in WHERE and JOIN clauses.', 'index'),
      ('snapshot', 'DEAD_TUPLE_GROWTH', 'MEDIUM',
       'Dead tuples appeared between two snapshots and were not reclaimed.',
       'sta.table_stats_sample.n_dead_tup',
       'Run VACUUM (ANALYZE).', 'vacuum'),
      ('snapshot', 'STATISTICS_GO_STALE', 'MEDIUM',
       'The relation changed between two snapshots and was not analyzed in between.',
       'sta.table_stats_sample.n_mod_since_analyze',
       'Run ANALYZE.', 'analyze'),
      ('snapshot', 'TABLE_GROWTH', 'INFO',
       'The relation grew noticeably between two snapshots.',
       'sta.table_stats_sample.n_live_tup',
       'Review the growth rate and make sure autovacuum keeps up.', 'plan'),
      ('snapshot', 'INDEX_NO_LONGER_USED', 'LOW',
       'The index was used before but has not been used during the last window.',
       'sta.index_sample.idx_scan',
       'Review the index; drop it only if it stays unused over several windows.', 'index')
    ) AS t(category, finding, default_severity, description, evidence_source,
           recommended_action, validation_kind)
$$;

COMMENT ON FUNCTION sta.advice_catalog() IS
  'Catalogue of every finding that pg_sta can produce, with its evidence source.';

------------------------------------------------------------------------------
-- PostgreSQL 19 parity: plan advice and advice stashes
--
-- PostgreSQL 19 ships two contrib modules that pg_sta mirrors:
--
--   pg_plan_advice  - a mini-language that pins planner decisions
--   pg_stash_advice - per-query-id advice kept in a named "stash"
--
-- pg_sta implements the same advice language and the same stash API, renamed
-- into the "sta" schema.  PostgreSQL 19 hooks the planner itself; PostgreSQL
-- 17 has no such hook, so pg_sta expresses the advice through the planner's
-- enable_* GUCs.  That is an approximation and is documented as such in
-- docs/pg19-compatibility.md.
------------------------------------------------------------------------------

CREATE TABLE sta.plan_advice_tag (
    tag          text PRIMARY KEY,
    category     text NOT NULL,
    description  text NOT NULL,
    enforcement  text NOT NULL
                CHECK (enforcement IN ('exact', 'approximate', 'unsupported'))
);

COMMENT ON TABLE sta.plan_advice_tag IS
  'The advice tags understood by pg_sta, mirroring contrib/pg_plan_advice in PostgreSQL 19. '
  'enforcement = exact means PostgreSQL 17 can reproduce the decision faithfully, '
  'approximate means the decision is expressed with planner GUCs, and unsupported means '
  'PostgreSQL 17 has no mechanism for it.';

CREATE TABLE sta.plan_advice_guc (
    tag        text NOT NULL REFERENCES sta.plan_advice_tag(tag) ON DELETE CASCADE,
    guc_name   text NOT NULL,
    guc_value  text NOT NULL,
    note       text NOT NULL DEFAULT '',
    PRIMARY KEY (tag, guc_name)
);

COMMENT ON TABLE sta.plan_advice_guc IS
  'How each advice tag is expressed with planner GUCs on PostgreSQL 17.  The GUCs are '
  'session-wide, so a relation-targeted piece of advice constrains the whole statement.';

INSERT INTO sta.plan_advice_tag (tag, category, description, enforcement) VALUES
 ('SEQ_SCAN',          'scan',      'Force a sequential scan of the named relation.',          'approximate'),
 ('INDEX_SCAN',        'scan',      'Force an index scan of the named relation.',                'approximate'),
 ('INDEX_ONLY_SCAN',   'scan',      'Force an index-only scan of the named relation.',           'approximate'),
 ('BITMAP_HEAP_SCAN',  'scan',      'Force a bitmap heap scan of the named relation.',           'approximate'),
 ('DO_NOT_SCAN',       'scan',      'Refuse to scan the named relation at all.',                 'unsupported'),
 ('NESTED_LOOP_PLAIN', 'join',      'Use a plain nested loop join.',                            'approximate'),
 ('HASH_JOIN',         'join',      'Use a hash join.',                                        'approximate'),
 ('MERGE_JOIN',        'join',      'Use a merge join.',                                       'approximate'),
 ('JOIN_ORDER',        'join',      'Pin the order in which relations are joined.',             'unsupported'),
 ('SEMIJOIN_UNIQUE',   'join',      'Use a unique semi join.',                                 'unsupported'),
 ('SEMIJOIN_NON_UNIQUE','join',      'Use a non-unique semi join.',                             'unsupported'),
 ('PARTITIONWISE',     'partition', 'Allow partition-wise joins and aggregates.',               'approximate'),
 ('GATHER',            'parallel',  'Use a parallel gather plan.',                             'unsupported'),
 ('GATHER_MERGE',      'parallel',  'Use a parallel gather merge plan.',                       'unsupported'),
 ('NO_GATHER',         'parallel',  'Forbid parallel workers for this statement.',              'approximate');

INSERT INTO sta.plan_advice_guc (tag, guc_name, guc_value, note) VALUES
 ('SEQ_SCAN',          'enable_indexscan',          'off', 'A sequential scan must not be replaced by an index scan.'),
 ('SEQ_SCAN',          'enable_indexonlyscan',      'off', 'A sequential scan must not be replaced by an index-only scan.'),
 ('SEQ_SCAN',          'enable_bitmapscan',         'off', 'A sequential scan must not be replaced by a bitmap scan.'),
 ('INDEX_SCAN',        'enable_seqscan',            'off', 'An index scan must not be replaced by a sequential scan.'),
 ('INDEX_SCAN',        'enable_bitmapscan',         'off', 'An index scan must not be replaced by a bitmap scan.'),
 ('INDEX_ONLY_SCAN',   'enable_seqscan',            'off', 'An index-only scan must not be replaced by a sequential scan.'),
 ('INDEX_ONLY_SCAN',   'enable_bitmapscan',         'off', 'An index-only scan must not be replaced by a bitmap scan.'),
 ('INDEX_ONLY_SCAN',   'enable_indexscan',          'off', 'An index-only scan must not be replaced by a plain index scan.'),
 ('BITMAP_HEAP_SCAN',  'enable_seqscan',            'off', 'A bitmap heap scan must not be replaced by a sequential scan.'),
 ('BITMAP_HEAP_SCAN',  'enable_indexscan',          'off', 'A bitmap heap scan must not be replaced by an index scan.'),
 ('BITMAP_HEAP_SCAN',  'enable_indexonlyscan',      'off', 'A bitmap heap scan must not be replaced by an index-only scan.'),
 ('NESTED_LOOP_PLAIN', 'enable_hashjoin',           'off', 'A nested loop must not be replaced by a hash join.'),
 ('NESTED_LOOP_PLAIN', 'enable_mergejoin',          'off', 'A nested loop must not be replaced by a merge join.'),
 ('HASH_JOIN',         'enable_nestloop',           'off', 'A hash join must not be replaced by a nested loop.'),
 ('HASH_JOIN',         'enable_mergejoin',          'off', 'A hash join must not be replaced by a merge join.'),
 ('MERGE_JOIN',        'enable_nestloop',           'off', 'A merge join must not be replaced by a nested loop.'),
 ('MERGE_JOIN',        'enable_hashjoin',           'off', 'A merge join must not be replaced by a hash join.'),
 ('PARTITIONWISE',     'enable_partitionwise_join', 'on',  'Partition-wise joins become available.'),
 ('PARTITIONWISE',     'enable_partitionwise_aggregate', 'on', 'Partition-wise aggregates become available.'),
 ('NO_GATHER',         'max_parallel_workers_per_gather', '0', 'No parallel workers may be gathered.');

------------------------------------------------------------------------------
-- Advice language
--
-- The language is the one used by contrib/pg_plan_advice: whitespace
-- separated items of the form TAG(targets), where the target list may
-- itself contain spaces, for example JOIN_ORDER(f d1 d2).
------------------------------------------------------------------------------

CREATE FUNCTION sta._advice_split(p_advice text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT COALESCE(array_agg(m[1] || COALESCE(m[2], '')), '{}'::text[])
    FROM regexp_matches(COALESCE(p_advice, ''),
                        '([A-Za-z_][A-Za-z0-9_]*)\s*(\(([^()]*)\))?',
                        'g') AS m
$$;

COMMENT ON FUNCTION sta._advice_split(text) IS
  'Split an advice string into its individual TAG(targets) items.';

CREATE FUNCTION sta._advice_parse(p_advice text)
RETURNS TABLE (item text, tag text, targets text[])
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT m[1] || COALESCE(m[2], '') AS item,
           upper(m[1]) AS tag,
           CASE
             WHEN btrim(COALESCE(m[3], '')) = '' THEN '{}'::text[]
             ELSE string_to_array(btrim(m[3]), ' ')
           END AS targets
    FROM regexp_matches(COALESCE(p_advice, ''),
                        '([A-Za-z_][A-Za-z0-9_]*)\s*(\(([^()]*)\))?',
                        'g') AS m
$$;

COMMENT ON FUNCTION sta._advice_parse(text) IS
  'Parse an advice string into its items, tags and target lists.  Tags are '
  'case-insensitive and returned in upper case.';

------------------------------------------------------------------------------
-- Generating advice from a plan
--
-- The advice produced here is written in the pg_plan_advice language and can
-- be fed back to sta.explain_with_advice().  Relation identifiers use the
-- alias of the plan node; when the same alias occurs more than once in a
-- plan the occurrence number is appended as alias#n, matching the shape of
-- the identifiers used by PostgreSQL 19.
------------------------------------------------------------------------------

CREATE FUNCTION sta.plan_advice_string(p_sql text, p_analyze boolean DEFAULT false)
RETURNS text
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_plan jsonb;
    v_out  text;
BEGIN
    v_plan := sta.explain(p_sql, p_analyze);

    WITH RECURSIVE tree AS (
        SELECT (v_plan->0)->'Plan' AS node, ARRAY[0]::bigint[] AS path
        UNION ALL
        SELECT c.node, t.path || c.ord
        FROM tree t
        CROSS JOIN LATERAL (
            SELECT ch.node, (ch.ord - 1) AS ord
            FROM jsonb_array_elements(
                     CASE WHEN jsonb_typeof(t.node->'Plans') = 'array'
                          THEN t.node->'Plans' ELSE '[]'::jsonb END
                 ) WITH ORDINALITY AS ch(node, ord)
        ) c
    ),
    nodes AS (
        SELECT t.path,
               t.node,
               t.node->>'Node Type'                        AS node_type,
               t.node->>'Index Name'                       AS index_name,
               COALESCE(t.node->>'Alias', t.node->>'Relation Name') AS rel_alias,
               CASE
                 WHEN jsonb_typeof(t.node->'Plans') = 'array'
                      AND jsonb_array_length(t.node->'Plans') > 1
                   THEN COALESCE(t.node->'Plans'->1->>'Alias',
                                 t.node->'Plans'->1->>'Relation Name')
                 WHEN jsonb_typeof(t.node->'Plans') = 'array'
                      AND jsonb_array_length(t.node->'Plans') > 0
                   THEN COALESCE(t.node->'Plans'->0->>'Alias',
                                 t.node->'Plans'->0->>'Relation Name')
               END AS child_alias
        FROM tree t
        WHERE t.node IS NOT NULL
    ),
    numbered AS (
        SELECT n.*,
               count(*) OVER (PARTITION BY n.rel_alias ORDER BY n.path) AS occurrence
        FROM nodes n
        WHERE n.rel_alias IS NOT NULL
    ),
    items AS (
        SELECT path,
               CASE node_type
                 WHEN 'Seq Scan'         THEN 'SEQ_SCAN(' || rel_alias
                                          || CASE WHEN occurrence > 1 THEN '#' || occurrence ELSE '' END || ')'
                 WHEN 'Index Scan'       THEN 'INDEX_SCAN(' || rel_alias
                                          || CASE WHEN occurrence > 1 THEN '#' || occurrence ELSE '' END
                                          || ' ' || index_name || ')'
                 WHEN 'Index Only Scan'  THEN 'INDEX_ONLY_SCAN(' || rel_alias
                                          || CASE WHEN occurrence > 1 THEN '#' || occurrence ELSE '' END
                                          || ' ' || index_name || ')'
                 WHEN 'Bitmap Heap Scan' THEN 'BITMAP_HEAP_SCAN(' || rel_alias
                                          || CASE WHEN occurrence > 1 THEN '#' || occurrence ELSE '' END || ')'
                 WHEN 'Hash Join'        THEN 'HASH_JOIN(' || child_alias || ')'
                 WHEN 'Merge Join'       THEN 'MERGE_JOIN(' || child_alias || ')'
                 WHEN 'Nested Loop'      THEN 'NESTED_LOOP_PLAIN(' || child_alias || ')'
                 WHEN 'Gather'           THEN 'GATHER(' || child_alias || ')'
                 WHEN 'Gather Merge'     THEN 'GATHER_MERGE(' || child_alias || ')'
               END AS item
        FROM numbered
    )
    SELECT COALESCE(string_agg(item, ' ' ORDER BY path), '')
      INTO v_out
    FROM items
    WHERE item IS NOT NULL;

    RETURN v_out;
END;
$$;

COMMENT ON FUNCTION sta.plan_advice_string(text, boolean) IS
  'Generate pg_plan_advice-style advice that reproduces the current plan of a statement. '
  'The result can be passed to sta.explain_with_advice().';

------------------------------------------------------------------------------
-- Advice stashes
--
-- The stash API mirrors contrib/pg_stash_advice in PostgreSQL 19:
--
--   pg_create_advice_stash(stash_name)          -> sta.create_stash(stash_name)
--   pg_drop_advice_stash(stash_name)            -> sta.drop_stash(stash_name)
--   pg_set_stashed_advice(stash, qid, advice)   -> sta.set_stashed_advice(...)
--   pg_get_advice_stashes()                     -> sta.get_stashes()
--   pg_get_advice_stash_contents(stash)         -> sta.get_stash_contents(stash)
--
-- PostgreSQL 19 keeps stashes in dynamic shared memory and applies them from
-- a background worker.  pg_sta keeps them in ordinary tables, which makes
-- them durable and visible across backends, and applies them on demand.
------------------------------------------------------------------------------

CREATE TABLE sta.advice_stash (
    stash_name text PRIMARY KEY,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT advice_stash_name_check CHECK (stash_name ~ '^[A-Za-z_][A-Za-z0-9_]*$'),
    CONSTRAINT advice_stash_length_check CHECK (length(stash_name) <= 63)
);

COMMENT ON TABLE sta.advice_stash IS
  'Named advice stashes.  Names must be valid identifiers of at most 63 characters.';

CREATE TABLE sta.advice_stash_entry (
    stash_name    text NOT NULL REFERENCES sta.advice_stash(stash_name) ON DELETE CASCADE,
    query_id      bigint NOT NULL,
    advice_string text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (stash_name, query_id),
    CONSTRAINT advice_stash_entry_query_id_check CHECK (query_id <> 0)
);

COMMENT ON TABLE sta.advice_stash_entry IS
  'Per-query-id advice inside a stash.  One row per query id and stash.';

CREATE FUNCTION sta.create_stash(p_name text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_name IS NULL OR p_name !~ '^[A-Za-z_][A-Za-z0-9_]*$' OR length(p_name) > 63 THEN
        RAISE EXCEPTION 'invalid advice stash name: %', COALESCE(p_name, '<null>')
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF EXISTS (SELECT 1 FROM sta.advice_stash WHERE stash_name = p_name) THEN
        RAISE EXCEPTION 'advice stash "%" already exists', p_name
            USING ERRCODE = 'duplicate_object';
    END IF;

    INSERT INTO sta.advice_stash(stash_name) VALUES (p_name);
END;
$$;

COMMENT ON FUNCTION sta.create_stash(text) IS
  'Create an empty advice stash.  Fails if the stash already exists or the name is invalid.';

CREATE FUNCTION sta.drop_stash(p_name text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM sta.advice_stash WHERE stash_name = p_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'advice stash "%" does not exist', p_name
            USING ERRCODE = 'undefined_object';
    END IF;
END;
$$;

COMMENT ON FUNCTION sta.drop_stash(text) IS
  'Drop an advice stash and every entry in it.  Fails if the stash does not exist.';

CREATE FUNCTION sta.set_stashed_advice(
    p_name   text,
    p_queryid bigint,
    p_advice text
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sta.advice_stash WHERE stash_name = p_name) THEN
        RAISE EXCEPTION 'advice stash "%" does not exist', p_name
            USING ERRCODE = 'undefined_object';
    END IF;

    IF p_queryid IS NULL OR p_queryid = 0 THEN
        RAISE EXCEPTION 'query id must not be zero'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF p_advice IS NULL THEN
        DELETE FROM sta.advice_stash_entry
         WHERE stash_name = p_name AND query_id = p_queryid;
    ELSE
        INSERT INTO sta.advice_stash_entry(stash_name, query_id, advice_string)
        VALUES (p_name, p_queryid, p_advice)
        ON CONFLICT (stash_name, query_id)
        DO UPDATE SET advice_string = EXCLUDED.advice_string,
                      created_at   = clock_timestamp();
    END IF;
END;
$$;

COMMENT ON FUNCTION sta.set_stashed_advice(text, bigint, text) IS
  'Store advice for one query id in a stash.  A NULL advice removes the entry.';

CREATE FUNCTION sta.get_stashes()
RETURNS TABLE (stash_name text, num_entries bigint)
LANGUAGE sql
STABLE
AS $$
    SELECT s.stash_name, count(e.query_id)::bigint
      FROM sta.advice_stash s
      LEFT JOIN sta.advice_stash_entry e ON e.stash_name = s.stash_name
     GROUP BY s.stash_name
     ORDER BY s.stash_name
$$;

COMMENT ON FUNCTION sta.get_stashes() IS
  'List every advice stash with the number of entries it holds.';

CREATE FUNCTION sta.get_stash_contents(p_stash text DEFAULT NULL)
RETURNS TABLE (stash_name text, query_id bigint, advice_string text)
LANGUAGE sql
STABLE
AS $$
    SELECT e.stash_name, e.query_id, e.advice_string
      FROM sta.advice_stash_entry e
     WHERE p_stash IS NULL OR e.stash_name = p_stash
     ORDER BY e.stash_name, e.query_id
$$;

COMMENT ON FUNCTION sta.get_stash_contents(text) IS
  'List the contents of one stash, or of every stash when the name is NULL.  '
  'An unknown stash name yields no rows rather than an error.';

CREATE FUNCTION sta.get_stashed_advice(p_queryid bigint, p_stash text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_stash text;
    v_advice text;
BEGIN
    v_stash := COALESCE(NULLIF(btrim(COALESCE(p_stash, '')), ''),
                         NULLIF(btrim(COALESCE(current_setting('pg_sta.advice_stash', true), '')), ''));

    IF v_stash IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT e.advice_string INTO v_advice
      FROM sta.advice_stash_entry e
     WHERE e.stash_name = v_stash AND e.query_id = p_queryid;

    RETURN v_advice;
END;
$$;

COMMENT ON FUNCTION sta.get_stashed_advice(bigint, text) IS
  'Return the advice stored for one query id in a stash.  When no stash name is given the '
  'stash named by pg_sta.advice_stash is used.';

------------------------------------------------------------------------------
-- Applying advice
--
-- sta.apply_advice() translates an advice string into planner GUC settings and
-- records the previous values in the pg_sta.advice_state GUC, so that
-- sta.restore_advice() can put the session back exactly as it was.
------------------------------------------------------------------------------

CREATE FUNCTION sta.apply_advice(p_advice text)
RETURNS text[]
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_item     record;
    v_guc      record;
    v_state    text := '';
    v_applied  text[] := '{}';
    v_previous text;
    v_seen     text[] := '{}';
BEGIN
    -- A second apply starts from a clean baseline so that the recorded state
    -- always describes the values that were in force before any advice.
    IF COALESCE(current_setting('pg_sta.advice_state', true), '') <> '' THEN
        PERFORM sta.restore_advice();
    END IF;

    FOR v_item IN SELECT * FROM sta._advice_parse(p_advice) LOOP
        IF NOT EXISTS (SELECT 1 FROM sta.plan_advice_tag t WHERE t.tag = v_item.tag) THEN
            RAISE EXCEPTION 'unknown plan advice tag: %', v_item.tag
                USING ERRCODE = 'invalid_parameter_value';
        END IF;

        FOR v_guc IN
            SELECT g.guc_name, g.guc_value
              FROM sta.plan_advice_guc g
              JOIN sta.plan_advice_tag t ON t.tag = g.tag
             WHERE g.tag = v_item.tag
               AND t.enforcement = 'approximate'
        LOOP
            v_previous := COALESCE(current_setting(v_guc.guc_name, true), '');

            -- Only the value that was in force *before* any advice was applied
            -- must be recorded.  A later advice item that touches the same
            -- setting would otherwise record the value this function has just
            -- written, and restore_advice() would then put back the advised
            -- value instead of the original one.
            IF v_previous <> '' AND NOT (v_guc.guc_name = ANY (v_seen)) THEN
                v_state := v_state
                           || CASE WHEN v_state = '' THEN '' ELSE ';' END
                           || v_guc.guc_name || '=' || v_previous;
                v_seen := v_seen || v_guc.guc_name;
            END IF;

            PERFORM set_config(v_guc.guc_name, v_guc.guc_value, false);
            v_applied := array_append(v_applied,
                                      v_item.tag || ':' || v_guc.guc_name || '=' || v_guc.guc_value);
        END LOOP;

        IF NOT EXISTS (SELECT 1 FROM sta.plan_advice_guc g
                        WHERE g.tag = v_item.tag AND EXISTS (
                                SELECT 1 FROM sta.plan_advice_tag t
                                 WHERE t.tag = g.tag AND t.enforcement = 'approximate')) THEN
            v_applied := array_append(v_applied, v_item.tag || ':unsupported');
        END IF;
    END LOOP;

    PERFORM set_config('pg_sta.advice_state', v_state, false);

    RETURN v_applied;
END;
$$;

COMMENT ON FUNCTION sta.apply_advice(text) IS
  'Apply an advice string by setting the planner GUCs that express it.  Returns one entry '
  'per setting that was changed, in the form TAG:guc=value, plus TAG:unsupported for advice '
  'that PostgreSQL 17 cannot enforce.  The previous values are saved so that '
  'sta.restore_advice() can undo the change.';

CREATE FUNCTION sta.restore_advice()
RETURNS text[]
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_state    text;
    v_part     text;
    v_name     text;
    v_value    text;
    v_restored text[] := '{}';
    v_seen     text[] := '{}';
BEGIN
    v_state := COALESCE(current_setting('pg_sta.advice_state', true), '');

    IF v_state = '' THEN
        RETURN v_restored;
    END IF;

    FOREACH v_part IN ARRAY string_to_array(v_state, ';') LOOP
        v_name  := split_part(v_part, '=', 1);
        v_value := split_part(v_part, '=', 2);

        IF v_name <> '' AND v_value <> '' AND NOT (v_name = ANY (v_seen)) THEN
            PERFORM set_config(v_name, v_value, false);
            v_restored := array_append(v_restored, v_name || '=' || v_value);
            v_seen := v_seen || v_name;
        END IF;
    END LOOP;

    PERFORM set_config('pg_sta.advice_state', '', false);

    RETURN v_restored;
END;
$$;

COMMENT ON FUNCTION sta.restore_advice() IS
  'Undo the planner changes made by sta.apply_advice() and return the restored settings.';

CREATE FUNCTION sta.explain_with_advice(
    p_advice  text,
    p_sql     text,
    p_analyze boolean DEFAULT false
)
RETURNS TABLE (plan jsonb, applied text[], restored text[])
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_applied text[];
    v_plan    jsonb;
BEGIN
    v_applied := sta.apply_advice(p_advice);

    BEGIN
        v_plan := sta.explain(p_sql, p_analyze);
    EXCEPTION WHEN OTHERS THEN
        PERFORM sta.restore_advice();
        RAISE;
    END;

    restored := sta.restore_advice();
    plan     := v_plan;
    applied  := v_applied;

    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION sta.explain_with_advice(text, text, boolean) IS
  'Plan a statement with an advice string applied, then restore the planner settings.  '
  'Returns the plan together with the settings that were applied and restored.';

CREATE FUNCTION sta.run_with_advice(
    p_advice  text,
    p_sql     text,
    p_analyze boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_plan jsonb;
BEGIN
    SELECT e.plan INTO v_plan FROM sta.explain_with_advice(p_advice, p_sql, p_analyze) e;
    RETURN v_plan;
END;
$$;

COMMENT ON FUNCTION sta.run_with_advice(text, text, boolean) IS
  'Plan a statement with an advice string applied and return only the plan.';

CREATE FUNCTION sta.explain_with_stashed_advice(
    p_stash   text,
    p_queryid bigint,
    p_sql     text,
    p_analyze boolean DEFAULT false
)
RETURNS TABLE (plan jsonb, applied text[], restored text[], advice text)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_advice  text;
    v_applied text[];
    v_plan    jsonb;
BEGIN
    v_advice := sta.get_stashed_advice(p_queryid, p_stash);

    IF v_advice IS NULL THEN
        v_plan := sta.explain(p_sql, p_analyze);
        advice := NULL;
        applied := '{}';
        restored := '{}';
        RETURN NEXT;
        RETURN;
    END IF;

    v_applied := sta.apply_advice(v_advice);

    BEGIN
        v_plan := sta.explain(p_sql, p_analyze);
    EXCEPTION WHEN OTHERS THEN
        PERFORM sta.restore_advice();
        RAISE;
    END;

    restored := sta.restore_advice();
    plan     := v_plan;
    applied  := v_applied;
    advice   := v_advice;

    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION sta.explain_with_stashed_advice(text, bigint, text, boolean) IS
  'Plan a statement using the advice stored for its query id in a stash.  When the stash '
  'holds no advice for the query id the statement is planned normally.';

CREATE VIEW sta.plan_advice_tag_view AS
SELECT t.tag,
       t.category,
       t.description,
       t.enforcement,
       (SELECT array_agg(g.guc_name || '=' || g.guc_value ORDER BY g.guc_name)
          FROM sta.plan_advice_guc g
         WHERE g.tag = t.tag) AS guc_settings
FROM sta.plan_advice_tag t;

COMMENT ON VIEW sta.plan_advice_tag_view IS
  'The advice tags pg_sta understands, with the planner settings each one applies.';

------------------------------------------------------------------------------
-- Extension metadata
------------------------------------------------------------------------------
CREATE VIEW sta.advice_run_view AS
SELECT r.run_id,
       r.created_at,
       r.scope,
       r.target,
       r.finding_count,
       r.tool,
       r.notes,
       (SELECT count(*) FROM sta.workload_sample)    AS workload_samples,
       (SELECT count(*) FROM sta.table_stats_sample) AS stats_samples
FROM sta.advice_run r;

COMMENT ON VIEW sta.advice_run_view IS
  'Advisory runs with the number of samples that each run captured.';
