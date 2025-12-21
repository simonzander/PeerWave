# Signal Protocol Session Validation - Action Plan

**Date:** December 21, 2025  
**Context:** Fixing session invalidation and validation issues in PeerWave Signal implementation

---

## Problem Statement

### Issue 1: Sessions Not Invalidated After Key Regeneration
When a user regenerates their Identity Key or SignedPreKey, existing sessions with other users become stale and invalid, but are not deleted. This causes:
- Sender uses NEW keys to encrypt
- Receiver has session with OLD keys → Decryption fails
- No automatic recovery mechanism

### Issue 2: No Session Validation Before Sending
The `sendItem()` method blindly uses existing sessions without validating:
- Is the remote Identity Key still the same?
- Has the remote party regenerated their keys?
- Is the session corrupted or stale?

---

## Action Plan

## Phase 1: Local Session Cleanup on Key Regeneration

### 1.1 Delete All Sessions When Regenerating Keys ✓

**Location:** `signal_service.dart` → `clearAllSignalData()`

**Implementation:**
```dart
Future<void> clearAllSignalData({String reason = 'Manual reset'}) async {
  debugPrint('[SIGNAL] 🚨 Clearing all Signal data: $reason');
  
  try {
    // 1. Delete local stores
    await identityStore.deleteAllData();
    await sessionStore.deleteAllSessions();  // ← NEW: Clear all sessions
    await preKeyStore.deleteAllData();
    await signedPreKeyStore.deleteAllData();
    
    // 2. Delete server-side keys
    await ApiService.delete('/signal/keys/all');
    
    // Reset state
    _isInitialized = false;
    _storesCreated = false;
    
    debugPrint('[SIGNAL] ✓ All Signal data cleared');
  } catch (e) {
    debugPrint('[SIGNAL] ⚠️ Error clearing Signal data: $e');
    rethrow;
  }
}
```

**Rationale:**
- When YOU regenerate keys, YOUR sessions are invalid (you changed the signing key)
- Other users' sessions with you are also invalid (they store your OLD identity)
- Deleting local sessions forces fresh session creation on next message

### 1.2 Server Notification? ❌ NOT NEEDED

**Q:** Should we notify the server when keys are regenerated?

**A:** **NO** - The server doesn't manage sessions. Here's why:

1. **Server is stateless for sessions:**
   - Server only stores PreKey bundles (identity + signedPreKey + preKeys)
   - Sessions are purely client-side (stored in sessionStore)
   - Server has no knowledge of who has sessions with whom

2. **Natural recovery mechanism:**
   - Receiver tries to decrypt with old session → FAILS
   - Receiver detects `UntrustedIdentityException` (Identity Key changed)
   - Receiver auto-trusts new Identity Key (already implemented in `handleUntrustedIdentity()`)
   - Receiver deletes old session and requests fresh PreKeyBundle
   - New session is established

3. **PreKeyBundle on server is automatically updated:**
   - When you call `clearAllSignalData()`, it calls `ApiService.delete('/signal/keys/all')`
   - When you run `initWithProgress()`, it uploads new keys to server
   - Server now has your NEW Identity Key + NEW SignedPreKey + NEW PreKeys

**Conclusion:** No server notification needed. The receiver will detect the key change on next message attempt and recover automatically.

---

## Phase 2: Session Validation Before Sending

### 2.1 Validate Session Against Server Keys ✓

**Q:** Do we check against the server?

**A:** **YES** - Server is the source of truth for current public keys.

**Q:** What data do we need from server?

**A:** **Identity Key + SignedPreKey ID is sufficient** for validation. Here's why:

#### Minimal Validation Check:
```
GET /signal/status/minimal?userId=<recipientUserId>&deviceId=<recipientDeviceId>

Response:
{
  "identityKey": "base64...",       // ← Current Identity public key
  "signedPreKeyId": 123,            // ← Current SignedPreKey ID
  "preKeysCount": 85                // ← Remaining PreKeys (optional)
}
```

#### Why This Is Enough:

1. **Identity Key Check:**
   - Session stores the remote Identity Key it was created with
   - If server's Identity Key ≠ stored Identity Key → Session is STALE
   - Action: Delete session, fetch fresh PreKeyBundle

2. **SignedPreKey ID Check:**
   - Sessions don't store SignedPreKey ID directly, BUT:
   - If SignedPreKey rotated significantly (e.g., ID jumped from 5 → 25), session might be old
   - Optional: Use as a "freshness hint" (not critical)

3. **Do NOT need PreKey:**
   - PreKeys are one-time use (consumed during session creation)
   - PreKey used in original session is already deleted
   - No point checking PreKey during validation

#### Validation Logic:

```dart
/// Validate session before sending (check if remote keys changed)
Future<bool> _validateSessionBeforeSend(
  SignalProtocolAddress remoteAddress,
  String recipientUserId,
  int recipientDeviceId,
) async {
  try {
    // 1. Check if session exists locally
    if (!await sessionStore.containsSession(remoteAddress)) {
      debugPrint('[SIGNAL] No session exists for ${remoteAddress.getName()}');
      return false; // Need to create new session
    }
    
    // 2. Get server's current Identity Key
    final response = await ApiService.get(
      '/signal/status/minimal',
      queryParameters: {
        'userId': recipientUserId,
        'deviceId': recipientDeviceId,
      },
    );
    
    final serverIdentityKey = response.data['identityKey'] as String;
    final serverIdentityKeyBytes = base64Decode(serverIdentityKey);
    
    // 3. Get Identity Key stored in our session
    final storedIdentity = await identityStore.getIdentity(remoteAddress);
    
    if (storedIdentity == null) {
      debugPrint('[SIGNAL] No stored identity for ${remoteAddress.getName()}');
      return false;
    }
    
    // 4. Compare: Server's current key vs. our stored key
    final storedIdentityBytes = storedIdentity.serialize();
    final keysMatch = const ListEquality().equals(
      serverIdentityKeyBytes,
      storedIdentityBytes,
    );
    
    if (!keysMatch) {
      debugPrint(
        '[SIGNAL] ⚠️ Identity Key mismatch for ${remoteAddress.getName()}! '
        'Session is STALE (remote user regenerated keys)',
      );
      return false; // Session invalid
    }
    
    debugPrint('[SIGNAL] ✓ Session valid for ${remoteAddress.getName()}');
    return true; // Session is valid
    
  } catch (e) {
    debugPrint('[SIGNAL] Session validation failed: $e');
    return false; // On error, assume invalid
  }
}
```

### 2.2 Integrate Validation into sendItem()

**Location:** `signal_service.dart` → `sendItem()` (around line 3900)

**Before Encryption Loop:**
```dart
for (final bundle in bundles) {
  final deviceId = bundle['deviceId'] as int;
  final recipientUserId = bundle['userId'] as String;
  
  // Skip sender's own device
  if (deviceId == _currentDeviceId && recipientUserId == _currentUserId) {
    continue;
  }
  
  // ========================================
  // NEW: Validate session before encrypting
  // ========================================
  final remoteAddress = SignalProtocolAddress(recipientUserId, deviceId);
  
  final isSessionValid = await _validateSessionBeforeSend(
    remoteAddress,
    recipientUserId,
    deviceId,
  );
  
  if (!isSessionValid) {
    debugPrint(
      '[SIGNAL] Session invalid or missing for $recipientUserId:$deviceId, '
      'deleting old session and creating new one...',
    );
    
    // Delete stale session
    await sessionStore.deleteSession(remoteAddress);
    
    // Session will be created below with fresh PreKeyBundle
  }
  // ========================================
  
  // Existing session creation logic continues...
  if (!await sessionStore.containsSession(remoteAddress)) {
    // Create new session with PreKeyBundle
    // ...
  }
  
  // Encrypt with (now validated) session
  final sessionCipher = SessionCipher(/* ... */);
  final ciphertext = await sessionCipher.encrypt(/* ... */);
}
```

---

## Phase 3: Receiver-Side Automatic Recovery

### 3.1 Current Implementation (Already Working) ✓

The receiver already has automatic recovery via `handleUntrustedIdentity()`:

**Location:** `signal_service.dart` → `handleUntrustedIdentity()` (line ~6298)

**Current Flow:**
```dart
Future<T> handleUntrustedIdentity<T>(
  UntrustedIdentityException exception,
  Future<T> Function() retryOperation,
  bool sendNotification = false,
) async {
  // 1. Auto-trust the new Identity Key
  await identityStore.saveIdentity(address, newIdentityKey);
  
  // 2. Delete old session (forces new session creation)
  await sessionStore.deleteSession(address);
  
  // 3. Retry the operation (will create new session)
  return await retryOperation();
}
```

**This already handles:**
- Detecting Identity Key changes
- Auto-trusting new keys
- Deleting stale sessions
- Re-establishing sessions with new keys

### 3.2 Enhancement: Add Metrics/Logging

**Optional Improvement:**
```dart
// Track session invalidation events for monitoring
KeyManagementMetrics.recordSessionInvalidation(
  address.getName(),
  reason: 'Identity Key changed',
);
```

---

## Implementation Checklist

### ✅ Phase 1: Session Cleanup
- [x] Add `sessionStore.deleteAllSessions()` to `clearAllSignalData()`
- [x] Created `deleteAllSessionsCompletely()` in PermanentSessionStore
- [x] Test: Regenerate keys → verify all sessions deleted

### ✅ Phase 2: Session Validation
- [x] Server endpoint `/signal/status/minimal` already exists (verified in client.js)
  - Returns: `{ identityKey, signedPreKeyId, preKeyCount }`
- [x] Implemented `_validateSessionBeforeSend()` helper method
- [x] Integrated validation into `sendItem()` before encryption loop
- [x] Added `collection` package import for `ListEquality`
- [x] Sender key distribution already creates fresh sessions (no changes needed)

### ✅ Phase 3: Monitoring
- [x] Added `sessionsInvalidated` counter to `KeyManagementMetrics`
- [x] Added `recordSessionInvalidation()` method
- [x] Integrated metrics recording in `_validateSessionBeforeSend()`
- [x] Added session invalidation to metrics report and JSON output

## Implementation Summary

**Status:** ✅ **COMPLETE**

## Implementation Summary

**Status:** ✅ **COMPLETE**

All planned features have been implemented:

### Phase 1: Session Cleanup ✅
**File:** `client/lib/services/signal_service.dart`
- Added `deleteAllSessionsCompletely()` method to `PermanentSessionStore`
- Integrated into `clearAllSignalData()` - deletes all sessions when regenerating keys
- Sessions are now properly invalidated when Identity Key changes

### Phase 2: Session Validation ✅
**Files:** 
- `client/lib/services/signal_service.dart`
- `server/routes/client.js` (endpoint already existed)

**Changes:**
1. Added `_validateSessionBeforeSend()` helper method that:
   - Checks if session exists locally
   - Fetches server's current Identity Key via `/signal/status/minimal`
   - Compares stored Identity Key vs. server's current key
   - Returns `false` if keys don't match (stale session)

2. Integrated into `sendItem()` encryption loop:
   - Validates session before encrypting
   - Deletes stale sessions automatically
   - Creates fresh session with new PreKeyBundle
   - Logs all validation events for debugging

3. Added `collection` package import for `ListEquality` comparison

### Phase 3: Monitoring ✅
**File:** `client/lib/services/key_management_metrics.dart`
- Added `sessionsInvalidated` static counter
- Added `recordSessionInvalidation(address, reason)` method
- Integrated into `_validateSessionBeforeSend()` when Identity Key mismatch detected
- Updated `report()`, `reset()`, and `toJson()` to include session metrics

---

## Additional Questions & Answers

### Q1: Do we need session validation for sendGroupItem()?

**A:** **NO** - Group chats use **SenderKey protocol**, not 1:1 sessions.
- SenderKeys are distributed via Socket.IO broadcast (`broadcastSenderKey`)
- No 1:1 encryption for group messages
- **HOWEVER:** See Q3 below about regenerating SenderKeys when Identity changes

### Q2: Do we delete sessions when detecting corrupted keys and regenerating?

**Current Status:**
- ✅ `clearAllSignalData()` - **Deletes all sessions** (Phase 1 implementation)
- ⚠️ `_forceServerKeyReinforcement()` - **Does NOT delete sessions** (Missing!)
- ⚠️ Identity regeneration in `signal_setup_service.dart` - **Does NOT delete sessions** (Missing!)

**Answer:** **NEEDS FIX** - All key regeneration paths should delete sessions.

**Implementation needed:**
```dart
// In _forceServerKeyReinforcement() after re-uploading keys:
await sessionStore.deleteAllSessionsCompletely();
debugPrint('[SIGNAL] ✓ All sessions deleted after key reinforcement');

// In signal_setup_service.dart when clearing corrupted keys:
await SignalService.instance.sessionStore.deleteAllSessionsCompletely();
```

### Q3: Should we regenerate SenderKeys when Identity Key changes?

**A:** **YES!** - SenderKeys are cryptographically signed with the Identity Key.

**Problem:**
- SenderKey distribution messages contain Identity Key signatures
- If Identity Key changes, old SenderKeys have **invalid signatures**
- Recipients can't verify the sender's identity

**Solution:**
When Identity Key is regenerated, delete all SenderKeys and force recreation:

```dart
// In clearAllSignalData() or identity regeneration:
await senderKeyStore.deleteAllSenderKeys();
debugPrint('[SIGNAL] ✓ All SenderKeys deleted - will be regenerated on next group message');
```

**Impact:**
- Next group message will create fresh SenderKey with new Identity signature
- Minimal UX impact - handled transparently

### Q4: When we can't decrypt a message, should we delete session and request new bundle?

**A:** **PARTIALLY IMPLEMENTED** - Current code handles some cases, but missing key parts.

**Current Implementation (✅ Working):**
1. **NoSessionException** → Sends `sessionRecoveryNeeded` to sender
2. **InvalidMessageException (Bad MAC)** → Deletes session + sends recovery request
3. **UntrustedIdentityException** → Auto-trusts new identity + retries

**Missing (❌ Needs Implementation):**
1. **No system message to user** - Silent failures, user doesn't know message was lost
2. **Session not always deleted on all error types**
3. **No re-request of PreKeyBundle** - Assumes sender will resend, but doesn't fetch new bundle proactively

**Enhanced Implementation Needed:**

```dart
// In decryptItem() catch blocks:
catch (e) {
  debugPrint('[SIGNAL] ❌ Decryption failed: $e');
  
  // 1. Delete corrupted session
  await sessionStore.deleteSession(senderAddress);
  
  // 2. Send system message to UI
  _notifyDecryptionFailure(senderAddress, reason: e.toString());
  
  // 3. Request fresh PreKeyBundle (proactive)
  final newBundle = await fetchPreKeyBundleForUser(senderAddress.getName());
  
  // 4. Notify sender to resend
  SocketService().emit('sessionRecoveryNeeded', {
    'recipientUserId': _currentUserId,
    'recipientDeviceId': _currentDeviceId,
    'senderUserId': senderAddress.getName(),
    'senderDeviceId': senderAddress.getDeviceId(),
    'reason': 'DecryptionFailed',
    'errorType': e.runtimeType.toString(),
  });
  
  return '';
}
```

**UI System Message:**
```dart
void _notifyDecryptionFailure(SignalProtocolAddress sender, {required String reason}) {
  // Emit system message for UI
  if (_itemTypeCallbacks.containsKey('system')) {
    for (final callback in _itemTypeCallbacks['system']!) {
      callback({
        'type': 'decryptionFailure',
        'sender': sender.getName(),
        'deviceId': sender.getDeviceId(),
        'message': 'Could not decrypt message. Requesting sender to resend...',
        'reason': reason,
      });
    }
  }
}
```

---

## Summary of Findings

| Issue | Current Status | Needs Fix | Priority |
|-------|---------------|-----------|----------|
| Session validation in sendItem() | ✅ Implemented | - | - |
| Session cleanup in clearAllSignalData() | ✅ Implemented | - | - |
| Session cleanup in _forceServerKeyReinforcement() | ❌ Missing | ✅ Yes | **HIGH** |
| Session cleanup in signal_setup_service.dart | ❌ Missing | ✅ Yes | **HIGH** |
| SenderKey regeneration on Identity change | ❌ Missing | ✅ Yes | **MEDIUM** |
| Proactive PreKeyBundle fetch on decrypt failure | ❌ Missing | ✅ Yes | **MEDIUM** |
| User notification on decrypt failure | ❌ Missing | ✅ Yes | **LOW** |

---

## Testing Strategy

## Testing Strategy

### Test Case 1: Sender Regenerates Keys
```
1. Alice and Bob have established session
2. Alice regenerates Identity Key (calls clearAllSignalData())
3. Verify: Alice's sessionStore is empty
4. Alice sends message to Bob
5. Bob receives message → UntrustedIdentityException
6. Bob auto-trusts new key, deletes old session
7. Bob requests Alice's new PreKeyBundle
8. New session established → decryption succeeds
```

### Test Case 2: Receiver Regenerates Keys
```
1. Alice and Bob have established session
2. Bob regenerates Identity Key
3. Alice sends message to Bob
4. Alice's validation check: GET /signal/status/minimal?userId=Bob
5. Server returns Bob's NEW Identity Key
6. Alice detects mismatch: stored ≠ server
7. Alice deletes old session with Bob
8. Alice fetches Bob's new PreKeyBundle
9. New session created → encryption succeeds
10. Bob decrypts successfully with new keys
```

### Test Case 3: Session Corrupted
```
1. Alice and Bob have session
2. Database corruption: Bob's session has garbled data
3. Alice sends message
4. Validation passes (keys match), but session is corrupted
5. Bob tries to decrypt → Exception
6. Bob deletes corrupted session
7. Bob re-establishes session
8. Next message succeeds
```

---

## API Endpoint Specification

### New Endpoint: GET /signal/status/minimal

**Purpose:** Lightweight endpoint for session validation (no PreKeyBundle needed)

**Request:**
```
GET /signal/status/minimal?userId=<userId>&deviceId=<deviceId>
```

**Response:**
```json
{
  "identityKey": "base64_encoded_public_key",
  "signedPreKeyId": 123,
  "preKeysCount": 85,
  "lastKeyUpdate": "2025-12-21T10:30:00Z"
}
```

**Error Cases:**
- `404`: User/device not found or has no keys
- `500`: Server error

**Usage:**
- Called before sending to validate cached sessions
- Much lighter than fetching full PreKeyBundle
- Can be cached for 5-10 minutes to reduce server load

---

## Migration Strategy

### Phase 1 (Immediate):
1. Deploy `clearAllSignalData()` fix (delete sessions)
2. Deploy server endpoint `/signal/status/minimal`
3. No breaking changes (backward compatible)

### Phase 2 (Next Release):
1. Deploy `_validateSessionBeforeSend()` logic
2. Gradual rollout (feature flag for 10% → 50% → 100%)
3. Monitor error rates and session recreation frequency

### Phase 3 (Optimization):
1. Add caching layer for validation checks (reduce API calls)
2. Add batch validation endpoint for multiple devices
3. Add server-side session expiry hints (optimize rotation)

---

## Performance Considerations

### Validation Overhead:
- **Before:** 0 API calls (blindly use session)
- **After:** 1 API call per recipient (first send after app start)
- **Mitigation:** Cache validation results for 5-10 minutes

### Session Recreation Cost:
- Creating new session requires PreKeyBundle fetch
- But: Only happens when keys actually changed (rare event)
- Much better than silent decryption failures

### Database Operations:
- `sessionStore.deleteAllSessions()` is O(n) where n = session count
- But: Only called during key regeneration (rare)
- Average user has 5-20 sessions → <100ms operation

---

## Security Implications

### ✅ Improvements:
1. **Prevents stale session attacks:** Can't use old session after key rotation
2. **Detects MITM early:** Identity mismatch caught before encryption
3. **Enforces key freshness:** Sessions are validated, not assumed valid

### ⚠️ Considerations:
1. **Validation bypass:** If `/signal/status/minimal` returns stale data (caching), validation is ineffective
   - **Solution:** Server must invalidate cache on key upload
2. **Timing attacks:** Validation adds network latency before sending
   - **Mitigation:** Cache validation results (trade-off: freshness vs. speed)

---

## Questions Answered

### Q1: Do we notify the server when keys are regenerated?
**A:** No. The server doesn't manage sessions. Receiver detects key change via `UntrustedIdentityException` and recovers automatically.

### Q2: Do we check against the server for validation?
**A:** Yes. Server has current public Identity Key and SignedPreKey ID. This is the source of truth.

### Q3: What data do we need from server?
**A:** Identity Key + SignedPreKey ID is sufficient. We don't need PreKey because:
- PreKeys are one-time use (consumed during session creation)
- We only validate that the Identity Key hasn't changed
- SignedPreKey ID is optional (used as freshness hint)

### Q4: Do we need full PreKeyBundle for validation?
**A:** No. Full PreKeyBundle (Identity + SignedPreKey + PreKey) is only needed when **creating a new session**. For validation, Identity Key alone is sufficient.

---

## Summary

**Key Insight:** Signal Protocol sessions are **bound to the Identity Key** they were created with. If the remote Identity Key changes, the session is invalid.

**Solution:**
1. **On key regeneration:** Delete all local sessions (force fresh sessions)
2. **Before sending:** Validate session by comparing stored Identity Key vs. server's current Identity Key
3. **On validation failure:** Delete stale session, fetch fresh PreKeyBundle, create new session
4. **On receiving:** Existing `handleUntrustedIdentity()` already handles recovery

**Result:** Sessions are always validated before use, preventing silent decryption failures.

---

## Additional Scenarios & Edge Cases to Consider

### ⚠️ Scenario 1: SignedPreKey Rotation (Every 7 days)

**Problem:**
- SignedPreKey rotates automatically every 7 days
- Sessions created with old SignedPreKey might still be valid locally
- But server has new SignedPreKey ID

**Current Status:** ⚠️ **NEEDS INVESTIGATION**

**Question:**
- Do sessions need to be recreated when SignedPreKey rotates?
- Answer: **NO** - Sessions are bound to Identity Key, not SignedPreKey
- SignedPreKey is only used during **session establishment** (PreKey message)
- Existing sessions continue to work with the Session Key derived during initial handshake

**Action:** ✅ No changes needed - SignedPreKey rotation doesn't affect existing sessions

---

### ⚠️ Scenario 2: PreKey Exhaustion & Bulk Regeneration

**Problem:**
- User has <20 PreKeys remaining
- Bulk regeneration triggers (e.g., 50 new PreKeys)
- PreKey IDs may overlap or conflict with existing sessions

**Current Status:** ⚠️ **PARTIALLY HANDLED**

**Existing Implementation:**
- PreKeys regenerated asynchronously when consumed
- Server tracks which PreKeys are consumed
- PreKey IDs are incremental (no collision)

**Missing:**
- ❌ What if all PreKeys consumed while offline?
- ❌ What if server has consumed PreKeys but client doesn't know?
- ❌ No session cleanup when PreKeys regenerated in bulk

**Recommendation:**
```dart
// When regenerating PreKeys in bulk (e.g., <20 remaining):
// 1. Do NOT delete sessions - PreKeys are one-time use, sessions independent
// 2. Sync consumed PreKey IDs from server before regenerating
// 3. Generate new PreKeys with IDs that don't conflict
```

**Action:** ✅ Current implementation is correct - no changes needed

---

### ✅ Scenario 3: Device Registration/Unregistration

**Problem:**
- Alice has Device 1 and Device 2
- Bob has session with Alice Device 2
- Alice logs out Device 2 (device unregistered)
- Bob tries to send to Alice Device 2 → message lost

**Current Status:** ✅ **HANDLED (Reactive Approach)**

**Solution: Validation-Based Cleanup (No Broadcasting)**

**Why not broadcast?**
- Broadcasting device removal to all users creates massive traffic
- Scales poorly with large user bases
- Most sessions are with users you rarely message

**Better approach: Reactive cleanup on send**
```dart
// In _validateSessionBeforeSend():
// 1. Check if device still has keys on server
final response = await ApiService.get('/signal/status/minimal?userId=X&deviceId=Y');

if (response.data['identityKey'] == null) {
  // Device removed or no keys uploaded
  await sessionStore.deleteSession(remoteAddress);
  debugPrint('Device no longer exists - session deleted');
  return false; // Skip this device
}

// 2. In sendItem(), skip devices that fail validation
if (!isSessionValid) {
  // Check if device exists
  if (deviceHasNoKeys) {
    skippedCount++;
    continue; // Skip to next device, don't try to create session
  }
}
```

**Benefits:**
- No broadcast storm
- Sessions cleaned up only when needed (lazy deletion)
- Natural cleanup during normal usage
- Handles 404 errors gracefully

**Implementation:** ✅ Complete
- Session validation detects missing keys
- Deletes session automatically
- Skips removed devices in send loop

**Priority:** ✅ IMPLEMENTED - No action needed

---

### ✅ Scenario 4: Sender Key Chain Desynchronization

**Problem:**
- Group chat with 5 members
- Member A sends message 1, 2, 3
- Member B misses message 2 (network issue)
- Member B receives message 3 → Chain number mismatch → Decryption fails

**Current Status:** ✅ **IMPLEMENTED**

**Signal Protocol Behavior:**
- Sender Keys use chain counters that must increment sequentially (1 → 2 → 3 → 4...)
- Each message derives encryption key from previous message's state
- If you skip a counter, key derivation breaks → permanent failure

**Example:**
```
Alice sends:
├─ Message 1 (counter: 1) → Bob decrypts ✓
├─ Message 2 (counter: 2) → ❌ Network packet dropped
└─ Message 3 (counter: 3) → Bob's state expects counter=2 → FAIL

Bob's state: "Next expected = 2"
Message 3:    "My counter is 3"
Result:       Mismatch! DecryptionException
```

**Recovery Implementation:**
```dart
// In decryptGroupMessage():
catch (e) {
  if (e.toString().contains('chain') || 
      e.toString().contains('counter')) {
    debugPrint('[SIGNAL] Chain desync detected');
    
    // 1. Delete corrupted sender key
    await senderKeyStore.removeSenderKey(senderKeyName);
    
    // 2. Request fresh sender key from server
    await loadSenderKeyFromServer(
      channelId: groupId,
      userId: senderId,
      deviceId: senderDeviceId,
      forceReload: true,
    );
    
    // 3. Send encrypted 1:1 message to sender asking to resend
    await sendItem(
      recipientUserId: senderId,
      type: 'group_message_recovery',
      payload: jsonEncode({
        'action': 'resend_last_message',
        'channelId': groupId,
        'reason': 'chain_desync',
        'message': 'Could not decrypt your last message. Please resend.',
      }),
    );
    
    // 4. Notify local user
    _notifyDecryptionFailure(sender, reason: 'Chain desync - sender notified');
  }
}
```

**Benefits:**
- Automatic detection of chain errors
- Fresh sender key loaded from server
- Sender receives encrypted notification to resend
- Current message lost, but future messages work
- No manual intervention needed

**Implementation:** ✅ Complete in [decryptGroupMessage()](signal_service.dart#L5535-L5640)

**Priority:** ✅ IMPLEMENTED

---

### ⚠️ Scenario 5: Concurrent Key Regeneration (Race Condition)

**Problem:**
- Alice Device 1 and Alice Device 2 both online
- Both detect corrupted keys simultaneously
- Both call `clearAllSignalData()` and regenerate
- Race condition: Which device's keys end up on server?

**Current Status:** ❌ **NOT HANDLED**

**Missing:**
- No locking mechanism for key regeneration
- No coordination between devices
- Last-write-wins → potential inconsistency

**Recommendation:**
```dart
// In clearAllSignalData() or key regeneration:
// 1. Acquire distributed lock via server
final lockAcquired = await ApiService.post('/signal/acquire-key-lock', {
  'userId': _currentUserId,
  'deviceId': _currentDeviceId,
  'ttl': 30, // 30 second lock
});

if (!lockAcquired.data['success']) {
  debugPrint('[SIGNAL] Another device is regenerating keys - waiting...');
  await Future.delayed(Duration(seconds: 5));
  // Fetch keys from server instead of regenerating
  return;
}

// Proceed with regeneration...

// Release lock
await ApiService.post('/signal/release-key-lock', {...});
```

**Priority:** LOW - Rare scenario, but could cause subtle bugs

---

### ⚠️ Scenario 6: Partial Key Upload Failure

**Problem:**
- Identity Key uploaded successfully
- Network failure before PreKeys uploaded
- Server has Identity but no PreKeys
- Other users fetch PreKeyBundle → incomplete bundle → session creation fails

**Current Status:** ⚠️ **PARTIALLY HANDLED**

**Existing Implementation:**
- `_ensureSignalKeysPresent()` validates server has all keys
- Auto-recovery uploads missing keys

**Missing:**
- ❌ No atomic transaction for key upload
- ❌ If SignedPreKey uploads but PreKeys fail, server in inconsistent state
- ❌ Other users might fetch incomplete bundle before auto-recovery

**Recommendation:**
```dart
// Server-side: Use database transaction for key uploads
// Ensure all keys uploaded atomically or none
await sequelize.transaction(async (t) => {
  await Client.update({public_key: ...}, {transaction: t});
  await SignalSignedPreKey.create({...}, {transaction: t});
  await SignalPreKey.bulkCreate([...], {transaction: t});
});

// Client-side: Validate upload completion
const uploadResult = await ApiService.post('/signal/upload-keys-atomic', {
  identity: {...},
  signedPreKey: {...},
  preKeys: [...]
});

if (!uploadResult.data['success']) {
  // Rollback local state
  await clearAllSignalData(reason: 'Upload failed - rollback');
  throw Exception('Key upload failed');
}
```

**Priority:** MEDIUM - Prevents incomplete key bundles

---

### ⚠️ Scenario 7: Clock Skew / Time-Based Key Rotation

**Problem:**
- Device clock is 1 week in the future
- SignedPreKey rotation triggers immediately (thinks 7 days passed)
- Device clock corrected → rotation timestamps are now in the "future"
- Confusion in rotation logic

**Current Status:** ⚠️ **POTENTIAL ISSUE**

**Existing Implementation:**
- Rotation uses `DateTime.now().difference(lastRotation)`
- If clock changes, rotation might trigger incorrectly

**Recommendation:**
```dart
// Use server time for rotation decisions instead of local time
final serverTimeResponse = await ApiService.get('/api/server-time');
final serverTime = DateTime.parse(serverTimeResponse.data['timestamp']);

// Check rotation using server time
final lastRotation = DateTime.parse(metadata['lastRotation']);
final age = serverTime.difference(lastRotation);
if (age.inDays >= 7) {
  // Rotate SignedPreKey
}
```

**Priority:** LOW - Most users have accurate clocks

---

### ⚠️ Scenario 8: Session Corruption During Active Conversation

**Problem:**
- Alice and Bob actively chatting
- Bob sends message → Alice session corrupted mid-flight
- Alice receives message → Decryption fails
- Alice's error handler deletes session and notifies Bob
- But Bob already sent 3 more messages (in-flight)
- All 3 messages will fail → Multiple recovery notifications → Spam

**Current Status:** ✅ **HANDLED (Correctly)**

**Why Server-Side Buffering WON'T Work:**

❌ **WRONG APPROACH (Original idea):**
```
Server buffers encrypted messages during recovery
→ After new session established, deliver buffered messages
→ FAILS: Messages encrypted with OLD session keys
→ Cannot decrypt with NEW session keys
```

**Why this fails:**
- Bob encrypted messages with `SESSION_KEY_OLD` (Double Ratchet state)
- Alice deleted corrupted session → Lost `SESSION_KEY_OLD`
- New session creates `SESSION_KEY_NEW` (completely different keys)
- Old messages are **cryptographically incompatible** with new session
- **Messages are permanently lost**

✅ **CORRECT APPROACH (Current implementation):**

**Existing Implementation:**
- Loop prevention: Only one recovery notification per 30 seconds ✓
- Prevents spam ✓
- In-flight messages are lost (unavoidable) ✓

**Enhanced Notification Strategy:**
```dart
// In Alice's error handler (already implemented):
catch (decryptionError) {
  // Rate limiting check
  if (lastRecoveryTime != null && 
      DateTime.now().difference(lastRecoveryTime).inSeconds < 30) {
    return ''; // Skip notification, already sent recently
  }
  
  // 1. Delete corrupted session
  await sessionStore.deleteSession(bobAddress);
  
  // 2. Send recovery notification to Bob (once)
  SocketService().emit('sessionRecoveryNeeded', {
    'recipientUserId': alice.userId,
    'senderUserId': bob.userId,
    'senderDeviceId': bob.deviceId,
    'reason': 'Session corrupted - please resend recent messages',
    'messagesLost': true, // ← Indicate messages were lost
  });
  
  // 3. Notify Alice's UI
  _notifyDecryptionFailure(bobAddress, 
    reason: 'Session corrupted - asked sender to resend',
  );
}

// Bob receives notification:
SocketService().on('sessionRecoveryNeeded', (data) {
  if (data['messagesLost'] == true) {
    // Show UI notification: "Your last few messages may not have been delivered"
    // User can manually resend if important
    showNotification(
      'Connection issue with ${data.recipientName}',
      'Your recent messages may need to be resent',
      action: 'View Conversation',
    );
  }
});
```

**Result:**
- ✅ No server-side buffering (impossible to decrypt anyway)
- ✅ Single recovery notification (spam prevented)
- ✅ Clear user feedback (Bob knows messages may be lost)
- ✅ Bob can manually resend important messages
- ✅ Honest UX: System doesn't pretend messages can be recovered

**Trade-offs:**
- **Lost messages:** Unavoidable with session corruption
- **Manual resend:** User must check and resend if needed
- **Alternative:** Keep chat history locally and auto-resend last N messages (but requires client-side buffering before encryption)

**Priority:** ✅ IMPLEMENTED - Current approach is correct

---

### ⚠️ Scenario 9: External Guest Session Expiration

**Problem:**
- External guest joins meeting (no account)
- Guest has Signal keys stored in sessionStorage
- Guest closes tab → Keys lost
- Guest rejoins same meeting → Different session ID → New keys
- Participants have stale sessions with old guest session ID

**Current Status:** ⚠️ **POTENTIAL ISSUE**

**Existing Implementation:**
- Guest keys in sessionStorage (lost on tab close)
- `clearGuestSessions()` called on meeting end

**Missing:**
- ❌ No TTL for guest sessions
- ❌ No cleanup if guest disconnects abruptly
- ❌ Participants might have orphaned sessions

**Recommendation:**
```dart
// Server-side: Track guest session lifetime
// Auto-cleanup after 1 hour or on disconnect
io.on('disconnect', (socket) => {
  if (socket.isGuest) {
    // Notify participants to delete guest session
    io.to(socket.meetingId).emit('guestDisconnected', {
      guestSessionId: socket.guestSessionId,
    });
    
    // Delete guest keys from server
    await deleteGuestKeys(socket.guestSessionId);
  }
});

// Client-side: Listen and cleanup
SocketService().on('guestDisconnected', (data) => {
  final address = SignalProtocolAddress(data['guestSessionId'], 1);
  await sessionStore.deleteSession(address);
});
```

**Priority:** LOW - Guest meetings are temporary

---

### ⚠️ Scenario 10: Database Corruption Detection

**Problem:**
- SQLite database corrupted (disk error, power loss)
- Decryption keys can't be retrieved
- All sessions fail to load
- No automatic recovery

**Current Status:** ❌ **NOT HANDLED**

**Recommendation:**
```dart
// Add database integrity check on startup
Future<bool> validateDatabaseIntegrity() async {
  try {
    final db = await DatabaseHelper.database;
    
    // SQLite PRAGMA integrity_check
    final result = await db.rawQuery('PRAGMA integrity_check');
    
    if (result.first['integrity_check'] != 'ok') {
      debugPrint('[DATABASE] Corruption detected!');
      
      // Backup corrupted database
      await _backupCorruptedDatabase();
      
      // Delete and recreate
      await DatabaseHelper.deleteDatabaseFile();
      
      // Trigger full key regeneration
      await SignalService.instance.clearAllSignalData(
        reason: 'Database corruption detected',
      );
      
      return false;
    }
    return true;
  } catch (e) {
    debugPrint('[DATABASE] Integrity check failed: $e');
    return false;
  }
}
```

**Priority:** LOW - Rare but catastrophic

---

## Summary Table: Additional Scenarios

| Scenario | Current Status | Needs Fix | Priority | Impact |
|----------|---------------|-----------|----------|--------|
| SignedPreKey rotation | ✅ Handled | No | N/A | None |
| PreKey exhaustion | ✅ Handled | No | N/A | None |
| Device unregistration | ✅ Implemented | No | N/A | None |
| Sender key chain desync | ✅ Implemented | No | N/A | None |
| Concurrent key regeneration | ✅ Not a problem | No | N/A | No collision (device-scoped) |
| Partial key upload | ✅ Verified | No | N/A | HTTP response checked |
| Clock skew | ✅ Not a problem | No | N/A | More rotations acceptable |
| Mid-conversation corruption | ✅ Handled correctly | No | N/A | Unavoidable loss |
| Guest session expiration | ✅ Not a problem | No | N/A | Keys only for e2ee exchange |
| Database corruption | ✅ Detected & handled | No | N/A | Auto-regenerates all keys |

---

## Recommended Next Steps

### **High Priority:**
1. **Sender key chain desync** - Add recovery mechanism for out-of-order group messages
2. **Session validation caching** - Cache validation results for 5-10 minutes to reduce API calls

### **Medium Priority:**
3. **Device unregistration** - Broadcast device removal and cleanup sessions
4. **Partial key upload** - Make key upload atomic (server-side transaction)
5. **Mid-conversation corruption** - Buffer messages during session recovery

### **Low Priority:**
6. **Concurrent key regeneration** - Add distributed locking
7. **Clock skew** - Use server time for rotation decisions
8. **Guest session cleanup** - Add TTL and disconnect handlers
9. **Database corruption** - Add integrity checks on startup

---

## Testing Strategy
