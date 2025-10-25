import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/api_service.dart';
import '../web_config.dart';
import '../widgets/registration_progress_bar.dart';
import 'dart:async';

class OtpWebPage extends StatefulWidget {
  final String email;
  final String serverUrl;
  final int? wait;
  final String clientId;

  const OtpWebPage({Key? key, required this.email, required this.serverUrl, required this.clientId, this.wait}) : super(key: key);

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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('OTP send!')),
        );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('OTP Verified!')),
        );
        GoRouter.of(context).go('/app');
      } else if (response.statusCode == 202) {
        // New user registration - go to backup codes
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('OTP Verified!')),
        );
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
    print('OtpWebPage initState with wait: ${widget.wait}');
    print('Email: ${widget.email}, ServerUrl: ${widget.serverUrl}');
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
    return Scaffold(
      backgroundColor: const Color(0xFF2C2F33),
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
                  color: const Color(0xFF23272A),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Verify Your Email',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'We sent a verification code to ${widget.email}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _otpController,
                      decoration: const InputDecoration(
                        labelText: 'Enter OTP Code',
                        labelStyle: TextStyle(color: Colors.white70),
                        hintText: '000000',
                        hintStyle: TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: Color(0xFF40444B),
                        border: OutlineInputBorder(),
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF40444B)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.blueAccent),
                        ),
                      ),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        letterSpacing: 4,
                      ),
                      textAlign: TextAlign.center,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                    ),
                    const SizedBox(height: 20),
                    if (_error != null)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.red),
                        ),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.red),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    if (_error != null) const SizedBox(height: 20),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                        backgroundColor: Colors.blueAccent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: _loading ? null : _submitOtp,
                      child: _loading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
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
                          color: (_loading || (_wait != null && _wait! > 0))
                              ? Colors.white38
                              : Colors.blueAccent,
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