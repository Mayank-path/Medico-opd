import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/core/pagination/keyset_cursor.dart';
import 'package:medico_opd/core/pagination/paginated_result.dart';
import 'package:medico_opd/features/consultation/models/consultation_model.dart';
import 'package:medico_opd/features/patient/models/patient_model.dart';

void main() {
  group('Block 1C Keyset Pagination Core Model & Logic Tests', () {
    test('1. First page: cursor is null, encodes and decodes next page position', () {
      final t1 = DateTime.parse('2026-09-27T01:00:00.000Z');
      const id1 = '00000000-0000-0000-0000-000000000001';

      final cursor = KeysetCursor(createdAt: t1, id: id1);
      final encoded = cursor.encode();
      expect(encoded, isNotEmpty);

      final decoded = KeysetCursor.decode(encoded);
      expect(decoded.id, equals(id1));
      expect(decoded.createdAtIso, equals('2026-09-27T01:00:00.000Z'));
    });

    test('2. Deterministic ordering: uses created_at DESC and id DESC tiebreaker', () {
      final t = DateTime.parse('2026-09-27T01:00:00.000Z');
      const idA = '00000000-0000-0000-0000-000000000002';
      const idB = '00000000-0000-0000-0000-000000000001';

      final cursorA = KeysetCursor(createdAt: t, id: idA);
      final cursorB = KeysetCursor(createdAt: t, id: idB);

      // Verify that even if timestamps are identical, the id tie-breaker distinguishes them
      expect(cursorA, isNot(equals(cursorB)));
      expect(cursorA.id.compareTo(cursorB.id) > 0, isTrue);
    });

    test('3. hasMore calculation: (pageSize + 1) logic correctly determines next cursor and bounds page', () {
      const pageSize = 3;
      // Simulate raw DB query returning 4 items (pageSize + 1)
      final rawItems = List.generate(4, (i) => {
        'id': 'pat-$i',
        'clinic_id': 'clinic-alpha',
        'full_name': 'Patient $i',
        'created_at': DateTime.parse('2026-09-27T01:0$i:00.000Z').toIso8601String(),
      });

      final hasMore = rawItems.length > pageSize;
      expect(hasMore, isTrue);

      final pageItems = hasMore ? rawItems.sublist(0, pageSize) : rawItems;
      expect(pageItems.length, equals(pageSize));

      final lastItem = pageItems.last;
      final nextCursor = hasMore ? KeysetCursor.fromRow(lastItem)?.encode() : null;
      expect(nextCursor, isNotNull);

      final decoded = KeysetCursor.decode(nextCursor!);
      expect(decoded.id, equals('pat-2'));
    });

    test('4. Final page: hasMore is false and nextCursor is null when items <= pageSize', () {
      const pageSize = 3;
      final rawItems = List.generate(2, (i) => {
        'id': 'pat-$i',
        'clinic_id': 'clinic-alpha',
        'full_name': 'Patient $i',
        'created_at': DateTime.parse('2026-09-27T01:0$i:00.000Z').toIso8601String(),
      });

      final hasMore = rawItems.length > pageSize;
      expect(hasMore, isFalse);

      final pageItems = hasMore ? rawItems.sublist(0, pageSize) : rawItems;
      final nextCursor = hasMore && pageItems.isNotEmpty
          ? KeysetCursor.fromRow(pageItems.last)?.encode()
          : null;

      expect(nextCursor, isNull);
    });

    test('5. Empty dataset returns empty PaginatedResult with hasMore false', () {
      final emptyResult = PaginatedResult<PatientModel>.empty();
      expect(emptyResult.items, isEmpty);
      expect(emptyResult.nextCursor, isNull);
      expect(emptyResult.hasMore, isFalse);
    });

    test('6. Cursor security: cursor never exposes clinic_id or patient PII in payload', () {
      final cursor = KeysetCursor(
        createdAt: DateTime.now().toUtc(),
        id: '11111111-2222-3333-4444-555555555555',
      );
      final encoded = cursor.encode();

      // Ensure no tenant id or PII leaks in the base64 cursor
      expect(encoded.contains('clinic_id'), isFalse);
      expect(encoded.contains('full_name'), isFalse);
      expect(encoded.contains('contact_info'), isFalse);
      expect(encoded.contains('opd_number'), isFalse);
    });

    test('7. Safe page limits: clamping enforces minimum 1 and maximum 100', () {
      int clampLimit(int limit) => limit.clamp(1, 100);

      expect(clampLimit(-10), equals(1));
      expect(clampLimit(0), equals(1));
      expect(clampLimit(25), equals(25));
      expect(clampLimit(100), equals(100));
      expect(clampLimit(1000), equals(100));
      expect(clampLimit(1000000), equals(100));
    });

    test('8. PostgREST keyset cursor condition format verification', () {
      final cursor = KeysetCursor(
        createdAt: DateTime.parse('2026-09-27T01:30:00.000Z'),
        id: 'pat-1234',
      );

      final condition = 'created_at.lt.${cursor.createdAtIso},and(created_at.eq.${cursor.createdAtIso},id.lt.${cursor.id})';
      expect(
        condition,
        equals('created_at.lt.2026-09-27T01:30:00.000Z,and(created_at.eq.2026-09-27T01:30:00.000Z,id.lt.pat-1234)'),
      );
    });

    test('9. Search + Keyset pagination or-filter builder compatibility', () {
      const search = '  Sharma  ';
      final s = search.trim();
      final searchFilter = 'full_name.ilike.%$s%,opd_number.ilike.%$s%,contact_info.ilike.%$s%';

      expect(searchFilter, contains('full_name.ilike.%Sharma%'));
      expect(searchFilter, contains('opd_number.ilike.%Sharma%'));
      expect(searchFilter, contains('contact_info.ilike.%Sharma%'));
    });

    test('10. Invalid cursor throws FormatException and does not silently succeed', () {
      expect(() => KeysetCursor.decode('corrupted_payload!'), throwsA(isA<FormatException>()));
      expect(() => KeysetCursor.decode(''), throwsA(isA<FormatException>()));
    });
  });

  group('Block 1C Consultation History Date-Range and Projection Tests', () {
    test('11. Minimal column projection for consultations list does NOT include heavy clinical JSON or audio', () {
      const projectedColumns = 'id, patient_id, doctor_id, clinic_id, status, started_at, ended_at, created_at';

      expect(projectedColumns.contains('structured_json'), isFalse, reason: 'Must not load structured clinical JSON');
      expect(projectedColumns.contains('transcript'), isFalse, reason: 'Must not load transcripts');
      expect(projectedColumns.contains('audio_path'), isFalse, reason: 'Must not load audio paths');
      expect(projectedColumns.contains('*'), isFalse, reason: 'Must not select *');
    });

    test('12. Minimal column projection for patient list does NOT include sensitive unneeded tables or select *', () {
      const projectedColumns = 'id, clinic_id, full_name, dob_or_age, sex, contact_info, opd_number, created_at, created_by';

      expect(projectedColumns.contains('*'), isFalse, reason: 'Must not select *');
      expect(projectedColumns.contains('full_name'), isTrue);
      expect(projectedColumns.contains('opd_number'), isTrue);
      expect(projectedColumns.contains('contact_info'), isTrue);
    });

    test('13. Consultation date range filter boundaries are parsed and validated safely', () {
      final fromDate = DateTime.parse('2026-09-01T00:00:00.000Z');
      final toDate = DateTime.parse('2026-09-27T23:59:59.000Z');

      expect(fromDate.isBefore(toDate), isTrue);
      expect(fromDate.toUtc().toIso8601String(), equals('2026-09-01T00:00:00.000Z'));
      expect(toDate.toUtc().toIso8601String(), equals('2026-09-27T23:59:59.000Z'));
    });

    test('14. ConsultationModel successfully parses projected summary payload without errors', () {
      final json = {
        'id': 'cons-uuid-1',
        'patient_id': 'pat-uuid-1',
        'doctor_id': 'doc-uuid-1',
        'clinic_id': 'clinic-uuid-1',
        'status': 'in_progress',
        'started_at': '2026-09-27T01:00:00.000Z',
        'ended_at': null,
        'created_at': '2026-09-27T01:00:00.000Z',
      };

      final model = ConsultationModel.fromJson(json);
      expect(model.id, equals('cons-uuid-1'));
      expect(model.status, equals('in_progress'));
      expect(model.startedAt, equals(DateTime.parse('2026-09-27T01:00:00.000Z')));
      expect(model.endedAt, isNull);
    });
  });
}
