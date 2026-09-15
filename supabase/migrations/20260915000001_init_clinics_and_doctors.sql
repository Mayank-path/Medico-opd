-- Migration: 20260915000001_init_clinics_and_doctors.sql
-- Description: Initialize clinics, doctors, RLS policies, column grants, and atomic onboarding RPC.

-- 1. Clinics Table
CREATE TABLE IF NOT EXISTS public.clinics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    address TEXT,
    contact_info TEXT,
    logo_url TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2. Doctors Table
CREATE TABLE IF NOT EXISTS public.doctors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    auth_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    clinic_id UUID NOT NULL REFERENCES public.clinics(id) ON DELETE RESTRICT,
    full_name TEXT NOT NULL,
    qualifications TEXT,
    registration_number TEXT,
    contact_info TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_doctors_auth_user UNIQUE (auth_user_id)
);

-- Indexes for foreign keys and lookup performance
CREATE INDEX IF NOT EXISTS idx_doctors_clinic_id ON public.doctors(clinic_id);
CREATE INDEX IF NOT EXISTS idx_doctors_auth_user_id ON public.doctors(auth_user_id);

-- 3. Enable Row-Level Security (Deny by default)
ALTER TABLE public.clinics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.doctors ENABLE ROW LEVEL SECURITY;

-- 4. Helper function to lookup caller's clinic ID
CREATE OR REPLACE FUNCTION public.get_auth_clinic_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT clinic_id FROM public.doctors WHERE auth_user_id = auth.uid() LIMIT 1;
$$;

-- 5. RLS Policies on public.clinics
-- Allow doctors to read their own clinic
DROP POLICY IF EXISTS "Doctors can view their own clinic" ON public.clinics;
CREATE POLICY "Doctors can view their own clinic"
    ON public.clinics
    FOR SELECT
    TO authenticated
    USING (id = public.get_auth_clinic_id());

-- Allow doctors to update their own clinic
DROP POLICY IF EXISTS "Doctors can update their own clinic" ON public.clinics;
CREATE POLICY "Doctors can update their own clinic"
    ON public.clinics
    FOR UPDATE
    TO authenticated
    USING (id = public.get_auth_clinic_id())
    WITH CHECK (id = public.get_auth_clinic_id());

-- Note: No client INSERT policy on clinics. Direct client INSERT is denied by default under RLS.

-- Column-level update restriction on clinics (Correction 3)
REVOKE UPDATE ON public.clinics FROM authenticated;
GRANT UPDATE (name, address, contact_info, logo_url)
    ON public.clinics TO authenticated;

-- 6. RLS Policies on public.doctors
-- Allow doctors to read profiles within their own clinic
DROP POLICY IF EXISTS "Doctors can view colleagues in their clinic" ON public.doctors;
CREATE POLICY "Doctors can view colleagues in their clinic"
    ON public.doctors
    FOR SELECT
    TO authenticated
    USING (clinic_id = public.get_auth_clinic_id() OR auth_user_id = auth.uid());

-- Allow doctors to update their own profile
DROP POLICY IF EXISTS "Doctors can update their own profile" ON public.doctors;
CREATE POLICY "Doctors can update their own profile"
    ON public.doctors
    FOR UPDATE
    TO authenticated
    USING (auth.uid() = auth_user_id)
    WITH CHECK (auth.uid() = auth_user_id);

-- Column-level update restriction on doctors (Correction 3: prevents reassigning clinic_id or auth_user_id)
REVOKE UPDATE ON public.doctors FROM authenticated;
GRANT UPDATE (full_name, qualifications, registration_number, contact_info)
    ON public.doctors TO authenticated;

-- 7. Atomic Onboarding RPC (Correction 1 & 2)
CREATE OR REPLACE FUNCTION public.create_clinic_and_doctor(
    p_clinic_name TEXT,
    p_clinic_address TEXT,
    p_clinic_contact TEXT,
    p_doctor_name TEXT,
    p_qualifications TEXT,
    p_registration_number TEXT,
    p_doctor_contact TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_auth_user_id UUID;
    v_clinic_id UUID;
    v_doctor_id UUID;
    v_existing_clinic_id UUID;
BEGIN
    v_auth_user_id := auth.uid();
    IF v_auth_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Prevent duplicate doctor profile creation
    SELECT clinic_id INTO v_existing_clinic_id
    FROM public.doctors
    WHERE auth_user_id = v_auth_user_id;

    IF v_existing_clinic_id IS NOT NULL THEN
        RAISE EXCEPTION 'Doctor is already associated with a clinic';
    END IF;

    -- Validate required input fields
    IF coalesce(trim(p_clinic_name), '') = '' THEN
        RAISE EXCEPTION 'Clinic name is required';
    END IF;
    IF coalesce(trim(p_doctor_name), '') = '' THEN
        RAISE EXCEPTION 'Doctor name is required';
    END IF;

    -- 1. Insert clinic (atomic transaction)
    INSERT INTO public.clinics (name, address, contact_info)
    VALUES (trim(p_clinic_name), trim(p_clinic_address), trim(p_clinic_contact))
    RETURNING id INTO v_clinic_id;

    -- 2. Insert doctor associated with newly created clinic
    INSERT INTO public.doctors (
        auth_user_id,
        clinic_id,
        full_name,
        qualifications,
        registration_number,
        contact_info
    )
    VALUES (
        v_auth_user_id,
        v_clinic_id,
        trim(p_doctor_name),
        trim(p_qualifications),
        trim(p_registration_number),
        trim(p_doctor_contact)
    )
    RETURNING id INTO v_doctor_id;

    RETURN jsonb_build_object(
        'clinic_id', v_clinic_id,
        'doctor_id', v_doctor_id
    );
END;
$$;

-- 8. Auto-confirm emails so doctors receive immediate session on signup
CREATE OR REPLACE FUNCTION public.auto_confirm_users()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  NEW.email_confirmed_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  BEFORE INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.auto_confirm_users();

