import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/recording_errors.dart';
import '../models/recording_session_model.dart';

/// Durable local persistence store for recording sessions.
/// Employs atomic write-and-rename mechanics to prevent file corruption during OS kills.
class RecordingSessionStore {
  final Directory? _customDirectory;

  RecordingSessionStore({Directory? directory}) : _customDirectory = directory;

  /// Resolves the base directory where recording sessions are stored.
  Future<Directory> _getSessionsDirectory() async {
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

    final sessionsDir = Directory('${baseDir.path}/recording_sessions');
    if (!await sessionsDir.exists()) {
      await sessionsDir.create(recursive: true);
    }
    return sessionsDir;
  }

  File _getSessionFile(Directory dir, String sessionId) {
    return File('${dir.path}/$sessionId.json');
  }

  File _getTempSessionFile(Directory dir, String sessionId) {
    return File('${dir.path}/$sessionId.json.tmp');
  }

  /// Atomically saves [session] to disk.
  /// Writes to a temporary file first, then atomically renames to the canonical target.
  Future<void> saveSession(RecordingSessionModel session) async {
    try {
      final dir = await _getSessionsDirectory();
      final targetFile = _getSessionFile(dir, session.recordingSessionId);
      final tempFile = _getTempSessionFile(dir, session.recordingSessionId);

      final jsonString = jsonEncode(session.toJson());

      // 1. Write payload to temporary file with flush
      await tempFile.writeAsString(jsonString, flush: true);

      // 2. Atomic rename to target file (replaces target if it exists)
      if (Platform.isWindows && await targetFile.exists()) {
        // Windows File.rename() fails if destination already exists
        await targetFile.delete();
      }
      await tempFile.rename(targetFile.path);

      debugPrint('[RecordingSessionStore] Persisted session: ${session.recordingSessionId} (${session.state.toCanonicalString()})');
    } catch (e) {
      debugPrint('[RecordingSessionStore] Failed to save session ${session.recordingSessionId}: $e');
      throw RecordingPersistenceException(
        'Failed to save recording session to disk',
        cause: e,
      );
    }
  }

  /// Loads a specific session by [sessionId].
  Future<RecordingSessionModel?> loadSession(String sessionId) async {
    try {
      final dir = await _getSessionsDirectory();
      final file = _getSessionFile(dir, sessionId);

      if (!await file.exists()) {
        return null;
      }

      final content = await file.readAsString();
      if (content.trim().isEmpty) {
        return null;
      }

      final json = jsonDecode(content) as Map<String, dynamic>;
      return RecordingSessionModel.fromJson(json);
    } catch (e) {
      debugPrint('[RecordingSessionStore] Failed to load session $sessionId: $e');
      throw RecordingPersistenceException(
        'Failed to load recording session from disk',
        cause: e,
      );
    }
  }

  /// Loads all stored recording sessions.
  Future<List<RecordingSessionModel>> loadAllSessions() async {
    try {
      final dir = await _getSessionsDirectory();
      final sessions = <RecordingSessionModel>[];

      final entities = dir.listSync();
      for (final entity in entities) {
        if (entity is File && entity.path.endsWith('.json') && !entity.path.endsWith('.tmp')) {
          try {
            final content = await entity.readAsString();
            if (content.trim().isNotEmpty) {
              final json = jsonDecode(content) as Map<String, dynamic>;
              sessions.add(RecordingSessionModel.fromJson(json));
            }
          } catch (itemErr) {
            debugPrint('[RecordingSessionStore] Error parsing session file ${entity.path}: $itemErr');
          }
        }
      }

      // Sort by updatedAt descending (newest first)
      sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return sessions;
    } catch (e) {
      debugPrint('[RecordingSessionStore] Failed to load all sessions: $e');
      throw RecordingPersistenceException(
        'Failed to read sessions directory',
        cause: e,
      );
    }
  }

  /// Finds the active (in-flight) session for a specific [consultationId], if one exists.
  Future<RecordingSessionModel?> loadActiveSessionForConsultation(String consultationId) async {
    final allSessions = await loadAllSessions();
    for (final session in allSessions) {
      if (session.consultationId == consultationId && session.state.isInFlight) {
        return session;
      }
    }
    return null;
  }

  /// Removes the persisted session file for [sessionId].
  Future<void> deleteSession(String sessionId) async {
    try {
      final dir = await _getSessionsDirectory();
      final file = _getSessionFile(dir, sessionId);
      if (await file.exists()) {
        await file.delete();
        debugPrint('[RecordingSessionStore] Deleted session: $sessionId');
      }
    } catch (e) {
      debugPrint('[RecordingSessionStore] Error deleting session $sessionId: $e');
    }
  }

  /// Clears all session files from disk (used primarily for test cleanup).
  Future<void> clearAllSessions() async {
    try {
      final dir = await _getSessionsDirectory();
      if (await dir.exists()) {
        final entities = dir.listSync();
        for (final entity in entities) {
          if (entity is File) {
            await entity.delete();
          }
        }
      }
    } catch (e) {
      debugPrint('[RecordingSessionStore] Error clearing all sessions: $e');
    }
  }
}
