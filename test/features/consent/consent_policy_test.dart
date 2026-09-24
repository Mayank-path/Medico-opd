import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/features/consent/models/consent_model.dart';
import 'package:medico_opd/features/consent/models/consent_policy.dart';
import 'package:medico_opd/features/consent/screens/consent_capture_screen.dart';
import 'package:medico_opd/features/consultation/models/consultation_model.dart';
import 'package:medico_opd/features/patient/models/patient_model.dart';

void main() {
  group('ConsentPolicy Model & Serialization Unit Tests', () {
    test('serializes and deserializes baseline policy correctly', () {
      final now = DateTime.now();
      final policy = ConsentPolicy(
        id: 'policy-test-01',
        version: 1,
        allowedMethods: [
          ConsentMethod.verbal,
          ConsentMethod.signature,
          ConsentMethod.otp,
        ],
        requiredEvidence: 'audio_sha256',
        pediatricVerificationRequired: false,
        effectiveFrom: now,
        notes: 'Test policy',
      );

      final json = policy.toJson();
      expect(json['id'], 'policy-test-01');
      expect(json['version'], 1);
      expect(json['allowed_methods'], ['verbal', 'signature', 'otp']);
      expect(json['pediatric_verification_required'], false);

      final deserialized = ConsentPolicy.fromJson(json);
      expect(deserialized.id, policy.id);
      expect(deserialized.version, 1);
      expect(deserialized.allowedMethods.length, 3);
      expect(deserialized.allowedMethods, contains(ConsentMethod.verbal));
      expect(deserialized.allowedMethods, contains(ConsentMethod.signature));
      expect(deserialized.allowedMethods, contains(ConsentMethod.otp));
      expect(deserialized.allowedMethods, isNot(contains(ConsentMethod.checkbox)));
    });

    test('parses PostgreSQL string array format {verbal,signature}', () {
      final json = {
        'id': 'policy-pg-01',
        'version': 2,
        'allowed_methods': '{verbal,signature}',
        'pediatric_verification_required': true,
        'effective_from': DateTime.now().toIso8601String(),
      };

      final policy = ConsentPolicy.fromJson(json);
      expect(policy.version, 2);
      expect(policy.allowedMethods.length, 2);
      expect(policy.allowedMethods, [ConsentMethod.verbal, ConsentMethod.signature]);
      expect(policy.pediatricVerificationRequired, true);
    });

    test('ConsentModel supports nullable guardian verification extension fields', () {
      final verifiedAt = DateTime.now();
      final consent = ConsentModel(
        id: 'consent-ext-01',
        clinicId: 'clinic-111',
        consultationId: 'cons-222',
        patientId: 'patient-333',
        consentStatus: ConsentStatus.granted,
        consentMethod: ConsentMethod.verbal,
        consentActor: ConsentActor.guardian,
        actorName: 'Asha Devi',
        actorRelationship: 'Mother',
        consentedAt: DateTime.now(),
        recordedBy: 'doc-444',
        verificationMethod: 'guardian_attestation_v1',
        verificationMetadata: {'witness': 'staff_nurse', 'id_checked': false},
        verifiedAt: verifiedAt,
      );

      final json = consent.toJson();
      expect(json['verification_method'], 'guardian_attestation_v1');
      expect(json['verification_metadata']?['witness'], 'staff_nurse');
      expect(json['verified_at'], verifiedAt.toIso8601String());

      final deserialized = ConsentModel.fromJson(json);
      expect(deserialized.verificationMethod, 'guardian_attestation_v1');
      expect(deserialized.verificationMetadata?['witness'], 'staff_nurse');
      expect(deserialized.verifiedAt, isNotNull);
    });
  });

  group('Policy-Driven Consent Screen Widget Tests (Step 3 & Adversarial)', () {
    final testPatient = PatientModel(
      id: 'patient-test-01',
      clinicId: 'clinic-01',
      fullName: 'Rahul Kumar',
      contactInfo: '9876543210',
      createdAt: DateTime.now(),
    );

    final testConsultation = ConsultationModel(
      id: 'cons-test-01',
      clinicId: 'clinic-01',
      patientId: 'patient-test-01',
      doctorId: 'doc-test-01',
      status: 'in_progress',
      startedAt: DateTime.now(),
      createdAt: DateTime.now(),
    );

    testWidgets('renders ONLY allowed_methods from active policy (e.g. signature only)', (tester) async {
      // Configure restrictive policy: only signature is allowed (e.g. counsel disallows verbal)
      final signatureOnlyPolicy = ConsentPolicy(
        id: 'policy-sig-only',
        version: 2,
        allowedMethods: [ConsentMethod.signature],
        pediatricVerificationRequired: false,
        effectiveFrom: DateTime.now(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ConsentCaptureScreen(
            patient: testPatient,
            consultation: testConsultation,
            doctorId: 'doc-test-01',
            initialPolicy: signatureOnlyPolicy,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify dropdown is rendered
      final dropdownFinder = find.byType(DropdownButtonFormField<ConsentMethod>);
      expect(dropdownFinder, findsOneWidget);

      // Verify selected value is Patient Signature
      expect(find.text(ConsentMethod.signature.label), findsOneWidget);

      // Tap dropdown to view menu items
      await tester.tap(dropdownFinder);
      await tester.pumpAndSettle();

      // Only 'Patient Signature' must appear in selectable menu
      expect(find.text(ConsentMethod.verbal.label), findsNothing);
      expect(find.text(ConsentMethod.checkbox.label), findsNothing);
      expect(find.text(ConsentMethod.otp.label), findsNothing);
      expect(find.text(ConsentMethod.other.label), findsNothing);
    });

    testWidgets('renders all 5 methods when policy allows all 5', (tester) async {
      final allMethodsPolicy = ConsentPolicy.fallbackDefault();

      await tester.pumpWidget(
        MaterialApp(
          home: ConsentCaptureScreen(
            patient: testPatient,
            consultation: testConsultation,
            doctorId: 'doc-test-01',
            initialPolicy: allMethodsPolicy,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final dropdownFinder = find.byType(DropdownButtonFormField<ConsentMethod>);
      expect(dropdownFinder, findsOneWidget);

      await tester.tap(dropdownFinder);
      await tester.pumpAndSettle();

      expect(find.text(ConsentMethod.verbal.label), findsWidgets);
      expect(find.text(ConsentMethod.checkbox.label), findsWidgets);
      expect(find.text(ConsentMethod.otp.label), findsWidgets);
      expect(find.text(ConsentMethod.signature.label), findsWidgets);
      expect(find.text(ConsentMethod.other.label), findsWidgets);
    });

    testWidgets('shows pediatric verification notice when pediatricVerificationRequired = true and guardian selected', (tester) async {
      final pediatricMandatePolicy = ConsentPolicy(
        id: 'policy-pediatric-strict',
        version: 3,
        allowedMethods: [ConsentMethod.verbal, ConsentMethod.signature],
        pediatricVerificationRequired: true,
        effectiveFrom: DateTime.now(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ConsentCaptureScreen(
            patient: testPatient,
            consultation: testConsultation,
            doctorId: 'doc-test-01',
            initialPolicy: pediatricMandatePolicy,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially Patient is selected -> no notice
      expect(find.byKey(const Key('pediatric_verification_notice')), findsNothing);

      // Switch actor to Guardian
      final guardianSegment = find.text('Guardian / Representative');
      await tester.tap(guardianSegment);
      await tester.pumpAndSettle();

      // Notice should now be rendered cleanly without crashing
      expect(find.byKey(const Key('pediatric_verification_notice')), findsOneWidget);
      expect(find.textContaining('Additional guardian identity verification required'), findsOneWidget);
    });
  });
}
