-- ---------------------------------------------------------------------------
-- pg_sta sample data
--
-- Every example in README.md and in docs/usage.md uses two tables:
--
--   customers(id, name, region, country, created_at)
--   orders(id, customer_id, status, amount, quantity, placed_at)
--
-- This script creates them and fills them with a deterministic data set, so
-- that the documented examples run as written and produce the documented
-- output.
--
-- The data set is chosen to make the advisor say something useful:
--
--   * orders has 120000 rows, so a sequential scan over it is reported
--     (sta.threshold: seq_scan_min_rows = 1000);
--   * orders has no index on customer_id, so sta.index_advice() has an
--     index candidate to propose;
--   * customers is analyzed, orders is not, so sta.stats_advice() has a
--     "never analyzed" relation to report.
--
-- Nothing is ever dropped here.  The loader (scripts/load_sample_data.sh
-- --force) drops the tables before loading them, but only when they carry
-- the marker comment "pg_sta sample data".
--
-- Load it with:
--
--   ./scripts/pg_sta_ctl --database appdb load-sample-data
--
-- or directly:
--
--   psql -d appdb -f sql/sample_data.sql
-- ---------------------------------------------------------------------------

BEGIN;

-- The shape check.  A table that already exists and is not a pg_sta sample
-- table is a conflict: the script refuses to touch it instead of failing
-- later with a confusing "column does not exist" error.
DO $pg_sta_shape$
DECLARE
    v_conflicts text;
BEGIN
    SELECT string_agg(t, ', ')
      INTO v_conflicts
      FROM unnest(ARRAY['customers', 'orders']) AS t
     WHERE to_regclass('public.' || t) IS NOT NULL
       AND coalesce(
             (SELECT obj_description(c.oid, 'pg_class')
                FROM pg_class c
               WHERE c.oid = to_regclass('public.' || t)),
             '') NOT LIKE 'pg_sta sample data%';

    IF v_conflicts IS NOT NULL THEN
        RAISE EXCEPTION
          'pg_sta sample data: the table(s) % already exist and are not pg_sta sample tables. Rename or drop them before loading the sample data.',
          v_conflicts;
    END IF;
END
$pg_sta_shape$;

CREATE TABLE IF NOT EXISTS public.customers (
    id         integer     PRIMARY KEY,
    name       text        NOT NULL,
    region     text        NOT NULL,
    country    text        NOT NULL,
    created_at timestamptz NOT NULL
);

COMMENT ON TABLE public.customers IS
  'pg_sta sample data: the customers table used by the documentation examples';

CREATE TABLE IF NOT EXISTS public.orders (
    id          bigint        PRIMARY KEY,
    customer_id integer       NOT NULL,
    status      text          NOT NULL,
    amount      numeric(12,2) NOT NULL,
    quantity    integer       NOT NULL,
    placed_at   timestamptz   NOT NULL
);

COMMENT ON TABLE public.orders IS
  'pg_sta sample data: the orders table used by the documentation examples';

-- 2000 customers, spread over four regions.  A quarter of them is in the
-- "eu" region, which is the filter of the join example.
INSERT INTO public.customers (id, name, region, country, created_at)
SELECT g,
       'customer ' || lpad(g::text, 6, '0'),
       (ARRAY['eu', 'us', 'apac', 'latam'])[1 + (g % 4)],
       (ARRAY['de', 'fr', 'us', 'jp', 'br', 'in'])[1 + (g % 6)],
       timestamptz '2024-01-01 00:00:00+00' + (g || ' minutes')::interval
  FROM generate_series(1, 2000) AS g
ON CONFLICT (id) DO NOTHING;

-- 120000 orders, spread over the customers.  The order status and the
-- order date are skewed on purpose, so that the aggregate and the sort
-- examples have something to work with.
INSERT INTO public.orders (id, customer_id, status, amount, quantity, placed_at)
SELECT g,
       1 + ((g * 7919) % 2000),
       (ARRAY['new', 'paid', 'shipped', 'cancelled', 'refunded'])[1 + (g % 5)],
       round((10 + (g % 9000) * 1.37)::numeric, 2),
       1 + (g % 7),
       timestamptz '2024-06-01 00:00:00+00'
         + ((g % 90) || ' days')::interval
         + ((g % 24) || ' hours')::interval
  FROM generate_series(1, 120000) AS g
ON CONFLICT (id) DO NOTHING;

COMMIT;
