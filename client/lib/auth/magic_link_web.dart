import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// Remove http import, use JS interop for fetch
import 'dart:convert';
import 'package:js/js.dart';
import 'package:js/js_util.dart';

@JS('window.open')
external dynamic openWindow(String url, String target);

@JS('fetchMagicKey')
external dynamic fetchMagicKeyJS(String url);

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
      // Use JS interop to fetch magic key
      final jsPromise = fetchMagicKeyJS('http://localhost:3000/magic/generate');
      final jsResult = jsPromise != null ? await promiseToFuture(jsPromise) : null;
      // Expect JS to return a JSON string with magicKey
      print('JS Result: $jsResult');
      if (jsResult != null) {
        final data = json.decode(jsResult as String);
        if (data is Map && data['magicKey'] is String) {
          magicKeyController.text = data['magicKey'];
          final url = 'peerwave://?magicKey=${Uri.encodeComponent(data['magicKey'])}';
          openWindow(url, '_self');
        }
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
