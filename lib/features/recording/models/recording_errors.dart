import '../../../core/observability/error_taxonomy.dart';

/// Base class for all domain-level recording exceptions in Medico-OPD.
/// Safe for user-facing display without exposing tokens, hostnames, or DB internals.
abstract class RecordingException implements Exception {
  final String message;
  final AppErrorCode errorCode;
  final String? technicalDetails;

  const RecordingException({
    required this.message,
    required this.errorCode,
    this.technicalDetails,
  });

  @override
  String toString() => '$runtimeType: $message (${errorCode.code})';
}

/// Thrown when an invalid state transition is attempted on the state machine.
class RecordingTransitionException extends RecordingException {
  final String fromState;
  final String toState;

  RecordingTransitionException({
    required this.fromState,
    required this.toState,
    String? reason,
  }) : super(
          message: 'Cannot transition recording session from "$fromState" to "$toState"'
              '${reason != null ? ': $reason' : '.'}',
          errorCode: AppErrorCode.conflictError,
          technicalDetails: 'Invalid state transition: $fromState -> $toState',
        );
}

/// Thrown when local session persistence fails to write or read state.
class RecordingPersistenceException extends RecordingException {
  RecordingPersistenceException(String message, {Object? cause})
      : super(
          message: 'Recording state could not be saved to local storage.',
          errorCode: AppErrorCode.storageFetchFailed,
          technicalDetails: cause != null ? '$message: $cause' : message,
        );
}

/// Thrown when audio hardware or recording permissions fail during preparation.
class RecordingInitializationException extends RecordingException {
  RecordingInitializationException(String message, {String? details})
      : super(
          message: message,
          errorCode: AppErrorCode.recordingNotFound,
          technicalDetails: details,
        );
}

/// Thrown during recovery when the expected local audio file is missing on disk.
class RecordingFileMissingException extends RecordingException {
  final String expectedPath;

  RecordingFileMissingException(this.expectedPath)
      : super(
          message: 'The local recording audio file could not be found for recovery.',
          errorCode: AppErrorCode.storageObjectNotFound,
          technicalDetails: 'Expected audio file missing: $expectedPath',
        );
}

/// Thrown when an interrupted recording session cannot be safely recovered.
class RecordingRecoveryException extends RecordingException {
  RecordingRecoveryException(String message, {String? details})
      : super(
          message: message,
          errorCode: AppErrorCode.claimFailed,
          technicalDetails: details,
        );
}

/// Thrown when attempting to start a recording for a consultation that already
/// has an active, non-terminal recording session.
class RecordingConcurrencyException extends RecordingException {
  final String consultationId;
  final String activeSessionId;

  RecordingConcurrencyException({
    required this.consultationId,
    required this.activeSessionId,
  }) : super(
          message: 'An active recording session is already in progress for this consultation.',
          errorCode: AppErrorCode.recordingAlreadyProcessing,
          technicalDetails: 'Conflict on consultation $consultationId with session $activeSessionId',
        );
}

/// Generic catch-all recording exception.
class RecordingUnknownException extends RecordingException {
  RecordingUnknownException(String message, {Object? cause})
      : super(
          message: 'An unexpected recording error occurred.',
          errorCode: AppErrorCode.unknownProcessingError,
          technicalDetails: cause != null ? '$message: $cause' : message,
        );
}
