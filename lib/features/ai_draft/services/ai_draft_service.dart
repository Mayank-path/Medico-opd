import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/observability/observability.dart';
import '../../../core/supabase/supabase_client_provider.dart';
import '../models/ai_draft_model.dart';

class ConcurrentModificationException implements Exception {
  final String message;
  const ConcurrentModificationException([
    this.message = 'Concurrent modification detected. Draft was modified by another session.',
  ]);

  @override
  String toString() => message;
}

class AiDraftService {
  final SupabaseClient? _customClient;
  final TelemetryService _telemetry;
  final StructuredLogger _logger;

  AiDraftService({
    SupabaseClient? client,
    TelemetryService? telemetry,
  })  : _customClient = client,
        _telemetry = telemetry ?? Telemetry.instance,
        _logger = StructuredLogger('ai_draft_service');

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
    } catch (e, stackTrace) {
      _telemetry.recordError(
        e,
        stackTrace: stackTrace,
        errorCode: AppErrorCode.databaseError.code,
      );
      _logger.error(
        'FETCH_DRAFT_FAILED',
        operation: 'fetch_draft',
        errorCode: AppErrorCode.databaseError.code,
        consultationId: consultationId,
      );
      rethrow;
    }
  }

  /// Updates draft with doctor's review edits (status -> 'doctor_reviewed').
  /// Enforces deterministic optimistic concurrency control via [expectedRevision].
  Future<AiDraftModel> updateDraftReview({
    required String draftId,
    required Map<String, dynamic> updatedJson,
    required String doctorId,
    int? expectedRevision,
  }) async {
    try {
      final payload = <String, dynamic>{
        'structured_json': updatedJson,
        'status': 'doctor_reviewed',
        'reviewed_by': doctorId,
        'reviewed_at': DateTime.now().toIso8601String(),
      };

      if (expectedRevision != null) {
        payload['revision'] = expectedRevision + 1;
        final data = await _client
            .from('ai_drafts')
            .update(payload)
            .eq('id', draftId)
            .eq('revision', expectedRevision)
            .select()
            .maybeSingle();

        if (data == null) {
          final current = await _client
              .from('ai_drafts')
              .select('id, revision, status')
              .eq('id', draftId)
              .maybeSingle();

          if (current == null) {
            throw StateError('AI draft not found or access denied: $draftId');
          }
          if (current['status'] == 'finalized') {
            throw StateError('AI draft is finalized and permanently locked against modifications.');
          }
          throw ConcurrentModificationException(
            'CONCURRENT_MODIFICATION: Draft revision mismatch (expected revision $expectedRevision, current revision is ${current['revision']}).',
          );
        }
        _logger.info('DRAFT_REVIEW_UPDATED', operation: 'update_draft_review', metadata: {'draft_id': draftId, 'revision': expectedRevision + 1});
        return AiDraftModel.fromJson(data);
      } else {
        final data = await _client
            .from('ai_drafts')
            .update(payload)
            .eq('id', draftId)
            .select()
            .single();

        _logger.info('DRAFT_REVIEW_UPDATED', operation: 'update_draft_review', metadata: {'draft_id': draftId});
        return AiDraftModel.fromJson(data);
      }
    } catch (e, stackTrace) {
      final isConflict = e is ConcurrentModificationException;
      final code = isConflict ? AppErrorCode.conflictError.code : AppErrorCode.databaseError.code;
      _telemetry.recordError(e, stackTrace: stackTrace, errorCode: code);
      _logger.error('UPDATE_DRAFT_FAILED', operation: 'update_draft_review', errorCode: code, metadata: {'draft_id': draftId});
      rethrow;
    }
  }

  /// Step 2 & 7: Doctor rejects an AI draft.
  /// Status moves to 'rejected'; row is preserved for audit trail.
  /// DELETE remains fully revoked.
  Future<AiDraftModel> rejectDraft({
    required String draftId,
    required String doctorId,
    int? expectedRevision,
  }) async {
    try {
      final payload = <String, dynamic>{
        'status': 'rejected',
        'reviewed_by': doctorId,
        'reviewed_at': DateTime.now().toIso8601String(),
      };

      if (expectedRevision != null) {
        payload['revision'] = expectedRevision + 1;
        final data = await _client
            .from('ai_drafts')
            .update(payload)
            .eq('id', draftId)
            .eq('revision', expectedRevision)
            .select()
            .maybeSingle();

        if (data == null) {
          final current = await _client
              .from('ai_drafts')
              .select('id, revision, status')
              .eq('id', draftId)
              .maybeSingle();

          if (current == null) {
            throw StateError('AI draft not found or access denied: $draftId');
          }
          if (current['status'] == 'finalized') {
            throw StateError('AI draft is finalized and permanently locked against modifications.');
          }
          throw ConcurrentModificationException(
            'CONCURRENT_MODIFICATION: Draft revision mismatch during rejection (expected revision $expectedRevision, current revision is ${current['revision']}).',
          );
        }
        _logger.info('DRAFT_REJECTED', operation: 'reject_draft', metadata: {'draft_id': draftId});
        return AiDraftModel.fromJson(data);
      } else {
        final data = await _client
            .from('ai_drafts')
            .update(payload)
            .eq('id', draftId)
            .select()
            .single();

        _logger.info('DRAFT_REJECTED', operation: 'reject_draft', metadata: {'draft_id': draftId});
        return AiDraftModel.fromJson(data);
      }
    } catch (e, stackTrace) {
      final isConflict = e is ConcurrentModificationException;
      final code = isConflict ? AppErrorCode.conflictError.code : AppErrorCode.databaseError.code;
      _telemetry.recordError(e, stackTrace: stackTrace, errorCode: code);
      _logger.error('REJECT_DRAFT_FAILED', operation: 'reject_draft', errorCode: code, metadata: {'draft_id': draftId});
      rethrow;
    }
  }

  /// Stamped with finalized_by and finalized_at.
  /// Invariant 11: Locked permanently by database trigger trg_lock_finalized_ai_draft.
  Future<AiDraftModel> finalizeDraft({
    required String draftId,
    required String doctorId,
    int? expectedRevision,
  }) async {
    try {
      final payload = <String, dynamic>{
        'status': 'finalized',
        'finalized_by': doctorId,
        'finalized_at': DateTime.now().toIso8601String(),
      };

      if (expectedRevision != null) {
        payload['revision'] = expectedRevision + 1;
        final data = await _client
            .from('ai_drafts')
            .update(payload)
            .eq('id', draftId)
            .eq('revision', expectedRevision)
            .select()
            .maybeSingle();

        if (data == null) {
          final current = await _client
              .from('ai_drafts')
              .select('id, revision, status')
              .eq('id', draftId)
              .maybeSingle();

          if (current == null) {
            throw StateError('AI draft not found or access denied: $draftId');
          }
          if (current['status'] == 'finalized') {
            throw StateError('AI draft is finalized and permanently locked against modifications.');
          }
          throw ConcurrentModificationException(
            'CONCURRENT_MODIFICATION: Draft revision mismatch during finalization (expected revision $expectedRevision, current revision is ${current['revision']}).',
          );
        }
        _logger.info('DRAFT_FINALIZED', operation: 'finalize_draft', metadata: {'draft_id': draftId});
        return AiDraftModel.fromJson(data);
      } else {
        final data = await _client
            .from('ai_drafts')
            .update(payload)
            .eq('id', draftId)
            .select()
            .single();

        _logger.info('DRAFT_FINALIZED', operation: 'finalize_draft', metadata: {'draft_id': draftId});
        return AiDraftModel.fromJson(data);
      }
    } catch (e, stackTrace) {
      final isConflict = e is ConcurrentModificationException;
      final code = isConflict ? AppErrorCode.conflictError.code : AppErrorCode.databaseError.code;
      _telemetry.recordError(e, stackTrace: stackTrace, errorCode: code);
      _logger.error('FINALIZE_DRAFT_FAILED', operation: 'finalize_draft', errorCode: code, metadata: {'draft_id': draftId});
      rethrow;
    }
  }
}
