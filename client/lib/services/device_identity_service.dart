import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:universal_html/html.dart' as html;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Service for managing device identity based on email, WebAuthn credential, and client ID
///
/// Device Identity = Hash(Email + WebAuthn Credential ID + Client ID UUID)
///
/// This ensures:
/// - Same user with different authenticators → different devices
/// - Same authenticator on different browsers → different devices
/// - Different users on same browser → different devices
///
/// Native Multi-Server Support:
/// - Stores one device identity per server URL
/// - Different email/account per server is supported
/// - Switching servers loads the correct identity
class DeviceIdentityService {
  static final DeviceIdentityService instance = DeviceIdentityService._();
  DeviceIdentityService._();

  static const String _storageKey =
      'device_identities'; // Changed to plural for multi-server
  static const String _activeServerKey = 'active_server_url';
  static final FlutterSecureStorage _secureStorage =
      const FlutterSecureStorage();

  // Current active identity
  String? _email;
  String? _credentialId;
  String? _clientId;
  String? _deviceId;
  String? _serverUrl;

  // Multi-server storage: serverUrl → identity data
  Map<String, Map<String, String>> _identities = {};

  /// Initialize device identity after authentication
  ///
  /// [email] - User's email address
  /// [credentialId] - WebAuthn credential ID (base64) or synthetic ID for native
  /// [clientId] - UUID unique to this browser/device
  /// [serverUrl] - Server URL (for multi-server support on native)
  Future<void> setDeviceIdentity(
    String email,
    String credentialId,
    String clientId, {
    String? serverUrl,
  }) async {
    _email = email;
    _credentialId = credentialId;
    _clientId = clientId;
    _serverUrl = serverUrl;
    _deviceId = _generateDeviceId(email, credentialId, clientId);

    // For native multi-server: store per-server identity
    if (!kIsWeb && serverUrl != null) {
      _identities[serverUrl] = {
        'email': email,
        'credentialId': credentialId,
        'clientId': clientId,
        'deviceId': _deviceId!,
      };

      // Save all identities and active server
      await _saveIdentities();
      await _saveActiveServer(serverUrl);

      debugPrint('[DEVICE_IDENTITY] ✓ Saved identity for server: $serverUrl');
    } else {
      // Web: single session-based identity (original behavior)
      final data = jsonEncode({
        'email': email,
        'credentialId': credentialId,
        'clientId': clientId,
        'deviceId': _deviceId,
      });

      html.window.sessionStorage[_storageKey] = data;
      debugPrint('[DEVICE_IDENTITY] ✓ Saved to SessionStorage');
    }

    debugPrint('[DEVICE_IDENTITY] Device initialized');
    debugPrint('[DEVICE_IDENTITY] Email: $email');
    debugPrint(
      '[DEVICE_IDENTITY] Credential ID: ${credentialId.substring(0, min(16, credentialId.length))}...',
    );
    debugPrint('[DEVICE_IDENTITY] Client ID: $clientId');
    debugPrint('[DEVICE_IDENTITY] Device ID: $_deviceId');
    if (serverUrl != null) {
      debugPrint('[DEVICE_IDENTITY] Server URL: $serverUrl');
    }
  }

  /// Restore device identity from storage (if exists)
  ///
  /// For web: Restores from SessionStorage
  /// For native: Loads identity for the specified server URL
  ///
  /// Returns true if successfully restored, false otherwise
  Future<bool> tryRestoreFromSession({String? serverUrl}) async {
    if (kIsWeb) {
      // Web: single session-based identity
      final stored = html.window.sessionStorage[_storageKey];
      if (stored == null) return false;

      try {
        final data = jsonDecode(stored) as Map<String, dynamic>;
        _email = data['email'] as String?;
        _credentialId = data['credentialId'] as String?;
        _clientId = data['clientId'] as String?;
        _deviceId = data['deviceId'] as String?;

        if (_email != null &&
            _credentialId != null &&
            _clientId != null &&
            _deviceId != null) {
          debugPrint('[DEVICE_IDENTITY] Restored from SessionStorage');
          return true;
        }
      } catch (e) {
        debugPrint(
          '[DEVICE_IDENTITY] Failed to restore from SessionStorage: $e',
        );
      }
      return false;
    } else {
      // Native: multi-server identity
      debugPrint(
        '[DEVICE_IDENTITY] 🔍 Attempting to restore native identity...',
      );
      await _loadIdentities();

      if (serverUrl != null) {
        // Load specific server's identity
        debugPrint('[DEVICE_IDENTITY] Loading identity for server: $serverUrl');
        return await _loadIdentityForServer(serverUrl);
      } else {
        // Load active server's identity
        debugPrint('[DEVICE_IDENTITY] Loading identity for active server...');
        final activeServer = await _loadActiveServer();
        if (activeServer != null) {
          debugPrint('[DEVICE_IDENTITY] Active server found: $activeServer');
          return await _loadIdentityForServer(activeServer);
        } else {
          debugPrint('[DEVICE_IDENTITY] ⚠️ No active server found');
        }
      }

      debugPrint('[DEVICE_IDENTITY] ❌ Failed to restore identity');
      return false;
    }
  }

  /// Load identity for a specific server (native only)
  Future<bool> _loadIdentityForServer(String serverUrl) async {
    final identity = _identities[serverUrl];
    if (identity == null) {
      debugPrint('[DEVICE_IDENTITY] No identity found for server: $serverUrl');
      return false;
    }

    _email = identity['email'];
    _credentialId = identity['credentialId'];
    _clientId = identity['clientId'];
    _deviceId = identity['deviceId'];
    _serverUrl = serverUrl;

    debugPrint('[DEVICE_IDENTITY] Restored identity for server: $serverUrl');
    debugPrint('[DEVICE_IDENTITY] Email: $_email');
    debugPrint('[DEVICE_IDENTITY] Device ID: $_deviceId');

    return true;
  }

  /// Load all identities from storage (native only)
  Future<void> _loadIdentities() async {
    try {
      final stored = await _secureStorage.read(key: _storageKey);
      if (stored != null) {
        final decoded = jsonDecode(stored) as Map<String, dynamic>;
        _identities = decoded.map(
          (key, value) => MapEntry(key, Map<String, String>.from(value as Map)),
        );
        debugPrint(
          '[DEVICE_IDENTITY] Loaded ${_identities.length} server identities',
        );
      }
    } catch (e) {
      debugPrint('[DEVICE_IDENTITY] Failed to load identities: $e');
      _identities = {};
    }
  }

  /// Save all identities to storage (native only)
  Future<void> _saveIdentities() async {
    try {
      final json = jsonEncode(_identities);
      await _secureStorage.write(key: _storageKey, value: json);
      debugPrint(
        '[DEVICE_IDENTITY] Saved ${_identities.length} server identities',
      );
    } catch (e) {
      debugPrint('[DEVICE_IDENTITY] Failed to save identities: $e');
    }
  }

  /// Load active server URL (native only)
  Future<String?> _loadActiveServer() async {
    try {
      return await _secureStorage.read(key: _activeServerKey);
    } catch (e) {
      debugPrint('[DEVICE_IDENTITY] Failed to load active server: $e');
      return null;
    }
  }

  /// Save active server URL (native only)
  Future<void> _saveActiveServer(String serverUrl) async {
    try {
      await _secureStorage.write(key: _activeServerKey, value: serverUrl);
      debugPrint('[DEVICE_IDENTITY] Saved active server: $serverUrl');
    } catch (e) {
      debugPrint('[DEVICE_IDENTITY] Failed to save active server: $e');
    }
  }

  /// Clear device identity on logout
  ///
  /// For web: Clears session storage
  /// For native: Optionally clears specific server's identity or all identities
  Future<void> clearDeviceIdentity({String? serverUrl}) async {
    debugPrint('[DEVICE_IDENTITY] Clearing device identity');

    if (kIsWeb) {
      // Web: clear session storage
      _email = null;
      _credentialId = null;
      _clientId = null;
      _deviceId = null;
      html.window.sessionStorage.remove(_storageKey);
    } else {
      // Native: clear specific server or all
      if (serverUrl != null) {
        // Clear specific server's identity
        _identities.remove(serverUrl);
        await _saveIdentities();

        // If cleared the active identity, reset current state
        if (_serverUrl == serverUrl) {
          _email = null;
          _credentialId = null;
          _clientId = null;
          _deviceId = null;
          _serverUrl = null;
        }

        debugPrint('[DEVICE_IDENTITY] Cleared identity for server: $serverUrl');
      } else {
        // Clear all identities
        _email = null;
        _credentialId = null;
        _clientId = null;
        _deviceId = null;
        _serverUrl = null;
        _identities.clear();
        await _secureStorage.delete(key: _storageKey);
        await _secureStorage.delete(key: _activeServerKey);
        debugPrint('[DEVICE_IDENTITY] Cleared all identities');
      }
    }
  }

  /// Generate stable device ID from email + client ID
  ///
  /// CRITICAL: deviceId represents the DEVICE, not individual passkeys!
  /// This ensures:
  /// - Same user on different devices → different deviceId (different clientId)
  /// - Multiple passkeys on same device → SAME deviceId (same clientId)
  /// - Database and encryption keys remain stable when adding passkeys
  ///
  /// Note: credentialId is NOT included in deviceId hash, as the device identity
  /// should remain stable even when registering additional security keys
  String _generateDeviceId(String email, String credentialId, String clientId) {
    // Device ID based ONLY on email + clientId (stable per device)
    final combined = '$email:$clientId';
    final bytes = utf8.encode(combined);
    final digest = sha256.convert(bytes);

    // Use first 16 chars of hex digest for filesystem-safe ID
    return digest.toString().substring(0, 16);
  }

  /// Switch to a different server's identity (native only)
  ///
  /// This should be called when switching servers on native clients
  Future<bool> switchToServer(String serverUrl) async {
    if (kIsWeb) {
      debugPrint('[DEVICE_IDENTITY] Server switching not supported on web');
      return false;
    }

    await _loadIdentities();
    final success = await _loadIdentityForServer(serverUrl);

    if (success) {
      await _saveActiveServer(serverUrl);
      debugPrint('[DEVICE_IDENTITY] Switched to server: $serverUrl');
    } else {
      debugPrint(
        '[DEVICE_IDENTITY] Failed to switch to server: $serverUrl (identity not found)',
      );
    }

    return success;
  }

  /// Get current device ID
  String get deviceId {
    if (_deviceId == null) {
      debugPrint(
        '[DEVICE_IDENTITY] ❌ deviceId getter called but _deviceId is null!',
      );
      debugPrint('[DEVICE_IDENTITY]    _email: $_email');
      debugPrint('[DEVICE_IDENTITY]    _credentialId: $_credentialId');
      debugPrint('[DEVICE_IDENTITY]    _clientId: $_clientId');
      debugPrint('[DEVICE_IDENTITY]    _serverUrl: $_serverUrl');
      throw Exception(
        'Device identity not initialized. Call setDeviceIdentity first.',
      );
    }
    return _deviceId!;
  }

  /// Get current email
  String get email {
    if (_email == null) {
      throw Exception('Device identity not initialized.');
    }
    return _email!;
  }

  /// Get current credential ID
  String get credentialId {
    if (_credentialId == null) {
      throw Exception('Device identity not initialized.');
    }
    return _credentialId!;
  }

  /// Get current client ID
  String get clientId {
    if (_clientId == null) {
      throw Exception('Device identity not initialized.');
    }
    return _clientId!;
  }

  /// Get current server URL (native only)
  String? get serverUrl => _serverUrl;

  /// Check if device identity is set
  bool get isInitialized => _deviceId != null;

  /// Get device display name for UI
  String get displayName {
    if (!isInitialized) return 'Unknown Device';

    final shortCredId = _credentialId!.substring(0, 8);
    final shortClientId = _clientId!.substring(0, 8);
    return '$_email ($shortCredId...-$shortClientId...)';
  }
}
