-- Migration: 20260927000004_block1d_async_job_architecture.sql
-- Description: Block 1D Async AI Processing & Durable Job Architecture.
--              Extends public.recordings with durable processing lifecycle fields:
--              attempt counters, processing stage timestamps, lease worker tracking,
--              error categorization, and server-side atomic claiming RPCs.
--              Maintains full backwards compatibility with Phase 3 & Blocks 1A-1C.

-- 1. Extend recording_processing_status enum with explicit processing states
-- Note: 'pending', 'transcribing', 'transcribed', 'failed' exist from 20260919000001
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_enum WHERE enumlabel = 'queued' AND enumtypid = 'public.recording_processing_status'::regtype) THEN
        ALTER TYPE public.recording_processing_status ADD VALUE 'queued' BEFORE 'transcribing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_enum WHERE enumlabel = 'structuring' AND enumtypid = 'public.recording_processing_status'::regtype) THEN
        ALTER TYPE public.recording_processing_status ADD VALUE 'structuring' BEFORE 'transcribed';
    END IF;
END $$;

-- 2. Add durable job lifecycle columns to public.recordings
ALTER TABLE public.recordings
    ADD COLUMN IF NOT EXISTS processing_started_at TIMESTAMPTZ NULL,
    ADD COLUMN IF NOT EXISTS last_attempt_at TIMESTAMPTZ NULL,
    ADD COLUMN IF NOT EXISTS attempt_count INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS max_attempts INTEGER NOT NULL DEFAULT 3,
    ADD COLUMN IF NOT EXISTS last_error_code TEXT NULL,
    ADD COLUMN IF NOT EXISTS last_error_message TEXT NULL,
    ADD COLUMN IF NOT EXISTS lease_worker_id TEXT NULL,
    ADD COLUMN IF NOT EXISTS lease_expires_at TIMESTAMPTZ NULL;

-- 3. Composite index for worker claim queries & stale job recovery
CREATE INDEX IF NOT EXISTS idx_recordings_processing_claim
    ON public.recordings (processing_status, lease_expires_at, created_at ASC);

-- 4. Atomic Job Claim RPC
-- Safely claims a recording for processing by a worker:
-- - Status is 'pending', 'queued', 'failed' (if retriable), OR
-- - Status is actively processing ('transcribing', 'structuring') but lease has expired (stale job recovery).
-- Atomically increments attempt_count, assigns lease_worker_id, and sets lease_expires_at.
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

-- Grant execution to authenticated & service_role
GRANT EXECUTE ON FUNCTION public.claim_recording_for_processing(UUID, TEXT, INTEGER) TO authenticated, service_role;
