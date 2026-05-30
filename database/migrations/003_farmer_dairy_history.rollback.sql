-- =============================================================================
-- PashuLedger V2 — Migration 003 ROLLBACK
--
-- ⚠️  SAFE IN: development, staging
-- ⚠️  PRODUCTION ROLLBACK: only if no application code has started reading
--    from farmer_dairy_history yet. Once the V2 reporting queries use this
--    table, rolling back destroys historical tracking data.
--
-- Pre-rollback check (run this first):
--   SELECT COUNT(*) FROM farmer_dairy_history WHERE source != 'backfill';
--   → If result > 0, live data has been written. Do NOT rollback without
--     exporting this data first.
-- =============================================================================

-- Step 1: Detach trigger from farmers table first
DROP TRIGGER IF EXISTS farmers_dairy_change_trigger ON farmers;

-- Step 2: Drop the trigger function
DROP FUNCTION IF EXISTS record_farmer_dairy_change();

-- Step 3: Drop the point-in-time lookup function
DROP FUNCTION IF EXISTS get_farmer_dairy_at(INT, DATE);

-- Step 4: Drop views
DROP VIEW IF EXISTS v_farmer_current_dairy;

-- Step 5: Drop indexes (CONCURRENTLY to avoid locking)
DROP INDEX CONCURRENTLY IF EXISTS idx_fdh_period_range;
DROP INDEX CONCURRENTLY IF EXISTS idx_fdh_doctor_id;
DROP INDEX CONCURRENTLY IF EXISTS idx_fdh_user_id;
DROP INDEX CONCURRENTLY IF EXISTS idx_fdh_dairy_period;
DROP INDEX CONCURRENTLY IF EXISTS idx_fdh_farmer_all;
DROP INDEX CONCURRENTLY IF EXISTS idx_fdh_farmer_current;

-- Step 6: Drop the history table (all data is lost)
DROP TABLE IF EXISTS farmer_dairy_history;

-- Step 7: Drop btree_gist extension only if nothing else uses it
-- (Safe to leave — it's harmless if present but unused)
-- DROP EXTENSION IF EXISTS btree_gist;

-- farmers.dairy_id, visits.dairy_id, and all other tables are UNTOUCHED.
