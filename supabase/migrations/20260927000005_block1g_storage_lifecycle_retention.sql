-- Migration: 20260927000005_block1g_storage_lifecycle_retention.sql
-- Description: Block 1G Storage Lifecycle, Retention Enforcement & Orphan Audio Cleanup.
--              Adds lifecycle tracking columns to public.recordings,
--              enhances public.data_retention_policies with clinic scoping and enablement status,
--              creates index for expired retention scans,
--              provides atomic claim, finalization, revert, and missing-object reconciliation RPCs,
--              and updates claim_recording_for_processing to strictly exclude pending_deletion recordings.

-- 1. Add deletion lifecycle metadata columns to public.recordings
ALTER TABLE public.recordings
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ NULL,
    ADD COLUMN IF NOT EXISTS deletion_attempted_at TIMESTAMPTZ NULL,
    ADD COLUMN IF NOT EXISTS deletion_error_code TEXT NULL;

-- 2. Enhance public.data_retention_policies with clinic scope, timestamps, and enabled flag
ALTER TABLE public.data_retention_policies
    ADD COLUMN IF NOT EXISTS clinic_id UUID NULL REFERENCES public.clinics(id) ON DELETE CASCADE,
    ADD COLUMN IF NOT EXISTS is_enabled BOOLEAN NOT NULL DEFAULT true,
    ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- Unique constraint index for clinic-specific data class overrides
CREATE UNIQUE INDEX IF NOT EXISTS idx_retention_policies_clinic_class
    ON public.data_retention_policies (COALESCE(clinic_id, '00000000-0000-0000-0000-000000000000'::uuid), data_class);

-- 3. Partial index for fast, scalable retention candidate scans
-- Only indexes active, un-held recordings with an expiration timestamp
CREATE INDEX IF NOT EXISTS idx_recordings_retention_scan
    ON public.recordings (retention_expires_at ASC)
    WHERE deletion_status = 'active' AND legal_hold = false;

-- 4. Function: Resolve active retention policy (Clinic override > Platform default > Fail closed)
CREATE OR REPLACE FUNCTION public.resolve_retention_policy(
    p_clinic_id UUID,
    p_data_class public.data_retention_class DEFAULT 'raw_audio'
)
RETURNS TABLE (
    retention_days INTEGER,
    legal_hold_default BOOLEAN,
    is_enabled BOOLEAN,
    scope TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_rec RECORD;
BEGIN
    -- 1. Check clinic-specific override first
    IF p_clinic_id IS NOT NULL THEN
        SELECT p.retention_days, p.legal_hold_default, p.is_enabled, 'clinic' AS scope
        INTO v_rec
        FROM public.data_retention_policies p
        WHERE p.clinic_id = p_clinic_id
          AND p.data_class = p_data_class
        LIMIT 1;

        IF FOUND THEN
            RETURN QUERY SELECT v_rec.retention_days, v_rec.legal_hold_default, v_rec.is_enabled, v_rec.scope;
            RETURN;
        END IF;
    END IF;

    -- 2. Fall back to global platform default
    SELECT p.retention_days, p.legal_hold_default, p.is_enabled, 'global' AS scope
    INTO v_rec
    FROM public.data_retention_policies p
    WHERE p.clinic_id IS NULL
      AND p.data_class = p_data_class
    LIMIT 1;

    IF FOUND THEN
        RETURN QUERY SELECT v_rec.retention_days, v_rec.legal_hold_default, v_rec.is_enabled, v_rec.scope;
        RETURN;
    END IF;

    -- 3. Fail closed: return NULL retention_days (safe inert retention)
    RETURN QUERY SELECT NULL::INTEGER, false, false, 'unresolved'::TEXT;
END;
$$;

-- 5. Function: Atomic retention deletion claim
-- Claims an expired, non-processing, non-held recording for deletion
CREATE OR REPLACE FUNCTION public.claim_recording_for_retention_deletion(
    p_recording_id UUID,
    p_worker_id TEXT DEFAULT 'retention_cleanup_worker'
)
RETURNS TABLE (
    id UUID,
    storage_path TEXT,
    consultation_id UUID,
    patient_id UUID,
    doctor_id UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_now TIMESTAMPTZ := now();
BEGIN
    RETURN QUERY
    UPDATE public.recordings r
    SET
        deletion_status = 'pending_deletion',
        deletion_attempted_at = v_now,
        deletion_error_code = NULL
    WHERE r.id = p_recording_id
      AND r.deletion_status = 'active'
      AND r.legal_hold = false
      -- Guard against active processing: cannot be in any active processing stage
      AND r.processing_status NOT IN ('pending', 'queued', 'transcribing', 'structuring')
      -- Guard against active leases: cannot have an unexpired lease
      AND (r.lease_expires_at IS NULL OR r.lease_expires_at < v_now)
      -- Retention window must be explicitly defined and expired
      AND r.retention_expires_at IS NOT NULL
      AND r.retention_expires_at <= v_now
    RETURNING
        r.id,
        r.storage_path,
        r.consultation_id,
        r.patient_id,
        r.doctor_id;
END;
$$;

-- 6. Function: Finalize recording deletion after storage object is removed
CREATE OR REPLACE FUNCTION public.finalize_recording_deletion(
    p_recording_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE public.recordings
    SET
        deletion_status = 'deleted',
        deleted_at = now(),
        deletion_error_code = NULL
    WHERE id = p_recording_id
      AND deletion_status = 'pending_deletion';

    RETURN FOUND;
END;
$$;

-- 7. Function: Revert deletion claim if storage removal fails
CREATE OR REPLACE FUNCTION public.revert_recording_deletion(
    p_recording_id UUID,
    p_error_code TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE public.recordings
    SET
        deletion_status = 'active',
        deletion_error_code = p_error_code
    WHERE id = p_recording_id
      AND deletion_status = 'pending_deletion';

    RETURN FOUND;
END;
$$;

-- 8. Function: Reconcile missing storage object (database orphan reconciliation)
CREATE OR REPLACE FUNCTION public.reconcile_missing_recording_storage(
    p_recording_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE public.recordings
    SET
        deletion_status = 'deleted',
        deleted_at = now(),
        deletion_error_code = 'STORAGE_OBJECT_NOT_FOUND'
    WHERE id = p_recording_id
      AND deletion_status IN ('active', 'pending_deletion');

    RETURN FOUND;
END;
$$;

-- 9. Update claim_recording_for_processing to strictly require deletion_status = 'active'
-- This prevents race conditions where processing tries to claim a recording already under deletion claim
CREATE OR REPLACE FUNCTION public.claim_recording_for_processing(
    p_recording_id UUID,
    p_worker_id TEXT,
    p_lease_duration_seconds INTEGER DEFAULT 180
)
RETURNS TABLE (
    id UUID,
    consultation_id UUID,
    patient_id UUID,
    doctor_id UUID,
    storage_path TEXT,
    processing_status public.recording_processing_status,
    attempt_count INTEGER,
    lease_expires_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_now TIMESTAMPTZ := now();
    v_lease_expiry TIMESTAMPTZ := v_now + (p_lease_duration_seconds || ' seconds')::INTERVAL;
BEGIN
    RETURN QUERY
    UPDATE public.recordings r
    SET
        processing_status = 'transcribing',
        processing_started_at = COALESCE(r.processing_started_at, v_now),
        last_attempt_at = v_now,
        attempt_count = r.attempt_count + 1,
        lease_worker_id = p_worker_id,
        lease_expires_at = v_lease_expiry,
        last_error_code = NULL,
        last_error_message = NULL
    WHERE r.id = p_recording_id
      AND r.deletion_status = 'active'
      AND (
          -- Unprocessed or queued
          r.processing_status IN ('pending', 'queued')
          -- Retriable failed job within max attempts
          OR (r.processing_status = 'failed' AND r.attempt_count < r.max_attempts)
          -- Stale lease recovery (worker crashed mid-flight)
          OR (r.processing_status IN ('transcribing', 'structuring') AND r.lease_expires_at IS NOT NULL AND r.lease_expires_at < v_now)
      )
    RETURNING
        r.id,
        r.consultation_id,
        r.patient_id,
        r.doctor_id,
        r.storage_path,
        r.processing_status,
        r.attempt_count,
        r.lease_expires_at;
END;
$$;

-- Grant permissions to authenticated & service_role
GRANT EXECUTE ON FUNCTION public.resolve_retention_policy(UUID, public.data_retention_class) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.claim_recording_for_retention_deletion(UUID, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.finalize_recording_deletion(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.revert_recording_deletion(UUID, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reconcile_missing_recording_storage(UUID) TO authenticated, service_role;
