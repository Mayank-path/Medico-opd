/// Canonical platform-independent recording lifecycle state machine.
/// Block 1 foundation for durable mobile recording state.
enum RecordingLifecycleState {
  idle,
  preparing,
  recording,
  paused,
  stopping,
  recorded,
  uploadPending,
  uploading,
  uploaded,
  processing,
  completed,
  failed,
  recoveryRequired;

  /// Serializes enum to canonical snake_case string.
  String toCanonicalString() {
    switch (this) {
      case RecordingLifecycleState.idle:
        return 'idle';
      case RecordingLifecycleState.preparing:
        return 'preparing';
      case RecordingLifecycleState.recording:
        return 'recording';
      case RecordingLifecycleState.paused:
        return 'paused';
      case RecordingLifecycleState.stopping:
        return 'stopping';
      case RecordingLifecycleState.recorded:
        return 'recorded';
      case RecordingLifecycleState.uploadPending:
        return 'upload_pending';
      case RecordingLifecycleState.uploading:
        return 'uploading';
      case RecordingLifecycleState.uploaded:
        return 'uploaded';
      case RecordingLifecycleState.processing:
        return 'processing';
      case RecordingLifecycleState.completed:
        return 'completed';
      case RecordingLifecycleState.failed:
        return 'failed';
      case RecordingLifecycleState.recoveryRequired:
        return 'recovery_required';
    }
  }

  /// Parses canonical snake_case string to enum.
  static RecordingLifecycleState fromCanonicalString(String value) {
    switch (value.trim().toLowerCase()) {
      case 'idle':
        return RecordingLifecycleState.idle;
      case 'preparing':
        return RecordingLifecycleState.preparing;
      case 'recording':
        return RecordingLifecycleState.recording;
      case 'paused':
        return RecordingLifecycleState.paused;
      case 'stopping':
        return RecordingLifecycleState.stopping;
      case 'recorded':
        return RecordingLifecycleState.recorded;
      case 'upload_pending':
      case 'uploadpending':
        return RecordingLifecycleState.uploadPending;
      case 'uploading':
        return RecordingLifecycleState.uploading;
      case 'uploaded':
        return RecordingLifecycleState.uploaded;
      case 'processing':
        return RecordingLifecycleState.processing;
      case 'completed':
        return RecordingLifecycleState.completed;
      case 'failed':
        return RecordingLifecycleState.failed;
      case 'recovery_required':
      case 'recoveryrequired':
        return RecordingLifecycleState.recoveryRequired;
      default:
        throw ArgumentError('Unknown RecordingLifecycleState: $value');
    }
  }

  /// Returns true if this state is a terminal state.
  bool get isTerminal =>
      this == RecordingLifecycleState.completed || this == RecordingLifecycleState.failed;

  /// Returns true if this state represents an active recording or in-flight session.
  bool get isInFlight =>
      this != RecordingLifecycleState.idle &&
      this != RecordingLifecycleState.completed &&
      this != RecordingLifecycleState.failed;

  /// Set of permitted next states from this state.
  Set<RecordingLifecycleState> get validNextStates {
    switch (this) {
      case RecordingLifecycleState.idle:
        return const {RecordingLifecycleState.preparing};

      case RecordingLifecycleState.preparing:
        return const {
          RecordingLifecycleState.recording,
          RecordingLifecycleState.failed,
        };

      case RecordingLifecycleState.recording:
        return const {
          RecordingLifecycleState.paused,
          RecordingLifecycleState.stopping,
          RecordingLifecycleState.recoveryRequired,
          RecordingLifecycleState.failed,
        };

      case RecordingLifecycleState.paused:
        return const {
          RecordingLifecycleState.recording,
          RecordingLifecycleState.stopping,
          RecordingLifecycleState.failed,
        };

      case RecordingLifecycleState.stopping:
        return const {
          RecordingLifecycleState.recorded,
          RecordingLifecycleState.failed,
          RecordingLifecycleState.recoveryRequired,
        };

      case RecordingLifecycleState.recorded:
        return const {
          RecordingLifecycleState.uploadPending,
        };

      case RecordingLifecycleState.uploadPending:
        return const {
          RecordingLifecycleState.uploading,
        };

      case RecordingLifecycleState.uploading:
        return const {
          RecordingLifecycleState.uploaded,
          RecordingLifecycleState.uploadPending,
          RecordingLifecycleState.failed,
          RecordingLifecycleState.recoveryRequired,
        };

      case RecordingLifecycleState.uploaded:
        return const {
          RecordingLifecycleState.processing,
        };

      case RecordingLifecycleState.processing:
        return const {
          RecordingLifecycleState.completed,
          RecordingLifecycleState.failed,
        };

      case RecordingLifecycleState.failed:
        return const {
          RecordingLifecycleState.recoveryRequired,
          RecordingLifecycleState.preparing,
          RecordingLifecycleState.uploadPending,
          RecordingLifecycleState.processing,
        };

      case RecordingLifecycleState.recoveryRequired:
        return const {
          RecordingLifecycleState.preparing,
          RecordingLifecycleState.recording,
          RecordingLifecycleState.recorded,
          RecordingLifecycleState.uploadPending,
        };

      case RecordingLifecycleState.completed:
        return const {};
    }
  }

  /// Validates whether transitioning to [target] is permitted.
  bool canTransitionTo(RecordingLifecycleState target) {
    return validNextStates.contains(target);
  }
}
