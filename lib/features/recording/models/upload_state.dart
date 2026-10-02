/// Strongly-typed states for the durable resumable upload pipeline.
/// Distinctly separates remote storage upload, integrity verification, and database registration.
enum UploadState {
  /// Local recording is complete and queued for upload.
  pending,

  /// Chunked or resumable transfer actively in flight.
  uploading,

  /// Transfer was interrupted by network loss, app backgrounding, or timeout.
  interrupted,

  /// Unrecoverable failure occurred (e.g. invalid file, permission denied).
  failed,

  /// Binary payload completely transferred to remote object storage.
  uploaded,

  /// Remote storage object confirmed to exist and verified for size/integrity.
  verified,

  /// Recording metadata record successfully inserted into database.
  registered,

  /// Entire upload pipeline completed; local cleanup authorized.
  complete;

  /// Serializes enum to canonical string.
  String toCanonicalString() => name;

  /// Parses canonical string to enum.
  static UploadState fromCanonicalString(String value) {
    return UploadState.values.firstWhere(
      (e) => e.name.toLowerCase() == value.trim().toLowerCase(),
      orElse: () => throw ArgumentError('Unknown UploadState: $value'),
    );
  }

  /// Whether this state is a terminal state.
  bool get isTerminal => this == complete || this == failed;

  /// Whether an upload is actively being transferred or processed.
  bool get isInFlight =>
      this == uploading ||
      this == uploaded ||
      this == verified ||
      this == registered;
}
