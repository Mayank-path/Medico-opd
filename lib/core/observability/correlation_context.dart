import 'package:medico_opd/core/utils/uuid_generator.dart';

/// Context managing request and correlation identity across the clinical documentation pipeline.
///
/// Correlation ID:
/// Preserved across the entire lifecycle:
/// upload -> recording registration -> worker claim -> STT -> transcript persistence -> AI structuring -> draft persistence -> retries.
///
/// Request ID:
/// Generated per individual HTTP / API call for tracing single execution attempts.
class CorrelationContext {
  final String correlationId;
  final String requestId;
  final int attemptCount;

  const CorrelationContext({
    required this.correlationId,
    required this.requestId,
    this.attemptCount = 1,
  });

  /// Creates a new root correlation context for a consultation workflow.
  factory CorrelationContext.createRoot() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final uuid = generateUuidV4().substring(0, 8);
    return CorrelationContext(
      correlationId: 'corr_${now}_$uuid',
      requestId: 'req_${now}_$uuid',
      attemptCount: 1,
    );
  }

  /// Creates a new request context for a retry or subsequent stage within the same correlation lifecycle.
  CorrelationContext nextAttempt() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final uuid = generateUuidV4().substring(0, 8);
    return CorrelationContext(
      correlationId: correlationId, // Strictly preserved
      requestId: 'req_${now}_$uuid', // New for this attempt
      attemptCount: attemptCount + 1,
    );
  }

  /// Parses or adopts existing IDs from incoming headers or upstream responses.
  factory CorrelationContext.fromHeaders(Map<String, String> headers) {
    String? corrId;
    String? reqId;

    headers.forEach((key, value) {
      final lowerKey = key.toLowerCase();
      if (lowerKey == 'x-correlation-id') corrId = value;
      if (lowerKey == 'x-request-id') reqId = value;
    });

    final now = DateTime.now().millisecondsSinceEpoch;
    final uuid = generateUuidV4().substring(0, 8);

    return CorrelationContext(
      correlationId: corrId ?? 'corr_${now}_$uuid',
      requestId: reqId ?? 'req_${now}_$uuid',
      attemptCount: 1,
    );
  }

  /// Returns HTTP headers to propagate correlation downstream.
  Map<String, String> toHeaders() {
    return {
      'X-Correlation-ID': correlationId,
      'X-Request-ID': requestId,
    };
  }
}
