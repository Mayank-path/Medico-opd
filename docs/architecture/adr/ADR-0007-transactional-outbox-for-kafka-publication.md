# ADR-0007: Transactional Outbox Pattern for Asynchronous Kafka Publication

```
Status   : ACCEPTED (ARCHITECTURAL DECISION ONLY — IMPLEMENTATION IN FUTURE BLOCK)
Date     : 2026-09-28
Deciders : Lead Architect, Database Engineer, Data Infrastructure Lead
Context  : Medico-OPD Block 0 Architecture
```

---

## 1. Context & Problem Statement
In Medico-OPD, business operations (such as registering a recording, granting consent, or finalizing a clinical draft) occur within PostgreSQL transactions. Downstream asynchronous pipelines (speech-to-text transcription via `faster-whisper` and structured note generation via `vLLM`) are triggered by publishing events to Apache Kafka.

A naive dual-write architecture (where the application server writes to PostgreSQL and then immediately publishes to Kafka) suffers from a fundamental distributed systems failure mode:
1. **The Dual-Write Failure Mode**: The database transaction commits successfully, but the network connection to Kafka fails, the Kafka broker times out, or the application process crashes before publishing the event.
2. **Outcome**: The clinical record exists in PostgreSQL, but no Kafka event is emitted. The consultation audio is never transcribed, leaving the doctor waiting indefinitely for an AI draft that will never arrive.
3. **Alternative Dual-Write Failure Mode**: If the application publishes to Kafka first, and then the database commit fails (e.g. serialization failure, constraint violation), Kafka consumers process a ghost consultation that was never committed to PostgreSQL.

---

## 2. Decision
We decide that **event publication to Apache Kafka must eventually use the Transactional Outbox Pattern**, with PostgreSQL remaining the single authoritative source of truth.

> [!IMPORTANT]
> **Block 0 Boundary Notice**:
> This is an **architectural decision and contract definition only**. The outbox table, outbox publisher, and Kafka brokers are **NOT implemented in Block 0**. Implementation belongs to the designated future backend/event backbone block.

### 2.1 Conceptual Architecture Flow

```
   Business Transaction Initiated
                 │
                 ▼
+----------------------------------+
|   PostgreSQL Transaction Block   |
|   ┌────────────────────────────┐ |
|   │ 1. Clinical State Change   │ |
|   │    (recordings, drafts)    │ |
|   │ 2. Insert Outbox Event     │ |
|   │    (outbox_events table)   │ |
|   └────────────────────────────┘ |
|                 │                |
|                 ▼                |
|        Atomic DB Commit          |
+----------------------------------+
                 │
                 ▼
+----------------------------------+
|         Outbox Publisher         |
|   (Debezium CDC or Polling)      |
+----------------------------------+
                 │
                 ▼
+----------------------------------+
|       Apache Kafka Cluster       |
|    (audio.uploaded, etc.)        |
+----------------------------------+
                 │
                 ▼
+----------------------------------+
|       Downstream Consumers       |
|      (STT & AI Worker Pools)     |
+----------------------------------+
```

### 2.2 Atomic Guarantees & Failure Handling

#### Scenario A: PostgreSQL Commit Succeeds, Outbox Publisher Fails to Publish to Kafka
* **Mechanism**: The clinical state change and the outbox event row were committed together atomically inside PostgreSQL.
* **Resilience**: The event is permanently preserved in the PostgreSQL `outbox_events` table with `status = 'pending'`.
* **Recovery**: When the Outbox Publisher recovers or the Kafka cluster becomes reachable again, the publisher replays unacknowledged outbox events from PostgreSQL. **Zero events are lost.**

#### Scenario B: PostgreSQL Transaction Fails or Rolls Back
* **Mechanism**: If any constraint, foreign key, or trigger check fails (e.g. `trg_check_recording_consent` blocks an unconsented recording), the entire transaction rolls back.
* **Resilience**: The outbox event row is rolled back with the transaction. No message is ever published to Kafka for an uncommitted transaction. **Zero phantom jobs are processed.**

#### Scenario C: Outbox Publisher Publishes to Kafka Twice (At-Least-Once Delivery)
* **Mechanism**: Network hiccup during Kafka broker ACK causes the publisher to retry sending the outbox message.
* **Resilience**: Downstream Kafka consumers (`faster-whisper` and `vLLM`) enforce idempotency via unique database constraints (`idx_transcripts_recording_id_unique` and optimistic locking `revision` on `ai_drafts`). Duplicate events are safely ignored.

---

## 3. Consequences

### Positive Consequences
* **Guaranteed Event Delivery**: Every committed clinical change requiring background processing is guaranteed to produce an event.
* **Decoupled Availability**: The user-facing API can accept consultations even during a temporary Kafka cluster outage; events accumulate safely in PostgreSQL and publish once Kafka recovers.
* **Preserves PostgreSQL Source of Truth**: The relational database remains the sole authority for event generation and state recovery.

### Negative / Trade-Off Consequences
* **Outbox Cleanup Overhead**: Requires a background sweeper or Change Data Capture (CDC) engine (e.g., Debezium via PostgreSQL logical replication) to prune published events from `outbox_events` after retention windows. (Implementation deferred to future block).
