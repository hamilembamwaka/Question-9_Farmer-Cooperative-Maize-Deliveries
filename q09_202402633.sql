-- ICT371 Advanced Database | Question 9: Farmer Cooperative Maize Deliveries
-- Student: Mwaka Hamilemba| Student No: 202402633

DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);
CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL,
    unit_rate    NUMERIC(10,2) NOT NULL,     -- filled in by the trigger
    total_value  NUMERIC(12,2) NOT NULL,     -- filled in by the trigger
    delivered_on DATE NOT NULL,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(14,2) NOT NULL,
    total_value   NUMERIC(14,2) NOT NULL
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Kalumba Mwewa'),
    ('F002', 'Mutinta Hachoose'),
    ('F003', 'Bwalya Chisanga');

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade VARCHAR)
RETURNS NUMERIC AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade must not be NULL';
    END IF;

    CASE p_grade
        WHEN 'A' THEN RETURN 5;
        WHEN 'B' THEN RETURN 4;
        WHEN 'C' THEN RETURN 3;
        ELSE RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
    END CASE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- (d) Trigger (installed BEFORE any delivery is loaded) -----------------------
CREATE OR REPLACE FUNCTION trg_delivery_pricing() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_delivery_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_delivery_pricing();

-- (c) Procedure (supplies only the basic fields; trigger supplies the price) ---
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INTEGER, p_grade VARCHAR,
                                                p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;
    IF p_grade IS NULL OR p_grade NOT IN ('A', 'B', 'C') THEN
        RAISE EXCEPTION 'Invalid grade: %', p_grade;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date is required';
    END IF;

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- (a) continued: six deliveries through the procedure (all grades, both states)
CALL pr_receive_delivery(1, 'A', 100, CURRENT_DATE - 2);
CALL pr_receive_delivery(1, 'B',  50, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'C', 200, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'A',  80, CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'B', 120, CURRENT_DATE - 2);
CALL pr_receive_delivery(3, 'C',  60, CURRENT_DATE);

UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 5, 6);   -- mix of paid / unpaid

SELECT * FROM deliveries ORDER BY delivery_id;

-- Tests
SELECT g AS grade, fn_maize_rate(g) AS rate FROM (VALUES ('A'), ('B'), ('C')) AS t(g);
DO $$
BEGIN
    BEGIN PERFORM fn_maize_rate(NULL);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN PERFORM fn_maize_rate('D');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_receive_delivery(1, 'A', 0, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    -- direct SQL gets the same pricing, and bad weight is rejected
    BEGIN INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
          VALUES (1, 'A', -5, 1, 1, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;
-- Direct insert with WRONG rate/value supplied: trigger overwrites them (should be 5 x 10 = 50)
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
VALUES (1, 'A', 10, 99, 99999, CURRENT_DATE - 3);
SELECT delivery_id, grade, weight_kg, unit_rate, total_value FROM deliveries
WHERE delivered_on = CURRENT_DATE - 3;   -- unit_rate 5, total_value 50.00

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value), 0) AS total_unpaid_value
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;   -- F003 shows 0

-- (f) Index ----------------------------------------------------------------
-- Equality on farmer_id then a range on delivered_on -> composite (farmer_id, delivered_on).
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;
SET enable_seqscan = off;   -- tiny table: force the plan to show the index
EXPLAIN
SELECT * FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
    FROM deliveries WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE      -- REPLACE the totals, never add to them
        SET total_weight = EXCLUDED.total_weight,
            total_value  = EXCLUDED.total_value;
END;
$$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);   -- rerun: same totals
SELECT * FROM daily_purchases;

-- Scheduling with pg_cron. If pg_cron is not installed, this prints a notice instead
-- of failing, so the rest of the script is not rolled back.
DO $do$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('refresh_purchases_daily', '30 1 * * *',
        $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron not available, job not scheduled: %', SQLERRM;
END $do$;

-- Inspect the job (works only where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, runid, status, return_message, start_time, end_time
--   FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;
