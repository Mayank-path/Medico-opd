import 'package:flutter/material.dart';

import '../../patient/models/patient_model.dart';
import '../../consultation/models/consultation_model.dart';
import '../models/consent_model.dart';
import '../models/consent_policy.dart';
import '../services/consent_service.dart';

class ConsentCaptureScreen extends StatefulWidget {
  final PatientModel patient;
  final ConsultationModel consultation;
  final String doctorId;
  final ConsentService? consentService;
  final ConsentPolicy? initialPolicy;

  const ConsentCaptureScreen({
    super.key,
    required this.patient,
    required this.consultation,
    required this.doctorId,
    this.consentService,
    this.initialPolicy,
  });

  @override
  State<ConsentCaptureScreen> createState() => _ConsentCaptureScreenState();
}

class _ConsentCaptureScreenState extends State<ConsentCaptureScreen> {
  late final ConsentService _consentService;
  late ConsentPolicy _activePolicy;

  late ConsentMethod _selectedMethod;
  ConsentActor _selectedActor = ConsentActor.patient;

  late final TextEditingController _actorNameController;
  final _actorRelationshipController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isSubmitting = false;
  bool _isLoadingPolicy = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _consentService = widget.consentService ?? ConsentService();
    _activePolicy = widget.initialPolicy ?? ConsentPolicy.fallbackDefault();
    _selectedMethod = _activePolicy.allowedMethods.contains(ConsentMethod.verbal)
        ? ConsentMethod.verbal
        : (_activePolicy.allowedMethods.isNotEmpty
            ? _activePolicy.allowedMethods.first
            : ConsentMethod.verbal);
    _actorNameController = TextEditingController(text: widget.patient.fullName);

    if (widget.initialPolicy == null) {
      _loadActivePolicy();
    }
  }

  Future<void> _loadActivePolicy() async {
    setState(() => _isLoadingPolicy = true);
    try {
      final policy = await _consentService.getActiveConsentPolicy();
      if (mounted) {
        setState(() {
          _activePolicy = policy;
          if (!_activePolicy.allowedMethods.contains(_selectedMethod) &&
              _activePolicy.allowedMethods.isNotEmpty) {
            _selectedMethod = _activePolicy.allowedMethods.first;
          }
          _isLoadingPolicy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingPolicy = false);
      }
    }
  }

  @override
  void dispose() {
    _actorNameController.dispose();
    _actorRelationshipController.dispose();
    super.dispose();
  }

  Future<void> _handleGrantConsent() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final consent = await _consentService.recordConsent(
        clinicId: widget.consultation.clinicId,
        consultationId: widget.consultation.id,
        patientId: widget.patient.id,
        consentStatus: ConsentStatus.granted,
        consentMethod: _selectedMethod,
        consentActor: _selectedActor,
        actorName: _actorNameController.text.trim(),
        actorRelationship: _selectedActor == ConsentActor.guardian
            ? _actorRelationshipController.text.trim()
            : null,
        recordedByDoctorId: widget.doctorId,
      );

      if (mounted) {
        Navigator.of(context).pop(consent);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _errorMessage = 'Failed to record consent: $e';
        });
      }
    }
  }

  Future<void> _handleDeclineConsent() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final consent = await _consentService.recordConsent(
        clinicId: widget.consultation.clinicId,
        consultationId: widget.consultation.id,
        patientId: widget.patient.id,
        consentStatus: ConsentStatus.declined,
        consentMethod: _selectedMethod,
        consentActor: _selectedActor,
        actorName: _actorNameController.text.trim().isNotEmpty
            ? _actorNameController.text.trim()
            : widget.patient.fullName,
        actorRelationship: _selectedActor == ConsentActor.guardian
            ? _actorRelationshipController.text.trim()
            : null,
        recordedByDoctorId: widget.doctorId,
      );

      if (mounted) {
        Navigator.of(context).pop(consent);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _errorMessage = 'Failed to record declined status: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const brandTeal = Color(0xFF007A78);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Consultation Audio Consent'),
        backgroundColor: brandTeal,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Patient Banner
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.teal.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.teal.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.patient.fullName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF003B3A),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'OPD: ${widget.patient.opdNumber ?? "N/A"} • Age/Sex: ${widget.patient.dobOrAge ?? "N/A"}, ${widget.patient.sex ?? "N/A"}',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Statutory Anti-Coercion Notice (DPDP Act & Telemedicine Guidelines)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.shade300),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: Colors.amber.shade900,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Declining audio recording will NOT affect patient care. The doctor can proceed with standard manual OPD documentation.',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.amber.shade900,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Consent Actor Selection (Patient vs Guardian)
              const Text(
                'Consent Given By',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              SegmentedButton<ConsentActor>(
                key: const Key('consent_actor_selector'),
                segments: const [
                  ButtonSegment(
                    value: ConsentActor.patient,
                    label: Text('Patient Directly'),
                    icon: Icon(Icons.person),
                  ),
                  ButtonSegment(
                    value: ConsentActor.guardian,
                    label: Text('Guardian / Representative'),
                    icon: Icon(Icons.supervisor_account),
                  ),
                ],
                selected: {_selectedActor},
                onSelectionChanged: (newSelection) {
                  setState(() {
                    _selectedActor = newSelection.first;
                    if (_selectedActor == ConsentActor.patient) {
                      _actorNameController.text = widget.patient.fullName;
                    } else {
                      _actorNameController.clear();
                    }
                  });
                },
              ),
              const SizedBox(height: 16),

              // Actor Name field
              TextFormField(
                key: const Key('consent_actor_name_field'),
                controller: _actorNameController,
                decoration: InputDecoration(
                  labelText: _selectedActor == ConsentActor.patient
                      ? 'Patient Full Name'
                      : 'Guardian Full Name',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.badge),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Please enter name of consenting individual';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Conditional Guardian Relationship field (Step 2 DB constraint)
              if (_selectedActor == ConsentActor.guardian) ...[
                TextFormField(
                  key: const Key('consent_actor_relationship_field'),
                  controller: _actorRelationshipController,
                  decoration: const InputDecoration(
                    labelText: 'Relationship to Patient (e.g. Mother, Father, Legal Guardian)',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.family_restroom),
                  ),
                  validator: (val) {
                    if (_selectedActor == ConsentActor.guardian &&
                        (val == null || val.trim().isEmpty)) {
                      return 'Relationship is required when guardian gives consent';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // Step 3 / RLR-04 Policy-driven verification notice placeholder
                if (_activePolicy.pediatricVerificationRequired) ...[
                  Container(
                    key: const Key('pediatric_verification_notice'),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blue.shade300),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.verified_user_outlined,
                          color: Colors.blue.shade800,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Policy Notice: Additional guardian identity verification required by active policy. (Extension placeholder).',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blue.shade900,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ],

              // Consent Method Selector (Driven dynamically from activePolicy.allowedMethods)
              const Text(
                'Consent Method',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              if (_isLoadingPolicy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8.0),
                  child: LinearProgressIndicator(),
                ),
              DropdownButtonFormField<ConsentMethod>(
                key: ValueKey('consent_method_dropdown_${_activePolicy.version}_${_selectedMethod.name}'),
                initialValue: _activePolicy.allowedMethods.contains(_selectedMethod)
                    ? _selectedMethod
                    : (_activePolicy.allowedMethods.isNotEmpty
                        ? _activePolicy.allowedMethods.first
                        : null),
                decoration: const InputDecoration(border: OutlineInputBorder()),
                items: _activePolicy.allowedMethods.map((m) {
                  return DropdownMenuItem(
                    value: m,
                    child: Text(m.label),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) {
                    setState(() {
                      _selectedMethod = val;
                    });
                  }
                },
              ),
              const SizedBox(height: 24),

              if (_errorMessage != null) ...[
                Text(
                  _errorMessage!,
                  style: TextStyle(color: Colors.red.shade800, fontSize: 13),
                ),
                const SizedBox(height: 12),
              ],

              // Action Buttons
              if (_isSubmitting)
                const Center(child: CircularProgressIndicator())
              else ...[
                ElevatedButton.icon(
                  key: const Key('grant_consent_button'),
                  onPressed: _handleGrantConsent,
                  icon: const Icon(Icons.check_circle),
                  label: const Text('Grant Consent & Proceed to Recording'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: brandTeal,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  key: const Key('decline_consent_button'),
                  onPressed: _handleDeclineConsent,
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Decline Recording (Proceed Manually)'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red.shade700,
                    side: BorderSide(color: Colors.red.shade300),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
