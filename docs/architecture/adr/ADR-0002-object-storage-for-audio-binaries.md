# ADR-0002: Object Storage Abstraction for Audio Binaries

```
Status   : ACCEPTED
Date     : 2026-09-28
Deciders : Lead Architect, Storage Engineer, Security Lead
Context  : Medico-OPD Block 0 Architecture
```

---

## 1. Context & Problem Statement
Medico-OPD captures ambient doctor-patient consultations to facilitate automated clinical documentation. At 500 doctors generating 6,000 to 15,750 consultations daily, raw audio volume ranges from 7.0 GB to 11.1 GB per day (up to 4 TB annually unpurged).

Storing large binary audio objects directly inside PostgreSQL (e.g., using `BYTEA` or PostgreSQL Large Objects) inflates database table bloat, degrades buffer cache hit ratios, causes severe Write-Ahead Log (WAL) amplification, and drastically extends backup and point-in-time restore windows.

---

## 2. Decision
We decide to store all raw consultation audio, preprocessed audio chunks, and exported PDF artifacts **exclusively in private S3-compatible Object Storage**:

1. **Object Storage Target**: A private S3-compatible bucket named `consultation-recordings` with public access disabled.
2. **Canonical Path Hierarchy**:
   `clinics/{clinic_id}/consultations/{consultation_id}/{recording_id}.m4a`
   Path segment index `[2]` allows storage Row-Level Security policies to enforce multi-tenant clinic isolation.
3. **Database Separation of Concerns**:
   PostgreSQL stores only metadata references:
   * `storage_path` (TEXT)
   * `checksum_sha256` (TEXT)
   * `duration_seconds` (INTEGER)
   * `encryption_key_ref` (TEXT)
   * `deleted_at` / `retention_expires_at` (TIMESTAMPTZ)
4. **Direct Client Upload via Presigned Multipart URLs**:
   Mobile clients upload audio binaries directly to Object Storage using presigned URLs or chunked multipart upload, completely bypassing the API application servers and eliminating server connection exhaustion.
5. **Server-Side & Envelope Encryption**:
   Object storage enforces AES-256 server-side encryption at rest (AWS SSE-S3 / MinIO KMS).

---

## 3. Consequences

### Positive Consequences
* **Database Cache Protection**: PostgreSQL buffer cache and shared buffers are reserved for high-speed indexing and relational queries rather than clogged with audio bytes.
* **Cost Efficiency**: Cloud object storage is ~10x cheaper per gigabyte than high-IOPS NVMe database volumes.
* **Storage Minimization Enforcement**: Storage objects can be purged seamlessly on Day 8 via automated retention lifecycle policies without requiring vacuuming or table defragmentation in PostgreSQL.

### Negative / Trade-Off Consequences
* **Two-Phase Commit Coordination**: Requires careful application handling to prevent orphaned audio files if an upload succeeds but the client fails to register the database row (mitigated by Block 1G orphan cleanup workers).
