import 'consent_model.dart';

class ConsentPolicy {
  final String id;
  final int version;
  final List<ConsentMethod> allowedMethods;
  final String? requiredEvidence;
  final bool pediatricVerificationRequired;
  final DateTime effectiveFrom;
  final String? createdBy;
  final String? notes;

  const ConsentPolicy({
    required this.id,
    required this.version,
    required this.allowedMethods,
    this.requiredEvidence,
    this.pediatricVerificationRequired = false,
    required this.effectiveFrom,
    this.createdBy,
    this.notes,
  });

  /// Factory constructor for fallback baseline policy
  /// (Maximally permissive baseline: all 5 methods enabled, pending legal counsel)
  factory ConsentPolicy.fallbackDefault() {
    return ConsentPolicy(
      id: 'default-baseline-policy',
      version: 1,
      allowedMethods: ConsentMethod.values.toList(),
      pediatricVerificationRequired: false,
      effectiveFrom: DateTime.now(),
      notes: 'Local client fallback baseline policy',
    );
  }

  factory ConsentPolicy.fromJson(Map<String, dynamic> json) {
    final rawMethods = json['allowed_methods'];
    List<ConsentMethod> methods = [];

    if (rawMethods is List) {
      methods = rawMethods
          .map((m) => ConsentMethodExtension.fromDbValue(m.toString()))
          .toList();
    } else if (rawMethods is String) {
      // Handles PostgreSQL array string format e.g. "{verbal,checkbox,otp}"
      final cleaned = rawMethods.replaceAll('{', '').replaceAll('}', '');
      if (cleaned.isNotEmpty) {
        methods = cleaned
            .split(',')
            .map((s) => ConsentMethodExtension.fromDbValue(s.trim()))
            .toList();
      }
    }

    if (methods.isEmpty) {
      methods = ConsentMethod.values.toList();
    }

    return ConsentPolicy(
      id: json['id'] as String? ?? 'policy-v${json['version'] ?? 1}',
      version: json['version'] as int? ?? 1,
      allowedMethods: methods,
      requiredEvidence: json['required_evidence'] as String?,
      pediatricVerificationRequired:
          json['pediatric_verification_required'] as bool? ?? false,
      effectiveFrom: json['effective_from'] != null
          ? DateTime.parse(json['effective_from'] as String)
          : DateTime.now(),
      createdBy: json['created_by'] as String?,
      notes: json['notes'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'version': version,
      'allowed_methods': allowedMethods.map((m) => m.toDbValue()).toList(),
      'required_evidence': requiredEvidence,
      'pediatric_verification_required': pediatricVerificationRequired,
      'effective_from': effectiveFrom.toIso8601String(),
      'created_by': createdBy,
      'notes': notes,
    };
  }
}
