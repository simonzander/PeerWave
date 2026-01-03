import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:dio/dio.dart';
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
      final availability = _passkeysAuth.getAvailability();
      // Check platform-specific availability
      if (defaultTargetPlatform == TargetPlatform.android) {
        final androidAvailability = await availability.android();
        return androidAvailability.hasPasskeySupport;
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        final iosAvailability = await availability.iOS();
        return iosAvailability.hasPasskeySupport;
      }
      return false;
    } catch (e) {
      debugPrint('[MobileWebAuthn] Error checking passkey availability: $e');
      return false;
    }
  }

  /// Fetch current user's email from server session
  ///
  /// [serverUrl] - The PeerWave server URL
  /// Returns email address from active session, null if not authenticated
  Future<String?> getCurrentUserEmail(String serverUrl) async {
    try {
      debugPrint('[MobileWebAuthn] Fetching user email from session');
      final response = await ApiService.dio.get('$serverUrl/api/user/me');

      debugPrint('[MobileWebAuthn] Response status: ${response.statusCode}');
      debugPrint(
        '[MobileWebAuthn] Response data type: ${response.data.runtimeType}',
      );
      debugPrint('[MobileWebAuthn] Response data: ${response.data}');

      if (response.statusCode == 200) {
        // Handle different response formats
        if (response.data is Map<String, dynamic>) {
          final data = response.data as Map<String, dynamic>;
          final email = data['email'] as String?;
          debugPrint('[MobileWebAuthn] Current user email: $email');
          return email;
        } else if (response.data is String) {
          // Server might return email directly as string
          final email = response.data as String;
          debugPrint('[MobileWebAuthn] Current user email (string): $email');
          return email;
        } else {
          debugPrint(
            '[MobileWebAuthn] Unexpected response format: ${response.data.runtimeType}',
          );
          return null;
        }
      }
      return null;
    } catch (e, stackTrace) {
      debugPrint('[MobileWebAuthn] Error fetching user email: $e');
      debugPrint('[MobileWebAuthn] Stack trace: $stackTrace');
      return null;
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
  /// [email] - User's email address (optional - will fetch from server session if empty)
  /// Returns credential ID on success, null on failure
  Future<String?> register({required String serverUrl, String? email}) async {
    try {
      // Fetch email from server session if not provided
      String? userEmail = email;
      if (userEmail == null || userEmail.isEmpty) {
        userEmail = await getCurrentUserEmail(serverUrl);
        if (userEmail == null || userEmail.isEmpty) {
          debugPrint('[MobileWebAuthn] Failed to get user email from session');
          return null;
        }
      }

      debugPrint(
        '[MobileWebAuthn] Starting passkey registration for $userEmail',
      );

      // 1. Check passkey availability
      if (!await isBiometricAvailable()) {
        debugPrint('[MobileWebAuthn] Passkeys not available');
        return null;
      }

      // 2. Request registration challenge from server
      debugPrint(
        '[MobileWebAuthn] Requesting challenge from: $serverUrl/webauthn/register-challenge',
      );
      final challengeResponse = await ApiService.dio.post(
        '$serverUrl/webauthn/register-challenge',
        data: {}, // Email comes from session
      );

      if (challengeResponse.statusCode != 200) {
        debugPrint(
          '[MobileWebAuthn] Failed to get challenge: ${challengeResponse.statusCode}',
        );
        debugPrint('[MobileWebAuthn] Response data: ${challengeResponse.data}');
        return null;
      }

      final challengeData = challengeResponse.data as Map<String, dynamic>;
      debugPrint('[MobileWebAuthn] Received challenge from server');
      debugPrint('[MobileWebAuthn] Challenge data keys: ${challengeData.keys}');

      // Fix null values in authenticatorSelection (server may not send all fields)
      if (challengeData['authenticatorSelection'] != null) {
        final authSelection =
            challengeData['authenticatorSelection'] as Map<String, dynamic>;
        // Set defaults for null boolean fields required by passkeys package
        authSelection['requireResidentKey'] ??= false;
        authSelection['residentKey'] ??= 'preferred';
        authSelection['userVerification'] ??= 'preferred';
      } else {
        // No authenticatorSelection provided - use defaults
        challengeData['authenticatorSelection'] = {
          'requireResidentKey': false,
          'residentKey': 'preferred',
          'userVerification': 'preferred',
        };
      }

      debugPrint(
        '[MobileWebAuthn] Fixed challenge data: ${challengeData['authenticatorSelection']}',
      );

      // 3. Create RegisterRequestType from server challenge
      debugPrint(
        '[MobileWebAuthn] Creating RegisterRequestType from challenge',
      );
      final registerRequest = RegisterRequestType.fromJson(challengeData);

      // 4. Use passkeys package to create credential (generates key in hardware)
      debugPrint(
        '[MobileWebAuthn] Calling passkeys.register() - biometric prompt should appear',
      );
      final registerResponse = await _passkeysAuth.register(registerRequest);

      debugPrint(
        '[MobileWebAuthn] Passkey created successfully, credential ID: ${registerResponse.id}',
      );

      // 5. Send attestation to server
      final registerResponseJson = registerResponse.toJson();
      debugPrint('[MobileWebAuthn] Sending attestation to server');
      final serverResponse = await ApiService.dio.post(
        '$serverUrl/webauthn/register',
        data: {'attestation': registerResponseJson},
      );

      if (serverResponse.statusCode != 200) {
        debugPrint(
          '[MobileWebAuthn] Registration failed: ${serverResponse.statusCode}',
        );
        debugPrint('[MobileWebAuthn] Response data: ${serverResponse.data}');
        return null;
      }

      // 6. Store credential metadata
      final credentialId = registerResponse.id;
      await _storeCredential(
        serverUrl: serverUrl,
        email: userEmail,
        credentialId: credentialId,
      );

      debugPrint('[MobileWebAuthn] ✓ Registration successful');
      return credentialId;
    } on DioException catch (e) {
      debugPrint('[MobileWebAuthn] API error during registration:');
      debugPrint('  Status: ${e.response?.statusCode}');
      debugPrint('  Data: ${e.response?.data}');
      debugPrint('  Message: ${e.message}');
      return null;
    } catch (e, stackTrace) {
      debugPrint('[MobileWebAuthn] Registration error: $e');
      debugPrint('  Stack trace: $stackTrace');
      return null;
    }
  }

  /// Authenticate with existing WebAuthn credential using passkey
  ///
  /// [serverUrl] - The PeerWave server URL
  /// [email] - User's email address (optional - will fetch from stored credentials)
  /// Returns authentication response data on success, null on failure
  Future<Map<String, dynamic>?> authenticate({
    required String serverUrl,
    String? email,
  }) async {
    try {
      // If email not provided, try to find stored credential for this server
      String? userEmail = email;
      if (userEmail == null || userEmail.isEmpty) {
        // Try to fetch from server session
        userEmail = await getCurrentUserEmail(serverUrl);
        if (userEmail == null || userEmail.isEmpty) {
          debugPrint(
            '[MobileWebAuthn] No email provided and session not found',
          );
          return null;
        }
      }

      debugPrint('[MobileWebAuthn] Starting authentication for $userEmail');

      // 1. Check passkey availability
      if (!await isBiometricAvailable()) {
        debugPrint('[MobileWebAuthn] Passkeys not available');
        return null;
      }

      // 2. Check if credential exists for this server/email
      final storedCredential = await _getStoredCredential(serverUrl, userEmail);
      if (storedCredential == null) {
        debugPrint(
          '[MobileWebAuthn] No credential found for $userEmail @ $serverUrl',
        );
        return null;
      }

      // 3. Request authentication challenge from server
      final challengeResponse = await ApiService.dio.post(
        '$serverUrl/webauthn/authenticate-challenge',
        data: {'email': userEmail},
      );

      if (challengeResponse.statusCode != 200) {
        debugPrint(
          '[MobileWebAuthn] Failed to get auth challenge: ${challengeResponse.statusCode}',
        );
        return null;
      }

      final challengeData = challengeResponse.data as Map<String, dynamic>;
      debugPrint('[MobileWebAuthn] Received challenge from server');
      debugPrint('[MobileWebAuthn] Challenge keys: ${challengeData.keys}');
      debugPrint(
        '[MobileWebAuthn] allowCredentials: ${challengeData['allowCredentials']}',
      );
      debugPrint('[MobileWebAuthn] extensions: ${challengeData['extensions']}');

      // Fix null values that might cause parsing issues
      // Ensure allowCredentials is a list (not null)
      if (challengeData['allowCredentials'] == null) {
        debugPrint('[MobileWebAuthn] Fixing null allowCredentials');
        challengeData['allowCredentials'] = [];
      }

      // Ensure extensions is a map (not null)
      if (challengeData['extensions'] == null) {
        debugPrint('[MobileWebAuthn] Fixing null extensions');
        challengeData['extensions'] = {};
      }

      debugPrint('[MobileWebAuthn] Fixed challenge data: $challengeData');

      // 4. Create AuthenticateRequestType from server challenge
      late final AuthenticateRequestType authRequest;
      try {
        authRequest = AuthenticateRequestType.fromJson(challengeData);
        debugPrint(
          '[MobileWebAuthn] AuthenticateRequestType created successfully',
        );
      } catch (e, stackTrace) {
        debugPrint(
          '[MobileWebAuthn] Error creating AuthenticateRequestType: $e',
        );
        debugPrint('[MobileWebAuthn] Stack trace: $stackTrace');
        rethrow;
      }

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
