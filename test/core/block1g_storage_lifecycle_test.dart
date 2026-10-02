import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/core/observability/metric_definitions.dart';
import 'package:medico_opd/core/observability/telemetry_service.dart';
import 'package:medico_opd/core/storage/storage_lifecycle_service.dart';
import 'package:medico_opd/features/recording/models/recording_model.dart';

void main() {
  group('Block 1G: Storage Lifecycle, Retention Enforcement & Orphan Audio Cleanup', () {
    late InMemoryTelemetryService telemetry;
    late StorageLifecycleService service;
    late Map<String, RecordingModel> mockDbRecordings;
    late Set<String> mockStorageFiles;
    late Set<String> claimedForDeletionIds;
    late Set<String> finalizedDeletedIds;
    late Set<String> reconciledMissingIds;

    final now = DateTime.utc(2026, 9, 27, 10, 0, 0);

    RecordingModel createTestRecording({
      String id = 'rec-001',
      String clinicId = 'c_001',
      RecordingProcessingStatus processingStatus = RecordingProcessingStatus.transcribed,
      DateTime? retentionExpiresAt,
      bool legalHold = false,
      DateTime? leaseExpiresAt,
    }) {
      return RecordingModel(
        id: id,
        consultationId: 'cons-001',
        patientId: 'pat-001',
        doctorId: 'doc-001',
        storagePath: 'clinics/$clinicId/consultations/cons-001/$id.m4a',
        encryptionKeyRef: 'key-ref-001',
        durationSeconds: 120,
        format: 'm4a',
        uploadStatus: RecordingUploadStatus.uploaded,
        processingStatus: processingStatus,
        createdAt: now.subtract(const Duration(days: 30)),
        retentionExpiresAt: retentionExpiresAt,
        legalHold: legalHold,
        deletionStatus: RecordingDeletionStatus.active,
        leaseExpiresAt: leaseExpiresAt,
      );
    }

    setUp(() {
      telemetry = InMemoryTelemetryService();
      mockDbRecordings = {};
      mockStorageFiles = {};
      claimedForDeletionIds = {};
      finalizedDeletedIds = {};
      reconciledMissingIds = {};

      service = StorageLifecycleService(
        telemetry: telemetry,
        policyResolver: (clinicId) async => const RetentionPolicyModel(
          dataClass: 'raw_audio',
          retentionDays: 7,
          isEnabled: true,
          scope: 'clinic',
        ),
        recordingLookup: (storagePath) async => mockDbRecordings[storagePath],
        candidateFetcher: ({clinicId, limit = 50, currentTime}) async {
          return mockDbRecordings.values
              .where((r) =>
                  (clinicId == null || r.storagePath.contains('/$clinicId/')) &&
                  r.deletionStatus == RecordingDeletionStatus.active &&
                  !r.legalHold &&
                  r.retentionExpiresAt != null &&
                  !r.retentionExpiresAt!.isAfter(currentTime ?? now))
              .take(limit)
              .toList();
        },
        deletionClaimer: (recordingId, workerId) async {
          // Atomic claim simulation: check if still active
          final rec = mockDbRecordings.values.firstWhere(
            (r) => r.id == recordingId,
            orElse: () => throw StateError('Not found'),
          );
          if (rec.processingStatus != RecordingProcessingStatus.transcribed &&
              rec.processingStatus != RecordingProcessingStatus.failed) {
            return false; // Active processing worker holds it
          }
          if (rec.legalHold) return false;
          claimedForDeletionIds.add(recordingId);
          return true;
        },
        storageRemover: (paths) async {
          for (final path in paths) {
            mockStorageFiles.remove(path);
          }
        },
        deletionFinalizer: (recordingId) async {
          finalizedDeletedIds.add(recordingId);
          return true;
        },
        deletionReverter: (recordingId, errorCode) async {
          claimedForDeletionIds.remove(recordingId);
          return true;
        },
        missingReconciler: (recordingId) async {
          reconciledMissingIds.add(recordingId);
          return true;
        },
      );
    });

    group('1. Production Safety Guard (Parts 1, 2 & 27)', () {
      test('Refuses execution and throws StateError when Production project is targeted', () {
        expect(
          () => StorageLifecycleService.verifyNonProductionGuard(
            'https://dyfrknwejqwilstcoytt.supabase.co',
          ),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Production project (dyfrknwejqwilstcoytt) detected'),
          )),
        );
      });

      test('Allows execution when TEST project is targeted', () {
        expect(
          () => StorageLifecycleService.verifyNonProductionGuard(
            'https://waklyrjpxstqckjipeyg.supabase.co',
          ),
          returnsNormally,
        );
      });
    });

    group('2. Storage Path Parser & Tenant Boundary (Parts 6 & 13)', () {
      test('Accurately parses valid storage path segments and IDs', () {
        const path = 'clinics/c_123/consultations/cons_456/rec_789.m4a';
        final parsed = ParsedStoragePath.parse(path);

        expect(parsed.isValid, isTrue);
        expect(parsed.clinicId, equals('c_123'));
        expect(parsed.consultationId, equals('cons_456'));
        expect(parsed.recordingId, equals('rec_789'));
        expect(parsed.extension, equals('m4a'));
      });

      test('Marks non-conforming or malformed paths as invalid', () {
        final invalid1 = ParsedStoragePath.parse('invalid/path.m4a');
        expect(invalid1.isValid, isFalse);

        final invalid2 = ParsedStoragePath.parse('clinics/c_123/wrong/cons_456/rec_789.m4a');
        expect(invalid2.isValid, isFalse);

        final invalid3 = ParsedStoragePath.parse('');
        expect(invalid3.isValid, isFalse);
      });
    });

    group('3. Retention Deletion Eligibility Rules (Parts 7, 8 & 15)', () {
      test('Eligible: Expired retention, transcribed, no legal hold, no active lease', () {
        final recording = createTestRecording(
          retentionExpiresAt: now.subtract(const Duration(days: 1)),
        );
        final classification = service.classifyRecording(recording, now: now);

        expect(classification, equals(StorageObjectClassification.retentionEligible));
      });

      test('Preserve: Retention not expired yet', () {
        final recording = createTestRecording(
          retentionExpiresAt: now.add(const Duration(days: 7)),
        );
        final classification = service.classifyRecording(recording, now: now);

        expect(classification, equals(StorageObjectClassification.retentionNotExpired));
      });

      test('Preserve: Legal hold placed (trumps expiration)', () {
        final recording = createTestRecording(
          retentionExpiresAt: now.subtract(const Duration(days: 10)),
          legalHold: true,
        );
        final classification = service.classifyRecording(recording, now: now);

        expect(classification, equals(StorageObjectClassification.underLegalHold));
      });

      test('Preserve: Active processing stages (pending, queued, transcribing, structuring)', () {
        for (final status in [
          RecordingProcessingStatus.pending,
          RecordingProcessingStatus.queued,
          RecordingProcessingStatus.transcribing,
          RecordingProcessingStatus.structuring,
        ]) {
          final recording = createTestRecording(
            processingStatus: status,
            retentionExpiresAt: now.subtract(const Duration(days: 1)),
          );
          final classification = service.classifyRecording(recording, now: now);

          expect(
            classification,
            equals(StorageObjectClassification.activeProcessing),
            reason: 'Stage $status must be protected from deletion',
          );
        }
      });

      test('Preserve: Active worker lease is protected even if retention has expired', () {
        final recording = createTestRecording(
          processingStatus: RecordingProcessingStatus.transcribing,
          retentionExpiresAt: now.subtract(const Duration(days: 1)),
          leaseExpiresAt: now.add(const Duration(minutes: 5)),
        );
        final classification = service.classifyRecording(recording, now: now);

        expect(classification, equals(StorageObjectClassification.activeProcessing));
      });

      test('Fail-Closed: Missing or inert policy (retention_days is NULL) preserves audio indefinitely', () {
        final recording = createTestRecording(
          retentionExpiresAt: null, // Unconfigured
        );
        const policy = RetentionPolicyModel(
          dataClass: 'raw_audio',
          retentionDays: null, // Safe inert retention
          isEnabled: true,
        );
        final classification = service.classifyRecording(
          recording,
          now: now,
          policy: policy,
        );

        expect(classification, equals(StorageObjectClassification.unresolvedPolicy));
      });

      test('Disabled policy fails closed', () {
        final recording = createTestRecording(
          retentionExpiresAt: now.subtract(const Duration(days: 1)),
        );
        const policy = RetentionPolicyModel(
          dataClass: 'raw_audio',
          retentionDays: 7,
          isEnabled: false, // Explicitly disabled
        );
        final classification = service.classifyRecording(
          recording,
          now: now,
          policy: policy,
        );

        expect(classification, equals(StorageObjectClassification.unresolvedPolicy));
      });
    });

    group('4. Safe Orphan Audio Identification (Parts 5 & 12)', () {
      test('Identifies genuine storage orphan when object age exceeds grace window', () {
        final object = StorageObjectInfo(
          name: 'clinics/c_001/consultations/cons_001/rec_orphan.m4a',
          id: 'obj-123',
          createdAt: now.subtract(const Duration(hours: 5)), // 5 hours old
          sizeBytes: 1048576,
        );

        final classification = service.classifyStorageObject(
          object: object,
          matchedRecording: null, // No DB row
          orphanGraceWindow: const Duration(hours: 2),
          now: now,
        );

        expect(classification, equals(StorageObjectClassification.storageOrphan));
      });

      test('Protects recent in-flight uploads within grace window (not treated as orphan)', () {
        final object = StorageObjectInfo(
          name: 'clinics/c_001/consultations/cons_001/rec_inflight.m4a',
          id: 'obj-456',
          createdAt: now.subtract(const Duration(minutes: 15)), // 15 mins old (< 2hr grace)
          sizeBytes: 524288,
        );

        final classification = service.classifyStorageObject(
          object: object,
          matchedRecording: null, // In-flight: DB row might not be committed yet
          orphanGraceWindow: const Duration(hours: 2),
          now: now,
        );

        // Protected as active processing
        expect(classification, equals(StorageObjectClassification.activeProcessing));
      });
    });

    group('5. Orphan Cleanup Dry-Run Mode & Batch Safety (Parts 10 & 11)', () {
      test('Dry-run scans candidates, identifies orphans, and performs zero deletions', () async {
        final objects = [
          // Genuine orphan
          StorageObjectInfo(
            name: 'clinics/c_001/consultations/cons_001/orphan_1.m4a',
            id: 'obj-1',
            createdAt: now.subtract(const Duration(hours: 10)),
            sizeBytes: 1024,
          ),
          // In-flight upload (recent)
          StorageObjectInfo(
            name: 'clinics/c_001/consultations/cons_001/inflight_1.m4a',
            id: 'obj-2',
            createdAt: now.subtract(const Duration(minutes: 30)),
            sizeBytes: 2048,
          ),
          // Cross-tenant object (different clinic)
          StorageObjectInfo(
            name: 'clinics/c_002/consultations/cons_002/other_clinic.m4a',
            id: 'obj-3',
            createdAt: now.subtract(const Duration(hours: 10)),
            sizeBytes: 1024,
          ),
        ];

        // Evaluate in dry-run mode scoped to clinic 'c_001'
        final result = await service.runOrphanCleanup(
          objects: objects,
          clinicId: 'c_001',
          dryRun: true,
          now: now,
        );

        expect(result.isDryRun, isTrue);
        expect(result.deletedCount, equals(0)); // Zero deletions in dry-run
        expect(result.orphanCount, equals(1)); // Only orphan_1 matched
        expect(result.blockedCount, equals(2)); // inflight_1 and cross-tenant blocked
        expect(result.items.length, equals(2)); // Evaluated items for clinic c_001
      });
    });

    group('6. Concurrency Protection & Race Prevention (Parts 8 & 20)', () {
      test('Atomic claim fails and aborts deletion when AI worker claims recording concurrently', () async {
        // Recording is expired
        final rec = createTestRecording(
          id: 'rec-race-1',
          clinicId: 'c_001',
          processingStatus: RecordingProcessingStatus.transcribing, // Worker changed to transcribing!
          retentionExpiresAt: now.subtract(const Duration(days: 1)),
        );
        mockDbRecordings[rec.storagePath] = rec;
        mockStorageFiles.add(rec.storagePath);

        final result = await service.runRetentionCleanup(
          clinicId: 'c_001',
          dryRun: false,
          now: now,
        );

        // Deletion must be aborted!
        expect(result.deletedCount, equals(0));
        expect(mockStorageFiles.contains(rec.storagePath), isTrue); // Audio strictly preserved!
        expect(finalizedDeletedIds.contains(rec.id), isFalse);
      });

      test('Successful retention deletion when conditions are met', () async {
        final rec = createTestRecording(
          id: 'rec-safe-del',
          clinicId: 'c_001',
          processingStatus: RecordingProcessingStatus.transcribed,
          retentionExpiresAt: now.subtract(const Duration(days: 2)),
        );
        mockDbRecordings[rec.storagePath] = rec;
        mockStorageFiles.add(rec.storagePath);

        final result = await service.runRetentionCleanup(
          clinicId: 'c_001',
          dryRun: false,
          now: now,
        );

        expect(result.deletedCount, equals(1));
        expect(claimedForDeletionIds.contains(rec.id), isTrue);
        expect(finalizedDeletedIds.contains(rec.id), isTrue);
        expect(mockStorageFiles.contains(rec.storagePath), isFalse); // Successfully removed
      });
    });

    group('7. Observability & Telemetry Integration (Part 17)', () {
      test('Emits Block 1F metrics on storage lifecycle operations', () async {
        final objects = [
          StorageObjectInfo(
            name: 'clinics/c_001/consultations/cons_001/orphan_obs.m4a',
            id: 'obj-obs',
            createdAt: now.subtract(const Duration(hours: 4)),
            sizeBytes: 1024,
          ),
        ];

        await service.runOrphanCleanup(
          objects: objects,
          clinicId: 'c_001',
          dryRun: true,
          now: now,
        );

        expect(
          telemetry.getCounter(
            MetricDefinitions.storageCleanupRunsTotal,
            labels: {'mode': 'dry_run'},
          ),
          equals(1),
        );
        expect(
          telemetry.getCounter(
            MetricDefinitions.storageOrphansDetectedTotal,
            labels: {'mode': 'dry_run'},
          ),
          equals(1),
        );
        expect(telemetry.timings.isNotEmpty, isTrue);
      });
    });

    group('8. Tenant Isolation Guarantees (Part 13)', () {
      test('Scoped cleanup strictly blocks any operations on other clinics', () async {
        final crossTenantObjects = [
          StorageObjectInfo(
            name: 'clinics/clinic_B/consultations/cons_b/audio.m4a',
            id: 'obj-b',
            createdAt: now.subtract(const Duration(hours: 12)),
            sizeBytes: 2048,
          ),
        ];

        // Run scoped to Clinic A
        final result = await service.runOrphanCleanup(
          objects: crossTenantObjects,
          clinicId: 'clinic_A',
          dryRun: true,
          now: now,
        );

        expect(result.orphanCount, equals(0));
        expect(result.deletedCount, equals(0));
        expect(result.blockedCount, equals(1));
      });
    });
  });
}
