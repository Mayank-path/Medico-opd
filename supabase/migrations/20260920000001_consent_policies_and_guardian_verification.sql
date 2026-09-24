-- Migration: 20260920000001_consent_policies_and_guardian_verification.sql
-- Description: TASK-003-03 Consent Policy Abstraction, Guardian Verification Extension Fields,
--              and Private Storage Bucket RLS for Consultation Recordings.

-- 1. Table: consent_policies (Platform-wide legal policy table)
CREATE TABLE IF NOT EXISTS public.consent_policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    version INTEGER NOT NULL,
    allowed_methods public.consent_method[] NOT NULL,
    required_evidence TEXT NULL,
    pediatric_verification_required BOOLEAN NOT NULL DEFAULT false,
    effective_from TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID NULL,
    notes TEXT NULL
);

CREATE INDEX IF NOT EXISTS idx_consent_policies_effective ON public.consent_policies(effective_from DESC, version DESC);

ALTER TABLE public.consent_policies ENABLE ROW LEVEL SECURITY;

-- Item 1 Check: SELECT is unconditionally "true for authenticated" (platform-wide legal policy)
DROP POLICY IF EXISTS "Authenticated users can view consent policies" ON public.consent_policies;
CREATE POLICY "Authenticated users can view consent policies"
    ON public.consent_policies FOR SELECT
    TO authenticated
    USING (true);

-- Immutable / Administrative control: Revoke all write permissions from client authenticated role
REVOKE INSERT, UPDATE, DELETE ON public.consent_policies FROM public, authenticated, anon;

-- Seed Row 1: Initial baseline policy (all 5 methods allowed pending legal determination)
INSERT INTO public.consent_policies (version, allowed_methods, pediatric_verification_required, notes)
VALUES (
    1,
    ARRAY['verbal', 'checkbox', 'otp', 'signature', 'other']::public.consent_method[],
    false,
    'Initial baseline policy: all 5 consent methods enabled pending formal legal determination'
)
ON CONFLICT DO NOTHING;

-- Helper function: get_active_consent_policy()
CREATE OR REPLACE FUNCTION public.get_active_consent_policy()
RETURNS SETOF public.consent_policies
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT * FROM public.consent_policies
    ORDER BY effective_from DESC, version DESC
    LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_consent_policy() TO authenticated, anon;

-- 2. Guardian Verification Extension Fields on consultation_consents
ALTER TABLE public.consultation_consents
    ADD COLUMN IF NOT EXISTS verification_method TEXT NULL,
    ADD COLUMN IF NOT EXISTS verification_metadata JSONB NULL,
    ADD COLUMN IF NOT EXISTS verified_at TIMESTAMPTZ NULL;

-- Maintain column grant immutability: Authenticated users can only update revoked_at
REVOKE UPDATE ON public.consultation_consents FROM authenticated;
GRANT UPDATE (revoked_at) ON public.consultation_consents TO authenticated;

-- 3. Storage Bucket: consultation-recordings (Private)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'consultation-recordings',
    'consultation-recordings',
    false,
    104857600, -- 100 MB
    ARRAY['audio/mp4', 'audio/x-m4a', 'audio/aac', 'audio/m4a', 'application/octet-stream']
)
ON CONFLICT (id) DO UPDATE SET
    public = false,
    file_size_limit = 104857600,
    allowed_mime_types = ARRAY['audio/mp4', 'audio/x-m4a', 'audio/aac', 'audio/m4a', 'application/octet-stream'];

-- Item 2 Check: Storage RLS policies using index [2] of storage.foldername(name)
-- Path format: clinics/{clinic_id}/consultations/{consultation_id}/{recording_id}.m4a
DROP POLICY IF EXISTS "Clinic audio isolation read" ON storage.objects;
CREATE POLICY "Clinic audio isolation read"
    ON storage.objects FOR SELECT
    TO authenticated
    USING (
        bucket_id = 'consultation-recordings'
        AND (storage.foldername(name))[2] = (public.get_auth_clinic_id())::text
    );

DROP POLICY IF EXISTS "Clinic audio isolation insert" ON storage.objects;
CREATE POLICY "Clinic audio isolation insert"
    ON storage.objects FOR INSERT
    TO authenticated
    WITH CHECK (
        bucket_id = 'consultation-recordings'
        AND (storage.foldername(name))[2] = (public.get_auth_clinic_id())::text
    );
