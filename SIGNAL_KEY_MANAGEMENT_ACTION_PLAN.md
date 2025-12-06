# Signal Key Management - Race Condition Analysis & Action Plan

**Date**: December 6, 2025  
**Status**: ✅ IMPLEMENTATION COMPLETE  
**Priority**: HIGH - Security & Data Integrity

---

## 📝 Implementation Summary

**All phases completed successfully:**
- ✅ Phase 1: Critical Security Fixes (3/3 complete)
- ✅ Phase 2: Code Quality Improvements (2/2 complete)
- ✅ Phase 3: Optional Enhancements (1/1 complete)
- ✅ Backend: Server Endpoints (2/2 complete)

**Files Modified:**
- `client/lib/services/signal_setup_service.dart` - Consolidated error handling + server validation
- `client/lib/services/signal_service.dart` - Key validation before clientReady + transaction-like listeners + smart PreKey regeneration
- `client/lib/services/key_management_metrics.dart` - NEW: Telemetry class
- `server/routes/client.js` - NEW: Two validation endpoints

---

## 🔍 Current State Analysis

### ✅ What Works Well

1. **`signal_service.dart`**:
   - ✅ HTTP batch upload with await (prevents race conditions)
   - ✅ Auto-regenerates consumed PreKeys in background
   - ✅ Validates SignedPreKey signatures
   - ✅ Identity key mismatch detection (local vs server)
   - ✅ PreKey reuse prevention (new `_handlePreKeyIdsSyncResponse`)

2. **`signal_setup_service.dart`**:
   - ✅ Decryption failure detection (InvalidCipherTextException)
   - ✅ SignedPreKey signature validation
   - ✅ Auto-clears corrupted keys
   - ✅ Grace period to prevent redirect loops

---

## 🚨 Critical Issues Found

### Issue #1: Race Condition in `checkKeysStatus()` ⚠️
**Location**: `signal_setup_service.dart` lines 250-400  
**Problem**: Multiple async checks without coordination

```dart
// Step 1: Check Identity (may trigger clearAllSignalData)
try {
  await identityStore.getIdentityKeyPair();
} catch (e) {
  if (decryption_failed) {
    await clearAllSignalData(); // ❌ Clears EVERYTHING
  }
}

// Step 2: Check SignedPreKey (may ALSO trigger clearAllSignalData)
try {
  await signedPreKeyStore.loadSignedPreKeys();
} catch (e) {
  if (decryption_failed) {
    await clearAllSignalData(); // ❌ DUPLICATE clear!
  }
}

// Step 3: Check PreKeys (may ALSO trigger clearAllSignalData)
// ❌ PROBLEM: clearAllSignalData() called 3 times if all fail!
```

**Impact**: 
- Multiple redundant server deletions
- State corruption if one completes while another starts
- Unnecessary network traffic

**Solution**: Single error handler with flag

---

### Issue #2: Missing Server Validation in `checkKeysStatus()` 🔒
**Location**: `signal_setup_service.dart`  
**Problem**: Only checks LOCAL keys, doesn't verify against server

**Current Flow**:
```
checkKeysStatus() → Only checks local storage
                 → Doesn't know if server has different keys
                 → User proceeds to app
                 → Later: _ensureSignalKeysPresent() finds mismatch
                 → ERROR: Keys out of sync, messages fail
```

**Desired Flow**:
```
checkKeysStatus() → Check local storage ✓
                 → Fetch server status (identityKey, signedPreKeyId, preKeyCount)
                 → Compare local vs server
                 → If mismatch: Mark needsSetup=true
                 → User redirected to setup BEFORE entering app
```

**Solution**: Add lightweight server check

---

### Issue #3: PreKey Replacement Strategy Unclear 🤔
**Question**: When should we replace ALL PreKeys vs individual ones?

**Current Behavior**:
- Identity change → Clear all keys (correct ✅)
- SignedPreKey rotation → Keep old for 30 days (correct ✅)
- PreKey consumed → Regenerate that one ID (correct ✅)
- PreKey decryption fails → ??? (currently: clear all)

**Scenarios to Consider**:

| Scenario | Current Action | Should Be? |
|----------|----------------|------------|
| Identity key changed | Clear all PreKeys ✅ | ✅ Correct (must re-sign) |
| SignedPreKey signature invalid | Clear all PreKeys ✅ | ✅ Correct (linked to identity) |
| One PreKey decryption fails | Clear all PreKeys ❌ | ❓ Only clear that PreKey? |
| Encryption key changed | Clear all PreKeys ✅ | ✅ Correct (can't decrypt any) |
| Server has 0 PreKeys, local has 110 | Upload all ✅ | ✅ Correct (first-time sync) |
| Server has 109, local has 110 | Request server IDs ✅ | ✅ Correct (identify consumed) |

**Recommendation**: Single PreKey failure should only regenerate that PreKey, unless it's a systemic issue (encryption key changed).

---

### Issue #4: `clientReady` Flow - Pending Message Timing ⏱️
**Location**: Multiple files  
**Problem**: Server may send messages before keys are validated

**Current Flow**:
```
1. User logs in
2. initStoresAndListeners() → clientReady sent ✓
3. Server: "Here are 50 pending messages" 📬
4. Client starts decrypting...
5. _ensureSignalKeysPresent() runs (async, after clientReady)
6. Finds identity mismatch! ❌
7. Too late - already received messages with wrong keys
```

**Better Flow**:
```
1. User logs in
2. initStoresAndListeners() → DON'T send clientReady yet
3. signalStatus → Get server key status
4. _ensureSignalKeysPresent() → Validate & sync keys
5. ONLY THEN: clientReady ✓
6. Server: "Here are 50 pending messages" 📬
7. Client decrypts successfully ✅
```

**Solution**: Delay `clientReady` until key validation completes

---

### Issue #5: Duplicate Socket Listener Registration 🔄
**Location**: `signal_service.dart` line 897  
**Problem**: `_listenersRegistered` flag prevents re-registration, BUT...

```dart
// Guard prevents duplicate registration
if (_listenersRegistered) { return; }

// However, if init() fails halfway:
// - Some listeners registered ✓
// - Some listeners NOT registered ❌
// - Flag set to true
// - Retry: Skips all listeners!
```

**Impact**: Lost event handlers after failed initialization

**Solution**: Transaction-like registration (all or nothing)

---

## 📋 Proposed Action Plan

### Phase 1: Critical Security Fixes (Must Do Now)

#### Action 1.1: Consolidate Error Handling in `checkKeysStatus()`
**File**: `signal_setup_service.dart`  
**Priority**: 🔴 CRITICAL

```dart
Future<Map<String, dynamic>> checkKeysStatus() async {
  bool needsFullReset = false;
  String resetReason = '';
  
  // Check Identity
  try {
    await identityStore.getIdentityKeyPair();
    result['hasIdentity'] = true;
  } catch (e) {
    if (isDecryptionFailure(e)) {
      needsFullReset = true;
      resetReason = 'Identity decryption failed';
    }
    result['hasIdentity'] = false;
  }
  
  // Check SignedPreKey (only if identity succeeded)
  if (!needsFullReset) {
    try {
      await signedPreKeyStore.loadSignedPreKeys();
      // Validate signatures...
    } catch (e) {
      if (isDecryptionFailure(e)) {
        needsFullReset = true;
        resetReason = 'SignedPreKey decryption failed';
      }
    }
  }
  
  // Check PreKeys (only if no systemic failure)
  if (!needsFullReset) {
    try {
      await preKeyStore.getAllPreKeyIds();
    } catch (e) {
      if (isDecryptionFailure(e)) {
        needsFullReset = true;
        resetReason = 'PreKey decryption failed';
      }
    }
  }
  
  // Single cleanup call if needed
  if (needsFullReset) {
    await clearAllSignalData(reason: resetReason);
    result['needsSetup'] = true;
  }
  
  return result;
}
```

**Benefits**:
- ✅ Single `clearAllSignalData()` call
- ✅ No race conditions between cleanup attempts
- ✅ Clear error tracking

---

#### Action 1.2: Add Server Validation to `checkKeysStatus()`
**File**: `signal_setup_service.dart`  
**Priority**: 🔴 CRITICAL

Add lightweight server check:

```dart
Future<Map<String, dynamic>> checkKeysStatus() async {
  // ... existing local checks ...
  
  // NEW: Fetch server status (only counts, not full keys)
  try {
    final serverStatus = await ApiService.get('/signal/status/minimal');
    
    // Compare Identity public key
    if (serverStatus['identityKey'] != null) {
      final localIdentity = await identityStore.getIdentityKeyPairData();
      if (serverStatus['identityKey'] != localIdentity['publicKey']) {
        // Mismatch detected BEFORE entering app!
        result['needsSetup'] = true;
        missingKeys['identity'] = 'Server identity mismatch';
      }
    }
    
    // Compare SignedPreKey ID (check if server has latest)
    final localSignedKeys = await signedPreKeyStore.loadSignedPreKeys();
    if (localSignedKeys.isNotEmpty) {
      final newestLocal = localSignedKeys.last;
      if (serverStatus['signedPreKeyId'] != newestLocal.id) {
        // Server has old SignedPreKey
        result['needsSetup'] = true;
        missingKeys['signedPreKey'] = 'Server has outdated SignedPreKey';
      }
    }
  } catch (e) {
    // Network error - allow offline use
    debugPrint('[SIGNAL SETUP] Could not verify server status (offline?): $e');
  }
  
  return result;
}
```

**Backend Required**:
```javascript
// Lightweight endpoint for checkKeysStatus()
app.get('/signal/status/minimal', authenticateJWT, async (req, res) => {
  const identity = await Identity.findOne({ 
    userId: req.user.userId, 
    deviceId: req.user.deviceId 
  });
  
  const signedPreKey = await SignedPreKey.findOne({
    userId: req.user.userId,
    deviceId: req.user.deviceId
  }).sort({ id: -1 }).limit(1);
  
  const preKeyCount = await PreKey.count({
    userId: req.user.userId,
    deviceId: req.user.deviceId
  });
  
  res.json({
    identityKey: identity?.publicKey,
    signedPreKeyId: signedPreKey?.id,
    preKeyCount: preKeyCount
  });
});

// Validation endpoint for initStoresAndListeners()
app.post('/signal/validate-and-sync', authenticateJWT, async (req, res) => {
  const { localIdentityKey, localSignedPreKeyId, localPreKeyCount } = req.body;
  
  // Fetch server state
  const serverIdentity = await Identity.findOne({ 
    userId: req.user.userId, 
    deviceId: req.user.deviceId 
  });
  
  const serverSignedPreKey = await SignedPreKey.findOne({
    userId: req.user.userId,
    deviceId: req.user.deviceId
  }).sort({ id: -1 }).limit(1);
  
  const serverPreKeys = await PreKey.find({
    userId: req.user.userId,
    deviceId: req.user.deviceId
  }).select('id');
  
  const validationResult = {
    keysValid: true,
    missingKeys: [],
    preKeyIdsToDelete: []
  };
  
  // Validate Identity
  if (!serverIdentity || serverIdentity.publicKey !== localIdentityKey) {
    validationResult.keysValid = false;
    validationResult.missingKeys.push('identity');
    validationResult.reason = 'Identity key mismatch';
  }
  
  // Validate SignedPreKey
  else if (!serverSignedPreKey || serverSignedPreKey.id !== localSignedPreKeyId) {
    validationResult.keysValid = false;
    validationResult.missingKeys.push('signedPreKey');
    validationResult.reason = 'SignedPreKey out of sync';
  }
  
  // Validate PreKeys
  else {
    const serverPreKeyIds = serverPreKeys.map(k => k.id);
    const localPreKeyIds = Array.from({length: localPreKeyCount}, (_, i) => i);
    
    // Find PreKeys that exist locally but not on server (consumed)
    const consumedPreKeyIds = localPreKeyIds.filter(id => !serverPreKeyIds.includes(id));
    
    if (consumedPreKeyIds.length > 0) {
      validationResult.preKeyIdsToDelete = consumedPreKeyIds;
      validationResult.reason = `${consumedPreKeyIds.length} PreKeys consumed`;
    }
  }
  
  res.json(validationResult);
});
```

---

#### Action 1.3: Delay `clientReady` Until Key Validation
**File**: `signal_service.dart`  
**Priority**: 🟡 HIGH

```dart
Future<void> initStoresAndListeners() async {
  // Initialize stores
  if (!_storesCreated) { ... }
  
  // Register listeners
  await _registerSocketListeners();
  
  // ❌ OLD: Send clientReady immediately
  // SocketService().notifyClientReady();
  
  // ✅ NEW: Validate keys first via HTTP, THEN send clientReady
  debugPrint('[SIGNAL INIT] Validating keys before clientReady...');
  
  try {
    // HTTP request to validate/sync keys (blocking, with response code)
    final response = await ApiService.post('/signal/validate-and-sync', {
      'localIdentityKey': await _getLocalIdentityPublicKey(),
      'localSignedPreKeyId': await _getLatestSignedPreKeyId(),
      'localPreKeyCount': await _getLocalPreKeyCount(),
    });
    
    if (response.statusCode == 200) {
      final validationResult = response.data;
      
      if (validationResult['keysValid'] == true) {
        debugPrint('[SIGNAL INIT] ✓ Keys validated by server');
      } else {
        // Server detected mismatch - handle sync
        debugPrint('[SIGNAL INIT] ⚠ Key mismatch detected: ${validationResult['reason']}');
        await _handleKeySyncRequired(validationResult);
      }
    } else {
      debugPrint('[SIGNAL INIT] ⚠ Key validation failed: ${response.statusCode}');
      // Proceed anyway for offline scenarios
    }
  } catch (e) {
    // Network error - allow offline use
    debugPrint('[SIGNAL INIT] Could not validate keys (offline?): $e');
  }
  
  // NOW send clientReady (keys are validated or offline mode accepted)
  SocketService().notifyClientReady();
  debugPrint('[SIGNAL INIT] ✓ Client ready sent');
  
  _isInitialized = true;
}

Future<String?> _getLocalIdentityPublicKey() async {
  try {
    final identity = await identityStore.getIdentityKeyPairData();
    return identity['publicKey'];
  } catch (_) {
    return null;
  }
}

Future<int?> _getLatestSignedPreKeyId() async {
  try {
    final keys = await signedPreKeyStore.loadSignedPreKeys();
    return keys.isNotEmpty ? keys.last.id : null;
  } catch (_) {
    return null;
  }
}

Future<int> _getLocalPreKeyCount() async {
  try {
    final ids = await preKeyStore.getAllPreKeyIds();
    return ids.length;
  } catch (_) {
    return 0;
  }
}

Future<void> _handleKeySyncRequired(Map<String, dynamic> validationResult) async {
  // Handle different sync scenarios based on server response
  if (validationResult['missingKeys']?.contains('identity') == true) {
    // Identity mismatch - needs full re-setup
    await clearAllSignalData(reason: 'Identity mismatch with server');
  } else if (validationResult['missingKeys']?.contains('signedPreKey') == true) {
    // SignedPreKey out of sync
    await rotateSignedPreKey();
  } else if (validationResult['preKeyIdsToDelete'] != null) {
    // PreKeys consumed - delete locally
    final idsToDelete = List<int>.from(validationResult['preKeyIdsToDelete']);
    for (final id in idsToDelete) {
      await preKeyStore.removePreKey(id);
    }
    // Regenerate missing PreKeys
    await _regenerateMissingPreKeys();
  }
}
```

---

### Phase 2: Code Quality Improvements (Should Do Soon)

#### Action 2.1: Transaction-Like Listener Registration
**File**: `signal_service.dart`  
**Priority**: 🟢 MEDIUM

```dart
Future<void> _registerSocketListeners() async {
  if (_listenersRegistered) { return; }
  
  final listeners = <String, Function>{};
  
  try {
    // Register all listeners (stored, not activated yet)
    listeners['receiveItem'] = (data) async { ... };
    listeners['groupMessage'] = (data) async { ... };
    // ... all other listeners ...
    
    // Activate all at once
    for (final entry in listeners.entries) {
      SocketService().registerListener(entry.key, entry.value);
    }
    
    _listenersRegistered = true;
    debugPrint('[SIGNAL SERVICE] ✅ All listeners registered');
  } catch (e) {
    // Rollback: Remove any partially registered listeners
    for (final event in listeners.keys) {
      SocketService().removeListener(event);
    }
    _listenersRegistered = false;
    rethrow;
  }
}
```

---

#### Action 2.2: Single PreKey Regeneration Strategy
**File**: `signal_service.dart`  
**Priority**: 🟢 MEDIUM

```dart
// When a single PreKey fails to decrypt:
try {
  await preKeyStore.loadPreKey(id);
} catch (e) {
  if (isDecryptionFailure(e)) {
    // Check if this is systemic (encryption key changed)
    final canDecryptOthers = await _testPreKeyDecryption();
    
    if (!canDecryptOthers) {
      // Systemic issue - clear all
      await clearAllSignalData(reason: 'Encryption key changed');
    } else {
      // Isolated issue - regenerate this PreKey
      await preKeyStore.removePreKey(id);
      await _regeneratePreKeyAsync(id);
    }
  }
}

Future<bool> _testPreKeyDecryption() async {
  final ids = await preKeyStore.getAllPreKeyIds();
  if (ids.isEmpty) return false;
  
  // Test 3 random PreKeys
  for (int i = 0; i < 3 && i < ids.length; i++) {
    try {
      await preKeyStore.loadPreKey(ids[i]);
      return true; // At least one works
    } catch (_) {}
  }
  return false; // All failed - systemic issue
}
```

---

### Phase 3: Optional Enhancements (Nice to Have)

#### Action 3.1: Telemetry & Monitoring
Add metrics for debugging:

```dart
class KeyManagementMetrics {
  static int identityRegenerations = 0;
  static int signedPreKeyRotations = 0;
  static int preKeysRegenerated = 0;
  static int decryptionFailures = 0;
  
  static void report() {
    debugPrint('[METRICS] Key Management Stats:');
    debugPrint('  Identity regenerations: $identityRegenerations');
    debugPrint('  SignedPreKey rotations: $signedPreKeyRotations');
    debugPrint('  PreKeys regenerated: $preKeysRegenerated');
    debugPrint('  Decryption failures: $decryptionFailures');
  }
}
```

---

## 🎯 Implementation Priority

### Must Do (Security Critical):
1. ✅ **Action 1.1**: Consolidate error handling
2. ✅ **Action 1.2**: Add server validation
3. ✅ **Action 1.3**: Delay clientReady

### Should Do (Stability):
4. ✅ **Action 2.1**: Transaction-like listeners
5. ✅ **Action 2.2**: Smart PreKey regeneration

### Nice to Have (Observability):
6. ⭐ **Action 3.1**: Telemetry

---

## 📊 Testing Checklist

After implementation, test:

- [ ] **Scenario 1**: Fresh install (no keys)
  - Expected: Generate all keys, validate, then clientReady
  
- [ ] **Scenario 2**: Return user (keys exist)
  - Expected: Validate keys, then clientReady
  
- [ ] **Scenario 3**: Encryption key changed
  - Expected: Detect in `checkKeysStatus()`, redirect to setup
  
- [ ] **Scenario 4**: Identity key mismatch (local ≠ server)
  - Expected: Detect in `checkKeysStatus()`, clear all, redirect to setup
  
- [ ] **Scenario 5**: Offline return (no network)
  - Expected: Skip server validation, use local keys
  
- [ ] **Scenario 6**: Single PreKey fails to decrypt
  - Expected: Regenerate only that PreKey
  
- [ ] **Scenario 7**: Multiple PreKeys consumed while offline
  - Expected: Sync with server IDs, regenerate consumed ones

---

## ⚠️ Breaking Changes

### Backend Required:
- New endpoint: `GET /signal/status/minimal`
  - Response: `{ identityKey, signedPreKeyId, preKeyCount }`
- New endpoint: `POST /signal/validate-and-sync`
  - Request: `{ localIdentityKey, localSignedPreKeyId, localPreKeyCount }`
  - Response: `{ keysValid, missingKeys[], preKeyIdsToDelete[], reason }`

### Client Changes:
- `checkKeysStatus()` may take longer (network call)
- `initStoresAndListeners()` uses HTTP POST with response validation (no arbitrary timeout)
- Users may see "Validating keys..." message during login
- Offline mode: Falls back gracefully if HTTP request fails

---

## 🤔 Questions for Review

1. **PreKey Replacement**: Should single PreKey failure clear ALL PreKeys, or just regenerate that one?
   - My recommendation: Test if systemic, then decide
   
2. **Server Validation**: Should `checkKeysStatus()` fail if offline, or skip server check?
   - My recommendation: Let it fail and use existing "server unreachable" flow - simpler and more consistent
   
3. **clientReady Delay**: HTTP POST blocks until server responds - acceptable?
   - My recommendation: Yes, provides definitive validation (no guessing with timeouts)
   
4. **Telemetry**: Do you want metrics/logging for production debugging?
   - My recommendation: Yes, helps diagnose user issues

---

## ✅ Approval Needed

Please review this action plan and confirm:

- [ ] Approve Phase 1 (Critical Security Fixes)
- [ ] Approve Phase 2 (Code Quality)
- [ ] Approve Phase 3 (Optional Enhancements)
- [ ] Request changes/clarifications

**Reply with**: "Approved" or specific sections to modify.
