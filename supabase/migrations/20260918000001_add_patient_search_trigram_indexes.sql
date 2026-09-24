-- Migration: 20260918000001_add_patient_search_trigram_indexes.sql
-- Description: Enable pg_trgm extension and create GIN trigram indexes on patients
--              columns (full_name, opd_number, contact_info) for performant ILIKE search.

-- 1. Enable pg_trgm extension in extensions schema (or public fallback)
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- 2. Trigram GIN indexes for fast ILIKE substring search on patients table
CREATE INDEX IF NOT EXISTS idx_patients_full_name_trgm
    ON public.patients USING gin (full_name gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_patients_opd_number_trgm
    ON public.patients USING gin (opd_number gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_patients_contact_info_trgm
    ON public.patients USING gin (contact_info gin_trgm_ops);
