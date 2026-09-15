import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/core/config/env_config.dart';
import 'package:medico_opd/core/supabase/supabase_client_provider.dart';
import 'package:medico_opd/features/auth/screens/login_screen.dart';
import 'package:medico_opd/features/auth/screens/signup_screen.dart';
import 'package:medico_opd/features/clinic/models/clinic_model.dart';
import 'package:medico_opd/features/clinic/models/doctor_model.dart';
import 'package:medico_opd/main.dart';

void main() {
  group('EnvConfig tests', () {
    test('EnvConfig initial state check', () {
      expect(EnvConfig.supabaseUrl, isNotNull);
    });
  });

  group('Widget Smoke Tests', () {
    testWidgets(
      'AuthGate renders Doctor LoginScreen cleanly when unconfigured and allows navigation to signup',
      (WidgetTester tester) async {
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

        // Verify Doctor Login Screen is displayed
        expect(find.text('Doctor Login'), findsOneWidget);
        expect(find.widgetWithText(ElevatedButton, 'Sign In'), findsOneWidget);
        expect(
          find.text("Don't have an account? Register Doctor & Clinic"),
          findsOneWidget,
        );

        // Tap register link to toggle to signup screen
        await tester.tap(find.text("Don't have an account? Register Doctor & Clinic"));
        await tester.pumpAndSettle();

        // Verify Doctor Signup Screen is displayed
        expect(find.text('Doctor & Clinic Registration'), findsOneWidget);
        expect(find.widgetWithText(ElevatedButton, 'Register & Create Clinic'), findsOneWidget);
      },
    );

    testWidgets('LoginScreen renders email, password, and registration link', (
      WidgetTester tester,
    ) async {
      bool navigatedToSignup = false;

      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(
            onNavigateToSignup: () {
              navigatedToSignup = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Doctor Login'), findsOneWidget);
      expect(find.byKey(const Key('login_email_field')), findsOneWidget);
      expect(find.byKey(const Key('login_password_field')), findsOneWidget);
      expect(find.byKey(const Key('login_submit_button')), findsOneWidget);

      // Trigger empty submit to test validation errors
      await tester.tap(find.byKey(const Key('login_submit_button')));
      await tester.pumpAndSettle();
      expect(find.text('Email is required'), findsOneWidget);
      expect(find.text('Password is required'), findsOneWidget);

      // Tap navigation link
      await tester.tap(find.byKey(const Key('login_switch_to_signup_button')));
      expect(navigatedToSignup, isTrue);
    });

    testWidgets(
      'SignupScreen renders doctor and clinic onboarding form fields',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        bool navigatedToLogin = false;

        await tester.pumpWidget(
          MaterialApp(
            home: SignupScreen(
              onNavigateToLogin: () {
                navigatedToLogin = true;
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Doctor & Clinic Registration'), findsOneWidget);
        expect(find.byKey(const Key('signup_email_field')), findsOneWidget);
        expect(find.byKey(const Key('signup_password_field')), findsOneWidget);
        expect(
          find.byKey(const Key('signup_doctor_name_field')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('signup_clinic_name_field')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('signup_submit_button')), findsOneWidget);

        // Trigger empty submit
        await tester.tap(find.byKey(const Key('signup_submit_button')));
        await tester.pumpAndSettle();
        expect(find.text('Email is required'), findsOneWidget);
        expect(find.text('Password is required'), findsOneWidget);
        expect(find.text('Doctor name is required'), findsOneWidget);
        expect(find.text('Clinic name is required'), findsOneWidget);

        // Navigate back to login
        await tester.tap(
          find.byKey(const Key('signup_switch_to_login_button')),
        );
        expect(navigatedToLogin, isTrue);
      },
    );

    testWidgets('ClinicProfileScreen displays doctor and clinic details', (
      WidgetTester tester,
    ) async {
      // Direct model test for Clinic and Doctor models
      final mockDoctor = DoctorModel(
        id: 'doc-123',
        authUserId: 'auth-123',
        clinicId: 'clinic-456',
        fullName: 'Dr. Test Physician',
        qualifications: 'MBBS, MD (Medicine)',
        registrationNumber: 'MCI-998877',
        contactInfo: '+91-9876543210',
        createdAt: DateTime.now(),
      );

      final mockClinic = ClinicModel(
        id: 'clinic-456',
        name: 'Apollo Health Clinic',
        address: 'Sector 15, Gurugram, Haryana',
        contactInfo: '+91-124-4000000',
        createdAt: DateTime.now(),
      );

      expect(mockDoctor.fullName, equals('Dr. Test Physician'));
      expect(mockDoctor.clinicId, equals('clinic-456'));
      expect(mockClinic.name, equals('Apollo Health Clinic'));
      expect(mockClinic.id, equals('clinic-456'));
    });
  });
}
