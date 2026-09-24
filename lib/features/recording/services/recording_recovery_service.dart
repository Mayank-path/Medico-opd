import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class InterruptedRecordingCheckpoint {
  final String recordingId;
  final String consultationId;
  final String patientId;
  final String localFilePath;
  final DateTime recordedAt;

  const InterruptedRecordingCheckpoint({
    required this.recordingId,
    required this.consultationId,
    required this.patientId,
    required this.localFilePath,
    required this.recordedAt,
  });

  Map<String, dynamic> toJson() => {
    'recordingId': recordingId,
    'consultationId': consultationId,
    'patientId': patientId,
    'localFilePath': localFilePath,
    'recordedAt': recordedAt.toIso8601String(),
  };

  factory InterruptedRecordingCheckpoint.fromJson(Map<String, dynamic> json) {
    return InterruptedRecordingCheckpoint(
      recordingId: json['recordingId'] as String,
      consultationId: json['consultationId'] as String,
      patientId: json['patientId'] as String,
      localFilePath: json['localFilePath'] as String,
      recordedAt: DateTime.parse(json['recordedAt'] as String),
    );
  }
}

class RecordingRecoveryService {
  final Directory? _customDirectory;

  RecordingRecoveryService({Directory? directory})
      : _customDirectory = directory;

  File _getCheckpointFile(Directory baseDir) {
    return File('${baseDir.path}/interrupted_recording_checkpoint.json');
  }

  /// Saves an active recording session checkpoint to disk.
  Future<void> saveActiveCheckpoint(
    InterruptedRecordingCheckpoint checkpoint, {
    Directory? overrideDir,
  }) async {
    try {
      final dir = overrideDir ?? _customDirectory ?? Directory.systemTemp;
      final file = _getCheckpointFile(dir);
      await file.writeAsString(jsonEncode(checkpoint.toJson()));
      debugPrint('[RecordingRecoveryService] Checkpoint saved: ${checkpoint.recordingId}');
    } catch (e) {
      debugPrint('[RecordingRecoveryService] Failed to save checkpoint: $e');
    }
  }

  /// Checks if an interrupted recording session exists from a previous crash.
  Future<InterruptedRecordingCheckpoint?> checkInterruptedRecording({
    Directory? overrideDir,
  }) async {
    try {
      final dir = overrideDir ?? _customDirectory ?? Directory.systemTemp;
      final file = _getCheckpointFile(dir);
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      if (content.trim().isEmpty) return null;

      return InterruptedRecordingCheckpoint.fromJson(
        jsonDecode(content) as Map<String, dynamic>,
      );
    } catch (e) {
      debugPrint('[RecordingRecoveryService] Failed to read checkpoint: $e');
      return null;
    }
  }

  /// Discards interrupted recording file and checkpoint cleanly.
  /// Prevents orphaned partial audio on device.
  Future<void> clearCheckpointAndPurgeFile(
    InterruptedRecordingCheckpoint checkpoint, {
    Directory? overrideDir,
  }) async {
    try {
      // 1. Delete partial audio file
      final audioFile = File(checkpoint.localFilePath);
      if (await audioFile.exists()) {
        await audioFile.delete();
        debugPrint('[RecordingRecoveryService] Purged orphaned audio: ${checkpoint.localFilePath}');
      }

      // 2. Delete checkpoint file
      final dir = overrideDir ?? _customDirectory ?? Directory.systemTemp;
      final file = _getCheckpointFile(dir);
      if (await file.exists()) {
        await file.delete();
        debugPrint('[RecordingRecoveryService] Cleared checkpoint: ${checkpoint.recordingId}');
      }
    } catch (e) {
      debugPrint('[RecordingRecoveryService] Error purging checkpoint: $e');
    }
  }
}
