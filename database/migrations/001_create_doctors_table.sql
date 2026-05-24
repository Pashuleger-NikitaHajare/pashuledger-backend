-- =============================================================================
-- PashuLedger V2 — Migration 001
-- Table: doctors
-- Purpose: Future-ready SaaS multi-doctor architecture
-- Author: NSN Technologies Pvt. Ltd.
-- Safe to run on: Supabase PostgreSQL (pg 15+)
-- Backward compatible: YES — does NOT touch existing tables
-- Run method: Supabase SQL Editor → Run, or psql
-- Idempotent: YES — safe to run multiple times (IF NOT EXISTS throughout)
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 0 — Enable pgcrypto for gen_random_uuid()
-- Supabase enables this by default. Included here for self-hosted safety.
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "pgcrypto";


-- ---------------------------------------------------------------------------
-- STEP 1 — Create the doctors table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS doctors (

  -- Primary key: UUID, not SERIAL
  -- Reason: prevents user-count enumeration, safe for public URLs and APIs
  id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Core identity
  phone             VARCHAR(15)   NOT NULL,
  name              VARCHAR(100)  NOT NULL,

  -- Professional profile
  clinic_name       VARCHAR(150),                        -- nullable: not all rural doctors have a named clinic
  village           VARCHAR(100),                        -- primary practice location
  district          VARCHAR(100),                        -- Maharashtra district (Pune, Nashik, Aurangabad…)

  -- OTP authentication support
  -- otp is hashed (bcrypt) before storage — never store plaintext
  otp_hash          TEXT,                                -- bcrypt hash of current OTP; NULL when no active OTP
  otp_expires_at    TIMESTAMPTZ,                         -- OTP validity window (10 minutes recommended)
  otp_attempts      SMALLINT      NOT NULL DEFAULT 0,    -- wrong-attempt counter; lock at 5
  last_otp_sent_at  TIMESTAMPTZ,                         -- rate-limit OTP sends (max 1 per minute)

  -- Onboarding + admin approval workflow
  -- Valid status transitions:
  --   pending_approval → approved → active
  --   pending_approval → rejected
  --   active           → suspended
  --   suspended        → active  (admin re-activates)
  status            VARCHAR(30)   NOT NULL DEFAULT 'pending_approval'
                    CHECK (status IN (
                      'pending_approval',   -- just registered; awaiting admin review
                      'approved',           -- admin approved; doctor not yet logged in
                      'active',             -- fully onboarded and currently using the app
                      'suspended',          -- temporarily blocked by admin
                      'rejected'            -- registration denied
                    )),

  -- Optional: link to existing users table during transition period
  -- NULL = doctor has not yet been migrated / linked to a legacy user account
  -- Non-null = this doctor record is the V2 identity for users.id = legacy_user_id
  legacy_user_id    INTEGER       REFERENCES users(id) ON DELETE SET NULL,

  -- Admin notes (rejection reason, approval note, suspension reason)
  admin_notes       TEXT,

  -- Timestamps
  created_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  approved_at       TIMESTAMPTZ,                         -- set when status → approved
  last_login_at     TIMESTAMPTZ                          -- set on every successful OTP login

);


-- ---------------------------------------------------------------------------
-- STEP 2 — Indexes
-- ---------------------------------------------------------------------------

-- Phone is the primary lookup key for OTP flow (login, forgot, send-OTP)
-- UNIQUE enforces one account per doctor phone number
CREATE UNIQUE INDEX IF NOT EXISTS idx_doctors_phone
  ON doctors(phone);

-- Admin dashboard: filter by status (pending_approval queue, active users)
CREATE INDEX IF NOT EXISTS idx_doctors_status
  ON doctors(status);

-- Bridge query: look up the V2 doctor record for a V1 user
CREATE INDEX IF NOT EXISTS idx_doctors_legacy_user_id
  ON doctors(legacy_user_id)
  WHERE legacy_user_id IS NOT NULL;

-- OTP flow: quickly find unexpired OTP by phone (used in verify-otp endpoint)
CREATE INDEX IF NOT EXISTS idx_doctors_otp_expiry
  ON doctors(phone, otp_expires_at)
  WHERE otp_hash IS NOT NULL;


-- ---------------------------------------------------------------------------
-- STEP 3 — Auto-update updated_at on every row change
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop and recreate trigger (idempotent pattern for Supabase)
DROP TRIGGER IF EXISTS doctors_set_updated_at ON doctors;
CREATE TRIGGER doctors_set_updated_at
  BEFORE UPDATE ON doctors
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();


-- ---------------------------------------------------------------------------
-- STEP 4 — Row Level Security (Supabase-native)
-- Enable RLS so that Supabase's anon/service keys respect data boundaries.
-- All actual access control is still enforced in the Express backend via JWT.
-- This is a second layer of defence for direct Supabase client access.
-- ---------------------------------------------------------------------------
ALTER TABLE doctors ENABLE ROW LEVEL SECURITY;

-- Service role (used by your Express backend) bypasses RLS automatically.
-- No policy needed for backend access.

-- Anon/authenticated Supabase client: deny all by default.
-- Explicitly grant nothing — zero-trust baseline.
-- When you build Supabase client-side features (e.g. Supabase Auth),
-- add policies here per feature.

-- Example policy for future use (commented out — add when needed):
-- CREATE POLICY "doctors_read_own" ON doctors
--   FOR SELECT USING (auth.uid()::text = id::text);


-- ---------------------------------------------------------------------------
-- STEP 5 — Verification query
-- Run this after migration to confirm the table was created correctly.
-- ---------------------------------------------------------------------------
-- SELECT
--   column_name,
--   data_type,
--   is_nullable,
--   column_default
-- FROM information_schema.columns
-- WHERE table_name = 'doctors'
-- ORDER BY ordinal_position;
