import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/core/observability/observability.dart';
import 'package:medico_opd/features/consultation/models/consultation_model.dart';
import 'package:medico_opd/features/patient/models/patient_model.dart';
import 'package:medico_opd/features/recording/models/recording_model.dart';
import 'package:medico_opd/features/recording/screens/recording_screen.dart';
import 'package:medico_opd/features/recording/services/recording_service.dart';

class MockRecordingService extends RecordingService {
  bool uploadCalled = false;
  bool triggerEdgeFunctionCalled = false;
  String? startRecordingResult;
  bool startRecordingThrows = false;
  String? stopRecordingResult;
  bool stopRecordingThrows = false;

  @override
  Future<String> startRecording({
    required String consultationId,
    required String patientId,
    required String clientRecordingId,
    String? overrideDirectoryPath,
  }) async {
    if (startRecordingThrows) {
      throw StateError('Microphone permission denied or device busy');
    }
    return startRecordingResult ?? 'test_recording.m4a';
  }

  @override
  Future<String?> stopRecording() async {
    if (stopRecordingThrows) {
      throw StateError('Hardware error stopping recorder');
    }
    return stopRecordingResult ?? startRecordingResult;
  }

  @override
  Future<RecordingModel?> getRecording(String recordingId) async {
    return null;
  }

  @override
  Future<RecordingModel> uploadAndRegisterRecording({
    required String localAudioPath,
    required String clientRecordingId,
    required String clinicId,
    required String consultationId,
    required String patientId,
    required String doctorId,
    int durationSeconds = 0,
    Uint8List? directBytes,
    CorrelationContext? correlationContext,
  }) async {
    uploadCalled = true;
    return RecordingModel(
      id: clientRecordingId,
      consultationId: consultationId,
      patientId: patientId,
      doctorId: doctorId,
      storagePath: 'clinics/$clinicId/consultations/$consultationId/$clientRecordingId.m4a',
      encryptionKeyRef: 'sse-s3',
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<Map<String, dynamic>> triggerEdgeFunctionProcessing({
    required String recordingId,
    required String consultationId,
    CorrelationContext? correlationContext,
  }) async {
    triggerEdgeFunctionCalled = true;
    return {'status': 'success'};
  }
}

void main() {
  group('RecordingScreen Hardening & Dummy-Byte Elimination Tests', () {
    late Directory tempDir;
    late PatientModel testPatient;
    late ConsultationModel testConsultation;
    const testDoctorId = 'doc-test-123';
    const testRecordingId = 'rec-test-uuid-456';

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('medico_screen_test_');

      testPatient = PatientModel(
        id: 'patient-test-01',
        clinicId: 'clinic-test-01',
        fullName: 'Aarav Sharma',
        dobOrAge: '32',
        sex: 'Male',
        contactInfo: '+919876543210',
        createdAt: DateTime.now(),
      );

      testConsultation = ConsultationModel(
        id: 'consultation-test-01',
        patientId: testPatient.id,
        doctorId: testDoctorId,
        clinicId: 'clinic-test-01',
        status: 'in_progress',
        startedAt: DateTime.now(),
        createdAt: DateTime.now(),
      );
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Widget createScreen(MockRecordingService service) {
      return MaterialApp(
        home: RecordingScreen(
          patient: testPatient,
          consultation: testConsultation,
          doctorId: testDoctorId,
          clientRecordingId: testRecordingId,
          recordingService: service,
        ),
      );
    }

    testWidgets('1. Valid audio file -> upload proceeds and triggers processing', (tester) async {
      final validAudioFile = File('${tempDir.path}/valid_audio.m4a');
      validAudioFile.writeAsBytesSync([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70]); // Non-empty audio header

      final mockService = MockRecordingService()
        ..startRecordingResult = validAudioFile.path
        ..stopRecordingResult = validAudioFile.path;

      await tester.pumpWidget(createScreen(mockService));
      await tester.pump();

      // Tap 'Start Recording' button
      final startButton = find.byKey(const Key('start_recording_button'));
      expect(startButton, findsOneWidget);
      await tester.tap(startButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Tap 'Stop & Upload Audio' button
      final stopButton = find.byKey(const Key('stop_recording_button'));
      expect(stopButton, findsOneWidget);
      await tester.tap(stopButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify upload was invoked
      expect(mockService.uploadCalled, isTrue, reason: 'Upload must be called when valid file exists');
      expect(mockService.triggerEdgeFunctionCalled, isTrue, reason: 'Edge Function must be triggered after successful upload');
    });

    testWidgets('2. Missing audio file -> upload rejected with error and no DB row created', (tester) async {
      final nonExistentFile = '${tempDir.path}/missing_file_never_created.m4a';

      final mockService = MockRecordingService()
        ..startRecordingResult = nonExistentFile
        ..stopRecordingResult = nonExistentFile;

      await tester.pumpWidget(createScreen(mockService));
      await tester.pump();

      // Tap 'Start Recording' button
      final startButton = find.byKey(const Key('start_recording_button'));
      expect(startButton, findsOneWidget);
      await tester.tap(startButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Tap 'Stop & Upload Audio' button
      final stopButton = find.byKey(const Key('stop_recording_button'));
      expect(stopButton, findsOneWidget);
      await tester.tap(stopButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify upload was NOT invoked
      expect(mockService.uploadCalled, isFalse, reason: 'Upload must NEVER be called when audio file is missing');
      expect(mockService.triggerEdgeFunctionCalled, isFalse);

      // Verify safe error message is displayed
      expect(find.textContaining('Recorded audio file not found on device'), findsOneWidget);
      expect(find.byKey(const Key('retry_button')), findsOneWidget);
    });

    testWidgets('3. Empty audio file (0 bytes) -> upload rejected with error and no DB row created', (tester) async {
      final emptyFile = File('${tempDir.path}/empty_zero_bytes.m4a');
      emptyFile.writeAsBytesSync([]); // 0 bytes

      final mockService = MockRecordingService()
        ..startRecordingResult = emptyFile.path
        ..stopRecordingResult = emptyFile.path;

      await tester.pumpWidget(createScreen(mockService));
      await tester.pump();

      // Tap 'Start Recording' button
      final startButton = find.byKey(const Key('start_recording_button'));
      expect(startButton, findsOneWidget);
      await tester.tap(startButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Tap 'Stop & Upload Audio' button
      final stopButton = find.byKey(const Key('stop_recording_button'));
      expect(stopButton, findsOneWidget);
      await tester.tap(stopButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify upload was NOT invoked
      expect(mockService.uploadCalled, isFalse, reason: 'Upload must NEVER be called when audio file is 0 bytes');
      expect(mockService.triggerEdgeFunctionCalled, isFalse);

      // Verify safe error message is displayed
      expect(find.textContaining('Recorded audio file is empty (0 bytes)'), findsOneWidget);
    });

    testWidgets('4. Failed microphone start -> transitions to uploadFailed and does not fake path', (tester) async {
      final mockService = MockRecordingService()
        ..startRecordingThrows = true;

      await tester.pumpWidget(createScreen(mockService));
      await tester.pump();

      // Tap 'Start Recording' button
      final startButton = find.byKey(const Key('start_recording_button'));
      expect(startButton, findsOneWidget);
      await tester.tap(startButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Should show uploadFailed / error banner immediately
      expect(find.textContaining('Microphone recording failed to start'), findsOneWidget);
      expect(mockService.uploadCalled, isFalse);
    });

    test('5. Static check: RecordingScreen source contains zero dummy byte fallbacks', () {
      final screenFile = File('lib/features/recording/screens/recording_screen.dart');
      expect(screenFile.existsSync(), isTrue);

      final content = screenFile.readAsStringSync();
      expect(
        content.contains('AUDIO_PAYLOAD_'),
        isFalse,
        reason: 'RecordingScreen must NEVER contain fake AUDIO_PAYLOAD fallbacks',
      );
      expect(
        content.contains('directBytes:'),
        isFalse,
        reason: 'RecordingScreen must not pass directBytes',
      );
      expect(
        content.contains("sandbox_\${widget.clientRecordingId}"),
        isFalse,
        reason: 'RecordingScreen must not create synthetic sandbox paths on mic failure',
      );
    });
  });
}
