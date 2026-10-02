-- Migration: 20261003000001_block5_postgres_production_hardening.sql
-- Description: Block 5 PostgreSQL Production Hardening.
--              1. Hardens public.data_retention_policies primary key:
--                 Replaces the legacy single-column PRIMARY KEY (data_class) with a synthetic UUID primary key (id),
--                 allowing clinic-level retention policy overrides alongside platform defaults while maintaining
--                 the unique constraint on (COALESCE(clinic_id, '00000000-0000-0000-0000-000000000000'::uuid), data_class).
--              2. Consent Revocation Synchronization:
--                 Provides an automatic trigger on public.consultation_consents that synchronizes
--                 consent_status := 'revoked' whenever revoked_at is updated, and grants authenticated UPDATE
--                 on consent_status to allow clean, deterministic revocation from client and service layers.
--              3. Consultation Keyset Composite Indexes:
--                 Adds composite B-tree indexes for deterministic keyset pagination on consultations:
--                 - (patient_id, created_at DESC, id DESC) for patient-filtered consultation history
--                 - (clinic_id, created_at DESC, id DESC) for clinic/doctor-dashboard consultation feeds.

-- 1. DATA RETENTION POLICIES PRIMARY KEY RESTRUCTURING
DO $$
BEGIN
    -- Check if data_retention_policies still has the legacy data_class primary key constraint
    IF EXISTS (
        SELECT 1
        FROM information_schema.table_constraints
        WHERE table_schema = 'public'
          AND table_name = 'data_retention_policies'
          AND constraint_type = 'PRIMARY KEY'
          AND constraint_name = 'data_retention_policies_pkey'
    ) THEN
        ALTER TABLE public.data_retention_policies DROP CONSTRAINT data_retention_policies_pkey;
    END IF;

    -- Add synthetic id UUID column if not present
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'data_retention_policies'
          AND column_name = 'id'
    ) THEN
        ALTER TABLE public.data_retention_policies ADD COLUMN id UUID DEFAULT gen_random_uuid();
        -- Populate id for any existing records
        UPDATE public.data_retention_policies SET id = gen_random_uuid() WHERE id IS NULL;
        ALTER TABLE public.data_retention_policies ALTER COLUMN id SET NOT NULL;
    END IF;

    -- Ensure id is the primary key
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.table_constraints
        WHERE table_schema = 'public'
          AND table_name = 'data_retention_policies'
          AND constraint_type = 'PRIMARY KEY'
    ) THEN
        ALTER TABLE public.data_retention_policies ADD PRIMARY KEY (id);
    END IF;
END $$;

-- Verify/ensure the unique index exists for (clinic_id, data_class)
CREATE UNIQUE INDEX IF NOT EXISTS idx_retention_policies_clinic_class
    ON public.data_retention_policies (COALESCE(clinic_id, '00000000-0000-0000-0000-000000000000'::uuid), data_class);

-- 2. CONSENT REVOCATION SYNCHRONIZATION TRIGGER & GRANT
-- Trigger function: Automatically set consent_status := 'revoked' when revoked_at is provided
CREATE OR REPLACE FUNCTION public.sync_consent_revocation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.revoked_at IS NOT NULL AND NEW.consent_status <> 'revoked' THEN
        NEW.consent_status := 'revoked';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_consent_revocation ON public.consultation_consents;
CREATE TRIGGER trg_sync_consent_revocation
    BEFORE INSERT OR UPDATE ON public.consultation_consents
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_consent_revocation();

-- Grant authenticated role UPDATE permission on consent_status (alongside existing revoked_at)
GRANT UPDATE (consent_status, revoked_at) ON public.consultation_consents TO authenticated;

-- 3. KEYSET PAGINATION COMPOSITE INDEXES ON CONSULTATIONS
-- Keyset cursor query: WHERE patient_id = :patient_id AND (created_at, id) < (:t, :id) ORDER BY created_at DESC, id DESC
CREATE INDEX IF NOT EXISTS idx_consultations_patient_created_at_id
    ON public.consultations (patient_id, created_at DESC, id DESC);

-- Keyset cursor query: WHERE clinic_id = :clinic_id AND (created_at, id) < (:t, :id) ORDER BY created_at DESC, id DESC
CREATE INDEX IF NOT EXISTS idx_consultations_clinic_created_at_id
    ON public.consultations (clinic_id, created_at DESC, id DESC);
