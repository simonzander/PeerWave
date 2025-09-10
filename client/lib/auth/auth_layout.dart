import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'webauthn_helper.dart'
  if (dart.library.js) 'webauthn_helper_web.dart';

class AuthLayout extends StatelessWidget {
  final TextEditingController emailController = TextEditingController();
  final TextEditingController serverController = TextEditingController();

  AuthLayout({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF2C2F33),
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(20),
          width: 300,
          decoration: BoxDecoration(
            color: const Color(0xFF23272A),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Login",
                  style: TextStyle(fontSize: 20, color: Colors.white)),
              const SizedBox(height: 20),
              TextField(
                controller: serverController,
                decoration: const InputDecoration(
                  hintText: "Server URL",
                  filled: true,
                  fillColor: Color(0xFF40444B),
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: emailController,
                decoration: const InputDecoration(
                  hintText: "E-Mail",
                  filled: true,
                  fillColor: Color(0xFF40444B),
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              // Password field removed for WebAuthn-only authentication
              const SizedBox(height: 20),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 45),
                  backgroundColor: Colors.blueAccent,
                ),
                onPressed: () async {
                  final serverUrl = serverController.text.trim();
                  final email = emailController.text.trim();
                  if (kIsWeb) {
                    try {
                      webauthnLogin(serverUrl, email);
                    } catch (e) {
                      debugPrint('WebAuthn JS call failed: $e');
                    }
                  } else {
                    debugPrint('WebAuthn is only available on Flutter web.');
                  }
                },
                child: const Text("Login"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
