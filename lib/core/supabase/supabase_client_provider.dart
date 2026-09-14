import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env_config.dart';

enum SupabaseState { unconfigured, initialized, error }

class SupabaseInitResult {
  final SupabaseState state;
  final String message;

  const SupabaseInitResult({required this.state, required this.message});

  bool get isReady => state == SupabaseState.initialized;
}

/// Initializes the Supabase client safely without hardcoded credentials.
Future<SupabaseInitResult> initSupabaseClient() async {
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
    );
    debugPrint('[Supabase] Successfully initialized Supabase client.');
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
