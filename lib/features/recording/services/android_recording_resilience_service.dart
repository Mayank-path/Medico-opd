import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Represents an audio interruption event originating from the Android OS.
class AudioInterruptionEvent {
  /// Reason for interruption: e.g. AUDIOFOCUS_LOSS (call answered), AUDIOFOCUS_LOSS_TRANSIENT (phone ring).
  final String reason;

  /// Session ID associated with the interruption.
  final String? sessionId;

  const AudioInterruptionEvent({
    required this.reason,
    this.sessionId,
  });

  bool get isPermanentLoss => reason == 'AUDIOFOCUS_LOSS';
  bool get isTransientLoss => reason == 'AUDIOFOCUS_LOSS_TRANSIENT';
  bool get isFocusRegained => reason == 'AUDIOFOCUS_GAIN';

  @override
  String toString() => 'AudioInterruptionEvent(reason: $reason, sessionId: $sessionId)';
}

/// Service managing native Android foreground service and audio focus resilience.
///
/// Ensures consultation recording is protected against:
/// 1. Android background execution limits and process kills via [RecordingForegroundService].
/// 2. Audio focus loss and phone call interruptions via native [AudioManager] callbacks.
///
/// Designed with platform checks and mock-ready architecture so it operates seamlessly
/// in tests and non-Android runtime environments.
class AndroidRecordingResilienceService {
  static const String channelName = 'com.medico.opd/recording_resilience';

  final MethodChannel _channel;
  final StreamController<AudioInterruptionEvent> _interruptionController =
      StreamController<AudioInterruptionEvent>.broadcast();

  final bool _isAndroid;
  bool _isProtectionActive = false;

  AndroidRecordingResilienceService({
    MethodChannel? channel,
    bool? isAndroid,
  })  : _channel = channel ?? const MethodChannel(channelName),
        _isAndroid = isAndroid ?? (!kIsWeb && Platform.isAndroid) {
    try {
      _channel.setMethodCallHandler(_handleNativeMethodCall);
    } catch (_) {
      // Gracefully ignore in test environments where binary messenger is not yet initialized
    }
  }

  /// Stream of audio interruption events (e.g. phone call, alarm, other app audio).
  Stream<AudioInterruptionEvent> get onInterruption => _interruptionController.stream;

  /// Whether foreground service background protection is actively engaged.
  bool get isProtectionActive => _isProtectionActive;

  /// Handles incoming calls from native Android (e.g. audio focus loss).
  Future<dynamic> _handleNativeMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onAudioInterruption':
        final args = call.arguments as Map<dynamic, dynamic>? ?? {};
        final reason = args['reason'] as String? ?? 'UNKNOWN';
        final sessionId = args['sessionId'] as String?;

        debugPrint('[AndroidRecordingResilience] Native audio interruption received: $reason (session: $sessionId)');

        _interruptionController.add(
          AudioInterruptionEvent(
            reason: reason,
            sessionId: sessionId,
          ),
        );
        break;
      default:
        break;
    }
  }

  /// Starts native Android Foreground Service with microphone type.
  ///
  /// Safe to call on all platforms: no-ops gracefully if not running on Android.
  /// Strictly passes only privacy-safe operational identifiers ([recordingSessionId], [consultationId]).
  Future<bool> startBackgroundProtection({
    required String recordingSessionId,
    required String consultationId,
  }) async {
    if (!_isAndroid) {
      _isProtectionActive = true;
      return true;
    }

    try {
      final success = await _channel.invokeMethod<bool>(
        'startForegroundService',
        {
          'recordingSessionId': recordingSessionId,
          'consultationId': consultationId,
        },
      );
      _isProtectionActive = success ?? true;
      debugPrint('[AndroidRecordingResilience] Foreground service started for session: $recordingSessionId');
      return _isProtectionActive;
    } catch (e) {
      debugPrint('[AndroidRecordingResilience] Failed to start foreground service: $e');
      _isProtectionActive = false;
      return false;
    }
  }

  /// Updates foreground service notification state (e.g. 'recording' vs 'paused').
  Future<void> updateProtectionState({required String state}) async {
    if (!_isAndroid || !_isProtectionActive) return;

    try {
      await _channel.invokeMethod<bool>(
        'updateForegroundServiceState',
        {'state': state},
      );
    } catch (e) {
      debugPrint('[AndroidRecordingResilience] Failed to update foreground service state: $e');
    }
  }

  /// Stops native Android Foreground Service and removes notification.
  Future<bool> stopBackgroundProtection() async {
    if (!_isAndroid || !_isProtectionActive) {
      _isProtectionActive = false;
      return true;
    }

    try {
      final success = await _channel.invokeMethod<bool>('stopForegroundService');
      _isProtectionActive = false;
      debugPrint('[AndroidRecordingResilience] Foreground service stopped.');
      return success ?? true;
    } catch (e) {
      debugPrint('[AndroidRecordingResilience] Failed to stop foreground service: $e');
      _isProtectionActive = false;
      return false;
    }
  }

  /// Checks if native Android Foreground Service is currently running.
  Future<bool> checkServiceRunning() async {
    if (!_isAndroid) return _isProtectionActive;

    try {
      final running = await _channel.invokeMethod<bool>('isForegroundServiceRunning');
      _isProtectionActive = running ?? false;
      return _isProtectionActive;
    } catch (_) {
      return false;
    }
  }

  /// Releases stream controllers and resources.
  Future<void> dispose() async {
    await _interruptionController.close();
  }
}
