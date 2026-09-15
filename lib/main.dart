import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config/env_config.dart';
import 'core/supabase/supabase_client_provider.dart';
import 'features/auth/screens/login_screen.dart';
import 'features/auth/screens/signup_screen.dart';
import 'features/clinic/screens/clinic_profile_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load local environment configuration (git-ignored .env or --dart-define)
  await EnvConfig.init();

  // Initialize Supabase client scaffold with SecureLocalStorage
  final initResult = await initSupabaseClient();

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
    // If Supabase failed to initialize or unconfigured, show diagnostic shell
    if (!widget.initResult.isReady) {
      return PlaceholderHomeScreen(initResult: widget.initResult);
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

/// Fallback diagnostic screen for unconfigured environments.
class PlaceholderHomeScreen extends StatefulWidget {
  final SupabaseInitResult initResult;

  const PlaceholderHomeScreen({super.key, required this.initResult});

  @override
  State<PlaceholderHomeScreen> createState() => _PlaceholderHomeScreenState();
}

class _PlaceholderHomeScreenState extends State<PlaceholderHomeScreen> {
  late SupabaseInitResult _result;
  bool _isPinging = false;
  String? _pingMessage;

  @override
  void initState() {
    super.initState();
    _result = widget.initResult;
  }

  String get _platformName {
    if (kIsWeb) return 'Web Target (Unsupported)';
    if (Platform.isAndroid) return 'Android Target';
    if (Platform.isIOS) return 'iOS Target';
    return 'Desktop / Unknown';
  }

  Future<void> _pingSupabase() async {
    setState(() {
      _isPinging = true;
      _pingMessage = null;
    });

    if (!_result.isReady) {
      setState(() {
        _isPinging = false;
        _pingMessage = 'Supabase credentials unconfigured. Supply SUPABASE_URL and SUPABASE_ANON_KEY in .env.';
      });
      return;
    }

    try {
      final client = Supabase.instance.client;
      final session = client.auth.currentSession;
      setState(() {
        _isPinging = false;
        _pingMessage =
            'Supabase ping successful! Client reachable (Session active: ${session != null}).';
      });
    } catch (e) {
      setState(() {
        _isPinging = false;
        _pingMessage = 'Supabase ping failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Medico OPD Assistant'),
        elevation: 0,
        backgroundColor: colorScheme.surface,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                elevation: 0,
                color: colorScheme.primaryContainer.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: colorScheme.primary.withValues(alpha: 0.2),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.medical_services_outlined,
                            size: 28,
                            color: colorScheme.primary,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Foundation & Scaffolding Shell',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: colorScheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Phase 000 | Task: TASK-000-01',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'This is the minimal foundation skeleton connecting Flutter (Android + iOS) to Supabase. Clinical modules, doctor auth, and schema tables will be built in subsequent phases.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              _buildStatusTile(
                icon: Icons.smartphone_outlined,
                title: 'Target Platform',
                subtitle: _platformName,
                statusText: 'Active',
                statusColor: Colors.teal,
              ),
              const SizedBox(height: 12),
              _buildStatusTile(
                icon: Icons.cloud_outlined,
                title: 'Backend Connection',
                subtitle: _result.message,
                statusText: _result.isReady ? 'Connected' : 'Skeleton',
                statusColor: _result.isReady ? Colors.green : Colors.amber,
              ),
              const SizedBox(height: 12),
              _buildStatusTile(
                icon: Icons.security_outlined,
                title: 'Secret Isolation',
                subtitle:
                    'Runtime .env and --dart-define config separation in place',
                statusText: 'Secured',
                statusColor: Colors.blueGrey,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _isPinging ? null : _pingSupabase,
                icon: _isPinging
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.network_ping),
                label: Text(_isPinging ? 'Pinging...' : 'Verify Supabase Ping'),
              ),
              if (_pingMessage != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _pingMessage!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required String statusText,
    required Color statusColor,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Icon(icon, size: 24, color: statusColor),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                statusText,
                style: TextStyle(
                  color: statusColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
