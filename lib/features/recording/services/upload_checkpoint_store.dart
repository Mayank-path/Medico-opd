import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/upload_checkpoint.dart';
import '../models/upload_state.dart';

/// Durable local persistence store for upload checkpoints.
/// Uses atomic write-and-rename mechanics to prevent file corruption during OS process kills.
class UploadCheckpointStore {
  final Directory? _customDirectory;

  UploadCheckpointStore({Directory? directory}) : _customDirectory = directory;

  Future<Directory> _getCheckpointsDirectory() async {
    Directory baseDir;
    final custom = _customDirectory;
    if (custom != null) {
      baseDir = custom;
    } else {
      try {
        baseDir = await getApplicationDocumentsDirectory();
      } catch (_) {
        baseDir = Directory.systemTemp;
      }
    }

    final checkpointsDir = Directory('${baseDir.path}/upload_checkpoints');
    if (!await checkpointsDir.exists()) {
      await checkpointsDir.create(recursive: true);
    }
    return checkpointsDir;
  }

  File _getCheckpointFile(Directory dir, String sessionId) {
    return File('${dir.path}/$sessionId.json');
  }

  File _getTempFile(Directory dir, String sessionId) {
    return File('${dir.path}/$sessionId.json.tmp');
  }

  /// Atomically saves [checkpoint] to disk.
  Future<void> saveCheckpoint(UploadCheckpoint checkpoint) async {
    try {
      final dir = await _getCheckpointsDirectory();
      final targetFile = _getCheckpointFile(dir, checkpoint.recordingSessionId);
      final tempFile = _getTempFile(dir, checkpoint.recordingSessionId);

      final jsonString = jsonEncode(checkpoint.toJson());

      // 1. Write to temp file with immediate flush
      await tempFile.writeAsString(jsonString, flush: true);

      // 2. Atomic rename (Windows compatibility: delete target first if exists)
      if (Platform.isWindows && await targetFile.exists()) {
        await targetFile.delete();
      }
      await tempFile.rename(targetFile.path);
    } catch (e) {
      debugPrint('[UploadCheckpointStore] Failed to save checkpoint ${checkpoint.recordingSessionId}: $e');
      rethrow;
    }
  }

  /// Loads a checkpoint by [sessionId], or returns null if not found.
  Future<UploadCheckpoint?> loadCheckpoint(String sessionId) async {
    try {
      final dir = await _getCheckpointsDirectory();
      final file = _getCheckpointFile(dir, sessionId);
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      final map = jsonDecode(content) as Map<String, dynamic>;
      return UploadCheckpoint.fromJson(map);
    } catch (e) {
      debugPrint('[UploadCheckpointStore] Error loading checkpoint $sessionId: $e');
      return null;
    }
  }

  /// Deletes a checkpoint from disk.
  Future<void> deleteCheckpoint(String sessionId) async {
    try {
      final dir = await _getCheckpointsDirectory();
      final file = _getCheckpointFile(dir, sessionId);
      if (await file.exists()) {
        await file.delete();
      }
      final tempFile = _getTempFile(dir, sessionId);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    } catch (e) {
      debugPrint('[UploadCheckpointStore] Failed to delete checkpoint $sessionId: $e');
    }
  }

  /// Loads all stored upload checkpoints.
  Future<List<UploadCheckpoint>> loadAllCheckpoints() async {
    final checkpoints = <UploadCheckpoint>[];
    try {
      final dir = await _getCheckpointsDirectory();
      final files = dir.listSync().whereType<File>();

      for (final file in files) {
        if (!file.path.endsWith('.json')) continue;
        try {
          final content = await file.readAsString();
          final map = jsonDecode(content) as Map<String, dynamic>;
          checkpoints.add(UploadCheckpoint.fromJson(map));
        } catch (_) {
          // Skip corrupted or invalid files
        }
      }
    } catch (e) {
      debugPrint('[UploadCheckpointStore] Failed to load all checkpoints: $e');
    }
    return checkpoints;
  }

  /// Returns all checkpoints that are not yet in a completed terminal state.
  Future<List<UploadCheckpoint>> loadUnfinishedCheckpoints() async {
    final all = await loadAllCheckpoints();
    return all.where((c) => c.uploadState != UploadState.complete).toList();
  }
}
