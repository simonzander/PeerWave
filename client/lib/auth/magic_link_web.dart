import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class MagicLinkWebPage extends StatefulWidget {
  const MagicLinkWebPage({super.key});

  @override
  State<MagicLinkWebPage> createState() => _MagicLinkWebPageState();
}

class _MagicLinkWebPageState extends State<MagicLinkWebPage> {
  final TextEditingController emailController = TextEditingController();
  final TextEditingController serverController = TextEditingController();
  String? _status;
  bool _loading = false;

  Future<void> _requestMagicLink() async {
    final email = emailController.text.trim();
    final serverUrl = serverController.text.trim();
    if (email.isEmpty || serverUrl.isEmpty) {
      setState(() {
        _status = 'Please enter both email and server URL.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _status = null;
    });
    try {
      final url = Uri.parse('$serverUrl/magic/request');
      final resp = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      );
      if (resp.statusCode == 200) {
        setState(() {
          _status = 'Magic link sent! Check your email.';
        });
      } else {
        setState(() {
          _status = 'Error: ${resp.body}';
        });
      }
    } catch (e) {
      setState(() {
        _status = 'Request failed: $e';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

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
              const Text('Request Magic Link', style: TextStyle(fontSize: 20, color: Colors.white)),
              const SizedBox(height: 20),
              TextField(
                controller: emailController,
                decoration: const InputDecoration(
                  hintText: 'Email',
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
                onPressed: _loading ? null : _requestMagicLink,
                child: _loading ? const CircularProgressIndicator(color: Colors.white) : const Text('Request Link'),
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
