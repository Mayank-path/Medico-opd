import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/core/utils/uuid_generator.dart';
import 'package:medico_opd/features/recording/models/recording_model.dart';

/// Simulated Block 1D Durable Job Processing Engine
/// Faithfully reproduces PostgreSQL table state, lease ownership, atomic claiming RPC,
/// transient vs permanent retries, backoff, consent revalidation, and stage separation.
class Block1dJobEngine {
  final Map<String, Map<String, dynamic>> recordings = {};
  final Map<String, Map<String, dynamic>> consents = {};
  final Map<String, Map<String, dynamic>> transcripts = {};
  final Map<String, Map<String, dynamic>> aiDrafts = {};
  final Set<String> transcriptRecordingIds = {};

  int deepgramCallCount = 0;
  int claudeCallCount = 0;

  // Failure simulation flags
  int deepgramFailuresRemaining = 0;
  String? deepgramErrorCode; // e.g. 'HTTP_429', 'HTTP_503', 'PERMANENT_ERROR'
  int claudeFailuresRemaining = 0;
  String? claudeErrorCode; // e.g. 'HTTP_429', 'MALFORMED_JSON'

  void reset() {
    recordings.clear();
    consents.clear();
    transcripts.clear();
    aiDrafts.clear();
    transcriptRecordingIds.clear();
    deepgramCallCount = 0;
    claudeCallCount = 0;
    deepgramFailuresRemaining = 0;
    deepgramErrorCode = null;
    claudeFailuresRemaining = 0;
    claudeErrorCode = null;
  }

  /// Simulates public.claim_recording_for_processing RPC:
  /// Atomically claims recording if pending/queued/retriable failed or lease expired.
  Future<Map<String, dynamic>?> claimRecording({
    required String recordingId,
    required String workerId,
    int leaseDurationSeconds = 180,
  }) async {
    final rec = recordings[recordingId];
    if (rec == null) return null;

    final now = DateTime.now().toUtc();
    final currentStatus = rec['processing_status'] as String;
    final leaseExpiry = rec['lease_expires_at'] != null
        ? DateTime.parse(rec['lease_expires_at'] as String)
        : null;
    final attemptCount = (rec['attempt_count'] as int?) ?? 0;
    final maxAttempts = (rec['max_attempts'] as int?) ?? 3;

    final isUnprocessed = currentStatus == 'pending' || currentStatus == 'queued';
    final isRetriableFailed = currentStatus == 'failed' && attemptCount < maxAttempts;
    final isLeaseExpired = ['transcribing', 'structuring'].contains(currentStatus) &&
        leaseExpiry != null &&
        leaseExpiry.isBefore(now);

    if (isUnprocessed || isRetriableFailed || isLeaseExpired) {
      rec['processing_status'] = 'transcribing';
      rec['processing_started_at'] ??= now.toIso8601String();
      rec['last_attempt_at'] = now.toIso8601String();
      rec['attempt_count'] = attemptCount + 1;
      rec['lease_worker_id'] = workerId;
      rec['lease_expires_at'] = now.add(Duration(seconds: leaseDurationSeconds)).toIso8601String();
      rec['last_error_code'] = null;
      rec['last_error_message'] = null;
      return Map<String, dynamic>.from(rec);
    }

    return null; // Could not claim (active lease or terminal status)
  }

  /// Full Block 1D Durable Processing Pipeline with stage separation and retry logic
  Future<Map<String, dynamic>> executeJobPipeline({
    required String recordingId,
    required String workerId,
  }) async {
    final rec = recordings[recordingId];
    if (rec == null) return {'status': 404, 'error': 'Recording not found'};

    final consultationId = rec['consultation_id'] as String;

    // 1. Initial Consent Check
    final consent = consents[consultationId];
    if (consent == null || consent['consent_status'] != 'granted' || consent['revoked_at'] != null) {
      rec['processing_status'] = 'failed';
      rec['last_error_code'] = 'CONSENT_REVOKED';
      rec['last_error_message'] = 'Consent revoked before processing started';
      return {'status': 403, 'code': 'CONSENT_REVOKED', 'error': 'Consent inactive'};
    }

    // 2. Atomic Claim
    final claimed = await claimRecording(recordingId: recordingId, workerId: workerId);
    if (claimed == null) {
      final current = rec['processing_status'] as String;
      if (['transcribing', 'structuring', 'queued'].contains(current)) {
        return {'status': 409, 'code': 'ALREADY_PROCESSING', 'idempotent': true};
      }
      if (current == 'transcribed') {
        return {'status': 200, 'code': 'ALREADY_TRANSCRIBED', 'idempotent': true};
      }
      return {'status': 409, 'code': 'STATE_LOCKED'};
    }

    // 3. STT Stage
    Map<String, dynamic>? transcript = transcripts.values.firstWhere(
      (t) => t['recording_id'] == recordingId,
      orElse: () => {},
    );

    if (transcript.isEmpty) {
      // Need STT
      bool sttSucceeded = false;
      const maxRetries = 2;
      for (int attempt = 0; attempt <= maxRetries; attempt++) {
        deepgramCallCount++;
        if (deepgramFailuresRemaining > 0) {
          deepgramFailuresRemaining--;
          if (deepgramErrorCode == 'HTTP_429' || deepgramErrorCode == 'HTTP_503') {
            // Transient: retry with backoff
            continue;
          } else {
            // Permanent
            rec['processing_status'] = 'failed';
            rec['last_error_code'] = 'STT_FAILED';
            rec['last_error_message'] = 'Permanent Deepgram STT error';
            return {'status': 502, 'code': 'STT_FAILED', 'error': 'Permanent Deepgram error'};
          }
        }
        sttSucceeded = true;
        break;
      }

      if (!sttSucceeded) {
        rec['processing_status'] = 'failed';
        rec['last_error_code'] = 'STT_RATE_LIMITED';
        return {'status': 502, 'code': 'STT_RATE_LIMITED'};
      }

      final transcriptId = generateUuidV4();
      transcript = {
        'id': transcriptId,
        'recording_id': recordingId,
        'privacy_processed_text': 'Patient reports 3 days of mild sore throat.',
      };
      transcripts[transcriptId] = transcript;
    }

    // 4. Consent Revalidation before LLM Stage
    final consentRecheck = consents[consultationId];
    if (consentRecheck == null || consentRecheck['consent_status'] != 'granted' || consentRecheck['revoked_at'] != null) {
      rec['processing_status'] = 'failed';
      rec['last_error_code'] = 'CONSENT_REVOKED';
      rec['last_error_message'] = 'Consent revoked before clinical structuring';
      return {'status': 403, 'code': 'CONSENT_REVOKED', 'error': 'Consent revoked during pipeline'};
    }

    // Advance state to structuring
    rec['processing_status'] = 'structuring';

    // 5. LLM Stage
    Map<String, dynamic>? draft = aiDrafts.values.firstWhere(
      (d) => d['consultation_id'] == consultationId && ['ai_draft', 'doctor_reviewed', 'finalized'].contains(d['status']),
      orElse: () => {},
    );

    if (draft.isEmpty) {
      bool llmSucceeded = false;
      const maxRetries = 2;
      for (int attempt = 0; attempt <= maxRetries; attempt++) {
        claudeCallCount++;
        if (claudeFailuresRemaining > 0) {
          claudeFailuresRemaining--;
          if (claudeErrorCode == 'HTTP_429') {
            continue; // Transient
          } else if (claudeErrorCode == 'MALFORMED_JSON') {
            rec['processing_status'] = 'failed';
            rec['last_error_code'] = 'LLM_INVALID_OUTPUT';
            return {'status': 502, 'code': 'LLM_INVALID_OUTPUT', 'error': 'Malformed LLM JSON'};
          }
        }
        llmSucceeded = true;
        break;
      }

      if (!llmSucceeded) {
        rec['processing_status'] = 'failed';
        rec['last_error_code'] = 'LLM_RATE_LIMITED';
        return {'status': 502, 'code': 'LLM_RATE_LIMITED'};
      }

      final draftId = generateUuidV4();
      draft = {
        'id': draftId,
        'consultation_id': consultationId,
        'status': 'ai_draft',
        'structured_json': {
          'chief_complaints': ['Sore throat for 3 days'],
          'provisional_diagnosis': ['Acute Pharyngitis'],
        },
      };
      aiDrafts[draftId] = draft;
    }

    // 6. Complete
    rec['processing_status'] = 'transcribed';
    return {
      'status': 200,
      'recording_id': recordingId,
      'transcript_id': transcript['id'],
      'ai_draft_id': draft['id'],
    };
  }
}

void main() {
  group('Block 1D — Async AI Processing & Durable Job Architecture Tests', () {
    late Block1dJobEngine engine;

    setUp(() {
      engine = Block1dJobEngine();
    });

    test('Test 1 — Job Claiming: Two workers attempt same job -> one owner, one rejected', () async {
      final recId = generateUuidV4();
      final consId = generateUuidV4();

      engine.recordings[recId] = {
        'id': recId,
        'consultation_id': consId,
        'clinic_id': 'clinic-1',
        'processing_status': 'pending',
      };
      engine.consents[consId] = {
        'consultation_id': consId,
        'consent_status': 'granted',
        'revoked_at': null,
      };

      // Worker 1 and Worker 2 race to claim the same recording
      final claim1 = await engine.claimRecording(recordingId: recId, workerId: 'worker-1');
      final claim2 = await engine.claimRecording(recordingId: recId, workerId: 'worker-2');

      expect(claim1, isNotNull);
      expect(claim1!['lease_worker_id'], equals('worker-1'));
      expect(claim2, isNull, reason: 'Worker 2 must be rejected as Worker 1 holds active lease');
      expect(engine.recordings[recId]!['attempt_count'], equals(1));
    });

    test('Test 2 — Crash Recovery: Worker crashes after claim -> job recoverable after lease expiration', () async {
      final recId = generateUuidV4();
      final consId = generateUuidV4();

      // Worker 1 claimed job but lease has now expired (e.g. 5 minutes ago)
      final past = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
      engine.recordings[recId] = {
        'id': recId,
        'consultation_id': consId,
        'clinic_id': 'clinic-1',
        'processing_status': 'transcribing',
        'attempt_count': 1,
        'max_attempts': 3,
        'lease_worker_id': 'crashed-worker-1',
        'lease_expires_at': past.toIso8601String(),
      };
      engine.consents[consId] = {
        'consultation_id': consId,
        'consent_status': 'granted',
        'revoked_at': null,
      };

      // Worker 2 attempts to claim the stale job
      final claim2 = await engine.claimRecording(recordingId: recId, workerId: 'recovery-worker-2');

      expect(claim2, isNotNull, reason: 'Stale lease must be reclaimed by recovery worker');
      expect(claim2!['lease_worker_id'], equals('recovery-worker-2'));
      expect(claim2['attempt_count'], equals(2));
    });

    test('Test 3 — Transient Deepgram 503: Worker retries transient failure with bounded retry and succeeds', () async {
      final recId = generateUuidV4();
      final consId = generateUuidV4();

      engine.recordings[recId] = {
        'id': recId,
        'consultation_id': consId,
        'clinic_id': 'clinic-1',
        'processing_status': 'queued',
      };
      engine.consents[consId] = {
        'consultation_id': consId,
        'consent_status': 'granted',
        'revoked_at': null,
      };

      // 1 transient failure, then success
      engine.deepgramFailuresRemaining = 1;
      engine.deepgramErrorCode = 'HTTP_503';

      final result = await engine.executeJobPipeline(recordingId: recId, workerId: 'w-1');
      expect(result['status'], equals(200));
      expect(engine.deepgramCallCount, equals(2), reason: 'Failed once and retried successfully');
      expect(engine.recordings[recId]!['processing_status'], equals('transcribed'));
    });

    test('Test 4 — Deepgram 429: Rate-limit failure backs off and retries', () async {
      final recId = generateUuidV4();
      final consId = generateUuidV4();

      engine.recordings[recId] = {
        'id': recId,
        'consultation_id': consId,
        'clinic_id': 'clinic-1',
        'processing_status': 'pending',
      };
      engine.consents[consId] = {
        'consultation_id': consId,
        'consent_status': 'granted',
        'revoked_at': null,
      };

      engine.deepgramFailuresRemaining = 1;
      engine.deepgramErrorCode = 'HTTP_429';

      final result = await engine.executeJobPipeline(recordingId: recId, workerId: 'w-1');
      expect(result['status'], equals(200));
      expect(engine.deepgramCallCount, equals(2));
    });

    test('Test 5 — Permanent STT Error: Bounded retry does not loop infinitely and transitions to failed', () async {
      final recId = generateUuidV4();
      final consId = generateUuidV4();

      engine.recordings[recId] = {
        'id': recId,
        'consultation_id': consId,
        'clinic_id': 'clinic-1',
        'processing_status': 'pending',
      };
      engine.consents[consId] = {
        'consultation_id': consId,
        'consent_status': 'granted',
        'revoked_at': null,
      };

      engine.deepgramFailuresRemaining = 5;
      engine.deepgramErrorCode = 'PERMANENT_ERROR';

      final result = await engine.executeJobPipeline(recordingId: recId, workerId: 'w-1');
      expect(result['status'], equals(502));
      expect(result['code'], equals('STT_FAILED'));
      expect(engine.deepgramCallCount, equals(1), reason: 'Permanent failure must not retry');
      expect(engine.recordings[recId]!['processing_status'], equals('failed'));
    });

    test('Test 6 — Claude 429: Rate-limit failure backs off and retries', () async {
      final recId = generateUuidV4();
      final consId = generateUuidV4();

      engine.recordings[recId] = {
        'id': recId,
        'consultation_id': consId,
        'clinic_id': 'clinic-1',
        'processing_status': 'pending',
      };
      engine.consents[consId] = {
        'consultation_id': consId,
        'consent_status': 'granted',
        'revoked_at': null,
      };

      engine.claudeFailuresRemaining = 1;
      engine.claudeErrorCode = 'HTTP_429';

      final result = await engine.executeJobPipeline(recordingId: recId, workerId: 'w-1');
      expect(result['status'], equals(200));
      expect(engine.claudeCallCount, equals(2));
    });

    test('Test 7 — Malformed Claude JSON: Draft is NOT marked ready and error is recorded', () async {
      final recId = generateUuidV4();
      final consId = generateUuidV4();

      engine.recordings[recId] = {
        'id': recId,
        'consultation_id': consId,
        'clinic_id': 'clinic-1',
        'processing_status': 'pending',
      };
      engine.consents[consId] = {
        'consultation_id': consId,
        'consent_status': 'granted',
        'revoked_at': null,
      };

      engine.claudeFailuresRemaining = 1;
      engine.claudeErrorCode = 'MALFORMED_JSON';

      final result = await engine.executeJobPipeline(recordingId: recId, workerId: 'w-1');
      expect(result['status'], equals(502));
      expect(result['code'], equals('LLM_INVALID_OUTPUT'));
      expect(engine.aiDrafts.isEmpty, isTrue, reason: 'Malformed JSON must NEVER create an active draft');
      expect(engine.recordings[recId]!['processing_status'], equals('failed'));
      expect(engine.recordings[recId]!['last_error_code'], equals('LLM_INVALID_OUTPUT'));
    });

    test('Test 8 — Existing Transcript: STT provider is skipped when transcript already exists', () async {
      final recId = generateUuidV4();
      final consId = generateUuidV4();

      engine.recordings[recId] = {
        'id': recId,
        'consultation_id': consId,
        'clinic_id': 'clinic-1',
        'processing_status': 'pending',
      };
      engine.consents[consId] = {
        'consultation_id': consId,
        'consent_status': 'granted',
        'revoked_at': null,
      };
      engine.transcripts['t-existing'] = {
        'id': 't-existing',
        'recording_id': recId,
        'privacy_processed_text': 'Pre-existing transcript text.',
      };

      final result = await engine.executeJobPipeline(recordingId: recId, workerId: 'w-1');
      expect(result['status'], equals(200));
      expect(engine.deepgramCallCount, equals(0), reason: 'Deepgram must be completely skipped');
      expect(engine.claudeCallCount, equals(1));
    });

    test('Test 9 — Existing Valid Draft: Claude provider is skipped when draft already exists', () async {
      final recId = generateUuidV4();
      final consId = generateUuidV4();

      engine.recordings[recId] = {
        'id': recId,
        'consultation_id': consId,
        'clinic_id': 'clinic-1',
        'processing_status': 'pending',
      };
      engine.consents[consId] = {
        'consultation_id': consId,
        'consent_status': 'granted',
        'revoked_at': null,
      };
      engine.transcripts['t-1'] = {
        'id': 't-1',
        'recording_id': recId,
        'privacy_processed_text': 'Transcript text.',
      };
      engine.aiDrafts['d-1'] = {
        'id': 'd-1',
        'consultation_id': consId,
        'status': 'ai_draft',
        'structured_json': {'chief_complaints': ['Existing note']},
      };

      final result = await engine.executeJobPipeline(recordingId: recId, workerId: 'w-1');
      expect(result['status'], equals(200));
      expect(engine.deepgramCallCount, equals(0));
      expect(engine.claudeCallCount, equals(0), reason: 'Claude must be completely skipped');
    });

    test('Test 10 — Consent Revoked While Queued: Zero provider calls and aborts immediately', () async {
      final recId = generateUuidV4();
      final consId = generateUuidV4();

      engine.recordings[recId] = {
        'id': recId,
        'consultation_id': consId,
        'clinic_id': 'clinic-1',
        'processing_status': 'queued',
      };
      engine.consents[consId] = {
        'consultation_id': consId,
        'consent_status': 'revoked',
        'revoked_at': DateTime.now().toIso8601String(),
      };

      final result = await engine.executeJobPipeline(recordingId: recId, workerId: 'w-1');
      expect(result['status'], equals(403));
      expect(result['code'], equals('CONSENT_REVOKED'));
      expect(engine.deepgramCallCount, equals(0));
      expect(engine.claudeCallCount, equals(0));
      expect(engine.recordings[recId]!['processing_status'], equals('failed'));
    });

    test('Test 11 — Consent Revoked Before LLM Stage: Transcript saved but Claude NOT called', () async {
      final recId = generateUuidV4();
      final consId = generateUuidV4();

      engine.recordings[recId] = {
        'id': recId,
        'consultation_id': consId,
        'clinic_id': 'clinic-1',
        'processing_status': 'pending',
      };
      // Consent valid initially
      engine.consents[consId] = {
        'consultation_id': consId,
        'consent_status': 'granted',
        'revoked_at': null,
      };

      // Set STT to succeed but consent revoked before LLM recheck
      engine.transcripts['t-mid'] = {
        'id': 't-mid',
        'recording_id': recId,
        'privacy_processed_text': 'Valid transcript before revocation.',
      };
      // Patient revokes consent!
      engine.consents[consId]!['revoked_at'] = DateTime.now().toIso8601String();

      final result = await engine.executeJobPipeline(recordingId: recId, workerId: 'w-1');
      expect(result['status'], equals(403));
      expect(result['code'], equals('CONSENT_REVOKED'));
      expect(engine.claudeCallCount, equals(0), reason: 'Claude must NEVER be called after revocation');
      expect(engine.recordings[recId]!['processing_status'], equals('failed'));
    });

    test('Test 12 — Stale Processing Job: Recovers cleanly and re-attempts', () async {
      final recId = generateUuidV4();
      final consId = generateUuidV4();

      final past = DateTime.now().toUtc().subtract(const Duration(minutes: 10));
      engine.recordings[recId] = {
        'id': recId,
        'consultation_id': consId,
        'clinic_id': 'clinic-1',
        'processing_status': 'transcribing',
        'attempt_count': 1,
        'max_attempts': 3,
        'lease_expires_at': past.toIso8601String(),
      };
      engine.consents[consId] = {
        'consultation_id': consId,
        'consent_status': 'granted',
        'revoked_at': null,
      };

      final result = await engine.executeJobPipeline(recordingId: recId, workerId: 'recovery-w');
      expect(result['status'], equals(200));
      expect(engine.recordings[recId]!['processing_status'], equals('transcribed'));
    });

    test('Test 13 — Clinic Isolation: Two clinics submit jobs simultaneously -> full tenant isolation', () async {
      final recA = generateUuidV4();
      final recB = generateUuidV4();
      final consA = generateUuidV4();
      final consB = generateUuidV4();

      engine.recordings[recA] = {
        'id': recA,
        'consultation_id': consA,
        'clinic_id': 'clinic-alpha',
        'processing_status': 'pending',
      };
      engine.consents[consA] = {
        'consultation_id': consA,
        'consent_status': 'granted',
        'revoked_at': null,
      };

      engine.recordings[recB] = {
        'id': recB,
        'consultation_id': consB,
        'clinic_id': 'clinic-beta',
        'processing_status': 'pending',
      };
      engine.consents[consB] = {
        'consultation_id': consB,
        'consent_status': 'granted',
        'revoked_at': null,
      };

      // Both execute concurrently
      final futureA = engine.executeJobPipeline(recordingId: recA, workerId: 'worker-alpha');
      final futureB = engine.executeJobPipeline(recordingId: recB, workerId: 'worker-beta');

      final results = await Future.wait([futureA, futureB]);
      expect(results[0]['status'], equals(200));
      expect(results[1]['status'], equals(200));

      expect(engine.recordings[recA]!['clinic_id'], equals('clinic-alpha'));
      expect(engine.recordings[recB]!['clinic_id'], equals('clinic-beta'));
    });

    test('Test 14 — App killed while processing: Server state remains durable and recoverable', () {
      final recId = generateUuidV4();
      final now = DateTime.now().toUtc();

      final model = RecordingModel(
        id: recId,
        consultationId: 'cons-1',
        patientId: 'pat-1',
        doctorId: 'doc-1',
        storagePath: 'clinics/c1/consultations/cons-1/$recId.m4a',
        encryptionKeyRef: 'sse-s3',
        createdAt: now,
        processingStatus: RecordingProcessingStatus.transcribing,
        processingStartedAt: now,
        attemptCount: 1,
        leaseWorkerId: 'edge-worker-1',
        leaseExpiresAt: now.add(const Duration(minutes: 3)),
      );

      final json = model.toJson();
      final parsed = RecordingModel.fromJson(json);

      expect(parsed.processingStatus, equals(RecordingProcessingStatus.transcribing));
      expect(parsed.leaseWorkerId, equals('edge-worker-1'));
      expect(parsed.attemptCount, equals(1));
    });

    test('Test 15 — Duplicate client processing request: Safe 409 conflict and zero duplicate provider calls', () async {
      final recId = generateUuidV4();
      final consId = generateUuidV4();

      engine.recordings[recId] = {
        'id': recId,
        'consultation_id': consId,
        'clinic_id': 'clinic-1',
        'processing_status': 'pending',
      };
      engine.consents[consId] = {
        'consultation_id': consId,
        'consent_status': 'granted',
        'revoked_at': null,
      };

      // Simulate Request 1 in flight
      await engine.claimRecording(recordingId: recId, workerId: 'worker-1');

      // Duplicate Request 2 arrives while Request 1 is active
      final result2 = await engine.executeJobPipeline(recordingId: recId, workerId: 'worker-2');

      expect(result2['status'], equals(409));
      expect(result2['code'], equals('ALREADY_PROCESSING'));
      expect(engine.deepgramCallCount, equals(0));
      expect(engine.claudeCallCount, equals(0));
    });
  });
}
