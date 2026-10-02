# ADR-0005: Decoupled, Horizontally Scalable STT and LLM Worker Architecture

```
Status   : ACCEPTED
Date     : 2026-09-28
Deciders : Lead Architect, ML Platform Lead, Infrastructure Lead
Context  : Medico-OPD Block 0 Architecture
```

---

## 1. Context & Problem Statement
Early-stage healthcare architectures frequently couple audio transcription and LLM inference into a single script, monolithic service, or single high-end GPU instance ("one Whisper server" / "one LLM endpoint").

Such designs suffer from severe structural defects:
1. **Resource Mismatch**: Speech-to-Text (`faster-whisper`) is primarily compute and memory-bandwidth bound on FP16 audio decoding. LLM inference (`vLLM`) is VRAM-capacity and KV-cache memory bound. Coupling them forces inefficient GPU resource allocation.
2. **Brittle Scaling**: A surge in long audio files blocks LLM inference for short notes.
3. **Single Point of Failure**: Crashing the monolith halts both transcription and note generation across the entire platform.

---

## 2. Decision
We decide to decouple the processing pipeline into **two independent, horizontally scalable, stateless worker pools**:

```
[ Kafka: audio.uploaded ]
           |
           v
+-----------------------------+
|    STT Worker Pool          |  Scale horizontally with audio queue depth
|    (faster-whisper)         |  (e.g., 2 to 6 NVIDIA A10G / T4 instances)
+-----------------------------+
           |
           v
[ Kafka: transcription.completed ]
           |
           v
+-----------------------------+
|    AI Worker Pool           |  Scale horizontally with inference queue depth
|    (vLLM continuous batch)  |  (e.g., 1 to 4 NVIDIA L40S / A10G instances)
+-----------------------------+
```

1. **Independent Worker Pools**:
   * **STT Pool (`faster-whisper`)**: Stateless Python workers running CTranslate2 engine with `large-v3-turbo` model. Workers pull jobs from Kafka, stream audio from S3, write transcripts to PostgreSQL, and emit completion events.
   * **AI Pool (`vLLM`)**: Stateless workers running continuous batching with PagedAttention serving open-weights clinical models. Workers pull transcripts from Kafka, apply XML prompt injection boundaries, extract structured JSON clinical notes, and write drafts to PostgreSQL.
2. **Horizontal Scaling Mechanism**:
   * Workers run as containerized pods or serverless GPU workers (e.g. RunPod, Kubernetes HPA, AWS ECS/EKS).
   * Scaling triggers are driven by Kafka consumer group lag and average queue wait time.
3. **Zero In-Worker State**:
   * Workers hold no local disk persistence. Any worker instance can be terminated, preempted (spot instances), or restarted without data loss.

---

## 3. Consequences

### Positive Consequences
* **Optimal GPU Economics**: Allows right-sizing GPU hardware independently: STT on cost-effective T4/A10G GPUs; LLM inference on high-memory L40S/A100 instances.
* **Failure Isolation**: A crash in an STT worker does not disrupt LLM inference or doctor review screens.
* **Elastic Surge Handling**: Capacity scales dynamically from 2 GPUs during quiet hours up to 8+ GPUs during peak clinic rush hours.

### Negative / Trade-Off Consequences
* **Multiple Container Deployments**: Requires maintaining separate Docker container images, CUDA dependencies, and healthcheck endpoints. (Implementation deferred to Block 4).
