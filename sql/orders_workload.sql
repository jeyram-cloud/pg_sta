--
-- pg_sta workload for a typical e-commerce schema
--
-- Ten statements against the tables of the "appdb" schema (customers,
-- orders, order_details, products, inventory, employees, departments,
-- suppliers, payments, shipments).  Every statement has a different
-- problem for the advisor to find:
--
--   1  SELECT * on a million-row relation        -> projection, index
--   2  a join across two relations               -> index, join order
--   3  OR between two equality predicates         -> rewrite to IN
--   4  a function on the filtered column          -> sargable rewrite
--   5  the column is cast, not the literal        -> implicit cast
--   6  a leading wildcard                         -> trigram index
--   7  NOT IN with a subquery                     -> NOT EXISTS
--   8  OFFSET pagination                          -> keyset pagination
--   9  UNION between two branches                 -> UNION ALL
--  10  a plain equality on an unindexed column    -> index
--
-- Every statement is registered with sta.record() before it is run.
-- pg_stat_statements keeps the text of a statement with its constants
-- replaced by "$n", so the rules that depend on a value -- the implicit
-- cast, the literal of a function -- can never fire on the text that
-- pg_stat_statements stored.  sta.record() keeps the original text next to
-- the query id, and the advisor uses it in preference to the stored text.
--
-- The statements are plain top-level statements, so pg_stat_statements
-- records them with their real text when it tracks the top level (the
-- default).  Run the file twice and collect a snapshot after each round:
-- the advisor then sees the difference between the two rounds and can
-- report the statements that cost the most.
--
-- The statements return a handful of rows, so the workload is quick, but
-- every statement has to read a whole million-row relation because none of
-- the filtered columns is indexed.  That is exactly the situation the
-- advisor exists for.
--
-- Usage on the development VM:
--
--   psql -d appdb -f sql/orders_workload.sql
--   psql -d appdb -c 'SELECT sta.collect();'
--
-- The file checks that the relations it needs exist and stops with a clear
-- message when they do not.
--
\set ON_ERROR_STOP on

DO $$
DECLARE
    v_missing text;
BEGIN
    SELECT string_agg(t, ', ' ORDER BY t)
      INTO v_missing
      FROM unnest(ARRAY['customers', 'orders', 'order_details', 'products',
                        'inventory', 'employees', 'departments', 'suppliers',
                        'payments', 'shipments']) AS t
     WHERE to_regclass('public.' || t) IS NULL;

    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION
            'the workload needs these relations in the public schema: %', v_missing;
    END IF;
END
$$;

-- 1. SELECT * on a million-row relation
SELECT sta.record('SELECT * FROM orders WHERE customer_id = 42');
SELECT * FROM orders WHERE customer_id = 42;

-- 2. a join across two relations that both have no index on the join column
SELECT sta.record($$
    SELECT o.order_id, o.order_date, c.customer_name
      FROM orders o
      JOIN customers c ON c.customer_id = o.customer_id
     WHERE o.customer_id = 42
$$);
SELECT o.order_id, o.order_date, c.customer_name
  FROM orders o
  JOIN customers c ON c.customer_id = o.customer_id
 WHERE o.customer_id = 42;

-- 3. OR between two equality predicates on the same column
SELECT sta.record('SELECT * FROM orders WHERE customer_id = 42 OR customer_id = 43');
SELECT * FROM orders WHERE customer_id = 42 OR customer_id = 43;

-- 4. a function applied to the filtered column
SELECT sta.record('SELECT * FROM customers WHERE lower(customer_name) = ''john doe''');
SELECT * FROM customers WHERE lower(customer_name) = 'john doe';

-- 5. the column is cast to text instead of the literal
SELECT sta.record('SELECT * FROM payments WHERE amount::text = ''150.00''');
SELECT * FROM payments WHERE amount::text = '150.00';

-- 6. a leading wildcard
SELECT sta.record('SELECT * FROM customers WHERE customer_name LIKE ''%son''');
SELECT * FROM customers WHERE customer_name LIKE '%son';

-- 7. NOT IN with a subquery
SELECT sta.record($$
    SELECT * FROM orders
     WHERE customer_id NOT IN (SELECT customer_id FROM customers WHERE email LIKE '%@example.com')
$$);
SELECT * FROM orders
 WHERE customer_id NOT IN (SELECT customer_id FROM customers WHERE email LIKE '%@example.com');

-- 8. OFFSET pagination over a sorted million rows
SELECT sta.record('SELECT * FROM orders ORDER BY order_date LIMIT 20 OFFSET 10000');
SELECT * FROM orders ORDER BY order_date LIMIT 20 OFFSET 10000;

-- 9. UNION between two branches
SELECT sta.record($$
    SELECT order_id FROM orders WHERE customer_id = 42
    UNION
    SELECT order_id FROM orders WHERE customer_id = 43
$$);
SELECT order_id FROM orders WHERE customer_id = 42
UNION
SELECT order_id FROM orders WHERE customer_id = 43;

-- 10. a plain equality on an unindexed column
SELECT sta.record('SELECT * FROM shipments WHERE order_id = 100');
SELECT * FROM shipments WHERE order_id = 100;