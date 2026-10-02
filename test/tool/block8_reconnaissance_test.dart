// ignore_for_file: avoid_print
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('Block 8 - Read-only Database Reconnaissance', () async {
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

    final testUrl = getVal('SUPABASE_TEST_URL');
    final testServiceRoleKey = getVal('SUPABASE_TEST_SERVICE_ROLE_KEY');

    expect(testUrl, isNotEmpty, reason: 'SUPABASE_TEST_URL must be set');
    expect(testServiceRoleKey, isNotEmpty, reason: 'SUPABASE_TEST_SERVICE_ROLE_KEY must be set');

    final adminClient = SupabaseClient(testUrl, testServiceRoleKey);

    print('=== BLOCK 8: READ-ONLY RECONNAISSANCE ===');
    print('Connected to: $testUrl');

    final tables = [
      'clinics',
      'doctors',
      'patients',
      'consultations',
      'consultation_consents',
      'recordings',
      'transcripts',
      'ai_drafts',
      'audit_logs',
      'data_retention_policies',
      'consent_policies',
    ];

    print('\n--- ACTUAL ROW COUNTS (TEST DATABASE) ---');
    for (final table in tables) {
      try {
        final res = await adminClient.from(table).select().count(CountOption.exact);
        print('Table: $table -> Count: ${res.count}');
      } catch (e) {
        print('Table: $table -> Error: $e');
      }
    }

    print('\n--- CHECK SAMPLE RECORDS & SCHEMAS ---');
    for (final table in tables) {
      try {
        final sample = await adminClient.from(table).select().limit(1);
        if (sample.isNotEmpty) {
          print('$table columns (${sample.first.keys.length}): ${sample.first.keys.toList()}');
        } else {
          print('$table is empty (0 rows)');
        }
      } catch (e) {
        print('$table sample error: $e');
      }
    }
  });
}
