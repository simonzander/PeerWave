
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:web/web.dart' as web;
import 'package:js/js.dart';
import 'package:js/js_util.dart' as js_util;
import '../services/api_service.dart';
import '../web_config.dart';
import 'dart:async';


class BackupCodeRecoveryPage extends StatefulWidget {
  const BackupCodeRecoveryPage({super.key});

  @override
  State<BackupCodeRecoveryPage> createState() => _BackupCodeRecoveryPageState();
}

class _BackupCodeRecoveryPageState extends State<BackupCodeRecoveryPage> {
  int? _waitTime;
  Timer? _waitTimer;
  final TextEditingController backupCodeController = TextEditingController();
  @override
  void initState() {
    super.initState();
  }


  Future<void> _verifyBackupCode() async {
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      // Try to include clientId if available (helps server attach device info immediately)
      String? clientId;
      try {
        // Reuse the same web client id service via JS localStorage (set earlier in AuthLayout)
        final jsClientId = web.window.localStorage.getItem('clientId');
        clientId = jsClientId;
      } catch (_) {}
      final resp = await ApiService.post('$urlString/backupcode/verify', data: {
        'code': backupCodeController.text,
        if (clientId != null) 'clientId': clientId,
      });
      if (resp.statusCode == 200) {
        setState(() {
          _status = 'Backup code accepted! ';
          GoRouter.of(context).go('/app/settings/webauthn');
          _loading = false;
        });
      } else if (resp.statusCode == 429) {
        final waitTime = resp.data['message'];
        setState(() {
          _status = 'Too many attempts. Please wait $waitTime seconds.';
          _waitTime = waitTime is int ? waitTime : int.tryParse(waitTime.toString());
          _loading = false;
        });
        _waitTimer?.cancel();
        if (_waitTime != null && _waitTime! > 0) {
          _waitTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
            if (_waitTime != null && _waitTime! > 1) {
              setState(() {
                _waitTime = _waitTime! - 1;
              });
            } else {
              timer.cancel();
              setState(() {
                _waitTime = null;
              });
            }
          });
        }
      } else {
        setState(() {
          _status = 'Invalid backup code. Please try again.';
          _loading = false;
        });
      }
    } catch (e) {
      print('Error fetching backup codes: $e');
    }
  }
  final TextEditingController serverController = TextEditingController();
  String? _status;
  bool _loading = false;

  @override
  void dispose() {
    _waitTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return const SizedBox.shrink();
    return Scaffold(
      backgroundColor: const Color(0xFF2C2F33),
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(20),
          width: 350,
          decoration: BoxDecoration(
            color: const Color(0xFF23272A),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Backup Code', style: TextStyle(fontSize: 20, color: Colors.white)),
              const SizedBox(height: 20),
              const Text(
                'Enter one of your backup codes below to recover your account access. Each code can only be used once.',
                style: TextStyle(color: Colors.white, fontSize: 13),
                textAlign: TextAlign.left,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: backupCodeController,
                maxLines: 1,
                decoration: const InputDecoration(
                  hintText: 'your backup code',
                  filled: true,
                  fillColor: Color(0xFF40444B),
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 45),
                  backgroundColor: Colors.deepPurple,
                ),
                onPressed: (_waitTime != null && _waitTime! > 0) ? null : () {
                  _verifyBackupCode();
                },
                child: (_waitTime != null && _waitTime! > 0)
                    ? Text('Recover your account (${_waitTime!} seconds)')
                    : const Text('Recover your account'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
