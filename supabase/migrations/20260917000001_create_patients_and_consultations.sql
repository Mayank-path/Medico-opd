-- Migration: 20260917000001_create_patients_and_consultations.sql
-- Description: Initialize patients and consultations tables with deny-by-default RLS,
--              cross-entity clinic consistency trigger, and column-scoped update privileges.

-- 1. Patients Table
CREATE TABLE IF NOT EXISTS public.patients (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id UUID NOT NULL REFERENCES public.clinics(id) ON DELETE CASCADE,
    full_name TEXT NOT NULL,
    dob_or_age TEXT,
    sex TEXT,
    contact_info TEXT,
    opd_number TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES public.doctors(id) ON DELETE SET NULL
);

-- Indexes for patients
CREATE INDEX IF NOT EXISTS idx_patients_clinic_id ON public.patients(clinic_id);
CREATE INDEX IF NOT EXISTS idx_patients_created_by ON public.patients(created_by);

-- 2. Consultations Table
CREATE TABLE IF NOT EXISTS public.consultations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
    doctor_id UUID NOT NULL REFERENCES public.doctors(id) ON DELETE CASCADE,
    clinic_id UUID NOT NULL REFERENCES public.clinics(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'in_progress', 'completed')),
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes for consultations
CREATE INDEX IF NOT EXISTS idx_consultations_patient_id ON public.consultations(patient_id);
CREATE INDEX IF NOT EXISTS idx_consultations_doctor_id ON public.consultations(doctor_id);
CREATE INDEX IF NOT EXISTS idx_consultations_clinic_id ON public.consultations(clinic_id);

-- 3. Clinic Consistency Trigger Function
-- Ensures consultation doctor_id and patient_id both belong to the same clinic_id as the consultation itself.
CREATE OR REPLACE FUNCTION public.check_consultation_clinic_consistency()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_patient_clinic_id UUID;
    v_doctor_clinic_id UUID;
BEGIN
    SELECT clinic_id INTO v_patient_clinic_id FROM public.patients WHERE id = NEW.patient_id;
    IF v_patient_clinic_id IS NULL OR v_patient_clinic_id <> NEW.clinic_id THEN
        RAISE EXCEPTION 'Consultation patient does not belong to the consultation clinic'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT clinic_id INTO v_doctor_clinic_id FROM public.doctors WHERE id = NEW.doctor_id;
    IF v_doctor_clinic_id IS NULL OR v_doctor_clinic_id <> NEW.clinic_id THEN
        RAISE EXCEPTION 'Consultation doctor does not belong to the consultation clinic'
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_consultation_clinic_consistency ON public.consultations;
CREATE TRIGGER trg_check_consultation_clinic_consistency
    BEFORE INSERT OR UPDATE ON public.consultations
    FOR EACH ROW
    EXECUTE FUNCTION public.check_consultation_clinic_consistency();

-- 4. Enable Row-Level Security (Deny by default)
ALTER TABLE public.patients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.consultations ENABLE ROW LEVEL SECURITY;

-- 5. RLS Policies on public.patients
-- Allow doctors to read patients belonging to their clinic
DROP POLICY IF EXISTS "Doctors can view patients in their clinic" ON public.patients;
CREATE POLICY "Doctors can view patients in their clinic"
    ON public.patients
    FOR SELECT
    TO authenticated
    USING (clinic_id = public.get_auth_clinic_id());

-- Allow doctors to insert patients into their clinic
DROP POLICY IF EXISTS "Doctors can create patients in their clinic" ON public.patients;
CREATE POLICY "Doctors can create patients in their clinic"
    ON public.patients
    FOR INSERT
    TO authenticated
    WITH CHECK (clinic_id = public.get_auth_clinic_id());

-- Allow doctors to update patients in their clinic
DROP POLICY IF EXISTS "Doctors can update patients in their clinic" ON public.patients;
CREATE POLICY "Doctors can update patients in their clinic"
    ON public.patients
    FOR UPDATE
    TO authenticated
    USING (clinic_id = public.get_auth_clinic_id())
    WITH CHECK (clinic_id = public.get_auth_clinic_id());

-- Note: DELETE is denied by default (no DELETE policy for authenticated).

-- Column-level update restrictions on patients (prevents reassigning clinic_id, id, created_at, created_by)
REVOKE UPDATE ON public.patients FROM authenticated;
GRANT UPDATE (full_name, dob_or_age, sex, contact_info, opd_number)
    ON public.patients TO authenticated;

-- 6. RLS Policies on public.consultations
-- Allow doctors to read consultations belonging to their clinic
DROP POLICY IF EXISTS "Doctors can view consultations in their clinic" ON public.consultations;
CREATE POLICY "Doctors can view consultations in their clinic"
    ON public.consultations
    FOR SELECT
    TO authenticated
    USING (clinic_id = public.get_auth_clinic_id());

-- Allow doctors to insert consultations into their clinic
DROP POLICY IF EXISTS "Doctors can create consultations in their clinic" ON public.consultations;
CREATE POLICY "Doctors can create consultations in their clinic"
    ON public.consultations
    FOR INSERT
    TO authenticated
    WITH CHECK (clinic_id = public.get_auth_clinic_id());

-- Allow doctors to update consultations in their clinic
DROP POLICY IF EXISTS "Doctors can update consultations in their clinic" ON public.consultations;
CREATE POLICY "Doctors can update consultations in their clinic"
    ON public.consultations
    FOR UPDATE
    TO authenticated
    USING (clinic_id = public.get_auth_clinic_id())
    WITH CHECK (clinic_id = public.get_auth_clinic_id());

-- Note: DELETE is denied by default (no DELETE policy for authenticated).

-- Column-level update restrictions on consultations (prevents mutating patient_id, doctor_id, clinic_id, started_at, created_at)
REVOKE UPDATE ON public.consultations FROM authenticated;
GRANT UPDATE (status, ended_at)
    ON public.consultations TO authenticated;
