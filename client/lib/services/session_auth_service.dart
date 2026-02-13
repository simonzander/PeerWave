import 'package:flutter/foundation.dart' show debugPrint;
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:dio/dio.dart';
import 'secure_session_storage.dart';
import 'api_service.dart';

/// Service for generating HMAC-based authentication signatures for API requests
/// Implements secure session authentication with replay attack prevention
class SessionAuthService {
  static final SessionAuthService _instance = SessionAuthService._internal();
  factory SessionAuthService() => _instance;
  SessionAuthService._internal();

  final _secureStorage = SecureSessionStorage();
  final _uuid = const Uuid();

  // Cache for used nonces (in-memory, cleared on app restart)
  final Map<String, DateTime> _usedNonces = {};

  /// Initialize session with secret received from server
  Future<void> initializeSession(
    String clientId,
    String sessionSecret, {
    required String serverUrl,
  }) async {
    await _secureStorage.saveSessionSecret(
      clientId,
      sessionSecret,
      serverUrl: serverUrl,
    );
    debugPrint(
      '[SessionAuth] Session initialized for client: $clientId @ $serverUrl',
    );
  }

  /// Get session secret for a client+server
  Future<String?> getSessionSecret(
    String clientId, {
    required String serverUrl,
  }) async {
    return await _secureStorage.getSessionSecret(
      clientId,
      serverUrl: serverUrl,
    );
  }

  /// Check if session exists for client+server
  Future<bool> hasSession({
    required String clientId,
    required String serverUrl,
  }) async {
    final secret = await getSessionSecret(clientId, serverUrl: serverUrl);
    return secret != null && secret.isNotEmpty;
  }

  /// Generate authentication headers for an API request
  /// Returns map of headers to include in request
  Future<Map<String, String>> generateAuthHeaders({
    required String clientId,
    required String requestPath,
    required String serverUrl,
    String? requestBody,
  }) async {
    final sessionSecret = await getSessionSecret(
      clientId,
      serverUrl: serverUrl,
    );

    if (sessionSecret == null || sessionSecret.isEmpty) {
      throw Exception(
        'No session secret found for client: $clientId @ $serverUrl',
      );
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final nonce = _uuid.v4();

    // Generate signature
    final signature = _generateSignature(
      sessionSecret: sessionSecret,
      clientId: clientId,
      timestamp: timestamp,
      nonce: nonce,
      requestPath: requestPath,
      requestBody: requestBody,
    );

    return {
      'X-Client-ID': clientId,
      'X-Timestamp': timestamp.toString(),
      'X-Nonce': nonce,
      'X-Signature': signature,
    };
  }

  /// Generate HMAC-SHA256 signature
  String _generateSignature({
    required String sessionSecret,
    required String clientId,
    required int timestamp,
    required String nonce,
    required String requestPath,
    String? requestBody,
  }) {
    // Create message to sign
    final message =
        '$clientId:$timestamp:$nonce:$requestPath:${requestBody ?? ''}';

    // Generate HMAC-SHA256
    final key = utf8.encode(sessionSecret);
    final bytes = utf8.encode(message);
    final hmac = Hmac(sha256, key);
    final digest = hmac.convert(bytes);

    return digest.toString();
  }

  /// Verify a signature (for testing/debugging)
  bool verifySignature({
    required String sessionSecret,
    required String clientId,
    required int timestamp,
    required String nonce,
    required String requestPath,
    required String signature,
    String? requestBody,
  }) {
    final expectedSignature = _generateSignature(
      sessionSecret: sessionSecret,
      clientId: clientId,
      timestamp: timestamp,
      nonce: nonce,
      requestPath: requestPath,
      requestBody: requestBody,
    );

    return signature == expectedSignature;
  }

  /// Rotate session secret (called periodically or on demand)
  Future<void> rotateSession(
    String clientId,
    String newSessionSecret, {
    required String serverUrl,
  }) async {
    await _secureStorage.saveSessionSecret(
      clientId,
      newSessionSecret,
      serverUrl: serverUrl,
    );
    debugPrint(
      '[SessionAuth] Session rotated for client: $clientId @ $serverUrl',
    );
  }

  /// Clear session (logout)
  Future<void> clearSession(
    String clientId, {
    required String serverUrl,
  }) async {
    await _secureStorage.deleteSessionSecret(clientId, serverUrl: serverUrl);
    debugPrint(
      '[SessionAuth] Session cleared for client: $clientId @ $serverUrl',
    );
  }

  /// Clear all sessions
  Future<void> clearAllSessions() async {
    await _secureStorage.deleteAllSessionSecrets();
    _usedNonces.clear();
    debugPrint('[SessionAuth] All sessions cleared');
  }

  /// Generate a random session secret (256 bits)
  /// This is typically done by the server, but included for reference
  static String generateSessionSecret() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// Check if timestamp is within acceptable window (±5 minutes)
  static bool isTimestampValid(int timestamp) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = (now - timestamp).abs();
    const maxDiff = 5 * 60 * 1000; // 5 minutes in milliseconds
    return diff <= maxDiff;
  }

  /// Refresh the session using a refresh token
  /// Returns true if successful, false if refresh token is invalid/expired
  Future<bool> refreshSession({required String serverUrl}) async {
    try {
      final storage = SecureSessionStorage();
      final clientId = await storage.getClientId();
      final refreshToken = await storage.getRefreshToken(serverUrl: serverUrl);

      if (clientId == null || refreshToken == null) {
        debugPrint(
          'SessionAuthService: Missing clientId or refreshToken @ $serverUrl',
        );
        return false;
      }

      // Try up to 3 times with exponential backoff
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          final response = await ApiService.instance.post(
            '/auth/token/refresh',
            data: {'clientId': clientId, 'refreshToken': refreshToken},
          );

          if (response.statusCode == 200) {
            final data = response.data;
            final newSessionSecret = data['sessionSecret'] as String?;
            final newRefreshToken = data['refreshToken'] as String?;

            if (newSessionSecret == null || newRefreshToken == null) {
              debugPrint(
                'SessionAuthService: Invalid response from refresh endpoint @ $serverUrl',
              );
              return false;
            }

            // Store new tokens
            await storage.saveSessionSecret(
              clientId,
              newSessionSecret,
              serverUrl: serverUrl,
            );
            await storage.saveRefreshToken(
              newRefreshToken,
              serverUrl: serverUrl,
            );

            // Calculate and store new expiry (60 days from now)
            final expiryDate = DateTime.now().add(Duration(days: 60));
            await storage.saveSessionExpiry(
              expiryDate.toIso8601String(),
              serverUrl: serverUrl,
            );

            debugPrint(
              'SessionAuthService: Session refreshed successfully @ $serverUrl',
            );
            return true;
          } else if (response.statusCode == 401) {
            // Refresh token is invalid or expired
            debugPrint('SessionAuthService: Refresh token expired or invalid');
            return false;
          } else if (response.statusCode == 429 && attempt < 3) {
            // Rate limited, wait and retry
            final delay = Duration(seconds: pow(2, attempt).toInt());
            debugPrint(
              'SessionAuthService: Rate limited, retrying in ${delay.inSeconds}s',
            );
            await Future.delayed(delay);
            continue;
          } else {
            debugPrint(
              'SessionAuthService: Unexpected response: ${response.statusCode}',
            );
            return false;
          }
        } on DioException catch (e) {
          if (e.response?.statusCode == 401) {
            debugPrint('SessionAuthService: Refresh token expired or invalid');
            return false;
          }

          if (attempt < 3) {
            final delay = Duration(seconds: pow(2, attempt).toInt());
            debugPrint(
              'SessionAuthService: Network error on attempt $attempt: $e, retrying in ${delay.inSeconds}s',
            );
            await Future.delayed(delay);
            continue;
          } else {
            debugPrint('SessionAuthService: Failed after 3 attempts: $e');
            return false;
          }
        }
      }

      return false;
    } catch (e) {
      debugPrint('SessionAuthService: Error refreshing session: $e');
      return false;
    }
  }

  /// Check if session should be refreshed and do it proactively
  /// Called on app startup to refresh sessions that are close to expiring
  Future<void> checkAndRefreshSession({
    required String serverUrl,
    required String clientId,
  }) async {
    try {
      final storage = SecureSessionStorage();
      final sessionSecret = await storage.getSessionSecret(
        clientId,
        serverUrl: serverUrl,
      );
      final refreshToken = await storage.getRefreshToken(serverUrl: serverUrl);
      final sessionExpiry = await storage.getSessionExpiry(
        serverUrl: serverUrl,
      );

      if (sessionSecret == null || refreshToken == null) {
        debugPrint('SessionAuthService: No session to refresh @ $serverUrl');
        return;
      }

      // Parse session expiry
      DateTime? expiryDate;
      if (sessionExpiry != null) {
        expiryDate = DateTime.tryParse(sessionExpiry);
      }

      // If no expiry date or session expires in less than 7 days, refresh it
      if (expiryDate == null ||
          expiryDate.difference(DateTime.now()).inDays < 7) {
        debugPrint(
          'SessionAuthService: Session expiring soon @ $serverUrl, refreshing proactively',
        );
        final success = await refreshSession(serverUrl: serverUrl);

        if (success) {
          debugPrint(
            'SessionAuthService: Proactive refresh successful @ $serverUrl',
          );
        } else {
          debugPrint(
            'SessionAuthService: Proactive refresh failed @ $serverUrl',
          );
        }
      } else {
        debugPrint(
          'SessionAuthService: Session still valid for ${expiryDate.difference(DateTime.now()).inDays} days @ $serverUrl',
        );
      }
    } catch (e) {
      debugPrint(
        'SessionAuthService: Error checking session expiry @ $serverUrl: $e',
      );
    }
  }
}
