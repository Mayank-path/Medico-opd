import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/observability/observability.dart';
import '../../../core/pagination/keyset_cursor.dart';
import '../../../core/pagination/paginated_result.dart';
import '../../../core/supabase/supabase_client_provider.dart';
import '../models/consultation_model.dart';

class ConsultationService {
  final SupabaseClient? _customClient;
  final TelemetryService _telemetry;
  final StructuredLogger _logger;

  ConsultationService({
    SupabaseClient? client,
    TelemetryService? telemetry,
  })  : _customClient = client,
        _telemetry = telemetry ?? Telemetry.instance,
        _logger = StructuredLogger('consultation_service');

  SupabaseClient get _client => _customClient ?? supabaseClient;

  /// Fetches consultations for a given patient using keyset pagination,
  /// minimal column projection, and optional date-range bounding.
  /// Limits are clamped between 1 and 100 (default 20).
  Future<PaginatedResult<ConsultationModel>> fetchConsultationsForPatient({
    required String patientId,
    int limit = 20,
    String? cursor,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final safeLimit = limit.clamp(1, 100);

      // PART E: Explicit column projection to eliminate SELECT *
      var query = _client.from('consultations').select(
        'id, patient_id, doctor_id, clinic_id, status, started_at, ended_at, created_at',
      ).eq('patient_id', patientId);

      // PART D: Optional date-range bounding
      if (fromDate != null) {
        query = query.gte('created_at', fromDate.toUtc().toIso8601String());
      }
      if (toDate != null) {
        query = query.lte('created_at', toDate.toUtc().toIso8601String());
      }

      // PART C: Keyset pagination filter using deterministic (created_at DESC, id DESC)
      if (cursor != null && cursor.trim().isNotEmpty) {
        final c = KeysetCursor.decode(cursor);
        query = query.or(
          'created_at.lt.${c.createdAtIso},and(created_at.eq.${c.createdAtIso},id.lt.${c.id})',
        );
      }

      // PART C: Deterministic ordering with tie-breaker
      final data = await query
          .order('created_at', ascending: false)
          .order('id', ascending: false)
          .limit(safeLimit + 1);

      final rawList = (data as List<dynamic>)
          .map((row) => ConsultationModel.fromJson(row as Map<String, dynamic>))
          .toList();

      final hasMore = rawList.length > safeLimit;
      final items = hasMore ? rawList.sublist(0, safeLimit) : rawList;

      String? nextCursor;
      if (hasMore && items.isNotEmpty) {
        final last = items.last;
        nextCursor = KeysetCursor(createdAt: last.createdAt, id: last.id).encode();
      }

      final durationMs = sw.elapsedMilliseconds;
      _telemetry.timing(MetricDefinitions.consultationQueryLatencyMs, durationMs);
      _logger.info(
        'CONSULTATIONS_FETCHED',
        operation: 'fetch_consultations',
        durationMs: durationMs,
        metadata: {'returned_count': items.length, 'has_more': hasMore},
      );

      return PaginatedResult<ConsultationModel>(
        items: items,
        nextCursor: nextCursor,
        hasMore: hasMore,
      );
    } catch (e, stackTrace) {
      sw.stop();
      _telemetry.recordError(
        e,
        stackTrace: stackTrace,
        errorCode: AppErrorCode.databaseError.code,
      );
      _logger.error(
        'FETCH_CONSULTATIONS_FAILED',
        operation: 'fetch_consultations',
        errorCode: AppErrorCode.databaseError.code,
        durationMs: sw.elapsedMilliseconds,
      );
      rethrow;
    }
  }

  /// Creates a new consultation session.
  Future<ConsultationModel> createConsultation({
    required String patientId,
    required String doctorId,
    required String clinicId,
    String status = 'draft',
  }) async {
    try {
      final payload = <String, dynamic>{
        'patient_id': patientId,
        'doctor_id': doctorId,
        'clinic_id': clinicId,
        'status': status,
        'started_at': DateTime.now().toIso8601String(),
      };

      final data = await _client
          .from('consultations')
          .insert(payload)
          .select()
          .single();

      return ConsultationModel.fromJson(data);
    } catch (e, stackTrace) {
      _telemetry.recordError(
        e,
        stackTrace: stackTrace,
        errorCode: AppErrorCode.databaseError.code,
      );
      _logger.error('CREATE_CONSULTATION_FAILED', operation: 'create_consultation', errorCode: AppErrorCode.databaseError.code);
      rethrow;
    }
  }

  /// Updates allowed consultation columns (status, ended_at).
  Future<ConsultationModel> updateConsultationStatus({
    required String consultationId,
    required String status,
    DateTime? endedAt,
  }) async {
    try {
      final payload = <String, dynamic>{
        'status': status,
        if (endedAt != null) 'ended_at': endedAt.toIso8601String(),
      };

      final data = await _client
          .from('consultations')
          .update(payload)
          .eq('id', consultationId)
          .select()
          .single();

      return ConsultationModel.fromJson(data);
    } catch (e, stackTrace) {
      _telemetry.recordError(
        e,
        stackTrace: stackTrace,
        errorCode: AppErrorCode.databaseError.code,
      );
      _logger.error('UPDATE_CONSULTATION_FAILED', operation: 'update_consultation', errorCode: AppErrorCode.databaseError.code);
      rethrow;
    }
  }
}
