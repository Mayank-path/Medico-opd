# Medico-OPD: Storage Lifecycle, Retention Enforcement & Orphan Audio Cleanup

## Block 1G Architecture & Technical Specification

---

## 1. Storage Lifecycle Architecture

The outpatient clinical audio lifecycle balances two critical legal/regulatory mandates:
* **Statutory Medical Documentation**: Consultation notes and finalized clinical history must be permanently preserved.
* **Data Minimization (DPDP Act 2023 / Medical Guidelines)**: High-liability, unencrypted or raw clinical audio must be purged after AI draft generation and physician review once the statutory retention window has elapsed.

### State Transition Diagram

```text
[ Audio Recording Created ]
            ↓
[ Encrypted Binary Uploaded to consultation-recordings ]
  Path: clinics/{clinic_id}/consultations/{consultation_id}/{recording_id}.m4a
            ↓
[ Processing: STT Minimization & Structuring ]
  Status: pending → queued → transcribing → structuring → transcribed
            ↓
[ Doctor Reviews & Finalizes Consultation ]
            ↓
[ Active Retention Horizon ]
  retention_expires_at = created_at + policy.retention_days
            ↓
[ Retention Window Expired & Legal Hold Inactive ]
            ↓
[ Atomic Claim: claim_recording_for_retention_deletion() ]
  Status transitions to pending_deletion
            ↓
[ Storage Purge: storage.objects.remove([path]) ]
            ↓
[ Finalize & Audit ]
  Status transitions to deleted; deleted_at recorded; audit_log appended
```

---

## 2. Retention Policy Resolution

The platform supports granular, clinic-level data retention horizons while maintaining a platform default.

### Resolution Precedence:
1. **Clinic Override**: If a policy exists in `public.data_retention_policies` matching `(clinic_id = :clinic_id, data_class = 'raw_audio')` and `is_enabled = true`, its `retention_days` is utilized.
2. **Platform Default**: If no active clinic override exists, the global row where `clinic_id IS NULL` and `is_enabled = true` is utilized.
3. **Fail-Closed Inert Retention**: If no policy row matches, or if `retention_days IS NULL`, or if `is_enabled = false`, the system resolves to `retention_days = NULL`. Under this state, the retention worker remains **completely inert** and executes **zero deletions**.

---

## 3. Storage Artifact & Orphan Classification

Artifacts are categorized into four mutually exclusive categories to prevent destructive data loss:

| Category | Storage Object | Database Row | Status / Condition | Cleanup Action |
| :--- | :--- | :--- | :--- | :--- |
| **Retention Eligible** | Exists | Exists | Expired (`retention_expires_at <= now()`), unheld (`legal_hold = false`), not processing | Atomic claim → Storage purge → Mark `deleted` |
| **Active Processing Artifact** | Exists | Exists | `pending`, `queued`, `transcribing`, `structuring`, or active lease (`lease_expires_at > now()`) | **PRESERVED**: Deletion strictly blocked |
| **Storage Orphan** | Exists | Missing | File in bucket with no `recordings` row, and file age exceeds 2-hour upload grace window | Purged via `ORPHAN_DELETE` audit event |
| **Database Orphan** | Missing (404) | Exists | DB row references storage path, but file is 404 in bucket | Reconciled via `reconcile_missing_recording_storage()`; audit logged |

---

## 4. Deletion Eligibility Rules

Deletion is only permitted when **ALL** of the following conditions are simultaneously met:
1. `recordings.deletion_status = 'active'`
2. `recordings.legal_hold = false`
3. `recordings.processing_status NOT IN ('pending', 'queued', 'transcribing', 'structuring')`
4. Active lease has expired or is null (`lease_expires_at IS NULL OR lease_expires_at < now()`)
5. Explicit expiration is reached (`retention_expires_at IS NOT NULL AND retention_expires_at <= now()`)
6. Active policy is not inert (`policy.is_enabled = true AND policy.retention_days IS NOT NULL`)
7. Tenant validation: Storage path clinic ID matches recording clinic ID

---

## 5. Dry-Run Mode

Both the Dart service (`StorageLifecycleService`) and the Edge Function (`retention-purge-worker`) implement an idempotent dry-run capability (`dry_run: true`).

### Dry-Run Invariants:
* Zero database mutations (no rows updated or claimed).
* Zero storage deletions (no files removed).
* Returns candidate and orphan metrics for operator review:
  * `eligible_count`
  * `orphan_count`
  * `blocked_count`
  * `already_missing_count`
  * `error_count`
  * `duration_ms`

---

## 6. Batch Cleanup & Bounded Execution

* The cleanup worker never scans or purges the entire bucket in an unbounded request.
* Queries are paginated and bounded with a configurable `limit` (default: 50, maximum: 200).
* Ordered by `retention_expires_at ASC` utilizing the partial index `idx_recordings_retention_scan`.
* Bounded batches ensure execution completes well within Edge Function and client timeout limits (< 15 seconds).

---

## 7. Tenant Isolation

* Object storage paths enforce strict multi-tenant structuring:
  `clinics/{clinic_id}/consultations/{consultation_id}/{recording_id}.m4a`
* Storage RLS policies enforce `(storage.foldername(name))[2] = get_auth_clinic_id()`.
* The cleanup evaluator parses `clinic_id` from every object path and skips any records outside the target tenant boundary.
* A cleanup invocation for Clinic A can never evaluate or purge objects belonging to Clinic B.

---

## 8. Concurrency Protection & Race Prevention

To prevent deletion of audio being actively transcribed or structured by a concurrent worker, an atomic check-and-set claim is enforced at the database layer before storage operations:

```sql
UPDATE public.recordings r
SET
    deletion_status = 'pending_deletion',
    deletion_attempted_at = now()
WHERE r.id = p_recording_id
  AND r.deletion_status = 'active'
  AND r.legal_hold = false
  AND r.processing_status NOT IN ('pending', 'queued', 'transcribing', 'structuring')
  AND (r.lease_expires_at IS NULL OR r.lease_expires_at < now())
  AND r.retention_expires_at IS NOT NULL
  AND r.retention_expires_at <= now()
RETURNING r.id, r.storage_path;
```

If an AI worker begins processing mid-flight, `processing_status` becomes `'transcribing'`, causing the `WHERE` clause to match 0 rows. The cleanup worker receives an empty result and immediately aborts deletion.

---

## 9. Failure Behavior & Reversion

* **Storage Delete 404**: Reconciled as a database orphan. Status updated to `deleted` with `deletion_error_code = 'STORAGE_OBJECT_NOT_FOUND'`.
* **Storage Delete Timeout / 5xx**: Reverts `deletion_status` to `'active'` via `revert_recording_deletion()` and logs error code `STORAGE_DELETE_FAILED`.
* **Fail-Closed Principle**: If database connection, policy resolution, or storage availability fails, the system aborts without deletion.

---

## 10. Observability Metrics (Block 1F Integration)

Low-cardinality Prometheus-compatible telemetry tracked:
* `storage_cleanup_runs_total{mode}`
* `storage_cleanup_candidates_total{mode}`
* `storage_cleanup_deleted_total{category}`
* `storage_cleanup_failed_total{category}`
* `storage_orphans_detected_total{mode}`
* `storage_orphans_deleted_total`
* `storage_cleanup_duration_ms`

---

## 11. Audit Events

Append-only, immutable audit events generated in `public.audit_logs`:
* `RETENTION_DELETE`: Raw audio purged following retention horizon expiration.
* `ORPHAN_DELETE`: Unreferenced storage file purged.
* `MISSING_OBJECT_RECONCILIATION`: Database recording reconciled after 404 storage lookup.

---

## 12. Storage Growth Model (Based on Benchmark Measurements)

### Observed Synthetic Benchmark:
* Classification throughput: **83,752 records/sec** (100-batch) to **2,905,288 records/sec** (10,000-batch).
* Average audio object size: **1.2 MB** (16kHz mono AAC, 3-minute consultation).

### Projected Scaling Profile:
* **100 Consultations / Day**: 120 MB / day → ~3.6 GB / month.
* **1,000 Consultations / Day**: 1.2 GB / day → ~36 GB / month.
* **10,000 Consultations / Day**: 12 GB / day → ~360 GB / month.
* With a standard 7-day raw audio retention policy, steady-state storage overhead is capped at **7 × daily volume** (~25.2 GB for 1,000 consults/day), preventing unbounded storage growth.

---

## 13. Production Deployment Prerequisites

Before deploying automated retention purging to Production (`dyfrknwejqwilstcoytt`):
1. **Legal Counsel Formal Sign-Off (RLR-02)**: Formal determination of statutory raw audio retention horizon (e.g. 7 days vs 30 days vs indefinite).
2. **Production Migration**: Apply `20260927000005_block1g_storage_lifecycle_retention.sql` via Supabase migration CLI.
3. **Dry-Run Validation on Production**: Execute initial run with `dry_run=true` to verify 0 unexpected candidates.
4. **pg_cron / Scheduled Edge Function Setup**: Configure cron trigger for off-peak hours (e.g., 02:00 UTC daily).
