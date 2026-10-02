import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Represents an audio interruption event originating from native iOS AVAudioSession.
class IosAudioInterruptionEvent {
  /// Either 'began' or 'ended'.
  final String type;

  /// Detailed interruption reason (e.g. 'AUDIO_INTERRUPTION_BEGAN', 'INTERRUPTION_APP_SUSPENDED').
  final String reason;

  /// Whether iOS signaled that recording should resume (only populated when type == 'ended').
  final bool shouldResume;

  /// Session ID associated with the interruption.
  final String? sessionId;

  const IosAudioInterruptionEvent({
    required this.type,
    required this.reason,
    this.shouldResume = false,
    this.sessionId,
  });

  bool get isInterruptionBegan => type == 'began';
  bool get isInterruptionEnded => type == 'ended';

  @override
  String toString() =>
      'IosAudioInterruptionEvent(type: $type, reason: $reason, shouldResume: $shouldResume, sessionId: $sessionId)';
}

/// Represents an audio route change event from native iOS AVAudioSession.
class IosAudioRouteChangeEvent {
  /// Reason string (e.g. 'newDeviceAvailable', 'oldDeviceUnavailable', 'categoryChange').
  final String reason;

  /// Comma-separated list of previous input port types (e.g. 'BluetoothHFP', 'HeadsetMic').
  final String previousRoute;

  /// Comma-separated list of current input port types.
  final String currentRoute;

  /// Session ID associated with the route change.
  final String? sessionId;

  const IosAudioRouteChangeEvent({
    required this.reason,
    required this.previousRoute,
    required this.currentRoute,
    this.sessionId,
  });

  bool get isDeviceDisconnected =>
      reason == 'oldDeviceUnavailable' ||
      (!currentRoute.contains('Bluetooth') && previousRoute.contains('Bluetooth')) ||
      (!currentRoute.contains('Headset') && previousRoute.contains('Headset'));

  @override
  String toString() =>
      'IosAudioRouteChangeEvent(reason: $reason, previous: $previousRoute, current: $currentRoute, sessionId: $sessionId)';
}

/// Represents an iOS media server reset or loss event.
class IosMediaServicesResetEvent {
  /// 'MEDIA_SERVICES_RESET' or 'MEDIA_SERVICES_LOST'.
  final String reason;

  /// Session ID associated with the event.
  final String? sessionId;

  const IosMediaServicesResetEvent({
    required this.reason,
    this.sessionId,
  });

  bool get isReset => reason == 'MEDIA_SERVICES_RESET';

  @override
  String toString() => 'IosMediaServicesResetEvent(reason: $reason, sessionId: $sessionId)';
}

/// Service managing native iOS AVAudioSession configuration, background recording resilience,
/// interruption handling, and hardware route change observation.
///
/// Designed with platform checks and mock-ready architecture so it operates seamlessly
/// in tests, Android, and non-iOS runtime environments.
class IosRecordingResilienceService {
  static const String channelName = 'com.medico.opd/ios_recording_resilience';

  final MethodChannel _channel;
  final StreamController<IosAudioInterruptionEvent> _interruptionController =
      StreamController<IosAudioInterruptionEvent>.broadcast();
  final StreamController<IosAudioRouteChangeEvent> _routeChangeController =
      StreamController<IosAudioRouteChangeEvent>.broadcast();
  final StreamController<IosMediaServicesResetEvent> _mediaResetController =
      StreamController<IosMediaServicesResetEvent>.broadcast();

  final bool _isIos;
  bool _isProtectionActive = false;

  IosRecordingResilienceService({
    MethodChannel? channel,
    bool? isIos,
  })  : _channel = channel ?? const MethodChannel(channelName),
        _isIos = isIos ?? (!kIsWeb && Platform.isIOS) {
    try {
      _channel.setMethodCallHandler(_handleNativeMethodCall);
    } catch (_) {
      // Gracefully ignore in test environments where binary messenger is not yet initialized
    }
  }

  /// Stream of AVAudioSession audio interruption events.
  Stream<IosAudioInterruptionEvent> get onInterruption => _interruptionController.stream;

  /// Stream of AVAudioSession route change events (e.g. AirPods connected/disconnected).
  Stream<IosAudioRouteChangeEvent> get onRouteChange => _routeChangeController.stream;

  /// Stream of AVAudioSession media server reset/lost events.
  Stream<IosMediaServicesResetEvent> get onMediaServicesReset => _mediaResetController.stream;

  /// Whether AVAudioSession background recording protection is actively engaged.
  bool get isProtectionActive => _isProtectionActive;

  /// Handles incoming notifications from native iOS Swift layer.
  Future<dynamic> _handleNativeMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onAudioInterruption':
        final args = call.arguments as Map<dynamic, dynamic>? ?? {};
        final type = args['type'] as String? ?? 'began';
        final reason = args['reason'] as String? ?? 'AUDIO_INTERRUPTION_BEGAN';
        final shouldResume = args['shouldResume'] as bool? ?? false;
        final sessionId = args['sessionId'] as String?;

        debugPrint('[IosRecordingResilience] Audio interruption received: type=$type, reason=$reason (session: $sessionId)');

        _interruptionController.add(
          IosAudioInterruptionEvent(
            type: type,
            reason: reason,
            shouldResume: shouldResume,
            sessionId: sessionId,
          ),
        );
        break;

      case 'onAudioRouteChange':
        final args = call.arguments as Map<dynamic, dynamic>? ?? {};
        final reason = args['reason'] as String? ?? 'unknown';
        final previousRoute = args['previousRoute'] as String? ?? 'none';
        final currentRoute = args['currentRoute'] as String? ?? 'none';
        final sessionId = args['sessionId'] as String?;

        debugPrint('[IosRecordingResilience] Route change received: reason=$reason, prev=$previousRoute, curr=$currentRoute');

        _routeChangeController.add(
          IosAudioRouteChangeEvent(
            reason: reason,
            previousRoute: previousRoute,
            currentRoute: currentRoute,
            sessionId: sessionId,
          ),
        );
        break;

      case 'onMediaServicesReset':
      case 'onMediaServicesLost':
        final args = call.arguments as Map<dynamic, dynamic>? ?? {};
        final reason = args['reason'] as String? ?? (call.method == 'onMediaServicesReset' ? 'MEDIA_SERVICES_RESET' : 'MEDIA_SERVICES_LOST');
        final sessionId = args['sessionId'] as String?;

        debugPrint('[IosRecordingResilience] Media services event: $reason (session: $sessionId)');

        _mediaResetController.add(
          IosMediaServicesResetEvent(
            reason: reason,
            sessionId: sessionId,
          ),
        );
        break;

      default:
        break;
    }
  }

  /// Activates native iOS AVAudioSession with .playAndRecord category,
  /// .spokenAudio mode, and .allowBluetooth options for consultation recording.
  ///
  /// Safe to call on all platforms: no-ops gracefully if not running on iOS.
  Future<bool> startBackgroundProtection({
    required String recordingSessionId,
    required String consultationId,
  }) async {
    if (!_isIos) {
      _isProtectionActive = true;
      return true;
    }

    try {
      final success = await _channel.invokeMethod<bool>(
        'startAudioSessionProtection',
        {
          'recordingSessionId': recordingSessionId,
          'consultationId': consultationId,
        },
      );
      _isProtectionActive = success ?? true;
      debugPrint('[IosRecordingResilience] AVAudioSession activated for session: $recordingSessionId');
      return _isProtectionActive;
    } catch (e) {
      debugPrint('[IosRecordingResilience] Failed to activate AVAudioSession: $e');
      _isProtectionActive = false;
      return false;
    }
  }

  /// Updates audio protection operational state (e.g. 'recording' vs 'paused').
  Future<void> updateProtectionState({required String state}) async {
    if (!_isIos || !_isProtectionActive) return;

    try {
      await _channel.invokeMethod<bool>(
        'updateProtectionState',
        {'state': state},
      );
    } catch (e) {
      debugPrint('[IosRecordingResilience] Failed to update protection state: $e');
    }
  }

  /// Deactivates native iOS AVAudioSession.
  Future<bool> stopBackgroundProtection() async {
    if (!_isIos || !_isProtectionActive) {
      _isProtectionActive = false;
      return true;
    }

    try {
      final success = await _channel.invokeMethod<bool>('stopAudioSessionProtection');
      _isProtectionActive = false;
      debugPrint('[IosRecordingResilience] AVAudioSession deactivated.');
      return success ?? true;
    } catch (e) {
      debugPrint('[IosRecordingResilience] Failed to deactivate AVAudioSession: $e');
      _isProtectionActive = false;
      return false;
    }
  }

  /// Queries current AVAudioSession category, mode, and permission.
  Future<Map<String, dynamic>> getAudioSessionState() async {
    if (!_isIos) {
      return {
        'category': 'default',
        'mode': 'default',
        'isOtherAudioPlaying': false,
        'recordPermission': 'granted',
        'isProtectionActive': _isProtectionActive,
      };
    }

    try {
      final state = await _channel.invokeMethod<Map<dynamic, dynamic>>('getAudioSessionState');
      return Map<String, dynamic>.from(state ?? {});
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  /// Checks microphone authorization status ('granted', 'denied', 'undetermined').
  Future<String> checkMicrophonePermission() async {
    if (!_isIos) return 'granted';

    try {
      final status = await _channel.invokeMethod<String>('checkPermission');
      return status ?? 'undetermined';
    } catch (_) {
      return 'undetermined';
    }
  }

  /// Requests microphone authorization from user.
  Future<bool> requestMicrophonePermission() async {
    if (!_isIos) return true;

    try {
      final granted = await _channel.invokeMethod<bool>('requestPermission');
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Disposes stream controllers.
  Future<void> dispose() async {
    await _interruptionController.close();
    await _routeChangeController.close();
    await _mediaResetController.close();
  }
}
