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
import '../services/server_settings_service.dart';

@JS('webauthnLogin')
external JSPromise webauthnLoginJs(
  String serverUrl,
  String email,
  String clientId,
  bool fromCustomTab,
);
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
@JS('window.location.hash')
external String? getWindowLocationHash();

// JS function to change window location (for deep links)
@JS('eval')
external void jsEval(String code);

@JS()
extension type AuthCallback(JSFunction _) {}
@JS()
extension type AbortCallback(JSFunction _) {}
@JS()
extension type SignatureCallback(JSFunction _) {}

void setupWebAuthnCallback(void Function(int, String?) callback) {
  _onWebAuthnSuccess = AuthCallback(
    (int status, [String? token]) {
      callback(status, token);
    }.toJS,
  );
}

void setupWebAuthnAbortCallback(void Function(String) callback) {
  _onWebAuthnAbort = AbortCallback(
    (String error) {
      callback(error);
    }.toJS,
  );
}

void setupWebAuthnSignatureCallback(void Function(String, String) callback) {
  _onWebAuthnSignature = SignatureCallback(
    (String credentialId, String signature) {
      callback(credentialId, signature);
    }.toJS,
  );
}

class AuthLayout extends StatefulWidget {
  final String? clientId; // Optional - will be fetched/created after login
  final bool fromApp;
  final String? initialEmail;

  const AuthLayout({
    super.key,
    this.clientId,
    this.fromApp = false,
    this.initialEmail,
  });

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
  Map<String, dynamic>? _serverSettings;
  bool _loadingSettings = true;
  bool _isFromMobileApp = false;
  bool _callbackInProgress = false;
  String? _callbackToken;
  // String? _mobileAppEmail; // Reserved for future use

  @override
  void initState() {
    super.initState();

    // Prefer query params provided by GoRouter (works reliably with hash routing).
    _isFromMobileApp = widget.fromApp;
    final initialEmailFromRoute = widget.initialEmail?.trim();
    final hasInitialEmailFromRoute =
        initialEmailFromRoute != null && initialEmailFromRoute.isNotEmpty;

    debugPrint(
      '[AUTH] ctor params: fromApp=${widget.fromApp}, initialEmail=$initialEmailFromRoute',
    );

    if (hasInitialEmailFromRoute) {
      final email = initialEmailFromRoute;
      _lastEmail = email;
      emailController.text = email;
      localStorageSetItem('email', email);
    }

    // In web + hash routing, the fragment/query can be finalized slightly after
    // Flutter initializes. Checking after the first frame avoids missing params.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _checkIfFromMobileApp();
    });
    // Load server settings
    _loadServerSettings();
    // NOTE: clientId is no longer persisted here - it's managed after login
    // The clientId will be fetched/created after WebAuthn authentication
    // and stored paired with the user's email address
    final storedEmail = localStorageGetItem('email');
    if (!hasInitialEmailFromRoute &&
        storedEmail != null &&
        storedEmail.isNotEmpty) {
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
        await WebAuthnService.instance.captureWebAuthnResponse(
          credentialId,
          signature,
        );
        debugPrint('[AUTH] ✓ WebAuthn signature stored for encryption');
      } catch (e) {
        debugPrint('[AUTH] ✗ Failed to capture WebAuthn signature: $e');
      }
    });

    // Setup JS callback for WebAuthn success using dart:js_interop
    setupWebAuthnCallback((status, token) async {
      debugPrint('STATUS: $status, has token: ${token != null}');
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
          await WebAuthnService.instance.initializeDeviceEncryption(
            email,
            clientId,
          );
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
        debugPrint(
          '[AUTH] ✓ Navigating to /app (initialization will continue there)',
        );
        if (!mounted) return;

        // If opened from mobile app, redirect back with deep link
        if (_isFromMobileApp) {
          debugPrint('[AUTH] Login successful, redirecting to mobile app');
          // Use token from authentication response (server already generated it)
          if (kIsWeb) {
            if (token != null) {
              debugPrint(
                '[AUTH] Using token from auth response, redirecting to app',
              );
              setState(() {
                _callbackInProgress = true;
                _callbackToken = token;
              });
              _triggerAppCallback(token);
            } else {
              debugPrint('[AUTH] No token in response, auth failed');
              jsEval(
                "window.location.href = 'peerwave://auth/callback?cancelled=true';",
              );
            }
          }
        } else if (fromParam == 'magic-link') {
          context.go('/magic-link');
        } else {
          context.go('/app');
        }
      } else if (status == 401) {
        final apiServer = await loadWebApiServer();
        String urlString = apiServer ?? '';
        if (!urlString.startsWith('http://') &&
            !urlString.startsWith('https://')) {
          urlString = 'https://$urlString';
        }
        debugPrint('lastEMail: $_lastEmail');
        setState(() {
          _loginStatus = 'Login failed with status: $status';
        });
        if (!mounted) return;
        context.go(
          '/otp',
          extra: {'email': _lastEmail ?? '', 'serverUrl': urlString, 'wait': 0},
        );
      } else if (status == 202) {
        final apiServer = await loadWebApiServer();
        String urlString = apiServer ?? '';
        if (!urlString.startsWith('http://') &&
            !urlString.startsWith('https://')) {
          urlString = 'https://$urlString';
        }
        // Client ID already stored locally during login
        if (!mounted) return;
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

  /// Trigger callback to mobile app with token
  void _triggerAppCallback(String token) {
    try {
      jsEval(
        "window.location.href = 'peerwave://auth/callback?token=${Uri.encodeComponent(token)}';",
      );
    } catch (e) {
      debugPrint('[AUTH] Failed to trigger callback: $e');
      setState(() {
        _loginStatus = 'Failed to callback app: $e';
      });
    }
  }

  /// Check if opened from mobile app via Chrome Custom Tab
  void _checkIfFromMobileApp() {
    if (!kIsWeb) return;

    final qp = GoRouterState.of(context).uri.queryParameters;
    final fromRaw = qp['from'];
    if (fromRaw == null) {
      // Don't override constructor-provided value if the router hasn't
      // provided query params for some reason.
      return;
    }

    final fromApp = fromRaw.trim().toLowerCase() == 'app';
    final emailParam = qp['email']?.trim();

    debugPrint(
      '[AUTH] GoRouter params: from=${qp['from']}, email=${qp['email']}',
    );
    debugPrint('[AUTH] Final result - From app: $fromApp, Email: $emailParam');

    if (!mounted) return;
    setState(() {
      _isFromMobileApp = fromApp;
      if (fromApp && emailParam != null && emailParam.isNotEmpty) {
        _lastEmail = emailParam;
        emailController.text = emailParam;
        localStorageSetItem('email', emailParam);
      }
    });
  }

  Future<void> _loadServerSettings() async {
    try {
      final settings = await ServerSettingsService.instance.getSettings();
      setState(() {
        _serverSettings = settings;
        _loadingSettings = false;
      });
    } catch (e) {
      debugPrint('[AUTH] Failed to load server settings: $e');
      setState(() => _loadingSettings = false);
    }
  }

  bool _validateEmailSuffix(String email, List suffixes) {
    if (suffixes.isEmpty) return true;
    final domain = email.split('@').last.toLowerCase();
    return suffixes.any(
      (suffix) => domain.endsWith(suffix.toString().toLowerCase()),
    );
  }

  Future<void> _proceedWithRegistration(String email) async {
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') &&
          !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final resp = await ApiService.post('/register', data: {'email': email});
      if (resp.statusCode == 200) {
        final data = resp.data;
        if (!mounted) return;
        if (data['status'] == "otp") {
          GoRouter.of(context).go(
            '/otp',
            extra: {
              'email': email,
              'serverUrl': urlString,
              'wait': int.parse(data['wait'].toString()),
            },
          );
        }
        if (data['status'] == "waitotp") {
          if (!mounted) return;
          GoRouter.of(context).go(
            '/otp',
            extra: {
              'email': email,
              'serverUrl': urlString,
              'wait': int.parse(data['wait'].toString()),
            },
          );
        }
        if (data['status'] == "recovery") {
          if (!mounted) return;
          GoRouter.of(
            context,
          ).go('/recovery', extra: {'email': email, 'serverUrl': urlString});
        }
        setState(() {
          _loginStatus = null;
        });
      } else {
        String errorMsg = 'Error: ${resp.statusCode} ${resp.statusMessage}';
        if (resp.data != null &&
            resp.data is Map &&
            resp.data['error'] != null) {
          errorMsg = resp.data['error'];
        } else if (resp.data != null &&
            resp.data is String &&
            resp.data.isNotEmpty) {
          errorMsg = resp.data;
        }
        setState(() {
          _loginStatus = errorMsg;
        });
      }
    } on DioException catch (e) {
      String errorMsg = 'Network error';
      if (e.response != null && e.response?.data != null) {
        if (e.response?.data is Map && e.response?.data['error'] != null) {
          errorMsg = e.response?.data['error'];
        } else if (e.response?.data is String &&
            (e.response?.data as String).isNotEmpty) {
          errorMsg = e.response?.data;
        }
      } else if (e.message != null && e.message!.isNotEmpty) {
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
  }

  Future<String> _getDeviceId() async {
    // For demo, use a random string. Replace with real device/hardware ID in production.
    return 'native-demo-${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<void> webauthnLogin(
    String serverUrl,
    String email,
    String clientId,
  ) async {
    if (kIsWeb) {
      debugPrint(
        '[AUTH] Calling webauthnLoginJs with serverUrl: $serverUrl, email: $email',
      );
      try {
        await webauthnLoginJs(
          serverUrl,
          email,
          clientId,
          _isFromMobileApp,
        ).toDart;
        debugPrint('[AUTH] webauthnLoginJs completed');
      } catch (e) {
        debugPrint('[AUTH] webauthnLoginJs error: $e');
        setState(() {
          _loginStatus = 'WebAuthn error: $e';
        });
      }
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
        ? screenWidth *
              0.9 // Mobile: 90% of screen width
        : screenWidth < 840
        ? 400.0 // Tablet: fixed 400px
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
                  color: colorScheme.shadow.withValues(alpha: 0.1),
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
                  Builder(
                    builder: (context) {
                      final status = _loginStatus!;
                      final isSuccess = status.contains('Login successful');
                      final isError =
                          status.contains('WebAuthn aborted') ||
                          status.contains('Login failed');

                      return Container(
                        key: ValueKey(status),
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: isSuccess
                              ? colorScheme.primaryContainer
                              : colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSuccess
                                ? colorScheme.primary
                                : colorScheme.error,
                            width: 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              status,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: isSuccess
                                    ? colorScheme.onPrimaryContainer
                                    : colorScheme.onErrorContainer,
                              ),
                            ),
                            if (isError) ...[
                              const SizedBox(height: 8),
                              Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () {
                                    context.go('/backupcode/recover');
                                  },
                                  borderRadius: BorderRadius.circular(4),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 4,
                                      horizontal: 0,
                                    ),
                                    child: Text(
                                      'Start recovery process',
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: colorScheme.primary,
                                            decoration:
                                                TextDecoration.underline,
                                            fontWeight: FontWeight.w500,
                                          ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
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
                        borderSide: BorderSide(
                          color: colorScheme.primary,
                          width: 2,
                        ),
                      ),
                      prefixIcon: Icon(
                        Icons.email,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurface,
                    ),
                  ),
                const SizedBox(height: 24),
                // Show callback status if in progress
                if (_callbackInProgress && _isFromMobileApp) ...[
                  // Show callback in progress message
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: colorScheme.primary.withOpacity(0.3),
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.sync, size: 48, color: colorScheme.primary),
                        const SizedBox(height: 16),
                        Text(
                          'Trying to callback the app...',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'If the app doesn\'t open automatically, use the retry button below',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onPrimaryContainer.withOpacity(
                              0.8,
                            ),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
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
                    onPressed: () {
                      if (_callbackToken != null) {
                        debugPrint('[AUTH] Retry button pressed');
                        _triggerAppCallback(_callbackToken!);
                      }
                    },
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.refresh, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          'Retry',
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (!_callbackInProgress)
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
                      debugPrint('[AUTH] Login button pressed');
                      final email = emailController.text.trim();
                      debugPrint('[AUTH] Email: $email');
                      _lastEmail = email;
                      localStorageSetItem('email', email);
                      if (kIsWeb) {
                        try {
                          final apiServer = await loadWebApiServer();
                          debugPrint('[AUTH] API Server: $apiServer');
                          String urlString = apiServer ?? '';
                          if (!urlString.startsWith('http://') &&
                              !urlString.startsWith('https://')) {
                            urlString = 'https://$urlString';
                          }

                          // Fetch/create client ID for this email (locally, no API call)
                          final clientId =
                              await ClientIdService.getClientIdForEmail(email);
                          debugPrint(
                            '[AUTH] Using client ID: $clientId for email: $email',
                          );

                          // ClientId is passed directly to WebAuthn JS function (no localStorage needed)
                          debugPrint('[AUTH] About to call webauthnLogin...');
                          await webauthnLogin(urlString, email, clientId);
                          debugPrint('[AUTH] webauthnLogin call completed');
                        } catch (e) {
                          debugPrint('WebAuthn JS call failed: $e');
                          setState(() {
                            _loginStatus = 'Login error: $e';
                          });
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
                if (!_callbackInProgress) ...[
                  const SizedBox(height: 16),
                  // Show Register OR Abort button based on context
                  if (_isFromMobileApp)
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 52),
                        foregroundColor: colorScheme.error,
                        side: BorderSide(color: colorScheme.outline),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        // Redirect back to app with cancellation
                        if (kIsWeb) {
                          debugPrint('[AUTH] User aborted from mobile');
                          try {
                            jsEval(
                              "window.location.href = 'peerwave://auth/callback?cancelled=true';",
                            );
                          } catch (e) {
                            debugPrint(
                              '[AUTH] Failed to trigger deep link: $e',
                            );
                            context.go('/');
                          }
                        }
                      },
                      child: Text(
                        "Abort",
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  else
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 52),
                        foregroundColor: colorScheme.primary,
                        side: BorderSide(color: colorScheme.outline),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: _loadingSettings
                          ? null
                          : () async {
                              final email = emailController.text.trim();

                              // Validate email format
                              if (email.isEmpty || !email.contains('@')) {
                                setState(
                                  () => _loginStatus = 'Invalid email address',
                                );
                                return;
                              }

                              // Check registration mode
                              final mode =
                                  _serverSettings?['registrationMode'] ??
                                  'open';

                              // Handle email_suffix mode
                              if (mode == 'email_suffix') {
                                final suffixes =
                                    _serverSettings?['allowedEmailSuffixes']
                                        as List? ??
                                    [];
                                if (!_validateEmailSuffix(email, suffixes)) {
                                  setState(
                                    () => _loginStatus =
                                        'Registration is restricted to specific email domains',
                                  );
                                  return;
                                }
                              }

                              // Handle invitation_only mode
                              if (mode == 'invitation_only') {
                                context.go(
                                  '/register/invitation',
                                  extra: {'email': email},
                                );
                                return;
                              }

                              // Open mode or email_suffix passed validation
                              await _proceedWithRegistration(email);
                            },
                      child: Text(
                        'Register',
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
                // About this server link
                const SizedBox(height: 24),
                TextButton(
                  onPressed: () => _showAboutServerDialog(context),
                  child: Text(
                    'About this server',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      decoration: TextDecoration.underline,
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

  Future<void> _showAboutServerDialog(BuildContext context) async {
    try {
      // Fetch server metadata including operator info
      final resp = await ApiService.get('/client/meta');
      if (resp.statusCode == 200) {
        final data = resp.data;
        final serverOperator = data['serverOperator'] as Map<String, dynamic>?;

        if (!mounted) return;

        showDialog(
          context: context,
          builder: (BuildContext context) {
            final theme = Theme.of(context);
            final colorScheme = theme.colorScheme;

            return AlertDialog(
              title: Text(
                'About this server',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'This PeerWave instance is hosted by',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (serverOperator?['owner'] != null) ...[
                      _buildInfoRow(
                        'Server Owner',
                        serverOperator!['owner'],
                        theme,
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (serverOperator?['contact'] != null) ...[
                      _buildInfoRow(
                        'Contact',
                        serverOperator!['contact'],
                        theme,
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (serverOperator?['location'] != null) ...[
                      _buildInfoRow(
                        'Location',
                        serverOperator!['location'],
                        theme,
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (serverOperator?['additionalInfo'] != null) ...[
                      _buildInfoRow(
                        'Additional Information',
                        serverOperator!['additionalInfo'],
                        theme,
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (serverOperator?['owner'] == null &&
                        serverOperator?['contact'] == null &&
                        serverOperator?['location'] == null) ...[
                      Text(
                        'No operator information available',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    const Divider(),
                    const SizedBox(height: 16),
                    InkWell(
                      onTap: () {
                        // Open link in new tab (web only)
                        if (kIsWeb) {
                          jsEval(
                            "window.open('https://peerwave.org', '_blank')",
                          );
                        }
                      },
                      child: Text(
                        'Find more about PeerWave at peerwave.org',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.primary,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      }
    } catch (e) {
      debugPrint('[AUTH] Failed to load server info: $e');
    }
  }

  Widget _buildInfoRow(String label, String value, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(value, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}
