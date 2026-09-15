import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

    try {
      // 2. Register auth user via Supabase Auth
      final authResponse = await _client.auth.signUp(
        email: trimmedEmail,
        password: trimmedPassword,
      );

      final user = authResponse.user;
      if (user == null) {
        return AuthResult.failure(
          'Registration failed: no user account created.',
        );
      }

      // If email confirmation is required and no session yet, doctor will complete onboarding on first login.
      // If session is active, call atomic RPC immediately:
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

    try {
      final response = await _client.auth.signInWithPassword(
        email: trimmedEmail,
        password: trimmedPassword,
      );
      return AuthResult.success(response.user);
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
