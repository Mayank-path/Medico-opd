# ADR-0006: Mobile Offline Resilience, Crash Recovery & Idempotency Contract

```
Status   : ACCEPTED
Date     : 2026-09-28
Deciders : Lead Architect, Mobile Engineering Lead, Backend Lead
Context  : Medico-OPD Block 0 Architecture
```

---

## 1. Context & Problem Statement
Doctors using Medico-OPD operate in real-world Indian clinic environments with variable cellular reception, basement OPD clinics, Wi-Fi drops during room transitions, and phone operating systems that aggressively kill background apps to conserve battery.

If the mobile client assumes continuous network availability or lacks deterministic recovery protocols:
1. Long patient consultations will be lost if network drops mid-recording.
2. Incomplete uploads will produce orphaned server records or duplicate billing.
3. Network timeouts will cause doctors to tap buttons repeatedly, triggering duplicate consultations or prescriptions.

---

## 2. Decision
We decide that **the Flutter mobile client must enforce an offline-first capture, crash-recovery, and idempotency contract**:

1. **Continuous Local Recording Resilience**:
   * Microphone capture writes audio chunks directly to device sandbox storage (`path_provider`).
   * Active recording **never requires network connectivity**. The network is only accessed when upload begins.
2. **Crash & Termination Recovery Protocol**:
   * Before opening the microphone, the client writes an atomic checkpoint (`InterruptedRecordingCheckpoint`) to encrypted local storage (`RecordingRecoveryService`).
   * When the app boots or resumes from background termination, it inspects active checkpoints. If an unclosed recording is found, the app presents an interactive recovery wizard:
     *"An interrupted consultation recording was recovered for Patient [Name]. Tap to resume upload or discard."*
3. **Resumable Chunked Upload Protocol**:
   * Audio files are uploaded using chunked HTTP multipart transfer (TUS or S3 Multipart) with client-calculated SHA-256 integrity hashes.
   * If connection drops mid-upload, the client resumes from the last acknowledged byte offset upon reconnection without re-uploading the entire file.
4. **Server-Side Idempotency via Client-Generated UUIDv4**:
   * Every recording and consultation creation generates a cryptographic UUIDv4 on the client prior to network dispatch (`clientRecordingId`).
   * The backend database insertion enforces idempotency (`ON CONFLICT (id) DO NOTHING` or `createOrGetRecording()`):
     If a doctor taps retry or the network times out on the response, the backend returns the existing row without creating duplicate consultations or re-triggering pipelines.

---

## 3. Consequences

### Positive Consequences
* **Zero Consultation Loss**: Doctor consultations are completely protected against app crashes, OS background kills, and network outages.
* **Deterministic Backend State**: Re-transmitted requests due to network blips never pollute the clinical database with ghost records.
* **Superior Clinical Trust**: Doctors can rely on the app during high-stress clinic hours without fear of lost documentation.

### Negative / Trade-Off Consequences
* **Client Local Storage Management**: The client must track and clean up temporary audio files post-upload to avoid filling the doctor's phone storage (implemented via `clearCheckpointAndPurgeFile()`).
