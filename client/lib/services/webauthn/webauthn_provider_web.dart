import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'webauthn_provider.dart';

/// WebAuthn result type
@JS()
extension type WebAuthnResult._(JSObject _) implements JSObject {
  external String? get credentialId;
  external String? get signature;
}

/// External JS functions
@JS('window.webauthnLogin')
external JSPromise<JSAny?> _webauthnLogin(
  String serverUrl,
  String email,
  String clientId,
);

@JS('window.webauthnRegister')
external JSPromise<JSAny?> _webauthnRegister(String serverUrl, String email);

/// Web implementation of WebAuthn using browser's navigator.credentials API
class WebAuthnProviderWeb implements IWebAuthnProvider {
  @override
  Future<bool> isAvailable() async {
    if (!kIsWeb) return false;

    // Check if PublicKeyCredential is supported
    // In modern browsers, credentials API is always available
    return true;
  }

  @override
  Future<Map<String, dynamic>?> register({
    required String serverUrl,
    required String email,
  }) async {
    if (!kIsWeb) return null;

    try {
      // Call the JavaScript function defined in index.html
      final promise = _webauthnRegister(serverUrl, email);

      // Wait for the promise to complete
      final result = await promise.toDart;

      if (result != null && result.isA<JSObject>()) {
        final webauthnResult = result as WebAuthnResult;
        final credentialId = webauthnResult.credentialId;
        final signature = webauthnResult.signature;

        if (credentialId != null && signature != null) {
          return {
            'credentialId': credentialId,
            'signature': signature,
            'success': true,
          };
        }
      }

      return null;
    } catch (e) {
      debugPrint('[WebAuthnProviderWeb] Registration error: $e');
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>?> authenticate({
    required String serverUrl,
    required String email,
    required String clientId,
  }) async {
    if (!kIsWeb) return null;

    try {
      // Call the JavaScript function defined in index.html
      final promise = _webauthnLogin(serverUrl, email, clientId);

      // Wait for the promise to complete
      final result = await promise.toDart;

      if (result != null && result.isA<JSObject>()) {
        final webauthnResult = result as WebAuthnResult;
        final credentialId = webauthnResult.credentialId;
        final signature = webauthnResult.signature;

        if (credentialId != null && signature != null) {
          return {
            'credentialId': credentialId,
            'signature': signature,
            'success': true,
          };
        }
      }

      return null;
    } catch (e) {
      debugPrint('[WebAuthnProviderWeb] Authentication error: $e');
      return null;
    }
  }

  @override
  Future<bool> hasCredential({
    required String serverUrl,
    required String email,
  }) async {
    // On web, credentials are stored in the browser's credential manager
    // We can't check directly, so we assume they exist if WebAuthn is available
    return await isAvailable();
  }

  @override
  Future<void> deleteCredential({
    required String serverUrl,
    required String email,
  }) async {
    // Web credentials are managed by the browser, can't be deleted programmatically
    debugPrint(
      '[WebAuthnProviderWeb] Credential deletion not supported on web',
    );
  }
}
