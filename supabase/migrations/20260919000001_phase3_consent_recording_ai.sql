-- Migration: 20260919000001_phase3_consent_recording_ai.sql
-- Description: Phase 3 Engineering Foundation - Consent, Recordings, Transcripts,
--              AI Drafts, Data Retention Policies, and Audit Logs with strict RLS,
--              column grants, and database-level gating triggers.

-- 1. Create Enums
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'consent_status') THEN
        CREATE TYPE public.consent_status AS ENUM ('pending', 'granted', 'declined', 'revoked');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'consent_method') THEN
        CREATE TYPE public.consent_method AS ENUM ('verbal', 'checkbox', 'otp', 'signature', 'other');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'consent_actor') THEN
        CREATE TYPE public.consent_actor AS ENUM ('patient', 'guardian');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'capture_source') THEN
        CREATE TYPE public.capture_source AS ENUM ('mobile_app', 'paper_upload');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'recording_upload_status') THEN
        CREATE TYPE public.recording_upload_status AS ENUM ('pending', 'uploading', 'uploaded', 'failed');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'recording_processing_status') THEN
        CREATE TYPE public.recording_processing_status AS ENUM ('pending', 'transcribing', 'transcribed', 'failed');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'recording_deletion_status') THEN
        CREATE TYPE public.recording_deletion_status AS ENUM ('active', 'pending_deletion', 'deleted', 'held');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ai_draft_status') THEN
        CREATE TYPE public.ai_draft_status AS ENUM ('ai_draft', 'doctor_reviewed', 'rejected', 'finalized');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'data_retention_class') THEN
        CREATE TYPE public.data_retention_class AS ENUM ('raw_audio', 'ai_draft', 'final_record', 'consent_evidence', 'audit_record');
    END IF;
END $$;

-- 2. Table: consultation_consents
CREATE TABLE IF NOT EXISTS public.consultation_consents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id UUID NOT NULL REFERENCES public.clinics(id) ON DELETE RESTRICT,
    consultation_id UUID NOT NULL REFERENCES public.consultations(id) ON DELETE RESTRICT,
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE RESTRICT,
    consent_status public.consent_status NOT NULL DEFAULT 'pending',
    consent_method public.consent_method NOT NULL,
    consent_actor public.consent_actor NOT NULL DEFAULT 'patient',
    actor_name TEXT NOT NULL,
    actor_relationship TEXT NULL,
    consented_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at TIMESTAMPTZ NULL,
    consent_text_version TEXT NOT NULL DEFAULT 'v1.0',
    capture_source public.capture_source NOT NULL DEFAULT 'mobile_app',
    evidence_reference TEXT NULL,
    recorded_by UUID NOT NULL REFERENCES public.doctors(id) ON DELETE RESTRICT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT chk_guardian_actor_relationship CHECK (
        consent_actor <> 'guardian' OR (actor_relationship IS NOT NULL AND trim(actor_relationship) <> '')
    )
);

CREATE INDEX IF NOT EXISTS idx_consents_consultation_id ON public.consultation_consents(consultation_id);
CREATE INDEX IF NOT EXISTS idx_consents_clinic_id ON public.consultation_consents(clinic_id);
CREATE INDEX IF NOT EXISTS idx_consents_patient_id ON public.consultation_consents(patient_id);

ALTER TABLE public.consultation_consents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Doctors can view clinic consultation consents" ON public.consultation_consents;
CREATE POLICY "Doctors can view clinic consultation consents"
    ON public.consultation_consents FOR SELECT
    TO authenticated
    USING (clinic_id = public.get_auth_clinic_id());

DROP POLICY IF EXISTS "Doctors can insert clinic consultation consents" ON public.consultation_consents;
CREATE POLICY "Doctors can insert clinic consultation consents"
    ON public.consultation_consents FOR INSERT
    TO authenticated
    WITH CHECK (
        clinic_id = public.get_auth_clinic_id()
        AND recorded_by IN (SELECT id FROM public.doctors WHERE auth_user_id = auth.uid())
    );

DROP POLICY IF EXISTS "Doctors can update revoked_at for clinic consents" ON public.consultation_consents;
CREATE POLICY "Doctors can update revoked_at for clinic consents"
    ON public.consultation_consents FOR UPDATE
    TO authenticated
    USING (clinic_id = public.get_auth_clinic_id())
    WITH CHECK (clinic_id = public.get_auth_clinic_id());

REVOKE UPDATE ON public.consultation_consents FROM authenticated;
GRANT UPDATE (revoked_at) ON public.consultation_consents TO authenticated;
REVOKE DELETE ON public.consultation_consents FROM authenticated;

-- 3. Table: recordings
CREATE TABLE IF NOT EXISTS public.recordings (
    id UUID PRIMARY KEY, -- client-generated UUIDv4 (idempotency key)
    consultation_id UUID NOT NULL REFERENCES public.consultations(id) ON DELETE RESTRICT,
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE RESTRICT,
    doctor_id UUID NOT NULL REFERENCES public.doctors(id) ON DELETE RESTRICT,
    storage_path TEXT NOT NULL,
    encryption_key_ref TEXT NOT NULL,
    duration_seconds INTEGER NOT NULL DEFAULT 0,
    format TEXT NOT NULL DEFAULT 'm4a',
    upload_status public.recording_upload_status NOT NULL DEFAULT 'pending',
    processing_status public.recording_processing_status NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    retention_expires_at TIMESTAMPTZ NULL,
    legal_hold BOOLEAN NOT NULL DEFAULT false,
    deletion_status public.recording_deletion_status NOT NULL DEFAULT 'active'
);

CREATE INDEX IF NOT EXISTS idx_recordings_consultation_id ON public.recordings(consultation_id);
CREATE INDEX IF NOT EXISTS idx_recordings_patient_id ON public.recordings(patient_id);
CREATE INDEX IF NOT EXISTS idx_recordings_doctor_id ON public.recordings(doctor_id);

-- Gating trigger: enforce granted, unrevoked consent before recording insertion
CREATE OR REPLACE FUNCTION public.check_recording_consent()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_consent_valid BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM public.consultation_consents
        WHERE consultation_id = NEW.consultation_id
          AND consent_status = 'granted'
          AND revoked_at IS NULL
    ) INTO v_consent_valid;

    IF NOT v_consent_valid THEN
        RAISE EXCEPTION 'Recording blocked: Valid granted consent required for consultation %', NEW.consultation_id
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_recording_consent ON public.recordings;
CREATE TRIGGER trg_check_recording_consent
    BEFORE INSERT ON public.recordings
    FOR EACH ROW
    EXECUTE FUNCTION public.check_recording_consent();

ALTER TABLE public.recordings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Doctors can view clinic recordings" ON public.recordings;
CREATE POLICY "Doctors can view clinic recordings"
    ON public.recordings FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.consultations c
            WHERE c.id = recordings.consultation_id
              AND c.clinic_id = public.get_auth_clinic_id()
        )
    );

DROP POLICY IF EXISTS "Doctors can insert clinic recordings" ON public.recordings;
CREATE POLICY "Doctors can insert clinic recordings"
    ON public.recordings FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.consultations c
            WHERE c.id = consultation_id
              AND c.clinic_id = public.get_auth_clinic_id()
        )
    );

DROP POLICY IF EXISTS "Doctors can update clinic recordings" ON public.recordings;
CREATE POLICY "Doctors can update clinic recordings"
    ON public.recordings FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.consultations c
            WHERE c.id = recordings.consultation_id
              AND c.clinic_id = public.get_auth_clinic_id()
        )
    );

REVOKE UPDATE ON public.recordings FROM authenticated;
GRANT UPDATE (storage_path, duration_seconds, upload_status, processing_status, retention_expires_at, legal_hold, deletion_status)
    ON public.recordings TO authenticated;
REVOKE DELETE ON public.recordings FROM authenticated;

-- 4. Table: transcripts
CREATE TABLE IF NOT EXISTS public.transcripts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    recording_id UUID NOT NULL REFERENCES public.recordings(id) ON DELETE RESTRICT,
    raw_text_ref TEXT NOT NULL,
    privacy_processed_text TEXT NOT NULL,
    stt_provider TEXT NOT NULL,
    stt_confidence DOUBLE PRECISION NOT NULL DEFAULT 0.0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_transcripts_recording_id ON public.transcripts(recording_id);

ALTER TABLE public.transcripts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Doctors can view clinic transcripts" ON public.transcripts;
CREATE POLICY "Doctors can view clinic transcripts"
    ON public.transcripts FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.recordings r
            JOIN public.consultations c ON c.id = r.consultation_id
            WHERE r.id = transcripts.recording_id
              AND c.clinic_id = public.get_auth_clinic_id()
        )
    );

DROP POLICY IF EXISTS "Doctors can insert clinic transcripts" ON public.transcripts;
CREATE POLICY "Doctors can insert clinic transcripts"
    ON public.transcripts FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.recordings r
            JOIN public.consultations c ON c.id = r.consultation_id
            WHERE r.id = recording_id
              AND c.clinic_id = public.get_auth_clinic_id()
        )
    );

REVOKE UPDATE, DELETE ON public.transcripts FROM authenticated;

-- 5. Table: ai_drafts
CREATE TABLE IF NOT EXISTS public.ai_drafts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    consultation_id UUID NOT NULL REFERENCES public.consultations(id) ON DELETE RESTRICT,
    structured_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    status public.ai_draft_status NOT NULL DEFAULT 'ai_draft',
    reviewed_by UUID NULL REFERENCES public.doctors(id) ON DELETE RESTRICT,
    reviewed_at TIMESTAMPTZ NULL,
    finalized_by UUID NULL REFERENCES public.doctors(id) ON DELETE RESTRICT,
    finalized_at TIMESTAMPTZ NULL,
    model_used TEXT NOT NULL,
    prompt_version TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ai_drafts_consultation_id ON public.ai_drafts(consultation_id);

CREATE OR REPLACE FUNCTION public.lock_finalized_ai_draft()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF OLD.status = 'finalized' THEN
        RAISE EXCEPTION 'AI draft is finalized and permanently locked against modifications'
            USING ERRCODE = 'check_violation';
    END IF;

    IF OLD.finalized_at IS NOT NULL AND (NEW.finalized_at <> OLD.finalized_at OR NEW.finalized_by <> OLD.finalized_by) THEN
        RAISE EXCEPTION 'finalized_by and finalized_at can only be set once'
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_lock_finalized_ai_draft ON public.ai_drafts;
CREATE TRIGGER trg_lock_finalized_ai_draft
    BEFORE UPDATE ON public.ai_drafts
    FOR EACH ROW
    EXECUTE FUNCTION public.lock_finalized_ai_draft();

ALTER TABLE public.ai_drafts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Doctors can view clinic ai drafts" ON public.ai_drafts;
CREATE POLICY "Doctors can view clinic ai drafts"
    ON public.ai_drafts FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.consultations c
            WHERE c.id = ai_drafts.consultation_id
              AND c.clinic_id = public.get_auth_clinic_id()
        )
    );

DROP POLICY IF EXISTS "Doctors can insert clinic ai drafts" ON public.ai_drafts;
CREATE POLICY "Doctors can insert clinic ai drafts"
    ON public.ai_drafts FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.consultations c
            WHERE c.id = consultation_id
              AND c.clinic_id = public.get_auth_clinic_id()
        )
    );

DROP POLICY IF EXISTS "Doctors can update clinic ai drafts" ON public.ai_drafts;
CREATE POLICY "Doctors can update clinic ai drafts"
    ON public.ai_drafts FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.consultations c
            WHERE c.id = ai_drafts.consultation_id
              AND c.clinic_id = public.get_auth_clinic_id()
        )
    );

REVOKE UPDATE ON public.ai_drafts FROM authenticated;
GRANT UPDATE (status, reviewed_by, reviewed_at, finalized_by, finalized_at, structured_json)
    ON public.ai_drafts TO authenticated;
REVOKE DELETE ON public.ai_drafts FROM authenticated;

-- 6. Table: data_retention_policies
CREATE TABLE IF NOT EXISTS public.data_retention_policies (
    data_class public.data_retention_class PRIMARY KEY,
    retention_days INTEGER NULL,
    legal_hold_default BOOLEAN NOT NULL DEFAULT false
);

ALTER TABLE public.data_retention_policies ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated users can view retention policies" ON public.data_retention_policies;
CREATE POLICY "Authenticated users can view retention policies"
    ON public.data_retention_policies FOR SELECT
    TO authenticated
    USING (true);

REVOKE INSERT, UPDATE, DELETE ON public.data_retention_policies FROM authenticated;

-- Seed retention policies with NULL retention_days (safe inert retention)
INSERT INTO public.data_retention_policies (data_class, retention_days, legal_hold_default)
VALUES
    ('raw_audio', NULL, false),
    ('ai_draft', NULL, false),
    ('final_record', NULL, false),
    ('consent_evidence', NULL, false),
    ('audit_record', NULL, false)
ON CONFLICT (data_class) DO NOTHING;

-- 7. Table: audit_logs (Append-only immutable ledger)
CREATE TABLE IF NOT EXISTS public.audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type TEXT NOT NULL,
    actor_id UUID NULL,
    clinic_id UUID NULL REFERENCES public.clinics(id) ON DELETE RESTRICT,
    target_table TEXT NOT NULL,
    target_id UUID NULL,
    ip_address TEXT NULL,
    user_agent TEXT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_clinic_id ON public.audit_logs(clinic_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_target ON public.audit_logs(target_table, target_id);

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Doctors can view clinic audit logs" ON public.audit_logs;
CREATE POLICY "Doctors can view clinic audit logs"
    ON public.audit_logs FOR SELECT
    TO authenticated
    USING (clinic_id = public.get_auth_clinic_id());

DROP POLICY IF EXISTS "Doctors can insert clinic audit logs" ON public.audit_logs;
CREATE POLICY "Doctors can insert clinic audit logs"
    ON public.audit_logs FOR INSERT
    TO authenticated
    WITH CHECK (clinic_id = public.get_auth_clinic_id() OR clinic_id IS NULL);

-- Strict immutability: Revoke UPDATE and DELETE entirely for ALL roles
REVOKE UPDATE, DELETE ON public.audit_logs FROM public, authenticated, anon;
