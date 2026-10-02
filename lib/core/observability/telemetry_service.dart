import 'package:flutter/foundation.dart';
import 'package:medico_opd/core/observability/error_taxonomy.dart';
import 'package:medico_opd/core/observability/metric_definitions.dart';
import 'package:medico_opd/core/observability/redaction_helper.dart';
import 'package:medico_opd/core/observability/structured_logger.dart';

class RecordedError {
  final dynamic error;
  final StackTrace? stackTrace;
  final String? errorCode;
  final String? correlationId;
  final Map<String, dynamic>? context;
  final DateTime timestamp;

  RecordedError({
    required this.error,
    this.stackTrace,
    this.errorCode,
    this.correlationId,
    this.context,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().toUtc();
}

/// Abstract Telemetry Service interface.
/// Decouples operational observability from external SaaS vendors (Sentry, OpenTelemetry, Datadog).
abstract class TelemetryService {
  void log(StructuredLogEntry entry);

  void increment(
    String metricName, {
    Map<String, String>? labels,
    int value = 1,
  });

  void timing(
    String metricName,
    int durationMs, {
    Map<String, String>? labels,
  });

  void recordError(
    dynamic error, {
    StackTrace? stackTrace,
    String? errorCode,
    String? correlationId,
    Map<String, dynamic>? context,
  });
}

/// In-memory implementation of TelemetryService for testing, local execution, and diagnostics.
class InMemoryTelemetryService implements TelemetryService {
  final List<StructuredLogEntry> logs = [];
  final Map<String, int> counters = {};
  final Map<String, List<int>> timings = {};
  final List<RecordedError> errors = [];

  void reset() {
    logs.clear();
    counters.clear();
    timings.clear();
    errors.clear();
  }

  @override
  void log(StructuredLogEntry entry) {
    logs.add(entry);
    if (kDebugMode) {
      debugPrint(entry.toString());
    }
  }

  @override
  void increment(
    String metricName, {
    Map<String, String>? labels,
    int value = 1,
  }) {
    final cleanLabels = MetricDefinitions.sanitizeLabels(labels);
    final key = _buildMetricKey(metricName, cleanLabels);
    counters[key] = (counters[key] ?? 0) + value;
  }

  @override
  void timing(
    String metricName,
    int durationMs, {
    Map<String, String>? labels,
  }) {
    final cleanLabels = MetricDefinitions.sanitizeLabels(labels);
    final key = _buildMetricKey(metricName, cleanLabels);
    timings.putIfAbsent(key, () => []).add(durationMs);
  }

  @override
  void recordError(
    dynamic error, {
    StackTrace? stackTrace,
    String? errorCode,
    String? correlationId,
    Map<String, dynamic>? context,
  }) {
    final sanitizedContext = context != null
        ? SensitiveDataRedactor.sanitizeValue(context) as Map<String, dynamic>
        : null;

    final recorded = RecordedError(
      error: error,
      stackTrace: stackTrace,
      errorCode: errorCode ?? AppErrorCode.unknownProcessingError.code,
      correlationId: correlationId,
      context: sanitizedContext,
    );
    errors.add(recorded);

    // Also record structured error log
    log(StructuredLogEntry(
      event: 'application_error',
      component: 'telemetry_service',
      operation: 'record_error',
      severity: LogSeverity.error,
      correlationId: correlationId,
      errorCode: recorded.errorCode,
      metadata: {
        'error_type': error.runtimeType.toString(),
        ...?sanitizedContext != null ? {'context': sanitizedContext} : null,
      },
    ));
  }

  String _buildMetricKey(String name, Map<String, String> labels) {
    if (labels.isEmpty) return name;
    final sortedPairs = labels.entries.map((e) => '${e.key}=${e.value}').toList()..sort();
    return '$name{${sortedPairs.join(',')}}';
  }

  int getCounter(String metricName, {Map<String, String>? labels}) {
    final clean = MetricDefinitions.sanitizeLabels(labels);
    final key = _buildMetricKey(metricName, clean);
    return counters[key] ?? 0;
  }

  List<int> getTimings(String metricName, {Map<String, String>? labels}) {
    final clean = MetricDefinitions.sanitizeLabels(labels);
    final key = _buildMetricKey(metricName, clean);
    return timings[key] ?? const [];
  }
}

/// Global registry for the active TelemetryService.
class Telemetry {
  static TelemetryService _instance = InMemoryTelemetryService();

  static TelemetryService get instance => _instance;

  static void setInstance(TelemetryService service) {
    _instance = service;
  }

  static void reset() {
    if (_instance is InMemoryTelemetryService) {
      (_instance as InMemoryTelemetryService).reset();
    }
  }
}
