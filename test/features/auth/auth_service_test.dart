import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/features/auth/services/auth_service.dart';

void main() {
  group('AuthService Input Validation & Failure Mode Tests', () {
    late AuthService authService;

    setUp(() {
      authService = AuthService();
    });

    test('Empty or malformed email is rejected during signup', () async {
      final emptyResult = await authService.signUpWithClinic(
        email: '',
        password: 'password123',
        doctorName: 'Dr. Test',
        clinicName: 'Test Clinic',
      );
      expect(emptyResult.isSuccess, isFalse);
      expect(emptyResult.errorMessage, contains('valid email address'));

      final invalidEmailResult = await authService.signUpWithClinic(
        email: 'invalid-email',
        password: 'password123',
        doctorName: 'Dr. Test',
        clinicName: 'Test Clinic',
      );
      expect(invalidEmailResult.isSuccess, isFalse);
      expect(invalidEmailResult.errorMessage, contains('valid email address'));
    });

    test('Short password (< 6 chars) is rejected during signup', () async {
      final result = await authService.signUpWithClinic(
        email: 'doctor@example.com',
        password: '123',
        doctorName: 'Dr. Test',
        clinicName: 'Test Clinic',
      );
      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('at least 6 characters'));
    });

    test('Missing doctor name is rejected during signup', () async {
      final result = await authService.signUpWithClinic(
        email: 'doctor@example.com',
        password: 'password123',
        doctorName: '   ',
        clinicName: 'Test Clinic',
      );
      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('Doctor name is required'));
    });

    test('Missing clinic name is rejected during signup', () async {
      final result = await authService.signUpWithClinic(
        email: 'doctor@example.com',
        password: 'password123',
        doctorName: 'Dr. Test',
        clinicName: '   ',
      );
      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('Clinic name is required'));
    });

    test('Empty credentials rejected during signIn', () async {
      final emptyEmail = await authService.signIn(
        email: '',
        password: 'secretPassword',
      );
      expect(emptyEmail.isSuccess, isFalse);
      expect(emptyEmail.errorMessage, contains('cannot be empty'));

      final emptyPassword = await authService.signIn(
        email: 'doctor@test.com',
        password: '',
      );
      expect(emptyPassword.isSuccess, isFalse);
      expect(emptyPassword.errorMessage, contains('cannot be empty'));
    });
  });
}
