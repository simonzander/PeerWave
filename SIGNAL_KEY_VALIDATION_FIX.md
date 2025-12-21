# Signal Protocol Key Validation Fix

## Problem Analysis

From the logs, we see:
```
[SIGNAL SERVICE] ! Device X has no keys - skipping
[SIGNAL SERVICE] Device was likely unregistered/logged out
```

This means:
1. Bundles are being fetched successfully (validation passes)
2. But when checking `/ signal/status/minimal`, the server reports NO identity key
3. Messages fail because all devices are skipped

## Root Causes

### 1. **No Self-Verification on Startup**
- We don't verify OUR OWN keys are uploaded to the server after initialization
- If our keys fail to upload, we won't know until someone tries to send us a message

### 2. **Late Validation**
- We validate sessions AFTER fetching bundles
- Should check if recipient has keys BEFORE fetching (save network round-trip)

### 3. **Missing Pre-Send Check**
- No comprehensive check that sender's keys are valid before attempting encryption

## Solutions Implemented

### 1. ✅ Added `verifyOwnKeysOnServer()` Function
Location: `signal_service.dart` after `_checkSignedPreKeyRotation()`

Verifies:
- Our identity key is uploaded and matches local
- Our SignedPreKey exists and signature is valid
- We have adequate PreKeys (>= 10)

Call this:
- After `initWithProgress()` completes
- Periodically (e.g., on app resume)
- Before sending first message in a session

### 2. ⚠️ TODO: Call Self-Verification After Init

Add to `initWithProgress()`:
```dart
// After SocketService().notifyClientReady()
// Wait a bit for server to process
await Future.delayed(Duration(seconds: 2));

// Verify our own keys are on server
final keysValid = await verifyOwnKeysOnServer();
if (!keysValid) {
  debugPrint('[SIGNAL INIT] ⚠️ Self-verification failed - keys may not be uploaded');
  debugPrint('[SIGNAL INIT] → Will retry key upload...');
  
  try {
    await _uploadKeysOnly();
    await Future.delayed(Duration(milliseconds: 500));
    
    // Verify again
    final retryValid = await verifyOwnKeysOnServer();
    if (!retryValid) {
      throw Exception('Failed to upload keys to server. Please try logging out and back in.');
    }
    debugPrint('[SIGNAL INIT] ✓ Keys uploaded and verified on retry');
  } catch (e) {
    debugPrint('[SIGNAL INIT] ❌ Key upload retry failed: $e');
    rethrow;
  }
}
```

### 3. ⚠️ TODO: Add Quick Recipient Key Check

Before fetching bundles in `sendItem()`, add fast check:

```dart
/// Quick check if recipient has ANY keys on server (before fetching bundles)
/// Returns true if recipient has keys, false otherwise
Future<bool> _recipientHasKeys(String userId) async {
  try {
    // First, get list of devices for this user
    final response = await ApiService.get('/signal/devices/$userId');
    final devices = response.data as List;
    
    if (devices.isEmpty) {
      debugPrint('[SIGNAL] Recipient $userId has no registered devices');
      return false;
    }

    // Check if at least ONE device has keys
    for (final device in devices) {
      final deviceId = device['device_id'];
      
      try {
        final statusResponse = await ApiService.get(
          '/signal/status/minimal',
          queryParameters: {
            'userId': userId,
            'deviceId': deviceId.toString(),
          },
        );
        
        final identityKey = statusResponse.data['identityKey'];
        if (identityKey != null) {
          debugPrint('[SIGNAL] ✓ Recipient $userId has keys on device $deviceId');
          return true; // Found at least one device with keys
        }
      } catch (e) {
        // Device might be 404, continue checking others
        continue;
      }
    }
    
    debugPrint('[SIGNAL] ❌ Recipient $userId has NO devices with keys');
    return false;
  } catch (e) {
    debugPrint('[SIGNAL] Error checking recipient keys: $e');
    return false; // Assume no keys on error to be safe
  }
}
```

Then in `sendItem()` before `fetchPreKeyBundleForUser()`:

```dart
// BEFORE: final preKeyBundles = await fetchPreKeyBundleForUser(recipientUserId);

// Quick check: Does recipient have ANY keys?
debugPrint('[SIGNAL SERVICE] Step 0c: Checking if recipient has keys...');
final recipientHasKeys = await _recipientHasKeys(recipientUserId);
if (!recipientHasKeys) {
  debugPrint('[SIGNAL SERVICE] ❌ Recipient $recipientUserId has no keys on server');
  throw Exception(
    'Recipient has not set up encryption keys. '
    'They need to log out and back in to generate Signal keys.'
  );
}
debugPrint('[SIGNAL SERVICE] ✓ Recipient has keys, proceeding with bundle fetch');

// NOW fetch bundles
final preKeyBundles = await fetchPreKeyBundleForUser(recipientUserId);
```

### 4. ⚠️ TODO: Server-Side Fix Needed

The server endpoint `/signal/prekey_bundle/:userId` should:

**Current behavior:**
- Returns bundles for devices even if they have NO keys uploaded

**Should be:**
- Only return devices that have complete PreKey bundles
- Filter out devices with missing keys at the database query level

Example SQL fix (server-side):
```sql
SELECT * FROM signal_identity 
WHERE user_id = ? 
AND public_key IS NOT NULL 
AND signed_prekey_data IS NOT NULL 
AND EXISTS (
  SELECT 1 FROM signal_prekeys 
  WHERE signal_prekeys.clientid = signal_identity.clientid 
  LIMIT 1
)
```

## Testing Checklist

- [ ] After login, verify `verifyOwnKeysOnServer()` returns true
- [ ] Try sending message to user who never logged in → should see clear error
- [ ] Try sending message to user who logged out → should see keys missing error
- [ ] Simulate key upload failure → verify retry logic works
- [ ] Check logs for self-verification after init
- [ ] Verify no more "Device X has no keys" errors for valid users

## Implementation Priority

1. **HIGH**: Add `verifyOwnKeysOnServer()` call after `initWithProgress()` (prevents "I have no keys" issues)
2. **HIGH**: Add `_recipientHasKeys()` check before bundle fetch (prevents "recipient has no keys" issues)
3. **MEDIUM**: Server-side filter for `/signal/prekey_bundle/:userId` (optimization)
4. **LOW**: Add periodic self-verification on app resume (nice-to-have)

## Expected Behavior After Fix

**Before:**
```
[SIGNAL SERVICE] Encrypting for device: X:1
[VALIDATION] ✓ Bundle valid
[SIGNAL SERVICE] Session invalid or missing
[SERVER] Device X:1 has no keys - skipping
[SIGNAL SERVICE] Message send failed - all devices had issues
```

**After:**
```
[SIGNAL INIT] Self-verification starting...
[SIGNAL INIT] ✓ All keys verified successfully
[SIGNAL SERVICE] Checking if recipient has keys...
[SIGNAL SERVICE] ✓ Recipient has keys, proceeding
[SIGNAL SERVICE] Encrypting for device: X:1
[SIGNAL SERVICE] ✓ Send complete: 1 succeeded
```
