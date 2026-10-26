--
-- pg_sta benchmark: analyze the benchmark tables
--
-- The statistics have to be right, otherwise every plan estimate is wrong
-- and the plan advice describes a plan that does not exist.
--
-- pg_sta.bench_skip_analyze says how many tables at the end of the list
-- are left alone, so that the statistics advisor has a subject:
--
--   SET pg_sta.bench_skip_analyze = '2';   -- bench_19 and bench_20 stay dark
--
SELECT set_config('pg_sta.bench_skip_analyze',
                  COALESCE(current_setting('pg_sta.bench_skip_analyze', true), '0'), false);

DO $analyze$
DECLARE
    v_names text[];
    v_count int;
    v_i     int;
BEGIN
    SELECT array_agg(c.relname ORDER BY c.relname)
      INTO v_names
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relname LIKE 'bench\_%'
       AND c.relkind = 'r';

    IF v_names IS NULL THEN
        RETURN;
    END IF;

    v_count := coalesce(array_length(v_names, 1), 0)
             - current_setting('pg_sta.bench_skip_analyze')::int;
    IF v_count < 0 THEN
        v_count := 0;
    END IF;

    FOR v_i IN 1..v_count LOOP
        EXECUTE format('ANALYZE public.%I', v_names[v_i]);
    END LOOP;
END
$analyze$;
