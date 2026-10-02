// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/core/observability/telemetry_service.dart';
import 'package:medico_opd/core/storage/storage_lifecycle_service.dart';
import 'package:medico_opd/features/recording/models/recording_model.dart';

void main() {
  group('Block 1G: Storage Lifecycle & Retention Benchmark', () {
    late InMemoryTelemetryService telemetry;
    late StorageLifecycleService service;

    final now = DateTime.utc(2026, 9, 27, 12, 0, 0);

    setUp(() {
      telemetry = InMemoryTelemetryService();
      service = StorageLifecycleService(telemetry: telemetry);
    });

    List<RecordingModel> generateSyntheticRecordings(int count) {
      final list = <RecordingModel>[];
      for (int i = 0; i < count; i++) {
        // 70% expired, 10% active processing, 10% legal hold, 10% unexpired
        final mod = i % 10;
        final RecordingProcessingStatus procStatus;
        final DateTime? expiresAt;
        final bool legalHold;

        if (mod < 7) {
          // Expired eligible
          procStatus = RecordingProcessingStatus.transcribed;
          expiresAt = now.subtract(Duration(days: 1 + (i % 30)));
          legalHold = false;
        } else if (mod == 7) {
          // Active processing
          procStatus = RecordingProcessingStatus.transcribing;
          expiresAt = now.subtract(const Duration(days: 5));
          legalHold = false;
        } else if (mod == 8) {
          // Legal hold
          procStatus = RecordingProcessingStatus.transcribed;
          expiresAt = now.subtract(const Duration(days: 10));
          legalHold = true;
        } else {
          // Not expired
          procStatus = RecordingProcessingStatus.transcribed;
          expiresAt = now.add(Duration(days: 1 + (i % 14)));
          legalHold = false;
        }

        list.add(RecordingModel(
          id: 'bench-rec-$i',
          consultationId: 'bench-cons-${i % 200}',
          patientId: 'bench-pat-${i % 100}',
          doctorId: 'bench-doc-${i % 10}',
          storagePath: 'clinics/c_bench/consultations/bench-cons-${i % 200}/bench-rec-$i.m4a',
          encryptionKeyRef: 'key-ref-$i',
          durationSeconds: 180,
          format: 'm4a',
          uploadStatus: RecordingUploadStatus.uploaded,
          processingStatus: procStatus,
          createdAt: now.subtract(const Duration(days: 60)),
          retentionExpiresAt: expiresAt,
          legalHold: legalHold,
          deletionStatus: RecordingDeletionStatus.active,
        ));
      }
      return list;
    }

    test('100 Synthetic Recordings: Scan, Classification & Bounded Batch Evaluation', () async {
      final recordings = generateSyntheticRecordings(100);
      final sw = Stopwatch()..start();

      int eligible = 0;
      int active = 0;
      int held = 0;
      int unexpired = 0;

      for (final rec in recordings) {
        final classification = service.classifyRecording(rec, now: now);
        switch (classification) {
          case StorageObjectClassification.retentionEligible:
            eligible++;
            break;
          case StorageObjectClassification.activeProcessing:
            active++;
            break;
          case StorageObjectClassification.underLegalHold:
            held++;
            break;
          case StorageObjectClassification.retentionNotExpired:
            unexpired++;
            break;
          default:
            break;
        }
      }
      sw.stop();

      final throughput = (recordings.length / (sw.elapsedMicroseconds / 1000000.0)).round();

      print('[BENCHMARK-100] Processed: ${recordings.length} records in ${sw.elapsedMicroseconds} µs (~${sw.elapsedMilliseconds} ms)');
      print('[BENCHMARK-100] Breakdown: $eligible eligible, $active active processing, $held under hold, $unexpired unexpired');
      print('[BENCHMARK-100] Throughput: $throughput classifications/sec');

      expect(eligible, equals(70));
      expect(active, equals(10));
      expect(held, equals(10));
      expect(unexpired, equals(10));
      expect(sw.elapsedMilliseconds, lessThan(200));
    });

    test('1,000 Synthetic Recordings: Scan, Classification & Memory Scale', () async {
      final recordings = generateSyntheticRecordings(1000);
      final sw = Stopwatch()..start();

      int eligible = 0;
      int blocked = 0;

      for (final rec in recordings) {
        final classification = service.classifyRecording(rec, now: now);
        if (classification == StorageObjectClassification.retentionEligible) {
          eligible++;
        } else {
          blocked++;
        }
      }
      sw.stop();

      final throughput = (recordings.length / (sw.elapsedMicroseconds / 1000000.0)).round();

      print('[BENCHMARK-1,000] Processed: ${recordings.length} records in ${sw.elapsedMicroseconds} µs (~${sw.elapsedMilliseconds} ms)');
      print('[BENCHMARK-1,000] Eligible: $eligible, Blocked: $blocked');
      print('[BENCHMARK-1,000] Throughput: $throughput classifications/sec');

      expect(eligible, equals(700));
      expect(blocked, equals(300));
      expect(sw.elapsedMilliseconds, lessThan(500));
    });

    test('10,000 Synthetic Recordings: Stress Classification & Throughput Measurement', () async {
      final recordings = generateSyntheticRecordings(10000);
      final sw = Stopwatch()..start();

      int eligible = 0;
      int blocked = 0;

      for (final rec in recordings) {
        final classification = service.classifyRecording(rec, now: now);
        if (classification == StorageObjectClassification.retentionEligible) {
          eligible++;
        } else {
          blocked++;
        }
      }
      sw.stop();

      final throughput = (recordings.length / (sw.elapsedMicroseconds / 1000000.0)).round();

      print('[BENCHMARK-10,000] Processed: ${recordings.length} records in ${sw.elapsedMilliseconds} ms');
      print('[BENCHMARK-10,000] Eligible: $eligible, Blocked: $blocked');
      print('[BENCHMARK-10,000] Throughput: $throughput classifications/sec');

      expect(eligible, equals(7000));
      expect(blocked, equals(3000));
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });
  });
}
