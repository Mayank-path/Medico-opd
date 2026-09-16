// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/core/config/env_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String? _getEnvValue(String key) {
  final envVar = Platform.environment[key];
  if (envVar != null && envVar.isNotEmpty) return envVar;

  final envFile = File('.env');
  if (envFile.existsSync()) {
    for (final line in envFile.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.startsWith('$key=')) {
        final val = trimmed.substring('$key='.length).trim();
        if (val.isNotEmpty) return val;
      }
    }
  }
  return null;
}

/// Refinement 2: Self-updating production guard.
/// Verifies that testUrl does not match the loaded production URL or point to the known production project ref.
void verifyNotProductionUrl(String testUrl, String prodUrl) {
  final cleanTest = testUrl.trim().toLowerCase();
  final cleanProd = prodUrl.trim().toLowerCase();

  if (cleanTest.isNotEmpty && cleanProd.isNotEmpty && cleanTest == cleanProd) {
    throw StateError(
      'FATAL: SUPABASE_TEST_URL matches production SUPABASE_URL ($cleanProd) — refusing to run tests against production.',
    );
  }

  if (cleanTest.contains('dyfrknwejqwilstcoytt')) {
    throw StateError(
      'FATAL: SUPABASE_TEST_URL points to known production project (dyfrknwejqwilstcoytt) — refusing to run tests against production.',
    );
  }
}

/// Refinement 1: FK deletion ordering in cleanup.
/// 1. Delete the auth user via Admin API (cascades to delete public.doctors via auth_user_id ON DELETE CASCADE).
/// 2. Only then delete the unreferenced public.clinics row (which has ON DELETE RESTRICT).
Future<void> cleanupUserAndClinic({
  required SupabaseClient adminClient,
  required String userId,
  String? clinicId,
}) async {
  // Step 1: Delete auth user -> cascades and deletes doctor row
  try {
    await adminClient.auth.admin.deleteUser(userId);
  } catch (e) {
    if (!e.toString().contains('user_not_found') &&
        !e.toString().contains('User not found')) {
      stderr.writeln(
        '[cleanupUserAndClinic] Warning: failed to delete auth user $userId: $e',
      );
    }
  }

  // Step 2: Delete clinic row now that doctors table no longer references it
  if (clinicId != null) {
    try {
      await adminClient.from('clinics').delete().eq('id', clinicId);
    } catch (e) {
      stderr.writeln(
        '[cleanupUserAndClinic] Warning: failed to delete clinic $clinicId: $e',
      );
    }
  }
}

void main() {
  // Standalone unit tests for Refinement 2 (Production Guard) - runs regardless of keys
  group('Production URL Guardrail Tests (Refinement 2)', () {
    test('Guardrail throws StateError when SUPABASE_TEST_URL equals production SUPABASE_URL', () {
      expect(
        () => verifyNotProductionUrl(
          'https://dyfrknwejqwilstcoytt.supabase.co',
          'https://dyfrknwejqwilstcoytt.supabase.co',
        ),
        throwsA(
          predicate(
            (e) =>
                e is StateError &&
                e.message.contains('matches production SUPABASE_URL'),
          ),
        ),
      );
    });

    test('Guardrail throws StateError when SUPABASE_TEST_URL contains known production ref', () {
      expect(
        () => verifyNotProductionUrl(
          'https://dyfrknwejqwilstcoytt.supabase.co',
          'https://some-other-project.supabase.co',
        ),
        throwsA(
          predicate(
            (e) =>
                e is StateError &&
                e.message.contains('points to known production project'),
          ),
        ),
      );
    });

    test('Guardrail passes cleanly for legitimate isolated test URL', () {
      expect(
        () => verifyNotProductionUrl(
          'https://medico-opd-test.supabase.co',
          'https://dyfrknwejqwilstcoytt.supabase.co',
        ),
        returnsNormally,
      );
    });
  });

  String normalizeUrl(String raw) {
    var u = raw.trim();
    if (u.contains('/dashboard/project/')) {
      final ref = u.split('/dashboard/project/').last.split('/').first.trim();
      return 'https://$ref.supabase.co';
    }
    return u;
  }

  // Pull exclusively from SUPABASE_TEST_* environment variables
  final rawTestUrl = _getEnvValue('SUPABASE_TEST_URL') ?? '';
  final testSupabaseUrl = normalizeUrl(rawTestUrl);
  final testSupabaseAnonKey = _getEnvValue('SUPABASE_TEST_ANON_KEY') ?? '';
  final testServiceRoleKey = _getEnvValue('SUPABASE_TEST_SERVICE_ROLE_KEY');

  final bool hasTestConfig =
      testSupabaseUrl.isNotEmpty &&
      testSupabaseAnonKey.isNotEmpty &&
      testServiceRoleKey != null &&
      testServiceRoleKey.isNotEmpty;

  // Active production guard check
  if (testSupabaseUrl.isNotEmpty) {
    final prodUrl = _getEnvValue('SUPABASE_URL') ?? EnvConfig.supabaseUrl;
    verifyNotProductionUrl(testSupabaseUrl, prodUrl);
  }

  group(
    'Mandatory Adversarial RLS Multi-Tenant Test Suite (Isolated Test Project)',
    () {
      late SupabaseClient clientA;
      late SupabaseClient clientB;
      SupabaseClient? adminClient;

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final emailA = 'dr.alice.test.$timestamp@gmail.com';
      final emailB = 'dr.bob.test.$timestamp@gmail.com';
      final emailC = 'dr.charlie.test.$timestamp@gmail.com';
      const password = 'SecurePassword123!';

      String? clinicAId;
      String? doctorAId;

      String? clinicBId;
      String? doctorBId;

      final createdUserIds = <String>[];
      final createdClinicIds = <String>[];
      int baselineUserCount = 0;

      Future<void> provisionTestDoctor({
        required SupabaseClient client,
        required String email,
        required String password,
      }) async {
        final adminUserResp = await adminClient!.auth.admin.createUser(
          AdminUserAttributes(
            email: email,
            password: password,
            emailConfirm: true,
          ),
        );
        expect(adminUserResp.user, isNotNull);
        createdUserIds.add(adminUserResp.user!.id);

        final signInResp = await client.auth.signInWithPassword(
          email: email,
          password: password,
        );
        expect(signInResp.user, isNotNull);
      }

      setUpAll(() async {
        // Enforce production guard
        final prodUrl = _getEnvValue('SUPABASE_URL') ?? EnvConfig.supabaseUrl;
        verifyNotProductionUrl(testSupabaseUrl, prodUrl);

        // 1. Initialize adminClient with test-scoped SUPABASE_TEST_SERVICE_ROLE_KEY
        adminClient = SupabaseClient(testSupabaseUrl, testServiceRoleKey!);

        // Record baseline user count in the test project
        final initialUsers = await adminClient!.auth.admin.listUsers();
        baselineUserCount = initialUsers.length;
        print(
          'BASELINE INITIAL: $baselineUserCount user(s) currently in medico-opd-test project.',
        );

        // 2. Initialize independent Supabase clients for Doctor A and Doctor B
        clientA = SupabaseClient(
          testSupabaseUrl,
          testSupabaseAnonKey,
          authOptions: const AuthClientOptions(
            authFlowType: AuthFlowType.implicit,
          ),
        );
        clientB = SupabaseClient(
          testSupabaseUrl,
          testSupabaseAnonKey,
          authOptions: const AuthClientOptions(
            authFlowType: AuthFlowType.implicit,
          ),
        );

        // 3. Provision pre-confirmed Doctor A
        await provisionTestDoctor(
          client: clientA,
          email: emailA,
          password: password,
        );

        final rpcRespA = await clientA.rpc(
          'create_clinic_and_doctor',
          params: {
            'p_clinic_name': 'Clinic Alpha $timestamp',
            'p_clinic_address': '123 Medical Center, Sector 14, Delhi',
            'p_clinic_contact': '+91-11-22334455',
            'p_doctor_name': 'Dr. Alice Smith',
            'p_qualifications': 'MBBS, MD',
            'p_registration_number': 'DMC-10001',
            'p_doctor_contact': '+91-9876543210',
          },
        );
        clinicAId = rpcRespA['clinic_id'] as String;
        doctorAId = rpcRespA['doctor_id'] as String;
        createdClinicIds.add(clinicAId!);

        // 4. Provision pre-confirmed Doctor B
        await provisionTestDoctor(
          client: clientB,
          email: emailB,
          password: password,
        );

        final rpcRespB = await clientB.rpc(
          'create_clinic_and_doctor',
          params: {
            'p_clinic_name': 'Clinic Beta $timestamp',
            'p_clinic_address': '456 Health Plaza, Indiranagar, Bengaluru',
            'p_clinic_contact': '+91-80-99887766',
            'p_doctor_name': 'Dr. Bob Patel',
            'p_qualifications': 'MBBS, MS',
            'p_registration_number': 'KMC-20002',
            'p_doctor_contact': '+91-9123456789',
          },
        );
        clinicBId = rpcRespB['clinic_id'] as String;
        doctorBId = rpcRespB['doctor_id'] as String;
        createdClinicIds.add(clinicBId!);
      });

      tearDownAll(() async {
        if (adminClient == null) return;

        // Clean up all test users created during the run (cascades doctors)
        for (final uid in List<String>.from(createdUserIds)) {
          try {
            await adminClient!.auth.admin.deleteUser(uid);
          } catch (e) {
            if (!e.toString().contains('user_not_found') &&
                !e.toString().contains('User not found')) {
              stderr.writeln(
                '[tearDownAll] Warning: failed to delete test user $uid: $e',
              );
            }
          }
        }
        createdUserIds.clear();

        // Clean up any remaining test clinics (now unreferenced)
        for (final cid in List<String>.from(createdClinicIds)) {
          try {
            await adminClient!.from('clinics').delete().eq('id', cid);
          } catch (e) {
            stderr.writeln(
              '[tearDownAll] Warning: failed to delete test clinic $cid: $e',
            );
          }
        }
        createdClinicIds.clear();

        // Baseline verification: Ensure test project user count returns to baseline
        final finalUsers = await adminClient!.auth.admin.listUsers();
        print(
          'BASELINE VERIFICATION: Initial count: $baselineUserCount | Final count: ${finalUsers.length}',
        );
        expect(
          finalUsers.length,
          equals(baselineUserCount),
          reason:
              'Test suite must return user count to pre-test baseline ($baselineUserCount). Found ${finalUsers.length} users.',
        );
      });

      test(
        'ADVERSARIAL 1: Direct client INSERT into clinics is denied by RLS',
        () async {
          expect(
            () async => await clientA.from('clinics').insert({
              'name': 'Malicious Clinic Insertion',
              'address': 'Nowhere',
            }).select(),
            throwsA(
              predicate(
                (e) =>
                    e is PostgrestException &&
                    (e.message.toLowerCase().contains('row-level security') ||
                        e.message.toLowerCase().contains('violates') ||
                        e.code == '42501'),
              ),
            ),
            reason: 'Direct client INSERT on clinics must be denied by RLS',
          );
        },
      );

      test('ADVERSARIAL 2: Secondary call to create_clinic_and_doctor RPC is rejected', () async {
        expect(
          () async => await clientA.rpc(
            'create_clinic_and_doctor',
            params: {
              'p_clinic_name': 'Duplicate Clinic',
              'p_clinic_address': 'Some Address',
              'p_clinic_contact': '123',
              'p_doctor_name': 'Dr. Alice Clone',
              'p_qualifications': 'MBBS',
              'p_registration_number': 'DMC-99999',
              'p_doctor_contact': '123',
            },
          ),
          throwsA(
            predicate(
              (e) =>
                  e is PostgrestException &&
                  e.message.contains(
                    'Doctor is already associated with a clinic',
                  ),
            ),
          ),
          reason:
              'Secondary RPC invocation for existing doctor must be rejected',
        );
      });

      test('ADVERSARIAL 3: Anti-Tenant-Hopping - Updating clinic_id on doctors is denied by column grant', () async {
        expect(
          () async => await clientA
              .from('doctors')
              .update({'clinic_id': clinicBId})
              .eq('id', doctorAId!),
          throwsA(
            predicate(
              (e) =>
                  e is PostgrestException &&
                  (e.message.toLowerCase().contains('permission denied') ||
                      e.message.toLowerCase().contains('clinic_id')),
            ),
          ),
          reason: 'Reassigning clinic_id on doctors row must be blocked by column privilege revocation',
        );
      });

      test('ADVERSARIAL 4: Updating auth_user_id on doctors is denied by column grant', () async {
        final doctorBAuthIdVal = clientB.auth.currentUser!.id;
        expect(
          () async => await clientA
              .from('doctors')
              .update({'auth_user_id': doctorBAuthIdVal})
              .eq('id', doctorAId!),
          throwsA(
            predicate(
              (e) =>
                  e is PostgrestException &&
                  (e.message.toLowerCase().contains('permission denied') ||
                      e.message.toLowerCase().contains('auth_user_id')),
            ),
          ),
          reason: 'Reassigning auth_user_id on doctors row must be blocked by column privilege revocation',
        );
      });

      test('ADVERSARIAL 5: Cross-Tenant Isolation - Doctor A cannot SELECT Doctor B clinic', () async {
        final result = await clientA
            .from('clinics')
            .select()
            .eq('id', clinicBId!);
        expect(
          result,
          isEmpty,
          reason:
              'Doctor A must receive empty set when querying Doctor B clinic',
        );
      });

      test('ADVERSARIAL 6: Cross-Tenant Isolation - Doctor A cannot UPDATE Doctor B clinic', () async {
        final result = await clientA
            .from('clinics')
            .update({'name': 'HACKED CLINIC NAME'})
            .eq('id', clinicBId!)
            .select();
        expect(
          result,
          isEmpty,
          reason: 'Doctor A mutation on Doctor B clinic must affect 0 rows',
        );

        final untouchedClinicB = await clientB
            .from('clinics')
            .select()
            .eq('id', clinicBId!)
            .single();
        expect(untouchedClinicB['name'], contains('Clinic Beta'));
      });

      test('ADVERSARIAL 7: Cross-Tenant Isolation - Doctor A cannot SELECT Doctor B profile', () async {
        final result = await clientA
            .from('doctors')
            .select()
            .eq('id', doctorBId!);
        expect(
          result,
          isEmpty,
          reason:
              'Doctor A must receive empty set when querying Doctor B profile',
        );
      });

      test('ADVERSARIAL 8: Cross-Tenant Isolation - Doctor A cannot UPDATE Doctor B profile', () async {
        final result = await clientA
            .from('doctors')
            .update({'full_name': 'HACKED DOCTOR NAME'})
            .eq('id', doctorBId!)
            .select();
        expect(
          result,
          isEmpty,
          reason: 'Doctor A mutation on Doctor B profile must affect 0 rows',
        );

        final untouchedDoctorB = await clientB
            .from('doctors')
            .select()
            .eq('id', doctorBId!)
            .single();
        expect(untouchedDoctorB['full_name'], equals('Dr. Bob Patel'));
      });

      test('ADVERSARIAL 9: Transaction Atomicity - Failure mid-onboarding leaves NO orphaned clinic', () async {
        final clientC = SupabaseClient(
          testSupabaseUrl,
          testSupabaseAnonKey,
          authOptions: const AuthClientOptions(
            authFlowType: AuthFlowType.implicit,
          ),
        );
        await provisionTestDoctor(
          client: clientC,
          email: emailC,
          password: password,
        );

        expect(
          () async => await clientC.rpc(
            'create_clinic_and_doctor',
            params: {
              'p_clinic_name': 'Orphan Clinic Test $timestamp',
              'p_clinic_address': 'Some Address',
              'p_clinic_contact': '111',
              'p_doctor_name': '', // Deliberate failure trigger
              'p_qualifications': 'MBBS',
              'p_registration_number': '123',
              'p_doctor_contact': '111',
            },
          ),
          throwsA(
            predicate(
              (e) =>
                  e is PostgrestException &&
                  e.message.contains('Doctor name is required'),
            ),
          ),
        );

        final searchA = await clientA
            .from('clinics')
            .select()
            .eq('name', 'Orphan Clinic Test $timestamp');
        expect(searchA, isEmpty);

        final searchB = await clientB
            .from('clinics')
            .select()
            .eq('name', 'Orphan Clinic Test $timestamp');
        expect(searchB, isEmpty);
      });

      test('REFINEMENT 1 VERIFICATION: Deleting clinic before doctor fails with foreign key violation', () async {
        final emailDemo = 'dr.fkdemo.test.$timestamp@gmail.com';
        final userResp = await adminClient!.auth.admin.createUser(
          AdminUserAttributes(
            email: emailDemo,
            password: password,
            emailConfirm: true,
          ),
        );
        final demoUserId = userResp.user!.id;
        createdUserIds.add(demoUserId);

        final clientDemo = SupabaseClient(
          testSupabaseUrl,
          testSupabaseAnonKey,
          authOptions: const AuthClientOptions(
            authFlowType: AuthFlowType.implicit,
          ),
        );
        await clientDemo.auth.signInWithPassword(
          email: emailDemo,
          password: password,
        );

        final rpcRes = await clientDemo.rpc(
          'create_clinic_and_doctor',
          params: {
            'p_clinic_name': 'FK Demo Clinic $timestamp',
            'p_clinic_address': 'Demo Address',
            'p_clinic_contact': '999',
            'p_doctor_name': 'Dr. FK Demo',
            'p_qualifications': 'MBBS',
            'p_registration_number': 'REG-DEMO-001',
            'p_doctor_contact': '999',
          },
        );
        final demoClinicId = rpcRes['clinic_id'] as String;
        createdClinicIds.add(demoClinicId);

        final docCheck = await adminClient!
            .from('doctors')
            .select()
            .eq('id', rpcRes['doctor_id'])
            .maybeSingle();
        expect(docCheck, isNotNull);
        print(
          'REFINEMENT 1 VERIFICATION: Attempting deletion of clinic $demoClinicId while doctor ${rpcRes['doctor_id']} still references it...',
        );

        // Attempting to delete clinic BEFORE doctor must fail with 23503 FK constraint violation
        bool threwFkException = false;
        try {
          await adminClient!
              .from('clinics')
              .delete()
              .eq('id', demoClinicId)
              .select();
        } catch (e) {
          if (e is PostgrestException &&
              (e.message.toLowerCase().contains('foreign key') ||
                  e.code == '23503')) {
            threwFkException = true;
            print(
              'REFINEMENT 1 VERIFICATION: Confirmed Postgres 23503 foreign key RESTRICT violation was genuinely thrown: ${e.message}',
            );
          } else {
            rethrow;
          }
        } finally {
          // Now clean up with correct ordering: user first, then clinic
          await cleanupUserAndClinic(
            adminClient: adminClient!,
            userId: demoUserId,
            clinicId: demoClinicId,
          );
          createdUserIds.remove(demoUserId);
          createdClinicIds.remove(demoClinicId);
        }

        expect(
          threwFkException,
          isTrue,
          reason:
              'Deleting clinic while doctors row still references it must be rejected by foreign key RESTRICT',
        );
      });

      test('DELIBERATE FAILURE CLEANUP: Uncaught test failure mid-flight still fully purges user and clinic', () async {
        final emailFail = 'dr.fail.test.$timestamp@gmail.com';
        String? failUserId;
        String? failClinicId;

        final usersBeforeFailure = await adminClient!.auth.admin.listUsers();

        try {
          // Provision doctor & clinic
          final userResp = await adminClient!.auth.admin.createUser(
            AdminUserAttributes(
              email: emailFail,
              password: password,
              emailConfirm: true,
            ),
          );
          failUserId = userResp.user!.id;
          createdUserIds.add(failUserId);

          final clientFail = SupabaseClient(
            testSupabaseUrl,
            testSupabaseAnonKey,
            authOptions: const AuthClientOptions(
              authFlowType: AuthFlowType.implicit,
            ),
          );
          await clientFail.auth.signInWithPassword(
            email: emailFail,
            password: password,
          );

          final rpcRes = await clientFail.rpc(
            'create_clinic_and_doctor',
            params: {
              'p_clinic_name': 'Deliberate Failure Clinic $timestamp',
              'p_clinic_address': 'Test Address',
              'p_clinic_contact': '555',
              'p_doctor_name': 'Dr. Fail Test',
              'p_qualifications': 'MBBS',
              'p_registration_number': 'REG-FAIL-999',
              'p_doctor_contact': '555',
            },
          );
          failClinicId = rpcRes['clinic_id'] as String;
          createdClinicIds.add(failClinicId);

          // Verify records exist in database prior to simulated failure
          final docInDb = await adminClient!
              .from('doctors')
              .select()
              .eq('auth_user_id', failUserId)
              .maybeSingle();
          expect(docInDb, isNotNull);

          // Deliberate failure simulation: throw unexpected exception mid-suite
          throw StateError('SIMULATED UNEXPECTED TEST FAILURE MID-SUITE');
        } catch (e) {
          expect(e, isA<StateError>());
        } finally {
          // Cleanup executes via Refinement 1 ordering
          if (failUserId != null) {
            await cleanupUserAndClinic(
              adminClient: adminClient!,
              userId: failUserId,
              clinicId: failClinicId,
            );
            createdUserIds.remove(failUserId);
            if (failClinicId != null) createdClinicIds.remove(failClinicId);
          }
        }

        // Verify the user and clinic are completely purged
        final docAfter = await adminClient!
            .from('doctors')
            .select()
            .eq('auth_user_id', failUserId!)
            .maybeSingle();
        expect(docAfter, isNull);

        if (failClinicId != null) {
          final clinicAfter = await adminClient!
              .from('clinics')
              .select()
              .eq('id', failClinicId)
              .maybeSingle();
          expect(clinicAfter, isNull);
        }

        final usersAfterFailure = await adminClient!.auth.admin.listUsers();
        print(
          'DELIBERATE FAILURE CLEANUP RESULT: Verified user count strictly returned to pre-failure baseline (${usersBeforeFailure.length} -> ${usersAfterFailure.length}).',
        );
        expect(
          usersAfterFailure.length,
          equals(usersBeforeFailure.length),
          reason:
              'Deliberate failure cleanup must strictly restore user count to pre-test baseline',
        );
      });
    },
    skip: hasTestConfig ? null : 'Adversarial RLS suite requires SUPABASE_TEST_URL, SUPABASE_TEST_ANON_KEY, and SUPABASE_TEST_SERVICE_ROLE_KEY in .env or CI environment.',
  );
}
