import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/observability/observability.dart';
import '../../../core/supabase/supabase_client_provider.dart';
import '../models/recording_lifecycle_state.dart';
import '../models/recording_model.dart';
import 'android_recording_resilience_service.dart';
import 'ios_recording_resilience_service.dart';
import 'recording_recovery_service.dart';
import 'recording_state_manager.dart';
import 'resumable_upload_service.dart';

class RecordingService {
  final SupabaseClient? _customClient;
  final AudioRecorder? _customRecorder;
  final RecordingRecoveryService _recoveryService;
  final RecordingStateManager? stateManager;
  final AndroidRecordingResilienceService _androidResilience;
  final IosRecordingResilienceService _iosResilience;
  final TelemetryService _telemetry;
  final StructuredLogger _logger;
  final ResumableUploadService _resumableUploadService;

  AudioRecorder? _internalRecorder;
  String? _activeRecordingId;
  StreamSubscription<AudioInterruptionEvent>? _androidInterruptionSubscription;
  StreamSubscription<IosAudioInterruptionEvent>? _iosInterruptionSubscription;
  StreamSubscription<IosAudioRouteChangeEvent>? _iosRouteChangeSubscription;
  StreamSubscription<IosMediaServicesResetEvent>? _iosMediaResetSubscription;

  RecordingService({
    SupabaseClient? client,
    AudioRecorder? recorder,
    RecordingRecoveryService? recoveryService,
    this.stateManager,
    AndroidRecordingResilienceService? androidResilience,
    IosRecordingResilienceService? iosResilience,
    TelemetryService? telemetry,
    ResumableUploadService? resumableUploadService,
  })  : _customClient = client,
        _customRecorder = recorder,
        _recoveryService = recoveryService ?? RecordingRecoveryService(),
        _androidResilience = androidResilience ?? AndroidRecordingResilienceService(),
        _iosResilience = iosResilience ?? IosRecordingResilienceService(),
        _telemetry = telemetry ?? Telemetry.instance,
        _logger = StructuredLogger('recording_service'),
        _resumableUploadService = resumableUploadService ??
            ResumableUploadService(
              client: client,
              stateManager: stateManager,
              telemetry: telemetry,
            );

  SupabaseClient get _client => _customClient ?? supabaseClient;

  AndroidRecordingResilienceService get androidResilience => _androidResilience;
  IosRecordingResilienceService get iosResilience => _iosResilience;
  ResumableUploadService get resumableUploadService => _resumableUploadService;

  AudioRecorder get _recorder {
    final custom = _customRecorder;
    if (custom != null) return custom;
    _internalRecorder ??= AudioRecorder();
    return _internalRecorder!;
  }

  /// Starts microphone recording and buffers output to app sandbox storage.
  /// Coordinates lifecycle transitions with canonical [RecordingStateManager].
  /// Saves recovery checkpoint immediately.
  Future<String> startRecording({
    required String consultationId,
    required String patientId,
    required String clientRecordingId,
    String? overrideDirectoryPath,
  }) async {
    try {
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        throw StateError('Microphone recording permission denied.');
      }

      _activeRecordingId = clientRecordingId;

      // 1. Coordinate with canonical state manager
      final sm = stateManager;
      if (sm != null) {
        final existingSession = await sm.getSession(clientRecordingId);
        if (existingSession == null) {
          await sm.createSession(
            consultationId: consultationId,
            customSessionId: clientRecordingId,
          );
        }
        await sm.transitionTo(
          clientRecordingId,
          RecordingLifecycleState.preparing,
        );
      }

      String basePath;
      if (overrideDirectoryPath != null) {
        basePath = overrideDirectoryPath;
      } else {
        try {
          final docDir = await getApplicationDocumentsDirectory();
          basePath = docDir.path;
        } catch (_) {
          basePath = Directory.systemTemp.path;
        }
      }

      final recordingsDir = Directory('$basePath/recordings');
      if (!await recordingsDir.exists()) {
        await recordingsDir.create(recursive: true);
      }

      final localFilePath = '${recordingsDir.path}/$clientRecordingId.m4a';

      // Standardized M4A / AAC format (16kHz mono, ~32kbps)
      const config = RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 32000,
        sampleRate: 16000,
        numChannels: 1,
      );

      // 2. Activate native background protection prior to mic capture
      await _androidResilience.startBackgroundProtection(
        recordingSessionId: clientRecordingId,
        consultationId: consultationId,
      );
      await _iosResilience.startBackgroundProtection(
        recordingSessionId: clientRecordingId,
        consultationId: consultationId,
      );

      // 3. Start hardware audio recorder
      await _recorder.start(config, path: localFilePath);

      // 4. Listen to native Android audio focus loss / phone call interruptions
      _androidInterruptionSubscription?.cancel();
      _androidInterruptionSubscription = _androidResilience.onInterruption.listen((event) async {
        if (event.isPermanentLoss || event.isTransientLoss) {
          debugPrint('[RecordingService] Android audio interruption detected (${event.reason}), pausing active recording.');
          final activeId = _activeRecordingId;
          if (activeId != null) {
            try {
              if (await _recorder.isRecording()) {
                await _recorder.pause();
              }
              final sm = stateManager;
              if (sm != null) {
                await sm.transitionTo(
                  activeId,
                  RecordingLifecycleState.paused,
                  recoveryMetadata: {
                    'interruptedBy': event.reason,
                    'interruptedAt': DateTime.now().toIso8601String(),
                  },
                );
              }
              await _androidResilience.updateProtectionState(state: 'paused');
              await _iosResilience.updateProtectionState(state: 'paused');
              _telemetry.increment('recording.interrupted');
              _logger.warning(
                'RECORDING_AUDIO_INTERRUPTED_ANDROID',
                operation: 'audio_focus_change',
                recordingId: activeId,
                metadata: {'reason': event.reason},
              );
            } catch (err) {
              debugPrint('[RecordingService] Android interruption handling error: $err');
            }
          }
        }
      });

      // 5. Listen to native iOS AVAudioSession interruptions (phone call, Siri, alarms)
      _iosInterruptionSubscription?.cancel();
      _iosInterruptionSubscription = _iosResilience.onInterruption.listen((event) async {
        final activeId = _activeRecordingId;
        if (activeId == null) return;

        if (event.isInterruptionBegan) {
          debugPrint('[RecordingService] iOS audio interruption began (${event.reason}), pausing active recording.');
          try {
            if (await _recorder.isRecording()) {
              await _recorder.pause();
            }
            final sm = stateManager;
            if (sm != null) {
              await sm.transitionTo(
                activeId,
                RecordingLifecycleState.paused,
                recoveryMetadata: {
                  'interruptedBy': event.reason,
                  'interruptedAt': DateTime.now().toIso8601String(),
                },
              );
            }
            await _iosResilience.updateProtectionState(state: 'paused');
            await _androidResilience.updateProtectionState(state: 'paused');
            _telemetry.increment('recording.interrupted.ios');
            _logger.warning(
              'RECORDING_AUDIO_INTERRUPTED_IOS',
              operation: 'ios_audio_interruption',
              recordingId: activeId,
              metadata: {'reason': event.reason},
            );
          } catch (err) {
            debugPrint('[RecordingService] iOS interruption began handling error: $err');
          }
        } else if (event.isInterruptionEnded) {
          // Block 3 Specification: Maintain deterministic pause state when interruption ends.
          // Do NOT automatically restart the microphone without explicit user action.
          debugPrint('[RecordingService] iOS audio interruption ended (shouldResume=${event.shouldResume}). Preserving paused state.');
          final sm = stateManager;
          if (sm != null) {
            try {
              final session = await sm.getSession(activeId);
              if (session != null && session.state == RecordingLifecycleState.paused) {
                await sm.updateSessionMetadata(
                  activeId,
                  metadata: {
                    'interruptionEndedAt': DateTime.now().toIso8601String(),
                    'shouldResumeReported': event.shouldResume,
                  },
                );
              }
            } catch (_) {}
          }
        }
      });

      // 6. Listen to native iOS audio route changes (AirPods / Bluetooth disconnects)
      _iosRouteChangeSubscription?.cancel();
      _iosRouteChangeSubscription = _iosResilience.onRouteChange.listen((event) async {
        debugPrint('[RecordingService] iOS route change detected: ${event.reason} (prev: ${event.previousRoute}, curr: ${event.currentRoute})');
        _logger.info(
          'RECORDING_AUDIO_ROUTE_CHANGED_IOS',
          operation: 'audio_route_change',
          recordingId: _activeRecordingId,
          metadata: {
            'reason': event.reason,
            'previousRoute': event.previousRoute,
            'currentRoute': event.currentRoute,
          },
        );
        if (event.isDeviceDisconnected) {
          debugPrint('[RecordingService] Primary audio input disconnected during recording.');
        }
      });

      // 7. Listen to native iOS Media Services Reset (mediaserverd crashes/resets)
      _iosMediaResetSubscription?.cancel();
      _iosMediaResetSubscription = _iosResilience.onMediaServicesReset.listen((event) async {
        final activeId = _activeRecordingId;
        if (activeId == null) return;

        debugPrint('[RecordingService] iOS media services reset/lost (${event.reason}). Entering recovery required state.');
        try {
          try {
            await _recorder.stop();
          } catch (_) {}

          final sm = stateManager;
          if (sm != null) {
            await sm.transitionTo(
              activeId,
              RecordingLifecycleState.recoveryRequired,
              recoveryMetadata: {
                'failureCategory': event.reason,
                'mediaServicesResetAt': DateTime.now().toIso8601String(),
              },
            );
          }
          await _iosResilience.stopBackgroundProtection();
          _telemetry.increment('recording.media_services_reset');
          _logger.error(
            'RECORDING_MEDIA_SERVICES_RESET_IOS',
            operation: 'media_services_reset',
            recordingId: activeId,
            metadata: {'reason': event.reason},
          );
        } catch (err) {
          debugPrint('[RecordingService] Media services reset handling error: $err');
        }
      });

      // 8. Persist RECORDING state with verified local file path
      if (sm != null) {
        await sm.transitionTo(
          clientRecordingId,
          RecordingLifecycleState.recording,
          localFilePath: localFilePath,
        );
      }

      // Save crash recovery checkpoint
      await _recoveryService.saveActiveCheckpoint(
        InterruptedRecordingCheckpoint(
          recordingId: clientRecordingId,
          consultationId: consultationId,
          patientId: patientId,
          localFilePath: localFilePath,
          recordedAt: DateTime.now(),
        ),
      );

      debugPrint('[RecordingService] Recording started: $localFilePath');
      return localFilePath;
    } catch (e) {
      await _androidResilience.stopBackgroundProtection();
      await _iosResilience.stopBackgroundProtection();
      final sm = stateManager;
      if (sm != null) {
        try {
          await sm.transitionTo(
            clientRecordingId,
            RecordingLifecycleState.failed,
            lastErrorCategory: AppErrorCode.unknownProcessingError.code,
            lastErrorMessage: 'Failed to start recording: $e',
          );
        } catch (_) {}
      }
      debugPrint('[RecordingService] Failed to start recording: $e');
      rethrow;
    }
  }

  /// Pauses the ongoing recording session.
  Future<void> pauseRecording() async {
    try {
      if (await _recorder.isRecording()) {
        await _recorder.pause();
      }
      final activeId = _activeRecordingId;
      final sm = stateManager;
      if (sm != null && activeId != null) {
        await sm.pauseRecording(activeId);
      }
      await _androidResilience.updateProtectionState(state: 'paused');
      await _iosResilience.updateProtectionState(state: 'paused');
    } catch (e) {
      debugPrint('[RecordingService] Failed to pause recording: $e');
      rethrow;
    }
  }

  /// Resumes a paused recording session.
  Future<void> resumeRecording() async {
    try {
      if (await _recorder.isPaused()) {
        await _recorder.resume();
      }
      final activeId = _activeRecordingId;
      final sm = stateManager;
      if (sm != null && activeId != null) {
        await sm.resumeRecording(activeId);
      }
      await _androidResilience.updateProtectionState(state: 'recording');
      await _iosResilience.updateProtectionState(state: 'recording');
    } catch (e) {
      debugPrint('[RecordingService] Failed to resume recording: $e');
      rethrow;
    }
  }

  /// Stops recording and returns the path to the recorded audio file.
  Future<String?> stopRecording() async {
    try {
      _androidInterruptionSubscription?.cancel();
      _androidInterruptionSubscription = null;
      _iosInterruptionSubscription?.cancel();
      _iosInterruptionSubscription = null;
      _iosRouteChangeSubscription?.cancel();
      _iosRouteChangeSubscription = null;
      _iosMediaResetSubscription?.cancel();
      _iosMediaResetSubscription = null;

      final activeId = _activeRecordingId;
      final sm = stateManager;
      // 1. Transition recording -> stopping
      if (sm != null && activeId != null) {
        await sm.stopRecording(activeId);
      }

      // 2. Finalize hardware recorder
      final path = await _recorder.stop();
      debugPrint('[RecordingService] Recording stopped at: $path');

      // 3. Transition stopping -> recorded only after recorder stops successfully
      if (sm != null && activeId != null) {
        await sm.transitionTo(
          activeId,
          RecordingLifecycleState.recorded,
          localFilePath: path,
        );
      }

      // 4. Safely remove native background protection after capture finalization
      await _androidResilience.stopBackgroundProtection();
      await _iosResilience.stopBackgroundProtection();

      return path;
    } catch (e) {
      await _androidResilience.stopBackgroundProtection();
      await _iosResilience.stopBackgroundProtection();
      debugPrint('[RecordingService] Failed to stop recording: $e');
      rethrow;
    }
  }

  /// Disposes the recorder resources.
  Future<void> dispose() async {
    _androidInterruptionSubscription?.cancel();
    _androidInterruptionSubscription = null;
    _iosInterruptionSubscription?.cancel();
    _iosInterruptionSubscription = null;
    _iosRouteChangeSubscription?.cancel();
    _iosRouteChangeSubscription = null;
    _iosMediaResetSubscription?.cancel();
    _iosMediaResetSubscription = null;
    await _androidResilience.stopBackgroundProtection();
    await _androidResilience.dispose();
    await _iosResilience.stopBackgroundProtection();
    await _iosResilience.dispose();
    await _internalRecorder?.dispose();
    _internalRecorder = null;
  }

  /// Computes SHA-256 integrity checksum for audio bytes.
  static String computeChecksum(Uint8List audioBytes) {
    return sha256.convert(audioBytes).toString();
  }

  /// Complete secure upload pipeline:
  /// 1. Reads local audio file bytes.
  /// 2. Verifies audio payload integrity via SHA-256 checksum.
  /// 3. Uploads valid AAC/M4A audio bytes to private `consultation-recordings` storage bucket.
  ///    (Protected by Supabase Storage AWS SSE-S3 encryption at rest and clinic-scoped RLS).
  /// 4. Inserts `recordings` row in DB (idempotent, gated by trg_check_recording_consent).
  /// 5. Clears recovery checkpoint and purges local audio file upon successful upload.
  Future<RecordingModel> uploadAndRegisterRecording({
    required String localAudioPath,
    required String clientRecordingId,
    required String clinicId,
    required String consultationId,
    required String patientId,
    required String doctorId,
    int durationSeconds = 0,
    Uint8List? directBytes, // Optional for testing without disk
    CorrelationContext? correlationContext,
  }) async {
    final ctx = correlationContext ?? CorrelationContext.createRoot();
    final sw = Stopwatch()..start();
    try {
      final recording = await _resumableUploadService.uploadRecording(
        localAudioPath: localAudioPath,
        clientRecordingId: clientRecordingId,
        clinicId: clinicId,
        consultationId: consultationId,
        patientId: patientId,
        doctorId: doctorId,
        durationSeconds: durationSeconds,
        directBytes: directBytes,
        correlationContext: ctx,
      );

      // Cleanup legacy crash recovery checkpoint if present
      if (localAudioPath.isNotEmpty) {
        await _recoveryService.clearCheckpointAndPurgeFile(
          InterruptedRecordingCheckpoint(
            recordingId: clientRecordingId,
            consultationId: consultationId,
            patientId: patientId,
            localFilePath: localAudioPath,
            recordedAt: DateTime.now(),
          ),
        );
      }

      final uploadDurationMs = sw.elapsedMilliseconds;
      _telemetry.timing(MetricDefinitions.uploadDurationMs, uploadDurationMs);
      _telemetry.increment(MetricDefinitions.recordingsUploadedTotal);
      _logger.info(
        'RECORDING_UPLOADED',
        operation: 'upload_audio',
        durationMs: uploadDurationMs,
        correlationId: ctx.correlationId,
        requestId: ctx.requestId,
        recordingId: clientRecordingId,
        consultationId: consultationId,
        clinicId: clinicId,
      );

      return recording;
    } catch (e, stackTrace) {
      sw.stop();
      _telemetry.recordError(
        e,
        stackTrace: stackTrace,
        errorCode: AppErrorCode.storageUploadFailed.code,
        correlationId: ctx.correlationId,
      );
      _logger.error(
        'UPLOAD_PIPELINE_FAILED',
        operation: 'upload_audio',
        errorCode: AppErrorCode.storageUploadFailed.code,
        correlationId: ctx.correlationId,
        requestId: ctx.requestId,
        recordingId: clientRecordingId,
        consultationId: consultationId,
        clinicId: clinicId,
      );
      rethrow;
    }
  }

  /// Direct storage binary upload fallback maintaining 'sse-s3' encryption reference:
  Future<void> directStorageUploadBinary(String storagePath, Uint8List rawBytes) async {
    await _client.storage.from('consultation-recordings').uploadBinary(
              storagePath,
              rawBytes,
              fileOptions: const FileOptions(
                contentType: 'audio/mp4',
                upsert: true,
              ),
            );
  }

  /// Creates a recording record using a client-generated UUIDv4 as idempotency key.
  /// If the row already exists (e.g. retry after network blip), returns the existing row
  /// without creating duplicates.
  Future<RecordingModel> createOrGetRecording({
    required String clientRecordingId,
    required String consultationId,
    required String patientId,
    required String doctorId,
    required String storagePath,
    String encryptionKeyRef = 'sse-s3',
    int durationSeconds = 0,
    String format = 'm4a',
  }) async {
    try {
      final existing = await _client
          .from('recordings')
          .select()
          .eq('id', clientRecordingId)
          .maybeSingle();

      if (existing != null) {
        debugPrint('[RecordingService] Idempotency hit: recording $clientRecordingId already exists.');
        return RecordingModel.fromJson(existing);
      }

      final payload = <String, dynamic>{
        'id': clientRecordingId,
        'consultation_id': consultationId,
        'patient_id': patientId,
        'doctor_id': doctorId,
        'storage_path': storagePath,
        'encryption_key_ref': encryptionKeyRef,
        'duration_seconds': durationSeconds,
        'format': format,
        'upload_status': 'uploaded',
        'processing_status': 'pending',
        'created_at': DateTime.now().toIso8601String(),
      };

      final inserted = await _client
          .from('recordings')
          .insert(payload)
          .select()
          .single();

      _telemetry.increment(MetricDefinitions.recordingsCreatedTotal);
      return RecordingModel.fromJson(inserted);
    } catch (e, stackTrace) {
      _telemetry.recordError(
        e,
        stackTrace: stackTrace,
        errorCode: AppErrorCode.databaseError.code,
      );
      _logger.error(
        'RECORDING_CREATE_FAILED',
        operation: 'create_or_get_recording',
        errorCode: AppErrorCode.databaseError.code,
        recordingId: clientRecordingId,
        consultationId: consultationId,
      );
      rethrow;
    }
  }

  /// Fetches current recording record from server to support app resume, kill, or background recovery.
  Future<RecordingModel?> getRecording(String recordingId) async {
    try {
      final res = await _client
          .from('recordings')
          .select()
          .eq('id', recordingId)
          .maybeSingle();

      if (res == null) return null;
      return RecordingModel.fromJson(res);
    } catch (e, stackTrace) {
      _telemetry.recordError(
        e,
        stackTrace: stackTrace,
        errorCode: AppErrorCode.databaseError.code,
      );
      _logger.error(
        'RECORDING_FETCH_FAILED',
        operation: 'get_recording',
        errorCode: AppErrorCode.databaseError.code,
        recordingId: recordingId,
      );
      rethrow;
    }
  }

  /// Triggers the Edge Function pipeline to process consultation audio.
  /// Does NOT call STT/LLM provider directly.
  Future<Map<String, dynamic>> triggerEdgeFunctionProcessing({
    required String recordingId,
    required String consultationId,
    CorrelationContext? correlationContext,
  }) async {
    final ctx = correlationContext ?? CorrelationContext.createRoot();
    final sw = Stopwatch()..start();
    _telemetry.increment(MetricDefinitions.recordingsProcessingTotal);
    _logger.info(
      'TRIGGER_EDGE_PROCESSING',
      operation: 'trigger_processing',
      correlationId: ctx.correlationId,
      requestId: ctx.requestId,
      recordingId: recordingId,
      consultationId: consultationId,
    );

    final sm = stateManager;
    if (sm != null) {
      await sm.markProcessing(recordingId);
    }

    try {
      final response = await _client.functions.invoke(
        'process-consultation',
        headers: ctx.toHeaders(),
        body: {
          'recording_id': recordingId,
          'consultation_id': consultationId,
        },
      );

      final durationMs = sw.elapsedMilliseconds;

      if (response.status != 200) {
        final errCode = response.data?['code'] ?? AppErrorCode.unknownProcessingError.code;
        if (sm != null) {
          try {
            await sm.transitionTo(
              recordingId,
              RecordingLifecycleState.failed,
              lastErrorCategory: errCode.toString(),
              lastErrorMessage: 'Processing failed with status ${response.status}',
            );
          } catch (_) {}
        }
        _telemetry.increment(
          MetricDefinitions.recordingsFailedTotal,
          labels: {'error_code': errCode.toString()},
        );
        _logger.warning(
          'EDGE_PROCESSING_NON_200',
          operation: 'trigger_processing',
          errorCode: errCode.toString(),
          durationMs: durationMs,
          correlationId: ctx.correlationId,
          requestId: ctx.requestId,
          recordingId: recordingId,
          consultationId: consultationId,
        );
        throw Exception(
          response.data?['error'] ??
              'Edge Function processing failed with status ${response.status}',
        );
      }

      if (sm != null) {
        await sm.markCompleted(recordingId);
      }

      _telemetry.increment(MetricDefinitions.recordingsCompletedTotal);
      _logger.info(
        'EDGE_PROCESSING_SUCCESS',
        operation: 'trigger_processing',
        durationMs: durationMs,
        correlationId: ctx.correlationId,
        requestId: ctx.requestId,
        recordingId: recordingId,
        consultationId: consultationId,
      );

      return (response.data as Map<String, dynamic>?) ?? {};
    } catch (e, stackTrace) {
      sw.stop();
      if (sm != null) {
        try {
          await sm.transitionTo(
            recordingId,
            RecordingLifecycleState.failed,
            lastErrorCategory: AppErrorCode.unknownProcessingError.code,
            lastErrorMessage: 'Processing failed: $e',
          );
        } catch (_) {}
      }
      _telemetry.recordError(
        e,
        stackTrace: stackTrace,
        errorCode: AppErrorCode.unknownProcessingError.code,
        correlationId: ctx.correlationId,
      );
      _logger.error(
        'EDGE_PROCESSING_FAILED',
        operation: 'trigger_processing',
        errorCode: AppErrorCode.unknownProcessingError.code,
        durationMs: sw.elapsedMilliseconds,
        correlationId: ctx.correlationId,
        requestId: ctx.requestId,
        recordingId: recordingId,
        consultationId: consultationId,
      );
      rethrow;
    }
  }

  /// Bounded status polling with backoff for client recovery (avoids tight loops).
  Future<RecordingModel?> pollRecordingUntilTerminal({
    required String recordingId,
    Duration initialInterval = const Duration(seconds: 2),
    int maxAttempts = 15,
  }) async {
    var interval = initialInterval;
    for (int i = 0; i < maxAttempts; i++) {
      await Future<void>.delayed(interval);
      final model = await getRecording(recordingId);
      if (model == null) return null;

      if (model.processingStatus == RecordingProcessingStatus.transcribed ||
          model.processingStatus == RecordingProcessingStatus.failed) {
        return model;
      }

      // Linear backoff capped at 5s
      interval = Duration(seconds: (interval.inSeconds + 1).clamp(2, 5));
    }
    return getRecording(recordingId);
  }
}
