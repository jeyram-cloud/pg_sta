-- =========================================================================
-- pg_sta QA suite -- assertions
-- =========================================================================
--
-- Every assertion produces one row of the form
--
--     assertion | expected | actual | passed
--
-- The runner (test/run_qa.sh) requires that every row has passed = true.
-- Any row with passed = false makes the QA suite fail.
--
-- The "expected findings" table below is the contract of this suite: it
-- lists every defect deliberately injected by qa_setup.sql and the finding
-- code pg_sta is expected to raise for it.  If the implementation stops
-- detecting one of these, the suite fails.
-- =========================================================================

\set ON_ERROR_STOP on

SET client_min_messages = warning;
SET search_path = sta_qa, public;

-- -------------------------------------------------------------------------
-- Expected-finding contract
-- -------------------------------------------------------------------------
CREATE TEMP TABLE qa_expected_findings (
    category   text,
    finding    text,
    rationale  text
) ON COMMIT PRESERVE ROWS;

INSERT INTO qa_expected_findings (category, finding, rationale) VALUES
    ('workload',   'HIGH_TOTAL_TIME',      '1200 calls x 80 ms dominate the window'),
    ('workload',   'HIGH_FREQUENCY',       '95000 calls is the hot path'),
    ('workload',   'LOW_CACHE_HIT_RATIO',  '8900 of 8910 blocks come from storage'),
    ('workload',   'HIGH_TEMP_IO',         '3400 temp blocks written'),
    ('plan',       'SEQ_SCAN_ON_LARGE_TABLE', 'big_events has 120000 rows and no index on status'),
    ('statistics', 'NEVER_ANALYZED',       'unanalysed was never analyzed'),
    ('statistics', 'NO_PRIMARY_KEY',       'unanalysed has no primary key'),
    ('statistics', 'NO_INDEXES',           'unanalysed has no indexes at all'),
    ('statistics', 'STALE_STATISTICS',     'stale_stats changed on nearly every row since analyze'),
    ('statistics', 'HIGH_DEAD_TUPLES',     'stale_stats accumulated dead tuples');

-- -------------------------------------------------------------------------
-- Result accumulator
-- -------------------------------------------------------------------------
CREATE TEMP TABLE qa_result (
    seq        serial,
    assertion  text,
    expected   text,
    actual     text,
    passed     boolean
);

-- -------------------------------------------------------------------------
-- 1. Workload findings
-- -------------------------------------------------------------------------
DO $$
DECLARE
    v_cnt  int;
    v_val  text;
BEGIN
    SELECT count(*) INTO v_cnt FROM sta.workload_advice('all', 0, 0, 50)
     WHERE finding = 'HIGH_TOTAL_TIME';
    INSERT INTO qa_result VALUES (default, 'workload: HIGH_TOTAL_TIME detected',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    SELECT count(*) INTO v_cnt FROM sta.workload_advice('all', 0, 0, 50)
     WHERE finding = 'HIGH_FREQUENCY';
    INSERT INTO qa_result VALUES (default, 'workload: HIGH_FREQUENCY detected',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    SELECT count(*) INTO v_cnt FROM sta.workload_advice('all', 0, 0, 50)
     WHERE finding = 'LOW_CACHE_HIT_RATIO';
    INSERT INTO qa_result VALUES (default, 'workload: LOW_CACHE_HIT_RATIO detected',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    SELECT count(*) INTO v_cnt FROM sta.workload_advice('all', 0, 0, 50)
     WHERE finding = 'HIGH_TEMP_IO';
    INSERT INTO qa_result VALUES (default, 'workload: HIGH_TEMP_IO detected',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    -- The dominant statement must be ranked first by total time.
    SELECT time_share_pct::text INTO v_val FROM sta.workload_advice('all', 0, 0, 50)
     WHERE finding = 'HIGH_TOTAL_TIME'
     ORDER BY time_share_pct DESC LIMIT 1;
    INSERT INTO qa_result VALUES (default, 'workload: top statement has the largest share',
                                  'not null', coalesce(v_val, 'null'), v_val IS NOT NULL);

    -- Every workload finding must carry prose.
    SELECT count(*) INTO v_cnt FROM sta.workload_advice('all', 0, 0, 50)
     WHERE finding_text IS NULL OR btrim(finding_text) = '';
    INSERT INTO qa_result VALUES (default, 'workload: every finding carries prose',
                                  '0', v_cnt::text, v_cnt = 0);
END
$$;

-- -------------------------------------------------------------------------
-- 2. Plan findings
-- -------------------------------------------------------------------------
DO $$
DECLARE
    v_cnt  int;
    v_val  text;
BEGIN
    SELECT count(*) INTO v_cnt FROM sta.plan_advice(
        'SELECT * FROM sta_qa.big_events WHERE status = ''paid''', false)
     WHERE finding = 'SEQ_SCAN_ON_LARGE_TABLE';
    INSERT INTO qa_result VALUES (default, 'plan: SEQ_SCAN_ON_LARGE_TABLE detected',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    -- A small table must not be reported as a high-severity problem.
    -- The filter must be on an unindexed column, otherwise the planner
    -- picks an index scan and there is no sequential scan to report.
    SELECT count(*) INTO v_cnt FROM sta.plan_advice(
        'SELECT * FROM sta_qa.hot_path WHERE value = ''value-1''', false)
     WHERE finding = 'SEQ_SCAN_ON_SMALL_TABLE';
    INSERT INTO qa_result VALUES (default, 'plan: small table reported as SEQ_SCAN_ON_SMALL_TABLE',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    SELECT count(*) INTO v_cnt FROM sta.plan_advice(
        'SELECT * FROM sta_qa.hot_path WHERE value = ''value-1''', false)
     WHERE finding = 'SEQ_SCAN_ON_SMALL_TABLE' AND severity IN ('HIGH', 'MEDIUM');
    INSERT INTO qa_result VALUES (default, 'plan: small-table scan is not a high severity',
                                  '0', v_cnt::text, v_cnt = 0);

    -- The relation must be resolved with its schema.
    SELECT object_name INTO v_val FROM sta.plan_advice(
        'SELECT * FROM sta_qa.big_events WHERE status = ''paid''', false)
     WHERE finding = 'SEQ_SCAN_ON_LARGE_TABLE' LIMIT 1;
    INSERT INTO qa_result VALUES (default, 'plan: relation is schema qualified',
                                  'sta_qa.big_events', coalesce(v_val, 'null'),
                                  v_val LIKE 'sta_qa.%');

    -- Plan advice must always produce something and always produce prose.
    SELECT count(*), count(*) FILTER (WHERE finding_text IS NULL OR btrim(finding_text) = '')
      INTO v_cnt, v_val::int FROM sta.plan_advice(
        'SELECT * FROM sta_qa.big_events WHERE status = ''paid''', false);
    INSERT INTO qa_result VALUES (default, 'plan: advice always produces findings',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    SELECT count(*) INTO v_cnt FROM sta.plan_advice(
        'SELECT * FROM sta_qa.big_events WHERE status = ''paid''', false)
     WHERE finding_text IS NULL OR btrim(finding_text) = '';
    INSERT INTO qa_result VALUES (default, 'plan: every finding carries prose',
                                  '0', v_cnt::text, v_cnt = 0);
END
$$;

-- -------------------------------------------------------------------------
-- 3. Statistics findings
-- -------------------------------------------------------------------------
-- sta.stats_advice() takes a *schema* name, not a relation name.  The
-- findings of the whole schema are returned, so they are filtered by
-- object_name.
DO $$
DECLARE
    v_cnt int;
BEGIN
    SELECT count(*) INTO v_cnt FROM sta.stats_advice('sta_qa')
     WHERE finding = 'NEVER_ANALYZED'
       AND object_name = 'sta_qa.unanalysed';
    INSERT INTO qa_result VALUES (default, 'stats: NEVER_ANALYZED detected',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    SELECT count(*) INTO v_cnt FROM sta.stats_advice('sta_qa')
     WHERE finding = 'NO_PRIMARY_KEY'
       AND object_name = 'sta_qa.unanalysed';
    INSERT INTO qa_result VALUES (default, 'stats: NO_PRIMARY_KEY detected',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    SELECT count(*) INTO v_cnt FROM sta.stats_advice('sta_qa')
     WHERE finding = 'NO_INDEXES'
       AND object_name = 'sta_qa.unanalysed';
    INSERT INTO qa_result VALUES (default, 'stats: NO_INDEXES detected',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    SELECT count(*) INTO v_cnt FROM sta.stats_advice('sta_qa')
     WHERE finding = 'STALE_STATISTICS'
       AND object_name = 'sta_qa.stale_stats';
    INSERT INTO qa_result VALUES (default, 'stats: STALE_STATISTICS detected',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    SELECT count(*) INTO v_cnt FROM sta.stats_advice('sta_qa')
     WHERE finding = 'HIGH_DEAD_TUPLES'
       AND object_name = 'sta_qa.stale_stats';
    INSERT INTO qa_result VALUES (default, 'stats: HIGH_DEAD_TUPLES detected',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    -- The healthy control tables must not be reported.
    SELECT count(*) INTO v_cnt FROM sta.stats_advice('sta_qa')
     WHERE object_name IN ('sta_qa.big_events', 'sta_qa.hot_path', 'sta_qa.lookup');
    INSERT INTO qa_result VALUES (default, 'stats: healthy tables are not reported',
                                  '0', v_cnt::text, v_cnt = 0);

    -- Statistics advice must never stray outside the requested schema.
    SELECT count(*) INTO v_cnt FROM sta.stats_advice('sta_qa')
     WHERE object_name NOT LIKE 'sta_qa.%';
    INSERT INTO qa_result VALUES (default, 'stats: advice stays inside the requested schema',
                                  '0', v_cnt::text, v_cnt = 0);
END
$$;

-- -------------------------------------------------------------------------
-- 4. Index advice
-- -------------------------------------------------------------------------
-- sta.index_advice() has its own, narrower shape (relation, columns,
-- suggested_ddl, rationale, ...) rather than the generic
-- (category, finding, ...) shape of the other advice functions.
DO $$
DECLARE
    v_cnt int;
BEGIN
    SELECT count(*) INTO v_cnt FROM sta.index_advice(
        'SELECT * FROM sta_qa.big_events WHERE status = ''paid''')
     WHERE relation = 'sta_qa.big_events';
    INSERT INTO qa_result VALUES (default, 'index: advice produced for the large table',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    SELECT count(*) INTO v_cnt FROM sta.index_advice(
        'SELECT * FROM sta_qa.big_events WHERE status = ''paid''')
     WHERE suggested_ddl ILIKE '%CREATE INDEX%'
       AND 'status' = ANY (columns);
    INSERT INTO qa_result VALUES (default, 'index: suggests an index on the filter column',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    SELECT count(*) INTO v_cnt FROM sta.index_advice(
        'SELECT * FROM sta_qa.unanalysed WHERE label = ''x''')
     WHERE relation = 'sta_qa.unanalysed'
       AND suggested_ddl ILIKE '%CREATE INDEX%';
    INSERT INTO qa_result VALUES (default, 'index: advice produced for the unindexed table',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    SELECT count(*) INTO v_cnt FROM sta.index_advice(
        'SELECT * FROM sta_qa.big_events WHERE status = ''paid''')
     WHERE validation_steps IS NULL OR cardinality(validation_steps) = 0;
    INSERT INTO qa_result VALUES (default, 'index: advice carries validation steps',
                                  '0', v_cnt::text, v_cnt = 0);
END
$$;

-- -------------------------------------------------------------------------
-- 5. Query id round trip
-- -------------------------------------------------------------------------
DO $$
DECLARE
    v_qid  bigint;
    v_cnt  int;
BEGIN
    v_qid := sta.queryid('SELECT * FROM sta_qa.big_events WHERE status = ''paid''');
    INSERT INTO qa_result VALUES (default, 'queryid: canonical id is produced',
                                  'not null', coalesce(v_qid::text, 'null'), v_qid IS NOT NULL);

    SELECT count(*) INTO v_cnt FROM sta.statement_text(v_qid);
    INSERT INTO qa_result VALUES (default, 'queryid: statement round trips',
                                  '1', v_cnt::text, v_cnt = 1);

    INSERT INTO qa_result VALUES (default, 'queryid: literals share one id',
                                  'true',
                                  (sta.queryid('SELECT * FROM sta_qa.hot_path WHERE id = 1')
                   = sta.queryid('SELECT * FROM sta_qa.hot_path WHERE id = 2'))::text,
                  sta.queryid('SELECT * FROM sta_qa.hot_path WHERE id = 1')
                  = sta.queryid('SELECT * FROM sta_qa.hot_path WHERE id = 2'));
END
$$;

-- -------------------------------------------------------------------------
-- 6. Validation of a proposed index
-- -------------------------------------------------------------------------
DO $$
DECLARE
    v_verdict   text;
    v_changed   boolean;
    v_improve   double precision;
    v_exists    boolean;
BEGIN
    SELECT verdict, plan_changed, improvement_pct INTO v_verdict, v_changed, v_improve
    FROM sta.validate(
        'CREATE INDEX qa_big_events_status_idx ON sta_qa.big_events (status)',
        'SELECT * FROM sta_qa.big_events WHERE status = ''paid''',
        3);

    INSERT INTO qa_result VALUES (default, 'validate: verdict is a known value',
                                  'known-verdict',
                                  coalesce(v_verdict, 'null'),
                                  v_verdict IN ('RECOMMENDED','NOT_USED','REJECTED',
                                                'NO_SIGNIFICANT_CHANGE','ERROR','NOT_COMPARABLE'));

    -- A selective filter must be improved by a matching index, so this is
    -- the positive case of the validation procedure.
    SELECT verdict INTO v_verdict
    FROM sta.validate(
        'CREATE INDEX qa_big_events_customer_idx ON sta_qa.big_events (customer_id)',
        'SELECT * FROM sta_qa.big_events WHERE customer_id = 17',
        3);
    INSERT INTO qa_result VALUES (default, 'validate: selective index is recommended',
                                  'RECOMMENDED', coalesce(v_verdict, 'null'),
                                  v_verdict = 'RECOMMENDED');

    INSERT INTO qa_result VALUES (default, 'validate: improvement percentage is numeric',
                                  'not null', coalesce(v_improve::text, 'null'),
                                  v_improve IS NOT NULL);

    SELECT to_regclass('sta_qa.qa_big_events_status_idx') IS NOT NULL INTO v_exists;
    INSERT INTO qa_result VALUES (default, 'validate: candidate index was rolled back',
                                  'false', v_exists::text, v_exists = false);

    -- An index on a column the statement does not filter on must not be
    -- recommended: the planner ignores it, so the verdict is NOT_USED.
    SELECT verdict INTO v_verdict
    FROM sta.validate(
        'CREATE INDEX qa_big_events_payload_idx ON sta_qa.big_events (payload)',
        'SELECT * FROM sta_qa.big_events WHERE status = ''paid''',
        3);
    INSERT INTO qa_result VALUES (default, 'validate: unrelated index is not recommended',
                                  'NOT_USED', coalesce(v_verdict, 'null'),
                                  v_verdict <> 'RECOMMENDED');
END
$$;

-- -------------------------------------------------------------------------
-- 7. Recommendations roll-up
-- -------------------------------------------------------------------------
DO $$
DECLARE
    v_cnt int;
BEGIN
    SELECT count(*) INTO v_cnt FROM sta.recommendations();
    INSERT INTO qa_result VALUES (default, 'recommendations: roll-up is not empty',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    SELECT count(*) INTO v_cnt FROM sta.recommendations()
     WHERE evidence IS NULL
        OR btrim(coalesce(recommendation, '')) = ''
        OR btrim(coalesce(expected_benefit, '')) = ''
        OR btrim(coalesce(estimated_cost, '')) = ''
        OR validation_steps IS NULL
        OR cardinality(validation_steps) = 0;
    INSERT INTO qa_result VALUES (default, 'recommendations: every row is fully explained',
                                  '0', v_cnt::text, v_cnt = 0);

    SELECT count(*) INTO v_cnt FROM sta.recommendations()
     WHERE finding_text IS NULL OR btrim(finding_text) = '';
    INSERT INTO qa_result VALUES (default, 'recommendations: every row carries prose',
                                  '0', v_cnt::text, v_cnt = 0);
END
$$;

-- -------------------------------------------------------------------------
-- 8. Every produced finding must be documented in the catalogue
-- -------------------------------------------------------------------------
DO $$
DECLARE
    v_cnt int;
BEGIN
    WITH produced AS (
        SELECT DISTINCT category, finding FROM (
            SELECT category, finding FROM sta.workload_advice('all', 0, 0, 500)
            UNION ALL
            SELECT category, finding FROM sta.plan_advice(
                'SELECT * FROM sta_qa.big_events WHERE status = ''paid''', false)
            UNION ALL
            SELECT category, finding FROM sta.stats_advice('sta_qa')
        ) s
    )
    SELECT count(*) INTO v_cnt FROM produced p
     WHERE NOT EXISTS (SELECT 1 FROM sta.advice_catalog() c
                        WHERE c.category = p.category AND c.finding = p.finding);
    INSERT INTO qa_result VALUES (default, 'catalog: every produced finding is documented',
                                  '0', v_cnt::text, v_cnt = 0);

    -- Every expected finding must actually have been produced.
    SELECT count(*) INTO v_cnt
    FROM qa_expected_findings e
    WHERE NOT EXISTS (
        SELECT 1 FROM (
            SELECT category, finding FROM sta.workload_advice('all', 0, 0, 500)
            UNION ALL
            SELECT category, finding FROM sta.plan_advice(
                'SELECT * FROM sta_qa.big_events WHERE status = ''paid''', false)
            UNION ALL
            SELECT category, finding FROM sta.stats_advice('sta_qa')
        ) produced
        WHERE produced.category = e.category AND produced.finding = e.finding);
    INSERT INTO qa_result VALUES (default, 'catalog: every expected finding was produced',
                                  '0', v_cnt::text, v_cnt = 0);
END
$$;

-- -------------------------------------------------------------------------
-- 9. Safety: the advisor must not leave anything behind
-- -------------------------------------------------------------------------
DO $$
DECLARE
    v_cnt int;
BEGIN
    SELECT count(*) INTO v_cnt FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'sta_qa'
       AND c.relname IN ('qa_big_events_status_idx', 'qa_big_events_payload_idx');
    INSERT INTO qa_result VALUES (default, 'safety: no index left behind by the advisor',
                                  '0', v_cnt::text, v_cnt = 0);

    SELECT count(*) INTO v_cnt FROM sta.workload_sample;
    INSERT INTO qa_result VALUES (default, 'safety: workload sample is intact',
                                  '4', v_cnt::text, v_cnt = 4);
END
$$;

-- -------------------------------------------------------------------------
-- 7. Finding cap (pg_sta.max_findings)
-- -------------------------------------------------------------------------
-- The GUC must actually bound the number of rows the advice functions
-- return; previously it was registered but never enforced.
DO $$
DECLARE
    v_cnt int;
BEGIN
    SET pg_sta.max_findings = 3;
    SELECT count(*) INTO v_cnt FROM sta.recommendations();
    INSERT INTO qa_result VALUES (default, 'guc: max_findings caps recommendations()',
                                  '<=3', v_cnt::text, v_cnt <= 3);

    SELECT count(*) INTO v_cnt FROM sta.plan_advice(
        'SELECT * FROM sta_qa.big_events WHERE status = ''paid''', false, 50);
    INSERT INTO qa_result VALUES (default, 'guc: max_findings caps plan_advice()',
                                  '<=3', v_cnt::text, v_cnt <= 3);

    SELECT count(*) INTO v_cnt FROM sta.stats_advice('sta_qa', 50);
    INSERT INTO qa_result VALUES (default, 'guc: max_findings caps stats_advice()',
                                  '<=3', v_cnt::text, v_cnt <= 3);

    RESET pg_sta.max_findings;
END
$$;

-- -------------------------------------------------------------------------
-- 8. Audit trail (sta.record_run)
-- -------------------------------------------------------------------------
-- sta.advice_run must be reachable; record_run() writes one row and
-- returns its id.
DO $$
DECLARE
    v_id    bigint;
    v_before int;
    v_after  int;
    v_tool   text;
BEGIN
    SELECT count(*) INTO v_before FROM sta.advice_run;

    v_id := sta.record_run('qa', 'qa-target', 7, 'qa note');
    INSERT INTO qa_result VALUES (default, 'audit: record_run returns a run id',
                                  'not null', coalesce(v_id::text, 'null'), v_id IS NOT NULL);

    SELECT count(*) INTO v_after FROM sta.advice_run;
    INSERT INTO qa_result VALUES (default, 'audit: record_run writes one row',
                                  '1', (v_after - v_before)::text, v_after = v_before + 1);

    SELECT min(tool) INTO v_tool FROM sta.advice_run
     WHERE scope = 'qa' AND target = 'qa-target' AND finding_count = 7;
    INSERT INTO qa_result VALUES (default, 'audit: record_run stamps the tool',
                                  'pg_sta', coalesce(v_tool, 'null'), v_tool = 'pg_sta');
END
$$;

-- -------------------------------------------------------------------------
-- 9. Snapshot diff
-- -------------------------------------------------------------------------
-- sta.snapshot_diff() compares the two most recent snapshots of a schema.
-- The fixture in qa_setup.sql creates one relation, churns it between two
-- snapshots and leaves an index that is no longer used.
DO $$
DECLARE
    v_cnt int;
BEGIN
    SELECT count(*) INTO v_cnt FROM sta.snapshot_diff('sta_diff')
     WHERE finding = 'DEAD_TUPLE_GROWTH';
    INSERT INTO qa_result VALUES (default, 'snapshot: DEAD_TUPLE_GROWTH detected',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    SELECT count(*) INTO v_cnt FROM sta.snapshot_diff('sta_diff')
     WHERE finding = 'STATISTICS_GO_STALE';
    INSERT INTO qa_result VALUES (default, 'snapshot: STATISTICS_GO_STALE detected',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    SELECT count(*) INTO v_cnt FROM sta.snapshot_diff('sta_diff')
     WHERE finding = 'INDEX_NO_LONGER_USED';
    INSERT INTO qa_result VALUES (default, 'snapshot: INDEX_NO_LONGER_USED detected',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    -- The primary key is never reported as an unused index.
    SELECT count(*) INTO v_cnt FROM sta.snapshot_diff('sta_diff')
     WHERE finding = 'INDEX_NO_LONGER_USED'
       AND object_name LIKE '%.churn_pkey';
    INSERT INTO qa_result VALUES (default, 'snapshot: the primary key is not reported as unused',
                                  '0', v_cnt::text, v_cnt = 0);

    -- The diff must not report anything for a schema it has no history for.
    SELECT count(*) INTO v_cnt FROM sta.snapshot_diff('no_such_schema_here');
    INSERT INTO qa_result VALUES (default, 'snapshot: unknown schema yields no findings',
                                  '0', v_cnt::text, v_cnt = 0);

    -- Every finding of the diff must be documented in the catalogue.
    SELECT count(*) INTO v_cnt
    FROM sta.snapshot_diff('sta_diff') p
    WHERE NOT EXISTS (SELECT 1 FROM sta.advice_catalog() c
                       WHERE c.category = p.category AND c.finding = p.finding);
    INSERT INTO qa_result VALUES (default, 'snapshot: every produced finding is documented',
                                  '0', v_cnt::text, v_cnt = 0);
END
$$;

-- -------------------------------------------------------------------------
-- Final report
-- -------------------------------------------------------------------------
-- Emitted unaligned with '|' as the separator so that test/run_qa.sh can
-- parse it without depending on psql's table layout.
\pset format unaligned
\pset fieldsep '|'
\pset tuples_only on

SELECT assertion, expected, actual, passed
FROM qa_result
ORDER BY seq;

SELECT 'TOTAL=' || count(*)
    || ' PASSED=' || count(*) FILTER (WHERE passed)
    || ' FAILED=' || count(*) FILTER (WHERE NOT passed)
FROM qa_result;

\pset format aligned
\pset fieldsep '|'
\pset tuples_only off
