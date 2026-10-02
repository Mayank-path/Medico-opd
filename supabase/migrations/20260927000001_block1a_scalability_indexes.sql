-- Migration: 20260927000001_block1a_scalability_indexes.sql
-- Description: Block 1A Database Scalability & Data Integrity Foundation.
--              Adds evidence-based composite lookup indexes for consultations,
--              consultation consents, audit logs, and AI drafts.
--              Strictly avoids speculative UNIQUE constraints or destructive mutations.

-- 1. Index on consultations: patient_id + created_at DESC
-- Supports: ConsultationService.fetchConsultationsForPatient(patientId)
-- Query: SELECT * FROM consultations WHERE patient_id = ? ORDER BY created_at DESC;
-- Solves: Eliminates in-memory sorting overhead when fetching patient consultation history.
CREATE INDEX IF NOT EXISTS idx_consultations_patient_created_at
    ON public.consultations (patient_id, created_at DESC);

-- 2. Index on consultation_consents: consultation_id + consent_status
-- Supports:
--   a) DB trigger `trg_check_recording_consent` gating audio insertion
--      (SELECT EXISTS (...) WHERE consultation_id = ? AND consent_status = 'granted' AND revoked_at IS NULL)
--   b) Edge Function `process-consultation` re-checking consent before STT pipeline
--   c) ConsentService.fetchConsentForConsultation
CREATE INDEX IF NOT EXISTS idx_consultation_consents_consultation_status
    ON public.consultation_consents (consultation_id, consent_status);

-- 3. Index on audit_logs: clinic_id + created_at DESC
-- Supports: Time-bounded audit trail inspection by clinic staff, legal compliance checks,
--           and time-range based data retention / audit log reporting.
CREATE INDEX IF NOT EXISTS idx_audit_logs_clinic_created_at
    ON public.audit_logs (clinic_id, created_at DESC);

-- 4. Index on ai_drafts: consultation_id + status
-- Supports:
--   a) Edge Function `process-consultation` checking existing draft status during idempotency check
--   b) AiDraftService fetching and filtering drafts by consultation and review/finalization state
-- NOTE ON UNIQUENESS: Intentionally NOT a UNIQUE constraint.
-- The Medico-OPD clinical documentation lifecycle permits doctors to reject drafts
-- (status = 'rejected') while preserving them in the audit trail. A future regeneration or
-- re-processing flow would create an updated draft for the same consultation.
-- Imposing a blanket UNIQUE(consultation_id) would break audit preservation of rejected drafts.
-- Concurrency and idempotency protection is addressed in Block 1B via atomic state claiming.
CREATE INDEX IF NOT EXISTS idx_ai_drafts_consultation_status
    ON public.ai_drafts (consultation_id, status);
