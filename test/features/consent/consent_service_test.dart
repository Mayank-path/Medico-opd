import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/features/consent/models/consent_model.dart';

void main() {
  group('ConsentModel Unit Tests', () {
    final now = DateTime.now();

    test('serializes and deserializes adult patient consent correctly', () {
      final consent = ConsentModel(
        id: 'consent-001',
        clinicId: 'clinic-555',
        consultationId: 'cons-100',
        patientId: 'patient-200',
        consentStatus: ConsentStatus.granted,
        consentMethod: ConsentMethod.verbal,
        consentActor: ConsentActor.patient,
        actorName: 'Sunita Sharma',
        actorRelationship: null,
        consentedAt: now,
        recordedBy: 'doc-777',
      );

      final json = consent.toJson();
      expect(json['id'], 'consent-001');
      expect(json['clinic_id'], 'clinic-555');
      expect(json['consultation_id'], 'cons-100');
      expect(json['patient_id'], 'patient-200');
      expect(json['consent_status'], 'granted');
      expect(json['consent_method'], 'verbal');
      expect(json['consent_actor'], 'patient');
      expect(json['actor_name'], 'Sunita Sharma');
      expect(json['actor_relationship'], isNull);
      expect(json['recorded_by'], 'doc-777');

      final deserialized = ConsentModel.fromJson(json);
      expect(deserialized.id, consent.id);
      expect(deserialized.consultationId, consent.consultationId);
      expect(deserialized.consentStatus, ConsentStatus.granted);
      expect(deserialized.consentActor, ConsentActor.patient);
      expect(deserialized.isGrantedAndActive, isTrue);
    });

    test('serializes and deserializes pediatric guardian consent with required relationship', () {
      final consent = ConsentModel(
        id: 'consent-002',
        clinicId: 'clinic-555',
        consultationId: 'cons-101',
        patientId: 'patient-pediatric-01',
        consentStatus: ConsentStatus.granted,
        consentMethod: ConsentMethod.signature,
        consentActor: ConsentActor.guardian,
        actorName: 'Ramesh Patel',
        actorRelationship: 'Father',
        consentedAt: now,
        recordedBy: 'doc-777',
        metadata: {'witness': 'Nurse Sunita'},
      );

      final json = consent.toJson();
      expect(json['consent_actor'], 'guardian');
      expect(json['actor_name'], 'Ramesh Patel');
      expect(json['actor_relationship'], 'Father');
      expect(json['metadata']?['witness'], 'Nurse Sunita');

      final deserialized = ConsentModel.fromJson(json);
      expect(deserialized.consentActor, ConsentActor.guardian);
      expect(deserialized.actorName, 'Ramesh Patel');
      expect(deserialized.actorRelationship, 'Father');
      expect(deserialized.isGrantedAndActive, isTrue);
    });

    test('validates guardian constraint logic matching DB chk_guardian_fields', () {
      bool validateGuardianFields(ConsentModel c) {
        if (c.consentActor == ConsentActor.guardian) {
          return c.actorName.trim().isNotEmpty &&
              c.actorRelationship != null &&
              c.actorRelationship!.trim().isNotEmpty;
        }
        return true;
      }

      final validGuardian = ConsentModel(
        id: 'c1',
        clinicId: 'c1',
        consultationId: 'c1',
        patientId: 'p1',
        consentStatus: ConsentStatus.granted,
        consentMethod: ConsentMethod.verbal,
        consentActor: ConsentActor.guardian,
        actorName: 'Anil Kumar',
        actorRelationship: 'Brother',
        consentedAt: now,
        recordedBy: 'd1',
      );

      final missingRelationship = ConsentModel(
        id: 'c2',
        clinicId: 'c2',
        consultationId: 'c2',
        patientId: 'p1',
        consentStatus: ConsentStatus.granted,
        consentMethod: ConsentMethod.verbal,
        consentActor: ConsentActor.guardian,
        actorName: 'Anil Kumar',
        actorRelationship: null,
        consentedAt: now,
        recordedBy: 'd1',
      );

      final missingName = ConsentModel(
        id: 'c3',
        clinicId: 'c3',
        consultationId: 'c3',
        patientId: 'p1',
        consentStatus: ConsentStatus.granted,
        consentMethod: ConsentMethod.verbal,
        consentActor: ConsentActor.guardian,
        actorName: '',
        actorRelationship: 'Mother',
        consentedAt: now,
        recordedBy: 'd1',
      );

      expect(validateGuardianFields(validGuardian), isTrue);
      expect(validateGuardianFields(missingRelationship), isFalse);
      expect(validateGuardianFields(missingName), isFalse);
    });

    test('validates consent status transition to revoked', () {
      final consent = ConsentModel(
        id: 'consent-rev',
        clinicId: 'clinic-555',
        consultationId: 'cons-100',
        patientId: 'patient-200',
        consentStatus: ConsentStatus.granted,
        consentMethod: ConsentMethod.verbal,
        consentActor: ConsentActor.patient,
        actorName: 'Sunita Sharma',
        consentedAt: now,
        recordedBy: 'doc-777',
      );

      expect(consent.isGrantedAndActive, isTrue);

      final revoked = ConsentModel(
        id: consent.id,
        clinicId: consent.clinicId,
        consultationId: consent.consultationId,
        patientId: consent.patientId,
        consentStatus: ConsentStatus.revoked,
        consentMethod: consent.consentMethod,
        consentActor: consent.consentActor,
        actorName: consent.actorName,
        consentedAt: consent.consentedAt,
        revokedAt: now.add(const Duration(minutes: 5)),
        recordedBy: consent.recordedBy,
        metadata: {'revocation_reason': 'Patient requested recording stop mid-consultation'},
      );

      expect(revoked.consentStatus, ConsentStatus.revoked);
      expect(revoked.isGrantedAndActive, isFalse);
      expect(revoked.revokedAt, isNotNull);
      expect(revoked.metadata['revocation_reason'], contains('Patient requested recording stop'));
    });
  });
}
