
import 'dart:convert';
import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:web/web.dart' as web;
import '../services/api_service.dart';
import '../web_config.dart';
import '../widgets/registration_progress_bar.dart';


class BackupCodeListPage extends StatefulWidget {
  const BackupCodeListPage({super.key});

  @override
  State<BackupCodeListPage> createState() => _BackupCodeListPageState();
}

class _BackupCodeListPageState extends State<BackupCodeListPage> {
  final TextEditingController backupCodesController = TextEditingController();
  bool _acknowledged = false;
  @override
  void initState() {
    super.initState();
    _fetchBackupCodes();
  }


  Future<void> _fetchBackupCodes() async {
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final resp = await ApiService.get('$urlString/backupcode/list');
      if (resp.statusCode == 200 && resp.data != null) {
        final data = resp.data is String ? json.decode(resp.data) : resp.data;
        if (data is Map && data['backupCodes'] is List) {
          backupCodesController.text = data['backupCodes'].join('\n');
        }
      }
    } catch (e) {
      debugPrint('Error fetching backup codes: $e');
    }
  }
  final TextEditingController serverController = TextEditingController();
  String? _status;
  final bool _loading = false;

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    
    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Column(
        children: [
          // Progress Bar
          const RegistrationProgressBar(currentStep: 2),
          // Content
          Expanded(
            child: Center(
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
                    Text('Backup Codes', style: TextStyle(fontSize: 20, color: colorScheme.onSurface)),
                    const SizedBox(height: 20),
                    Text(
                      'Each backup code is valid once. If you lost your passkey, you can login with a backup code. The backup codes are saved encrypted on the server and can\'t be decrypted anymore. Please save your backup codes on safe place like a key vault (1Password, bitwarden, KeePass etc.) If you lost your access to your passkeys and backup codes you can\'t login to your account anymore. Keep this in your mind. Support through the administration is not possible through security reasons.',
                      style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13),
                      textAlign: TextAlign.left,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: backupCodesController,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: 'your backup codes',
                        filled: true,
                        fillColor: colorScheme.surfaceContainerHighest,
                        border: const OutlineInputBorder(),
                      ),
                      style: TextStyle(color: colorScheme.onSurface),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(double.infinity, 45),
                      ),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: backupCodesController.text));
                        setState(() {
                          _status = 'Backup codes copied to clipboard!';
                        });
                      },
                      child: _loading ? CircularProgressIndicator(color: colorScheme.onPrimary) : const Text('Copy Backup Codes to Clipboard'),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 45),
                      ),
                      onPressed: () {
                        final text = backupCodesController.text;
                        final bytes = utf8.encode(text);
                        final blob = web.Blob([bytes.toJS].toJS);
                        final url = web.URL.createObjectURL(blob);
                        final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
                        anchor.href = url;
                        anchor.download = 'backup_codes.txt';
                        web.document.body!.append(anchor);
                        anchor.click();
                        anchor.remove();
                        web.URL.revokeObjectURL(url);
                      },
                      child: const Text('Download as .txt'),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Checkbox(
                          value: _acknowledged,
                          onChanged: (val) {
                            setState(() {
                              _acknowledged = val ?? false;
                            });
                          },
                        ),
                        Expanded(
                          child: Text(
                            "I know the backup codes can't be retrieved again. I downloaded / copied the codes and stored them safe.",
                            style: TextStyle(color: colorScheme.onSurface),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(double.infinity, 45),
                      ),
                      onPressed: _acknowledged ? () {
                        GoRouter.of(context).go('/register/webauthn');
                      } : null,
                      child: const Text('Next'),
                    ),
                    if (_status != null) ...[
                      const SizedBox(height: 20),
                      Text(_status!, style: TextStyle(color: colorScheme.primary)),
                    ],
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

