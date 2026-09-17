import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../consultation/screens/consultation_history_screen.dart';
import '../../consultation/services/consultation_service.dart';
import '../models/patient_model.dart';
import '../services/patient_service.dart';
import 'add_patient_screen.dart';

class PatientListScreen extends StatefulWidget {
  final String clinicId;
  final String doctorId;
  final String? clinicName;
  final PatientService? patientService;
  final ConsultationService? consultationService;

  const PatientListScreen({
    super.key,
    required this.clinicId,
    required this.doctorId,
    this.clinicName,
    this.patientService,
    this.consultationService,
  });

  @override
  State<PatientListScreen> createState() => _PatientListScreenState();
}

class _PatientListScreenState extends State<PatientListScreen> {
  late final PatientService _patientService;
  late final ConsultationService _consultationService;

  final _searchController = TextEditingController();
  bool _isLoading = true;
  String? _errorMessage;
  List<PatientModel> _allPatients = [];
  List<PatientModel> _filteredPatients = [];

  @override
  void initState() {
    super.initState();
    _patientService = widget.patientService ?? PatientService();
    _consultationService = widget.consultationService ?? ConsultationService();
    _searchController.addListener(_filterPatients);
    _loadPatients();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filterPatients() {
    final query = _searchController.text.toLowerCase().trim();
    if (query.isEmpty) {
      setState(() => _filteredPatients = _allPatients);
    } else {
      setState(() {
        _filteredPatients = _allPatients.where((p) {
          final matchName = p.fullName.toLowerCase().contains(query);
          final matchOpd = p.opdNumber?.toLowerCase().contains(query) ?? false;
          final matchContact =
              p.contactInfo?.toLowerCase().contains(query) ?? false;
          return matchName || matchOpd || matchContact;
        }).toList();
      });
    }
  }

  Future<void> _loadPatients() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final list = await _patientService.fetchPatients();
      if (mounted) {
        setState(() {
          _allPatients = list;
          _filterPatients();
          _isLoading = false;
        });

        if (kDebugMode &&
            const bool.fromEnvironment(
              'CI_CAPTURE_FLOW',
              defaultValue: false,
            )) {
          Future.delayed(const Duration(seconds: 8), () {
            if (mounted && _allPatients.isNotEmpty) {
              _navigateToConsultations(_allPatients.first);
            }
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load patients: $e';
        });
      }
    }
  }

  Future<void> _navigateToAddPatient() async {
    final newPatient = await Navigator.of(context).push<PatientModel>(
      MaterialPageRoute(
        builder: (_) => AddPatientScreen(
          clinicId: widget.clinicId,
          doctorId: widget.doctorId,
          patientService: _patientService,
        ),
      ),
    );

    if (newPatient != null && mounted) {
      setState(() {
        _allPatients.insert(0, newPatient);
        _filterPatients();
      });
    }
  }

  void _navigateToConsultations(PatientModel patient) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConsultationHistoryScreen(
          patient: patient,
          clinicId: widget.clinicId,
          doctorId: widget.doctorId,
          consultationService: _consultationService,
        ),
      ),
    );
  }

  Future<void> _startQuickConsultation(PatientModel patient) async {
    try {
      await _consultationService.createConsultation(
        patientId: patient.id,
        doctorId: widget.doctorId,
        clinicId: widget.clinicId,
        status: 'in_progress',
      );

      if (mounted) {
        _navigateToConsultations(patient);
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

  @override
  Widget build(BuildContext context) {
    const brandTeal = Color(0xFF007A78);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Patient Directory',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            if (widget.clinicName != null)
              Text(
                widget.clinicName!,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
          ],
        ),
        backgroundColor: brandTeal,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loadPatients,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_patient_fab'),
        onPressed: _navigateToAddPatient,
        backgroundColor: brandTeal,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add),
        label: const Text('Add Patient'),
      ),
      body: Column(
        children: [
          // Search box
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              key: const Key('patient_search_input'),
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search by name, OPD #, or phone...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => _searchController.clear(),
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                filled: true,
                fillColor: Colors.grey.shade100,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          // Patients List
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
                          onPressed: _loadPatients,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                : _filteredPatients.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.people_outline,
                          size: 56,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _searchController.text.isNotEmpty
                              ? 'No matching patients found'
                              : 'No patients registered in this clinic yet',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          key: const Key('register_first_patient_button'),
                          onPressed: _navigateToAddPatient,
                          icon: const Icon(Icons.person_add),
                          label: const Text('Register First Patient'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: brandTeal,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _loadPatients,
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      itemCount: _filteredPatients.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final patient = _filteredPatients[index];

                        return Card(
                          key: Key('patient_card_${patient.id}'),
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
                                    CircleAvatar(
                                      backgroundColor: const Color(0xFFE6F4F1),
                                      foregroundColor: brandTeal,
                                      radius: 20,
                                      child: Text(
                                        patient.fullName.isNotEmpty
                                            ? patient.fullName[0].toUpperCase()
                                            : 'P',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            patient.fullName,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${patient.dobOrAge ?? "Age N/A"} • ${patient.sex ?? "Sex N/A"}${patient.contactInfo != null && patient.contactInfo!.isNotEmpty ? " • ${patient.contactInfo}" : ""}',
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: Colors.grey.shade600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (patient.opdNumber != null)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.grey.shade100,
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          border: Border.all(
                                            color: Colors.grey.shade300,
                                          ),
                                        ),
                                        child: Text(
                                          patient.opdNumber!,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const Divider(height: 24),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    TextButton.icon(
                                      key: Key('view_history_${patient.id}'),
                                      onPressed: () =>
                                          _navigateToConsultations(patient),
                                      icon: const Icon(Icons.history, size: 18),
                                      label: const Text('History'),
                                      style: TextButton.styleFrom(
                                        foregroundColor: Colors.grey.shade800,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    ElevatedButton.icon(
                                      key: Key(
                                        'start_consultation_${patient.id}',
                                      ),
                                      onPressed: () =>
                                          _startQuickConsultation(patient),
                                      icon: const Icon(
                                        Icons.play_arrow,
                                        size: 18,
                                      ),
                                      label: const Text('Start OPD'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: brandTeal,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
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
