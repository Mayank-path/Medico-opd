-- Migration: 20260927000002_block1b_idempotency_concurrency.sql
-- Description: Block 1B Idempotency & Concurrency Hardening.
--              Adds integer revision tracking for deterministic optimistic locking
--              on ai_drafts and enforces transcript uniqueness per recording.
--              Strictly preserves historical draft semantics (no blanket UNIQUE on consultation_id).

-- 1. Add revision column to ai_drafts for deterministic optimistic concurrency control
ALTER TABLE public.ai_drafts
    ADD COLUMN IF NOT EXISTS revision INTEGER NOT NULL DEFAULT 1;

-- Grant column UPDATE permission on revision to authenticated role
-- (Matches column-level grants in 20260919000001_phase3_consent_recording_ai.sql)
GRANT UPDATE (revision) ON public.ai_drafts TO authenticated;

-- 2. Enforce strict 1:1 relationship between recording and transcript
-- Prevents duplicate transcript generation during concurrent processing races
CREATE UNIQUE INDEX IF NOT EXISTS idx_transcripts_recording_id_unique
    ON public.transcripts (recording_id);
