import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class MagicLinkWebPageWithServer extends StatefulWidget {
  final String serverUrl;
  const MagicLinkWebPageWithServer({Key? key, required this.serverUrl}) : super(key: key);

  @override
  State<MagicLinkWebPageWithServer> createState() => _MagicLinkWebPageWithServerState();
}

class _MagicLinkWebPageWithServerState extends State<MagicLinkWebPageWithServer> {
  @override
  Widget build(BuildContext context) {
    return MagicLinkWebPageWithInjectedServer(serverUrl: widget.serverUrl);
  }
}

// Internal widget to inject serverUrl into MagicLinkWebPage
class MagicLinkWebPageWithInjectedServer extends StatefulWidget {
  final String serverUrl;
  const MagicLinkWebPageWithInjectedServer({Key? key, required this.serverUrl}) : super(key: key);

  @override
  State<MagicLinkWebPageWithInjectedServer> createState() => _MagicLinkWebPageWithInjectedServerState();
}

class _MagicLinkWebPageWithInjectedServerState extends State<MagicLinkWebPageWithInjectedServer> {
  @override
  Widget build(BuildContext context) {
    return MagicLinkWebPageWithServerUrl(serverUrl: widget.serverUrl);
  }
}

// MagicLinkWebPage with serverUrl injected into controller
class MagicLinkWebPageWithServerUrl extends MagicLinkWebPage {
  final String serverUrl;
  MagicLinkWebPageWithServerUrl({Key? key, required this.serverUrl}) : super(key: key);

  @override
  State<MagicLinkWebPage> createState() => _MagicLinkWebPageWithServerUrlState();
}

class _MagicLinkWebPageWithServerUrlState extends _MagicLinkWebPageState {
  @override
  void initState() {
    super.initState();
    serverController.text = (widget as MagicLinkWebPageWithServerUrl).serverUrl;
  }
}

class MagicLinkWebPage extends StatefulWidget {
  const MagicLinkWebPage({super.key});

  @override
  State<MagicLinkWebPage> createState() => _MagicLinkWebPageState();
}

class _MagicLinkWebPageState extends State<MagicLinkWebPage> {
  final TextEditingController magicKeyController = TextEditingController();
  final TextEditingController serverController = TextEditingController();
  String? _status;
  bool _loading = false;

  Future<void> _evaluateMagicKey() async {
    final magicKey = magicKeyController.text.trim();
    final serverUrl = serverController.text.trim();
    if (magicKey.isEmpty || serverUrl.isEmpty) {
      setState(() {
        _status = 'Please enter both magic key and server URL.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _status = null;
    });
    try {
      final url = Uri.parse('$serverUrl/magic/evaluate');
      final resp = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'magic_key': magicKey}),
      );
      if (resp.statusCode == 200) {
        setState(() {
          _status = 'Magic key evaluated successfully!';
        });
      } else {
        setState(() {
          _status = 'Error: ${resp.body}';
        });
      }
    } catch (e) {
      setState(() {
        _status = 'Evaluation failed: $e';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
  // Show UI on all platforms
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
              const Text('Evaluate Magic Key', style: TextStyle(fontSize: 20, color: Colors.white)),
              const SizedBox(height: 20),
              TextField(
                controller: magicKeyController,
                decoration: const InputDecoration(
                  hintText: 'Magic Key',
                  filled: true,
                  fillColor: Color(0xFF40444B),
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(color: Colors.white),
                minLines: 3,
                maxLines: 8,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 45),
                  backgroundColor: Colors.blueAccent,
                ),
                onPressed: _loading ? null : _evaluateMagicKey,
                child: _loading ? const CircularProgressIndicator(color: Colors.white) : const Text('Evaluate Key'),
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
