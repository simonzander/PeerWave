import 'dart:convert';
import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;
import '../services/api_service.dart';
import '../web_config.dart';

/// Backup Code page for Settings (WITH sidebar, WITHOUT progress bar)
class BackupCodeSettingsPage extends StatefulWidget {
  const BackupCodeSettingsPage({super.key});

  @override
  State<BackupCodeSettingsPage> createState() => _BackupCodeSettingsPageState();
}

class _BackupCodeSettingsPageState extends State<BackupCodeSettingsPage> {
  final TextEditingController backupCodesController = TextEditingController();
  String? _status;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _fetchBackupCodes();
  }

  Future<void> _fetchBackupCodes() async {
    setState(() {
      _loading = true;
    });

    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') &&
          !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final resp = await ApiService.get('/backupcode/list');
      if (resp.statusCode == 200 && resp.data != null) {
        final data = resp.data is String ? json.decode(resp.data) : resp.data;
        if (data is Map && data['backupCodes'] is List) {
          backupCodesController.text = data['backupCodes'].join('\n');
        }
      }
    } catch (e) {
      debugPrint('Error fetching backup codes: $e');
      setState(() {
        _status = 'Error loading backup codes';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            padding: const EdgeInsets.all(32),
            constraints: const BoxConstraints(maxWidth: 600),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Backup Codes',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                Text(
                  'Each backup code is valid once. If you lost your passkey, you can login with a backup code. The backup codes are saved encrypted on the server and can\'t be decrypted anymore. Please save your backup codes in a safe place like a key vault (1Password, Bitwarden, KeePass etc.). If you lost access to your passkeys and backup codes you can\'t login to your account anymore. Support through the administration is not possible for security reasons.',
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.left,
                ),
                const SizedBox(height: 24),

                // Backup Codes Display
                TextField(
                  controller: backupCodesController,
                  maxLines: 8,
                  readOnly: true,
                  decoration: InputDecoration(
                    hintText: 'Loading backup codes...',
                    filled: true,
                    fillColor: colorScheme.surfaceContainerHighest,
                    border: const OutlineInputBorder(),
                  ),
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontFamily: 'monospace',
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 20),

                // Copy to Clipboard Button
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.copy),
                  onPressed: _loading
                      ? null
                      : () async {
                          await Clipboard.setData(
                            ClipboardData(text: backupCodesController.text),
                          );
                          setState(() {
                            _status = 'Backup codes copied to clipboard!';
                          });

                          // Clear status after 3 seconds
                          Future.delayed(const Duration(seconds: 3), () {
                            if (mounted) {
                              setState(() {
                                _status = null;
                              });
                            }
                          });
                        },
                  label: const Text(
                    'Copy to Clipboard',
                    style: TextStyle(fontSize: 16),
                  ),
                ),
                const SizedBox(height: 12),

                // Download as .txt Button
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.download),
                  onPressed: _loading
                      ? null
                      : () {
                          final text = backupCodesController.text;
                          final bytes = utf8.encode(text);
                          final blob = web.Blob([bytes.toJS].toJS);
                          final url = web.URL.createObjectURL(blob);
                          final anchor =
                              web.document.createElement('a')
                                  as web.HTMLAnchorElement;
                          anchor.href = url;
                          anchor.download = 'backup_codes.txt';
                          web.document.body!.append(anchor);
                          anchor.click();
                          anchor.remove();
                          web.URL.revokeObjectURL(url);

                          setState(() {
                            _status = 'Backup codes downloaded!';
                          });

                          // Clear status after 3 seconds
                          Future.delayed(const Duration(seconds: 3), () {
                            if (mounted) {
                              setState(() {
                                _status = null;
                              });
                            }
                          });
                        },
                  label: const Text(
                    'Download as .txt',
                    style: TextStyle(fontSize: 16),
                  ),
                ),

                // Status Message
                if (_status != null) ...[
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colorScheme.primary),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle, color: colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _status!,
                            style: TextStyle(color: colorScheme.primary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Loading Indicator
                if (_loading) ...[
                  const SizedBox(height: 20),
                  Center(
                    child: CircularProgressIndicator(
                      color: colorScheme.primary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    backupCodesController.dispose();
    super.dispose();
  }
}
