import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/core/config/env_config.dart';
import 'package:medico_opd/core/supabase/supabase_client_provider.dart';
import 'package:medico_opd/main.dart';

void main() {
  group('EnvConfig tests', () {
    test('EnvConfig unconfigured state detection', () {
      expect(EnvConfig.isConfigured, isFalse);
    });
  });

  group('Widget Smoke Tests', () {
    testWidgets('PlaceholderHomeScreen renders skeleton shell cleanly', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const mockResult = SupabaseInitResult(
        state: SupabaseState.unconfigured,
        message: 'Mock skeleton initialized for testing.',
      );

      await tester.pumpWidget(const MedicoApp(initialResult: mockResult));
      await tester.pumpAndSettle();

      // Verify title and key components are displayed
      expect(find.text('Medico OPD Assistant'), findsWidgets);
      expect(find.text('Foundation & Scaffolding Shell'), findsOneWidget);
      expect(find.text('Phase 000 | Task: TASK-000-01'), findsOneWidget);

      final pingButtonFinder = find.widgetWithText(
        FilledButton,
        'Verify Supabase Ping',
      );
      expect(pingButtonFinder, findsOneWidget);

      // Tap ping button and verify graceful prompt without crash
      await tester.tap(pingButtonFinder);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Supabase credentials unconfigured'),
        findsOneWidget,
      );
    });
  });
}
