// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('Inspect actual table columns', () async {
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

    final testUrl = env['SUPABASE_TEST_URL'] ?? '';
    final testServiceRoleKey = env['SUPABASE_TEST_SERVICE_ROLE_KEY'] ?? '';
    final adminClient = SupabaseClient(testUrl, testServiceRoleKey);

    print('Querying data_retention_policies columns...');
    try {
      final rows = await adminClient.from('data_retention_policies').select().limit(5);
      print('data_retention_policies rows: $rows');
    } catch (e) {
      print('Error querying data_retention_policies: $e');
    }

    print('Querying recordings columns...');
    try {
      final rows = await adminClient.from('recordings').select().limit(1);
      print('recordings sample row keys: ${rows.isNotEmpty ? rows.first.keys.toList() : "empty"}');
    } catch (e) {
      print('Error querying recordings: $e');
    }

    print('Querying ai_drafts columns...');
    try {
      final rows = await adminClient.from('ai_drafts').select().limit(1);
      print('ai_drafts sample row keys: ${rows.isNotEmpty ? rows.first.keys.toList() : "empty"}');
    } catch (e) {
      print('Error querying ai_drafts: $e');
    }
  });
}
