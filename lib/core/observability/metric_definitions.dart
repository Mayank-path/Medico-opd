/// Catalog of standard metric definitions and high-cardinality guards.
/// Enforces low-cardinality label dimensions to prevent metric index explosion.
class MetricDefinitions {
  // --- Recording Lifecycle Metrics ---
  static const String recordingsCreatedTotal = 'recordings_created_total';
  static const String recordingsUploadedTotal = 'recordings_uploaded_total';
  static const String recordingsProcessingTotal = 'recordings_processing_total';
  static const String recordingsCompletedTotal = 'recordings_completed_total';
  static const String recordingsFailedTotal = 'recordings_failed_total';
  static const String recordingsRetriedTotal = 'recordings_retried_total';
  static const String recordingsReclaimedTotal = 'recordings_reclaimed_total';

  // --- Processing Latency Metrics (ms) ---
  static const String uploadDurationMs = 'upload_duration_ms';
  static const String claimLatencyMs = 'claim_latency_ms';
  static const String sttDurationMs = 'stt_duration_ms';
  static const String transcriptPersistenceMs = 'transcript_persistence_ms';
  static const String llmDurationMs = 'llm_duration_ms';
  static const String draftPersistenceMs = 'draft_persistence_ms';
  static const String totalProcessingDurationMs = 'total_processing_duration_ms';

  // --- Deepgram Provider Metrics ---
  static const String deepgramRequestsTotal = 'deepgram_requests_total';
  static const String deepgramSuccessTotal = 'deepgram_success_total';
  static const String deepgramFailureTotal = 'deepgram_failure_total';
  static const String deepgram429Total = 'deepgram_429_total';
  static const String deepgram5xxTotal = 'deepgram_5xx_total';
  static const String deepgramTimeoutTotal = 'deepgram_timeout_total';
  static const String deepgramLatencyMs = 'deepgram_latency_ms';

  // --- Anthropic Provider Metrics ---
  static const String anthropicRequestsTotal = 'anthropic_requests_total';
  static const String anthropicSuccessTotal = 'anthropic_success_total';
  static const String anthropicFailureTotal = 'anthropic_failure_total';
  static const String anthropic429Total = 'anthropic_429_total';
  static const String anthropic5xxTotal = 'anthropic_5xx_total';
  static const String anthropicTimeoutTotal = 'anthropic_timeout_total';
  static const String anthropicLatencyMs = 'anthropic_latency_ms';

  // --- Retry Metrics ---
  static const String retryAttemptTotal = 'retry_attempt_total';
  static const String retrySuccessTotal = 'retry_success_total';
  static const String retryTerminalFailureTotal = 'retry_terminal_failure_total';

  // --- Database & Client Query Latency Metrics ---
  static const String patientQueryLatencyMs = 'patient_query_latency_ms';
  static const String consultationQueryLatencyMs = 'consultation_query_latency_ms';
  static const String patientSearchLatencyMs = 'patient_search_latency_ms';

  // --- Storage Lifecycle & Retention Metrics (Block 1G) ---
  static const String storageCleanupRunsTotal = 'storage_cleanup_runs_total';
  static const String storageCleanupCandidatesTotal = 'storage_cleanup_candidates_total';
  static const String storageCleanupDeletedTotal = 'storage_cleanup_deleted_total';
  static const String storageCleanupFailedTotal = 'storage_cleanup_failed_total';
  static const String storageOrphansDetectedTotal = 'storage_orphans_detected_total';
  static const String storageOrphansDeletedTotal = 'storage_orphans_deleted_total';
  static const String storageCleanupDurationMs = 'storage_cleanup_duration_ms';

  // Allowed Low-Cardinality Label Keys
  static const Set<String> allowedLabelKeys = {
    'component',
    'stage',
    'provider',
    'error_code',
    'status',
    'retryable',
    'method',
    'mode',
    'category',
  };

  // Forbidden High-Cardinality Keys
  static const Set<String> forbiddenLabelKeys = {
    'patient_id',
    'patient_name',
    'consultation_id',
    'recording_id',
    'request_id',
    'correlation_id',
    'user_id',
    'doctor_id',
    'clinic_id',
    'storage_path',
    'audio_url',
    'prompt',
    'transcript',
  };

  /// Sanitizes label map to strictly enforce low-cardinality rules.
  /// Throws or removes high-cardinality items to protect TSDB index.
  static Map<String, String> sanitizeLabels(Map<String, String>? labels) {
    if (labels == null || labels.isEmpty) return const {};

    final cleanLabels = <String, String>{};
    for (final entry in labels.entries) {
      final key = entry.key.toLowerCase();
      if (forbiddenLabelKeys.contains(key)) {
        // High-cardinality labels belong in structured logs/traces, NEVER metrics!
        continue;
      }
      if (allowedLabelKeys.contains(key)) {
        cleanLabels[key] = entry.value;
      }
    }
    return cleanLabels;
  }
}
