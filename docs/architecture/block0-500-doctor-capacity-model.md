# MEDICO-OPD — 500-DOCTOR FORMAL CAPACITY MODEL

## Block 0: Workload Projections, Resource Modeling & Infrastructure Sizing

```
Document Version : 1.0.0
Status           : APPROVED (BLOCK 0 BASELINE)
Target Capacity  : 500 Registered Outpatient Doctors
Workload Baseline: Multi-Scenario Engineering Sizing (Normal / Busy / Stress)
Classification   : Technical & Infrastructure Specification
```

---

## 1. Engineering Assumptions & Classification Taxonomy

To ensure complete transparency and prevent unverified assumptions from being mistaken for verified production benchmarks, all metrics in this capacity model are strictly categorized into one of four mutually exclusive designations:

```
[ ASSUMPTION CLASSIFICATION TAXONOMY ]
```

* **`[MEASURED]`**: Empirical values measured directly from the existing repository codebase, database schemas, or executed automated test benchmarks.
* **`[ESTIMATED]`**: Sizing estimates derived by applying established mathematical formulas, physics of networking, or standard audio codecs to explicit baseline assumptions.
* **`[ASSUMED]`**: Initial engineering assumptions based on typical Indian private outpatient clinic operating patterns, consultation cadences, and specialist work schedules.
* **`[TARGET]`**: Product performance Service Level Objectives (SLOs) and engineering latency bounds required for acceptable clinical user experience.

---

### 1.1 Assumptions Table by Taxonomy

| Metric Parameter | Designation | Baseline Value | Source / Justification |
| :--- | :---: | :---: | :--- |
| **Total Registered Doctors** | `[ASSUMED]` | 500 doctors | Project initial target capacity. |
| **Daily Active Ratio** | `[ASSUMED]` | 60% – 70% | Fraction of registered doctors holding OPD on a given weekday. |
| **Peak Concurrency Ratio** | `[ASSUMED]` | 20% – 30% | Fraction of active doctors simultaneously seeing patients during peak rush hours (10 AM–1 PM / 5 PM–8 PM). |
| **Consultations / Doctor / Day** | `[ASSUMED]` | 20 – 45 consults | Range across standard single-specialist to busy general OPD clinics in India. |
| **Peak Window Duration** | `[ASSUMED]` | 3 hours (180 min) | Indian OPD morning rush window where ~50% of daily volume concentrates. |
| **Consultation Duration** | `[ASSUMED]` | 4.0 – 7.0 minutes | Average duration a patient occupies the consultation room. |
| **Active Audio Duration** | `[ASSUMED]` | 3.0 – 5.0 minutes | Portion of consultation involving active doctor-patient verbal dialogue. |
| **Audio Format & Bitrate** | `[MEASURED]` | AAC-LC / 16kHz mono / 32 kbps | Configured in `RecordingService` (`RecordConfig(bitRate: 32000, sampleRate: 16000)`). |
| **Audio File Size / Minute** | `[MEASURED]` | 240 KB / minute (4 KB/s) | Mathematical output of 32,000 bits/sec / 8 bits/byte. |
| **STT Model & Real-Time Factor (RTF)** | `[ESTIMATED]` | RTF 0.08 (faster-whisper large-v3-turbo FP16) | Standard performance on NVIDIA A10G / T4 GPU; 5 min audio transcribes in ~24s. |
| **LLM Token Input / Output** | `[ESTIMATED]` | 2,500 input / 600 output tokens | Clinical transcript (~1,000 tok) + system prompt (~1,200 tok) + patient context (~300 tok). |
| **LLM Inference Latency** | `[ESTIMATED]` | 8 – 12 seconds | vLLM continuous batching on modern GPU (Time-To-First-Token ~300ms + 60 tok/s generation). |
| **Interactive API Latency Target** | `[TARGET]` | p95 < 300 ms, p99 < 500 ms | Standard CRUD operations (patients, consultations, draft edits). |
| **End-to-End AI Draft Ready Target** | `[TARGET]` | p95 < 45 seconds | Time from doctor tapping "Stop Recording" to structured draft rendering on device. |

---

## 2. Multi-Scenario Capacity Model

To prevent designing for a single brittle operating point, three explicit operational scenarios are modeled:
1. **Normal**: Standard daily outpatient clinic volume with typical pacing.
2. **Busy**: High-volume clinic day (e.g. Monday morning rush, post-holiday backlog).
3. **Stress**: Extreme operational surge (e.g. seasonal dengue/flu epidemic, multi-doctor OPD camp).

### 2.1 Capacity Sizing Table

| Metric | Normal Scenario | Busy Scenario | Stress Scenario | Formula / Derivation Method |
| :--- | :---: | :---: | :---: | :--- |
| **Registered Doctors** | 500 `[ASSUMED]` | 500 `[ASSUMED]` | 500 `[ASSUMED]` | Target doctor population. |
| **Active Doctors / Day** | 300 `[ASSUMED]` | 325 `[ASSUMED]` | 350 `[ASSUMED]` | $500 \times [60\%, 65\%, 70\%]$ |
| **Peak Concurrent Doctors** | 60 `[ASSUMED]` | 82 `[ASSUMED]` | 105 `[ASSUMED]` | $\text{Active Doctors} \times [20\%, 25.2\%, 30\%]$ |
| **Consultations / Doctor / Day** | 20 `[ASSUMED]` | 30 `[ASSUMED]` | 45 `[ASSUMED]` | Indian clinical practice assumptions. |
| **Total Consultations / Day** | **6,000** `[ESTIMATED]` | **9,750** `[ESTIMATED]` | **15,750** `[ESTIMATED]` | $\text{Active Doctors} \times \text{Consults/Doctor/Day}$ |
| **Average Consultation Time** | 7.0 min `[ASSUMED]` | 5.5 min `[ASSUMED]` | 4.0 min `[ASSUMED]` | Room turnaround duration per patient. |
| **Average Audio Time / Consult** | 5.0 min `[ASSUMED]` | 4.0 min `[ASSUMED]` | 3.0 min `[ASSUMED]` | Recorded doctor-patient conversational duration. |
| **Peak Window Volume (3 hrs)** | 3,000 (50%) | 4,875 (50%) | 8,662 (55%) | Fraction of daily consults during 3 peak hours. |
| **Peak Consultation Starts / Min** | **16.7 / min** `[ESTIMATED]` | **27.1 / min** `[ESTIMATED]` | **48.1 / min** `[ESTIMATED]` | $\text{Peak Window Consults} \div 180\text{ min}$ |
| **Peak Consultation Starts / Sec** | **0.28 / s** `[ESTIMATED]` | **0.45 / s** `[ESTIMATED]` | **0.80 / s** `[ESTIMATED]` | $\text{Starts/min} \div 60\text{ s}$ |
| **Peak Concurrent Recordings** | **43** `[ESTIMATED]` | **60** `[ESTIMATED]` | **79** `[ESTIMATED]` | $\text{Peak Doctors} \times (\text{Audio Duration} \div \text{Consult Duration})$ |
| **Audio Minutes / Day** | **30,000 min** `[ESTIMATED]` | **39,000 min** `[ESTIMATED]` | **47,250 min** `[ESTIMATED]` | $\text{Total Consults} \times \text{Audio Duration}$ (500 to 787.5 hrs/day) |
| **Daily Raw Audio Upload Size** | **7.20 GB (6.71 GiB)** `[ESTIMATED]` | **9.36 GB (8.72 GiB)** `[ESTIMATED]` | **11.34 GB (10.56 GiB)** `[ESTIMATED]` | $\text{Audio Minutes} \times 240,000\text{ bytes} \div 10^9\text{ (GB)}$ |
| **STT Jobs / Day** | **6,000** `[ESTIMATED]` | **9,750** `[ESTIMATED]` | **15,750** `[ESTIMATED]` | 1 transcription job per consented recording. |
| **STT Job Duration (faster-whisper)**| 24.0 s `[ESTIMATED]` | 19.2 s `[ESTIMATED]` | 14.4 s `[ESTIMATED]` | $\text{Audio Duration (s)} \times \text{RTF } 0.08$ |
| **Peak STT Processing Concurrency** | **6.7 (~7)** `[ESTIMATED]` | **8.6 (~9)** `[ESTIMATED]` | **11.5 (~12)** `[ESTIMATED]`| Little's Law: $L = \lambda \times W = \text{Peak Starts/s} \times \text{Job Duration}$ |
| **AI LLM Requests / Day** | **6,900** `[ESTIMATED]` | **11,213** `[ESTIMATED]` | **18,113** `[ESTIMATED]` | $\text{Consults} \times 1.15$ (includes 15% regeneration/edit rate). |
| **Peak AI Inference Concurrency** | **3.2 (~4)** `[ESTIMATED]` | **5.2 (~6)** `[ESTIMATED]` | **9.2 (~10)** `[ESTIMATED]` | Little's Law: $L = \lambda \times W = (\text{Starts/s} \times 1.15) \times 10\text{ s}$ |

---

## 3. Detailed Audio Capacity & Storage Lifecycle Model

### 3.1 Audio Codec Selection & Justification
* **Selected Format**: **AAC-LC inside M4A container (16 kHz, Mono, 32 kbps)**
* **Technical Justification**:
  1. *Acoustic Clarity*: 32 kbps AAC-LC preserves speech frequencies up to 8 kHz, comfortably capturing Indian medical terminology, drug brand names, and phonetic code-switching without muffled distortion.
  2. *Bandwidth Efficiency*: Generates exactly **4.0 KB/sec** (240 KB per minute, 14.4 MB per hour). Compared to uncompressed 16-bit 16kHz PCM WAV (32 KB/sec = 1.92 MB/min), AAC delivers an **87.5% bandwidth reduction**.
  3. *Native Hardware Support*: Android (`MediaCodec`) and iOS (`AVAudioRecorder`) encode AAC-LC in hardware with near-zero CPU overhead and minimal battery consumption.
  4. *Inference Direct Ingestion*: `faster-whisper` and FFmpeg decode AAC directly without intermediate server-side transcoding.

### 3.2 Storage Classification by Artifact Tier

To ensure total transparency, storage calculations are decoupled into four mutually exclusive operational tiers:

1. **TIER 1: RAW AUDIO OBJECTS (S3 Storage)**:
   * Encrypted `.m4a` file captured on mobile device and uploaded directly to S3.
   * Encoding: 16 kHz Mono AAC-LC @ 32,000 bits/sec (4,000 bytes/sec).
   * Exact file size per consultation:
     * *Normal* (5.0 min = 300 s): $300 \times 4,000\text{ bytes} = 1,200,000\text{ bytes} = 1.200\text{ MB} = 1.144\text{ MiB}$
     * *Busy* (4.0 min = 240 s): $240 \times 4,000\text{ bytes} = 960,000\text{ bytes} = 0.960\text{ MB} = 0.916\text{ MiB}$
     * *Stress* (3.0 min = 180 s): $180 \times 4,000\text{ bytes} = 720,000\text{ bytes} = 0.720\text{ MB} = 0.687\text{ MiB}$
   * Lifecycle Status: **Architecturally modeled for 7-day auto-purge**, subject to formal legal review (RLR-02); operational implementation belongs to the future storage retention block.
2. **TIER 2: PROCESSED AUDIO (In-Memory Intermediate)**:
   * In-memory decoded 16kHz FP32 tensors inside `faster-whisper` worker RAM/VRAM.
   * Persistence: **Zero disk persistence**. Wiped immediately upon transcription completion.
3. **TIER 3: TEMPORARY UPLOADS (In-Flight Mobile Disk)**:
   * Encrypted `.m4a` buffer inside local device sandbox (`path_provider`).
   * Peak disk footprint: 1 active consultation (~0.72 MB to 1.20 MB).
   * Persistence: Purged immediately from mobile disk upon server verification of SHA-256 integrity hash.
4. **TIER 4: PERMANENT RELATIONAL CLINICAL DATA (PostgreSQL Source of Truth)**:
   * Relational data retained for the mandatory 3-year statutory medical window under NMC Regulation 1.3.
   * Itemized footprint per consultation:
     * Base records (`consultations`, `consents`, `recordings` metadata): ~1.5 KB
     * Full raw transcript (`transcripts` table, TOAST-compressed): ~4.0 KB
     * Structured clinical note (`ai_drafts` table JSONB): ~8.0 KB
     * Audit logs (`audit_logs` table, ~5 immutable audit events @ 1 KB): ~5.0 KB
     * Index overhead (PostgreSQL B-Tree and GIN indexes, ~40% table size): ~7.4 KB
     * **Total relational footprint per consultation**: $\mathbf{25.9\text{ KB} \approx 26.0\text{ KB}}$ ($26,000\text{ bytes}$).

---

### 3.3 Audited Storage Calculations (Exact Formulas)

> [!NOTE]
> All storage calculations below explicitly report both **Decimal Units** (SI: $1\text{ GB} = 10^9\text{ bytes}$, $1\text{ TB} = 10^{12}\text{ bytes}$) and **Binary Units** (IEC: $1\text{ GiB} = 2^{30}\text{ bytes} = 1,073,741,824\text{ bytes}$, $1\text{ TiB} = 2^{40}\text{ bytes}$).
> The 7-day raw audio auto-purge policy is **architecturally modeled** and **subject to legal determination (RLR-02)**. Implementation belongs to a future block.

#### A. Raw Audio Storage Model (S3 Storage)

| Storage Metric | Normal Scenario | Busy Scenario | Stress Scenario | Exact Mathematical Formula |
| :--- | :---: | :---: | :---: | :--- |
| **Daily Raw Audio Uploaded** | **7.200 GB**<br>*(6.705 GiB)* | **9.360 GB**<br>*(8.717 GiB)* | **11.340 GB**<br>*(10.561 GiB)* | $\text{Consults/day} \times (\text{Audio Seconds} \times 4,000\text{ bytes/s})$ |
| **7-Day Rolling Storage (Raw Audio)** | **50.400 GB**<br>*(46.939 GiB)* | **65.520 GB**<br>*(61.020 GiB)* | **79.380 GB**<br>*(73.928 GiB)* | $\text{Daily Raw Audio} \times 7\text{ days}$ |
| **30-Day Rolling Storage (With 7-Day Purge)** | **50.400 GB**<br>*(46.939 GiB)* | **65.520 GB**<br>*(61.020 GiB)* | **79.380 GB**<br>*(73.928 GiB)* | Active in S3 = $\text{Daily Raw Audio} \times 7\text{ days}$ (Days 8–30 purged) |
| *Purged Audio Volume (Days 8 to 30)* | *165.600 GB*<br>*(154.227 GiB)* | *215.280 GB*<br>*(200.495 GiB)* | *260.820 GB*<br>*(242.907 GiB)* | $\text{Daily Raw Audio} \times 23\text{ purged days}$ |
| **1-Year Rolling Storage (With 7-Day Purge)** | **50.400 GB**<br>*(46.939 GiB)* | **65.520 GB**<br>*(61.020 GiB)* | **79.380 GB**<br>*(73.928 GiB)* | Active in S3 = $\text{Daily Raw Audio} \times 7\text{ days}$ (Days 8–365 purged) |
| *Cumulative Purged Audio (358 Days)* | *2,577.600 GB*<br>*(2.401 TiB)* | *3,350.880 GB*<br>*(3.120 TiB)* | *4,059.720 GB*<br>*(3.778 TiB)* | $\text{Daily Raw Audio} \times 358\text{ purged days}$ |
| **1-Year Unpurged Baseline (Reference)** | **2,628.000 GB**<br>**(2.628 TB / 2.390 TiB)** | **3,416.400 GB**<br>**(3.416 TB / 3.107 TiB)** | **4,139.100 GB**<br>**(4.139 TB / 3.764 TiB)** | $\text{Daily Raw Audio} \times 365\text{ days}$ (If zero deletions occur) |

---

#### B. Permanent Relational Data Growth (PostgreSQL)

| Storage Metric | Normal Scenario | Busy Scenario | Stress Scenario | Exact Mathematical Formula |
| :--- | :---: | :---: | :---: | :--- |
| **Daily Relational Data & Indexes** | **0.156 GB**<br>*(148.8 MiB)* | **0.254 GB**<br>*(241.7 MiB)* | **0.410 GB**<br>*(390.5 MiB)* | $\text{Consults/day} \times 26,000\text{ bytes/consult}$ |
| **30-Day Cumulative Relational Data** | **4.680 GB**<br>*(4.359 GiB)* | **7.605 GB**<br>*(7.083 GiB)* | **12.285 GB**<br>*(11.441 GiB)* | $\text{Daily Relational} \times 30\text{ days}$ |
| **1-Year Cumulative Relational Data** | **56.940 GB**<br>*(53.030 GiB)* | **92.528 GB**<br>*(86.173 GiB)* | **149.468 GB**<br>*(139.203 GiB)* | $\text{Daily Relational} \times 365\text{ days}$ |

---

#### C. Total Active Platform Storage Footprint (S3 Active + PostgreSQL)

$$\text{Active Footprint} = \text{Active Rolling S3 Raw Audio (7 Days)} + \text{Cumulative PostgreSQL Relational Data}$$

| Time Horizon | Normal Scenario | Busy Scenario | Stress Scenario | Composition Breakdown |
| :--- | :---: | :---: | :---: | :--- |
| **Day 1** | **7.356 GB**<br>*(6.850 GiB)* | **9.614 GB**<br>*(8.953 GiB)* | **11.750 GB**<br>*(10.942 GiB)* | Day 1 Raw Audio + Day 1 Relational Data |
| **Day 30 (With Modeled 7-Day Purge)** | **55.080 GB**<br>*(51.298 GiB)* | **73.125 GB**<br>*(68.103 GiB)* | **91.665 GB**<br>*(85.369 GiB)* | 50.40 GB S3 Audio (7d) + 4.68 GB Postgres Data (30d) |
| **Day 365 (With Modeled 7-Day Purge)**| **107.340 GB**<br>*(99.969 GiB)* | **158.048 GB**<br>*(147.193 GiB)* | **228.848 GB**<br>*(213.131 GiB)* | 50.40 GB S3 Audio (7d) + 56.94 GB Postgres Data (365d) |
| **Day 365 (Unpurged Baseline)** | **2,684.940 GB**<br>**(2.685 TB / 2.442 TiB)** | **3,508.928 GB**<br>**(3.509 TB / 3.191 TiB)** | **4,288.568 GB**<br>**(4.289 TB / 3.900 TiB)** | 365d Unpurged S3 Audio + 365d Postgres Data |

> [!IMPORTANT]
> **Storage Minimization Benefit**: The architecturally modeled 7-day auto-purge policy bounds active S3 audio storage to ~50 GB – ~79 GB indefinitely, preventing 2.6 TB – 4.1 TB of high-liability ambient biometric voice recordings from accumulating annually in cloud storage. Legal counsel determination (RLR-02) is tracked before operational activation in the designated future block.

### 3.4 Upload Network & Retry Amplification Model
* **Peak Concurrent Uploads**:
  * Upload duration for 1.2 MB file over typical 4G uplink (1.5 Mbps / ~180 KB/s) = **6.7 seconds**.
  * Little's Law for uploads: $\lambda = 0.28\text{ starts/s} \times 6.7\text{ s} \approx 1.88 \rightarrow$ **~2 to 3 concurrent active uploads** in Normal; **~5 concurrent uploads** in Stress.
* **Failed Upload Rate Assumption**: 4.0% of initial mobile uploads encounter temporary network drops or cell handovers.
* **Resumable Chunk Size**: 256 KB chunks. An interrupted upload loses at most 1 chunk (< 256 KB) of retransmission.
* **Retry Amplification Factor**: $1 + (0.04 \times 0.25) \approx \mathbf{1.01}$ (**1% total network bandwidth amplification**), proving that chunked resumable upload effectively neutralizes network flakiness.

---

## 4. Speech-to-Text (STT) Worker Capacity Model

### 4.1 Worker Model: `faster-whisper`
* **Target Architecture**: Stateless GPU worker pool consuming from Kafka topic `audio.uploaded`.
* **Model Class**: `faster-whisper` (CTranslate2 inference engine) using model `large-v3-turbo` with INT8/FP16 quantization.
* **Benchmark Status**: `[ESTIMATED]` based on standard CTranslate2 benchmarks on NVIDIA A10G (24GB VRAM) and T4 (16GB VRAM) GPUs.

### 4.2 Sizing Parameters

| Parameter | Value | Designation | Basis / Notes |
| :--- | :---: | :---: | :--- |
| **Acoustic Real-Time Factor (RTF)** | 0.08 | `[ESTIMATED]` | 60 seconds of audio processes in 4.8 seconds on NVIDIA A10G FP16. |
| **Average Audio Duration** | 5.0 min (300 s) | `[ASSUMED]` | Normal scenario baseline. |
| **Worker Processing Time / Job** | 24.0 s | `[ESTIMATED]` | $300\text{ s} \times 0.08 = 24.0\text{ s}$. |
| **Worker Concurrency per A10G GPU** | 4 parallel streams | `[ESTIMATED]` | CTranslate2 multi-stream execution within 24GB VRAM. |
| **Throughput per GPU Worker Pod** | 10.0 jobs / min | `[ESTIMATED]` | $(4\text{ streams} \times 60\text{ s}) \div 24.0\text{ s} = 10\text{ jobs/min}$. |
| **Peak Arrival Rate (Normal)** | 16.7 jobs / min | `[ESTIMATED]` | 0.28 jobs/sec during 3 peak hours. |
| **Peak Arrival Rate (Stress)** | 48.1 jobs / min | `[ESTIMATED]` | 0.80 jobs/sec during 3 peak hours. |
| **Required GPU Pods (Normal - Zero Queue)**| **1.67 -> 2 GPUs** | `[ESTIMATED]` | $16.7 \div 10 = 1.67$ A10G instances. |
| **Required GPU Pods (Stress - Zero Queue)**| **4.81 -> 5 GPUs** | `[ESTIMATED]` | $48.1 \div 10 = 4.81$ A10G instances. |
| **Recommended Provisioned Pool (3x Headroom)**| **3 GPUs (Normal)**<br>**6 GPUs (Stress)** | `[TARGET]` | Maintains queue wait time < 5s during sudden traffic bursts. |
| **Target Processing Latency (SLO)** | p95 < 30 seconds | `[TARGET]` | Total queue + transcription duration. |

---

## 5. Large Language Model (LLM) Inference Capacity Model

### 5.1 Worker Model: `vLLM`
* **Target Architecture**: Horizontally scalable `vLLM` inference cluster serving open-weights clinical models (e.g. Llama-3.3-70B-Instruct AWQ or Med42-8B / Mistral-Large) via OpenAI-compatible endpoints with continuous batching and PagedAttention.
* **Benchmark Status**: `[ESTIMATED]` based on standard vLLM v0.6+ throughput on NVIDIA A10G / L40S GPUs.

### 5.2 Token & Concurrency Sizing

| Parameter | Value | Designation | Basis / Notes |
| :--- | :---: | :---: | :--- |
| **Input Tokens per Consultation** | 2,500 tokens | `[ESTIMATED]` | Transcript (~1,000) + System Prompt/Few-shot (~1,200) + Patient Context (~300). |
| **Output Tokens per Consultation** | 600 tokens | `[ESTIMATED]` | Structured clinical JSON: HPI, Exam, Provisional Dx, Rx array, Follow-up. |
| **Total Tokens per Consultation** | 3,100 tokens | `[ESTIMATED]` | Input + Output. |
| **LLM Calls per Consultation** | 1.15 | `[ASSUMED]` | 1 primary draft + 15% regeneration/clarification rate. |
| **Time-to-First-Token (TTFT)** | ~300 ms | `[ESTIMATED]` | vLLM prompt chunking with prefill acceleration. |
| **Inter-Token Latency (ITL)** | ~16 ms / token | `[ESTIMATED]` | Generation throughput of ~60 tokens/sec per stream. |
| **Total Inference Execution Time** | 10.0 seconds | `[ESTIMATED]` | $300\text{ ms} + (600\text{ tok} \times 16\text{ ms}) \approx 9.9\text{ s} \rightarrow 10\text{ s}$. |
| **Peak Arrival Rate (Normal)** | 0.32 req / s | `[ESTIMATED]` | $0.28 \times 1.15 = 0.32\text{ req/s}$ (19.2 req/min). |
| **Peak Arrival Rate (Stress)** | 0.92 req / s | `[ESTIMATED]` | $0.80 \times 1.15 = 0.92\text{ req/s}$ (55.2 req/min). |
| **Peak Concurrency (Normal)** | **3.2 -> 4 streams** | `[ESTIMATED]` | Little's Law: $0.32\text{ req/s} \times 10\text{ s} = 3.2$. |
| **Peak Concurrency (Stress)** | **9.2 -> 10 streams**| `[ESTIMATED]` | Little's Law: $0.92\text{ req/s} \times 10\text{ s} = 9.2$. |
| **Required GPU Instances (Normal)** | **1 x L40S or 2 x A10G**| `[ESTIMATED]` | Continuous batching effortlessly handles 8-16 concurrent streams. |
| **Required GPU Instances (Stress)** | **2 x L40S or 4 x A10G**| `[ESTIMATED]` | Absorbs 10-20 concurrent generation streams. |
| **Target Draft Generation Latency (SLO)**| p95 < 15 seconds | `[TARGET]` | Queue wait + inference execution. |

---

## 6. PostgreSQL Database Capacity & Workload Analysis

### 6.1 Workload Categorization

```
[ POSTGRESQL WORKLOAD CLASSIFICATION ]
```

1. **OLTP Workloads (Transactional Clinical CRUD)**:
   * Tables: `clinics`, `doctors`, `patients`, `consultations`, `consultation_consents`, `ai_drafts`.
   * Pattern: High-read, low-to-medium write. Heavy single-row lookups by primary key and clinic ID.
   * Transaction Sensitivity: **CRITICAL**. RLS enforcement, consistency triggers, and foreign key integrity.
2. **High-Write Workloads (State Machines & Logs)**:
   * Tables: `recordings`, `audit_logs`, `transcripts`.
   * Pattern: Append-only or rapid status transitions (`pending` -> `queued` -> `transcribing` -> `structuring` -> `transcribed`).
   * Transaction Sensitivity: High throughput, atomic leases, append-only logs.
3. **Read-Heavy Workloads (Doctor Portal & Search)**:
   * Queries: Doctor dashboard, patient directory search (trigram `pg_trgm` GIN indexes), consultation history keyset pagination.
   * Pattern: Multi-row range scans filtered by `clinic_id`.

### 6.2 Annual Growth & Indexing Strategy

| Table | Daily Rows (Normal) | Annual Rows (Normal) | Daily Rows (Stress) | Annual Rows (Stress) | Growth Strategy & Index Requirements |
| :--- | :---: | :---: | :---: | :---: | :--- |
| `patients` | ~150 | ~55,000 | ~450 | ~165,000 | Keyset B-tree index `idx_patients_clinic_created_at_id` `[MEASURED]`. Trigram GIN on `full_name`, `contact_info`, `opd_number`. |
| `consultations` | 6,000 | 2,190,000 | 15,750 | 5,748,750 | B-tree index `idx_consultations_patient_created_at` `[MEASURED]`. Composite `(clinic_id, created_at DESC)`. Future partition candidate by year. |
| `consultation_consents`| 6,000 | 2,190,000 | 15,750 | 5,748,750 | Composite index `(consultation_id, consent_status)` `[MEASURED]`. Enforces DB trigger gating. |
| `recordings` | 6,000 | 2,190,000 | 15,750 | 5,748,750 | Partial index `idx_recordings_retention_scan` `[MEASURED]`. Claim index `(processing_status, lease_expires_at)`. |
| `transcripts` | 6,000 | 2,190,000 | 15,750 | 5,748,750 | Unique constraint `idx_transcripts_recording_id_unique` `[MEASURED]`. Stored out-of-line in Postgres TOAST. |
| `ai_drafts` | 6,900 | 2,518,500 | 18,113 | 6,611,245 | Composite index `idx_ai_drafts_consultation_status` `[MEASURED]`. Revision column for optimistic concurrency. |
| `audit_logs` | ~30,000 | ~10,950,000 | ~94,500 | ~34,500,000 | Composite index `idx_audit_logs_clinic_created_at` `[MEASURED]`. **Prime candidate for monthly range partitioning in Block 5**. |

### 6.3 Database IOPS & Connection Pool Sizing
* **Peak Write Operations / Sec**:
  * Normal: ~25 writes/sec (consultation inserts, status updates, audit entries).
  * Stress: ~75 writes/sec.
* **Peak Read Operations / Sec**:
  * Normal: ~150 reads/sec (dashboard polls, patient searches, draft reviews).
  * Stress: ~450 reads/sec.
* **Connection Pool Requirement**:
  * Max active connections: 250 pooled connections (managed via Supavisor / PgBouncer).
  * Postgres `max_connections`: 100 backend server connections.
  * Sizing: Standard **8 vCPU, 32 GB RAM, 3,000 Provisioned IOPS NVMe SSD** handles the 500-doctor workload with > 65% headroom.

---

## 7. Redis Cache & Distributed Lock Sizing

Redis is strictly non-authoritative. It is used for ephemeral acceleration and distributed synchronization.

### 7.1 Redis Workload Profile

| Category | Key Pattern | TTL | Operations / Sec (Peak) | Memory Footprint |
| :--- | :--- | :---: | :---: | :---: |
| **Rate Limiting** | `rate:clinic:{clinic_id}:min` | 60 seconds | ~150 ops/s | < 5 MB |
| **Distributed Locks** | `lock:draft:{draft_id}` | 10 seconds | ~30 ops/s | < 2 MB |
| **Auth Session Cache** | `session:doc:{doctor_id}` | 15 minutes | ~200 ops/s | ~25 MB |
| **Dashboard Active Cache**| `dash:clinic:{clinic_id}` | 30 seconds | ~80 ops/s | ~10 MB |
| **Total Redis Working Set** | — | — | **~460 ops/s (Normal)**<br>**~1,200 ops/s (Stress)** | **< 100 MB** |

* **Hardware Sizing**: A modest **2 vCPU, 2 GB RAM Redis / Valkey node** provides over **100,000 ops/sec capacity**—representing a massive **80x safety margin** over the 1,200 ops/sec stress peak.
* **Failure Behavior**: If Redis becomes completely unavailable, rate-limiting fails open, locks fall back to PostgreSQL row locks (`SELECT FOR UPDATE`), and queries read directly from PostgreSQL replicas with zero data loss.

---

## 8. Apache Kafka Event Backbone Capacity

### 8.1 Event Topic Taxonomy & Daily Volumes

| Event Topic Name | Normal (Events/Day) | Busy (Events/Day) | Stress (Events/Day) | Peak Rate (Normal) | Peak Rate (Stress) |
| :--- | :---: | :---: | :---: | :---: | :---: |
| `audio.uploaded` | 6,000 | 9,750 | 15,750 | 0.28 / s | 0.80 / s |
| `transcription.requested` | 6,000 | 9,750 | 15,750 | 0.28 / s | 0.80 / s |
| `transcription.completed` | 6,000 | 9,750 | 15,750 | 0.28 / s | 0.80 / s |
| `ai.structuring.requested` | 6,900 | 11,213 | 18,113 | 0.32 / s | 0.92 / s |
| `ai.draft.created` | 6,900 | 11,213 | 18,113 | 0.32 / s | 0.92 / s |
| `consultation.finalized` | 6,000 | 9,750 | 15,750 | 0.28 / s | 0.80 / s |
| `processing.failed` (Alerts) | ~120 (2%) | ~195 (2%) | ~315 (2%) | < 0.05 / s | < 0.10 / s |
| **Total Kafka Event Volume** | **37,920 events/day** | **61,621 events/day** | **99,541 events/day** | **~1.8 events/s** | **~5.1 events/s** |

### 8.2 Partitioning & Retention Strategy
* **Total Daily Event Data**: ~100,000 events/day $\times$ 1.5 KB payload $\approx$ **150 MB / day**.
* **Partitioning Strategy**: Topics are partitioned by `clinic_id` hash across **6 to 12 partitions**. This guarantees strict per-clinic sequential ordering while allowing parallel processing across 6–12 worker instances.
* **Retention Horizon**: 7 days log retention (`log.retention.hours = 168`). Total cluster storage footprint is < 2.0 GB, representing trivial disk overhead.
* **Broker Topology**: Standard **3-Broker Kafka Cluster** (Replication Factor = 3, `min.insync.replicas = 2`).

---

## 9. API Traffic & Latency Budgets

### 9.1 API Traffic Classes

```
[ API TRAFFIC PROFILE ]
```

1. **Interactive APIs (Synchronous)**:
   * Operations: Doctor login, clinic profile, patient directory search, consultation CRUD, draft fetch, doctor finalization.
   * Peak Rate (Normal): ~35 requests/sec.
   * Peak Rate (Stress): ~110 requests/sec.
   * Architecture: Direct PostgREST / Go API servers over HTTP/2 or HTTP/3.
2. **Upload APIs (Chunked & Resumable)**:
   * Operations: Upload intent initialization, presigned URL issuance, completion handshake.
   * Peak Rate (Normal): ~1.5 requests/sec.
   * Peak Rate (Stress): ~4.5 requests/sec.
   * Architecture: Binary payloads bypass API servers; clients upload directly to S3 storage via presigned multipart URLs.
3. **Background APIs (Status Polling & Notifications)**:
   * Operations: Processing status polling (`pollRecordingUntilTerminal`), server-sent events (SSE).
   * Peak Rate (Normal): ~15 requests/sec.
   * Peak Rate (Stress): ~45 requests/sec.

### 9.2 Latency Budgets (Target SLOs)

| Operation Class | Target p50 | Target p95 | Target p99 | Target Sizing Rationale |
| :--- | :---: | :---: | :---: | :--- |
| **Interactive CRUD API** | < 80 ms | < 300 ms | < 500 ms | Fast Postgres primary queries utilizing composite indexes. |
| **Patient Trigram Search** | < 120 ms | < 400 ms | < 700 ms | GIN trigram index range scan over clinic-scoped rows. |
| **Upload Intent Handshake** | < 60 ms | < 200 ms | < 350 ms | S3 presigned URL generation and RLS verification. |
| **Direct S3 Audio Upload** | < 3.0 s | < 7.0 s | < 12.0 s | 1.2 MB binary transfer over 4G mobile uplink (network bound). |
| **STT Audio Transcription** | < 18.0 s | < 30.0 s | < 45.0 s | faster-whisper CTranslate2 processing on NVIDIA GPU. |
| **LLM Note Structuring** | < 8.0 s | < 14.0 s | < 20.0 s | vLLM prompt prefill and token generation. |
| **End-to-End Pipeline (Upload to Draft)** | **< 28.0 s** | **< 45.0 s** | **< 65.0 s** | Complete user experience wait time before doctor reviews draft. |
