import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:web/web.dart' as web;
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
      if (!urlString.startsWith('http://') &&
          !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      // Try to include clientId if available (helps server attach device info immediately)
      String? clientId;
      try {
        // Reuse the same web client id service via JS localStorage (set earlier in AuthLayout)
        final jsClientId = web.window.localStorage.getItem('clientId');
        clientId = jsClientId;
      } catch (_) {}
      final resp = await ApiService.instance.post(
        '/backupcode/verify',
        data: {
          'code': backupCodeController.text,
          if (clientId != null) 'clientId': clientId,
        },
      );
      if (resp.statusCode == 200) {
        setState(() {
          GoRouter.of(context).go('/app/settings/webauthn');
        });
      } else if (resp.statusCode == 429) {
        final waitTime = resp.data['message'];
        setState(() {
          _waitTime = waitTime is int
              ? waitTime
              : int.tryParse(waitTime.toString());
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
        // Invalid backup code - no action needed, user can try again
      }
    } catch (e) {
      debugPrint('Error fetching backup codes: $e');
    }
  }

  final TextEditingController serverController = TextEditingController();

  @override
  void dispose() {
    _waitTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(20),
          width: 350,
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Backup Code',
                style: TextStyle(fontSize: 20, color: colorScheme.onSurface),
              ),
              const SizedBox(height: 20),
              Text(
                'Enter one of your backup codes below to recover your account access. Each code can only be used once.',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
                textAlign: TextAlign.left,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: backupCodeController,
                maxLines: 1,
                decoration: InputDecoration(
                  hintText: 'your backup code',
                  filled: true,
                  fillColor: colorScheme.surfaceContainerHighest,
                  border: const OutlineInputBorder(),
                ),
                style: TextStyle(color: colorScheme.onSurface),
              ),
              const SizedBox(height: 10),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 45),
                ),
                onPressed: (_waitTime != null && _waitTime! > 0)
                    ? null
                    : () {
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
