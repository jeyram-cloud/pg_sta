-- ---------------------------------------------------------------------------
-- pg_sta sample workload
--
-- The statements below are executed many times, so that pg_stat_statements
-- holds a workload and the advisor has something to report on.
--
-- The statements are sent with \gexec, which sends every returned row as its
-- own top level statement.  That matters: pg_stat_statements only tracks
-- top level statements by default (track = 'top'), so a PL/pgSQL loop
-- would be invisible to it.
--
-- The number of iterations comes from the psql variable "iterations"; the
-- loader passes it with -v iterations=N.  The default is high enough to
-- cross the high_frequency_calls threshold (100 calls).
--
-- Run it with:
--
--   psql -d appdb -v iterations=120 -f sql/sample_workload.sql
-- ---------------------------------------------------------------------------

\set ON_ERROR_STOP on

-- The workload is measured, not read: discard the output of the generated
-- statements so that loading the workload does not flood the terminal.
\o /dev/null

-- Fall back to a default iteration count when the caller did not pass one.
\if :{?iterations}
\else
\set iterations 120
\endif

-- 1. A sequential scan with a filter.  This is the statement that produces
--    the index candidate: orders.customer_id is not indexed.
SELECT 'SELECT * FROM public.orders WHERE customer_id = 42;'
  FROM generate_series(1, :'iterations');
\gexec

-- 2. The join of the documentation example.
SELECT 'SELECT o.id, o.amount, c.region FROM public.orders o JOIN public.customers c ON c.id = o.customer_id WHERE c.region = ''eu'';'
  FROM generate_series(1, :'iterations');
\gexec

-- 3. An aggregate with a sort.
SELECT 'SELECT o.status, count(*) AS n, sum(o.amount) AS total FROM public.orders o GROUP BY o.status ORDER BY 2 DESC;'
  FROM generate_series(1, :'iterations');
\gexec

-- 4. A small result set produced by a sort over many rows.
SELECT 'SELECT id, customer_id, amount FROM public.orders WHERE status = ''new'' ORDER BY placed_at DESC LIMIT 50;'
  FROM generate_series(1, :'iterations');
\gexec

-- 5. A cheap counter, so that the workload also contains a statement that
--    is fast and frequent.
SELECT 'SELECT count(*) FROM public.orders;'
  FROM generate_series(1, :'iterations');
\gexec

\o
