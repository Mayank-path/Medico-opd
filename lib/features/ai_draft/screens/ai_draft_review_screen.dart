import 'package:flutter/material.dart';

import '../../consultation/models/consultation_model.dart';
import '../../patient/models/patient_model.dart';
import '../models/ai_draft_model.dart';
import '../services/ai_draft_service.dart';

class AiDraftReviewScreen extends StatefulWidget {
  final PatientModel patient;
  final ConsultationModel consultation;
  final String doctorId;
  final AiDraftModel? initialDraft;
  final AiDraftService? aiDraftService;

  const AiDraftReviewScreen({
    super.key,
    required this.patient,
    required this.consultation,
    required this.doctorId,
    this.initialDraft,
    this.aiDraftService,
  });

  @override
  State<AiDraftReviewScreen> createState() => _AiDraftReviewScreenState();
}

class _AiDraftReviewScreenState extends State<AiDraftReviewScreen> {
  late final AiDraftService _draftService;

  AiDraftModel? _draft;
  bool _isLoading = false;
  bool _isSaving = false;
  String? _errorMessage;

  // Controllers for editable fields
  late final TextEditingController _complaintsController;
  late final TextEditingController _hpiController;
  late final TextEditingController _examinationController;
  late final TextEditingController _diagnosisController;
  late final TextEditingController _investigationsController;
  late final TextEditingController _followUpController;

  // Editable medications list
  List<Map<String, String>> _medications = [];

  static const Color brandTeal = Color(0xFF007A78);

  @override
  void initState() {
    super.initState();
    _draftService = widget.aiDraftService ?? AiDraftService();
    _complaintsController = TextEditingController();
    _hpiController = TextEditingController();
    _examinationController = TextEditingController();
    _diagnosisController = TextEditingController();
    _investigationsController = TextEditingController();
    _followUpController = TextEditingController();

    if (widget.initialDraft != null) {
      _loadFromDraft(widget.initialDraft!);
    } else {
      _fetchDraft();
    }
  }

  @override
  void dispose() {
    _complaintsController.dispose();
    _hpiController.dispose();
    _examinationController.dispose();
    _diagnosisController.dispose();
    _investigationsController.dispose();
    _followUpController.dispose();
    super.dispose();
  }

  void _loadFromDraft(AiDraftModel draft) {
    _draft = draft;
    final json = draft.structuredJson;

    final complaints = (json['chief_complaints'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];
    _complaintsController.text = complaints.join('\n');

    _hpiController.text = json['history_of_present_illness']?.toString() ?? '';

    final exams = (json['examination_findings'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];
    _examinationController.text = exams.join('\n');

    final diagnoses = (json['provisional_diagnosis'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];
    _diagnosisController.text = diagnoses.join('\n');

    final investigations = (json['investigations_ordered'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];
    _investigationsController.text = investigations.join('\n');

    _followUpController.text = json['follow_up_advice']?.toString() ?? '';

    final meds = (json['medications'] as List<dynamic>?) ?? [];
    _medications = meds.map((m) {
      if (m is Map) {
        return {
          'drug_name': m['drug_name']?.toString() ?? '',
          'dosage': m['dosage']?.toString() ?? '',
          'frequency': m['frequency']?.toString() ?? '',
          'duration': m['duration']?.toString() ?? '',
          'instructions': m['instructions']?.toString() ?? '',
        };
      }
      return <String, String>{};
    }).toList();
  }

  Map<String, dynamic> _collectStructuredJson() {
    final rawComplaints = _complaintsController.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final rawExams = _examinationController.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final rawDiagnoses = _diagnosisController.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final rawInvestigations = _investigationsController.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    return {
      'chief_complaints': rawComplaints,
      'history_of_present_illness': _hpiController.text.trim(),
      'examination_findings': rawExams,
      'provisional_diagnosis': rawDiagnoses,
      'medications': _medications,
      'investigations_ordered': rawInvestigations,
      'follow_up_advice': _followUpController.text.trim(),
      if (_draft?.structuredJson['model_metadata'] != null)
        'model_metadata': _draft!.structuredJson['model_metadata'],
    };
  }

  Future<void> _fetchDraft() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final draft =
          await _draftService.fetchDraftForConsultation(widget.consultation.id);
      if (mounted) {
        setState(() {
          _isLoading = false;
          if (draft != null) {
            _loadFromDraft(draft);
          } else {
            _draft = null;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load AI draft: $e';
        });
      }
    }
  }

  Future<void> _saveReview() async {
    if (_draft == null) return;

    setState(() {
      _isSaving = true;
    });

    try {
      final updatedJson = _collectStructuredJson();
      final updated = await _draftService.updateDraftReview(
        draftId: _draft!.id,
        updatedJson: updatedJson,
        doctorId: widget.doctorId,
        expectedRevision: _draft!.revision,
      );

      if (mounted) {
        setState(() {
          _isSaving = false;
          _loadFromDraft(updated);
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Doctor review saved successfully.'),
            backgroundColor: brandTeal,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });

        final isConflict = e is ConcurrentModificationException ||
            e.toString().contains('CONCURRENT_MODIFICATION');
        final msg = isConflict
            ? 'Conflict: This draft was modified in another session. Please reload.'
            : 'Failed to save review: $e';

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    }
  }

  Future<void> _rejectDraft() async {
    if (_draft == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject Clinical Draft?'),
        content: const Text(
          'This will mark the AI draft as rejected. The draft will be preserved in the audit log for compliance, but will not be used as clinical documentation.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
            ),
            child: const Text('Reject Draft'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _isSaving = true;
    });

    try {
      final rejected = await _draftService.rejectDraft(
        draftId: _draft!.id,
        doctorId: widget.doctorId,
        expectedRevision: _draft!.revision,
      );

      if (mounted) {
        setState(() {
          _isSaving = false;
          _loadFromDraft(rejected);
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Draft rejected.'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });

        final isConflict = e is ConcurrentModificationException ||
            e.toString().contains('CONCURRENT_MODIFICATION');
        final msg = isConflict
            ? 'Conflict: Draft was modified in another session. Please reload.'
            : 'Failed to reject draft: $e';

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    }
  }

  Future<void> _finalizeRecord() async {
    if (_draft == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.lock, color: brandTeal),
            SizedBox(width: 8),
            Text('Finalize & Lock Record'),
          ],
        ),
        content: const Text(
          'Finalizing approves this clinical document as the authoritative medical record. '
          'Once finalized, the database permanently locks this record against any further modifications.\n\n'
          'Confirm that you have reviewed and verified all diagnosis, prescriptions, and instructions.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.check_circle),
            label: const Text('Confirm Finalization'),
            style: ElevatedButton.styleFrom(
              backgroundColor: brandTeal,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _isSaving = true;
    });

    try {
      // Step 1: Save any pending doctor edits first using current revision
      final updatedJson = _collectStructuredJson();
      final reviewed = await _draftService.updateDraftReview(
        draftId: _draft!.id,
        updatedJson: updatedJson,
        doctorId: widget.doctorId,
        expectedRevision: _draft!.revision,
      );

      // Step 2: Finalize and trigger permanent database lock using updated revision
      final finalized = await _draftService.finalizeDraft(
        draftId: reviewed.id,
        doctorId: widget.doctorId,
        expectedRevision: reviewed.revision,
      );

      if (mounted) {
        setState(() {
          _isSaving = false;
          _loadFromDraft(finalized);
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Clinical record finalized and permanently locked.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });

        final isConflict = e is ConcurrentModificationException ||
            e.toString().contains('CONCURRENT_MODIFICATION');
        final msg = isConflict
            ? 'Conflict: Draft was modified in another session. Please reload.'
            : 'Failed to finalize record: $e';

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    }
  }

  void _addMedicationDialog() {
    final nameCtl = TextEditingController();
    final dosageCtl = TextEditingController();
    final freqCtl = TextEditingController();
    final durationCtl = TextEditingController();
    final instructionsCtl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Medication'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtl,
                decoration: const InputDecoration(labelText: 'Drug Name *'),
              ),
              TextField(
                controller: dosageCtl,
                decoration: const InputDecoration(labelText: 'Dosage (e.g. 500mg)'),
              ),
              TextField(
                controller: freqCtl,
                decoration: const InputDecoration(labelText: 'Frequency (e.g. 1-0-1)'),
              ),
              TextField(
                controller: durationCtl,
                decoration: const InputDecoration(labelText: 'Duration (e.g. 5 days)'),
              ),
              TextField(
                controller: instructionsCtl,
                decoration: const InputDecoration(labelText: 'Instructions (e.g. After food)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameCtl.text.trim().isEmpty) return;
              setState(() {
                _medications.add({
                  'drug_name': nameCtl.text.trim(),
                  'dosage': dosageCtl.text.trim(),
                  'frequency': freqCtl.text.trim(),
                  'duration': durationCtl.text.trim(),
                  'instructions': instructionsCtl.text.trim(),
                });
              });
              Navigator.of(ctx).pop();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: brandTeal,
              foregroundColor: Colors.white,
            ),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBanner() {
    final draft = _draft;
    if (draft == null) return const SizedBox.shrink();

    Color bgColor;
    Color textColor;
    IconData icon;
    String title;
    String subtitle;

    switch (draft.status) {
      case AiDraftStatus.aiDraft:
        bgColor = Colors.amber.shade50;
        textColor = Colors.amber.shade900;
        icon = Icons.auto_awesome;
        title = 'AI-Assisted Draft (Pending Doctor Review)';
        subtitle =
            'This clinical note was generated by AI from the consultation audio. You must review, edit, and approve it before finalization.';
        break;
      case AiDraftStatus.doctorReviewed:
        bgColor = Colors.blue.shade50;
        textColor = Colors.blue.shade900;
        icon = Icons.edit_note;
        title = 'Doctor Reviewed (Pending Finalization)';
        subtitle =
            'Revisions saved by doctor. Review once more and finalize to lock the clinical record.';
        break;
      case AiDraftStatus.rejected:
        bgColor = Colors.red.shade50;
        textColor = Colors.red.shade900;
        icon = Icons.cancel;
        title = 'Draft Rejected';
        subtitle =
            'This AI draft was rejected by the doctor and is archived for audit compliance.';
        break;
      case AiDraftStatus.finalized:
        bgColor = Colors.green.shade50;
        textColor = Colors.green.shade900;
        icon = Icons.lock;
        title = 'Finalized Clinical Record — Locked';
        subtitle =
            'Approved by doctor. This record is permanently locked in the database.';
        break;
    }

    return Container(
      key: const Key('draft_status_banner'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: textColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: textColor, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: textColor.withValues(alpha: 0.9)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: brandTeal),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1E293B),
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildMedicationsSection(bool isReadOnly) {
    return _buildSectionCard(
      title: 'Medications / Prescriptions',
      icon: Icons.medication,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_medications.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Text(
                'No medications prescribed.',
                style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey.shade600),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _medications.length,
              separatorBuilder: (context, index) => const Divider(height: 12),
              itemBuilder: (ctx, index) {
                final med = _medications[index];
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            med['drug_name'] ?? '',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              if ((med['dosage'] ?? '').isNotEmpty) med['dosage'],
                              if ((med['frequency'] ?? '').isNotEmpty) med['frequency'],
                              if ((med['duration'] ?? '').isNotEmpty) 'for ${med['duration']}',
                            ].join(' • '),
                            style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
                          ),
                          if ((med['instructions'] ?? '').isNotEmpty)
                            Text(
                              'Instructions: ${med['instructions']}',
                              style: TextStyle(
                                fontSize: 12,
                                fontStyle: FontStyle.italic,
                                color: Colors.grey.shade600,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (!isReadOnly)
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red),
                        onPressed: () {
                          setState(() {
                            _medications.removeAt(index);
                          });
                        },
                      ),
                  ],
                );
              },
            ),
          if (!isReadOnly) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('add_medication_button'),
                onPressed: _addMedicationDialog,
                icon: const Icon(Icons.add, size: 18, color: brandTeal),
                label: const Text(
                  'Add Medication',
                  style: TextStyle(color: brandTeal, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isReadOnly = _draft?.isFinalized == true || _draft?.isRejected == true;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Clinical Draft Review'),
        backgroundColor: brandTeal,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            key: const Key('refresh_draft_button'),
            icon: const Icon(Icons.refresh),
            onPressed: _fetchDraft,
            tooltip: 'Refresh draft',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: brandTeal),
                  SizedBox(height: 16),
                  Text('Loading AI clinical draft...'),
                ],
              ),
            )
          : _errorMessage != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error_outline, size: 48, color: Colors.red),
                        const SizedBox(height: 16),
                        Text(
                          _errorMessage!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 14),
                        ),
                        const SizedBox(height: 20),
                        ElevatedButton.icon(
                          onPressed: _fetchDraft,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: brandTeal,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : _draft == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.pending_actions,
                                size: 56, color: Colors.grey),
                            const SizedBox(height: 16),
                            const Text(
                              'No AI Draft Available Yet',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'The consultation recording is still being processed or no audio has been uploaded yet.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey),
                            ),
                            const SizedBox(height: 24),
                            ElevatedButton.icon(
                              onPressed: _fetchDraft,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Check Status'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: brandTeal,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Status banner
                          _buildStatusBanner(),
                          const SizedBox(height: 16),

                          // Patient info summary
                          Card(
                            color: Colors.grey.shade50,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: BorderSide(color: Colors.grey.shade300),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(12.0),
                              child: Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: brandTeal.withValues(alpha: 0.1),
                                    foregroundColor: brandTeal,
                                    child: const Icon(Icons.person),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          widget.patient.fullName,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15,
                                          ),
                                        ),
                                        Text(
                                          'Age: ${widget.patient.dobOrAge ?? "N/A"} • Sex: ${widget.patient.sex ?? "N/A"} • UHID: ${widget.patient.id.substring(0, widget.patient.id.length < 8 ? widget.patient.id.length : 8)}',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey.shade700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Chief Complaints
                          _buildSectionCard(
                            title: 'Chief Complaints',
                            icon: Icons.chat_bubble_outline,
                            child: TextField(
                              key: const Key('chief_complaints_field'),
                              controller: _complaintsController,
                              readOnly: isReadOnly,
                              maxLines: null,
                              decoration: const InputDecoration(
                                hintText: 'Enter chief complaints (one per line)',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),

                          // History of Present Illness
                          _buildSectionCard(
                            title: 'History of Present Illness (HPI)',
                            icon: Icons.history_edu,
                            child: TextField(
                              key: const Key('hpi_field'),
                              controller: _hpiController,
                              readOnly: isReadOnly,
                              maxLines: 4,
                              decoration: const InputDecoration(
                                hintText: 'Detailed clinical history of present illness...',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),

                          // Examination Findings
                          _buildSectionCard(
                            title: 'Examination Findings',
                            icon: Icons.search,
                            child: TextField(
                              key: const Key('examination_findings_field'),
                              controller: _examinationController,
                              readOnly: isReadOnly,
                              maxLines: null,
                              decoration: const InputDecoration(
                                hintText: 'Physical / clinical examination findings...',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),

                          // Provisional Diagnosis
                          _buildSectionCard(
                            title: 'Provisional Diagnosis',
                            icon: Icons.assignment_turned_in_outlined,
                            child: TextField(
                              key: const Key('provisional_diagnosis_field'),
                              controller: _diagnosisController,
                              readOnly: isReadOnly,
                              maxLines: null,
                              decoration: const InputDecoration(
                                hintText: 'Provisional or differential diagnosis...',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),

                          // Medications / Prescriptions
                          _buildMedicationsSection(isReadOnly),

                          // Investigations Ordered
                          _buildSectionCard(
                            title: 'Investigations Ordered',
                            icon: Icons.biotech,
                            child: TextField(
                              key: const Key('investigations_field'),
                              controller: _investigationsController,
                              readOnly: isReadOnly,
                              maxLines: null,
                              decoration: const InputDecoration(
                                hintText: 'Laboratory, imaging, or other diagnostics ordered...',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),

                          // Follow-up Advice
                          _buildSectionCard(
                            title: 'Follow-up Advice & Patient Instructions',
                            icon: Icons.event_note,
                            child: TextField(
                              key: const Key('follow_up_field'),
                              controller: _followUpController,
                              readOnly: isReadOnly,
                              maxLines: 3,
                              decoration: const InputDecoration(
                                hintText: 'Advice, diet, lifestyle, and follow-up timeline...',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),

                          const SizedBox(height: 12),

                          // Action Buttons
                          if (!isReadOnly) ...[
                            if (_isSaving)
                              const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(16.0),
                                  child: CircularProgressIndicator(color: brandTeal),
                                ),
                              )
                            else ...[
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      key: const Key('save_review_button'),
                                      onPressed: _saveReview,
                                      icon: const Icon(Icons.save_outlined),
                                      label: const Text('Save Review'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: brandTeal,
                                        side: const BorderSide(color: brandTeal),
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 14),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      key: const Key('reject_draft_button'),
                                      onPressed: _rejectDraft,
                                      icon: const Icon(Icons.cancel_outlined),
                                      label: const Text('Reject Draft'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.red.shade700,
                                        side: BorderSide(
                                            color: Colors.red.shade700),
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 14),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              ElevatedButton.icon(
                                key: const Key('finalize_record_button'),
                                onPressed: _finalizeRecord,
                                icon: const Icon(Icons.lock_outline),
                                label: const Text(
                                  'Approve & Finalize Record',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: brandTeal,
                                  foregroundColor: Colors.white,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 16),
                                ),
                              ),
                            ],
                          ] else if (_draft?.isFinalized == true) ...[
                            Container(
                              key: const Key('locked_record_notice'),
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.green.shade50,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.green.shade300),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.verified, color: Colors.green),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      'Record finalized on ${_draft!.finalizedAt?.toLocal().toString().substring(0, 16) ?? ''} by Doctor ${_draft!.finalizedBy ?? ''}.\nThis clinical record is immutable.',
                                      style: TextStyle(
                                        color: Colors.green.shade900,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 32),
                        ],
                      ),
                    ),
    );
  }
}
