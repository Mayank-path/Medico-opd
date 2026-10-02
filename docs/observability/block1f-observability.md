# Block 1F — Observability, Metrics & Production-Safe Diagnostics

## Medico-OPD Clinical Documentation Platform

---

### 1. Architecture Overview

Medico-OPD implements an observability and telemetry subsystem designed specifically for clinical environments subject to the **Digital Personal Data Protection (DPDP) Act 2023** and medical confidentiality standards.

The system decouples operational monitoring from proprietary monitoring vendors (such as Sentry, OpenTelemetry, Datadog) through clean interface abstractions:

```text
+-----------------------------------------------------------------------------------+
| Flutter Mobile Client (Doctor Device)                                             |
|                                                                                   |
|  [Screens]                                                                        |
|      |                                                                            |
|  [Services: Patient / Consultation / Recording / AiDraft]                         |
|      |                                                                            |
|  [CorrelationContext] <---> [TelemetryService Interface]                          |
|                                   |                                               |
|                    +--------------+--------------+                                |
|                    |                             |                                |
|         [StructuredLogger]             [InMemoryTelemetryService]                 |
|         (JSON format output)           (Counters, Timings, Errors)                |
|                    |                             |                                |
|         [SensitiveDataRedactor]        (Production Plug: Sentry / OTel)           |
+-----------------------------------------------------------------------------------+
                                   |
                      HTTP Headers with Correlation:
                      - X-Correlation-ID: corr_<ts>_<uuid>
                      - X-Request-ID: req_<ts>_<uuid>
                                   |
                                   v
+-----------------------------------------------------------------------------------+
| Supabase Edge Functions (Deno Runtime)                                            |
|                                                                                   |
|  [process-consultation]                                                           |
|      |                                                                            |
|  [EdgeLogger] ---> [EdgeRedactor] ---> console.log(JSON)                          |
|      |                                                                            |
|  [Pipeline Stages with Monotonic Timers]:                                         |
|      1. Auth & Doctor Verification                                                |
|      2. Consent Verification Check                                                |
|      3. Atomic State Claim (check-and-set)                                        |
|      4. STT Provider (Deepgram with Exponential Backoff + Jitter)                 |
|      5. Privacy Data Minimization (DPDP Section 8)                                |
|      6. Transcript Persistence                                                    |
|      7. Consent Mid-flight Revalidation                                           |
|      8. LLM Structuring (Claude with Exponential Backoff + Jitter)                |
|      9. AI Clinical Schema Validation                                             |
|     10. Draft Persistence & Final State Transition                                |
+-----------------------------------------------------------------------------------+
```

---

### 2. Operational Event Taxonomy

Every event emitted in operational logs conforms to a strictly defined JSON schema:

```json
{
  "timestamp": "2026-09-27T04:00:00.000Z",
  "event": "RECORDING_UPLOADED",
  "severity": "INFO",
  "component": "recording_service",
  "operation": "upload_audio",
  "request_id": "req_1790450000_a1b2c3d4",
  "correlation_id": "corr_1790450000_a1b2c3d4",
  "clinic_id_hash": "a1b2c3d4e5f6",
  "recording_id": "01923050-0000-7000-8000-000000000001",
  "consultation_id": "01923050-0000-7000-8000-000000000002",
  "attempt_count": 1,
  "duration_ms": 230,
  "error_code": null,
  "metadata": {
    "returned_count": 20,
    "has_more": true
  }
}
```

#### Standard Event Types:
* `RECORDING_UPLOADED`: Client audio binary successfully uploaded and registered.
* `STORAGE_UPLOAD_SUCCESS`: Supabase Storage private bucket write succeeded.
* `STORAGE_UPLOAD_FAILED`: Storage transfer interrupted or rejected.
* `TRIGGER_EDGE_PROCESSING`: Client dispatched async Edge Function processing request.
* `EDGE_PROCESSING_SUCCESS`: Edge Function completed and returned 200 OK.
* `EDGE_PROCESSING_NON_200`: Edge Function returned non-200 status code.
* `PROCESSING_STARTED`: Edge Function received request and commenced pipeline.
* `CONSENT_REVOKED`: Mid-flight pipeline check aborted because patient consent was revoked.
* `ALREADY_PROCESSING`: Idempotent rejection; recording is actively transcribing/structuring.
* `STT_COMPLETED`: Deepgram transcription succeeded.
* `STT_FAILED`: Deepgram transcription failed or timed out.
* `LLM_COMPLETED`: Claude clinical structuring completed successfully.
* `LLM_FAILED`: Claude clinical structuring failed or rate-limited.
* `DRAFT_REVIEW_UPDATED`: Doctor submitted review edits under optimistic concurrency.
* `DRAFT_REJECTED`: Doctor rejected AI draft.
* `DRAFT_FINALIZED`: Doctor finalized clinical note (locked permanently against mutations).

---

### 3. Metric Definitions

All metrics adhere to low-cardinality label dimensions (`component`, `stage`, `provider`, `error_code`, `status`, `retryable`, `method`). High-cardinality keys (`patient_id`, `consultation_id`, `recording_id`, `request_id`, `prompt`, `transcript`) are strictly forbidden and automatically stripped.

| Metric Name | Type | Unit | Allowed Labels | Operational Meaning | Privacy Level |
| :--- | :---: | :---: | :--- | :--- | :--- |
| `recordings_created_total` | Counter | count | `component` | Total recordings registered in database | Safe Aggregate |
| `recordings_uploaded_total` | Counter | count | `component` | Total recordings successfully uploaded | Safe Aggregate |
| `recordings_processing_total` | Counter | count | `stage` | Total processing jobs dispatched | Safe Aggregate |
| `recordings_completed_total` | Counter | count | `status` | Total recordings reaching `transcribed` | Safe Aggregate |
| `recordings_failed_total` | Counter | count | `error_code` | Total recordings transitioning to `failed` | Safe Aggregate |
| `upload_duration_ms` | Timing | ms | `component` | Client-side audio storage upload duration | Operational Latency |
| `claim_latency_ms` | Timing | ms | `component` | Duration of atomic check-and-set claim query | Database Latency |
| `stt_duration_ms` | Timing | ms | `provider` | End-to-end Deepgram STT transcription time | External Provider |
| `transcript_persistence_ms` | Timing | ms | `component` | Time taken to insert sanitized transcript row | Database Latency |
| `llm_duration_ms` | Timing | ms | `provider` | End-to-end Claude clinical structuring time | External Provider |
| `draft_persistence_ms` | Timing | ms | `component` | Time taken to persist AI draft row | Database Latency |
| `total_processing_duration_ms`| Timing | ms | `status` | End-to-end Edge Function lifecycle duration | System Latency |
| `deepgram_requests_total` | Counter | count | `provider` | Total requests sent to Deepgram API | Provider Volume |
| `deepgram_success_total` | Counter | count | `provider` | Total successful Deepgram API responses | Provider Volume |
| `deepgram_failure_total` | Counter | count | `provider` | Total failed Deepgram API calls | Provider Quality |
| `deepgram_429_total` | Counter | count | `provider` | Rate limit errors from Deepgram | Provider Capacity |
| `deepgram_5xx_total` | Counter | count | `provider` | Server/upstream errors from Deepgram | Provider Uptime |
| `anthropic_requests_total` | Counter | count | `provider` | Total requests sent to Claude API | Provider Volume |
| `anthropic_success_total` | Counter | count | `provider` | Total successful Claude API responses | Provider Volume |
| `anthropic_failure_total` | Counter | count | `provider` | Total failed Claude API calls | Provider Quality |
| `anthropic_429_total` | Counter | count | `provider` | Rate limit (TPM/RPM) errors from Claude | Provider Capacity |
| `anthropic_5xx_total` | Counter | count | `provider` | Server/upstream errors from Claude | Provider Uptime |
| `retry_attempt_total` | Counter | count | `stage`, `provider` | Total automated retry attempts dispatched | Retry Overhead |
| `retry_success_total` | Counter | count | `stage`, `provider` | Retries that subsequently succeeded | Self-Healing Rate |
| `retry_terminal_failure_total`| Counter | count | `stage`, `provider` | Retries that exhausted all attempts | Terminal Failures |
| `patient_query_latency_ms` | Timing | ms | `method` | Keyset pagination directory query latency | Client Responsiveness |
| `patient_search_latency_ms` | Timing | ms | `method` | Trigram search query latency | Client Responsiveness |
| `consultation_query_latency_ms` | Timing | ms | `method` | Patient consultation history query latency | Client Responsiveness |

---

### 4. Stable Error Taxonomy

The application maps all internal and upstream exceptions into a stable, privacy-safe error code taxonomy:

| Error Code | Category | User-Facing Message | Diagnostic Meaning |
| :--- | :--- | :--- | :--- |
| `CONSENT_REVOKED` | `security` | Patient consent has been revoked. Processing stopped. | Patient revoked consent before or mid-flight. |
| `CONSENT_REQUIRED` | `security` | Patient consent is required before proceeding. | Missing active consent row before recording. |
| `UNAUTHORIZED_ACCESS` | `security` | You do not have permission to access this clinical record. | Doctor not affiliated or JWT invalid. |
| `CROSS_TENANT_ACCESS_DENIED` | `security` | You do not have permission to access this clinical record. | Attempt to access cross-clinic data. |
| `RECORDING_NOT_FOUND` | `lifecycle` | The consultation recording could not be located. | Recording row does not exist or access denied. |
| `RECORDING_ALREADY_PROCESSING`| `lifecycle`| Audio processing is already in progress for this consultation. | Competing worker or user double-tap. |
| `CLAIM_FAILED` | `lifecycle` | Could not secure a processing worker. Please retry shortly. | Check-and-set claim failed. |
| `STT_TIMEOUT` | `stt` | Speech-to-text service is temporarily unavailable. Please retry. | Deepgram request exceeded HTTP timeout. |
| `STT_RATE_LIMIT` | `stt` | Speech-to-text service is temporarily unavailable. Please retry. | Deepgram returned HTTP 429. |
| `STT_PROVIDER_ERROR` | `stt` | Speech-to-text service is temporarily unavailable. Please retry. | Deepgram returned HTTP 5xx or bad audio. |
| `TRANSCRIPT_PERSIST_FAILED` | `stt` | Speech-to-text service is temporarily unavailable. Please retry. | Database error saving transcript row. |
| `LLM_TIMEOUT` | `llm` | AI clinical note generation is temporarily unavailable. Transcript saved. | Claude API call timed out. |
| `LLM_RATE_LIMIT` | `llm` | AI clinical note generation is temporarily unavailable. Transcript saved. | Claude returned HTTP 429. |
| `LLM_PROVIDER_ERROR` | `llm` | AI clinical note generation is temporarily unavailable. Transcript saved. | Claude returned HTTP 5xx. |
| `AI_SCHEMA_INVALID` | `llm` | AI clinical note generation is temporarily unavailable. Transcript saved. | LLM response omitted chief complaints. |
| `DRAFT_PERSIST_FAILED` | `llm` | AI clinical note generation is temporarily unavailable. Transcript saved. | Database error inserting AI draft row. |
| `STORAGE_UPLOAD_FAILED` | `storage` | Failed to transfer consultation audio. Check connection. | Storage bucket write interrupted. |
| `DATABASE_ERROR` | `database` | Database synchronization error. Please refresh and try again. | PostgREST / PostgreSQL exception. |
| `CONFLICT_ERROR` | `database` | Concurrent modification detected. Draft was modified elsewhere. | Optimistic concurrency revision mismatch. |
| `NETWORK_UNAVAILABLE` | `network` | Network connection issue. Please verify connection. | Device offline or socket error. |
| `UNKNOWN_PROCESSING_ERROR` | `unknown` | An unexpected processing error occurred. Please try again. | Catch-all for unclassified exceptions. |

---

### 5. Privacy & Automated Redaction Rules

Under DPDP Act 2023 Section 8 and medical privacy rules, protected health information (PHI) and authentication secrets must never enter log files, trace spans, or metric labels:

1. **Authentication Secrets**:
   * JWT tokens (`eyJ...`) -> `[REDACTED_JWT]`
   * API Keys (`sk-ant-...`, `Bearer ...`) -> `[REDACTED_API_KEY]`
   * Signed URLs with tokens -> `[REDACTED_SIGNED_URL]`
2. **Patient Identifiers**:
   * Phone numbers (`9876543210`, `+91-...`) -> `[REDACTED_PHONE]`
   * Email addresses (`name@domain.com`) -> `[REDACTED_EMAIL]`
   * Indian Aadhaar numbers (`\d{4}\s\d{4}\s\d{4}`) -> `[REDACTED_AADHAAR]`
3. **Clinical Content**:
   * Metadata dictionary keys containing `transcript`, `prompt`, `audio`, `chief_complaint`, `diagnosis`, `prescription`, `notes`, or `raw_text` are replaced with `[REDACTED_CLINICAL_PAYLOAD]`.
4. **Tenant Anonymization**:
   * Raw clinic UUIDs are hashed using SHA-256 (`clinic_id_hash: 12-char prefix`) before entering external logs, preventing clinic tracking across third-party observability providers.

---

### 6. Correlation & Request Tracing

Every consultation lifecycle establishes a root `CorrelationContext`:

1. **Correlation ID (`X-Correlation-ID`)**:
   * Format: `corr_<timestamp>_<uuid>`
   * Created at recording upload.
   * Preserved across retries, Edge Function invocations, background polling, and doctor reviews.
2. **Request ID (`X-Request-ID`)**:
   * Format: `req_<timestamp>_<uuid>`
   * Created per individual HTTP attempt.
   * Changes on every retry while correlation ID remains fixed.
   * Returned in all Edge Function response headers for easy client-server log alignment.

---

### 7. Operational Debugging Workflow

When a doctor or administrator reports an issue:

```text
Doctor reports failure in Consultation Screen
                │
                ▼
1. Extract "Request ID" or "Correlation ID" from client error dialog or session log
                │
                ▼
2. Search Edge Function structured logs for correlation_id:
   grep "corr_1790450000_a1b2c3d4" edge_logs.json
                │
                ▼
3. Inspect pipeline stage progression:
   ├── PROCESSING_STARTED        (OK)
   ├── claim_latency_ms: 12ms    (OK)
   ├── stt_duration_ms: 2150ms   (OK - deepgram_success_total)
   ├── DATA_MINIMIZATION         (OK - redactions_performed: 2)
   ├── LLM_FAILED                (FAILED - error_code: LLM_RATE_LIMIT, attempt: 3)
   └── recordings_failed_total   (error_code: LLM_RATE_LIMIT)
                │
                ▼
4. Diagnosis reached:
   - Stage: LLM clinical structuring
   - Cause: Provider rate limiting (429) exhausted 3 retries
   - Impact: Transcript safely saved; draft pending retry
   - Zero patient clinical notes or audio listened to / viewed during diagnosis!
```

---

### 8. Production Plug-in Interface (Future Sentry / OpenTelemetry)

To integrate Sentry or OpenTelemetry in production without altering application code:

```dart
class SentryTelemetryService implements TelemetryService {
  @override
  void log(StructuredLogEntry entry) {
    Sentry.addBreadcrumb(Breadcrumb(
      message: entry.event,
      category: entry.component,
      level: _mapSeverity(entry.severity),
      data: entry.toJson(),
    ));
  }

  @override
  void increment(String metricName, {Map<String, String>? labels, int value = 1}) {
    // Forward to Sentry Metrics / StatsD / OpenTelemetry Meter
  }

  @override
  void timing(String metricName, int durationMs, {Map<String, String>? labels}) {
    // Forward to OpenTelemetry Histogram / Sentry Span
  }

  @override
  void recordError(dynamic error, {StackTrace? stackTrace, String? errorCode, String? correlationId, Map<String, dynamic>? context}) {
    Sentry.captureException(
      error,
      stackTrace: stackTrace,
      withScope: (scope) {
        if (correlationId != null) scope.setTag('correlation_id', correlationId);
        if (errorCode != null) scope.setTag('error_code', errorCode);
        if (context != null) scope.setContexts('operational_context', context);
      },
    );
  }
}
```
In `main.dart`, invoke: `Telemetry.setInstance(SentryTelemetryService());`.

---

### 9. Production Safety Verification

* Production DB modified: **NO**
* Production data accessed: **NO**
* Production migrations applied: **NO**
* Production secrets changed: **NO**
* Production Edge Functions deployed: **NO**
* Real patient data used: **NO**
