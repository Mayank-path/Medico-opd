import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:medico_opd/core/observability/redaction_helper.dart';

enum LogSeverity { debug, info, warning, error, critical }

/// Structured operational log event.
class StructuredLogEntry {
  final String timestamp;
  final String event;
  final LogSeverity severity;
  final String component;
  final String operation;
  final String? requestId;
  final String? correlationId;
  final String? clinicIdHash;
  final String? recordingId;
  final String? consultationId;
  final int? attemptCount;
  final int? durationMs;
  final String? errorCode;
  final Map<String, dynamic>? metadata;

  StructuredLogEntry({
    required this.event,
    required this.component,
    required this.operation,
    this.severity = LogSeverity.info,
    this.requestId,
    this.correlationId,
    this.clinicIdHash,
    this.recordingId,
    this.consultationId,
    this.attemptCount,
    this.durationMs,
    this.errorCode,
    this.metadata,
    String? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().toUtc().toIso8601String();

  Map<String, dynamic> toJson() {
    final rawMap = <String, dynamic>{
      'timestamp': timestamp,
      'event': event,
      'severity': severity.name.toUpperCase(),
      'component': component,
      'operation': operation,
      if (requestId != null) 'request_id': requestId,
      if (correlationId != null) 'correlation_id': correlationId,
      if (clinicIdHash != null) 'clinic_id_hash': clinicIdHash,
      if (recordingId != null) 'recording_id': recordingId,
      if (consultationId != null) 'consultation_id': consultationId,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (durationMs != null) 'duration_ms': durationMs,
      if (errorCode != null) 'error_code': errorCode,
      if (metadata != null) 'metadata': SensitiveDataRedactor.sanitizeValue(metadata),
    };

    return rawMap;
  }

  @override
  String toString() {
    return jsonEncode(toJson());
  }
}

/// Structured logger that safely outputs logs as JSON without leaking protected clinical information.
class StructuredLogger {
  final String component;
  final void Function(String line)? customSink;

  StructuredLogger(this.component, {this.customSink});

  void log(StructuredLogEntry entry) {
    final jsonLine = entry.toString();
    if (customSink != null) {
      customSink!(jsonLine);
    } else {
      debugPrint(jsonLine);
    }
  }

  void info(
    String event, {
    required String operation,
    String? requestId,
    String? correlationId,
    String? clinicId,
    String? recordingId,
    String? consultationId,
    int? attemptCount,
    int? durationMs,
    Map<String, dynamic>? metadata,
  }) {
    log(StructuredLogEntry(
      event: event,
      component: component,
      operation: operation,
      severity: LogSeverity.info,
      requestId: requestId,
      correlationId: correlationId,
      clinicIdHash: clinicId != null ? SensitiveDataRedactor.hashTenantId(clinicId) : null,
      recordingId: recordingId,
      consultationId: consultationId,
      attemptCount: attemptCount,
      durationMs: durationMs,
      metadata: metadata,
    ));
  }

  void warning(
    String event, {
    required String operation,
    String? requestId,
    String? correlationId,
    String? clinicId,
    String? recordingId,
    String? consultationId,
    int? attemptCount,
    int? durationMs,
    String? errorCode,
    Map<String, dynamic>? metadata,
  }) {
    log(StructuredLogEntry(
      event: event,
      component: component,
      operation: operation,
      severity: LogSeverity.warning,
      requestId: requestId,
      correlationId: correlationId,
      clinicIdHash: clinicId != null ? SensitiveDataRedactor.hashTenantId(clinicId) : null,
      recordingId: recordingId,
      consultationId: consultationId,
      attemptCount: attemptCount,
      durationMs: durationMs,
      errorCode: errorCode,
      metadata: metadata,
    ));
  }

  void error(
    String event, {
    required String operation,
    String? requestId,
    String? correlationId,
    String? clinicId,
    String? recordingId,
    String? consultationId,
    int? attemptCount,
    int? durationMs,
    String? errorCode,
    Map<String, dynamic>? metadata,
  }) {
    log(StructuredLogEntry(
      event: event,
      component: component,
      operation: operation,
      severity: LogSeverity.error,
      requestId: requestId,
      correlationId: correlationId,
      clinicIdHash: clinicId != null ? SensitiveDataRedactor.hashTenantId(clinicId) : null,
      recordingId: recordingId,
      consultationId: consultationId,
      attemptCount: attemptCount,
      durationMs: durationMs,
      errorCode: errorCode,
      metadata: metadata,
    ));
  }
}
