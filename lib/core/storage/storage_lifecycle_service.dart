import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:medico_opd/core/config/env_config.dart';
import 'package:medico_opd/core/observability/error_taxonomy.dart';
import 'package:medico_opd/core/observability/metric_definitions.dart';
import 'package:medico_opd/core/observability/structured_logger.dart';
import 'package:medico_opd/core/observability/telemetry_service.dart';
import 'package:medico_opd/features/recording/models/recording_model.dart';

/// Parsed storage path representation.
/// Expected format: clinics/{clinic_id}/consultations/{consultation_id}/{recording_id}.m4a
class ParsedStoragePath {
  final String clinicId;
  final String consultationId;
  final String recordingId;
  final String extension;
  final bool isValid;
  final String rawPath;

  const ParsedStoragePath({
    required this.clinicId,
    required this.consultationId,
    required this.recordingId,
    required this.extension,
    required this.isValid,
    required this.rawPath,
  });

  factory ParsedStoragePath.parse(String path) {
    final clean = path.trim().replaceAll('\\', '/');
    final segments = clean.split('/').where((s) => s.isNotEmpty).toList();

    // Must be: ['clinics', clinicId, 'consultations', consultationId, filename]
    if (segments.length != 5 ||
        segments[0] != 'clinics' ||
        segments[2] != 'consultations') {
      return ParsedStoragePath(
        clinicId: '',
        consultationId: '',
        recordingId: '',
        extension: '',
        isValid: false,
        rawPath: path,
      );
    }

    final clinicId = segments[1];
    final consultationId = segments[3];
    final filename = segments[4];

    final dotIndex = filename.lastIndexOf('.');
    final recId = dotIndex > 0 ? filename.substring(0, dotIndex) : filename;
    final ext = dotIndex > 0 ? filename.substring(dotIndex + 1) : '';

    return ParsedStoragePath(
      clinicId: clinicId,
      consultationId: consultationId,
      recordingId: recId,
      extension: ext,
      isValid: recId.isNotEmpty && clinicId.isNotEmpty && consultationId.isNotEmpty,
      rawPath: path,
    );
  }
}

/// Precise classification of storage and database artifacts.
enum StorageObjectClassification {
  /// Eligible for retention deletion (expired, not processing, unheld).
  retentionEligible,

  /// Protected active processing audio (pending, queued, transcribing, structuring, or active lease).
  activeProcessing,

  /// Protected by legal hold (retention deletion blocked).
  underLegalHold,

  /// Retention period has not expired yet.
  retentionNotExpired,

  /// Storage file exists, but no valid database recording references it (and age > grace window).
  storageOrphan,

  /// Database recording exists, but storage file is physically missing (404).
  databaseOrphan,

  /// Policy is NULL or disabled (safe inert retention, fail-closed).
  unresolvedPolicy,
}

/// Retention policy representation with clinic-level resolution.
class RetentionPolicyModel {
  final String dataClass;
  final int? retentionDays;
  final bool legalHoldDefault;
  final String? clinicId;
  final bool isEnabled;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String scope;

  const RetentionPolicyModel({
    required this.dataClass,
    this.retentionDays,
    this.legalHoldDefault = false,
    this.clinicId,
    this.isEnabled = true,
    this.createdAt,
    this.updatedAt,
    this.scope = 'global',
  });

  bool get isInertOrUnresolved => retentionDays == null || !isEnabled;

  factory RetentionPolicyModel.fromJson(Map<String, dynamic> json) {
    return RetentionPolicyModel(
      dataClass: json['data_class'] as String? ?? 'raw_audio',
      retentionDays: json['retention_days'] as int?,
      legalHoldDefault: json['legal_hold_default'] as bool? ?? false,
      clinicId: json['clinic_id'] as String?,
      isEnabled: json['is_enabled'] as bool? ?? true,
      createdAt: json['created_at'] != null ? DateTime.parse(json['created_at']) : null,
      updatedAt: json['updated_at'] != null ? DateTime.parse(json['updated_at']) : null,
      scope: json['scope'] as String? ?? (json['clinic_id'] != null ? 'clinic' : 'global'),
    );
  }
}

/// Storage object representation for orphan scanning.
class StorageObjectInfo {
  final String name;
  final String id;
  final DateTime createdAt;
  final int sizeBytes;

  const StorageObjectInfo({
    required this.name,
    required this.id,
    required this.createdAt,
    required this.sizeBytes,
  });
}

/// Cleanup item detail. Strictly sanitizes clinical content / PII.
class StorageCleanupItem {
  final String identifier;
  final String? storagePath;
  final String? clinicId;
  final StorageObjectClassification classification;
  final String reason;
  final bool wasDeleted;
  final String? errorCode;

  const StorageCleanupItem({
    required this.identifier,
    this.storagePath,
    this.clinicId,
    required this.classification,
    required this.reason,
    this.wasDeleted = false,
    this.errorCode,
  });

  Map<String, dynamic> toSummaryJson() => {
    'identifier': identifier,
    'classification': classification.name,
    'reason': reason,
    'wasDeleted': wasDeleted,
    if (clinicId != null) 'clinicId': clinicId,
    if (errorCode != null) 'errorCode': errorCode,
  };
}

/// Result of a retention or orphan cleanup execution.
class StorageCleanupResult {
  final int eligibleCount;
  final int orphanCount;
  final int blockedCount;
  final int alreadyMissingCount;
  final int deletedCount;
  final int errorCount;
  final int durationMs;
  final bool isDryRun;
  final List<StorageCleanupItem> items;

  const StorageCleanupResult({
    required this.eligibleCount,
    required this.orphanCount,
    required this.blockedCount,
    required this.alreadyMissingCount,
    required this.deletedCount,
    required this.errorCount,
    required this.durationMs,
    required this.isDryRun,
    required this.items,
  });

  Map<String, dynamic> toMetricsJson() => {
    'eligible_count': eligibleCount,
    'orphan_count': orphanCount,
    'blocked_count': blockedCount,
    'already_missing_count': alreadyMissingCount,
    'deleted_count': deletedCount,
    'error_count': errorCount,
    'duration_ms': durationMs,
    'dry_run': isDryRun,
  };
}

typedef StorageRecordingLookup = Future<RecordingModel?> Function(String storagePath);
typedef StoragePolicyResolver = Future<RetentionPolicyModel> Function(String? clinicId);
typedef StorageCandidateFetcher = Future<List<RecordingModel>> Function({String? clinicId, int limit, DateTime? currentTime});
typedef StorageObjectRemover = Future<void> Function(List<String> paths);
typedef StorageDeletionClaimer = Future<bool> Function(String recordingId, String workerId);
typedef StorageDeletionFinalizer = Future<bool> Function(String recordingId);
typedef StorageDeletionReverter = Future<bool> Function(String recordingId, String errorCode);
typedef StorageMissingReconciler = Future<bool> Function(String recordingId);

/// Authoritative Storage Lifecycle & Retention Enforcement Service.
/// Implements Block 1G safety, idempotency, atomic DB claiming,
/// tenant isolation, dry-run mode, and Block 1F observability.
class StorageLifecycleService {
  static const String productionProjectId = 'dyfrknwejqwilstcoytt';
  static const String bucketName = 'consultation-recordings';

  final SupabaseClient? client;
  final TelemetryService _telemetry;
  final StorageRecordingLookup? recordingLookup;
  final StoragePolicyResolver? policyResolver;
  final StorageCandidateFetcher? candidateFetcher;
  final StorageObjectRemover? storageRemover;
  final StorageDeletionClaimer? deletionClaimer;
  final StorageDeletionFinalizer? deletionFinalizer;
  final StorageDeletionReverter? deletionReverter;
  final StorageMissingReconciler? missingReconciler;

  StorageLifecycleService({
    this.client,
    TelemetryService? telemetry,
    this.recordingLookup,
    this.policyResolver,
    this.candidateFetcher,
    this.storageRemover,
    this.deletionClaimer,
    this.deletionFinalizer,
    this.deletionReverter,
    this.missingReconciler,
  }) : _telemetry = telemetry ?? InMemoryTelemetryService();

  SupabaseClient get _supabase => client ?? Supabase.instance.client;

  /// Strictly enforces that the target environment is NEVER Production.
  /// Throws StateError immediately if Production is targeted.
  static void verifyNonProductionGuard([String? targetUrl]) {
    final url = targetUrl ?? EnvConfig.supabaseUrl;
    if (url.toLowerCase().contains(productionProjectId)) {
      throw StateError(
        'CRITICAL: Production project ($productionProjectId) detected. '
        'Storage lifecycle deletion is strictly forbidden in Production.',
      );
    }
  }

  /// Classifies a recording for deletion eligibility based on retention,
  /// processing stage, active lease, and legal hold.
  StorageObjectClassification classifyRecording(
    RecordingModel recording, {
    DateTime? now,
    RetentionPolicyModel? policy,
  }) {
    final currentTime = now ?? DateTime.now().toUtc();

    // 1. Legal hold takes precedence over any expiration
    if (recording.legalHold) {
      return StorageObjectClassification.underLegalHold;
    }

    // 2. Active processing protection: Never delete audio needed by worker
    const activeStatuses = {
      RecordingProcessingStatus.pending,
      RecordingProcessingStatus.queued,
      RecordingProcessingStatus.transcribing,
      RecordingProcessingStatus.structuring,
    };
    if (activeStatuses.contains(recording.processingStatus)) {
      return StorageObjectClassification.activeProcessing;
    }

    // 3. Active lease protection: If an unexpired lease exists
    if (recording.leaseExpiresAt != null &&
        recording.leaseExpiresAt!.isAfter(currentTime)) {
      return StorageObjectClassification.activeProcessing;
    }

    // 4. Policy check: If retention policy is inert or unresolved, deletion is blocked
    if (policy != null && policy.isInertOrUnresolved) {
      return StorageObjectClassification.unresolvedPolicy;
    }

    // 5. Expiration check: Must have an explicit retention_expires_at <= now
    if (recording.retentionExpiresAt == null) {
      // If policy provides retention_days, check if elapsed
      if (policy != null && policy.retentionDays != null) {
        final policyExpiry = recording.createdAt.add(Duration(days: policy.retentionDays!));
        if (policyExpiry.isAfter(currentTime)) {
          return StorageObjectClassification.retentionNotExpired;
        }
      } else {
        // Safe inert retention
        return StorageObjectClassification.unresolvedPolicy;
      }
    } else if (recording.retentionExpiresAt!.isAfter(currentTime)) {
      return StorageObjectClassification.retentionNotExpired;
    }

    // All conditions satisfied: Eligible for retention deletion
    return StorageObjectClassification.retentionEligible;
  }

  /// Evaluates an individual storage object to classify if it is an orphan,
  /// an active upload, or belongs to a known recording.
  StorageObjectClassification classifyStorageObject({
    required StorageObjectInfo object,
    RecordingModel? matchedRecording,
    Duration orphanGraceWindow = const Duration(hours: 2),
    DateTime? now,
    RetentionPolicyModel? policy,
  }) {
    final currentTime = now ?? DateTime.now().toUtc();

    // If a database recording references this path, evaluate the recording
    if (matchedRecording != null) {
      return classifyRecording(matchedRecording, now: currentTime, policy: policy);
    }

    // If no recording references it, check age against the grace window
    // Recent files might be in-flight uploads that have not yet written the DB row
    final objectAge = currentTime.difference(object.createdAt.toUtc());
    if (objectAge < orphanGraceWindow) {
      // In-flight upload grace protection
      return StorageObjectClassification.activeProcessing;
    }

    // Aged object with no database reference: Genuine Storage Orphan
    return StorageObjectClassification.storageOrphan;
  }

  /// Evaluates and cleans retention-expired recordings in bounded batches.
  /// When [dryRun] is true, no DB or Storage mutations occur.
  Future<StorageCleanupResult> runRetentionCleanup({
    String? clinicId,
    int batchSize = 50,
    bool dryRun = true,
    String workerId = 'retention_worker',
    DateTime? now,
  }) async {
    verifyNonProductionGuard();
    final startTime = DateTime.now();
    final currentTime = now ?? startTime.toUtc();

    _telemetry.increment(
      MetricDefinitions.storageCleanupRunsTotal,
      labels: {'mode': dryRun ? 'dry_run' : 'live'},
    );

    int eligibleCount = 0;
    int blockedCount = 0;
    int alreadyMissingCount = 0;
    int deletedCount = 0;
    int errorCount = 0;
    final List<StorageCleanupItem> items = [];

    try {
      // 1. Resolve active retention policy
      final policy = await resolveRetentionPolicy(clinicId: clinicId);

      if (policy.isInertOrUnresolved) {
        _telemetry.log(StructuredLogEntry(
          event: 'RETENTION_POLICY_INERT',
          component: 'storage_lifecycle',
          operation: 'runRetentionCleanup',
          severity: LogSeverity.info,
          metadata: {'scope': policy.scope, 'clinic_id': clinicId},
        ));
        final duration = DateTime.now().difference(startTime).inMilliseconds;
        return StorageCleanupResult(
          eligibleCount: 0,
          orphanCount: 0,
          blockedCount: 0,
          alreadyMissingCount: 0,
          deletedCount: 0,
          errorCount: 0,
          durationMs: duration,
          isDryRun: dryRun,
          items: const [],
        );
      }

      // 2. Query expired candidate recordings with bounded limit
      List<RecordingModel> candidates;
      final fetcher = candidateFetcher;
      if (fetcher != null) {
        candidates = await fetcher(
          clinicId: clinicId,
          limit: batchSize,
          currentTime: currentTime,
        );
      } else {
        var query = _supabase
            .from('recordings')
            .select()
            .eq('deletion_status', 'active')
            .eq('legal_hold', false)
            .not('retention_expires_at', 'is', null)
            .lte('retention_expires_at', currentTime.toIso8601String())
            .order('retention_expires_at', ascending: true)
            .limit(batchSize);

        final response = await query;
        candidates = (response as List<dynamic>)
            .map((json) => RecordingModel.fromJson(json as Map<String, dynamic>))
            .toList();
      }

      _telemetry.increment(
        MetricDefinitions.storageCleanupCandidatesTotal,
        value: candidates.length,
        labels: {'mode': dryRun ? 'dry_run' : 'live'},
      );

      for (final recording in candidates) {
        // Enforce tenant boundary: Verify path clinic matches target clinic
        final parsedPath = ParsedStoragePath.parse(recording.storagePath);
        if (clinicId != null && parsedPath.isValid && parsedPath.clinicId != clinicId) {
          // Cross-tenant mismatch detected: Skip immediately
          blockedCount++;
          items.add(StorageCleanupItem(
            identifier: recording.id,
            storagePath: recording.storagePath,
            clinicId: parsedPath.clinicId,
            classification: StorageObjectClassification.unresolvedPolicy,
            reason: 'Tenant mismatch: candidate does not belong to clinic $clinicId',
          ));
          continue;
        }

        // Authoritative classification
        final classification = classifyRecording(recording, now: currentTime, policy: policy);

        if (classification != StorageObjectClassification.retentionEligible) {
          blockedCount++;
          items.add(StorageCleanupItem(
            identifier: recording.id,
            storagePath: recording.storagePath,
            clinicId: parsedPath.clinicId,
            classification: classification,
            reason: 'Blocked by rule: $classification',
          ));
          continue;
        }

        eligibleCount++;

        if (dryRun) {
          // Dry-run mode: report candidate without deleting
          items.add(StorageCleanupItem(
            identifier: recording.id,
            storagePath: recording.storagePath,
            clinicId: parsedPath.clinicId,
            classification: classification,
            reason: 'Eligible for retention deletion (dry-run)',
            wasDeleted: false,
          ));
          continue;
        }

        // LIVE DELETION PIPELINE (Atomic claim -> Storage delete -> Finalize)
        try {
          // Step A: Atomic DB claim (prevents race with worker starting processing)
          bool claimSuccess = false;
          final claimer = deletionClaimer;
          if (claimer != null) {
            claimSuccess = await claimer(recording.id, workerId);
          } else {
            final claimRes = await _supabase.rpc(
              'claim_recording_for_retention_deletion',
              params: {
                'p_recording_id': recording.id,
                'p_worker_id': workerId,
              },
            );

            final claimedRows = claimRes as List<dynamic>?;
            claimSuccess = claimedRows != null && claimedRows.isNotEmpty;
          }

          if (!claimSuccess) {
            // Worker claimed or state changed concurrently: Abort deletion
            blockedCount++;
            items.add(StorageCleanupItem(
              identifier: recording.id,
              storagePath: recording.storagePath,
              clinicId: parsedPath.clinicId,
              classification: StorageObjectClassification.activeProcessing,
              reason: 'Atomic claim failed: recording state modified concurrently',
            ));
            continue;
          }

          // Step B: Storage object deletion
          try {
            final remover = storageRemover;
            if (remover != null) {
              await remover([recording.storagePath]);
            } else {
              await _supabase.storage
                  .from(bucketName)
                  .remove([recording.storagePath]);
            }

            // Step C: Finalize DB recording deletion
            final finalizer = deletionFinalizer;
            if (finalizer != null) {
              await finalizer(recording.id);
            } else {
              await _supabase.rpc(
                'finalize_recording_deletion',
                params: {'p_recording_id': recording.id},
              );
            }

            // Step D: Write immutable audit record
            if (client != null) {
              await _emitAuditEvent(
                client: _supabase,
                eventType: 'RETENTION_DELETE',
                targetTable: 'recordings',
                targetId: recording.id,
                clinicId: parsedPath.clinicId,
                metadata: {
                  'reason': 'retention_window_expired',
                  'storage_path': recording.storagePath,
                },
              );
            }

            deletedCount++;
            _telemetry.increment(
              MetricDefinitions.storageCleanupDeletedTotal,
              labels: {'category': 'retention'},
            );

            items.add(StorageCleanupItem(
              identifier: recording.id,
              storagePath: recording.storagePath,
              clinicId: parsedPath.clinicId,
              classification: classification,
              reason: 'Successfully purged from storage and finalized',
              wasDeleted: true,
            ));
          } on StorageException catch (storageErr) {
            if (storageErr.statusCode == '404' || storageErr.message.contains('not found')) {
              // Database Orphan: file was already missing in Storage
              final reconciler = missingReconciler;
              if (reconciler != null) {
                await reconciler(recording.id);
              } else {
                await _supabase.rpc(
                  'reconcile_missing_recording_storage',
                  params: {'p_recording_id': recording.id},
                );
              }

              if (client != null) {
                await _emitAuditEvent(
                  client: _supabase,
                  eventType: 'MISSING_OBJECT_RECONCILIATION',
                  targetTable: 'recordings',
                  targetId: recording.id,
                  clinicId: parsedPath.clinicId,
                  metadata: {
                    'reason': 'storage_object_not_found',
                    'storage_path': recording.storagePath,
                  },
                );
              }

              alreadyMissingCount++;
              items.add(StorageCleanupItem(
                identifier: recording.id,
                storagePath: recording.storagePath,
                clinicId: parsedPath.clinicId,
                classification: StorageObjectClassification.databaseOrphan,
                reason: 'Storage file was already 404; reconciled DB recording status',
                wasDeleted: false,
                errorCode: AppErrorCode.storageObjectNotFound.code,
              ));
            } else {
              // Transient or fatal storage error: Revert atomic claim
              final reverter = deletionReverter;
              if (reverter != null) {
                await reverter(recording.id, AppErrorCode.storageDeleteFailed.code);
              } else {
                await _supabase.rpc(
                  'revert_recording_deletion',
                  params: {
                    'p_recording_id': recording.id,
                    'p_error_code': AppErrorCode.storageDeleteFailed.code,
                  },
                );
              }

              errorCount++;
              _telemetry.increment(
                MetricDefinitions.storageCleanupFailedTotal,
                labels: {'category': 'storage_error'},
              );

              items.add(StorageCleanupItem(
                identifier: recording.id,
                storagePath: recording.storagePath,
                clinicId: parsedPath.clinicId,
                classification: classification,
                reason: 'Storage delete failed: ${storageErr.message}; claim reverted',
                errorCode: AppErrorCode.storageDeleteFailed.code,
              ));
            }
          }
        } catch (err, st) {
          errorCount++;
          _telemetry.recordError(
            err,
            stackTrace: st,
            errorCode: AppErrorCode.databaseError.code,
          );
          items.add(StorageCleanupItem(
            identifier: recording.id,
            storagePath: recording.storagePath,
            clinicId: parsedPath.clinicId,
            classification: classification,
            reason: 'Unexpected error during deletion: $err',
            errorCode: AppErrorCode.databaseError.code,
          ));
        }
      }
    } catch (err, st) {
      errorCount++;
      _telemetry.recordError(
        err,
        stackTrace: st,
        errorCode: AppErrorCode.databaseError.code,
      );
    }

    final durationMs = DateTime.now().difference(startTime).inMilliseconds;
    _telemetry.timing(MetricDefinitions.storageCleanupDurationMs, durationMs);

    return StorageCleanupResult(
      eligibleCount: eligibleCount,
      orphanCount: 0,
      blockedCount: blockedCount,
      alreadyMissingCount: alreadyMissingCount,
      deletedCount: deletedCount,
      errorCount: errorCount,
      durationMs: durationMs,
      isDryRun: dryRun,
      items: items,
    );
  }

  /// Scans storage objects and safely detects/purges storage orphans.
  /// Storage Orphan: File exists in storage, but no valid recording references it (and age > grace window).
  Future<StorageCleanupResult> runOrphanCleanup({
    required List<StorageObjectInfo> objects,
    String? clinicId,
    int batchSize = 50,
    bool dryRun = true,
    Duration orphanGraceWindow = const Duration(hours: 2),
    DateTime? now,
  }) async {
    verifyNonProductionGuard();
    final startTime = DateTime.now();
    final currentTime = now ?? startTime.toUtc();

    _telemetry.increment(
      MetricDefinitions.storageCleanupRunsTotal,
      labels: {'mode': dryRun ? 'dry_run' : 'live'},
    );

    int orphanCount = 0;
    int blockedCount = 0;
    int deletedCount = 0;
    int errorCount = 0;
    final List<StorageCleanupItem> items = [];

    try {
      // Process in bounded batch
      final batch = objects.take(batchSize).toList();

      for (final obj in batch) {
        final parsed = ParsedStoragePath.parse(obj.name);

        // Tenant boundary check
        if (clinicId != null && parsed.isValid && parsed.clinicId != clinicId) {
          blockedCount++;
          continue;
        }

        // 1. Check if recording exists for this storage path
        RecordingModel? matchedRecording;
        try {
          final lookup = recordingLookup;
          if (lookup != null) {
            matchedRecording = await lookup(obj.name);
          } else {
            final res = await _supabase
                .from('recordings')
                .select()
                .eq('storage_path', obj.name)
                .maybeSingle();

            if (res != null) {
              matchedRecording = RecordingModel.fromJson(res);
            }
          }
        } catch (_) {
          // If query fails, fail-closed: do not delete
          blockedCount++;
          continue;
        }

        // 2. Classify
        final classification = classifyStorageObject(
          object: obj,
          matchedRecording: matchedRecording,
          orphanGraceWindow: orphanGraceWindow,
          now: currentTime,
        );

        if (classification != StorageObjectClassification.storageOrphan) {
          blockedCount++;
          items.add(StorageCleanupItem(
            identifier: obj.name,
            storagePath: obj.name,
            clinicId: parsed.clinicId,
            classification: classification,
            reason: 'Object is not an orphan: $classification',
          ));
          continue;
        }

        orphanCount++;
        _telemetry.increment(
          MetricDefinitions.storageOrphansDetectedTotal,
          labels: {'mode': dryRun ? 'dry_run' : 'live'},
        );

        if (dryRun) {
          items.add(StorageCleanupItem(
            identifier: obj.name,
            storagePath: obj.name,
            clinicId: parsed.clinicId,
            classification: classification,
            reason: 'Storage orphan detected (dry-run)',
            wasDeleted: false,
          ));
          continue;
        }

        // LIVE ORPHAN DELETION
        try {
          final remover = storageRemover;
          if (remover != null) {
            await remover([obj.name]);
          } else {
            await _supabase.storage.from(bucketName).remove([obj.name]);
          }

          if (client != null) {
            await _emitAuditEvent(
              client: _supabase,
              eventType: 'ORPHAN_DELETE',
              targetTable: 'storage_objects',
              targetId: null,
              clinicId: parsed.clinicId.isNotEmpty ? parsed.clinicId : null,
              metadata: {
                'storage_path': obj.name,
                'reason': 'unreferenced_storage_orphan',
                'object_age_seconds': currentTime.difference(obj.createdAt).inSeconds,
              },
            );
          }

          deletedCount++;
          _telemetry.increment(
            MetricDefinitions.storageOrphansDeletedTotal,
          );

          items.add(StorageCleanupItem(
            identifier: obj.name,
            storagePath: obj.name,
            clinicId: parsed.clinicId,
            classification: classification,
            reason: 'Storage orphan deleted',
            wasDeleted: true,
          ));
        } catch (err, st) {
          errorCount++;
          _telemetry.recordError(
            err,
            stackTrace: st,
            errorCode: AppErrorCode.storageDeleteFailed.code,
          );
          items.add(StorageCleanupItem(
            identifier: obj.name,
            storagePath: obj.name,
            clinicId: parsed.clinicId,
            classification: classification,
            reason: 'Failed to delete orphan: $err',
            errorCode: AppErrorCode.storageDeleteFailed.code,
          ));
        }
      }
    } catch (err, st) {
      errorCount++;
      _telemetry.recordError(
        err,
        stackTrace: st,
        errorCode: AppErrorCode.databaseError.code,
      );
    }

    final durationMs = DateTime.now().difference(startTime).inMilliseconds;
    _telemetry.timing(MetricDefinitions.storageCleanupDurationMs, durationMs);

    return StorageCleanupResult(
      eligibleCount: 0,
      orphanCount: orphanCount,
      blockedCount: blockedCount,
      alreadyMissingCount: 0,
      deletedCount: deletedCount,
      errorCount: errorCount,
      durationMs: durationMs,
      isDryRun: dryRun,
      items: items,
    );
  }

  /// Resolves the effective retention policy for a clinic.
  /// Priority: Clinic override > Global default > Fail closed (NULL).
  Future<RetentionPolicyModel> resolveRetentionPolicy({
    String? clinicId,
    String dataClass = 'raw_audio',
  }) async {
    final resolver = policyResolver;
    if (resolver != null) {
      return resolver(clinicId);
    }

    try {
      final res = await _supabase.rpc(
        'resolve_retention_policy',
        params: {
          'p_clinic_id': clinicId,
          'p_data_class': dataClass,
        },
      );

      final rows = res as List<dynamic>?;
      if (rows != null && rows.isNotEmpty) {
        final row = rows.first as Map<String, dynamic>;
        return RetentionPolicyModel(
          dataClass: dataClass,
          retentionDays: row['retention_days'] as int?,
          legalHoldDefault: row['legal_hold_default'] as bool? ?? false,
          isEnabled: row['is_enabled'] as bool? ?? false,
          scope: row['scope'] as String? ?? 'unresolved',
        );
      }
    } catch (_) {
      // Fail closed on any RPC error
    }

    return const RetentionPolicyModel(
      dataClass: 'raw_audio',
      retentionDays: null,
      isEnabled: false,
      scope: 'unresolved',
    );
  }

  /// Emits a privacy-safe audit log event.
  /// Excludes patient names, signed URLs, audio tokens, and clinical content.
  Future<void> _emitAuditEvent({
    required SupabaseClient client,
    required String eventType,
    required String targetTable,
    required String? targetId,
    required String? clinicId,
    required Map<String, dynamic> metadata,
  }) async {
    try {
      await client.from('audit_logs').insert({
        'event_type': eventType,
        'target_table': targetTable,
        'target_id': targetId,
        'clinic_id': clinicId,
        'metadata': metadata,
      });
    } catch (e) {
      debugPrint('[StorageLifecycleService] Audit logging failed: $e');
    }
  }
}
