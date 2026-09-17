import 'dart:io';

import 'package:flutter/foundation.dart';

/// Lightweight coordination server for deterministic CI screenshot capture.
/// Only active in debug mode when `CI_CAPTURE_FLOW=true`.
/// Provides `/status` to verify current active screen and `/next` to trigger navigation.
class CiFlowCoordinator {
  static HttpServer? _server;
  static String _currentScreen = 'initializing';
  static VoidCallback? _onAdvance;
  static bool _initialized = false;

  static String get currentScreen => _currentScreen;

  static void init() async {
    if (_initialized) return;
    if (!kDebugMode ||
        !const bool.fromEnvironment('CI_CAPTURE_FLOW', defaultValue: false)) {
      return;
    }
    _initialized = true;

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 8888);
      debugPrint('[CiFlowCoordinator] Listening on port 8888');

      _server!.listen((HttpRequest request) async {
        request.response.headers.add('Access-Control-Allow-Origin', '*');
        request.response.headers.add('Content-Type', 'text/plain');

        if (request.uri.path == '/status') {
          request.response.statusCode = 200;
          request.response.write(_currentScreen);
          await request.response.close();
          return;
        }

        if (request.uri.path == '/next') {
          final advanceCb = _onAdvance;
          if (advanceCb != null) {
            _onAdvance = null;
            advanceCb();
            request.response.statusCode = 200;
            request.response.write('ADVANCED_FROM_$_currentScreen');
          } else {
            request.response.statusCode = 200;
            request.response.write('NO_ADVANCE_HANDLER_FOR_$_currentScreen');
          }
          await request.response.close();
          return;
        }

        request.response.statusCode = 404;
        request.response.write('NOT_FOUND');
        await request.response.close();
      });
    } catch (e) {
      debugPrint('[CiFlowCoordinator] Failed to bind server: $e');
    }
  }

  static void registerScreen({
    required String screenName,
    VoidCallback? onAdvance,
  }) {
    if (!kDebugMode ||
        !const bool.fromEnvironment('CI_CAPTURE_FLOW', defaultValue: false)) {
      return;
    }
    _currentScreen = screenName;
    _onAdvance = onAdvance;
    debugPrint(
      '[CiFlowCoordinator] Active screen set to: $screenName (hasAdvance: ${onAdvance != null})',
    );
  }
}
