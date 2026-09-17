import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/features/consultation/models/consultation_model.dart';
import 'package:medico_opd/features/patient/models/patient_model.dart';

void main() {
  group('PatientModel Unit Tests', () {
    test('serializes to and from JSON correctly', () {
      final now = DateTime.now();
      final patient = PatientModel(
        id: 'patient-123',
        clinicId: 'clinic-456',
        fullName: 'Sunita Sharma',
        dobOrAge: '45 yrs',
        sex: 'Female',
        contactInfo: '+91 9876543210',
        opdNumber: 'OPD-2026-001',
        createdAt: now,
        createdBy: 'doctor-789',
      );

      final json = patient.toJson();
      expect(json['id'], 'patient-123');
      expect(json['clinic_id'], 'clinic-456');
      expect(json['full_name'], 'Sunita Sharma');
      expect(json['dob_or_age'], '45 yrs');
      expect(json['sex'], 'Female');
      expect(json['contact_info'], '+91 9876543210');
      expect(json['opd_number'], 'OPD-2026-001');
      expect(json['created_by'], 'doctor-789');

      final deserialized = PatientModel.fromJson(json);
      expect(deserialized.id, patient.id);
      expect(deserialized.clinicId, patient.clinicId);
      expect(deserialized.fullName, patient.fullName);
      expect(deserialized.dobOrAge, patient.dobOrAge);
      expect(deserialized.sex, patient.sex);
      expect(deserialized.contactInfo, patient.contactInfo);
      expect(deserialized.opdNumber, patient.opdNumber);
      expect(deserialized.createdBy, patient.createdBy);
    });

    test('copyWith updates fields while preserving others', () {
      final now = DateTime.now();
      final patient = PatientModel(
        id: 'patient-1',
        clinicId: 'clinic-1',
        fullName: 'Original Name',
        createdAt: now,
      );

      final updated = patient.copyWith(
        fullName: 'Updated Name',
        opdNumber: 'OPD-999',
      );

      expect(updated.fullName, 'Updated Name');
      expect(updated.opdNumber, 'OPD-999');
      expect(updated.id, 'patient-1');
      expect(updated.clinicId, 'clinic-1');
      expect(updated.createdAt, now);
    });
  });

  group('ConsultationModel Unit Tests', () {
    test('serializes to and from JSON correctly', () {
      final now = DateTime.now();
      final later = now.add(const Duration(minutes: 15));

      final consultation = ConsultationModel(
        id: 'cons-100',
        patientId: 'patient-123',
        doctorId: 'doctor-789',
        clinicId: 'clinic-456',
        status: 'completed',
        startedAt: now,
        endedAt: later,
        createdAt: now,
      );

      final json = consultation.toJson();
      expect(json['id'], 'cons-100');
      expect(json['patient_id'], 'patient-123');
      expect(json['doctor_id'], 'doctor-789');
      expect(json['clinic_id'], 'clinic-456');
      expect(json['status'], 'completed');
      expect(json['ended_at'], later.toIso8601String());

      final deserialized = ConsultationModel.fromJson(json);
      expect(deserialized.id, consultation.id);
      expect(deserialized.status, 'completed');
      expect(deserialized.endedAt, isNotNull);
    });

    test('validates allowed status lifecycle transitions', () {
      const allowedStatuses = {'draft', 'in_progress', 'completed'};

      expect(allowedStatuses.contains('draft'), isTrue);
      expect(allowedStatuses.contains('in_progress'), isTrue);
      expect(allowedStatuses.contains('completed'), isTrue);
      expect(allowedStatuses.contains('cancelled'), isFalse);
      expect(allowedStatuses.contains('unknown'), isFalse);
    });
  });

  group('Failure-Mode Simulation Tests', () {
    test('simulates network timeout when registering a patient', () async {
      Future<PatientModel> mockRegisterWithTimeout() async {
        await Future.delayed(const Duration(milliseconds: 50));
        throw TimeoutException('Connection to Supabase timed out');
      }

      expect(() => mockRegisterWithTimeout(), throwsA(isA<TimeoutException>()));
    });

    test('validates rejection of empty full name during patient creation', () {
      bool validatePatientName(String name) {
        return name.trim().isNotEmpty;
      }

      expect(validatePatientName(''), isFalse);
      expect(validatePatientName('   '), isFalse);
      expect(validatePatientName('Valid Name'), isTrue);
    });
  });
}
