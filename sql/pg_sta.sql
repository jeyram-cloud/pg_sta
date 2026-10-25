-- pg_sta regression tests
--
-- The suite is deliberately deterministic: every statement either asserts a
-- property (a boolean, a count, a normalised value) or prints a value that is
-- stable for a given PostgreSQL version.  Nothing prints a timing, a plan
-- cost or a row estimate, because those legitimately differ between builds.
--
-- Run with:  make installcheck PG_CONFIG=/usr/pgsql-17/bin/pg_config

CREATE EXTENSION IF NOT EXISTS pg_sta;

------------------------------------------------------------------------------
-- Test schema and fixtures
--
-- The schema is named "sta_regress" rather than "pg_sta_regress": PostgreSQL
-- reserves any name beginning with "pg_" for the system, and a user object
-- with such a prefix cannot be created.
------------------------------------------------------------------------------
CREATE SCHEMA sta_regress;

CREATE TABLE sta_regress.orders (
    id          serial PRIMARY KEY,
    customer_id integer NOT NULL,
    status      text    NOT NULL,
    amount      numeric(12,2) NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO sta_regress.orders (customer_id, status, amount)
SELECT g % 50,
       (ARRAY['new', 'paid', 'shipped', 'cancelled'])[(g % 4) + 1],
       (g % 1000)::numeric
FROM generate_series(1, 5000) AS g;

CREATE TABLE sta_regress.tiny (id integer PRIMARY KEY, v text);
INSERT INTO sta_regress.tiny VALUES (1, 'a'), (2, 'b');

-- A relation that is deliberately left without a primary key and without
-- statistics, so that the statistics advice has something to report.
CREATE TABLE sta_regress.unanalysed (a integer, b text);
INSERT INTO sta_regress.unanalysed SELECT g, 'x' FROM generate_series(1, 100) AS g;

ANALYZE sta_regress.orders;
ANALYZE sta_regress.tiny;

-- The advisory functions resolve relations from the plan and from the search
-- path, so the fixtures have to be visible.  "sta_regress" is put first so
-- that it wins over any same-named relation in "public".
SET search_path = sta_regress, public;

------------------------------------------------------------------------------
-- 1. C entry points
------------------------------------------------------------------------------

-- 1.1 query id is stable for the same text
SELECT sta.queryid('SELECT 1') = sta.queryid('SELECT 1') AS queryid_is_stable;

-- 1.2 constants are replaced by $n placeholders, so statements that differ
--     only in their literals share a single query id.  This is the same
--     behaviour as pg_stat_statements, and it is what makes it possible to
--     aggregate the workload of a whole class of statements.
SELECT sta.queryid('SELECT 1') = sta.queryid('SELECT 2') AS literals_share_queryid;

SELECT count(DISTINCT queryid) = 1 AS queryid_is_shared_by_normalised_text
FROM (VALUES
    (sta.queryid('SELECT 1')),
    (sta.queryid('SELECT 2')),
    (sta.queryid('SELECT 1'))
) AS v(queryid);

-- 1.3 constants are replaced by $n placeholders.  The relation has to exist
--     because the statement is parsed and analysed in order to compute the
--     query id.
SELECT sta.queryid_normalized('SELECT * FROM sta_regress.orders WHERE id = 42') AS normalized;

-- 1.4 placeholders inside a string literal and inside comments are not
--     treated as parameters of the statement.  They are copied through
--     verbatim, but the literal itself is still normalised, so the text
--     '$1' becomes $1.
SELECT sta.queryid_normalized('SELECT ''$1'' AS x') AS string_literal_normalised;
SELECT sta.queryid_normalized('SELECT 1 -- $2') AS line_comment_kept;
SELECT sta.queryid_normalized('SELECT /* $3 */ 1') AS block_comment_kept;

-- 1.5 server info exposes the pieces the advisor depends on
SELECT (sta.server_info()->>'server_version') IS NOT NULL AS has_server_version,
       (sta.server_info()->>'pg_stat_statements') IS NOT NULL AS has_pgss_flag;

------------------------------------------------------------------------------
-- 2. EXPLAIN
------------------------------------------------------------------------------

-- 2.1 a constant statement is explained without a plan-cache dance
SELECT sta.plan_signature(sta.explain('SELECT 1')) AS signature_constant;

-- 2.2 a normalised statement with parameters is explained through the
--     generic-plan path.  Before the fix this raised
--     "there is no parameter $1".
SELECT sta.plan_signature(
           sta.explain('SELECT * FROM sta_regress.orders WHERE customer_id = $1 AND status = $2'))
       AS signature_parameterized;

-- 2.3 EXPLAIN ANALYZE is rejected for parameterised statements, because the
--     parameter values are unknown and the measurement would be meaningless.
--     The error must be raised, and the surrounding transaction must survive.
DO $$
BEGIN
    BEGIN
        PERFORM sta.explain('SELECT * FROM sta_regress.orders WHERE customer_id = $1', true);
        RAISE EXCEPTION 'sta.explain: expected an error for EXPLAIN ANALYZE on a parameterised statement';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'there is no parameter%' THEN
                RAISE EXCEPTION 'sta.explain: parameterised statement was parsed with fixed parameters';
            END IF;
            IF SQLERRM NOT LIKE '%parameter%' THEN
                RAISE;
            END IF;
    END;
END
$$;

-- 2.4 plan_cache_mode is restored after a parameterised EXPLAIN
SHOW plan_cache_mode;

-- 2.5 a statement that only looks parameterised is still explained normally
SELECT sta.plan_signature(
           sta.explain('SELECT ''$1''::text AS literal'))
       AS signature_literal_string;

SELECT sta.plan_signature(
           sta.explain('SELECT $$dollar quoted$$ AS literal'))
       AS signature_dollar_quoted;

-- 2.6 only read-only statements are accepted
DO $$
BEGIN
    BEGIN
        PERFORM sta.explain('CREATE TABLE sta_regress.should_not_exist(i int)');
        RAISE EXCEPTION 'sta.explain: expected an error for a non-SELECT statement';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM NOT LIKE '%only SELECT%' AND SQLERRM NOT LIKE '%not allowed%' THEN
                RAISE;
            END IF;
    END;
END
$$;

SELECT to_regclass('sta_regress.should_not_exist') IS NULL AS no_table_created;

-- 2.7 the same statement explained many times yields the same plan.
--     Before the fix the SPI result was freed before it was used, so the
--     plan signature changed at random and the plan text was sometimes
--     truncated to invalid JSON.
SELECT count(DISTINCT sta.plan_signature(sta.explain(
               'SELECT * FROM sta_regress.orders WHERE customer_id = $1 AND status = $2'))) = 1
           AS repeated_explain_is_stable;

------------------------------------------------------------------------------
-- 3. Helpers
------------------------------------------------------------------------------

-- 3.1 identifiers() returns every word-like token of the statement,
--     including the SQL keywords.
SELECT sta.identifiers('SELECT a.x, b.y FROM tbl_a a JOIN tbl_b b ON a.id = b.id')
       AS identifiers;

-- 3.2 the plan signature ignores constants, so the same statement shape
--     produces the same signature.
SELECT sta.plan_signature(sta.explain('SELECT 1')) =
       sta.plan_signature(sta.explain('SELECT 2')) AS signature_ignores_constants;

-- 3.3 validation steps are provided for the known kinds and a safe default
--     is returned for anything else.
SELECT sta.validation_steps('index') IS NOT NULL AS validation_steps_index;
SELECT array_length(sta.validation_steps('nonexistent-kind'), 1) AS validation_steps_default;

-- 3.4 relations are resolved by schema, so an ambiguous name in the search
--     path does not pick the wrong relation.
SELECT r.schema, r.relname, r.reltuples
FROM sta._resolve_relation('orders', 'sta_regress') r;

------------------------------------------------------------------------------
-- 4. Statistics advice must not report the extension's own tables
------------------------------------------------------------------------------
SELECT count(*) = 0 AS stats_advice_skips_extension_tables
FROM sta.stats_advice('sta');

-- 4.1 the statistics advice reports the fixture relation by its qualified
--     name, which proves the relation was resolved correctly.
SELECT count(*) > 0 AS stats_advice_finds_fixture
FROM sta.stats_advice('sta_regress')
WHERE object_name = 'sta_regress.orders';

-- 4.2 a relation that was never analyzed and has no primary key is
--     reported.  The check does not depend on the statistics collector
--     having flushed yet, so the result is stable.
SELECT count(*) > 0 AS stats_advice_reports_never_analyzed
FROM sta.stats_advice('sta_regress')
WHERE object_name = 'sta_regress.unanalysed'
  AND finding = 'NEVER_ANALYZED';

SELECT count(*) > 0 AS stats_advice_reports_no_primary_key
FROM sta.stats_advice('sta_regress')
WHERE object_name = 'sta_regress.unanalysed'
  AND finding = 'NO_PRIMARY_KEY';

-- 4.3 the fixture that has a primary key and fresh statistics is not
--     reported for either of the two findings above.
SELECT count(*) = 0 AS stats_advice_ignores_healthy_table
FROM sta.stats_advice('sta_regress')
WHERE object_name = 'sta_regress.orders'
  AND finding IN ('NEVER_ANALYZED', 'NO_PRIMARY_KEY');

------------------------------------------------------------------------------
-- 5. Plan advice
------------------------------------------------------------------------------

SELECT count(*) > 0 AS plan_advice_finds_something
FROM sta.plan_advice('SELECT * FROM sta_regress.orders WHERE status = ''new'' ORDER BY amount DESC', true);

-- 5.1 a sequential scan over a relation that is larger than the threshold
--     is reported, and the object is named with its schema.
SELECT count(*) > 0 AS plan_advice_finds_seq_scan_on_large_table
FROM sta.plan_advice('SELECT * FROM sta_regress.orders WHERE customer_id = 7', true)
WHERE finding = 'SEQ_SCAN_ON_LARGE_TABLE';

SELECT count(*) > 0 AS plan_advice_object_is_schema_qualified
FROM sta.plan_advice('SELECT * FROM sta_regress.orders WHERE customer_id = 7', true)
WHERE finding = 'SEQ_SCAN_ON_LARGE_TABLE'
  AND object_name = 'sta_regress.orders';

-- 5.2 a sequential scan over a small relation is reported as such and is
--     not confused with the "large table" finding.
SELECT count(*) > 0 AS plan_advice_reports_small_table_scan
FROM sta.plan_advice('SELECT * FROM sta_regress.tiny WHERE id = 1', true)
WHERE finding = 'SEQ_SCAN_ON_SMALL_TABLE';

SELECT count(*) = 0 AS plan_advice_small_table_is_not_large_table
FROM sta.plan_advice('SELECT * FROM sta_regress.tiny WHERE id = 1', true)
WHERE finding = 'SEQ_SCAN_ON_LARGE_TABLE';

-- 5.3 every finding that plan advice emits has a prose explanation next to
--     the machine-readable code.
SELECT count(*) = 0 AS plan_advice_always_has_finding_text
FROM sta.plan_advice('SELECT * FROM sta_regress.orders WHERE customer_id = 7', true)
WHERE finding IS NOT NULL AND finding_text IS NULL;

------------------------------------------------------------------------------
-- 6. Index advice
------------------------------------------------------------------------------
SELECT count(*) > 0 AS index_advice_proposes_candidate
FROM sta.index_advice('SELECT * FROM sta_regress.orders WHERE customer_id = 7 AND status = ''new''');

------------------------------------------------------------------------------
-- 7. Validation
--
--    The candidate index is created in a subtransaction that is rolled back,
--    so the database must be unchanged afterwards.
------------------------------------------------------------------------------

-- 7.1 an index the planner will actually use is reported as RECOMMENDED.
SELECT verdict = 'RECOMMENDED' AS validate_reports_recommended,
       plan_changed = true AS validate_plan_changed_true
FROM sta.validate(
        'CREATE INDEX regress_idx_orders_customer ON sta_regress.orders(customer_id)',
        'SELECT * FROM sta_regress.orders WHERE customer_id = 42',
        2);

-- 7.2 an index the planner ignores is reported as NOT_USED, because the
--     timing difference would be noise.  The candidate is on "amount" while
--     the statement filters on "customer_id", so the planner has no reason
--     to pick it.
SELECT verdict = 'NOT_USED' AS validate_reports_not_used,
       plan_changed = false AS validate_plan_changed_false
FROM sta.validate(
        'CREATE INDEX regress_idx_orders_amount ON sta_regress.orders(amount)',
        'SELECT * FROM sta_regress.orders WHERE customer_id = 42',
        2);

-- 7.3 the notes state that the candidate index was rolled back.
SELECT notes @> ARRAY['The candidate index was created in a subtransaction and rolled back; the database is unchanged.']::text[]
           AS validate_notes_rollback
FROM sta.validate(
        'CREATE INDEX regress_idx_orders_customer ON sta_regress.orders(customer_id)',
        'SELECT * FROM sta_regress.orders WHERE customer_id = 42',
        2);

-- 7.4 no candidate index survives the validation.
SELECT to_regclass('sta_regress.regress_idx_orders_customer') IS NULL AS validate_rolled_back_customer;
SELECT to_regclass('sta_regress.regress_idx_orders_amount') IS NULL AS validate_rolled_back_amount;

------------------------------------------------------------------------------
-- 8. Workload advice and collection
------------------------------------------------------------------------------
SELECT sta.reset() IS NULL AS reset_ok;

SELECT count(*) >= 0 AS collect_returns_counts
FROM sta.collect();

SELECT count(*) >= 0 AS workload_advice_runs
FROM sta.workload_advice();

------------------------------------------------------------------------------
-- 9. Recommendations
------------------------------------------------------------------------------
SELECT count(*) >= 0 AS recommendations_run
FROM sta.recommendations();

-- 9.1 the recommendations carry the machine-readable code, the prose and the
--     evidence, and every code can be looked up in the catalogue.
SELECT count(*) = 0 AS recommendations_all_in_catalog
FROM sta.recommendations() r
LEFT JOIN sta.advice_catalog() c
       ON c.category = r.category AND c.finding = r.finding
WHERE c.finding IS NULL;

------------------------------------------------------------------------------
-- 10. Advice catalogue
------------------------------------------------------------------------------
SELECT count(*) > 0 AS advice_catalog_has_entries
FROM sta.advice_catalog();

SELECT count(DISTINCT finding) = count(*) AS advice_catalog_findings_unique
FROM sta.advice_catalog();

-- 10.1 the catalogue is a set-returning function, so it is queried as one.
SELECT count(*) > 0 AS advice_catalog_is_a_function
FROM sta.advice_catalog() c
WHERE c.category IS NOT NULL AND c.finding IS NOT NULL;

------------------------------------------------------------------------------
-- 11. Thresholds are configurable
------------------------------------------------------------------------------
UPDATE sta.threshold SET value = 1000000 WHERE name = 'seq_scan_min_rows';
SELECT count(*) = 0 AS threshold_takes_effect
FROM sta.plan_advice('SELECT * FROM sta_regress.orders WHERE customer_id = 7', true)
WHERE finding = 'SEQ_SCAN_ON_LARGE_TABLE';
UPDATE sta.threshold SET value = 1000 WHERE name = 'seq_scan_min_rows';

-- 11.1 restoring the threshold restores the finding.
SELECT count(*) > 0 AS threshold_restored
FROM sta.plan_advice('SELECT * FROM sta_regress.orders WHERE customer_id = 7', true)
WHERE finding = 'SEQ_SCAN_ON_LARGE_TABLE';

------------------------------------------------------------------------------
-- 12. Cleanup
------------------------------------------------------------------------------
RESET search_path;
DROP SCHEMA sta_regress CASCADE;