# ADR-0003: Redis Non-Authoritative Role & Graceful Degradation

```
Status   : ACCEPTED
Date     : 2026-09-28
Deciders : Lead Architect, Infrastructure Lead, Backend Platform Lead
Context  : Medico-OPD Block 0 Architecture
```

---

## 1. Context & Problem Statement
High-concurrency mobile clinic applications require low-latency rate limiting, fast distributed locking (e.g. preventing two devices from editing the same draft simultaneously), and short-lived caching of doctor dashboards. Redis is an industry-standard in-memory datastore suited for this sub-millisecond coordination.

However, treating Redis as a persistent store or making business correctness dependent on Redis uptime introduces split-brain risks, memory exhaustion crashes (OOM), and complex clustering maintenance.

---

## 2. Decision
We decide that **Redis is strictly non-authoritative** and operates solely as an ephemeral caching, rate-limiting, and coordination layer:

1. **Permitted Redis Workloads**:
   * *Rate Limiting*: Sliding window counters for API and Edge Function invocations.
   * *Distributed Locks*: Ephemeral leases for concurrent draft edits or worker task locks (with strict short TTLs < 30 seconds).
   * *Read Caching*: Temporary caching of active doctor profiles and clinic metadata.
   * *Token Blacklisting*: Short-lived revocation markers for logged-out JWTs.
2. **Prohibited Redis Uses**:
   * Never store permanent consultation state, patient records, consent records, or financial data in Redis.
   * Never rely on Redis persistence mechanisms (RDB/AOF) as a primary backup.
3. **Graceful Degradation Guarantee**:
   The system must remain fully operational and correct if Redis crashes or is partitioned:
   * *Rate Limiting*: Fails open (allows requests with warning logged).
   * *Distributed Locking*: Falls back to PostgreSQL row-level locks (`SELECT FOR UPDATE`).
   * *Caching*: Falls back to direct read queries on PostgreSQL replicas.

---

## 3. Consequences

### Positive Consequences
* **Zero Clinical Downtime on Cache Outage**: An operational failure in the Redis layer will not prevent doctors from writing prescriptions or recording consultations.
* **Simplified Operations**: Redis instances can be restarted, upgraded, or flushed without requiring complex point-in-time state recovery.
* **Low Memory Footprint**: Because keys carry aggressive TTLs, memory consumption remains under 200 MB even under stress workloads.

### Negative / Trade-Off Consequences
* **PostgreSQL Spikes on Cache Outage**: A complete Redis outage creates a temporary increase in read IOPS on PostgreSQL read replicas.
