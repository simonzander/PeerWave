
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
      print('Error fetching backup codes: $e');
    }
  }
  final TextEditingController serverController = TextEditingController();
  String? _status;
  bool _loading = false;

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
              const Text('Backup Codes', style: TextStyle(fontSize: 20, color: Colors.white)),
              const SizedBox(height: 20),
              const Text(
                'Each backup code is valid once. If you lost your passkey, you can login with a backup code. The backup codes are saved encrypted on the server and can\'t be decrypted anymore. Please save your backup codes on safe place like a key vault (1Password, bitwarden, KeePass etc.) If you lost your access to your passkeys and backup codes you can\'t login to your account anymore. Keep this in your mind. Support through the administration is not possible through security reasons.',
                style: TextStyle(color: Colors.white, fontSize: 13),
                textAlign: TextAlign.left,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: backupCodesController,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: 'your backup codes',
                  filled: true,
                  fillColor: Color(0xFF40444B),
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 45),
                  backgroundColor: Colors.blueAccent,
                ),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: backupCodesController.text));
                  setState(() {
                    _status = 'Backup codes copied to clipboard!';
                  });
                },
                child: _loading ? const CircularProgressIndicator(color: Colors.white) : const Text('Copy Backup Codes to Clipboard'),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 45),
                  backgroundColor: Colors.deepPurple,
                ),
                onPressed: () {
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
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 45),
                  backgroundColor: Colors.green,
                ),
                onPressed: _acknowledged ? () {
                  GoRouter.of(context).go('/app/settings/webauthn');
                } : null,
                child: const Text('Next'),
              ),
              if (_status != null) ...[
                const SizedBox(height: 20),
                Text(_status!, style: const TextStyle(color: Colors.green)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
