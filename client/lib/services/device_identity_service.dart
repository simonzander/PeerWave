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
class DeviceIdentityService {
  static final DeviceIdentityService instance = DeviceIdentityService._();
  DeviceIdentityService._();
  
  static const String _storageKey = 'device_identity';
  static final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  
  String? _email;
  String? _credentialId;
  String? _clientId;
  String? _deviceId;
  
  /// Initialize device identity after WebAuthn login
  /// 
  /// [email] - User's email address
  /// [credentialId] - WebAuthn credential ID (base64)
  /// [clientId] - UUID unique to this browser/device (already implemented in your codebase)
  void setDeviceIdentity(String email, String credentialId, String clientId) {
    _email = email;
    _credentialId = credentialId;
    _clientId = clientId;
    _deviceId = _generateDeviceId(email, credentialId, clientId);
    
    // 💾 Persist to storage (fire and forget for native)
    final data = jsonEncode({
      'email': email,
      'credentialId': credentialId,
      'clientId': clientId,
      'deviceId': _deviceId,
    });
    
    if (kIsWeb) {
      html.window.sessionStorage[_storageKey] = data;
    } else {
      // For native, use secure storage (persists across restarts)
      // Fire and forget - don't wait for write to complete
      _secureStorage.write(key: _storageKey, value: data);
    }
    
    debugPrint('[DEVICE_IDENTITY] Device initialized');
    debugPrint('[DEVICE_IDENTITY] Email: $email');
    debugPrint('[DEVICE_IDENTITY] Credential ID: ${credentialId.substring(0, min(16, credentialId.length))}...');
    debugPrint('[DEVICE_IDENTITY] Client ID: $clientId');
    debugPrint('[DEVICE_IDENTITY] Device ID: $_deviceId');
  }
  
  /// Restore device identity from storage (if exists)
  /// 
  /// Returns true if successfully restored, false otherwise
  Future<bool> tryRestoreFromSession() async {
    String? stored;
    
    if (kIsWeb) {
      stored = html.window.sessionStorage[_storageKey];
    } else {
      stored = await _secureStorage.read(key: _storageKey);
    }
    
    if (stored == null) return false;
    
    try {
      final data = jsonDecode(stored) as Map<String, dynamic>;
      _email = data['email'] as String?;
      _credentialId = data['credentialId'] as String?;
      _clientId = data['clientId'] as String?;
      _deviceId = data['deviceId'] as String?;
      
      if (_email != null && _credentialId != null && _clientId != null && _deviceId != null) {
        debugPrint('[DEVICE_IDENTITY] Restored from storage');
        return true;
      }
    } catch (e) {
      debugPrint('[DEVICE_IDENTITY] Failed to restore from storage: $e');
    }
    
    return false;
  }
  
  /// Clear device identity on logout
  Future<void> clearDeviceIdentity() async {
    debugPrint('[DEVICE_IDENTITY] Clearing device identity');
    _email = null;
    _credentialId = null;
    _clientId = null;
    _deviceId = null;
    
    // Clear from storage
    if (kIsWeb) {
      html.window.sessionStorage.remove(_storageKey);
    } else {
      await _secureStorage.delete(key: _storageKey);
    }
  }
  
  /// Generate stable device ID from email + credential ID + client ID
  /// 
  /// This ensures:
  /// - Same user on different devices → different deviceId (different clientId)
  /// - Same user with different authenticators → different deviceId (different credentialId)
  /// - Same authenticator on different browsers → different deviceId (different clientId)
  String _generateDeviceId(String email, String credentialId, String clientId) {
    final combined = '$email:$credentialId:$clientId';
    final bytes = utf8.encode(combined);
    final digest = sha256.convert(bytes);
    
    // Use first 16 chars of hex digest for filesystem-safe ID
    return digest.toString().substring(0, 16);
  }
  
  /// Get current device ID
  String get deviceId {
    if (_deviceId == null) {
      throw Exception('Device identity not initialized. Call setDeviceIdentity first.');
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
