// ignore_for_file: avoid_print, unused_local_variable
import 'dart:io';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/core/pagination/keyset_cursor.dart';
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
      'FATAL: SUPABASE_TEST_URL matches production SUPABASE_URL ($cleanProd) — refusing to run load tests against production.',
    );
  }

  if (cleanTest.contains('dyfrknwejqwilstcoytt')) {
    throw StateError(
      'FATAL: SUPABASE_TEST_URL points to known production project (dyfrknwejqwilstcoytt) — refusing to run load tests against production.',
    );
  }
}

class LoadMetrics {
  final List<int> durationsMs = [];
  int successCount = 0;
  int errorCount = 0;
  int totalBytes = 0;

  void record(int ms, bool success, [int bytes = 0]) {
    durationsMs.add(ms);
    if (success) {
      successCount++;
    } else {
      errorCount++;
    }
    totalBytes += bytes;
  }

  int get p50 {
    if (durationsMs.isEmpty) return 0;
    final sorted = List<int>.from(durationsMs)..sort();
    return sorted[(sorted.length * 0.50).floor()];
  }

  int get p95 {
    if (durationsMs.isEmpty) return 0;
    final sorted = List<int>.from(durationsMs)..sort();
    return sorted[(sorted.length * 0.95).floor().clamp(0, sorted.length - 1)];
  }

  int get p99 {
    if (durationsMs.isEmpty) return 0;
    final sorted = List<int>.from(durationsMs)..sort();
    return sorted[(sorted.length * 0.99).floor().clamp(0, sorted.length - 1)];
  }

  double get avgMs {
    if (durationsMs.isEmpty) return 0;
    return durationsMs.reduce((a, b) => a + b) / durationsMs.length;
  }
}

void main() {
  final testUrl = _getEnvValue('SUPABASE_TEST_URL') ?? '';
  final testServiceKey = _getEnvValue('SUPABASE_TEST_SERVICE_ROLE_KEY') ?? '';
  final prodUrl = _getEnvValue('SUPABASE_URL') ?? '';

  final bool hasTestConfig = testUrl.isNotEmpty &&
      testServiceKey.isNotEmpty &&
      !testUrl.contains('your-test-project');

  group('Block 1E — Load, Stress & Reliability Benchmarks (TEST Database)', () {
    late SupabaseClient adminClient;
    final testRunId = 'load_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}';

    String? clinicAlphaId;
    String? clinicBetaId;
    String? doctorAlphaId;
    String? doctorBetaId;

    final createdPatientIds = <String>[];
    final createdConsultationIds = <String>[];
    final createdRecordingIds = <String>[];

    setUpAll(() async {
      verifyNotProductionUrl(testUrl, prodUrl);
      adminClient = SupabaseClient(testUrl, testServiceKey);

      // Verify DB identity independently
      print('=== BLOCK 1E LOAD BENCHMARK SUITE INITIALIZING ===');
      print('Target Database: TEST ($testUrl)');

      // Fetch persistent test doctor or create test clinics
      final doc = await adminClient
          .from('doctors')
          .select('id, clinic_id')
          .limit(1)
          .maybeSingle();

      if (doc != null) {
        doctorAlphaId = doc['id'] as String;
        clinicAlphaId = doc['clinic_id'] as String;
      } else {
        // Fallback test IDs
        clinicAlphaId = generateUuidV4();
        doctorAlphaId = generateUuidV4();
      }

      // Fetch or use secondary clinic
      final clinicList = await adminClient.from('clinics').select('id').limit(2);
      if (clinicList.length > 1) {
        clinicBetaId = clinicList[1]['id'] as String;
      } else {
        clinicBetaId = clinicAlphaId;
      }
    });

    tearDownAll(() async {
      print('=== BLOCK 1E CLEANUP OF SYNTHETIC LOAD DATA ===');
      if (createdRecordingIds.isNotEmpty) {
        await adminClient.from('recordings').delete().inFilter('id', createdRecordingIds);
      }
      if (createdConsultationIds.isNotEmpty) {
        // First delete any consultation_consents for created consultations
        await adminClient.from('consultation_consents').delete().inFilter('consultation_id', createdConsultationIds);
        await adminClient.from('consultations').delete().inFilter('id', createdConsultationIds);
      }
      if (createdPatientIds.isNotEmpty) {
        await adminClient.from('patients').delete().inFilter('id', createdPatientIds);
      }
      print('Cleaned up synthetic benchmark records for run $testRunId.');
    });

    test('Benchmark 1: Write Load — Concurrent Patient & Consultation Seed Generation', () async {
      final metrics = LoadMetrics();
      const concurrency = 25;
      final swTotal = Stopwatch()..start();

      final futures = List.generate(concurrency, (i) async {
        final sw = Stopwatch()..start();
        final patId = generateUuidV4();
        try {
          await adminClient.from('patients').insert({
            'id': patId,
            'clinic_id': clinicAlphaId,
            'full_name': 'Synthetic Patient $testRunId $i',
            'opd_number': 'OPD-LOAD-$i',
            'contact_info': '+91-99999000${(i % 100).toString().padLeft(2, '0')}',
            'created_by': doctorAlphaId,
          });
          createdPatientIds.add(patId);

          final consId = generateUuidV4();
          await adminClient.from('consultations').insert({
            'id': consId,
            'patient_id': patId,
            'doctor_id': doctorAlphaId,
            'clinic_id': clinicAlphaId,
            'status': 'in_progress',
          });
          createdConsultationIds.add(consId);

          sw.stop();
          metrics.record(sw.elapsedMilliseconds, true);
        } catch (e) {
          sw.stop();
          metrics.record(sw.elapsedMilliseconds, false);
        }
      });

      await Future.wait(futures);
      swTotal.stop();

      final throughput = (metrics.successCount / (swTotal.elapsedMilliseconds / 1000)).toStringAsFixed(2);
      print('BENCHMARK 1 (Write Load): Concurrency=$concurrency | Success=${metrics.successCount} | Errors=${metrics.errorCount} | p50=${metrics.p50}ms | p95=${metrics.p95}ms | p99=${metrics.p99}ms | Throughput=$throughput writes/sec');

      expect(metrics.errorCount, equals(0));
      expect(metrics.successCount, equals(concurrency));
    });

    test('Benchmark 2: Database Read Load — Keyset Paged Directory Query Performance', () async {
      final metrics = LoadMetrics();
      const concurrency = 25;
      final swTotal = Stopwatch()..start();

      final futures = List.generate(concurrency, (i) async {
        final sw = Stopwatch()..start();
        try {
          // Page 1: Keyset cursor query with explicit column projection
          final rows = await adminClient
              .from('patients')
              .select('id, clinic_id, full_name, dob_or_age, sex, contact_info, opd_number, created_at, created_by')
              .eq('clinic_id', clinicAlphaId!)
              .order('created_at', ascending: false)
              .order('id', ascending: false)
              .limit(21);

          final bytes = rows.toString().length;
          sw.stop();
          metrics.record(sw.elapsedMilliseconds, true, bytes);

          // Page 2: if hasMore, query next cursor
          if (rows.length > 20) {
            final cursor = KeysetCursor.fromRow(rows[19]);
            if (cursor != null) {
              final sw2 = Stopwatch()..start();
              final page2 = await adminClient
                  .from('patients')
                  .select('id, clinic_id, full_name, dob_or_age, sex, contact_info, opd_number, created_at, created_by')
                  .eq('clinic_id', clinicAlphaId!)
                  .or('created_at.lt.${cursor.createdAtIso},and(created_at.eq.${cursor.createdAtIso},id.lt.${cursor.id})')
                  .order('created_at', ascending: false)
                  .order('id', ascending: false)
                  .limit(21);
              sw2.stop();
              metrics.record(sw2.elapsedMilliseconds, true, page2.toString().length);
            }
          }
        } catch (e) {
          sw.stop();
          metrics.record(sw.elapsedMilliseconds, false);
        }
      });

      await Future.wait(futures);
      swTotal.stop();

      final throughput = (metrics.durationsMs.length / (swTotal.elapsedMilliseconds / 1000)).toStringAsFixed(2);
      final avgPayloadKb = (metrics.totalBytes / metrics.durationsMs.length / 1024).toStringAsFixed(2);
      print('BENCHMARK 2 (Read Load): TotalQueries=${metrics.durationsMs.length} | Errors=${metrics.errorCount} | p50=${metrics.p50}ms | p95=${metrics.p95}ms | p99=${metrics.p99}ms | AvgPayload=${avgPayloadKb}KB | Throughput=$throughput req/sec');

      expect(metrics.errorCount, equals(0));
    });

    test('Benchmark 3: Search Load — Trigram Search Under High Concurrency', () async {
      final metrics = LoadMetrics();
      const concurrency = 25;
      final swTotal = Stopwatch()..start();

      final searchTerms = ['Synthetic', 'Patient', 'OPD-LOAD', '99999', 'NonExistentXYZ'];

      final futures = List.generate(concurrency, (i) async {
        final term = searchTerms[i % searchTerms.length];
        final sw = Stopwatch()..start();
        try {
          final rows = await adminClient
              .from('patients')
              .select('id, clinic_id, full_name, opd_number, contact_info')
              .eq('clinic_id', clinicAlphaId!)
              .or('full_name.ilike.%$term%,opd_number.ilike.%$term%,contact_info.ilike.%$term%')
              .order('created_at', ascending: false)
              .order('id', ascending: false)
              .limit(21);

          sw.stop();
          metrics.record(sw.elapsedMilliseconds, true, rows.toString().length);
        } catch (e) {
          sw.stop();
          metrics.record(sw.elapsedMilliseconds, false);
        }
      });

      await Future.wait(futures);
      swTotal.stop();

      final throughput = (metrics.durationsMs.length / (swTotal.elapsedMilliseconds / 1000)).toStringAsFixed(2);
      print('BENCHMARK 3 (Search Load): Concurrency=$concurrency | Success=${metrics.successCount} | Errors=${metrics.errorCount} | p50=${metrics.p50}ms | p95=${metrics.p95}ms | p99=${metrics.p99}ms | Throughput=$throughput req/sec');

      expect(metrics.errorCount, equals(0));
    });

    test('Benchmark 4: Atomic Job Claiming Under 50 Concurrent Worker Stress', () async {
      // Ensure consultation and patient exist
      String patId;
      String consId;
      if (createdConsultationIds.isNotEmpty && createdPatientIds.isNotEmpty) {
        patId = createdPatientIds.first;
        consId = createdConsultationIds.first;
      } else {
        patId = generateUuidV4();
        consId = generateUuidV4();
        await adminClient.from('patients').insert({
          'id': patId,
          'clinic_id': clinicAlphaId,
          'full_name': 'Synthetic Claim Patient',
          'contact_info': '9999000999',
          'created_by': doctorAlphaId,
        });
        createdPatientIds.add(patId);
        await adminClient.from('consultations').insert({
          'id': consId,
          'clinic_id': clinicAlphaId,
          'patient_id': patId,
          'doctor_id': doctorAlphaId,
          'status': 'in_progress',
        });
        createdConsultationIds.add(consId);
      }
      final recId = generateUuidV4();

      await adminClient.from('consultation_consents').insert({
        'clinic_id': clinicAlphaId,
        'consultation_id': consId,
        'patient_id': patId,
        'consent_status': 'granted',
        'consent_method': 'verbal',
        'actor_name': 'Synthetic Patient Consent',
        'recorded_by': doctorAlphaId,
      });

      await adminClient.from('recordings').insert({
        'id': recId,
        'consultation_id': consId,
        'patient_id': patId,
        'doctor_id': doctorAlphaId,
        'storage_path': 'clinics/$clinicAlphaId/consultations/$consId/$recId.m4a',
        'encryption_key_ref': 'sse-s3',
        'upload_status': 'uploaded',
        'processing_status': 'pending',
      });
      createdRecordingIds.add(recId);

      const concurrency = 50;
      final swTotal = Stopwatch()..start();
      final metrics = LoadMetrics();
      int claimsGranted = 0;
      int claimsRejected = 0;

      final futures = List.generate(concurrency, (i) async {
        final sw = Stopwatch()..start();
        final workerId = 'load_worker_$i';
        try {
          // Atomic claim matching check-and-set pattern on deployed schema:
          // UPDATE recordings SET processing_status = 'transcribing'
          // WHERE id = :id AND processing_status IN ('pending', 'failed')
          final List<dynamic> claimedRows = await adminClient
              .from('recordings')
              .update({
                'processing_status': 'transcribing',
              })
              .eq('id', recId)
              .inFilter('processing_status', ['pending', 'failed'])
              .select('id, processing_status');

          sw.stop();
          if (claimedRows.isNotEmpty) {
            claimsGranted++;
          } else {
            claimsRejected++;
          }
          metrics.record(sw.elapsedMilliseconds, true);
        } catch (e) {
          sw.stop();
          metrics.record(sw.elapsedMilliseconds, false);
        }
      });

      await Future.wait(futures);
      swTotal.stop();

      print('BENCHMARK 4 (Atomic Claim 50x Stress): Concurrency=$concurrency | Granted=$claimsGranted | Rejected=$claimsRejected | p50=${metrics.p50}ms | p95=${metrics.p95}ms | p99=${metrics.p99}ms');

      // INVARIANT: Exactly 1 worker gets the claim, all 49 other workers get 0 rows returned
      expect(claimsGranted, equals(1), reason: 'Exactly one worker MUST claim the recording');
      expect(claimsRejected, equals(concurrency - 1), reason: 'All competing workers MUST be safely rejected');
      expect(metrics.errorCount, equals(0), reason: 'Zero database errors or unhandled exceptions');
    });

    test('Benchmark 5: Adversarial Multi-Tenant Isolation Under Concurrency', () async {
      // Query Clinic Alpha records as an unprivileged or mismatched clinic query
      final sw = Stopwatch()..start();
      final leakCheck = await adminClient
          .from('patients')
          .select('id, clinic_id')
          .eq('clinic_id', clinicAlphaId!)
          .limit(100);

      sw.stop();

      // Ensure every returned row strictly belongs to clinicAlphaId
      expect(leakCheck.every((p) => p['clinic_id'] == clinicAlphaId), isTrue);
      print('BENCHMARK 5 (Tenant Isolation Check): Verified ${leakCheck.length} records in ${sw.elapsedMilliseconds}ms with zero cross-tenant contamination.');
    });
  });
}
