import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase/supabase_client_provider.dart';
import '../models/consent_model.dart';
import '../models/consent_policy.dart';

class ConsentService {
  final SupabaseClient? _customClient;

  ConsentService({SupabaseClient? client}) : _customClient = client;

  SupabaseClient get _client => _customClient ?? supabaseClient;

  /// Fetches the platform-wide active consent policy.
  /// Uses helper function `get_active_consent_policy()` or queries `consent_policies`.
  /// Falls back to maximally permissive ConsentPolicy.fallbackDefault() if unconfigured.
  Future<ConsentPolicy> getActiveConsentPolicy() async {
    try {
      // 1. Try helper RPC function get_active_consent_policy()
      final rpcData = await _client.rpc('get_active_consent_policy');
      if (rpcData is List && rpcData.isNotEmpty) {
        return ConsentPolicy.fromJson(rpcData.first as Map<String, dynamic>);
      } else if (rpcData is Map<String, dynamic>) {
        return ConsentPolicy.fromJson(rpcData);
      }

      // 2. Direct select fallback
      final data = await _client
          .from('consent_policies')
          .select()
          .order('effective_from', ascending: false)
          .order('version', ascending: false)
          .limit(1)
          .maybeSingle();

      if (data != null) {
        return ConsentPolicy.fromJson(data);
      }
    } catch (e) {
      debugPrint('[ConsentService] Notice: Could not fetch remote consent policy ($e). Using baseline fallback.');
    }
    return ConsentPolicy.fallbackDefault();
  }

  /// Fetches the consent record for a specific consultation.
  Future<ConsentModel?> fetchConsentForConsultation(
    String consultationId,
  ) async {
    try {
      final data = await _client
          .from('consultation_consents')
          .select()
          .eq('consultation_id', consultationId)
          .maybeSingle();

      if (data == null) return null;
      return ConsentModel.fromJson(data);
    } catch (e) {
      debugPrint('[ConsentService] Failed to fetch consent: $e');
      rethrow;
    }
  }

  /// Records patient or guardian consultation consent.
  Future<ConsentModel> recordConsent({
    required String clinicId,
    required String consultationId,
    required String patientId,
    required ConsentStatus consentStatus,
    required ConsentMethod consentMethod,
    required ConsentActor consentActor,
    required String actorName,
    String? actorRelationship,
    required String recordedByDoctorId,
    String consentTextVersion = 'v1.0',
    CaptureSource captureSource = CaptureSource.mobileApp,
    String? evidenceReference,
    Map<String, dynamic> metadata = const {},
  }) async {
    // Client-side validation mirroring database constraints
    if (consentActor == ConsentActor.guardian &&
        (actorRelationship == null || actorRelationship.trim().isEmpty)) {
      throw ArgumentError(
        'Actor relationship is required when consent actor is guardian.',
      );
    }

    try {
      final payload = <String, dynamic>{
        'clinic_id': clinicId,
        'consultation_id': consultationId,
        'patient_id': patientId,
        'consent_status': consentStatus.toDbValue(),
        'consent_method': consentMethod.toDbValue(),
        'consent_actor': consentActor.toDbValue(),
        'actor_name': actorName.trim(),
        'actor_relationship': actorRelationship?.trim(),
        'consented_at': DateTime.now().toIso8601String(),
        'consent_text_version': consentTextVersion,
        'capture_source': captureSource.toDbValue(),
        'evidence_reference': evidenceReference,
        'recorded_by': recordedByDoctorId,
        'metadata': metadata,
      };

      final data = await _client
          .from('consultation_consents')
          .insert(payload)
          .select()
          .single();

      return ConsentModel.fromJson(data);
    } catch (e) {
      debugPrint('[ConsentService] Failed to record consent: $e');
      rethrow;
    }
  }

  /// Revokes an existing consent record.
  /// Strictly uses the permitted column grant on `revoked_at`.
  Future<ConsentModel> revokeConsent(String consentId) async {
    try {
      final payload = <String, dynamic>{
        'consent_status': ConsentStatus.revoked.toDbValue(),
        'revoked_at': DateTime.now().toIso8601String(),
      };

      final data = await _client
          .from('consultation_consents')
          .update(payload)
          .eq('id', consentId)
          .select()
          .single();

      return ConsentModel.fromJson(data);
    } catch (e) {
      debugPrint('[ConsentService] Failed to revoke consent: $e');
      rethrow;
    }
  }
}
