import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure storage for session secrets using platform-specific secure storage
/// iOS: Keychain, Android: EncryptedSharedPreferences, Windows: Credential Manager
class SecureSessionStorage {
  static final SecureSessionStorage _instance =
      SecureSessionStorage._internal();
  factory SecureSessionStorage() => _instance;
  SecureSessionStorage._internal();

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      // encryptedSharedPreferences removed - deprecated and automatically migrated
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    wOptions: WindowsOptions(useBackwardCompatibility: false),
  );

  // Key prefixes for organization (server-scoped)
  static const _sessionSecretPrefix = 'session_secret_';
  static const _sessionMetadataPrefix = 'session_metadata_';
  static const _clientIdKey = 'client_id';
  static const _refreshTokenPrefix = 'refresh_token_'; // Now server-scoped
  static const _sessionExpiryPrefix = 'session_expiry_'; // Now server-scoped

  /// Generate server-scoped key
  String _makeServerScopedKey(
    String prefix,
    String serverUrl,
    String clientId,
  ) {
    // Sanitize server URL for use in key (replace special chars)
    final sanitized = serverUrl.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return '${prefix}${sanitized}_$clientId';
  }

  /// Save session secret for a client+server with retry on Windows file lock errors
  Future<void> saveSessionSecret(
    String clientId,
    String sessionSecret, {
    required String serverUrl,
  }) async {
    final key = _makeServerScopedKey(_sessionSecretPrefix, serverUrl, clientId);

    // Retry logic for Windows file locking issues
    int retries = 3;
    while (retries > 0) {
      try {
        await _storage.write(key: key, value: sessionSecret);

        // Save metadata (timestamp + server)
        final metadataKey = _makeServerScopedKey(
          _sessionMetadataPrefix,
          serverUrl,
          clientId,
        );
        final metadata = {
          'created_at': DateTime.now().toIso8601String(),
          'client_id': clientId,
          'server_url': serverUrl,
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

  /// Get session secret for a client+server with retry on Windows file lock errors
  Future<String?> getSessionSecret(
    String clientId, {
    required String serverUrl,
  }) async {
    final key = _makeServerScopedKey(_sessionSecretPrefix, serverUrl, clientId);

    // Retry logic for Windows file locking issues
    int retries = 3;
    while (retries > 0) {
      try {
        return await _storage.read(key: key);
      } catch (e) {
        retries--;
        if (retries == 0) {
          debugPrint(
            '[SecureSessionStorage] Failed to read session after retries: $e',
          );
          return null; // Return null instead of throwing
        }
        await Future.delayed(Duration(milliseconds: 100));
      }
    }
    return null;
  }

  /// Check if session secret exists for client+server
  Future<bool> hasSessionSecret(
    String clientId, {
    required String serverUrl,
  }) async {
    final secret = await getSessionSecret(clientId, serverUrl: serverUrl);
    return secret != null && secret.isNotEmpty;
  }

  /// Delete session secret for a client+server
  Future<void> deleteSessionSecret(
    String clientId, {
    required String serverUrl,
  }) async {
    final key = _makeServerScopedKey(_sessionSecretPrefix, serverUrl, clientId);
    final metadataKey = _makeServerScopedKey(
      _sessionMetadataPrefix,
      serverUrl,
      clientId,
    );

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

  /// Save client ID
  Future<void> saveClientId(String clientId) async {
    await _storage.write(key: _clientIdKey, value: clientId);
  }

  /// Get client ID
  Future<String?> getClientId() async {
    return await _storage.read(key: _clientIdKey);
  }

  /// Delete client ID
  Future<void> deleteClientId() async {
    await _storage.delete(key: _clientIdKey);
  }

  /// Save refresh token with retry on Windows file lock errors
  Future<void> saveRefreshToken(
    String refreshToken, {
    required String serverUrl,
  }) async {
    final clientId = await getClientId();
    if (clientId == null) {
      throw Exception('ClientId not found');
    }

    final key = _makeServerScopedKey(_refreshTokenPrefix, serverUrl, clientId);

    int retries = 3;
    while (retries > 0) {
      try {
        await _storage.write(key: key, value: refreshToken);
        return; // Success
      } catch (e) {
        retries--;
        if (retries == 0) rethrow;
        await Future.delayed(Duration(milliseconds: 100));
      }
    }
  }

  /// Get refresh token with retry on Windows file lock errors
  Future<String?> getRefreshToken({required String serverUrl}) async {
    final clientId = await getClientId();
    if (clientId == null) return null;

    final key = _makeServerScopedKey(_refreshTokenPrefix, serverUrl, clientId);

    int retries = 3;
    while (retries > 0) {
      try {
        return await _storage.read(key: key);
      } catch (e) {
        retries--;
        if (retries == 0) {
          debugPrint(
            '[SecureSessionStorage] Failed to read refresh token after retries: $e',
          );
          return null;
        }
        await Future.delayed(Duration(milliseconds: 100));
      }
    }
    return null;
  }

  /// Delete refresh token
  Future<void> deleteRefreshToken({required String serverUrl}) async {
    final clientId = await getClientId();
    if (clientId == null) return;

    final key = _makeServerScopedKey(_refreshTokenPrefix, serverUrl, clientId);
    await _storage.delete(key: key);
  }

  /// Save session expiry date
  Future<void> saveSessionExpiry(
    String expiryDate, {
    required String serverUrl,
  }) async {
    final clientId = await getClientId();
    if (clientId == null) {
      throw Exception('ClientId not found');
    }

    final key = _makeServerScopedKey(_sessionExpiryPrefix, serverUrl, clientId);
    await _storage.write(key: key, value: expiryDate);
  }

  /// Get session expiry date
  Future<String?> getSessionExpiry({required String serverUrl}) async {
    final clientId = await getClientId();
    if (clientId == null) return null;

    final key = _makeServerScopedKey(_sessionExpiryPrefix, serverUrl, clientId);
    return await _storage.read(key: key);
  }

  /// Delete session expiry
  Future<void> deleteSessionExpiry({required String serverUrl}) async {
    final clientId = await getClientId();
    if (clientId == null) return;

    final key = _makeServerScopedKey(_sessionExpiryPrefix, serverUrl, clientId);
    await _storage.delete(key: key);
  }
}
