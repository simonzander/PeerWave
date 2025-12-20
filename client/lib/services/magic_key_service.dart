import 'package:flutter/foundation.dart' show debugPrint;
import 'api_service.dart';
import 'session_auth_service.dart';

/// Data class for parsed magic key components
class MagicKeyData {
  final String serverUrl;
  final String randomHash;
  final DateTime timestamp;
  final String signature;

  MagicKeyData({
    required this.serverUrl,
    required this.randomHash,
    required this.timestamp,
    required this.signature,
  });

  @override
  String toString() {
    return 'MagicKeyData(serverUrl: $serverUrl, timestamp: $timestamp)';
  }
}

/// Response from magic key verification
class MagicKeyVerificationResponse {
  final bool success;
  final String message;
  final Map<String, dynamic>? data;

  MagicKeyVerificationResponse({
    required this.success,
    required this.message,
    this.data,
  });
}

/// Service for handling magic key operations
class MagicKeyService {
  /// Parse magic key format: {serverUrl}:{randomHash}:{timestamp}:{hmacSignature}
  /// Returns null if format is invalid
  static MagicKeyData? parseMagicKey(String magicKey) {
    try {
      // Split by colon
      final parts = magicKey.split(':');
      
      // Need at least 4 parts for basic format (protocol://host:hash:timestamp:signature)
      if (parts.length < 4) {
        debugPrint('[MagicKey] Invalid format: Expected at least 4 parts, got ${parts.length}');
        return null;
      }

      // Extract protocol (http or https)
      final protocol = parts[0];
      if (protocol != 'http' && protocol != 'https') {
        debugPrint('[MagicKey] Invalid protocol: $protocol');
        return null;
      }

      // Extract host (remove leading //)
      final hostPart = parts[1].replaceAll('//', '');
      
      // Check if next part is a port number or the hash
      int serverUrlEndIndex = 2;
      String serverUrl = '$protocol://$hostPart';
      
      // If parts[2] is a number and small (< 65536, valid port range), it's likely a port
      if (parts.length > 2) {
        final possiblePort = int.tryParse(parts[2]);
        if (possiblePort != null && possiblePort > 0 && possiblePort < 65536) {
          serverUrl = '$protocol://$hostPart:${parts[2]}';
          serverUrlEndIndex = 3;
        }
      }

      // Find where timestamp starts (should be a valid integer in reasonable range)
      int timestampIndex = -1;
      for (int i = serverUrlEndIndex; i < parts.length; i++) {
        final possibleTimestamp = int.tryParse(parts[i]);
        if (possibleTimestamp != null && possibleTimestamp > 1000000000000) { // After year 2001 in milliseconds
          timestampIndex = i;
          break;
        }
      }

      if (timestampIndex == -1) {
        debugPrint('[MagicKey] No valid timestamp found');
        return null;
      }

      // RandomHash is everything between server URL and timestamp
      final randomHash = parts.sublist(serverUrlEndIndex, timestampIndex).join(':');
      
      // Timestamp
      final timestamp = DateTime.fromMillisecondsSinceEpoch(int.parse(parts[timestampIndex]));
      
      // Signature is everything after timestamp
      final signature = parts.sublist(timestampIndex + 1).join(':');

      debugPrint('[MagicKey] Parsed - serverUrl: $serverUrl, randomHash: $randomHash');

      return MagicKeyData(
        serverUrl: serverUrl,
        randomHash: randomHash,
        timestamp: timestamp,
        signature: signature,
      );
    } catch (e) {
      debugPrint('[MagicKey] Parse error: $e');
      return null;
    }
  }

  /// Check if magic key format is valid (structure only, not cryptographic validation)
  static bool isValidFormat(String magicKey) {
    return parseMagicKey(magicKey) != null;
  }

  /// Check if timestamp indicates expiration (client-side check, 5 min expiry)
  static bool isExpired(String magicKey) {
    final parsed = parseMagicKey(magicKey);
    if (parsed == null) return true;

    final now = DateTime.now();
    final expiresAt = parsed.timestamp.add(const Duration(minutes: 5));
    
    return now.isAfter(expiresAt);
  }

  /// Extract server URL from magic key
  static String? getServerUrl(String magicKey) {
    final parsed = parseMagicKey(magicKey);
    return parsed?.serverUrl;
  }

  /// Verify magic key with server
  /// Calls: POST /client/magic/verify
  /// Returns verification response with success status
  static Future<MagicKeyVerificationResponse> verifyWithServer(
    String magicKey,
    String clientId,
  ) async {
    try {
      // Parse key to extract server URL
      final parsed = parseMagicKey(magicKey);
      if (parsed == null) {
        return MagicKeyVerificationResponse(
          success: false,
          message: 'Invalid magic key format',
        );
      }

      // Check client-side expiration first
      if (isExpired(magicKey)) {
        return MagicKeyVerificationResponse(
          success: false,
          message: 'Magic key has expired (5 minutes)',
        );
      }

      // Construct full API URL using server URL from magic key
      final verifyUrl = '${parsed.serverUrl}/magic/verify';
      
      debugPrint('[MagicKey] Verifying with server: $verifyUrl');
      debugPrint('[MagicKey] Client ID: $clientId');

      // Call verification endpoint
      final response = await ApiService.post(
        verifyUrl,
        data: {
          'key': magicKey,
          'clientid': clientId,
        },
      );

      if (response.statusCode == 200) {
        final data = response.data;
        final success = data['status'] == 'ok';
        
        // If verification successful and server provides session secret, store it
        if (success && data['sessionSecret'] != null) {
          final sessionSecret = data['sessionSecret'] as String;
          await SessionAuthService().initializeSession(clientId, sessionSecret);
          debugPrint('[MagicKey] Session secret stored for client: $clientId');
        }
        
        return MagicKeyVerificationResponse(
          success: success,
          message: data['message'] ?? 'Verification successful',
          data: data,
        );
      } else {
        final data = response.data;
        return MagicKeyVerificationResponse(
          success: false,
          message: data['message'] ?? 'Verification failed',
        );
      }
    } catch (e) {
      debugPrint('[MagicKey] Verification error: $e');
      return MagicKeyVerificationResponse(
        success: false,
        message: 'Network error: $e',
      );
    }
  }

  /// Get remaining time string for UI display
  static String getRemainingTime(String magicKey) {
    final parsed = parseMagicKey(magicKey);
    if (parsed == null) return 'Invalid';

    final now = DateTime.now();
    final expiresAt = parsed.timestamp.add(const Duration(minutes: 5));
    final remaining = expiresAt.difference(now);

    if (remaining.isNegative) return 'Expired';

    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds % 60;
    return '${minutes}m ${seconds}s';
  }
}
