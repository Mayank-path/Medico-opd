import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Security Hardening & Configuration Regression Tests', () {
    test('Regression: pubspec.yaml does NOT bundle .env in Flutter assets', () {
      final pubspecFile = File('pubspec.yaml');
      expect(pubspecFile.existsSync(), isTrue, reason: 'pubspec.yaml must exist');

      final content = pubspecFile.readAsStringSync();
      // Look for asset declarations of .env
      final assetEnvRegex = RegExp(r'^\s*-\s*\.?env\s*$', multiLine: true);
      expect(
        assetEnvRegex.hasMatch(content),
        isFalse,
        reason: 'pubspec.yaml must NOT declare .env as a bundled asset',
      );
    });

    test('Regression: CI workflow does NOT print secrets or .env', () {
      final ciFile = File('.github/workflows/ci.yml');
      expect(ciFile.existsSync(), isTrue, reason: '.github/workflows/ci.yml must exist');

      final content = ciFile.readAsStringSync();
      expect(
        content.contains('cat .env'),
        isFalse,
        reason: 'ci.yml must NOT contain "cat .env"',
      );
      expect(
        content.contains('printenv'),
        isFalse,
        reason: 'ci.yml must NOT print sensitive environment variables',
      );
    });

    test('Regression: Android release manifest includes INTERNET and RECORD_AUDIO permissions', () {
      final manifestFile = File('android/app/src/main/AndroidManifest.xml');
      expect(manifestFile.existsSync(), isTrue, reason: 'AndroidManifest.xml must exist');

      final content = manifestFile.readAsStringSync();
      expect(
        content.contains('android.permission.INTERNET'),
        isTrue,
        reason: 'AndroidManifest.xml must declare android.permission.INTERNET',
      );
      expect(
        content.contains('android.permission.RECORD_AUDIO'),
        isTrue,
        reason: 'AndroidManifest.xml must declare android.permission.RECORD_AUDIO',
      );
    });

    test('Regression: iOS Info.plist includes NSMicrophoneUsageDescription', () {
      final infoPlistFile = File('ios/Runner/Info.plist');
      expect(infoPlistFile.existsSync(), isTrue, reason: 'Info.plist must exist');

      final content = infoPlistFile.readAsStringSync();
      expect(
        content.contains('NSMicrophoneUsageDescription'),
        isTrue,
        reason: 'Info.plist must declare NSMicrophoneUsageDescription',
      );
    });

    test('Regression: process-consultation Edge Function implements idempotency check', () {
      final edgeFunctionFile = File('supabase/functions/process-consultation/index.ts');
      expect(edgeFunctionFile.existsSync(), isTrue, reason: 'index.ts must exist');

      final content = edgeFunctionFile.readAsStringSync();
      expect(
        content.contains('Idempotency Check'),
        isTrue,
        reason: 'process-consultation must implement idempotency check before transcribing',
      );
      expect(
        content.contains('existingDraft'),
        isTrue,
        reason: 'process-consultation must check for existing drafts',
      );
    });

    test('Regression: process-consultation Edge Function initializes userClient with anonKey and authHeader', () {
      final edgeFunctionFile = File('supabase/functions/process-consultation/index.ts');
      expect(edgeFunctionFile.existsSync(), isTrue, reason: 'index.ts must exist');

      final content = edgeFunctionFile.readAsStringSync();
      expect(
        content.contains("const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!"),
        isTrue,
        reason: 'process-consultation must retrieve SUPABASE_ANON_KEY',
      );
      expect(
        content.contains('createClient(supabaseUrl, anonKey,'),
        isTrue,
        reason: 'process-consultation must pass anonKey as second argument to createClient',
      );
      expect(
        content.contains('Authorization: authHeader'),
        isTrue,
        reason: 'process-consultation must preserve Authorization: authHeader in global headers',
      );
    });

    test('Regression: Migration 20260919000001 enforces consultation_consents consistency', () {
      final migrationFile = File('supabase/migrations/20260919000001_phase3_consent_recording_ai.sql');
      expect(migrationFile.existsSync(), isTrue);

      final sql = migrationFile.readAsStringSync();
      expect(
        sql.contains('check_consent_clinic_consistency()'),
        isTrue,
        reason: 'Migration must define check_consent_clinic_consistency trigger function',
      );
      expect(
        sql.contains('trg_check_consent_clinic_consistency'),
        isTrue,
        reason: 'Migration must create trg_check_consent_clinic_consistency trigger',
      );
      expect(
        sql.contains('Consent consultation does not belong to the consent clinic'),
        isTrue,
        reason: 'Trigger must verify consultation clinic ownership',
      );
      expect(
        sql.contains('Consent patient does not match the consultation patient'),
        isTrue,
        reason: 'Trigger must verify patient consultation alignment',
      );
    });

    test('Regression: Migration 20260919000001 enforces NULL-safe finalized draft locking', () {
      final migrationFile = File('supabase/migrations/20260919000001_phase3_consent_recording_ai.sql');
      expect(migrationFile.existsSync(), isTrue);

      final sql = migrationFile.readAsStringSync();
      expect(
        sql.contains('IS DISTINCT FROM'),
        isTrue,
        reason: 'Migration must use NULL-safe IS DISTINCT FROM comparison in lock_finalized_ai_draft',
      );
      expect(
        sql.contains('Finalized AI draft must have finalized_by and finalized_at specified'),
        isTrue,
        reason: 'Finalized status must require both finalized_by and finalized_at',
      );
      expect(
        sql.contains('trg_prevent_delete_finalized_ai_draft'),
        isTrue,
        reason: 'Migration must create trigger preventing deletion of finalized drafts',
      );
    });

    test('Regression: Migration 20260919000001 enforces recordings cross-entity consistency', () {
      final migrationFile = File('supabase/migrations/20260919000001_phase3_consent_recording_ai.sql');
      expect(migrationFile.existsSync(), isTrue);

      final sql = migrationFile.readAsStringSync();
      expect(
        sql.contains('check_recording_clinic_consistency()'),
        isTrue,
        reason: 'Migration must define check_recording_clinic_consistency trigger function',
      );
      expect(
        sql.contains('trg_check_recording_clinic_consistency'),
        isTrue,
        reason: 'Migration must create trg_check_recording_clinic_consistency trigger',
      );
      expect(
        sql.contains('Recording patient does not match the consultation patient'),
        isTrue,
        reason: 'Trigger must verify recording patient matches consultation patient',
      );
      expect(
        sql.contains('Recording patient does not belong to the consultation clinic'),
        isTrue,
        reason: 'Trigger must verify recording patient belongs to consultation clinic',
      );
      expect(
        sql.contains('Recording doctor does not belong to the consultation clinic'),
        isTrue,
        reason: 'Trigger must verify recording doctor belongs to consultation clinic',
      );
      expect(
        sql.contains('consultation_id cannot be changed on a recording'),
        isTrue,
        reason: 'Trigger must prevent mutating consultation_id on UPDATE',
      );
      expect(
        sql.contains('patient_id cannot be changed on a recording'),
        isTrue,
        reason: 'Trigger must prevent mutating patient_id on UPDATE',
      );
      expect(
        sql.contains('doctor_id cannot be changed on a recording'),
        isTrue,
        reason: 'Trigger must prevent mutating doctor_id on UPDATE',
      );
    });

    test('Regression: Migration 20260927000001 defines Block 1A scalability composite indexes', () {
      final migrationFile = File('supabase/migrations/20260927000001_block1a_scalability_indexes.sql');
      expect(migrationFile.existsSync(), isTrue, reason: 'Block 1A migration file must exist');

      final sql = migrationFile.readAsStringSync();
      expect(
        sql.contains('idx_consultations_patient_created_at'),
        isTrue,
        reason: 'Migration must create idx_consultations_patient_created_at',
      );
      expect(
        sql.contains('idx_consultation_consents_consultation_status'),
        isTrue,
        reason: 'Migration must create idx_consultation_consents_consultation_status',
      );
      expect(
        sql.contains('idx_audit_logs_clinic_created_at'),
        isTrue,
        reason: 'Migration must create idx_audit_logs_clinic_created_at',
      );
      expect(
        sql.contains('idx_ai_drafts_consultation_status'),
        isTrue,
        reason: 'Migration must create idx_ai_drafts_consultation_status',
      );
      expect(
        sql.contains('CREATE UNIQUE INDEX') || sql.contains('UNIQUE ('),
        isFalse,
        reason: 'Block 1A migration must NOT introduce unsafe blanket UNIQUE constraint on ai_drafts',
      );
    });

    test('Regression: Migration 20260927000002 defines Block 1B revision and transcript uniqueness without blanket draft constraint', () {
      final migrationFile = File('supabase/migrations/20260927000002_block1b_idempotency_concurrency.sql');
      expect(migrationFile.existsSync(), isTrue, reason: 'Block 1B migration file must exist');

      final sql = migrationFile.readAsStringSync();
      expect(
        sql.contains('revision INTEGER NOT NULL DEFAULT 1'),
        isTrue,
        reason: 'Migration must add revision column with default 1 for optimistic locking',
      );
      expect(
        sql.contains('GRANT UPDATE (revision) ON public.ai_drafts TO authenticated'),
        isTrue,
        reason: 'Migration must grant UPDATE (revision) to authenticated doctors',
      );
      expect(
        sql.contains('idx_transcripts_recording_id_unique'),
        isTrue,
        reason: 'Migration must create idx_transcripts_recording_id_unique',
      );
      expect(
        sql.contains('UNIQUE (consultation_id)'),
        isFalse,
        reason: 'Block 1B must preserve historical rejected drafts and NOT add blanket UNIQUE on consultation_id',
      );
    });

    test('Regression: process-consultation Edge Function implements atomic state claiming and safe conflict handling', () {
      final edgeFunctionFile = File('supabase/functions/process-consultation/index.ts');
      expect(edgeFunctionFile.existsSync(), isTrue);

      final content = edgeFunctionFile.readAsStringSync();
      expect(
        content.contains(".in('processing_status', ['pending', 'failed'])") ||
            content.contains(".in('processing_status', ['pending', 'queued', 'failed'])"),
        isTrue,
        reason: 'Must atomically claim recording from pending or failed (and optional queued)',
      );
      expect(
        content.contains('ALREADY_PROCESSING'),
        isTrue,
        reason: 'Must return ALREADY_PROCESSING when recording is claimed by another request',
      );
      expect(
        content.contains('status: 409'),
        isTrue,
        reason: 'Must return 409 Conflict when already transcribing',
      );
      expect(
        content.contains('revision: 1'),
        isTrue,
        reason: 'Must initialize AI draft revision to 1',
      );
    });

    test('Regression: RecordingScreen retry distinguishes uploadFailed from processingFailed to preserve recording identity', () {
      final screenFile = File('lib/features/recording/screens/recording_screen.dart');
      expect(screenFile.existsSync(), isTrue);

      final content = screenFile.readAsStringSync();
      expect(
        content.contains('RecordingScreenState.processingFailed'),
        isTrue,
        reason: 'RecordingScreen must check processingFailed state during retry',
      );
      expect(
        content.contains('widget.clientRecordingId'),
        isTrue,
        reason: 'RecordingScreen must reuse widget.clientRecordingId across retries',
      );
    });

    test('Regression: RecordingService uploads valid audio bytes with sse-s3 encryption reference without ciphertext scramble', () {
      final recordingServiceFile = File('lib/features/recording/services/recording_service.dart');
      expect(recordingServiceFile.existsSync(), isTrue);

      final content = recordingServiceFile.readAsStringSync();

      // Proves that broken ephemeral ciphertext encryption is removed
      expect(
        content.contains('encryptAudioBytes'),
        isFalse,
        reason: 'RecordingService must not perform unrecoverable ephemeral AES-GCM encryption',
      );
      expect(
        content.contains('EncryptedAudioPayload'),
        isFalse,
        reason: 'RecordingService must not use EncryptedAudioPayload',
      );

      // Proves valid audio bytes are uploaded directly to private storage bucket
      expect(
        content.contains("uploadBinary(\n              storagePath,\n              rawBytes,"),
        isTrue,
        reason: 'RecordingService must upload rawBytes directly to storage',
      );

      // Proves sse-s3 encryption reference is populated instead of fake KMS key
      expect(
        content.contains("'sse-s3'"),
        isTrue,
        reason: "RecordingService must record 'sse-s3' to document Supabase Storage encryption at rest",
      );
      expect(
        content.contains('kms://vault/clinics/'),
        isFalse,
        reason: 'RecordingService must not fabricate fake KMS vault key references',
      );
    });

    test('Regression: RecordingScreen contains zero dummy byte fallbacks or synthetic paths', () {
      final screenFile = File('lib/features/recording/screens/recording_screen.dart');
      expect(screenFile.existsSync(), isTrue);

      final content = screenFile.readAsStringSync();
      expect(
        content.contains('AUDIO_PAYLOAD_'),
        isFalse,
        reason: 'RecordingScreen must NEVER contain fake AUDIO_PAYLOAD fallbacks',
      );
      expect(
        content.contains('directBytes:'),
        isFalse,
        reason: 'RecordingScreen must not pass directBytes',
      );
      expect(
        content.contains("sandbox_\${widget.clientRecordingId}"),
        isFalse,
        reason: 'RecordingScreen must not create synthetic sandbox paths on mic failure',
      );
    });

    test('Regression: android/app/build.gradle.kts release buildType does NOT use debug signing', () {
      final gradleFile = File('android/app/build.gradle.kts');
      expect(gradleFile.existsSync(), isTrue);

      final content = gradleFile.readAsStringSync();

      // Ensure release block does not use debug signing
      final releaseBlockMatch = RegExp(r'buildTypes\s*\{\s*release\s*\{([^}]+)\}', dotAll: true).firstMatch(content);
      expect(releaseBlockMatch, isNotNull, reason: 'buildTypes.release block must exist');

      final releaseBody = releaseBlockMatch!.group(1)!;
      expect(
        releaseBody.contains('signingConfigs.getByName("debug")'),
        isFalse,
        reason: 'Release builds must NEVER be configured to sign with debug keys',
      );
      expect(
        releaseBody.contains('signingConfigs.getByName("release")'),
        isTrue,
        reason: 'Release builds must explicitly use the "release" signingConfig',
      );
    });

    test('Regression: android/app/build.gradle.kts release signingConfig loads from key.properties or env vars', () {
      final gradleFile = File('android/app/build.gradle.kts');
      expect(gradleFile.existsSync(), isTrue);

      final content = gradleFile.readAsStringSync();

      expect(
        content.contains('key.properties'),
        isTrue,
        reason: 'build.gradle.kts must load properties from key.properties',
      );
      expect(
        content.contains('ANDROID_STORE_FILE') &&
            content.contains('ANDROID_STORE_PASSWORD') &&
            content.contains('ANDROID_KEY_ALIAS') &&
            content.contains('ANDROID_KEY_PASSWORD'),
        isTrue,
        reason: 'build.gradle.kts must support standard ANDROID_* CI environment variables',
      );
    });

    test('Regression: .gitignore and android/.gitignore properly ignore key.properties and keystores', () {
      final rootGitignore = File('.gitignore').readAsStringSync();
      final androidGitignore = File('android/.gitignore').readAsStringSync();

      expect(rootGitignore.contains('key.properties'), isTrue);
      expect(rootGitignore.contains('*.keystore'), isTrue);
      expect(rootGitignore.contains('*.jks'), isTrue);

      expect(androidGitignore.contains('key.properties'), isTrue);
      expect(androidGitignore.contains('*.keystore'), isTrue);
      expect(androidGitignore.contains('*.jks'), isTrue);

      final exampleFile = File('android/key.properties.example');
      expect(exampleFile.existsSync(), isTrue, reason: 'key.properties.example template must exist');
    });

    test('Regression: zero production keystores or active key.properties files are committed', () {
      final activeKeyProps = File('android/key.properties');
      expect(
        activeKeyProps.existsSync(),
        isFalse,
        reason: 'Active key.properties containing secrets must never exist in repository',
      );

      final dir = Directory('android');
      final keystores = dir
          .listSync(recursive: true)
          .where((f) => f.path.endsWith('.jks') || f.path.endsWith('.keystore'))
          .toList();
      expect(
        keystores,
        isEmpty,
        reason: 'No keystore files (.jks or .keystore) may be committed to the repository',
      );
    });

    test('Block 1C: Forward migration 20260927000003 defines composite index for patient directory pagination', () {
      final migrationFile = File('supabase/migrations/20260927000003_block1c_query_pagination_scalability.sql');
      expect(migrationFile.existsSync(), isTrue, reason: 'Migration 20260927000003 must exist');

      final content = migrationFile.readAsStringSync();
      expect(
        content.contains('idx_patients_clinic_created_at_id'),
        isTrue,
        reason: 'Migration must create idx_patients_clinic_created_at_id',
      );
      expect(
        content.contains('ON public.patients (clinic_id, created_at DESC, id DESC)'),
        isTrue,
        reason: 'Index must index (clinic_id, created_at DESC, id DESC) for deterministic keyset pagination',
      );
    });

    test('Block 1C: Services implement minimal column projection and bound page limits', () {
      final patientServiceFile = File('lib/features/patient/services/patient_service.dart');
      expect(patientServiceFile.existsSync(), isTrue);
      final patientServiceContent = patientServiceFile.readAsStringSync();

      // Must not use SELECT *
      expect(
        patientServiceContent.contains(".select('*')"),
        isFalse,
        reason: 'PatientService must NOT use select("*")',
      );
      expect(
        patientServiceContent.contains("id, clinic_id, full_name, dob_or_age, sex, contact_info, opd_number, created_at, created_by"),
        isTrue,
        reason: 'PatientService must project specific required columns',
      );
      expect(
        patientServiceContent.contains("limit.clamp(1, 100)"),
        isTrue,
        reason: 'PatientService must clamp page size to maximum 100',
      );

      final consultationServiceFile = File('lib/features/consultation/services/consultation_service.dart');
      expect(consultationServiceFile.existsSync(), isTrue);
      final consultationContent = consultationServiceFile.readAsStringSync();

      // Must not use SELECT *
      expect(
        consultationContent.contains(".select('*')"),
        isFalse,
        reason: 'ConsultationService must NOT use select("*") for consultation list',
      );
      expect(
        consultationContent.contains("id, patient_id, doctor_id, clinic_id, status, started_at, ended_at, created_at"),
        isTrue,
        reason: 'ConsultationService must project specific required columns without heavy JSON/transcript payloads',
      );
      expect(
        consultationContent.contains("limit.clamp(1, 100)"),
        isTrue,
        reason: 'ConsultationService must clamp page size to maximum 100',
      );
    });

    test('Block 1D: Forward migration 20260927000004 defines durable job columns and atomic claim RPC', () {
      final migrationFile = File('supabase/migrations/20260927000004_block1d_async_job_architecture.sql');
      expect(migrationFile.existsSync(), isTrue, reason: 'Migration 20260927000004 must exist');

      final content = migrationFile.readAsStringSync();
      expect(
        content.contains('processing_started_at') &&
            content.contains('attempt_count') &&
            content.contains('lease_worker_id') &&
            content.contains('lease_expires_at'),
        isTrue,
        reason: 'Migration must add durable job lifecycle fields',
      );
      expect(
        content.contains('claim_recording_for_processing'),
        isTrue,
        reason: 'Migration must define atomic claim_recording_for_processing RPC',
      );
      expect(
        content.contains('idx_recordings_processing_claim'),
        isTrue,
        reason: 'Migration must define composite claim and recovery index',
      );
    });

    test('Block 1D: process-consultation Edge Function implements stage separation, retries, and consent re-check', () {
      final edgeFunctionFile = File('supabase/functions/process-consultation/index.ts');
      expect(edgeFunctionFile.existsSync(), isTrue);

      final content = edgeFunctionFile.readAsStringSync();
      expect(
        content.contains('executeWithRetry'),
        isTrue,
        reason: 'Edge Function must implement executeWithRetry helper with backoff',
      );
      expect(
        content.contains('structuring'),
        isTrue,
        reason: 'Edge Function must separate and advance to structuring stage',
      );
      expect(
        content.contains('Re-verify consent before entering LLM stage'),
        isTrue,
        reason: 'Edge Function must re-verify consent prior to sending data to Claude',
      );
      expect(
        content.contains('chief_complaints'),
        isTrue,
        reason: 'Edge Function must validate structured clinical output schema',
      );
    });
  });
}
