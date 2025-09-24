import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../services/auth_service_native.dart';
import 'package:go_router/go_router.dart';

class MagicLinkWebPageWithServer extends StatefulWidget {
  final String serverUrl;
  final String? clientId;

  const MagicLinkWebPageWithServer({Key? key, required this.serverUrl, this.clientId}) : super(key: key);

  @override
  State<MagicLinkWebPageWithServer> createState() => _MagicLinkWebPageWithServerState();
}

class _MagicLinkWebPageWithServerState extends State<MagicLinkWebPageWithServer> {
  @override
  Widget build(BuildContext context) {
    print('[MagicLinkWebPageWithServer] clientId: ${widget.clientId}');
    return MagicLinkWebPageWithInjectedServer(serverUrl: widget.serverUrl, clientId: widget.clientId);
  }
}

// Internal widget to inject serverUrl into MagicLinkWebPage
class MagicLinkWebPageWithInjectedServer extends StatefulWidget {
  final String serverUrl;
  final String? clientId;
  const MagicLinkWebPageWithInjectedServer({Key? key, required this.serverUrl, this.clientId}) : super(key: key);

  @override
  State<MagicLinkWebPageWithInjectedServer> createState() => _MagicLinkWebPageWithInjectedServerState();
}

class _MagicLinkWebPageWithInjectedServerState extends State<MagicLinkWebPageWithInjectedServer> {
  @override
  Widget build(BuildContext context) {
    print('[MagicLinkWebPageWithInjectedServer] clientId: ${widget.clientId}');
    return MagicLinkWebPageWithServerUrl(serverUrl: widget.serverUrl, clientId: widget.clientId);
  }
}

// MagicLinkWebPage with serverUrl injected into controller
class MagicLinkWebPageWithServerUrl extends MagicLinkWebPage {
  final String serverUrl;
  final String? clientId;

  MagicLinkWebPageWithServerUrl({Key? key, required this.serverUrl, this.clientId}) : super(key: key, clientId: clientId);

  @override
  State<MagicLinkWebPage> createState() => _MagicLinkWebPageWithServerUrlState();
}

class _MagicLinkWebPageWithServerUrlState extends _MagicLinkWebPageState {
  @override
  void initState() {
    super.initState();
    print('[MagicLinkWebPageWithServerUrl] clientId: ${(widget as MagicLinkWebPageWithServerUrl).clientId}');
    serverController.text = (widget as MagicLinkWebPageWithServerUrl).serverUrl;
  }
}

class MagicLinkWebPage extends StatefulWidget {
  final String? clientId;
  const MagicLinkWebPage({super.key, this.clientId});

  @override
  State<MagicLinkWebPage> createState() => _MagicLinkWebPageState();
}

class _MagicLinkWebPageState extends State<MagicLinkWebPage> {
  final TextEditingController magicKeyController = TextEditingController();
  final TextEditingController serverController = TextEditingController();
  String? _status;
  bool _loading = false;

  String hexToString(String hex) {
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return String.fromCharCodes(bytes);
  }

  @override
  void initState() {
    super.initState();
    print('[MagicLinkWebPage] clientId: ${widget.clientId}');
  }

  Future<void> _evaluateMagicKey() async {
    final magicKey = magicKeyController.text.trim();
    final serverUrl = serverController.text.trim();
    final clientId = widget.clientId; // Use the passed clientId
    print('[MagicLinkWebPageState:_evaluateMagicKey] clientId: $clientId');
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
      print('[try block] clientId: $clientId');
      final keyHex = magicKey.substring(0, 64); // First 64 chars = 32 bytes key
      final serverHexInfo = magicKey.substring(64); // Rest = hostname in hex
      print('Server Hex Info: $serverHexInfo'); // Debug output
      final decodedServerInfo = hexToString(serverHexInfo);
      print( 'Decoded Server Info: $decodedServerInfo'); // Debug output
      final Map<String, dynamic> jsonData = jsonDecode(decodedServerInfo);
      print(jsonData); // Debug output
      final String hostname = jsonData['serverUrl'] ?? '';
      final String mail = jsonData['mail'] ?? '';
      //final url = Uri.parse('http://localhost:3000/magic/verify');
      final url = Uri.parse('$hostname/magic/verify');
      final resp = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'key': keyHex, 'clientid': clientId}),
      );
      print('Request URL: $url');
      print('Status: ${resp.statusCode}');
      print('Headers: ${resp.headers}');
      print('Body: ${resp.body}');
      if (resp.statusCode == 200) {
        await AuthService().saveHostMailList(hostname, mail); // <-- Add host to persistent list
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
    // ...existing UI code...
    return Scaffold(
      backgroundColor: const Color(0xFF2C2F33),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            GoRouter.of(context).go("/app");
          },
        ),
        title: const Text('Magic Key Evaluation'),
      ),
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