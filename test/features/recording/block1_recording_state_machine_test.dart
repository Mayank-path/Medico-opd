import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/core/observability/error_taxonomy.dart';
import 'package:medico_opd/features/recording/models/recording_errors.dart';
import 'package:medico_opd/features/recording/models/recording_lifecycle_state.dart';
import 'package:medico_opd/features/recording/models/recording_session_model.dart';
import 'package:medico_opd/features/recording/services/recording_session_store.dart';
import 'package:medico_opd/features/recording/services/recording_state_manager.dart';

void main() {
  group('Block 1 — Canonical Recording State Machine Tests', () {
    test('all 13 canonical states are defined and correctly mapped to/from string', () {
      final expectedStates = [
        'idle',
        'preparing',
        'recording',
        'paused',
        'stopping',
        'recorded',
        'upload_pending',
        'uploading',
        'uploaded',
        'processing',
        'completed',
        'failed',
        'recovery_required',
      ];

      expect(RecordingLifecycleState.values.length, equals(13));

      for (final state in RecordingLifecycleState.values) {
        final canonicalString = state.toCanonicalString();
        expect(expectedStates, contains(canonicalString));
        final roundTrip = RecordingLifecycleState.fromCanonicalString(canonicalString);
        expect(roundTrip, equals(state));
      }
    });

    test('validates terminal and in-flight state properties', () {
      expect(RecordingLifecycleState.completed.isTerminal, isTrue);
      expect(RecordingLifecycleState.failed.isTerminal, isTrue);
      expect(RecordingLifecycleState.idle.isTerminal, isFalse);
      expect(RecordingLifecycleState.recording.isTerminal, isFalse);

      expect(RecordingLifecycleState.idle.isInFlight, isFalse);
      expect(RecordingLifecycleState.completed.isInFlight, isFalse);
      expect(RecordingLifecycleState.failed.isInFlight, isFalse);
      expect(RecordingLifecycleState.recording.isInFlight, isTrue);
      expect(RecordingLifecycleState.paused.isInFlight, isTrue);
      expect(RecordingLifecycleState.stopping.isInFlight, isTrue);
      expect(RecordingLifecycleState.uploading.isInFlight, isTrue);
      expect(RecordingLifecycleState.processing.isInFlight, isTrue);
      expect(RecordingLifecycleState.recoveryRequired.isInFlight, isTrue);
    });

    test('validates all explicit valid state transitions', () {
      // IDLE -> PREPARING
      expect(RecordingLifecycleState.idle.canTransitionTo(RecordingLifecycleState.preparing), isTrue);

      // PREPARING -> RECORDING, FAILED
      expect(RecordingLifecycleState.preparing.canTransitionTo(RecordingLifecycleState.recording), isTrue);
      expect(RecordingLifecycleState.preparing.canTransitionTo(RecordingLifecycleState.failed), isTrue);

      // RECORDING -> PAUSED, STOPPING, RECOVERY_REQUIRED, FAILED
      expect(RecordingLifecycleState.recording.canTransitionTo(RecordingLifecycleState.paused), isTrue);
      expect(RecordingLifecycleState.recording.canTransitionTo(RecordingLifecycleState.stopping), isTrue);
      expect(RecordingLifecycleState.recording.canTransitionTo(RecordingLifecycleState.recoveryRequired), isTrue);
      expect(RecordingLifecycleState.recording.canTransitionTo(RecordingLifecycleState.failed), isTrue);

      // PAUSED -> RECORDING, STOPPING, FAILED
      expect(RecordingLifecycleState.paused.canTransitionTo(RecordingLifecycleState.recording), isTrue);
      expect(RecordingLifecycleState.paused.canTransitionTo(RecordingLifecycleState.stopping), isTrue);
      expect(RecordingLifecycleState.paused.canTransitionTo(RecordingLifecycleState.failed), isTrue);

      // STOPPING -> RECORDED, FAILED, RECOVERY_REQUIRED
      expect(RecordingLifecycleState.stopping.canTransitionTo(RecordingLifecycleState.recorded), isTrue);
      expect(RecordingLifecycleState.stopping.canTransitionTo(RecordingLifecycleState.failed), isTrue);
      expect(RecordingLifecycleState.stopping.canTransitionTo(RecordingLifecycleState.recoveryRequired), isTrue);

      // RECORDED -> UPLOAD_PENDING
      expect(RecordingLifecycleState.recorded.canTransitionTo(RecordingLifecycleState.uploadPending), isTrue);

      // UPLOAD_PENDING -> UPLOADING
      expect(RecordingLifecycleState.uploadPending.canTransitionTo(RecordingLifecycleState.uploading), isTrue);

      // UPLOADING -> UPLOADED, UPLOAD_PENDING, FAILED, RECOVERY_REQUIRED
      expect(RecordingLifecycleState.uploading.canTransitionTo(RecordingLifecycleState.uploaded), isTrue);
      expect(RecordingLifecycleState.uploading.canTransitionTo(RecordingLifecycleState.uploadPending), isTrue);
      expect(RecordingLifecycleState.uploading.canTransitionTo(RecordingLifecycleState.failed), isTrue);
      expect(RecordingLifecycleState.uploading.canTransitionTo(RecordingLifecycleState.recoveryRequired), isTrue);

      // UPLOADED -> PROCESSING
      expect(RecordingLifecycleState.uploaded.canTransitionTo(RecordingLifecycleState.processing), isTrue);

      // PROCESSING -> COMPLETED, FAILED
      expect(RecordingLifecycleState.processing.canTransitionTo(RecordingLifecycleState.completed), isTrue);
      expect(RecordingLifecycleState.processing.canTransitionTo(RecordingLifecycleState.failed), isTrue);

      // FAILED -> RECOVERY_REQUIRED, PREPARING, UPLOAD_PENDING, PROCESSING
      expect(RecordingLifecycleState.failed.canTransitionTo(RecordingLifecycleState.recoveryRequired), isTrue);
      expect(RecordingLifecycleState.failed.canTransitionTo(RecordingLifecycleState.preparing), isTrue);
      expect(RecordingLifecycleState.failed.canTransitionTo(RecordingLifecycleState.uploadPending), isTrue);
      expect(RecordingLifecycleState.failed.canTransitionTo(RecordingLifecycleState.processing), isTrue);

      // RECOVERY_REQUIRED -> PREPARING, RECORDING, RECORDED, UPLOAD_PENDING
      expect(RecordingLifecycleState.recoveryRequired.canTransitionTo(RecordingLifecycleState.preparing), isTrue);
      expect(RecordingLifecycleState.recoveryRequired.canTransitionTo(RecordingLifecycleState.recording), isTrue);
      expect(RecordingLifecycleState.recoveryRequired.canTransitionTo(RecordingLifecycleState.recorded), isTrue);
      expect(RecordingLifecycleState.recoveryRequired.canTransitionTo(RecordingLifecycleState.uploadPending), isTrue);

      // COMPLETED has no outgoing transitions
      expect(RecordingLifecycleState.completed.validNextStates, isEmpty);
    });

    test('deterministic rejection of invalid state transitions', () {
      final invalidPairs = [
        [RecordingLifecycleState.idle, RecordingLifecycleState.uploading],
        [RecordingLifecycleState.idle, RecordingLifecycleState.completed],
        [RecordingLifecycleState.idle, RecordingLifecycleState.recording],
        [RecordingLifecycleState.completed, RecordingLifecycleState.recording],
        [RecordingLifecycleState.completed, RecordingLifecycleState.uploading],
        [RecordingLifecycleState.completed, RecordingLifecycleState.idle],
        [RecordingLifecycleState.recording, RecordingLifecycleState.completed],
        [RecordingLifecycleState.recording, RecordingLifecycleState.uploaded],
        [RecordingLifecycleState.processing, RecordingLifecycleState.recording],
        [RecordingLifecycleState.recorded, RecordingLifecycleState.recording],
      ];

      for (final pair in invalidPairs) {
        final from = pair[0];
        final to = pair[1];
        expect(
          from.canTransitionTo(to),
          isFalse,
          reason: 'Transition from $from to $to must be rejected',
        );
      }
    });
  });

  group('Block 1 — Durable Persistence & Session Store Tests', () {
    late Directory tempDir;
    late RecordingSessionStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('medico_session_store_test_');
      store = RecordingSessionStore(directory: tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('saves, reloads, and preserves full recording session model', () async {
      final now = DateTime.now();
      final session = RecordingSessionModel(
        recordingSessionId: 'sess-001',
        consultationId: 'cons-100',
        clinicId: 'clinic-200',
        doctorId: 'doc-300',
        localFilePath: '/data/recordings/sess-001.m4a',
        remoteObjectPath: 'clinics/clinic-200/consultations/cons-100/sess-001.m4a',
        state: RecordingLifecycleState.recorded,
        createdAt: now,
        startedAt: now.add(const Duration(seconds: 1)),
        stoppedAt: now.add(const Duration(seconds: 181)),
        updatedAt: now.add(const Duration(seconds: 182)),
        durationSeconds: 180,
        bytesWritten: 720000,
        checksum: 'sha256_mock_hash_abc123',
        uploadProgress: 0.0,
        retryCount: 1,
        lastErrorCategory: null,
        lastErrorMessage: null,
        recoveryMetadata: {'interrupted': false},
      );

      // Save to disk
      await store.saveSession(session);

      // Reload from disk
      final loaded = await store.loadSession('sess-001');
      expect(loaded, isNotNull);
      expect(loaded!.recordingSessionId, equals('sess-001'));
      expect(loaded.consultationId, equals('cons-100'));
      expect(loaded.clinicId, equals('clinic-200'));
      expect(loaded.doctorId, equals('doc-300'));
      expect(loaded.localFilePath, equals('/data/recordings/sess-001.m4a'));
      expect(loaded.remoteObjectPath, equals('clinics/clinic-200/consultations/cons-100/sess-001.m4a'));
      expect(loaded.state, equals(RecordingLifecycleState.recorded));
      expect(loaded.durationSeconds, equals(180));
      expect(loaded.duration, equals(const Duration(seconds: 180)));
      expect(loaded.bytesWritten, equals(720000));
      expect(loaded.checksum, equals('sha256_mock_hash_abc123'));
      expect(loaded.retryCount, equals(1));
      expect(loaded.recoveryMetadata?['interrupted'], isFalse);
    });

    test('persistence is idempotent and safe under repeated saves', () async {
      final now = DateTime.now();
      final session = RecordingSessionModel(
        recordingSessionId: 'sess-idempotent-01',
        consultationId: 'cons-idemp',
        state: RecordingLifecycleState.recording,
        createdAt: now,
        updatedAt: now,
      );

      // Save 3 times in succession
      await store.saveSession(session);
      await store.saveSession(session);
      await store.saveSession(session);

      final loaded = await store.loadSession('sess-idempotent-01');
      expect(loaded, isNotNull);
      expect(loaded!.recordingSessionId, equals('sess-idempotent-01'));
      expect(loaded.state, equals(RecordingLifecycleState.recording));

      // Verify only 1 canonical file exists, zero temp files remaining
      final dir = Directory('${tempDir.path}/recording_sessions');
      final files = dir.listSync();
      expect(files.where((f) => f.path.endsWith('.tmp')), isEmpty);
      expect(files.where((f) => f.path.endsWith('.json')).length, equals(1));
    });

    test('loadAllSessions sorts newest updatedAt first and ignores temp files', () async {
      final t1 = DateTime.now().subtract(const Duration(minutes: 5));
      final t2 = DateTime.now().subtract(const Duration(minutes: 2));
      final t3 = DateTime.now();

      final s1 = RecordingSessionModel(
        recordingSessionId: 'sess-old',
        consultationId: 'cons-1',
        state: RecordingLifecycleState.completed,
        createdAt: t1,
        updatedAt: t1,
      );
      final s2 = RecordingSessionModel(
        recordingSessionId: 'sess-mid',
        consultationId: 'cons-2',
        state: RecordingLifecycleState.recorded,
        createdAt: t2,
        updatedAt: t2,
      );
      final s3 = RecordingSessionModel(
        recordingSessionId: 'sess-new',
        consultationId: 'cons-3',
        state: RecordingLifecycleState.recording,
        createdAt: t3,
        updatedAt: t3,
      );

      await store.saveSession(s1);
      await store.saveSession(s2);
      await store.saveSession(s3);

      final all = await store.loadAllSessions();
      expect(all.length, equals(3));
      // Newest first
      expect(all[0].recordingSessionId, equals('sess-new'));
      expect(all[1].recordingSessionId, equals('sess-mid'));
      expect(all[2].recordingSessionId, equals('sess-old'));
    });

    test('deleteSession removes session file cleanly', () async {
      final session = RecordingSessionModel(
        recordingSessionId: 'sess-to-delete',
        consultationId: 'cons-del',
        state: RecordingLifecycleState.idle,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await store.saveSession(session);
      expect(await store.loadSession('sess-to-delete'), isNotNull);

      await store.deleteSession('sess-to-delete');
      expect(await store.loadSession('sess-to-delete'), isNull);
    });
  });

  group('Block 1 — State Manager Execution & Concurrency Tests', () {
    late Directory tempDir;
    late RecordingSessionStore store;
    late RecordingStateManager manager;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('medico_manager_test_');
      store = RecordingSessionStore(directory: tempDir);
      manager = RecordingStateManager(store: store);
    });

    tearDown(() async {
      await manager.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('creates session with stable ID and transitions through full lifecycle', () async {
      final session = await manager.createSession(
        consultationId: 'cons-flow-100',
        clinicId: 'clinic-1',
        doctorId: 'doc-1',
      );

      expect(session.state, equals(RecordingLifecycleState.idle));
      expect(session.recordingSessionId, isNotEmpty);
      final stableId = session.recordingSessionId;

      // 1. Prepare
      final preparing = await manager.prepareRecording(stableId);
      expect(preparing.state, equals(RecordingLifecycleState.preparing));
      expect(preparing.recordingSessionId, equals(stableId));

      // 2. Start
      final recording = await manager.startRecording(stableId, localFilePath: '/tmp/test.m4a');
      expect(recording.state, equals(RecordingLifecycleState.recording));
      expect(recording.localFilePath, equals('/tmp/test.m4a'));
      expect(recording.startedAt, isNotNull);

      // 3. Pause
      final paused = await manager.pauseRecording(stableId);
      expect(paused.state, equals(RecordingLifecycleState.paused));
      expect(paused.pausedAt, isNotNull);

      // 4. Resume
      final resumed = await manager.resumeRecording(stableId);
      expect(resumed.state, equals(RecordingLifecycleState.recording));

      // 5. Stop
      final stopping = await manager.stopRecording(stableId, durationSeconds: 45);
      expect(stopping.state, equals(RecordingLifecycleState.stopping));
      expect(stopping.durationSeconds, equals(45));

      // 6. Recorded
      final recorded = await manager.markRecorded(stableId, checksum: 'sha256_dummy');
      expect(recorded.state, equals(RecordingLifecycleState.recorded));
      expect(recorded.checksum, equals('sha256_dummy'));

      // 7. Upload Pending
      final uploadPending = await manager.markUploadPending(stableId);
      expect(uploadPending.state, equals(RecordingLifecycleState.uploadPending));

      // 8. Uploading
      final uploading = await manager.markUploading(stableId, uploadProgress: 0.5);
      expect(uploading.state, equals(RecordingLifecycleState.uploading));
      expect(uploading.uploadProgress, equals(0.5));

      // 9. Uploaded
      final uploaded = await manager.markUploaded(stableId, remoteObjectPath: 'clinics/c1/rec.m4a');
      expect(uploaded.state, equals(RecordingLifecycleState.uploaded));
      expect(uploaded.remoteObjectPath, equals('clinics/c1/rec.m4a'));

      // 10. Processing
      final processing = await manager.markProcessing(stableId);
      expect(processing.state, equals(RecordingLifecycleState.processing));

      // 11. Completed
      final completed = await manager.markCompleted(stableId);
      expect(completed.state, equals(RecordingLifecycleState.completed));
      expect(completed.state.isTerminal, isTrue);

      // Verify identity stability across entire flow
      expect(completed.recordingSessionId, equals(stableId));
    });

    test('rejects invalid state transition with typed RecordingTransitionException', () async {
      final session = await manager.createSession(consultationId: 'cons-invalid-01');

      // Attempt IDLE -> UPLOADING directly
      expect(
        () async => await manager.transitionTo(session.recordingSessionId, RecordingLifecycleState.uploading),
        throwsA(
          isA<RecordingTransitionException>()
              .having((e) => e.fromState, 'fromState', 'idle')
              .having((e) => e.toState, 'toState', 'uploading')
              .having((e) => e.errorCode, 'errorCode', AppErrorCode.conflictError),
        ),
      );
    });

    test('concurrency guard: prevents multiple active sessions for same consultation', () async {
      // 1. Create first session
      final session1 = await manager.createSession(consultationId: 'cons-conflict-99');
      await manager.prepareRecording(session1.recordingSessionId);
      await manager.startRecording(session1.recordingSessionId, localFilePath: '/tmp/audio1.m4a');

      // 2. Attempt to create second session for same consultation while first is active
      expect(
        () async => await manager.createSession(consultationId: 'cons-conflict-99'),
        throwsA(
          isA<RecordingConcurrencyException>()
              .having((e) => e.consultationId, 'consultationId', 'cons-conflict-99')
              .having((e) => e.activeSessionId, 'activeSessionId', session1.recordingSessionId)
              .having((e) => e.errorCode, 'errorCode', AppErrorCode.recordingAlreadyProcessing),
        ),
      );

      // 3. Different consultation can start simultaneously
      final session2 = await manager.createSession(consultationId: 'cons-other-clinic-1');
      expect(session2.consultationId, equals('cons-other-clinic-1'));

      // 4. Once session 1 completes, a new session for cons-conflict-99 is allowed
      await manager.stopRecording(session1.recordingSessionId);
      await manager.markRecorded(session1.recordingSessionId, checksum: 'sha');
      await manager.markUploadPending(session1.recordingSessionId);
      await manager.markUploading(session1.recordingSessionId);
      await manager.markUploaded(session1.recordingSessionId, remoteObjectPath: 'path');
      await manager.markProcessing(session1.recordingSessionId);
      await manager.markCompleted(session1.recordingSessionId);

      // New session now permitted
      final session3 = await manager.createSession(consultationId: 'cons-conflict-99');
      expect(session3.recordingSessionId, isNot(equals(session1.recordingSessionId)));
    });

    test('idempotency: calling pause, resume, stop repeatedly is safe', () async {
      final session = await manager.createSession(consultationId: 'cons-idemp-cycle');
      await manager.prepareRecording(session.recordingSessionId);
      await manager.startRecording(session.recordingSessionId, localFilePath: '/tmp/idemp.m4a');

      // Repeated pause
      final p1 = await manager.pauseRecording(session.recordingSessionId);
      final p2 = await manager.pauseRecording(session.recordingSessionId);
      expect(p1.state, equals(RecordingLifecycleState.paused));
      expect(p2.state, equals(RecordingLifecycleState.paused));

      // Repeated resume
      final r1 = await manager.resumeRecording(session.recordingSessionId);
      final r2 = await manager.resumeRecording(session.recordingSessionId);
      expect(r1.state, equals(RecordingLifecycleState.recording));
      expect(r2.state, equals(RecordingLifecycleState.recording));

      // Repeated stop
      final s1 = await manager.stopRecording(session.recordingSessionId);
      final s2 = await manager.stopRecording(session.recordingSessionId);
      expect(s1.state, equals(RecordingLifecycleState.stopping));
      expect(s2.state, equals(RecordingLifecycleState.stopping));
    });
  });

  group('Block 1 — Recovery Discovery & Resilience Tests', () {
    late Directory tempDir;
    late RecordingSessionStore store;
    late RecordingStateManager manager;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('medico_recovery_test_');
      store = RecordingSessionStore(directory: tempDir);
      manager = RecordingStateManager(store: store);
    });

    tearDown(() async {
      await manager.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('discoverRecoverableSessions returns empty when no unfinished sessions exist', () async {
      final list = await manager.discoverRecoverableSessions();
      expect(list, isEmpty);
    });

    test('discoverRecoverableSessions classifies interrupted in-flight session with local file as recovery_required', () async {
      final audioFile = File('${tempDir.path}/valid_audio.m4a');
      await audioFile.writeAsString('DUMMY_AUDIO_BYTES');

      // Create session simulating app crash while in RECORDING state
      final session = RecordingSessionModel(
        recordingSessionId: 'sess-crash-01',
        consultationId: 'cons-crashed',
        localFilePath: audioFile.path,
        state: RecordingLifecycleState.recording,
        createdAt: DateTime.now().subtract(const Duration(minutes: 10)),
        startedAt: DateTime.now().subtract(const Duration(minutes: 9)),
        updatedAt: DateTime.now().subtract(const Duration(minutes: 9)),
      );
      await store.saveSession(session);

      // Run recovery discovery
      final recoverable = await manager.discoverRecoverableSessions();
      expect(recoverable.length, equals(1));
      expect(recoverable[0].recordingSessionId, equals('sess-crash-01'));
      expect(recoverable[0].state, equals(RecordingLifecycleState.recoveryRequired));
      expect(recoverable[0].recoveryMetadata?['interruptedFromState'], equals('recording'));

      // Verify persisted session updated to recoveryRequired
      final persisted = await store.loadSession('sess-crash-01');
      expect(persisted!.state, equals(RecordingLifecycleState.recoveryRequired));
    });

    test('discoverRecoverableSessions classifies session as failed when local file is missing', () async {
      final missingFilePath = '${tempDir.path}/non_existent_audio.m4a';

      // Create session referencing missing file
      final session = RecordingSessionModel(
        recordingSessionId: 'sess-missing-file',
        consultationId: 'cons-missing',
        localFilePath: missingFilePath,
        state: RecordingLifecycleState.recording,
        createdAt: DateTime.now().subtract(const Duration(minutes: 10)),
        updatedAt: DateTime.now().subtract(const Duration(minutes: 9)),
      );
      await store.saveSession(session);

      final recoverable = await manager.discoverRecoverableSessions();
      expect(recoverable.length, equals(1));
      expect(recoverable[0].recordingSessionId, equals('sess-missing-file'));
      expect(recoverable[0].state, equals(RecordingLifecycleState.failed));
      expect(recoverable[0].lastErrorCategory, equals(AppErrorCode.storageObjectNotFound.code));
    });

    test('recoverSession preserves stable session ID and transitions to valid resume state', () async {
      final audioFile = File('${tempDir.path}/resume_audio.m4a');
      await audioFile.writeAsString('AUDIO_FOR_RESUME');

      final session = RecordingSessionModel(
        recordingSessionId: 'sess-preserve-id',
        consultationId: 'cons-resume',
        localFilePath: audioFile.path,
        state: RecordingLifecycleState.recoveryRequired,
        createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
        updatedAt: DateTime.now().subtract(const Duration(minutes: 5)),
      );
      await store.saveSession(session);

      // Execute explicit recovery to RECORDED state
      final recovered = await manager.recoverSession(
        'sess-preserve-id',
        resumeTargetState: RecordingLifecycleState.recorded,
      );

      // Session ID must remain strictly identical
      expect(recovered.recordingSessionId, equals('sess-preserve-id'));
      expect(recovered.state, equals(RecordingLifecycleState.recorded));
    });

    test('recoverSession throws RecordingRecoveryException if called on non-recovery session', () async {
      final session = await manager.createSession(consultationId: 'cons-not-recovery');

      expect(
        () async => await manager.recoverSession(
          session.recordingSessionId,
          resumeTargetState: RecordingLifecycleState.recording,
        ),
        throwsA(isA<RecordingRecoveryException>()),
      );
    });

    test('completed session is ignored by recovery discovery', () async {
      final session = RecordingSessionModel(
        recordingSessionId: 'sess-completed',
        consultationId: 'cons-done',
        state: RecordingLifecycleState.completed,
        createdAt: DateTime.now().subtract(const Duration(days: 1)),
        updatedAt: DateTime.now().subtract(const Duration(days: 1)),
      );
      await store.saveSession(session);

      final list = await manager.discoverRecoverableSessions();
      expect(list, isEmpty);
    });
  });

  group('Block 1 — Error Model & Privacy-Safe Formatting Tests', () {
    test('exceptions do not expose tokens, DB credentials or secrets', () {
      final err1 = RecordingTransitionException(fromState: 'idle', toState: 'completed');
      expect(err1.message, isNot(contains('postgres')));
      expect(err1.message, isNot(contains('supabase')));
      expect(err1.message, isNot(contains('jwt')));

      final err2 = RecordingFileMissingException('/app/data/audio.m4a');
      expect(err2.message, isNot(contains('/app/data'))); // User message is sanitized
      expect(err2.technicalDetails, contains('/app/data/audio.m4a')); // Technical details have path

      final err3 = RecordingConcurrencyException(
        consultationId: 'cons-1',
        activeSessionId: 'sess-1',
      );
      expect(err3.errorCode, equals(AppErrorCode.recordingAlreadyProcessing));
    });
  });

  group('Block 1 — End-to-End Real Lifecycle & Process Restart Simulation', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('block1_e2e_restart_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Full End-to-End: Start -> Record -> Simulated Kill -> Recreate -> Recover -> Complete with stable UUID', () async {
      final store1 = RecordingSessionStore(directory: tempDir);
      final manager1 = RecordingStateManager(store: store1);

      // 1. Create real audio file on disk
      final audioFile = File('${tempDir.path}/consultation_audio_real.m4a');
      await audioFile.writeAsString('AAC_AUDIO_DATA_VALID_16KHZ');
      expect(audioFile.existsSync(), isTrue);

      // 2. Start session and transition to RECORDING
      final session = await manager1.createSession(
        consultationId: 'cons-prod-1001',
        clinicId: 'clinic-alpha',
        doctorId: 'doc-rajesh',
      );
      final stableSessionId = session.recordingSessionId;
      expect(stableSessionId, isNotEmpty);

      await manager1.prepareRecording(stableSessionId);
      await manager1.startRecording(stableSessionId, localFilePath: audioFile.path);

      final persistedBeforeKill = await store1.loadSession(stableSessionId);
      expect(persistedBeforeKill, isNotNull);
      expect(persistedBeforeKill!.state, equals(RecordingLifecycleState.recording));
      expect(persistedBeforeKill.localFilePath, equals(audioFile.path));

      // 3. Simulate process termination / restart:
      // Dispose old manager/store instances completely
      await manager1.dispose();

      // 4. Fresh startup: recreate completely new store & manager pointing to the same disk directory
      final store2 = RecordingSessionStore(directory: tempDir);
      final manager2 = RecordingStateManager(store: store2);

      // 5. Discover unfinished sessions on app launch
      final recoverableSessions = await manager2.discoverRecoverableSessions();
      expect(recoverableSessions.length, equals(1));

      final discovered = recoverableSessions.first;
      // Stable identity verified: UUID preserved exactly
      expect(discovered.recordingSessionId, equals(stableSessionId));
      expect(discovered.consultationId, equals('cons-prod-1001'));
      // File existence verified
      expect(discovered.localFilePath, equals(audioFile.path));
      expect(File(discovered.localFilePath!).existsSync(), isTrue);
      // State classified as recovery_required
      expect(discovered.state, equals(RecordingLifecycleState.recoveryRequired));

      // 6. Explicit user/application recovery action
      final recovered = await manager2.recoverSession(
        stableSessionId,
        resumeTargetState: RecordingLifecycleState.recorded,
      );
      expect(recovered.recordingSessionId, equals(stableSessionId));
      expect(recovered.state, equals(RecordingLifecycleState.recorded));

      // 7. Progress through remaining valid lifecycle
      await manager2.markUploadPending(stableSessionId);
      await manager2.markUploading(stableSessionId, uploadProgress: 0.5);
      await manager2.markUploaded(
        stableSessionId,
        remoteObjectPath: 'clinics/clinic-alpha/consultations/cons-prod-1001/$stableSessionId.m4a',
      );
      await manager2.markProcessing(stableSessionId);
      final completed = await manager2.markCompleted(stableSessionId);

      expect(completed.state, equals(RecordingLifecycleState.completed));
      expect(completed.recordingSessionId, equals(stableSessionId));

      await manager2.dispose();
    });

    test('Missing-File Recovery: In-flight session with deleted audio transitions to FAILED with STORAGE_OBJECT_NOT_FOUND', () async {
      final store1 = RecordingSessionStore(directory: tempDir);
      final manager1 = RecordingStateManager(store: store1);

      final nonExistentFilePath = '${tempDir.path}/deleted_by_os_cleaner.m4a';

      // Create session pointing to non-existent file
      final session = await manager1.createSession(
        consultationId: 'cons-missing-file-404',
      );
      await manager1.prepareRecording(session.recordingSessionId);
      await manager1.startRecording(
        session.recordingSessionId,
        localFilePath: nonExistentFilePath,
      );

      // Verify file does not exist
      expect(File(nonExistentFilePath).existsSync(), isFalse);

      // Simulate process restart
      await manager1.dispose();

      final store2 = RecordingSessionStore(directory: tempDir);
      final manager2 = RecordingStateManager(store: store2);

      // Discovery must identify missing file and safely transition to FAILED
      final recoverable = await manager2.discoverRecoverableSessions();
      expect(recoverable.length, equals(1));
      expect(recoverable.first.state, equals(RecordingLifecycleState.failed));
      expect(recoverable.first.lastErrorCategory, equals(AppErrorCode.storageObjectNotFound.code));

      final failedSession = await store2.loadSession(session.recordingSessionId);
      expect(failedSession, isNotNull);
      expect(failedSession!.state, equals(RecordingLifecycleState.failed));
      expect(failedSession.lastErrorCategory, equals(AppErrorCode.storageObjectNotFound.code));

      await manager2.dispose();
    });

    test('Idempotency: calling pause, resume, stop multiple times never corrupts state or duplicate sessions', () async {
      final store = RecordingSessionStore(directory: tempDir);
      final manager = RecordingStateManager(store: store);

      final session = await manager.createSession(consultationId: 'cons-idemp-multi');
      final id = session.recordingSessionId;

      await manager.prepareRecording(id);
      await manager.startRecording(id, localFilePath: '${tempDir.path}/audio.m4a');

      // Pause twice
      final p1 = await manager.pauseRecording(id);
      final p2 = await manager.pauseRecording(id);
      expect(p1.state, equals(RecordingLifecycleState.paused));
      expect(p2.state, equals(RecordingLifecycleState.paused));

      // Resume twice
      final r1 = await manager.resumeRecording(id);
      final r2 = await manager.resumeRecording(id);
      expect(r1.state, equals(RecordingLifecycleState.recording));
      expect(r2.state, equals(RecordingLifecycleState.recording));

      // Stop twice
      final s1 = await manager.stopRecording(id);
      final s2 = await manager.stopRecording(id);
      expect(s1.state, equals(RecordingLifecycleState.stopping));
      expect(s2.state, equals(RecordingLifecycleState.stopping));

      final allSessions = await store.loadAllSessions();
      expect(allSessions.length, equals(1)); // No duplicate sessions created

      await manager.dispose();
    });

    test('Durable State Privacy Verification: Persisted session JSON contains NO patient identifiers or secrets', () async {
      final store = RecordingSessionStore(directory: tempDir);
      final manager = RecordingStateManager(store: store);

      final session = await manager.createSession(
        consultationId: 'cons-privacy-audit',
        clinicId: 'clinic-sec-01',
        doctorId: 'doc-sec-01',
      );

      final sessionFile = File('${tempDir.path}/recording_sessions/${session.recordingSessionId}.json');
      expect(sessionFile.existsSync(), isTrue);

      final jsonContent = await sessionFile.readAsString();

      // Explicit verification: No patientId, no patient names, no UHIDs, no credentials
      expect(jsonContent, isNot(contains('patientId')));
      expect(jsonContent, isNot(contains('patient_id')));
      expect(jsonContent, isNot(contains('uhid')));
      expect(jsonContent, isNot(contains('password')));
      expect(jsonContent, isNot(contains('token')));
      expect(jsonContent, isNot(contains('secret')));

      await manager.dispose();
    });
  });
}
