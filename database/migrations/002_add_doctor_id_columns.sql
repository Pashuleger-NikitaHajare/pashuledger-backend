-- ============================================
-- Migration 002
-- Add doctor_id to core tables
-- Safe additive migration for SaaS V2
-- ============================================

-- ============================================
-- Add doctor_id to dairies
-- ============================================

ALTER TABLE dairies
ADD COLUMN IF NOT EXISTS doctor_id UUID
REFERENCES doctors(id)
ON DELETE SET NULL
DEFERRABLE INITIALLY DEFERRED;

-- ============================================
-- Add doctor_id to farmers
-- ============================================

ALTER TABLE farmers
ADD COLUMN IF NOT EXISTS doctor_id UUID
REFERENCES doctors(id)
ON DELETE SET NULL
DEFERRABLE INITIALLY DEFERRED;

-- ============================================
-- Add doctor_id to visits
-- ============================================

ALTER TABLE visits
ADD COLUMN IF NOT EXISTS doctor_id UUID
REFERENCES doctors(id)
ON DELETE SET NULL
DEFERRABLE INITIALLY DEFERRED;

-- ============================================
-- Indexes for dairies
-- ============================================

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_dairies_doctor_id
ON dairies(doctor_id)
WHERE doctor_id IS NOT NULL;

-- ============================================
-- Indexes for farmers
-- ============================================

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_farmers_doctor_id
ON farmers(doctor_id)
WHERE doctor_id IS NOT NULL;

-- ============================================
-- Indexes for visits
-- ============================================

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_visits_doctor_id
ON visits(doctor_id)
WHERE doctor_id IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_visits_doctor_date
ON visits(doctor_id, visit_date)
WHERE doctor_id IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_visits_doctor_payment
ON visits(doctor_id, payment_status)
WHERE doctor_id IS NOT NULL;

-- ============================================
-- Transition View
-- ============================================

CREATE OR REPLACE VIEW v_visits_with_owner AS
SELECT
    v.*,

    CASE
        WHEN v.doctor_id IS NOT NULL
        THEN v.doctor_id::TEXT
        ELSE v.user_id::TEXT
    END AS owner_id,

    CASE
        WHEN v.doctor_id IS NOT NULL
        THEN 'doctor'
        ELSE 'user'
    END AS owner_type

FROM visits v;

-- ============================================
-- Schema migration tracking
-- ============================================

CREATE TABLE IF NOT EXISTS schema_migrations (
    version VARCHAR(10) PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    applied_by TEXT NOT NULL DEFAULT current_user,
    notes TEXT
);

INSERT INTO schema_migrations (
    version,
    name,
    notes
)
VALUES (
    '002',
    'add_doctor_id_to_core_tables',
    'Phase 1 SaaS V2 additive migration'
)
ON CONFLICT (version) DO NOTHING;