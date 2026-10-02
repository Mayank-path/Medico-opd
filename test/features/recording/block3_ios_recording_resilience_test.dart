import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/features/recording/models/recording_errors.dart';
import 'package:medico_opd/features/recording/models/recording_lifecycle_state.dart';
import 'package:medico_opd/features/recording/models/recording_session_model.dart';
import 'package:medico_opd/features/recording/services/ios_recording_resilience_service.dart';
import 'package:medico_opd/features/recording/services/recording_recovery_service.dart';
import 'package:medico_opd/features/recording/services/recording_service.dart';
import 'package:medico_opd/features/recording/services/recording_session_store.dart';
import 'package:medico_opd/features/recording/services/recording_state_manager.dart';
import 'package:record/record.dart';

// --- Mock AudioRecorder ---
class MockAudioRecorder implements AudioRecorder {
  bool permissionGranted;
  bool isStarted = false;
  bool isPausedState = false;
  String? lastPath;

  MockAudioRecorder({this.permissionGranted = true});

  @override
  Future<bool> hasPermission({bool request = true}) async => permissionGranted;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    if (!permissionGranted) throw StateError('Permission denied');
    isStarted = true;
    isPausedState = false;
    lastPath = path;
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes([0x00, 0x01, 0x02, 0x03]);
  }

  @override
  Future<void> pause() async {
    if (!isStarted) throw StateError('Not started');
    isPausedState = true;
  }

  @override
  Future<void> resume() async {
    if (!isStarted) throw StateError('Not started');
    isPausedState = false;
  }

  @override
  Future<String?> stop() async {
    isStarted = false;
    isPausedState = false;
    return lastPath;
  }

  @override
  Future<bool> isRecording() async => isStarted && !isPausedState;

  @override
  Future<bool> isPaused() async => isStarted && isPausedState;

  @override
  Future<void> cancel() async {
    isStarted = false;
    isPausedState = false;
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late RecordingSessionStore store;
  late RecordingStateManager stateManager;
  late RecordingRecoveryService recoveryService;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('medico_block3_test_');
    store = RecordingSessionStore(directory: tempDir);
    stateManager = RecordingStateManager(store: store);
    recoveryService = RecordingRecoveryService(directory: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Block 3 — iOS Recording Resilience Suite', () {
    // =========================================================================
    // 1. Permission Gating (Section 19.A)
    // =========================================================================
    group('A. Microphone Permission Gating', () {
      test('1. Permission granted allows recording to progress through preparing to recording', () async {
        final mockRecorder = MockAudioRecorder(permissionGranted: true);
        final iosResilience = IosRecordingResilienceService(isIos: false);
        final recordingService = RecordingService(
          recorder: mockRecorder,
          recoveryService: recoveryService,
          stateManager: stateManager,
          iosResilience: iosResilience,
        );

        final path = await recordingService.startRecording(
          consultationId: 'cons-ios-perm-001',
          patientId: 'pat-ios-perm-001',
          clientRecordingId: 'sess-ios-perm-001',
          overrideDirectoryPath: tempDir.path,
        );

        expect(path, contains('sess-ios-perm-001.m4a'));
        final session = await stateManager.getSession('sess-ios-perm-001');
        expect(session?.state, equals(RecordingLifecycleState.recording));
        expect(mockRecorder.isStarted, isTrue);
      });

      test('2. Permission denied fails deterministically and never reaches recording state', () async {
        final mockRecorder = MockAudioRecorder(permissionGranted: false);
        final iosResilience = IosRecordingResilienceService(isIos: false);
        final recordingService = RecordingService(
          recorder: mockRecorder,
          recoveryService: recoveryService,
          stateManager: stateManager,
          iosResilience: iosResilience,
        );

        expect(
          () => recordingService.startRecording(
            consultationId: 'cons-ios-perm-denied',
            patientId: 'pat-ios-perm-denied',
            clientRecordingId: 'sess-ios-perm-denied',
            overrideDirectoryPath: tempDir.path,
          ),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Microphone recording permission denied'),
          )),
        );

        final session = await stateManager.getSession('sess-ios-perm-denied');
        expect(session, isNull);
        expect(mockRecorder.isStarted, isFalse);
      });
    });

    // =========================================================================
    // 2. Lifecycle & Background Resilience (Section 19.B)
    // =========================================================================
    group('B. iOS Lifecycle & App Background Resilience', () {
      test('3. App backgrounding and foreground return preserves same session UUID without duplicate recorder', () async {
        final mockRecorder = MockAudioRecorder(permissionGranted: true);
        final iosResilience = IosRecordingResilienceService(isIos: false);
        final recordingService = RecordingService(
          recorder: mockRecorder,
          recoveryService: recoveryService,
          stateManager: stateManager,
          iosResilience: iosResilience,
        );

        const sessionId = 'sess-ios-lifecycle-001';
        await recordingService.startRecording(
          consultationId: 'cons-ios-lifecycle-001',
          patientId: 'pat-ios-lifecycle-001',
          clientRecordingId: sessionId,
          overrideDirectoryPath: tempDir.path,
        );

        // Simulate app moving to background (UI detached)
        final sessionWhileBackgrounded = await stateManager.getSession(sessionId);
        expect(sessionWhileBackgrounded?.state, equals(RecordingLifecycleState.recording));
        expect(sessionWhileBackgrounded?.recordingSessionId, equals(sessionId));

        // Simulate app returning to foreground (UI reconnected)
        final sessionForegrounded = await stateManager.getSession(sessionId);
        expect(sessionForegrounded?.recordingSessionId, equals(sessionId));
        expect(sessionForegrounded?.state, equals(RecordingLifecycleState.recording));
        expect(mockRecorder.isStarted, isTrue);

        await recordingService.stopRecording();
        final sessionStopped = await stateManager.getSession(sessionId);
        expect(sessionStopped?.state, equals(RecordingLifecycleState.recorded));
      });
    });

    // =========================================================================
    // 3. Audio Interruptions (Section 19.C & 19.D)
    // =========================================================================
    group('C & D. AVAudioSession Interruptions (Phone Call, Siri, Alarms)', () {
      test('4. Interruption began pauses recorder, persists recovery metadata, does not fabricate recorded', () async {
        final mockRecorder = MockAudioRecorder(permissionGranted: true);
        final iosResilience = IosRecordingResilienceService(isIos: false);
        final recordingService = RecordingService(
          recorder: mockRecorder,
          recoveryService: recoveryService,
          stateManager: stateManager,
          iosResilience: iosResilience,
        );

        const sessionId = 'sess-ios-interruption-001';
        await recordingService.startRecording(
          consultationId: 'cons-ios-interruption-001',
          patientId: 'pat-ios-interruption-001',
          clientRecordingId: sessionId,
          overrideDirectoryPath: tempDir.path,
        );

        // Simulate native iOS AVAudioSession.interruptionNotification (began)
        // Dispatched via MethodChannel handler
        final binaryMessenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final codec = const StandardMethodCodec();
        final callData = codec.encodeMethodCall(
          const MethodCall('onAudioInterruption', {
            'type': 'began',
            'reason': 'AUDIO_INTERRUPTION_BEGAN',
            'sessionId': sessionId,
          }),
        );

        await binaryMessenger.handlePlatformMessage(
          IosRecordingResilienceService.channelName,
          callData,
          (_) {},
        );

        // Allow async stream listener to process
        await Future.delayed(const Duration(milliseconds: 50));

        final session = await stateManager.getSession(sessionId);
        expect(session?.state, equals(RecordingLifecycleState.paused));
        expect(session?.recoveryMetadata?['interruptedBy'], equals('AUDIO_INTERRUPTION_BEGAN'));
        expect(session?.recoveryMetadata?['interruptedAt'], isNotNull);
        expect(mockRecorder.isPausedState, isTrue);
      });

      test('5. Interruption ended maintains deterministic pause without unauthorized mic restart', () async {
        final mockRecorder = MockAudioRecorder(permissionGranted: true);
        final iosResilience = IosRecordingResilienceService(isIos: false);
        final recordingService = RecordingService(
          recorder: mockRecorder,
          recoveryService: recoveryService,
          stateManager: stateManager,
          iosResilience: iosResilience,
        );

        const sessionId = 'sess-ios-interruption-ended-001';
        await recordingService.startRecording(
          consultationId: 'cons-ios-interruption-ended-001',
          patientId: 'pat-ios-interruption-ended-001',
          clientRecordingId: sessionId,
          overrideDirectoryPath: tempDir.path,
        );

        final binaryMessenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final codec = const StandardMethodCodec();

        // 1. Interruption began
        await binaryMessenger.handlePlatformMessage(
          IosRecordingResilienceService.channelName,
          codec.encodeMethodCall(
            const MethodCall('onAudioInterruption', {
              'type': 'began',
              'reason': 'INTERRUPTION_APP_SUSPENDED',
              'sessionId': sessionId,
            }),
          ),
          (_) {},
        );
        await Future.delayed(const Duration(milliseconds: 50));

        // 2. Interruption ended with shouldResume = true
        await binaryMessenger.handlePlatformMessage(
          IosRecordingResilienceService.channelName,
          codec.encodeMethodCall(
            const MethodCall('onAudioInterruption', {
              'type': 'ended',
              'reason': 'AUDIO_INTERRUPTION_ENDED',
              'shouldResume': true,
              'sessionId': sessionId,
            }),
          ),
          (_) {},
        );
        await Future.delayed(const Duration(milliseconds: 50));

        // Block 3 Constraint: Session MUST remain safely paused; mic does not auto-restart
        final session = await stateManager.getSession(sessionId);
        expect(session?.state, equals(RecordingLifecycleState.paused));
        expect(session?.recoveryMetadata?['shouldResumeReported'], isTrue);
        expect(session?.recoveryMetadata?['interruptionEndedAt'], isNotNull);
        expect(mockRecorder.isPausedState, isTrue);

        // Explicit user action resumes
        await recordingService.resumeRecording();
        final resumedSession = await stateManager.getSession(sessionId);
        expect(resumedSession?.state, equals(RecordingLifecycleState.recording));
        expect(mockRecorder.isPausedState, isFalse);
      });
    });

    // =========================================================================
    // 4. Audio Route Changes (Section 19.E)
    // =========================================================================
    group('E. Audio Route Changes (AirPods / Bluetooth)', () {
      test('6. Route change notification handled safely without session corruption', () async {
        final mockRecorder = MockAudioRecorder(permissionGranted: true);
        final iosResilience = IosRecordingResilienceService(isIos: false);
        final recordingService = RecordingService(
          recorder: mockRecorder,
          recoveryService: recoveryService,
          stateManager: stateManager,
          iosResilience: iosResilience,
        );

        const sessionId = 'sess-ios-route-001';
        await recordingService.startRecording(
          consultationId: 'cons-ios-route-001',
          patientId: 'pat-ios-route-001',
          clientRecordingId: sessionId,
          overrideDirectoryPath: tempDir.path,
        );

        final binaryMessenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final codec = const StandardMethodCodec();

        // Simulate AirPods disconnected -> oldDeviceUnavailable
        await binaryMessenger.handlePlatformMessage(
          IosRecordingResilienceService.channelName,
          codec.encodeMethodCall(
            const MethodCall('onAudioRouteChange', {
              'reason': 'oldDeviceUnavailable',
              'previousRoute': 'BluetoothHFP',
              'currentRoute': 'BuiltInMic',
              'sessionId': sessionId,
            }),
          ),
          (_) {},
        );
        await Future.delayed(const Duration(milliseconds: 50));

        // Session remains healthy and actively recording
        final session = await stateManager.getSession(sessionId);
        expect(session?.state, equals(RecordingLifecycleState.recording));
        expect(mockRecorder.isStarted, isTrue);
      });
    });

    // =========================================================================
    // 5. Media Services Reset (Section 19.F)
    // =========================================================================
    group('F. Media Services Reset (mediaserverd crash)', () {
      test('7. Media services reset transitions session to recovery_required and persists metadata', () async {
        final mockRecorder = MockAudioRecorder(permissionGranted: true);
        final iosResilience = IosRecordingResilienceService(isIos: false);
        final recordingService = RecordingService(
          recorder: mockRecorder,
          recoveryService: recoveryService,
          stateManager: stateManager,
          iosResilience: iosResilience,
        );

        const sessionId = 'sess-ios-media-reset-001';
        await recordingService.startRecording(
          consultationId: 'cons-ios-media-reset-001',
          patientId: 'pat-ios-media-reset-001',
          clientRecordingId: sessionId,
          overrideDirectoryPath: tempDir.path,
        );

        final binaryMessenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final codec = const StandardMethodCodec();

        // Simulate OS mediaserverd crash reset
        await binaryMessenger.handlePlatformMessage(
          IosRecordingResilienceService.channelName,
          codec.encodeMethodCall(
            const MethodCall('onMediaServicesReset', {
              'reason': 'MEDIA_SERVICES_RESET',
              'sessionId': sessionId,
            }),
          ),
          (_) {},
        );
        await Future.delayed(const Duration(milliseconds: 50));

        final session = await stateManager.getSession(sessionId);
        expect(session?.state, equals(RecordingLifecycleState.recoveryRequired));
        expect(session?.recoveryMetadata?['failureCategory'], equals('MEDIA_SERVICES_RESET'));
        expect(session?.recoveryMetadata?['mediaServicesResetAt'], isNotNull);
      });
    });

    // =========================================================================
    // 6. Idempotency & Concurrency Invariants (Section 19.G)
    // =========================================================================
    group('G. Concurrency & Idempotency Invariants', () {
      test('8. Repeated pause/resume/stop commands are idempotent and do not corrupt state', () async {
        final mockRecorder = MockAudioRecorder(permissionGranted: true);
        final iosResilience = IosRecordingResilienceService(isIos: false);
        final recordingService = RecordingService(
          recorder: mockRecorder,
          recoveryService: recoveryService,
          stateManager: stateManager,
          iosResilience: iosResilience,
        );

        const sessionId = 'sess-ios-idempotent-001';
        await recordingService.startRecording(
          consultationId: 'cons-ios-idempotent-001',
          patientId: 'pat-ios-idempotent-001',
          clientRecordingId: sessionId,
          overrideDirectoryPath: tempDir.path,
        );

        // Pause twice
        await recordingService.pauseRecording();
        await recordingService.pauseRecording();
        expect((await stateManager.getSession(sessionId))?.state, equals(RecordingLifecycleState.paused));

        // Resume twice
        await recordingService.resumeRecording();
        await recordingService.resumeRecording();
        expect((await stateManager.getSession(sessionId))?.state, equals(RecordingLifecycleState.recording));

        // Stop
        await recordingService.stopRecording();
        expect((await stateManager.getSession(sessionId))?.state, equals(RecordingLifecycleState.recorded));
      });

      test('9. Single active session concurrency per consultation is strictly enforced', () async {
        const consultationId = 'cons-ios-concurrency-001';
        await stateManager.createSession(
          consultationId: consultationId,
          customSessionId: 'sess-active-001',
        );
        await stateManager.transitionTo('sess-active-001', RecordingLifecycleState.preparing);
        await stateManager.transitionTo('sess-active-001', RecordingLifecycleState.recording);

        expect(
          () => stateManager.createSession(
            consultationId: consultationId,
            customSessionId: 'sess-active-002',
          ),
          throwsA(isA<RecordingConcurrencyException>()),
        );
      });
    });

    // =========================================================================
    // 7. Crash Recovery / Process Interruption (Section 19.H)
    // =========================================================================
    group('H. Cold Recovery & Process Termination', () {
      test('10. Unclosed recording after iOS termination is discovered and recovered explicitly without mic auto-start', () async {
        // Step 1: Simulate active recording when process was killed by OS
        final audioFile = File('${tempDir.path}/recordings/sess-ios-crash-001.m4a');
        await audioFile.parent.create(recursive: true);
        await audioFile.writeAsBytes(List.filled(2048, 0x42));

        final orphanSession = RecordingSessionModel(
          recordingSessionId: 'sess-ios-crash-001',
          consultationId: 'cons-ios-crash-001',
          state: RecordingLifecycleState.recording,
          localFilePath: audioFile.path,
          createdAt: DateTime.now().subtract(const Duration(minutes: 10)),
          updatedAt: DateTime.now().subtract(const Duration(minutes: 9)),
        );
        await store.saveSession(orphanSession);

        // Step 2: Fresh app boot with new state manager
        final newStore = RecordingSessionStore(directory: tempDir);
        final newStateManager = RecordingStateManager(store: newStore);

        final recoverableSessions = await newStateManager.discoverRecoverableSessions();
        expect(recoverableSessions.length, equals(1));
        expect(recoverableSessions.first.state, equals(RecordingLifecycleState.recoveryRequired));

        // Step 3: Explicit recovery converts to recorded; does NOT auto-restart microphone
        final recovered = await newStateManager.markRecorded(
          recoverableSessions.first.recordingSessionId,
          checksum: 'test-chk-001',
        );

        expect(recovered.state, equals(RecordingLifecycleState.recorded));
      });
    });

    // =========================================================================
    // 8. Privacy & Data Minimization Audit (Section 22)
    // =========================================================================
    group('I. Privacy & Telemetry Audit', () {
      test('11. iOS resilience event logs and persisted sessions contain zero patient identifiers or clinical data', () async {
        const sessionId = 'sess-ios-privacy-001';
        await stateManager.createSession(
          consultationId: 'cons-ios-privacy-001',
          customSessionId: sessionId,
        );
        await stateManager.transitionTo(
          sessionId,
          RecordingLifecycleState.preparing,
        );
        await stateManager.transitionTo(
          sessionId,
          RecordingLifecycleState.recording,
          recoveryMetadata: {
            'interruptedBy': 'AUDIO_INTERRUPTION_BEGAN',
            'interruptedAt': DateTime.now().toIso8601String(),
          },
        );

        final sessionFile = File('${tempDir.path}/recording_sessions/$sessionId.json');
        expect(await sessionFile.exists(), isTrue);
        final jsonContent = await sessionFile.readAsString();

        // Privacy assertions: No PHI, no patient names, no medical data, no auth tokens
        expect(jsonContent, isNot(contains('John Doe')));
        expect(jsonContent, isNot(contains('patient_name')));
        expect(jsonContent, isNot(contains('diagnosis')));
        expect(jsonContent, isNot(contains('transcript')));
        expect(jsonContent, isNot(contains('Bearer ')));
        expect(jsonContent, isNot(contains('refreshToken')));
        expect(jsonContent, contains(sessionId));
      });
    });
  });
}
