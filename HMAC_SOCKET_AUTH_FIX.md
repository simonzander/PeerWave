# HMAC Socket Authentication Fix

## Problem Identified

The native client was sending video E2EE key requests, but the server was rejecting them with:
```
[GROUP ITEM] ERROR: Not authenticated
```

**Root Cause**: The Socket.IO connection from native clients was not authenticating properly because:
1. The client was sending `null` in the `authenticate` event instead of HMAC credentials
2. Video key requests were being stored in the database unnecessarily

## Changes Made

### 1. Socket.IO HMAC Authentication (`socket_service.dart`)

**Added imports:**
```dart
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'session_auth_service.dart';
import 'clientid_native.dart' if (dart.library.js) 'clientid_web_stub.dart';
```

**Added `_authenticateSocket()` method:**
- Detects platform (web vs native)
- Web: Uses cookie-based session authentication (existing behavior)
- Native: Generates HMAC signature for socket authentication
  - Gets client ID and session secret
  - Creates nonce and timestamp
  - Signs the message: `{clientId}:{timestamp}:{nonce}:/socket.io/auth:`
  - Sends authentication data with signature

**Updated connection flow:**
- `connect` event → calls `_authenticateSocket()`
- `reconnect` event → calls `_authenticateSocket()`
- Manual `authenticate()` → calls `_authenticateSocket()`

### 2. Skip Storage for Video Key Exchange (`signal_service.dart`)

Added ephemeral message types to skip storage:
```dart
const SKIP_STORAGE_TYPES = {
  'fileKeyResponse',
  'senderKeyDistribution',
  'video_e2ee_key_request',   // NEW
  'video_e2ee_key_response',  // NEW
  'video_key_request',        // NEW (legacy)
  'video_key_response',       // NEW (legacy)
};
```

**Why skip storage?**
- Key exchange messages are ephemeral
- They're only needed during the initial handshake
- No need to persist in database
- Reduces database overhead

## How It Works

### Socket Authentication Flow (Native)

1. **Socket connects** → `connect` event fires
2. **Generate HMAC signature**:
   ```
   Message: {clientId}:{timestamp}:{nonce}:/socket.io/auth:
   Signature: HMAC-SHA256(sessionSecret, message)
   ```
3. **Send to server**:
   ```javascript
   socket.emit('authenticate', {
     'X-Client-ID': clientId,
     'X-Timestamp': timestamp,
     'X-Nonce': nonce,
     'X-Signature': signature,
   });
   ```
4. **Server validates**:
   - Checks timestamp (±5 minutes)
   - Validates nonce (no replay attacks)
   - Verifies signature matches session secret
   - Sets `socket.data.sessionAuth = true`

5. **Client receives confirmation**:
   ```javascript
   socket.on('authenticated', (data) => {
     // data.authenticated === true
     // data.uuid === user ID
     // data.deviceId === device ID
   });
   ```

### Video Key Exchange Flow (After Fix)

1. **Join request** → First participant generates E2EE key
2. **Second participant joins** → Sends `video_e2ee_key_request`
   - ✅ Now authenticated via HMAC
   - ✅ No longer stored in database
   - ✅ Server forwards to channel participants
3. **First participant responds** → Sends `video_e2ee_key_response`
   - ✅ Encrypted with recipient's public key
   - ✅ No longer stored in database
4. **Both have keys** → Can join LiveKit room with E2EE enabled

## Testing Checklist

- [ ] Native to Native video calls with E2EE
- [ ] Native to Web video calls with E2EE
- [ ] Web to Native video calls with E2EE
- [ ] Multiple participants joining
- [ ] Reconnection scenarios
- [ ] Session expiry handling

## Expected Server Logs

**Before fix:**
```
[GROUP ITEM] ERROR: Not authenticated
```

**After fix:**
```
[SIGNAL SERVER] authenticate event received
[SIGNAL SERVER] Native client detected, using HMAC auth
[SIGNAL SERVER] Authentication successful for native client
authenticated: true, uuid: <user-id>, deviceId: <device-id>
[GROUP ITEM] Received group item from <user-id>
```

## What's Left to Investigate

1. **Session persistence** - Sessions may need refresh mechanism
2. **Reconnection** - Verify HMAC auth works after disconnect/reconnect
3. **Multiple devices** - Test same user on multiple native devices
4. **Session rotation** - Implement periodic session secret rotation
5. **Error handling** - Better error messages for auth failures

## Related Files

- `client/lib/services/socket_service.dart` - Socket connection + HMAC auth
- `client/lib/services/signal_service.dart` - Message sending + storage logic
- `client/lib/services/session_auth_service.dart` - HMAC signature generation
- `client/lib/services/video_conference_service.dart` - E2EE key exchange
- `server/server.js` - Socket authentication handling

## Notes

- Web clients still use cookie-based authentication (unchanged)
- Native clients now properly authenticate with HMAC signatures
- Video key exchange is now truly ephemeral (not persisted)
- This follows the same pattern as HTTP API requests (HMAC + headers)
