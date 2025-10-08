import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// Remove http import, use JS interop for fetch
import 'dart:convert';
import 'package:js/js.dart';
//import 'package:js/js_util.dart';
import '../services/api_service.dart';
import '../web_config.dart';

@JS('window.open')
external dynamic openWindow(String url, String target);

/*@JS('fetchMagicKey')
external dynamic fetchMagicKeyJS(String url);*/

class MagicLinkWebPage extends StatefulWidget {
  const MagicLinkWebPage({super.key});

  @override
  State<MagicLinkWebPage> createState() => _MagicLinkWebPageState();
}

class _MagicLinkWebPageState extends State<MagicLinkWebPage> {
  final TextEditingController magicKeyController = TextEditingController();
  @override
  void initState() {
    super.initState();
    _fetchMagicKey();
  }


  Future<void> _fetchMagicKey() async {
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final resp = await ApiService.get('$urlString/magic/generate');
      if (resp.statusCode == 200 && resp.data != null) {
        final data = resp.data is String ? json.decode(resp.data) : resp.data;
        if (data is Map && data['magicKey'] is String) {
          magicKeyController.text = data['magicKey'];
          final url = 'peerwave://?magicKey=${Uri.encodeComponent(data['magicKey'])}';
          openWindow(url, '_self');
        }
      }
    } catch (e) {
      print('Error fetching magic key: $e');
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
              const Text('Magic Key', style: TextStyle(fontSize: 20, color: Colors.white)),
              const SizedBox(height: 20),
              TextField(
                controller: magicKeyController,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: 'your magic key',
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
                  await Clipboard.setData(ClipboardData(text: magicKeyController.text));
                  setState(() {
                  _status = 'Magic key copied to clipboard!';
                  });
                },
                child: _loading ? const CircularProgressIndicator(color: Colors.white) : const Text('Submit Key'),
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
