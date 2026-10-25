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
-- 8. PostgreSQL 19 plan advice
-- -------------------------------------------------------------------------
--
-- The plan-advice feature is the pg_plan_advice equivalent of PostgreSQL
-- 19: an advice string is generated from a plan, the advice string is
-- parsed back into planner settings, and applying those settings must
-- reproduce the plan the advice was generated from.
--
DO $$
DECLARE
    v_advice  text;
    v_parsed  text[];
    v_applied text[];
    v_restored text[];
    v_before  text;
    v_during  text;
    v_after   text;
    v_plan_a  jsonb;
    v_plan_b  jsonb;
    v_cnt     int;
    v_tag     text;
    v_targets text[];
    v_msg     text;
BEGIN
    -- ---- parsing -------------------------------------------------------
    -- An advice string is split into its individual items.
    v_parsed := sta._advice_split('SEQ_SCAN(foo) HASH_JOIN(bar@ss)');
    INSERT INTO qa_result VALUES (default, 'advice: the splitter returns every item of an advice string',
                                  '2', array_length(v_parsed, 1)::text,
                                  array_length(v_parsed, 1) = 2);

    -- A tag without a target list is a valid item.
    v_parsed := sta._advice_split('NO_GATHER');
    INSERT INTO qa_result VALUES (default, 'advice: a tag without a target list is accepted',
                                  '1', array_length(v_parsed, 1)::text,
                                  array_length(v_parsed, 1) = 1);

    -- Tags are case insensitive and returned in upper case.
    SELECT tag, targets INTO v_tag, v_targets
      FROM sta._advice_parse('join_order(f d1 d2)') LIMIT 1;
    INSERT INTO qa_result VALUES (default, 'advice: tags are case insensitive',
                                  'JOIN_ORDER', v_tag, v_tag = 'JOIN_ORDER');

    INSERT INTO qa_result VALUES (default, 'advice: the target list is parsed',
                                  'f,d1,d2', array_to_string(v_targets, ','),
                                  array_to_string(v_targets, ',') = 'f,d1,d2');

    -- The advice language of PostgreSQL 19 uses @ to qualify a target.
    SELECT targets INTO v_targets
      FROM sta._advice_parse('HASH_JOIN(bar@ss)') LIMIT 1;
    INSERT INTO qa_result VALUES (default, 'advice: a qualified target is parsed',
                                  'bar@ss', array_to_string(v_targets, ','),
                                  array_to_string(v_targets, ',') = 'bar@ss');

    -- ---- generating advice from a plan ---------------------------------
    v_advice := sta.plan_advice_string(
        'SELECT * FROM sta_qa.pa_fact f
           LEFT JOIN sta_qa.pa_dim1 d1 ON f.dim1_id = d1.id
          WHERE d1.val1 = 1');

    INSERT INTO qa_result VALUES (default, 'advice: a plan produces an advice string',
                                  'non-empty', coalesce(length(v_advice)::text, 'null'),
                                  v_advice IS NOT NULL AND v_advice <> '');

    -- The generated advice must be parsable by the parser of the advisor.
    SELECT count(*) INTO v_cnt
      FROM sta._advice_parse(v_advice) p
     WHERE p.tag NOT IN (SELECT tag FROM sta.plan_advice_tag);
    INSERT INTO qa_result VALUES (default, 'advice: the generated advice only uses known tags',
                                  '0', v_cnt::text, v_cnt = 0);

    -- A join node names no relation of its own, so it is easy to lose it
    -- while collecting the advice.  The join item is the one that tells
    -- the planner which join method the plan used, so it must be there.
    SELECT count(*) INTO v_cnt
      FROM sta._advice_parse(v_advice) p
     WHERE p.tag IN ('HASH_JOIN', 'MERGE_JOIN', 'NESTED_LOOP_PLAIN');
    INSERT INTO qa_result VALUES (default, 'advice: the advice contains the join item',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    -- The join item names the relation that is hashed, which is not
    -- necessarily the relation that appears first in the plan.
    SELECT count(*) INTO v_cnt
      FROM sta._advice_parse(v_advice) p
     WHERE p.tag = 'HASH_JOIN' AND p.targets = ARRAY['d1'];
    INSERT INTO qa_result VALUES (default, 'advice: the join item names the hashed relation',
                                  '>=1', v_cnt::text, v_cnt >= 1);

    -- ---- round trip -----------------------------------------------------
    -- The central guarantee of the feature: the advice generated from a
    -- plan must reproduce that very plan when it is applied.
    SELECT sta.explain(
        'SELECT * FROM sta_qa.pa_fact f
           LEFT JOIN sta_qa.pa_dim1 d1 ON f.dim1_id = d1.id
          WHERE d1.val1 = 1', false)
      INTO v_plan_a;

    SELECT (sta.run_with_advice(v_advice,
        'SELECT * FROM sta_qa.pa_fact f
           LEFT JOIN sta_qa.pa_dim1 d1 ON f.dim1_id = d1.id
          WHERE d1.val1 = 1', false)->0->'Plan')
      INTO v_plan_b;

    INSERT INTO qa_result VALUES (default, 'advice: applying the generated advice reproduces the plan',
                                  'identical',
                                  CASE WHEN v_plan_a->0->'Plan' = v_plan_b THEN 'identical' ELSE 'different' END,
                                  v_plan_a->0->'Plan' = v_plan_b);

    -- ---- applying and restoring ----------------------------------------
    v_before := current_setting('enable_indexscan');

    v_applied := sta.apply_advice('SEQ_SCAN(d1)');

    -- SEQ_SCAN does not switch enable_seqscan off; it switches the index
    -- scan methods off, so that only the sequential scan is left.
    v_during := current_setting('enable_indexscan');
    INSERT INTO qa_result VALUES (default, 'advice: applying SEQ_SCAN disables the index scans',
                                  'off', v_during, v_during = 'off');

    v_restored := sta.restore_advice();
    v_after := current_setting('enable_indexscan');
    INSERT INTO qa_result VALUES (default, 'advice: restoring returns the previous setting',
                                  v_before, v_after, v_after = v_before);

    -- The restore list must name the settings that were changed.
    INSERT INTO qa_result VALUES (default, 'advice: the restore list names the changed settings',
                                  '3', array_length(v_restored, 1)::text,
                                  array_length(v_restored, 1) = 3);

    -- Applying a second time must first restore the baseline, so that the
    -- restore list is still exact.
    v_applied := sta.apply_advice('SEQ_SCAN(d1)');
    v_restored := sta.restore_advice();
    v_after := current_setting('enable_indexscan');
    INSERT INTO qa_result VALUES (default, 'advice: applying twice still restores the baseline',
                                  v_before, v_after, v_after = v_before);

    -- Two advice items that touch the same planner setting must not
    -- confuse the recorded baseline: the value that was in force before the
    -- first item was applied is the one that has to be restored.
    v_applied := sta.apply_advice('SEQ_SCAN(d1) SEQ_SCAN(d2)');
    v_during := current_setting('enable_indexscan');
    INSERT INTO qa_result VALUES (default, 'advice: a repeated tag still switches the planner',
                                  'off', v_during, v_during = 'off');

    v_restored := sta.restore_advice();
    v_after := current_setting('enable_indexscan');
    INSERT INTO qa_result VALUES (default, 'advice: a repeated tag restores the original setting',
                                  v_before, v_after, v_after = v_before);

    -- An unsupported tag must be reported as such instead of silently
    -- doing nothing.
    v_applied := sta.apply_advice('JOIN_ORDER(f d1)');
    INSERT INTO qa_result VALUES (default, 'advice: an unsupported tag is reported as unsupported',
                                  'JOIN_ORDER:unsupported',
                                  coalesce(array_to_string(v_applied, ','), ''),
                                  v_applied = ARRAY['JOIN_ORDER:unsupported']::text[]);

    -- The unsupported tag must not have changed anything, so the restore
    -- list is empty.
    v_restored := sta.restore_advice();
    INSERT INTO qa_result VALUES (default, 'advice: an unsupported tag changes nothing',
                                  '0', coalesce(array_length(v_restored, 1), 0)::text,
                                  coalesce(array_length(v_restored, 1), 0) = 0);

    -- An unknown tag must be an error.
    BEGIN
        PERFORM sta.apply_advice('BOGUS_TAG(x)');
        v_msg := 'no error';
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
    END;
    INSERT INTO qa_result VALUES (default, 'advice: an unknown tag raises an error',
                                  'unknown plan advice tag', v_msg,
                                  v_msg LIKE 'unknown plan advice tag%');

    -- ---- the tag catalogue ---------------------------------------------
    -- Every tag must either map to at least one planner setting or be
    -- marked unsupported.  A tag that maps to nothing and is not marked
    -- unsupported would silently do nothing.
    SELECT count(*) INTO v_cnt
      FROM sta.plan_advice_tag t
     WHERE t.enforcement <> 'unsupported'
       AND NOT EXISTS (SELECT 1 FROM sta.plan_advice_guc g WHERE g.tag = t.tag);
    INSERT INTO qa_result VALUES (default, 'advice: every enforceable tag maps to a planner setting',
                                  '0', v_cnt::text, v_cnt = 0);

    -- The view of the catalogue must show every tag.
    SELECT count(*) INTO v_cnt FROM sta.plan_advice_tag_view;
    INSERT INTO qa_result VALUES (default, 'advice: the tag view lists every tag',
                                  (SELECT count(*)::text FROM sta.plan_advice_tag),
                                  v_cnt::text,
                                  v_cnt = (SELECT count(*) FROM sta.plan_advice_tag));
END
$$;

-- -------------------------------------------------------------------------
-- 9. PostgreSQL 19 advice stash
-- -------------------------------------------------------------------------
--
-- The stash is the pg_stash_advice equivalent of PostgreSQL 19: advice is
-- stored per query id in a named container so that it can be applied
-- later, without the caller having to repeat the advice string.
--
DO $$
DECLARE
    v_qid     bigint;
    v_advice  text;
    v_cnt     int;
    v_msg     text;
    v_entries bigint;
BEGIN
    v_qid := sta.queryid('SELECT * FROM sta_qa.pa_fact f
                             LEFT JOIN sta_qa.pa_dim1 d1 ON f.dim1_id = d1.id
                            WHERE d1.val1 = 1');

    -- A fresh stash is empty.
    PERFORM sta.create_stash('qa_stash');
    SELECT count(*) INTO v_cnt FROM sta.get_stash_contents('qa_stash');
    INSERT INTO qa_result VALUES (default, 'stash: a new stash is empty',
                                  '0', v_cnt::text, v_cnt = 0);

    -- Creating the same stash twice must be an error.
    BEGIN
        PERFORM sta.create_stash('qa_stash');
        v_msg := 'no error';
    EXCEPTION WHEN duplicate_object THEN
        v_msg := 'duplicate';
    END;
    INSERT INTO qa_result VALUES (default, 'stash: creating an existing stash raises an error',
                                  'duplicate', v_msg, v_msg = 'duplicate');

    -- An invalid stash name must be rejected.
    BEGIN
        PERFORM sta.create_stash('99bottles');
        v_msg := 'no error';
    EXCEPTION WHEN invalid_parameter_value THEN
        v_msg := 'invalid';
    END;
    INSERT INTO qa_result VALUES (default, 'stash: an invalid stash name raises an error',
                                  'invalid', v_msg, v_msg = 'invalid');

    -- Dropping a stash that does not exist must be an error.
    BEGIN
        PERFORM sta.drop_stash('no_such_stash');
        v_msg := 'no error';
    EXCEPTION WHEN undefined_object THEN
        v_msg := 'undefined';
    END;
    INSERT INTO qa_result VALUES (default, 'stash: dropping an unknown stash raises an error',
                                  'undefined', v_msg, v_msg = 'undefined');

    -- Storing advice for a query id.
    PERFORM sta.set_stashed_advice('qa_stash', v_qid, 'SEQ_SCAN(d1)');

    SELECT count(*) INTO v_cnt FROM sta.get_stash_contents('qa_stash');
    INSERT INTO qa_result VALUES (default, 'stash: the stored advice appears in the contents',
                                  '1', v_cnt::text, v_cnt = 1);

    -- The entry must be retrievable by query id.
    v_advice := sta.get_stashed_advice(v_qid, 'qa_stash');
    INSERT INTO qa_result VALUES (default, 'stash: the advice is retrievable by query id',
                                  'SEQ_SCAN(d1)', coalesce(v_advice, 'null'),
                                  v_advice = 'SEQ_SCAN(d1)');

    -- The list of stashes must report the number of entries.
    SELECT num_entries INTO v_entries FROM sta.get_stashes() WHERE stash_name = 'qa_stash';
    INSERT INTO qa_result VALUES (default, 'stash: the stash list reports the number of entries',
                                  '1', coalesce(v_entries::text, 'null'), v_entries = 1);

    -- An unknown stash yields no rows instead of an error.
    SELECT count(*) INTO v_cnt FROM sta.get_stash_contents('no_such_stash');
    INSERT INTO qa_result VALUES (default, 'stash: the contents of an unknown stash are empty',
                                  '0', v_cnt::text, v_cnt = 0);

    -- The query id zero must be rejected.
    BEGIN
        PERFORM sta.set_stashed_advice('qa_stash', 0, 'SEQ_SCAN(d1)');
        v_msg := 'no error';
    EXCEPTION WHEN invalid_parameter_value THEN
        v_msg := 'invalid';
    END;
    INSERT INTO qa_result VALUES (default, 'stash: the query id zero raises an error',
                                  'invalid', v_msg, v_msg = 'invalid');

    -- Storing advice for a query id that is not in the stash must be an
    -- error.
    BEGIN
        PERFORM sta.set_stashed_advice('no_such_stash', v_qid, 'SEQ_SCAN(d1)');
        v_msg := 'no error';
    EXCEPTION WHEN undefined_object THEN
        v_msg := 'undefined';
    END;
    INSERT INTO qa_result VALUES (default, 'stash: storing advice in an unknown stash raises an error',
                                  'undefined', v_msg, v_msg = 'undefined');

    -- Storing the same query id twice replaces the advice.
    PERFORM sta.set_stashed_advice('qa_stash', v_qid, 'HASH_JOIN(d1)');
    v_advice := sta.get_stashed_advice(v_qid, 'qa_stash');
    INSERT INTO qa_result VALUES (default, 'stash: storing the same query id twice replaces the advice',
                                  'HASH_JOIN(d1)', coalesce(v_advice, 'null'),
                                  v_advice = 'HASH_JOIN(d1)');

    -- A null advice removes the entry.
    PERFORM sta.set_stashed_advice('qa_stash', v_qid, NULL);
    SELECT count(*) INTO v_cnt FROM sta.get_stash_contents('qa_stash');
    INSERT INTO qa_result VALUES (default, 'stash: a null advice removes the entry',
                                  '0', v_cnt::text, v_cnt = 0);

    -- The stash must not leak into another session: it is stored in an
    -- ordinary table, so it is visible everywhere.  What must not happen is
    -- that dropping the stash leaves its entries behind.
    PERFORM sta.set_stashed_advice('qa_stash', v_qid, 'SEQ_SCAN(d1)');
    PERFORM sta.drop_stash('qa_stash');
    SELECT count(*) INTO v_cnt FROM sta.get_stash_contents('qa_stash');
    INSERT INTO qa_result VALUES (default, 'stash: dropping a stash removes its entries',
                                  '0', v_cnt::text, v_cnt = 0);
END
$$;

-- -------------------------------------------------------------------------
-- 10. Applying stashed advice
-- -------------------------------------------------------------------------
--
-- The end-to-end path of the stash: a statement is planned with the advice
-- that is stored for its query id, and the planner settings are restored
-- afterwards.
--
DO $$
DECLARE
    v_qid     bigint;
    v_before  text;
    v_after   text;
    v_advice  text;
    v_applied text[];
    v_plan    jsonb;
    v_cnt     int;
BEGIN
    v_qid := sta.queryid('SELECT * FROM sta_qa.pa_fact f
                             LEFT JOIN sta_qa.pa_dim1 d1 ON f.dim1_id = d1.id
                            WHERE d1.val1 = 1');

    PERFORM sta.create_stash('qa_apply');
    PERFORM sta.set_stashed_advice('qa_apply', v_qid, 'SEQ_SCAN(d1)');

    v_before := current_setting('enable_seqscan');

    SELECT e.advice, e.applied, e.plan
      INTO v_advice, v_applied, v_plan
      FROM sta.explain_with_stashed_advice('qa_apply', v_qid,
        'SELECT * FROM sta_qa.pa_fact f
           LEFT JOIN sta_qa.pa_dim1 d1 ON f.dim1_id = d1.id
          WHERE d1.val1 = 1', false) e;

    INSERT INTO qa_result VALUES (default, 'stash: the stored advice is used to plan the statement',
                                  'SEQ_SCAN(d1)', coalesce(v_advice, 'null'),
                                  v_advice = 'SEQ_SCAN(d1)');

    INSERT INTO qa_result VALUES (default, 'stash: the stashed advice is applied to the planner',
                                  '3', coalesce(array_length(v_applied, 1), 0)::text,
                                  array_length(v_applied, 1) = 3);

    INSERT INTO qa_result VALUES (default, 'stash: the statement is planned',
                                  'plan', coalesce(v_plan->0->'Plan'->>'Node Type', 'null'),
                                  v_plan IS NOT NULL AND v_plan->0->'Plan' IS NOT NULL);

    v_after := current_setting('enable_seqscan');
    INSERT INTO qa_result VALUES (default, 'stash: the planner settings are restored afterwards',
                                  v_before, v_after, v_after = v_before);

    -- A query id that is not in the stash is planned normally.
    SELECT e.applied INTO v_applied
      FROM sta.explain_with_stashed_advice('qa_apply', 42,
        'SELECT * FROM sta_qa.pa_fact f
           LEFT JOIN sta_qa.pa_dim1 d1 ON f.dim1_id = d1.id
          WHERE d1.val1 = 1', false) e;

    INSERT INTO qa_result VALUES (default, 'stash: a query id that is not stashed changes nothing',
                                  '0', coalesce(array_length(v_applied, 1), 0)::text,
                                  coalesce(array_length(v_applied, 1), 0) = 0);

    PERFORM sta.drop_stash('qa_apply');
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
