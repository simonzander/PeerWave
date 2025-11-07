# WebAuthn Encryption - Critical Discussion Points

## 🎯 Executive Summary

WebAuthn-based encryption for IndexedDB is **technically feasible** but comes with significant trade-offs. This document discusses critical considerations that go beyond the basic implementation.

---

## 🔴 Critical Issues to Resolve

### 1. WebAuthn Signature Non-Determinism

**The Core Problem:**
```javascript
// WebAuthn signatures are DIFFERENT every time
const sig1 = await navigator.credentials.get({...}); // Sign challenge
const sig2 = await navigator.credentials.get({...}); // Sign same challenge

// sig1 !== sig2  ❌ Problem!
```

**Why This Matters:**
- We need the SAME encryption key every session
- But WebAuthn produces DIFFERENT signatures each time
- We cannot store the signature (defeats security purpose)

**Proposed Solutions:**

#### Option A: Session Persistence (RECOMMENDED ⭐)
```dart
// After WebAuthn auth, store derived key in SessionStorage
class SessionKeyManager {
  // SessionStorage = cleared when browser tab closes
  // localStorage = persists forever (NOT SECURE)
  // memory = lost on page refresh (BAD UX)
  
  void storeInSession(CryptoKey key) {
    // Survives page refresh within same tab
    // Cleared when tab/browser closes
    sessionStorage['encryption_key'] = exportKey(key);
  }
}
```

**Trade-off:**
- ✅ Works across page refreshes
- ✅ Automatic cleanup on browser close
- ❌ Re-authentication needed after browser restart
- ❌ Key exists in memory (could be extracted)

#### Option B: Challenge-Response with Server Salt
```dart
class DeterministicKeyDerivation {
  Future<CryptoKey> deriveKey() async {
    // 1. Get deterministic salt from server (tied to user)
    final salt = await api.getUserSalt(userId);
    
    // 2. Sign the salt with WebAuthn
    final signature = await webauthn.sign(salt);
    
    // 3. Derive key with HKDF
    final key = await hkdf(signature, salt, 'indexeddb-encryption');
    
    return key;
  }
}
```

**Trade-off:**
- ✅ Same signature each time (same challenge)
- ✅ Key can be re-derived on demand
- ❌ Server knows the salt (potential attack vector)
- ❌ Requires online connection

#### Option C: Password-Based Key Backup (FALLBACK)
```dart
class KeyBackup {
  Future<void> backupKey(CryptoKey key, String password) async {
    // Encrypt encryption key with password
    final backupKey = await pbkdf2(password, salt, 100000);
    final encryptedKey = await aesEncrypt(key, backupKey);
    
    // Store on server
    await api.storeBackupKey(encryptedKey);
  }
  
  Future<CryptoKey> recoverKey(String password) async {
    // User enters password → recover key
    final encryptedKey = await api.getBackupKey();
    final backupKey = await pbkdf2(password, salt, 100000);
    return await aesDecrypt(encryptedKey, backupKey);
  }
}
```

**Trade-off:**
- ✅ Works even if WebAuthn device lost
- ✅ User-controlled recovery
- ❌ Requires password (defeats passwordless goal)
- ❌ Password strength becomes critical

---

### 2. Multi-Device Synchronization

**Problem:**
```
User has:
- Laptop (WebAuthn key A)
- Phone (WebAuthn key B)

Laptop encrypts messages with key A
Phone tries to decrypt → FAIL (has key B, not key A)
```

**This is a FUNDAMENTAL issue with device-specific encryption.**

**Proposed Solutions:**

#### Option A: Server-Side Key Escrow (CONTROVERSIAL)
```dart
class KeyEscrow {
  Future<void> uploadEncryptionKey(CryptoKey key) async {
    // Encrypt user's encryption key with server's public key
    final serverPubKey = await api.getServerPublicKey();
    final encryptedKey = await rsaEncrypt(key, serverPubKey);
    
    // Server stores encrypted key
    await api.escrowKey(encryptedKey);
  }
  
  Future<CryptoKey> downloadEncryptionKey() async {
    // New device downloads encrypted key from server
    // Server decrypts with private key and re-encrypts for device
    return await api.retrieveEscrowedKey();
  }
}
```

**Trade-off:**
- ✅ Seamless multi-device experience
- ✅ User doesn't lose data on device change
- ❌ **Server can decrypt all user data** (major security compromise)
- ❌ Requires absolute trust in server operator
- ❌ Regulatory issues (GDPR, data residency)

#### Option B: Device-Specific Encryption (RECOMMENDED ⭐)
```dart
class PerDeviceEncryption {
  Future<void> syncToNewDevice() async {
    // User adds new device
    
    // 1. Existing device generates sync key
    final syncKey = generateSyncKey();
    
    // 2. Display QR code on existing device
    final qrCode = generateQRCode(syncKey);
    
    // 3. New device scans QR code
    final scannedKey = await scanQRCode();
    
    // 4. Existing device sends encrypted data over local network
    await transferEncryptedData(newDevice, scannedKey);
  }
}
```

**Trade-off:**
- ✅ No server involvement
- ✅ True end-to-end encryption
- ❌ Complex UX (QR code scanning)
- ❌ Requires physical proximity
- ❌ Must be done for each device

#### Option C: Hybrid Approach (BALANCED)
```dart
class HybridSync {
  // Each device has its own encryption key
  // Messages stored once per device
  
  Future<void> sendMessage(String text) async {
    // 1. Encrypt message with Signal protocol (E2EE)
    final signalEncrypted = await signalEncrypt(text);
    
    // 2. Store on server (Signal-encrypted)
    await api.storeMessage(signalEncrypted);
    
    // 3. Each device downloads and decrypts with Signal
    // 4. Each device re-encrypts with its own IndexedDB key
    final localKey = await getDeviceEncryptionKey();
    await indexedDB.putEncrypted(messageId, text, localKey);
  }
}
```

**Trade-off:**
- ✅ Multi-device works
- ✅ No server-side encryption key escrow
- ❌ Each device stores separate copy
- ❌ Storage duplication

---

### 3. Key Loss Scenarios

**Scenarios Where User Loses Access:**

#### Scenario A: Lost WebAuthn Device
```
User's laptop with security key is stolen/lost
→ Cannot derive encryption key
→ ALL IndexedDB data is permanently unreadable
```

**Mitigation:**
- **MUST implement password-based key backup**
- Display warning during WebAuthn setup
- Force user to set recovery password

#### Scenario B: Browser Clear Cache
```
User clicks "Clear browsing data"
→ IndexedDB deleted
→ Data loss
```

**Mitigation:**
- Sync data to server (encrypted with Signal)
- Warn user before clearing data
- Implement "Export Data" feature

#### Scenario C: WebAuthn Not Available
```
User on old browser without WebAuthn support
→ Cannot authenticate
→ Cannot derive encryption key
```

**Mitigation:**
- Fallback to password-based authentication
- Polyfill for older browsers
- Mobile app with biometric auth

---

### 4. Performance Impact Analysis

**Encryption Overhead:**

```dart
// Benchmark Results (estimated):

// Current (no encryption):
await idb.put(key, data);  // ~1ms

// With encryption:
await encryptedIDB.put(key, data);
// - Serialize: 0.5ms
// - Encrypt (AES-GCM): 5ms
// - Store: 1ms
// TOTAL: ~6.5ms (6.5x slower)

// For 1000 messages:
// Current: 1 second
// Encrypted: 6.5 seconds
```

**Optimization Strategies:**

1. **Batch Operations:**
```dart
// Instead of:
for (msg in messages) {
  await encrypt(msg);  // 1000 crypto calls
}

// Do:
await encryptBatch(messages);  // 1 crypto call
```

2. **Web Workers:**
```dart
class CryptoWorker {
  Worker? _worker;
  
  Future<void> init() async {
    _worker = Worker('crypto_worker.js');
  }
  
  Future<Uint8List> encryptAsync(data) async {
    return await _worker.postMessage({
      'action': 'encrypt',
      'data': data,
    });
  }
}
```

3. **Lazy Decryption:**
```dart
class LazyDecryptedMessage {
  final String _encryptedData;
  String? _plaintext;
  
  Future<String> get text async {
    _plaintext ??= await decrypt(_encryptedData);
    return _plaintext!;
  }
}
```

---

### 5. Regulatory & Compliance

#### GDPR Considerations

**Positive:**
- ✅ "Privacy by Design" - data encrypted at rest
- ✅ "Right to be Forgotten" - delete encrypted key = data unreadable
- ✅ "Data Minimization" - server doesn't store decryption keys

**Negative:**
- ❌ "Right to Data Portability" - harder to export encrypted data
- ❌ "Lawful Access" - law enforcement cannot access user data

#### Export Control

**Encryption is regulated in some countries:**
- Strong encryption (AES-256) may require export licenses
- Some countries ban or restrict encryption
- May need country-specific compliance checks

**Mitigation:**
```dart
class ComplianceCheck {
  Future<bool> canUseEncryption() async {
    final country = await getUserCountry();
    
    if (restrictedCountries.contains(country)) {
      // Use weaker encryption or disable feature
      return false;
    }
    
    return true;
  }
}
```

---

### 6. User Experience Impact

#### Scenario: User Reinstalls Browser

**Current (no encryption):**
```
1. User reinstalls browser
2. Login with WebAuthn
3. ✅ Messages sync from server
4. ✅ Chat history loads
```

**With IndexedDB encryption:**
```
1. User reinstalls browser
2. Login with WebAuthn (new key!)
3. ❌ Cannot decrypt old IndexedDB data
4. ❌ Chat history appears empty
5. Server re-syncs messages
6. New IndexedDB created with new key
7. ✅ Eventually works, but UX disruption
```

**UX Improvements Needed:**

1. **Clear Messaging:**
```dart
showDialog(
  context: context,
  child: AlertDialog(
    title: Text('Setting up encrypted storage'),
    content: Text(
      'We\'re downloading your messages securely. '
      'This may take a few minutes...'
    ),
  ),
);
```

2. **Progress Indicators:**
```dart
class SyncProgress {
  int total = 0;
  int synced = 0;
  
  double get progress => synced / total;
  
  Widget build() {
    return LinearProgressIndicator(
      value: progress,
      label: 'Syncing $synced of $total messages',
    );
  }
}
```

3. **Offline Support:**
```dart
class OfflineQueue {
  // Queue messages while offline
  List<Message> pendingMessages = [];
  
  Future<void> sendWhenOnline() async {
    while (pendingMessages.isNotEmpty) {
      final msg = pendingMessages.first;
      try {
        await sendMessage(msg);
        pendingMessages.removeAt(0);
      } catch (e) {
        // Retry later
        break;
      }
    }
  }
}
```

---

## 🟡 Alternative: Simpler User Isolation

### Option: Email + DeviceId Namespacing

**Instead of encryption, just isolate data by user:**

```dart
class NamespacedIndexedDB {
  final String userEmail;
  final String deviceId;
  
  String _getKey(String key) {
    return '$userEmail:$deviceId:$key';
  }
  
  Future<void> put(String key, dynamic value) async {
    final namespacedKey = _getKey(key);
    await idb.put(namespacedKey, value);
  }
  
  Future<dynamic> get(String key) async {
    final namespacedKey = _getKey(key);
    return await idb.get(namespacedKey);
  }
  
  Future<void> deleteAllUserData() async {
    // Delete all keys starting with user's namespace
    final prefix = '$userEmail:$deviceId:';
    await idb.deleteByPrefix(prefix);
  }
}
```

**Pros:**
- ✅ Much simpler implementation (1 week vs 14 weeks)
- ✅ No performance overhead
- ✅ No key management complexity
- ✅ Works offline without issues

**Cons:**
- ❌ Data not encrypted at rest
- ❌ Physical access to browser = data readable
- ❌ Other users on same browser can theoretically access

**When This Is Sufficient:**
- PeerWave runs on personal devices (not shared computers)
- Users trust their browser environment
- Primary threat is logical separation, not physical access

---

## 🟢 Recommendation Matrix

| Scenario | Recommended Solution | Rationale |
|----------|---------------------|-----------|
| **Personal devices only** | Namespaced IndexedDB | Simple, fast, sufficient isolation |
| **Shared computers** | WebAuthn encryption | Prevents cross-user data access |
| **High security requirement** | WebAuthn + Password backup | Defense in depth |
| **Multi-device users** | Hybrid (Signal E2EE + local encryption) | Balances security and UX |
| **Enterprise deployment** | Server-side key escrow | Centralized management, compliance |

---

## 📋 Decision Checklist

Before implementing WebAuthn encryption, answer these questions:

### Security Requirements
- [ ] Do users access PeerWave from shared computers?
- [ ] Is data encrypted at rest a regulatory requirement?
- [ ] What is the threat model? (Physical access? Malware?)
- [ ] Can server operators be trusted with key escrow?

### User Experience
- [ ] Can users tolerate re-authentication on browser restart?
- [ ] Is multi-device support critical?
- [ ] What happens if user loses WebAuthn device?
- [ ] Can users understand encryption trade-offs?

### Technical Feasibility
- [ ] Do all target browsers support WebAuthn?
- [ ] Do all target browsers support Web Crypto API?
- [ ] Is performance overhead acceptable?
- [ ] Do we have 3-4 months for implementation?

### Operational
- [ ] Do we have key recovery support plan?
- [ ] Do we have incident response for lost keys?
- [ ] Can we support users in multiple countries?
- [ ] Do we have budget for extended development?

---

## 🚀 Phased Rollout Recommendation

### Phase 1: Namespaced IndexedDB (4 weeks)
**Goal:** Logical user isolation

```dart
// Implement simple namespacing
class NamespacedStore {
  final String namespace;
  
  Future<void> put(key, value) async {
    await idb.put('$namespace:$key', value);
  }
}
```

**Benefits:**
- Quick win for multi-user browsers
- Foundation for future encryption
- Low risk, high value

### Phase 2: Optional WebAuthn Encryption (12 weeks)
**Goal:** Encryption for users who need it

```dart
// Settings option
class SecuritySettings {
  bool enableIndexedDBEncryption = false;
  
  Widget build() {
    return SwitchListTile(
      title: Text('Encrypt local data'),
      subtitle: Text('Requires WebAuthn. More secure but may impact performance.'),
      value: enableIndexedDBEncryption,
      onChanged: (value) async {
        if (value) {
          await setupWebAuthnEncryption();
        }
      },
    );
  }
}
```

**Benefits:**
- Users choose their security level
- Power users get encryption
- Casual users get performance

### Phase 3: Mandatory Encryption (TBD)
**Goal:** All users encrypted

Only after:
- Phase 2 proven stable
- Multi-device sync solved
- Key recovery tested
- Performance optimized

---

## 💬 Open Questions for Team Discussion

1. **Is the added complexity worth the security gain?**
   - Most PeerWave users likely on personal devices
   - Signal protocol already provides E2EE
   - IndexedDB is supplementary cache

2. **What is our key recovery strategy?**
   - Password backup?
   - Server escrow?
   - "Lost data is acceptable"?

3. **How do we handle multi-device?**
   - Per-device encryption?
   - QR code pairing?
   - Server-assisted sync?

4. **Performance budget:**
   - Max acceptable encryption overhead?
   - Can we use Web Workers?
   - Batch size for crypto operations?

5. **Timeline priority:**
   - Is 14 weeks acceptable?
   - Are there higher priority features?
   - Can we ship Phase 1 (namespacing) first?

---

## 📊 Cost-Benefit Analysis

### WebAuthn Encryption

**Costs:**
- Development: 14 weeks × 1 developer = 3.5 months
- Testing: 4 weeks × 1 QA = 1 month
- Documentation: 2 weeks
- **Total: ~4.5-5 months**

**Benefits:**
- Data encrypted at rest
- Cryptographic user isolation
- Compliance advantage
- Marketing ("Bank-grade encryption")

### Simple Namespacing

**Costs:**
- Development: 1 week
- Testing: 1 week
- Documentation: 2 days
- **Total: ~2 weeks**

**Benefits:**
- Logical user isolation
- Foundation for future encryption
- No performance impact
- Quick deployment

### ROI Comparison
```
WebAuthn: 5 months investment, high security gain
Namespacing: 2 weeks investment, 80% of benefit

Recommendation: Start with namespacing, evaluate encryption later
```

---

## ✅ Conclusion - UPDATED RECOMMENDATION

**DECISION: Simplified Device-Scoped Storage** ⭐

### Core Concept
```
Device = Email + WebAuthn Credential ID
Each device gets completely isolated IndexedDB stores
No encryption needed - physical isolation is sufficient
```

### Implementation Strategy

**Phase 1: Device-Scoped Storage (2-3 weeks)**

```dart
class DeviceScopedStorage {
  final String userEmail;
  final String webAuthnCredentialId; // Unique per authenticator
  
  // Device identifier
  String get deviceId => '$userEmail:$webAuthnCredentialId';
  
  // Store names are device-specific
  String _getStoreName(String baseName) {
    return '${baseName}_${deviceId.hashCode}';
  }
  
  // Each device gets its own IndexedDB databases
  Future<void> initializeStores() async {
    await openDatabase(_getStoreName('peerwaveSignal'));
    await openDatabase(_getStoreName('peerwaveMessages'));
    await openDatabase(_getStoreName('peerwaveKeys'));
    // ... all other stores
  }
  
  // On logout: Clear current device's stores
  Future<void> clearDeviceData() async {
    await deleteDatabase(_getStoreName('peerwaveSignal'));
    await deleteDatabase(_getStoreName('peerwaveMessages'));
    // ... clear all device stores
  }
}
```

### Key Principles

1. **Device = Email + WebAuthn Credential ID**
   - User with 2 security keys = 2 separate devices
   - Each device has completely isolated storage
   - No data sharing between devices

2. **Data Loss is Acceptable**
   - Lost WebAuthn key = lost local data (by design)
   - New key = fresh start
   - Messages remain on server (Signal encrypted)

3. **No Migration Needed**
   - Still in development phase
   - Clean slate implementation
   - Old data can be purged

4. **Multi-Device Sync via Server**
   - Devices don't share IndexedDB
   - All sync happens through Signal protocol
   - Server stores encrypted messages
   - Each device downloads and decrypts independently

### Benefits

✅ **Security:**
- True device isolation
- Lost key ≠ compromised data (data gone)
- No encryption complexity needed

✅ **Simplicity:**
- No key derivation
- No SessionStorage management
- No key recovery mechanisms

✅ **Performance:**
- Zero encryption overhead
- Native IndexedDB speed
- No crypto operations

✅ **Multi-Device:**
- Works naturally via Signal protocol
- No special sync logic
- Server already handles this

### Trade-offs (Acceptable)

❌ **Data not encrypted at rest locally**
- But: Signal protocol encrypts everything on server
- But: Physical device access is the real threat model
- But: Device isolation prevents cross-user access

❌ **Lost key = lost local cache**
- But: Messages on server (Signal encrypted)
- But: Re-download on new device
- But: Prevents security vulnerabilities

### Architecture

```
┌──────────────────────────────────────────────────────────┐
│ User A                                                   │
├──────────────────────────────────────────────────────────┤
│ Email: alice@example.com                                │
│                                                          │
│ Device 1 (YubiKey #1):                                  │
│   ├─ peerwaveSignal_hash1                              │
│   ├─ peerwaveMessages_hash1                            │
│   └─ peerwaveKeys_hash1                                │
│                                                          │
│ Device 2 (YubiKey #2):                                  │
│   ├─ peerwaveSignal_hash2                              │
│   ├─ peerwaveMessages_hash2                            │
│   └─ peerwaveKeys_hash2                                │
│                                                          │
│ ► No data sharing between devices                       │
│ ► Sync happens via server                              │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│ User B (Different user, same browser)                   │
├──────────────────────────────────────────────────────────┤
│ Email: bob@example.com                                  │
│                                                          │
│ Device 1 (Windows Hello):                               │
│   ├─ peerwaveSignal_hash3                              │
│   ├─ peerwaveMessages_hash3                            │
│   └─ peerwaveKeys_hash3                                │
│                                                          │
│ ► Completely isolated from User A                       │
└──────────────────────────────────────────────────────────┘
```

### Implementation Timeline

**Week 1:**
- Implement `DeviceScopedStorage` service
- Extract WebAuthn Credential ID on login
- Generate device-specific store names

**Week 2:**
- Refactor all stores to use device-scoped names
- Implement cleanup on logout
- Add device management UI

**Week 3:**
- Testing across multiple devices
- Verify isolation between users
- Performance testing

**Total: 3 weeks to production**

### This Approach Solves Everything

| Problem | Solution |
|---------|----------|
| User isolation | Device-specific store names |
| Multi-device sync | Server + Signal protocol |
| Lost key | Data loss acceptable, fresh start |
| Encryption complexity | Not needed - device isolation sufficient |
| Migration | None needed - in development |
| Performance | Zero overhead |
| Security | Physical device isolation |

### Why This Is Better

**vs. WebAuthn Encryption:**
- ⏱️ 3 weeks instead of 14 weeks
- 🚀 Zero performance overhead
- 🔧 Much simpler to maintain
- ✅ No key management complexity

**vs. Simple Namespacing:**
- 🔒 Better isolation (separate databases)
- 🎯 Aligns with device concept
- 🗑️ Easier cleanup (delete entire database)
- 📊 Better for future device management UI

---

## 📞 Next Steps

1. **Team Meeting:** Discuss this document
2. **Decision:** Encryption now vs. later?
3. **Priority:** High/Medium/Low?
4. **Assignment:** Who leads implementation?
5. **Timeline:** When to start?

