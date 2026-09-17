import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/test/ci_flow_coordinator.dart';

import '../../patient/models/patient_model.dart';
import '../models/consultation_model.dart';
import '../services/consultation_service.dart';

class ConsultationHistoryScreen extends StatefulWidget {
  final PatientModel patient;
  final String clinicId;
  final String doctorId;
  final ConsultationService? consultationService;

  const ConsultationHistoryScreen({
    super.key,
    required this.patient,
    required this.clinicId,
    required this.doctorId,
    this.consultationService,
  });

  @override
  State<ConsultationHistoryScreen> createState() =>
      _ConsultationHistoryScreenState();
}

class _ConsultationHistoryScreenState extends State<ConsultationHistoryScreen> {
  late final ConsultationService _consultationService;
  bool _isLoading = true;
  String? _errorMessage;
  List<ConsultationModel> _consultations = [];

  @override
  void initState() {
    super.initState();
    _consultationService = widget.consultationService ?? ConsultationService();
    _loadConsultations();
  }

  Future<void> _loadConsultations() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final list = await _consultationService.fetchConsultationsForPatient(
        widget.patient.id,
      );
      if (mounted) {
        setState(() {
          _consultations = list;
          _isLoading = false;
        });

        if (kDebugMode &&
            const bool.fromEnvironment(
              'CI_CAPTURE_FLOW',
              defaultValue: false,
            )) {
          CiFlowCoordinator.registerScreen(
            screenName: 'consultation',
            onAdvance: null,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load consultations: $e';
        });
      }
    }
  }

  Future<void> _startNewConsultation() async {
    try {
      final newConsultation = await _consultationService.createConsultation(
        patientId: widget.patient.id,
        doctorId: widget.doctorId,
        clinicId: widget.clinicId,
        status: 'in_progress',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Consultation started'),
            backgroundColor: Color(0xFF007A78),
          ),
        );
        setState(() {
          _consultations.insert(0, newConsultation);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start consultation: $e'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    }
  }

  Future<void> _advanceStatus(ConsultationModel consultation) async {
    String nextStatus;
    DateTime? endedAt;

    if (consultation.status == 'draft') {
      nextStatus = 'in_progress';
    } else if (consultation.status == 'in_progress') {
      nextStatus = 'completed';
      endedAt = DateTime.now();
    } else {
      return; // Already completed
    }

    try {
      final updated = await _consultationService.updateConsultationStatus(
        consultationId: consultation.id,
        status: nextStatus,
        endedAt: endedAt,
      );

      if (mounted) {
        setState(() {
          final index = _consultations.indexWhere(
            (c) => c.id == consultation.id,
          );
          if (index != -1) {
            _consultations[index] = updated;
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Status updated to $nextStatus'),
            backgroundColor: const Color(0xFF007A78),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update status: $e'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    }
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'completed':
        return Colors.green.shade700;
      case 'in_progress':
        return Colors.blue.shade700;
      case 'draft':
      default:
        return Colors.orange.shade700;
    }
  }

  @override
  Widget build(BuildContext context) {
    const brandTeal = Color(0xFF007A78);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Consultations: ${widget.patient.fullName}',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        backgroundColor: brandTeal,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Column(
        children: [
          // Patient summary card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.teal.shade50,
              border: Border(bottom: BorderSide(color: Colors.teal.shade100)),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: brandTeal,
                  radius: 24,
                  child: Text(
                    widget.patient.fullName.isNotEmpty
                        ? widget.patient.fullName[0].toUpperCase()
                        : 'P',
                    style: const TextStyle(
                      color: Colors.white,
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
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF003B3A),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${widget.patient.opdNumber ?? "No OPD #"} • ${widget.patient.dobOrAge ?? "Age N/A"} • ${widget.patient.sex ?? "Sex N/A"}',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
                ElevatedButton.icon(
                  key: const Key('start_consultation_action_button'),
                  onPressed: _startNewConsultation,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Start'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: brandTeal,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Consultation list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _errorMessage != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _errorMessage!,
                          style: TextStyle(color: Colors.red.shade800),
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton(
                          onPressed: _loadConsultations,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                : _consultations.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.medical_services_outlined,
                          size: 48,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No consultations recorded yet',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          key: const Key('start_first_consultation_button'),
                          onPressed: _startNewConsultation,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Start First Consultation'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: brandTeal,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _loadConsultations,
                    child: ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _consultations.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final consultation = _consultations[index];
                        final statusColor = _getStatusColor(
                          consultation.status,
                        );

                        return Card(
                          elevation: 1,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: BorderSide(color: Colors.grey.shade200),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: statusColor.withValues(
                                          alpha: 0.1,
                                        ),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: statusColor),
                                      ),
                                      child: Text(
                                        consultation.status
                                            .toUpperCase()
                                            .replaceAll('_', ' '),
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: statusColor,
                                        ),
                                      ),
                                    ),
                                    const Spacer(),
                                    Text(
                                      consultation.startedAt
                                          .toLocal()
                                          .toString()
                                          .substring(0, 16),
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Consultation ID: ${consultation.id}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                                if (consultation.endedAt != null) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    'Ended: ${consultation.endedAt!.toLocal().toString().substring(0, 16)}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 12),
                                if (consultation.status != 'completed')
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton.icon(
                                      key: Key(
                                        'advance_status_${consultation.id}',
                                      ),
                                      onPressed: () =>
                                          _advanceStatus(consultation),
                                      icon: Icon(
                                        consultation.status == 'draft'
                                            ? Icons.play_arrow
                                            : Icons.check,
                                        size: 16,
                                      ),
                                      label: Text(
                                        consultation.status == 'draft'
                                            ? 'Mark In Progress'
                                            : 'Mark Completed',
                                        style: TextStyle(
                                          color: brandTeal,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
