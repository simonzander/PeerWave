import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'api_service.dart';
import 'session_auth_service.dart';
import 'device_info_helper.dart';

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
  /// Parse magic key format: {serverUrl}|{randomHash}|{timestamp}|{hmacSignature}
  /// Using pipe delimiter which is safe for all URL formats (including IPv6)
  /// Returns null if format is invalid
  static MagicKeyData? parseMagicKey(String magicKey) {
    try {
      // Split by pipe delimiter
      final parts = magicKey.split('|');

      // Must have exactly 4 parts
      if (parts.length != 4) {
        debugPrint(
          '[MagicKey] Invalid format: Expected 4 parts, got ${parts.length}',
        );
        return null;
      }

      // Extract components directly
      final serverUrl = parts[0];
      final randomHash = parts[1];

      // Parse timestamp
      final timestampMs = int.tryParse(parts[2]);
      if (timestampMs == null) {
        debugPrint('[MagicKey] Invalid timestamp: ${parts[2]}');
        return null;
      }

      final timestamp = DateTime.fromMillisecondsSinceEpoch(timestampMs);
      final signature = parts[3];

      debugPrint(
        '[MagicKey] Parsed - serverUrl: $serverUrl, randomHash: $randomHash',
      );

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

      // Get device info for native platforms
      String? deviceInfo;
      if (!kIsWeb) {
        deviceInfo = await DeviceInfoHelper.getDeviceDisplayName();
        debugPrint('[MagicKey] Device info: $deviceInfo');
      }

      // Call verification endpoint
      final requestData = {'key': magicKey, 'clientid': clientId};

      if (deviceInfo != null) {
        requestData['deviceInfo'] = deviceInfo;
      }

      final response = await ApiService.post(verifyUrl, data: requestData);

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
