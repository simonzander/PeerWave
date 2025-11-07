# Device-Scoped IndexedDB Storage with WebAuthn Encryption - Implementation Plan

## 🎯 Core Concept

**Device = Email + WebAuthn Credential ID + Client ID (UUID) + WebAuthn Signature Encryption**

Each device gets:
1. **Isolated IndexedDB databases** (device-specific names based on email + credential + clientId)
2. **Encrypted data at rest** (AES-GCM with key derived from WebAuthn signature)
3. **Zero-knowledge architecture** (server never has decryption keys)
4. **Unique per browser/device** (clientId UUID ensures isolation even with same authenticator)

**Best of both worlds: Isolation + Encryption**

---

## 📐 Architecture

### Three-Layer Security Model

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 1: Device Isolation                                   │
├─────────────────────────────────────────────────────────────┤
│ Device ID = Hash(Email + WebAuthn Credential ID + ClientId) │
│ ClientId = UUID unique to this browser/device               │
│ Each device → Separate IndexedDB databases                  │
│ Database names: peerwaveSignal_<deviceId>                   │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ Layer 2: WebAuthn Encryption                                │
├─────────────────────────────────────────────────────────────┤
│ WebAuthn Authentication → Signature                         │
│ Derive Encryption Key: HKDF(signature, salt, info)          │
│ Store key in SessionStorage (cleared on logout)             │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ Layer 3: Data Encryption                                    │
├─────────────────────────────────────────────────────────────┤
│ Plaintext → AES-GCM-256 Encrypt → Encrypted Blob            │
│ Store: {iv, encryptedData, authTag}                         │
│ On Read: Decrypt with session key                           │
└─────────────────────────────────────────────────────────────┘
```

### Authentication & Encryption Flow

```
┌─────────────────────────────────────────────────────────────┐
│ LOGIN FLOW                                                  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│ 1. User initiates login (email)                            │
│    ↓                                                        │
│ 2. WebAuthn Challenge sent to authenticator                │
│    ↓                                                        │
│ 3. User provides biometric/PIN                             │
│    ↓                                                        │
│ 4. WebAuthn returns:                                       │
│    - credential.id (device identifier)                     │
│    - credential.response.signature (for encryption)        │
│    ↓                                                        │
│ 5. Set Device Identity:                                    │
│    deviceId = hash(email + credential.id + clientId)       │
│    ↓                                                        │
│ 6. Derive Encryption Key:                                  │
│    key = HKDF(signature, salt, "peerwave-idb-v1")         │
│    ↓                                                        │
│ 7. Store key in SessionStorage (memory only)               │
│    sessionStorage['encryption_key_<deviceId>'] = key       │
│    ↓                                                        │
│ 8. Initialize device-specific encrypted stores             │
│                                                             │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ DATA WRITE FLOW                                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│ 1. Application wants to store data                         │
│    ↓                                                        │
│ 2. Get encryption key from SessionStorage                  │
│    ↓                                                        │
│ 3. Generate random IV (12 bytes)                           │
│    ↓                                                        │
│ 4. Serialize data → JSON string → UTF-8 bytes              │
│    ↓                                                        │
│ 5. Encrypt: AES-GCM-256(plaintext, key, iv)               │
│    ↓                                                        │
│ 6. Create envelope: {iv, encryptedData, version}           │
│    ↓                                                        │
│ 7. Store in device-specific IndexedDB                      │
│    peerwaveSignal_<deviceId> → key → envelope              │
│                                                             │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ DATA READ FLOW                                              │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│ 1. Application wants to read data                          │
│    ↓                                                        │
│ 2. Load envelope from device-specific IndexedDB            │
│    ↓                                                        │
│ 3. Get encryption key from SessionStorage                  │
│    ↓                                                        │
│ 4. Decrypt: AES-GCM-256(encryptedData, key, iv)           │
│    ↓                                                        │
│ 5. Deserialize: UTF-8 bytes → JSON string → Object         │
│    ↓                                                        │
│ 6. Return plaintext data                                   │
│                                                             │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ LOGOUT FLOW                                                 │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│ 1. User initiates logout                                   │
│    ↓                                                        │
│ 2. Clear encryption key from SessionStorage                │
│    sessionStorage.removeItem('encryption_key_<deviceId>')  │
│    ↓                                                        │
│ 3. Clear device identity                                   │
│    ↓                                                        │
│ 4. Clear session                                           │
│    ↓                                                        │
│ 5. Encrypted data remains in IndexedDB                     │
│    (unreadable without key)                                │
│    ↓                                                        │
│ 6. Optional: Delete device databases                       │
│    (for complete cleanup)                                  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Device Identity

```dart
class DeviceIdentity {
  final String email;
  final String webAuthnCredentialId; // From WebAuthn credential
  
  /// Unique device identifier
  String get deviceId {
    // Use hash to create filesystem-safe identifier
    final combined = '$email:$webAuthnCredentialId';
    return combined.hashCode.toRadixString(36).replaceAll('-', 'n');
  }
  
  /// Human-readable device name for UI
  String get displayName {
    final shortId = webAuthnCredentialId.substring(0, 8);
    return '$email ($shortId...)';
  }
}
```

### WebAuthn Crypto Service

**File:** `client/lib/services/web/webauthn_crypto_service.dart`

```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'dart:html' as html;

class WebAuthnCryptoService {
  static final WebAuthnCryptoService instance = WebAuthnCryptoService._();
  WebAuthnCryptoService._();
  
  // Encryption key stored in SessionStorage (survives page refresh, cleared on tab close)
  static const _keyStoragePrefix = 'peerwave_encryption_key_';
  
  /// Derive encryption key from WebAuthn signature using HKDF
  Future<Uint8List> deriveEncryptionKey(Uint8List signature) async {
    debugPrint('[WEBAUTHN_CRYPTO] Deriving encryption key from signature');
    
    // HKDF parameters
    final salt = utf8.encode('peerwave-indexeddb-encryption-v1');
    final info = utf8.encode('aes-gcm-256');
    
    // Use crypto.subtle for Web Crypto API (browser native)
    if (kIsWeb) {
      try {
        // Import signature as key material
        final keyMaterial = await html.window.crypto!.subtle!.importKey(
          'raw',
          signature,
          {'name': 'HKDF'},
          false,
          ['deriveKey'],
        );
        
        // Derive AES-GCM key
        final derivedKey = await html.window.crypto!.subtle!.deriveKey(
          {
            'name': 'HKDF',
            'salt': Uint8List.fromList(salt),
            'info': Uint8List.fromList(info),
            'hash': 'SHA-256',
          },
          keyMaterial,
          {
            'name': 'AES-GCM',
            'length': 256,
          },
          true, // extractable (so we can store in SessionStorage)
          ['encrypt', 'decrypt'],
        );
        
        // Export key as raw bytes
        final exportedKey = await html.window.crypto!.subtle!.exportKey('raw', derivedKey);
        final keyBytes = Uint8List.view(exportedKey as ByteBuffer);
        
        debugPrint('[WEBAUTHN_CRYPTO] ✓ Key derived successfully (${keyBytes.length} bytes)');
        return keyBytes;
      } catch (e) {
        debugPrint('[WEBAUTHN_CRYPTO] ✗ Web Crypto API failed: $e');
        // Fallback to Dart implementation
        return _deriveKeyFallback(signature, salt, info);
      }
    } else {
      // Native platform: Use Dart crypto
      return _deriveKeyFallback(signature, salt, info);
    }
  }
  
  /// Fallback HKDF implementation (for native or if Web Crypto fails)
  Uint8List _deriveKeyFallback(Uint8List ikm, List<int> salt, List<int> info) {
    debugPrint('[WEBAUTHN_CRYPTO] Using fallback HKDF implementation');
    
    // HKDF-Extract
    final hmacExtract = Hmac(sha256, salt);
    final prk = hmacExtract.convert(ikm).bytes;
    
    // HKDF-Expand (32 bytes for AES-256)
    final hmacExpand = Hmac(sha256, prk);
    final t = <int>[];
    final okm = <int>[];
    
    for (var i = 1; okm.length < 32; i++) {
      t.addAll(info);
      t.add(i);
      final hash = hmacExpand.convert(t).bytes;
      okm.addAll(hash);
      t.clear();
      t.addAll(hash);
    }
    
    return Uint8List.fromList(okm.sublist(0, 32));
  }
  
  /// Store encryption key in SessionStorage (cleared on browser close)
  void storeKeyInSession(String deviceId, Uint8List key) {
    final keyString = base64Encode(key);
    final storageKey = '$_keyStoragePrefix$deviceId';
    
    if (kIsWeb) {
      html.window.sessionStorage[storageKey] = keyString;
      debugPrint('[WEBAUTHN_CRYPTO] ✓ Key stored in SessionStorage');
    } else {
      // Native: Store in memory (session-scoped)
      _memoryKeyStore[deviceId] = key;
      debugPrint('[WEBAUTHN_CRYPTO] ✓ Key stored in memory');
    }
  }
  
  /// Retrieve encryption key from SessionStorage
  Uint8List? getKeyFromSession(String deviceId) {
    final storageKey = '$_keyStoragePrefix$deviceId';
    
    if (kIsWeb) {
      final keyString = html.window.sessionStorage[storageKey];
      if (keyString != null) {
        debugPrint('[WEBAUTHN_CRYPTO] ✓ Key retrieved from SessionStorage');
        return base64Decode(keyString);
      }
    } else {
      final key = _memoryKeyStore[deviceId];
      if (key != null) {
        debugPrint('[WEBAUTHN_CRYPTO] ✓ Key retrieved from memory');
        return key;
      }
    }
    
    debugPrint('[WEBAUTHN_CRYPTO] ✗ No key found in session');
    return null;
  }
  
  /// Clear encryption key from session
  void clearKeyFromSession(String deviceId) {
    final storageKey = '$_keyStoragePrefix$deviceId';
    
    if (kIsWeb) {
      html.window.sessionStorage.remove(storageKey);
    } else {
      _memoryKeyStore.remove(deviceId);
    }
    
    debugPrint('[WEBAUTHN_CRYPTO] ✓ Key cleared from session');
  }
  
  // Memory store for native platforms
  final Map<String, Uint8List> _memoryKeyStore = {};
  
  /// Encrypt data with AES-GCM
  Future<Map<String, String>> encrypt(Uint8List plaintext, Uint8List key) async {
    debugPrint('[WEBAUTHN_CRYPTO] Encrypting data (${plaintext.length} bytes)');
    
    if (kIsWeb) {
      try {
        // Use Web Crypto API
        final cryptoKey = await html.window.crypto!.subtle!.importKey(
          'raw',
          key,
          {'name': 'AES-GCM'},
          false,
          ['encrypt'],
        );
        
        // Generate random IV (12 bytes for GCM)
        final iv = html.window.crypto!.getRandomValues(Uint8List(12));
        
        // Encrypt
        final encrypted = await html.window.crypto!.subtle!.encrypt(
          {
            'name': 'AES-GCM',
            'iv': iv,
          },
          cryptoKey,
          plaintext,
        );
        
        final encryptedBytes = Uint8List.view(encrypted as ByteBuffer);
        
        debugPrint('[WEBAUTHN_CRYPTO] ✓ Data encrypted (${encryptedBytes.length} bytes)');
        
        return {
          'iv': base64Encode(iv),
          'data': base64Encode(encryptedBytes),
        };
      } catch (e) {
        debugPrint('[WEBAUTHN_CRYPTO] ✗ Web Crypto encryption failed: $e');
        throw Exception('Encryption failed: $e');
      }
    } else {
      // Native: Would need platform-specific crypto implementation
      throw UnimplementedError('Native encryption not yet implemented');
    }
  }
  
  /// Decrypt data with AES-GCM
  Future<Uint8List> decrypt(String ivBase64, String dataBase64, Uint8List key) async {
    debugPrint('[WEBAUTHN_CRYPTO] Decrypting data');
    
    if (kIsWeb) {
      try {
        final cryptoKey = await html.window.crypto!.subtle!.importKey(
          'raw',
          key,
          {'name': 'AES-GCM'},
          false,
          ['decrypt'],
        );
        
        final iv = base64Decode(ivBase64);
        final encryptedData = base64Decode(dataBase64);
        
        final decrypted = await html.window.crypto!.subtle!.decrypt(
          {
            'name': 'AES-GCM',
            'iv': iv,
          },
          cryptoKey,
          encryptedData,
        );
        
        final decryptedBytes = Uint8List.view(decrypted as ByteBuffer);
        
        debugPrint('[WEBAUTHN_CRYPTO] ✓ Data decrypted (${decryptedBytes.length} bytes)');
        
        return decryptedBytes;
      } catch (e) {
        debugPrint('[WEBAUTHN_CRYPTO] ✗ Decryption failed: $e');
        throw Exception('Decryption failed: $e');
      }
    } else {
      throw UnimplementedError('Native decryption not yet implemented');
    }
  }
}
```

### Encrypted Storage Wrapper

**File:** `client/lib/services/web/encrypted_storage_wrapper.dart`

```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'webauthn_crypto_service.dart';
import '../device_identity_service.dart';

class EncryptedStorageWrapper {
  final WebAuthnCryptoService _crypto = WebAuthnCryptoService.instance;
  final DeviceIdentityService _deviceIdentity = DeviceIdentityService.instance;
  
  /// Encrypt data before storing
  Future<Map<String, dynamic>> encryptForStorage(dynamic value) async {
    // Get encryption key from session
    final key = _crypto.getKeyFromSession(_deviceIdentity.deviceId);
    if (key == null) {
      throw Exception('No encryption key available. Please re-authenticate.');
    }
    
    // Serialize value
    final plaintext = jsonEncode(value);
    final plaintextBytes = utf8.encode(plaintext);
    
    // Encrypt
    final encrypted = await _crypto.encrypt(Uint8List.fromList(plaintextBytes), key);
    
    // Create envelope with metadata
    return {
      'version': 1,
      'deviceId': _deviceIdentity.deviceId,
      'iv': encrypted['iv'],
      'data': encrypted['data'],
      'timestamp': DateTime.now().toIso8601String(),
    };
  }
  
  /// Decrypt data when reading
  Future<dynamic> decryptFromStorage(Map<String, dynamic> envelope) async {
    // Verify device ownership
    if (envelope['deviceId'] != _deviceIdentity.deviceId) {
      throw Exception('Data belongs to different device');
    }
    
    // Get encryption key
    final key = _crypto.getKeyFromSession(_deviceIdentity.deviceId);
    if (key == null) {
      throw Exception('No encryption key available. Please re-authenticate.');
    }
    
    // Decrypt
    final decryptedBytes = await _crypto.decrypt(
      envelope['iv'] as String,
      envelope['data'] as String,
      key,
    );
    
    // Deserialize
    final plaintext = utf8.decode(decryptedBytes);
    return jsonDecode(plaintext);
  }
}
```

### Device-Scoped Storage Service (Updated with Encryption)

```dart
class DeviceScopedStorage {
  final DeviceIdentity device;
  
  /// Generate device-specific database name
  String getDatabaseName(String baseName) {
    return '${baseName}_${device.deviceId}';
  }
  
  /// Open device-specific IndexedDB
  Future<Database> openDeviceDatabase(String baseName) async {
    final dbName = getDatabaseName(baseName);
    
    return await idbFactory.open(
      dbName,
      version: 1,
      onUpgradeNeeded: (event) {
        // Setup schema
      }
    );
  }
  
  /// Delete all device databases
  Future<void> deleteAllDeviceData() async {
    final databases = [
      'peerwaveSignal',
      'peerwaveSignalIdentityKeys',
      'peerwavePreKeys',
      'peerwaveSignedPreKeys',
      'peerwaveSenderKeys',
      'peerwaveSessions',
      'peerwaveDecryptedMessages',
      'peerwaveSentMessages',
      'peerwaveDecryptedGroupItems',
      'peerwaveSentGroupItems',
    ];
    
    for (final baseName in databases) {
      final dbName = getDatabaseName(baseName);
      try {
        await idbFactory.deleteDatabase(dbName);
        debugPrint('[DEVICE_STORAGE] Deleted: $dbName');
      } catch (e) {
        debugPrint('[DEVICE_STORAGE] Failed to delete $dbName: $e');
      }
    }
  }
}
```

---

## 🔧 Implementation Steps

### Phase 1: Crypto Infrastructure (Week 1-2)

#### Step 1.1: Add Dependencies

**File:** `client/pubspec.yaml`

```yaml
dependencies:
  crypto: ^3.0.3  # For HKDF, SHA-256, HMAC
  convert: ^3.1.1 # For base64
```

Run: `flutter pub get`

#### Step 1.2: Create WebAuthn Crypto Service

**Create file:** `client/lib/services/web/webauthn_crypto_service.dart`

Copy the complete implementation from the "WebAuthn Crypto Service" section above. This provides:
- ✅ HKDF key derivation from WebAuthn signature
- ✅ AES-GCM-256 encryption/decryption
- ✅ SessionStorage key management
- ✅ Web and native platform support

**Test the service:**
```dart
test('WebAuthn crypto service key derivation', () async {
  final signature = Uint8List.fromList(List.generate(64, (i) => i));
  
  final key = await WebAuthnCryptoService.instance.deriveEncryptionKey(signature);
  
  expect(key.length, equals(32)); // 256 bits
  
  // Test consistency
  final key2 = await WebAuthnCryptoService.instance.deriveEncryptionKey(signature);
  expect(key, equals(key2));
});

test('Encryption and decryption roundtrip', () async {
  final crypto = WebAuthnCryptoService.instance;
  final key = Uint8List.fromList(List.generate(32, (i) => i));
  final plaintext = Uint8List.fromList(utf8.encode('Hello, World!'));
  
  final encrypted = await crypto.encrypt(plaintext, key);
  expect(encrypted['iv'], isNotNull);
  expect(encrypted['data'], isNotNull);
  
  final decrypted = await crypto.decrypt(
    encrypted['iv']!,
    encrypted['data']!,
    key,
  );
  
  expect(utf8.decode(decrypted), equals('Hello, World!'));
});
```

#### Step 1.3: Create Encrypted Storage Wrapper

**Create file:** `client/lib/services/web/encrypted_storage_wrapper.dart`

Copy the complete implementation from the "Encrypted Storage Wrapper" section above. This provides:
- ✅ Transparent encryption/decryption
- ✅ Envelope format with metadata
- ✅ Device ownership verification

**Test the wrapper:**
```dart
test('Encrypted storage wrapper roundtrip', () async {
  final wrapper = EncryptedStorageWrapper();
  final testData = {
    'message': 'Hello',
    'timestamp': DateTime.now().toIso8601String(),
    'count': 42,
  };
  
  // Initialize device identity
  DeviceIdentityService.instance.setDeviceIdentity('test@example.com', 'cred123');
  
  // Derive and store key
  final signature = Uint8List.fromList(List.generate(64, (i) => i));
  final key = await WebAuthnCryptoService.instance.deriveEncryptionKey(signature);
  WebAuthnCryptoService.instance.storeKeyInSession(
    DeviceIdentityService.instance.deviceId,
    key,
  );
  
  // Encrypt
  final envelope = await wrapper.encryptForStorage(testData);
  expect(envelope['version'], equals(1));
  expect(envelope['deviceId'], isNotNull);
  expect(envelope['iv'], isNotNull);
  expect(envelope['data'], isNotNull);
  
  // Decrypt
  final decrypted = await wrapper.decryptFromStorage(envelope);
  expect(decrypted, equals(testData));
});
```

#### Step 1.4: Extract WebAuthn Signature on Login

**File:** `client/lib/services/auth/webauthn_service.dart`

```dart
class WebAuthnService {
  String? _currentCredentialId;
  Uint8List? _lastSignature;
  
  Future<WebAuthnLoginResult> login(String email) async {
    // Get credential from WebAuthn
    final credential = await navigator.credentials.get({
      'publicKey': {
        'challenge': challenge,
        'rpId': 'peerwave.app',
        'userVerification': 'required',
      }
    });
    
    // Extract credential ID (unique per authenticator)
    _currentCredentialId = base64Encode(credential.rawId);
    
    // Extract signature (for key derivation)
    _lastSignature = Uint8List.fromList(credential.response.signature);
    
    debugPrint('[WEBAUTHN] Credential ID: ${_currentCredentialId!.substring(0, 16)}...');
    debugPrint('[WEBAUTHN] Signature length: ${_lastSignature!.length} bytes');
    
    return WebAuthnLoginResult(
      email: email,
      credentialId: _currentCredentialId!,
      signature: _lastSignature!,
    );
  }
  
  String? get currentCredentialId => _currentCredentialId;
  Uint8List? get lastSignature => _lastSignature;
}
```

#### Step 1.2: Create Device Identity Service

**File:** `client/lib/services/device_identity_service.dart`

```dart
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

class DeviceIdentityService {
  static final DeviceIdentityService instance = DeviceIdentityService._();
  DeviceIdentityService._();
  
  String? _email;
  String? _credentialId;
  String? _deviceId;
  
  /// Initialize device identity after WebAuthn login
  void setDeviceIdentity(String email, String credentialId) {
    _email = email;
    _credentialId = credentialId;
    _deviceId = _generateDeviceId(email, credentialId);
    
    debugPrint('[DEVICE_IDENTITY] Device initialized');
    debugPrint('[DEVICE_IDENTITY] Email: $email');
    debugPrint('[DEVICE_IDENTITY] Credential ID: ${credentialId.substring(0, 16)}...');
    debugPrint('[DEVICE_IDENTITY] Device ID: $_deviceId');
  }
  
  /// Clear device identity on logout
  void clearDeviceIdentity() {
    debugPrint('[DEVICE_IDENTITY] Clearing device identity');
    _email = null;
    _credentialId = null;
    _deviceId = null;
  }
  
  /// Generate stable device ID from email + credential ID
  String _generateDeviceId(String email, String credentialId) {
    final combined = '$email:$credentialId';
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
  
  /// Check if device identity is set
  bool get isInitialized => _deviceId != null;
  
  /// Get device display name for UI
  String get displayName {
    if (!isInitialized) return 'Unknown Device';
    
    final shortCredId = _credentialId!.substring(0, 8);
    return '$_email ($shortCredId...)';
  }
}
```

#### Step 1.2: Create Device Identity Service

**File:** `client/lib/services/device_identity_service.dart`

```dart
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

class DeviceIdentityService {
  static final DeviceIdentityService instance = DeviceIdentityService._();
  DeviceIdentityService._();
  
  String? _email;
  String? _credentialId;
  String? _deviceId;
  
  /// Initialize device identity after WebAuthn login
  void setDeviceIdentity(String email, String credentialId) {
    _email = email;
    _credentialId = credentialId;
    _deviceId = _generateDeviceId(email, credentialId);
    
    debugPrint('[DEVICE_IDENTITY] Device initialized');
    debugPrint('[DEVICE_IDENTITY] Email: $email');
    debugPrint('[DEVICE_IDENTITY] Credential ID: ${credentialId.substring(0, 16)}...');
    debugPrint('[DEVICE_IDENTITY] Device ID: $_deviceId');
  }
  
  /// Clear device identity on logout
  void clearDeviceIdentity() {
    debugPrint('[DEVICE_IDENTITY] Clearing device identity');
    _email = null;
    _credentialId = null;
    _deviceId = null;
  }
  
  /// Generate stable device ID from email + credential ID
  String _generateDeviceId(String email, String credentialId) {
    final combined = '$email:$credentialId';
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
  
  /// Check if device identity is set
  bool get isInitialized => _deviceId != null;
  
  /// Get device display name for UI
  String get displayName {
    if (!isInitialized) return 'Unknown Device';
    
    final shortCredId = _credentialId!.substring(0, 8);
    return '$_email ($shortCredId...)';
  }
}
```

#### Step 1.5: Create Device-Scoped Storage Service with Encryption

**File:** `client/lib/services/device_scoped_storage_service.dart`

```dart
import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb_browser.dart';
import 'device_identity_service.dart';
import 'web/encrypted_storage_wrapper.dart';

class DeviceScopedStorageService {
  static final DeviceScopedStorageService instance = DeviceScopedStorageService._();
  DeviceScopedStorageService._();
  
  final DeviceIdentityService _deviceIdentity = DeviceIdentityService.instance;
  final IdbFactory _idbFactory = idbFactoryBrowser;
  final EncryptedStorageWrapper _encryption = EncryptedStorageWrapper();
  
  /// Get device-specific database name
  String getDeviceDatabaseName(String baseName) {
    if (!_deviceIdentity.isInitialized) {
      throw Exception('Device identity not initialized');
    }
    
    final deviceId = _deviceIdentity.deviceId;
    return '${baseName}_$deviceId';
  }
  
  /// Open device-specific database
  Future<Database> openDeviceDatabase(
    String baseName, {
    int version = 1,
    required void Function(VersionChangeEvent) onUpgradeNeeded,
  }) async {
    final dbName = getDeviceDatabaseName(baseName);
    
    debugPrint('[DEVICE_STORAGE] Opening encrypted database: $dbName');
    
    return await _idbFactory.open(
      dbName,
      version: version,
      onUpgradeNeeded: onUpgradeNeeded,
    );
  }
  
  /// Store encrypted data in device-specific database
  Future<void> putEncrypted(
    String baseName,
    String storeName,
    String key,
    dynamic value,
  ) async {
    // 1. Encrypt data
    final envelope = await _encryption.encryptForStorage(value);
    
    // 2. Open device-specific database
    final db = await openDeviceDatabase(
      baseName,
      onUpgradeNeeded: (event) {
        final db = event.database;
        if (!db.objectStoreNames.contains(storeName)) {
          db.createObjectStore(storeName, autoIncrement: false);
        }
      },
    );
    
    // 3. Store encrypted envelope
    final txn = db.transaction(storeName, 'readwrite');
    final store = txn.objectStore(storeName);
    await store.put(envelope, key);
    await txn.completed;
    db.close();
    
    debugPrint('[DEVICE_STORAGE] ✓ Stored encrypted data: $key');
  }
  
  /// Retrieve and decrypt data from device-specific database
  Future<dynamic> getDecrypted(
    String baseName,
    String storeName,
    String key,
  ) async {
    // 1. Open device-specific database
    final db = await openDeviceDatabase(
      baseName,
      onUpgradeNeeded: (event) {
        final db = event.database;
        if (!db.objectStoreNames.contains(storeName)) {
          db.createObjectStore(storeName, autoIncrement: false);
        }
      },
    );
    
    // 2. Load encrypted envelope
    final txn = db.transaction(storeName, 'readonly');
    final store = txn.objectStore(storeName);
    final envelope = await store.getObject(key);
    await txn.completed;
    db.close();
    
    if (envelope == null) {
      debugPrint('[DEVICE_STORAGE] ✗ Key not found: $key');
      return null;
    }
    
    // 3. Decrypt data
    try {
      final decrypted = await _encryption.decryptFromStorage(envelope as Map<String, dynamic>);
      debugPrint('[DEVICE_STORAGE] ✓ Retrieved and decrypted data: $key');
      return decrypted;
    } catch (e) {
      debugPrint('[DEVICE_STORAGE] ✗ Decryption failed for $key: $e');
      rethrow;
    }
  }
  
  /// Delete all databases for current device
  Future<void> deleteAllDeviceDatabases() async {
    if (!_deviceIdentity.isInitialized) {
      debugPrint('[DEVICE_STORAGE] No device identity - skipping cleanup');
      return;
    }
    
    debugPrint('[DEVICE_STORAGE] Deleting all databases for device: ${_deviceIdentity.deviceId}');
    
    final baseDatabases = [
      'peerwaveSignal',
      'peerwaveSignalIdentityKeys',
      'peerwavePreKeys',
      'peerwaveSignedPreKeys',
      'peerwaveSenderKeys',
      'peerwaveSessions',
      'peerwaveDecryptedMessages',
      'peerwaveSentMessages',
      'peerwaveDecryptedGroupItems',
      'peerwaveSentGroupItems',
    ];
    
    int deletedCount = 0;
    int errorCount = 0;
    
    for (final baseName in baseDatabases) {
      final dbName = getDeviceDatabaseName(baseName);
      try {
        await _idbFactory.deleteDatabase(dbName);
        deletedCount++;
        debugPrint('[DEVICE_STORAGE] ✓ Deleted: $dbName');
      } catch (e) {
        errorCount++;
        debugPrint('[DEVICE_STORAGE] ✗ Failed to delete $dbName: $e');
      }
    }
    
    debugPrint('[DEVICE_STORAGE] Cleanup complete: $deletedCount deleted, $errorCount errors');
  }
}
```

---

### Phase 2: Store Refactoring with Encryption (Week 3-4)
    ];
    
    int deletedCount = 0;
    int errorCount = 0;
    
    for (final baseName in baseDatabases) {
      final dbName = getDeviceDatabaseName(baseName);
      try {
        await _idbFactory.deleteDatabase(dbName);
        deletedCount++;
        debugPrint('[DEVICE_STORAGE] ✓ Deleted: $dbName');
      } catch (e) {
        errorCount++;
        debugPrint('[DEVICE_STORAGE] ✗ Failed to delete $dbName: $e');
      }
    }
    
    debugPrint('[DEVICE_STORAGE] Cleanup complete: $deletedCount deleted, $errorCount errors');
  }
  
  /// List all databases for current device
  Future<List<String>> listDeviceDatabases() async {
    if (!_deviceIdentity.isInitialized) {
      return [];
    }
    
    // Note: IDB doesn't provide a native list operation
    // This is a best-effort implementation
    final deviceId = _deviceIdentity.deviceId;
    
    // Try to open known databases and check if they exist
    final knownBases = [
      'peerwaveSignal',
      'peerwaveMessages',
      'peerwaveKeys',
    ];
    
    final existing = <String>[];
    
    for (final base in knownBases) {
      final dbName = getDeviceDatabaseName(base);
      try {
        final db = await _idbFactory.open(dbName, version: 1);
        existing.add(dbName);
        db.close();
      } catch (e) {
        // Database doesn't exist or error
      }
    }
    
    return existing;
  }
}
```

---

### Phase 2: Store Refactoring with Encryption (Week 3-4)

#### Step 2.1: Update Identity Key Store with Encryption

**File:** `client/lib/services/permanent_identity_key_store.dart`

**Pattern to apply:**

```dart
class PermanentIdentityKeyStore extends IdentityKeyStore {
  final String _baseStoreName = 'peerwaveSignalIdentityKeys';
  final DeviceScopedStorageService _storage = DeviceScopedStorageService.instance;
  final EncryptedStorageWrapper _encryption = EncryptedStorageWrapper();
  
  // OLD: Direct IDB access
  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    if (kIsWeb) {
      final db = await idbFactory.open('peerwaveSignalIdentityKeys');
      // ... read from IDB
    }
  }
  
  // NEW: Encrypted device-scoped access
  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    if (kIsWeb) {
      try {
        // Use encrypted storage
        final decrypted = await _storage.getDecrypted(
          _baseStoreName,
          _baseStoreName,
          _identityKey(address),
        );
        
        if (decrypted is String) {
          return IdentityKey.fromBytes(base64Decode(decrypted), 0);
        }
        return null;
      } catch (e) {
        debugPrint('[IDENTITY_KEY_STORE] Error getting identity: $e');
        return null;
      }
    } else {
      // Native: FlutterSecureStorage (unchanged)
      final storage = FlutterSecureStorage();
      var value = await storage.read(key: _identityKey(address));
      if (value != null) {
        return IdentityKey.fromBytes(base64Decode(value), 0);
      }
      return null;
    }
  }
  
  @override
  Future<bool> saveIdentity(SignalProtocolAddress address, IdentityKey identityKey) async {
    if (kIsWeb) {
      try {
        // Use encrypted storage
        await _storage.putEncrypted(
          _baseStoreName,
          _baseStoreName,
          _identityKey(address),
          base64Encode(identityKey.serialize()),
        );
        debugPrint('[IDENTITY_KEY_STORE] ✓ Saved identity (encrypted)');
        return true;
      } catch (e) {
        debugPrint('[IDENTITY_KEY_STORE] ✗ Error saving identity: $e');
        return false;
      }
    } else {
      // Native: FlutterSecureStorage (unchanged)
      final storage = FlutterSecureStorage();
      await storage.write(
        key: _identityKey(address),
        value: base64Encode(identityKey.serialize()),
      );
      return true;
    }
  }
  
  // Apply same pattern to all other methods...
}
```

#### Step 2.2: Refactor All Signal Stores

**Apply this encryption pattern to:**

1. ✅ **`permanent_identity_key_store.dart`**
   - Replace direct IDB access with `_storage.getDecrypted()` / `_storage.putEncrypted()`
   - Keep native FlutterSecureStorage unchanged
   
2. ✅ **`permanent_pre_key_store.dart`**
   - Same pattern for pre-keys
   
3. ✅ **`permanent_signed_pre_key_store.dart`**
   - Same pattern for signed pre-keys
   
4. ✅ **`sender_key_store.dart`**
   - Same pattern + keep rotation logic
   - Encrypt SenderKey metadata (createdAt, messageCount, lastRotation)
   
5. ✅ **`permanent_session_store.dart`**
   - Same pattern for sessions

6. ✅ **Message stores:**
   - `decrypted_messages_store.dart`
   - `sent_messages_store.dart`
   - `decrypted_group_items_store.dart`
   - `sent_group_items_store.dart`

**For each store:**
- Add `EncryptedStorageWrapper` instance
- Replace `idbFactory.open()` with `DeviceScopedStorageService.instance`
- Replace `store.put()` with `_storage.putEncrypted()`
- Replace `store.get()` with `_storage.getDecrypted()`
- Keep try-catch blocks for error handling

---

### Phase 3: Integration with Login/Logout (Week 5)

#### Step 2.1: Update Identity Key Store

**File:** `client/lib/services/permanent_identity_key_store.dart`

```dart
class PermanentIdentityKeyStore extends IdentityKeyStore {
  final String _baseStoreName = 'peerwaveSignalIdentityKeys';
  // Remove hardcoded store name, use device-scoped service
  
  final DeviceScopedStorageService _storage = DeviceScopedStorageService.instance;
  
  // Update all IDB operations to use device-scoped database
  Future<Database> _getDatabase() async {
    return await _storage.openDeviceDatabase(
      _baseStoreName,
      onUpgradeNeeded: (event) {
        Database db = event.database;
        if (!db.objectStoreNames.contains(_baseStoreName)) {
          db.createObjectStore(_baseStoreName, autoIncrement: false);
        }
      }
    );
  }
  
  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    if (kIsWeb) {
      final db = await _getDatabase();
      var txn = db.transaction(_baseStoreName, 'readonly');
      var store = txn.objectStore(_baseStoreName);
      var value = await store.getObject(_identityKey(address));
      await txn.completed;
      db.close();
      
      if (value is String) {
        return IdentityKey.fromBytes(base64Decode(value), 0);
      }
      return null;
    } else {
      // Native implementation unchanged (FlutterSecureStorage already isolated per app)
      final storage = FlutterSecureStorage();
      var value = await storage.read(key: _identityKey(address));
      if (value != null) {
        return IdentityKey.fromBytes(base64Decode(value), 0);
      }
      return null;
    }
  }
  
  // ... update all other methods similarly
}
```

#### Step 2.2: Refactor Pattern for All Stores

**Apply this pattern to:**
- ✅ `permanent_identity_key_store.dart`
- ✅ `permanent_pre_key_store.dart`
- ✅ `permanent_signed_pre_key_store.dart`
- ✅ `sender_key_store.dart`
- ✅ `permanent_session_store.dart`
- ✅ `decrypted_messages_store.dart`
- ✅ `sent_messages_store.dart`
- ✅ `decrypted_group_items_store.dart`
- ✅ `sent_group_items_store.dart`

**Refactoring Steps for Each Store:**

1. Add `DeviceScopedStorageService` reference
2. Replace hardcoded database names with `_storage.getDeviceDatabaseName(baseName)`
3. Use `_storage.openDeviceDatabase()` instead of direct `idbFactory.open()`
4. Keep native (FlutterSecureStorage) implementations unchanged

---

### Phase 3: Integration with Login/Logout (Week 5)

#### Step 3.1: Update Login Flow with Key Derivation

**File:** `client/lib/screens/auth/login_screen.dart`

```dart
class LoginScreen extends StatefulWidget {
  // ... existing code
  
  Future<void> _handleWebAuthnLogin() async {
    try {
      debugPrint('[LOGIN] Starting WebAuthn login');
      
      // 1. WebAuthn authentication (get credential + signature)
      final result = await WebAuthnService.instance.login(emailController.text);
      
      debugPrint('[LOGIN] WebAuthn successful');
      debugPrint('[LOGIN] Email: ${result.email}');
      debugPrint('[LOGIN] Credential ID: ${result.credentialId.substring(0, 16)}...');
      debugPrint('[LOGIN] Signature length: ${result.signature.length} bytes');
      
      // 2. Set device identity (CRITICAL: Device isolation)
      // Get the clientId (UUID) that's already implemented in your codebase
      final clientId = await getClientId(); // Your existing function
      
      DeviceIdentityService.instance.setDeviceIdentity(
        result.email,
        result.credentialId,
        clientId,
      );
      
      final deviceId = DeviceIdentityService.instance.deviceId;
      debugPrint('[LOGIN] ✓ Device identity set: $deviceId');
      
      // 3. Derive encryption key from WebAuthn signature (CRITICAL: Data encryption)
      final encryptionKey = await WebAuthnCryptoService.instance.deriveEncryptionKey(
        result.signature,
      );
      
      debugPrint('[LOGIN] ✓ Encryption key derived (${encryptionKey.length} bytes)');
      
      // 4. Store encryption key in SessionStorage (survives page refresh)
      WebAuthnCryptoService.instance.storeKeyInSession(deviceId, encryptionKey);
      
      debugPrint('[LOGIN] ✓ Encryption key stored in session');
      
      // 5. Verify key is retrievable
      final retrievedKey = WebAuthnCryptoService.instance.getKeyFromSession(deviceId);
      if (retrievedKey == null) {
        throw Exception('Failed to store encryption key');
      }
      
      debugPrint('[LOGIN] ✓ Encryption key verified');
      
      // 6. Initialize Signal service with device info
      await SignalService.instance.setCurrentUserInfo(
        result.userId,
        result.deviceId,
      );
      
      debugPrint('[LOGIN] ✓ Signal service initialized');
      
      // 7. Continue normal login flow
      await _initializeServices();
      
      debugPrint('[LOGIN] ✓ Login complete');
      
      Navigator.pushReplacementNamed(context, '/home');
    } catch (e, stackTrace) {
      debugPrint('[LOGIN] ✗ Login failed: $e');
      debugPrint('[LOGIN] Stack trace: $stackTrace');
      _showError('Login failed: $e');
    }
  }
}
```

#### Step 3.2: Update Logout Flow with Key Cleanup

**File:** `client/lib/services/auth/auth_service.dart` or wherever logout is handled

```dart
class AuthService {
  Future<void> logout() async {
    try {
      debugPrint('[LOGOUT] Starting logout process');
      
      if (!DeviceIdentityService.instance.isInitialized) {
        debugPrint('[LOGOUT] No device identity - skipping cleanup');
        return;
      }
      
      final deviceId = DeviceIdentityService.instance.deviceId;
      
      // 1. Clear encryption key from SessionStorage (CRITICAL: Security)
      WebAuthnCryptoService.instance.clearKeyFromSession(deviceId);
      debugPrint('[LOGOUT] ✓ Encryption key cleared');
      
      // 2. Delete all device-specific databases (optional - data stays encrypted)
      // NOTE: Can skip this if you want to keep encrypted data for faster re-login
      await DeviceScopedStorageService.instance.deleteAllDeviceDatabases();
      debugPrint('[LOGOUT] ✓ Device databases deleted');
      
      // 3. Clear device identity
      DeviceIdentityService.instance.clearDeviceIdentity();
      debugPrint('[LOGOUT] ✓ Device identity cleared');
      
      // 4. Clear session
      await SessionService.instance.clearSession();
      debugPrint('[LOGOUT] ✓ Session cleared');
      
      // 5. Clear Signal service
      SignalService.instance.reset();
      debugPrint('[LOGOUT] ✓ Signal service reset');
      
      debugPrint('[LOGOUT] ✓ Logout complete');
    } catch (e, stackTrace) {
      debugPrint('[LOGOUT] ✗ Error during logout: $e');
      debugPrint('[LOGOUT] Stack trace: $stackTrace');
      // Continue logout even if cleanup fails
    }
  }
}
```

#### Step 3.3: Handle Page Refresh (SessionStorage Persistence)

**Pattern:**

```dart
// On page load / app initialization
Future<void> initializeApp() async {
  // Check if device identity exists
  if (DeviceIdentityService.instance.isInitialized) {
    final deviceId = DeviceIdentityService.instance.deviceId;
    
    // Check if encryption key still exists in SessionStorage
    final key = WebAuthnCryptoService.instance.getKeyFromSession(deviceId);
    
    if (key != null) {
      debugPrint('[INIT] ✓ Session restored from SessionStorage');
      // User can continue - no re-authentication needed
      return;
    } else {
      debugPrint('[INIT] ✗ Encryption key lost - need re-authentication');
      // Clear device identity and force re-login
      DeviceIdentityService.instance.clearDeviceIdentity();
      // Redirect to login
    }
  } else {
    debugPrint('[INIT] No device identity - showing login');
    // Show login screen
  }
}
```

**Key Points:**
- ✅ SessionStorage survives page refresh within same tab/window
- ✅ SessionStorage is cleared when browser tab/window closes
- ✅ Each browser tab gets its own SessionStorage (isolation)
- ⚠️ Closing tab = lost key = need re-authentication

---

### Phase 4: Testing & Validation (Week 5)

---

### Phase 4: Testing & Validation (Week 5)

#### Test 4.1: Device Isolation Test

```dart
testWidgets('Different users get isolated databases', (tester) async {
  // User 1 login (Device A)
  DeviceIdentityService.instance.setDeviceIdentity(
    'user1@example.com',
    'cred1',
    'client-uuid-1',
  );
  
  final signature1 = Uint8List.fromList(List.generate(64, (i) => i));
  final key1 = await WebAuthnCryptoService.instance.deriveEncryptionKey(signature1);
  WebAuthnCryptoService.instance.storeKeyInSession(
    DeviceIdentityService.instance.deviceId,
    key1,
  );
  
  // Store some data
  await DeviceScopedStorageService.instance.putEncrypted(
    'testDB',
    'testStore',
    'message',
    {'text': 'User 1 secret'},
  );
  
  final device1Id = DeviceIdentityService.instance.deviceId;
  
  // Logout
  WebAuthnCryptoService.instance.clearKeyFromSession(device1Id);
  DeviceIdentityService.instance.clearDeviceIdentity();
  
  // User 2 login (Device B - different user, different clientId)
  DeviceIdentityService.instance.setDeviceIdentity(
    'user2@example.com',
    'cred2',
    'client-uuid-2',
  );
  
  final signature2 = Uint8List.fromList(List.generate(64, (i) => i + 1));
  final key2 = await WebAuthnCryptoService.instance.deriveEncryptionKey(signature2);
  WebAuthnCryptoService.instance.storeKeyInSession(
    DeviceIdentityService.instance.deviceId,
    key2,
  );
  
  // Try to read user 1's data (should be null - different database)
  final user2Data = await DeviceScopedStorageService.instance.getDecrypted(
    'testDB',
    'testStore',
    'message',
  );
  
  expect(user2Data, isNull); // User 2 cannot see User 1's data
  
  // Cleanup
  await DeviceScopedStorageService.instance.deleteAllDeviceDatabases();
});
```

#### Test 4.1b: Same User, Same Authenticator, Different Browsers

```dart
testWidgets('Same user with same authenticator on different browsers get isolated storage', (tester) async {
  // User on Browser A (Laptop Chrome)
  DeviceIdentityService.instance.setDeviceIdentity(
    'user@example.com',
    'yubikey-cred-123', // Same YubiKey
    'client-uuid-chrome-laptop',
  );
  
  final deviceA = DeviceIdentityService.instance.deviceId;
  
  // Logout
  DeviceIdentityService.instance.clearDeviceIdentity();
  
  // Same user on Browser B (Laptop Firefox) - Same authenticator but different browser
  DeviceIdentityService.instance.setDeviceIdentity(
    'user@example.com',
    'yubikey-cred-123', // Same YubiKey
    'client-uuid-firefox-laptop',
  );
  
  final deviceB = DeviceIdentityService.instance.deviceId;
  
  // Device IDs should be different (different clientId)
  expect(deviceA, isNot(equals(deviceB)));
  
  debugPrint('[TEST] Same authenticator, different browsers → different deviceIds ✓');
});
```

#### Test 4.2: Encryption Key Isolation Test

```dart
test('Different devices produce different encryption keys', () async {
  // Device 1
  final signature1 = Uint8List.fromList(List.generate(64, (i) => i));
  final key1 = await WebAuthnCryptoService.instance.deriveEncryptionKey(signature1);
  
  // Device 2 (different signature)
  final signature2 = Uint8List.fromList(List.generate(64, (i) => i + 1));
  final key2 = await WebAuthnCryptoService.instance.deriveEncryptionKey(signature2);
  
  // Keys should be different
  expect(key1, isNot(equals(key2)));
});
```

#### Test 4.3: Encryption/Decryption Roundtrip Test

```dart
test('Encrypt and decrypt data successfully', () async {
  DeviceIdentityService.instance.setDeviceIdentity(
    'test@example.com',
    'cred123',
    'client-uuid-test',
  );
  
  final signature = Uint8List.fromList(List.generate(64, (i) => i));
  final key = await WebAuthnCryptoService.instance.deriveEncryptionKey(signature);
  WebAuthnCryptoService.instance.storeKeyInSession(
    DeviceIdentityService.instance.deviceId,
    key,
  );
  
  final testData = {
    'message': 'Hello, encrypted world!',
    'timestamp': DateTime.now().toIso8601String(),
    'count': 42,
  };
  
  await DeviceScopedStorageService.instance.putEncrypted(
    'testDB',
    'testStore',
    'testKey',
    testData,
  );
  
  final decrypted = await DeviceScopedStorageService.instance.getDecrypted(
    'testDB',
    'testStore',
    'testKey',
  );
  
  expect(decrypted, equals(testData));
  
  // Cleanup
  await DeviceScopedStorageService.instance.deleteAllDeviceDatabases();
  DeviceIdentityService.instance.clearDeviceIdentity();
});
```

#### Test 4.4: Key Loss Scenario Test

```dart
test('Cannot decrypt data without encryption key', () async {
  DeviceIdentityService.instance.setDeviceIdentity(
    'test@example.com',
    'cred123',
    'client-uuid-test',
  );
  
  final signature = Uint8List.fromList(List.generate(64, (i) => i));
  final key = await WebAuthnCryptoService.instance.deriveEncryptionKey(signature);
  WebAuthnCryptoService.instance.storeKeyInSession(
    DeviceIdentityService.instance.deviceId,
    key,
  );
  
  // Store encrypted data
  await DeviceScopedStorageService.instance.putEncrypted(
    'testDB',
    'testStore',
    'testKey',
    {'secret': 'data'},
  );
  
  // Simulate key loss (logout)
  final deviceId = DeviceIdentityService.instance.deviceId;
  WebAuthnCryptoService.instance.clearKeyFromSession(deviceId);
  
  // Try to read (should throw exception)
  expect(
    () => DeviceScopedStorageService.instance.getDecrypted(
      'testDB',
      'testStore',
      'testKey',
    ),
    throwsException,
  );
  
  // Cleanup
  await DeviceScopedStorageService.instance.deleteAllDeviceDatabases();
  DeviceIdentityService.instance.clearDeviceIdentity();
});
```

#### Test 4.5: SessionStorage Persistence Test

```dart
test('Encryption key persists in SessionStorage', () async {
  DeviceIdentityService.instance.setDeviceIdentity(
    'test@example.com',
    'cred123',
    'client-uuid-test',
  );
  
  final signature = Uint8List.fromList(List.generate(64, (i) => i));
  final key = await WebAuthnCryptoService.instance.deriveEncryptionKey(signature);
  
  final deviceId = DeviceIdentityService.instance.deviceId;
  
  // Store key
  WebAuthnCryptoService.instance.storeKeyInSession(deviceId, key);
  
  // Retrieve key
  final retrievedKey = WebAuthnCryptoService.instance.getKeyFromSession(deviceId);
  
  expect(retrievedKey, isNotNull);
  expect(retrievedKey, equals(key));
  
  // Clear key
  WebAuthnCryptoService.instance.clearKeyFromSession(deviceId);
  
  // Verify cleared
  final clearedKey = WebAuthnCryptoService.instance.getKeyFromSession(deviceId);
  expect(clearedKey, isNull);
});
```

#### Test 4.6: Multi-Device Test (Manual)
    }
  }
}
```

#### Step 3.3: Add Device Management UI (Optional but Recommended)

**File:** `client/lib/screens/settings/device_management_screen.dart`

```dart
class DeviceManagementScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final deviceIdentity = DeviceIdentityService.instance;
    
    if (!deviceIdentity.isInitialized) {
      return Scaffold(
        appBar: AppBar(title: Text('Device Management')),
        body: Center(child: Text('Not logged in')),
      );
    }
    
    return Scaffold(
      appBar: AppBar(title: Text('Device Management')),
      body: ListView(
        padding: EdgeInsets.all(16),
        children: [
          // Current Device Info
          Card(
            child: ListTile(
              leading: Icon(Icons.devices),
              title: Text('Current Device'),
              subtitle: Text(deviceIdentity.displayName),
              trailing: Chip(
                label: Text('Active'),
                backgroundColor: Colors.green,
              ),
            ),
          ),
          
          SizedBox(height: 16),
          
          // Device ID (for debugging)
          Card(
            child: ListTile(
              leading: Icon(Icons.fingerprint),
              title: Text('Device ID'),
              subtitle: SelectableText(deviceIdentity.deviceId),
            ),
          ),
          
          SizedBox(height: 16),
          
          // Email
          Card(
            child: ListTile(
              leading: Icon(Icons.email),
              title: Text('Email'),
              subtitle: Text(deviceIdentity.email),
            ),
          ),
          
          SizedBox(height: 16),
          
          // WebAuthn Credential
          Card(
            child: ListTile(
              leading: Icon(Icons.security),
              title: Text('WebAuthn Credential'),
              subtitle: Text(
                '${deviceIdentity.credentialId.substring(0, 32)}...',
              ),
            ),
          ),
          
          SizedBox(height: 32),
          
          // Clear Device Data Button
          ElevatedButton.icon(
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('Clear Device Data?'),
                  content: Text(
                    'This will delete all local data for this device. '
                    'Messages on the server will not be affected. '
                    'You can re-download them after logging in again.'
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text('Cancel'),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text('Clear Data'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                      ),
                    ),
                  ],
                ),
              );
              
              if (confirmed == true) {
                await DeviceScopedStorageService.instance.deleteAllDeviceDatabases();
                
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Device data cleared')),
                );
              }
            },
            icon: Icon(Icons.delete_forever),
            label: Text('Clear Device Data'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
          ),
        ],
      ),
    );
  }
}
```

---

## 🧪 Testing Strategy

### Test 1: Device Isolation

```dart
test('Different devices have isolated storage', () async {
  // Setup Device A
  DeviceIdentityService.instance.setDeviceIdentity(
    'alice@example.com',
    'credential_id_1',
  );
  
  final deviceA_Id = DeviceIdentityService.instance.deviceId;
  final deviceA_DbName = DeviceScopedStorageService.instance.getDeviceDatabaseName('test');
  
  // Store data for Device A
  final dbA = await openDatabase(deviceA_DbName);
  await storeData(dbA, 'key1', 'value_A');
  dbA.close();
  
  // Clear and setup Device B (same email, different credential)
  DeviceIdentityService.instance.clearDeviceIdentity();
  DeviceIdentityService.instance.setDeviceIdentity(
    'alice@example.com',
    'credential_id_2',
  );
  
  final deviceB_Id = DeviceIdentityService.instance.deviceId;
  final deviceB_DbName = DeviceScopedStorageService.instance.getDeviceDatabaseName('test');
  
  // Verify different device IDs
  expect(deviceA_Id, isNot(equals(deviceB_Id)));
  expect(deviceA_DbName, isNot(equals(deviceB_DbName)));
  
  // Verify Device B cannot access Device A's data
  final dbB = await openDatabase(deviceB_DbName);
  final value = await getData(dbB, 'key1');
  expect(value, isNull); // Device B's database is empty
  dbB.close();
});
```

### Test 2: User Isolation

```dart
test('Different users have isolated storage', () async {
  // User A
  DeviceIdentityService.instance.setDeviceIdentity(
    'alice@example.com',
    'credential_1',
  );
  final userA_DeviceId = DeviceIdentityService.instance.deviceId;
  
  // User B
  DeviceIdentityService.instance.clearDeviceIdentity();
  DeviceIdentityService.instance.setDeviceIdentity(
    'bob@example.com',
    'credential_1', // Same credential ID, different email
  );
  final userB_DeviceId = DeviceIdentityService.instance.deviceId;
  
  // Verify different device IDs
  expect(userA_DeviceId, isNot(equals(userB_DeviceId)));
});
```

### Test 3: Cleanup

```dart
test('Logout clears all device databases', () async {
  // Setup and create data
  DeviceIdentityService.instance.setDeviceIdentity(
    'test@example.com',
    'credential_1',
  );
  
  // Create some databases
  await DeviceScopedStorageService.instance.openDeviceDatabase(
    'peerwaveSignal',
    onUpgradeNeeded: (event) {},
  );
  
  // List databases (should have at least 1)
  var databases = await DeviceScopedStorageService.instance.listDeviceDatabases();
  expect(databases, isNotEmpty);
  
  // Logout (cleanup)
  await DeviceScopedStorageService.instance.deleteAllDeviceDatabases();
  DeviceIdentityService.instance.clearDeviceIdentity();
  
  // Verify cleanup
  // Note: Can't easily verify in test, but databases are deleted
});
```

---

## 📊 Migration Strategy (Not Needed, but for Reference)

Since you're still in development, you can simply:

1. **Delete old data:**
   ```dart
   // One-time cleanup of old non-device-scoped databases
   Future<void> cleanupLegacyDatabases() async {
     final legacy = [
       'peerwaveSignal',
       'peerwaveMessages',
       // ... all old names
     ];
     
     for (final name in legacy) {
       try {
         await idbFactory.deleteDatabase(name);
       } catch (e) {
         // Ignore errors
       }
     }
   }
   ```

2. **Force re-login:**
   - Users will need to log in again
   - Fresh device identity will be created
   - New device-scoped databases will be generated

---

## 🎯 Success Criteria

### Functional
- ✅ Each device gets isolated IndexedDB
- ✅ Different users on same browser are isolated
- ✅ Same user with different WebAuthn keys gets different devices
- ✅ Logout clears all device data
- ✅ Re-login creates fresh device storage

### Security
- ✅ No cross-device data access
- ✅ No cross-user data access
- ✅ Lost key = lost local data (acceptable)

### Performance
- ✅ Zero overhead (native IndexedDB speed)
- ✅ No encryption/decryption
- ✅ No additional CPU usage

---

## 📝 Files to Create/Modify

### New Files
- ✅ `client/lib/services/device_identity_service.dart`
- ✅ `client/lib/services/device_scoped_storage_service.dart`
- ✅ `client/lib/screens/settings/device_management_screen.dart` (optional)

### Files to Modify
- ✅ `client/lib/services/permanent_identity_key_store.dart`
- ✅ `client/lib/services/permanent_pre_key_store.dart`
- ✅ `client/lib/services/permanent_signed_pre_key_store.dart`
- ✅ `client/lib/services/sender_key_store.dart`
- ✅ `client/lib/services/permanent_session_store.dart`
- ✅ `client/lib/services/decrypted_messages_store.dart`
- ✅ `client/lib/services/sent_messages_store.dart`
- ✅ `client/lib/services/decrypted_group_items_store.dart`
- ✅ `client/lib/services/sent_group_items_store.dart`
- ✅ `client/lib/screens/auth/login_screen.dart`
- ✅ `client/lib/services/auth/auth_service.dart` (logout)

---

## � Migration Strategy

**Good News:** Since you're still in development, no migration needed!

Simply:
1. Delete old non-device-scoped databases (one-time cleanup)
2. Force users to re-login
3. Fresh encrypted device-scoped databases will be created

**One-time cleanup code:**
```dart
Future<void> cleanupLegacyDatabases() async {
  final legacy = [
    'peerwaveSignal',
    'peerwaveSignalIdentityKeys',
    'peerwavePreKeys',
    'peerwaveSignedPreKeys',
    'peerwaveSenderKeys',
    'peerwaveSessions',
    'peerwaveDecryptedMessages',
    'peerwaveSentMessages',
    'peerwaveDecryptedGroupItems',
    'peerwaveSentGroupItems',
  ];
  
  for (final name in legacy) {
    try {
      await idbFactoryBrowser.deleteDatabase(name);
      debugPrint('[CLEANUP] Deleted legacy database: $name');
    } catch (e) {
      debugPrint('[CLEANUP] Failed to delete $name: $e');
    }
  }
}
```

Run once on app startup, then remove the code.

---

## 🎉 Benefits of Hybrid Approach (Device Isolation + Encryption)

### vs. Simple Device Isolation (Original Plan)
- 🔒 **Stronger security:** Data encrypted at rest
- 🔐 **WebAuthn-backed encryption:** Keys derived from authenticator
- 🛡️ **Defense in depth:** Physical + cryptographic isolation
- ⚖️ **Acceptable trade-off:** +1-2 weeks development, minimal performance impact

### vs. Full WebAuthn Encryption Plan (14 Weeks)
- ⏱️ **5 weeks** instead of 14 weeks (64% faster)
- 🚀 **Minimal overhead:** Key cached in SessionStorage
- 🔧 **Simpler:** No multi-device key sync complexity
- 💰 **Lower cost:** Fewer development hours
- 🐛 **Fewer bugs:** Less complex crypto logic

### Security Layers
```
┌──────────────────────────────────────────┐
│ Layer 1: Device Isolation               │
│ → Separate IndexedDB per device          │
│ → deviceId = hash(email + credential + clientId) │
│ → clientId ensures uniqueness per browser/device │
└──────────────────────────────────────────┘
            ↓
┌──────────────────────────────────────────┐
│ Layer 2: WebAuthn Encryption            │
│ → Key = HKDF(WebAuthn signature)         │
│ → Unique key per device/authenticator    │
└──────────────────────────────────────────┘
            ↓
┌──────────────────────────────────────────┐
│ Layer 3: Data Encryption                │
│ → AES-GCM-256 with random IV             │
│ → Envelope: {version, deviceId, iv, data}│
└──────────────────────────────────────────┘
            ↓
┌──────────────────────────────────────────┐
│ Result: Triple-Protected Data           │
│ → Physical isolation (separate databases)│
│ → Cryptographic isolation (unique keys)  │
│ → Encrypted storage (AES-GCM)            │
└──────────────────────────────────────────┘
```

### User Experience
- ✅ **Fast:** Encryption is hardware-accelerated
- ✅ **Seamless:** Page refresh doesn't require re-authentication
- ✅ **Secure:** Lost key = secure data deletion
- ✅ **Multi-device:** Server handles sync (Signal encrypted)

### Trade-offs (All Acceptable)
- ⚠️ **SessionStorage cleared on browser close:** User must re-authenticate
  - **Acceptable:** This is standard web security behavior
- ⚠️ **Lost WebAuthn key = lost local data:** Cannot decrypt
  - **Acceptable:** Server has Signal-encrypted backup, user gets fresh sync
- ⚠️ **+10ms encryption overhead per operation:** Minimal impact
  - **Acceptable:** Negligible for user experience
- ⚠️ **+1-2 weeks development time:** vs. simple isolation
  - **Acceptable:** Worth it for strong security

---

## 🔄 How Multi-Device Works

```
┌─────────────────────────────────────────────────────────┐
│ Laptop (Device A)                                       │
├─────────────────────────────────────────────────────────┤
│ 1. User sends message                                   │
│ 2. Encrypt with Signal protocol                         │
│ 3. Send to server                                       │
│ 4. Store in local IndexedDB (device-specific, encrypted)│
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ Server                                                  │
├─────────────────────────────────────────────────────────┤
│ - Stores Signal-encrypted message                       │
│ - Broadcasts to all user's devices                      │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ Phone (Device B)                                        │
├─────────────────────────────────────────────────────────┤
│ 1. Receives encrypted message from server              │
│ 2. Decrypts with Signal protocol                        │
│ 3. Stores in local IndexedDB (device-specific, encrypted)│
│ 4. Displays in UI                                       │
└─────────────────────────────────────────────────────────┘

► Each device has its own IndexedDB copy (encrypted with unique key)
► No device-to-device sharing
► Server acts as sync hub (Signal encrypted)
```

---

## ✅ Ready to Implement!

This hybrid approach provides:
- ✅ **Best of both worlds:** Device isolation + Encryption
- ✅ **Three-layer security:** Physical + Cryptographic + Encrypted
- ✅ **5-week timeline:** Faster than full encryption (14 weeks)
- ✅ **Minimal overhead:** Hardware-accelerated crypto
- ✅ **No migration needed:** Fresh start (still in development)
- ✅ **Acceptable trade-offs:** Lost key = lost local data (server has backup)

**Next Steps:**
1. Review and approve this plan
2. Start with Phase 1 (Crypto Infrastructure)
3. Test thoroughly at each phase
4. Deploy with confidence!

---

## 📚 Additional Resources

### Key Concepts
- **Device Identity:** `hash(email + WebAuthn credential ID + clientId UUID)`
  - Ensures unique storage even when same authenticator is used on different browsers/devices
- **Encryption Key:** `HKDF(WebAuthn signature, salt, info)`
- **SessionStorage:** Browser storage cleared on tab close, survives page refresh
- **Envelope:** Metadata wrapper around encrypted data
- **HKDF:** HMAC-based Key Derivation Function (RFC 5869)
- **AES-GCM:** Advanced Encryption Standard - Galois/Counter Mode (authenticated encryption)

### Security Principles
1. **Defense in Depth:** Multiple layers of protection
2. **Key Derivation:** Cryptographically secure (HKDF with SHA-256)
3. **Random IVs:** Each encryption uses unique initialization vector (12 bytes for GCM)
4. **Device Ownership:** Envelope includes deviceId verification
5. **Acceptable Data Loss:** Lost key = fresh start (server backup exists)
6. **No Key Sharing:** Each device has unique encryption key

### Web Crypto API
- **HKDF:** HMAC-based Key Derivation Function (RFC 5869)
- **AES-GCM:** Advanced Encryption Standard - Galois/Counter Mode
- **Hardware Acceleration:** Native browser crypto (fast)
- **Fallback:** Pure Dart implementation for native platforms
- **Browser Support:** All modern browsers (Chrome, Firefox, Safari, Edge)

### WebAuthn Integration
- **Signature Extraction:** `credential.response.signature`
- **Credential ID:** `base64Encode(credential.rawId)`
- **Consistent Signatures:** Same authenticator → same key derivation
- **Per-Device Keys:** Different authenticators → different keys

---

## 🔍 Debugging Checklist

If encryption fails:
1. **Check device identity:** `DeviceIdentityService.instance.isInitialized`
2. **Check encryption key:** `WebAuthnCryptoService.instance.getKeyFromSession(deviceId)`
3. **Check WebAuthn signature:** Verify signature is extracted on login (should be ~64 bytes)
4. **Check SessionStorage:** Look in browser DevTools → Application → Session Storage
5. **Check envelope format:** Verify `{version, deviceId, iv, data}` structure
6. **Check logs:** Look for `[WEBAUTHN_CRYPTO]`, `[DEVICE_STORAGE]`, `[DEVICE_IDENTITY]` debug prints
7. **Check Web Crypto API:** Verify `window.crypto.subtle` is available (HTTPS required)
8. **Check key length:** Encryption key should be 32 bytes (256 bits)
9. **Check IV length:** IV should be 12 bytes for AES-GCM
10. **Test with simple data first:** Before testing with complex Signal data

### Common Issues
- **"No encryption key available":** User logged out or SessionStorage cleared → Re-authenticate
- **"Data belongs to different device":** Trying to decrypt with wrong device key → Expected behavior
- **"Decryption failed":** Wrong key or corrupted data → Check deviceId matches
- **"Web Crypto API not available":** Not using HTTPS → Requires secure context
- **"Device identity not initialized":** Login flow didn't set identity → Check login code

---

## 🎊 Conclusion

This implementation plan provides a **secure, performant, and maintainable solution** for device-scoped encrypted storage in PeerWave's web client. By combining device isolation with WebAuthn-backed encryption, you get the best of both approaches with minimal complexity and overhead.

### Summary

**What You Get:**
- 🔒 Device-specific databases (physical isolation)
- 🔐 WebAuthn-derived encryption (cryptographic security)
- 🚀 Hardware-accelerated crypto (Web Crypto API)
- 💾 SessionStorage key persistence (survives page refresh)
- 🛡️ Three-layer security architecture
- 📱 Multi-device support via server sync

**Total Timeline: 5 Weeks**
- Week 1-2: Crypto infrastructure (WebAuthnCryptoService, EncryptedStorageWrapper)
- Week 3-4: Store refactoring (9 stores with encryption)
- Week 5: Integration & testing (login/logout flows, comprehensive tests)

**Total Files:**
- 3 new files (WebAuthnCryptoService, EncryptedStorageWrapper, DeviceIdentityService)
- 13 modified files (stores, login, logout, pubspec.yaml)
- 1 updated file (DeviceScopedStorageService with encryption)

**Security Level:**
- ✅ Physical isolation (separate databases)
- ✅ Cryptographic isolation (unique keys per device)
- ✅ Data encryption (AES-GCM-256 at rest)
- ✅ Signal protocol (end-to-end encryption in transit)

**Let's build it! 🚀**
