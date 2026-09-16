import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/env_config.dart';
import '../../../core/supabase/supabase_client_provider.dart';

class AuthResult {
  final bool isSuccess;
  final String? errorMessage;
  final User? user;

  const AuthResult({required this.isSuccess, this.errorMessage, this.user});

  factory AuthResult.success([User? user]) =>
      AuthResult(isSuccess: true, user: user);
  factory AuthResult.failure(String message) =>
      AuthResult(isSuccess: false, errorMessage: message);
}

class AuthService {
  final SupabaseClient? _customClient;

  AuthService({SupabaseClient? client}) : _customClient = client;

  SupabaseClient get _client => _customClient ?? supabaseClient;

  User? get currentUser => _client.auth.currentUser;
  Session? get currentSession => _client.auth.currentSession;
  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  /// Registers a doctor and atomically provisions their clinic in a single RPC transaction.
  Future<AuthResult> signUpWithClinic({
    required String email,
    required String password,
    required String doctorName,
    String? qualifications,
    String? registrationNumber,
    String? doctorContact,
    required String clinicName,
    String? clinicAddress,
    String? clinicContact,
  }) async {
    // 1. Client-side input validations
    final trimmedEmail = email.trim();
    final trimmedPassword = password.trim();
    final trimmedDoctorName = doctorName.trim();
    final trimmedClinicName = clinicName.trim();

    if (trimmedEmail.isEmpty || !trimmedEmail.contains('@')) {
      return AuthResult.failure('Please provide a valid email address.');
    }
    if (trimmedPassword.length < 6) {
      return AuthResult.failure('Password must be at least 6 characters long.');
    }
    if (trimmedDoctorName.isEmpty) {
      return AuthResult.failure('Doctor name is required.');
    }
    if (trimmedClinicName.isEmpty) {
      return AuthResult.failure('Clinic name is required.');
    }

    if (_customClient == null && !EnvConfig.isConfigured) {
      return AuthResult.failure(
        'Supabase credentials unconfigured. Please configure SUPABASE_URL and SUPABASE_ANON_KEY in your .env.',
      );
    }

    try {
      // 2. Register auth user via Supabase Auth
      final authResponse = await _client.auth.signUp(
        email: trimmedEmail,
        password: trimmedPassword,
        data: {
          'doctor_name': trimmedDoctorName,
          'qualifications': qualifications?.trim() ?? '',
          'registration_number': registrationNumber?.trim() ?? '',
          'doctor_contact': doctorContact?.trim() ?? '',
          'clinic_name': trimmedClinicName,
          'clinic_address': clinicAddress?.trim() ?? '',
          'clinic_contact': clinicContact?.trim() ?? '',
        },
      );

      final user = authResponse.user;
      if (user == null) {
        return AuthResult.failure(
          'Registration failed: no user account created.',
        );
      }

      // If session is already active (e.g. autoconfirm or admin creation), call atomic RPC immediately:
      if (_client.auth.currentSession != null) {
        await _client.rpc(
          'create_clinic_and_doctor',
          params: {
            'p_clinic_name': trimmedClinicName,
            'p_clinic_address': clinicAddress?.trim() ?? '',
            'p_clinic_contact': clinicContact?.trim() ?? '',
            'p_doctor_name': trimmedDoctorName,
            'p_qualifications': qualifications?.trim() ?? '',
            'p_registration_number': registrationNumber?.trim() ?? '',
            'p_doctor_contact': doctorContact?.trim() ?? '',
          },
        );
      }

      return AuthResult.success(user);
    } on AuthException catch (e) {
      debugPrint('[AuthService] AuthException: ${e.message}');
      return AuthResult.failure(_sanitizeAuthError(e.message));
    } on PostgrestException catch (e) {
      debugPrint('[AuthService] PostgrestException: ${e.message}');
      return AuthResult.failure(_sanitizePostgrestError(e.message));
    } catch (e) {
      debugPrint('[AuthService] Unexpected error: $e');
      return AuthResult.failure(
        'An unexpected error occurred during signup. Please try again.',
      );
    }
  }

  /// Finalizes clinic and doctor onboarding if pending after email confirmation.
  ///
  /// Guaranteed to be atomic and idempotent. If a doctor record already exists,
  /// this safely returns [AuthResult.success]. If onboarding is pending, it executes
  /// the [create_clinic_and_doctor] RPC.
  Future<AuthResult> finalizePendingOnboarding([User? targetUser]) async {
    final user = targetUser ?? currentUser;
    if (user == null) {
      return AuthResult.failure('No authenticated session found.');
    }

    try {
      final existingDoctor = await _client
          .from('doctors')
          .select('id')
          .eq('auth_user_id', user.id)
          .maybeSingle();

      if (existingDoctor != null) {
        return AuthResult.success(user);
      }

      final meta = user.userMetadata ?? {};
      final clinicName = meta['clinic_name'] as String?;
      final doctorName = meta['doctor_name'] as String?;

      if (clinicName == null ||
          clinicName.trim().isEmpty ||
          doctorName == null ||
          doctorName.trim().isEmpty) {
        return AuthResult.failure(
          'Account setup incomplete: Missing clinic or doctor registration details.',
        );
      }

      await _client.rpc(
        'create_clinic_and_doctor',
        params: {
          'p_clinic_name': clinicName.trim(),
          'p_clinic_address': (meta['clinic_address'] as String?)?.trim() ?? '',
          'p_clinic_contact': (meta['clinic_contact'] as String?)?.trim() ?? '',
          'p_doctor_name': doctorName.trim(),
          'p_qualifications': (meta['qualifications'] as String?)?.trim() ?? '',
          'p_registration_number':
              (meta['registration_number'] as String?)?.trim() ?? '',
          'p_doctor_contact': (meta['doctor_contact'] as String?)?.trim() ?? '',
        },
      );

      return AuthResult.success(user);
    } on PostgrestException catch (e) {
      debugPrint(
        '[AuthService] PostgrestException in finalizePendingOnboarding: ${e.message}',
      );
      if (e.message.contains('Doctor is already associated with a clinic')) {
        return AuthResult.success(user);
      }
      return AuthResult.failure(_sanitizePostgrestError(e.message));
    } catch (e) {
      debugPrint(
        '[AuthService] Unexpected error in finalizePendingOnboarding: $e',
      );
      return AuthResult.failure(
        'Failed to finalize clinic setup. Please check your connection and retry.',
      );
    }
  }

  /// Authenticates a doctor with email and password.
  Future<AuthResult> signIn({
    required String email,
    required String password,
  }) async {
    final trimmedEmail = email.trim();
    final trimmedPassword = password.trim();

    if (trimmedEmail.isEmpty || trimmedPassword.isEmpty) {
      return AuthResult.failure('Email and password cannot be empty.');
    }

    if (_customClient == null && !EnvConfig.isConfigured) {
      return AuthResult.failure(
        'Supabase credentials unconfigured. Please configure SUPABASE_URL and SUPABASE_ANON_KEY in your .env.',
      );
    }

    try {
      final response = await _client.auth.signInWithPassword(
        email: trimmedEmail,
        password: trimmedPassword,
      );

      final user = response.user;
      if (user != null) {
        await finalizePendingOnboarding(user);
      }

      return AuthResult.success(user);
    } on AuthException catch (e) {
      debugPrint('[AuthService] AuthException: ${e.message}');
      return AuthResult.failure(_sanitizeAuthError(e.message));
    } catch (e) {
      debugPrint('[AuthService] Unexpected error during sign in: $e');
      return AuthResult.failure(
        'Failed to sign in. Please verify your connection.',
      );
    }
  }

  /// Terminates the doctor's active session and clears secure tokens.
  Future<void> signOut() async {
    try {
      await _client.auth.signOut();
    } catch (e) {
      debugPrint('[AuthService] Error during signOut: $e');
    }
  }

  String _sanitizeAuthError(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('invalid login credentials') ||
        lower.contains('invalid credentials')) {
      return 'Invalid email or password.';
    }
    if (lower.contains('user already registered') ||
        lower.contains('already exists')) {
      return 'An account with this email already exists.';
    }
    if (lower.contains('password should be at least')) {
      return 'Password is too weak. Must be at least 6 characters.';
    }
    return 'Authentication failed: $message';
  }

  String _sanitizePostgrestError(String message) {
    if (message.contains('already associated with a clinic')) {
      return 'Doctor profile already exists for this account.';
    }
    if (message.contains('Clinic name is required')) {
      return 'Clinic name is required.';
    }
    if (message.contains('Doctor name is required')) {
      return 'Doctor name is required.';
    }
    return 'Failed to save clinic or doctor profile.';
  }
}
