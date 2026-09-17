import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase/supabase_client_provider.dart';
import '../models/consultation_model.dart';

class ConsultationService {
  final SupabaseClient? _customClient;

  ConsultationService({SupabaseClient? client}) : _customClient = client;

  SupabaseClient get _client => _customClient ?? supabaseClient;

  /// Fetches consultations for a given patient, ordered from newest to oldest.
  Future<List<ConsultationModel>> fetchConsultationsForPatient(
    String patientId,
  ) async {
    try {
      final data = await _client
          .from('consultations')
          .select()
          .eq('patient_id', patientId)
          .order('created_at', ascending: false);

      return (data as List<dynamic>)
          .map((row) => ConsultationModel.fromJson(row as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint(
        '[ConsultationService] Failed to fetch consultations for patient $patientId: $e',
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
    } catch (e) {
      debugPrint('[ConsultationService] Failed to create consultation: $e');
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
    } catch (e) {
      debugPrint('[ConsultationService] Failed to update consultation: $e');
      rethrow;
    }
  }
}
