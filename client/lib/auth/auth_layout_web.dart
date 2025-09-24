import 'package:flutter/material.dart';
import 'package:app_links/app_links.dart';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/foundation.dart';
//import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import '../web_config.dart';
//import 'webauthn_js_web.dart';
import 'dart:js_interop';
//import 'package:js/js.dart';
import 'package:go_router/go_router.dart';
@JS('webauthnLogin')
external JSPromise webauthnLoginJs(String serverUrl, String email);
@JS('onWebAuthnSuccess')
external set _onWebAuthnSuccess(AuthCallback callback);

@JS()
extension type AuthCallback(JSFunction _) {}

void setupWebAuthnCallback(void Function(int) callback) {
  _onWebAuthnSuccess = AuthCallback((int status) {
    callback(status);
  }.toJS);
}

class AuthLayout extends StatefulWidget {
  const AuthLayout({super.key});

  @override
  State<AuthLayout> createState() => _AuthLayoutState();
}

class _AuthLayoutState extends State<AuthLayout> {
  final TextEditingController emailController = TextEditingController();
  final TextEditingController serverController = TextEditingController();
  StreamSubscription<Uri>? _sub;
  final AppLinks _appLinks = AppLinks();
  String? _loginStatus;

  @override
  void initState() {
    super.initState();
    _sub = _appLinks.uriLinkStream.listen((Uri? uri) async {
      if (uri != null && uri.scheme == 'peerwave' && uri.host == 'login') {
        final token = uri.queryParameters['token'];
        final serverUrl = serverController.text.trim();
        final deviceId = await _getDeviceId();
        if (token != null && serverUrl.isNotEmpty) {
          final resp = await http.post(
            Uri.parse('$serverUrl/magic/verify'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'token': token, 'deviceId': deviceId}),
          );
          if (resp.statusCode == 200) {
            setState(() {
              _loginStatus = 'Login successful!';
            });
            // TODO: Store session/token for future logins
          } else {
            setState(() {
              _loginStatus = 'Login failed: ${resp.body}';
            });
          }
        }
      }
    });
    // Setup JS callback for WebAuthn success using dart:js_interop
    setupWebAuthnCallback((status) {
      setState(() {
        
        _loginStatus = 'Login successful! Status: $status';
        if(status == 200) {
          final uri = Uri.base;
          final fromParam = uri.queryParameters['from'];
          if (fromParam == 'magic-link') {
            context.go('/magic-link');
          } else {
            context.go('/app');
          }
        }
        // Handle token, e.g. store, navigate, etc.
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<String> _getDeviceId() async {
    // For demo, use a random string. Replace with real device/hardware ID in production.
    return 'native-demo-' + DateTime.now().millisecondsSinceEpoch.toString();
  }

  Future<void> webauthnLogin(String serverUrl, String email) async {
    if (kIsWeb) {
      await webauthnLoginJs(serverUrl, email).toDart;
    } else {
      debugPrint('WebAuthn is only available on Flutter web.');
    }
  }

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
              if (kIsWeb)
                TextField(
                  controller: emailController,
                  decoration: const InputDecoration(
                    hintText: "Email",
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
                  final serverUrl = serverController.text.trim();
                  final email = emailController.text.trim();
                  if (kIsWeb) {
                    try {
                      final apiServer = await loadWebApiServer();
                      String urlString = apiServer ?? '';
                      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
                        urlString = 'https://$urlString';
                      }
                      await webauthnLogin(urlString, email);
                    } catch (e) {
                      debugPrint('WebAuthn JS call failed: $e');
                    }
                  }
                },
                child: const Text("Login"),
              ),
              if (_loginStatus != null) ...[
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.shade900,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Could not open the login URL. Please copy this in your browser instead:',
                        style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: TextEditingController(text: _loginStatus!),
                              readOnly: true,
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blueAccent,
                              minimumSize: const Size(40, 40),
                              padding: EdgeInsets.zero,
                            ),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: _loginStatus!));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('URL copied to clipboard!')),
                              );
                            },
                            child: const Icon(Icons.copy, color: Colors.white, size: 20),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
