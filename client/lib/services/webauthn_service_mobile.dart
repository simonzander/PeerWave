import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:dio/dio.dart';
import 'api_service.dart';
import 'clientid_native.dart';

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
  /// Returns map with credentialId and serverResponse on success, null on failure
  Future<Map<String, dynamic>?> register({
    required String serverUrl,
    String? email,
  }) async {
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
        // IMPORTANT: Don't override residentKey if server already set it!
        authSelection['requireResidentKey'] ??= false;
        authSelection['residentKey'] ??=
            'required'; // Changed to 'required' for Google Password Manager
        authSelection['userVerification'] ??= 'preferred';
      } else {
        // No authenticatorSelection provided - use defaults that enable passkey sync
        challengeData['authenticatorSelection'] = {
          'requireResidentKey': false,
          'residentKey':
              'required', // Changed to 'required' for Google Password Manager
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
      debugPrint('[MobileWebAuthn] Credential ID details:');
      debugPrint('[MobileWebAuthn]   - Length: ${registerResponse.id.length}');
      debugPrint(
        '[MobileWebAuthn]   - Contains +: ${registerResponse.id.contains('+')}',
      );
      debugPrint(
        '[MobileWebAuthn]   - Contains /: ${registerResponse.id.contains('/')}',
      );
      debugPrint(
        '[MobileWebAuthn]   - Contains =: ${registerResponse.id.contains('=')}',
      );
      debugPrint(
        '[MobileWebAuthn]   - Contains _: ${registerResponse.id.contains('_')}',
      );
      debugPrint(
        '[MobileWebAuthn]   - Contains -: ${registerResponse.id.contains('-')}',
      );

      // 5. Send attestation to server with clientId for HMAC session
      final registerResponseJson = registerResponse.toJson();

      // Add clientId to request for server to create HMAC session
      final clientId = await _getClientId();

      debugPrint('[MobileWebAuthn] Sending attestation to server');
      final serverResponse = await ApiService.dio.post(
        '$serverUrl/webauthn/register',
        data: {'attestation': registerResponseJson, 'clientId': clientId},
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

      // Return credential ID and server response for HMAC session handling
      return {
        'credentialId': credentialId,
        'serverResponse': serverResponse.data,
      };
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

      // 2. Skip local credential check - use discoverable authentication
      // Android Credential Manager will show available passkeys regardless of local metadata
      debugPrint(
        '[MobileWebAuthn] Using discoverable authentication (no local credential check)',
      );

      // 3. Request authentication challenge from server
      // Send platform parameter so server knows to use empty allowCredentials
      final challengeResponse = await ApiService.dio.post(
        '$serverUrl/webauthn/authenticate-challenge',
        data: {
          'email': userEmail,
          'platform': 'android', // Explicit platform for server-side detection
        },
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

      // Log each credential ID in detail
      if (challengeData['allowCredentials'] is List) {
        final credentials = challengeData['allowCredentials'] as List;
        debugPrint(
          '[MobileWebAuthn] Server sent ${credentials.length} credential(s):',
        );
        for (var i = 0; i < credentials.length; i++) {
          final cred = credentials[i];
          debugPrint(
            '[MobileWebAuthn]   [$i] ID: ${cred['id']}, type: ${cred['type']}, transports: ${cred['transports']}',
          );
          // Check if ID is base64url encoded correctly
          if (cred['id'] is String) {
            final idString = cred['id'] as String;
            debugPrint(
              '[MobileWebAuthn]   [$i] ID length: ${idString.length}, contains +: ${idString.contains('+')}, contains /: ${idString.contains('/')}, contains =: ${idString.contains('=')}',
            );
          }
        }
      }

      debugPrint('[MobileWebAuthn] extensions: ${challengeData['extensions']}');

      // Fix null values that might cause parsing issues
      // ALWAYS use empty allowCredentials for discoverable authentication
      // This forces Android to show ALL registered passkeys for this rpId
      debugPrint(
        '[MobileWebAuthn] Forcing empty allowCredentials (discoverable authentication)',
      );
      challengeData['allowCredentials'] = [];

      // Ensure extensions is a map (not null)
      if (challengeData['extensions'] == null) {
        debugPrint('[MobileWebAuthn] Fixing null extensions');
        challengeData['extensions'] = {};
      }

      debugPrint('[MobileWebAuthn] Fixed challenge data: $challengeData');

      // Log RP information for debugging
      debugPrint('[MobileWebAuthn] RP from server: ${challengeData['rp']}');
      if (challengeData['rp'] is Map) {
        final rp = challengeData['rp'] as Map;
        debugPrint('[MobileWebAuthn]   - RP name: ${rp['name']}');
        debugPrint('[MobileWebAuthn]   - RP id: ${rp['id']}');
      }

      // 4. Create AuthenticateRequestType from server challenge
      late final AuthenticateRequestType authRequest;
      try {
        authRequest = AuthenticateRequestType.fromJson(challengeData);
        debugPrint(
          '[MobileWebAuthn] AuthenticateRequestType created successfully',
        );
        debugPrint('[MobileWebAuthn]   - Calling passkeys.authenticate()...');
        debugPrint(
          '[MobileWebAuthn]   - This will trigger Android Credential Manager',
        );
        debugPrint(
          '[MobileWebAuthn]   - Expected behavior: Show passkey picker with registered passkeys',
        );
      } catch (e, stackTrace) {
        debugPrint(
          '[MobileWebAuthn] Error creating AuthenticateRequestType: $e',
        );
        debugPrint('[MobileWebAuthn] Stack trace: $stackTrace');
        rethrow;
      }

      // 5. Use passkeys package to sign challenge (with hardware key)
      late final AuthenticateResponseType authResponse;
      try {
        authResponse = await _passkeysAuth.authenticate(authRequest);
        debugPrint('[MobileWebAuthn] Challenge signed successfully');
      } catch (e) {
        debugPrint('[MobileWebAuthn] Authentication error: $e');
        rethrow;
      }

      // 6. Send assertion to server with clientId for HMAC session
      final authResponseJson = authResponse.toJson();

      // Add clientId to request for server to create HMAC session
      final clientId = await _getClientId();
      authResponseJson['clientId'] = clientId;

      // Extract credential ID from the response
      final credentialId = authResponse.id;
      debugPrint('[MobileWebAuthn] Credential ID used: $credentialId');

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

      // Store credential metadata for future use (if not already stored)
      await _storeCredential(
        serverUrl: serverUrl,
        email: userEmail,
        credentialId: credentialId,
      );

      return {'credentialId': credentialId, 'authData': responseData};
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

  /// Get client ID (needed for HMAC authentication)
  Future<String> _getClientId() async {
    return await ClientIdService.getClientId();
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
