import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:medico_opd/features/consultation/models/consultation_model.dart';
import 'package:medico_opd/features/patient/models/patient_model.dart';
import 'package:medico_opd/features/recording/models/recording_lifecycle_state.dart';
import 'package:medico_opd/features/recording/models/recording_model.dart';
import 'package:medico_opd/features/recording/models/recording_session_model.dart';
import 'package:medico_opd/features/recording/screens/recording_screen.dart';
import 'package:medico_opd/features/recording/services/android_recording_resilience_service.dart';
import 'package:medico_opd/features/recording/services/recording_service.dart';
import 'package:medico_opd/features/recording/services/recording_session_store.dart';
import 'package:medico_opd/features/recording/services/recording_state_manager.dart';
import 'package:record/record.dart';

class MockTestRecordingService extends RecordingService {
  MockTestRecordingService({
    super.stateManager,
    super.recorder,
    super.androidResilience,
  });

  @override
  Future<RecordingModel?> getRecording(String recordingId) async => null;
}

/// Mock AudioRecorder simulating native hardware capture and state without real microphone.
class MockAudioRecorder implements AudioRecorder {
  bool _isRecording = false;
  bool _isPaused = false;
  String? _lastPath;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    _isRecording = true;
    _isPaused = false;
    _lastPath = path;
    final file = File(path);
    if (!file.existsSync()) {
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(List.filled(1024, 0xAA)); // 1KB mock audio
    }
  }

  @override
  Future<String?> stop() async {
    _isRecording = false;
    _isPaused = false;
    return _lastPath;
  }

  @override
  Future<void> pause() async {
    _isPaused = true;
    _isRecording = false;
  }

  @override
  Future<void> resume() async {
    _isPaused = false;
    _isRecording = true;
  }

  @override
  Future<bool> isRecording() async => _isRecording;

  @override
  Future<bool> isPaused() async => _isPaused;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<void> dispose() async {
    _isRecording = false;
    _isPaused = false;
  }

  @override
  Future<void> cancel() async {
    _isRecording = false;
    _isPaused = false;
  }

  @override
  Stream<RecordState> onStateChanged() => const Stream.empty();

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) => const Stream.empty();

  @override
  Future<List<InputDevice>> listInputDevices() async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late RecordingSessionStore store;
  late RecordingStateManager stateManager;
  late MockAudioRecorder mockRecorder;
  late AndroidRecordingResilienceService resilienceService;
  late RecordingService recordingService;

  final List<MethodCall> nativeMethodCalls = [];

  setUp(() async {
    nativeMethodCalls.clear();

    // Mock platform channel for Android resilience
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(AndroidRecordingResilienceService.channelName),
      (MethodCall call) async {
        nativeMethodCalls.add(call);
        switch (call.method) {
          case 'startForegroundService':
            return true;
          case 'updateForegroundServiceState':
            return true;
          case 'stopForegroundService':
            return true;
          case 'isForegroundServiceRunning':
            return true;
          default:
            return null;
        }
      },
    );

    tempDir = await Directory.systemTemp.createTemp('medico_b2_test_');
    store = RecordingSessionStore(directory: tempDir);
    stateManager = RecordingStateManager(store: store);
    mockRecorder = MockAudioRecorder();
    resilienceService = AndroidRecordingResilienceService(isAndroid: true);
    recordingService = RecordingService(
      stateManager: stateManager,
      recorder: mockRecorder,
      androidResilience: resilienceService,
    );
  });

  tearDown(() async {
    await recordingService.dispose();
    await stateManager.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(AndroidRecordingResilienceService.channelName),
      null,
    );
  });

  group('Block 2 — Android Recording Resilience & Foreground Service Lifecycle', () {
    test('1. Starting recording starts Android foreground service with privacy-safe metadata', () async {
      const sessionId = 'b2-sess-001';
      const consultationId = 'cons-b2-100';

      final path = await recordingService.startRecording(
        consultationId: consultationId,
        patientId: 'patient-privacy-test',
        clientRecordingId: sessionId,
      );

      expect(path, isNotNull);
      expect(File(path).existsSync(), isTrue);

      // Verify native method calls
      final startCalls = nativeMethodCalls.where((c) => c.method == 'startForegroundService').toList();
      expect(startCalls.length, 1);

      final args = Map<String, dynamic>.from(startCalls.first.arguments as Map);
      expect(args['recordingSessionId'], sessionId);
      expect(args['consultationId'], consultationId);

      // Privacy audit: Verify no patient ID, consultation clinical details in notification/channel payload
      expect(args.containsKey('patientName'), isFalse);
      expect(args.containsKey('patientId'), isFalse);
      expect(args.containsKey('uhid'), isFalse);
      expect(args.containsKey('diagnosis'), isFalse);
      expect(args.containsKey('token'), isFalse);

      // Verify canonical state is recording
      final session = await stateManager.getSession(sessionId);
      expect(session, isNotNull);
      expect(session!.state, RecordingLifecycleState.recording);
    });

    test('2. Pausing recording updates Android foreground notification state to paused', () async {
      const sessionId = 'b2-sess-002';
      await recordingService.startRecording(
        consultationId: 'cons-b2-101',
        patientId: 'pat-101',
        clientRecordingId: sessionId,
      );

      await recordingService.pauseRecording();

      // Verify updateForegroundServiceState called with paused
      final updateCalls = nativeMethodCalls.where((c) => c.method == 'updateForegroundServiceState').toList();
      expect(updateCalls.isNotEmpty, isTrue);
      final lastUpdate = Map<String, dynamic>.from(updateCalls.last.arguments as Map);
      expect(lastUpdate['state'], 'paused');

      // Verify canonical state is paused
      final session = await stateManager.getSession(sessionId);
      expect(session!.state, RecordingLifecycleState.paused);
    });

    test('3. Resuming recording updates Android foreground notification state back to recording', () async {
      const sessionId = 'b2-sess-003';
      await recordingService.startRecording(
        consultationId: 'cons-b2-102',
        patientId: 'pat-102',
        clientRecordingId: sessionId,
      );

      await recordingService.pauseRecording();
      await recordingService.resumeRecording();

      final updateCalls = nativeMethodCalls.where((c) => c.method == 'updateForegroundServiceState').toList();
      expect(updateCalls.length, greaterThanOrEqualTo(2));
      final lastUpdate = Map<String, dynamic>.from(updateCalls.last.arguments as Map);
      expect(lastUpdate['state'], 'recording');

      final session = await stateManager.getSession(sessionId);
      expect(session!.state, RecordingLifecycleState.recording);
    });

    test('4. Stopping recording safely tears down Android foreground service', () async {
      const sessionId = 'b2-sess-004';
      await recordingService.startRecording(
        consultationId: 'cons-b2-103',
        patientId: 'pat-103',
        clientRecordingId: sessionId,
      );

      final stoppedPath = await recordingService.stopRecording();
      expect(stoppedPath, isNotNull);

      // Verify stopForegroundService was dispatched
      final stopCalls = nativeMethodCalls.where((c) => c.method == 'stopForegroundService').toList();
      expect(stopCalls.length, 1);

      // Verify canonical state transitioned to recorded
      final session = await stateManager.getSession(sessionId);
      expect(session!.state, RecordingLifecycleState.recorded);
      expect(session.localFilePath, stoppedPath);
    });
  });

  group('Block 2 — Audio Interruption & Focus Loss Handling', () {
    test('5. Android AUDIOFOCUS_LOSS (e.g. phone call) auto-pauses recording with audit metadata', () async {
      const sessionId = 'b2-sess-interruption-001';
      await recordingService.startRecording(
        consultationId: 'cons-b2-call',
        patientId: 'pat-call',
        clientRecordingId: sessionId,
      );

      expect(await mockRecorder.isRecording(), isTrue);

      // Simulate native Android sending onAudioInterruption callback to Flutter
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        AndroidRecordingResilienceService.channelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onAudioInterruption', {
            'reason': 'AUDIOFOCUS_LOSS',
            'sessionId': sessionId,
          }),
        ),
        (ByteData? data) {},
      );

      // Small async yield to allow stream listeners to execute
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Verify hardware recorder was paused
      expect(await mockRecorder.isPaused(), isTrue);

      // Verify canonical state was transitioned to paused
      final session = await stateManager.getSession(sessionId);
      expect(session!.state, RecordingLifecycleState.paused);
      expect(session.recoveryMetadata?['interruptedBy'], 'AUDIOFOCUS_LOSS');
    });

    test('6. Android AUDIOFOCUS_LOSS_TRANSIENT (e.g. notification ring) pauses recording gracefully', () async {
      const sessionId = 'b2-sess-interruption-002';
      await recordingService.startRecording(
        consultationId: 'cons-b2-ring',
        patientId: 'pat-ring',
        clientRecordingId: sessionId,
      );

      // Simulate native transient audio focus loss
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        AndroidRecordingResilienceService.channelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onAudioInterruption', {
            'reason': 'AUDIOFOCUS_LOSS_TRANSIENT',
            'sessionId': sessionId,
          }),
        ),
        (ByteData? data) {},
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(await mockRecorder.isPaused(), isTrue);
      final session = await stateManager.getSession(sessionId);
      expect(session!.state, RecordingLifecycleState.paused);
      expect(session.recoveryMetadata?['interruptedBy'], 'AUDIOFOCUS_LOSS_TRANSIENT');
    });
  });

  group('Block 2 — Concurrency & Idempotency Invariants', () {
    test('7. Repeated start commands do not duplicate foreground service or create multiple sessions', () async {
      const sessionId = 'b2-sess-idempotent-001';
      const consultationId = 'cons-b2-repeat';

      await recordingService.startRecording(
        consultationId: consultationId,
        patientId: 'pat-repeat',
        clientRecordingId: sessionId,
      );

      // Attempt second start while already recording
      expect(
        () => recordingService.startRecording(
          consultationId: consultationId,
          patientId: 'pat-repeat',
          clientRecordingId: sessionId,
        ),
        throwsA(isA<Exception>()),
      );

      // Verify only 1 startForegroundService call occurred
      final startCalls = nativeMethodCalls.where((c) => c.method == 'startForegroundService').toList();
      expect(startCalls.length, 1);
    });

    test('8. Repeated pause/resume commands are idempotent and do not corrupt state', () async {
      const sessionId = 'b2-sess-idempotent-002';
      await recordingService.startRecording(
        consultationId: 'cons-b2-idem',
        patientId: 'pat-idem',
        clientRecordingId: sessionId,
      );

      // First pause
      await recordingService.pauseRecording();
      var session = await stateManager.getSession(sessionId);
      expect(session!.state, RecordingLifecycleState.paused);

      // Second pause (safe no-op or handled gracefully by state machine)
      try {
        await recordingService.pauseRecording();
      } catch (e) {
        // Handled gracefully
      }
      session = await stateManager.getSession(sessionId);
      expect(session!.state, RecordingLifecycleState.paused);

      // First resume
      await recordingService.resumeRecording();
      session = await stateManager.getSession(sessionId);
      expect(session!.state, RecordingLifecycleState.recording);

      // Stop recording
      await recordingService.stopRecording();
      session = await stateManager.getSession(sessionId);
      expect(session!.state, RecordingLifecycleState.recorded);
    });
  });

  group('Block 2 — Process Death / Unfinished Session Recovery', () {
    test('9. Unfinished session killed during background recording enters Block 1 recovery on reboot', () async {
      const orphanSessionId = 'b2-orphan-process-death';
      const consultationId = 'cons-b2-death';

      final audioFile = File('${tempDir.path}/interrupted_audio.m4a');
      audioFile.writeAsBytesSync(List.filled(2048, 0xBB));

      // Simulate a session that was actively recording when the Android OS killed the process
      final interruptedSession = RecordingSessionModel(
        recordingSessionId: orphanSessionId,
        consultationId: consultationId,
        doctorId: 'doc-001',
        clinicId: 'clinic-001',
        localFilePath: audioFile.path,
        state: RecordingLifecycleState.recording,
        createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
        startedAt: DateTime.now().subtract(const Duration(minutes: 5)),
        updatedAt: DateTime.now().subtract(const Duration(minutes: 5)),
        durationSeconds: 120,
      );

      await store.saveSession(interruptedSession);

      // On app reboot / service recreation: run recovery discovery
      final recoverable = await stateManager.discoverRecoverableSessions();

      expect(recoverable.isNotEmpty, isTrue);
      final discovered = recoverable.firstWhere((s) => s.recordingSessionId == orphanSessionId);
      expect(discovered.recordingSessionId, orphanSessionId);
      // Unfinished recording must transition to recoveryRequired, NOT completed or uploaded
      expect(discovered.state, RecordingLifecycleState.recoveryRequired);

      // Recovery requires explicit user action to recover
      final recovered = await stateManager.recoverSession(
        orphanSessionId,
        resumeTargetState: RecordingLifecycleState.recorded,
      );
      expect(recovered.state, RecordingLifecycleState.recorded);
      expect(recovered.recordingSessionId, orphanSessionId);
    });
  });

  group('Block 2 — Static Privacy & Security Audit', () {
    test('10. Native Kotlin service contains NO patient names, UHIDs, clinical data, or auth secrets', () {
      final serviceFile = File('android/app/src/main/kotlin/com/medico/opd/medico_opd/recording/RecordingForegroundService.kt');
      expect(serviceFile.existsSync(), isTrue);

      final content = serviceFile.readAsStringSync();

      // Ensure no sensitive clinical or patient fields exist in service
      expect(content.contains('patientName'), isFalse);
      expect(content.contains('uhid'), isFalse);
      expect(content.contains('diagnosis'), isFalse);
      expect(content.contains('transcript'), isFalse);
      expect(content.contains('bearer'), isFalse);
      expect(content.contains('jwt'), isFalse);
      expect(content.contains('supabaseKey'), isFalse);

      // Ensure notification channel is configured with privacy-safe strings
      expect(content.contains('Consultation Recording'), isTrue);
      expect(content.contains('Recording consultation audio'), isTrue);
      expect(content.contains('FOREGROUND_SERVICE_TYPE_MICROPHONE'), isTrue);
    });

    test('11. AndroidManifest declares required foreground service permissions and microphone type', () {
      final manifestFile = File('android/app/src/main/AndroidManifest.xml');
      expect(manifestFile.existsSync(), isTrue);

      final manifest = manifestFile.readAsStringSync();

      expect(manifest.contains('android.permission.FOREGROUND_SERVICE'), isTrue);
      expect(manifest.contains('android.permission.FOREGROUND_SERVICE_MICROPHONE'), isTrue);
      expect(manifest.contains('android.permission.POST_NOTIFICATIONS'), isTrue);
      expect(manifest.contains('android:foregroundServiceType="microphone"'), isTrue);
      expect(manifest.contains('.recording.RecordingForegroundService'), isTrue);
    });
  });

  group('Block 2 — Activity Lifecycle & UI Reconnection', () {
    testWidgets('12. Activity background -> foreground resume reconciles state without duplicate recording', (tester) async {
      await tester.runAsync(() async {
        const sessionId = 'b2-sess-lifecycle-001';
        const consultationId = 'cons-lifecycle-001';

        // Setup pre-existing recording session in canonical state manager
        final audioFile = File('${tempDir.path}/$sessionId.m4a');
        audioFile.writeAsBytesSync(List.filled(1024, 0xCC));

        await stateManager.createSession(
          consultationId: consultationId,
          customSessionId: sessionId,
        );
        await stateManager.prepareRecording(sessionId);
        await stateManager.startRecording(
          sessionId,
          localFilePath: audioFile.path,
        );

        final patient = PatientModel(
          id: 'patient-b2',
          clinicId: 'clinic-001',
          fullName: 'Dr. Test Patient',
          dobOrAge: '45',
          sex: 'Female',
          contactInfo: '+919876543210',
          createdAt: DateTime.now(),
        );

        final consultation = ConsultationModel(
          id: consultationId,
          patientId: patient.id,
          doctorId: 'doc-001',
          clinicId: 'clinic-001',
          status: 'in_progress',
          startedAt: DateTime.now(),
          createdAt: DateTime.now(),
        );

        final mockService = MockTestRecordingService(
          stateManager: stateManager,
          recorder: mockRecorder,
          androidResilience: resilienceService,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: RecordingScreen(
              patient: patient,
              consultation: consultation,
              doctorId: 'doc-001',
              clientRecordingId: sessionId,
              recordingService: mockService,
              stateManager: stateManager,
            ),
          ),
        );

        // Allow async state reconciliation to execute
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();

        // Verify UI is in recording state
        expect(find.byKey(const Key('state_recording_label')), findsOneWidget);
        expect(find.byKey(const Key('stop_recording_button')), findsOneWidget);

        // Simulate Activity backgrounding (pause)
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();

        // Canonical state must still be recording
        var session = await stateManager.getSession(sessionId);
        expect(session!.state, RecordingLifecycleState.recording);

        // Simulate Activity foreground return (resumed)
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();

        // UI remains in recording state with same session ID
        expect(find.byKey(const Key('state_recording_label')), findsOneWidget);
        session = await stateManager.getSession(sessionId);
        expect(session!.recordingSessionId, sessionId);
        expect(session.state, RecordingLifecycleState.recording);

        // Clean up widget and active periodic timer
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    });
  });
}
