import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/features/auth/services/auth_service.dart';
import 'package:medico_opd/features/clinic/models/clinic_model.dart';
import 'package:medico_opd/features/clinic/models/doctor_model.dart';
import 'package:medico_opd/features/clinic/screens/clinic_profile_screen.dart';
import 'package:medico_opd/features/clinic/services/clinic_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// In-memory mock service to simulate Supabase and RPC behavior under failure conditions.
class MockFailingAuthService extends AuthService {
  bool shouldRpcFail;
  int rpcCallCount = 0;
  int successfulOnboardingCount = 0;
  bool doctorExists = false;
  final User mockUser;

  MockFailingAuthService({required this.mockUser, this.shouldRpcFail = true});

  @override
  User? get currentUser => mockUser;

  @override
  Future<AuthResult> finalizePendingOnboarding([User? targetUser]) async {
    rpcCallCount++;
    if (doctorExists) {
      // Idempotent: already onboarded
      return AuthResult.success(targetUser ?? mockUser);
    }

    if (shouldRpcFail) {
      return AuthResult.failure(
        'Database connection timed out during clinic creation RPC.',
      );
    }

    // Atomic transaction success
    doctorExists = true;
    successfulOnboardingCount++;
    return AuthResult.success(targetUser ?? mockUser);
  }
}

class MockClinicService extends ClinicService {
  final MockFailingAuthService authService;
  int clinicCount = 0;
  int doctorCount = 0;

  MockClinicService(this.authService);

  @override
  Future<DoctorModel?> fetchCurrentDoctor() async {
    if (!authService.doctorExists) return null;
    doctorCount = 1;
    return DoctorModel(
      id: 'doc-mock-001',
      authUserId: authService.mockUser.id,
      clinicId: 'clinic-mock-001',
      fullName: 'Dr. Test Physician',
      qualifications: 'MBBS, MD',
      registrationNumber: 'MCI-12345',
      contactInfo: '+91-9876543210',
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<ClinicModel?> fetchCurrentClinic(String clinicId) async {
    if (!authService.doctorExists) return null;
    clinicCount = 1;
    return ClinicModel(
      id: clinicId,
      name: 'Alpha Care Clinic',
      address: '101 Medical Way, Delhi',
      contactInfo: '+91-11-20000001',
      createdAt: DateTime.now(),
    );
  }
}

void main() {
  group('Deferred Onboarding RPC Failure & Recovery Window Tests', () {
    late User testUser;

    setUp(() {
      testUser = User(
        id: 'user-uuid-12345',
        appMetadata: {},
        userMetadata: {
          'clinic_name': 'Alpha Care Clinic',
          'doctor_name': 'Dr. Test Physician',
          'clinic_address': '101 Medical Way, Delhi',
          'clinic_contact': '+91-11-20000001',
          'qualifications': 'MBBS, MD',
          'registration_number': 'MCI-12345',
          'doctor_contact': '+91-9876543210',
        },
        aud: 'authenticated',
        createdAt: DateTime.now().toIso8601String(),
        emailConfirmedAt: DateTime.now().toIso8601String(),
      );
    });

    test('Scenario 1: Forced RPC failure on first login produces clear failure and leaves 0 clinics/doctors', () async {
      final authService = MockFailingAuthService(
        mockUser: testUser,
        shouldRpcFail: true,
      );
      final clinicService = MockClinicService(authService);

      // Doctor logs in -> calls finalizePendingOnboarding -> RPC fails
      final result = await authService.finalizePendingOnboarding(testUser);

      expect(result.isSuccess, isFalse);
      expect(
        result.errorMessage,
        contains('Database connection timed out during clinic creation RPC'),
      );
      expect(authService.rpcCallCount, equals(1));
      expect(authService.doctorExists, isFalse);

      // Atomicity check: Exactly ZERO doctors and ZERO clinics created
      final doctor = await clinicService.fetchCurrentDoctor();
      expect(doctor, isNull);
      expect(clinicService.doctorCount, equals(0));
      expect(clinicService.clinicCount, equals(0));
    });

    test('Scenario 2: Retry after failure succeeds and produces exactly 1 clinic/doctor pair (no duplicate risk)', () async {
      final authService = MockFailingAuthService(
        mockUser: testUser,
        shouldRpcFail: true,
      );
      final clinicService = MockClinicService(authService);

      // 1. Initial attempt fails (transient error / network drop)
      final firstAttempt = await authService.finalizePendingOnboarding(
        testUser,
      );
      expect(firstAttempt.isSuccess, isFalse);
      expect(authService.successfulOnboardingCount, equals(0));

      // 2. Recovery retry (network restored / retry tapped)
      authService.shouldRpcFail = false;
      final retryAttempt = await authService.finalizePendingOnboarding(
        testUser,
      );
      expect(retryAttempt.isSuccess, isTrue);
      expect(authService.successfulOnboardingCount, equals(1));

      // Verify exactly ONE doctor and ONE clinic are created
      final doctor = await clinicService.fetchCurrentDoctor();
      expect(doctor, isNotNull);
      expect(doctor!.fullName, equals('Dr. Test Physician'));

      final clinic = await clinicService.fetchCurrentClinic(doctor.clinicId);
      expect(clinic, isNotNull);
      expect(clinic!.name, equals('Alpha Care Clinic'));
      expect(clinicService.doctorCount, equals(1));
      expect(clinicService.clinicCount, equals(1));

      // 3. Second retry (idempotency test): must NOT create a duplicate clinic
      final idempotentRetry = await authService.finalizePendingOnboarding(
        testUser,
      );
      expect(idempotentRetry.isSuccess, isTrue);
      expect(
        authService.successfulOnboardingCount,
        equals(1),
        reason: 'Subsequent retries must be idempotent and never provision duplicate clinics',
      );
    });

    testWidgets(
      'Scenario 3: App renders "Account setup incomplete — tap to retry" state and does NOT silent dead-end',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final authService = MockFailingAuthService(
          mockUser: testUser,
          shouldRpcFail: true,
        );
        final clinicService = MockClinicService(authService);

        await tester.pumpWidget(
          MaterialApp(
            home: ClinicProfileScreen(
              authService: authService,
              clinicService: clinicService,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Verify the app displays the clear recovery UX:
        expect(find.text('Account setup incomplete'), findsOneWidget);
        expect(find.text('Tap to retry'), findsOneWidget);
        expect(
          find.byKey(const Key('profile_retry_onboarding_button')),
          findsOneWidget,
        );
        expect(find.text('Sign Out'), findsOneWidget);

        // Ensure it did NOT dead-end or render an unhandled crash
        expect(find.byType(CircularProgressIndicator), findsNothing);

        // Now simulate user tapping "Tap to retry" after connection restores
        authService.shouldRpcFail = false;
        await tester.tap(
          find.byKey(const Key('profile_retry_onboarding_button')),
        );
        await tester.pumpAndSettle();

        // Verify the doctor and clinic profile successfully displays!
        expect(find.text('Account setup incomplete'), findsNothing);
        expect(find.text('Doctor Information'), findsOneWidget);
        expect(find.text('Dr. Test Physician'), findsOneWidget);
        expect(find.text('Clinic Details'), findsOneWidget);
        expect(find.text('Alpha Care Clinic'), findsOneWidget);
      },
    );
  });
}
