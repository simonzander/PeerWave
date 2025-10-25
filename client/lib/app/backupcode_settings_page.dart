import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;
import 'package:js/js_util.dart' as js_util;
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
      print('Error fetching backup codes: $e');
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
    return Scaffold(
      backgroundColor: const Color(0xFF36393F),
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            padding: const EdgeInsets.all(32),
            constraints: const BoxConstraints(maxWidth: 600),
            decoration: BoxDecoration(
              color: const Color(0xFF2C2F33),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Backup Codes',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                const Text(
                  'Each backup code is valid once. If you lost your passkey, you can login with a backup code. The backup codes are saved encrypted on the server and can\'t be decrypted anymore. Please save your backup codes in a safe place like a key vault (1Password, Bitwarden, KeePass etc.). If you lost access to your passkeys and backup codes you can\'t login to your account anymore. Support through the administration is not possible for security reasons.',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                  textAlign: TextAlign.left,
                ),
                const SizedBox(height: 24),
                
                // Backup Codes Display
                TextField(
                  controller: backupCodesController,
                  maxLines: 8,
                  readOnly: true,
                  decoration: const InputDecoration(
                    hintText: 'Loading backup codes...',
                    filled: true,
                    fillColor: Color(0xFF40444B),
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 20),
                
                // Copy to Clipboard Button
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                    backgroundColor: Colors.blueAccent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.copy),
                  onPressed: _loading ? null : () async {
                    await Clipboard.setData(ClipboardData(text: backupCodesController.text));
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
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                    backgroundColor: Colors.deepPurple,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.download),
                  onPressed: _loading ? null : () {
                    final text = backupCodesController.text;
                    final bytes = utf8.encode(text);
                    final jsArray = js_util.jsify([bytes]);
                    final blob = web.Blob(jsArray);
                    final url = js_util.callMethod(
                      js_util.getProperty(web.window, 'URL'),
                      'createObjectURL',
                      [blob],
                    ) as String;
                    final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
                    anchor.href = url;
                    anchor.download = 'backup_codes.txt';
                    web.document.body!.append(anchor);
                    anchor.click();
                    anchor.remove();
                    js_util.callMethod(
                      js_util.getProperty(web.window, 'URL'),
                      'revokeObjectURL',
                      [url],
                    );
                    
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
                      color: Colors.green.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.green),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle, color: Colors.green),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _status!,
                            style: const TextStyle(color: Colors.green),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                
                // Loading Indicator
                if (_loading) ...[
                  const SizedBox(height: 20),
                  const Center(
                    child: CircularProgressIndicator(color: Colors.blueAccent),
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
