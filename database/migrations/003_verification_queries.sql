-- =============================================================================
-- PashuLedger V2 — Migration 003 VERIFICATION
-- Run after the forward migration. Each check has an expected result.
-- =============================================================================


-- CHECK 1: Table exists with correct columns
-- Expected: all 12 columns present with correct types
SELECT
  column_name,
  data_type,
  is_nullable,
  column_default
FROM information_schema.columns
WHERE table_name = 'farmer_dairy_history'
  AND table_schema = 'public'
ORDER BY ordinal_position;
/*
Expected columns (in order):
  id            | uuid        | NO  | gen_random_uuid()
  farmer_id     | integer     | NO  | NULL
  dairy_id      | integer     | YES | NULL
  user_id       | integer     | YES | NULL
  doctor_id     | uuid        | YES | NULL
  started_at    | date        | NO  | NULL
  ended_at      | date        | YES | NULL
  change_reason | text        | YES | NULL
  source        | varchar(20) | NO  | 'manual'
  created_at    | timestamptz | NO  | now()
  updated_at    | timestamptz | NO  | now()
*/


-- CHECK 2: Foreign keys are correct
SELECT
  tc.table_name,
  kcu.column_name,
  ccu.table_name  AS references_table,
  ccu.column_name AS references_column,
  rc.delete_rule
FROM information_schema.table_constraints AS tc
JOIN information_schema.key_column_usage AS kcu
  ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.constraint_column_usage AS ccu
  ON ccu.constraint_name = tc.constraint_name
JOIN information_schema.referential_constraints AS rc
  ON rc.constraint_name = tc.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_name = 'farmer_dairy_history'
ORDER BY kcu.column_name;
/*
Expected:
  farmer_dairy_history | dairy_id  | dairies | id | SET NULL
  farmer_dairy_history | doctor_id | doctors | id | SET NULL
  farmer_dairy_history | farmer_id | farmers | id | CASCADE
  farmer_dairy_history | user_id   | users   | id | CASCADE
*/


-- CHECK 3: All 6 indexes exist
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'farmer_dairy_history'
  AND schemaname = 'public'
ORDER BY indexname;
/*
Expected: 7 rows (1 primary key + 6 explicit indexes)
  farmer_dairy_history_pkey
  idx_fdh_dairy_period
  idx_fdh_doctor_id
  idx_fdh_farmer_all
  idx_fdh_farmer_current
  idx_fdh_period_range
  idx_fdh_user_id
*/


-- CHECK 4: Trigger exists and is attached to farmers table
SELECT
  trigger_name,
  event_manipulation,
  event_object_table,
  action_timing,
  action_orientation
FROM information_schema.triggers
WHERE trigger_name = 'farmers_dairy_change_trigger'
  AND trigger_schema = 'public';
/*
Expected:
  farmers_dairy_change_trigger | UPDATE | farmers | AFTER | ROW
*/


-- CHECK 5: Backfill ran correctly
-- Expected: farmer_dairy_history row count = farmers row count
SELECT
  (SELECT COUNT(*) FROM farmers)               AS total_farmers,
  (SELECT COUNT(*) FROM farmer_dairy_history)  AS total_history_rows,
  (SELECT COUNT(*) FROM farmer_dairy_history
   WHERE source = 'backfill')                  AS backfill_rows,
  (SELECT COUNT(*) FROM farmer_dairy_history
   WHERE ended_at IS NULL)                     AS currently_active;
/*
Expected: total_farmers = total_history_rows = backfill_rows = currently_active
(All existing farmers have exactly one open-ended backfill record)
*/


-- CHECK 6: Verify backfill data matches farmers.dairy_id
-- Expected: 0 rows (no mismatches between backfill and current farmer data)
SELECT
  f.id          AS farmer_id,
  f.name        AS farmer_name,
  f.dairy_id    AS farmer_current_dairy,
  fdh.dairy_id  AS history_dairy,
  fdh.source
FROM farmers f
JOIN farmer_dairy_history fdh
  ON fdh.farmer_id = f.id
  AND fdh.ended_at IS NULL
WHERE f.dairy_id IS DISTINCT FROM fdh.dairy_id;
/*
Expected: 0 rows
If rows appear here, the backfill or trigger created a mismatch.
*/


-- CHECK 7: View v_farmer_current_dairy works
SELECT
  farmer_id,
  farmer_name,
  current_dairy_id,
  current_dairy_name,
  at_dairy_since
FROM v_farmer_current_dairy
LIMIT 5;
/*
Expected: same results as:
  SELECT f.id, f.name, d.id, d.name FROM farmers f LEFT JOIN dairies d ON f.dairy_id = d.id
*/


-- CHECK 8: Test point-in-time function
-- Replace 1 with an actual farmer_id from your data
-- Replace the date with one after that farmer's created_at
SELECT * FROM get_farmer_dairy_at(1, CURRENT_DATE);
/*
Expected: one row with the current dairy for farmer 1
*/


-- CHECK 9: Trigger fires correctly (TEST — run in dev/staging only)
-- This simulates changing a farmer's dairy and verifies history is recorded
-- DO NOT run in production as it modifies real data
--
-- BEGIN;
--   -- Remember current state
--   SELECT id, dairy_id FROM farmers WHERE id = 1;  -- note current dairy
--
--   -- Simulate dairy change (use a valid dairy_id from your data)
--   UPDATE farmers SET dairy_id = 2 WHERE id = 1;
--
--   -- Check that history was updated
--   SELECT * FROM farmer_dairy_history WHERE farmer_id = 1 ORDER BY started_at DESC;
--   -- Expected: old record has ended_at = CURRENT_DATE - 1
--   --           new record has ended_at = NULL, started_at = CURRENT_DATE
--
-- ROLLBACK;  -- ← rolls back the farmer update AND the history records (they're in same txn)


-- CHECK 10: Confirm existing tables are completely untouched
-- Expected: same column list as before migration 003
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name IN ('farmers', 'dairies', 'visits', 'users')
  AND table_schema = 'public'
ORDER BY table_name, ordinal_position;
/*
No new columns should appear on these tables.
(farmers.doctor_id and dairies.doctor_id were added in Migration 002)
*/
