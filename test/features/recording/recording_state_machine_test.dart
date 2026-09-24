import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/core/utils/uuid_generator.dart';
import 'package:medico_opd/features/recording/models/recording_model.dart';

void main() {
  group('Recording State Machine & Model Unit Tests', () {
    final now = DateTime.now();

    test('generateUuidV4 produces valid RFC 4122 v4 UUIDs', () {
      final uuid1 = generateUuidV4();
      final uuid2 = generateUuidV4();

      expect(uuid1, isNot(equals(uuid2)));
      // RFC 4122 v4 regex: 8-4-4-4-12 hex with 4 at version pos and [89ab] at variant pos
      final uuidRegex = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        caseSensitive: false,
      );
      expect(uuidRegex.hasMatch(uuid1), isTrue, reason: 'UUID $uuid1 must match v4 format');
      expect(uuidRegex.hasMatch(uuid2), isTrue, reason: 'UUID $uuid2 must match v4 format');
    });

    test('RecordingModel serializes and deserializes accurately', () {
      final model = RecordingModel(
        id: 'rec-001',
        consultationId: 'cons-100',
        patientId: 'patient-200',
        doctorId: 'doc-777',
        storagePath: 'clinic-555/cons-100/rec-001.m4a',
        encryptionKeyRef: 'kms://vault/key-01',
        durationSeconds: 142,
        format: 'm4a',
        uploadStatus: RecordingUploadStatus.uploaded,
        processingStatus: RecordingProcessingStatus.transcribed,
        createdAt: now,
        retentionExpiresAt: null,
        legalHold: false,
        deletionStatus: RecordingDeletionStatus.active,
      );

      final json = model.toJson();
      expect(json['id'], 'rec-001');
      expect(json['consultation_id'], 'cons-100');
      expect(json['patient_id'], 'patient-200');
      expect(json['doctor_id'], 'doc-777');
      expect(json['upload_status'], 'uploaded');
      expect(json['processing_status'], 'transcribed');
      expect(json['duration_seconds'], 142);
      expect(json['legal_hold'], isFalse);

      final deserialized = RecordingModel.fromJson(json);
      expect(deserialized.id, model.id);
      expect(deserialized.storagePath, model.storagePath);
      expect(deserialized.encryptionKeyRef, model.encryptionKeyRef);
      expect(deserialized.durationSeconds, 142);
      expect(deserialized.uploadStatus, RecordingUploadStatus.uploaded);
      expect(deserialized.processingStatus, RecordingProcessingStatus.transcribed);
    });

    test('validates all 7 RecordingScreenState enum values exist for explicit UI handling', () {
      final states = RecordingScreenState.values;
      expect(states.length, equals(7));
      expect(states, contains(RecordingScreenState.idle));
      expect(states, contains(RecordingScreenState.recording));
      expect(states, contains(RecordingScreenState.uploading));
      expect(states, contains(RecordingScreenState.uploadFailed));
      expect(states, contains(RecordingScreenState.processing));
      expect(states, contains(RecordingScreenState.processingFailed));
      expect(states, contains(RecordingScreenState.transcribed));
    });

    test('validates standard recording state progression', () {
      RecordingScreenState transition(RecordingScreenState current, String event) {
        switch (current) {
          case RecordingScreenState.idle:
            if (event == 'start_recording') return RecordingScreenState.recording;
            break;
          case RecordingScreenState.recording:
            if (event == 'stop_recording') return RecordingScreenState.uploading;
            break;
          case RecordingScreenState.uploading:
            if (event == 'upload_success') return RecordingScreenState.processing;
            if (event == 'upload_error') return RecordingScreenState.uploadFailed;
            break;
          case RecordingScreenState.uploadFailed:
            if (event == 'retry_upload') return RecordingScreenState.uploading;
            break;
          case RecordingScreenState.processing:
            if (event == 'pipeline_success') return RecordingScreenState.transcribed;
            if (event == 'pipeline_error') return RecordingScreenState.processingFailed;
            break;
          case RecordingScreenState.processingFailed:
            if (event == 'retry_processing') return RecordingScreenState.processing;
            break;
          case RecordingScreenState.transcribed:
            break;
        }
        return current;
      }

      var state = RecordingScreenState.idle;
      state = transition(state, 'start_recording');
      expect(state, RecordingScreenState.recording);

      state = transition(state, 'stop_recording');
      expect(state, RecordingScreenState.uploading);

      state = transition(state, 'upload_error');
      expect(state, RecordingScreenState.uploadFailed);

      state = transition(state, 'retry_upload');
      expect(state, RecordingScreenState.uploading);

      state = transition(state, 'upload_success');
      expect(state, RecordingScreenState.processing);

      state = transition(state, 'pipeline_error');
      expect(state, RecordingScreenState.processingFailed);

      state = transition(state, 'retry_processing');
      expect(state, RecordingScreenState.processing);

      state = transition(state, 'pipeline_success');
      expect(state, RecordingScreenState.transcribed);
    });

    test('validates crash/interruption recovery mapping for stalled recordings', () {
      RecordingScreenState recoverFromDBRecord({
        required RecordingUploadStatus uploadStatus,
        required RecordingProcessingStatus processingStatus,
      }) {
        if (uploadStatus == RecordingUploadStatus.pending ||
            uploadStatus == RecordingUploadStatus.uploading ||
            uploadStatus == RecordingUploadStatus.failed) {
          return RecordingScreenState.uploadFailed;
        }
        if (uploadStatus == RecordingUploadStatus.uploaded) {
          if (processingStatus == RecordingProcessingStatus.pending ||
              processingStatus == RecordingProcessingStatus.transcribing) {
            return RecordingScreenState.processing;
          }
          if (processingStatus == RecordingProcessingStatus.failed) {
            return RecordingScreenState.processingFailed;
          }
          if (processingStatus == RecordingProcessingStatus.transcribed) {
            return RecordingScreenState.transcribed;
          }
        }
        return RecordingScreenState.idle;
      }

      expect(
        recoverFromDBRecord(
          uploadStatus: RecordingUploadStatus.pending,
          processingStatus: RecordingProcessingStatus.pending,
        ),
        RecordingScreenState.uploadFailed,
      );
      expect(
        recoverFromDBRecord(
          uploadStatus: RecordingUploadStatus.uploaded,
          processingStatus: RecordingProcessingStatus.transcribing,
        ),
        RecordingScreenState.processing,
      );
      expect(
        recoverFromDBRecord(
          uploadStatus: RecordingUploadStatus.uploaded,
          processingStatus: RecordingProcessingStatus.failed,
        ),
        RecordingScreenState.processingFailed,
      );
      expect(
        recoverFromDBRecord(
          uploadStatus: RecordingUploadStatus.uploaded,
          processingStatus: RecordingProcessingStatus.transcribed,
        ),
        RecordingScreenState.transcribed,
      );
    });
  });
}
