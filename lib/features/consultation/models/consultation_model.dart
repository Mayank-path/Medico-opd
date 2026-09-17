class ConsultationModel {
  final String id;
  final String patientId;
  final String doctorId;
  final String clinicId;
  final String status;
  final DateTime startedAt;
  final DateTime? endedAt;
  final DateTime createdAt;

  const ConsultationModel({
    required this.id,
    required this.patientId,
    required this.doctorId,
    required this.clinicId,
    required this.status,
    required this.startedAt,
    this.endedAt,
    required this.createdAt,
  });

  factory ConsultationModel.fromJson(Map<String, dynamic> json) {
    return ConsultationModel(
      id: json['id'] as String,
      patientId: json['patient_id'] as String,
      doctorId: json['doctor_id'] as String,
      clinicId: json['clinic_id'] as String,
      status: json['status'] as String,
      startedAt: DateTime.parse(json['started_at'] as String),
      endedAt: json['ended_at'] != null
          ? DateTime.parse(json['ended_at'] as String)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'patient_id': patientId,
      'doctor_id': doctorId,
      'clinic_id': clinicId,
      'status': status,
      'started_at': startedAt.toIso8601String(),
      if (endedAt != null) 'ended_at': endedAt!.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
    };
  }

  ConsultationModel copyWith({
    String? id,
    String? patientId,
    String? doctorId,
    String? clinicId,
    String? status,
    DateTime? startedAt,
    DateTime? endedAt,
    DateTime? createdAt,
  }) {
    return ConsultationModel(
      id: id ?? this.id,
      patientId: patientId ?? this.patientId,
      doctorId: doctorId ?? this.doctorId,
      clinicId: clinicId ?? this.clinicId,
      status: status ?? this.status,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
