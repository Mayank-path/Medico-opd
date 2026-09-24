// Explicit recording screen & pipeline state machine enum
// Step 6: Explicit distinctly testable states, not a single opaque spinner
enum RecordingScreenState {
  idle,
  recording,
  uploading,
  uploadFailed,
  processing,
  processingFailed,
  transcribed,
}

enum RecordingUploadStatus { pending, uploading, uploaded, failed }

enum RecordingProcessingStatus { pending, transcribing, transcribed, failed }

enum RecordingDeletionStatus { active, pendingDeletion, deleted, held }

class RecordingModel {
  final String id; // Client-generated UUIDv4 (idempotency key)
  final String consultationId;
  final String patientId;
  final String doctorId;
  final String storagePath;
  final String encryptionKeyRef;
  final int durationSeconds;
  final String format;
  final RecordingUploadStatus uploadStatus;
  final RecordingProcessingStatus processingStatus;
  final DateTime createdAt;
  final DateTime? retentionExpiresAt;
  final bool legalHold;
  final RecordingDeletionStatus deletionStatus;

  const RecordingModel({
    required this.id,
    required this.consultationId,
    required this.patientId,
    required this.doctorId,
    required this.storagePath,
    required this.encryptionKeyRef,
    this.durationSeconds = 0,
    this.format = 'm4a',
    this.uploadStatus = RecordingUploadStatus.pending,
    this.processingStatus = RecordingProcessingStatus.pending,
    required this.createdAt,
    this.retentionExpiresAt,
    this.legalHold = false,
    this.deletionStatus = RecordingDeletionStatus.active,
  });

  factory RecordingModel.fromJson(Map<String, dynamic> json) {
    return RecordingModel(
      id: json['id'] as String,
      consultationId: json['consultation_id'] as String,
      patientId: json['patient_id'] as String,
      doctorId: json['doctor_id'] as String,
      storagePath: json['storage_path'] as String,
      encryptionKeyRef: json['encryption_key_ref'] as String,
      durationSeconds: json['duration_seconds'] as int? ?? 0,
      format: json['format'] as String? ?? 'm4a',
      uploadStatus: _parseUploadStatus(json['upload_status'] as String?),
      processingStatus: _parseProcessingStatus(
        json['processing_status'] as String?,
      ),
      createdAt: DateTime.parse(json['created_at'] as String),
      retentionExpiresAt: json['retention_expires_at'] != null
          ? DateTime.parse(json['retention_expires_at'] as String)
          : null,
      legalHold: json['legal_hold'] as bool? ?? false,
      deletionStatus: _parseDeletionStatus(
        json['deletion_status'] as String?,
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'consultation_id': consultationId,
      'patient_id': patientId,
      'doctor_id': doctorId,
      'storage_path': storagePath,
      'encryption_key_ref': encryptionKeyRef,
      'duration_seconds': durationSeconds,
      'format': format,
      'upload_status': uploadStatus.name,
      'processing_status': processingStatus.name,
      'created_at': createdAt.toIso8601String(),
      'retention_expires_at': retentionExpiresAt?.toIso8601String(),
      'legal_hold': legalHold,
      'deletion_status': deletionStatus.name,
    };
  }

  static RecordingUploadStatus _parseUploadStatus(String? val) {
    switch (val) {
      case 'uploading':
        return RecordingUploadStatus.uploading;
      case 'uploaded':
        return RecordingUploadStatus.uploaded;
      case 'failed':
        return RecordingUploadStatus.failed;
      case 'pending':
      default:
        return RecordingUploadStatus.pending;
    }
  }

  static RecordingProcessingStatus _parseProcessingStatus(String? val) {
    switch (val) {
      case 'transcribing':
        return RecordingProcessingStatus.transcribing;
      case 'transcribed':
        return RecordingProcessingStatus.transcribed;
      case 'failed':
        return RecordingProcessingStatus.failed;
      case 'pending':
      default:
        return RecordingProcessingStatus.pending;
    }
  }

  static RecordingDeletionStatus _parseDeletionStatus(String? val) {
    switch (val) {
      case 'pending_deletion':
        return RecordingDeletionStatus.pendingDeletion;
      case 'deleted':
        return RecordingDeletionStatus.deleted;
      case 'held':
        return RecordingDeletionStatus.held;
      case 'active':
      default:
        return RecordingDeletionStatus.active;
    }
  }
}
