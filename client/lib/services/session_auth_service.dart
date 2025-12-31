import 'package:flutter/foundation.dart' show debugPrint;
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'secure_session_storage.dart';

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
  Future<void> initializeSession(String clientId, String sessionSecret) async {
    await _secureStorage.saveSessionSecret(clientId, sessionSecret);
    debugPrint('[SessionAuth] Session initialized for client: $clientId');
  }

  /// Get session secret for a client
  Future<String?> getSessionSecret(String clientId) async {
    return await _secureStorage.getSessionSecret(clientId);
  }

  /// Check if session exists for client
  Future<bool> hasSession(String clientId) async {
    final secret = await getSessionSecret(clientId);
    return secret != null && secret.isNotEmpty;
  }

  /// Generate authentication headers for an API request
  /// Returns map of headers to include in request
  Future<Map<String, String>> generateAuthHeaders({
    required String clientId,
    required String requestPath,
    String? requestBody,
  }) async {
    final sessionSecret = await getSessionSecret(clientId);

    if (sessionSecret == null || sessionSecret.isEmpty) {
      throw Exception('No session secret found for client: $clientId');
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
  Future<void> rotateSession(String clientId, String newSessionSecret) async {
    await _secureStorage.saveSessionSecret(clientId, newSessionSecret);
    debugPrint('[SessionAuth] Session rotated for client: $clientId');
  }

  /// Clear session (logout)
  Future<void> clearSession(String clientId) async {
    await _secureStorage.deleteSessionSecret(clientId);
    debugPrint('[SessionAuth] Session cleared for client: $clientId');
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
}
