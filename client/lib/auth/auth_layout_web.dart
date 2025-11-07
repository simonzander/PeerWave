import 'package:flutter/material.dart';
import 'package:app_links/app_links.dart';
import 'dart:async';
//import 'package:http/http.dart' as http;
//import 'dart:convert';
import 'package:flutter/foundation.dart';
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
import 'package:google_fonts/google_fonts.dart';
import '../services/webauthn_service.dart';

@JS('webauthnLogin')
external JSPromise webauthnLoginJs(String serverUrl, String email, String clientId);
@JS('onWebAuthnSuccess')
external set _onWebAuthnSuccess(AuthCallback callback);
@JS('onWebAuthnAbort')
external set _onWebAuthnAbort(AbortCallback callback);
@JS('onWebAuthnSignature')
external set _onWebAuthnSignature(SignatureCallback callback);
@JS('window.localStorage.setItem')
external void localStorageSetItem(String key, String value);
@JS('window.localStorage.getItem')
external String? localStorageGetItem(String key);


@JS()
extension type AuthCallback(JSFunction _) {}
@JS()
extension type AbortCallback(JSFunction _) {}
@JS()
extension type SignatureCallback(JSFunction _) {}

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

void setupWebAuthnSignatureCallback(void Function(String, String) callback) {
  _onWebAuthnSignature = SignatureCallback((String credentialId, String signature) {
    callback(credentialId, signature);
  }.toJS);
}

class AuthLayout extends StatefulWidget {
  final String? clientId;  // Optional - will be fetched/created after login
  const AuthLayout({super.key, this.clientId});

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
    // NOTE: clientId is no longer persisted here - it's managed after login
    // The clientId will be fetched/created after WebAuthn authentication
    // and stored paired with the user's email address
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
    
    // Setup JS callback for WebAuthn abort using dart:js_interop
    setupWebAuthnAbortCallback((error) {
      debugPrint('WebAuthn aborted: $error');
      setState(() {
        _loginStatus = 'WebAuthn aborted: $error';
      });
    });
    
    // Setup JS callback for WebAuthn signature capture
    setupWebAuthnSignatureCallback((credentialId, signature) async {
      debugPrint('[AUTH] WebAuthn signature captured');
      try {
        await WebAuthnService.instance.captureWebAuthnResponse(credentialId, signature);
        debugPrint('[AUTH] ✓ WebAuthn signature stored for encryption');
      } catch (e) {
        debugPrint('[AUTH] ✗ Failed to capture WebAuthn signature: $e');
      }
    });
    
    // Setup JS callback for WebAuthn success using dart:js_interop
    setupWebAuthnCallback((status) async {
      debugPrint('STATUS: $status');
      if (status == 200) {
        setState(() {
          _loginStatus = 'Login successful! Status: $status';
        });
        
        // Fetch/create client ID for this email (locally, no API call)
        final email = _lastEmail ?? '';
        final clientId = await ClientIdService.getClientIdForEmail(email);
        debugPrint('[AUTH] Client ID for $email: $clientId');
        
        // Initialize device encryption with WebAuthn signature
        try {
          debugPrint('[AUTH] Initializing device encryption...');
          await WebAuthnService.instance.initializeDeviceEncryption(email, clientId);
          debugPrint('[AUTH] ✓ Device encryption initialized');
        } catch (e) {
          debugPrint('[AUTH] ✗ Failed to initialize device encryption: $e');
          setState(() {
            _loginStatus = 'Login successful, but encryption setup failed: $e';
          });
        }
        
        final uri = Uri.base;
        final fromParam = uri.queryParameters['from'];
        
        // Navigate to /app - PostLoginInitService will handle the rest
        debugPrint('[AUTH] ✓ Navigating to /app (initialization will continue there)');
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
        debugPrint('lastEMail: $_lastEmail');
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
        // Client ID already stored locally during login
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

  Future<void> webauthnLogin(String serverUrl, String email, String clientId) async {
    if (kIsWeb) {
      await webauthnLoginJs(serverUrl, email, clientId).toDart;
    } else {
      debugPrint('WebAuthn is only available on Flutter web.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    
    // Responsive width based on screen size
    final screenWidth = MediaQuery.of(context).size.width;
    final cardWidth = screenWidth < 600 
        ? screenWidth * 0.9  // Mobile: 90% of screen width
        : screenWidth < 840
            ? 400.0  // Tablet: fixed 400px
            : 450.0; // Desktop: fixed 450px
    
    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Container(
            padding: const EdgeInsets.all(24),
            width: cardWidth,
            constraints: const BoxConstraints(maxWidth: 500),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: colorScheme.shadow.withOpacity(0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                  SizedBox(
                    height: 96,
                    width: 96,
                    child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Image.asset(
                      'assets/images/peerwave.png',
                      fit: BoxFit.contain,
                    ),
                    ),
                  ),
                  Text(
                    "PeerWave",
                    style: GoogleFonts.nunitoSans(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w200, // ExtraLight statt w100
                      fontSize: 56,
                      letterSpacing: -2.0, // Macht es optisch dünner
                    ),
                  ),
                  ],
                ),
                const SizedBox(height: 24),
              if (_loginStatus != null) ...[
                Container(
                  key: ValueKey(_loginStatus),
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: _loginStatus!.contains('Login successful')
                        ? colorScheme.primaryContainer
                        : colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _loginStatus!.contains('Login successful')
                          ? colorScheme.primary
                          : colorScheme.error,
                      width: 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _loginStatus!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: _loginStatus!.contains('Login successful')
                              ? colorScheme.onPrimaryContainer
                              : colorScheme.onErrorContainer,
                        ),
                      ),
                      if (_loginStatus!.contains('WebAuthn aborted') || _loginStatus!.contains('Login failed')) ...[
                        const SizedBox(height: 8),
                        Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () {
                              context.go('/backupcode/recover');
                            },
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 0),
                              child: Text(
                                'Start recovery process',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: colorScheme.primary,
                                  decoration: TextDecoration.underline,
                                  fontWeight: FontWeight.w500,
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
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: "Email",
                    hintText: "Enter your email address",
                    filled: true,
                    fillColor: colorScheme.surfaceContainerHigh,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: colorScheme.outline),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: colorScheme.outline),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: colorScheme.primary, width: 2),
                    ),
                    prefixIcon: Icon(Icons.email, color: colorScheme.onSurfaceVariant),
                  ),
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
              const SizedBox(height: 24),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 52),
                  backgroundColor: colorScheme.primary,
                  foregroundColor: colorScheme.onPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 2,
                ),
                onPressed: () async {
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
                      
                      // Fetch/create client ID for this email (locally, no API call)
                      final clientId = await ClientIdService.getClientIdForEmail(email);
                      debugPrint('[AUTH] Using client ID: $clientId for email: $email');
                      
                      // ClientId is passed directly to WebAuthn JS function (no localStorage needed)
                      await webauthnLogin(urlString, email, clientId);
                    } catch (e) {
                      debugPrint('WebAuthn JS call failed: $e');
                    }
                  }
                },
                child: Text(
                  "Login",
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 52),
                  foregroundColor: colorScheme.primary,
                  side: BorderSide(color: colorScheme.outline),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
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
                  child: Text(
                    'Register',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

