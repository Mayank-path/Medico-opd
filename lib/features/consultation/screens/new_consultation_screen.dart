import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/test/ci_flow_coordinator.dart';
import '../../patient/models/patient_model.dart';
import '../models/consultation_model.dart';
import '../services/consultation_service.dart';

class NewConsultationScreen extends StatefulWidget {
  final PatientModel patient;
  final String clinicId;
  final String doctorId;
  final ConsultationService? consultationService;

  const NewConsultationScreen({
    super.key,
    required this.patient,
    required this.clinicId,
    required this.doctorId,
    this.consultationService,
  });

  @override
  State<NewConsultationScreen> createState() => _NewConsultationScreenState();
}

class _NewConsultationScreenState extends State<NewConsultationScreen> {
  late final ConsultationService _consultationService;
  String _selectedStatus = 'draft'; // Requirement 2: Default to draft
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _consultationService = widget.consultationService ?? ConsultationService();

    if (kDebugMode &&
        const bool.fromEnvironment('CI_CAPTURE_FLOW', defaultValue: false)) {
      CiFlowCoordinator.registerScreen(
        screenName: 'new_consultation',
        onAdvance: null, // Terminal screen in the screenshot flow
      );
    }
  }

  Future<void> _createConsultation() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final ConsultationModel consultation =
          await _consultationService.createConsultation(
            patientId: widget.patient.id,
            doctorId: widget.doctorId,
            clinicId: widget.clinicId,
            status: _selectedStatus,
          );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Consultation created as ${_selectedStatus.toUpperCase()}',
            ),
            backgroundColor: const Color(0xFF007A78),
          ),
        );
        Navigator.of(context).pop(consultation);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _errorMessage = 'Failed to create consultation: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const brandTeal = Color(0xFF007A78);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Start Consultation',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        backgroundColor: brandTeal,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Text(
                    _errorMessage!,
                    style: TextStyle(color: Colors.red.shade800),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Patient Summary Card (Strictly Read-Only Structured Data)
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.teal.shade100),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: const Color(0xFFE6F4F1),
                            foregroundColor: brandTeal,
                            radius: 24,
                            child: Text(
                              widget.patient.fullName.isNotEmpty
                                  ? widget.patient.fullName[0].toUpperCase()
                                  : 'P',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 20,
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.patient.fullName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                    color: Color(0xFF003B3A),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${widget.patient.dobOrAge ?? "Age N/A"} • ${widget.patient.sex ?? "Sex N/A"}',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 24),
                      _buildInfoRow(
                        'OPD Number',
                        widget.patient.opdNumber ?? 'Not assigned',
                      ),
                      const SizedBox(height: 6),
                      _buildInfoRow(
                        'Contact',
                        widget.patient.contactInfo ?? 'Not available',
                      ),
                      const SizedBox(height: 6),
                      _buildInfoRow('Patient ID', widget.patient.id, isMonospace: true),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Clinical Session Metadata (Strictly Read-Only Context)
              Card(
                elevation: 1,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.grey.shade200),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.info_outline, size: 18, color: brandTeal),
                          const SizedBox(width: 8),
                          const Text(
                            'Session Context',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF003B3A),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _buildInfoRow(
                        'Doctor Attributed',
                        widget.doctorId,
                        isMonospace: true,
                      ),
                      const SizedBox(height: 6),
                      _buildInfoRow(
                        'Clinic ID',
                        widget.clinicId,
                        isMonospace: true,
                      ),
                      const SizedBox(height: 6),
                      _buildInfoRow(
                        'Timestamp',
                        DateTime.now().toLocal().toString().substring(0, 16),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Consultation Initial Status Selector (Default: draft per Requirement 2)
              const Text(
                'Initial Consultation Status',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF003B3A),
                ),
              ),
              const SizedBox(height: 8),
              Column(
                children: [
                  InkWell(
                    key: const Key('status_draft_radio'),
                    onTap: () => setState(() => _selectedStatus = 'draft'),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _selectedStatus == 'draft'
                            ? const Color(0xFFE6F4F1)
                            : Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: _selectedStatus == 'draft'
                              ? brandTeal
                              : Colors.grey.shade300,
                          width: _selectedStatus == 'draft' ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _selectedStatus == 'draft'
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            color: _selectedStatus == 'draft'
                                ? brandTeal
                                : Colors.grey,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Draft (Queued / Opening Record)',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Recommended: Record is prepared; doctor transitions to in-progress when examination starts.',
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
                  const SizedBox(height: 10),
                  InkWell(
                    key: const Key('status_in_progress_radio'),
                    onTap: () => setState(() => _selectedStatus = 'in_progress'),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _selectedStatus == 'in_progress'
                            ? const Color(0xFFE6F4F1)
                            : Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: _selectedStatus == 'in_progress'
                              ? brandTeal
                              : Colors.grey.shade300,
                          width: _selectedStatus == 'in_progress' ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _selectedStatus == 'in_progress'
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            color: _selectedStatus == 'in_progress'
                                ? brandTeal
                                : Colors.grey,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'In Progress (Active OPD Assessment)',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Begins the active clinical consultation immediately.',
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
                ],
              ),
              const SizedBox(height: 32),

              // Action Button
              ElevatedButton.icon(
                key: const Key('create_consultation_submit_button'),
                onPressed: _isSubmitting ? null : _createConsultation,
                icon: _isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_circle_outline),
                label: Text(
                  _selectedStatus == 'draft'
                      ? 'Queue Consultation (Draft)'
                      : 'Begin Active OPD (In Progress)',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: brandTeal,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {bool isMonospace = false}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFamily: isMonospace ? 'monospace' : null,
              color: Colors.grey.shade800,
            ),
          ),
        ),
      ],
    );
  }
}
