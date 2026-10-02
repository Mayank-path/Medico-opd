-- Migration: 20260927000003_block1c_query_pagination_scalability.sql
-- Description: Block 1C Query & Pagination Scalability.
--              Adds composite B-tree index for keyset pagination on patients.
--              Consultations table reuses existing Block 1A index idx_consultations_patient_created_at.

-- 1. Composite B-tree index for deterministic keyset pagination in patient directory
-- Supports: PatientService.fetchPatients(clinic_id, cursor, limit)
-- Query: SELECT ... FROM patients WHERE clinic_id = :clinic_id AND (created_at, id) < (:t, :id) ORDER BY created_at DESC, id DESC LIMIT :limit;
-- Benefit: Enables direct B-tree range scan under RLS clinic filtering, eliminating in-memory sorting overhead.
CREATE INDEX IF NOT EXISTS idx_patients_clinic_created_at_id
    ON public.patients (clinic_id, created_at DESC, id DESC);
