enum ConsentStatus { pending, granted, declined, revoked }

enum ConsentMethod { verbal, checkbox, otp, signature, other }

enum ConsentActor { patient, guardian }

enum CaptureSource { mobileApp, paperUpload }

extension ConsentStatusExtension on ConsentStatus {
  String toDbValue() {
    switch (this) {
      case ConsentStatus.pending:
        return 'pending';
      case ConsentStatus.granted:
        return 'granted';
      case ConsentStatus.declined:
        return 'declined';
      case ConsentStatus.revoked:
        return 'revoked';
    }
  }

  static ConsentStatus fromDbValue(String val) {
    switch (val) {
      case 'granted':
        return ConsentStatus.granted;
      case 'declined':
        return ConsentStatus.declined;
      case 'revoked':
        return ConsentStatus.revoked;
      case 'pending':
      default:
        return ConsentStatus.pending;
    }
  }
}

extension ConsentMethodExtension on ConsentMethod {
  String toDbValue() {
    switch (this) {
      case ConsentMethod.verbal:
        return 'verbal';
      case ConsentMethod.checkbox:
        return 'checkbox';
      case ConsentMethod.otp:
        return 'otp';
      case ConsentMethod.signature:
        return 'signature';
      case ConsentMethod.other:
        return 'other';
    }
  }

  static ConsentMethod fromDbValue(String val) {
    switch (val) {
      case 'verbal':
        return ConsentMethod.verbal;
      case 'checkbox':
        return ConsentMethod.checkbox;
      case 'otp':
        return ConsentMethod.otp;
      case 'signature':
        return ConsentMethod.signature;
      case 'other':
      default:
        return ConsentMethod.other;
    }
  }

  String get label {
    switch (this) {
      case ConsentMethod.verbal:
        return 'Verbal Confirmation';
      case ConsentMethod.checkbox:
        return 'Digital Checkbox';
      case ConsentMethod.otp:
        return 'Patient OTP';
      case ConsentMethod.signature:
        return 'Patient Signature';
      case ConsentMethod.other:
        return 'Other Method';
    }
  }
}

extension ConsentActorExtension on ConsentActor {
  String toDbValue() {
    switch (this) {
      case ConsentActor.patient:
        return 'patient';
      case ConsentActor.guardian:
        return 'guardian';
    }
  }

  static ConsentActor fromDbValue(String val) {
    switch (val) {
      case 'guardian':
        return ConsentActor.guardian;
      case 'patient':
      default:
        return ConsentActor.patient;
    }
  }
}

extension CaptureSourceExtension on CaptureSource {
  String toDbValue() {
    switch (this) {
      case CaptureSource.mobileApp:
        return 'mobile_app';
      case CaptureSource.paperUpload:
        return 'paper_upload';
    }
  }

  static CaptureSource fromDbValue(String val) {
    switch (val) {
      case 'paper_upload':
        return CaptureSource.paperUpload;
      case 'mobile_app':
      default:
        return CaptureSource.mobileApp;
    }
  }
}

class ConsentModel {
  final String id;
  final String clinicId;
  final String consultationId;
  final String patientId;
  final ConsentStatus consentStatus;
  final ConsentMethod consentMethod;
  final ConsentActor consentActor;
  final String actorName;
  final String? actorRelationship;
  final DateTime consentedAt;
  final DateTime? revokedAt;
  final String consentTextVersion;
  final CaptureSource captureSource;
  final String? evidenceReference;
  final String recordedBy;
  final Map<String, dynamic> metadata;
  final String? verificationMethod;
  final Map<String, dynamic>? verificationMetadata;
  final DateTime? verifiedAt;

  const ConsentModel({
    required this.id,
    required this.clinicId,
    required this.consultationId,
    required this.patientId,
    required this.consentStatus,
    required this.consentMethod,
    required this.consentActor,
    required this.actorName,
    this.actorRelationship,
    required this.consentedAt,
    this.revokedAt,
    this.consentTextVersion = 'v1.0',
    this.captureSource = CaptureSource.mobileApp,
    this.evidenceReference,
    required this.recordedBy,
    this.metadata = const {},
    this.verificationMethod,
    this.verificationMetadata,
    this.verifiedAt,
  });

  bool get isGrantedAndActive =>
      consentStatus == ConsentStatus.granted && revokedAt == null;

  factory ConsentModel.fromJson(Map<String, dynamic> json) {
    return ConsentModel(
      id: json['id'] as String,
      clinicId: json['clinic_id'] as String,
      consultationId: json['consultation_id'] as String,
      patientId: json['patient_id'] as String,
      consentStatus: ConsentStatusExtension.fromDbValue(
        json['consent_status'] as String,
      ),
      consentMethod: ConsentMethodExtension.fromDbValue(
        json['consent_method'] as String,
      ),
      consentActor: ConsentActorExtension.fromDbValue(
        json['consent_actor'] as String,
      ),
      actorName: json['actor_name'] as String,
      actorRelationship: json['actor_relationship'] as String?,
      consentedAt: DateTime.parse(json['consented_at'] as String),
      revokedAt: json['revoked_at'] != null
          ? DateTime.parse(json['revoked_at'] as String)
          : null,
      consentTextVersion: json['consent_text_version'] as String? ?? 'v1.0',
      captureSource: CaptureSourceExtension.fromDbValue(
        json['capture_source'] as String? ?? 'mobile_app',
      ),
      evidenceReference: json['evidence_reference'] as String?,
      recordedBy: json['recorded_by'] as String,
      metadata: json['metadata'] as Map<String, dynamic>? ?? const {},
      verificationMethod: json['verification_method'] as String?,
      verificationMetadata: json['verification_metadata'] as Map<String, dynamic>?,
      verifiedAt: json['verified_at'] != null
          ? DateTime.parse(json['verified_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'clinic_id': clinicId,
      'consultation_id': consultationId,
      'patient_id': patientId,
      'consent_status': consentStatus.toDbValue(),
      'consent_method': consentMethod.toDbValue(),
      'consent_actor': consentActor.toDbValue(),
      'actor_name': actorName,
      'actor_relationship': actorRelationship,
      'consented_at': consentedAt.toIso8601String(),
      'revoked_at': revokedAt?.toIso8601String(),
      'consent_text_version': consentTextVersion,
      'capture_source': captureSource.toDbValue(),
      'evidence_reference': evidenceReference,
      'recorded_by': recordedBy,
      'metadata': metadata,
      'verification_method': verificationMethod,
      'verification_metadata': verificationMetadata,
      'verified_at': verifiedAt?.toIso8601String(),
    };
  }
}
