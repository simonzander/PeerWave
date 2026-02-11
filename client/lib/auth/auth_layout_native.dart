import 'package:flutter/material.dart';
import 'package:app_links/app_links.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
//import '../web_config.dart';
import 'webauthn_js_stub.dart';
import '../extensions/snackbar_extensions.dart';
import '../services/api_service.dart';

class AuthLayout extends StatefulWidget {
  // Deprecated legacy native login screen; kept to avoid breaking imports.
  const AuthLayout({
    super.key,
    this.clientId,
    this.fromApp = false,
    this.initialEmail,
  });

  final String? clientId;
  final bool fromApp;
  final String? initialEmail;

  @override
  State<AuthLayout> createState() => _AuthLayoutState();
}

class _AuthLayoutState extends State<AuthLayout> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final extra = GoRouterState.of(context).extra;
    if (extra is Map && extra['host'] is String) {
      final host = extra['host'] as String;
      if (serverController.text != host) {
        serverController.text = host;
      }
    }
  }

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
          try {
            final resp = await ApiService.instance.post(
              '$serverUrl/magic/verify',
              data: {'token': token, 'deviceId': deviceId},
            );
            if (resp.statusCode == 200) {
              setState(() {
                _loginStatus = 'Login successful!';
              });
              // TODO: Store session/token for future logins
            } else {
              setState(() {
                _loginStatus = 'Login failed: ${resp.data}';
              });
            }
          } catch (e) {
            setState(() {
              _loginStatus = 'Login failed: $e';
            });
          }
        }
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<String> _getDeviceId() async {
    // For demo, use a random string. Replace with real device/hardware ID in production.
    return 'native-demo-${DateTime.now().millisecondsSinceEpoch}';
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
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            GoRouter.of(context).go("/app");
          },
        ),
        title: const Text('Login'),
      ),
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
              const Text(
                "Login",
                style: TextStyle(fontSize: 20, color: Colors.white),
              ),
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
              const SizedBox(height: 20),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 45),
                  backgroundColor: Colors.blueAccent,
                ),
                onPressed: () async {
                  final serverUrl = serverController.text.trim();
                  String urlString = serverUrl;
                  if (!urlString.startsWith('http://') &&
                      !urlString.startsWith('https://')) {
                    urlString = 'https://$urlString';
                  }
                  if (urlString.endsWith('/')) {
                    urlString = urlString.substring(0, urlString.length - 1);
                  }
                  final url = Uri.parse('$urlString/#/login?from=magic-link');
                  if (await canLaunchUrl(url)) {
                    await launchUrl(url, mode: LaunchMode.externalApplication);
                    if (mounted) {
                      // Use GoRouter to navigate to /magic-link and pass serverUrl as extra
                      // ignore: use_build_context_synchronously
                      GoRouter.of(context).go('/magic-link', extra: urlString);
                    }
                  } else {
                    setState(() {
                      _loginStatus = urlString;
                    });
                  }
                },
                child: const Text("Login"),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 45),
                  backgroundColor: Colors.greenAccent,
                ),
                onPressed: () {
                  GoRouter.of(context).go('/magic-link');
                },
                child: const Text("Evaluate Magic Key"),
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
                        style: TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: TextEditingController(
                                text: _loginStatus!,
                              ),
                              readOnly: true,
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  vertical: 8,
                                  horizontal: 8,
                                ),
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
                              Clipboard.setData(
                                ClipboardData(text: _loginStatus!),
                              );
                              context.showSuccessSnackBar(
                                'URL copied to clipboard!',
                              );
                            },
                            child: const Icon(
                              Icons.copy,
                              color: Colors.white,
                              size: 20,
                            ),
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
