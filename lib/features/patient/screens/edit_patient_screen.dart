import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/test/ci_flow_coordinator.dart';
import '../models/patient_model.dart';
import '../services/patient_service.dart';

class EditPatientScreen extends StatefulWidget {
  final PatientModel patient;
  final PatientService? patientService;

  const EditPatientScreen({
    super.key,
    required this.patient,
    this.patientService,
  });

  @override
  State<EditPatientScreen> createState() => _EditPatientScreenState();
}

class _EditPatientScreenState extends State<EditPatientScreen> {
  final _formKey = GlobalKey<FormState>();
  late final PatientService _patientService;

  late final TextEditingController _fullNameController;
  late final TextEditingController _dobOrAgeController;
  late final TextEditingController _contactInfoController;
  late final TextEditingController _opdNumberController;

  late String _selectedSex;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _patientService = widget.patientService ?? PatientService();

    _fullNameController = TextEditingController(text: widget.patient.fullName);
    _dobOrAgeController = TextEditingController(
      text: widget.patient.dobOrAge ?? '',
    );
    _contactInfoController = TextEditingController(
      text: widget.patient.contactInfo ?? '',
    );
    _opdNumberController = TextEditingController(
      text: widget.patient.opdNumber ?? '',
    );

    final currentSex = widget.patient.sex;
    if (currentSex != null &&
        (currentSex == 'Male' ||
            currentSex == 'Female' ||
            currentSex == 'Other')) {
      _selectedSex = currentSex;
    } else {
      _selectedSex = 'Male';
    }

    if (kDebugMode &&
        const bool.fromEnvironment('CI_CAPTURE_FLOW', defaultValue: false)) {
      CiFlowCoordinator.registerScreen(
        screenName: 'edit_patient',
        onAdvance: () {
          if (mounted) {
            Navigator.of(context).pop();
          }
        },
      );
    }
  }

  @override
  void dispose() {
    _fullNameController.dispose();
    _dobOrAgeController.dispose();
    _contactInfoController.dispose();
    _opdNumberController.dispose();
    super.dispose();
  }

  Future<void> _submitForm() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final updatedPatient = await _patientService.updatePatient(
        patientId: widget.patient.id,
        fullName: _fullNameController.text,
        dobOrAge: _dobOrAgeController.text.trim().isEmpty
            ? null
            : _dobOrAgeController.text.trim(),
        sex: _selectedSex,
        contactInfo: _contactInfoController.text.trim().isEmpty
            ? null
            : _contactInfoController.text.trim(),
        opdNumber: _opdNumberController.text.trim().isEmpty
            ? null
            : _opdNumberController.text.trim(),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Patient ${updatedPatient.fullName} updated successfully',
            ),
            backgroundColor: const Color(0xFF007A78),
          ),
        );
        Navigator.of(context).pop(updatedPatient);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to update patient: $e';
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
          'Edit Patient Details',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        backgroundColor: brandTeal,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Immutable metadata banner
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.lock_outline,
                            size: 16,
                            color: Colors.grey.shade700,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'System Identifiers (Read-Only)',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'ID: ${widget.patient.id}',
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: Colors.grey.shade600,
                        ),
                      ),
                      Text(
                        'Registered: ${widget.patient.createdAt.toLocal().toString().substring(0, 16)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

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

                // Full Name
                TextFormField(
                  key: const Key('edit_patient_full_name_input'),
                  controller: _fullNameController,
                  decoration: const InputDecoration(
                    labelText: 'Full Name *',
                    hintText: 'e.g. Ramesh Kumar',
                    prefixIcon: Icon(Icons.person_outline),
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Patient name is required';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // Age and Sex
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextFormField(
                        key: const Key('edit_patient_age_input'),
                        controller: _dobOrAgeController,
                        decoration: const InputDecoration(
                          labelText: 'Age / DOB',
                          hintText: 'e.g. 42 yrs',
                          prefixIcon: Icon(Icons.calendar_today_outlined, size: 20),
                          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 14),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 3,
                      child: DropdownButtonFormField<String>(
                        key: const Key('edit_patient_sex_dropdown'),
                        initialValue: _selectedSex,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Sex',
                          prefixIcon: Icon(Icons.wc_outlined, size: 20),
                          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 14),
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'Male', child: Text('Male')),
                          DropdownMenuItem(
                            value: 'Female',
                            child: Text('Female'),
                          ),
                          DropdownMenuItem(
                            value: 'Other',
                            child: Text('Other'),
                          ),
                        ],
                        onChanged: (val) {
                          if (val != null) setState(() => _selectedSex = val);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Contact Number
                TextFormField(
                  key: const Key('edit_patient_contact_input'),
                  controller: _contactInfoController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Contact Number',
                    hintText: 'e.g. +91 98765 43210',
                    prefixIcon: Icon(Icons.phone_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),

                // OPD Number
                TextFormField(
                  key: const Key('edit_patient_opd_number_input'),
                  controller: _opdNumberController,
                  decoration: const InputDecoration(
                    labelText: 'OPD / Registration Number',
                    hintText: 'e.g. OPD-2026-001',
                    prefixIcon: Icon(Icons.tag_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 28),

                // Submit Button
                ElevatedButton(
                  key: const Key('save_patient_changes_button'),
                  onPressed: _isLoading ? null : _submitForm,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: brandTeal,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Save Changes',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
