class DoctorModel {
  final String id;
  final String authUserId;
  final String clinicId;
  final String fullName;
  final String? qualifications;
  final String? registrationNumber;
  final String? contactInfo;
  final DateTime createdAt;

  const DoctorModel({
    required this.id,
    required this.authUserId,
    required this.clinicId,
    required this.fullName,
    this.qualifications,
    this.registrationNumber,
    this.contactInfo,
    required this.createdAt,
  });

  factory DoctorModel.fromJson(Map<String, dynamic> json) {
    return DoctorModel(
      id: json['id'] as String,
      authUserId: json['auth_user_id'] as String,
      clinicId: json['clinic_id'] as String,
      fullName: json['full_name'] as String,
      qualifications: json['qualifications'] as String?,
      registrationNumber: json['registration_number'] as String?,
      contactInfo: json['contact_info'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'auth_user_id': authUserId,
      'clinic_id': clinicId,
      'full_name': fullName,
      if (qualifications != null) 'qualifications': qualifications,
      if (registrationNumber != null) 'registration_number': registrationNumber,
      if (contactInfo != null) 'contact_info': contactInfo,
      'created_at': createdAt.toIso8601String(),
    };
  }
}
