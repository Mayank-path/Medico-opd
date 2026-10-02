/// Standardized container for keyset paginated query results.
class PaginatedResult<T> {
  final List<T> items;
  final String? nextCursor;
  final bool hasMore;

  const PaginatedResult({
    required this.items,
    this.nextCursor,
    required this.hasMore,
  });

  /// Empty page representation
  const PaginatedResult.empty()
      : items = const [],
        nextCursor = null,
        hasMore = false;

  /// Transforms items in this page while preserving pagination cursor state.
  PaginatedResult<R> map<R>(R Function(T item) mapper) {
    return PaginatedResult<R>(
      items: items.map(mapper).toList(),
      nextCursor: nextCursor,
      hasMore: hasMore,
    );
  }

  @override
  String toString() =>
      'PaginatedResult(items: ${items.length}, nextCursor: $nextCursor, hasMore: $hasMore)';
}
