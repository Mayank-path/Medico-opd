import 'package:flutter_test/flutter_test.dart';
import 'package:medico_opd/features/ai_draft/models/ai_draft_model.dart';

void main() {
  group('AiDraftModel Unit Tests', () {
    final now = DateTime.now();

    final sampleStructuredJson = {
      'chief_complaint': 'Throat pain and dry cough for 3 days',
      'history_of_present_illness': 'Patient reports onset of sore throat followed by low grade fever and dry irritating cough. Denies shortness of breath.',
      'examination_findings': 'Throat congested, tonsils mildly enlarged without purulent exudates. Chest clear bilaterally.',
      'assessment_diagnosis': 'Acute viral pharyngitis',
      'plan': 'Warm saline gargles, hydration, rest. Prescribed symptomatic relief.',
      'prescriptions': [
        {
          'medicine': 'Paracetamol',
          'dosage': '650mg',
          'frequency': 'TDS as needed',
          'duration': '3 days',
        },
        {
          'medicine': 'Cetirizine',
          'dosage': '10mg',
          'frequency': 'OD at bedtime',
          'duration': '5 days',
        }
      ],
      'follow_up': 'Review after 3 days if fever persists or symptoms worsen',
    };

    test('serializes and deserializes structured AI draft correctly', () {
      final draft = AiDraftModel(
        id: 'draft-001',
        consultationId: 'cons-100',
        structuredJson: sampleStructuredJson,
        status: AiDraftStatus.aiDraft,
        modelUsed: 'claude-3-5-sonnet-20241022',
        promptVersion: 'v1.0.0',
      );

      final json = draft.toJson();
      expect(json['id'], 'draft-001');
      expect(json['consultation_id'], 'cons-100');
      expect(json['status'], 'ai_draft');
      expect(json['model_used'], 'claude-3-5-sonnet-20241022');
      expect(json['reviewed_by'], isNull);
      expect(json['reviewed_at'], isNull);

      final deserialized = AiDraftModel.fromJson(json);
      expect(deserialized.id, draft.id);
      expect(deserialized.structuredJson['chief_complaint'], 'Throat pain and dry cough for 3 days');
      final prescriptions = deserialized.structuredJson['prescriptions'] as List;
      expect(prescriptions.length, equals(2));
      expect(prescriptions[0]['medicine'], equals('Paracetamol'));
      expect(deserialized.isFinalized, isFalse);
      expect(deserialized.isRejected, isFalse);
    });

    test('validates lifecycle progression and doctor review transition', () {
      final draft = AiDraftModel(
        id: 'draft-002',
        consultationId: 'cons-100',
        structuredJson: sampleStructuredJson,
        status: AiDraftStatus.aiDraft,
        modelUsed: 'claude-3-5-sonnet-20241022',
        promptVersion: 'v1.0.0',
      );

      // Doctor review transition
      final doctorReviewed = draft.copyWith(
        status: AiDraftStatus.doctorReviewed,
        reviewedBy: 'doc-777',
        reviewedAt: now,
      );
      expect(doctorReviewed.status, AiDraftStatus.doctorReviewed);
      expect(doctorReviewed.reviewedBy, 'doc-777');

      // Finalized transition
      final finalizedTime = now.add(const Duration(minutes: 5));
      final finalized = doctorReviewed.copyWith(
        status: AiDraftStatus.finalized,
        finalizedBy: 'doc-777',
        finalizedAt: finalizedTime,
      );

      expect(finalized.status, AiDraftStatus.finalized);
      expect(finalized.isFinalized, isTrue);
      expect(finalized.finalizedBy, 'doc-777');
      expect(finalized.finalizedAt, finalizedTime);
    });

    test('validates rejection preserves draft without deletion (Invariant 10)', () {
      final draft = AiDraftModel(
        id: 'draft-003',
        consultationId: 'cons-100',
        structuredJson: sampleStructuredJson,
        status: AiDraftStatus.aiDraft,
        modelUsed: 'claude-3-5-sonnet-20241022',
        promptVersion: 'v1.0.0',
      );

      final rejectedTime = now.add(const Duration(minutes: 3));
      final rejected = draft.copyWith(
        status: AiDraftStatus.rejected,
        reviewedBy: 'doc-777',
        reviewedAt: rejectedTime,
      );

      expect(rejected.status, AiDraftStatus.rejected);
      expect(rejected.isRejected, isTrue);
      // The structured content must still be intact for clinical audit
      expect(rejected.structuredJson['chief_complaint'], isNotNull);
    });

    test('validates immutable finalized draft check matching DB trg_lock_finalized_ai_draft', () {
      bool canModifyDraft(AiDraftModel draft) {
        // Once finalized, draft cannot be modified
        return draft.status != AiDraftStatus.finalized;
      }

      final draftGenerated = AiDraftModel(
        id: 'draft-004',
        consultationId: 'cons-100',
        structuredJson: sampleStructuredJson,
        status: AiDraftStatus.aiDraft,
        modelUsed: 'claude-3-5-sonnet-20241022',
        promptVersion: 'v1.0.0',
      );

      final draftFinalized = draftGenerated.copyWith(
        status: AiDraftStatus.finalized,
        finalizedBy: 'doc-777',
        finalizedAt: now,
      );

      expect(canModifyDraft(draftGenerated), isTrue);
      expect(canModifyDraft(draftFinalized), isFalse);
    });
  });
}
