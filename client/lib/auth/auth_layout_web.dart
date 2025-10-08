import 'package:flutter/material.dart';
import 'package:app_links/app_links.dart';
import 'dart:async';
//import 'package:http/http.dart' as http;
//import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart';
//import 'package:url_launcher/url_launcher.dart';
//import 'package:flutter/services.dart';
import '../web_config.dart';
//import 'webauthn_js_web.dart';
import 'dart:js_interop';
//import 'package:js/js.dart';
import 'package:go_router/go_router.dart';
import 'package:dio/dio.dart';
import '../services/api_service.dart';
import '../services/clientid_web.dart';

@JS('webauthnLogin')
external JSPromise webauthnLoginJs(String serverUrl, String email);
@JS('onWebAuthnSuccess')
external set _onWebAuthnSuccess(AuthCallback callback);
@JS('onWebAuthnAbort')
external set _onWebAuthnAbort(AbortCallback callback);
@JS('window.localStorage.setItem')
external void localStorageSetItem(String key, String value);
@JS('window.localStorage.getItem')
external String? localStorageGetItem(String key);


@JS()
extension type AuthCallback(JSFunction _) {}
@JS()
extension type AbortCallback(JSFunction _) {}

void setupWebAuthnCallback(void Function(int) callback) {
  _onWebAuthnSuccess = AuthCallback((int status) {
    callback(status);
  }.toJS);
}

void setupWebAuthnAbortCallback(void Function(String) callback) {
  _onWebAuthnAbort = AbortCallback((String error) {
    callback(error);
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
  String? _lastEmail;

  @override
  void initState() {
    super.initState();
    final storedEmail = localStorageGetItem('email');
  if (storedEmail != null &&storedEmail.isNotEmpty) {
    _lastEmail = storedEmail;
    emailController.text = storedEmail;
  }
  emailController.addListener(() {
    _lastEmail = emailController.text.trim();
    localStorageSetItem('email', _lastEmail!);
  });
    _sub = _appLinks.uriLinkStream.listen((Uri? uri) async {
      if (uri != null && uri.scheme == 'peerwave' && uri.host == 'login') {
        final token = uri.queryParameters['token'];
        final serverUrl = serverController.text.trim();
        final deviceId = await _getDeviceId();
        if (token != null && serverUrl.isNotEmpty) {
          try {
            final resp = await ApiService.post(
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
    Future<void> sendClientIdToServer(String host) async {
      final clientId = await ClientIdService.getClientId();
      print('Sending clientId to server: $clientId');
      ApiService.init();
      final dio = ApiService.dio;
      await dio.post('$host/client/addweb', data: {'clientId': clientId});
    }
    // Setup JS callback for WebAuthn abort using dart:js_interop
    setupWebAuthnAbortCallback((error) {
      print('WebAuthn aborted: $error');
      setState(() {
        _loginStatus = 'WebAuthn aborted: $error';
      });
    });
    // Setup JS callback for WebAuthn success using dart:js_interop
    setupWebAuthnCallback((status) async {
      print('STATUS: $status');
      if (status == 200) {
        setState(() {
          _loginStatus = 'Login successful! Status: $status';
        });
        final uri = Uri.base;
        final fromParam = uri.queryParameters['from'];
        final apiServer = await loadWebApiServer();
        String urlString = apiServer ?? '';
        if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
          urlString = 'https://$urlString';
        }
        sendClientIdToServer(urlString);
        if (fromParam == 'magic-link') {
          context.go('/magic-link');
        } else {
          context.go('/app');
        }
      } else if (status == 401) {
        final apiServer = await loadWebApiServer();
        String urlString = apiServer ?? '';
        if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
          urlString = 'https://$urlString';
        }
        print('lastEMail: $_lastEmail');
        setState(() {
          _loginStatus = 'Login failed with status: $status';
        });
        context.go('/otp', extra: {'email': _lastEmail ?? '', 'serverUrl': urlString, 'wait': 0});
      } else if (status == 202) {
        final apiServer = await loadWebApiServer();
        String urlString = apiServer ?? '';
        if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
          urlString = 'https://$urlString';
        }
        sendClientIdToServer(urlString);
        context.go('/app/settings/backupcode/list');
      } else {
        setState(() {
          _loginStatus = 'Login failed with status: $status';
        });
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
              if (_loginStatus != null) ...[
                Container(
                  key: ValueKey(_loginStatus),
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: _loginStatus!.contains('Login successful')
                        ? Colors.green.shade700
                        : Colors.red.shade900,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _loginStatus!,
                        style: const TextStyle(color: Colors.white),
                      ),
                      if (_loginStatus!.contains('WebAuthn aborted') || _loginStatus!.contains('Login failed')) ...[
                        const SizedBox(height: 8),
                        Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () {
                              context.go('/backupcode/recover');
                            },
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 2, horizontal: 0),
                              child: Text(
                                'Start recovery process',
                                style: TextStyle(
                                  color: Colors.blueAccent,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
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
                  _lastEmail = email;
                  localStorageSetItem('email', email);
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
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: () async {
                    try {
                      final email = emailController.text.trim();
                      final apiServer = await loadWebApiServer();
                      String urlString = apiServer ?? '';
                      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
                        urlString = 'https://$urlString';
                      }
                      //ApiService.init();
                      //final dio = ApiService.dio;
                      final resp = await ApiService.post(
                        '$urlString/register',
                        data: {
                          'email': email
                        }
                      );
                      if (resp.statusCode == 200) {
                        final data = resp.data;
                        if (data['status'] == "otp") {
                          GoRouter.of(context).go('/otp', extra: {'email': email, 'serverUrl': urlString, 'wait': int.parse(data['wait'].toString())});
                        }
                        if (data['status'] == "waitotp") {
                          GoRouter.of(context).go('/otp', extra: {'email': email, 'serverUrl': urlString, 'wait': int.parse(data['wait'].toString())});
                        }
                        if(data['status'] == "recovery") {
                          GoRouter.of(context).go('/recovery', extra: {'email': email, 'serverUrl': urlString});
                        }
                        setState(() {
                          _loginStatus = null;
                        });
                      } else {
                        String errorMsg = 'Error: ${resp.statusCode} ${resp.statusMessage}';
                        if (resp.data != null && resp.data is Map && resp.data['error'] != null) {
                          errorMsg = resp.data['error'];
                        } else if (resp.data != null && resp.data is String && resp.data.isNotEmpty) {
                          errorMsg = resp.data;
                        }
                        setState(() {
                          _loginStatus = errorMsg;
                        });
                      }
                    } on DioError catch (e) {
                      String errorMsg = 'Network error';
                      if (e.response != null && e.response?.data != null) {
                        if (e.response?.data is Map && e.response?.data['error'] != null) {
                          errorMsg = e.response?.data['error'];
                        } else if (e.response?.data is String && (e.response?.data as String).isNotEmpty) {
                          errorMsg = e.response?.data;
                        }
                      } else if (e.message != null) {
                        errorMsg = e.message!;
                      }
                      setState(() {
                        _loginStatus = errorMsg;
                      });
                    } catch (e) {
                      setState(() {
                        _loginStatus = 'Unexpected error: $e';
                      });
                    }
                  },
                  child: const Text('Register'),
                ),
              // ...existing code...
            ],
          ),
        ),
      ),
    );
  }
}
