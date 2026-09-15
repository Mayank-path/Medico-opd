import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase/supabase_client_provider.dart';
import '../models/clinic_model.dart';
import '../models/doctor_model.dart';

class ClinicService {
  final SupabaseClient? _customClient;

  ClinicService({SupabaseClient? client}) : _customClient = client;

  SupabaseClient get _client => _customClient ?? supabaseClient;

  /// Retrieves the current authenticated doctor's profile.
  Future<DoctorModel?> fetchCurrentDoctor() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return null;

    try {
      final data = await _client
          .from('doctors')
          .select()
          .eq('auth_user_id', userId)
          .maybeSingle();

      if (data == null) return null;
      return DoctorModel.fromJson(data);
    } catch (e) {
      debugPrint('[ClinicService] Failed to fetch current doctor: $e');
      rethrow;
    }
  }

  /// Retrieves the clinic record associated with the authenticated doctor.
  Future<ClinicModel?> fetchCurrentClinic(String clinicId) async {
    try {
      final data = await _client
          .from('clinics')
          .select()
          .eq('id', clinicId)
          .maybeSingle();

      if (data == null) return null;
      return ClinicModel.fromJson(data);
    } catch (e) {
      debugPrint('[ClinicService] Failed to fetch current clinic: $e');
      rethrow;
    }
  }

  /// Updates allowed doctor profile columns (full_name, qualifications, registration_number, contact_info).
  Future<void> updateDoctorProfile({
    required String doctorId,
    required String fullName,
    String? qualifications,
    String? registrationNumber,
    String? contactInfo,
  }) async {
    await _client
        .from('doctors')
        .update({
          'full_name': fullName.trim(),
          'qualifications': qualifications?.trim(),
          'registration_number': registrationNumber?.trim(),
          'contact_info': contactInfo?.trim(),
        })
        .eq('id', doctorId);
  }

  /// Updates allowed clinic columns (name, address, contact_info, logo_url).
  Future<void> updateClinicProfile({
    required String clinicId,
    required String name,
    String? address,
    String? contactInfo,
    String? logoUrl,
  }) async {
    await _client
        .from('clinics')
        .update({
          'name': name.trim(),
          'address': address?.trim(),
          'contact_info': contactInfo?.trim(),
          'logo_url': logoUrl?.trim(),
        })
        .eq('id', clinicId);
  }
}
