-- =============================================================================
-- PashuLedger V2 — Migration 003
-- Title: Farmer Dairy History — Point-in-time dairy tracking
-- Depends on: Migration 001 (doctors), Migration 002 (doctor_id columns)
-- Backward compatible: YES
--   → No existing tables modified
--   → farmers.dairy_id is NOT touched (still the live "current dairy" pointer)
--   → visits.dairy_id is NOT touched (still the snapshotted dairy at visit time)
--   → All existing queries continue to work without any code changes
-- Idempotent: YES — safe to re-run; all DDL uses IF NOT EXISTS
-- Run on: Supabase SQL Editor or psql
-- Estimated runtime: < 3 seconds on current data size
-- =============================================================================


-- =============================================================================
-- BACKGROUND: THE TWO EXISTING dairy_id COLUMNS AND THEIR PROBLEMS
--
-- farmers.dairy_id  → "which dairy does this farmer sell milk to TODAY"
--   Problem: overwrites the old value when a farmer switches dairy.
--            No record of when they were at their previous dairy.
--
-- visits.dairy_id   → snapshot of farmers.dairy_id at the moment of INSERT
--   Problem: correctly captures "which dairy at visit time" (good design!)
--            BUT: if visits are edited (PUT /visits/:id), the dairy_id is
--            re-read from farmers.dairy_id at edit time — which may already
--            have changed. Historical visit accuracy degrades on edits.
--            Also: provides no "effective period" — just a point snapshot.
--
-- farmer_dairy_history solves BOTH problems by recording the full timeline:
-- when each farmer was at each dairy, with start and end dates.
-- =============================================================================


-- =============================================================================
-- STEP 1 — Enable required extensions
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS "pgcrypto";    -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "btree_gist";  -- for the EXCLUDE constraint (overlap prevention)


-- =============================================================================
-- STEP 2 — Create farmer_dairy_history table
-- =============================================================================
CREATE TABLE IF NOT EXISTS farmer_dairy_history (

  -- ── Identity ──────────────────────────────────────────────────────────────
  id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),

  -- ── Core relationship ─────────────────────────────────────────────────────
  farmer_id     INT           NOT NULL
                REFERENCES farmers(id) ON DELETE CASCADE,
                -- CASCADE: if farmer is deleted, all their history is deleted too.
                -- This is correct — history has no meaning without the farmer.

  dairy_id      INT
                REFERENCES dairies(id) ON DELETE SET NULL,
                -- SET NULL: if a dairy is deleted, preserve the history row
                -- but null out the dairy reference. The period still tells you
                -- "this farmer was at some dairy from X to Y" even if the dairy
                -- record itself is gone. NEVER lose the date range.

  -- ── V2 identity (future: populated when doctor_id backfill runs) ──────────
  user_id       INT           REFERENCES users(id) ON DELETE CASCADE,
  doctor_id     UUID          REFERENCES doctors(id) ON DELETE SET NULL,
  -- Rationale: both identity columns included now, same pattern as Migration 002.
  -- user_id is the active auth column; doctor_id is NULL until Phase 3 backfill.

  -- ── Effective period ─────────────────────────────────────────────────────
  -- These two columns together define WHEN the farmer was at this dairy.
  --
  -- started_at:  the date this farmer began selling milk at this dairy.
  --              For backfill of existing data: use farmers.created_at.
  --              For new records: set to CURRENT_DATE when dairy_id changes.
  --
  -- ended_at:    the day BEFORE the farmer moved to the next dairy.
  --              NULL means "this is the current, active dairy" (open-ended).
  --              When a farmer switches dairy:
  --                UPDATE ... SET ended_at = CURRENT_DATE - 1 WHERE ended_at IS NULL
  --              This keeps periods non-overlapping and correct.
  started_at    DATE          NOT NULL,
  ended_at      DATE,
                -- NULL = still active at this dairy

  -- ── Why this farmer changed (for analytics and admin context) ────────────
  -- Optional free-text note set by the doctor at the time of the change.
  -- Examples: "Farmer requested transfer", "Better rate at Amul dairy"
  change_reason TEXT,

  -- ── How this record was created ──────────────────────────────────────────
  -- Distinguishes backfill rows (from existing data) from live tracked rows
  -- (from the new trigger or API). Important for analytics accuracy.
  source        VARCHAR(20)   NOT NULL DEFAULT 'manual'
                CHECK (source IN (
                  'backfill',   -- created by migration 003 backfill script
                  'manual',     -- doctor explicitly updated farmer's dairy
                  'trigger',    -- created automatically by DB trigger (Step 5)
                  'api',        -- created by V2 API endpoint
                  'import'      -- future: bulk import from CSV
                )),

  -- ── Timestamps ───────────────────────────────────────────────────────────
  created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW()

  -- ── Overlap prevention constraint ────────────────────────────────────────
  -- A farmer cannot be at two different dairies during overlapping periods.
  -- Uses GIST index with daterange type (requires btree_gist extension).
  -- The constraint is DEFERRABLE so the backfill transaction can temporarily
  -- have overlaps mid-batch before they're resolved.
  --
  -- Syntax: EXCLUDE USING gist (
  --   farmer_id WITH =,
  --   daterange(started_at, ended_at, '[)') WITH &&
  -- )
  -- Explanation:
  --   farmer_id WITH =      → same farmer
  --   daterange(...) WITH &&  → date ranges that overlap
  --   [)  → inclusive start, exclusive end (standard for date ranges)
  --
  -- Note: ended_at = NULL is treated as "open-ended to infinity" by daterange.
  -- A new open-ended record (ended_at NULL) for a farmer will correctly conflict
  -- with any existing open-ended record for the same farmer.
  --
  -- Commented out for now — uncomment after verifying btree_gist is available
  -- in your Supabase project tier.
  --
  -- CONSTRAINT no_overlapping_dairy_periods EXCLUDE USING gist (
  --   farmer_id   WITH =,
  --   daterange(started_at, COALESCE(ended_at, '9999-12-31'::date), '[)') WITH &&
  -- ) DEFERRABLE INITIALLY DEFERRED

);

COMMENT ON TABLE farmer_dairy_history IS
  'Complete audit trail of which dairy each farmer was enrolled at, and during '
  'which period. The active record is the row where ended_at IS NULL. '
  'Replaces the single farmers.dairy_id pointer for all historical queries.';

COMMENT ON COLUMN farmer_dairy_history.started_at IS
  'The first date this farmer was enrolled at this dairy. Inclusive.';

COMMENT ON COLUMN farmer_dairy_history.ended_at IS
  'The last date this farmer was enrolled at this dairy. Inclusive. '
  'NULL means currently active at this dairy.';

COMMENT ON COLUMN farmer_dairy_history.source IS
  'How this record was created: backfill/manual/trigger/api/import.';


-- =============================================================================
-- STEP 3 — Indexes
-- =============================================================================

-- Primary lookup: "what is the current dairy for farmer X?"
-- This is the query the app runs most often (on every visit create/edit).
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_fdh_farmer_current
  ON farmer_dairy_history(farmer_id)
  WHERE ended_at IS NULL;
  -- Partial index — only open-ended (active) records. Fast and tiny.
  -- Guarantees O(1) lookup for current dairy regardless of history length.

-- "all history for farmer X" — farmer profile page, audit view
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_fdh_farmer_all
  ON farmer_dairy_history(farmer_id, started_at DESC);

-- "all farmers ever at dairy Y during period Z" — dairy report, analytics
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_fdh_dairy_period
  ON farmer_dairy_history(dairy_id, started_at, ended_at)
  WHERE dairy_id IS NOT NULL;

-- "all changes by this doctor" — doctor-scoped history (V1 path)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_fdh_user_id
  ON farmer_dairy_history(user_id);

-- V2 path — will be used once doctor_id backfill runs
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_fdh_doctor_id
  ON farmer_dairy_history(doctor_id)
  WHERE doctor_id IS NOT NULL;

-- Date range queries: "which farmer was at dairy X on date Y?"
-- Covering index for the most common historical report join
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_fdh_period_range
  ON farmer_dairy_history(farmer_id, started_at, ended_at);


-- =============================================================================
-- STEP 4 — Auto-update updated_at trigger
-- (Reuses the set_updated_at() function created in Migration 001)
-- =============================================================================
DROP TRIGGER IF EXISTS fdh_set_updated_at ON farmer_dairy_history;
CREATE TRIGGER fdh_set_updated_at
  BEFORE UPDATE ON farmer_dairy_history
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();
  -- set_updated_at() was created in Migration 001. If running this migration
  -- in isolation (fresh DB), create it first:
  --
  -- CREATE OR REPLACE FUNCTION set_updated_at()
  -- RETURNS TRIGGER AS $$
  -- BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
  -- $$ LANGUAGE plpgsql;


-- =============================================================================
-- STEP 5 — Automatic history trigger on farmers.dairy_id changes
--
-- When a doctor updates a farmer's dairy (PUT /api/farmers/:id),
-- this trigger automatically:
--   1. Closes the current open history record (sets ended_at = CURRENT_DATE - 1)
--   2. Opens a new history record (started_at = CURRENT_DATE, ended_at = NULL)
--
-- This removes the need to manually manage history records in application code
-- for the most common case (farmer switches dairy via the edit farmer form).
-- =============================================================================

CREATE OR REPLACE FUNCTION record_farmer_dairy_change()
RETURNS TRIGGER AS $$
BEGIN
  -- Only fire when dairy_id actually changed (not on name/phone/village edits)
  -- and the new dairy is different from the old one (handles NULL→value,
  -- value→NULL, and value→different_value cases)
  IF (NEW.dairy_id IS DISTINCT FROM OLD.dairy_id) THEN

    -- Step A: Close the current open record for this farmer
    -- ended_at = NEW.updated_at::date - 1 day
    -- (the last day they were at the old dairy is the day before they switched)
    UPDATE farmer_dairy_history
    SET
      ended_at   = CURRENT_DATE - INTERVAL '1 day',
      updated_at = NOW()
    WHERE
      farmer_id  = NEW.id
      AND ended_at IS NULL;
    -- If no open record exists (e.g. first-time setup before backfill),
    -- this UPDATE affects 0 rows — that is safe and expected.

    -- Step B: Open a new record for the new dairy
    -- source = 'trigger' to distinguish from manual API inserts
    INSERT INTO farmer_dairy_history (
      farmer_id,
      dairy_id,
      user_id,
      started_at,
      ended_at,
      source
    ) VALUES (
      NEW.id,
      NEW.dairy_id,         -- NULL is valid: farmer left all dairies (independent)
      NEW.user_id,
      CURRENT_DATE,
      NULL,                 -- open-ended: currently active
      'trigger'
    );

  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Attach trigger to farmers table — fires AFTER every UPDATE
DROP TRIGGER IF EXISTS farmers_dairy_change_trigger ON farmers;
CREATE TRIGGER farmers_dairy_change_trigger
  AFTER UPDATE OF dairy_id ON farmers   -- only fires when dairy_id column changes
  FOR EACH ROW
  EXECUTE FUNCTION record_farmer_dairy_change();

COMMENT ON FUNCTION record_farmer_dairy_change() IS
  'Automatically maintains farmer_dairy_history when farmers.dairy_id changes. '
  'Closes the previous open-ended record and opens a new one. '
  'source = ''trigger'' distinguishes these from manual/API inserts.';


-- =============================================================================
-- STEP 6 — Row Level Security (consistent with Migrations 001 + 002)
-- =============================================================================
ALTER TABLE farmer_dairy_history ENABLE ROW LEVEL SECURITY;
-- Service role (Express backend) bypasses RLS automatically.
-- Zero-trust baseline: no permissive policies until explicitly needed.


-- =============================================================================
-- STEP 7 — Backfill existing farmers into history
--
-- Creates ONE history record per farmer using their current dairy_id.
-- started_at = farmers.created_at (best available approximation)
-- ended_at   = NULL (currently active — still at this dairy as far as we know)
-- source     = 'backfill'
--
-- This gives you a baseline history record for every farmer.
-- It does NOT tell you if they previously switched dairies — that history
-- is genuinely lost from the MVP data. But from this migration forward,
-- all dairy changes are captured.
--
-- IMPORTANT: Run this AFTER Step 5 trigger is in place, so any concurrent
-- farmer edits during the backfill window are also captured.
-- =============================================================================
INSERT INTO farmer_dairy_history (
  farmer_id,
  dairy_id,
  user_id,
  started_at,
  ended_at,
  source
)
SELECT
  f.id,
  f.dairy_id,                             -- current dairy (or NULL if independent)
  f.user_id,
  f.created_at::date,                     -- use account creation date as start
  NULL,                                   -- currently active
  'backfill'
FROM farmers f
WHERE
  -- Skip if a history record already exists for this farmer
  -- (idempotent: safe to re-run without creating duplicates)
  NOT EXISTS (
    SELECT 1
    FROM farmer_dairy_history fdh
    WHERE fdh.farmer_id = f.id
  );

-- Verify backfill:
-- SELECT COUNT(*) FROM farmers;                    -- should equal:
-- SELECT COUNT(*) FROM farmer_dairy_history;       -- same count (one row per farmer)


-- =============================================================================
-- STEP 8 — Convenience view: current dairy per farmer
--
-- This view replaces the simple "LEFT JOIN dairies d ON f.dairy_id = d.id"
-- pattern in reports.js and visits.js for the common "current dairy" case.
-- Existing code uses farmers.dairy_id directly — this view is for NEW
-- V2 query code that reads from history rather than the scalar column.
-- =============================================================================
CREATE OR REPLACE VIEW v_farmer_current_dairy AS
SELECT
  f.id                AS farmer_id,
  f.name              AS farmer_name,
  f.phone             AS farmer_phone,
  f.village           AS farmer_village,
  f.user_id,
  d.id                AS current_dairy_id,
  d.name              AS current_dairy_name,
  d.phone             AS current_dairy_phone,
  d.address           AS current_dairy_address,
  fdh.started_at      AS at_dairy_since,
  fdh.id              AS history_id
FROM farmers f
LEFT JOIN farmer_dairy_history fdh
  ON fdh.farmer_id = f.id
  AND fdh.ended_at IS NULL           -- only the open-ended (current) record
LEFT JOIN dairies d
  ON d.id = fdh.dairy_id;

COMMENT ON VIEW v_farmer_current_dairy IS
  'Current dairy for each farmer, resolved through farmer_dairy_history. '
  'Use this instead of "JOIN dairies d ON f.dairy_id = d.id" in V2 queries.';


-- =============================================================================
-- STEP 9 — Point-in-time lookup function
--
-- Given a farmer_id and a target date, returns which dairy that farmer
-- was enrolled at on that specific date.
--
-- Usage: SELECT * FROM get_farmer_dairy_at(42, '2025-11-15');
--
-- Used by:
--   - Historical visit accuracy queries
--   - PDF report: "which dairy was this farmer at on this visit date?"
--   - Future analytics: "dairy performance on a given date"
-- =============================================================================
CREATE OR REPLACE FUNCTION get_farmer_dairy_at(
  p_farmer_id  INT,
  p_date       DATE
)
RETURNS TABLE (
  dairy_id    INT,
  dairy_name  VARCHAR,
  started_at  DATE,
  ended_at    DATE
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    d.id,
    d.name,
    fdh.started_at,
    fdh.ended_at
  FROM farmer_dairy_history fdh
  LEFT JOIN dairies d ON d.id = fdh.dairy_id
  WHERE
    fdh.farmer_id  = p_farmer_id
    AND fdh.started_at <= p_date
    AND (fdh.ended_at IS NULL OR fdh.ended_at >= p_date)
  ORDER BY fdh.started_at DESC
  LIMIT 1;
END;
$$ LANGUAGE plpgsql STABLE;
-- STABLE: function reads DB but doesn't modify it; enables query optimizer caching

COMMENT ON FUNCTION get_farmer_dairy_at(INT, DATE) IS
  'Returns the dairy a farmer was enrolled at on a specific historical date. '
  'Returns empty if no history record covers that date (pre-backfill gap). '
  'Usage: SELECT * FROM get_farmer_dairy_at(42, ''2025-11-15'');';
