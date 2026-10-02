import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/observability/observability.dart';
import '../../../core/pagination/keyset_cursor.dart';
import '../../../core/pagination/paginated_result.dart';
import '../../../core/supabase/supabase_client_provider.dart';
import '../models/patient_model.dart';

class PatientService {
  final SupabaseClient? _customClient;
  final TelemetryService _telemetry;
  final StructuredLogger _logger;

  PatientService({
    SupabaseClient? client,
    TelemetryService? telemetry,
  })  : _customClient = client,
        _telemetry = telemetry ?? Telemetry.instance,
        _logger = StructuredLogger('patient_service');

  SupabaseClient get _client => _customClient ?? supabaseClient;

  /// Fetches patients belonging to the authenticated doctor's clinic,
  /// with keyset/cursor pagination, explicit column projection, and optional search.
  /// Limits are clamped between 1 and 100 (default 20).
  Future<PaginatedResult<PatientModel>> fetchPatients({
    int limit = 20,
    String? cursor,
    String? searchQuery,
  }) async {
    final sw = Stopwatch()..start();
    final isSearch = searchQuery != null && searchQuery.trim().isNotEmpty;
    try {
      final safeLimit = limit.clamp(1, 100);

      // PART E: Explicit column projection to eliminate SELECT *
      var query = _client.from('patients').select(
        'id, clinic_id, full_name, dob_or_age, sex, contact_info, opd_number, created_at, created_by',
      );

      // PART B: Search filtering compatible with GIN trigram indexes
      if (isSearch) {
        final term = searchQuery.trim();
        query = query.or(
          'full_name.ilike.%$term%,opd_number.ilike.%$term%,contact_info.ilike.%$term%',
        );
      }

      // PART B: Keyset pagination filter using deterministic (created_at DESC, id DESC)
      if (cursor != null && cursor.trim().isNotEmpty) {
        final c = KeysetCursor.decode(cursor);
        query = query.or(
          'created_at.lt.${c.createdAtIso},and(created_at.eq.${c.createdAtIso},id.lt.${c.id})',
        );
      }

      // PART B: Deterministic ordering with id tie-breaker
      final data = await query
          .order('created_at', ascending: false)
          .order('id', ascending: false)
          .limit(safeLimit + 1);

      final rawList = (data as List<dynamic>)
          .map((row) => PatientModel.fromJson(row as Map<String, dynamic>))
          .toList();

      final hasMore = rawList.length > safeLimit;
      final items = hasMore ? rawList.sublist(0, safeLimit) : rawList;

      String? nextCursor;
      if (hasMore && items.isNotEmpty) {
        final last = items.last;
        nextCursor = KeysetCursor(createdAt: last.createdAt, id: last.id).encode();
      }

      final durationMs = sw.elapsedMilliseconds;
      final metricName = isSearch
          ? MetricDefinitions.patientSearchLatencyMs
          : MetricDefinitions.patientQueryLatencyMs;
      _telemetry.timing(metricName, durationMs);
      _logger.info(
        isSearch ? 'PATIENT_SEARCH_COMPLETED' : 'PATIENTS_FETCHED',
        operation: 'fetch_patients',
        durationMs: durationMs,
        metadata: {'returned_count': items.length, 'has_more': hasMore},
      );

      return PaginatedResult<PatientModel>(
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
        'FETCH_PATIENTS_FAILED',
        operation: 'fetch_patients',
        errorCode: AppErrorCode.databaseError.code,
        durationMs: sw.elapsedMilliseconds,
      );
      rethrow;
    }
  }

  /// Fetches a specific patient by ID.
  Future<PatientModel?> fetchPatientById(String patientId) async {
    try {
      final data = await _client
          .from('patients')
          .select()
          .eq('id', patientId)
          .maybeSingle();

      if (data == null) return null;
      return PatientModel.fromJson(data);
    } catch (e, stackTrace) {
      _telemetry.recordError(e, stackTrace: stackTrace, errorCode: AppErrorCode.databaseError.code);
      _logger.error('FETCH_PATIENT_BY_ID_FAILED', operation: 'fetch_patient_by_id', errorCode: AppErrorCode.databaseError.code);
      rethrow;
    }
  }

  /// Creates a new patient within the specified clinic.
  Future<PatientModel> createPatient({
    required String clinicId,
    required String fullName,
    String? dobOrAge,
    String? sex,
    String? contactInfo,
    String? opdNumber,
    String? createdBy,
  }) async {
    try {
      final payload = <String, dynamic>{
        'clinic_id': clinicId,
        'full_name': fullName.trim(),
        if (dobOrAge != null && dobOrAge.trim().isNotEmpty)
          'dob_or_age': dobOrAge.trim(),
        if (sex != null && sex.trim().isNotEmpty) 'sex': sex.trim(),
        if (contactInfo != null && contactInfo.trim().isNotEmpty)
          'contact_info': contactInfo.trim(),
        if (opdNumber != null && opdNumber.trim().isNotEmpty)
          'opd_number': opdNumber.trim(),
        'created_by': ?createdBy,
      };

      final data = await _client
          .from('patients')
          .insert(payload)
          .select()
          .single();

      _logger.info('PATIENT_CREATED', operation: 'create_patient', clinicId: clinicId);
      return PatientModel.fromJson(data);
    } catch (e, stackTrace) {
      _telemetry.recordError(e, stackTrace: stackTrace, errorCode: AppErrorCode.databaseError.code);
      _logger.error('CREATE_PATIENT_FAILED', operation: 'create_patient', errorCode: AppErrorCode.databaseError.code, clinicId: clinicId);
      rethrow;
    }
  }

  /// Updates allowed patient columns (full_name, dob_or_age, sex, contact_info, opd_number).
  Future<PatientModel> updatePatient({
    required String patientId,
    required String fullName,
    String? dobOrAge,
    String? sex,
    String? contactInfo,
    String? opdNumber,
  }) async {
    try {
      final data = await _client
          .from('patients')
          .update({
            'full_name': fullName.trim(),
            'dob_or_age': dobOrAge?.trim(),
            'sex': sex?.trim(),
            'contact_info': contactInfo?.trim(),
            'opd_number': opdNumber?.trim(),
          })
          .eq('id', patientId)
          .select()
          .single();

      _logger.info('PATIENT_UPDATED', operation: 'update_patient');
      return PatientModel.fromJson(data);
    } catch (e, stackTrace) {
      _telemetry.recordError(e, stackTrace: stackTrace, errorCode: AppErrorCode.databaseError.code);
      _logger.error('UPDATE_PATIENT_FAILED', operation: 'update_patient', errorCode: AppErrorCode.databaseError.code);
      rethrow;
    }
  }
}
