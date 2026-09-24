# REGULATORY & COMPLIANCE SPECIFICATION: CLINICAL AUDIO RECORDING & AI DOCUMENTATION

**Applicable Territory**: Republic of India  
**Scope**: Consultation Audio Capture, Sensitive Health Data Processing, Speech Transcription, and AI-Assisted Clinical Documentation (PHASE-003)  
**Governing Laws & Frameworks**:
1. Digital Personal Data Protection Act, 2023 (DPDP Act, 2023)
2. Telemedicine Practice Guidelines, 2020 (Appendix 5 to Indian Medical Council Regulations, 2002 / National Medical Commission)
3. Indian Medical Council (Professional Conduct, Etiquette and Ethics) Regulations, 2002 (Regulation 1.3 - Maintenance of Medical Records)
4. Information Technology Act, 2000 & CERT-In Cyber Security Directions, 2022
5. Ayushman Bharat Digital Mission (ABDM) Health Data Management Policy, 2022

---

## 1. Statutory & Regulatory Analysis

### 1.1 Digital Personal Data Protection Act, 2023 (DPDP Act, 2023)

#### A. Data Classification & Processing Lawfulness (Sections 4 & 5)
- Under the DPDP Act 2023, personal data encompasses any data about an individual who is identifiable by or in relation to such data. Patient audio recordings, transcripts, diagnostic impressions, and prescriptions constitute personal health data.
- **Section 4**: Personal data may only be processed for a lawful purpose for which the Data Principal (patient) has given consent, or for certain legitimate uses.
- **Section 5 (Notice Requirement)**: Every request for consent must be accompanied or preceded by an explicit, transparent notice informing the Data Principal:
  1. The specific personal data to be collected (e.g. ambient voice recording of consultation).
  2. The exact purpose for processing (e.g. speech-to-text transcription to assist the attending doctor in drafting outpatient notes and prescriptions).
  3. The manner in which the Data Principal may exercise their rights (access, correction, withdrawal).
  4. How the Data Principal may lodge a complaint with the Data Protection Board of India.
  5. The notice must be available in English or any of the 22 languages specified in the Eighth Schedule to the Constitution of India.

#### B. Consent Standards & Withdrawal (Section 6)
- **Section 6(1)**: Consent must be **free, specific, informed, unconditional, and unambiguous**, accompanied by a **clear affirmative action**. Consent cannot be bundled into generic terms of service or made a condition for receiving standard medical treatment.
- **Section 6(4)**: The Data Principal has the right to withdraw consent at any time.
- **Section 6(5)**: The consequence of withdrawal shall not affect the lawfulness of processing prior to withdrawal. Upon withdrawal, the Data Fiduciary (the clinic/doctor) must cease processing and cause any Data Processor (transcription or AI vendor) to cease processing within a reasonable timeframe.
- **Section 6(7)**: The process of withdrawing consent must be as easy as the process of giving consent.

#### C. Data Minimization, Purpose Limitation & Storage Limitation (Section 8)
- **Purpose Limitation (Section 8(1))**: Personal data collected for consultation documentation cannot be repurposed for model training, advertising, cross-clinic profiling, or pharmaceutical marketing without distinct, explicit consent.
- **Storage Limitation & Erasure (Section 8(7))**: Personal data must be erased upon the Data Principal withdrawing consent or as soon as it is reasonable to assume that the specified purpose is no longer being served.
- **The Statutory Retention Carve-Out (Section 8(7) Proviso)**: Personal data **shall not be erased** where retention is *necessary for compliance with any law for the time being in force*. This establishes the critical interplay with the NMC 3-year record retention rule (see Section 1.3 below).

#### D. Data Principal Rights (Sections 11 & 12)
- **Section 11 (Right to Access)**: Patient has the right to obtain a summary of personal data being processed, identities of third-party processors, and description of categories shared.
- **Section 12 (Right to Correction & Erasure)**: Patient may request correction of inaccurate or misleading data, completion of incomplete data, updating of data, and erasure of data (subject to statutory retention exceptions).

#### E. Breach Notification Obligations (Section 8(6))
- In the event of a personal data breach, the Data Fiduciary is statutorily mandated to notify:
  1. The **Data Protection Board of India**.
  2. Each **affected Data Principal** (patient).
- Form, manner, and timeline are governed by DPDP rules. Concurrently, CERT-In directions impose an ultra-fast 6-hour reporting window (see Section 1.4).

---

### 1.2 Telemedicine Practice Guidelines, 2020 & NMC / Medical Council Rules

#### A. Telemedicine Practice Guidelines, 2020 (MoHFW / NITI Aayog / NMC)
- **Clause 3.6 & 3.7 (Patient Consent)**:
  - Implied consent applies when a patient initiates a basic teleconsultation.
  - **Explicit Consent is strictly mandatory** when consultation recording is initiated by the Registered Medical Practitioner (RMP).
  - Explicit consent must be recorded in the clinical record: *"If an RMP wishes to record a teleconsultation session, explicit written/recorded consent must be obtained from the patient."*
- **Clause 5 (Medical Records & Documentation)**:
  - RMPs are legally obligated to maintain an audit trail and clinical documentation of every consultation.
  - The prescription and clinical summary must be maintained as standard medical records.

#### B. Indian Medical Council (Professional Conduct, Etiquette and Ethics) Regulations, 2002
- **Regulation 1.3 (Maintenance of Medical Records)**:
  - Every Registered Medical Practitioner must maintain medical records pertaining to patients for a minimum period of **three (3) years** from the date of commencement of treatment.
  - Medical records must be produced within 72 hours if requested by the patient, legal authorities, or medical councils.

---

### 1.3 Reconciling the Conflict: DPDP Right to Erasure vs. NMC 3-Year Retention

A major tension exists between:
1. **DPDP Act Section 12(3) / Section 8(7)**: Patient right to demand erasure of personal data upon consent withdrawal or request.
2. **NMC / MCI Regulation 1.3 & Telemedicine Guidelines 2020**: Doctor's strict statutory obligation to preserve medical records for at least 3 years to defend against medical negligence allegations under the Consumer Protection Act, 2019 or National Medical Commission disciplinary inquiries.

#### The Architectural Resolution:
- **Statutory Exemption Applied**: Under **Section 8(7) Proviso** of the DPDP Act 2023, data retention is permitted and mandated where required by law. NMC Regulation 1.3 has statutory force under the National Medical Commission Act, 2019. Therefore, **a patient's request for erasure cannot force deletion of the finalized clinical note, prescription, or consultation audit log within the mandatory 3-year statutory retention window.**
- **Differentiation of Raw Audio vs. Clinical Record**:
  - **Raw Audio Recording**: Raw audio is an intermediate sensory capture used to generate the clinical note. The law mandates retention of the *medical record* (the clinical summary, diagnosis, prescribed drugs, investigation orders, and digital interaction log), **NOT the continuous raw voice recording**.
  - **Storage Minimization Rule**: Raw audio files carry disproportionate biometric and privacy risk. Medico OPD Assistant adopts a policy of **short-term retention for raw audio (default: 7 days post-finalization)** to allow doctor verification of the transcript, after which raw audio is permanently purged from storage. The finalized structured note and interaction metadata are retained for the statutory 3-year period under Invariant 10 (DELETE-denied RLS).
  - If a patient withdraws consent during or immediately after recording, the raw audio and pending AI draft are immediately purged, but the patient record and doctor consultation timestamp remain logged as an aborted session.

---

### 1.4 Cybersecurity & Incident Reporting: CERT-In 2022 Directions

- Under Section 70B(6) of the Information Technology Act, 2000 and the CERT-In Directions (April 2022):
  - Any cybersecurity incident involving unauthorized access to personal health databases, server breach, ransomware, or leak of audio files must be reported to the **Indian Computer Emergency Response Team (CERT-In)** within **six (6) hours** of noticing or being brought to notice of the incident.
  - ICT system logs (access logs, audit trails) must be maintained within the Indian jurisdiction for a rolling period of **180 days** (or longer under medical rules).

---

### 1.5 Data Residency & Cross-Border Transfer Considerations

#### A. DPDP Act 2023 (Section 16)
- The DPDP Act adopts a "blacklisting / negative list" approach: data transfers outside India are permitted unless specifically restricted to designated countries by Central Government notification.
- **Section 16(2)**: Higher sectoral restrictions take precedence over the DPDP Act.

#### B. ABDM Health Data Management Policy (Clause 9.1) & DISHA Draft
- Under the National Health Authority (NHA) Ayushman Bharat Digital Mission (ABDM) Health Data Management Policy:
  - **Clause 9.1**: Personal health data shall be processed and stored **only within the territory of India**.
- **Supabase Cloud Infrastructure Evaluation**:
  - Supabase supports AWS `ap-south-1` (Mumbai, India).
  - **Mandatory Policy**: Production deployment of Medico OPD Assistant processing Indian patient health data MUST reside in an Indian cloud region (AWS Mumbai `ap-south-1`). Hosting database or audio storage in foreign regions (e.g. `ap-southeast-1` Singapore or `us-east-1` USA) violates ABDM data localization requirements for healthcare integrations.

---

## 2. Legally Defensible Mobile Consent-Capture UX

For audio recording to be legally valid under Section 6 of the DPDP Act and the Telemedicine Practice Guidelines 2020, consent cannot be assumed, implied, or hidden.

### 2.1 Core UX Requirements
1. **Explicit Affirmative Action**:
   - The doctor or patient must interact with a dedicated consent modal prior to recording activation.
   - Dual-mode consent is supported:
     - **Verbal Confirmed by Doctor (`verbal_confirmed_by_doctor`)**: Doctor asks the patient in person/teleconsult, explains ambient recording for documentation, and taps "Patient Confirmed Verbally" with mandatory verification checkbox.
     - **Patient Digital Signature (`patient_signature`)**: On-device signature pad signed by patient/guardian.
     - **In-App Patient Toggle (`in_app_toggle`)**: Direct patient confirmation if secondary patient screen/device is used.
2. **Unconditional Care (Anti-Coercion)**:
   - The UI must prominently state: *"Declining audio recording will NOT affect patient care. The doctor can proceed with standard manual documentation."*
   - If consent is declined or cancelled, the consultation remains open in standard manual mode.
3. **Comprehensive Audit Metadata**:
   - Recorded consent stores: `patient_id`, `consultation_id`, `consent_given` (`true`), `consent_timestamp` (`TIMESTAMPTZ`), `consent_method`, `recorded_by` (`doctor_id`), and optional signature hash/binary.
4. **Frictionless Withdrawal Flow**:
   - During recording or consultation review, a persistent "Withdraw Consent / Stop & Discard Audio" action is surfaced.
   - Upon withdrawal: audio capture halts immediately, uncommitted audio buffers are wiped from device memory, any staged cloud upload is aborted, and the database status updates to `withdrawn_at = now()`.

---

## 3. Items Flagged "REQUIRES LEGAL REVIEW"

The following points represent legal determinations that require formal review by qualified legal counsel prior to enterprise deployment:

| Item Code | Scope & Description | Legal Question / Ambiguity |
|---|---|---|
| **RLR-01** | **Verbal Consent Defense in Court** | Under DPDP Act Section 6, does a doctor's digital attestation of a patient's verbal consent (`verbal_confirmed_by_doctor`) sufficiently satisfy the evidentiary burden of proving "affirmative action by the Data Principal" in the event of a dispute before the Data Protection Board of India, or is written/digital patient signature strictly mandatory? |
| **RLR-02** | **Raw Audio Purge Timeline (7 vs 30 Days vs 3 Years)** | Does purging raw audio 7 days post-transcription conflict with any local medical council interpretation of Telemedicine Guideline 5 ("maintain interaction logs including audio/video records for 3 years"), where an opposing litigant might subpoena the raw audio rather than the transcript in a medical negligence case? |
| **RLR-03** | **Cloud STT/AI Vendor Data Processor Liability** | If using a third-party cloud STT/LLM API (e.g. AWS Transcribe, OpenAI, Anthropic) operating under "Zero Data Retention (ZDR)" enterprise terms, does transferring fleeting encrypted voice snippets across foreign API endpoints violate ABDM Clause 9.1 data localization if the server is outside India? |
| **RLR-04** | **Minor / Pediatric Consent Execution** | Under DPDP Act Section 9, processing personal data of a child (under 18) requires verifiable parental consent. What specific mobile verification mechanism (e.g. DigiLocker, Aadhaar OTP, or physical guardian attestation) meets DPDP rules for pediatric OPD visits? |
| **RLR-05** | **Consent Manager Integration Timeline** | Under DPDP Act Section 6(7)-(9), Data Principals may manage consent via registered Consent Managers. When MeitY operationalizes Consent Manager technical architectures, what API hooks must Medico OPD Assistant expose? |

---

*This compliance specification serves as the formal regulatory foundation for TASK-003-01 and must be maintained as a binding system artifact throughout Phase 3.*
