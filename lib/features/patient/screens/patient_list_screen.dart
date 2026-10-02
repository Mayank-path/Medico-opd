import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/test/ci_flow_coordinator.dart';
import '../../consultation/screens/consultation_history_screen.dart';
import '../../consultation/screens/new_consultation_screen.dart';
import '../../consultation/services/consultation_service.dart';
import '../models/patient_model.dart';
import '../services/patient_service.dart';
import 'add_patient_screen.dart';
import 'edit_patient_screen.dart';

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
  Timer? _debounceTimer;

  static const int _pageSize = 20;
  String? _nextCursor;
  bool _hasMore = true;
  bool _isLoading = true;
  bool _isLoadingMore = false;
  String? _errorMessage;
  List<PatientModel> _patients = [];

  @override
  void initState() {
    super.initState();
    _patientService = widget.patientService ?? PatientService();
    _consultationService = widget.consultationService ?? ConsultationService();
    _searchController.addListener(_onSearchChanged);
    _loadPatients(refresh: true);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      _loadPatients(refresh: true);
    });
  }

  Future<void> _loadPatients({bool refresh = false}) async {
    if (refresh) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
        _nextCursor = null;
        _hasMore = true;
      });
    }

    try {
      final query = _searchController.text.trim();
      final result = await _patientService.fetchPatients(
        limit: _pageSize,
        cursor: refresh ? null : _nextCursor,
        searchQuery: query.isNotEmpty ? query : null,
      );

      if (mounted) {
        setState(() {
          if (refresh) {
            _patients = result.items;
          } else {
            _patients.addAll(result.items);
          }

          _nextCursor = result.nextCursor;
          _hasMore = result.hasMore;
          _isLoading = false;
          _isLoadingMore = false;
        });

        if (kDebugMode &&
            const bool.fromEnvironment(
              'CI_CAPTURE_FLOW',
              defaultValue: false,
            )) {
          CiFlowCoordinator.registerScreen(
            screenName: 'patient_list',
            onAdvance: () {
              if (mounted && _patients.isNotEmpty) {
                _navigateToEditPatientForCi(_patients.first);
              }
            },
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isLoadingMore = false;
          _errorMessage = 'Failed to load patients: $e';
        });
      }
    }
  }

  Future<void> _loadMorePatients() async {
    if (_isLoadingMore || !_hasMore || _isLoading || _nextCursor == null) return;

    setState(() {
      _isLoadingMore = true;
    });

    await _loadPatients(refresh: false);
  }

  void _navigateToEditPatientForCi(PatientModel patient) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditPatientScreen(
          patient: patient,
          patientService: _patientService,
        ),
      ),
    ).then((_) {
      // When edit screen pops via CI advance, continue CI flow to consultation history
      if (mounted && _patients.isNotEmpty) {
        _navigateToConsultations(_patients.first);
      }
    });
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
        _patients.insert(0, newPatient);
      });
    }
  }

  Future<void> _navigateToEditPatient(PatientModel patient) async {
    final updated = await Navigator.of(context).push<PatientModel>(
      MaterialPageRoute(
        builder: (_) => EditPatientScreen(
          patient: patient,
          patientService: _patientService,
        ),
      ),
    );

    if (updated != null && mounted) {
      setState(() {
        final index = _patients.indexWhere((p) => p.id == updated.id);
        if (index != -1) {
          _patients[index] = updated;
        }
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

  Future<void> _startConsultationFlow(PatientModel patient) async {
    final newConsultation = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NewConsultationScreen(
          patient: patient,
          clinicId: widget.clinicId,
          doctorId: widget.doctorId,
          consultationService: _consultationService,
        ),
      ),
    );

    if (newConsultation != null && mounted) {
      _navigateToConsultations(patient);
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
            onPressed: () => _loadPatients(refresh: true),
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
                        onPressed: () {
                          _searchController.clear();
                          _loadPatients(refresh: true);
                        },
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

          // Patients List & Pagination
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
                          onPressed: () => _loadPatients(refresh: true),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                : _patients.isEmpty
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
                    onRefresh: () => _loadPatients(refresh: true),
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      itemCount: _patients.length + (_hasMore ? 1 : 0),
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        if (index == _patients.length) {
                          // Load more pagination footer
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16.0),
                            child: Center(
                              child: _isLoadingMore
                                  ? const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : OutlinedButton.icon(
                                      key: const Key('load_more_patients_button'),
                                      onPressed: _loadMorePatients,
                                      icon: const Icon(Icons.expand_more),
                                      label: const Text('Load More Patients'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: brandTeal,
                                      ),
                                    ),
                            ),
                          );
                        }

                        final patient = _patients[index];

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
                                      key: Key('edit_patient_${patient.id}'),
                                      onPressed: () =>
                                          _navigateToEditPatient(patient),
                                      icon: const Icon(Icons.edit_outlined, size: 18),
                                      label: const Text('Edit'),
                                      style: TextButton.styleFrom(
                                        foregroundColor: Colors.grey.shade800,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
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
                                          _startConsultationFlow(patient),
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
