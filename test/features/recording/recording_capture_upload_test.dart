import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/features/recording/services/recording_recovery_service.dart';
import 'package:medico_opd/features/recording/services/recording_service.dart';

void main() {
  group('Recording Capture, Envelope Encryption & Recovery Tests', () {
    late Directory tempDir;
    late RecordingRecoveryService recoveryService;
    late RecordingService recordingService;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('medico_recording_test_');
      recoveryService = RecordingRecoveryService(directory: tempDir);
      recordingService = RecordingService(recoveryService: recoveryService);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('AES-256-GCM envelope encryption encrypts raw audio and matches SHA-256 checksum', () async {
      final sampleAudio = Uint8List.fromList(utf8.encode('SIMULATED_CONSULTATION_AUDIO_AAC_16KHZ'));
      const clinicId = 'clinic-alpha-999';

      final encrypted = await recordingService.encryptAudioBytes(
        rawAudioBytes: sampleAudio,
        clinicId: clinicId,
      );

      // Ciphertext must differ from plaintext
      expect(encrypted.ciphertext, isNot(equals(sampleAudio)));
      expect(encrypted.ciphertext, isNotEmpty);

      // Checksum must match SHA-256 of ciphertext
      final computedChecksum = sha256.convert(encrypted.ciphertext).toString();
      expect(encrypted.sha256Checksum, equals(computedChecksum));

      // Key reference must scope to clinic
      expect(encrypted.encryptionKeyRef, startsWith('kms://vault/clinics/$clinicId/dek_'));

      // Test that nonce is valid base64
      final nonce = base64Decode(encrypted.nonceBase64);
      expect(nonce, isNotEmpty);
    });

    test('Crash-recovery checkpoint: save, checkInterruptedRecording, and clearCheckpointAndPurgeFile', () async {
      final dummyAudioFile = File('${tempDir.path}/interrupted_audio.m4a');
      await dummyAudioFile.writeAsString('PARTIAL_AUDIO_RECORDING_BYTES');

      final checkpoint = InterruptedRecordingCheckpoint(
        recordingId: 'rec-interrupted-01',
        consultationId: 'cons-999',
        patientId: 'pat-888',
        localFilePath: dummyAudioFile.path,
        recordedAt: DateTime.now(),
      );

      // 1. Save checkpoint
      await recoveryService.saveActiveCheckpoint(checkpoint, overrideDir: tempDir);

      // 2. Check interrupted recording
      final detected = await recoveryService.checkInterruptedRecording(overrideDir: tempDir);
      expect(detected, isNotNull);
      expect(detected!.recordingId, 'rec-interrupted-01');
      expect(detected.consultationId, 'cons-999');
      expect(detected.localFilePath, dummyAudioFile.path);

      // 3. Clear checkpoint and purge orphaned partial file
      await recoveryService.clearCheckpointAndPurgeFile(detected, overrideDir: tempDir);

      // Verify both checkpoint and audio file are purged
      expect(await dummyAudioFile.exists(), isFalse);
      final checkAgain = await recoveryService.checkInterruptedRecording(overrideDir: tempDir);
      expect(checkAgain, isNull);
    });

    test('Checksum verification failure aborts upload pipeline', () async {
      final dummyAudioFile = File('${tempDir.path}/corrupt_audio.m4a');
      await dummyAudioFile.writeAsString(''); // Empty file

      expect(
        () async => await recordingService.uploadAndRegisterRecording(
          localAudioPath: dummyAudioFile.path,
          clientRecordingId: 'rec-corrupt-01',
          clinicId: 'clinic-01',
          consultationId: 'cons-01',
          patientId: 'pat-01',
          doctorId: 'doc-01',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
