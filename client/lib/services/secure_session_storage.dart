import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure storage for session secrets using platform-specific secure storage
/// iOS: Keychain, Android: EncryptedSharedPreferences, Windows: Credential Manager
class SecureSessionStorage {
  static final SecureSessionStorage _instance = SecureSessionStorage._internal();
  factory SecureSessionStorage() => _instance;
  SecureSessionStorage._internal();

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      // encryptedSharedPreferences removed - deprecated and automatically migrated
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    wOptions: WindowsOptions(
      useBackwardCompatibility: false,
    ),
  );

  // Key prefixes for organization
  static const _sessionSecretPrefix = 'session_secret_';
  static const _sessionMetadataPrefix = 'session_metadata_';

  /// Save session secret for a client with retry on Windows file lock errors
  Future<void> saveSessionSecret(String clientId, String sessionSecret) async {
    final key = '$_sessionSecretPrefix$clientId';
    
    // Retry logic for Windows file locking issues
    int retries = 3;
    while (retries > 0) {
      try {
        await _storage.write(key: key, value: sessionSecret);
        
        // Save metadata (timestamp)
        final metadataKey = '$_sessionMetadataPrefix$clientId';
        final metadata = {
          'created_at': DateTime.now().toIso8601String(),
          'client_id': clientId,
        };
        await _storage.write(key: metadataKey, value: metadata.toString());
        return; // Success
      } catch (e) {
        retries--;
        if (retries == 0) rethrow;
        // Wait before retry (file might be locked)
        await Future.delayed(Duration(milliseconds: 100));
      }
    }
  }

  /// Get session secret for a client with retry on Windows file lock errors
  Future<String?> getSessionSecret(String clientId) async {
    final key = '$_sessionSecretPrefix$clientId';
    
    // Retry logic for Windows file locking issues
    int retries = 3;
    while (retries > 0) {
      try {
        return await _storage.read(key: key);
      } catch (e) {
        retries--;
        if (retries == 0) {
          debugPrint('[SecureSessionStorage] Failed to read session after retries: $e');
          return null; // Return null instead of throwing
        }
        await Future.delayed(Duration(milliseconds: 100));
      }
    }
    return null;
  }

  /// Check if session secret exists for client
  Future<bool> hasSessionSecret(String clientId) async {
    final secret = await getSessionSecret(clientId);
    return secret != null && secret.isNotEmpty;
  }

  /// Delete session secret for a client
  Future<void> deleteSessionSecret(String clientId) async {
    final key = '$_sessionSecretPrefix$clientId';
    final metadataKey = '$_sessionMetadataPrefix$clientId';
    
    await _storage.delete(key: key);
    await _storage.delete(key: metadataKey);
  }

  /// Delete all session secrets
  Future<void> deleteAllSessionSecrets() async {
    final allKeys = await _storage.readAll();
    
    for (final key in allKeys.keys) {
      if (key.startsWith(_sessionSecretPrefix) || 
          key.startsWith(_sessionMetadataPrefix)) {
        await _storage.delete(key: key);
      }
    }
  }

  /// Get all client IDs with stored sessions
  Future<List<String>> getAllClientIds() async {
    final allKeys = await _storage.readAll();
    final clientIds = <String>[];
    
    for (final key in allKeys.keys) {
      if (key.startsWith(_sessionSecretPrefix)) {
        final clientId = key.substring(_sessionSecretPrefix.length);
        clientIds.add(clientId);
      }
    }
    
    return clientIds;
  }

  /// Get session creation time for a client
  Future<DateTime?> getSessionCreatedAt(String clientId) async {
    final metadataKey = '$_sessionMetadataPrefix$clientId';
    final metadataString = await _storage.read(key: metadataKey);
    
    if (metadataString != null) {
      try {
        // Parse the stored timestamp
        final regex = RegExp(r'created_at: ([^,}]+)');
        final match = regex.firstMatch(metadataString);
        if (match != null) {
          return DateTime.parse(match.group(1)!);
        }
      } catch (e) {
        debugPrint('[SecureSessionStorage] Error parsing metadata: $e');
      }
    }
    
    return null;
  }
}
