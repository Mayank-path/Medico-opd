import 'recording_lifecycle_state.dart';

/// Durable recording session model representing the platform-independent
/// state of a clinical audio recording across mobile app lifecycles.
class RecordingSessionModel {
  /// Stable unique identifier for the session (UUIDv4).
  /// Preserved across widget rebuilds, backgrounding, retries, and recovery.
  final String recordingSessionId;

  /// Associated consultation identifier.
  final String consultationId;

  /// Associated clinic identifier (tenant boundary).
  final String? clinicId;

  /// Associated doctor identifier.
  final String? doctorId;

  /// Path to the local raw audio file on the device sandbox.
  final String? localFilePath;

  /// Remote S3-compatible storage object path once registered.
  final String? remoteObjectPath;

  /// Current canonical state in the recording lifecycle state machine.
  final RecordingLifecycleState state;

  /// Timestamp when the recording session was first created.
  final DateTime createdAt;

  /// Timestamp when audio capture started.
  final DateTime? startedAt;

  /// Timestamp when audio capture was paused.
  final DateTime? pausedAt;

  /// Timestamp when audio capture was stopped.
  final DateTime? stoppedAt;

  /// Timestamp when this session record was last updated.
  final DateTime updatedAt;

  /// Elapsed duration of captured audio in seconds.
  final int durationSeconds;

  /// Approximate bytes written to disk if available.
  final int? bytesWritten;

  /// SHA-256 integrity checksum of the recorded audio file.
  final String? checksum;

  /// Fractional upload progress from 0.0 to 1.0.
  final double? uploadProgress;

  /// Number of retry attempts executed for upload or processing.
  final int retryCount;

  /// Category code of the last encountered error.
  final String? lastErrorCategory;

  /// Sanitized user-safe message of the last error.
  final String? lastErrorMessage;

  /// Opaque recovery metadata (e.g. prior interrupted state).
  final Map<String, dynamic>? recoveryMetadata;

  const RecordingSessionModel({
    required this.recordingSessionId,
    required this.consultationId,
    this.clinicId,
    this.doctorId,
    this.localFilePath,
    this.remoteObjectPath,
    required this.state,
    required this.createdAt,
    this.startedAt,
    this.pausedAt,
    this.stoppedAt,
    required this.updatedAt,
    this.durationSeconds = 0,
    this.bytesWritten,
    this.checksum,
    this.uploadProgress,
    this.retryCount = 0,
    this.lastErrorCategory,
    this.lastErrorMessage,
    this.recoveryMetadata,
  });

  /// Returns [durationSeconds] as a strongly-typed [Duration].
  Duration get duration => Duration(seconds: durationSeconds);

  /// Creates a copy of this session model with specified fields updated.
  RecordingSessionModel copyWith({
    String? recordingSessionId,
    String? consultationId,
    String? clinicId,
    String? doctorId,
    String? localFilePath,
    String? remoteObjectPath,
    RecordingLifecycleState? state,
    DateTime? createdAt,
    DateTime? startedAt,
    DateTime? pausedAt,
    DateTime? stoppedAt,
    DateTime? updatedAt,
    int? durationSeconds,
    int? bytesWritten,
    String? checksum,
    double? uploadProgress,
    int? retryCount,
    String? lastErrorCategory,
    String? lastErrorMessage,
    Map<String, dynamic>? recoveryMetadata,
  }) {
    return RecordingSessionModel(
      recordingSessionId: recordingSessionId ?? this.recordingSessionId,
      consultationId: consultationId ?? this.consultationId,
      clinicId: clinicId ?? this.clinicId,
      doctorId: doctorId ?? this.doctorId,
      localFilePath: localFilePath ?? this.localFilePath,
      remoteObjectPath: remoteObjectPath ?? this.remoteObjectPath,
      state: state ?? this.state,
      createdAt: createdAt ?? this.createdAt,
      startedAt: startedAt ?? this.startedAt,
      pausedAt: pausedAt ?? this.pausedAt,
      stoppedAt: stoppedAt ?? this.stoppedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      bytesWritten: bytesWritten ?? this.bytesWritten,
      checksum: checksum ?? this.checksum,
      uploadProgress: uploadProgress ?? this.uploadProgress,
      retryCount: retryCount ?? this.retryCount,
      lastErrorCategory: lastErrorCategory ?? this.lastErrorCategory,
      lastErrorMessage: lastErrorMessage ?? this.lastErrorMessage,
      recoveryMetadata: recoveryMetadata ?? this.recoveryMetadata,
    );
  }

  /// Serializes this session model to a JSON map for durable persistence.
  Map<String, dynamic> toJson() {
    return {
      'recordingSessionId': recordingSessionId,
      'consultationId': consultationId,
      'clinicId': clinicId,
      'doctorId': doctorId,
      'localFilePath': localFilePath,
      'remoteObjectPath': remoteObjectPath,
      'state': state.toCanonicalString(),
      'createdAt': createdAt.toIso8601String(),
      'startedAt': startedAt?.toIso8601String(),
      'pausedAt': pausedAt?.toIso8601String(),
      'stoppedAt': stoppedAt?.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'durationSeconds': durationSeconds,
      'bytesWritten': bytesWritten,
      'checksum': checksum,
      'uploadProgress': uploadProgress,
      'retryCount': retryCount,
      'lastErrorCategory': lastErrorCategory,
      'lastErrorMessage': lastErrorMessage,
      'recoveryMetadata': recoveryMetadata,
    };
  }

  /// Deserializes a session model from a persisted JSON map.
  factory RecordingSessionModel.fromJson(Map<String, dynamic> json) {
    return RecordingSessionModel(
      recordingSessionId: json['recordingSessionId'] as String,
      consultationId: json['consultationId'] as String,
      clinicId: json['clinicId'] as String?,
      doctorId: json['doctorId'] as String?,
      localFilePath: json['localFilePath'] as String?,
      remoteObjectPath: json['remoteObjectPath'] as String?,
      state: RecordingLifecycleState.fromCanonicalString(json['state'] as String),
      createdAt: DateTime.parse(json['createdAt'] as String),
      startedAt: json['startedAt'] != null
          ? DateTime.parse(json['startedAt'] as String)
          : null,
      pausedAt: json['pausedAt'] != null
          ? DateTime.parse(json['pausedAt'] as String)
          : null,
      stoppedAt: json['stoppedAt'] != null
          ? DateTime.parse(json['stoppedAt'] as String)
          : null,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      durationSeconds: json['durationSeconds'] as int? ?? 0,
      bytesWritten: json['bytesWritten'] as int?,
      checksum: json['checksum'] as String?,
      uploadProgress: (json['uploadProgress'] as num?)?.toDouble(),
      retryCount: json['retryCount'] as int? ?? 0,
      lastErrorCategory: json['lastErrorCategory'] as String?,
      lastErrorMessage: json['lastErrorMessage'] as String?,
      recoveryMetadata: json['recoveryMetadata'] != null
          ? Map<String, dynamic>.from(json['recoveryMetadata'] as Map)
          : null,
    );
  }

  @override
  String toString() {
    return 'RecordingSessionModel(id: $recordingSessionId, consultation: $consultationId, state: ${state.toCanonicalString()}, duration: ${durationSeconds}s)';
  }
}
