import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/api_service.dart';
import '../web_config.dart';
import '../widgets/registration_progress_bar.dart';
import '../extensions/snackbar_extensions.dart';
import 'dart:async';

class OtpWebPage extends StatefulWidget {
  final String email;
  final String serverUrl;
  final int? wait;
  final String? clientId;  // Optional - fetched/created after login

  const OtpWebPage({super.key, required this.email, required this.serverUrl, this.clientId, this.wait});

  @override
  State<OtpWebPage> createState() => _OtpWebPageState();
}

class _OtpWebPageState extends State<OtpWebPage> {
  final TextEditingController _otpController = TextEditingController();
  bool _loading = false;
  String? _error;
  int? _wait;
  Timer? _timer;

  Future<void> _resendOtp() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      //final dio = ApiService.dio;

      final response = await ApiService.post(
        '$urlString/register',
        data: {
          'email': widget.email,
        },
      );
      // Handle response as needed
      if (response.statusCode == 200) {
        // Success logic here
        if (!mounted) return;
        context.showSuccessSnackBar('OTP sent!');
      } else {
        setState(() {
          _error = 'server error.';
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Failed to resend OTP.';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _submitOtp() async {
    setState(() {
      _error = null;
    });

    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      //final dio = ApiService.dio;

      final response = await ApiService.post(
        '$urlString/otp',
        data: {
          'email': widget.email,
          'otp': _otpController.text,
          'clientId': widget.clientId,
        },
      );
      // Handle response as needed
      if (response.statusCode == 200) {
        // Success logic here - existing user login
        if (!mounted) return;
        context.showSuccessSnackBar('OTP Verified!');
        GoRouter.of(context).go('/app');
      } else if (response.statusCode == 202) {
        // New user registration - go to backup codes
        if (!mounted) return;
        context.showSuccessSnackBar('OTP Verified!');
        GoRouter.of(context).go('/register/backupcode');
      } else {
        setState(() {
          _error = 'Invalid OTP or server error.';
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Failed to verify OTP.';
      });
    }
  }

  @override
  @override
  void initState() {
    super.initState();
    debugPrint('OtpWebPage initState with wait: ${widget.wait}');
    debugPrint('Email: ${widget.email}, ServerUrl: ${widget.serverUrl}');
    if (widget.wait != null && widget.wait! > 0) {
      _wait = widget.wait;
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_wait != null && _wait! > 0) {
          setState(() {
            _wait = _wait! - 1;
          });
        }
        if (_wait == 0) {
          timer.cancel();
          setState(() {
            _wait = null;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Column(
        children: [
          // Progress Bar
          const RegistrationProgressBar(currentStep: 1),
          // Content
          Expanded(
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(32),
                width: 450,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Verify Your Email',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'We sent a verification code to ${widget.email}',
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _otpController,
                      decoration: InputDecoration(
                        labelText: 'Enter OTP Code',
                        labelStyle: TextStyle(color: colorScheme.onSurfaceVariant),
                        hintText: '00000',
                        hintStyle: TextStyle(color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                        filled: true,
                        fillColor: colorScheme.surfaceContainerHighest,
                        border: const OutlineInputBorder(),
                      ),
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontSize: 18,
                        letterSpacing: 4,
                      ),
                      textAlign: TextAlign.center,
                      keyboardType: TextInputType.number,
                      maxLength: 5,
                    ),
                    const SizedBox(height: 20),
                    if (_error != null)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: colorScheme.error),
                        ),
                        child: Text(
                          _error!,
                          style: TextStyle(color: colorScheme.error),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    if (_error != null) const SizedBox(height: 20),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: _loading ? null : _submitOtp,
                      child: _loading
                          ? SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                color: colorScheme.onPrimary,
                                strokeWidth: 2,
                              ),
                            )
                          : const Text(
                              'Verify Code',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                      ),
                      onPressed: (_loading || (_wait != null && _wait! > 0))
                          ? null
                          : _resendOtp,
                      child: Text(
                        _wait != null && _wait! > 0
                            ? 'Resend Code (${_wait}s)'
                            : 'Resend Code',
                        style: TextStyle(
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
