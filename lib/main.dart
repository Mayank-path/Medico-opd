import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config/env_config.dart';
import 'core/supabase/supabase_client_provider.dart';
import 'core/test/ci_flow_coordinator.dart';
import 'features/auth/screens/login_screen.dart';
import 'features/auth/screens/signup_screen.dart';
import 'features/clinic/screens/clinic_profile_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load local environment configuration (git-ignored .env or --dart-define)
  await EnvConfig.init();

  // Initialize Supabase client scaffold with SecureLocalStorage
  final initResult = await initSupabaseClient();

  if (kDebugMode &&
      const bool.fromEnvironment('CI_CAPTURE_FLOW', defaultValue: false)) {
    CiFlowCoordinator.init();
  }

  runApp(MedicoApp(initialResult: initResult));
}

class MedicoApp extends StatelessWidget {
  final SupabaseInitResult initialResult;

  const MedicoApp({super.key, required this.initialResult});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Medico OPD Assistant',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF007A78), // Clinical teal
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F9FA),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF007A78),
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: AuthGate(initResult: initialResult),
    );
  }
}

/// Dynamic router handling authentication status and unconfigured fallback.
class AuthGate extends StatefulWidget {
  final SupabaseInitResult initResult;

  const AuthGate({super.key, required this.initResult});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _showSignup = false;

  void _toggleAuthScreen(bool showSignup) {
    setState(() {
      _showSignup = showSignup;
    });
  }

  @override
  Widget build(BuildContext context) {
    // If Supabase is not configured / initialized, render Login/Signup screens directly
    if (!widget.initResult.isReady) {
      if (_showSignup) {
        return SignupScreen(onNavigateToLogin: () => _toggleAuthScreen(false));
      } else {
        return LoginScreen(onNavigateToSignup: () => _toggleAuthScreen(true));
      }
    }

    // StreamBuilder listening to Supabase Auth state changes
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = Supabase.instance.client.auth.currentSession;

        if (session != null) {
          return const ClinicProfileScreen();
        }

        if (_showSignup) {
          return SignupScreen(
            onNavigateToLogin: () => _toggleAuthScreen(false),
          );
        } else {
          return LoginScreen(onNavigateToSignup: () => _toggleAuthScreen(true));
        }
      },
    );
  }
}
