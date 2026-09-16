// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('Provision or ensure CI test doctor exists in medico-opd-test', () async {
    // Read environment variables or load from .env
    final env = <String, String>{};
    final envFile = File('.env');
    if (envFile.existsSync()) {
      for (final line in envFile.readAsLinesSync()) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        final eqIndex = trimmed.indexOf('=');
        if (eqIndex > 0) {
          final key = trimmed.substring(0, eqIndex).trim();
          var val = trimmed.substring(eqIndex + 1).trim();
          if (val.startsWith('"') && val.endsWith('"') && val.length >= 2) {
            val = val.substring(1, val.length - 1);
          }
          env[key] = val;
        }
      }
    }

    String getVal(String key) {
      final sysVal = Platform.environment[key];
      if (sysVal != null && sysVal.isNotEmpty) return sysVal;
      return env[key] ?? '';
    }

    String normalizeSupabaseUrl(String raw) {
      var url = raw.trim();
      if (url.startsWith('https://supabase.com/dashboard/project/')) {
        final ref = url
            .replaceFirst('https://supabase.com/dashboard/project/', '')
            .split('/')
            .first;
        return 'https://$ref.supabase.co';
      }
      return url;
    }

    final testUrl = normalizeSupabaseUrl(getVal('SUPABASE_TEST_URL'));
    final testAnonKey = getVal('SUPABASE_TEST_ANON_KEY');
    final testServiceRoleKey = getVal('SUPABASE_TEST_SERVICE_ROLE_KEY');
    final prodUrl = normalizeSupabaseUrl(getVal('SUPABASE_URL'));

    final email = getVal('CI_TEST_DOCTOR_EMAIL').isNotEmpty
        ? getVal('CI_TEST_DOCTOR_EMAIL')
        : (getVal('TEST_DOCTOR_EMAIL').isNotEmpty
              ? getVal('TEST_DOCTOR_EMAIL')
              : 'dr.rajesh.sharma.ci@medico-opd.in');
    final password = getVal('CI_TEST_DOCTOR_PASSWORD').isNotEmpty
        ? getVal('CI_TEST_DOCTOR_PASSWORD')
        : (getVal('TEST_DOCTOR_PASSWORD').isNotEmpty
              ? getVal('TEST_DOCTOR_PASSWORD')
              : 'SecureTestPass123!');

    if (testUrl.isEmpty || testServiceRoleKey.isEmpty) {
      print(
        'Skipping CI test doctor provisioning: SUPABASE_TEST_URL or SUPABASE_TEST_SERVICE_ROLE_KEY not configured.',
      );
      return;
    }

    // Production Guard
    if (prodUrl.isNotEmpty && testUrl == prodUrl) {
      throw StateError(
        'FATAL: SUPABASE_TEST_URL matches production SUPABASE_URL',
      );
    }
    if (testUrl.contains('dyfrknwejqwilstcoytt')) {
      throw StateError('FATAL: SUPABASE_TEST_URL points to production project');
    }

    final adminClient = SupabaseClient(testUrl, testServiceRoleKey);

    print('Checking test doctor ($email) in $testUrl...');
    final users = await adminClient.auth.admin.listUsers();
    var user = users.cast<User?>().firstWhere(
      (u) => u?.email == email,
      orElse: () => null,
    );

    if (user == null) {
      print('Creating pre-confirmed test doctor auth user...');
      final created = await adminClient.auth.admin.createUser(
        AdminUserAttributes(
          email: email,
          password: password,
          emailConfirm: true,
        ),
      );
      user = created.user;
      expect(user, isNotNull);
      print('Created auth user ${user!.id}.');
    } else {
      print(
        'Auth user already exists (${user.id}). Updating password to ensure match...',
      );
      await adminClient.auth.admin.updateUserById(
        user.id,
        attributes: AdminUserAttributes(password: password, emailConfirm: true),
      );
    }

    // Check if doctor and clinic exist for this user
    final doc = await adminClient
        .from('doctors')
        .select('id, clinic_id, full_name')
        .eq('auth_user_id', user.id)
        .maybeSingle();

    if (doc != null) {
      print(
        'Test doctor profile already exists (Doctor ID: ${doc['id']}, Clinic ID: ${doc['clinic_id']}, Name: ${doc['full_name']}). Reusing existing account.',
      );
    } else {
      print(
        'Provisioning clinic and doctor profile via atomic RPC create_clinic_and_doctor...',
      );
      expect(testAnonKey.isNotEmpty, isTrue);
      final anonClient = SupabaseClient(
        testUrl,
        testAnonKey,
        authOptions: const AuthClientOptions(
          authFlowType: AuthFlowType.implicit,
        ),
      );
      await anonClient.auth.signInWithPassword(
        email: email,
        password: password,
      );
      final rpcRes = await anonClient.rpc(
        'create_clinic_and_doctor',
        params: {
          'p_clinic_name': 'Apex Care Clinic',
          'p_clinic_address': 'Plot 42, Knowledge Park III, Greater Noida',
          'p_clinic_contact': '+91-120-4567890',
          'p_doctor_name': 'Dr. Rajesh Sharma',
          'p_qualifications': 'MBBS, MD (Medicine)',
          'p_registration_number': 'DMC-2024-9876',
          'p_doctor_contact': '+91-9876501234',
        },
      );
      print('Provisioned clinic and doctor: $rpcRes');
    }

    print('SUCCESS: Test doctor account is ready for automated UI capture.');
  });
}
