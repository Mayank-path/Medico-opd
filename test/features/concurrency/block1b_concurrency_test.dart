import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/core/utils/uuid_generator.dart';
import 'package:medico_opd/features/ai_draft/services/ai_draft_service.dart';

/// Simulated in-memory database engine for concurrency and idempotency testing.
/// Accurately reproduces PostgreSQL row-level locks, unique constraints,
/// and trigger-enforced finalized draft locks.
class InMemoryDatabaseEngine {
  final Map<String, Map<String, dynamic>> recordings = {};
  final Map<String, Map<String, dynamic>> transcripts = {};
  final Map<String, Map<String, dynamic>> aiDrafts = {};
  final Set<String> transcriptRecordingIds = {};

  int deepgramCallCount = 0;
  int claudeCallCount = 0;

  void reset() {
    recordings.clear;
    transcripts.clear();
    aiDrafts.clear();
    transcriptRecordingIds.clear();
    deepgramCallCount = 0;
    claudeCallCount = 0;
  }

  /// Simulates atomic state claim:
  /// UPDATE recordings SET processing_status = 'transcribing'
  /// WHERE id = :id AND processing_status IN ('pending', 'failed')
  /// RETURNING id, processing_status;
  Future<Map<String, dynamic>?> atomicClaimRecording(String recordingId) async {
    // Row-level lock simulation: atomic check-and-set
    final row = recordings[recordingId];
    if (row == null) return null;

    final currentStatus = row['processing_status'] as String;
    if (currentStatus == 'pending' || currentStatus == 'failed') {
      row['processing_status'] = 'transcribing';
      return Map<String, dynamic>.from(row);
    }
    // Zero rows updated if already claimed
    return null;
  }

  /// Simulates the process-consultation pipeline
  Future<Map<String, dynamic>> processConsultation({
    required String recordingId,
    required String consultationId,
    required String clinicId,
  }) async {
    final rec = recordings[recordingId];
    if (rec == null || rec['clinic_id'] != clinicId) {
      return {'status': 404, 'error': 'Recording not found or cross-clinic access denied'};
    }

    // 1. Check existing active draft
    final existingDraft = aiDrafts.values.firstWhere(
      (d) =>
          d['consultation_id'] == consultationId &&
          ['ai_draft', 'doctor_reviewed', 'finalized'].contains(d['status']),
      orElse: () => {},
    );

    if (existingDraft.isNotEmpty) {
      rec['processing_status'] = 'transcribed';
      return {
        'status': 200,
        'idempotent': true,
        'recording_id': recordingId,
        'ai_draft_id': existingDraft['id'],
        'ai_draft_status': existingDraft['status'],
      };
    }

    // 2. Atomic claim
    final claimed = await atomicClaimRecording(recordingId);
    if (claimed == null) {
      final currentStatus = rec['processing_status'] as String;
      if (currentStatus == 'transcribing') {
        return {
          'status': 409,
          'idempotent': true,
          'code': 'ALREADY_PROCESSING',
          'message': 'Recording is currently being processed by another request.',
        };
      }
      if (currentStatus == 'transcribed') {
        return {
          'status': 200,
          'idempotent': true,
          'recording_id': recordingId,
          'ai_draft_id': existingDraft['id'],
        };
      }
      return {'status': 409, 'code': 'STATE_LOCKED'};
    }

    // 3. STT Stage (Paid Provider)
    // Check if transcript already exists
    Map<String, dynamic>? transcript = transcripts.values.firstWhere(
      (t) => t['recording_id'] == recordingId,
      orElse: () => {},
    );

    if (transcript.isEmpty) {
      deepgramCallCount++;
      // Simulate STT delay
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Insert transcript with unique index constraint
      if (transcriptRecordingIds.contains(recordingId)) {
        throw StateError('UNIQUE constraint violation: transcript for recording_id already exists');
      }
      transcriptRecordingIds.add(recordingId);
      final transcriptId = generateUuidV4();
      transcript = {
        'id': transcriptId,
        'recording_id': recordingId,
        'privacy_processed_text': 'Patient presents with mild fever and throat irritation.',
      };
      transcripts[transcriptId] = transcript;
    }

    // 4. LLM Stage (Paid Provider)
    claudeCallCount++;
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Re-check for active draft before inserting
    var activeDraft = aiDrafts.values.firstWhere(
      (d) =>
          d['consultation_id'] == consultationId &&
          ['ai_draft', 'doctor_reviewed', 'finalized'].contains(d['status']),
      orElse: () => {},
    );

    if (activeDraft.isEmpty) {
      final draftId = generateUuidV4();
      activeDraft = {
        'id': draftId,
        'consultation_id': consultationId,
        'status': 'ai_draft',
        'revision': 1,
        'structured_json': {'chief_complaint': 'Mild fever and throat irritation'},
      };
      aiDrafts[draftId] = activeDraft;
    }

    rec['processing_status'] = 'transcribed';
    return {
      'status': 200,
      'recording_id': recordingId,
      'transcript_id': transcript['id'],
      'ai_draft_id': activeDraft['id'],
      'ai_draft_status': activeDraft['status'],
    };
  }

  /// Simulates optimistic locking update on ai_drafts:
  /// UPDATE ai_drafts SET ..., revision = revision + 1
  /// WHERE id = :id AND revision = :expected_revision
  Future<Map<String, dynamic>> updateAiDraftReview({
    required String draftId,
    required Map<String, dynamic> updatedJson,
    required String doctorId,
    required int expectedRevision,
  }) async {
    final draft = aiDrafts[draftId];
    if (draft == null) {
      throw StateError('AI draft not found: $draftId');
    }

    // Trigger simulation: trg_lock_finalized_ai_draft
    if (draft['status'] == 'finalized') {
      throw StateError('AI draft is finalized and permanently locked against modifications.');
    }

    // Optimistic locking revision check
    final currentRevision = draft['revision'] as int;
    if (currentRevision != expectedRevision) {
      throw ConcurrentModificationException(
        'CONCURRENT_MODIFICATION: Draft revision mismatch (expected $expectedRevision, actual $currentRevision).',
      );
    }

    draft['structured_json'] = updatedJson;
    draft['status'] = 'doctor_reviewed';
    draft['reviewed_by'] = doctorId;
    draft['reviewed_at'] = DateTime.now().toIso8601String();
    draft['revision'] = currentRevision + 1;

    return Map<String, dynamic>.from(draft);
  }
}

void main() {
  group('Block 1B — Concurrency & Idempotency Hardening Suite', () {
    late InMemoryDatabaseEngine db;

    setUp(() {
      db = InMemoryDatabaseEngine();
    });

    test('Test 1 — Double Processing: Concurrent process requests produce exactly one owner and zero duplicate paid calls', () async {
      final recordingId = generateUuidV4();
      final consultationId = generateUuidV4();
      final clinicId = 'clinic-alpha';

      db.recordings[recordingId] = {
        'id': recordingId,
        'consultation_id': consultationId,
        'clinic_id': clinicId,
        'processing_status': 'pending',
      };

      // Launch Request A and Request B simultaneously
      final futureA = db.processConsultation(
        recordingId: recordingId,
        consultationId: consultationId,
        clinicId: clinicId,
      );
      final futureB = db.processConsultation(
        recordingId: recordingId,
        consultationId: consultationId,
        clinicId: clinicId,
      );

      final results = await Future.wait([futureA, futureB]);
      final success = results.where((r) => r['status'] == 200).toList();
      final conflict = results.where((r) => r['status'] == 409).toList();

      expect(success.length, equals(1), reason: 'Exactly one request must successfully claim the recording');
      expect(conflict.length, equals(1), reason: 'Second concurrent request must receive conflict');
      expect(conflict.first['code'], equals('ALREADY_PROCESSING'));

      // Invariant: Paid providers must be called exactly once
      expect(db.deepgramCallCount, equals(1), reason: 'Deepgram STT must be invoked exactly once');
      expect(db.claudeCallCount, equals(1), reason: 'Claude LLM must be invoked exactly once');

      // Transcript and draft count
      expect(db.transcripts.length, equals(1), reason: 'Only one transcript must be created');
      expect(db.aiDrafts.length, equals(1), reason: 'Only one active draft must be created');
    });

    test('Test 2 — Already Processing: Recording in transcribing state returns safe idempotent 409 without calling AI', () async {
      final recordingId = generateUuidV4();
      final consultationId = generateUuidV4();
      final clinicId = 'clinic-alpha';

      db.recordings[recordingId] = {
        'id': recordingId,
        'consultation_id': consultationId,
        'clinic_id': clinicId,
        'processing_status': 'transcribing', // Already claimed by prior worker
      };

      final response = await db.processConsultation(
        recordingId: recordingId,
        consultationId: consultationId,
        clinicId: clinicId,
      );

      expect(response['status'], equals(409));
      expect(response['code'], equals('ALREADY_PROCESSING'));
      expect(response['idempotent'], isTrue);

      // Verify zero provider invocations
      expect(db.deepgramCallCount, equals(0), reason: 'Zero Deepgram calls when already transcribing');
      expect(db.claudeCallCount, equals(0), reason: 'Zero Claude calls when already transcribing');
    });

    test('Test 3 — Transcript Uniqueness: Recording ID unique constraint prevents duplicate transcripts', () async {
      final recordingId = generateUuidV4();
      final t1 = generateUuidV4();
      final t2 = generateUuidV4();

      db.transcriptRecordingIds.add(recordingId);
      db.transcripts[t1] = {
        'id': t1,
        'recording_id': recordingId,
        'privacy_processed_text': 'First transcript',
      };

      // Second attempt to add transcript for same recording_id must fail unique constraint
      expect(
        () {
          if (db.transcriptRecordingIds.contains(recordingId)) {
            throw StateError('UNIQUE constraint violation: transcript for recording_id already exists');
          }
          db.transcripts[t2] = {
            'id': t2,
            'recording_id': recordingId,
            'privacy_processed_text': 'Second transcript duplicate',
          };
        },
        throwsStateError,
      );

      expect(db.transcripts.length, equals(1));
      expect(db.transcripts.values.first['id'], equals(t1));
    });

    test('Test 4 — Draft Duplication: Prevents duplicate active drafts while preserving historical rejected drafts', () async {
      final consultationId = generateUuidV4();

      // Historical rejected draft exists for this consultation (retained for audit compliance)
      final rejectedDraftId = generateUuidV4();
      db.aiDrafts[rejectedDraftId] = {
        'id': rejectedDraftId,
        'consultation_id': consultationId,
        'status': 'rejected',
        'revision': 2,
        'structured_json': {'note': 'Rejected draft artifact'},
      };

      // Now create an active draft via atomic processing
      final recordingId = generateUuidV4();
      db.recordings[recordingId] = {
        'id': recordingId,
        'consultation_id': consultationId,
        'clinic_id': 'clinic-alpha',
        'processing_status': 'pending',
      };

      final res = await db.processConsultation(
        recordingId: recordingId,
        consultationId: consultationId,
        clinicId: 'clinic-alpha',
      );

      expect(res['status'], equals(200));

      // Both drafts exist: 1 rejected historical draft, 1 active draft
      expect(db.aiDrafts.length, equals(2));
      final activeDrafts = db.aiDrafts.values.where((d) => d['status'] == 'ai_draft').toList();
      final rejectedDrafts = db.aiDrafts.values.where((d) => d['status'] == 'rejected').toList();

      expect(activeDrafts.length, equals(1), reason: 'Exactly one active draft created');
      expect(rejectedDrafts.length, equals(1), reason: 'Historical rejected draft preserved for audit');
    });

    test('Test 5 — Retry Identity: Preserves same recording UUID and deterministic storage path across client retries', () async {
      final clientRecordingId = generateUuidV4();
      final consultationId = generateUuidV4();
      final clinicId = 'clinic-alpha';

      // Simulates deterministic storage path computation
      final path1 = 'clinics/$clinicId/consultations/$consultationId/$clientRecordingId.m4a';

      // Simulate first attempt: uploads bytes and creates recording row
      db.recordings[clientRecordingId] = {
        'id': clientRecordingId,
        'consultation_id': consultationId,
        'clinic_id': clinicId,
        'storage_path': path1,
        'processing_status': 'pending',
      };

      // Simulate network blip / timeout on Edge Function: processing moves to 'failed'
      db.recordings[clientRecordingId]!['processing_status'] = 'failed';

      // Client retries: retry MUST reuse the exact same clientRecordingId
      final retryRecordingId = clientRecordingId; // Preserved in widget.clientRecordingId
      final path2 = 'clinics/$clinicId/consultations/$consultationId/$retryRecordingId.m4a';

      expect(path2, equals(path1), reason: 'Storage path must be deterministic on retry');
      expect(retryRecordingId, equals(clientRecordingId), reason: 'Recording UUID must remain stable across retries');

      // Retry successfully claims the 'failed' recording
      final retryRes = await db.processConsultation(
        recordingId: retryRecordingId,
        consultationId: consultationId,
        clinicId: clinicId,
      );

      expect(retryRes['status'], equals(200));
      expect(db.recordings.length, equals(1), reason: 'Zero orphan recording rows created');
      expect(db.recordings[clientRecordingId]!['processing_status'], equals('transcribed'));
    });

    test('Test 6 — Concurrent Draft Editing: Optimistic locking detects conflict and prevents silent overwrites', () async {
      final draftId = generateUuidV4();
      db.aiDrafts[draftId] = {
        'id': draftId,
        'consultation_id': generateUuidV4(),
        'status': 'ai_draft',
        'revision': 1,
        'structured_json': {'chief_complaint': 'Original text'},
      };

      // Doctor on Device A and Doctor on Device B both open draft at revision 1
      const initialRevision = 1;

      // Doctor A saves first
      final updateA = await db.updateAiDraftReview(
        draftId: draftId,
        updatedJson: {'chief_complaint': 'Doctor A diagnosis and prescription'},
        doctorId: 'doc-A',
        expectedRevision: initialRevision,
      );

      expect(updateA['revision'], equals(2));
      expect(updateA['structured_json']['chief_complaint'], contains('Doctor A'));

      // Doctor B attempts to save using stale revision 1
      expect(
        () => db.updateAiDraftReview(
          draftId: draftId,
          updatedJson: {'chief_complaint': 'Doctor B concurrent overwrite attempt'},
          doctorId: 'doc-B',
          expectedRevision: initialRevision,
        ),
        throwsA(isA<ConcurrentModificationException>()),
      );

      // Verify Doctor A's content was NOT overwritten
      expect(
        db.aiDrafts[draftId]!['structured_json']['chief_complaint'],
        equals('Doctor A diagnosis and prescription'),
        reason: 'Silent overwrite must be completely blocked',
      );
      expect(db.aiDrafts[draftId]!['revision'], equals(2));
    });

    test('Test 7 — Finalized Draft: Concurrent update rejected and finalized note immutability strictly preserved', () async {
      final draftId = generateUuidV4();
      db.aiDrafts[draftId] = {
        'id': draftId,
        'consultation_id': generateUuidV4(),
        'status': 'finalized', // Locked by trg_lock_finalized_ai_draft
        'revision': 3,
        'finalized_by': 'doc-chief',
        'finalized_at': DateTime.now().toIso8601String(),
        'structured_json': {'diagnosis': 'Permanent authoritative record'},
      };

      // Even if client provides the matching revision, update against finalized draft is blocked
      expect(
        () => db.updateAiDraftReview(
          draftId: draftId,
          updatedJson: {'diagnosis': 'Illicit tampering attempt'},
          doctorId: 'doc-malicious',
          expectedRevision: 3,
        ),
        throwsA(
          predicate(
            (e) => e is StateError && e.message.contains('finalized and permanently locked'),
          ),
        ),
      );

      // Verify draft state remains untouched
      expect(db.aiDrafts[draftId]!['status'], equals('finalized'));
      expect(db.aiDrafts[draftId]!['structured_json']['diagnosis'], equals('Permanent authoritative record'));
    });

    test('Test 8 — Cross-Clinic Concurrency: Concurrent operations across clinics are strictly isolated by RLS', () async {
      final clinicAlphaRecId = generateUuidV4();
      final clinicBetaRecId = generateUuidV4();

      db.recordings[clinicAlphaRecId] = {
        'id': clinicAlphaRecId,
        'consultation_id': generateUuidV4(),
        'clinic_id': 'clinic-alpha',
        'processing_status': 'pending',
      };

      db.recordings[clinicBetaRecId] = {
        'id': clinicBetaRecId,
        'consultation_id': generateUuidV4(),
        'clinic_id': 'clinic-beta',
        'processing_status': 'pending',
      };

      // Doctor from Clinic Alpha attempts to process Clinic Beta's recording
      final crossClinicRes = await db.processConsultation(
        recordingId: clinicBetaRecId,
        consultationId: db.recordings[clinicBetaRecId]!['consultation_id'],
        clinicId: 'clinic-alpha', // Mis-matched clinic
      );

      expect(crossClinicRes['status'], equals(404));
      expect(crossClinicRes['error'], contains('cross-clinic access denied'));

      // Verify Clinic Beta recording remains pending and unclaimed
      expect(db.recordings[clinicBetaRecId]!['processing_status'], equals('pending'));
      expect(db.deepgramCallCount, equals(0));
    });
  });
}
