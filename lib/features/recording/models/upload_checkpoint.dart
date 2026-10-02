import 'upload_state.dart';

/// Durable technical checkpoint persisting upload progress across network cuts,
/// backgrounding, and cold app restarts.
///
/// PRIVACY & SECURITY CONTRACT:
/// Strictly contains technical operational metadata.
/// Under NO circumstances contains patient identifiers, patient names, UHIDs,
/// clinical notes, transcripts, AI drafts, consultation IDs, doctor IDs, clinic IDs,
/// audio payloads, or JWT/refresh authentication tokens.
class UploadCheckpoint {
  final String recordingSessionId;
  final String localFilePath;
  final String remoteObjectPath;
  final int fileSize;
  final String fileHash;
  final UploadState uploadState;
  final int uploadedBytes;
  final String? uploadUrl;
  final int uploadAttempts;
  final String? lastErrorCode;
  final String? lastErrorMessage;
  final bool remoteVerified;
  final bool databaseRegistered;
  final DateTime createdAt;
  final DateTime updatedAt;

  const UploadCheckpoint({
    required this.recordingSessionId,
    required this.localFilePath,
    required this.remoteObjectPath,
    required this.fileSize,
    required this.fileHash,
    required this.uploadState,
    this.uploadedBytes = 0,
    this.uploadUrl,
    this.uploadAttempts = 0,
    this.lastErrorCode,
    this.lastErrorMessage,
    this.remoteVerified = false,
    this.databaseRegistered = false,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Extracts clinic ID dynamically from remoteObjectPath (`clinics/{clinicId}/consultations/{consultationId}/...`)
  /// without persisting it as a standalone identity field in the checkpoint file.
  String? get clinicId {
    final parts = remoteObjectPath.split('/');
    final idx = parts.indexOf('clinics');
    if (idx != -1 && idx + 1 < parts.length) {
      return parts[idx + 1];
    }
    return null;
  }

  /// Extracts consultation ID dynamically from remoteObjectPath (`clinics/{clinicId}/consultations/{consultationId}/...`)
  /// without persisting it as a standalone identity field in the checkpoint file.
  String? get consultationId {
    final parts = remoteObjectPath.split('/');
    final idx = parts.indexOf('consultations');
    if (idx != -1 && idx + 1 < parts.length) {
      return parts[idx + 1];
    }
    return null;
  }

  /// Fractional progress between 0.0 and 1.0.
  double get progressFraction {
    if (fileSize <= 0) return 0.0;
    final frac = uploadedBytes / fileSize;
    return frac.clamp(0.0, 1.0);
  }

  /// Whether the upload has reached terminal completion.
  bool get isComplete => uploadState == UploadState.complete;

  /// Whether the upload is ready for local file cleanup.
  bool get isSafeToPurgeLocalFile =>
      uploadState == UploadState.complete &&
      remoteVerified &&
      databaseRegistered;

  UploadCheckpoint copyWith({
    String? recordingSessionId,
    String? localFilePath,
    String? remoteObjectPath,
    int? fileSize,
    String? fileHash,
    UploadState? uploadState,
    int? uploadedBytes,
    String? uploadUrl,
    int? uploadAttempts,
    String? lastErrorCode,
    String? lastErrorMessage,
    bool? remoteVerified,
    bool? databaseRegistered,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return UploadCheckpoint(
      recordingSessionId: recordingSessionId ?? this.recordingSessionId,
      localFilePath: localFilePath ?? this.localFilePath,
      remoteObjectPath: remoteObjectPath ?? this.remoteObjectPath,
      fileSize: fileSize ?? this.fileSize,
      fileHash: fileHash ?? this.fileHash,
      uploadState: uploadState ?? this.uploadState,
      uploadedBytes: uploadedBytes ?? this.uploadedBytes,
      uploadUrl: uploadUrl ?? this.uploadUrl,
      uploadAttempts: uploadAttempts ?? this.uploadAttempts,
      lastErrorCode: lastErrorCode ?? this.lastErrorCode,
      lastErrorMessage: lastErrorMessage ?? this.lastErrorMessage,
      remoteVerified: remoteVerified ?? this.remoteVerified,
      databaseRegistered: databaseRegistered ?? this.databaseRegistered,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'recordingSessionId': recordingSessionId,
      'localFilePath': localFilePath,
      'remoteObjectPath': remoteObjectPath,
      'fileSize': fileSize,
      'fileHash': fileHash,
      'uploadState': uploadState.toCanonicalString(),
      'uploadedBytes': uploadedBytes,
      'uploadUrl': uploadUrl,
      'uploadAttempts': uploadAttempts,
      'lastErrorCode': lastErrorCode,
      'lastErrorMessage': lastErrorMessage,
      'remoteVerified': remoteVerified,
      'databaseRegistered': databaseRegistered,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory UploadCheckpoint.fromJson(Map<String, dynamic> json) {
    return UploadCheckpoint(
      recordingSessionId: json['recordingSessionId'] as String,
      localFilePath: json['localFilePath'] as String,
      remoteObjectPath: json['remoteObjectPath'] as String,
      fileSize: json['fileSize'] as int,
      fileHash: json['fileHash'] as String,
      uploadState: UploadState.fromCanonicalString(json['uploadState'] as String),
      uploadedBytes: (json['uploadedBytes'] as int?) ?? 0,
      uploadUrl: json['uploadUrl'] as String?,
      uploadAttempts: (json['uploadAttempts'] as int?) ?? 0,
      lastErrorCode: json['lastErrorCode'] as String?,
      lastErrorMessage: json['lastErrorMessage'] as String?,
      remoteVerified: (json['remoteVerified'] as bool?) ?? false,
      databaseRegistered: (json['databaseRegistered'] as bool?) ?? false,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  @override
  String toString() =>
      'UploadCheckpoint(id: $recordingSessionId, state: ${uploadState.name}, bytes: $uploadedBytes/$fileSize, verified: $remoteVerified, db: $databaseRegistered)';
}
