# ADR-0001: PostgreSQL as the Authoritative Source of Truth

```
Status   : ACCEPTED
Date     : 2026-09-28
Deciders : Lead Architect, Database Engineer, Security & Compliance Lead
Context  : Medico-OPD Block 0 Architecture
```

---

## 1. Context & Problem Statement
Medico-OPD is an outpatient clinical documentation assistant operating in the Indian healthcare ecosystem, subject to the National Medical Commission (NMC) regulations, the Digital Personal Data Protection (DPDP) Act 2023, and CERT-In directions. The system incorporates multiple distributed state-bearing components, including Redis, Apache Kafka, S3-compatible Object Storage, and worker pools.

If state management is fragmented across caches, queues, and message brokers, the system risks data drift, orphaned medical records, irreproducible patient audit trails, and catastrophic data loss during cluster failovers. We must establish a single authoritative source of truth.

---

## 2. Decision
We decide that **PostgreSQL is the sole, authoritative source of truth** for all business, clinical, identity, and compliance state across Medico-OPD:

1. **Authoritative Clinical State**: All patient demographics, consultations, legal consent grants, recording metadata, raw transcripts, structured AI drafts, and final doctor attestations must permanently reside in PostgreSQL.
2. **Crash & Disaster Recovery Standard**: In the event of a catastrophic failure, split-brain condition, or total cluster loss of Redis, Kafka, or worker containers, the complete operational state of the platform must be fully reconstructible from PostgreSQL write-ahead logs (WAL) and database snapshots.
3. **Data Protection & Row-Level Security (RLS)**: PostgreSQL enforces multi-tenant clinic isolation, database-level consent checks (`trg_check_recording_consent`), and finalized draft immutability (`trg_lock_finalized_ai_draft`) at the relational layer.

---

## 3. What is NOT Authoritative
* **Kafka**: Kafka is an asynchronous event backbone. Offset position or broker state does not dictate clinical reality.
* **Redis**: Redis is an ephemeral cache and fast lock provider. If Redis is flushed or destroyed, no persistent clinical data is lost.
* **Object Storage**: S3 stores encrypted binary blobs. The canonical record of an audio file’s ownership, duration, consent binding, and checksum resides in PostgreSQL `recordings`.
* **Worker Memory**: Any in-memory state inside STT or LLM containers is non-authoritative and safely discardable.

---

## 4. Consequences

### Positive Consequences
* **Deterministic Auditability**: Regulators and clinical auditors can verify patient care history directly from an ACID-compliant, relational ledger.
* **Simplified Multi-Tenancy**: Tenant isolation is guaranteed via PostgreSQL Row-Level Security (RLS) and column-level grants rather than distributed application filters.
* **Proven Durability**: Point-in-Time Recovery (PITR) and synchronous replication provide sub-second Recovery Point Objectives (RPO).

### Negative / Trade-Off Consequences
* **Write Scaling Overhead**: High-throughput events (e.g. audit logs, status state transitions) generate write load on PostgreSQL primary, requiring indexing discipline, connection pooling, and future time-series partitioning.
