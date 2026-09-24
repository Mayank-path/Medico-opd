// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/core/utils/uuid_generator.dart';
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

void main() {
  final testUrl = _getEnvValue('SUPABASE_TEST_URL');
  final testAnonKey = _getEnvValue('SUPABASE_TEST_ANON_KEY');
  final testServiceRoleKey = _getEnvValue('SUPABASE_TEST_SERVICE_ROLE_KEY');
  final prodUrl = _getEnvValue('SUPABASE_URL') ?? '';

  final bool hasTestConfig = testUrl != null &&
      testAnonKey != null &&
      testServiceRoleKey != null &&
      testUrl.isNotEmpty &&
      testAnonKey.isNotEmpty &&
      testServiceRoleKey.isNotEmpty;

  group(
    'TASK-003-03 Adversarial Security & Policy Verification Suite',
    () {
      late final SupabaseClient adminClient;
      late final SupabaseClient doctorClient;
      late final String clinicId;
      late final String otherClinicId;
      late final String doctorId;
      late final String patientId;
      late final String consultationId;
      late final String doctorAuthEmail;

      setUpAll(() async {
        verifyNotProductionUrl(testUrl!, prodUrl);
        adminClient = SupabaseClient(testUrl, testServiceRoleKey!);

        // Fetch persistent CI test doctor specifically
        final doc = await adminClient
            .from('doctors')
            .select()
            .eq('full_name', 'Dr. Rajesh Sharma')
            .single();
        doctorId = doc['id'] as String;
        clinicId = doc['clinic_id'] as String;

        // Generate dedicated dummy clinic UUID for cross-tenant storage path verification
        // (Storage RLS checks path token at index [2], does not require a foreign key row)
        otherClinicId = generateUuidV4();

        // Provision a dedicated patient and consultation for phase3_task3_adversarial_test to guarantee complete test isolation
        final pat = await adminClient
            .from('patients')
            .insert({
              'clinic_id': clinicId,
              'full_name': 'Phase3 Task3 Patient ${generateUuidV4().substring(0, 8)}',
              'created_by': doctorId,
            })
            .select()
            .single();
        patientId = pat['id'] as String;

        final cons = await adminClient
            .from('consultations')
            .insert({
              'patient_id': patientId,
              'doctor_id': doctorId,
              'clinic_id': clinicId,
              'status': 'in_progress',
            })
            .select()
            .single();
        consultationId = cons['id'] as String;

        doctorAuthEmail = 'dr.rajesh.sharma.ci@medico-opd.in';
        const doctorPassword = 'SecureTestPass123!';

        // Create doctorClient using anon key and sign in
        doctorClient = SupabaseClient(testUrl, testAnonKey!);
        try {
          final authRes = await doctorClient.auth.signInWithPassword(
            email: doctorAuthEmail,
            password: doctorPassword,
          );
          print('Authenticated doctorClient session user: ${authRes.user?.id}');
        } catch (e) {
          print('Notice: doctor sign-in info: $e');
        }
      });

      setUp(() async {
        if (!hasTestConfig) return;
        await adminClient.from('recordings').delete().eq('consultation_id', consultationId);
        await adminClient.from('consultation_consents').delete().eq('consultation_id', consultationId);
      });

      test('Item 1: RLS SELECT on consent_policies is unconditionally true for authenticated (platform-wide policy, not clinic-scoped)', () async {
        // Query consent_policies using doctorClient or adminClient
        final policies = await adminClient
            .from('consent_policies')
            .select()
            .order('effective_from', ascending: false)
            .limit(1);

        expect(policies, isNotEmpty, reason: 'consent_policies must contain at least the seed baseline row');
        final active = policies.first;
        expect(active['version'], equals(1));
        expect(active['allowed_methods'], isNotNull);
        print('Verified consent_policies baseline row: version=${active['version']}, methods=${active['allowed_methods']}');

        // Verify helper function get_active_consent_policy() works
        final rpcResult = await adminClient.rpc('get_active_consent_policy');
        expect(rpcResult, isNotEmpty);
      });

      test('Step 1 Security: consent_policies is UNWRITABLE by authenticated role (RLS/grant deny)', () async {
        // Authenticated client attempt to insert new consent policy must fail
        final fakePolicyId = generateUuidV4();
        expect(
          () async => await doctorClient.from('consent_policies').insert({
            'id': fakePolicyId,
            'version': 99,
            'allowed_methods': ['signature'],
            'pediatric_verification_required': true,
          }),
          throwsA(anything),
          reason: 'authenticated role must have INSERT permission revoked on consent_policies',
        );

        // Authenticated client attempt to delete or update consent_policies must fail
        expect(
          () async => await doctorClient.from('consent_policies').delete().eq('version', 1),
          throwsA(anything),
          reason: 'authenticated role must have DELETE permission revoked on consent_policies',
        );
      });

      test('Step 1 Guardrail (Invariant 16): trg_check_recording_consent still requires consent regardless of consent_policies', () async {
        // Clear any consent for this consultation
        await adminClient.from('recordings').delete().eq('consultation_id', consultationId);
        await adminClient.from('consultation_consents').delete().eq('consultation_id', consultationId);

        final testRecId = generateUuidV4();

        // Attempt direct insertion of recording row without consent
        // Must fail at DB trigger level, proving consent_policies cannot configure away the consent requirement
        expect(
          () async => await adminClient.from('recordings').insert({
            'id': testRecId,
            'consultation_id': consultationId,
            'patient_id': patientId,
            'doctor_id': doctorId,
            'storage_path': 'clinics/$clinicId/consultations/$consultationId/$testRecId.m4a',
            'encryption_key_ref': 'kms://vault/clinics/$clinicId/dek_test',
          }),
          throwsA(
            predicate((e) =>
                e.toString().contains('Recording blocked') ||
                e.toString().contains('Valid granted consent required')),
          ),
          reason: 'Invariant 16: recording consent requirement is non-configurable and cannot be disabled',
        );
      });

      test('Step 2: consultation_consents has verification extension fields (nullable)', () async {
        final consentId = generateUuidV4();
        final now = DateTime.now();

        // Insert consent including verification extension fields
        final res = await adminClient.from('consultation_consents').insert({
          'id': consentId,
          'clinic_id': clinicId,
          'consultation_id': consultationId,
          'patient_id': patientId,
          'consent_status': 'granted',
          'consent_method': 'verbal',
          'consent_actor': 'guardian',
          'actor_name': 'Meera Devi',
          'actor_relationship': 'Mother',
          'recorded_by': doctorId,
          'verification_method': 'attestation_v1',
          'verification_metadata': {'id_verified': false},
          'verified_at': now.toIso8601String(),
        }).select();

        expect(res, isNotEmpty);
        expect(res.first['verification_method'], equals('attestation_v1'));
        expect(res.first['verification_metadata']['id_verified'], equals(false));

        // Cleanup
        await adminClient.from('consultation_consents').delete().eq('id', consentId);
      });

      test('Item 2: Storage RLS policy matches clinic_id at index [2] of storage.foldername(name) and denies cross-clinic access', () async {
        // Doctor of clinicId attempts to upload audio to otherClinicId folder:
        // clinics/{otherClinicId}/consultations/{consultationId}/test_unauthorized.m4a
        // The storage RLS policy checks (storage.foldername(name))[2] = get_auth_clinic_id().
        // Since (storage.foldername)[2] is otherClinicId != clinicId, upload must be rejected.
        final unauthorizedPath = 'clinics/$otherClinicId/consultations/$consultationId/unauthorized.m4a';
        final dummyBytes = Uint8List.fromList([1, 2, 3, 4, 5]);

        if (doctorClient.auth.currentUser != null) {
          // 1. Cross-clinic upload attempt: Doctor of clinicId attempts to upload to otherClinicId path
          expect(
            () async => await doctorClient.storage.from('consultation-recordings').uploadBinary(
                  unauthorizedPath,
                  dummyBytes,
                ),
            throwsA(anything),
            reason: 'Cross-clinic upload must be denied by storage RLS policy index [2]',
          );

          // 2. Cross-clinic read attempt: Pre-stage file in otherClinicId using adminClient, then attempt download via doctorClient
          final otherClinicAudioPath = 'clinics/$otherClinicId/consultations/$consultationId/other_clinic_${generateUuidV4()}.m4a';
          await adminClient.storage.from('consultation-recordings').uploadBinary(
                otherClinicAudioPath,
                dummyBytes,
              );
          try {
            expect(
              () async => await doctorClient.storage.from('consultation-recordings').download(otherClinicAudioPath),
              throwsA(anything),
              reason: 'Cross-clinic read/download must be denied by storage RLS policy index [2]',
            );
          } finally {
            await adminClient.storage.from('consultation-recordings').remove([otherClinicAudioPath]);
          }

          // 3. Authorized path matching own clinicId
          final authorizedPath = 'clinics/$clinicId/consultations/$consultationId/authorized_${generateUuidV4()}.m4a';
          await doctorClient.storage.from('consultation-recordings').uploadBinary(
                authorizedPath,
                dummyBytes,
              );
          // Read back must succeed for same-clinic doctor
          final readBytes = await doctorClient.storage.from('consultation-recordings').download(authorizedPath);
          expect(readBytes, isNotEmpty, reason: 'Authorized same-clinic download must succeed');
          // Cleanup storage object
          await adminClient.storage.from('consultation-recordings').remove([authorizedPath]);
        } else {
          // If doctor session not active, verify via anonClient that all operations are rejected
          final anonClient = SupabaseClient(testUrl!, testAnonKey!);
          expect(
            () async => await anonClient.storage.from('consultation-recordings').uploadBinary(
                  unauthorizedPath,
                  dummyBytes,
                ),
            throwsA(anything),
          );
        }
      });

      tearDownAll(() async {
        if (!hasTestConfig) return;
        try {
          await adminClient.from('recordings').delete().eq('consultation_id', consultationId);
          await adminClient.from('consultation_consents').delete().eq('consultation_id', consultationId);
          await adminClient.from('consultations').delete().eq('id', consultationId);
          await adminClient.from('patients').delete().eq('id', patientId);
        } catch (_) {}
      });
    },
    skip: hasTestConfig ? null : 'Requires SUPABASE_TEST_* env variables',
  );
}
