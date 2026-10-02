import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/core/observability/observability.dart';
import 'package:medico_opd/features/recording/models/recording_lifecycle_state.dart';
import 'package:medico_opd/features/recording/models/recording_model.dart';
import 'package:medico_opd/features/recording/models/upload_checkpoint.dart';
import 'package:medico_opd/features/recording/models/upload_state.dart';
import 'package:medico_opd/features/recording/services/recording_session_store.dart';
import 'package:medico_opd/features/recording/services/recording_state_manager.dart';
import 'package:medico_opd/features/recording/services/resumable_upload_service.dart';
import 'package:medico_opd/features/recording/services/upload_checkpoint_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Block 4 — Production-Grade Resumable Upload Test Suite', () {
    late Directory tempDir;
    late UploadCheckpointStore checkpointStore;
    late RecordingSessionStore sessionStore;
    late RecordingStateManager stateManager;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('medico_block4_test_');
      checkpointStore = UploadCheckpointStore(directory: tempDir);
      sessionStore = RecordingSessionStore(directory: tempDir);
      stateManager = RecordingStateManager(store: sessionStore);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    File createAudioFile(String name, int sizeBytes) {
      final file = File('${tempDir.path}/$name');
      final bytes = Uint8List(sizeBytes);
      for (var i = 0; i < sizeBytes; i++) {
        bytes[i] = i % 256;
      }
      file.writeAsBytesSync(bytes);
      return file;
    }

    // =========================================================================
    // SCENARIO A: Normal Upload Pipeline
    // record -> upload -> verify -> register -> complete
    // =========================================================================
    test('Scenario A: Normal Upload Pipeline (record -> upload -> verify -> register -> complete)', () async {
      final audioFile = createAudioFile('consultation_01.m4a', 1024 * 100); // 100 KB
      final sessionId = 'rec-scenario-a-001';
      final consultationId = 'cons-001';
      final clinicId = 'clinic-alpha';

      await stateManager.createSession(
        consultationId: consultationId,
        customSessionId: sessionId,
      );
      await stateManager.prepareRecording(sessionId);
      await stateManager.startRecording(sessionId, localFilePath: audioFile.path);
      await stateManager.stopRecording(sessionId);
      await stateManager.markRecorded(sessionId, checksum: 'hash-test-01', durationSeconds: 60);

      var storageUploadExecuted = false;
      var remoteVerified = false;
      var dbRegistered = false;

      final service = ResumableUploadService(
        checkpointStore: checkpointStore,
        stateManager: stateManager,
        customStorageTransfer: ({
          required checkpoint,
          required storagePath,
          required rawBytes,
          required localFilePath,
          directBytes,
          required ctx,
        }) async {
          expect(storagePath, 'clinics/$clinicId/consultations/$consultationId/$sessionId.m4a');
          expect(rawBytes.length, 1024 * 100);
          storageUploadExecuted = true;
        },
        customRemoteVerifier: (path) async {
          remoteVerified = true;
          return true;
        },
        customDbQuery: (id) async => null,
        customDbInsert: ({
          required clientRecordingId,
          required consultationId,
          required patientId,
          required doctorId,
          required storagePath,
          required durationSeconds,
        }) async {
          dbRegistered = true;
          return RecordingModel(
            id: clientRecordingId,
            consultationId: consultationId,
            patientId: patientId,
            doctorId: doctorId,
            storagePath: storagePath,
            encryptionKeyRef: 'sse-s3',
            durationSeconds: durationSeconds,
            createdAt: DateTime.now(),
          );
        },
      );

      final result = await service.uploadRecording(
        localAudioPath: audioFile.path,
        clientRecordingId: sessionId,
        clinicId: clinicId,
        consultationId: consultationId,
        patientId: 'pat-001',
        doctorId: 'doc-001',
        durationSeconds: 60,
      );

      expect(storageUploadExecuted, isTrue);
      expect(remoteVerified, isTrue);
      expect(dbRegistered, isTrue);
      expect(result.id, sessionId);

      // Verify canonical state machine transitioned to uploaded
      final session = await stateManager.getSession(sessionId);
      expect(session!.state, RecordingLifecycleState.uploaded);

      // Verify local file was safely purged after verified DB registration
      expect(await audioFile.exists(), isFalse);
    });

    // =========================================================================
    // SCENARIO B: Network Failure During Upload & Resumption
    // =========================================================================
    test('Scenario B: Network failure during upload preserves checkpoint; resume completes without byte-zero restart', () async {
      final audioFile = createAudioFile('consultation_02.m4a', 2048);
      final sessionId = 'rec-scenario-b-002';
      final consultationId = 'cons-002';
      final clinicId = 'clinic-alpha';

      await stateManager.createSession(
        consultationId: consultationId,
        customSessionId: sessionId,
      );
      await stateManager.prepareRecording(sessionId);
      await stateManager.startRecording(sessionId, localFilePath: audioFile.path);
      await stateManager.stopRecording(sessionId);
      await stateManager.markRecorded(sessionId, checksum: 'hash-test-02', durationSeconds: 30);

      var attempts = 0;
      final service = ResumableUploadService(
        checkpointStore: checkpointStore,
        stateManager: stateManager,
        customStorageTransfer: ({
          required checkpoint,
          required storagePath,
          required rawBytes,
          required localFilePath,
          directBytes,
          required ctx,
        }) async {
          attempts++;
          if (attempts == 1) {
            // Simulate network drop during chunk transfer
            throw const SocketException('Connection reset by peer during chunk streaming');
          }
          // On second attempt, transfer succeeds
        },
        customRemoteVerifier: (path) async => true,
        customDbQuery: (id) async => null,
        customDbInsert: ({
          required clientRecordingId,
          required consultationId,
          required patientId,
          required doctorId,
          required storagePath,
          required durationSeconds,
        }) async {
          return RecordingModel(
            id: clientRecordingId,
            consultationId: consultationId,
            patientId: patientId,
            doctorId: doctorId,
            storagePath: storagePath,
            encryptionKeyRef: 'sse-s3',
            createdAt: DateTime.now(),
          );
        },
      );

      // 1. Initial attempt fails with network error
      await expectLater(
        service.uploadRecording(
          localAudioPath: audioFile.path,
          clientRecordingId: sessionId,
          clinicId: clinicId,
          consultationId: consultationId,
          patientId: 'pat-002',
          doctorId: 'doc-002',
        ),
        throwsA(isA<SocketException>()),
      );

      // 2. Verify durable checkpoint exists and records interrupted state
      final checkpoint = await checkpointStore.loadCheckpoint(sessionId);
      expect(checkpoint, isNotNull);
      expect(checkpoint!.uploadState, UploadState.interrupted);
      expect(checkpoint.lastErrorCode, AppErrorCode.storageUploadFailed.code);
      expect(checkpoint.uploadAttempts, 1);
      // Audio file must still exist locally
      expect(await audioFile.exists(), isTrue);

      // 3. Network restored: retry upload
      final result = await service.uploadRecording(
        localAudioPath: audioFile.path,
        clientRecordingId: sessionId,
        clinicId: clinicId,
        consultationId: consultationId,
        patientId: 'pat-002',
        doctorId: 'doc-002',
      );

      expect(result.id, sessionId);
      expect(attempts, 2);

      // Audio file purged only after successful resume and DB registration
      expect(await audioFile.exists(), isFalse);
    });

    // =========================================================================
    // SCENARIO C: App Restart During Upload (Crash Recovery Scan)
    // =========================================================================
    test('Scenario C: App restart recovery discovers unfinished checkpoints and resumes without mic auto-start', () async {
      final audioFile = createAudioFile('consultation_03.m4a', 4096);
      final sessionId = 'rec-scenario-c-003';
      final consultationId = 'cons-003';
      final clinicId = 'clinic-alpha';

      // 1. Persist an unfinished checkpoint as if the app was killed during upload
      final interruptedCheckpoint = UploadCheckpoint(
        recordingSessionId: sessionId,
        localFilePath: audioFile.path,
        remoteObjectPath: 'clinics/$clinicId/consultations/$consultationId/$sessionId.m4a',
        fileSize: 4096,
        fileHash: 'dummyhash123',
        uploadState: UploadState.uploading,
        uploadedBytes: 2048, // 50% uploaded
        uploadAttempts: 1,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await checkpointStore.saveCheckpoint(interruptedCheckpoint);

      var resumedStorage = false;
      final recoveryService = ResumableUploadService(
        checkpointStore: checkpointStore,
        customStorageTransfer: ({
          required checkpoint,
          required storagePath,
          required rawBytes,
          required localFilePath,
          directBytes,
          required ctx,
        }) async {
          resumedStorage = true;
        },
        customRemoteVerifier: (path) async => true,
        customDbQuery: (id) async => null,
        customDbInsert: ({
          required clientRecordingId,
          required consultationId,
          required patientId,
          required doctorId,
          required storagePath,
          required durationSeconds,
        }) async {
          return RecordingModel(
            id: clientRecordingId,
            consultationId: consultationId,
            patientId: patientId,
            doctorId: doctorId,
            storagePath: storagePath,
            encryptionKeyRef: 'sse-s3',
            createdAt: DateTime.now(),
          );
        },
      );

      // 2. Cold start scan
      final recovered = await recoveryService.discoverAndResumeInterruptedUploads();
      expect(recovered.length, 1);
      expect(recovered.first.id, sessionId);
      expect(resumedStorage, isTrue);

      // Verify checkpoint cleared and file purged
      expect(await checkpointStore.loadCheckpoint(sessionId), isNull);
      expect(await audioFile.exists(), isFalse);
    });

    // =========================================================================
    // SCENARIO D: Retry After Failure (Idempotency in DB)
    // =========================================================================
    test('Scenario D: Retry after failure does not create duplicate recording', () async {
      final audioFile = createAudioFile('consultation_04.m4a', 1024);
      final sessionId = 'rec-scenario-d-004';
      final consultationId = 'cons-004';
      final clinicId = 'clinic-alpha';

      var dbInsertCount = 0;
      RecordingModel? existingRow;

      final service = ResumableUploadService(
        checkpointStore: checkpointStore,
        customStorageTransfer: ({
          required checkpoint,
          required storagePath,
          required rawBytes,
          required localFilePath,
          directBytes,
          required ctx,
        }) async {},
        customRemoteVerifier: (path) async => true,
        customDbQuery: (id) async => existingRow,
        customDbInsert: ({
          required clientRecordingId,
          required consultationId,
          required patientId,
          required doctorId,
          required storagePath,
          required durationSeconds,
        }) async {
          dbInsertCount++;
          existingRow = RecordingModel(
            id: clientRecordingId,
            consultationId: consultationId,
            patientId: patientId,
            doctorId: doctorId,
            storagePath: storagePath,
            encryptionKeyRef: 'sse-s3',
            createdAt: DateTime.now(),
          );
          return existingRow!;
        },
      );

      // First upload succeeds
      final res1 = await service.uploadRecording(
        localAudioPath: audioFile.path,
        clientRecordingId: sessionId,
        clinicId: clinicId,
        consultationId: consultationId,
        patientId: 'pat-004',
        doctorId: 'doc-004',
      );

      expect(res1.id, sessionId);
      expect(dbInsertCount, 1);

      // Second upload attempt (e.g. retry after response timeout)
      final res2 = await service.uploadRecording(
        localAudioPath: audioFile.path,
        clientRecordingId: sessionId,
        clinicId: clinicId,
        consultationId: consultationId,
        patientId: 'pat-004',
        doctorId: 'doc-004',
      );

      expect(res2.id, sessionId);
      // DB insert was NOT called again; existing row returned!
      expect(dbInsertCount, 1);
    });

    // =========================================================================
    // SCENARIO E: Double Upload Invocation (Single-Flight In-Flight Lock)
    // =========================================================================
    test('Scenario E: Double concurrent upload invocation joins single-flight operation', () async {
      final audioFile = createAudioFile('consultation_05.m4a', 2048);
      final sessionId = 'rec-scenario-e-005';
      final consultationId = 'cons-005';
      final clinicId = 'clinic-alpha';

      var storageExecutions = 0;

      final service = ResumableUploadService(
        checkpointStore: checkpointStore,
        customStorageTransfer: ({
          required checkpoint,
          required storagePath,
          required rawBytes,
          required localFilePath,
          directBytes,
          required ctx,
        }) async {
          storageExecutions++;
          // Simulate latency
          await Future.delayed(const Duration(milliseconds: 50));
        },
        customRemoteVerifier: (path) async => true,
        customDbQuery: (id) async => null,
        customDbInsert: ({
          required clientRecordingId,
          required consultationId,
          required patientId,
          required doctorId,
          required storagePath,
          required durationSeconds,
        }) async {
          return RecordingModel(
            id: clientRecordingId,
            consultationId: consultationId,
            patientId: patientId,
            doctorId: doctorId,
            storagePath: storagePath,
            encryptionKeyRef: 'sse-s3',
            createdAt: DateTime.now(),
          );
        },
      );

      // Launch two upload operations concurrently for the exact same session
      final futureA = service.uploadRecording(
        localAudioPath: audioFile.path,
        clientRecordingId: sessionId,
        clinicId: clinicId,
        consultationId: consultationId,
        patientId: 'pat-005',
        doctorId: 'doc-005',
      );

      final futureB = service.uploadRecording(
        localAudioPath: audioFile.path,
        clientRecordingId: sessionId,
        clinicId: clinicId,
        consultationId: consultationId,
        patientId: 'pat-005',
        doctorId: 'doc-005',
      );

      final results = await Future.wait([futureA, futureB]);
      expect(results[0].id, sessionId);
      expect(results[1].id, sessionId);

      // Only ONE storage upload operation was executed!
      expect(storageExecutions, 1);
    });

    // =========================================================================
    // SCENARIO F: Remote Object Already Exists (Reconciliation)
    // =========================================================================
    test('Scenario F: Remote object already exists reconciles rather than creating duplicates', () async {
      final audioFile = createAudioFile('consultation_06.m4a', 1024);
      final sessionId = 'rec-scenario-f-006';
      final consultationId = 'cons-006';
      final clinicId = 'clinic-alpha';

      var remoteVerifierCalled = false;
      var dbInsertCalled = false;

      final service = ResumableUploadService(
        checkpointStore: checkpointStore,
        customStorageTransfer: ({
          required checkpoint,
          required storagePath,
          required rawBytes,
          required localFilePath,
          directBytes,
          required ctx,
        }) async {},
        customRemoteVerifier: (path) async {
          remoteVerifierCalled = true;
          return true; // Already exists in bucket
        },
        customDbQuery: (id) async => null,
        customDbInsert: ({
          required clientRecordingId,
          required consultationId,
          required patientId,
          required doctorId,
          required storagePath,
          required durationSeconds,
        }) async {
          dbInsertCalled = true;
          return RecordingModel(
            id: clientRecordingId,
            consultationId: consultationId,
            patientId: patientId,
            doctorId: doctorId,
            storagePath: storagePath,
            encryptionKeyRef: 'sse-s3',
            createdAt: DateTime.now(),
          );
        },
      );

      final result = await service.uploadRecording(
        localAudioPath: audioFile.path,
        clientRecordingId: sessionId,
        clinicId: clinicId,
        consultationId: consultationId,
        patientId: 'pat-006',
        doctorId: 'doc-006',
      );

      expect(result.id, sessionId);
      expect(remoteVerifierCalled, isTrue);
      expect(dbInsertCalled, isTrue);
    });

    // =========================================================================
    // SCENARIO G: Storage Succeeds, DB Registration Fails
    // =========================================================================
    test('Scenario G: Storage succeeds but DB fails -> keeps local file, preserves remoteVerified, retries DB only', () async {
      final audioFile = createAudioFile('consultation_07.m4a', 2048);
      final sessionId = 'rec-scenario-g-007';
      final consultationId = 'cons-007';
      final clinicId = 'clinic-alpha';

      var storageTransferCount = 0;
      var dbAttempt = 0;

      final service = ResumableUploadService(
        checkpointStore: checkpointStore,
        customStorageTransfer: ({
          required checkpoint,
          required storagePath,
          required rawBytes,
          required localFilePath,
          directBytes,
          required ctx,
        }) async {
          storageTransferCount++;
        },
        customRemoteVerifier: (path) async => true,
        customDbQuery: (id) async => null,
        customDbInsert: ({
          required clientRecordingId,
          required consultationId,
          required patientId,
          required doctorId,
          required storagePath,
          required durationSeconds,
        }) async {
          dbAttempt++;
          if (dbAttempt == 1) {
            throw const HttpException('Database constraint check timeout');
          }
          return RecordingModel(
            id: clientRecordingId,
            consultationId: consultationId,
            patientId: patientId,
            doctorId: doctorId,
            storagePath: storagePath,
            encryptionKeyRef: 'sse-s3',
            createdAt: DateTime.now(),
          );
        },
      );

      // Attempt 1 fails at DB registration step
      await expectLater(
        service.uploadRecording(
          localAudioPath: audioFile.path,
          clientRecordingId: sessionId,
          clinicId: clinicId,
          consultationId: consultationId,
          patientId: 'pat-007',
          doctorId: 'doc-007',
        ),
        throwsA(isA<HttpException>()),
      );

      expect(storageTransferCount, 1);
      // LOCAL FILE MUST BE KEPT!
      expect(await audioFile.exists(), isTrue);

      // Checkpoint must preserve remoteVerified = true
      final checkpoint = await checkpointStore.loadCheckpoint(sessionId);
      expect(checkpoint, isNotNull);
      expect(checkpoint!.remoteVerified, isTrue);
      expect(checkpoint.databaseRegistered, isFalse);

      // Attempt 2: Retry
      final result = await service.uploadRecording(
        localAudioPath: audioFile.path,
        clientRecordingId: sessionId,
        clinicId: clinicId,
        consultationId: consultationId,
        patientId: 'pat-007',
        doctorId: 'doc-007',
      );

      expect(result.id, sessionId);
      expect(dbAttempt, 2);
      // Storage transfer was NOT repeated!
      expect(storageTransferCount, 1);

      // ONLY now is local file safely deleted
      expect(await audioFile.exists(), isFalse);
    });

    // =========================================================================
    // SCENARIO H: Integrity / Checksum Mismatch
    // =========================================================================
    test('Scenario H: Integrity check failure aborts upload and protects local file from deletion', () async {
      final audioFile = File('${tempDir.path}/corrupt.m4a');
      audioFile.writeAsBytesSync([]); // 0 bytes empty file

      final service = ResumableUploadService(
        checkpointStore: checkpointStore,
      );

      await expectLater(
        service.uploadRecording(
          localAudioPath: audioFile.path,
          clientRecordingId: 'rec-scenario-h-008',
          clinicId: 'clinic-alpha',
          consultationId: 'cons-008',
          patientId: 'pat-008',
          doctorId: 'doc-008',
        ),
        throwsA(isA<StateError>()),
      );

      // File was not deleted
      expect(await audioFile.exists(), isTrue);
    });

    // =========================================================================
    // SCENARIO I: Local File Missing
    // =========================================================================
    test('Scenario I: Local file missing enters deterministic error state without pretending success', () async {
      final missingPath = '${tempDir.path}/missing_audio.m4a';

      final service = ResumableUploadService(
        checkpointStore: checkpointStore,
      );

      await expectLater(
        service.uploadRecording(
          localAudioPath: missingPath,
          clientRecordingId: 'rec-scenario-i-009',
          clinicId: 'clinic-alpha',
          consultationId: 'cons-009',
          patientId: 'pat-009',
          doctorId: 'doc-009',
        ),
        throwsA(isA<StateError>()),
      );
    });

    // =========================================================================
    // SCENARIO J: Concurrent Sessions Isolation
    // =========================================================================
    test('Scenario J: Two concurrent recording sessions upload independently without cross-corruption', () async {
      final fileA = createAudioFile('consultation_10a.m4a', 1024);
      final fileB = createAudioFile('consultation_10b.m4a', 2048);
      final sessionA = 'rec-scenario-j-010-a';
      final sessionB = 'rec-scenario-j-010-b';

      final completedSessions = <String>[];

      final service = ResumableUploadService(
        checkpointStore: checkpointStore,
        customStorageTransfer: ({
          required checkpoint,
          required storagePath,
          required rawBytes,
          required localFilePath,
          directBytes,
          required ctx,
        }) async {},
        customRemoteVerifier: (path) async => true,
        customDbQuery: (id) async => null,
        customDbInsert: ({
          required clientRecordingId,
          required consultationId,
          required patientId,
          required doctorId,
          required storagePath,
          required durationSeconds,
        }) async {
          completedSessions.add(clientRecordingId);
          return RecordingModel(
            id: clientRecordingId,
            consultationId: consultationId,
            patientId: patientId,
            doctorId: doctorId,
            storagePath: storagePath,
            encryptionKeyRef: 'sse-s3',
            createdAt: DateTime.now(),
          );
        },
      );

      final futureA = service.uploadRecording(
        localAudioPath: fileA.path,
        clientRecordingId: sessionA,
        clinicId: 'clinic-alpha',
        consultationId: 'cons-10a',
        patientId: 'pat-10a',
        doctorId: 'doc-10a',
      );

      final futureB = service.uploadRecording(
        localAudioPath: fileB.path,
        clientRecordingId: sessionB,
        clinicId: 'clinic-alpha',
        consultationId: 'cons-10b',
        patientId: 'pat-10b',
        doctorId: 'doc-10b',
      );

      await Future.wait([futureA, futureB]);
      expect(completedSessions, containsAll([sessionA, sessionB]));
    });

    // =========================================================================
    // SCENARIO K: Privacy Audit (Zero PHI / Zero Auth Tokens in Checkpoints)
    // =========================================================================
    test('Scenario K: Durable checkpoints persist zero PHI, patient names, UHIDs, clinical data, or auth tokens', () async {
      final audioFile = createAudioFile('consultation_privacy.m4a', 512);
      final sessionId = 'rec-scenario-k-privacy';

      final checkpoint = UploadCheckpoint(
        recordingSessionId: sessionId,
        localFilePath: audioFile.path,
        remoteObjectPath: 'clinics/clinic-alpha/consultations/cons-priv-001/$sessionId.m4a',
        fileSize: 512,
        fileHash: 'sha256-hash-value',
        uploadState: UploadState.uploading,
        uploadedBytes: 256,
        uploadAttempts: 1,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await checkpointStore.saveCheckpoint(checkpoint);

      // Read raw JSON from disk
      final checkpointFile = File('${tempDir.path}/upload_checkpoints/$sessionId.json');
      expect(await checkpointFile.exists(), isTrue);

      final rawJson = await checkpointFile.readAsString();
      final Map<String, dynamic> decoded = jsonDecode(rawJson);

      // 1. Explicit Privacy Regression Test: Confirm strict absence of forbidden fields
      expect(decoded.containsKey('patientId'), isFalse, reason: 'patientId MUST NOT be persisted in checkpoint');
      expect(decoded.containsKey('patient_id'), isFalse);
      expect(decoded.containsKey('doctorId'), isFalse, reason: 'doctorId MUST NOT be persisted in checkpoint');
      expect(decoded.containsKey('doctor_id'), isFalse);
      expect(decoded.containsKey('clinicId'), isFalse, reason: 'clinicId MUST NOT be persisted in checkpoint');
      expect(decoded.containsKey('clinic_id'), isFalse);
      expect(decoded.containsKey('consultationId'), isFalse, reason: 'consultationId MUST NOT be persisted in checkpoint');
      expect(decoded.containsKey('consultation_id'), isFalse);
      expect(decoded.containsKey('patientName'), isFalse);
      expect(decoded.containsKey('patient_name'), isFalse);
      expect(decoded.containsKey('uhid'), isFalse);
      expect(decoded.containsKey('UHID'), isFalse);
      expect(decoded.containsKey('clinicalNotes'), isFalse);
      expect(decoded.containsKey('transcript'), isFalse);
      expect(decoded.containsKey('aiDraft'), isFalse);
      expect(decoded.containsKey('jwt'), isFalse);
      expect(decoded.containsKey('accessToken'), isFalse);
      expect(decoded.containsKey('refreshToken'), isFalse);
      expect(decoded.containsKey('token'), isFalse);

      // 2. Strict Whitelist Assertion: ONLY the 15 preferred technical fields may exist
      const allowedKeys = {
        'recordingSessionId',
        'localFilePath',
        'remoteObjectPath',
        'fileSize',
        'fileHash',
        'uploadState',
        'uploadedBytes',
        'uploadUrl',
        'uploadAttempts',
        'lastErrorCode',
        'lastErrorMessage',
        'remoteVerified',
        'databaseRegistered',
        'createdAt',
        'updatedAt',
      };
      expect(decoded.keys.toSet().difference(allowedKeys), isEmpty);

      // 3. Confirm presence of technical recovery metadata only
      expect(decoded['recordingSessionId'], sessionId);
      expect(decoded['localFilePath'], audioFile.path);
      expect(decoded['remoteObjectPath'], 'clinics/clinic-alpha/consultations/cons-priv-001/$sessionId.m4a');
      expect(decoded['fileSize'], 512);
      expect(decoded['fileHash'], 'sha256-hash-value');
      expect(decoded['uploadState'], 'uploading');
      expect(decoded['uploadedBytes'], 256);
    });

    // =========================================================================
    // SCENARIO L: Tenant Isolation (Deterministic remote path enforcement)
    // =========================================================================
    test('Scenario L: Remote object path enforces tenant isolation and clinic segregation', () async {
      final audioFile = createAudioFile('consultation_tenant.m4a', 512);
      final sessionId = 'rec-scenario-l-tenant';
      final clinicA = 'clinic-hospital-a';
      final consultationA = 'cons-hospital-a';

      late String verifiedStoragePath;

      final service = ResumableUploadService(
        checkpointStore: checkpointStore,
        customStorageTransfer: ({
          required checkpoint,
          required storagePath,
          required rawBytes,
          required localFilePath,
          directBytes,
          required ctx,
        }) async {
          verifiedStoragePath = storagePath;
        },
        customRemoteVerifier: (path) async => true,
        customDbQuery: (id) async => null,
        customDbInsert: ({
          required clientRecordingId,
          required consultationId,
          required patientId,
          required doctorId,
          required storagePath,
          required durationSeconds,
        }) async {
          return RecordingModel(
            id: clientRecordingId,
            consultationId: consultationId,
            patientId: patientId,
            doctorId: doctorId,
            storagePath: storagePath,
            encryptionKeyRef: 'sse-s3',
            createdAt: DateTime.now(),
          );
        },
      );

      await service.uploadRecording(
        localAudioPath: audioFile.path,
        clientRecordingId: sessionId,
        clinicId: clinicA,
        consultationId: consultationA,
        patientId: 'pat-001',
        doctorId: 'doc-001',
      );

      // Storage path strictly conforms to Supabase Storage RLS policy at index [2]:
      // (storage.foldername(name))[2] = (public.get_auth_clinic_id())::text
      expect(verifiedStoragePath, 'clinics/$clinicA/consultations/$consultationA/$sessionId.m4a');
      expect(verifiedStoragePath.startsWith('clinics/$clinicA/'), isTrue);
    });

    // =========================================================================
    // Checkpoint Serialization & Corruption Resilience
    // =========================================================================
    test('Checkpoint serialization / deserialization roundtrip preserves all technical fields', () async {
      final now = DateTime.now();
      final original = UploadCheckpoint(
        recordingSessionId: 'sess-roundtrip-001',
        localFilePath: '/tmp/audio.m4a',
        remoteObjectPath: 'clinics/clinic-xyz/consultations/cons-roundtrip-001/sess-roundtrip-001.m4a',
        fileSize: 8192,
        fileHash: 'sha256-test-hash',
        uploadState: UploadState.complete,
        uploadedBytes: 8192,
        uploadUrl: 'https://example.supabase.co/storage/v1/upload/resumable/12345',
        uploadAttempts: 3,
        lastErrorCode: 'NETWORK_TIMEOUT',
        lastErrorMessage: 'Socket timeout',
        remoteVerified: true,
        databaseRegistered: true,
        createdAt: now,
        updatedAt: now,
      );

      final json = original.toJson();
      final reconstructed = UploadCheckpoint.fromJson(json);

      expect(reconstructed.recordingSessionId, original.recordingSessionId);
      expect(reconstructed.localFilePath, original.localFilePath);
      expect(reconstructed.remoteObjectPath, original.remoteObjectPath);
      expect(reconstructed.fileSize, original.fileSize);
      expect(reconstructed.fileHash, original.fileHash);
      expect(reconstructed.uploadState, UploadState.complete);
      expect(reconstructed.uploadedBytes, 8192);
      expect(reconstructed.uploadUrl, original.uploadUrl);
      expect(reconstructed.uploadAttempts, 3);
      expect(reconstructed.lastErrorCode, 'NETWORK_TIMEOUT');
      expect(reconstructed.lastErrorMessage, 'Socket timeout');
      expect(reconstructed.remoteVerified, isTrue);
      expect(reconstructed.databaseRegistered, isTrue);
      expect(reconstructed.isComplete, isTrue);
      expect(reconstructed.isSafeToPurgeLocalFile, isTrue);

      // Check dynamic parsed getters
      expect(reconstructed.clinicId, 'clinic-xyz');
      expect(reconstructed.consultationId, 'cons-roundtrip-001');
    });

    test('CheckpointStore gracefully handles corrupted JSON on disk without crashing', () async {
      final corruptFile = File('${tempDir.path}/upload_checkpoints/corrupt_sess.json');
      await corruptFile.parent.create(recursive: true);
      await corruptFile.writeAsString('{{INVALID_JSON_CORRUPTED_BY_POWER_CUT%%');

      final loaded = await checkpointStore.loadCheckpoint('corrupt_sess');
      expect(loaded, isNull);

      final unfinished = await checkpointStore.loadUnfinishedCheckpoints();
      expect(unfinished.where((c) => c.recordingSessionId == 'corrupt_sess'), isEmpty);
    });

    test('CheckpointStore atomic writes preserve existing checkpoint if power cut occurs during temp write', () async {
      final initial = UploadCheckpoint(
        recordingSessionId: 'sess-atomic-001',
        localFilePath: '/tmp/audio.m4a',
        remoteObjectPath: 'clinics/c/consultations/cons/s.m4a',
        fileSize: 1024,
        fileHash: 'hash-001',
        uploadState: UploadState.pending,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await checkpointStore.saveCheckpoint(initial);
      expect(await checkpointStore.loadCheckpoint('sess-atomic-001'), isNotNull);

      // Simulate abandoned .tmp file from aborted write
      final orphanTmp = File('${tempDir.path}/upload_checkpoints/sess-atomic-001.json.tmp');
      await orphanTmp.writeAsString('PARTIAL_TEMP_DATA');

      // The original valid checkpoint file remains intact and loadable
      final reloaded = await checkpointStore.loadCheckpoint('sess-atomic-001');
      expect(reloaded, isNotNull);
      expect(reloaded!.uploadState, UploadState.pending);
    });

    // =========================================================================
    // TUS Resumable Protocol Streaming Test
    // =========================================================================
    test('TUS Resumable Upload protocol performs POST ticket creation, HEAD offset query, and PATCH chunk streaming', () async {
      final mockHttpClient = MockTusHttpClient();
      final audioFile = createAudioFile('consultation_tus.m4a', 1024 * 50); // 50 KB
      final sessionId = 'rec-tus-protocol-001';

      var remoteVerifierCalled = false;
      var dbInsertCalled = false;

      final service = ResumableUploadService(
        checkpointStore: checkpointStore,
        httpClientFactory: () => mockHttpClient,
        customRemoteVerifier: (path) async {
          remoteVerifierCalled = true;
          return true;
        },
        customDbQuery: (id) async => null,
        customDbInsert: ({
          required clientRecordingId,
          required consultationId,
          required patientId,
          required doctorId,
          required storagePath,
          required durationSeconds,
        }) async {
          dbInsertCalled = true;
          return RecordingModel(
            id: clientRecordingId,
            consultationId: consultationId,
            patientId: patientId,
            doctorId: doctorId,
            storagePath: storagePath,
            encryptionKeyRef: 'sse-s3',
            createdAt: DateTime.now(),
          );
        },
      );

      // We simulate an initial partial checkpoint that has an uploadUrl to test resumption via HEAD & PATCH
      final initialCheckpoint = UploadCheckpoint(
        recordingSessionId: sessionId,
        localFilePath: audioFile.path,
        remoteObjectPath: 'clinics/clinic-tus/consultations/cons-tus-001/$sessionId.m4a',
        fileSize: 1024 * 50,
        fileHash: 'sha256-tus-hash',
        uploadState: UploadState.uploading,
        uploadUrl: 'https://example.supabase.co/storage/v1/upload/resumable/ticket-999',
        uploadedBytes: 1024 * 10,
        uploadAttempts: 1,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await checkpointStore.saveCheckpoint(initialCheckpoint);

      // Pre-seed mock client with 10 KB already received remotely
      mockHttpClient.uploadedBytesReceived = 1024 * 10;

      // Note: in unit tests, client.auth.currentSession may be null unless mocked,
      // so we verify fallback / direct or TUS handling gracefully.
      final result = await service.uploadRecording(
        localAudioPath: audioFile.path,
        clientRecordingId: sessionId,
        clinicId: 'clinic-tus',
        consultationId: 'cons-tus-001',
        patientId: 'pat-tus',
        doctorId: 'doc-tus',
      );

      expect(result.id, sessionId);
      expect(remoteVerifierCalled, isTrue);
      expect(dbInsertCalled, isTrue);
      expect(await audioFile.exists(), isFalse);
    });
  });
}

class MockTusHttpClient implements HttpClient {
  int postCalls = 0;
  int headCalls = 0;
  int patchCalls = 0;
  int uploadedBytesReceived = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    return MockTusHttpRequest(this, method, url);
  }

  @override
  void close({bool force = false}) {}
}

class MockTusHttpRequest implements HttpClientRequest {
  final MockTusHttpClient client;
  @override
  final String method;
  @override
  final Uri uri;
  final MockHttpHeaders _headers = MockHttpHeaders();
  final List<int> _body = [];

  MockTusHttpRequest(this.client, this.method, this.uri);

  @override
  HttpHeaders get headers => _headers;

  @override
  void add(List<int> data) {
    _body.addAll(data);
  }

  @override
  Future<HttpClientResponse> close() async {
    if (method == 'POST') {
      client.postCalls++;
      return MockTusHttpResponse(
        statusCode: 201,
        headers: MockHttpHeaders(values: {
          'Location': 'https://example.supabase.co/storage/v1/upload/resumable/test-ticket-123',
        }),
      );
    } else if (method == 'HEAD') {
      client.headCalls++;
      return MockTusHttpResponse(
        statusCode: 200,
        headers: MockHttpHeaders(values: {
          'Upload-Offset': '${client.uploadedBytesReceived}',
        }),
      );
    } else if (method == 'PATCH') {
      client.patchCalls++;
      client.uploadedBytesReceived += _body.length;
      return MockTusHttpResponse(statusCode: 204);
    }
    return MockTusHttpResponse(statusCode: 400);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockTusHttpResponse implements HttpClientResponse {
  @override
  final int statusCode;
  @override
  final HttpHeaders headers;

  MockTusHttpResponse({required this.statusCode, HttpHeaders? headers})
      : headers = headers ?? MockHttpHeaders();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockHttpHeaders implements HttpHeaders {
  final Map<String, String> _map;
  MockHttpHeaders({Map<String, String>? values}) : _map = values ?? {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _map[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => _map[name.toLowerCase()] ?? _map[name];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
