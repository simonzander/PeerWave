import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/api_service.dart';
import '../web_config.dart';
import 'dart:async';

class OtpWebPage extends StatefulWidget {
  final String email;
  final String serverUrl;
  final int? wait;

  const OtpWebPage({Key? key, required this.email, required this.serverUrl, this.wait}) : super(key: key);

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
        },
      );
      // Handle response as needed
      if (response.statusCode == 200) {
        // Success logic here
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('OTP Verified!')),
        );
        GoRouter.of(context).go('/app/settings/webauthn');
      } else if (response.statusCode == 202) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('OTP Verified!')),
        );
        GoRouter.of(context).go('/app/settings/backupcode/list');
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
      appBar: AppBar(title: const Text('Enter OTP')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _otpController,
              decoration: const InputDecoration(
                labelText: 'OTP',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading ? null : _submitOtp,
                child: _loading
                    ? const CircularProgressIndicator()
                    : const Text('Submit'),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: (_loading || (_wait != null && _wait! > 0)) ? null : _resendOtp,
                child: _loading
                    ? const CircularProgressIndicator()
                    : Text('Request new OTP${_wait != null && _wait! > 0 ? ' (${_wait}s)' : ''}'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}