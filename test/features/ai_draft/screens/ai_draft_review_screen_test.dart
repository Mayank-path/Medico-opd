import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/features/ai_draft/models/ai_draft_model.dart';
import 'package:medico_opd/features/ai_draft/screens/ai_draft_review_screen.dart';
import 'package:medico_opd/features/ai_draft/services/ai_draft_service.dart';
import 'package:medico_opd/features/consultation/models/consultation_model.dart';
import 'package:medico_opd/features/patient/models/patient_model.dart';

class FakeAiDraftService extends AiDraftService {
  AiDraftModel? draft;
  bool updateReviewCalled = false;
  bool rejectCalled = false;
  bool finalizeCalled = false;

  FakeAiDraftService({this.draft});

  @override
  Future<AiDraftModel?> fetchDraftForConsultation(String consultationId) async {
    return draft;
  }

  @override
  Future<AiDraftModel> updateDraftReview({
    required String draftId,
    required Map<String, dynamic> updatedJson,
    required String doctorId,
    int? expectedRevision,
  }) async {
    updateReviewCalled = true;
    draft = draft!.copyWith(
      structuredJson: updatedJson,
      status: AiDraftStatus.doctorReviewed,
      reviewedBy: doctorId,
      reviewedAt: DateTime.now(),
      revision: (expectedRevision ?? draft!.revision) + 1,
    );
    return draft!;
  }

  @override
  Future<AiDraftModel> rejectDraft({
    required String draftId,
    required String doctorId,
    int? expectedRevision,
  }) async {
    rejectCalled = true;
    draft = draft!.copyWith(
      status: AiDraftStatus.rejected,
      reviewedBy: doctorId,
      reviewedAt: DateTime.now(),
      revision: (expectedRevision ?? draft!.revision) + 1,
    );
    return draft!;
  }

  @override
  Future<AiDraftModel> finalizeDraft({
    required String draftId,
    required String doctorId,
    int? expectedRevision,
  }) async {
    finalizeCalled = true;
    draft = draft!.copyWith(
      status: AiDraftStatus.finalized,
      finalizedBy: doctorId,
      finalizedAt: DateTime.now(),
      revision: (expectedRevision ?? draft!.revision) + 1,
    );
    return draft!;
  }
}

void main() {
  final samplePatient = PatientModel(
    id: 'pat-12345678',
    clinicId: 'clinic-1',
    fullName: 'Jane Doe',
    dobOrAge: '34',
    sex: 'Female',
    contactInfo: '+919876543210',
    createdAt: DateTime.now(),
  );

  final sampleConsultation = ConsultationModel(
    id: 'cons-101',
    clinicId: 'clinic-1',
    patientId: 'pat-12345678',
    doctorId: 'doc-007',
    status: 'in_progress',
    startedAt: DateTime.now(),
    createdAt: DateTime.now(),
  );

  final sampleStructured = {
    'chief_complaints': ['Throat pain', 'Fever for 2 days'],
    'history_of_present_illness': 'Patient has mild fever and pain on swallowing.',
    'examination_findings': ['Erythematous posterior pharynx', 'No exudates'],
    'provisional_diagnosis': ['Acute Pharyngitis'],
    'medications': [
      {
        'drug_name': 'Amoxicillin',
        'dosage': '500mg',
        'frequency': '1-0-1',
        'duration': '5 days',
        'instructions': 'After food',
      }
    ],
    'investigations_ordered': ['CBC with Differential'],
    'follow_up_advice': 'Drink warm fluids and return if fever persists.',
  };

  group('AiDraftReviewScreen Widget Tests', () {
    testWidgets('renders loading and then displays AI draft fields and amber warning banner',
        (tester) async {
      final fakeService = FakeAiDraftService(
        draft: AiDraftModel(
          id: 'draft-1',
          consultationId: 'cons-101',
          structuredJson: sampleStructured,
          status: AiDraftStatus.aiDraft,
          modelUsed: 'claude-3-5-sonnet',
          promptVersion: 'v1.0.0',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AiDraftReviewScreen(
            patient: samplePatient,
            consultation: sampleConsultation,
            doctorId: 'doc-007',
            aiDraftService: fakeService,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Banner verifies AI-Assisted Draft warning
      expect(find.byKey(const Key('draft_status_banner')), findsOneWidget);
      expect(find.textContaining('AI-Assisted Draft'), findsOneWidget);

      // Verify fields populated
      expect(find.textContaining('Throat pain'), findsOneWidget);
      expect(find.textContaining('Patient has mild fever'), findsOneWidget);
      expect(find.textContaining('Acute Pharyngitis'), findsOneWidget);
      expect(find.text('Amoxicillin'), findsOneWidget);

      // Verify action buttons present
      expect(find.byKey(const Key('save_review_button')), findsOneWidget);
      expect(find.byKey(const Key('reject_draft_button')), findsOneWidget);
      expect(find.byKey(const Key('finalize_record_button')), findsOneWidget);
    });

    testWidgets('doctor can edit complaints and save review', (tester) async {
      final fakeService = FakeAiDraftService(
        draft: AiDraftModel(
          id: 'draft-1',
          consultationId: 'cons-101',
          structuredJson: sampleStructured,
          status: AiDraftStatus.aiDraft,
          modelUsed: 'claude-3-5-sonnet',
          promptVersion: 'v1.0.0',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AiDraftReviewScreen(
            patient: samplePatient,
            consultation: sampleConsultation,
            doctorId: 'doc-007',
            aiDraftService: fakeService,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Enter new text in Chief Complaints
      final complaintsField = find.byKey(const Key('chief_complaints_field'));
      await tester.enterText(complaintsField, 'Severe throat pain\nHigh fever');
      await tester.pump();

      // Tap Save Review
      final saveBtn = find.byKey(const Key('save_review_button'));
      await tester.ensureVisible(saveBtn);
      await tester.pumpAndSettle();
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      expect(fakeService.updateReviewCalled, isTrue);
      expect(fakeService.draft!.status, equals(AiDraftStatus.doctorReviewed));
      expect(find.textContaining('Doctor Reviewed'), findsOneWidget);
    });

    testWidgets('doctor finalize action shows confirmation dialog and locks the record',
        (tester) async {
      final fakeService = FakeAiDraftService(
        draft: AiDraftModel(
          id: 'draft-1',
          consultationId: 'cons-101',
          structuredJson: sampleStructured,
          status: AiDraftStatus.doctorReviewed,
          modelUsed: 'claude-3-5-sonnet',
          promptVersion: 'v1.0.0',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AiDraftReviewScreen(
            patient: samplePatient,
            consultation: sampleConsultation,
            doctorId: 'doc-007',
            aiDraftService: fakeService,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Tap Finalize button
      final finalizeBtn = find.byKey(const Key('finalize_record_button'));
      await tester.ensureVisible(finalizeBtn);
      await tester.pumpAndSettle();
      await tester.tap(finalizeBtn);
      await tester.pumpAndSettle();

      // Confirmation dialog should appear with warning
      expect(find.text('Finalize & Lock Record'), findsOneWidget);
      expect(find.textContaining('permanently locks this record'), findsOneWidget);

      // Confirm
      await tester.tap(find.text('Confirm Finalization'));
      await tester.pumpAndSettle();

      expect(fakeService.finalizeCalled, isTrue);
      expect(fakeService.draft!.isFinalized, isTrue);

      // Locked record indicator should appear
      expect(find.byKey(const Key('locked_record_notice')), findsOneWidget);
      expect(find.textContaining('permanently locked in the database'), findsOneWidget);

      // Save and Finalize buttons should no longer be rendered
      expect(find.byKey(const Key('save_review_button')), findsNothing);
      expect(find.byKey(const Key('finalize_record_button')), findsNothing);
    });

    testWidgets('renders empty state when no draft exists yet', (tester) async {
      final fakeService = FakeAiDraftService(draft: null);

      await tester.pumpWidget(
        MaterialApp(
          home: AiDraftReviewScreen(
            patient: samplePatient,
            consultation: sampleConsultation,
            doctorId: 'doc-007',
            aiDraftService: fakeService,
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('No AI Draft Available Yet'), findsOneWidget);
      expect(find.text('Check Status'), findsOneWidget);
    });
  });
}
