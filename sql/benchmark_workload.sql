--
-- pg_sta benchmark workload
--
-- Ten statements, each written the way a report or an ORM tends to write
-- it, and each with a different problem for the advisor to find:
--
--   1  SELECT * on a million-row relation        -> projection, index
--   2  OR between two equality predicates         -> rewrite to IN
--   3  a function on the filtered column          -> sargable rewrite
--   4  a join across two unindexed relations      -> index, join order
--   5  the column is cast, not the literal        -> implicit cast
--   6  a leading wildcard                         -> trigram / range
--   7  NOT IN with a subquery                     -> NOT EXISTS
--   8  OFFSET pagination                          -> keyset pagination
--   9  UNION between two branches                 -> UNION ALL
--  10  a plain equality on an unindexed column    -> index
--
-- Every statement returns a handful of rows, so the workload is fast to
-- run, but every statement has to read a whole million-row relation
-- because none of the filtered columns is indexed.  That is exactly the
-- situation the advisor exists for.
--
-- The statements are executed through EXECUTE inside one transaction, so
-- the result rows are produced but not sent to the client.
--
-- The relations are the tables that were actually created, so the
-- workload works whatever table count the loader was given.  The number
-- of repetitions comes from pg_sta.bench_iterations, which the loader
-- sets; when the file is run on its own it defaults to 20.
--
SELECT set_config('pg_sta.bench_iterations',
                  COALESCE(current_setting('pg_sta.bench_iterations', true), '20'), false);

-- The statements below are executed from inside a function body, so
-- pg_stat_statements only records them when it tracks nested statements.
DO $track$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        PERFORM set_config('pg_stat_statements.track', 'all', false);
    END IF;
END
$track$;

DO $work$
DECLARE
    v_iter  int := current_setting('pg_sta.bench_iterations')::int;
    v_tabs  text[];
    v_n     int;
    v_i     int;
    t1 text; t2 text; t3 text; t4 text; t5 text; t6 text;
    t7 text; t8 text; t9 text; t10 text; t11 text; t12 text; t13 text;
BEGIN
    IF v_iter < 1 THEN
        RAISE EXCEPTION 'pg_sta.bench_iterations must be positive (got %)', v_iter;
    END IF;

    -- The relations are the tables that were actually created, so the
    -- workload works whatever table count the loader was given.
    SELECT array_agg(format('public.%I', c.relname) ORDER BY c.relname)
      INTO v_tabs
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relname LIKE 'bench\_%'
       AND c.relkind = 'r';

    IF v_tabs IS NULL THEN
        RAISE EXCEPTION 'no bench_* tables found; run load_benchmark.sh first';
    END IF;

    v_n := array_length(v_tabs, 1);

    t1  := v_tabs[(( 1-1) % v_n) + 1];
    t2  := v_tabs[(( 2-1) % v_n) + 1];
    t3  := v_tabs[(( 3-1) % v_n) + 1];
    t4  := v_tabs[(( 4-1) % v_n) + 1];
    t5  := v_tabs[(( 5-1) % v_n) + 1];
    t6  := v_tabs[(( 6-1) % v_n) + 1];
    t7  := v_tabs[(( 7-1) % v_n) + 1];
    t8  := v_tabs[(( 8-1) % v_n) + 1];
    t9  := v_tabs[(( 9-1) % v_n) + 1];
    t10 := v_tabs[((10-1) % v_n) + 1];
    t11 := v_tabs[((11-1) % v_n) + 1];
    t12 := v_tabs[((12-1) % v_n) + 1];
    t13 := v_tabs[((13-1) % v_n) + 1];

    FOR v_i IN 1..v_iter LOOP

        -- 1. SELECT * on a large relation
        EXECUTE format('SELECT * FROM %s WHERE customer_id = 42', t1);

        -- 2. OR between two equality predicates on the same column
        EXECUTE format($q$
            SELECT id, amount FROM %s
             WHERE customer_id = 42 AND (region = 'eu' OR region = 'us')
        $q$, t2);

        -- 3. a function applied to the filtered column
        EXECUTE format($q$
            SELECT id, amount FROM %s
             WHERE customer_id = 42 AND lower(status) = 'shipped'
        $q$, t3);

        -- 4. a join across two relations that both have no index
        EXECUTE format($q$
            SELECT o.id, o.amount, c.region
              FROM %s o
              JOIN %s c ON c.customer_id = o.customer_id
             WHERE o.customer_id = 42
        $q$, t4, t5);

        -- 5. the column is cast to text instead of the literal
        EXECUTE format($q$
            SELECT id, amount FROM %s
             WHERE customer_id = 42 AND amount::text = '123.45'
        $q$, t6);

        -- 6. a leading wildcard
        EXECUTE format($q$
            SELECT id, status FROM %s
             WHERE customer_id = 42 AND status LIKE '%%ship%%'
        $q$, t7);

        -- 7. NOT IN with a subquery
        EXECUTE format($q$
            SELECT id, amount FROM %s
             WHERE customer_id = 42
               AND id NOT IN (SELECT id FROM %s WHERE customer_id = 43)
        $q$, t8, t9);

        -- 8. OFFSET pagination over a sorted million rows
        EXECUTE format($q$
            SELECT id, placed_at FROM %s
             ORDER BY placed_at LIMIT 20 OFFSET 10000
        $q$, t10);

        -- 9. UNION between two branches
        EXECUTE format($q$
            SELECT id FROM %s WHERE customer_id = 42
            UNION
            SELECT id FROM %s WHERE customer_id = 43
        $q$, t11, t12);

        -- 10. a plain equality on an unindexed column
        EXECUTE format($q$
            SELECT count(*) FROM %s WHERE customer_id = 17
        $q$, t13);

    END LOOP;
END
$work$;
