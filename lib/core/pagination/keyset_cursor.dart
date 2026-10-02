import 'dart:convert';

/// Keyset pagination cursor encoding created_at timestamp and unique id tiebreaker.
/// Produces an opaque, tenant-safe Base64URL string containing no sensitive clinical data.
class KeysetCursor {
  final DateTime createdAt;
  final String id;

  const KeysetCursor({
    required this.createdAt,
    required this.id,
  });

  /// Encodes this cursor to an opaque URL-safe Base64 string.
  String encode() {
    final payload = jsonEncode({
      't': createdAt.toUtc().toIso8601String(),
      'id': id,
    });
    return base64Url.encode(utf8.encode(payload));
  }

  /// Decodes an opaque Base64URL string back into a KeysetCursor.
  /// Throws [FormatException] if the cursor is malformed, corrupted, or missing required fields.
  factory KeysetCursor.decode(String raw) {
    try {
      final normalized = base64Url.normalize(raw.trim());
      final decodedJson = utf8.decode(base64Url.decode(normalized));
      final map = jsonDecode(decodedJson) as Map<String, dynamic>;

      final tStr = map['t'] as String?;
      final idStr = map['id'] as String?;

      if (tStr == null || tStr.isEmpty || idStr == null || idStr.isEmpty) {
        throw const FormatException('Missing required cursor fields ("t" or "id")');
      }

      final parsedTime = DateTime.parse(tStr);
      return KeysetCursor(createdAt: parsedTime, id: idStr);
    } catch (e) {
      throw FormatException('Invalid pagination cursor: $e');
    }
  }

  /// Constructs a cursor from a row map containing 'id' and 'created_at'.
  /// Returns null if required fields are missing or unparseable.
  static KeysetCursor? fromRow(Map<String, dynamic> row) {
    final id = row['id'] as String?;
    final createdAtRaw = row['created_at'];
    if (id == null || id.isEmpty || createdAtRaw == null) {
      return null;
    }
    try {
      final createdAt = createdAtRaw is DateTime
          ? createdAtRaw
          : DateTime.parse(createdAtRaw.toString());
      return KeysetCursor(createdAt: createdAt, id: id);
    } catch (_) {
      return null;
    }
  }

  /// UTC ISO 8601 representation for PostgREST filtering
  String get createdAtIso => createdAt.toUtc().toIso8601String();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KeysetCursor &&
          runtimeType == other.runtimeType &&
          createdAt == other.createdAt &&
          id == other.id;

  @override
  int get hashCode => createdAt.hashCode ^ id.hashCode;

  @override
  String toString() => 'KeysetCursor(createdAt: $createdAt, id: $id)';
}
