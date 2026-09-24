# LEGAL_DECISIONS_REQUIRED.md — Unresolved Regulatory and Legal Decisions

This document tracks all regulatory, compliance, and legal determinations required before production deployment of Medico OPD Assistant.
**Status**: ACTIVE TRACKING.
**Policy**: Engineering defaults have been implemented in code to guarantee security and privacy isolation, but **no legal assumptions are treated as final**. All default values are fail-safe (inert or restrictive) until formal counsel review.

---

## 1. Item Registry

| Identifier | Domain | Description | Current Engineering Default | Dependent Database / Code Artifacts | Blocking Release? |
|---|---|---|---|---|---|
| **RLR-01** | Telemedicine Practice Guidelines / IT Act | Evidentiary burden for verbal consent in OPD consultations | Explicit metadata audit record logged (`consultation_consents`, timestamp, actor, audio SHA-256) | `consultation_consents`, `trg_check_recording_consent` | **Yes** (Before live patient audio capture) |
| **RLR-02** | DPDP Act 2023 / Medical Council Guidelines | Raw consultation audio purge horizon and clinical liability | Retention policy initialized with `retention_days = NULL` (Inert purge worker) | `data_retention_policies`, `retention-purge-worker` | **Yes** (Before automated purging goes live) |
| **RLR-03** | DPDP Act 2023 (Data Processor) | Cloud AI vendor processing terms (Deepgram / Anthropic) | Client-side & Edge isolation; PII masking via regex minimizer before LLM | `supabase/functions/_shared/providers/`, `data_minimizer.ts` | **Yes** (Vendor BAA / DPA required) |
| **RLR-04** | DPDP Act 2023 / Indian Majority Act | Pediatric (<18) & incapacitated patient guardian consent | Schema enforces `guardian_name` + `guardian_relationship` when `actor = 'guardian'` | `consultation_consents.chk_guardian_fields` | **Yes** (Before pediatric patient onboarding) |
| **RLR-05** | ABDM M2/M3 Architecture | Consent Manager artifact registration and notification webhooks | Extensible status enum (`revoked`, `pending`) and metadata JSONB schema | `consultation_consents.consent_manager_artifact_id` | **No** (Optional for OPD-only baseline; required for ABDM) |

---

## 2. Detailed Legal Decision Briefs

### RLR-01: Verbal Consent Evidentiary Burden
- **Context**: In high-throughput Indian Outpatient Departments (OPD), requiring wet signatures or digital OTP signatures for every audio-assisted consultation introduces significant friction. Doctors routinely rely on verbal consent ("Can I record our conversation to assist with note-taking?").
- **Legal Question**: Does an immutable metadata record in Postgres (`consultation_consents`) containing the doctor's timestamped attestation of verbal consent satisfy the consent burden under the Digital Personal Data Protection (DPDP) Act 2023 and the Indian Evidence Act (Sec 65B electronic records), or must the raw audio recording itself preserve the audio segment where consent was spoken?
- **Current Engineering Default**:
  - `consent_method = 'verbal'` is permitted by database constraint.
  - The doctor initiates the consent record before recording begins (`trg_check_recording_consent` strictly enforces that consent must exist with `status = 'granted'`).
  - Mobile UI shows an anti-coercion disclaimer reminding the clinician of required patient notification.
- **Configuration Change Path**:
  - **Zero Schema Change**: Fully policy-driven via `consent_policies` table.
  - If verbal consent is disallowed by counsel: Insert a new `consent_policies` row with `allowed_methods` excluding `'verbal'`:
    ```sql
    INSERT INTO public.consent_policies (version, allowed_methods, notes)
    VALUES (2, ARRAY['checkbox','otp','signature','other']::public.consent_method[], 'Verbal consent disabled per legal counsel determination');
    ```
  - Mobile client (`ConsentCaptureScreen`) dynamically reads `get_active_consent_policy()` and immediately disables verbal option across all clinics.

---

### RLR-02: Raw Audio Retention Horizon & Purge Worker
- **Context**: DPDP Act 2023 mandates data minimization and purpose limitation (data must be erased as soon as the specified purpose is fulfilled). However, state medical councils and the National Medical Commission (NMC) mandate 3-year record retention for clinical case records for medico-legal liability defense.
- **Legal Question**: Is raw ambient consultation audio classified as:
  - (A) Ephemeral working data that should be destroyed immediately after structured transcript and doctor-finalized EHR entry are generated (e.g., within 24–72 hours)? OR
  - (B) Part of the official clinical record that must be retained for 3 years?
- **Current Engineering Default**:
  - `data_retention_policies.retention_days` is set to `NULL` for all retention classes (`raw_audio`, `interim_transcript`, `ai_draft`).
  - `retention-purge-worker` is completely **inert** when `retention_days IS NULL`. It will log that policies are unconfigured and delete zero rows or storage objects.
  - The worker explicitly skips any record with `legal_hold = TRUE`.
- **Unresolved Legal Decisions**:
  1. What is the lawful retention window for `raw_audio`?
  2. Does the patient's right to erasure under DPDP Act apply to audio when medical malpractice limitation periods have not expired?
- **Configuration Change Path**:
  - Update `data_retention_policies` with approved integer days via administrative SQL:
    ```sql
    UPDATE data_retention_policies
    SET retention_days = <approved_days>, updated_at = NOW()
    WHERE data_class = 'raw_audio';
    ```

---

### RLR-03: Third-Party AI Data Processor Agreements
- **Context**: Medico OPD Assistant uses Deepgram for Speech-to-Text (STT) and Anthropic Claude for clinical summarization. Both operate as Data Processors under Indian DPDP Act.
- **Legal Question**: Can patient clinical audio and de-identified transcripts be transferred or processed by cloud providers whose data centers are outside India without violating DPDP Act cross-border transfer rules and ABDM data localization requirements?
- **Current Engineering Default**:
  - Mobile client NEVER connects directly to Deepgram or Anthropic.
  - All calls originate server-side from Supabase Edge Functions.
  - PII minimizer (`data_minimizer.ts`) redacts 10-digit phone numbers, 12-digit Aadhaar patterns, email addresses, and Indian PIN codes prior to transmitting transcripts to the LLM.
- **Unresolved Legal Decisions**:
  1. Must Enterprise "Zero Data Retention" (ZDR) agreements be executed with Deepgram and Anthropic before processing any production data?
  2. Does DPDP cross-border data transfer blacklist permit AI processing in US/EU regions?
- **Configuration Change Path**:
  - Provider abstraction interfaces (`STTProvider`, `LLMProvider`) allow hot-swapping cloud providers for on-premise or India-local models (e.g. self-hosted Whisper / vLLM) by updating Edge Function environment variables (`STT_PROVIDER=local_whisper`, `LLM_PROVIDER=local_vllm`).

---

### RLR-04: Pediatric and Guardian Consent Thresholds
- **Context**: Minors (<18 years under Indian Majority Act) cannot legally execute contracts or give independent consent under DPDP Act Sec 9.
- **Legal Question**: What validation is legally required to verify guardian identity and authority before recording an OPD consultation for a pediatric patient?
- **Current Engineering Default**:
  - UI provides an actor toggle (`patient` vs `guardian`).
  - Selecting `guardian` makes `guardian_name` and `guardian_relationship` strictly required in both mobile UI validation and PostgreSQL DB table check constraint (`chk_guardian_fields`).
- **Configuration Change Path**:
  - **Zero Schema Change**: Fully policy-driven via `consent_policies` table and `consultation_consents` extension columns (`verification_method`, `verification_metadata`, `verified_at`).
  - If counsel mandates guardian identity verification: Insert a new `consent_policies` row with `pediatric_verification_required = true`:
    ```sql
    INSERT INTO public.consent_policies (version, allowed_methods, pediatric_verification_required, notes)
    VALUES (2, ARRAY['verbal','checkbox','otp','signature','other']::public.consent_method[], true, 'Guardian verification mandated per legal counsel determination');
    ```
  - Mobile client (`ConsentCaptureScreen`) dynamically reads policy and surfaces verification workflow without modifying database schema.

---

### RLR-05: ABDM Consent Manager (CM) Integration
- **Context**: Ayushman Bharat Digital Mission (ABDM) specifies a federated consent framework via National Health Authority (NHA) Consent Managers.
- **Legal Question**: Does OPD audio recording fall under ABDM Electronic Health Record (EHR) data types requiring ABDM CM artifact generation?
- **Current Engineering Default**:
  - `consultation_consents` table includes nullable `consent_manager_artifact_id`.
  - OPD baseline operations operate on direct clinic-patient consent without hard dependency on ABDM gateway uptime.
- **Unresolved Legal Decisions**:
  1. Is ABDM CM integration mandatory for private OPD practices not participating in public schemes?
- **Configuration Change Path**:
  - Webhooks in `consultation_consents` can listen for ABDM CM revoke notifications and update `status = 'revoked'`.

---

## 3. Policy Verification Checklist (For Legal Counsel Sign-off)

- [ ] Approved retention period for raw audio (`raw_audio` retention_days = _____ )
- [ ] Approved retention period for intermediate transcripts (`interim_transcript` retention_days = _____ )
- [ ] Approved verbal consent disclaimer wording for mobile UI
- [ ] Signed Data Processing Agreement (DPA) with STT vendor
- [ ] Signed Data Processing Agreement (DPA) with LLM vendor
- [ ] Determination on cross-border data transfer compliance under DPDP Act 2023
