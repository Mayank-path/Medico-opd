import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env_config.dart';
import 'secure_local_storage.dart';

enum SupabaseState { unconfigured, initialized, error }

class SupabaseInitResult {
  final SupabaseState state;
  final String message;

  const SupabaseInitResult({required this.state, required this.message});

  bool get isReady => state == SupabaseState.initialized;
}

/// Returns the active SupabaseClient instance.
SupabaseClient get supabaseClient => Supabase.instance.client;

/// Initializes the Supabase client safely with secure token storage.
Future<SupabaseInitResult> initSupabaseClient({
  LocalStorage? authLocalStorage,
}) async {
  if (!EnvConfig.isConfigured) {
    debugPrint('[Supabase] Credentials not configured or using placeholders.');
    return const SupabaseInitResult(
      state: SupabaseState.unconfigured,
      message: 'Supabase credentials are unconfigured or placeholder. Provide valid SUPABASE_URL and SUPABASE_ANON_KEY in your local .env or via --dart-define.',
    );
  }

  try {
    await Supabase.initialize(
      url: EnvConfig.supabaseUrl,
      publishableKey: EnvConfig.supabaseAnonKey,
      authOptions: FlutterAuthClientOptions(
        localStorage: authLocalStorage ?? const SecureLocalStorage(),
      ),
    );
    debugPrint(
      '[Supabase] Successfully initialized Supabase client with SecureLocalStorage.',
    );
    return const SupabaseInitResult(
      state: SupabaseState.initialized,
      message: 'Supabase client initialized successfully.',
    );
  } catch (e) {
    debugPrint('[Supabase] Initialization failed: $e');
    return SupabaseInitResult(
      state: SupabaseState.error,
      message: 'Failed to initialize Supabase client: $e',
    );
  }
}
