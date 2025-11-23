# Multi-Device Key Exchange Fix

## Problems Identified

### 1. **Same-User Key Exchange Blocked**
**Location**: `message_listener_service.dart` line 533-537

**Issue**: Code was checking if `requesterId == currentUserId || senderId == currentUserId` and ignoring the message. This breaks multi-device scenarios where the same user has web + native clients.

**Fix**: Check BOTH user ID AND device ID. Only ignore if it's from the exact same device (true echo).

```dart
// ❌ BEFORE (Wrong):
if (requesterId == currentUserId || senderId == currentUserId) {
  return; // Blocks all messages from same user, including other devices!
}

// ✅ AFTER (Correct):
if (requesterId == currentUserId && senderDeviceId == currentDeviceId) {
  return; // Only blocks same device
}
```

### 2. **Flutter Secure Storage File Locking (Windows)**
**Location**: `secure_session_storage.dart`

**Issue**: Windows locks the `flutter_secure_storage.dat` file causing:
```
Error 0x00000000: Failure on CryptUnprotectData()
PathAccessException: Cannot delete file (OS Error: errno = 32)
```

**Fix**: Added retry logic with 100ms delays for read/write operations.

### 3. **Sender Key Distribution for New Members**
**Issue**: When a native client joins a channel later, they don't have the sender keys from existing participants.

**Root Cause**: 
- Web clients load sender keys via REST API when opening a channel
- Native clients might join a video conference without opening the chat first
- No automatic sender key distribution on channel membership

**Solution Needed**: Implement automatic sender key distribution when:
1. A new member joins a channel
2. A user adds a new device to their account
3. Video conference starts (pre-join phase)

## Implementation Status

### ✅ Completed
1. Multi-device key exchange filter fixed
2. Flutter secure storage retry logic added
3. Video key request/response skips database storage

### 🚧 In Progress
Sender key distribution for new channel members needs server-side support.

## Sender Key Distribution Architecture

### Current Flow (Works for web):
```
1. User opens channel chat
2. Client calls GET /api/sender-keys/:channelId
3. Server returns all sender keys for that channel
4. Client processes and stores keys locally
5. Can now decrypt messages
```

### Problem with Native Video Calls:
```
1. Native client joins video pre-join screen
2. Sends video_e2ee_key_request
3. Another participant tries to respond
4. ❌ Cannot encrypt response - no sender key!
```

### Solution Options:

#### Option A: Load Sender Keys on Channel Join (REST API)
**When**: Native client navigates to any channel view
**How**: Call GET `/api/sender-keys/:channelId` automatically
**Pros**: Simple, uses existing API
**Cons**: Need to ensure it's called before video join

#### Option B: Automatic Distribution on Member Add
**When**: Server detects new channel member
**How**: Server pushes sender keys via Socket.IO
**Pros**: Fully automatic
**Cons**: More complex, requires server changes

#### Option C: On-Demand via Socket.IO
**When**: Client detects missing sender key
**How**: Request specific key via socket event
**Pros**: Efficient, only loads what's needed
**Cons**: Adds latency to first decrypt

## Recommended Implementation: Hybrid Approach

### 1. Pre-load sender keys when joining video conference
```dart
// In video_conference_prejoin_view.dart
await _ensureSenderKeysLoaded(channelId);
```

### 2. Request missing keys on decrypt failure
```dart
// In signal_service.dart decryptGroupItem()
if (error.contains('No sender key')) {
  await requestSenderKeyFromServer(channelId, senderId, senderDeviceId);
}
```

### 3. Distribute keys when new member joins
```javascript
// In server.js when channel member added
socket.on('join_channel', async (channelId) => {
  // Distribute existing sender keys to new member
  await distributeExistingSenderKeys(socket, channelId);
});
```

## Testing Scenarios

### Multi-Device Key Exchange
- [ ] Web device A requests key from Web device B (same user)
- [ ] Native device A requests key from Web device B (same user)
- [ ] Native device A requests key from Native device B (same user)
- [ ] Verify only same-device echo is ignored

### New Channel Member
- [ ] User A creates channel
- [ ] User B joins channel  
- [ ] User A sends message
- [ ] ✅ User B can decrypt (has sender key)
- [ ] User B sends message
- [ ] ✅ User A can decrypt (has sender key)

### New Device Added
- [ ] User has web device connected
- [ ] User adds native device
- [ ] Native device joins existing channel
- [ ] ✅ Can decrypt messages from web device
- [ ] ✅ Web device can decrypt messages from native

### Video Conference Scenarios
- [ ] Native joins video channel (first time)
- [ ] Loads sender keys before requesting E2EE key
- [ ] ✅ Can decrypt key response
- [ ] ✅ Can join LiveKit room with E2EE

## Code Changes Made

### 1. `message_listener_service.dart`
```dart
// Line 529-544: Fixed multi-device filtering
// Now checks both user ID AND device ID
// Only ignores true echo (same device), not same user
```

### 2. `secure_session_storage.dart`
```dart
// Added retry logic for Windows file locking:
// - 3 retries with 100ms delay
// - Graceful fallback on read failure
// - Better error handling
```

### 3. `signal_service.dart`
```dart
// Line 2900: Added to SKIP_STORAGE_TYPES:
'video_e2ee_key_request',
'video_e2ee_key_response', 
'video_key_request',
'video_key_response',
```

## Next Steps

1. **Add sender key pre-loading to video pre-join view**
   - Call GET `/api/sender-keys/:channelId` 
   - Process all keys before allowing join

2. **Implement automatic sender key distribution**
   - Server emits `senderKeyDistribution` when new member joins
   - Client processes automatically

3. **Add sender key request/response via Socket.IO**
   - New events: `request_sender_key` / `sender_key_response`
   - Allows on-demand key loading

4. **Test all multi-device scenarios**
   - Verify web-to-native, native-to-web, native-to-native
   - Test with 3+ devices per user

## Files Modified
- `client/lib/services/message_listener_service.dart`
- `client/lib/services/secure_session_storage.dart`
- `client/lib/services/signal_service.dart`
- `client/lib/services/socket_service.dart`
