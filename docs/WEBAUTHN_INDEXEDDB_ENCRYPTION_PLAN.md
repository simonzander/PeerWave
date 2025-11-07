# WebAuthn-Based IndexedDB Encryption - Implementation Plan

## Problem Statement

**Current Issues:**
1. IndexedDB stores decrypted data for all users in the same browser
2. When user switches accounts, previous user's data is still accessible
3. No encryption at rest for sensitive Signal protocol keys and messages
4. Data isolation between users is only logical, not cryptographic

**Security Risk:**
- User A logs in → decrypted messages stored in IndexedDB
- User A logs out
- User B logs in on same browser → can potentially access User A's data

---

## Solution: WebAuthn-Based Encryption

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│ WebAuthn Encryption Flow                                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│ 1. LOGIN (WebAuthn Authentication)                              │
│    ↓                                                             │
│    WebAuthn Challenge → User biometric/PIN                      │
│    ↓                                                             │
│    Signature Generated (tied to user + device + clientid)        │
│    ↓                                                             │
│    Derive Encryption Key (HKDF from signature)                  │
│    ↓                                                             │
│    Store derived key in SessionStorage (temporary)              │
│                                                                  │
│ 2. WRITE TO INDEXEDDB                                           │
│    ↓                                                             │
│    Plaintext Data → AES-GCM Encrypt (with derived key)          │
│    ↓                                                             │
│    Store {userEmail, deviceId, encryptedData, iv, tag}          │
│                                                                  │
│ 3. READ FROM INDEXEDDB                                          │
│    ↓                                                             │
│    Load {userEmail, deviceId, encryptedData, iv, tag}           │
│    ↓                                                             │
│    Verify userEmail matches current session                     │
│    ↓                                                             │
│    AES-GCM Decrypt (with derived key from SessionStorage)       │
│    ↓                                                             │
│    Return Plaintext Data                                        │
│                                                                  │
│ 4. LOGOUT / USER SWITCH                                         │
│    ↓                                                             │
│    Clear SessionStorage (key destroyed)                         │
│    ↓                                                             │
│    Previous user's encrypted data remains but is unreadable     │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Implementation Phases

### **Phase 1: Core Encryption Infrastructure** (Week 1-2)

#### 1.1 WebAuthn Key Derivation Service
**File:** `client/lib/services/web/webauthn_crypto_service.dart`

```dart
class WebAuthnCryptoService {
  static CryptoKey? _sessionEncryptionKey;
  static String? _currentUserEmail;
  static String? _currentDeviceId;
  
  /// Derive encryption key from WebAuthn signature
  Future<CryptoKey> deriveEncryptionKey(Uint8List signature) async {
    // Use HKDF (HMAC-based Key Derivation Function)
    final salt = utf8.encode('peerwave-indexeddb-encryption-v1');
    final info = utf8.encode('aes-gcm-256');
    
    // Import signature as key material
    final keyMaterial = await crypto.subtle.importKey(
      'raw',
      signature,
      {'name': 'HKDF'},
      false,
      ['deriveKey']
    );
    
    // Derive AES-GCM key
    final derivedKey = await crypto.subtle.deriveKey(
      {
        'name': 'HKDF',
        'salt': Uint8List.fromList(salt),
        'info': Uint8List.fromList(info),
        'hash': 'SHA-256'
      },
      keyMaterial,
      {'name': 'AES-GCM', 'length': 256},
      false,
      ['encrypt', 'decrypt']
    );
    
    return derivedKey;
  }
  
  /// Store key in session (memory only)
  void setSessionKey(CryptoKey key, String email, String deviceId) {
    _sessionEncryptionKey = key;
    _currentUserEmail = email;
    _currentDeviceId = deviceId;
  }
  
  /// Clear key on logout
  void clearSession() {
    _sessionEncryptionKey = null;
    _currentUserEmail = null;
    _currentDeviceId = null;
  }
}
```

#### 1.2 Encrypted IndexedDB Wrapper
**File:** `client/lib/services/web/encrypted_idb_store.dart`

```dart
class EncryptedIndexedDBStore {
  final String storeName;
  final WebAuthnCryptoService _crypto;
  
  /// Encrypt data before storing
  Future<void> putEncrypted(String key, dynamic value) async {
    final encryptionKey = _crypto.sessionEncryptionKey;
    if (encryptionKey == null) {
      throw Exception('No encryption key available - user not authenticated');
    }
    
    // Serialize value
    final plaintext = jsonEncode(value);
    final plaintextBytes = utf8.encode(plaintext);
    
    // Generate random IV
    final iv = crypto.getRandomValues(Uint8List(12));
    
    // Encrypt with AES-GCM
    final encrypted = await crypto.subtle.encrypt(
      {'name': 'AES-GCM', 'iv': iv},
      encryptionKey,
      plaintextBytes
    );
    
    // Store metadata + encrypted data
    final envelope = {
      'userEmail': _crypto.currentUserEmail,
      'deviceId': _crypto.currentDeviceId,
      'iv': base64Encode(iv),
      'data': base64Encode(encrypted),
      'version': 1,
      'timestamp': DateTime.now().toIso8601String(),
    };
    
    // Store in IndexedDB
    await _putRaw(key, envelope);
  }
  
  /// Decrypt data when reading
  Future<dynamic> getDecrypted(String key) async {
    final encryptionKey = _crypto.sessionEncryptionKey;
    if (encryptionKey == null) {
      throw Exception('No encryption key available - user not authenticated');
    }
    
    // Load encrypted envelope
    final envelope = await _getRaw(key);
    if (envelope == null) return null;
    
    // Verify user ownership
    if (envelope['userEmail'] != _crypto.currentUserEmail) {
      throw Exception('Access denied: Data belongs to different user');
    }
    
    // Decrypt
    final iv = base64Decode(envelope['iv']);
    final encryptedData = base64Decode(envelope['data']);
    
    final decrypted = await crypto.subtle.decrypt(
      {'name': 'AES-GCM', 'iv': iv},
      encryptionKey,
      encryptedData
    );
    
    // Deserialize
    final plaintext = utf8.decode(decrypted);
    return jsonDecode(plaintext);
  }
}
```

---

### **Phase 2: Integration with Signal Stores** (Week 3-4)

#### 2.1 Migrate Signal Key Stores
**Files to modify:**
- `permanent_identity_key_store.dart`
- `permanent_pre_key_store.dart`
- `permanent_signed_pre_key_store.dart`
- `sender_key_store.dart`
- `permanent_session_store.dart`

**Strategy:**
```dart
// Before (current):
await idb.put(serializedKey, keyId);

// After (encrypted):
await encryptedIDB.putEncrypted(keyId, serializedKey);
```

#### 2.2 Migrate Message Stores
**Files:**
- `decrypted_messages_store.dart`
- `sent_messages_store.dart`
- `decrypted_group_items_store.dart`

---

### **Phase 3: WebAuthn Integration** (Week 5)

#### 3.1 Login Flow Enhancement
**File:** `client/lib/screens/auth/login_screen.dart`

```dart
// After successful WebAuthn authentication:
final signature = webAuthnResponse.signature;

// Derive encryption key
final cryptoService = WebAuthnCryptoService();
final encryptionKey = await cryptoService.deriveEncryptionKey(signature);

// Store in session
cryptoService.setSessionKey(
  encryptionKey,
  userEmail,
  deviceId.toString()
);

// Initialize encrypted stores
await initializeEncryptedStores(cryptoService);
```

#### 3.2 Logout Flow Enhancement
```dart
// On logout:
final cryptoService = WebAuthnCryptoService();
cryptoService.clearSession();

// Key destroyed → previous data unreadable
```

---

### **Phase 4: Data Migration & User Switching** (Week 6)

#### 4.1 Automatic Data Cleanup
```dart
class IndexedDBCleanupService {
  /// Delete all data when user email changes
  Future<void> cleanupOnUserSwitch(String newEmail) async {
    final previousEmail = await getStoredUserEmail();
    
    if (previousEmail != null && previousEmail != newEmail) {
      debugPrint('[CLEANUP] User switched from $previousEmail to $newEmail');
      debugPrint('[CLEANUP] Deleting all IndexedDB data...');
      
      await deleteAllStores([
        'peerwaveSignal',
        'peerwaveSignalIdentityKeys',
        'peerwavePreKeys',
        'peerwaveSignedPreKeys',
        'peerwaveSenderKeys',
        'peerwaveSessions',
        'peerwaveDecryptedMessages',
        'peerwaveSentMessages',
        // ... all other stores
      ]);
      
      debugPrint('[CLEANUP] ✓ Cleanup complete');
    }
    
    await storeUserEmail(newEmail);
  }
}
```

#### 4.2 Migration from Unencrypted to Encrypted
```dart
class DataMigrationService {
  /// One-time migration of existing unencrypted data
  Future<void> migrateToEncrypted() async {
    final version = await getMigrationVersion();
    
    if (version < 2) { // Version 2 = encrypted storage
      debugPrint('[MIGRATION] Migrating to encrypted storage...');
      
      // 1. Load all unencrypted data
      final identityKeys = await loadLegacyIdentityKeys();
      final preKeys = await loadLegacyPreKeys();
      // ... load all stores
      
      // 2. Re-encrypt with new system
      for (final key in identityKeys) {
        await encryptedStore.putEncrypted(key.id, key.data);
      }
      // ... migrate all stores
      
      // 3. Delete legacy data
      await deleteLegacyStores();
      
      // 4. Mark migration complete
      await setMigrationVersion(2);
      
      debugPrint('[MIGRATION] ✓ Migration complete');
    }
  }
}
```

---

## Technical Challenges & Solutions

### Challenge 1: WebAuthn Signature Consistency
**Problem:** WebAuthn signatures are non-deterministic (different every time)

**Solution:**
```dart
// Store derived key in SessionStorage (survives page refresh)
// Re-derive only on:
// 1. Fresh login
// 2. Session expired
// 3. Browser restart

class SessionKeyPersistence {
  static const _sessionKey = 'peerwave_session_key';
  
  void saveToSessionStorage(CryptoKey key) async {
    // Export key
    final exported = await crypto.subtle.exportKey('raw', key);
    
    // Store in SessionStorage (cleared on tab close)
    window.sessionStorage[_sessionKey] = base64Encode(exported);
  }
  
  Future<CryptoKey?> loadFromSessionStorage() async {
    final keyData = window.sessionStorage[_sessionKey];
    if (keyData == null) return null;
    
    // Re-import key
    final keyBytes = base64Decode(keyData);
    return await crypto.subtle.importKey(
      'raw',
      keyBytes,
      {'name': 'AES-GCM', 'length': 256},
      false,
      ['encrypt', 'decrypt']
    );
  }
}
```

### Challenge 2: Performance Impact
**Problem:** Encryption/decryption adds overhead

**Solution:**
- **Batch Operations:** Encrypt/decrypt multiple items together
- **Caching:** Keep decrypted data in memory (cleared on logout)
- **Lazy Loading:** Only decrypt data when accessed
- **Web Workers:** Offload crypto to background thread

```dart
class CryptoWorkerPool {
  final workers = <Worker>[];
  
  Future<Uint8List> encryptAsync(Uint8List data) async {
    final worker = _getAvailableWorker();
    return await worker.encrypt(data);
  }
}
```

### Challenge 3: Key Loss / Recovery
**Problem:** If WebAuthn fails, user loses access to data

**Solution:**
```dart
class KeyBackupService {
  /// Backup encrypted key to server (encrypted with password)
  Future<void> backupEncryptionKey(CryptoKey key, String password) async {
    // Derive backup key from password
    final backupKey = await deriveKeyFromPassword(password);
    
    // Encrypt the encryption key
    final encryptedKey = await encryptKey(key, backupKey);
    
    // Store on server
    await api.storeBackupKey(encryptedKey);
  }
  
  /// Recover key using password
  Future<CryptoKey> recoverEncryptionKey(String password) async {
    final encryptedKey = await api.getBackupKey();
    final backupKey = await deriveKeyFromPassword(password);
    return await decryptKey(encryptedKey, backupKey);
  }
}
```

---

## Additional Security Considerations

### 1. Key Rotation
```dart
class KeyRotationService {
  /// Rotate encryption key every 30 days
  Future<void> rotateEncryptionKey() async {
    final lastRotation = await getLastRotationDate();
    final daysSinceRotation = DateTime.now().difference(lastRotation).inDays;
    
    if (daysSinceRotation >= 30) {
      // 1. Derive new key from fresh WebAuthn signature
      final newKey = await requestNewWebAuthnSignature();
      
      // 2. Re-encrypt all data with new key
      await reencryptAllData(oldKey, newKey);
      
      // 3. Update session key
      cryptoService.setSessionKey(newKey, email, deviceId);
    }
  }
}
```

### 2. Tamper Detection
```dart
class IntegrityVerification {
  /// Add HMAC to detect tampering
  Future<void> putWithIntegrity(String key, dynamic value) async {
    final encrypted = await encrypt(value);
    
    // Calculate HMAC
    final hmac = await calculateHMAC(encrypted);
    
    final envelope = {
      'data': encrypted,
      'hmac': hmac,
      'timestamp': DateTime.now().toIso8601String(),
    };
    
    await idb.put(key, envelope);
  }
  
  Future<dynamic> getWithIntegrity(String key) async {
    final envelope = await idb.get(key);
    
    // Verify HMAC
    final expectedHmac = await calculateHMAC(envelope['data']);
    if (envelope['hmac'] != expectedHmac) {
      throw TamperingDetectedException();
    }
    
    return await decrypt(envelope['data']);
  }
}
```

### 3. Access Logging
```dart
class AccessAuditLog {
  /// Log all access to encrypted data
  Future<void> logAccess(String operation, String key) async {
    await auditLog.add({
      'timestamp': DateTime.now().toIso8601String(),
      'user': currentUser,
      'operation': operation, // 'read', 'write', 'delete'
      'key': key,
      'success': true,
    });
  }
}
```

---

## Testing Strategy

### Unit Tests
```dart
test('WebAuthn key derivation produces consistent keys', () async {
  final signature = generateMockSignature();
  final key1 = await crypto.deriveEncryptionKey(signature);
  final key2 = await crypto.deriveEncryptionKey(signature);
  
  expect(key1, equals(key2));
});

test('Encrypted data cannot be read by different user', () async {
  // User A encrypts data
  crypto.setSessionKey(keyA, 'userA@example.com', '1');
  await store.putEncrypted('test', 'secret');
  
  // User B tries to read
  crypto.setSessionKey(keyB, 'userB@example.com', '2');
  expect(
    () => store.getDecrypted('test'),
    throwsA(isA<AccessDeniedException>())
  );
});

test('Data cleanup on user switch', () async {
  await cleanup.cleanupOnUserSwitch('newuser@example.com');
  
  final stores = await listAllStores();
  expect(stores, isEmpty);
});
```

### Integration Tests
```dart
testWidgets('Full login-encrypt-logout-login cycle', (tester) async {
  // 1. User A logs in
  await loginWithWebAuthn('userA@example.com');
  
  // 2. Send message (encrypted)
  await sendMessage('Hello World');
  
  // 3. Logout (key destroyed)
  await logout();
  
  // 4. User B logs in
  await loginWithWebAuthn('userB@example.com');
  
  // 5. Verify User B cannot read User A's messages
  final messages = await loadMessages();
  expect(messages, isEmpty);
  
  // 6. User A logs back in
  await loginWithWebAuthn('userA@example.com');
  
  // 7. Verify User A can read their messages
  final userAMessages = await loadMessages();
  expect(userAMessages.length, 1);
  expect(userAMessages[0].text, 'Hello World');
});
```

---

## Rollout Plan

### Phase 1: Alpha (Internal Testing)
- Deploy to staging environment
- Test with 5 internal users
- Monitor performance metrics
- Fix critical bugs

### Phase 2: Beta (Limited Release)
- Deploy to 10% of users
- Monitor error rates
- Collect feedback
- Optimize performance

### Phase 3: Production (Full Release)
- Gradual rollout: 25% → 50% → 100%
- Enable for all new users
- Migrate existing users over 4 weeks
- Keep legacy fallback for 2 months

---

## Fallback & Recovery

### Graceful Degradation
```dart
class EncryptedStoreWithFallback {
  Future<dynamic> get(String key) async {
    try {
      // Try encrypted first
      return await encryptedStore.getDecrypted(key);
    } catch (e) {
      // Fallback to unencrypted
      debugPrint('[WARN] Encryption failed, falling back to legacy store');
      return await legacyStore.get(key);
    }
  }
}
```

### Emergency Key Recovery
```dart
class EmergencyRecovery {
  /// Admin can reset user's encryption (data loss)
  Future<void> resetUserEncryption(String userId) async {
    await deleteAllUserData(userId);
    await generateNewEncryptionKey(userId);
    await notifyUser('Your encryption keys have been reset. Previous data is lost.');
  }
}
```

---

## Performance Benchmarks

### Target Metrics
- **Encryption:** < 10ms per message
- **Decryption:** < 5ms per message
- **Key Derivation:** < 200ms (one-time on login)
- **Storage Overhead:** < 20% (IV + metadata)

### Optimization Techniques
1. **Batch Crypto Operations:** Process 100 items at once
2. **Memory Cache:** Keep 1000 most recent decrypted items
3. **Lazy Decryption:** Decrypt on-demand, not on load
4. **Index Optimization:** Store metadata separately for fast filtering

---

## Documentation Requirements

### User Documentation
- [ ] WebAuthn setup guide
- [ ] What happens on logout
- [ ] Key recovery process
- [ ] FAQ: "Why can't I see old messages?"

### Developer Documentation
- [ ] API reference for EncryptedIndexedDBStore
- [ ] Migration guide for existing stores
- [ ] Security best practices
- [ ] Troubleshooting guide

---

## Success Criteria

### Security
- ✅ Data encrypted at rest
- ✅ User isolation enforced cryptographically
- ✅ No plaintext data in IndexedDB
- ✅ Key derivation from WebAuthn signature

### Performance
- ✅ < 10ms encryption overhead per operation
- ✅ No noticeable UI lag
- ✅ < 100MB memory increase

### Reliability
- ✅ 99.9% success rate for encrypt/decrypt
- ✅ < 0.1% data loss during migration
- ✅ Graceful fallback on errors

---

## Timeline

| Phase | Duration | Deliverable |
|-------|----------|-------------|
| Phase 1 | 2 weeks | Core crypto infrastructure |
| Phase 2 | 2 weeks | Signal store integration |
| Phase 3 | 1 week | WebAuthn integration |
| Phase 4 | 1 week | Migration & cleanup |
| Testing | 2 weeks | Unit + integration tests |
| Beta | 2 weeks | Limited user testing |
| Rollout | 4 weeks | Gradual production release |
| **TOTAL** | **14 weeks** | **~3.5 months** |

---

## Next Steps

1. ✅ Approve this plan
2. Create detailed technical specs
3. Set up development branch: `feature/webauthn-encryption`
4. Implement Phase 1 (core crypto)
5. Weekly progress reviews

