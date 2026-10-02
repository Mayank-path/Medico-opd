# ADR-0004: Apache Kafka as Asynchronous Event Streaming Backbone

```
Status   : ACCEPTED
Date     : 2026-09-28
Deciders : Lead Architect, Data Infrastructure Lead, ML Platform Lead
Context  : Medico-OPD Block 0 Architecture
```

---

## 1. Context & Problem Statement
The clinical documentation workflow spans multiple stages: audio upload, speech-to-text decoding, PII redaction, generative AI note structuring, and doctor notification. STT takes 15–30 seconds; LLM inference takes 8–15 seconds.

If these processing stages are linked synchronously over HTTP chains:
1. Mobile devices must maintain active HTTP connections for 30–60 seconds, which frequently break on mobile networks.
2. API servers exhaust connection thread pools waiting on external AI model inference.
3. A failure in the STT or LLM container requires re-running the entire sequence or loses the job completely.

---

## 2. Decision
We decide to adopt **Apache Kafka as the durable, asynchronous event streaming backbone** to decouple interactive API operations from background AI worker pools:

1. **Decoupled Asynchronous Processing**:
   * API servers acknowledge audio registration immediately (`HTTP 202 Accepted`) and publish an `audio.uploaded` event to Kafka.
   * Mobile clients release network sockets and poll or listen via Server-Sent Events (SSE) / WebSockets for progress updates.
2. **Event Backbone Role**:
   * Kafka provides an append-only, partitioned, replicated commit log.
   * Topics are partitioned by `clinic_id` hash, guaranteeing sequential event delivery per clinic while allowing horizontal worker scaling across partitions.
3. **Transactional Outbox / Idempotent Producers**:
   * Event publication is tied to database transaction state via the Transactional Outbox pattern or atomic job status transitions in PostgreSQL.
   * Kafka producers configure `acks = all` and `enable.idempotence = true` to prevent message loss or duplication during broker leader failovers.
4. **Independent Consumer Groups**:
   * `stt-workers` consume from `audio.uploaded` and produce to `transcription.completed`.
   * `ai-workers` consume from `transcription.completed` and produce to `ai.draft.created`.
   * Additional consumer groups (e.g. real-time telemetry, analytics) can subscribe without affecting primary inference latency.

---

## 3. What Kafka is NOT
* Kafka is **not** a database or clinical source of truth.
* Kafka messages are transient processing signals.
* Retention is bounded (7 days) for operational replayability.

---

## 4. Consequences

### Positive Consequences
* **Elastic Shock Absorber**: Traffic surges during peak morning OPD hours buffer in Kafka queues without crashing API servers or dropping patient records.
* **Independent Scalability**: STT GPU worker pools and LLM GPU worker pools can scale independently based on their respective queue lags.
* **Replayability & Resilience**: If an AI model deployment contains a bug, events can be replayed from any offset within the 7-day retention horizon.

### Negative / Trade-Off Consequences
* **Operational Complexity**: Requires managing a Kafka cluster (or managed Confluent/Strimzi/MSK instance), monitoring consumer group lag, and handling dead-letter queues. (Implementation deferred to Block 3).
