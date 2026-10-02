import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/core/pagination/keyset_cursor.dart';
import 'package:medico_opd/core/pagination/paginated_result.dart';

void main() {
  group('Block 1C KeysetCursor Unit Tests', () {
    test('Encodes and decodes valid timestamp and id round-trip', () {
      final now = DateTime.now().toUtc();
      const id = 'c4d15617-578b-4b2a-8742-990ff5b8f60b';

      final cursor = KeysetCursor(createdAt: now, id: id);
      final encoded = cursor.encode();

      expect(encoded, isNotEmpty);
      expect(encoded.contains('{'), isFalse, reason: 'Cursor must be opaque URL-safe base64');
      expect(encoded.contains('clinic_id'), isFalse, reason: 'Cursor must never expose tenant context');

      final decoded = KeysetCursor.decode(encoded);
      expect(decoded.id, equals(id));
      expect(decoded.createdAt.millisecondsSinceEpoch, equals(now.millisecondsSinceEpoch));
    });

    test('Throws FormatException on empty, invalid, or malformed cursor string', () {
      expect(() => KeysetCursor.decode(''), throwsA(isA<FormatException>()));
      expect(() => KeysetCursor.decode('not-base-64!#%*'), throwsA(isA<FormatException>()));
      // valid base64 but invalid JSON
      expect(() => KeysetCursor.decode('aGVsbG8gd29ybGQ='), throwsA(isA<FormatException>()));
      // valid JSON base64 but missing fields: eyJmb28iOiJiYXIifQ== is {"foo":"bar"}
      expect(() => KeysetCursor.decode('eyJmb28iOiJiYXIifQ=='), throwsA(isA<FormatException>()));
    });

    test('Creates cursor from map correctly', () {
      final map = {
        'id': 'test-uuid-1234',
        'created_at': '2026-09-27T01:00:00.000Z',
      };

      final cursor = KeysetCursor.fromRow(map);
      expect(cursor, isNotNull);
      expect(cursor!.id, equals('test-uuid-1234'));
      expect(cursor.createdAtIso, equals('2026-09-27T01:00:00.000Z'));
    });

    test('Returns null fromRow if id or created_at is missing', () {
      expect(KeysetCursor.fromRow({'id': 'test'}), isNull);
      expect(KeysetCursor.fromRow({'created_at': '2026-09-27T01:00:00.000Z'}), isNull);
    });
  });

  group('Block 1C PaginatedResult Unit Tests', () {
    test('Instantiates and transforms items cleanly', () {
      final result = PaginatedResult<int>(
        items: [1, 2, 3],
        nextCursor: 'cursor_abc',
        hasMore: true,
      );

      expect(result.items.length, equals(3));
      expect(result.nextCursor, equals('cursor_abc'));
      expect(result.hasMore, isTrue);

      final mapped = result.map((n) => 'Item $n');
      expect(mapped.items, equals(['Item 1', 'Item 2', 'Item 3']));
      expect(mapped.nextCursor, equals('cursor_abc'));
      expect(mapped.hasMore, isTrue);
    });

    test('Empty result properties', () {
      final empty = PaginatedResult<String>.empty();
      expect(empty.items, isEmpty);
      expect(empty.nextCursor, isNull);
      expect(empty.hasMore, isFalse);
    });
  });
}
