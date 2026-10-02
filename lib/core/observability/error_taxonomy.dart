/// Stable, privacy-safe internal error code taxonomy for Medico-OPD.
/// Maps low-level exceptions into stable categories and safe user-facing messages.
enum AppErrorCode {
  // Consent & Access
  consentRevoked('CONSENT_REVOKED'),
  consentRequired('CONSENT_REQUIRED'),
  unauthorizedAccess('UNAUTHORIZED_ACCESS'),
  crossTenantAccessDenied('CROSS_TENANT_ACCESS_DENIED'),

  // Recording & Claiming
  recordingNotFound('RECORDING_NOT_FOUND'),
  recordingAlreadyProcessing('RECORDING_ALREADY_PROCESSING'),
  claimFailed('CLAIM_FAILED'),
  staleLeaseExpired('STALE_LEASE_EXPIRED'),
  maxAttemptsExceeded('MAX_ATTEMPTS_EXCEEDED'),

  // STT Provider (Deepgram)
  sttTimeout('STT_TIMEOUT'),
  sttRateLimit('STT_RATE_LIMIT'),
  sttProviderError('STT_PROVIDER_ERROR'),
  transcriptPersistFailed('TRANSCRIPT_PERSIST_FAILED'),

  // LLM Provider (Claude)
  llmTimeout('LLM_TIMEOUT'),
  llmRateLimit('LLM_RATE_LIMIT'),
  llmProviderError('LLM_PROVIDER_ERROR'),
  aiSchemaInvalid('AI_SCHEMA_INVALID'),
  draftPersistFailed('DRAFT_PERSIST_FAILED'),

  // Storage & Database
  storageUploadFailed('STORAGE_UPLOAD_FAILED'),
  storageFetchFailed('STORAGE_FETCH_FAILED'),
  storageObjectNotFound('STORAGE_OBJECT_NOT_FOUND'),
  storageDeleteFailed('STORAGE_DELETE_FAILED'),
  storageReferenceConflict('STORAGE_REFERENCE_CONFLICT'),
  databaseError('DATABASE_ERROR'),
  conflictError('CONFLICT_ERROR'),

  // Storage Retention & Cleanup (Block 1G)
  retentionPolicyUnresolved('RETENTION_POLICY_UNRESOLVED'),
  retentionNotExpired('RETENTION_NOT_EXPIRED'),
  recordingActive('RECORDING_ACTIVE'),

  // Network & Client
  networkUnavailable('NETWORK_UNAVAILABLE'),
  networkTimeout('NETWORK_TIMEOUT'),
  clientCancelled('CLIENT_CANCELLED'),

  // Generic Catch-All
  unknownProcessingError('UNKNOWN_PROCESSING_ERROR');

  final String code;
  const AppErrorCode(this.code);

  static AppErrorCode fromString(String? code) {
    if (code == null || code.isEmpty) return AppErrorCode.unknownProcessingError;
    return AppErrorCode.values.firstWhere(
      (e) => e.code.toUpperCase() == code.toUpperCase(),
      orElse: () => AppErrorCode.unknownProcessingError,
    );
  }

  /// Returns a safe, sanitized, user-facing error message.
  /// Never exposes database schema, table names, API keys, or stack traces.
  String toUserMessage() {
    switch (this) {
      case AppErrorCode.consentRevoked:
        return 'Patient consent has been revoked. Processing stopped.';
      case AppErrorCode.consentRequired:
        return 'Patient consent is required before proceeding.';
      case AppErrorCode.unauthorizedAccess:
      case AppErrorCode.crossTenantAccessDenied:
        return 'You do not have permission to access this clinical record.';
      case AppErrorCode.recordingNotFound:
        return 'The consultation recording could not be located.';
      case AppErrorCode.recordingAlreadyProcessing:
        return 'Audio processing is already in progress for this consultation.';
      case AppErrorCode.claimFailed:
      case AppErrorCode.staleLeaseExpired:
        return 'Could not secure a processing worker. Please retry shortly.';
      case AppErrorCode.maxAttemptsExceeded:
        return 'Maximum processing retries reached. Please check the recording.';
      case AppErrorCode.sttTimeout:
      case AppErrorCode.sttRateLimit:
      case AppErrorCode.sttProviderError:
      case AppErrorCode.transcriptPersistFailed:
        return 'Speech-to-text service is temporarily unavailable. Please retry.';
      case AppErrorCode.llmTimeout:
      case AppErrorCode.llmRateLimit:
      case AppErrorCode.llmProviderError:
      case AppErrorCode.aiSchemaInvalid:
      case AppErrorCode.draftPersistFailed:
        return 'AI clinical note generation is temporarily unavailable. Your transcript is saved.';
      case AppErrorCode.storageUploadFailed:
      case AppErrorCode.storageFetchFailed:
      case AppErrorCode.storageObjectNotFound:
      case AppErrorCode.storageDeleteFailed:
      case AppErrorCode.storageReferenceConflict:
        return 'Storage service operation failed. Please check your connection.';
      case AppErrorCode.retentionPolicyUnresolved:
      case AppErrorCode.retentionNotExpired:
      case AppErrorCode.recordingActive:
        return 'Audio retention conditions not met.';
      case AppErrorCode.databaseError:
      case AppErrorCode.conflictError:
        return 'Database synchronization error. Please refresh and try again.';
      case AppErrorCode.networkUnavailable:
      case AppErrorCode.networkTimeout:
        return 'Network connection issue. Please verify your internet connection.';
      case AppErrorCode.clientCancelled:
        return 'Operation was cancelled.';
      case AppErrorCode.unknownProcessingError:
        return 'An unexpected processing error occurred. Please try again.';
    }
  }

  /// Low-cardinality category for metric dimensioning.
  String get category {
    switch (this) {
      case AppErrorCode.consentRevoked:
      case AppErrorCode.consentRequired:
      case AppErrorCode.unauthorizedAccess:
      case AppErrorCode.crossTenantAccessDenied:
        return 'security';
      case AppErrorCode.recordingNotFound:
      case AppErrorCode.recordingAlreadyProcessing:
      case AppErrorCode.claimFailed:
      case AppErrorCode.staleLeaseExpired:
      case AppErrorCode.maxAttemptsExceeded:
      case AppErrorCode.retentionPolicyUnresolved:
      case AppErrorCode.retentionNotExpired:
      case AppErrorCode.recordingActive:
        return 'lifecycle';
      case AppErrorCode.sttTimeout:
      case AppErrorCode.sttRateLimit:
      case AppErrorCode.sttProviderError:
      case AppErrorCode.transcriptPersistFailed:
        return 'stt';
      case AppErrorCode.llmTimeout:
      case AppErrorCode.llmRateLimit:
      case AppErrorCode.llmProviderError:
      case AppErrorCode.aiSchemaInvalid:
      case AppErrorCode.draftPersistFailed:
        return 'llm';
      case AppErrorCode.storageUploadFailed:
      case AppErrorCode.storageFetchFailed:
      case AppErrorCode.storageObjectNotFound:
      case AppErrorCode.storageDeleteFailed:
      case AppErrorCode.storageReferenceConflict:
        return 'storage';
      case AppErrorCode.databaseError:
      case AppErrorCode.conflictError:
        return 'database';
      case AppErrorCode.networkUnavailable:
      case AppErrorCode.networkTimeout:
      case AppErrorCode.clientCancelled:
        return 'network';
      case AppErrorCode.unknownProcessingError:
        return 'unknown';
    }
  }
}
