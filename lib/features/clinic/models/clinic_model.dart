class ClinicModel {
  final String id;
  final String name;
  final String? address;
  final String? contactInfo;
  final String? logoUrl;
  final DateTime createdAt;

  const ClinicModel({
    required this.id,
    required this.name,
    this.address,
    this.contactInfo,
    this.logoUrl,
    required this.createdAt,
  });

  factory ClinicModel.fromJson(Map<String, dynamic> json) {
    return ClinicModel(
      id: json['id'] as String,
      name: json['name'] as String,
      address: json['address'] as String?,
      contactInfo: json['contact_info'] as String?,
      logoUrl: json['logo_url'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      if (address != null) 'address': address,
      if (contactInfo != null) 'contact_info': contactInfo,
      if (logoUrl != null) 'logo_url': logoUrl,
      'created_at': createdAt.toIso8601String(),
    };
  }
}
