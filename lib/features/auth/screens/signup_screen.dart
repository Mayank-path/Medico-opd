import 'package:flutter/material.dart';

import '../services/auth_service.dart';

class SignupScreen extends StatefulWidget {
  final VoidCallback onNavigateToLogin;

  const SignupScreen({super.key, required this.onNavigateToLogin});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _doctorNameController = TextEditingController();
  final _qualificationsController = TextEditingController();
  final _registrationNumberController = TextEditingController();
  final _doctorContactController = TextEditingController();

  final _clinicNameController = TextEditingController();
  final _clinicAddressController = TextEditingController();
  final _clinicContactController = TextEditingController();

  final _authService = AuthService();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _doctorNameController.dispose();
    _qualificationsController.dispose();
    _registrationNumberController.dispose();
    _doctorContactController.dispose();
    _clinicNameController.dispose();
    _clinicAddressController.dispose();
    _clinicContactController.dispose();
    super.dispose();
  }

  Future<void> _handleSignup() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result = await _authService.signUpWithClinic(
      email: _emailController.text,
      password: _passwordController.text,
      doctorName: _doctorNameController.text,
      qualifications: _qualificationsController.text,
      registrationNumber: _registrationNumberController.text,
      doctorContact: _doctorContactController.text,
      clinicName: _clinicNameController.text,
      clinicAddress: _clinicAddressController.text,
      clinicContact: _clinicContactController.text,
    );

    if (!mounted) return;

    setState(() {
      _isLoading = false;
      if (!result.isSuccess) {
        _errorMessage = result.errorMessage;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Doctor & Clinic Registration')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Create Doctor Account',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  if (_errorMessage != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        border: Border.all(color: Colors.red.shade300),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(color: Colors.red.shade800),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  // Credentials
                  const Text(
                    'Account Credentials',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    key: const Key('signup_email_field'),
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email Address *',
                      border: OutlineInputBorder(),
                    ),
                    validator: (val) {
                      if (val == null || val.trim().isEmpty) {
                        return 'Email is required';
                      }
                      if (!val.contains('@')) {
                        return 'Enter a valid email';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('signup_password_field'),
                    controller: _passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Password *',
                      border: OutlineInputBorder(),
                    ),
                    validator: (val) {
                      if (val == null || val.trim().isEmpty) {
                        return 'Password is required';
                      }
                      if (val.trim().length < 6) {
                        return 'Password must be at least 6 characters';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 20),
                  // Doctor Profile
                  const Text(
                    'Doctor Profile',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    key: const Key('signup_doctor_name_field'),
                    controller: _doctorNameController,
                    decoration: const InputDecoration(
                      labelText: 'Full Name *',
                      border: OutlineInputBorder(),
                    ),
                    validator: (val) {
                      if (val == null || val.trim().isEmpty) {
                        return 'Doctor name is required';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('signup_doctor_reg_field'),
                    controller: _registrationNumberController,
                    decoration: const InputDecoration(
                      labelText: 'Registration Number (MCI / SMC)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('signup_doctor_qualifications_field'),
                    controller: _qualificationsController,
                    decoration: const InputDecoration(
                      labelText: 'Qualifications (e.g. MBBS, MD)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('signup_doctor_contact_field'),
                    controller: _doctorContactController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Doctor Contact Phone',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Clinic Profile
                  const Text(
                    'Clinic Details',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    key: const Key('signup_clinic_name_field'),
                    controller: _clinicNameController,
                    decoration: const InputDecoration(
                      labelText: 'Clinic Name *',
                      border: OutlineInputBorder(),
                    ),
                    validator: (val) {
                      if (val == null || val.trim().isEmpty) {
                        return 'Clinic name is required';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('signup_clinic_address_field'),
                    controller: _clinicAddressController,
                    decoration: const InputDecoration(
                      labelText: 'Clinic Address',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('signup_clinic_contact_field'),
                    controller: _clinicContactController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Clinic Contact Info',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    key: const Key('signup_submit_button'),
                    onPressed: _isLoading ? null : _handleSignup,
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Register & Create Clinic'),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    key: const Key('signup_switch_to_login_button'),
                    onPressed: _isLoading ? null : widget.onNavigateToLogin,
                    child: const Text('Already have an account? Sign In'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
