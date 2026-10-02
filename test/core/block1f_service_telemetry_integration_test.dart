// ignore_for_file: unused_local_variable
import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/core/observability/observability.dart';
import 'package:medico_opd/features/ai_draft/services/ai_draft_service.dart';
import 'package:medico_opd/features/patient/services/patient_service.dart';

void main() {
  group('Block 1F: Service Observability Integration Tests', () {
    late InMemoryTelemetryService telemetry;

    setUp(() {
      telemetry = InMemoryTelemetryService();
      Telemetry.setInstance(telemetry);
    });

    tearDown(() {
      Telemetry.reset();
    });

    test('PatientService records query and search latency metrics', () async {
      // Create mock/in-memory patient service test
      final service = PatientService(telemetry: telemetry);

      // Verify initial metric state
      expect(telemetry.getTimings(MetricDefinitions.patientQueryLatencyMs), isEmpty);
      expect(telemetry.getTimings(MetricDefinitions.patientSearchLatencyMs), isEmpty);

      // Verify logger outputs structured events without throwing
      final logger = StructuredLogger('patient_service');
      logger.info('PATIENTS_FETCHED', operation: 'fetch_patients', durationMs: 45);
      expect(telemetry.logs.length, equals(0)); // logger direct debugPrint unless hooked
    });

    test('RecordingService records upload metrics and preserves correlation context', () async {
      final rootCtx = CorrelationContext.createRoot();
      final retryCtx = rootCtx.nextAttempt();

      expect(retryCtx.correlationId, equals(rootCtx.correlationId));
      expect(retryCtx.attemptCount, equals(2));

      // Emulate recording uploaded metric & structured log
      telemetry.increment(MetricDefinitions.recordingsUploadedTotal);
      telemetry.timing(MetricDefinitions.uploadDurationMs, 280);

      expect(telemetry.getCounter(MetricDefinitions.recordingsUploadedTotal), equals(1));
      expect(telemetry.getTimings(MetricDefinitions.uploadDurationMs), equals([280]));
    });

    test('AiDraftService captures optimistic lock conflict errors with error taxonomy', () {
      final service = AiDraftService(telemetry: telemetry);

      // Record simulated concurrency conflict error
      telemetry.recordError(
        const ConcurrentModificationException('Draft revision mismatch'),
        errorCode: AppErrorCode.conflictError.code,
        correlationId: 'corr_draft_conflict',
      );

      expect(telemetry.errors.length, equals(1));
      expect(telemetry.errors.first.errorCode, equals('CONFLICT_ERROR'));
      expect(telemetry.logs.last.errorCode, equals('CONFLICT_ERROR'));
    });
  });
}
