import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Centralized environment configuration loader.
/// Supports both compile-time `--dart-define` and git-ignored runtime `.env`.
class EnvConfig {
  static const String _envSupabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String _envSupabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
  );

  static bool _dotenvLoaded = false;

  /// Initializes environment variables by loading the `.env` asset if available.
  /// Gracefully catches missing file errors to prevent app crashes when `.env` is unprovisioned.
  static Future<void> init() async {
    try {
      await dotenv.load(fileName: '.env');
      _dotenvLoaded = true;
    } catch (e) {
      _dotenvLoaded = false;
      debugPrint('[EnvConfig] .env file not found or could not be loaded: $e');
      debugPrint(
        '[EnvConfig] Falling back to --dart-define or placeholder defaults.',
      );
    }
  }

  /// Supabase project URL.
  /// Supabase project URL.
  static String get supabaseUrl {
    if (_envSupabaseUrl.isNotEmpty &&
        !_envSupabaseUrl.contains('your-project') &&
        !_envSupabaseUrl.contains('placeholder')) {
      return _envSupabaseUrl;
    }
    if (_dotenvLoaded) {
      final url = dotenv.maybeGet('SUPABASE_URL') ?? '';
      if (url.isNotEmpty &&
          !url.contains('your-project') &&
          !url.contains('placeholder')) {
        return url;
      }
      final testUrl = dotenv.maybeGet('SUPABASE_TEST_URL') ?? '';
      if (testUrl.isNotEmpty &&
          !testUrl.contains('your-project') &&
          !testUrl.contains('placeholder')) {
        return testUrl;
      }
    }
    if (testSupabaseUrl.isNotEmpty &&
        !testSupabaseUrl.contains('your-project') &&
        !testSupabaseUrl.contains('placeholder')) {
      return testSupabaseUrl;
    }
    return '';
  }

  /// Supabase anonymous public API key.
  static String get supabaseAnonKey {
    if (_envSupabaseAnonKey.isNotEmpty &&
        !_envSupabaseAnonKey.contains('your-anon-key') &&
        !_envSupabaseAnonKey.contains('placeholder')) {
      return _envSupabaseAnonKey;
    }
    if (_dotenvLoaded) {
      final key = dotenv.maybeGet('SUPABASE_ANON_KEY') ?? '';
      if (key.isNotEmpty &&
          !key.contains('your-anon-key') &&
          !key.contains('placeholder')) {
        return key;
      }
      final testKey = dotenv.maybeGet('SUPABASE_TEST_ANON_KEY') ?? '';
      if (testKey.isNotEmpty &&
          !testKey.contains('your-anon-key') &&
          !testKey.contains('placeholder')) {
        return testKey;
      }
    }
    if (testSupabaseAnonKey.isNotEmpty &&
        !testSupabaseAnonKey.contains('your-anon-key') &&
        !testSupabaseAnonKey.contains('placeholder')) {
      return testSupabaseAnonKey;
    }
    return '';
  }

  /// Checks whether real (non-placeholder) credentials have been configured.
  static bool get isConfigured {
    final url = supabaseUrl.trim();
    final key = supabaseAnonKey.trim();

    if (url.isEmpty || key.isEmpty) {
      return false;
    }
    if (url.contains('placeholder') || url.contains('your-project')) {
      return false;
    }
    if (key.contains('placeholder') || key.contains('your-anon-key')) {
      return false;
    }

    return Uri.tryParse(url)?.hasAbsolutePath ?? false;
  }

  /// Optional test doctor email used for automated CI device screen capture.
  static String? get testDoctorEmail {
    const fromEnv = String.fromEnvironment('CI_TEST_DOCTOR_EMAIL');
    if (fromEnv.isNotEmpty) return fromEnv;
    const fromEnvAlt = String.fromEnvironment('TEST_DOCTOR_EMAIL');
    if (fromEnvAlt.isNotEmpty) return fromEnvAlt;
    if (_dotenvLoaded) {
      return dotenv.maybeGet('CI_TEST_DOCTOR_EMAIL') ??
          dotenv.maybeGet('TEST_DOCTOR_EMAIL');
    }
    return null;
  }

  /// Optional test doctor password used for automated CI device screen capture.
  static String? get testDoctorPassword {
    const fromEnv = String.fromEnvironment('CI_TEST_DOCTOR_PASSWORD');
    if (fromEnv.isNotEmpty) return fromEnv;
    const fromEnvAlt = String.fromEnvironment('TEST_DOCTOR_PASSWORD');
    if (fromEnvAlt.isNotEmpty) return fromEnvAlt;
    if (_dotenvLoaded) {
      return dotenv.maybeGet('CI_TEST_DOCTOR_PASSWORD') ??
          dotenv.maybeGet('TEST_DOCTOR_PASSWORD');
    }
    return null;
  }

  /// Supabase test project URL (used exclusively for testing/staging).
  static String get testSupabaseUrl {
    const fromEnv = String.fromEnvironment('SUPABASE_TEST_URL');
    if (fromEnv.isNotEmpty) return fromEnv;
    if (_dotenvLoaded) return dotenv.maybeGet('SUPABASE_TEST_URL') ?? '';
    return '';
  }

  /// Supabase test project anonymous public API key.
  static String get testSupabaseAnonKey {
    const fromEnv = String.fromEnvironment('SUPABASE_TEST_ANON_KEY');
    if (fromEnv.isNotEmpty) return fromEnv;
    if (_dotenvLoaded) return dotenv.maybeGet('SUPABASE_TEST_ANON_KEY') ?? '';
    return '';
  }

  /// Supabase test project service role key.
  static String? get testSupabaseServiceRoleKey {
    const fromEnv = String.fromEnvironment('SUPABASE_TEST_SERVICE_ROLE_KEY');
    if (fromEnv.isNotEmpty) return fromEnv;
    if (_dotenvLoaded) return dotenv.maybeGet('SUPABASE_TEST_SERVICE_ROLE_KEY');
    return null;
  }
}
