--
-- pg_sta benchmark fixture
--
-- Creates N tables (default 20) with M rows each (default 1,000,000) that
-- are large enough for the advisor to have something to say, and that carry
-- the shapes of query that the advisor has to recognise:
--
--   * a relation with no index at all          -> index advice
--   * a skewed relation                        -> plan advice
--   * a relation with a primary key            -> NO_INDEXES must not fire
--   * a relation that is never analysed        -> statistics advice
--
-- The size is controlled by two session settings, so that the same file
-- serves a 20 x 1,000,000 benchmark and a quick 3 x 1,000 smoke test:
--
--   SET pg_sta.bench_tables = '20';
--   SET pg_sta.bench_rows   = '1000000';
--
-- The script is idempotent: it drops the tables it is about to create.
-- Only the tables it created itself are dropped -- they all carry the
-- "pg_sta benchmark" comment.
--
SELECT set_config('pg_sta.bench_tables',
                  COALESCE(current_setting('pg_sta.bench_tables', true), '20'), false);
SELECT set_config('pg_sta.bench_rows',
                  COALESCE(current_setting('pg_sta.bench_rows', true), '1000000'), false);

DO $bench$
DECLARE
    v_tables int  := current_setting('pg_sta.bench_tables')::int;
    v_rows   int  := current_setting('pg_sta.bench_rows')::int;
    v_i      int;
    v_name   text;
    v_skew   boolean;
BEGIN
    IF v_tables < 1 OR v_tables > 200 THEN
        RAISE EXCEPTION 'pg_sta.bench_tables must be between 1 and 200 (got %)', v_tables;
    END IF;
    IF v_rows < 1 THEN
        RAISE EXCEPTION 'pg_sta.bench_rows must be positive (got %)', v_rows;
    END IF;

    FOR v_i IN 1..v_tables LOOP
        v_name := format('bench_%s', lpad(v_i::text, 2, '0'));

        -- The last table is skewed: 90 % of its rows share one customer.
        -- That is the relation where the planner estimates go wrong and
        -- where forcing a join method makes a measurable difference.
        v_skew := (v_i = v_tables);

        EXECUTE format('DROP TABLE IF EXISTS public.%I CASCADE', v_name);

        EXECUTE format($ddl$
            CREATE TABLE public.%I (
                id          bigint        NOT NULL,
                customer_id integer       NOT NULL,
                region      text          NOT NULL,
                status      text          NOT NULL,
                amount      numeric(12,2) NOT NULL,
                quantity    integer       NOT NULL,
                placed_at   timestamp     NOT NULL,
                reference   text          NOT NULL
            )
        $ddl$, v_name);

        EXECUTE format('COMMENT ON TABLE public.%I IS %L', v_name,
                       'pg_sta benchmark table');

        EXECUTE format($ins$
            INSERT INTO public.%I
                 (id, customer_id, region, status, amount, quantity, placed_at, reference)
            SELECT g,
                   CASE WHEN %L THEN CASE WHEN g %% 10 = 0 THEN (g %% 50000) + 1 ELSE 0 END
                        ELSE (g %% 50000) + 1 END,
                   (ARRAY['eu','us','apac','latam','emea'])[1 + (g %% 5)],
                   (ARRAY['new','packed','shipped','delivered',
                          'cancelled','returned','backordered'])[1 + (g %% 7)],
                   ((g %% 99991) + 1)::numeric / 100,
                   1 + (g %% 25),
                   timestamp '2024-01-01' + ((g %% 365) * interval '1 day'),
                   'REF-' || lpad(g::text, 12, '0')
              FROM generate_series(1, %s) g
        $ins$, v_name, v_skew, v_rows);
    END LOOP;
END
$bench$;

-- A primary key on a few of the relations, so that the statistics advisor
-- has both "no index at all" and "has a primary key but no other index"
-- to tell apart.
DO $bench_pk$
DECLARE
    v_tables int := current_setting('pg_sta.bench_tables')::int;
    v_i      int;
    v_name   text;
BEGIN
    FOR v_i IN 1..v_tables LOOP
        CONTINUE WHEN v_i % 6 <> 1;    -- bench_01, bench_07, bench_13, bench_19, ...
        v_name := format('bench_%s', lpad(v_i::text, 2, '0'));
        EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I PRIMARY KEY (id)',
                       v_name, format('%s_pkey', v_name));
    END LOOP;
END
$bench_pk$;
