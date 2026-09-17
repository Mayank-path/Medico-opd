class PatientModel {
  final String id;
  final String clinicId;
  final String fullName;
  final String? dobOrAge;
  final String? sex;
  final String? contactInfo;
  final String? opdNumber;
  final DateTime createdAt;
  final String? createdBy;

  const PatientModel({
    required this.id,
    required this.clinicId,
    required this.fullName,
    this.dobOrAge,
    this.sex,
    this.contactInfo,
    this.opdNumber,
    required this.createdAt,
    this.createdBy,
  });

  factory PatientModel.fromJson(Map<String, dynamic> json) {
    return PatientModel(
      id: json['id'] as String,
      clinicId: json['clinic_id'] as String,
      fullName: json['full_name'] as String,
      dobOrAge: json['dob_or_age'] as String?,
      sex: json['sex'] as String?,
      contactInfo: json['contact_info'] as String?,
      opdNumber: json['opd_number'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      createdBy: json['created_by'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'clinic_id': clinicId,
      'full_name': fullName,
      if (dobOrAge != null) 'dob_or_age': dobOrAge,
      if (sex != null) 'sex': sex,
      if (contactInfo != null) 'contact_info': contactInfo,
      if (opdNumber != null) 'opd_number': opdNumber,
      'created_at': createdAt.toIso8601String(),
      if (createdBy != null) 'created_by': createdBy,
    };
  }

  PatientModel copyWith({
    String? id,
    String? clinicId,
    String? fullName,
    String? dobOrAge,
    String? sex,
    String? contactInfo,
    String? opdNumber,
    DateTime? createdAt,
    String? createdBy,
  }) {
    return PatientModel(
      id: id ?? this.id,
      clinicId: clinicId ?? this.clinicId,
      fullName: fullName ?? this.fullName,
      dobOrAge: dobOrAge ?? this.dobOrAge,
      sex: sex ?? this.sex,
      contactInfo: contactInfo ?? this.contactInfo,
      opdNumber: opdNumber ?? this.opdNumber,
      createdAt: createdAt ?? this.createdAt,
      createdBy: createdBy ?? this.createdBy,
    );
  }
}
