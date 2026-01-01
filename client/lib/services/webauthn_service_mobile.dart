import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Mobile app secret for server authentication
/// This identifies the official PeerWave mobile app to the server
const String _kMobileAppSecret = 'peerwave-mobile-app-2026';

/// Mobile WebAuthn service for iOS and Android
///
/// Implements WebAuthn-like authentication using biometric hardware (Face ID, Touch ID, fingerprint).
/// Stores credentials securely in iOS Keychain or Android KeyStore via flutter_secure_storage.
class MobileWebAuthnService {
  static final MobileWebAuthnService instance = MobileWebAuthnService._();
  MobileWebAuthnService._();

  final LocalAuthentication _localAuth = LocalAuthentication();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  /// Check if biometric authentication is available on this device
  Future<bool> isBiometricAvailable() async {
    try {
      final bool canAuthenticateWithBiometrics =
          await _localAuth.canCheckBiometrics;
      final bool canAuthenticate =
          canAuthenticateWithBiometrics || await _localAuth.isDeviceSupported();
      return canAuthenticate;
    } catch (e) {
      debugPrint('[MobileWebAuthn] Error checking biometric availability: $e');
      return false;
    }
  }

  /// Get available biometric types
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _localAuth.getAvailableBiometrics();
    } catch (e) {
      debugPrint('[MobileWebAuthn] Error getting biometrics: $e');
      return [];
    }
  }

  /// Register a new WebAuthn credential with biometric authentication
  ///
  /// [serverUrl] - The PeerWave server URL
  /// [email] - User's email address
  /// Returns credential ID on success, null on failure
  Future<String?> register({
    required String serverUrl,
    required String email,
  }) async {
    try {
      debugPrint('[MobileWebAuthn] Starting registration for $email');

      // 1. Check biometric availability
      if (!await isBiometricAvailable()) {
        debugPrint('[MobileWebAuthn] Biometric authentication not available');
        return null;
      }

      // 2. Request registration challenge from server
      final challengeResponse = await http.post(
        Uri.parse('$serverUrl/webauthn/register-challenge'),
        headers: {
          'Content-Type': 'application/json',
          'X-PeerWave-App-Secret': _kMobileAppSecret,
        },
        body: jsonEncode({'email': email}),
      );

      if (challengeResponse.statusCode != 200) {
        debugPrint(
          '[MobileWebAuthn] Failed to get challenge: ${challengeResponse.statusCode}',
        );
        return null;
      }

      final challengeData = jsonDecode(challengeResponse.body);
      final challenge = challengeData['challenge'] as String;
      debugPrint('[MobileWebAuthn] Received challenge from server');

      // 3. Prompt biometric authentication
      final bool authenticated = await _localAuth.authenticate(
        localizedReason: 'Register your device for PeerWave',
      );

      if (!authenticated) {
        debugPrint('[MobileWebAuthn] Biometric authentication failed');
        return null;
      }

      // 4. Generate credential ID (stable identifier for this device)
      final credentialId = _generateCredentialId(email, challenge);
      debugPrint(
        '[MobileWebAuthn] Generated credential ID: ${credentialId.substring(0, 16)}...',
      );

      // 5. Create attestation object (simulated for mobile)
      final attestation = _createAttestationObject(
        credentialId: credentialId,
        challenge: challenge,
        email: email,
      );

      // 6. Send attestation to server
      final registerResponse = await http.post(
        Uri.parse('$serverUrl/webauthn/register'),
        headers: {
          'Content-Type': 'application/json',
          'X-PeerWave-App-Secret': _kMobileAppSecret,
        },
        body: jsonEncode(attestation),
      );

      if (registerResponse.statusCode != 200) {
        debugPrint(
          '[MobileWebAuthn] Registration failed: ${registerResponse.statusCode}',
        );
        return null;
      }

      // 7. Store credential securely
      await _storeCredential(
        serverUrl: serverUrl,
        email: email,
        credentialId: credentialId,
      );

      debugPrint('[MobileWebAuthn] ✓ Registration successful');
      return credentialId;
    } catch (e) {
      debugPrint('[MobileWebAuthn] Registration error: $e');
      return null;
    }
  }

  /// Authenticate with existing WebAuthn credential using biometric
  ///
  /// [serverUrl] - The PeerWave server URL
  /// [email] - User's email address
  /// Returns authentication response data on success, null on failure
  Future<Map<String, dynamic>?> authenticate({
    required String serverUrl,
    required String email,
  }) async {
    try {
      debugPrint('[MobileWebAuthn] Starting authentication for $email');

      // 1. Check biometric availability
      if (!await isBiometricAvailable()) {
        debugPrint('[MobileWebAuthn] Biometric authentication not available');
        return null;
      }

      // 2. Check if credential exists for this server/email
      final storedCredential = await _getStoredCredential(serverUrl, email);
      if (storedCredential == null) {
        debugPrint(
          '[MobileWebAuthn] No credential found for $email @ $serverUrl',
        );
        return null;
      }

      // 3. Request authentication challenge from server
      final challengeResponse = await http.post(
        Uri.parse('$serverUrl/webauthn/authenticate-challenge'),
        headers: {
          'Content-Type': 'application/json',
          'X-PeerWave-App-Secret': _kMobileAppSecret,
        },
        body: jsonEncode({'email': email}),
      );

      if (challengeResponse.statusCode != 200) {
        debugPrint(
          '[MobileWebAuthn] Failed to get challenge: ${challengeResponse.statusCode}',
        );
        return null;
      }

      final challengeData = jsonDecode(challengeResponse.body);
      final challenge = challengeData['challenge'] as String;
      debugPrint('[MobileWebAuthn] Received challenge from server');

      // 4. Prompt biometric authentication
      final bool authenticated = await _localAuth.authenticate(
        localizedReason: 'Sign in to PeerWave',
      );

      if (!authenticated) {
        debugPrint('[MobileWebAuthn] Biometric authentication failed');
        return null;
      }

      // 5. Create assertion (signature) using stored credential
      final assertion = _createAssertionObject(
        credentialId: storedCredential['credentialId'],
        challenge: challenge,
        email: email,
      );

      // 6. Send assertion to server
      final authResponse = await http.post(
        Uri.parse('$serverUrl/webauthn/authenticate'),
        headers: {
          'Content-Type': 'application/json',
          'X-PeerWave-App-Secret': _kMobileAppSecret,
        },
        body: jsonEncode(assertion),
      );

      if (authResponse.statusCode != 200) {
        debugPrint(
          '[MobileWebAuthn] Authentication failed: ${authResponse.statusCode}',
        );
        return null;
      }

      final responseData = jsonDecode(authResponse.body);
      debugPrint('[MobileWebAuthn] ✓ Authentication successful');

      return {
        'credentialId': storedCredential['credentialId'],
        'signature': assertion['response']['signature'],
        'authData': responseData,
      };
    } catch (e) {
      debugPrint('[MobileWebAuthn] Authentication error: $e');
      return null;
    }
  }

  /// Check if a credential exists for the given server and email
  Future<bool> hasCredential(String serverUrl, String email) async {
    final credential = await _getStoredCredential(serverUrl, email);
    return credential != null;
  }

  /// Delete stored credential for server/email
  Future<void> deleteCredential(String serverUrl, String email) async {
    final key = _getStorageKey(serverUrl, email);
    await _secureStorage.delete(key: key);
    debugPrint('[MobileWebAuthn] Deleted credential for $email @ $serverUrl');
  }

  /// Generate a stable credential ID from email and initial challenge
  String _generateCredentialId(String email, String challenge) {
    final input = '$email:$challenge:mobile-webauthn';
    final bytes = utf8.encode(input);
    final hash = sha256.convert(bytes);
    return base64UrlEncode(hash.bytes);
  }

  /// Create attestation object for registration
  Map<String, dynamic> _createAttestationObject({
    required String credentialId,
    required String challenge,
    required String email,
  }) {
    // Simulated WebAuthn attestation object
    // In a real implementation, this would use platform-specific APIs
    return {
      'id': credentialId,
      'rawId': credentialId,
      'response': {
        'attestationObject': base64UrlEncode(utf8.encode('mobile-attestation')),
        'clientDataJSON': base64UrlEncode(
          utf8.encode(
            jsonEncode({
              'type': 'webauthn.create',
              'challenge': challenge,
              'origin': 'mobile://$email',
            }),
          ),
        ),
      },
      'type': 'public-key',
    };
  }

  /// Create assertion object for authentication
  Map<String, dynamic> _createAssertionObject({
    required String credentialId,
    required String challenge,
    required String email,
  }) {
    // Create signature from credential ID and challenge
    final signatureInput = '$credentialId:$challenge';
    final signatureBytes = utf8.encode(signatureInput);
    final signature = sha256.convert(signatureBytes);

    return {
      'id': credentialId,
      'rawId': credentialId,
      'response': {
        'authenticatorData': base64UrlEncode(utf8.encode('mobile-auth-data')),
        'clientDataJSON': base64UrlEncode(
          utf8.encode(
            jsonEncode({
              'type': 'webauthn.get',
              'challenge': challenge,
              'origin': 'mobile://$email',
            }),
          ),
        ),
        'signature': base64UrlEncode(signature.bytes),
        'userHandle': base64UrlEncode(utf8.encode(email)),
      },
      'type': 'public-key',
    };
  }

  /// Store credential securely
  Future<void> _storeCredential({
    required String serverUrl,
    required String email,
    required String credentialId,
  }) async {
    final key = _getStorageKey(serverUrl, email);
    final data = jsonEncode({
      'credentialId': credentialId,
      'email': email,
      'serverUrl': serverUrl,
      'createdAt': DateTime.now().toIso8601String(),
    });
    await _secureStorage.write(key: key, value: data);
  }

  /// Get stored credential
  Future<Map<String, dynamic>?> _getStoredCredential(
    String serverUrl,
    String email,
  ) async {
    final key = _getStorageKey(serverUrl, email);
    final data = await _secureStorage.read(key: key);
    if (data == null) return null;
    return jsonDecode(data) as Map<String, dynamic>;
  }

  /// Generate storage key for server/email combination
  String _getStorageKey(String serverUrl, String email) {
    final normalized = serverUrl.toLowerCase().replaceAll(
      RegExp(r'https?://'),
      '',
    );
    return 'webauthn_credential_${normalized}_${email.toLowerCase()}';
  }
}
