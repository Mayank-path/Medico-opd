import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase/supabase_client_provider.dart';
import '../models/patient_model.dart';

class PatientService {
  final SupabaseClient? _customClient;

  PatientService({SupabaseClient? client}) : _customClient = client;

  SupabaseClient get _client => _customClient ?? supabaseClient;

  /// Fetches all patients belonging to the authenticated doctor's clinic.
  Future<List<PatientModel>> fetchPatients() async {
    try {
      final data = await _client
          .from('patients')
          .select()
          .order('created_at', ascending: false);

      return (data as List<dynamic>)
          .map((row) => PatientModel.fromJson(row as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[PatientService] Failed to fetch patients: $e');
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
    } catch (e) {
      debugPrint('[PatientService] Failed to fetch patient $patientId: $e');
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

      return PatientModel.fromJson(data);
    } catch (e) {
      debugPrint('[PatientService] Failed to create patient: $e');
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

      return PatientModel.fromJson(data);
    } catch (e) {
      debugPrint('[PatientService] Failed to update patient: $e');
      rethrow;
    }
  }
}
