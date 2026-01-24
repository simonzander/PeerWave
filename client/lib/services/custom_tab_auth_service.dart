import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:app_links/app_links.dart';
import 'api_service.dart';
import 'session_auth_service.dart';
import 'clientid_native.dart';
import 'device_identity_service.dart';
import 'native_crypto_service.dart';
import 'secure_session_storage.dart';
import 'server_config_native.dart';
import 'auth_service_native.dart';

/// Service for handling authentication via Chrome Custom Tabs
///
/// Flow:
/// 1. Open Chrome Custom Tab with /auth/passkey?from=app
/// 2. User authenticates with WebAuthn in browser
/// 3. Server redirects to peerwave://auth/callback?token=XYZ
/// 4. App receives deep link and exchanges token for session
class CustomTabAuthService {
  static final CustomTabAuthService instance = CustomTabAuthService._();
  CustomTabAuthService._();

  final _appLinks = AppLinks();
  StreamSubscription? _linkSub;
  Completer<String?>? _authCompleter;
  Completer<bool>? _loginCompleter;
  Timer? _timeoutTimer;

  /// Check if there's an active authenticate() call waiting for a token
  bool get hasAuthCompleter =>
      _authCompleter != null && !_authCompleter!.isCompleted;

  /// Start listening for auth callback deep links
  void initialize() {
    _linkSub = _appLinks.uriLinkStream.listen(
      (Uri uri) {
        debugPrint('[CustomTabAuth] Deep link received: $uri');

        if (uri.scheme == 'peerwave' &&
            uri.host == 'auth' &&
            uri.path == '/callback') {
          final token = uri.queryParameters['token'];
          final cancelled = uri.queryParameters['cancelled'];

          if (cancelled == 'true') {
            debugPrint('[CustomTabAuth] ✗ User cancelled authentication');
            _completeAuth(null);
          } else if (token != null && token.isNotEmpty) {
            debugPrint('[CustomTabAuth] ✓ Auth token received from callback');
            _completeAuth(token);
          } else {
            debugPrint('[CustomTabAuth] ✗ Callback missing token parameter');
            _completeAuth(null);
          }
        }
      },
      onError: (err) {
        debugPrint('[CustomTabAuth] Deep link error: $err');
        _completeAuth(null);
      },
    );

    debugPrint('[CustomTabAuth] Deep link listener initialized');
  }

  /// Stop listening for auth callbacks
  void dispose() {
    _linkSub?.cancel();
    _linkSub = null;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    debugPrint('[CustomTabAuth] Deep link listener disposed');
  }

  /// Complete the authentication flow
  void _completeAuth(String? token) {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;

    if (_authCompleter != null && !_authCompleter!.isCompleted) {
      _authCompleter!.complete(token);
      _authCompleter = null;
    }
  }

  /// Cancel any in-progress authentication
  void cancelAuth() {
    if (_authCompleter != null) {
      debugPrint('[CustomTabAuth] ⚠️ Cancelling previous auth attempt');
      _completeAuth(null);
    }
    if (_loginCompleter != null && !_loginCompleter!.isCompleted) {
      _loginCompleter!.complete(false);
      _loginCompleter = null;
    }
  }

  /// Manually complete authentication with a token (called by router)
  void completeWithToken(String? token) {
    debugPrint('[CustomTabAuth] 📥 Manually completing auth with token');
    _completeAuth(token);
  }

  /// Wait for login completion (finishLogin to complete)
  ///
  /// Returns a Future that completes when finishLogin() succeeds or fails
  /// Must be called before the token exchange starts
  Future<bool> waitForLoginComplete() async {
    _loginCompleter = Completer<bool>();
    return await _loginCompleter!.future;
  }

  /// Start passkey authentication in Chrome Custom Tab
  ///
  /// Opens browser with /auth/passkey?from=app and waits for callback
  /// Returns authentication token on success, null on failure/timeout
  Future<String?> startPasskeyLogin({
    required String serverUrl,
    String? email,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    // Cancel any existing auth attempt before starting a new one
    if (_authCompleter != null) {
      debugPrint(
        '[CustomTabAuth] ⚠️ Auth already in progress - cancelling previous attempt',
      );
      cancelAuth();
    }

    _authCompleter = Completer<String?>();

    // Set timeout
    _timeoutTimer = Timer(timeout, () {
      debugPrint('[CustomTabAuth] ⏱️ Auth timeout after ${timeout.inSeconds}s');
      _completeAuth(null);
    });

    try {
      // Build URL with hash-based routing: #/login?from=app&email=...
      // Query parameters MUST be after the hash for Flutter web routing to work
      final queryParams = <String, String>{'from': 'app'};
      if (email != null && email.isNotEmpty) {
        queryParams['email'] = email;
      }

      // Build query string manually
      final queryString = queryParams.entries
          .map(
            (e) =>
                '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
          )
          .join('&');

      // Use Flutter web login page with hash routing
      final uri = Uri.parse('$serverUrl/#/login?$queryString');

      debugPrint('[CustomTabAuth] Opening Custom Tab: $uri');

      if (!await launchUrl(
        uri,
        mode: LaunchMode.externalApplication, // Opens in Chrome Custom Tab
      )) {
        debugPrint('[CustomTabAuth] ✗ Failed to launch URL');
        _completeAuth(null);
        return null;
      }

      debugPrint(
        '[CustomTabAuth] ✓ Custom Tab opened, waiting for callback...',
      );
      return await _authCompleter!.future;
    } catch (e) {
      debugPrint('[CustomTabAuth] Error: $e');
      _completeAuth(null);
      return null;
    }
  }

  /// Exchange auth token for session
  ///
  /// Validates token with server and establishes authenticated session
  Future<bool> finishLogin({
    required String token,
    required String serverUrl,
  }) async {
    try {
      debugPrint('[CustomTabAuth] Exchanging token for session...');

      // Get client ID for HMAC session
      final clientId = await ClientIdService.getClientId();

      debugPrint('[CustomTabAuth] POST $serverUrl/token/exchange');

      // Exchange token for session
      final response = await ApiService.dio.post(
        '$serverUrl/token/exchange',
        data: {'token': token, 'clientId': clientId},
      );

      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        final sessionSecret = data['sessionSecret'] as String?;
        final userId = data['userId'] as String?;
        final email = data['email'] as String?;
        final credentialId = data['credentialId'] as String?;
        final refreshToken = data['refreshToken'] as String?;

        if (sessionSecret != null && userId != null) {
          // Store HMAC session for authenticated API requests
          await SessionAuthService().initializeSession(
            clientId,
            sessionSecret,
            serverUrl: serverUrl,
          );
          debugPrint('[CustomTabAuth] ✓ Session established for user $userId');

          final storage = SecureSessionStorage();
          await storage.saveClientId(clientId);

          // Store session expiry (90 days for HMAC session)
          final sessionExpiryDate = DateTime.now().add(Duration(days: 90));
          await storage.saveSessionExpiry(
            sessionExpiryDate.toIso8601String(),
            serverUrl: serverUrl,
          );

          // Store refresh token if available
          if (refreshToken != null) {
            await storage.saveRefreshToken(refreshToken, serverUrl: serverUrl);
            debugPrint('[CustomTabAuth] ✓ Refresh token stored');
          }

          // Set device identity if we have all required info
          if (email != null && credentialId != null) {
            await DeviceIdentityService.instance.setDeviceIdentity(
              email,
              credentialId,
              clientId,
              serverUrl:
                  serverUrl, // Required for multi-server support on native
            );
            debugPrint('[CustomTabAuth] ✓ Device identity set for $email');

            // Derive encryption key from credentialId
            final deviceId = DeviceIdentityService.instance.deviceId;
            if (deviceId != null) {
              await NativeCryptoService.instance.deriveKeyFromCredentialId(
                deviceId,
                credentialId,
              );
              debugPrint('[CustomTabAuth] ✓ Encryption key derived and stored');
            }
          } else {
            debugPrint(
              '[CustomTabAuth] ⚠ Missing credentialId, device identity not set',
            );
          }

          // Save server configuration (prevents redirect to server selection)
          await ServerConfigService.addServer(
            serverUrl: serverUrl,
            credentials: sessionSecret,
            // displayName will be auto-generated from serverUrl if not provided
          );
          debugPrint('[CustomTabAuth] ✓ Server configuration saved');

          // Set login flag to true (required for router redirect logic)
          AuthService.isLoggedIn = true;
          debugPrint('[CustomTabAuth] ✓ AuthService.isLoggedIn = true');

          // Complete login completer if waiting
          if (_loginCompleter != null && !_loginCompleter!.isCompleted) {
            _loginCompleter!.complete(true);
            _loginCompleter = null;
          }

          return true;
        }
      }

      debugPrint(
        '[CustomTabAuth] ✗ Token exchange failed: ${response.statusCode}',
      );
      // Complete login completer with failure
      if (_loginCompleter != null && !_loginCompleter!.isCompleted) {
        _loginCompleter!.complete(false);
        _loginCompleter = null;
      }
      return false;
    } catch (e) {
      debugPrint('[CustomTabAuth] Error exchanging token: $e');
      // Complete login completer with failure
      if (_loginCompleter != null && !_loginCompleter!.isCompleted) {
        _loginCompleter!.complete(false);
        _loginCompleter = null;
      }
      return false;
    }
  }

  /// Complete authentication flow: open Custom Tab and exchange token
  ///
  /// Convenience method that combines startPasskeyLogin and finishLogin
  Future<bool> authenticate({
    required String serverUrl,
    String? email,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final token = await startPasskeyLogin(
      serverUrl: serverUrl,
      email: email,
      timeout: timeout,
    );

    if (token == null) {
      debugPrint('[CustomTabAuth] ✗ No token received');
      return false;
    }

    return await finishLogin(token: token, serverUrl: serverUrl);
  }

  /// Revoke a JWT token
  ///
  /// Invalidates the token on the server before it expires
  /// Useful for logout or security incidents
  Future<bool> revokeToken({
    required String token,
    required String serverUrl,
  }) async {
    try {
      debugPrint('[CustomTabAuth] Revoking token...');

      final response = await ApiService.dio.post(
        '$serverUrl/auth/token/revoke',
        data: {'token': token},
      );

      if (response.statusCode == 200) {
        debugPrint('[CustomTabAuth] ✓ Token revoked successfully');
        return true;
      }

      debugPrint(
        '[CustomTabAuth] ✗ Token revocation failed: ${response.statusCode}',
      );
      return false;
    } catch (e) {
      debugPrint('[CustomTabAuth] Error revoking token: $e');
      return false;
    }
  }
}
