import 'package:flutter/material.dart';

import '../services/patient_service.dart';

class AddPatientScreen extends StatefulWidget {
  final String clinicId;
  final String? doctorId;
  final PatientService? patientService;

  const AddPatientScreen({
    super.key,
    required this.clinicId,
    this.doctorId,
    this.patientService,
  });

  @override
  State<AddPatientScreen> createState() => _AddPatientScreenState();
}

class _AddPatientScreenState extends State<AddPatientScreen> {
  final _formKey = GlobalKey<FormState>();
  late final PatientService _patientService;

  final _fullNameController = TextEditingController();
  final _dobOrAgeController = TextEditingController();
  final _contactInfoController = TextEditingController();
  final _opdNumberController = TextEditingController();

  String _selectedSex = 'Male';
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _patientService = widget.patientService ?? PatientService();
    // Pre-generate a default OPD number prefix based on timestamp
    final now = DateTime.now();
    _opdNumberController.text =
        'OPD-${now.year}${now.month.toString().padLeft(2, '0')}-${now.millisecond.toString().padLeft(3, '0')}';
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
      final patient = await _patientService.createPatient(
        clinicId: widget.clinicId,
        fullName: _fullNameController.text,
        dobOrAge: _dobOrAgeController.text,
        sex: _selectedSex,
        contactInfo: _contactInfoController.text,
        opdNumber: _opdNumberController.text,
        createdBy: widget.doctorId,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Patient ${patient.fullName} registered successfully',
            ),
            backgroundColor: const Color(0xFF007A78),
          ),
        );
        Navigator.of(context).pop(patient);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to register patient: $e';
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
          'Register New Patient',
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
                TextFormField(
                  key: const Key('patient_full_name_input'),
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
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        key: const Key('patient_age_input'),
                        controller: _dobOrAgeController,
                        decoration: const InputDecoration(
                          labelText: 'Age / DOB',
                          hintText: 'e.g. 42 yrs',
                          prefixIcon: Icon(Icons.calendar_today_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: const Key('patient_sex_dropdown'),
                        initialValue: _selectedSex,
                        decoration: const InputDecoration(
                          labelText: 'Sex',
                          prefixIcon: Icon(Icons.wc_outlined),
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
                TextFormField(
                  key: const Key('patient_contact_input'),
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
                TextFormField(
                  key: const Key('patient_opd_number_input'),
                  controller: _opdNumberController,
                  decoration: const InputDecoration(
                    labelText: 'OPD / Registration Number',
                    hintText: 'e.g. OPD-2026-001',
                    prefixIcon: Icon(Icons.tag_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 28),
                ElevatedButton(
                  key: const Key('save_patient_button'),
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
                          'Save Patient',
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
