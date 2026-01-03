import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'api_service.dart';

/// Mobile WebAuthn service for iOS and Android
///
/// Implements proper WebAuthn authentication using hardware-backed keys via the passkeys package.
/// - Android: Uses Android Keystore for hardware-backed key pairs
/// - iOS: Uses Secure Enclave for hardware-backed key pairs
/// - Proper cryptographic signing with private keys
/// - Server validates signatures with public keys
class MobileWebAuthnService {
  static final MobileWebAuthnService instance = MobileWebAuthnService._();
  MobileWebAuthnService._();

  final PasskeyAuthenticator _passkeysAuth = PasskeyAuthenticator();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  /// Check if passkey/biometric authentication is available on this device
  Future<bool> isBiometricAvailable() async {
    try {
      final availability = await _passkeysAuth.getAvailability();
      return availability.isSupported;
    } catch (e) {
      debugPrint('[MobileWebAuthn] Error checking passkey availability: $e');
      return false;
    }
  }

  /// Get available biometric types (compatibility method)
  Future<List<String>> getAvailableBiometrics() async {
    try {
      final available = await isBiometricAvailable();
      return available ? ['passkey'] : [];
    } catch (e) {
      debugPrint('[MobileWebAuthn] Error getting biometrics: $e');
      return [];
    }
  }

  /// Send registration request to server to initiate OTP flow
  ///
  /// [serverUrl] - The PeerWave server URL
  /// [email] - User's email address
  /// Returns response data with wait time on success
  Future<Map<String, dynamic>> sendRegistrationRequest({
    required String serverUrl,
    required String email,
  }) async {
    return sendRegistrationRequestWithData(
      serverUrl: serverUrl,
      data: {'email': email},
    );
  }

  /// Send registration request with custom data (e.g., invitation token)
  ///
  /// [serverUrl] - The PeerWave server URL
  /// [data] - Registration data (must include 'email')
  /// Returns response data with wait time on success
  Future<Map<String, dynamic>> sendRegistrationRequestWithData({
    required String serverUrl,
    required Map<String, dynamic> data,
  }) async {
    try {
      final email = data['email'] ?? '';
      debugPrint(
        '[MobileWebAuthn] Sending registration request for $email to $serverUrl',
      );

      final response = await ApiService.dio.post(
        '$serverUrl/register',
        data: data,
      );

      debugPrint(
        '[MobileWebAuthn] Register response status: ${response.statusCode}',
      );
      debugPrint('[MobileWebAuthn] Register response data: ${response.data}');

      return response.data as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[MobileWebAuthn] Registration request error: $e');
      rethrow;
    }
  }

  /// Register a new WebAuthn credential with passkey (hardware-backed key)
  ///
  /// [serverUrl] - The PeerWave server URL
  /// [email] - User's email address
  /// Returns credential ID on success, null on failure
  Future<String?> register({
    required String serverUrl,
    required String email,
  }) async {
    try {
      debugPrint('[MobileWebAuthn] Starting passkey registration for $email');

      // 1. Check passkey availability
      if (!await isBiometricAvailable()) {
        debugPrint('[MobileWebAuthn] Passkeys not available');
        return null;
      }

      // 2. Request registration challenge from server
      final challengeResponse = await ApiService.dio.post(
        '$serverUrl/webauthn/register-challenge',
        data: {}, // Email comes from session
      );

      if (challengeResponse.statusCode != 200) {
        debugPrint(
          '[MobileWebAuthn] Failed to get challenge: ${challengeResponse.statusCode}',
        );
        return null;
      }

      final challengeData = challengeResponse.data as Map<String, dynamic>;
      debugPrint('[MobileWebAuthn] Received challenge from server');

      // 3. Create RegisterRequest from server challenge
      final registerRequest = RegisterRequest.fromJson(challengeData);

      // 4. Use passkeys package to create credential (generates key in hardware)
      final registerResponse = await _passkeysAuth.register(registerRequest);

      debugPrint('[MobileWebAuthn] Passkey created successfully');

      // 5. Send attestation to server
      final registerResponseJson = registerResponse.toJson();
      final serverResponse = await ApiService.dio.post(
        '$serverUrl/webauthn/register',
        data: {'attestation': registerResponseJson},
      );

      if (serverResponse.statusCode != 200) {
        debugPrint(
          '[MobileWebAuthn] Registration failed: ${serverResponse.statusCode}',
        );
        return null;
      }

      // 6. Store credential metadata
      final credentialId = registerResponse.id;
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

  /// Authenticate with existing WebAuthn credential using passkey
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

      // 1. Check passkey availability
      if (!await isBiometricAvailable()) {
        debugPrint('[MobileWebAuthn] Passkeys not available');
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
      final challengeResponse = await ApiService.dio.post(
        '$serverUrl/webauthn/auth-challenge',
        data: {'email': email},
      );

      if (challengeResponse.statusCode != 200) {
        debugPrint(
          '[MobileWebAuthn] Failed to get auth challenge: ${challengeResponse.statusCode}',
        );
        return null;
      }

      final challengeData = challengeResponse.data as Map<String, dynamic>;
      debugPrint('[MobileWebAuthn] Received challenge from server');

      // 4. Create AuthenticateRequest from server challenge
      final authRequest = AuthenticateRequest.fromJson(challengeData);

      // 5. Use passkeys package to sign challenge (with hardware key)
      final authResponse = await _passkeysAuth.authenticate(authRequest);

      debugPrint('[MobileWebAuthn] Challenge signed successfully');

      // 6. Send assertion to server
      final authResponseJson = authResponse.toJson();
      final serverResponse = await ApiService.dio.post(
        '$serverUrl/webauthn/authenticate',
        data: authResponseJson,
      );

      if (serverResponse.statusCode != 200) {
        debugPrint(
          '[MobileWebAuthn] Authentication failed: ${serverResponse.statusCode}',
        );
        return null;
      }

      final responseData = serverResponse.data as Map<String, dynamic>;
      debugPrint('[MobileWebAuthn] ✓ Authentication successful');

      return {
        'credentialId': storedCredential['credentialId'],
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

  /// Store credential metadata securely
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

  /// Get stored credential metadata
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
