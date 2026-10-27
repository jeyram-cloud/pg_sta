/* pg_sta--0.1.3.sql -- PostgreSQL SQL Tuning Advisor */

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

-- The text that pg_stat_statements stores is normalised: every constant is
-- replaced by a $n placeholder.  The advisor can still plan such a
-- statement, but it cannot see the values, and a rule such as "the pattern
-- starts with a wildcard" needs the value.  A workload therefore registers
-- the text of its statements here, and the advisor uses that text whenever
-- it can be matched to a captured statement by its canonical query id.
CREATE TABLE sta.workload_statement (
    id               bigserial PRIMARY KEY,
    captured_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    queryid          bigint      NOT NULL,
    query            text        NOT NULL,
    normalized_query text        NOT NULL,
    source           text        NOT NULL DEFAULT 'manual'
);

CREATE INDEX workload_statement_queryid_idx
    ON sta.workload_statement (queryid);
CREATE INDEX workload_statement_captured_at_idx
    ON sta.workload_statement (captured_at);
CREATE INDEX workload_statement_normalized_idx
    ON sta.workload_statement (normalized_query);

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
-- Raw statement text
--
-- pg_stat_statements stores the normalised text of a statement: every
-- constant is replaced by a $n placeholder.  The planner can work with
-- that text, but a rewrite rule such as "the LIKE pattern starts with a
-- wildcard" or "the OFFSET skips 10000 rows" needs the values.
--
-- sta.record() registers the text of a statement exactly as it was
-- written.  The advisor looks the text up by its canonical query id, so
-- the counters still come from pg_stat_statements while the rules see the
-- real constants.  Registering a statement is optional: the advisor works
-- without it, it just cannot see the values.
------------------------------------------------------------------------------
CREATE FUNCTION sta.record(
    p_sql   text,
    p_source text DEFAULT 'manual'
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    v_qid  bigint;
    v_norm text;
BEGIN
    IF p_sql IS NULL OR btrim(p_sql) = '' THEN
        RAISE EXCEPTION 'sta.record: the statement text is empty';
    END IF;

    v_qid := sta.queryid(p_sql);
    IF v_qid IS NULL THEN
        RAISE EXCEPTION 'sta.record: the statement could not be parsed';
    END IF;

    v_norm := sta.queryid_normalized(p_sql);

    INSERT INTO sta.workload_statement (queryid, query, normalized_query, source)
    VALUES (v_qid, p_sql, v_norm, coalesce(p_source, 'manual'));

    RETURN v_qid;
END
$$;

COMMENT ON FUNCTION sta.record(text, text) IS
  'Register the text of a statement so that the advisor can see its constants.';

/*
 * The text of a statement as it was written.
 *
 * The advisor works on the text that pg_stat_statements stores, and that
 * text holds a $n placeholder for every constant.  When the workload
 * registered the original text of the statement, the advisor uses that
 * text instead: the rules can then see the values, and the rewritten
 * statement can be executed as it is.
 */
CREATE FUNCTION sta._raw_statement(p_sql text)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_raw text;
BEGIN
    IF p_sql IS NULL OR btrim(p_sql) = '' THEN
        RETURN p_sql;
    END IF;

    -- Text without a placeholder is the text as it was written.
    IF p_sql !~ '\$[0-9]+' THEN
        RETURN p_sql;
    END IF;

    -- The exact text of the statement as pg_stat_statements stores it.
    SELECT w.query
      INTO v_raw
      FROM sta.workload_statement w
     WHERE w.normalized_query = p_sql
     ORDER BY w.id DESC
     LIMIT 1;

    IF v_raw IS NULL THEN
        -- The same statement, found through its query id.
        BEGIN
            SELECT w.query
              INTO v_raw
              FROM sta.workload_statement w
             WHERE w.queryid = sta.queryid(p_sql)
             ORDER BY w.id DESC
             LIMIT 1;
        EXCEPTION WHEN others THEN
            v_raw := NULL;
        END;
    END IF;

    RETURN COALESCE(v_raw, p_sql);
END
$$;

COMMENT ON FUNCTION sta._raw_statement(text) IS
  'The text of a statement as it was written, when the workload registered it.';

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
        WHEN 'rewrite' THEN ARRAY[
            'Save the original statement and run EXPLAIN (ANALYZE, BUFFERS) on it.',
            'Run the rewritten statement with the same parameters and compare the result sets row by row.',
            'Compare the plan shape and the buffer counts of both statements.',
            'Check that the assumptions the finding lists hold (NULL values, case of the stored text, unique sort key).',
            'Measure the statement again in the application before the rewrite is kept.']
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
        COALESCE(
            (SELECT w.query
               FROM sta.workload_statement w
              WHERE w.normalized_query = m.query
              ORDER BY w.id DESC
              LIMIT 1),
            (SELECT w.query
               FROM sta.workload_statement w
              WHERE w.queryid = m.queryid
              ORDER BY w.id DESC
              LIMIT 1),
            m.query),
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

/*
 * The statements that the plan, rewrite and index advisors run against.
 *
 * Only the statements that read data are of interest here: a statement
 * that loads rows cannot be improved with an index on the relation it
 * writes to, and it has no rewritten form either.  A statement is also
 * only worth analysing when it reads a relation that exists, because the
 * advisors work from the plan of the statement.
 */
CREATE FUNCTION sta._workload_targets(p_window text DEFAULT 'window',
                                      p_limit  integer DEFAULT 25)
RETURNS TABLE (
    sql             text,
    queryid         bigint,
    calls           bigint,
    total_exec_time double precision
)
LANGUAGE sql
STABLE
AS $$
    SELECT d.query::text, d.queryid, d.calls, d.total_exec_time
    FROM sta._workload_delta(p_window) d
    WHERE d.query IS NOT NULL
      AND d.queryid IS NOT NULL
      AND d.query ~* '^\s*(select|with|table|values)\s'
      AND EXISTS (
            SELECT 1
              FROM unnest(sta._sql_relations(d.query)) r
             WHERE to_regclass(r) IS NOT NULL)
    ORDER BY d.total_exec_time DESC, d.calls DESC
    LIMIT LEAST(GREATEST(p_limit, 1), 50)
$$;

COMMENT ON FUNCTION sta._workload_targets(text, integer) IS
  'The read-only statements of the workload that the statement advisors analyse.';

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
-- EXPLAIN that never raises
--
-- sta.explain() refuses anything that is not a plain SELECT.  That is the
-- right behaviour for an explicit request, but the advisors also run over
-- a whole pg_stat_statements workload, which contains INSERT, UPDATE,
-- CREATE and utility statements as well.  _explain_safe() turns those
-- "cannot be explained" cases into a NULL plan so that one unsupported
-- statement does not abort the whole report.
------------------------------------------------------------------------------
CREATE FUNCTION sta._explain_safe(p_sql text, p_analyze boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN sta.explain(p_sql, p_analyze);
EXCEPTION WHEN others THEN
    RETURN NULL;
END
$$;

COMMENT ON FUNCTION sta._explain_safe(text, boolean) IS
  'EXPLAIN (FORMAT JSON) of a statement, or NULL when the statement cannot be '
  'explained (not a SELECT, a syntax error, a missing relation).';

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
    v_plan := sta._explain_safe(p_sql, p_analyze);
    IF v_plan IS NULL THEN
        RETURN;
    END IF;

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
        SELECT 'NEVER_VACUUMED',
               'LOW', 'HIGH', 25,
               (t.schema || '.' || t.relname),
               format('The relation has never been vacuumed, so its visibility map is empty and an '
                      'index-only scan still has to read the heap'),
               jsonb_build_object(
                   'relation',        t.schema || '.' || t.relname,
                   'reltuples',       t.reltuples,
                   'n_live_tup',      t.n_live_tup,
                   'total_bytes',     t.total_bytes,
                   'last_vacuum',     t.last_vacuum,
                   'last_autovacuum', t.last_autovacuum),
               'Run VACUUM (ANALYZE) on the relation.',
               'A vacuum fills the visibility map, so an index-only scan can return the rows without '
                 'reading the heap, and it records the free space that the load left behind.',
               'VACUUM uses I/O and CPU; a VACUUM FULL would lock the table but is not required here.',
               'vacuum'::text
        FROM tables t
        WHERE t.est_rows > 0
          AND t.last_vacuum IS NULL
          AND t.last_autovacuum IS NULL
          AND t.n_dead_tup > 0

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
    v_plan := sta._explain_safe(p_sql, false);
    IF v_plan IS NULL THEN
        RETURN;
    END IF;

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
               -- The function that is applied to the column in the filter, if
               -- there is one.  A column that is compared inside lower() or
               -- upper() needs an index on the expression, not on the column.
               -- The argument of the call is taken out of the filter first,
               -- because the filter of the plan carries the casts and the
               -- qualification of the column
               -- ("lower((orders.customer_name)::text)").
               CASE
                   WHEN lower(coalesce(substring(rs.node->>'Filter' from
                        '\ylower\s*\(([^()]*(\([^()]*\))?[^()]*)\)'), ''))
                        ~ ('\y' || regexp_replace(a.attname, '[^A-Za-z0-9_]', '', 'g') || '\y')
                   THEN 'lower'
                   WHEN lower(coalesce(substring(rs.node->>'Filter' from
                        '\yupper\s*\(([^()]*(\([^()]*\))?[^()]*)\)'), ''))
                        ~ ('\y' || regexp_replace(a.attname, '[^A-Za-z0-9_]', '', 'g') || '\y')
                   THEN 'upper'
                   ELSE NULL
               END AS expr_func,
               (rs.node->>'Filter' ~ ('\y' || a.attname || '\y[^=<>!]*=')) AS plain_equality,
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
        SELECT c.*,
               (c.plain_equality OR c.expr_func IS NOT NULL) AS has_equality
        FROM cols c
        WHERE NOT EXISTS (
            SELECT 1
            FROM pg_index i
            CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
            WHERE i.indrelid = c.oid
              AND k.ord = 1
              AND k.attnum = c.colid
        )
          AND NOT EXISTS (
                SELECT 1
                FROM pg_index i
                WHERE i.indrelid = c.oid
                  AND c.expr_func IS NOT NULL
                  AND pg_get_indexdef(i.indexrelid) ~ ('\y' || c.expr_func || '\s*\(\s*'
                       || regexp_replace(c.colname, '[^A-Za-z0-9_]', '', 'g') || '\s*\)')
          )
    ),
    singles AS (
        SELECT DISTINCT ON (u.oid, u.colname)
               u.oid, u.schema, u.relname, u.reltuples, u.est_rows, u.total_bytes, u.node,
               u.colname, u.has_equality, u.expr_func
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
               array_agg(u.colname::text ORDER BY u.filter_pos NULLS LAST, u.colname::text) AS cols,
               array_agg(CASE WHEN u.expr_func IS NOT NULL
                              THEN format('%s(%s)', u.expr_func, u.colname)
                              ELSE u.colname::text END
                         ORDER BY u.filter_pos NULLS LAST, u.colname::text) AS exprs
        FROM usable u
        WHERE u.has_equality
        GROUP BY u.oid, u.schema, u.relname, u.reltuples, u.est_rows, u.total_bytes, u.node
        HAVING count(*) >= 2
    ),
    proposals AS (
        SELECT s.schema || '.' || s.relname AS relation,
               CASE WHEN s.expr_func IS NOT NULL
                    THEN ARRAY[format('%s(%s)', s.expr_func, s.colname)]
                    ELSE ARRAY[s.colname::text] END AS columns,
               format('CREATE INDEX CONCURRENTLY %s ON %s.%s (%s);',
                      left(lower('idx_' || s.relname || '_'
                                 || CASE WHEN s.expr_func IS NOT NULL
                                         THEN s.colname || '_' || s.expr_func
                                         ELSE s.colname END), 63),
                      s.schema, s.relname,
                      CASE WHEN s.expr_func IS NOT NULL
                           THEN format('%s(%s)', s.expr_func, s.colname)
                           ELSE s.colname END) AS suggested_ddl,
               CASE WHEN s.expr_func IS NOT NULL
                    THEN format('The plan scans %s sequentially with the filter %s; the predicate applies '
                                '%s() to %s, so only an index on the expression %s(%s) can serve it',
                                s.relname, COALESCE(s.node->>'Filter', '<none>'),
                                s.expr_func, s.colname, s.expr_func, s.colname)
                    ELSE format('The plan scans %s sequentially with the filter %s; the column %s is a real column '
                                'of the relation and is not the leading column of any existing index',
                                s.relname, COALESCE(s.node->>'Filter', '<none>'), s.colname)
               END AS rationale,
               CASE WHEN s.expr_func IS NOT NULL
                    THEN format('The scan currently reads about %s rows and returns about %s; an index on '
                                '(%s(%s)) is expected to read only the matching rows',
                                s.est_rows, COALESCE(s.node->>'Plan Rows', 'unknown'),
                                s.expr_func, s.colname)
                    ELSE format('The scan currently reads about %s rows and returns about %s; an index on (%s) '
                                'is expected to read only the matching rows',
                                s.est_rows, COALESCE(s.node->>'Plan Rows', 'unknown'), s.colname)
               END AS estimated_benefit,
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
                      c.schema, c.relname, array_to_string(c.exprs, ', ')),
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
-- SQL formatting
--
-- The rewritten statements have to be complete and readable, because they
-- are meant to be pasted into a terminal.  The formatter only inserts line
-- breaks and spaces between the tokens of a statement: every string
-- literal, quoted identifier and dollar quoted string is copied verbatim, so
-- the result parses exactly like the input.
------------------------------------------------------------------------------
CREATE FUNCTION sta._format_sql(p_sql text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_tokens   text[]    := ARRAY[]::text[];
    v_depths   integer[] := ARRAY[]::integer[];
    v_depth    integer   := 0;
    v_i        integer;
    v_len      integer;
    v_ch       text;
    v_word     text;
    v_tag      text;
    v_end      integer;
    v_body     integer;
    v_out      text      := '';
    v_line     text      := '';
    v_kw       text;
    v_n        integer;
    v_j        integer;
    v_tok      text;
    v_consumed integer;
    v_prev     text;
    v_prev_tok text;
    v_keywords constant text[] := ARRAY[
        'all','and','any','as','asc','between','by','case','distinct','else',
        'end','except','exists','for','from','group','having','in','intersect',
        'into','is','like','limit','not','null','offset','on','or','order',
        'returning','select','set','some','then','union','using','values',
        'when','where','with'
    ];
    v_breaks constant text[] := ARRAY[
        'select','from','where','group by','having','order by','limit','offset',
        'union','union all','intersect','except','join','left join',
        'right join','full join','inner join','cross join','outer join',
        'natural join','returning','values','set'
    ];
BEGIN
    IF p_sql IS NULL OR btrim(p_sql) = '' THEN
        RETURN p_sql;
    END IF;

    ------------------------------------------------------------------
    -- 1. Split the statement into tokens.
    ------------------------------------------------------------------
    v_len := length(p_sql);
    v_i := 1;
    WHILE v_i <= v_len LOOP
        v_ch := substr(p_sql, v_i, 1);

        IF v_ch ~ '\s' THEN
            v_i := v_i + 1;
            CONTINUE;
        END IF;

        -- A single quoted literal, with the doubled quote escape.
        IF v_ch = '''' THEN
            v_word := v_ch;
            v_i := v_i + 1;
            WHILE v_i <= v_len LOOP
                v_ch := substr(p_sql, v_i, 1);
                v_word := v_word || v_ch;
                v_i := v_i + 1;
                IF v_ch = '''' THEN
                    IF v_i <= v_len AND substr(p_sql, v_i, 1) = '''' THEN
                        v_word := v_word || '''';
                        v_i := v_i + 1;
                    ELSE
                        EXIT;
                    END IF;
                END IF;
            END LOOP;
            v_tokens := array_append(v_tokens, v_word);
            v_depths := array_append(v_depths, v_depth);
            CONTINUE;
        END IF;

        -- A quoted identifier.
        IF v_ch = '"' THEN
            v_word := v_ch;
            v_i := v_i + 1;
            WHILE v_i <= v_len LOOP
                v_ch := substr(p_sql, v_i, 1);
                v_word := v_word || v_ch;
                v_i := v_i + 1;
                EXIT WHEN v_ch = '"';
            END LOOP;
            v_tokens := array_append(v_tokens, v_word);
            v_depths := array_append(v_depths, v_depth);
            CONTINUE;
        END IF;

        -- A dollar quoted string.
        IF v_ch = '$' AND substr(p_sql, v_i) ~ '^\$[A-Za-z_0-9]*\$' THEN
            v_tag := regexp_match(substr(p_sql, v_i), '^\$[A-Za-z_0-9]*\$')[1];
            v_body := v_i + length(v_tag);
            v_end := position(v_tag IN substr(p_sql, v_body));
            IF v_end = 0 THEN
                v_word := substr(p_sql, v_i);
                v_i := v_len + 1;
            ELSE
                v_word := substr(p_sql, v_i, (v_body - v_i) + v_end - 1 + length(v_tag));
                v_i := v_body + v_end - 1 + length(v_tag);
            END IF;
            v_tokens := array_append(v_tokens, v_word);
            v_depths := array_append(v_depths, v_depth);
            CONTINUE;
        END IF;

        -- A word.
        IF v_ch ~ '[A-Za-z_0-9$]' THEN
            v_word := '';
            WHILE v_i <= v_len AND substr(p_sql, v_i, 1) ~ '[A-Za-z_0-9$]' LOOP
                v_word := v_word || substr(p_sql, v_i, 1);
                v_i := v_i + 1;
            END LOOP;
            v_tokens := array_append(v_tokens, v_word);
            v_depths := array_append(v_depths, v_depth);
            CONTINUE;
        END IF;

        -- Punctuation.  The operators that consist of two characters are
        -- one token, so that "::", ">=" and "<>" survive the formatting.
        IF substr(p_sql, v_i, 2) IN ('::', '>=', '<=', '<>', '!=', '||', '->>', '->')
           THEN
            v_tokens := array_append(v_tokens, substr(p_sql, v_i, 2));
            v_depths := array_append(v_depths, v_depth);
            v_i := v_i + 2;
            CONTINUE;
        END IF;

        v_tokens := array_append(v_tokens, v_ch);
        v_depths := array_append(v_depths, v_depth);
        IF v_ch = '(' THEN
            v_depth := v_depth + 1;
        ELSIF v_ch = ')' THEN
            v_depth := greatest(v_depth - 1, 0);
        END IF;
        v_i := v_i + 1;
    END LOOP;

    ------------------------------------------------------------------
    -- 2. Put the tokens back together, one clause per line.
    ------------------------------------------------------------------
    v_n := coalesce(array_length(v_tokens, 1), 0);
    v_j := 1;
    WHILE v_j <= v_n LOOP
        v_tok := v_tokens[v_j];
        v_kw := lower(v_tok);
        v_consumed := 1;

        -- Multi word keywords have to be recognised as a whole.
        IF v_kw IN ('group', 'order') AND v_j + 1 <= v_n
           AND lower(v_tokens[v_j + 1]) = 'by' THEN
            v_kw := v_kw || ' by';
            v_consumed := 2;
        ELSIF v_kw = 'union' AND v_j + 1 <= v_n
              AND lower(v_tokens[v_j + 1]) = 'all' THEN
            v_kw := 'union all';
            v_consumed := 2;
        ELSIF v_kw IN ('left', 'right', 'full', 'inner', 'cross', 'natural', 'outer')
              AND v_j + 1 <= v_n THEN
            IF lower(v_tokens[v_j + 1]) = 'join' THEN
                v_kw := v_kw || ' join';
                v_consumed := 2;
            ELSIF lower(v_tokens[v_j + 1]) = 'outer' AND v_j + 2 <= v_n
                  AND lower(v_tokens[v_j + 2]) = 'join' THEN
                v_kw := v_kw || ' outer join';
                v_consumed := 3;
            END IF;
        END IF;

        -- A clause starts on its own line.
        IF v_depths[v_j] = 0 AND v_kw = ANY (v_breaks) THEN
            IF btrim(v_line) <> '' THEN
                v_out := v_out || rtrim(v_line) || E'\n';
            END IF;
            v_line := '';
        END IF;

        -- The separator in front of the token.
        IF btrim(v_line) <> '' THEN
            v_prev := lower(right(rtrim(v_line), 1));
            -- The token in front of this one decides whether a parenthesis
            -- starts a sub-expression (NOT EXISTS (...)) or is the argument
            -- list of a function (count(*)).
            v_prev_tok := CASE WHEN v_j > 1
                                THEN lower(v_tokens[v_j - 1])
                                ELSE '' END;
            IF v_tok IN (',', ')', ';', '.') THEN
                NULL;   -- no space in front of these
            ELSIF v_prev = '(' OR v_prev = '.' THEN
                NULL;   -- no space after an opening parenthesis or a dot
            -- A parenthesis that follows a keyword starts a sub-expression
            -- ("IN (...)", "EXISTS (...)"); a parenthesis that follows a
            -- name is the argument list of a function ("count(*)").
            -- "<> ALL" is the test for "is not one of": the value has to
            -- differ from every element of the list.
            ELSIF v_tok = '(' AND v_prev_tok <> ALL (v_keywords) THEN
                NULL;   -- a function call: count(*)
            ELSE
                v_line := v_line || ' ';
            END IF;
        END IF;

        IF v_consumed = 1 THEN
            v_line := v_line || v_tok;
        ELSIF v_consumed = 2 THEN
            v_line := v_line || v_tok || ' ' || v_tokens[v_j + 1];
        ELSE
            v_line := v_line || v_tok || ' ' || v_tokens[v_j + 1]
                      || ' ' || v_tokens[v_j + 2];
        END IF;

        -- A column list reads better one column per line.
        IF v_tok = ',' AND v_depths[v_j] = 0 THEN
            v_out := v_out || rtrim(v_line) || E'\n';
            v_line := '       ';
        END IF;

        v_j := v_j + v_consumed;
    END LOOP;

    v_out := v_out || rtrim(v_line);
    RETURN v_out;
END
$$;

COMMENT ON FUNCTION sta._format_sql(text) IS
  'Lay a SQL statement out with one clause per line, without changing its meaning.';

------------------------------------------------------------------------------
-- SQL rewrite advice
--
-- The rewrite advisor reads the text of a statement and reports the places
-- where the same answer can be produced in a way that the planner can use
-- better: a star projection, a disjunction that could be an IN list, a
-- function on the filtered column, a cast on the wrong side of the
-- comparison, a leading wildcard, a NOT IN with a subquery, a UNION that
-- removes duplicates, and an OFFSET that walks the whole result set.
--
-- The advisor never applies a rewrite and it never changes the meaning of
-- a statement silently.  Every rule states the assumption the rewrite
-- depends on, and the rules whose rewrite is not semantically identical
-- say so in the finding text.
--
-- The rewritten statement is always returned next to the original one, so
-- that the two can be compared before anything is changed.
------------------------------------------------------------------------------

-- The relations a statement reads from.
CREATE FUNCTION sta._sql_relations(p_sql text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
    SELECT COALESCE(array_agg(DISTINCT m[1]), ARRAY[]::text[])
    FROM regexp_matches(p_sql,
                        '\m(?:from|join)\s+([A-Za-z_][A-Za-z0-9_$]*(?:\.[A-Za-z_][A-Za-z0-9_$]*)?)',
                        'gi') AS m
$$;

COMMENT ON FUNCTION sta._sql_relations(text) IS
  'The relations named after FROM and JOIN in a piece of SQL text.';

-- The relations of the outermost query of a piece of SQL text.  The
-- relations of a subquery are at a parenthesis depth greater than zero and
-- are therefore not returned.  The helper is used to decide whether a
-- SELECT * can be expanded: when the outer query names exactly one
-- relation, the star can only refer to that relation.
CREATE FUNCTION sta._sql_outer_relations(p_sql text)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $$
DECLARE
    v_i      integer;
    v_ch     text;
    v_depth  integer := 0;
    v_in_str boolean := false;
    v_match  text[];
    v_out    text[] := ARRAY[]::text[];
BEGIN
    FOR v_i IN 1..length(p_sql) LOOP
        v_ch := substr(p_sql, v_i, 1);

        IF v_in_str THEN
            IF v_ch = '''' THEN
                -- A doubled quote is an escaped quote, not the end of the
                -- literal.
                IF substr(p_sql, v_i + 1, 1) = '''' THEN
                    v_i := v_i + 1;
                ELSE
                    v_in_str := false;
                END IF;
            END IF;
            CONTINUE;
        END IF;

        IF v_ch = '''' THEN
            v_in_str := true;
        ELSIF v_ch = '(' THEN
            v_depth := v_depth + 1;
        ELSIF v_ch = ')' THEN
            v_depth := v_depth - 1;
        ELSIF v_depth = 0 THEN
            v_match := regexp_match(substr(p_sql, v_i),
                '^\s*(?:from|join)\s+([A-Za-z_][A-Za-z0-9_$]*(?:\.[A-Za-z_][A-Za-z0-9_$]*)?)',
                'i');
            IF v_match IS NOT NULL THEN
                v_out := array_append(v_out, v_match[1]);
            END IF;
        END IF;
    END LOOP;

    RETURN COALESCE(ARRAY(SELECT DISTINCT unnest(v_out)), ARRAY[]::text[]);
END
$$;

COMMENT ON FUNCTION sta._sql_outer_relations(text) IS
  'The relations of the outermost query of a piece of SQL text.';

-- The name of a relation without its schema.
CREATE FUNCTION sta._sql_relname(p_rel text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE WHEN position('.' IN p_rel) > 0
                THEN split_part(p_rel, '.', 2)
                ELSE p_rel END
$$;

COMMENT ON FUNCTION sta._sql_relname(text) IS
  'The name of a relation without the schema it was qualified with.';

-- The alias of a relation, when the text that follows the relation name
-- starts with one.
CREATE FUNCTION sta._sql_first_word_alias(p_rest text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
             WHEN m[1] IS NULL THEN NULL
             WHEN lower(m[1]) = ANY (ARRAY[
                    'where','group','order','having','limit','offset','join','inner',
                    'left','right','full','cross','on','union','except','intersect',
                    'returning','set','values','and','or','not','is','in','like',
                    'between','from','select','as','fetch','for','window','natural',
                    'lateral','using','with','table','when','then','else','end'])
             THEN NULL
             ELSE m[1]
           END
      FROM regexp_matches(p_rest, '^\s*([A-Za-z_][A-Za-z0-9_$]*)', 'i') AS m
     LIMIT 1
$$;

COMMENT ON FUNCTION sta._sql_first_word_alias(text) IS
  'The alias that follows a relation name, or NULL when the next word is a keyword.';

-- The first relation of a statement, with the alias it is used under.
CREATE FUNCTION sta._sql_first_from(p_sql text)
RETURNS TABLE (relation text, alias text)
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT m[1],
           CASE WHEN m[2] IS NULL
                     OR lower(m[2]) = ANY (ARRAY[
                            'where','group','order','having','limit','offset','join','inner',
                            'left','right','full','cross','on','union','except','intersect',
                            'returning','set','values','and','or','not','is','in','like',
                            'between','from','select','as','fetch','for','window','natural',
                            'lateral','using','with','table','when','then','else','end'])
                THEN NULL
                ELSE m[2]
           END
      FROM regexp_matches(p_sql,
             '\mfrom\s+([A-Za-z_][A-Za-z0-9_$]*(?:\.[A-Za-z_][A-Za-z0-9_$]*)?)'
             '(?:\s+(?:as\s+)?([A-Za-z_][A-Za-z0-9_$]*))?',
             'gi') AS m
     LIMIT 1
$$;

COMMENT ON FUNCTION sta._sql_first_from(text) IS
  'The first relation of a statement and the alias it is used under.';

-- The OID of a relation, as it is named in a statement.
--
-- to_regclass() resolves the name with the search path of the session, and
-- it is what a statement really means.  A statement that names a relation
-- that is not in the search path -- a table of another schema that the
-- caller qualifies, or a table of a schema that the session does not
-- include -- is still worth analysing, so the function falls back to a
-- relation of the same name in any other schema.
CREATE FUNCTION sta._sql_relid(p_rel text)
RETURNS oid
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        CASE WHEN p_rel ~ '^[A-Za-z_][A-Za-z0-9_$]*(\.[A-Za-z_][A-Za-z0-9_$]*)?$'
             THEN pg_catalog.to_regclass(p_rel)::oid
        END,
        (SELECT c.oid
           FROM pg_class c
           JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE c.relname = CASE WHEN position('.' IN p_rel) > 0
                                 THEN split_part(p_rel, '.', 2) ELSE p_rel END
            AND n.nspname = ANY (current_schemas(false))
          ORDER BY n.nspname
          LIMIT 1),
        (SELECT c.oid
           FROM pg_class c
           JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE c.relname = CASE WHEN position('.' IN p_rel) > 0
                                 THEN split_part(p_rel, '.', 2) ELSE p_rel END
            AND n.nspname NOT IN ('pg_catalog', 'information_schema')
            AND n.nspname NOT LIKE 'pg_toast%'
          ORDER BY n.nspname
          LIMIT 1))
$$;

COMMENT ON FUNCTION sta._sql_relid(text) IS
  'The OID of the relation a statement names, or NULL when there is none.';

-- The columns of a relation, in attribute order.
CREATE FUNCTION sta._sql_relation_columns(p_rel text)
RETURNS text[]
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(array_agg(a.attname ORDER BY a.attnum), ARRAY[]::text[])
      FROM pg_attribute a
     WHERE a.attrelid = sta._sql_relid(p_rel)
       AND a.attnum > 0
       AND NOT a.attisdropped
$$;

COMMENT ON FUNCTION sta._sql_relation_columns(text) IS
  'The column names of a relation, in attribute order.';

-- The type of a column of a relation, as PostgreSQL spells it.
CREATE FUNCTION sta._sql_column_type(p_rel text, p_col text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT format_type(a.atttypid, a.atttypmod)
      FROM pg_attribute a
     WHERE a.attrelid = sta._sql_relid(p_rel)
       AND a.attname = p_col
       AND a.attnum > 0
       AND NOT a.attisdropped
     LIMIT 1
$$;

COMMENT ON FUNCTION sta._sql_column_type(text, text) IS
  'The type of a column of a relation, as PostgreSQL spells it.';

-- The DDL of an index on a relation.
CREATE FUNCTION sta._sql_index_ddl(p_schema text, p_relname text, p_columns text, p_suffix text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT format('CREATE INDEX CONCURRENTLY %s ON %s.%s (%s);',
                  left(lower('idx_' || p_relname || '_' || p_suffix), 63),
                  p_schema, p_relname, p_columns)
$$;

COMMENT ON FUNCTION sta._sql_index_ddl(text, text, text, text) IS
  'The CREATE INDEX statement for a relation, with a name that fits into 63 characters.';

-- Whether every stored value of a column already has the case that lower()
-- or upper() would produce.  The answer decides whether a predicate of the
-- form lower(col) = 'x' may be rewritten as col = 'x'.
CREATE FUNCTION sta._sql_values_are_normalized(p_rel text, p_col text, p_func text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_schema text;
    v_name   text;
    v_rows   bigint;
    v_ok     boolean;
BEGIN
    IF p_rel IS NULL OR p_col IS NULL OR p_func NOT IN ('lower', 'upper') THEN
        RETURN NULL;
    END IF;

    SELECT n.nspname, c.relname, c.reltuples::bigint
      INTO v_schema, v_name, v_rows
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relname = CASE WHEN position('.' IN p_rel) > 0
                            THEN split_part(p_rel, '.', 2)
                            ELSE p_rel END
       AND (position('.' IN p_rel) = 0 OR n.nspname = split_part(p_rel, '.', 1))
       AND (position('.' IN p_rel) > 0 OR n.nspname = ANY (current_schemas(false)))
       AND c.relkind IN ('r', 'm', 'p')
     LIMIT 1;

    IF v_name IS NULL THEN
        RETURN NULL;
    END IF;

    -- The check reads the whole relation, so it is only made when the
    -- relation is small enough for the scan to be quick.  A relation that
    -- is too large is reported as "not known", and the safe advice is used.
    IF v_rows > 10000000 THEN
        RETURN NULL;
    END IF;

    EXECUTE format('SELECT NOT EXISTS (SELECT 1 FROM %I.%I WHERE %I <> %s(%I) LIMIT 1)',
                   v_schema, v_name, p_col, p_func, p_col)
       INTO v_ok;
    RETURN v_ok;
EXCEPTION WHEN others THEN
    RETURN NULL;
END
$$;

COMMENT ON FUNCTION sta._sql_values_are_normalized(text, text, text) IS
  'Whether every value of a column is already in the case lower() or upper() produces, '
  'or NULL when that cannot be determined cheaply.';

CREATE FUNCTION sta.rewrite_advice(p_sql text)
RETURNS TABLE (
    finding_id       integer,
    category         text,
    severity         text,
    confidence       text,
    impact_score     integer,
    object_name      text,
    pattern          text,
    original_sql     text,
    rewritten_sql    text,
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
    v_sql      text := sta._raw_statement(p_sql);
    v_orig     text;
    v_plan     jsonb;
    v_nodes    jsonb := '[]'::jsonb;
    v_rels     text[];
    v_all_cols text[];
    v_rel      text;
    v_alias    text;
    v_outer    text[];
    v_cols     text[];
    v_m        text[];
    v_new      text;
    v_col      text;
    v_col2     text;
    v_lit      text;
    v_type     text;
    v_qual     text;
    v_outer_qual text;
    v_qual2    text;
    v_outer_ref text;
    v_inner_ref text;
    v_inner_rest text;
    v_inner_tail text;
    v_wpos     integer;
    v_func    text;
    v_schema  text;
    v_relname text;
    v_ddl     text;
    v_safe    boolean;
    v_r       text;
    v_findings jsonb := '[]'::jsonb;
    v_n_union  integer;
    v_n_all    integer;
    v_key      text;
    v_key_dir  text;
    v_base     text;
    v_limit    integer;
    v_offset   integer;
    v_cut      integer;
    v_pos      integer;
    v_where    integer;
    v_cond     text;
    v_trgm     boolean;
BEGIN
    IF p_sql IS NULL OR btrim(p_sql) = '' THEN
        RETURN;
    END IF;

    v_orig := sta._format_sql(v_sql);

    -- The plan is evidence, not a requirement: the rewrite rules work on
    -- the text of the statement, and a statement that cannot be planned
    -- (a relation that does not exist, a syntax error) still deserves a
    -- rewrite.
    BEGIN
        v_plan := sta.explain(p_sql, false);
        SELECT COALESCE(jsonb_agg(DISTINCT n.node->>'Node Type'), '[]'::jsonb)
          INTO v_nodes
          FROM sta._plan_nodes(v_plan) n;
    EXCEPTION WHEN others THEN
        v_plan := NULL;
    END;

    v_rels := sta._sql_relations(v_sql);

    SELECT COALESCE(array_agg(DISTINCT c), ARRAY[]::text[])
      INTO v_all_cols
      FROM unnest(v_rels) r,
           LATERAL unnest(sta._sql_relation_columns(r)) c;

    ------------------------------------------------------------------
    -- 1. SELECT *
    ------------------------------------------------------------------
    IF v_sql ~* '\yselect\s+\*' THEN
        v_outer := sta._sql_outer_relations(v_sql);
        IF array_length(v_outer, 1) = 1 THEN
            v_cols := sta._sql_relation_columns(v_outer[1]);
        END IF;
        IF array_length(v_cols, 1) IS NOT NULL THEN
            v_new := regexp_replace(v_sql, '(\yselect\s+)\*',
                                    '\1' || array_to_string(v_cols, ', '), 'i');
            IF v_new IS DISTINCT FROM v_sql THEN
                v_findings := v_findings || jsonb_build_array(jsonb_build_object(
                    'category', 'rewrite',
                    'severity', 'MEDIUM',
                    'confidence', 'HIGH',
                    'impact_score', 50,
                    'object_name', v_outer[1],
                    'pattern', 'SELECT_STAR',
                    'original_sql', v_orig,
                    'rewritten_sql', sta._format_sql(v_new),
                    'finding', 'SELECT_STAR',
                    'finding_text', format(
                        'The statement reads every column of %s, including the columns it does not use. '
                        'The relation has %s columns, so every row is widened on the way out of the server.',
                        v_outer[1], array_length(v_cols, 1)),
                    'evidence', jsonb_build_object(
                        'relation', v_outer[1],
                        'column_count', array_length(v_cols, 1),
                        'columns', to_jsonb(v_cols),
                        'plan_nodes', v_nodes),
                    'recommendation', format(
                        'Name the columns the statement actually uses: %s',
                        left(array_to_string(v_cols, ', '), 300)),
                    'expected_benefit', 'Fewer bytes are read and transferred for every row, and the '
                        'relation may become covered by an index that holds only the selected columns.',
                    'estimated_cost', 'The statement gets longer and has to be kept in step with the '
                        'relation whenever a column is added, dropped or renamed.',
                    'validation_steps', to_jsonb(sta.validation_steps('rewrite'))));
            END IF;
        END IF;
    END IF;

    ------------------------------------------------------------------
    -- 2. x = a OR x = b  ->  x IN (a, b)
    ------------------------------------------------------------------
    FOR v_m IN
        SELECT m FROM regexp_matches(v_sql,
             '\y([A-Za-z_][A-Za-z0-9_$]*)\s*=\s*(''[^'']*''|[-+]?[0-9]*\.?[0-9]+)'
             '\s+or\s+\1\s*=\s*(''[^'']*''|[-+]?[0-9]*\.?[0-9]+)', 'gi') AS m
    LOOP
        v_col := v_m[1];
        CONTINUE WHEN v_all_cols IS NOT NULL AND NOT (v_col = ANY (v_all_cols));
        v_new := regexp_replace(v_sql,
             '\y([A-Za-z_][A-Za-z0-9_$]*)\s*=\s*(''[^'']*''|[-+]?[0-9]*\.?[0-9]+)'
             '\s+or\s+\1\s*=\s*(''[^'']*''|[-+]?[0-9]*\.?[0-9]+)',
             '\1 IN (\2, \3)', 'gi');
        IF v_new IS DISTINCT FROM v_sql THEN
            v_findings := v_findings || jsonb_build_array(jsonb_build_object(
                'category', 'rewrite',
                'severity', 'MEDIUM',
                'confidence', 'HIGH',
                'impact_score', 50,
                'object_name', v_col,
                'pattern', 'OR_TO_IN',
                'original_sql', v_orig,
                'rewritten_sql', sta._format_sql(v_new),
                'finding', 'OR_TO_IN',
                'finding_text', format(
                    'The statement tests %s twice with an OR.  Two equality tests on the same column are '
                    'rewritten by the planner into a single index lookup, while a disjunction usually '
                    'becomes a bitmap scan or a filter that has to read the whole relation.', v_col),
                'evidence', jsonb_build_object(
                    'column', v_col,
                    'matched', v_m[1] || ' = ' || v_m[2] || ' OR ' || v_col || ' = ' || v_m[3],
                    'plan_nodes', v_nodes),
                'recommendation', format('Replace the disjunction with an IN list on %s.', v_col),
                'expected_benefit', format(
                    'The planner can use one index lookup on %s instead of a filter over the whole relation.',
                    v_col),
                'estimated_cost', format(
                    'None: the rewrite returns exactly the same rows, including the rows where %s is NULL.',
                    v_col),
                'validation_steps', to_jsonb(sta.validation_steps('rewrite'))));
            EXIT;   -- one report per statement is enough
        END IF;
    END LOOP;

    ------------------------------------------------------------------
    -- 3. x NOT IN (SELECT ...)  ->  NOT EXISTS (...)
    ------------------------------------------------------------------
    SELECT relation, alias INTO v_rel, v_alias FROM sta._sql_first_from(v_sql);
    IF v_rel IS NOT NULL THEN
        v_qual := COALESCE(v_alias, sta._sql_relname(v_rel));
        FOR v_m IN
            SELECT m FROM regexp_matches(v_sql,
                 '\y((?:[A-Za-z_][A-Za-z0-9_$]*\.)?)([A-Za-z_][A-Za-z0-9_$]*)\s+not\s+in\s*\(\s*select\s+((?:[A-Za-z_][A-Za-z0-9_$]*\.)?)([A-Za-z_][A-Za-z0-9_$]*)'
                 '\s+from\s+([A-Za-z_][A-Za-z0-9_$]*(?:\.[A-Za-z_][A-Za-z0-9_$]*)?)\s*([^)]*)\)', 'gi') AS m
        LOOP
            v_col  := v_m[2];
            v_col2 := v_m[4];

            -- The outer column keeps the qualifier the statement uses.  When
            -- it has none, the alias of the outer relation is used, and when
            -- the column does not belong to that relation it stays bare.
            IF v_m[1] <> '' THEN
                v_outer_qual := left(v_m[1], length(v_m[1]) - 1);
            ELSE
                v_outer_qual := COALESCE(v_alias, sta._sql_relname(v_rel));
            END IF;
            IF v_outer_qual IS NOT NULL
               AND v_col = ANY (sta._sql_relation_columns(v_rel)) THEN
                v_outer_ref := v_outer_qual || '.' || v_col;
            ELSE
                v_outer_ref := v_col;
            END IF;

            -- The inner column is qualified with the qualifier of the
            -- subquery when it has one, with the alias of the inner relation
            -- when the subquery gives it one, and with the name of the inner
            -- relation otherwise.
            v_qual2 := COALESCE(NULLIF(left(v_m[3], length(v_m[3]) - 1), ''),
                                 sta._sql_first_word_alias(v_m[6]),
                                 sta._sql_relname(v_m[5]));
            v_inner_ref := v_qual2 || '.' || v_col2;

            -- The rest of the subquery: its alias, its WHERE clause and
            -- everything that follows it.
            v_inner_rest := btrim(v_m[6]);

            -- A subquery that has a GROUP BY, an ORDER BY, a LIMIT or an
            -- OFFSET of its own does not return the same rows when it is
            -- correlated, so the rule leaves such a statement alone.
            CONTINUE WHEN v_inner_rest ~* '\m(group\s+by|order\s+by|limit|offset)\b';

            -- The pattern stops at the first closing parenthesis, so a rest
            -- that still holds an opening parenthesis means that the
            -- subquery was cut in the middle.  The rewrite would not be
            -- valid SQL, so the statement is left alone.
            CONTINUE WHEN position('(' IN v_inner_rest) > 0;

            -- The correlated condition goes at the end of the WHERE clause
            -- of the subquery.  A subquery without a WHERE clause gets one.
            IF v_inner_rest = '' THEN
                v_inner_tail := ' WHERE ' || v_inner_ref || ' = ' || v_outer_ref;
            ELSIF strpos(lower(v_inner_rest), 'where') > 0 THEN
                v_inner_tail := ' ' || v_inner_rest || ' AND '
                               || v_inner_ref || ' = ' || v_outer_ref;
            ELSE
                v_inner_tail := ' ' || v_inner_rest || ' WHERE '
                               || v_inner_ref || ' = ' || v_outer_ref;
            END IF;

            v_new := regexp_replace(v_sql,
                 '\y((?:[A-Za-z_][A-Za-z0-9_$]*\.)?)([A-Za-z_][A-Za-z0-9_$]*)\s+not\s+in\s*\(\s*select\s+((?:[A-Za-z_][A-Za-z0-9_$]*\.)?)([A-Za-z_][A-Za-z0-9_$]*)'
                 '\s+from\s+([A-Za-z_][A-Za-z0-9_$]*(?:\.[A-Za-z_][A-Za-z0-9_$]*)?)\s*([^)]*)\)',
                 'NOT EXISTS (SELECT 1 FROM \5' || v_inner_tail || ')', 'i');
            IF v_new IS DISTINCT FROM v_sql THEN
                v_findings := v_findings || jsonb_build_array(jsonb_build_object(
                    'category', 'rewrite',
                    'severity', 'MEDIUM',
                    'confidence', 'MEDIUM',
                    'impact_score', 50,
                    'object_name', v_rel,
                    'pattern', 'NOT_IN_TO_NOT_EXISTS',
                    'original_sql', v_orig,
                    'rewritten_sql', sta._format_sql(v_new),
                    'finding', 'NOT_IN_TO_NOT_EXISTS',
                    'finding_text', format(
                        'The statement uses NOT IN with a subquery.  NOT IN is evaluated as a hashed '
                        'anti-join over the whole subquery, while NOT EXISTS stops at the first matching '
                        'row and can use an index.  The two are not identical: NOT IN returns no rows at '
                        'all when the subquery produces a single NULL, whereas NOT EXISTS does not.  The '
                        'rewrite is therefore offered with the assumption that %s contains no NULL, or that '
                        'the difference does not matter.', v_qual2),
                    'evidence', jsonb_build_object(
                        'outer_column', v_outer_ref,
                        'subquery_column', v_inner_ref,
                        'subquery_relation', v_m[5],
                        'outer_relation', v_rel,
                        'plan_nodes', v_nodes),
                    'recommendation', format(
                        'Rewrite the NOT IN as NOT EXISTS and confirm that %s cannot return NULL.',
                        v_qual2),
                    'expected_benefit', 'The subquery can stop at the first matching row instead of hashing '
                        'the whole result set.',
                    'estimated_cost', 'The NULL semantics change; a query that used to return no rows may '
                        'now return rows.',
                    'validation_steps', to_jsonb(sta.validation_steps('rewrite'))));
                EXIT;
            END IF;
        END LOOP;
    END IF;

    ------------------------------------------------------------------
    -- 4. lower(col) = 'x'  ->  col = 'x'   (only when it is equivalent)
    ------------------------------------------------------------------
    FOR v_m IN
        SELECT m FROM regexp_matches(v_sql,
             '\y(lower|upper)\s*\(\s*([A-Za-z_][A-Za-z0-9_$]*)\s*\)\s*=\s*''([^'']*)''', 'gi') AS m
    LOOP
        v_col  := v_m[2];
        v_func := lower(v_m[1]);

        -- The relation that owns the column.
        v_rel     := NULL;
        v_schema  := NULL;
        v_relname := NULL;
        FOR v_r IN SELECT unnest(v_rels) LOOP
            IF v_col = ANY (sta._sql_relation_columns(v_r)) THEN
                v_rel := v_r;
                EXIT;
            END IF;
        END LOOP;

        IF v_rel IS NOT NULL THEN
            SELECT r.schema, r.relname INTO v_schema, v_relname
              FROM sta._resolve_relation(sta._sql_relname(v_rel)) r;
        END IF;

        -- The expression index is the advice that works in every case.
        IF v_schema IS NOT NULL THEN
            v_ddl := sta._sql_index_ddl(v_schema, v_relname,
                                        format('%s(%s)', v_func, v_col),
                                        v_col || '_' || v_func);
        ELSE
            v_ddl := format('CREATE INDEX CONCURRENTLY idx_<relation>_%s_%s ON <schema>.<relation> (%s(%s));',
                            lower(v_col), v_func, v_func, v_col);
        END IF;

        -- The statement without the function is only equivalent when every
        -- stored value already has the case the function produces.
        v_safe := sta._sql_values_are_normalized(v_rel, v_col, v_func);

        IF v_safe THEN
            v_new := regexp_replace(v_sql,
                 '\y(lower|upper)\s*\(\s*([A-Za-z_][A-Za-z0-9_$]*)\s*\)\s*=\s*''([^'']*)''',
                 '\2 = ' || quote_literal(v_m[3]), 'i');
        ELSE
            v_new := v_sql;
        END IF;

        IF v_new IS DISTINCT FROM v_sql THEN
            v_findings := v_findings || jsonb_build_array(jsonb_build_object(
                'category', 'rewrite',
                'severity', 'HIGH',
                'confidence', 'HIGH',
                'impact_score', 70,
                'object_name', v_col,
                'pattern', 'NON_SARGABLE_PREDICATE',
                'original_sql', v_orig,
                'rewritten_sql', sta._format_sql(v_new),
                'finding', 'NON_SARGABLE_PREDICATE',
                'finding_text', format(
                    'The statement applies %s() to %s before comparing it.  An index on %s cannot be used '
                    'for that, because the index stores the values of the column and not the result of the '
                    'function.  Every stored value of %s was checked and is already %s-case, so the '
                    'function can be dropped from the predicate without changing the result.',
                    v_func, v_col, v_col, v_col, v_func),
                'evidence', jsonb_build_object(
                    'function', v_func,
                    'column', v_col,
                    'literal', v_m[3],
                    'relation', v_rel,
                    'values_already_normalized', v_safe,
                    'suggested_ddl', v_ddl,
                    'plan_nodes', v_nodes),
                'recommendation', format(
                    'Drop the function from the predicate, and build the expression index as well: %s',
                    v_ddl),
                'expected_benefit', format(
                    'The predicate becomes sargable, so the index on %s can be used.', v_col),
                'estimated_cost', 'None: the rewrite returns the same rows, because every stored value '
                    'was checked.  The expression index adds write overhead on the relation.',
                'validation_steps', to_jsonb(sta.validation_steps('rewrite'))));
        ELSE
            v_findings := v_findings || jsonb_build_array(jsonb_build_object(
                'category', 'rewrite',
                'severity', 'HIGH',
                'confidence', 'HIGH',
                'impact_score', 70,
                'object_name', v_col,
                'pattern', 'NON_SARGABLE_PREDICATE',
                'original_sql', v_orig,
                -- There is no rewrite of the predicate that keeps the result
                -- and makes the index usable: the values are not all in the
                -- case the function produces, so the statement is returned
                -- unchanged and the index has to change instead.
                'rewritten_sql', v_orig,
                'finding', 'NON_SARGABLE_PREDICATE',
                'finding_text', format(
                    'The statement applies %s() to %s before comparing it.  An index on %s cannot be used '
                    'for that, because the index stores the values of the column and not the result of the '
                    'function.  The stored values of %s are not all %s-case, so dropping the function from '
                    'the predicate would change the result and no rewrite of the statement is offered.  The '
                    'index has to change instead: an index on the expression %s(%s) serves the predicate '
                    'as it is written.', v_func, v_col, v_col, v_col, v_func, v_func, v_col),
                'evidence', jsonb_build_object(
                    'function', v_func,
                    'column', v_col,
                    'literal', v_m[3],
                    'relation', v_rel,
                    'values_already_normalized', v_safe,
                    'suggested_ddl', v_ddl,
                    'plan_nodes', v_nodes),
                'recommendation', format(
                    'Keep the predicate and build an index on the expression: %s', v_ddl),
                'expected_benefit', format(
                    'The expression index can serve the predicate on %s, so the whole relation does not '
                    'have to be read.', v_col),
                'estimated_cost', 'An expression index is larger than a plain index and slows down writes '
                    'on the relation.',
                'validation_steps', to_jsonb(sta.validation_steps('rewrite'))));
        END IF;
        EXIT;
    END LOOP;

    ------------------------------------------------------------------
    -- 5. date(col) = '2024-01-01'  ->  col >= '2024-01-01' AND col < ...
    ------------------------------------------------------------------
    FOR v_m IN
        SELECT m FROM regexp_matches(v_sql,
             '\ydate\s*\(\s*([A-Za-z_][A-Za-z0-9_$]*)\s*\)\s*=\s*''([0-9]{4}-[0-9]{2}-[0-9]{2})''',
             'gi') AS m
    LOOP
        v_col := v_m[1];
        v_lit := v_m[2];
        v_new := regexp_replace(v_sql,
             '\ydate\s*\(\s*([A-Za-z_][A-Za-z0-9_$]*)\s*\)\s*=\s*''([0-9]{4}-[0-9]{2}-[0-9]{2})''',
             '\1 >= ' || quote_literal(v_lit) || '::date AND \1 < ('
                 || quote_literal(v_lit) || '::date + 1)', 'i');
        IF v_new IS DISTINCT FROM v_sql THEN
            v_findings := v_findings || jsonb_build_array(jsonb_build_object(
                'category', 'rewrite',
                'severity', 'HIGH',
                'confidence', 'HIGH',
                'impact_score', 70,
                'object_name', v_col,
                'pattern', 'NON_SARGABLE_PREDICATE',
                'original_sql', v_orig,
                'rewritten_sql', sta._format_sql(v_new),
                'finding', 'NON_SARGABLE_PREDICATE',
                'finding_text', format(
                    'The statement applies date() to %s before comparing it, so an index on %s cannot be '
                    'used.  The range from %s to the next day is exactly the same set of rows and can use '
                    'the index.', v_col, v_col, v_lit),
                'evidence', jsonb_build_object(
                    'function', 'date',
                    'column', v_col,
                    'literal', v_lit,
                    'plan_nodes', v_nodes),
                'recommendation', format('Compare %s with a half-open range instead of a function call.', v_col),
                'expected_benefit', format(
                    'The predicate becomes sargable, so the index on %s can be used.', v_col),
                'estimated_cost', 'None for a date or timestamp column; the range covers exactly one day.',
                'validation_steps', to_jsonb(sta.validation_steps('rewrite'))));
            EXIT;
        END IF;
    END LOOP;

    ------------------------------------------------------------------
    -- 6. col::text = '123.45'  ->  col = 123.45
    ------------------------------------------------------------------
    FOR v_m IN
        SELECT m FROM regexp_matches(v_sql,
             '\y([A-Za-z_][A-Za-z0-9_$]*)\s*::\s*text\s*=\s*''([^'']*)''', 'gi') AS m
    LOOP
        v_col := v_m[1];
        v_lit := v_m[2];
        v_type := NULL;
        FOR v_rel IN SELECT unnest(v_rels) LOOP
            v_type := sta._sql_column_type(v_rel, v_col);
            EXIT WHEN v_type IS NOT NULL;
        END LOOP;
        CONTINUE WHEN v_type IS NULL;

        -- format_type() spells a numeric column as numeric(10,2); only the
        -- base type decides how the comparison has to be rewritten.
        v_base := split_part(v_type, '(', 1);

        IF v_base IN ('numeric', 'integer', 'bigint', 'smallint', 'real',
                      'double precision', 'money')
           AND v_lit ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
            v_new := regexp_replace(v_sql,
                 '\y([A-Za-z_][A-Za-z0-9_$]*)\s*::\s*text\s*=\s*''([^'']*)''',
                 '\1 = ' || v_lit::numeric::text, 'i');
        ELSIF v_base IN ('text', 'character varying', 'character', 'varchar',
                         'bpchar', 'citext') THEN
            v_new := regexp_replace(v_sql,
                 '\y([A-Za-z_][A-Za-z0-9_$]*)\s*::\s*text\s*=\s*''([^'']*)''',
                 '\1 = ' || quote_literal(v_lit), 'i');
        ELSE
            CONTINUE;
        END IF;

        IF v_new IS DISTINCT FROM v_sql THEN
            v_findings := v_findings || jsonb_build_array(jsonb_build_object(
                'category', 'rewrite',
                'severity', 'HIGH',
                'confidence', 'MEDIUM',
                'impact_score', 70,
                'object_name', v_col,
                'pattern', 'IMPLICIT_CAST',
                'original_sql', v_orig,
                'rewritten_sql', sta._format_sql(v_new),
                'finding', 'IMPLICIT_CAST',
                'finding_text', format(
                    'The statement casts %s to text before comparing it.  The cast is applied to every row '
                    'of the relation and it makes an index on %s unusable, because the index stores the '
                    'numeric values.  The comparison is only equivalent when the text form of the literal '
                    'is the canonical form of the number (123.45 is, 1e2 is not).', v_col, v_col),
                'evidence', jsonb_build_object(
                    'column', v_col,
                    'column_type', v_type,
                    'literal', v_lit,
                    'plan_nodes', v_nodes),
                'recommendation', format('Compare %s with a literal of its own type.', v_col),
                'expected_benefit', format(
                    'The cast disappears from the plan and the index on %s can be used.', v_col),
                'estimated_cost', 'A numeric literal is not always spelled the same way as its text form, '
                    'so the two can select different rows.',
                'validation_steps', to_jsonb(sta.validation_steps('rewrite'))));
            EXIT;
        END IF;
    END LOOP;

    ------------------------------------------------------------------
    -- 7. col LIKE '%x%'
    ------------------------------------------------------------------
    SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') INTO v_trgm;
    FOR v_m IN
        SELECT m FROM regexp_matches(v_sql,
             '\y([A-Za-z_][A-Za-z0-9_$]*)\s+like\s+''(%[^'']*|[^'']*%)''', 'gi') AS m
    LOOP
        v_col := v_m[1];

        -- The relation that owns the column, so that the index can be named
        -- after it and built on the right schema.
        v_rel     := NULL;
        v_schema  := NULL;
        v_relname := NULL;
        FOR v_r IN SELECT unnest(v_rels) LOOP
            IF v_col = ANY (sta._sql_relation_columns(v_r)) THEN
                v_rel := v_r;
                EXIT;
            END IF;
        END LOOP;

        IF v_rel IS NOT NULL THEN
            SELECT r.schema, r.relname INTO v_schema, v_relname
              FROM sta._resolve_relation(sta._sql_relname(v_rel)) r;
        END IF;

        IF v_schema IS NOT NULL THEN
            v_ddl := format('CREATE INDEX CONCURRENTLY %s ON %s.%s USING gin (%s gin_trgm_ops);',
                            left(lower('idx_' || v_relname || '_' || v_col || '_trgm'), 63),
                            v_schema, v_relname, v_col);
        ELSE
            v_ddl := format('CREATE INDEX CONCURRENTLY idx_<relation>_%s_trgm ON <schema>.<relation> USING gin (%s gin_trgm_ops);',
                            lower(v_col), v_col);
        END IF;

        v_findings := v_findings || jsonb_build_array(jsonb_build_object(
            'category', 'rewrite',
            'severity', 'HIGH',
            'confidence', 'HIGH',
            'impact_score', 60,
            'object_name', v_col,
            'pattern', 'LEADING_WILDCARD_LIKE',
            'original_sql', v_orig,
            -- There is no rewrite of the predicate that makes it sargable: a B-tree index cannot serve a
            -- pattern that starts with a wildcard.  The statement is returned unchanged and the fix is
            -- stated in the recommendation.
            'rewritten_sql', v_orig,
            'finding', 'LEADING_WILDCARD_LIKE',
            'finding_text', format(
                'The pattern on %s starts with a wildcard, so a B-tree index on %s cannot be used and the '
                'whole relation has to be read.  No rewrite of the predicate can change that; the index has '
                'to change instead.', v_col, v_col),
            'evidence', jsonb_build_object(
                'column', v_col,
                'relation', v_rel,
                'pattern', CASE WHEN left(v_m[2], 1) = '%'
                                THEN v_m[2] ELSE '%' || v_m[2] END,
                'pg_trgm_available', v_trgm,
                'suggested_ddl', v_ddl,
                'plan_nodes', v_nodes),
            'recommendation', CASE WHEN v_trgm
                THEN format('Create a trigram index: %s', v_ddl)
                ELSE format('Install pg_trgm and create a trigram index: CREATE EXTENSION IF NOT EXISTS pg_trgm; %s', v_ddl)
            END,
            'expected_benefit', 'The trigram index can serve the pattern without reading the whole relation.',
            'estimated_cost', 'A trigram index is large and slows down writes on the relation.',
            'validation_steps', to_jsonb(sta.validation_steps('rewrite'))));
        CONTINUE;
    END LOOP;

    ------------------------------------------------------------------
    -- 8. UNION  ->  UNION ALL
    ------------------------------------------------------------------
    SELECT count(*) INTO v_n_union FROM regexp_matches(v_sql, '\yunion\y', 'gi');
    SELECT count(*) INTO v_n_all   FROM regexp_matches(v_sql, '\yunion\s+all\y', 'gi');
    IF v_n_union > v_n_all THEN
        v_new := regexp_replace(v_sql, '\yunion\y(?!\s+all\y)', 'UNION ALL', 'gi');
        IF v_new IS DISTINCT FROM v_sql THEN
            v_findings := v_findings || jsonb_build_array(jsonb_build_object(
                'category', 'rewrite',
                'severity', 'LOW',
                'confidence', 'MEDIUM',
                'impact_score', 30,
                'object_name', NULL,
                'pattern', 'UNION_TO_UNION_ALL',
                'original_sql', v_orig,
                'rewritten_sql', sta._format_sql(v_new),
                'finding', 'UNION_TO_UNION_ALL',
                'finding_text', 'The statement joins two branches with UNION, so PostgreSQL has to sort or '
                    'hash both branches and remove the duplicates.  UNION ALL skips that work.  The two are '
                    'only equivalent when the branches cannot produce the same row, for example when they '
                    'filter on different values of the same column.',
                'evidence', jsonb_build_object(
                    'union_count', v_n_union,
                    'union_all_count', v_n_all,
                    'plan_nodes', v_nodes),
                'recommendation', 'Use UNION ALL when the branches cannot produce the same row; when they '
                    'can, use SELECT DISTINCT * FROM ( ... ) instead.',
                'expected_benefit', 'The duplicate removal disappears, and so does the sort or hash of the '
                    'combined result.',
                'estimated_cost', 'The result can contain duplicates when the branches overlap.',
                'validation_steps', to_jsonb(sta.validation_steps('rewrite'))));
        END IF;
    END IF;

    ------------------------------------------------------------------
    -- 9. LIMIT n OFFSET m  ->  keyset pagination
    ------------------------------------------------------------------
    SELECT m[1]::integer, m[2]::integer
      INTO v_limit, v_offset
      FROM regexp_matches(v_sql, '\ylimit\s+([0-9]+)\s+offset\s+([0-9]+)', 'gi') AS m
     LIMIT 1;

    IF v_limit IS NULL THEN
        SELECT m[1]::integer, m[2]::integer
          INTO v_limit, v_offset
          FROM regexp_matches(v_sql, '\yoffset\s+([0-9]+)\s+limit\s+([0-9]+)', 'gi') AS m
         LIMIT 1;
    END IF;

    IF v_limit IS NOT NULL AND v_offset > 0 THEN
        SELECT m[1], m[2] INTO v_key, v_key_dir
          FROM regexp_matches(v_sql, '\yorder\s+by\s+([A-Za-z_][A-Za-z0-9_$]*)(?:\s+(asc|desc))?', 'gi') AS m
         LIMIT 1;

        IF v_key IS NOT NULL AND v_rel IS NOT NULL THEN
            v_qual := COALESCE(v_alias, sta._sql_relname(v_rel));
            IF v_qual IS NULL OR v_qual = '' THEN
                v_outer_ref := v_key;
            ELSE
                v_outer_ref := v_qual || '.' || v_key;
            END IF;

            -- The keyset condition asks for the rows after the last row of
            -- the previous page.  The caller supplies that value as the
            -- first parameter, so the server never has to produce and
            -- discard the rows that come before it.
            IF lower(COALESCE(v_key_dir, 'asc')) = 'desc' THEN
                v_cond := format('%s < $1', v_outer_ref);
            ELSE
                v_cond := format('%s > $1', v_outer_ref);
            END IF;

            -- The condition goes in front of the first of GROUP BY, ORDER BY and LIMIT.
            -- The search looks for the clause and the whitespace in front of
            -- it, so that it also finds the clause when the statement is
            -- already laid out on several lines.
            v_cut := length(v_sql) + 1;
            FOREACH v_pos IN ARRAY ARRAY[
                coalesce(regexp_instr(lower(v_sql), '\s+group\s+by\y'), 0),
                coalesce(regexp_instr(lower(v_sql), '\s+order\s+by\y'), 0),
                coalesce(regexp_instr(lower(v_sql), '\s+limit\y'), 0)] LOOP
                IF v_pos > 0 AND v_pos < v_cut THEN
                    v_cut := v_pos;
                END IF;
            END LOOP;

            v_where := coalesce(regexp_instr(lower(v_sql), '\s+where\y'), 0);
            IF v_where > 0 AND v_where < v_cut THEN
                v_new := left(v_sql, v_cut - 1) || ' AND ' || v_cond
                         || substring(v_sql FROM v_cut);
            ELSE
                v_new := left(v_sql, v_cut - 1) || ' WHERE ' || v_cond
                         || substring(v_sql FROM v_cut);
            END IF;

            -- The OFFSET is replaced by the keyset condition.
            v_new := regexp_replace(v_new, '\s+offset\s+[0-9]+', '', 'i');

            IF v_new IS DISTINCT FROM v_sql THEN
                v_findings := v_findings || jsonb_build_array(jsonb_build_object(
                    'category', 'rewrite',
                    'severity', 'MEDIUM',
                    'confidence', 'MEDIUM',
                    'impact_score', 40,
                    'object_name', v_rel,
                    'pattern', 'OFFSET_PAGINATION',
                    'original_sql', v_orig,
                    'rewritten_sql', sta._format_sql(v_new),
                    'finding', 'OFFSET_PAGINATION',
                    'finding_text', format(
                        'The statement skips %s rows with OFFSET.  The server has to produce and discard '
                        'those rows on every page, so the cost of a page grows with its depth.  Keyset '
                        'pagination asks for the rows after the last one of the previous page instead: the '
                        'rewrite replaces the OFFSET with a comparison on %s, and the caller passes the '
                        'sort key of the last row of the previous page as the first parameter.  The rewrite '
                        'assumes that %s sorts the rows in a stable order; if %s is not unique, a row can '
                        'be repeated or skipped at the boundary, and a unique sort key is the safe choice.',
                        v_offset, v_key, v_rel, v_key),
                    'evidence', jsonb_build_object(
                        'limit', v_limit,
                        'offset', v_offset,
                        'order_by_column', v_key,
                        'order_by_direction', COALESCE(v_key_dir, 'asc'),
                        'relation', v_rel,
                        'plan_nodes', v_nodes),
                    'recommendation', format(
                        'Page with a keyset condition on %s, and pass the last value of %s from the '
                        'previous page as the first parameter.', v_key, v_key),
                    'expected_benefit', 'The cost of a page no longer grows with the depth of the page.',
                    'estimated_cost', 'The caller has to keep the sort key of the last row of the page.',
                    'validation_steps', to_jsonb(sta.validation_steps('rewrite'))));
            END IF;
        END IF;
    END IF;

    ------------------------------------------------------------------
    -- The findings
    ------------------------------------------------------------------
    RETURN QUERY
    SELECT (f.n)::integer,
           f.f->>'category',
           f.f->>'severity',
           f.f->>'confidence',
           (f.f->>'impact_score')::integer,
           f.f->>'object_name',
           f.f->>'pattern',
           f.f->>'original_sql',
           f.f->>'rewritten_sql',
           f.f->>'finding',
           f.f->>'finding_text',
           f.f->'evidence',
           f.f->>'recommendation',
           f.f->>'expected_benefit',
           f.f->>'estimated_cost',
           ARRAY(SELECT jsonb_array_elements_text(f.f->'validation_steps'))
      FROM jsonb_array_elements(v_findings) WITH ORDINALITY AS f(f, n);
END
$$;

COMMENT ON FUNCTION sta.rewrite_advice(text) IS
  'Rewrite candidates for a statement: the original text, the rewritten text, and what the rewrite '
  'assumes, gains and costs.';

------------------------------------------------------------------------------
-- The rewritten statement, with every rule applied
--
-- The rules of sta.rewrite_advice() are independent: each one of them
-- produces a candidate on its own.  A statement that breaks more than one
-- rule needs more than one fix, but the caller wants one statement, so
-- this function applies the rules one after the other, always on the
-- result of the previous one, and returns the final statement.
--
-- The order of the rules matters.  A cast or a date function is fixed
-- first, because the other rules match on the text of the predicate.
-- OR and NOT IN are fixed next, then the set operation and the
-- pagination.  The expansion of "SELECT *" comes last, because it changes
-- the shape of the statement and would make the other rules miss.
------------------------------------------------------------------------------
CREATE FUNCTION sta.rewrite_statement(p_sql text)
RETURNS TABLE (
    original_sql  text,
    rewritten_sql text,
    applied       text[],
    changed       boolean
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_cur     text;
    v_next    text;
    v_pattern text;
    v_applied text[] := ARRAY[]::text[];
    v_seen    text[] := ARRAY[]::text[];
    v_orig    text;
    v_round   integer := 0;
BEGIN
    IF p_sql IS NULL OR btrim(p_sql) = '' THEN
        RETURN;
    END IF;

    v_orig := sta._format_sql(sta._raw_statement(p_sql));
    v_cur  := v_orig;

    LOOP
        v_round := v_round + 1;
        EXIT WHEN v_round > 12;   -- a rule that cannot settle down

        -- The rule that comes first in the order and that has not been
        -- applied yet.  A rewrite that lands on a statement that was seen
        -- before is skipped, so that a rule is applied once.
        SELECT rw.rewritten_sql, rw.pattern
          INTO v_next, v_pattern
          FROM sta.rewrite_advice(v_cur) rw
         WHERE rw.rewritten_sql IS DISTINCT FROM rw.original_sql
           AND rw.original_sql = v_cur          -- the rule saw this statement
           AND NOT (rw.rewritten_sql = ANY (v_seen))
         ORDER BY CASE rw.pattern
                    WHEN 'IMPLICIT_CAST'            THEN 1
                    WHEN 'NON_SARGABLE_PREDICATE'   THEN 2
                    WHEN 'OR_TO_IN'                 THEN 3
                    WHEN 'NOT_IN_TO_NOT_EXISTS'     THEN 4
                    WHEN 'UNION_TO_UNION_ALL'       THEN 5
                    WHEN 'OFFSET_PAGINATION'        THEN 6
                    WHEN 'LEADING_WILDCARD_LIKE'    THEN 7
                    WHEN 'SELECT_STAR'              THEN 8
                    ELSE 9
                  END,
                  rw.finding_id
         LIMIT 1;

        EXIT WHEN NOT FOUND;

        v_seen := array_append(v_seen, v_next);
        v_cur  := v_next;

        IF NOT (v_pattern = ANY (v_applied)) THEN
            v_applied := array_append(v_applied, v_pattern);
        END IF;
    END LOOP;

    original_sql  := v_orig;
    rewritten_sql := v_cur;
    applied       := v_applied;
    changed       := v_cur IS DISTINCT FROM v_orig;
    RETURN NEXT;
END
$$;

COMMENT ON FUNCTION sta.rewrite_statement(text) IS
  'The statement as it should be run: every rewrite rule is applied, one after the other, '
  'and the final statement is returned together with the rules that were used.';

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
    IF p_index_ddl ~* '\yCONCURRENTLY\y' THEN
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
    WITH lim AS (
        SELECT LEAST(GREATEST(p_limit, 1), sta._max_findings()) AS n
    ),
    w AS (
        SELECT * FROM sta.workload_advice(p_window, 0, 0, p_limit)
    ),
    s AS (
        SELECT * FROM sta.stats_advice(NULL, p_limit)
    ),
    /*
     * The statements that the plan, rewrite and index advisors run against.
     *
     * With p_sql only that one statement is analysed.  Without p_sql the
     * most expensive statements of the workload window are analysed, so a
     * plain `SELECT * FROM sta.recommendations()` still produces index and
     * rewrite advice for the workload that was actually observed instead of
     * only reporting workload counters and table statistics.
     */
    targets AS (
        SELECT p_sql::text AS sql, NULL::bigint AS queryid
        WHERE p_sql IS NOT NULL
        UNION ALL
        SELECT t.sql, t.queryid
        FROM sta._workload_targets(p_window, LEAST((SELECT n FROM lim), 25)) t
        WHERE p_sql IS NULL
    ),
    p AS (
        SELECT pa.category, pa.severity, pa.confidence, pa.impact_score,
               pa.object_name, t.queryid, t.sql::text AS query, pa.finding, pa.finding_text,
               pa.evidence, pa.recommendation, pa.expected_benefit, pa.estimated_cost,
               pa.validation_steps
        FROM targets t
        CROSS JOIN LATERAL sta.plan_advice(t.sql, p_analyze, 20) pa
    ),
    r AS (
        SELECT rw.category, rw.severity, rw.confidence, rw.impact_score,
               rw.object_name, t.queryid, rw.original_sql::text AS query, rw.finding, rw.finding_text,
               rw.evidence, rw.recommendation, rw.expected_benefit, rw.estimated_cost,
               rw.validation_steps
        FROM targets t
        CROSS JOIN LATERAL sta.rewrite_advice(t.sql) rw
    ),
    ix AS (
        SELECT 'index'::text AS category,
               'HIGH'::text AS severity,
               ia.confidence::text AS confidence,
               75::integer AS impact_score,
               ia.relation::text AS object_name,
               t.queryid,
               t.sql::text AS query,
               'MISSING_INDEX'::text AS finding,
               ia.rationale::text AS finding_text,
               jsonb_build_object('relation', ia.relation,
                                  'columns', to_jsonb(ia.columns),
                                  'suggested_ddl', ia.suggested_ddl) AS evidence,
               ia.suggested_ddl::text AS recommendation,
               ia.estimated_benefit::text AS expected_benefit,
               ia.estimated_cost::text AS estimated_cost,
               ia.validation_steps
        FROM targets t
        CROSS JOIN LATERAL sta.index_advice(t.sql) ia
    ),
    all_findings AS (
        SELECT w.category, w.severity, w.confidence, w.impact_score,
               NULL::text AS object_name, w.queryid, w.query, w.finding, w.finding_text, w.evidence,
               w.recommendation, w.expected_benefit, w.estimated_cost, w.validation_steps
        FROM w
        UNION ALL
        SELECT pl.category, pl.severity, pl.confidence, pl.impact_score,
               pl.object_name, pl.queryid, pl.query, pl.finding, pl.finding_text, pl.evidence,
               pl.recommendation, pl.expected_benefit, pl.estimated_cost, pl.validation_steps
        FROM p pl
        UNION ALL
        SELECT st.category, st.severity, st.confidence, st.impact_score,
               st.object_name, NULL::bigint, NULL::text, st.finding, st.finding_text, st.evidence,
               st.recommendation, st.expected_benefit, st.estimated_cost, st.validation_steps
        FROM s st
        UNION ALL
        SELECT rw.category, rw.severity, rw.confidence, rw.impact_score,
               rw.object_name, rw.queryid, rw.query, rw.finding, rw.finding_text, rw.evidence,
               rw.recommendation, rw.expected_benefit, rw.estimated_cost, rw.validation_steps
        FROM r rw
        UNION ALL
        SELECT i.category, i.severity, i.confidence, i.impact_score,
               i.object_name, i.queryid, i.query, i.finding, i.finding_text, i.evidence,
               i.recommendation, i.expected_benefit, i.estimated_cost, i.validation_steps
        FROM ix i
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
  'All findings from the workload, plan, statistics and rewrite advisors, ranked by impact.';

------------------------------------------------------------------------------
-- Action plan
--
-- The other advisors say what is wrong.  The action plan says what to do
-- about it: it turns every finding into a statement that can be run as it
-- is, together with the reason, the benefit, the cost and the risk.
--
-- The order is not arbitrary.  The statistics come first, because a
-- correct estimate can remove the need for an index.  The index comes
-- next.  The rewritten statement comes last, because it has to be written
-- against the statement that the application really runs.
------------------------------------------------------------------------------
CREATE FUNCTION sta.action_plan(
    p_sql     text    DEFAULT NULL,
    p_window  text    DEFAULT 'window',
    p_analyze boolean DEFAULT false,
    p_limit   integer DEFAULT 50
)
RETURNS TABLE (
    action_id        integer,
    action_type      text,
    priority         integer,
    object_name      text,
    queryid          bigint,
    query            text,
    action_sql       text,
    finding          text,
    finding_text     text,
    severity         text,
    confidence       text,
    rationale        text,
    expected_benefit text,
    estimated_cost   text,
    risk             text,
    validation_steps text[]
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_actions jsonb := '[]'::jsonb;
    r         record;
    t         record;
    v_type    text;
    v_sql     text;
    v_prio    integer;
    v_risk    text;
    v_seen_ddl text[] := ARRAY[]::text[];
    v_ddl_text text;
    v_seen_analyze text[] := ARRAY[]::text[];
    v_seen_vacuum text[] := ARRAY[]::text[];
    v_orig_sql  text;
    v_new_sql   text;
    v_applied   text[];
    v_finding_text text;
    v_rationale text;
    v_benefit   text;
    v_cost      text;
    v_object_name text;
    v_steps     text[];
    v_severity  text;
    v_confidence text;
BEGIN
    ------------------------------------------------------------------
    -- 1. Statistics
    ------------------------------------------------------------------
    FOR r IN SELECT s.* FROM sta.stats_advice(NULL, p_limit) s
    LOOP
        IF r.finding IN ('NEVER_ANALYZED', 'STALE_STATISTICS') THEN
            CONTINUE WHEN r.object_name = ANY (v_seen_analyze);
            v_seen_analyze := array_append(v_seen_analyze, r.object_name);
            v_type := 'ANALYZE';
            v_prio := 10;
            v_sql  := format('ANALYZE %s;', r.object_name);
            v_risk := 'None. ANALYZE only reads the relation and writes the '
                      'statistics.  It takes a SHARE UPDATE EXCLUSIVE lock, so it '
                      'does not block reads or writes.';
        ELSIF r.finding IN ('HIGH_DEAD_TUPLES', 'NEVER_VACUUMED') THEN
            -- A relation with dead tuples and a relation that was never
            -- vacuumed need the same command, so the action is only
            -- emitted once for each relation.
            CONTINUE WHEN r.object_name = ANY (v_seen_vacuum);
            v_seen_vacuum := array_append(v_seen_vacuum, r.object_name);
            v_type := 'VACUUM_ANALYZE';
            v_prio := 5;
            v_sql  := format('VACUUM (ANALYZE) %s;', r.object_name);
            v_risk := 'Low. VACUUM takes a SHARE UPDATE EXCLUSIVE lock and adds '
                      'I/O load to the server.  A VACUUM FULL would lock the '
                      'relation while it rewrites it and is not needed here.';
        ELSE
            CONTINUE;
        END IF;

        v_actions := v_actions || jsonb_build_array(jsonb_build_object(
            'action_type',      v_type,
            'priority',         v_prio,
            'object_name',      r.object_name,
            'queryid',          NULL::bigint,
            'query',            NULL::text,
            'action_sql',       v_sql,
            'finding',          r.finding,
            'finding_text',     r.finding_text,
            'severity',         r.severity,
            'confidence',       r.confidence,
            'rationale',        r.recommendation,
            'expected_benefit', r.expected_benefit,
            'estimated_cost',   r.estimated_cost,
            'risk',             v_risk,
            'validation_steps', to_jsonb(r.validation_steps)));
    END LOOP;

    ------------------------------------------------------------------
    -- 2. The statements to work on
    ------------------------------------------------------------------
    FOR t IN
        SELECT p_sql::text AS sql, NULL::bigint AS queryid
        WHERE p_sql IS NOT NULL
        UNION ALL
        SELECT x.sql, x.queryid
        FROM sta._workload_targets(p_window, LEAST(GREATEST(p_limit, 1), 25)) x
        WHERE p_sql IS NULL
    LOOP
        -- 2a. The index candidates.
        BEGIN
            FOR r IN SELECT ia.* FROM sta.index_advice(t.sql) ia
            LOOP
                -- The same index is asked for by more than one statement of
                -- the workload.  It is only built once.
                CONTINUE WHEN r.suggested_ddl = ANY (v_seen_ddl);
                v_seen_ddl := array_append(v_seen_ddl, r.suggested_ddl);
                v_actions := v_actions || jsonb_build_array(jsonb_build_object(
                    'action_type',      'CREATE_INDEX',
                    'priority',         20,
                    'object_name',      r.relation,
                    'queryid',          t.queryid,
                    'query',            t.sql,
                    'action_sql',       r.suggested_ddl,
                    'finding',          'MISSING_INDEX',
                    'finding_text',     r.rationale,
                    'severity',         'HIGH',
                    'confidence',       r.confidence,
                    'rationale',        r.rationale,
                    'expected_benefit', r.estimated_benefit,
                    'estimated_cost',   r.estimated_cost,
                    'risk',             'Medium. CREATE INDEX CONCURRENTLY reads '
                                        'the relation twice and cannot run inside a '
                                        'transaction block.  A build that fails '
                                        'leaves an invalid index behind that has to '
                                        'be dropped before the name can be used '
                                        'again.',
                    'validation_steps', to_jsonb(r.validation_steps)));
            END LOOP;
        EXCEPTION WHEN others THEN
            NULL;   -- a statement that cannot be planned has no index advice
        END;

        -- 2b. The rewritten statements.
        BEGIN
            FOR r IN SELECT rw.* FROM sta.rewrite_advice(t.sql) rw
            LOOP
                -- A rewrite that has no safe rewrite but carries the DDL of
                -- the index that would serve it becomes an index action.
                IF r.evidence ? 'suggested_ddl'
                   AND r.evidence->>'suggested_ddl' IS NOT NULL
                   AND NOT (r.evidence->>'suggested_ddl' = ANY (v_seen_ddl)) THEN
                    v_seen_ddl := array_append(v_seen_ddl, r.evidence->>'suggested_ddl');
                    v_ddl_text := r.evidence->>'suggested_ddl';
                    -- A trigram index needs pg_trgm.  The action has to be
                    -- runnable, so the extension is installed first when it
                    -- is missing.
                    IF r.pattern = 'LEADING_WILDCARD_LIKE'
                       AND v_ddl_text LIKE '%gin_trgm_ops%'
                       AND NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
                        v_ddl_text := 'CREATE EXTENSION IF NOT EXISTS pg_trgm;'
                                   || E'\n' || v_ddl_text;
                    END IF;
                    v_actions := v_actions || jsonb_build_array(jsonb_build_object(
                        'action_type',      'CREATE_INDEX',
                        'priority',         20,
                        'object_name',      r.object_name,
                        'queryid',          t.queryid,
                        'query',            r.original_sql,
                        'action_sql',       v_ddl_text,
                        'finding',          r.pattern,
                        'finding_text',     r.finding_text,
                        'severity',         r.severity,
                        'confidence',       r.confidence,
                        'rationale',        r.recommendation,
                        'expected_benefit', r.expected_benefit,
                        'estimated_cost',   r.estimated_cost,
                        'risk',             'Medium. CREATE INDEX CONCURRENTLY reads '
                                            'the relation twice and cannot run inside a '
                                            'transaction block.  A build that fails '
                                            'leaves an invalid index behind that has to '
                                            'be dropped before the name can be used '
                                            'again.',
                        'validation_steps', to_jsonb(r.validation_steps)));
                END IF;

            END LOOP;

            -- One rewritten statement per statement.  Every rule is
            -- applied, one after the other, so that the statement that
            -- comes out can be run as it is.
            SELECT rs.original_sql, rs.rewritten_sql, rs.applied
              INTO v_orig_sql, v_new_sql, v_applied
              FROM sta.rewrite_statement(t.sql) rs;

            IF v_new_sql IS NOT NULL AND v_new_sql IS DISTINCT FROM v_orig_sql THEN
                -- What the rules that were used have to say.
                SELECT coalesce(string_agg(DISTINCT rw.finding_text, ' '), ''),
                       coalesce(string_agg(DISTINCT rw.recommendation, ' '), ''),
                       coalesce(string_agg(DISTINCT rw.expected_benefit, ' '), ''),
                       coalesce(string_agg(DISTINCT rw.estimated_cost, ' '), '')
                  INTO v_finding_text, v_rationale, v_benefit, v_cost
                  FROM sta.rewrite_advice(t.sql) rw
                 WHERE rw.pattern = ANY (v_applied);

                -- The severity and the confidence of the most important of
                -- the rules that were used.
                SELECT rw.severity, rw.confidence, rw.object_name, rw.validation_steps
                  INTO v_severity, v_confidence, v_object_name, v_steps
                  FROM sta.rewrite_advice(t.sql) rw
                 WHERE rw.pattern = ANY (v_applied)
                 ORDER BY CASE rw.severity
                              WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2
                              WHEN 'LOW' THEN 1 ELSE 0 END DESC,
                          CASE rw.confidence
                              WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2
                              WHEN 'LOW' THEN 1 ELSE 0 END DESC
                 LIMIT 1;

                v_actions := v_actions || jsonb_build_array(jsonb_build_object(
                    'action_type',      'REWRITE',
                    'priority',         30,
                    'object_name',      v_object_name,
                    'queryid',          t.queryid,
                    'query',            v_orig_sql,
                    'action_sql',       v_new_sql,
                    'finding',          array_to_string(v_applied, ', '),
                    'finding_text',     v_finding_text,
                    'severity',         coalesce(v_severity, 'MEDIUM'),
                    'confidence',       coalesce(v_confidence, 'MEDIUM'),
                    'rationale',        v_rationale,
                    'expected_benefit', v_benefit,
                    'estimated_cost',   v_cost,
                    'risk',             'Depends on the rules that were used.  The '
                                        'findings list the assumption every rewrite '
                                        'depends on; check them before the rewritten '
                                        'statement is used.',
                    'validation_steps', to_jsonb(coalesce(v_steps, ARRAY[]::text[]))));
            END IF;
        EXCEPTION WHEN others THEN
            NULL;   -- a statement that cannot be parsed has no rewrite advice
        END;

        -- 2c. The statistics that a measured plan asks for.  The plan is
        -- only measured when the caller asks for it, because measuring a
        -- statement runs it.
        IF p_analyze THEN
            BEGIN
                FOR r IN SELECT pa.* FROM sta.plan_advice(t.sql, true, 50) pa
                LOOP
                    CONTINUE WHEN r.finding <> 'ESTIMATE_MISMATCH';
                    CONTINUE WHEN r.object_name IS NULL;
                    CONTINUE WHEN r.object_name = ANY (v_seen_analyze);
                    v_seen_analyze := array_append(v_seen_analyze, r.object_name);
                    v_actions := v_actions || jsonb_build_array(jsonb_build_object(
                        'action_type',      'ANALYZE',
                        'priority',         10,
                        'object_name',      r.object_name,
                        'queryid',          t.queryid,
                        'query',            t.sql,
                        'action_sql',       format('ANALYZE %s;', r.object_name),
                        'finding',          r.finding,
                        'finding_text',     r.finding_text,
                        'severity',         r.severity,
                        'confidence',       r.confidence,
                        'rationale',        r.recommendation,
                        'expected_benefit', r.expected_benefit,
                        'estimated_cost',   r.estimated_cost,
                        'risk',             'None. ANALYZE only reads the relation and '
                                            'writes the statistics.  It takes a SHARE '
                                            'UPDATE EXCLUSIVE lock, so it does not '
                                            'block reads or writes.',
                        'validation_steps', to_jsonb(r.validation_steps)));
                END LOOP;
            EXCEPTION WHEN others THEN
                NULL;   -- a statement that cannot be measured has no plan advice
            END;
        END IF;
    END LOOP;

    RETURN QUERY
    SELECT x.n::integer,
           x.action->>'action_type',
           (x.action->>'priority')::integer,
           x.action->>'object_name',
           (x.action->>'queryid')::bigint,
           x.action->>'query',
           x.action->>'action_sql',
           x.action->>'finding',
           x.action->>'finding_text',
           x.action->>'severity',
           x.action->>'confidence',
           x.action->>'rationale',
           x.action->>'expected_benefit',
           x.action->>'estimated_cost',
           x.action->>'risk',
           ARRAY(SELECT jsonb_array_elements_text(x.action->'validation_steps'))
      FROM (SELECT j.n,
                   j.j AS action,
                   row_number() OVER (ORDER BY (j.j->>'priority')::integer, j.n) AS rn
              FROM jsonb_array_elements(v_actions) WITH ORDINALITY AS j(j, n)) x
     WHERE x.rn <= LEAST(GREATEST(p_limit, 1), 200)
        -- When one statement is asked for, the actions that belong to that
        -- statement are always returned, even when the limit is reached.
        -- The caller asked for this statement and not for the workload, so
        -- the advice about the statement must not be dropped in favour of
        -- the advice about other relations.
        OR (p_sql IS NOT NULL
            AND x.action->>'action_type' IN ('REWRITE', 'CREATE_INDEX'))
     ORDER BY (x.action->>'priority')::integer, x.n;
END
$$;

COMMENT ON FUNCTION sta.action_plan(text, text, boolean, integer) IS
  'The changes that the findings ask for, as runnable statements, ordered by priority.';


------------------------------------------------------------------------------
-- The plan before and after a change
--
-- This is the part of an Oracle SQL Tuning Advisor run that answers the
-- question "did the change actually help?":  the plan of the statement as
-- the application runs it, the plan after the change was applied, and the
-- difference between the two.
--
-- Nothing is left behind.  The index is created in a subtransaction and
-- the statistics update is transactional, so both are rolled back when the
-- measurement is finished.
------------------------------------------------------------------------------

-- The readable plan of a statement: EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT).
-- EXPLAIN cannot be used as a plain command inside a function, so it is run
-- through SPI and the result rows are concatenated.
CREATE FUNCTION sta._explain_text(p_sql text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    r     record;
    v_out text := '';
    v_sql text;
BEGIN
    v_sql := btrim(p_sql);
    -- EXPLAIN does not accept a trailing semicolon
    IF right(v_sql, 1) = ';' THEN
        v_sql := btrim(left(v_sql, length(v_sql) - 1));
    END IF;

    -- Only statements that return rows can be explained, the same rule that
    -- sta.explain() follows.
    IF v_sql !~* '^\s*(SELECT|WITH|TABLE|VALUES)\y' THEN
        RETURN NULL;
    END IF;

    FOR r IN EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) ' || v_sql LOOP
        v_out := v_out || r."QUERY PLAN" || E'\n';
    END LOOP;

    RETURN NULLIF(v_out, '');
EXCEPTION WHEN others THEN
    RETURN NULL;
END
$$;

COMMENT ON FUNCTION sta._explain_text(text) IS
  'The plan of a statement as readable text (EXPLAIN ANALYZE, BUFFERS, '
  'FORMAT TEXT), or NULL when the statement cannot be explained.';

-- One entry per plan node: the node type and the relation or index it works
-- on.  Used to build the plan change matrix.
CREATE FUNCTION sta._plan_node_list(p_plan jsonb)
RETURNS text[]
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE root AS (
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
    SELECT COALESCE(array_agg(
        CASE
            WHEN node ->> 'Relation Name' IS NOT NULL
                THEN node ->> 'Node Type' || ' on ' ||
                     coalesce(node->>'Schema', '') ||
                     CASE WHEN node->>'Schema' IS NOT NULL THEN '.' ELSE '' END ||
                     (node ->> 'Relation Name') ||
                     CASE WHEN node ->> 'Index Name' IS NOT NULL
                          THEN ' using ' || (node ->> 'Index Name')
                          ELSE '' END
            WHEN node ->> 'Index Name' IS NOT NULL
                THEN node ->> 'Node Type' || ' using ' || (node ->> 'Index Name')
            ELSE node ->> 'Node Type'
        END ORDER BY t.ord), ARRAY[]::text[])
    FROM (SELECT node, row_number() OVER () AS ord FROM nodes
          WHERE node IS NOT NULL) t
$$;

COMMENT ON FUNCTION sta._plan_node_list(jsonb) IS
  'One entry per plan node: the node type and the relation or index it '
  'works on, in the order the planner produced them.';

-------------------------------------------------------------------------------
--- The reading of a plan
-------------------------------------------------------------------------------
-- The plan says what the planner did.  The reading says what that means:
-- which table was read, with which index, how many rows came back, and
-- which step of the plan cost the most time and the most buffers.
--
-- The reading is built from the plan alone, so it works for an estimated
-- plan as well as for a measured one.  When the plan was measured, the
-- reading speaks about rows and milliseconds; when it was only estimated,
-- it speaks about rows and cost.
-------------------------------------------------------------------------------

-- The name of a step of the plan, in words.
CREATE FUNCTION sta._plan_node_label(p_node jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_label text;
BEGIN
    IF p_node IS NULL THEN
        RETURN NULL;
    END IF;

    v_label := lower(coalesce(p_node->>'Node Type', '?'));

    IF p_node->>'Relation Name' IS NOT NULL THEN
        v_label := v_label || ' on ' ||
                   CASE WHEN p_node->>'Schema' IS NOT NULL
                        THEN (p_node->>'Schema') || '.' END ||
                   (p_node->>'Relation Name');
    END IF;

    IF p_node->>'Index Name' IS NOT NULL THEN
        v_label := v_label || ' using ' || (p_node->>'Index Name');
    END IF;

    IF p_node->>'Join Type' IS NOT NULL THEN
        v_label := v_label || ' (' || lower(p_node->>'Join Type') || ' join)';
    END IF;

    RETURN v_label;
END
$$;

COMMENT ON FUNCTION sta._plan_node_label(jsonb) IS
  'The name of a step of the plan, in words: the node type, the relation '
  'it works on, the index it uses and the kind of the join.';

-- What a single step of the plan does, in one sentence.
CREATE FUNCTION sta._plan_node_reading(p_node jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_type text;
    v_rel  text;
    v_idx  text;
BEGIN
    IF p_node IS NULL THEN
        RETURN NULL;
    END IF;

    v_type := p_node->>'Node Type';
    IF v_type IS NULL THEN
        RETURN NULL;
    END IF;

    v_rel := p_node->>'Relation Name';
    v_idx := p_node->>'Index Name';

    CASE v_type
        WHEN 'Seq Scan' THEN
            RETURN 'reads every row of ' || v_rel;
        WHEN 'Sample Scan' THEN
            RETURN 'reads a sample of ' || v_rel;
        WHEN 'Index Scan' THEN
            RETURN 'looks ' || v_rel || ' up in the index ' || v_idx;
        WHEN 'Index Only Scan' THEN
            RETURN 'looks ' || v_rel || ' up in the index ' || v_idx ||
                   ' and reads the index alone';
        WHEN 'Bitmap Index Scan' THEN
            RETURN 'marks the pages of ' || v_rel || ' that the index ' ||
                   v_idx || ' points at';
        WHEN 'Bitmap Heap Scan' THEN
            RETURN 'reads the pages of ' || v_rel ||
                   ' that the bitmap marked and checks every row again';
        WHEN 'Tid Scan' THEN
            RETURN 'reads ' || v_rel || ' by physical row';
        WHEN 'Subquery Scan' THEN
            RETURN 'runs the subquery below';
        WHEN 'Function Scan' THEN
            RETURN 'returns the rows of the function ' ||
                   coalesce(p_node->>'Function Name', '');
        WHEN 'Values Scan' THEN
            RETURN 'returns the rows of the VALUES list';
        WHEN 'CTE Scan' THEN
            RETURN 'returns the rows of the common table expression ' ||
                   coalesce(p_node->>'CTE Name', '');
        WHEN 'Nested Loop' THEN
            RETURN 'runs the inner side once for every row of the outer side';
        WHEN 'Hash Join' THEN
            RETURN 'builds a hash table from the inner side and probes it ' ||
                   'with every row of the outer side';
        WHEN 'Merge Join' THEN
            RETURN 'merges the two sides, which are both sorted';
        WHEN 'Hash' THEN
            RETURN 'builds a hash table from the rows below';
        WHEN 'Materialize' THEN
            RETURN 'keeps the rows below in memory so that they can be read again';
        WHEN 'Memoize' THEN
            RETURN 'remembers the result of the inner side for every key';
        WHEN 'Sort' THEN
            RETURN 'sorts the rows below';
        WHEN 'Incremental Sort' THEN
            RETURN 'sorts the rows below, keeping the order that is already there';
        WHEN 'Group' THEN
            RETURN 'groups the rows below';
        WHEN 'Aggregate' THEN
            RETURN 'aggregates the rows below';
        WHEN 'WindowAgg' THEN
            RETURN 'computes the window functions over the rows below';
        WHEN 'Unique' THEN
            RETURN 'removes the duplicate rows below';
        WHEN 'Limit' THEN
            RETURN 'stops after the given number of rows';
        WHEN 'Gather' THEN
            RETURN 'runs the rows below in parallel and collects the result';
        WHEN 'Gather Merge' THEN
            RETURN 'runs the rows below in parallel and merges the result';
        WHEN 'Append' THEN
            RETURN 'runs the parts below and appends the results';
        WHEN 'Merge Append' THEN
            RETURN 'merges the sorted parts below';
        WHEN 'Result' THEN
            RETURN 'returns the rows without reading a table';
        ELSE
            RETURN NULL;
    END CASE;
END
$$;

COMMENT ON FUNCTION sta._plan_node_reading(jsonb) IS
  'What a single step of the plan does, in one sentence.';

-- The plan, line by line, with the numbers of every step.
CREATE FUNCTION sta._plan_reading_lines(p_node jsonb, p_depth integer, p_lines text[])
RETURNS text[]
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_out  text[] := p_lines;
    v_key  text;
    v_kv   text;
    v_ind  text;
    v_hit  bigint;
    v_read bigint;
    c      record;
BEGIN
    IF p_node IS NULL THEN
        RETURN v_out;
    END IF;

    v_ind := repeat('  ', greatest(p_depth, 0));

    v_out := array_append(v_out, v_ind || '- ' ||
                          coalesce(sta._plan_node_label(p_node), '?'));

    -- the condition of the step
    FOREACH v_key IN ARRAY ARRAY['Index Cond', 'Recheck Cond', 'TID Cond',
                                  'Filter', 'Hash Cond', 'Join Filter',
                                  'One-Time Filter', 'Group Key', 'Sort Key',
                                  'Presorted Key', 'Cache Key'] LOOP
        IF p_node->v_key IS NOT NULL THEN
            v_out := array_append(v_out, v_ind || '    ' || lower(v_key) || ': ' ||
                                  (p_node->>v_key));
        END IF;
    END LOOP;

    -- the numbers of the step
    v_kv := NULL;

    IF p_node->>'Plan Rows' IS NOT NULL THEN
        v_kv := format('%s row%s estimated',
                       to_char((p_node->>'Plan Rows')::numeric, 'FM999,999,999,999'),
                       CASE WHEN (p_node->>'Plan Rows')::numeric = 1 THEN '' ELSE 's' END);
    END IF;

    IF p_node->>'Actual Rows' IS NOT NULL THEN
        v_kv := coalesce(v_kv || ', ', '') ||
               format('%s row%s returned',
                      to_char((p_node->>'Actual Rows')::numeric, 'FM999,999,999,999'),
                      CASE WHEN (p_node->>'Actual Rows')::numeric = 1 THEN '' ELSE 's' END);
    END IF;

    IF p_node->>'Actual Loops' IS NOT NULL
       AND (p_node->>'Actual Loops')::numeric > 1 THEN
        v_kv := coalesce(v_kv || ', ', '') ||
               format('in %s loops',
                      to_char((p_node->>'Actual Loops')::numeric, 'FM999,999,999,999'));
    END IF;

    IF p_node->>'Actual Total Time' IS NOT NULL THEN
        v_kv := coalesce(v_kv || ', ', '') ||
               format('%s ms', round((p_node->>'Actual Total Time')::numeric, 3));
    END IF;

    v_hit  := coalesce((p_node->>'Shared Hit Blocks')::bigint, 0) +
              coalesce((p_node->>'Local Hit Blocks')::bigint, 0);
    v_read := coalesce((p_node->>'Shared Read Blocks')::bigint, 0) +
              coalesce((p_node->>'Local Read Blocks')::bigint, 0);

    IF v_hit + v_read > 0 THEN
        v_kv := coalesce(v_kv || ', ', '') || format('%s buffers hit', v_hit);
        IF v_read > 0 THEN
            v_kv := v_kv || format(', %s read', v_read);
        END IF;
    END IF;

    IF v_kv IS NOT NULL THEN
        v_out := array_append(v_out, v_ind || '    ' || v_kv);
    END IF;

    -- the steps below
    FOR c IN
        SELECT child
          FROM jsonb_array_elements(
                   CASE WHEN jsonb_typeof(p_node->'Plans') = 'array'
                        THEN p_node->'Plans' ELSE '[]'::jsonb END) AS a(child)
    LOOP
        v_out := sta._plan_reading_lines(c.child, p_depth + 1, v_out);
    END LOOP;

    RETURN v_out;
END
$$;

COMMENT ON FUNCTION sta._plan_reading_lines(jsonb, integer, text[]) IS
  'The plan, line by line, with the numbers of every step.';

-- The reading of a plan, in words.
CREATE FUNCTION sta.plan_explanation(p_plan jsonb)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_doc    jsonb;
    v_root   jsonb;
    v_arr    jsonb;
    v_lines  text[] := ARRAY[]::text[];
    v_para   text[] := ARRAY[]::text[];
    v_shape  text;
    v_rels   text;
    v_hot    jsonb;
    v_hot_ms double precision;
    v_hotloops bigint;
    v_total  double precision;
    v_hotbuf bigint;
    v_totbuf bigint;
    v_exec   double precision;
    v_planms double precision;
    v_rows   bigint;
    v_hit    bigint;
    v_read   bigint;
    n        record;
BEGIN
    IF p_plan IS NULL THEN
        RETURN NULL;
    END IF;

    v_doc := CASE WHEN jsonb_typeof(p_plan) = 'array' THEN p_plan->0 ELSE p_plan END;
    IF v_doc IS NULL THEN
        RETURN NULL;
    END IF;

    v_root := CASE WHEN jsonb_typeof(v_doc) = 'object' AND v_doc ? 'Plan'
                   THEN v_doc->'Plan' ELSE v_doc END;
    IF v_root IS NULL THEN
        RETURN NULL;
    END IF;

    v_arr := jsonb_build_array(jsonb_build_object('Plan', v_root));

    ------------------------------------------------------------------
    -- the plan itself
    ------------------------------------------------------------------
    v_lines := sta._plan_reading_lines(v_root, 0, ARRAY[]::text[]);

    ------------------------------------------------------------------
    -- the shape of the plan
    ------------------------------------------------------------------
    CASE v_root->>'Node Type'
        WHEN 'Nested Loop'      THEN v_shape := 'a nested loop join';
        WHEN 'Hash Join'        THEN v_shape := 'a hash join';
        WHEN 'Merge Join'       THEN v_shape := 'a merge join';
        WHEN 'Seq Scan'         THEN v_shape := 'a sequential scan';
        WHEN 'Index Scan'       THEN v_shape := 'an index scan';
        WHEN 'Index Only Scan'  THEN v_shape := 'an index only scan';
        WHEN 'Bitmap Heap Scan' THEN v_shape := 'a bitmap heap scan';
        WHEN 'Aggregate'        THEN v_shape := 'an aggregate';
        WHEN 'Sort'             THEN v_shape := 'a sort';
        WHEN 'Gather'           THEN v_shape := 'a parallel gather';
        WHEN 'Limit'            THEN v_shape := 'a limit';
        ELSE v_shape := 'a ' || lower(coalesce(v_root->>'Node Type', 'plan'));
    END CASE;

    SELECT string_agg(DISTINCT rel, ' and ')
      INTO v_rels
      FROM (SELECT nd.node->>'Relation Name' AS rel
              FROM sta._plan_nodes(v_arr) nd
             WHERE nd.node->>'Relation Name' IS NOT NULL) s;

    v_para := array_append(v_para, 'The plan is ' || v_shape ||
                           CASE WHEN v_rels IS NOT NULL
                                THEN ' over ' || v_rels ELSE '' END || '.');

    ------------------------------------------------------------------
    -- every table the plan reads
    ------------------------------------------------------------------
    FOR n IN
        SELECT nd.node
          FROM sta._plan_nodes(v_arr) nd
         WHERE nd.node->>'Relation Name' IS NOT NULL
           AND NOT EXISTS (
                 SELECT 1
                   FROM jsonb_array_elements(
                            CASE WHEN jsonb_typeof(nd.node->'Plans') = 'array'
                                 THEN nd.node->'Plans' ELSE '[]'::jsonb END) AS c(child)
                WHERE true)
    LOOP
        v_para := array_append(v_para,
            CASE n.node->>'Parent Relationship'
                WHEN 'Outer' THEN 'The outer side '
                WHEN 'Inner' THEN 'The inner side '
                ELSE 'The statement '
            END ||
            coalesce(sta._plan_node_reading(n.node),
                     'reads ' || (n.node->>'Relation Name')) || '.');
    END LOOP;

    ------------------------------------------------------------------
    -- the step that costs the most
    ------------------------------------------------------------------
    SELECT nd.node INTO v_hot
      FROM sta._plan_nodes(v_arr) nd
     WHERE nd.node->>'Actual Total Time' IS NOT NULL
       AND nd.node_path <> ''
     ORDER BY (nd.node->>'Actual Total Time')::double precision *
              greatest(coalesce((nd.node->>'Actual Loops')::double precision, 1), 1) DESC,
              (nd.node->>'Total Cost')::double precision DESC NULLS LAST
     LIMIT 1;

    IF v_hot IS NOT NULL THEN
        v_hot_ms := (v_hot->>'Actual Total Time')::double precision *
                    greatest(coalesce((v_hot->>'Actual Loops')::double precision, 1), 1);
        v_hotloops := greatest(coalesce((v_hot->>'Actual Loops')::bigint, 1), 1);
        v_hotbuf := coalesce((v_hot->>'Shared Hit Blocks')::bigint, 0) +
                    coalesce((v_hot->>'Shared Read Blocks')::bigint, 0) +
                    coalesce((v_hot->>'Local Hit Blocks')::bigint, 0) +
                    coalesce((v_hot->>'Local Read Blocks')::bigint, 0);
        v_total := coalesce((v_root->>'Actual Total Time')::double precision, 0);
        v_totbuf := coalesce((v_root->>'Shared Hit Blocks')::bigint, 0) +
                    coalesce((v_root->>'Shared Read Blocks')::bigint, 0) +
                    coalesce((v_root->>'Local Hit Blocks')::bigint, 0) +
                    coalesce((v_root->>'Local Read Blocks')::bigint, 0);

        v_para := array_append(v_para,
            'The step that costs the most is the ' || sta._plan_node_label(v_hot) || ': ' ||
            CASE WHEN v_hotloops > 1
                 THEN round(v_hot_ms::numeric, 3) || ' ms in total across ' ||
                      v_hotloops || ' loops; the loops run at the same time, so the step can ' ||
                      'account for more than the ' || round(v_total::numeric, 3) ||
                      ' ms the statement took'
                 ELSE round(v_hot_ms::numeric, 3) || ' ms of the ' ||
                      round(v_total::numeric, 3) || ' ms in total'
            END ||
            CASE WHEN v_totbuf > 0
                 THEN ', and ' || v_hotbuf || ' of the ' || v_totbuf || ' buffers'
                 ELSE '' END || '.');
    END IF;

    ------------------------------------------------------------------
    -- the totals
    ------------------------------------------------------------------
    v_exec   := (v_doc->>'Execution Time')::double precision;
    v_planms := (v_doc->>'Planning Time')::double precision;
    v_rows   := (v_root->>'Actual Rows')::bigint;
    v_hit    := coalesce((v_root->>'Shared Hit Blocks')::bigint, 0) +
                coalesce((v_root->>'Local Hit Blocks')::bigint, 0);
    v_read   := coalesce((v_root->>'Shared Read Blocks')::bigint, 0) +
                coalesce((v_root->>'Local Read Blocks')::bigint, 0);

    IF v_rows IS NOT NULL THEN
        v_para := array_append(v_para,
            'The statement returned ' || to_char(v_rows::numeric, 'FM999,999,999,999') ||
            ' row' || CASE WHEN v_rows = 1 THEN '' ELSE 's' END || '.');
    END IF;

    IF v_exec IS NOT NULL THEN
        v_para := array_append(v_para,
            'Planning took ' || round(coalesce(v_planms, 0)::numeric, 3) ||
            ' ms, the execution ' || round(v_exec::numeric, 3) || ' ms' ||
            CASE WHEN v_hit + v_read > 0
                 THEN ', and the plan touched ' || (v_hit + v_read) || ' buffers' ||
                      CASE WHEN v_read > 0
                           THEN ', ' || v_read || ' of them read from disk'
                           ELSE ', all of them from the cache' END
                 ELSE '' END || '.');
    ELSE
        v_para := array_append(v_para,
            'The plan was not measured, so only the estimate is known: the cost ' ||
            'of the plan is ' ||
            round(coalesce((v_root->>'Total Cost')::numeric, 0), 2) || '.');
    END IF;

    RETURN array_to_string(v_lines, E'\n') || E'\n\n' ||
           array_to_string(v_para, ' ');
END
$$;

COMMENT ON FUNCTION sta.plan_explanation(jsonb) IS
  'The reading of a plan: what every step of the plan does, what it cost, '
  'and which step cost the most.  Works for an estimated plan and for a '
  'measured one.';

-- The reading of the plan of a statement.
CREATE FUNCTION sta.statement_explanation(p_sql text, p_analyze boolean DEFAULT true)
RETURNS text
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_plan jsonb;
BEGIN
    IF p_sql IS NULL OR btrim(p_sql) = '' THEN
        RETURN NULL;
    END IF;

    BEGIN
        v_plan := sta.explain(p_sql, p_analyze);
    EXCEPTION WHEN others THEN
        BEGIN
            v_plan := sta.explain(p_sql, false);
        EXCEPTION WHEN others THEN
            RETURN NULL;
        END;
    END;

    RETURN sta.plan_explanation(v_plan);
END
$$;

COMMENT ON FUNCTION sta.statement_explanation(text, boolean) IS
  'The reading of the plan of a statement.  A statement that cannot be run, '
  'because it uses parameter placeholders, is read from its estimated plan.';

-------------------------------------------------------------------------------
--- The comparison of two results
-------------------------------------------------------------------------------
-- Two statements that should return the same rows are compared row by row:
-- every row is turned into its JSON form and hashed, and the two sets of
-- hashes are compared.  The comparison also says whether the order of the
-- rows is the same, which only means something when the statement has an
-- ORDER BY of its own.
-------------------------------------------------------------------------------
CREATE FUNCTION sta._compare_results(p_before text, p_after text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_b      text := rtrim(btrim(coalesce(p_before, '')), ';');
    v_a      text := rtrim(btrim(coalesce(p_after, '')), ';');
    v_out    jsonb;
    v_ordered boolean;
BEGIN
    IF v_b = '' OR v_a = '' THEN
        RETURN jsonb_build_object('error', 'one of the two statements is missing');
    END IF;

    -- The order of the rows only means something when the statement asks
    -- for an order of its own.
    v_ordered := (v_b ~* '\yorder\s+by\b') AND (v_a ~* '\yorder\s+by\b');

    BEGIN
        EXECUTE format($q$
            WITH b AS MATERIALIZED (
                SELECT md5(to_jsonb(t)::text) AS h, to_jsonb(t)::text AS r,
                       row_number() OVER () AS n
                  FROM (%s) t),
            a AS MATERIALIZED (
                SELECT md5(to_jsonb(t)::text) AS h, to_jsonb(t)::text AS r,
                       row_number() OVER () AS n
                  FROM (%s) t),
            bh AS (SELECT DISTINCT h FROM b),
            ah AS (SELECT DISTINCT h FROM a)
            SELECT jsonb_build_object(
                'before_rows', (SELECT count(*) FROM b),
                'after_rows', (SELECT count(*) FROM a),
                'rows_in_both', (SELECT count(*) FROM bh JOIN ah USING (h)),
                'only_before', (SELECT count(*) FROM bh
                                 WHERE NOT EXISTS (SELECT 1 FROM ah WHERE ah.h = bh.h)),
                'only_after', (SELECT count(*) FROM ah
                                WHERE NOT EXISTS (SELECT 1 FROM bh WHERE bh.h = ah.h)),
                'order_preserved', CASE
                    WHEN %L AND (SELECT count(*) FROM b) <= 10000
                        THEN (SELECT string_agg(h, ',' ORDER BY n) FROM b)
                           = (SELECT string_agg(h, ',' ORDER BY n) FROM a)
                    ELSE NULL END,
                'example_before', (SELECT r FROM b ORDER BY n LIMIT 1),
                'example_after', (SELECT r FROM a ORDER BY n LIMIT 1))
        $q$, v_b, v_a, coalesce(v_ordered::text, 'false'))
        INTO v_out;
    EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('error', SQLERRM);
    END;

    RETURN v_out
        || jsonb_build_object(
               'rows_identical',
               (v_out->>'before_rows')::bigint = (v_out->>'after_rows')::bigint
               AND (v_out->>'only_before')::bigint = 0
               AND (v_out->>'only_after')::bigint = 0,
               'order_comparable', v_ordered);
END
$$;

COMMENT ON FUNCTION sta._compare_results(text, text) IS
  'The comparison of the rows of two statements: the number of rows on each '
  'side, the rows that are only in one of them, and whether the order of the '
  'rows is the same.';

-------------------------------------------------------------------------------
--- The assumptions a rewrite depends on
-------------------------------------------------------------------------------
-- A rewrite is only safe when the assumption it depends on holds.  The
-- assumption is stated by the rule that offered the rewrite; this function
-- checks it against the data and reports the result.
--
-- Every rewrite also has to return the same rows as the original, and that
-- is checked row by row.
-------------------------------------------------------------------------------
CREATE FUNCTION sta.assumption_checks(
    p_pattern   text,
    p_original  text,
    p_rewritten text
)
RETURNS TABLE (
    check_id   integer,
    assumption text,
    check_sql  text,
    expected   text,
    status     text,
    detail     text
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_pattern text := upper(btrim(coalesce(p_pattern, '')));
    v_n       integer := 0;
    v_cmp     jsonb;
    v_m       text[];
    v_rel     text;
    v_col     text;
    v_lit     text;
    v_func    text;
    v_cols    text[];
    v_list    text;
    v_sql     text;
    v_count   bigint;
    v_ok      boolean;
    v_status  text;
    v_detail  text;
    v_orig    text;
    v_new     text;
    r         record;
BEGIN
    v_orig := rtrim(btrim(coalesce(p_original, '')), ';');
    v_new  := rtrim(btrim(coalesce(p_rewritten, '')), ';');

    ------------------------------------------------------------------
    -- The check that every rewrite has to pass: the same rows.
    ------------------------------------------------------------------
    v_n := v_n + 1;
    IF v_orig = '' OR v_new = '' THEN
        RETURN QUERY
        SELECT v_n,
               'The rewrite returns the same rows as the original.',
               '(the two statements are compared row by row)',
               'the same rows', 'SKIPPED',
               'one of the two statements is missing';
        RETURN;
    END IF;

    IF v_orig = v_new THEN
        RETURN QUERY
        SELECT v_n,
               'The rewrite returns the same rows as the original.',
               '(the two statements are compared row by row)',
               'the same rows', 'SKIPPED',
               'the statement was not rewritten, so there is nothing to compare';
        RETURN;
    END IF;

    v_cmp := sta._compare_results(v_orig, v_new);
    IF v_cmp ? 'error' THEN
        RETURN QUERY
        SELECT v_n,
               'The rewrite returns the same rows as the original.',
               '(the two statements are compared row by row)',
               'the same rows', 'ERROR', v_cmp->>'error';
    ELSE
        v_status := CASE WHEN (v_cmp->>'rows_identical')::boolean
                         THEN 'PASS' ELSE 'FAIL' END;
        v_detail := format('%s rows before, %s rows after, %s rows only in the original, %s rows only in the rewrite',
                           v_cmp->>'before_rows', v_cmp->>'after_rows',
                           v_cmp->>'only_before', v_cmp->>'only_after');
        RETURN QUERY
        SELECT v_n,
               'The rewrite returns the same rows as the original.',
               '(the two statements are compared row by row)',
               'the same rows', v_status, v_detail;
    END IF;

    ------------------------------------------------------------------
    -- NOT IN -> NOT EXISTS: the column of the subquery holds no NULL
    ------------------------------------------------------------------
    IF v_pattern = 'NOT_IN_TO_NOT_EXISTS' THEN
        SELECT m[4], m[3] INTO v_rel, v_col
          FROM regexp_matches(v_orig,
               '\y([A-Za-z_][A-Za-z0-9_$]*)\s+not\s+in\s*\(\s*select\s+'
               || '((?:[A-Za-z_][A-Za-z0-9_$]*\.)?)([A-Za-z_][A-Za-z0-9_$]*)'
               || '\s+from\s+([A-Za-z_][A-Za-z0-9_$]*(?:\.[A-Za-z_][A-Za-z0-9_$]*)?)', 'gi') AS m
         LIMIT 1;

        v_n := v_n + 1;
        IF v_rel IS NULL OR v_col IS NULL THEN
            RETURN QUERY
            SELECT v_n,
                   'The column of the subquery holds no NULL, so NOT IN and NOT EXISTS return the same rows.',
                   '(the subquery could not be read from the statement)',
                   'no row with a NULL', 'SKIPPED',
                   'the subquery of the original statement could not be found';
        ELSE
            v_sql := format('SELECT count(*) FROM %s WHERE %I IS NULL', v_rel, v_col);
            BEGIN
                EXECUTE v_sql INTO v_count;
                v_status := CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END;
                v_detail := format('%s rows of %s have a NULL in %s',
                                   v_count, v_rel, v_col);
            EXCEPTION WHEN others THEN
                v_status := 'ERROR';
                v_detail := SQLERRM;
            END;
            RETURN QUERY
            SELECT v_n,
                   'The column of the subquery holds no NULL, so NOT IN and NOT EXISTS return the same rows.',
                   v_sql, 'no row with a NULL', v_status, v_detail;
        END IF;

    ------------------------------------------------------------------
    -- lower(col) = 'x' -> col = 'x': the values are already in that case
    ------------------------------------------------------------------
    ELSIF v_pattern = 'NON_SARGABLE_PREDICATE'
          AND v_orig ~* '\y(lower|upper)\s*\(' THEN
        SELECT m[1], m[2], m[3] INTO v_col, v_func, v_lit
          FROM regexp_matches(v_orig,
               '\y(lower|upper)\s*\(\s*([A-Za-z_][A-Za-z0-9_$]*)\s*\)\s*=\s*''([^'']*)''', 'gi') AS m
         LIMIT 1;

        v_rel := NULL;
        IF v_col IS NOT NULL THEN
            FOR r IN SELECT unnest(sta._sql_relations(v_orig)) LOOP
                IF v_col = ANY (sta._sql_relation_columns(r)) THEN
                    v_rel := r;
                    EXIT;
                END IF;
            END LOOP;
        END IF;

        v_n := v_n + 1;
        IF v_rel IS NULL OR v_col IS NULL THEN
            RETURN QUERY
            SELECT v_n,
                   format('Every stored value of %s is already %s-case, so dropping the function from the predicate returns the same rows.', coalesce(v_col, 'the column'), lower(coalesce(v_func, 'lower'))),
                   '(the relation of the column could not be found)',
                   'no row that differs', 'SKIPPED',
                   'the relation that owns the column could not be found';
        ELSE
            v_sql := format('SELECT count(*) FROM %s WHERE %I IS DISTINCT FROM %s(%I)',
                            v_rel, v_col, lower(v_func), v_col);
            BEGIN
                EXECUTE v_sql INTO v_count;
                v_status := CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END;
                v_detail := format('%s rows of %s hold a value that is not %s-case',
                                   v_count, v_rel, lower(v_func));
            EXCEPTION WHEN others THEN
                v_status := 'ERROR';
                v_detail := SQLERRM;
            END;
            RETURN QUERY
            SELECT v_n,
                   format('Every stored value of %s is already %s-case, so dropping the function from the predicate returns the same rows.', v_col, lower(v_func)),
                   v_sql, 'no row that differs', v_status, v_detail;
        END IF;

    ------------------------------------------------------------------
    -- date(col) = 'x' -> col >= 'x' AND col < 'x' + 1: no time of day
    ------------------------------------------------------------------
    ELSIF v_pattern = 'NON_SARGABLE_PREDICATE' THEN
        SELECT m[1] INTO v_col
          FROM regexp_matches(v_orig,
               '\ydate\s*\(\s*([A-Za-z_][A-Za-z0-9_$]*)\s*\)\s*=\s*''[0-9]{4}-[0-9]{2}-[0-9]{2}''', 'gi') AS m
         LIMIT 1;

        v_rel := NULL;
        IF v_col IS NOT NULL THEN
            FOR r IN SELECT unnest(sta._sql_relations(v_orig)) LOOP
                IF v_col = ANY (sta._sql_relation_columns(r)) THEN
                    v_rel := r;
                    EXIT;
                END IF;
            END LOOP;
        END IF;

        v_n := v_n + 1;
        IF v_rel IS NULL OR v_col IS NULL THEN
            RETURN QUERY
            SELECT v_n,
                   format('The column %s holds no time of day, so the range of the day returns exactly the rows the function returned.', coalesce(v_col, 'the column')),
                   '(the relation of the column could not be found)',
                   'no row with a time of day', 'SKIPPED',
                   'the relation that owns the column could not be found';
        ELSE
            v_sql := format('SELECT count(*) FROM %s WHERE %I IS NOT NULL AND %I::timestamp <> date_trunc(''day'', %I::timestamp)',
                            v_rel, v_col, v_col, v_col);
            BEGIN
                EXECUTE v_sql INTO v_count;
                v_status := CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END;
                v_detail := format('%s rows of %s hold a time of day', v_count, v_rel);
            EXCEPTION WHEN others THEN
                v_status := 'ERROR';
                v_detail := SQLERRM;
            END;
            RETURN QUERY
            SELECT v_n,
                   format('The column %s holds no time of day, so the range of the day returns exactly the rows the function returned.', v_col),
                   v_sql, 'no row with a time of day', v_status, v_detail;
        END IF;

    ------------------------------------------------------------------
    -- col::text = '123.45' -> col = 123.45: the literal is canonical
    ------------------------------------------------------------------
    ELSIF v_pattern = 'IMPLICIT_CAST' THEN
        SELECT m[1], m[2] INTO v_col, v_lit
          FROM regexp_matches(v_orig,
               '\y([A-Za-z_][A-Za-z0-9_$]*)\s*::\s*text\s*=\s*''([^'']*)''', 'gi') AS m
         LIMIT 1;

        v_n := v_n + 1;
        IF v_lit IS NULL OR v_lit !~ '^-?[0-9]+(\.[0-9]+)?$' THEN
            RETURN QUERY
            SELECT v_n,
                   'The text of the literal is the canonical form of the number, so the comparison selects the same rows.',
                   '(the literal is not a number)',
                   'the same text', 'SKIPPED',
                   'the literal is not a number, so the rewrite is exact';
        ELSE
            v_sql := format('SELECT %L::numeric::text = %L', v_lit, v_lit);
            BEGIN
                EXECUTE v_sql INTO v_ok;
                v_status := CASE WHEN coalesce(v_ok, false) THEN 'PASS' ELSE 'FAIL' END;
                v_detail := format('the literal %s reads back as %s',
                                   v_lit, v_lit::numeric::text);
            EXCEPTION WHEN others THEN
                v_status := 'ERROR';
                v_detail := SQLERRM;
            END;
            RETURN QUERY
            SELECT v_n,
                   'The text of the literal is the canonical form of the number, so the comparison selects the same rows.',
                   v_sql, 'the same text', v_status, v_detail;
        END IF;

    ------------------------------------------------------------------
    -- col LIKE '%x%': the trigram index can be built
    ------------------------------------------------------------------
    ELSIF v_pattern = 'LEADING_WILDCARD_LIKE' THEN
        v_n := v_n + 1;
        v_sql := 'SELECT count(*) FROM pg_extension WHERE extname = ''pg_trgm''';
        BEGIN
            EXECUTE v_sql INTO v_count;
            v_status := CASE WHEN v_count > 0 THEN 'PASS' ELSE 'FAIL' END;
            v_detail := CASE WHEN v_count > 0
                             THEN 'the pg_trgm extension is installed'
                             ELSE 'the pg_trgm extension is not installed, so the trigram index cannot be built yet'
                        END;
        EXCEPTION WHEN others THEN
            v_status := 'ERROR';
            v_detail := SQLERRM;
        END;
        RETURN QUERY
        SELECT v_n,
               'The trigram index can be built: the pg_trgm extension is installed.',
               v_sql, 'the extension is installed', v_status, v_detail;

    ------------------------------------------------------------------
    -- UNION -> UNION ALL: the branches do not return the same row
    ------------------------------------------------------------------
    ELSIF v_pattern = 'UNION_TO_UNION_ALL' THEN
        v_n := v_n + 1;
        IF v_cmp ? 'error' THEN
            RETURN QUERY
            SELECT v_n,
                   'The two branches do not return the same row, so UNION ALL does not add duplicates.',
                   '(the number of rows the two statements return)',
                   'the same number of rows', 'ERROR', v_cmp->>'error';
        ELSE
            v_status := CASE WHEN (v_cmp->>'before_rows')::bigint = (v_cmp->>'after_rows')::bigint
                             THEN 'PASS' ELSE 'FAIL' END;
            v_detail := format('%s rows with UNION, %s rows with UNION ALL',
                               v_cmp->>'before_rows', v_cmp->>'after_rows');
            RETURN QUERY
            SELECT v_n,
                   'The two branches do not return the same row, so UNION ALL does not add duplicates.',
                   '(the number of rows the two statements return)',
                   'the same number of rows', v_status, v_detail;
        END IF;

    ------------------------------------------------------------------
    -- LIMIT n OFFSET m -> keyset: the sort key is unique and never NULL
    ------------------------------------------------------------------
    ELSIF v_pattern = 'OFFSET_PAGINATION' THEN
        SELECT m[1] INTO v_col
          FROM regexp_matches(v_orig,
               '\yorder\s+by\s+([A-Za-z_][A-Za-z0-9_$]*)', 'gi') AS m
         LIMIT 1;
        SELECT f.relation INTO v_rel FROM sta._sql_first_from(v_orig) f;

        v_n := v_n + 1;
        IF v_rel IS NULL OR v_col IS NULL THEN
            RETURN QUERY
            SELECT v_n,
                   format('The sort key %s is unique and is never NULL, so the pages do not repeat or skip a row.', coalesce(v_col, 'the sort key')),
                   '(the sort key could not be read from the statement)',
                   'every row has its own value', 'SKIPPED',
                   'the sort key of the statement could not be found';
        ELSE
            v_sql := format('SELECT count(*) = count(DISTINCT %I) AND count(*) = count(%I) FROM %s',
                            v_col, v_col, v_rel);
            BEGIN
                EXECUTE v_sql INTO v_ok;
                v_status := CASE WHEN coalesce(v_ok, false) THEN 'PASS' ELSE 'FAIL' END;
                v_detail := CASE WHEN coalesce(v_ok, false)
                                 THEN 'the sort key is unique and is never NULL'
                                 ELSE 'the sort key is not unique, or it is NULL on some rows';
            EXCEPTION WHEN others THEN
                v_status := 'ERROR';
                v_detail := SQLERRM;
            END;
            RETURN QUERY
            SELECT v_n,
                   format('The sort key %s is unique and is never NULL, so the pages do not repeat or skip a row.', v_col),
                   v_sql, 'every row has its own value', v_status, v_detail;
        END IF;

    ------------------------------------------------------------------
    -- SELECT *: the relation still has the columns the rewrite names
    ------------------------------------------------------------------
    ELSIF v_pattern = 'SELECT_STAR' THEN
        SELECT o INTO v_rel
          FROM (SELECT unnest(sta._sql_outer_relations(v_orig)) o) s
         LIMIT 1;
        SELECT m[1] INTO v_list
          FROM regexp_matches(v_new, '\yselect\s+(.*?)\s+from\s', 'i') AS m
         LIMIT 1;
        IF v_list IS NOT NULL THEN
            SELECT array_agg(DISTINCT
                     btrim(regexp_replace(regexp_replace(x, '\s+as\s+.*$', '', 'i'),
                                          '\..*$', ''), E' \t\n\r'))
              INTO v_cols
              FROM unnest(string_to_array(v_list, ',')) x
             WHERE btrim(x, E' \t\n\r') <> '';
        END IF;

        v_n := v_n + 1;
        IF v_rel IS NULL OR v_cols IS NULL THEN
            RETURN QUERY
            SELECT v_n,
                   'The relation still has the columns the rewrite names.',
                   '(the columns of the rewrite could not be read)',
                   'every column is there', 'SKIPPED',
                   'the columns of the rewritten statement could not be found';
        ELSE
            v_sql := format('SELECT count(*) FROM pg_attribute WHERE attrelid = %L::regclass AND attnum > 0 AND NOT attisdropped AND attname = ANY (ARRAY[%s])',
                            v_rel,
                            array_to_string(ARRAY(SELECT quote_literal(c) FROM unnest(v_cols) c), ', '));
            BEGIN
                EXECUTE v_sql INTO v_count;
                v_status := CASE WHEN v_count = array_length(v_cols, 1)
                                 THEN 'PASS' ELSE 'FAIL' END;
                v_detail := format('%s of the %s columns the rewrite names are in %s',
                                   v_count, array_length(v_cols, 1), v_rel);
            EXCEPTION WHEN others THEN
                v_status := 'ERROR';
                v_detail := SQLERRM;
            END;
            RETURN QUERY
            SELECT v_n,
                   'The relation still has the columns the rewrite names.',
                   v_sql, 'every column is there', v_status, v_detail;
        END IF;
    END IF;
END
$$;

COMMENT ON FUNCTION sta.assumption_checks(text, text, text) IS
  'The assumptions a rewrite depends on, checked against the data: the '
  'assumption itself, the check that was made, and whether the check '
  'passed.';

-- The plan change matrix: what each node of the plan became.
CREATE FUNCTION sta._plan_change_matrix(p_before jsonb, p_after jsonb)
RETURNS text[]
LANGUAGE sql
STABLE
AS $$
    WITH b AS (
        SELECT ord, node FROM unnest(sta._plan_node_list(p_before)) WITH ORDINALITY AS t(node, ord)
    ),
    a AS (
        SELECT ord, node FROM unnest(sta._plan_node_list(p_after)) WITH ORDINALITY AS t(node, ord)
    ),
    paired AS (
        SELECT coalesce(b.ord, a.ord) AS ord,
               b.node AS before_node,
               a.node AS after_node
        FROM b FULL JOIN a ON a.ord = b.ord
    )
    SELECT COALESCE(array_agg(
        CASE
            WHEN before_node IS NOT NULL AND after_node IS NOT NULL
                 AND before_node = after_node
                THEN '  ' || before_node
            WHEN before_node IS NOT NULL AND after_node IS NOT NULL
                THEN '  ' || before_node || '  ->  ' || after_node
            WHEN before_node IS NOT NULL
                THEN '  ' || before_node || '  ->  (removed)'
            ELSE '  (added)  ' || after_node
        END ORDER BY ord), ARRAY[]::text[])
    FROM paired
$$;

COMMENT ON FUNCTION sta._plan_change_matrix(jsonb, jsonb) IS
  'The plan change matrix: one line per plan node, showing what the node '
  'became after the change.';

-- The name of the index a plan uses, wherever in the plan it is used.
-- The root node of a plan is not always the node that reads the index: a
-- bitmap index scan, for example, is a child of the bitmap heap scan, so
-- the index name has to be looked for in the whole tree.
CREATE FUNCTION sta._plan_index_name(p_plan jsonb)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_path_query_first(p_plan, '$.**."Index Name"') #>> '{}'
$$;

COMMENT ON FUNCTION sta._plan_index_name(jsonb) IS
  'The name of the index the plan uses, or NULL when the plan reads no '
  'index.';

-- The plan before and after a change.
--
--   p_sql         the statement as the application runs it
--   p_change      the change to apply: a CREATE INDEX statement, an
--                 ANALYZE / VACUUM statement, or the rewritten statement
--   p_change_type AUTO (detect it), CREATE_INDEX, ANALYZE, VACUUM_ANALYZE
--                 or REWRITE
--   p_iterations  how often each plan is measured
--
-- The change is applied in a subtransaction and rolled back afterwards, so
-- the database is left exactly as it was.
-- Measure a statement: the plan, the readable plan, the times and the
-- buffer counts.  Called before and after a change, so that the two
-- measurements are made in exactly the same way.
CREATE FUNCTION sta._measure_plan(p_sql text, p_iterations integer DEFAULT 3)
RETURNS TABLE (
    plan         jsonb,
    plan_text    text,
    avg_ms       double precision,
    best_ms      double precision,
    actual_rows  numeric,
    shared_hit   bigint,
    shared_read  bigint,
    temp_blocks  bigint,
    node_type    text,
    index_name   text,
    signature    text
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_plan  jsonb;
    v_text  text;
    v_root  jsonb;
    v_times double precision[] := ARRAY[]::double precision[];
    i       integer;
BEGIN
    FOR i IN 1..greatest(p_iterations, 1) LOOP
        v_plan := sta.explain(p_sql, true);
        v_times := array_append(v_times,
            COALESCE(NULLIF((v_plan->0)->>'Execution Time', '')::double precision, 0));
        IF i = 1 THEN
            v_root := (v_plan->0)->'Plan';
            v_text := sta._explain_text(p_sql);
        END IF;
    END LOOP;

    RETURN QUERY
    SELECT v_plan,
           v_text,
           (SELECT avg(x) FROM unnest(v_times) AS x),
           (SELECT min(x) FROM unnest(v_times) AS x),
           NULLIF(v_root->>'Actual Rows', '')::numeric,
           COALESCE(NULLIF(v_root->>'Shared Hit Blocks', '')::bigint, 0),
           COALESCE(NULLIF(v_root->>'Shared Read Blocks', '')::bigint, 0),
           COALESCE(NULLIF(v_root->>'Temp Read Blocks', '')::bigint, 0)
             + COALESCE(NULLIF(v_root->>'Temp Written Blocks', '')::bigint, 0),
           v_root->>'Node Type',
           sta._plan_index_name(v_plan),
           sta.plan_signature(v_plan);
END
$$;

COMMENT ON FUNCTION sta._measure_plan(text, integer) IS
  'The plan of a statement, its readable form, the execution times and the '
  'buffer counts, measured the given number of times.';

-- The benefit of the change: one row, with the numbers of both plans.
CREATE FUNCTION sta.plan_before_after(
    p_sql         text,
    p_change      text DEFAULT NULL,
    p_change_type text DEFAULT 'AUTO',
    p_iterations  integer DEFAULT 3
)
RETURNS TABLE (
    phase        text,
    change_type  text,
    change_sql   text,
    statement    text,
    plan_text    text,
    plan         jsonb,
    exec_ms      double precision,
    best_ms      double precision,
    actual_rows  numeric,
    shared_hit   bigint,
    shared_read  bigint,
    temp_blocks  bigint,
    node_type    text,
    index_name   text,
    signature    text,
    notes        text[]
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_type   text;
    v_change text;
    v_stmt   text;
    v_m      record;
    v_notes  text[] := ARRAY[]::text[];
BEGIN
    IF p_sql IS NULL OR btrim(p_sql) = '' THEN
        RAISE EXCEPTION 'sta.plan_before_after: p_sql must not be empty';
    END IF;
    IF p_iterations < 1 OR p_iterations > 100 THEN
        RAISE EXCEPTION 'sta.plan_before_after: p_iterations must be between 1 and 100';
    END IF;

    v_type := upper(btrim(coalesce(p_change_type, 'AUTO')));
    IF v_type NOT IN ('AUTO', 'NONE', 'CREATE_INDEX', 'ANALYZE', 'VACUUM_ANALYZE', 'REWRITE') THEN
        RAISE EXCEPTION 'sta.plan_before_after: unknown change type "%"', p_change_type;
    END IF;

    v_change := p_change;

    IF v_type = 'AUTO' THEN
        IF v_change IS NULL OR btrim(v_change) = '' THEN
            v_type := 'NONE';
        ELSIF v_change ~* '^\s*CREATE\s+(UNIQUE\s+)?INDEX' THEN
            v_type := 'CREATE_INDEX';
        ELSIF v_change ~* '^\s*VACUUM' THEN
            v_type := 'VACUUM_ANALYZE';
        ELSIF v_change ~* '^\s*ANALYZE' THEN
            v_type := 'ANALYZE';
        ELSE
            v_type := 'REWRITE';
        END IF;
    END IF;

    IF v_type <> 'NONE' AND (v_change IS NULL OR btrim(v_change) = '') THEN
        RAISE EXCEPTION 'sta.plan_before_after: p_change must not be empty when the change type is %', v_type;
    END IF;

    IF v_type = 'CREATE_INDEX' THEN
        IF v_change !~* '^\s*CREATE\s+(UNIQUE\s+)?INDEX([[:space:]]|$)' THEN
            RAISE EXCEPTION 'sta.plan_before_after: p_change must be a CREATE [UNIQUE] INDEX statement';
        END IF;
        IF v_change ~* '\yCONCURRENTLY\y' THEN
            RAISE EXCEPTION 'sta.plan_before_after: CREATE INDEX CONCURRENTLY cannot be used here because it cannot run inside a transaction block. Remove CONCURRENTLY; the index is rolled back anyway.';
        END IF;
    END IF;

    ------------------------------------------------------------------
    -- BEFORE: the plan of the statement as the application runs it
    ------------------------------------------------------------------
    v_stmt := p_sql;
    SELECT * INTO v_m FROM sta._measure_plan(v_stmt, p_iterations);

    v_notes := ARRAY['The plan of the statement as the application runs it, '
                     || 'measured ' || p_iterations || ' time(s).'];

    RETURN QUERY
    SELECT 'BEFORE'::text,
           v_type,
           v_change,
           v_stmt,
           v_m.plan_text,
           v_m.plan,
           v_m.avg_ms,
           v_m.best_ms,
           v_m.actual_rows,
           v_m.shared_hit,
           v_m.shared_read,
           v_m.temp_blocks,
           v_m.node_type,
           v_m.index_name,
           v_m.signature,
           v_notes;

    ------------------------------------------------------------------
    -- The change itself
    ------------------------------------------------------------------
    v_notes := ARRAY[]::text[];

    IF v_type = 'NONE' THEN
        -- Nothing to do: measure the same statement again, so that the two
        -- rows show what the measurement noise looks like.
        v_stmt := p_sql;
        v_notes := array_append(v_notes,
            'No change was given, so the same statement was measured again. The difference between the two rows is the measurement noise.');
    ELSIF v_type = 'REWRITE' THEN
        -- The change is the rewritten statement: the "after" plan is the
        -- plan of the new text.
        v_stmt := v_change;
        v_notes := array_append(v_notes,
            'The change is the rewritten statement, so the "after" plan is the plan of the new text.');
    ELSE
        -- The change is applied to the database.  It is rolled back below.
        BEGIN
            IF v_type = 'CREATE_INDEX' THEN
                EXECUTE v_change;
            ELSIF v_type = 'VACUUM_ANALYZE' THEN
                /*
                 * VACUUM cannot run inside a transaction block, so only the
                 * statistics part of it -- which is the part that changes
                 * the plan -- can be measured here.
                 */
                EXECUTE regexp_replace(v_change, '^\s*VACUUM\s*(\([^)]*\))?\s*', 'ANALYZE ', 'i');
                v_notes := array_append(v_notes,
                    'VACUUM cannot run inside a transaction block, so the measurement used the ANALYZE part of the statement: the statistics were refreshed, the dead tuples were not removed.');
            ELSE
                EXECUTE v_change;
            END IF;

            -- The plan with the change in place is measured here, inside the
            -- subtransaction, because the change has to be present while it
            -- is measured.
            SELECT * INTO v_m FROM sta._measure_plan(p_sql, p_iterations);

            RAISE EXCEPTION 'pg_sta_before_after_rollback';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM = 'pg_sta_before_after_rollback' THEN
                    v_notes := array_append(v_notes,
                        'The change was applied in a subtransaction and rolled back; the database is unchanged.');
                ELSE
                    RAISE EXCEPTION 'sta.plan_before_after: the change failed: %', SQLERRM;
                END IF;
        END;
    END IF;

    ------------------------------------------------------------------
    -- AFTER: the plan with the change in place
    ------------------------------------------------------------------
    IF v_type = 'NONE' OR v_type = 'REWRITE' THEN
        -- Either there was no change at all, or the change is the new text
        -- of the statement: measure the statement again.
        SELECT * INTO v_m FROM sta._measure_plan(v_stmt, p_iterations);
    END IF;

    RETURN QUERY
    SELECT 'AFTER'::text,
           v_type,
           v_change,
           v_stmt,
           v_m.plan_text,
           v_m.plan,
           v_m.avg_ms,
           v_m.best_ms,
           v_m.actual_rows,
           v_m.shared_hit,
           v_m.shared_read,
           v_m.temp_blocks,
           v_m.node_type,
           v_m.index_name,
           v_m.signature,
           v_notes;
END
$$;

COMMENT ON FUNCTION sta.plan_before_after(text, text, text, integer) IS
  'The plan of a statement before and after a change, with the execution '
  'times and the buffer counts of both.  The change is applied in a '
  'subtransaction and rolled back, so the database is left unchanged.  The '
  'change may be a CREATE INDEX statement, an ANALYZE or VACUUM statement, '
  'or the rewritten statement.';

CREATE FUNCTION sta.before_after_benefit(
    p_sql         text,
    p_change      text DEFAULT NULL,
    p_change_type text DEFAULT 'AUTO',
    p_iterations  integer DEFAULT 3
)
RETURNS TABLE (
    before_ms       double precision,
    after_ms        double precision,
    improvement_pct double precision,
    before_hit      bigint,
    after_hit       bigint,
    before_read     bigint,
    after_read      bigint,
    buffer_change_pct double precision,
    plan_changed    boolean,
    rows_match      boolean,
    node_changes    text[],
    change_type     text,
    change_sql      text,
    verdict         text,
    notes           text[],
    before_plan     text,
    after_plan      text
)
LANGUAGE plpgsql
AS $$
DECLARE
    r            record;
    v_before     record;
    v_after      record;
    v_b_ms       double precision;
    v_a_ms       double precision;
    v_improve    double precision;
    v_b_hit      bigint;
    v_a_hit      bigint;
    v_b_read     bigint;
    v_a_read     bigint;
    v_buf_pct    double precision;
    v_changed    boolean;
    v_rows_match boolean;
    v_nodes      text[];
    v_verdict    text;
    v_notes      text[] := ARRAY[]::text[];
BEGIN
    FOR r IN
        SELECT * FROM sta.plan_before_after(p_sql, p_change, p_change_type, p_iterations)
    LOOP
        IF r.phase = 'BEFORE' THEN
            v_before := r;
        ELSE
            v_after := r;
        END IF;
    END LOOP;

    IF v_after IS NULL THEN
        RAISE EXCEPTION 'sta.before_after_benefit: the measurement produced no AFTER plan';
    END IF;

    v_b_ms    := v_before.exec_ms;
    v_a_ms    := v_after.exec_ms;
    v_b_hit   := v_before.shared_hit;
    v_a_hit   := v_after.shared_hit;
    v_b_read  := v_before.shared_read;
    v_a_read  := v_after.shared_read;

    v_improve := CASE WHEN v_b_ms > 0 THEN 100.0 * (v_b_ms - v_a_ms) / v_b_ms ELSE 0 END;

    v_buf_pct := CASE
        WHEN (v_b_hit + v_b_read) > 0
            THEN 100.0 * ((v_b_hit + v_b_read) - (v_a_hit + v_a_read)) / (v_b_hit + v_b_read)
        ELSE 0 END;

    v_changed    := (v_before.signature IS DISTINCT FROM v_after.signature);
    v_rows_match := (v_before.actual_rows IS NOT DISTINCT FROM v_after.actual_rows);
    v_nodes      := sta._plan_change_matrix(v_before.plan, v_after.plan);

    v_notes := v_notes || coalesce(v_after.notes, ARRAY[]::text[]);

    IF NOT v_rows_match THEN
        v_verdict := 'NOT_COMPARABLE';
        v_notes := array_append(v_notes,
            'The statement returned a different number of rows before and after, so the two measurements cannot be compared.');
    ELSIF NOT v_changed THEN
        v_verdict := 'NOT_USED';
        v_notes := array_append(v_notes,
            'The plan shape did not change, so the planner did not use the change. The measured difference is noise.');
    ELSIF v_improve >= 5 THEN
        v_verdict := 'RECOMMENDED';
    ELSIF v_improve <= -5 THEN
        v_verdict := 'REJECTED';
    ELSE
        v_verdict := 'NO_SIGNIFICANT_CHANGE';
    END IF;

    RETURN QUERY
    SELECT v_b_ms,
           v_a_ms,
           v_improve,
           v_b_hit,
           v_a_hit,
           v_b_read,
           v_a_read,
           v_buf_pct,
           v_changed,
           v_rows_match,
           v_nodes,
           v_after.change_type,
           v_after.change_sql,
           v_verdict,
           v_notes,
           v_before.plan_text,
           v_after.plan_text;
END
$$;

COMMENT ON FUNCTION sta.before_after_benefit(text, text, text, integer) IS
  'The benefit of a change: the execution time and the buffer counts before '
  'and after, the improvement in percent, the plan change matrix and a '
  'verdict (RECOMMENDED, REJECTED, NO_SIGNIFICANT_CHANGE, NOT_USED or '
  'NOT_COMPARABLE).  Nothing is left in the database: the change is rolled '
  'back.';

------------------------------------------------------------------------------
-- The plan before and after a change, for every statement
--
-- The functions above measure one statement against one change.  The
-- functions below do the same for a whole workload: every statement of the
-- workload is measured against every change the advisor recommends for it,
-- and the plan before and the plan after are returned for each of them.
--
-- A statement that comes from pg_stat_statements is normalised: its
-- literals have been replaced by $n placeholders.  Such a statement cannot
-- be measured, because the values are unknown, so the generic plan is used
-- instead and the estimated cost is what is compared.
------------------------------------------------------------------------------

-- The readable plan of a statement, whatever the statement looks like.
CREATE FUNCTION sta._explain_text_any(p_sql text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    r     record;
    v_out text := '';
    v_sql text;
    v_n   integer;
BEGIN
    v_sql := btrim(p_sql);
    -- EXPLAIN does not accept a trailing semicolon
    IF right(v_sql, 1) = ';' THEN
        v_sql := btrim(left(v_sql, length(v_sql) - 1));
    END IF;

    -- Only statements that return rows can be explained, the same rule that
    -- sta.explain() follows.
    IF v_sql !~* '^\s*(SELECT|WITH|TABLE|VALUES)\y' THEN
        RETURN NULL;
    END IF;

    ------------------------------------------------------------------
    -- The ordinary case: the statement can be run as it is.
    ------------------------------------------------------------------
    BEGIN
        FOR r IN EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) ' || v_sql LOOP
            v_out := v_out || r."QUERY PLAN" || E'\n';
        END LOOP;
        IF v_out <> '' THEN
            RETURN NULLIF(v_out, '');
        END IF;
    EXCEPTION WHEN others THEN
        v_out := '';
    END;

    ------------------------------------------------------------------
    -- The statement uses parameter placeholders, so it cannot be run.
    -- It is explained through a prepared statement with the generic plan,
    -- which is the plan PostgreSQL uses for a statement that is executed
    -- many times with different values.
    ------------------------------------------------------------------
    BEGIN
        EXECUTE 'PREPARE pg_sta_text AS ' || v_sql;
    EXCEPTION WHEN others THEN
        RETURN NULL;
    END;

    -- The number of parameters comes from the server, not from the text:
    -- the server knows how many parameters the statement has.
    SELECT coalesce(array_length(parameter_types, 1), 0)
      INTO v_n
      FROM pg_prepared_statements
     WHERE name = 'pg_sta_text';

    BEGIN
        PERFORM set_config('plan_cache_mode', 'force_generic_plan', true);
        FOR r IN EXECUTE 'EXPLAIN (FORMAT TEXT) EXECUTE pg_sta_text('
                       || repeat('NULL, ', greatest(v_n - 1, 0)) || 'NULL)' LOOP
            v_out := v_out || r."QUERY PLAN" || E'\n';
        END LOOP;
    EXCEPTION WHEN others THEN
        v_out := '';
    END;

    BEGIN
        EXECUTE 'DEALLOCATE pg_sta_text';
    EXCEPTION WHEN others THEN
        NULL;
    END;

    RETURN NULLIF(v_out, '');
END
$$;

COMMENT ON FUNCTION sta._explain_text_any(text) IS
  'The readable plan of a statement.  A statement with parameter '
  'placeholders is explained through a prepared statement with the generic '
  'plan, so that it can be shown as well.';

-- The measurement of a statement that works for a normalised statement as
-- well: when the statement cannot be run, the generic plan is measured and
-- the estimated cost is what is compared.
CREATE FUNCTION sta._measure_plan_any(p_sql text, p_iterations integer)
RETURNS TABLE (
    mode         text,
    plan_text    text,
    plan         jsonb,
    avg_ms       double precision,
    best_ms      double precision,
    est_cost     double precision,
    actual_rows  numeric,
    shared_hit   bigint,
    shared_read  bigint,
    temp_blocks  bigint,
    node_type    text,
    index_name   text,
    signature    text
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_plan  jsonb;
    v_text  text;
    v_root  jsonb;
    v_times double precision[] := ARRAY[]::double precision[];
    v_mode  text;
    i       integer;
BEGIN
    IF p_sql IS NULL OR btrim(p_sql) = '' THEN
        RAISE EXCEPTION 'sta._measure_plan_any: the statement must not be empty';
    END IF;

    ------------------------------------------------------------------
    -- A statement with a parameter placeholder cannot be measured: the
    -- values are unknown, so PostgreSQL refuses to run it.  The generic
    -- plan is used instead, and the estimated cost is what is compared.
    ------------------------------------------------------------------
    BEGIN
        v_plan := sta.explain(p_sql, true);
        v_mode := 'MEASURED';
        v_times := array_append(v_times,
            COALESCE(NULLIF((v_plan->0)->>'Execution Time', '')::double precision, 0));
        v_root := (v_plan->0)->'Plan';
        v_text := sta._explain_text_any(p_sql);
    EXCEPTION WHEN feature_not_supported THEN
        v_plan := sta.explain(p_sql, false);
        v_mode := 'ESTIMATED';
        v_root := (v_plan->0)->'Plan';
        v_text := sta._explain_text_any(p_sql);
    END;

    IF v_mode = 'MEASURED' THEN
        FOR i IN 2..greatest(p_iterations, 1) LOOP
            v_plan := sta.explain(p_sql, true);
            v_times := array_append(v_times,
                COALESCE(NULLIF((v_plan->0)->>'Execution Time', '')::double precision, 0));
        END LOOP;
    END IF;

    RETURN QUERY
    SELECT v_mode,
           v_text,
           v_plan,
           (SELECT avg(x) FROM unnest(v_times) AS x),
           (SELECT min(x) FROM unnest(v_times) AS x),
           COALESCE(NULLIF(v_root->>'Total Cost', '')::double precision, 0),
           NULLIF(v_root->>'Actual Rows', '')::numeric,
           COALESCE(NULLIF(v_root->>'Shared Hit Blocks', '')::bigint, 0),
           COALESCE(NULLIF(v_root->>'Shared Read Blocks', '')::bigint, 0),
           COALESCE(NULLIF(v_root->>'Temp Read Blocks', '')::bigint, 0)
             + COALESCE(NULLIF(v_root->>'Temp Written Blocks', '')::bigint, 0),
           v_root->>'Node Type',
           sta._plan_index_name(v_plan),
           sta.plan_signature(v_plan);
END
$$;

COMMENT ON FUNCTION sta._measure_plan_any(text, integer) IS
  'The measurement of a statement.  A statement that cannot be run, '
  'because it uses parameter placeholders, is measured with its generic '
  'plan; the mode of the measurement is returned with the numbers.';

-- The heaviest statement of the workload that uses a relation.  A change
-- that belongs to a relation rather than to a statement, such as ANALYZE,
-- is measured on that statement.
CREATE FUNCTION sta._action_statement(
    p_window      text    DEFAULT 'window',
    p_object_name text    DEFAULT NULL,
    p_limit       integer DEFAULT 25
)
RETURNS TABLE (
    sql             text,
    queryid         bigint,
    total_exec_time double precision
)
LANGUAGE sql
STABLE
AS $$
    SELECT t.sql, t.queryid, t.total_exec_time
      FROM sta._workload_targets(p_window, LEAST(GREATEST(p_limit, 1), 50)) t
     WHERE p_object_name IS NULL
        OR EXISTS (
            SELECT 1
              FROM unnest(sta._sql_relations(t.sql)) r
             WHERE regexp_replace(r, '^.*\.', '') =
                   regexp_replace(p_object_name, '^.*\.', ''))
     ORDER BY t.total_exec_time DESC, t.calls DESC
     LIMIT 1
$$;

COMMENT ON FUNCTION sta._action_statement(text, text, integer) IS
  'The heaviest statement of the workload that uses a relation.  A change '
  'that belongs to a relation, such as ANALYZE, is measured on it.';

-- One statement against one change: the plan before, the plan after and
-- the benefit of the change.  The change is rolled back.
CREATE FUNCTION sta._measure_change(
    p_sql         text,
    p_change      text,
    p_change_type text,
    p_iterations  integer,
    p_pattern     text DEFAULT NULL
)
RETURNS TABLE (
    measurement       text,
    before_plan       text,
    after_plan        text,
    before_reading    text,
    after_reading     text,
    before_ms         double precision,
    after_ms          double precision,
    before_cost       double precision,
    after_cost        double precision,
    improvement_pct   double precision,
    benefit_basis     text,
    before_buffers    bigint,
    after_buffers     bigint,
    before_hit        bigint,
    before_read       bigint,
    after_hit         bigint,
    after_read        bigint,
    buffer_change_pct double precision,
    before_rows       bigint,
    after_rows        bigint,
    rows_identical    boolean,
    order_preserved   boolean,
    comparison        jsonb,
    assumptions       jsonb,
    plan_changed      boolean,
    rows_match        boolean,
    verdict           text,
    node_changes      text[],
    notes             text[]
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_b         record;
    v_a         record;
    v_type      text;
    v_change    text;
    v_notes     text[] := ARRAY[]::text[];
    v_improve   double precision;
    v_verdict   text;
    v_nodes     text[];
    v_changed   boolean;
    v_rows_ok   boolean;
    v_basis     text;
    v_cmp       jsonb;
    v_identical boolean;
    v_order     boolean;
    v_assume    jsonb := '[]'::jsonb;
    v_pat       text;
    v_pats      text[];
    v_check     record;
    v_buf_pct   double precision;
    v_b_hit     bigint;
    v_b_read    bigint;
    v_a_hit     bigint;
    v_a_read    bigint;
    v_read_b    text;
    v_read_a    text;
BEGIN
    v_type := upper(btrim(coalesce(p_change_type, 'NONE')));
    v_change := p_change;

    IF v_type = 'NONE' THEN
        v_notes := array_append(v_notes,
            'No change was given, so the same statement was measured again. The difference between the two plans is the measurement noise.');
    END IF;

    ------------------------------------------------------------------
    -- BEFORE: the plan of the statement as the application runs it
    ------------------------------------------------------------------
    SELECT * INTO v_b FROM sta._measure_plan_any(p_sql, p_iterations);

    ------------------------------------------------------------------
    -- AFTER: the plan with the change in place
    ------------------------------------------------------------------
    IF v_type = 'REWRITE' THEN
        -- The change is the rewritten statement: the "after" plan is the
        -- plan of the new text.
        SELECT * INTO v_a FROM sta._measure_plan_any(v_change, p_iterations);
        v_notes := array_append(v_notes,
            'The change is the rewritten statement, so the "after" plan is the plan of the new text.');
    ELSIF v_type = 'NONE' THEN
        SELECT * INTO v_a FROM sta._measure_plan_any(p_sql, p_iterations);
    ELSE
        -- The change is applied to the database.  It is rolled back below.
        BEGIN
            IF v_type = 'VACUUM_ANALYZE' THEN
                /*
                 * VACUUM cannot run inside a transaction block, so only the
                 * statistics part of it -- which is the part that changes
                 * the plan -- can be measured here.
                 */
                EXECUTE regexp_replace(v_change, '^\s*VACUUM\s*(\([^)]*\))?\s*', 'ANALYZE ', 'i');
                v_notes := array_append(v_notes,
                    'VACUUM cannot run inside a transaction block, so the measurement used the ANALYZE part of the statement: the statistics were refreshed, the dead tuples were not removed.');
            ELSE
                -- CREATE INDEX CONCURRENTLY cannot run inside a transaction
                -- block either, and the index is rolled back anyway.
                EXECUTE regexp_replace(v_change, '\yCONCURRENTLY\y', '', 'g');
            END IF;

            -- The plan with the change in place is measured here, inside the
            -- subtransaction, because the change has to be present while it
            -- is measured.
            SELECT * INTO v_a FROM sta._measure_plan_any(p_sql, p_iterations);

            RAISE EXCEPTION 'pg_sta_measure_change_rollback';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM = 'pg_sta_measure_change_rollback' THEN
                    v_notes := array_append(v_notes,
                        'The change was applied in a subtransaction and rolled back; the database is unchanged.');
                ELSE
                    RAISE EXCEPTION 'sta._measure_change: the change failed: %', SQLERRM;
                END IF;
        END;
    END IF;

    v_changed := (v_b.signature IS DISTINCT FROM v_a.signature);
    v_rows_ok := (v_b.actual_rows IS NOT DISTINCT FROM v_a.actual_rows);
    v_nodes   := sta._plan_change_matrix(v_b.plan, v_a.plan);

    ------------------------------------------------------------------
    -- The reading of the two plans
    ------------------------------------------------------------------
    v_read_b := sta.plan_explanation(v_b.plan);
    v_read_a := sta.plan_explanation(v_a.plan);

    ------------------------------------------------------------------
    -- The buffers, split into the ones that came from the cache and the
    -- ones that had to be read from the disk
    ------------------------------------------------------------------
    v_b_hit  := v_b.shared_hit;
    v_b_read := v_b.shared_read;
    v_a_hit  := v_a.shared_hit;
    v_a_read := v_a.shared_read;

    ------------------------------------------------------------------
    -- The rows, one by one
    --
    -- Only a rewrite changes what the statement returns.  An index or a
    -- refresh of the statistics leaves the result alone, so there is
    -- nothing to compare for those.
    ------------------------------------------------------------------
    IF v_type = 'REWRITE' THEN
        v_cmp := sta._compare_results(p_sql, v_change);
        IF v_cmp ? 'error' THEN
            v_notes := array_append(v_notes,
                'The rows of the original and of the rewritten statement could not be compared: '
                || (v_cmp->>'error'));
        ELSE
            v_identical := coalesce((v_cmp->>'rows_identical')::boolean, false);
            v_order    := (v_cmp->>'order_preserved')::boolean;
        END IF;

        ------------------------------------------------------------------
        -- The assumptions the rewrite depends on
        ------------------------------------------------------------------
        v_pats := ARRAY(SELECT btrim(x)
                           FROM unnest(string_to_array(coalesce(p_pattern, ''), ',')) x
                          WHERE btrim(x) <> '');
        FOREACH v_pat IN ARRAY v_pats LOOP
            FOR v_check IN SELECT * FROM sta.assumption_checks(v_pat, p_sql, v_change) LOOP
                v_assume := v_assume || jsonb_build_array(jsonb_build_object(
                    'pattern', v_pat,
                    'assumption', v_check.assumption,
                    'check_sql', v_check.check_sql,
                    'expected', v_check.expected,
                    'status', v_check.status,
                    'detail', v_check.detail));
            END LOOP;
        END LOOP;
    END IF;

    ------------------------------------------------------------------
    -- The benefit
    ------------------------------------------------------------------
    IF v_type = 'NONE' THEN
        -- There is no change, so there is no benefit to report.  The
        -- difference between the two measurements is the noise of the
        -- measurement itself, and reporting it as a gain would be wrong.
        v_improve := NULL;
        v_basis   := 'NONE';
    ELSIF v_b.mode = 'MEASURED' AND coalesce(v_b.avg_ms, 0) > 0 THEN
        v_improve := 100.0 * (v_b.avg_ms - v_a.avg_ms) / v_b.avg_ms;
        v_basis   := 'TIME';
        v_notes := array_append(v_notes,
            'The benefit is measured in time: the statement was run several times on both sides and the averages were compared.');
    ELSIF coalesce(v_b.est_cost, 0) > 0 THEN
        -- The statement could not be run, so the estimated cost of the
        -- generic plan is what is compared.
        v_improve := 100.0 * (v_b.est_cost - v_a.est_cost) / v_b.est_cost;
        v_basis   := 'COST';
        v_notes := array_append(v_notes,
            'The statement could not be run, so the benefit is measured in the estimated cost of the plan and not in time.');
    END IF;

    IF (v_b.shared_hit + v_b.shared_read) > 0 THEN
        v_buf_pct := 100.0 * ((v_b.shared_hit + v_b.shared_read)
                              - (v_a.shared_hit + v_a.shared_read))
                     / (v_b.shared_hit + v_b.shared_read);
    END IF;

    IF v_identical IS FALSE THEN
        v_verdict := 'ROWS_DIFFER';
        v_notes := array_append(v_notes,
            'The rewritten statement does not return the same rows as the original, so it cannot be used as it is.');
    ELSIF v_type = 'NONE' THEN
        v_verdict := 'NO_CHANGE_NEEDED';
        v_notes := array_append(v_notes,
            'No change is recommended for this statement, so there is no benefit to report.');
    ELSIF NOT v_rows_ok THEN
        v_verdict := 'NOT_COMPARABLE';
        v_notes := array_append(v_notes,
            'The statement returned a different number of rows before and after, so the two measurements cannot be compared.');
    ELSIF NOT v_changed THEN
        v_verdict := 'NOT_USED';
        v_notes := array_append(v_notes,
            'The plan shape did not change, so the planner did not use the change. The measured difference is noise.');
    ELSIF v_improve IS NULL THEN
        v_verdict := 'NO_SIGNIFICANT_CHANGE';
    ELSIF v_improve >= 5 THEN
        v_verdict := 'RECOMMENDED';
    ELSIF v_improve <= -5 THEN
        v_verdict := 'REJECTED';
    ELSE
        v_verdict := 'NO_SIGNIFICANT_CHANGE';
    END IF;

    RETURN QUERY
    SELECT v_b.mode,
           v_b.plan_text,
           v_a.plan_text,
           v_read_b,
           v_read_a,
           v_b.avg_ms,
           v_a.avg_ms,
           v_b.est_cost,
           v_a.est_cost,
           v_improve,
           v_basis,
           (v_b.shared_hit + v_b.shared_read),
           (v_a.shared_hit + v_a.shared_read),
           v_b_hit,
           v_b_read,
           v_a_hit,
           v_a_read,
           v_buf_pct,
           v_b.actual_rows::bigint,
           v_a.actual_rows::bigint,
           v_identical,
           v_order,
           v_cmp,
           v_assume,
           v_changed,
           v_rows_ok,
           v_verdict,
           v_nodes,
           v_notes;
END
$$;

COMMENT ON FUNCTION sta._measure_change(text, text, text, integer, text) IS
  'The plan of a statement before and after a change, with the benefit of '
  'the change, the reading of the two plans, the comparison of the rows and '
  'the result of the assumption checks.  The change is applied in a '
  'subtransaction and rolled back, so the database is left unchanged.';

-- The full detail of one statement before and after a change.  It is the
-- public face of _measure_change: the change type is worked out from the
-- change itself when it is not given, and the result carries the reading
-- of the two plans, the benefit and the checks.
CREATE FUNCTION sta.before_after_detail(
    p_sql         text,
    p_change      text DEFAULT NULL,
    p_change_type text DEFAULT 'AUTO',
    p_iterations  integer DEFAULT 3
)
RETURNS TABLE (
    statement         text,
    change_type       text,
    change_sql        text,
    measurement       text,
    before_plan       text,
    after_plan        text,
    before_reading    text,
    after_reading     text,
    before_ms         double precision,
    after_ms          double precision,
    before_cost       double precision,
    after_cost        double precision,
    improvement_pct   double precision,
    benefit_basis     text,
    before_buffers    bigint,
    after_buffers     bigint,
    before_hit        bigint,
    before_read       bigint,
    after_hit         bigint,
    after_read        bigint,
    buffer_change_pct double precision,
    before_rows       bigint,
    after_rows        bigint,
    rows_identical    boolean,
    order_preserved   boolean,
    comparison        jsonb,
    assumptions       jsonb,
    plan_changed      boolean,
    rows_match        boolean,
    verdict           text,
    node_changes      text[],
    notes             text[]
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_type   text;
    v_change text;
BEGIN
    v_type := upper(btrim(coalesce(p_change_type, 'AUTO')));
    IF v_type NOT IN ('AUTO', 'NONE', 'CREATE_INDEX', 'ANALYZE',
                       'VACUUM_ANALYZE', 'REWRITE') THEN
        RAISE EXCEPTION 'sta.before_after_detail: unknown change type "%"',
                        p_change_type;
    END IF;

    v_change := p_change;

    IF v_type = 'AUTO' THEN
        IF v_change IS NULL OR btrim(v_change) = '' THEN
            v_type := 'NONE';
        ELSIF v_change ~* '^\s*CREATE\s+(UNIQUE\s+)?INDEX' THEN
            v_type := 'CREATE_INDEX';
        ELSIF v_change ~* '^\s*VACUUM' THEN
            v_type := 'VACUUM_ANALYZE';
        ELSIF v_change ~* '^\s*ANALYZE' THEN
            v_type := 'ANALYZE';
        ELSE
            v_type := 'REWRITE';
        END IF;
    END IF;

    RETURN QUERY
    SELECT p_sql,
           v_type,
           v_change,
           m.measurement,
           m.before_plan,
           m.after_plan,
           m.before_reading,
           m.after_reading,
           m.before_ms,
           m.after_ms,
           m.before_cost,
           m.after_cost,
           m.improvement_pct,
           m.benefit_basis,
           m.before_buffers,
           m.after_buffers,
           m.before_hit,
           m.before_read,
           m.after_hit,
           m.after_read,
           m.buffer_change_pct,
           m.before_rows,
           m.after_rows,
           m.rows_identical,
           m.order_preserved,
           m.comparison,
           m.assumptions,
           m.plan_changed,
           m.rows_match,
           m.verdict,
           m.node_changes,
           m.notes
      FROM sta._measure_change(p_sql, v_change, v_type, p_iterations) m;
END
$$;

COMMENT ON FUNCTION sta.before_after_detail(text, text, text, integer) IS
  'The plan of a statement before and after a change, with the reading of '
  'both plans, the benefit of the change, the comparison of the rows and '
  'the result of the assumption checks.  The change type is worked out '
  'from the change when it is not given.  The change is applied in a '
  'subtransaction and rolled back, so the database is left unchanged.';

-- The plan before and after a change, for every statement of the workload.
CREATE FUNCTION sta.before_after_report(
    p_sql        text    DEFAULT NULL,
    p_window     text    DEFAULT 'window',
    p_iterations integer DEFAULT 3,
    p_limit      integer DEFAULT 10,
    p_statistics boolean DEFAULT true
)
RETURNS TABLE (
    report_id         integer,
    queryid           bigint,
    statement         text,
    relation          text,
    change_type       text,
    change_sql        text,
    measurement       text,
    before_plan       text,
    after_plan        text,
    before_reading    text,
    after_reading     text,
    before_ms         double precision,
    after_ms          double precision,
    before_cost       double precision,
    after_cost        double precision,
    improvement_pct   double precision,
    benefit_basis     text,
    before_buffers    bigint,
    after_buffers     bigint,
    before_hit        bigint,
    before_read       bigint,
    after_hit         bigint,
    after_read        bigint,
    buffer_change_pct double precision,
    before_rows       bigint,
    after_rows        bigint,
    rows_identical    boolean,
    order_preserved   boolean,
    comparison        jsonb,
    assumptions       jsonb,
    plan_changed      boolean,
    rows_match        boolean,
    verdict           text,
    node_changes      text[],
    notes             text[]
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_stmt    record;
    v_act     jsonb;
    v_m       record;
    v_id      integer := 0;
    v_limit   integer;
    v_iters   integer;
    v_window  text;
    v_actions jsonb := '[]'::jsonb;
    v_has     boolean;
BEGIN
    v_limit  := LEAST(GREATEST(p_limit, 1), 50);
    v_iters  := LEAST(GREATEST(p_iterations, 1), 20);
    v_window := lower(coalesce(p_window, 'window'));

    ------------------------------------------------------------------
    -- The changes the advisor recommends
    --
    -- The action plan is asked for more changes than there are
    -- statements: the plan is ordered by priority, so a limit that is
    -- too small would drop every rewrite in favour of the indexes.
    ------------------------------------------------------------------
    FOR v_act IN
        SELECT jsonb_build_object(
                   'action_type', a.action_type,
                   'object_name', a.object_name,
                   'queryid',     a.queryid,
                   'query',       a.query,
                   'finding',     a.finding,
                   'action_sql',  a.action_sql)
          FROM sta.action_plan(p_sql, v_window, false,
                               LEAST(GREATEST(v_limit * 4, 20), 200)) a
    LOOP
        v_actions := v_actions || jsonb_build_array(v_act);
    END LOOP;

    ------------------------------------------------------------------
    -- Every statement of the workload, with the changes that belong to it
    ------------------------------------------------------------------
    FOR v_stmt IN
        SELECT p_sql::text AS sql, NULL::bigint AS queryid
         WHERE p_sql IS NOT NULL
        UNION ALL
        SELECT t.sql, t.queryid
          FROM sta._workload_targets(v_window, v_limit) t
         WHERE p_sql IS NULL
    LOOP
        v_has := false;

        --
        -- The actions are matched to the statement they belong to.  The
        -- query identifier is the reliable key: the text of a rewritten
        -- statement is laid out differently from the text of the
        -- statement it was made from, so the two never match.  A single
        -- statement that was given by the caller has no query
        -- identifier, and then every action that carries a statement
        -- belongs to it.
        --
        FOR v_act IN
            SELECT a.value
              FROM jsonb_array_elements(v_actions) a
             WHERE (v_stmt.queryid IS NOT NULL
                    AND a.value->>'queryid' = v_stmt.queryid::text)
                OR (v_stmt.queryid IS NULL
                    AND a.value->>'queryid' IS NULL
                    AND a.value->>'query' IS NOT NULL)
        LOOP
            v_has := true;

            BEGIN
                SELECT * INTO v_m
                  FROM sta._measure_change(v_stmt.sql,
                                           v_act->>'action_sql',
                                           v_act->>'action_type',
                                           v_iters,
                                           v_act->>'finding');
            EXCEPTION WHEN others THEN
                v_id := v_id + 1;
                RETURN QUERY
                SELECT v_id, v_stmt.queryid, v_stmt.sql,
                       v_act->>'object_name', v_act->>'action_type',
                       v_act->>'action_sql', 'ERROR',
                       NULL::text, NULL::text,
                       NULL::text, NULL::text,
                       NULL::double precision, NULL::double precision,
                       NULL::double precision, NULL::double precision,
                       NULL::double precision,
                       NULL::text,
                       NULL::bigint, NULL::bigint,
                       NULL::bigint, NULL::bigint,
                       NULL::bigint, NULL::bigint,
                       NULL::double precision,
                       NULL::bigint, NULL::bigint,
                       NULL::boolean, NULL::boolean,
                       NULL::jsonb, NULL::jsonb,
                       false, false, 'NOT_MEASURED', ARRAY[]::text[],
                       ARRAY[format('The change could not be measured: %s', SQLERRM)];
                CONTINUE;
            END;

            v_id := v_id + 1;
            RETURN QUERY
            SELECT v_id, v_stmt.queryid, v_stmt.sql,
                   v_act->>'object_name', v_act->>'action_type',
                   v_act->>'action_sql',
                   v_m.measurement, v_m.before_plan, v_m.after_plan,
                   v_m.before_reading, v_m.after_reading,
                   v_m.before_ms, v_m.after_ms,
                   v_m.before_cost, v_m.after_cost,
                   v_m.improvement_pct, v_m.benefit_basis,
                   v_m.before_buffers, v_m.after_buffers,
                   v_m.before_hit, v_m.before_read,
                   v_m.after_hit, v_m.after_read,
                   v_m.buffer_change_pct,
                   v_m.before_rows, v_m.after_rows,
                   v_m.rows_identical, v_m.order_preserved,
                   v_m.comparison, v_m.assumptions,
                   v_m.plan_changed, v_m.rows_match,
                   v_m.verdict, v_m.node_changes, v_m.notes;
        END LOOP;

        -- A statement without a change still gets its plan, so that every
        -- statement of the workload is shown.
        IF NOT v_has THEN
            BEGIN
                SELECT * INTO v_m
                  FROM sta._measure_change(v_stmt.sql, NULL, 'NONE', v_iters);
            EXCEPTION WHEN others THEN
                v_id := v_id + 1;
                RETURN QUERY
                SELECT v_id, v_stmt.queryid, v_stmt.sql,
                       NULL::text, 'NONE', NULL::text, 'ERROR',
                       NULL::text, NULL::text,
                       NULL::text, NULL::text,
                       NULL::double precision, NULL::double precision,
                       NULL::double precision, NULL::double precision,
                       NULL::double precision,
                       NULL::text,
                       NULL::bigint, NULL::bigint,
                       NULL::bigint, NULL::bigint,
                       NULL::bigint, NULL::bigint,
                       NULL::double precision,
                       NULL::bigint, NULL::bigint,
                       NULL::boolean, NULL::boolean,
                       NULL::jsonb, NULL::jsonb,
                       false, false, 'NOT_MEASURED', ARRAY[]::text[],
                       ARRAY[format('The statement could not be measured: %s', SQLERRM)];
                CONTINUE;
            END;

            v_id := v_id + 1;
            RETURN QUERY
            SELECT v_id, v_stmt.queryid, v_stmt.sql,
                   NULL::text, 'NONE', NULL::text,
                   v_m.measurement, v_m.before_plan, v_m.after_plan,
                   v_m.before_reading, v_m.after_reading,
                   v_m.before_ms, v_m.after_ms,
                   v_m.before_cost, v_m.after_cost,
                   v_m.improvement_pct, v_m.benefit_basis,
                   v_m.before_buffers, v_m.after_buffers,
                   v_m.before_hit, v_m.before_read,
                   v_m.after_hit, v_m.after_read,
                   v_m.buffer_change_pct,
                   v_m.before_rows, v_m.after_rows,
                   v_m.rows_identical, v_m.order_preserved,
                   v_m.comparison, v_m.assumptions,
                   v_m.plan_changed, v_m.rows_match,
                   v_m.verdict, v_m.node_changes, v_m.notes;
        END IF;
    END LOOP;

    ------------------------------------------------------------------
    -- The changes that belong to a relation rather than to a statement:
    -- the statistics.  They are measured on the heaviest statement that
    -- uses the relation.
    ------------------------------------------------------------------
    IF p_statistics THEN
        FOR v_act IN
            SELECT a.value
              FROM jsonb_array_elements(v_actions) a
             WHERE a.value->>'query' IS NULL
               AND a.value->>'action_type' IN ('ANALYZE', 'VACUUM_ANALYZE')
        LOOP
            SELECT a.sql, a.queryid INTO v_stmt
              FROM sta._action_statement(v_window, v_act->>'object_name', v_limit) a;

            IF v_stmt.sql IS NULL THEN
                CONTINUE;
            END IF;

            BEGIN
                SELECT * INTO v_m
                  FROM sta._measure_change(v_stmt.sql,
                                           v_act->>'action_sql',
                                           v_act->>'action_type',
                                           v_iters,
                                           v_act->>'finding');
            EXCEPTION WHEN others THEN
                v_id := v_id + 1;
                RETURN QUERY
                SELECT v_id, v_stmt.queryid, v_stmt.sql,
                       v_act->>'object_name', v_act->>'action_type',
                       v_act->>'action_sql', 'ERROR',
                       NULL::text, NULL::text,
                       NULL::text, NULL::text,
                       NULL::double precision, NULL::double precision,
                       NULL::double precision, NULL::double precision,
                       NULL::double precision,
                       NULL::text,
                       NULL::bigint, NULL::bigint,
                       NULL::bigint, NULL::bigint,
                       NULL::bigint, NULL::bigint,
                       NULL::double precision,
                       NULL::bigint, NULL::bigint,
                       NULL::boolean, NULL::boolean,
                       NULL::jsonb, NULL::jsonb,
                       false, false, 'NOT_MEASURED', ARRAY[]::text[],
                       ARRAY[format('The change could not be measured: %s', SQLERRM)];
                CONTINUE;
            END;

            v_id := v_id + 1;
            RETURN QUERY
            SELECT v_id, v_stmt.queryid, v_stmt.sql,
                   v_act->>'object_name', v_act->>'action_type',
                   v_act->>'action_sql',
                   v_m.measurement, v_m.before_plan, v_m.after_plan,
                   v_m.before_reading, v_m.after_reading,
                   v_m.before_ms, v_m.after_ms,
                   v_m.before_cost, v_m.after_cost,
                   v_m.improvement_pct, v_m.benefit_basis,
                   v_m.before_buffers, v_m.after_buffers,
                   v_m.before_hit, v_m.before_read,
                   v_m.after_hit, v_m.after_read,
                   v_m.buffer_change_pct,
                   v_m.before_rows, v_m.after_rows,
                   v_m.rows_identical, v_m.order_preserved,
                   v_m.comparison, v_m.assumptions,
                   v_m.plan_changed, v_m.rows_match,
                   v_m.verdict, v_m.node_changes, v_m.notes;
        END LOOP;
    END IF;
END
$$;

COMMENT ON FUNCTION sta.before_after_report(text, text, integer, integer, boolean) IS
  'The plan before and after a change for every statement of the workload, '
  'with the reading of the two plans, the benefit of the change, the '
  'comparison of the rows and the result of the assumption checks.  Every '
  'change the advisor recommends is measured: the index, the rewrite and '
  'the statistics.  Nothing is left in the database: every change is '
  'rolled back.';

/*
 * The action plan as one script.
 *
 * The script is meant to be read before it is run: every step states why
 * it is there, what it is expected to gain, what it costs and how to
 * check that it worked.
 *
 * When p_plans is true, every step also carries the plan of the statement
 * before the change and the plan after it, with the benefit that the
 * change was measured to give.  The changes are measured in a
 * subtransaction that is rolled back, so the script shows what the change
 * would do without leaving anything behind in the database.
 */
CREATE FUNCTION sta.action_script(
    p_sql        text    DEFAULT NULL,
    p_window     text    DEFAULT 'window',
    p_analyze    boolean DEFAULT false,
    p_limit      integer DEFAULT 50,
    p_plans      boolean DEFAULT true,
    p_iterations integer DEFAULT 3
)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    r      record;
    m      record;
    s      record;
    v_as   record;
    v_out  text;
    v_n    integer := 0;
    v_step text;
    v_val  text;
    v_sql  text;
    v_iters integer;
    v_plan_block text;
BEGIN
    v_iters := LEAST(GREATEST(p_iterations, 1), 20);

    v_out := format(
        E'-- ===========================================================================\n'
     || E'-- pg_sta action script\n'
     || E'-- Generated at %s on database %s\n'
     || E'-- Scope: %s\n'
     || E'--\n'
     || E'-- Read the whole script before you run it.  The order matters: the\n'
     || E'-- statistics come first, because a correct estimate can remove the need\n'
     || E'-- for an index, and the rewritten statements come last, because they\n'
     || E'-- have to be written against the statement the application really runs.\n'
     || E'-- ===========================================================================\n\n',
        now(),
        current_database(),
        CASE WHEN p_sql IS NULL
             THEN format('the %s of the workload', p_window)
             ELSE 'a single statement'
        END);

    IF p_plans THEN
        v_out := v_out
              || format(E'-- Every step below carries the plan of the statement before the\n'
                     || E'-- change and the plan after it.  The change was applied in a\n'
                     || E'-- subtransaction and rolled back, so the database is unchanged.\n'
                     || E'-- A statement that comes from pg_stat_statements uses parameter\n'
                     || E'-- placeholders, so it cannot be run: its generic plan is shown\n'
                     || E'-- instead and the estimated cost is what is compared.\n\n');
    END IF;

    FOR r IN
        SELECT * FROM sta.action_plan(p_sql, p_window, p_analyze, p_limit)
        ORDER BY priority, action_id
    LOOP
        v_n := v_n + 1;
        v_step := format(
            E'-- ---------------------------------------------------------------------------\n'
         || E'-- %s. [%s] %s\n'
         || E'--\n'
         || E'-- Why:     %s\n'
         || E'-- Benefit: %s\n'
         || E'-- Cost:    %s\n'
         || E'-- Risk:    %s\n',
            v_n,
            r.action_type,
            coalesce(r.object_name, r.finding),
            coalesce(r.finding_text, r.rationale),
            coalesce(r.expected_benefit, 'not stated'),
            coalesce(r.estimated_cost, 'not stated'),
            coalesce(r.risk, 'not stated'));

        IF r.action_type = 'REWRITE' THEN
            v_step := v_step
                   || format(E'--\n-- Original statement:\n--   %s\n',
                             replace(coalesce(r.query, ''), E'\n', E'\n--   '));
        ELSE
            v_step := v_step
                   || format(E'--\n-- Command:\n--   %s\n',
                             replace(coalesce(r.action_sql, ''), E'\n', E'\n--   '));
        END IF;

        v_out := v_out || v_step;

        -- The validation steps.
        IF array_length(r.validation_steps, 1) > 0 THEN
            v_out := v_out || E'--\n';
            FOREACH v_val IN ARRAY r.validation_steps LOOP
                v_out := v_out || format(E'--   - %s\n', v_val);
            END LOOP;
        END IF;

        v_out := v_out || E'--\n';

        -- The plan before and after the change.
        IF p_plans THEN
            v_plan_block := '';

            -- The statement the change is measured on: the statement of the
            -- finding, or -- for a change that belongs to a relation, such as
            -- ANALYZE -- the heaviest statement that uses the relation.
            v_sql := r.query;
            IF v_sql IS NULL AND r.action_type IN ('ANALYZE', 'VACUUM_ANALYZE') THEN
                SELECT a.sql INTO v_sql
                  FROM sta._action_statement(p_window, r.object_name, p_limit) a;
            END IF;

            IF v_sql IS NOT NULL THEN
                BEGIN
                    SELECT * INTO m
                      FROM sta._measure_change(v_sql,
                                               r.action_sql,
                                               r.action_type,
                                               v_iters,
                                               r.finding);

                    v_plan_block := format(
                        E'-- Plan before%s:\n--   %s\n'
                     || E'--\n-- Plan after%s:\n--   %s\n'
                     || E'--\n-- Measured: %s\n',
                        CASE WHEN m.measurement = 'MEASURED'
                             THEN ' (measured)'
                             ELSE ' (generic plan, the statement could not be run)'
                        END,
                        coalesce(replace(rtrim(m.before_plan, E'\n'), E'\n', E'\n--   '),
                                 '(no plan)'),
                        CASE WHEN m.measurement = 'MEASURED'
                             THEN ' (measured)'
                             ELSE ' (generic plan, the statement could not be run)'
                        END,
                        coalesce(replace(rtrim(m.after_plan, E'\n'), E'\n', E'\n--   '),
                                 '(no plan)'),
                        CASE WHEN m.measurement = 'MEASURED'
                             THEN format('%s ms before, %s ms after',
                                         round(m.before_ms::numeric, 3),
                                         round(m.after_ms::numeric, 3))
                             ELSE format('estimated cost %s before, %s after',
                                         round(m.before_cost::numeric, 1),
                                         round(m.after_cost::numeric, 1))
                        END);

                    ------------------------------------------------------------------
                    -- The reading of the two plans
                    ------------------------------------------------------------------
                    IF m.before_reading IS NOT NULL THEN
                        v_plan_block := v_plan_block
                                     || format(E'--\n-- Reading of the plan before:\n--   %s\n',
                                               replace(m.before_reading, E'\n', E'\n--   '));
                    END IF;
                    IF m.after_reading IS NOT NULL THEN
                        v_plan_block := v_plan_block
                                     || format(E'--\n-- Reading of the plan after:\n--   %s\n',
                                               replace(m.after_reading, E'\n', E'\n--   '));
                    END IF;

                    ------------------------------------------------------------------
                    -- The benefit, and what it was measured in
                    ------------------------------------------------------------------
                    IF m.improvement_pct IS NOT NULL THEN
                        v_plan_block := v_plan_block
                                     || format(E'--\n-- Gain: %s%% (%s)%s\n',
                                               round(m.improvement_pct::numeric, 1),
                                               CASE WHEN m.benefit_basis = 'TIME'
                                                    THEN 'measured in time'
                                                    WHEN m.benefit_basis = 'COST'
                                                    THEN 'measured in the estimated cost of the plan'
                                                    ELSE 'measured in ' ||
                                                         coalesce(m.benefit_basis, 'an unknown way')
                                               END,
                                               CASE WHEN m.verdict = 'NOT_USED'
                                                    THEN E', but the plan did not change, so the difference is the noise of the measurement'
                                                    WHEN m.verdict = 'NO_SIGNIFICANT_CHANGE'
                                                    THEN E', which is too small to be worth the change'
                                                    ELSE '' END);
                    ELSE
                        v_plan_block := v_plan_block
                                     || E'--\n-- Gain: none (there is no change to measure)\n';
                    END IF;

                    ------------------------------------------------------------------
                    -- The buffers
                    ------------------------------------------------------------------
                    IF m.before_buffers IS NOT NULL THEN
                        v_plan_block := v_plan_block
                                     || format(E'-- Buffers: %s before, %s after',
                                               m.before_buffers, m.after_buffers)
                                     || format(E' (%s hit, %s read before; %s hit, %s read after)%s\n',
                                               m.before_hit, m.before_read,
                                               m.after_hit, m.after_read,
                                               CASE WHEN m.buffer_change_pct IS NOT NULL
                                                    THEN format(', %s%% fewer',
                                                                round(abs(m.buffer_change_pct::numeric), 1))
                                                    ELSE '' END);
                    END IF;

                    ------------------------------------------------------------------
                    -- The rows, one by one
                    ------------------------------------------------------------------
                    IF m.comparison IS NOT NULL AND NOT (m.comparison ? 'error') THEN
                        v_plan_block := v_plan_block
                                     || format(E'--\n-- Rows: %s before, %s after',
                                               m.comparison->>'before_rows',
                                               m.comparison->>'after_rows')
                                     || format(E'; %s rows in both, %s only before, %s only after%s\n',
                                               m.comparison->>'rows_in_both',
                                               m.comparison->>'only_before',
                                               m.comparison->>'only_after',
                                               CASE WHEN coalesce((m.comparison->>'order_comparable')::boolean, false)
                                                    THEN format(', the order is %s',
                                                                CASE WHEN coalesce(m.order_preserved, false)
                                                                     THEN 'the same' ELSE 'not the same' END)
                                                    ELSE ', the order was not compared (the statement has no ORDER BY)'
                                               END);
                    ELSIF m.comparison IS NOT NULL THEN
                        v_plan_block := v_plan_block
                                     || format(E'--\n-- Rows: the two statements could not be compared: %s\n',
                                               m.comparison->>'error');
                    END IF;

                    ------------------------------------------------------------------
                    -- The assumptions the change depends on, and the result of
                    -- every check
                    ------------------------------------------------------------------
                    IF m.assumptions IS NOT NULL
                       AND jsonb_array_length(m.assumptions) > 0 THEN
                        v_plan_block := v_plan_block || E'--\n-- Assumptions:\n';
                        FOR v_as IN SELECT jsonb_array_elements(m.assumptions) AS a LOOP
                            v_plan_block := v_plan_block
                                         || format(E'--   [%s] %s\n',
                                                   coalesce(v_as.a->>'status', '?'),
                                                   v_as.a->>'assumption');
                            IF v_as.a->>'check_sql' IS NOT NULL THEN
                                v_plan_block := v_plan_block
                                             || format(E'--       check:  %s\n',
                                                       replace(v_as.a->>'check_sql', E'\n', E' '));
                            END IF;
                            IF v_as.a->>'expected' IS NOT NULL THEN
                                v_plan_block := v_plan_block
                                             || format(E'--       wanted: %s\n',
                                                       v_as.a->>'expected');
                            END IF;
                            IF v_as.a->>'detail' IS NOT NULL THEN
                                v_plan_block := v_plan_block
                                             || format(E'--       result: %s\n',
                                                       v_as.a->>'detail');
                            END IF;
                        END LOOP;
                    END IF;

                    v_plan_block := v_plan_block
                                 || format(E'-- Verdict: %s\n',
                                           coalesce(m.verdict, 'NOT_MEASURED'));

                    IF array_length(m.node_changes, 1) > 0 THEN
                        v_plan_block := v_plan_block || E'-- Plan changes:\n';
                        FOREACH v_val IN ARRAY m.node_changes LOOP
                            v_plan_block := v_plan_block
                                         || format(E'--   - %s\n', v_val);
                        END LOOP;
                    END IF;

                    FOREACH v_val IN ARRAY m.notes LOOP
                        v_plan_block := v_plan_block
                                     || format(E'-- Note: %s\n', v_val);
                    END LOOP;

                    v_plan_block := v_plan_block || E'--\n';
                EXCEPTION WHEN others THEN
                    v_plan_block := format(
                        E'-- The plan before and after could not be measured: %s\n--\n',
                        SQLERRM);
                END;
            ELSE
                v_plan_block := format(
                    E'-- The plan before and after could not be measured: the statement\n'
                 || E'-- this change belongs to was not found in the workload.\n--\n');
            END IF;

            v_out := v_out || v_plan_block;
        END IF;

        -- The statement itself.
        IF r.action_type = 'REWRITE' THEN
            v_out := v_out
                  || format(E'-- Rewritten statement (%s):\n',
                            coalesce(r.finding, 'REWRITE'));
            IF coalesce(r.action_sql, '') ~ '\$\d+' THEN
                -- The statement uses a parameter placeholder, so it cannot
                -- be run as it is.  It is shown as a comment, with the
                -- instruction that says what the parameter means.
                v_out := v_out
                      || format(E'-- This statement uses a parameter placeholder, so it is shown\n'
                             || E'-- as a comment.  Replace the placeholder with the value the\n'
                             || E'-- application has to pass and run the statement yourself.\n'
                             || E'--\n-- %s\n\n',
                               replace(coalesce(r.action_sql, ''), E'\n', E'\n-- '));
            ELSE
                v_out := v_out
                      || format(E'%s;\n\n',
                                rtrim(coalesce(r.action_sql, ''), '; '));
            END IF;
        ELSE
            v_out := v_out || format(E'%s\n\n', coalesce(r.action_sql, ''));
            IF r.action_type = 'CREATE_INDEX' THEN
                v_out := v_out
                      || E'-- Note: CREATE INDEX CONCURRENTLY cannot run inside a transaction\n'
                      || E'-- block, so run it on its own.\n\n';
            END IF;
        END IF;
    END LOOP;

    IF v_n = 0 THEN
        v_out := v_out
              || E'-- No action was found.  That is not always a problem: the advisor\n'
              || E'-- can only act on what it has seen.  Collect a snapshot of the\n'
              || E'-- workload first (sta.collect()), run the statements again, and\n'
              || E'-- ask a second time.\n';
    END IF;

    RETURN v_out;
END
$$;

COMMENT ON FUNCTION sta.action_script(text, text, boolean, integer, boolean, integer) IS
  'The action plan as one commented script that can be reviewed and then run. '
  'With p_plans, every step carries the plan of the statement before the '
  'change and the plan after it, with the measured gain.';
------------------------------------------------------------------------------
-- Statement identifiers, the Oracle way
--
-- Oracle identifies a statement with SQL_ID (a hash of the exact text) and
-- SQL_HASH (a hash of the text with the literals replaced).  PostgreSQL has
-- no equivalent of SQL_ID: pg_stat_statements only keeps the query id of
-- the *normalised* statement, so two statements that differ only in their
-- literals share one id.  pg_sta adds the missing half.
------------------------------------------------------------------------------

-- The Oracle style SQL_ID: a stable id for the exact text of the statement.
CREATE FUNCTION sta.sql_id(p_sql text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_hash bigint;
BEGIN
    IF p_sql IS NULL OR btrim(p_sql) = '' THEN
        RAISE EXCEPTION 'sta.sql_id: p_sql must not be empty';
    END IF;

    v_hash := hashtextextended(p_sql, 0);

    -- Oracle shows the id as a positive number of up to ten digits.
    RETURN lpad((((v_hash % 10000000000) + 10000000000) % 10000000000)::bigint::text, 10, '0');
END
$$;

COMMENT ON FUNCTION sta.sql_id(text) IS
  'An Oracle style SQL_ID for the exact text of a statement: a stable id '
  'that changes when the text changes.  It fills the gap that PostgreSQL '
  'leaves open, because pg_stat_statements only identifies the normalised '
  'statement.';

-- The Oracle style SQL_HASH: a hash of the statement text with every
-- literal replaced by a placeholder, which is the text PostgreSQL uses to
-- compute the query id.
CREATE FUNCTION sta.sql_hash(p_sql text)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_norm text;
BEGIN
    IF p_sql IS NULL OR btrim(p_sql) = '' THEN
        RAISE EXCEPTION 'sta.sql_hash: p_sql must not be empty';
    END IF;

    v_norm := upper(sta.queryid_normalized(p_sql));
    RETURN hashtextextended(v_norm, 0);
END
$$;

COMMENT ON FUNCTION sta.sql_hash(text) IS
  'An Oracle style SQL_HASH: a hash of the statement text with every literal '
  'replaced by a placeholder.';

-- Everything that identifies a statement, in one row.
CREATE FUNCTION sta.queryid_info(p_sql text)
RETURNS TABLE (
    queryid            bigint,
    sql_id             text,
    sql_hash           bigint,
    normalized_sql     text,
    recorded_sql       text,
    in_stat_statements boolean,
    calls              bigint,
    total_exec_time    double precision,
    mean_exec_time     double precision,
    shared_blks_hit    bigint,
    shared_blks_read   bigint
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_queryid   bigint;
    v_norm      text;
    v_recorded  text;
    v_schema    text;
    v_calls     bigint := 0;
    v_total     double precision := 0;
    v_mean      double precision := 0;
    v_hit       bigint := 0;
    v_read      bigint := 0;
    v_found     boolean := false;
BEGIN
    IF p_sql IS NULL OR btrim(p_sql) = '' THEN
        RAISE EXCEPTION 'sta.queryid_info: p_sql must not be empty';
    END IF;

    v_queryid  := sta.queryid(p_sql);
    v_norm     := sta.queryid_normalized(p_sql);
    v_recorded := sta.statement_text(v_queryid);

    SELECT n.nspname INTO v_schema
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = 'pg_stat_statements' AND c.relkind IN ('v', 'm')
    ORDER BY n.nspname
    LIMIT 1;

    IF v_schema IS NOT NULL THEN
        EXECUTE format(
            'SELECT count(*)::bigint, sum(total_exec_time)::double precision, '
            'avg(mean_exec_time)::double precision, sum(shared_blks_hit)::bigint, '
            'sum(shared_blks_read)::bigint '
            'FROM %I.pg_stat_statements WHERE queryid = $1', v_schema)
        INTO v_calls, v_total, v_mean, v_hit, v_read
        USING v_queryid;
        v_found := (v_calls > 0);
    END IF;

    RETURN QUERY
    SELECT v_queryid,
           sta.sql_id(p_sql),
           hashtextextended(upper(v_norm), 0),
           v_norm,
           v_recorded,
           v_found,
           v_calls,
           v_total,
           v_mean,
           v_hit,
           v_read;
END
$$;

COMMENT ON FUNCTION sta.queryid_info(text) IS
  'Every identifier of a statement in one row: the PostgreSQL query id '
  '(the one pg_stat_statements uses), the Oracle style SQL_ID of the exact '
  'text, the Oracle style SQL_HASH of the normalised text, the normalised '
  'text itself and the measurements of the statement.';

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
    rewrite_rows AS (
        SELECT * FROM sta.rewrite_advice(v_text)
    ),
    index_rows AS (
        SELECT * FROM sta.index_advice(v_text)
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
        UNION ALL
        SELECT rw.category, rw.severity, rw.confidence, rw.impact_score, rw.object_name,
               rw.finding, rw.finding_text, rw.evidence, rw.recommendation, rw.expected_benefit,
               rw.estimated_cost, rw.validation_steps
        FROM rewrite_rows rw
        UNION ALL
        SELECT 'index'::text, 'HIGH'::text, i.confidence, 75::integer, i.relation,
               'MISSING_INDEX'::text, i.rationale,
               jsonb_build_object('relation', i.relation,
                                  'columns', to_jsonb(i.columns),
                                  'suggested_ddl', i.suggested_ddl),
               i.suggested_ddl, i.estimated_benefit, i.estimated_cost, i.validation_steps
        FROM index_rows i
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
  'All findings that relate to one statement: plan, workload, relation statistics and rewrites.';

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
      ('statistics', 'NEVER_VACUUMED', 'LOW',
       'The relation has dead tuples but has never been vacuumed, so its visibility map is still empty.',
       'pg_stat_all_tables.last_vacuum / last_autovacuum',
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
       'Review the index; drop it only if it stays unused over several windows.', 'index'),
      ('rewrite', 'SELECT_STAR', 'MEDIUM',
       'The statement reads every column of the relation, including the columns it does not use.',
       'The text of the statement (SELECT *) and pg_attribute',
       'Name the columns the statement uses.', 'rewrite'),
      ('rewrite', 'OR_TO_IN', 'MEDIUM',
       'The statement tests the same column twice with an OR, which the planner cannot serve with one index lookup.',
       'The text of the statement (col = a OR col = b)',
       'Use an IN list on the column.', 'rewrite'),
      ('rewrite', 'NOT_IN_TO_NOT_EXISTS', 'MEDIUM',
       'The statement uses NOT IN with a subquery, which is evaluated as a hashed anti-join over the whole subquery.',
       'The text of the statement (NOT IN (SELECT ...))',
       'Rewrite the predicate as NOT EXISTS, after checking the NULL semantics.', 'rewrite'),
      ('rewrite', 'NON_SARGABLE_PREDICATE', 'HIGH',
       'A function is applied to the filtered column, so an index on that column cannot be used.',
       'The text of the statement (lower(col) = ... , date(col) = ...)',
       'Compare the column directly, or index the expression.', 'rewrite'),
      ('rewrite', 'IMPLICIT_CAST', 'HIGH',
       'The filtered column is cast to text, so an index on the column cannot be used.',
       'The text of the statement (col::text = ...)',
       'Compare the column with a literal of its own type.', 'rewrite'),
      ('rewrite', 'LEADING_WILDCARD_LIKE', 'HIGH',
       'The pattern starts with a wildcard, so a B-tree index on the column cannot be used.',
       'The text of the statement (col LIKE ''%x%'')',
       'Create a trigram index on the column with pg_trgm.', 'rewrite'),
      ('rewrite', 'UNION_TO_UNION_ALL', 'LOW',
       'The statement joins two branches with UNION, so the duplicates have to be removed.',
       'The text of the statement (UNION without ALL)',
       'Use UNION ALL when the branches cannot produce the same row.', 'rewrite'),
      ('rewrite', 'OFFSET_PAGINATION', 'MEDIUM',
       'The statement skips rows with OFFSET, so the cost of a page grows with its depth.',
       'The text of the statement (LIMIT n OFFSET m)',
       'Page with a keyset condition on the sort key.', 'rewrite')
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
               END AS child_alias,
               -- The relation that is built into the hash table, when the
               -- node has one.  A hash join is named after that relation,
               -- because that is the one that gets hashed.
               (SELECT hashed.alias
                  FROM (
                        SELECT COALESCE(hc.node->'Plans'->0->>'Alias',
                                        hc.node->'Plans'->0->>'Relation Name') AS alias
                          FROM jsonb_array_elements(
                                   CASE WHEN jsonb_typeof(t.node->'Plans') = 'array'
                                        THEN t.node->'Plans' ELSE '[]'::jsonb END
                                 ) AS hc(node)
                         WHERE hc.node->>'Node Type' = 'Hash'
                         LIMIT 1
                       ) AS hashed
                 WHERE hashed.alias IS NOT NULL
               ) AS hash_alias
        FROM tree t
        WHERE t.node IS NOT NULL
    ),
    numbered AS (
        -- The window function is only meaningful for the nodes that name a
        -- relation, but the rows must not be filtered here: a join or a
        -- gather node has no relation of its own and would be lost, and
        -- with it the HASH_JOIN(), MERGE_JOIN(), NESTED_LOOP_PLAIN(),
        -- GATHER() and GATHER_MERGE() advice of the plan.
        SELECT n.*,
               count(*) OVER (PARTITION BY n.rel_alias ORDER BY n.path) AS occurrence
        FROM nodes n
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
                 WHEN 'Hash Join'        THEN 'HASH_JOIN(' || coalesce(nullif(hash_alias, ''), child_alias) || ')'
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
    v_reported text[] := '{}';
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

            -- The same tag may appear more than once in one advice string
            -- (one item per relation, for example).  Report each distinct
            -- setting once, so that the list describes the settings that
            -- were changed rather than the items that were parsed.
            IF NOT (v_item.tag || ':' || v_guc.guc_name || '=' || v_guc.guc_value
                    = ANY (v_reported)) THEN
                v_applied := array_append(v_applied,
                                          v_item.tag || ':' || v_guc.guc_name || '=' || v_guc.guc_value);
                v_reported := v_reported
                             || (v_item.tag || ':' || v_guc.guc_name || '=' || v_guc.guc_value);
            END IF;
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
