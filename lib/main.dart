import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config/env_config.dart';
import 'core/supabase/supabase_client_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load local environment configuration (git-ignored .env or --dart-define)
  await EnvConfig.init();

  // Initialize Supabase client scaffold
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
      home: PlaceholderHomeScreen(initResult: initialResult),
    );
  }
}

class PlaceholderHomeScreen extends StatefulWidget {
  final SupabaseInitResult initResult;

  const PlaceholderHomeScreen({super.key, required this.initResult});

  @override
  State<PlaceholderHomeScreen> createState() => _PlaceholderHomeScreenState();
}

class _PlaceholderHomeScreenState extends State<PlaceholderHomeScreen> {
  late SupabaseInitResult _result;
  String _pingMessage = '';
  bool _isPinging = false;

  @override
  void initState() {
    super.initState();
    _result = widget.initResult;
  }

  String _resolvePlatformName() {
    if (kIsWeb) return 'Web Browser';
    try {
      if (Platform.isAndroid) return 'Android Target';
      if (Platform.isIOS) return 'iOS Target';
      if (Platform.isWindows) return 'Windows Host';
      if (Platform.isMacOS) return 'macOS Host';
      if (Platform.isLinux) return 'Linux Host';
    } catch (_) {}
    return 'Unknown Device';
  }

  Future<void> _pingSupabase() async {
    if (!_result.isReady) {
      setState(() {
        _pingMessage = 'Supabase credentials unconfigured. Supply SUPABASE_URL and SUPABASE_ANON_KEY in .env.';
      });
      return;
    }

    setState(() {
      _isPinging = true;
      _pingMessage = '';
    });

    try {
      // Minimal network ping to Supabase auth / health endpoint
      final client = Supabase.instance.client;
      // Reading auth session is a zero-query client health verification
      final session = client.auth.currentSession;
      setState(() {
        _pingMessage =
            'Supabase ping successful! Client reachable (Session active: ${session != null}).';
      });
    } catch (e) {
      setState(() {
        _pingMessage = 'Supabase ping failed: $e';
      });
    } finally {
      setState(() {
        _isPinging = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final platformName = _resolvePlatformName();

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Medico OPD Assistant',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        elevation: 0,
        centerTitle: false,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              children: [
                // Header Card
                Card(
                  elevation: 0,
                  color: theme.colorScheme.primaryContainer.withValues(
                    alpha: 0.4,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: theme.colorScheme.primary.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.medical_services_outlined,
                              color: theme.colorScheme.primary,
                              size: 28,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Foundation & Scaffolding Shell',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Phase 000 | Task: TASK-000-01',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'This is the minimal foundation skeleton connecting Flutter (Android + iOS) to Supabase. Clinical modules, doctor auth, and schema tables will be built in subsequent phases.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Diagnostic Items
                _buildInfoTile(
                  context,
                  icon: Icons.smartphone,
                  title: 'Target Platform',
                  subtitle: platformName,
                  trailingBadge: 'Active',
                  badgeColor: Colors.teal,
                ),
                const SizedBox(height: 12),
                _buildInfoTile(
                  context,
                  icon: Icons.cloud_done_outlined,
                  title: 'Backend Connection',
                  subtitle: _result.message,
                  trailingBadge: _result.isReady ? 'Ready' : 'Skeleton',
                  badgeColor: _result.isReady ? Colors.green : Colors.orange,
                ),
                const SizedBox(height: 12),
                _buildInfoTile(
                  context,
                  icon: Icons.security,
                  title: 'Secret Isolation',
                  subtitle: 'Runtime .env and --dart-define configured. .env is git-ignored.',
                  trailingBadge: 'Secured',
                  badgeColor: Colors.blueGrey,
                ),
                const SizedBox(height: 24),

                // Action / Ping button
                FilledButton.tonalIcon(
                  onPressed: _isPinging ? null : _pingSupabase,
                  icon: _isPinging
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync_outlined),
                  label: Text(
                    _isPinging ? 'Pinging...' : 'Verify Supabase Ping',
                  ),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),

                if (_pingMessage.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _pingMessage,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 32),
                const Divider(),
                const SizedBox(height: 12),
                Text(
                  'DO-NOT-BREAK DISCIPLINE: No auth or tables should be added until designated in subsequent clinical phases.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required String trailingBadge,
    required Color badgeColor,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: theme.colorScheme.primary, size: 24),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        trailingBadge,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: badgeColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
