import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/core/observability/observability.dart';

void main() {
  group('Block 1F: Observability, Metrics & Production-Safe Diagnostics', () {
    late InMemoryTelemetryService telemetry;

    setUp(() {
      telemetry = InMemoryTelemetryService();
      Telemetry.setInstance(telemetry);
    });

    tearDown(() {
      Telemetry.reset();
    });

    group('1. Structured Logging & Privacy Redaction (Parts 2 & 10)', () {
      test('Emits complete structured JSON format with all standard operational fields', () {
        final logs = <String>[];
        final logger = StructuredLogger('test_component', customSink: logs.add);

        logger.info(
          'RECORDING_UPLOADED',
          operation: 'upload_audio',
          requestId: 'req_123',
          correlationId: 'corr_456',
          clinicId: 'clinic-uuid-789',
          recordingId: 'rec_abc',
          consultationId: 'cons_def',
          attemptCount: 1,
          durationMs: 250,
          metadata: {'custom_flag': true},
        );

        expect(logs.length, equals(1));
        final parsed = jsonDecode(logs.first) as Map<String, dynamic>;

        expect(parsed['timestamp'], isNotNull);
        expect(parsed['event'], equals('RECORDING_UPLOADED'));
        expect(parsed['severity'], equals('INFO'));
        expect(parsed['component'], equals('test_component'));
        expect(parsed['operation'], equals('upload_audio'));
        expect(parsed['request_id'], equals('req_123'));
        expect(parsed['correlation_id'], equals('corr_456'));
        expect(parsed['recording_id'], equals('rec_abc'));
        expect(parsed['consultation_id'], equals('cons_def'));
        expect(parsed['attempt_count'], equals(1));
        expect(parsed['duration_ms'], equals(250));
        expect(parsed['clinic_id_hash'], isNot(equals('clinic-uuid-789'))); // Must be hashed!
        expect(parsed['clinic_id_hash']?.length, equals(12));
      });

      test('Automated Redaction: Redacts JWTs, API keys, and signed URLs', () {
        const sampleJwt = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c';
        const sampleApiKey = 'sk-ant-api03-abcdef1234567890abcdef1234567890';
        const sampleSignedUrl = 'https://waklyrjpxstqckjipeyg.supabase.co/storage/v1/object/sign/recordings/audio.m4a?token=secrettoken12345&Expires=1700000000';

        final input = 'User token is $sampleJwt, key is $sampleApiKey, download at $sampleSignedUrl';
        final redacted = SensitiveDataRedactor.redact(input);

        expect(redacted, isNot(contains(sampleJwt)));
        expect(redacted, isNot(contains(sampleApiKey)));
        expect(redacted, isNot(contains('secrettoken12345')));
        expect(redacted, contains('[REDACTED_JWT]'));
        expect(redacted, contains('[REDACTED_API_KEY]'));
        expect(redacted, contains('[REDACTED_SIGNED_URL]'));
      });

      test('Automated Redaction: Redacts Emails, Phones, and Indian Aadhaar numbers', () {
        const phone = '9876543210';
        const email = 'doctor.sharma@example-hospital.in';
        const aadhaar = '9999 8888 7777';

        final input = 'Contact: $phone, Email: $email, Govt ID: $aadhaar';
        final redacted = SensitiveDataRedactor.redact(input);

        expect(redacted, isNot(contains(phone)));
        expect(redacted, isNot(contains(email)));
        expect(redacted, isNot(contains(aadhaar)));
        expect(redacted, contains('[REDACTED_PHONE]'));
        expect(redacted, contains('[REDACTED_EMAIL]'));
        expect(redacted, contains('[REDACTED_AADHAAR]'));
      });

      test('Automated Redaction: Completely strips clinical payloads from metadata maps', () {
        final payload = {
          'patient_name': 'Ramesh Kumar',
          'transcript': 'Patient complains of severe chest pain radiating to left arm.',
          'diagnosis': 'Acute Myocardial Infarction',
          'prompt': 'Summarize clinical diagnosis and prescribe medication.',
          'safe_metric': 42,
          'nested': {
            'prescription': 'Aspirin 300mg stat',
            'status': 'active',
          },
        };

        final sanitized = SensitiveDataRedactor.sanitizeValue(payload) as Map<String, dynamic>;

        expect(sanitized['patient_name'], equals('[REDACTED_CLINICAL_PAYLOAD]'));
        expect(sanitized['transcript'], equals('[REDACTED_CLINICAL_PAYLOAD]'));
        expect(sanitized['diagnosis'], equals('[REDACTED_CLINICAL_PAYLOAD]'));
        expect(sanitized['prompt'], equals('[REDACTED_CLINICAL_PAYLOAD]'));
        expect(sanitized['safe_metric'], equals(42));
        expect((sanitized['nested'] as Map)['prescription'], equals('[REDACTED_CLINICAL_PAYLOAD]'));
        expect((sanitized['nested'] as Map)['status'], equals('active'));
      });
    });

    group('2. Correlation & Request Context (Parts 3 & 4)', () {
      test('Root context generates valid correlation ID and request ID', () {
        final ctx = CorrelationContext.createRoot();

        expect(ctx.correlationId, startsWith('corr_'));
        expect(ctx.requestId, startsWith('req_'));
        expect(ctx.attemptCount, equals(1));
      });

      test('Retries preserve correlation identity while generating fresh request IDs', () {
        final root = CorrelationContext.createRoot();
        final retry1 = root.nextAttempt();
        final retry2 = retry1.nextAttempt();

        // Correlation ID strictly preserved across lifecycle
        expect(retry1.correlationId, equals(root.correlationId));
        expect(retry2.correlationId, equals(root.correlationId));

        // Request ID strictly unique per HTTP attempt
        expect(retry1.requestId, isNot(equals(root.requestId)));
        expect(retry2.requestId, isNot(equals(retry1.requestId)));

        // Attempt counter increments
        expect(retry1.attemptCount, equals(2));
        expect(retry2.attemptCount, equals(3));
      });

      test('Headers propagation includes X-Correlation-ID and X-Request-ID', () {
        final ctx = CorrelationContext.createRoot();
        final headers = ctx.toHeaders();

        expect(headers['X-Correlation-ID'], equals(ctx.correlationId));
        expect(headers['X-Request-ID'], equals(ctx.requestId));
      });

      test('Context correctly adopts upstream headers when present', () {
        final headers = {
          'X-Correlation-ID': 'corr_upstream_999',
          'X-Request-ID': 'req_upstream_888',
        };
        final ctx = CorrelationContext.fromHeaders(headers);

        expect(ctx.correlationId, equals('corr_upstream_999'));
        expect(ctx.requestId, equals('req_upstream_888'));
      });
    });

    group('3. Metrics Collection & High-Cardinality Protection (Parts 5, 6, 7, 8, 17, 18)', () {
      test('Telemetry records counters and timings accurately', () {
        telemetry.increment(MetricDefinitions.recordingsCreatedTotal);
        telemetry.increment(MetricDefinitions.recordingsCreatedTotal, value: 4);
        telemetry.timing(MetricDefinitions.uploadDurationMs, 350);
        telemetry.timing(MetricDefinitions.uploadDurationMs, 420);

        expect(telemetry.getCounter(MetricDefinitions.recordingsCreatedTotal), equals(5));
        expect(telemetry.getTimings(MetricDefinitions.uploadDurationMs), equals([350, 420]));
      });

      test('High-cardinality protection strips raw IDs from metric labels', () {
        telemetry.increment(
          MetricDefinitions.recordingsProcessingTotal,
          labels: {
            'stage': 'stt',
            'provider': 'deepgram',
            'patient_id': 'secret-patient-uuid-123', // MUST BE STRIPPED
            'recording_id': 'secret-recording-uuid-456', // MUST BE STRIPPED
            'request_id': 'req-789', // MUST BE STRIPPED
          },
        );

        // Verify the sanitized key does NOT include high-cardinality dimensions
        expect(telemetry.counters.keys.first, equals('recordings_processing_total{provider=deepgram,stage=stt}'));
        expect(telemetry.counters.keys.first, isNot(contains('secret-patient-uuid-123')));
        expect(telemetry.counters.keys.first, isNot(contains('secret-recording-uuid-456')));
      });

      test('Provider metrics record success, failure, 429 rate limits, and latency', () {
        // Deepgram metrics
        telemetry.increment(MetricDefinitions.deepgramRequestsTotal);
        telemetry.increment(MetricDefinitions.deepgram429Total);
        telemetry.timing(MetricDefinitions.deepgramLatencyMs, 1200);

        // Anthropic metrics
        telemetry.increment(MetricDefinitions.anthropicRequestsTotal);
        telemetry.increment(MetricDefinitions.anthropicSuccessTotal);
        telemetry.timing(MetricDefinitions.anthropicLatencyMs, 2400);

        expect(telemetry.getCounter(MetricDefinitions.deepgramRequestsTotal), equals(1));
        expect(telemetry.getCounter(MetricDefinitions.deepgram429Total), equals(1));
        expect(telemetry.getTimings(MetricDefinitions.deepgramLatencyMs), equals([1200]));

        expect(telemetry.getCounter(MetricDefinitions.anthropicRequestsTotal), equals(1));
        expect(telemetry.getCounter(MetricDefinitions.anthropicSuccessTotal), equals(1));
        expect(telemetry.getTimings(MetricDefinitions.anthropicLatencyMs), equals([2400]));
      });

      test('Retry metrics capture stage and low-cardinality error code', () {
        telemetry.increment(
          MetricDefinitions.retryAttemptTotal,
          labels: {'stage': 'stt', 'provider': 'deepgram'},
        );
        telemetry.increment(
          MetricDefinitions.retrySuccessTotal,
          labels: {'stage': 'stt', 'provider': 'deepgram'},
        );

        expect(
          telemetry.getCounter(MetricDefinitions.retryAttemptTotal, labels: {'stage': 'stt', 'provider': 'deepgram'}),
          equals(1),
        );
        expect(
          telemetry.getCounter(MetricDefinitions.retrySuccessTotal, labels: {'stage': 'stt', 'provider': 'deepgram'}),
          equals(1),
        );
      });
    });

    group('4. Error Taxonomy & User Safety (Part 9)', () {
      test('Maps all error codes to safe, generic user-facing messages', () {
        for (final code in AppErrorCode.values) {
          final msg = code.toUserMessage();
          expect(msg, isNotEmpty);
          // Verify no technical database leaks in user-facing message
          expect(msg.toLowerCase(), isNot(contains('select')));
          expect(msg.toLowerCase(), isNot(contains('insert')));
          expect(msg.toLowerCase(), isNot(contains('postgres')));
          expect(msg.toLowerCase(), isNot(contains('stack trace')));
          expect(msg.toLowerCase(), isNot(contains('jwt')));
        }
      });

      test('Assigns low-cardinality category to every error code', () {
        for (final code in AppErrorCode.values) {
          expect(code.category, isNotEmpty);
          expect(
            ['security', 'lifecycle', 'stt', 'llm', 'storage', 'database', 'network', 'unknown'],
            contains(code.category),
          );
        }
      });

      test('Parses strings safely into taxonomy with fallback to unknown', () {
        expect(AppErrorCode.fromString('CONSENT_REVOKED'), equals(AppErrorCode.consentRevoked));
        expect(AppErrorCode.fromString('STT_RATE_LIMIT'), equals(AppErrorCode.sttRateLimit));
        expect(AppErrorCode.fromString('UNKNOWN_XYZ'), equals(AppErrorCode.unknownProcessingError));
        expect(AppErrorCode.fromString(null), equals(AppErrorCode.unknownProcessingError));
      });
    });

    group('5. TelemetryService Error Recording & Sanitization (Part 14)', () {
      test('recordError sanitizes context and creates structured log without throwing', () {
        telemetry.recordError(
          Exception('Simulated network timeout'),
          errorCode: AppErrorCode.networkTimeout.code,
          correlationId: 'corr_test_001',
          context: {
            'patient_name': 'Confidential Patient',
            'auth_token': 'Bearer secret-jwt-token-12345',
            'retry_count': 2,
          },
        );

        expect(telemetry.errors.length, equals(1));
        final err = telemetry.errors.first;
        expect(err.errorCode, equals('NETWORK_TIMEOUT'));
        expect(err.correlationId, equals('corr_test_001'));

        // Context must be sanitized
        expect(err.context?['patient_name'], equals('[REDACTED_CLINICAL_PAYLOAD]'));
        expect(err.context?['auth_token'], equals('[REDACTED_CREDENTIAL]'));
        expect(err.context?['retry_count'], equals(2));

        // Corresponding structured log must exist
        expect(telemetry.logs.length, equals(1));
        final log = telemetry.logs.first;
        expect(log.event, equals('application_error'));
        expect(log.severity, equals(LogSeverity.error));
        expect(log.errorCode, equals('NETWORK_TIMEOUT'));
      });
    });
  });
}
