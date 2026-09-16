import 'package:flutter/material.dart';

import '../../auth/services/auth_service.dart';
import '../models/clinic_model.dart';
import '../models/doctor_model.dart';
import '../services/clinic_service.dart';

class ClinicProfileScreen extends StatefulWidget {
  final AuthService? authService;
  final ClinicService? clinicService;

  const ClinicProfileScreen({super.key, this.authService, this.clinicService});

  @override
  State<ClinicProfileScreen> createState() => _ClinicProfileScreenState();
}

class _ClinicProfileScreenState extends State<ClinicProfileScreen> {
  late final AuthService _authService;
  late final ClinicService _clinicService;

  bool _isLoading = true;
  bool _isOnboardingIncomplete = false;
  String? _errorMessage;
  DoctorModel? _doctor;
  ClinicModel? _clinic;

  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? AuthService();
    _clinicService = widget.clinicService ?? ClinicService();
    _loadProfileData();
  }

  Future<void> _loadProfileData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      var doctor = await _clinicService.fetchCurrentDoctor();
      if (doctor == null) {
        final currentUser = _authService.currentUser;
        final meta = currentUser?.userMetadata;
        final hasPendingMeta =
            meta != null &&
            (meta['clinic_name'] as String?)?.isNotEmpty == true &&
            (meta['doctor_name'] as String?)?.isNotEmpty == true;

        if (hasPendingMeta) {
          final onboardingRes = await _authService.finalizePendingOnboarding(
            currentUser,
          );
          if (onboardingRes.isSuccess) {
            doctor = await _clinicService.fetchCurrentDoctor();
          } else {
            setState(() {
              _isLoading = false;
              _isOnboardingIncomplete = true;
              _errorMessage = onboardingRes.errorMessage ?? 'Account setup incomplete: Clinic registration could not be completed.';
            });
            return;
          }
        }
      }

      if (doctor == null) {
        setState(() {
          _isLoading = false;
          _isOnboardingIncomplete = true;
          _errorMessage = 'Account setup incomplete: Doctor profile not found. Tap to retry.';
        });
        return;
      }

      final clinic = await _clinicService.fetchCurrentClinic(doctor.clinicId);
      if (clinic == null) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Associated clinic record not found.';
        });
        return;
      }

      setState(() {
        _doctor = doctor;
        _clinic = clinic;
        _isOnboardingIncomplete = false;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to load profile data: $e';
      });
    }
  }

  Future<void> _retryOnboarding() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final res = await _authService.finalizePendingOnboarding();
    if (!res.isSuccess) {
      setState(() {
        _isLoading = false;
        _isOnboardingIncomplete = true;
        _errorMessage =
            res.errorMessage ?? 'Account setup incomplete — tap to retry.';
      });
      return;
    }

    await _loadProfileData();
  }

  Future<void> _handleLogout() async {
    await _authService.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Clinic Profile'),
        actions: [
          IconButton(
            key: const Key('profile_refresh_button'),
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loadProfileData,
          ),
          IconButton(
            key: const Key('profile_logout_button'),
            icon: const Icon(Icons.logout),
            tooltip: 'Sign Out',
            onPressed: _handleLogout,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_isOnboardingIncomplete) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.assignment_late_outlined,
                color: Colors.amber,
                size: 56,
              ),
              const SizedBox(height: 16),
              const Text(
                'Account setup incomplete',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                _errorMessage ?? 'Your email has been confirmed, but setting up your clinic and doctor profile was interrupted. Tap below to retry.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Colors.black87),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                key: const Key('profile_retry_onboarding_button'),
                onPressed: _retryOnboarding,
                icon: const Icon(Icons.refresh),
                label: const Text('Tap to retry'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _handleLogout,
                child: const Text('Sign Out'),
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _loadProfileData,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _handleLogout,
                child: const Text('Sign Out'),
              ),
            ],
          ),
        ),
      );
    }

    final doctor = _doctor!;
    final clinic = _clinic!;

    return ListView(
      padding: const EdgeInsets.all(20.0),
      children: [
        // Doctor Card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.person, color: Colors.teal),
                    const SizedBox(width: 8),
                    Text(
                      'Doctor Information',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const Divider(height: 24),
                _buildInfoRow(
                  'Full Name',
                  doctor.fullName,
                  keyName: 'doctor_name_text',
                ),
                _buildInfoRow(
                  'Registration No',
                  doctor.registrationNumber?.isNotEmpty == true
                      ? doctor.registrationNumber!
                      : 'Not specified',
                  keyName: 'doctor_reg_text',
                ),
                _buildInfoRow(
                  'Qualifications',
                  doctor.qualifications?.isNotEmpty == true
                      ? doctor.qualifications!
                      : 'Not specified',
                  keyName: 'doctor_qualifications_text',
                ),
                _buildInfoRow(
                  'Contact Info',
                  doctor.contactInfo?.isNotEmpty == true
                      ? doctor.contactInfo!
                      : 'Not specified',
                  keyName: 'doctor_contact_text',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Clinic Card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.local_hospital, color: Colors.blue),
                    const SizedBox(width: 8),
                    Text(
                      'Clinic Details',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const Divider(height: 24),
                _buildInfoRow(
                  'Clinic Name',
                  clinic.name,
                  keyName: 'clinic_name_text',
                ),
                _buildInfoRow(
                  'Address',
                  clinic.address?.isNotEmpty == true
                      ? clinic.address!
                      : 'Not specified',
                  keyName: 'clinic_address_text',
                ),
                _buildInfoRow(
                  'Contact Info',
                  clinic.contactInfo?.isNotEmpty == true
                      ? clinic.contactInfo!
                      : 'Not specified',
                  keyName: 'clinic_contact_text',
                ),
                _buildInfoRow(
                  'Clinic ID',
                  clinic.id,
                  keyName: 'clinic_id_text',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          key: const Key('profile_signout_bottom_button'),
          onPressed: _handleLogout,
          icon: const Icon(Icons.logout),
          label: const Text('Sign Out of Medico OPD'),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value, {String? keyName}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              key: keyName != null ? Key(keyName) : null,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}
