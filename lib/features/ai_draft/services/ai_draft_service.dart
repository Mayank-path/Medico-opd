import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase/supabase_client_provider.dart';
import '../models/ai_draft_model.dart';

class AiDraftService {
  final SupabaseClient? _customClient;

  AiDraftService({SupabaseClient? client}) : _customClient = client;

  SupabaseClient get _client => _customClient ?? supabaseClient;

  /// Fetches an AI draft for a consultation.
  Future<AiDraftModel?> fetchDraftForConsultation(String consultationId) async {
    try {
      final data = await _client
          .from('ai_drafts')
          .select()
          .eq('consultation_id', consultationId)
          .maybeSingle();

      if (data == null) return null;
      return AiDraftModel.fromJson(data);
    } catch (e) {
      debugPrint('[AiDraftService] Failed to fetch AI draft: $e');
      rethrow;
    }
  }

  /// Updates draft with doctor's review edits (status -> 'doctor_reviewed').
  Future<AiDraftModel> updateDraftReview({
    required String draftId,
    required Map<String, dynamic> updatedJson,
    required String doctorId,
  }) async {
    try {
      final payload = <String, dynamic>{
        'structured_json': updatedJson,
        'status': 'doctor_reviewed',
        'reviewed_by': doctorId,
        'reviewed_at': DateTime.now().toIso8601String(),
      };

      final data = await _client
          .from('ai_drafts')
          .update(payload)
          .eq('id', draftId)
          .select()
          .single();

      return AiDraftModel.fromJson(data);
    } catch (e) {
      debugPrint('[AiDraftService] Failed to update draft review: $e');
      rethrow;
    }
  }

  /// Step 2 & 7: Doctor rejects an AI draft.
  /// Status moves to 'rejected'; row is preserved for audit trail.
  /// DELETE remains fully revoked.
  Future<AiDraftModel> rejectDraft({
    required String draftId,
    required String doctorId,
  }) async {
    try {
      final payload = <String, dynamic>{
        'status': 'rejected',
        'reviewed_by': doctorId,
        'reviewed_at': DateTime.now().toIso8601String(),
      };

      final data = await _client
          .from('ai_drafts')
          .update(payload)
          .eq('id', draftId)
          .select()
          .single();

      return AiDraftModel.fromJson(data);
    } catch (e) {
      debugPrint('[AiDraftService] Failed to reject draft: $e');
      rethrow;
    }
  }

  /// Stamped with finalized_by and finalized_at.
  /// Invariant 11: Locked permanently by database trigger trg_lock_finalized_ai_draft.
  Future<AiDraftModel> finalizeDraft({
    required String draftId,
    required String doctorId,
  }) async {
    try {
      final payload = <String, dynamic>{
        'status': 'finalized',
        'finalized_by': doctorId,
        'finalized_at': DateTime.now().toIso8601String(),
      };

      final data = await _client
          .from('ai_drafts')
          .update(payload)
          .eq('id', draftId)
          .select()
          .single();

      return AiDraftModel.fromJson(data);
    } catch (e) {
      debugPrint('[AiDraftService] Failed to finalize draft: $e');
      rethrow;
    }
  }
}
