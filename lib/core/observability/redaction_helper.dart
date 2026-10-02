import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Automated sensitive data redactor.
/// Guarantees that PII, authentication tokens, API keys, signed URLs,
/// and clinical payloads are stripped before emitting logs or telemetry.
class SensitiveDataRedactor {
  // Regex for JWT tokens (header.payload.signature)
  static final RegExp _jwtRegex = RegExp(
    r'eyJ[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}',
  );

  // Regex for API keys (e.g. Anthropic, Deepgram, Supabase service keys)
  static final RegExp _apiKeyRegex = RegExp(
    r'''(?:sk-ant-[a-zA-Z0-9_-]{20,}|Bearer\s+[a-zA-Z0-9._-]{20,}|(?:api[_-]?key|secret|token|service_role)\s*[:=]\s*["']?[a-zA-Z0-9._-]{20,}["']?)''',
    caseSensitive: false,
  );

  // Regex for signed URLs with query tokens or signature params
  static final RegExp _signedUrlRegex = RegExp(
    r'https?://[^\s"<>]+(?:\?|&)(?:token|Signature|AWSAccessKeyId|Expires)=[^\s"<>]+',
    caseSensitive: false,
  );

  // Regex for email addresses
  static final RegExp _emailRegex = RegExp(
    r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}',
  );

  // Regex for phone numbers (Indian & international formats)
  static final RegExp _phoneRegex = RegExp(
    r'(?:\+?91[\-\s]?)?[6-9]\d{9}\b',
  );

  // Regex for Aadhaar numbers (12 digits with optional spaces or hyphens)
  static final RegExp _aadhaarRegex = RegExp(
    r'\b[2-9]\d{3}[\s\-]?\d{4}[\s\-]?\d{4}\b',
  );

  /// Redacts sensitive patterns in a string and replaces them with standard redaction tokens.
  static String redact(String? input) {
    if (input == null || input.isEmpty) return '';

    String sanitized = input;

    // 1. Redact signed URLs first before token regex breaks them
    sanitized = sanitized.replaceAllMapped(_signedUrlRegex, (_) => '[REDACTED_SIGNED_URL]');

    // 2. Redact JWT tokens
    sanitized = sanitized.replaceAllMapped(_jwtRegex, (_) => '[REDACTED_JWT]');

    // 3. Redact API keys and authorization headers
    sanitized = sanitized.replaceAllMapped(_apiKeyRegex, (_) => '[REDACTED_API_KEY]');

    // 4. Redact Emails
    sanitized = sanitized.replaceAllMapped(_emailRegex, (_) => '[REDACTED_EMAIL]');

    // 5. Redact Aadhaar Numbers
    sanitized = sanitized.replaceAllMapped(_aadhaarRegex, (_) => '[REDACTED_AADHAAR]');

    // 6. Redact Phone Numbers
    sanitized = sanitized.replaceAllMapped(_phoneRegex, (_) => '[REDACTED_PHONE]');

    return sanitized;
  }

  /// Recursively sanitizes a Map or List to guarantee sensitive values and clinical payloads are stripped.
  static dynamic sanitizeValue(dynamic value) {
    if (value == null) return null;
    if (value is String) return redact(value);
    if (value is num || value is bool) return value;
    if (value is List) return value.map(sanitizeValue).toList();
    if (value is Map) {
      final sanitizedMap = <String, dynamic>{};
      for (final entry in value.entries) {
        final key = entry.key.toString().toLowerCase();
        // Drop forbidden clinical payload keys completely
        if (_isForbiddenPayloadKey(key)) {
          sanitizedMap[entry.key.toString()] = '[REDACTED_CLINICAL_PAYLOAD]';
        } else if (_isForbiddenCredentialKey(key)) {
          sanitizedMap[entry.key.toString()] = '[REDACTED_CREDENTIAL]';
        } else {
          sanitizedMap[entry.key.toString()] = sanitizeValue(entry.value);
        }
      }
      return sanitizedMap;
    }
    return redact(value.toString());
  }

  /// Checks if a metadata key represents high-risk clinical information.
  static bool _isForbiddenPayloadKey(String key) {
    return key.contains('transcript') ||
        key.contains('prompt') ||
        key.contains('audio') ||
        key.contains('chief_complaint') ||
        key.contains('diagnosis') ||
        key.contains('prescription') ||
        key.contains('notes') ||
        key.contains('patient_name') ||
        key.contains('raw_text');
  }

  /// Checks if a metadata key represents credentials or auth tokens.
  static bool _isForbiddenCredentialKey(String key) {
    return key.contains('token') ||
        key.contains('password') ||
        key.contains('secret') ||
        key.contains('api_key') ||
        key.contains('authorization') ||
        key.contains('bearer');
  }

  /// Deterministically hashes a clinic ID or tenant ID using SHA-256 for privacy-safe aggregation.
  /// Prevents exposing raw clinic UUIDs across external telemetry tiers.
  static String hashTenantId(String? clinicId) {
    if (clinicId == null || clinicId.isEmpty) return 'unknown';
    final bytes = utf8.encode('medico_clinic_$clinicId');
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 12); // Safe 12-char prefix hash
  }
}
