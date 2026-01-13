import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';

/// Native implementation for BackupCodeSettingsPage
/// Backup codes are available for mobile WebAuthn (iOS/Android)
/// Desktop native uses magic key authentication (no backup codes)
class BackupCodeSettingsPage extends StatefulWidget {
  const BackupCodeSettingsPage({super.key});

  @override
  State<BackupCodeSettingsPage> createState() => _BackupCodeSettingsPageState();
}

class _BackupCodeSettingsPageState extends State<BackupCodeSettingsPage> {
  final TextEditingController backupCodesController = TextEditingController();
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final isMobile = Platform.isIOS || Platform.isAndroid;
    if (isMobile) {
      _fetchBackupCodes();
    } else {
      _loading = false;
    }
  }

  Future<void> _fetchBackupCodes() async {
    try {
      final resp = await ApiService.get('/backupcode/list');
      if (resp.statusCode == 200 && resp.data != null) {
        final data = resp.data is String ? json.decode(resp.data) : resp.data;
        if (data is Map && data['backupCodes'] is List) {
          setState(() {
            backupCodesController.text = data['backupCodes'].join('\n');
            _loading = false;
          });
        }
      }
    } catch (e) {
      debugPrint('Error fetching backup codes: $e');
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _regenerateBackupCodes() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final resp = await ApiService.post('/backupcode/regenerate', data: {});
      if (resp.statusCode == 200 && resp.data != null) {
        final data = resp.data is String ? json.decode(resp.data) : resp.data;
        if (data is Map && data['backupCodes'] is List) {
          setState(() {
            backupCodesController.text = data['backupCodes'].join('\n');
            _loading = false;
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Backup codes regenerated')),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('Error regenerating backup codes: $e');
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Check if platform is mobile (iOS or Android)
    final isMobile = Platform.isIOS || Platform.isAndroid;

    if (isMobile) {
      // Mobile: Show backup codes UI
      final colorScheme = Theme.of(context).colorScheme;

      return Scaffold(
        appBar: AppBar(title: const Text('Backup Codes')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Backup Codes',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Save these backup codes in a secure location. Each code can be used once if you lose access to your biometric authentication.',
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    if (_error != null)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _error!,
                          style: TextStyle(color: colorScheme.onErrorContainer),
                        ),
                      ),
                    if (_error != null) const SizedBox(height: 16),
                    Expanded(
                      child: TextField(
                        controller: backupCodesController,
                        maxLines: null,
                        readOnly: true,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          hintText: 'Your backup codes',
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: backupCodesController.text),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Copied to clipboard'),
                                ),
                              );
                            },
                            icon: const Icon(Icons.copy),
                            label: const Text('Copy'),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _regenerateBackupCodes,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Regenerate'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
      );
    }

    // Desktop: Show not available message
    return Scaffold(
      appBar: AppBar(title: const Text('Backup Codes')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline, size: 64, color: Colors.grey),
              SizedBox(height: 24),
              Text(
                'Backup Codes Not Available',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 16),
              Text(
                'Backup codes are only available for WebAuthn authentication (web and mobile apps).',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
              SizedBox(height: 8),
              Text(
                'This desktop client uses magic key authentication instead.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
