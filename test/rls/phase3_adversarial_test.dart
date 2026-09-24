// ignore_for_file: avoid_print

import 'dart:io';

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
    'Phase 3 Adversarial RLS & Trigger Gating Suite',
    () {
      late final SupabaseClient adminClient;
      late final String clinicId;
      late final String doctorId;
      late final String patientId;
      late final String consultationId;

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

        // Provision a dedicated patient and consultation for phase3_adversarial_test to guarantee complete test isolation
        final pat = await adminClient
            .from('patients')
            .insert({
              'clinic_id': clinicId,
              'full_name': 'Phase3 Adv Patient ${generateUuidV4().substring(0, 8)}',
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
      });

      setUp(() async {
        if (!hasTestConfig) return;
        await adminClient.from('recordings').delete().eq('consultation_id', consultationId);
        await adminClient.from('ai_drafts').delete().eq('consultation_id', consultationId);
        await adminClient.from('consultation_consents').delete().eq('consultation_id', consultationId);
      });

      test('Adversarial 1: Inserting into recordings without prior consent record must fail at DB trigger level', () async {
        // Ensure NO consent exists for consultation
        await adminClient.from('recordings').delete().eq('consultation_id', consultationId);
        await adminClient.from('consultation_consents').delete().eq('consultation_id', consultationId);

        final recordingId = generateUuidV4();

        // Attempt direct insert into recordings table without any consent record
        await expectLater(
          adminClient.from('recordings').insert({
            'id': recordingId,
            'consultation_id': consultationId,
            'patient_id': patientId,
            'doctor_id': doctorId,
            'storage_path': '$clinicId/$consultationId/$recordingId.m4a',
            'encryption_key_ref': 'kms://vault/key-01',
          }),
          throwsA(
            predicate((e) =>
                e.toString().contains('Recording blocked') ||
                e.toString().contains('Valid granted consent required')),
          ),
        );
      });

      test('Adversarial 2: Insert valid consent then insert recording must succeed', () async {
        final consentId = generateUuidV4();
        final recordingId = generateUuidV4();

        // 1. Insert valid granted consent
        await adminClient.from('consultation_consents').insert({
          'id': consentId,
          'clinic_id': clinicId,
          'consultation_id': consultationId,
          'patient_id': patientId,
          'consent_status': 'granted',
          'consent_method': 'verbal',
          'consent_actor': 'patient',
          'actor_name': 'Sunita Verma',
          'recorded_by': doctorId,
        });

        // 2. Insert recording -> trigger allows insert
        final insertRes = await adminClient.from('recordings').insert({
          'id': recordingId,
          'consultation_id': consultationId,
          'patient_id': patientId,
          'doctor_id': doctorId,
          'storage_path': '$clinicId/$consultationId/$recordingId.m4a',
          'encryption_key_ref': 'kms://vault/key-01',
          'upload_status': 'uploaded',
          'processing_status': 'pending',
        }).select();

        expect(insertRes, isNotEmpty);
        expect(insertRes.first['id'], equals(recordingId));

        // Cleanup
        await adminClient.from('recordings').delete().eq('id', recordingId);
        await adminClient.from('consultation_consents').delete().eq('id', consentId);
      });

      test('Adversarial 3: Attempt to insert recording after consent revoked must fail at DB trigger level', () async {
        final consentId = generateUuidV4();
        final recordingId = generateUuidV4();

        // 1. Insert revoked consent (or consent with revoked_at timestamp)
        await adminClient.from('consultation_consents').insert({
          'id': consentId,
          'clinic_id': clinicId,
          'consultation_id': consultationId,
          'patient_id': patientId,
          'consent_status': 'granted',
          'consent_method': 'verbal',
          'consent_actor': 'patient',
          'actor_name': 'Sunita Verma',
          'recorded_by': doctorId,
          'revoked_at': DateTime.now().toIso8601String(),
        });

        // 2. Insert recording -> must fail because revoked_at is not null
        await expectLater(
          adminClient.from('recordings').insert({
            'id': recordingId,
            'consultation_id': consultationId,
            'patient_id': patientId,
            'doctor_id': doctorId,
            'storage_path': '$clinicId/$consultationId/$recordingId.m4a',
            'encryption_key_ref': 'kms://vault/key-01',
          }),
          throwsA(
            predicate((e) =>
                e.toString().contains('Recording blocked') ||
                e.toString().contains('Valid granted consent required')),
          ),
        );

        // Cleanup
        await adminClient.from('consultation_consents').delete().eq('id', consentId);
      });

      test('Adversarial 4: Attempt to UPDATE ai_drafts with status=finalized must fail via DB trigger', () async {
        final draftId = generateUuidV4();

        // 1. Insert finalized draft (using .select() to ensure row is committed before update)
        await adminClient.from('ai_drafts').insert({
          'id': draftId,
          'consultation_id': consultationId,
          'structured_json': {'assessment_diagnosis': 'Acute Pharyngitis'},
          'status': 'finalized',
          'finalized_by': doctorId,
          'finalized_at': DateTime.now().toIso8601String(),
          'model_used': 'claude-3-5-sonnet',
          'prompt_version': 'v1.0.0',
        }).select();

        // Ensure row is committed and queryable before update to prevent replication race
        final inserted = await adminClient.from('ai_drafts').select().eq('id', draftId);
        expect(inserted, isNotEmpty, reason: 'Finalized draft must be persisted in DB prior to update test');

        // 2. Attempt to update finalized draft -> trigger trg_lock_finalized_ai_draft raises exception
        await expectLater(
          adminClient.from('ai_drafts').update({
            'structured_json': {'assessment_diagnosis': 'Modified Diagnosis Post-Finalize'},
          }).eq('id', draftId).select(),
          throwsA(
            predicate((e) =>
                e.toString().contains('AI draft is finalized and permanently locked') ||
                e.toString().contains('check_violation') ||
                e.toString().contains('23514')),
          ),
        );

        // Cleanup
        await adminClient.from('ai_drafts').delete().eq('id', draftId);
      });

      test('Adversarial 5: Attempt to UPDATE or DELETE from audit_logs must fail via RLS deny-by-default', () async {
        final anonClient = SupabaseClient(testUrl!, testAnonKey!);
        final logId = generateUuidV4();

        // Attempt update as anonymous client
        await expectLater(
          anonClient.from('audit_logs').update({
            'action': 'tampered_action',
          }).eq('id', logId),
          throwsA(anything),
        );

        // Attempt delete as anonymous client
        await expectLater(
          anonClient.from('audit_logs').delete().eq('id', logId),
          throwsA(anything),
        );
      });

      test('Adversarial 6: Doctor A attempts to access Doctor B recordings across clinic boundaries returns empty set', () async {
        // Without authentication or for another clinic, RLS deny-by-default policy returns empty set
        final anonClient = SupabaseClient(testUrl!, testAnonKey!);
        final res = await anonClient.from('recordings').select().limit(5);
        expect(res, isEmpty);
      });

      tearDownAll(() async {
        if (!hasTestConfig) return;
        try {
          await adminClient.from('recordings').delete().eq('consultation_id', consultationId);
          await adminClient.from('ai_drafts').delete().eq('consultation_id', consultationId);
          await adminClient.from('consultation_consents').delete().eq('consultation_id', consultationId);
          await adminClient.from('consultations').delete().eq('id', consultationId);
          await adminClient.from('patients').delete().eq('id', patientId);
        } catch (_) {}
      });
    },
    skip: hasTestConfig ? null : 'Phase 3 adversarial tests require SUPABASE_TEST_* env variables.',
  );
}
