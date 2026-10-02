import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

import '../../../core/observability/observability.dart';
import '../../../core/utils/uuid_generator.dart';
import '../models/recording_errors.dart';
import '../models/recording_lifecycle_state.dart';
import '../models/recording_session_model.dart';
import 'recording_session_store.dart';

/// Platform-independent canonical recording lifecycle state manager for Medico-OPD.
/// Controls state transitions, durable local persistence, concurrency boundaries,
/// recovery discovery, and privacy-safe observability.
class RecordingStateManager {
  final RecordingSessionStore _store;
  final TelemetryService _telemetry;
  final StructuredLogger _logger;

  /// In-memory cache of active sessions indexed by consultation ID.
  final Map<String, RecordingSessionModel> _activeByConsultation = {};

  /// In-memory index of active sessions by session ID.
  final Map<String, RecordingSessionModel> _sessionsById = {};

  /// Stream controller broadcasting state updates to UI listeners.
  final StreamController<RecordingSessionModel> _sessionStreamController =
      StreamController<RecordingSessionModel>.broadcast();

  RecordingStateManager({
    RecordingSessionStore? store,
    TelemetryService? telemetry,
  })  : _store = store ?? RecordingSessionStore(),
        _telemetry = telemetry ?? Telemetry.instance,
        _logger = StructuredLogger('recording_lifecycle');

  /// Stream of all recording session state changes.
  Stream<RecordingSessionModel> get sessionStream =>
      _sessionStreamController.stream;

  /// Creates a new recording session with a stable UUIDv4.
  /// Enforces single-active-session concurrency per consultation.
  Future<RecordingSessionModel> createSession({
    required String consultationId,
    String? clinicId,
    String? doctorId,
    String? customSessionId,
  }) async {
    // 1. Concurrency Check: Verify no existing active session for this consultation
    final existingActive = await getActiveSessionForConsultation(consultationId);
    if (existingActive != null) {
      _logger.warning(
        'RECORDING_CONCURRENCY_CONFLICT',
        operation: 'create_session',
        consultationId: consultationId,
        recordingId: existingActive.recordingSessionId,
      );
      throw RecordingConcurrencyException(
        consultationId: consultationId,
        activeSessionId: existingActive.recordingSessionId,
      );
    }

    final now = DateTime.now();
    final sessionId = customSessionId ?? generateUuidV4();

    final session = RecordingSessionModel(
      recordingSessionId: sessionId,
      consultationId: consultationId,
      clinicId: clinicId,
      doctorId: doctorId,
      state: RecordingLifecycleState.idle,
      createdAt: now,
      updatedAt: now,
    );

    // 2. Persist & cache
    await _store.saveSession(session);
    _activeByConsultation[consultationId] = session;
    _sessionsById[sessionId] = session;
    _sessionStreamController.add(session);

    _telemetry.increment('recording.session.created');
    _logger.info(
      'RECORDING_SESSION_CREATED',
      operation: 'create_session',
      recordingId: sessionId,
      consultationId: consultationId,
    );

    return session;
  }

  /// Returns the current active session for [consultationId], checking memory and persistent store.
  Future<RecordingSessionModel?> getActiveSessionForConsultation(
    String consultationId,
  ) async {
    // Check in-memory first
    final inMemory = _activeByConsultation[consultationId];
    if (inMemory != null && inMemory.state.isInFlight) {
      return inMemory;
    }

    // Check disk store
    final fromStore =
        await _store.loadActiveSessionForConsultation(consultationId);
    if (fromStore != null) {
      _activeByConsultation[consultationId] = fromStore;
      _sessionsById[fromStore.recordingSessionId] = fromStore;
    }
    return fromStore;
  }

  /// Retrieves a session by its [sessionId].
  Future<RecordingSessionModel?> getSession(String sessionId) async {
    if (_sessionsById.containsKey(sessionId)) {
      return _sessionsById[sessionId];
    }
    final session = await _store.loadSession(sessionId);
    if (session != null) {
      _sessionsById[sessionId] = session;
      if (session.state.isInFlight) {
        _activeByConsultation[session.consultationId] = session;
      }
    }
    return session;
  }

  /// Executes an explicit state transition with deterministic validation and persistence.
  Future<RecordingSessionModel> transitionTo(
    String sessionId,
    RecordingLifecycleState targetState, {
    String? localFilePath,
    String? remoteObjectPath,
    int? durationSeconds,
    int? bytesWritten,
    String? checksum,
    double? uploadProgress,
    int? retryCount,
    String? lastErrorCategory,
    String? lastErrorMessage,
    Map<String, dynamic>? recoveryMetadata,
  }) async {
    final currentSession = await getSession(sessionId);
    if (currentSession == null) {
      throw RecordingSessionNotFoundException(sessionId);
    }

    // Idempotency: Transitioning to the exact same state without metadata change
    if (currentSession.state == targetState) {
      debugPrint('[RecordingStateManager] Idempotent transition to $targetState for $sessionId');
      return currentSession;
    }

    // Validate transition
    if (!currentSession.state.canTransitionTo(targetState)) {
      _logger.warning(
        'RECORDING_INVALID_TRANSITION',
        operation: 'transition_to',
        recordingId: sessionId,
        consultationId: currentSession.consultationId,
        errorCode: AppErrorCode.conflictError.code,
      );
      throw RecordingTransitionException(
        fromState: currentSession.state.toCanonicalString(),
        toState: targetState.toCanonicalString(),
      );
    }

    final now = DateTime.now();
    DateTime? startedAt = currentSession.startedAt;
    DateTime? pausedAt = currentSession.pausedAt;
    DateTime? stoppedAt = currentSession.stoppedAt;

    if (targetState == RecordingLifecycleState.recording && startedAt == null) {
      startedAt = now;
    } else if (targetState == RecordingLifecycleState.paused) {
      pausedAt = now;
    } else if (targetState == RecordingLifecycleState.stopping ||
        targetState == RecordingLifecycleState.recorded) {
      stoppedAt ??= now;
    }

    final updatedSession = currentSession.copyWith(
      state: targetState,
      updatedAt: now,
      startedAt: startedAt,
      pausedAt: pausedAt,
      stoppedAt: stoppedAt,
      localFilePath: localFilePath ?? currentSession.localFilePath,
      remoteObjectPath: remoteObjectPath ?? currentSession.remoteObjectPath,
      durationSeconds: durationSeconds ?? currentSession.durationSeconds,
      bytesWritten: bytesWritten ?? currentSession.bytesWritten,
      checksum: checksum ?? currentSession.checksum,
      uploadProgress: uploadProgress ?? currentSession.uploadProgress,
      retryCount: retryCount ?? currentSession.retryCount,
      lastErrorCategory: lastErrorCategory ?? currentSession.lastErrorCategory,
      lastErrorMessage: lastErrorMessage ?? currentSession.lastErrorMessage,
      recoveryMetadata: recoveryMetadata ?? currentSession.recoveryMetadata,
    );

    // Atomically persist state
    await _store.saveSession(updatedSession);

    // Update in-memory caches
    _sessionsById[sessionId] = updatedSession;
    if (targetState.isTerminal) {
      _activeByConsultation.remove(updatedSession.consultationId);
    } else {
      _activeByConsultation[updatedSession.consultationId] = updatedSession;
    }

    // Broadcast update
    _sessionStreamController.add(updatedSession);

    // Observability events
    _logTransitionMetrics(currentSession.state, targetState, updatedSession);

    return updatedSession;
  }

  // --- Convenience Lifecycle Transitions ---

  /// Transitions session: IDLE -> PREPARING.
  Future<RecordingSessionModel> prepareRecording(String sessionId) async {
    return transitionTo(sessionId, RecordingLifecycleState.preparing);
  }

  /// Transitions session: PREPARING -> RECORDING.
  Future<RecordingSessionModel> startRecording(
    String sessionId, {
    required String localFilePath,
  }) async {
    return transitionTo(
      sessionId,
      RecordingLifecycleState.recording,
      localFilePath: localFilePath,
    );
  }

  /// Transitions session: RECORDING -> PAUSED. Idempotent if already paused.
  Future<RecordingSessionModel> pauseRecording(String sessionId) async {
    final session = await getSession(sessionId);
    if (session?.state == RecordingLifecycleState.paused) return session!;
    return transitionTo(sessionId, RecordingLifecycleState.paused);
  }

  /// Transitions session: PAUSED -> RECORDING. Idempotent if already recording.
  Future<RecordingSessionModel> resumeRecording(String sessionId) async {
    final session = await getSession(sessionId);
    if (session?.state == RecordingLifecycleState.recording) return session!;
    return transitionTo(sessionId, RecordingLifecycleState.recording);
  }

  /// Updates session recovery metadata and persists to local store.
  Future<RecordingSessionModel> updateSessionMetadata(
    String sessionId, {
    required Map<String, dynamic> metadata,
  }) async {
    final session = await getSession(sessionId);
    if (session == null) {
      throw StateError('Recording session "$sessionId" not found.');
    }
    final updated = session.copyWith(
      updatedAt: DateTime.now(),
      recoveryMetadata: {
        ...?session.recoveryMetadata,
        ...metadata,
      },
    );
    await _store.saveSession(updated);
    _sessionsById[sessionId] = updated;
    _activeByConsultation[updated.consultationId] = updated;
    _sessionStreamController.add(updated);
    return updated;
  }

  /// Transitions session to STOPPING.
  Future<RecordingSessionModel> stopRecording(
    String sessionId, {
    int? durationSeconds,
    int? bytesWritten,
  }) async {
    final session = await getSession(sessionId);
    if (session?.state == RecordingLifecycleState.stopping ||
        session?.state == RecordingLifecycleState.recorded) {
      return session!;
    }
    return transitionTo(
      sessionId,
      RecordingLifecycleState.stopping,
      durationSeconds: durationSeconds,
      bytesWritten: bytesWritten,
    );
  }

  /// Transitions session: STOPPING -> RECORDED.
  Future<RecordingSessionModel> markRecorded(
    String sessionId, {
    required String checksum,
    int? durationSeconds,
    int? bytesWritten,
  }) async {
    return transitionTo(
      sessionId,
      RecordingLifecycleState.recorded,
      checksum: checksum,
      durationSeconds: durationSeconds,
      bytesWritten: bytesWritten,
    );
  }

  /// Transitions session: RECORDED -> UPLOAD_PENDING.
  Future<RecordingSessionModel> markUploadPending(String sessionId) async {
    final session = await getSession(sessionId);
    if (session?.state == RecordingLifecycleState.uploadPending) return session!;
    return transitionTo(sessionId, RecordingLifecycleState.uploadPending);
  }

  /// Transitions session: UPLOAD_PENDING -> UPLOADING.
  Future<RecordingSessionModel> markUploading(
    String sessionId, {
    double? uploadProgress,
  }) async {
    return transitionTo(
      sessionId,
      RecordingLifecycleState.uploading,
      uploadProgress: uploadProgress,
    );
  }

  /// Transitions session: UPLOADING -> UPLOADED.
  Future<RecordingSessionModel> markUploaded(
    String sessionId, {
    required String remoteObjectPath,
  }) async {
    return transitionTo(
      sessionId,
      RecordingLifecycleState.uploaded,
      remoteObjectPath: remoteObjectPath,
      uploadProgress: 1.0,
    );
  }

  /// Transitions session: UPLOADED -> PROCESSING.
  Future<RecordingSessionModel> markProcessing(String sessionId) async {
    return transitionTo(sessionId, RecordingLifecycleState.processing);
  }

  /// Transitions session: PROCESSING -> COMPLETED (Terminal State).
  Future<RecordingSessionModel> markCompleted(String sessionId) async {
    return transitionTo(sessionId, RecordingLifecycleState.completed);
  }

  /// Transitions session to FAILED from any permitted state.
  Future<RecordingSessionModel> markFailed(
    String sessionId, {
    required String errorCategory,
    required String errorMessage,
  }) async {
    return transitionTo(
      sessionId,
      RecordingLifecycleState.failed,
      lastErrorCategory: errorCategory,
      lastErrorMessage: errorMessage,
    );
  }

  /// Transitions session to RECOVERY_REQUIRED.
  Future<RecordingSessionModel> markRecoveryRequired(
    String sessionId, {
    Map<String, dynamic>? recoveryMetadata,
  }) async {
    return transitionTo(
      sessionId,
      RecordingLifecycleState.recoveryRequired,
      recoveryMetadata: recoveryMetadata,
    );
  }

  // --- Recovery Discovery Mechanics ---

  /// Discovers unfinished sessions across the device sandbox.
  /// Verifies local audio file integrity and classifies each session into:
  /// - [RecordingLifecycleState.recoveryRequired] if local audio file exists.
  /// - [RecordingLifecycleState.failed] if local audio file is missing.
  /// Completed sessions are excluded from active recovery.
  Future<List<RecordingSessionModel>> discoverRecoverableSessions() async {
    final allSessions = await _store.loadAllSessions();
    final recoverableSessions = <RecordingSessionModel>[];

    for (final session in allSessions) {
      // Completed sessions are ignored
      if (session.state == RecordingLifecycleState.completed) {
        continue;
      }

      // Check if session was interrupted in an active in-flight state
      final wasInFlight = session.state == RecordingLifecycleState.recording ||
          session.state == RecordingLifecycleState.paused ||
          session.state == RecordingLifecycleState.stopping ||
          session.state == RecordingLifecycleState.uploading ||
          session.state == RecordingLifecycleState.recoveryRequired;

      if (!wasInFlight && session.state != RecordingLifecycleState.recorded &&
          session.state != RecordingLifecycleState.uploadPending) {
        continue;
      }

      // Verify local file existence
      final localPath = session.localFilePath;
      final fileExists = localPath != null && await File(localPath).exists();

      if (fileExists) {
        // File exists: classify as recoveryRequired if not already recorded/pending
        if (session.state != RecordingLifecycleState.recorded &&
            session.state != RecordingLifecycleState.uploadPending &&
            session.state != RecordingLifecycleState.recoveryRequired) {
          final updated = await transitionTo(
            session.recordingSessionId,
            RecordingLifecycleState.recoveryRequired,
            recoveryMetadata: {
              'interruptedFromState': session.state.toCanonicalString(),
              'discoveredAt': DateTime.now().toIso8601String(),
            },
          );
          recoverableSessions.add(updated);
        } else {
          recoverableSessions.add(session);
        }
      } else {
        // File missing: mark failed with recoverable classification
        _logger.warning(
          'RECORDING_RECOVERY_FILE_MISSING',
          operation: 'discover_recovery',
          recordingId: session.recordingSessionId,
          consultationId: session.consultationId,
          errorCode: AppErrorCode.storageObjectNotFound.code,
        );
        final failed = await markFailed(
          session.recordingSessionId,
          errorCategory: AppErrorCode.storageObjectNotFound.code,
          errorMessage: 'Local recording audio file was not found on device disk.',
        );
        recoverableSessions.add(failed);
      }
    }

    _logger.info(
      'RECORDING_RECOVERY_DISCOVERY_COMPLETED',
      operation: 'discover_recovery',
      durationMs: recoverableSessions.length,
    );

    return recoverableSessions;
  }

  /// Explicitly resumes a session that is in RECOVERY_REQUIRED.
  /// Reuses the existing [sessionId] without creating a duplicate session.
  Future<RecordingSessionModel> recoverSession(
    String sessionId, {
    required RecordingLifecycleState resumeTargetState,
  }) async {
    final current = await getSession(sessionId);
    if (current == null) {
      throw RecordingSessionNotFoundException(sessionId);
    }

    if (current.state != RecordingLifecycleState.recoveryRequired) {
      throw RecordingRecoveryException(
        'Session $sessionId is in state "${current.state.toCanonicalString()}", '
        'expected "recovery_required" to execute recovery.',
      );
    }

    _logger.info(
      'RECORDING_RECOVERY_STARTED',
      operation: 'recover_session',
      recordingId: sessionId,
      consultationId: current.consultationId,
    );

    final recovered = await transitionTo(sessionId, resumeTargetState);

    _telemetry.increment('recording.recovery_completed');
    _logger.info(
      'RECORDING_RECOVERY_COMPLETED',
      operation: 'recover_session',
      recordingId: sessionId,
      consultationId: current.consultationId,
    );

    return recovered;
  }

  /// Discards a session and optionally purges its local file.
  Future<void> discardSession(
    String sessionId, {
    bool purgeLocalFile = true,
  }) async {
    final session = await getSession(sessionId);
    if (session == null) return;

    if (purgeLocalFile && session.localFilePath != null) {
      try {
        final file = File(session.localFilePath!);
        if (await file.exists()) {
          await file.delete();
          debugPrint('[RecordingStateManager] Purged local file: ${session.localFilePath}');
        }
      } catch (e) {
        debugPrint('[RecordingStateManager] Error deleting audio file: $e');
      }
    }

    await _store.deleteSession(sessionId);
    _sessionsById.remove(sessionId);
    _activeByConsultation.remove(session.consultationId);

    _logger.info(
      'RECORDING_SESSION_DISCARDED',
      operation: 'discard_session',
      recordingId: sessionId,
      consultationId: session.consultationId,
    );
  }

  void _logTransitionMetrics(
    RecordingLifecycleState from,
    RecordingLifecycleState to,
    RecordingSessionModel session,
  ) {
    switch (to) {
      case RecordingLifecycleState.recording:
        _telemetry.increment('recording.started');
        _logger.info('RECORDING_STARTED', operation: 'state_transition', recordingId: session.recordingSessionId);
        break;
      case RecordingLifecycleState.paused:
        _telemetry.increment('recording.paused');
        _logger.info('RECORDING_PAUSED', operation: 'state_transition', recordingId: session.recordingSessionId);
        break;
      case RecordingLifecycleState.stopping:
        _telemetry.increment('recording.stop_requested');
        break;
      case RecordingLifecycleState.completed:
        _telemetry.increment('recording.completed');
        _logger.info('RECORDING_COMPLETED', operation: 'state_transition', recordingId: session.recordingSessionId);
        break;
      case RecordingLifecycleState.recoveryRequired:
        _telemetry.increment('recording.recovery_required');
        _logger.warning('RECORDING_RECOVERY_REQUIRED', operation: 'state_transition', recordingId: session.recordingSessionId);
        break;
      case RecordingLifecycleState.failed:
        _telemetry.increment('recording.failure');
        _logger.error(
          'RECORDING_FAILURE',
          operation: 'state_transition',
          recordingId: session.recordingSessionId,
          errorCode: session.lastErrorCategory ?? AppErrorCode.unknownProcessingError.code,
        );
        break;
      default:
        break;
    }
  }

  /// Disposes state manager streams.
  Future<void> dispose() async {
    await _sessionStreamController.close();
  }
}

/// Specialized internal exception when session ID is not found.
class RecordingSessionNotFoundException extends RecordingException {
  RecordingSessionNotFoundException(String sessionId)
      : super(
          message: 'Recording session $sessionId was not found.',
          errorCode: AppErrorCode.recordingNotFound,
          technicalDetails: 'RecordingSession ID $sessionId not in memory or store',
        );
}
