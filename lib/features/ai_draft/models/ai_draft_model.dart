enum AiDraftStatus {
  aiDraft,
  doctorReviewed,
  rejected,
  finalized,
}

extension AiDraftStatusExtension on AiDraftStatus {
  String toDbValue() {
    switch (this) {
      case AiDraftStatus.aiDraft:
        return 'ai_draft';
      case AiDraftStatus.doctorReviewed:
        return 'doctor_reviewed';
      case AiDraftStatus.rejected:
        return 'rejected';
      case AiDraftStatus.finalized:
        return 'finalized';
    }
  }

  static AiDraftStatus fromDbValue(String val) {
    switch (val) {
      case 'doctor_reviewed':
        return AiDraftStatus.doctorReviewed;
      case 'rejected':
        return AiDraftStatus.rejected;
      case 'finalized':
        return AiDraftStatus.finalized;
      case 'ai_draft':
      default:
        return AiDraftStatus.aiDraft;
    }
  }
}

class AiDraftModel {
  final String id;
  final String consultationId;
  final Map<String, dynamic> structuredJson;
  final AiDraftStatus status;
  final String? reviewedBy;
  final DateTime? reviewedAt;
  final String? finalizedBy;
  final DateTime? finalizedAt;
  final String modelUsed;
  final String promptVersion;
  final int revision;

  const AiDraftModel({
    required this.id,
    required this.consultationId,
    required this.structuredJson,
    required this.status,
    this.reviewedBy,
    this.reviewedAt,
    this.finalizedBy,
    this.finalizedAt,
    required this.modelUsed,
    required this.promptVersion,
    this.revision = 1,
  });

  bool get isFinalized => status == AiDraftStatus.finalized;
  bool get isRejected => status == AiDraftStatus.rejected;

  AiDraftModel copyWith({
    String? id,
    String? consultationId,
    Map<String, dynamic>? structuredJson,
    AiDraftStatus? status,
    String? reviewedBy,
    DateTime? reviewedAt,
    String? finalizedBy,
    DateTime? finalizedAt,
    String? modelUsed,
    String? promptVersion,
    int? revision,
  }) {
    return AiDraftModel(
      id: id ?? this.id,
      consultationId: consultationId ?? this.consultationId,
      structuredJson: structuredJson ?? this.structuredJson,
      status: status ?? this.status,
      reviewedBy: reviewedBy ?? this.reviewedBy,
      reviewedAt: reviewedAt ?? this.reviewedAt,
      finalizedBy: finalizedBy ?? this.finalizedBy,
      finalizedAt: finalizedAt ?? this.finalizedAt,
      modelUsed: modelUsed ?? this.modelUsed,
      promptVersion: promptVersion ?? this.promptVersion,
      revision: revision ?? this.revision,
    );
  }

  factory AiDraftModel.fromJson(Map<String, dynamic> json) {
    return AiDraftModel(
      id: json['id'] as String,
      consultationId: json['consultation_id'] as String,
      structuredJson: json['structured_json'] as Map<String, dynamic>? ?? const {},
      status: AiDraftStatusExtension.fromDbValue(json['status'] as String),
      reviewedBy: json['reviewed_by'] as String?,
      reviewedAt: json['reviewed_at'] != null
          ? DateTime.parse(json['reviewed_at'] as String)
          : null,
      finalizedBy: json['finalized_by'] as String?,
      finalizedAt: json['finalized_at'] != null
          ? DateTime.parse(json['finalized_at'] as String)
          : null,
      modelUsed: json['model_used'] as String? ?? '',
      promptVersion: json['prompt_version'] as String? ?? '',
      revision: json['revision'] as int? ?? 1,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'consultation_id': consultationId,
      'structured_json': structuredJson,
      'status': status.toDbValue(),
      'reviewed_by': reviewedBy,
      'reviewed_at': reviewedAt?.toIso8601String(),
      'finalized_by': finalizedBy,
      'finalized_at': finalizedAt?.toIso8601String(),
      'model_used': modelUsed,
      'prompt_version': promptVersion,
      'revision': revision,
    };
  }
}
