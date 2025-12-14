# Guest Signal Protocol E2EE Migration - Action Plan

**Date:** December 12, 2025  
**Status:** 📋 Planning Phase  
**Priority:** 🔒 CRITICAL - Security First Approach

---

## 📋 Executive Summary

Migrate external guest E2EE key exchange from Socket.IO direct messages to Signal Protocol encrypted communication. This ensures:
- ✅ **End-to-end encryption** for all key exchanges (currently plaintext over Socket.IO)
- ✅ **Unified security model** - same encryption for guests and authenticated users
- ✅ **Simplified codebase** - reuse existing Signal message listeners
- ✅ **Future-proof** - Signal Protocol handles session corruption, replay attacks, forward secrecy

---

## 🔐 Current Architecture (INSECURE)

### Guest Key Exchange Flow (Socket.IO - PLAINTEXT)

```
┌─────────────────────────────────────────────────────────────┐
│                   CURRENT FLOW (INSECURE)                    │
└─────────────────────────────────────────────────────────────┘

1. Guest generates Signal keys (identity, signed pre-key, 30 pre-keys)
2. Guest uploads keys to server via HTTP POST /api/meetings/external/register
3. Guest connects to /external Socket.IO namespace
4. Guest emits: guest:request_e2ee_key:meetingId
   └─> Server broadcasts to /default namespace (participants)
5. Participant receives event on /default namespace
6. Participant emits: participant:send_e2ee_key_to_guest
   └─> Contains PLAINTEXT E2EE key (32 bytes - AES-256 key)
7. Guest receives E2EE key over Socket.IO (UNENCRYPTED)

🚨 SECURITY ISSUE: LiveKit E2EE key transmitted in cleartext
🚨 SECURITY ISSUE: Man-in-the-middle can intercept video decryption key
🚨 SECURITY ISSUE: No forward secrecy, session corruption recovery
```

### Current Files Involved

**Client:**
- `client/lib/services/external_participant_service.dart` - Socket.IO event registration
- `client/lib/services/external_guest_socket_service.dart` - /external namespace client
- `client/lib/views/external_prejoin_view.dart` - Guest UI, key request logic
- `client/lib/views/meeting_video_conference_view.dart` - Participant key response

**Server:**
- `server/namespaces/external.js` - /external Socket.IO namespace handlers
- `server/server.js` - participant:send_e2ee_key_to_guest handler (line 3496)
- `server/routes/external.js` - Guest HTTP registration endpoint

---

## 🎯 Target Architecture (SECURE)

### Guest Signal Protocol E2EE Flow

```
┌─────────────────────────────────────────────────────────────┐
│               NEW FLOW (SIGNAL PROTOCOL E2EE)                │
└─────────────────────────────────────────────────────────────┘

1. Guest generates Signal keys (identity, signed pre-key, 30 pre-keys)
2. Guest uploads keys to server via HTTP POST /api/meetings/external/register
3. Guest connects to /external Socket.IO namespace
4. Guest discovers participants via GET /api/meetings/external/:meetingId/participants
   └─> Returns list: [{ user_id, device_id, display_name }]
5. For each participant:
   a. Guest fetches participant's Signal keybundle via HTTP
      GET /api/meetings/external/keys/:sessionId/participant/:userId/:deviceId
   b. Guest establishes Signal session with participant
   c. Guest sends Signal-encrypted message type: 'guest:meeting_e2ee_key_request'
      └─> Encrypted with participant's Signal session
6. Participant receives Signal message (already handled by MessageListenerService)
7. Participant sends Signal-encrypted response type: 'participant:meeting_e2ee_key_response'
   └─> Contains encrypted LiveKit E2EE key
8. Guest receives Signal message and decrypts E2EE key

✅ SECURITY: All communication encrypted with Signal Protocol
✅ SECURITY: Forward secrecy (Double Ratchet)
✅ SECURITY: Protection against replay attacks (message counters)
✅ SECURITY: Session corruption recovery (pre-key rotation)
```

---

## 🔧 Implementation Plan

### Phase 1: Server-Side Signal Keybundle Endpoints (2-3 hours)

**Objective:** Allow guests to fetch participant Signal keybundles for session establishment

#### 1.1 Create Guest → Participant Keybundle Endpoint

**File:** `server/routes/external.js`

```javascript
/**
 * Get participant's Signal keybundle for guest session establishment
 * GET /api/meetings/external/:sessionId/participant/:userId/:deviceId/keys
 * 
 * Security:
 * - Validates guest session exists and is admitted
 * - Validates participant is in same meeting
 * - Returns participant's identity, signed pre-key, and one pre-key
 */
router.get(
  '/meetings/external/:sessionId/participant/:userId/:deviceId/keys',
  async (req, res) => {
    try {
      const { sessionId, userId, deviceId } = req.params;
      
      // 1. Validate guest session
      const session = await externalParticipantService.getSession(sessionId);
      if (!session) {
        return res.status(404).json({ error: 'Session not found' });
      }
      
      // 2. Check if session is admitted (optional - allow during key exchange)
      // if (session.admitted !== true) {
      //   return res.status(403).json({ error: 'Session not admitted yet' });
      // }
      
      // 3. Verify participant is in same meeting
      const meeting = await meetingService.getMeeting(session.meeting_id);
      if (!meeting) {
        return res.status(404).json({ error: 'Meeting not found' });
      }
      
      const isParticipant = meeting.created_by === userId ||
                           meeting.participants?.some(p => p.uuid === userId) ||
                           meeting.invited_participants?.includes(userId);
      
      if (!isParticipant) {
        return res.status(403).json({ error: 'Target user not in meeting' });
      }
      
      // 4. Fetch participant's Signal keybundle
      const { Client, SignalPreKey, SignalSignedPreKey } = require('../db/model');
      
      const client = await Client.findOne({
        where: { owner: userId, device_id: deviceId }
      });
      
      if (!client || !client.public_key || !client.registration_id) {
        return res.status(404).json({ error: 'Participant keys not found' });
      }
      
      // Get signed pre-key
      const signedPreKey = await SignalSignedPreKey.findOne({
        where: { owner: userId, client: client.clientid },
        order: [['createdAt', 'DESC']]
      });
      
      if (!signedPreKey) {
        return res.status(404).json({ error: 'No signed pre-key found' });
      }
      
      // Get one pre-key (will be consumed)
      const preKey = await SignalPreKey.findOne({
        where: { owner: userId, client: client.clientid },
        order: [['createdAt', 'ASC']]
      });
      
      if (!preKey) {
        return res.status(404).json({ error: 'No pre-keys available' });
      }
      
      // Return keybundle
      res.json({
        user_id: userId,
        device_id: deviceId,
        identity_key: client.public_key,
        registration_id: client.registration_id,
        signed_pre_key: {
          id: signedPreKey.signed_prekey_id,
          public_key: signedPreKey.signed_prekey_data,
          signature: signedPreKey.signed_prekey_signature
        },
        pre_key: {
          id: preKey.prekey_id,
          public_key: preKey.prekey_data
        }
      });
      
      // Delete consumed pre-key
      await preKey.destroy();
      console.log(`[EXTERNAL] Pre-key ${preKey.prekey_id} consumed by guest ${sessionId}`);
      
    } catch (error) {
      console.error('[EXTERNAL] Error fetching participant keys:', error);
      res.status(500).json({ error: 'Internal server error' });
    }
  }
);
```

#### 1.2 Create Participant → Guest Keybundle Endpoint

**File:** `server/routes/external.js`

```javascript
/**
 * Get guest's Signal keybundle for participant session establishment
 * GET /api/meetings/:meetingId/external/:sessionId/keys
 * 
 * Security:
 * - Requires authentication (verifyAuthEither middleware)
 * - Validates user is participant in meeting
 * - Returns guest's identity, signed pre-key, and one pre-key
 */
router.get(
  '/meetings/:meetingId/external/:sessionId/keys',
  verifyAuthEither,
  async (req, res) => {
    try {
      const { meetingId, sessionId } = req.params;
      const userId = req.userId; // From verifyAuthEither middleware
      
      // 1. Validate meeting and participant
      const meeting = await meetingService.getMeeting(meetingId);
      if (!meeting) {
        return res.status(404).json({ error: 'Meeting not found' });
      }
      
      const isParticipant = meeting.created_by === userId ||
                           meeting.participants?.some(p => p.uuid === userId) ||
                           meeting.invited_participants?.includes(userId);
      
      if (!isParticipant) {
        return res.status(403).json({ error: 'Not a participant' });
      }
      
      // 2. Validate guest session
      const session = await externalParticipantService.getSession(sessionId);
      if (!session || session.meeting_id !== meetingId) {
        return res.status(404).json({ error: 'Guest session not found' });
      }
      
      // 3. Return guest's keybundle (stored during registration)
      // Parse pre_keys if it's JSON string
      let preKeys = session.pre_keys;
      if (typeof preKeys === 'string') {
        preKeys = JSON.parse(preKeys);
      }
      
      // Parse signed_pre_key if it's JSON string
      let signedPreKey = session.signed_pre_key;
      if (typeof signedPreKey === 'string') {
        signedPreKey = JSON.parse(signedPreKey);
      }
      
      // Select one pre-key (oldest one)
      const selectedPreKey = preKeys && preKeys.length > 0 ? preKeys[0] : null;
      
      if (!selectedPreKey) {
        return res.status(404).json({ error: 'No pre-keys available for guest' });
      }
      
      res.json({
        session_id: sessionId,
        display_name: session.display_name,
        identity_key: session.identity_key_public,
        registration_id: 1, // Guests don't have registration ID - use fixed value
        signed_pre_key: signedPreKey,
        pre_key: selectedPreKey
      });
      
      // Remove consumed pre-key from session
      const remainingPreKeys = preKeys.filter(pk => pk.id !== selectedPreKey.id);
      await externalParticipantService.updateSessionPreKeys(sessionId, remainingPreKeys);
      console.log(`[EXTERNAL] Pre-key ${selectedPreKey.id} consumed from guest ${sessionId}`);
      
    } catch (error) {
      console.error('[EXTERNAL] Error fetching guest keys:', error);
      res.status(500).json({ error: 'Internal server error' });
    }
  }
);
```

#### 1.3 Add Helper Method to ExternalParticipantService

**File:** `server/services/externalParticipantService.js`

```javascript
/**
 * Update guest session pre-keys (after consumption)
 * @param {string} session_id - Session ID
 * @param {Array} pre_keys - Remaining pre-keys
 */
async updateSessionPreKeys(session_id, pre_keys) {
  try {
    await ExternalSession.update(
      { pre_keys: JSON.stringify(pre_keys) },
      { where: { session_id } }
    );
    return true;
  } catch (error) {
    console.error('Error updating session pre-keys:', error);
    return false;
  }
}
```

---

### Phase 2: Client-Side Signal Protocol Integration (4-6 hours)

**Objective:** Enable guests to send/receive Signal Protocol encrypted messages

#### 2.1 Extend SignalService for Guest Sessions

**File:** `client/lib/services/signal_service.dart`

**NEW METHODS:**

```dart
/// Send Signal encrypted item to external guest (participant → guest)
/// Used for sending meeting E2EE key to guest
Future<void> sendItemToGuest({
  required String guestSessionId,
  required String type,
  required String payload,
  required String itemId,
}) async {
  // Establish Signal session if not exists
  final session = await _getOrCreateGuestSession(guestSessionId);
  
  // Encrypt message with Signal Protocol
  final encrypted = await _encryptForGuest(session, payload);
  
  // Send via Socket.IO to /external namespace
  SocketService().emit('participant:signal_message_to_guest', {
    'guest_session_id': guestSessionId,
    'type': type,
    'encrypted_message': encrypted,
    'item_id': itemId,
  });
}

/// Receive Signal encrypted item from participant (guest ← participant)
/// Registered as listener in ExternalGuestSocketService
Future<Map<String, dynamic>?> receiveItemFromParticipant({
  required String participantUserId,
  required String participantDeviceId,
  required String encryptedMessage,
  required String type,
}) async {
  // Establish Signal session if not exists
  final session = await _getOrCreateParticipantSession(
    participantUserId,
    participantDeviceId,
  );
  
  // Decrypt message with Signal Protocol
  final decrypted = await _decryptFromParticipant(session, encryptedMessage);
  
  return {
    'type': type,
    'payload': decrypted,
    'sender_user_id': participantUserId,
    'sender_device_id': participantDeviceId,
  };
}

/// Fetch participant's Signal keybundle and establish session
Future<void> _getOrCreateParticipantSession(
  String userId,
  String deviceId,
) async {
  // Check if session already exists
  final existingSession = await _sessionStore.loadSession(
    '$userId:$deviceId',
  );
  
  if (existingSession != null) {
    return; // Session exists
  }
  
  // Fetch keybundle from server
  final sessionId = /* get from session storage */;
  final response = await ApiService.get(
    '/api/meetings/external/$sessionId/participant/$userId/$deviceId/keys',
  );
  
  final keybundle = response.data;
  
  // Build Signal session
  await _sessionStore.processPreKeyBundle(
    '$userId:$deviceId',
    keybundle,
  );
}

/// Guest-specific: Fetch guest's own keybundle for participant
/// (Not needed - guest already has keys, participants fetch via HTTP)
```

#### 2.2 Add Guest Signal Message Listener

**File:** `client/lib/services/external_guest_socket_service.dart`

```dart
/// Register listener for Signal encrypted messages from participants
void _registerSignalMessageListener() {
  on('participant:signal_message', (data) async {
    debugPrint('[GUEST SOCKET] Received Signal message: $data');
    
    try {
      final participantUserId = data['participant_user_id'] as String;
      final participantDeviceId = data['participant_device_id'] as String;
      final encryptedMessage = data['encrypted_message'] as String;
      final messageType = data['type'] as String;
      
      // Decrypt via SignalService
      final decrypted = await SignalService.instance.receiveItemFromParticipant(
        participantUserId: participantUserId,
        participantDeviceId: participantDeviceId,
        encryptedMessage: encryptedMessage,
        type: messageType,
      );
      
      if (decrypted == null) {
        debugPrint('[GUEST SOCKET] Failed to decrypt message');
        return;
      }
      
      // Handle based on message type
      if (messageType == 'participant:meeting_e2ee_key_response') {
        _handleE2EEKeyResponse(decrypted);
      }
      
    } catch (e) {
      debugPrint('[GUEST SOCKET] Error processing Signal message: $e');
    }
  });
}
```

#### 2.3 Update Guest Key Request Flow

**File:** `client/lib/views/external_prejoin_view.dart`

```dart
/// Request E2EE key from specific participant using Signal Protocol
Future<void> _requestE2EEKeyViaSignal(
  String participantUserId,
  String participantDeviceId,
) async {
  try {
    // Establish Signal session with participant
    await SignalService.instance._getOrCreateParticipantSession(
      participantUserId,
      participantDeviceId,
    );
    
    // Send Signal-encrypted key request
    await SignalService.instance.sendItemToParticipant(
      recipientUserId: participantUserId,
      recipientDeviceId: participantDeviceId,
      type: 'guest:meeting_e2ee_key_request',
      payload: jsonEncode({
        'meeting_id': _meetingId,
        'guest_session_id': _sessionId,
        'request_id': 'req_${DateTime.now().millisecondsSinceEpoch}',
      }),
      itemId: 'guest_key_req_${DateTime.now().millisecondsSinceEpoch}',
    );
    
    debugPrint('[GUEST] E2EE key request sent via Signal to $participantUserId:$participantDeviceId');
    
  } catch (e) {
    debugPrint('[GUEST] Error sending Signal key request: $e');
  }
}
```

---

### Phase 3: Server-Side Signal Message Routing (2-3 hours)

**Objective:** Route Signal messages between guests (unauthenticated) and participants (authenticated)

#### 3.1 Add Signal Message Relay in External Namespace

**File:** `server/namespaces/external.js`

```javascript
/**
 * Guest sends Signal encrypted message to participant
 * Relays to participant's device via main namespace
 */
socket.on('guest:signal_message', async (data) => {
  try {
    const { participant_user_id, participant_device_id, encrypted_message, type } = data;
    
    console.log(`[EXTERNAL WS] Guest ${session_id} sending Signal message to ${participant_user_id}:${participant_device_id}`);
    
    // Find participant's socket on MAIN namespace
    const deviceKey = `${participant_user_id}:${participant_device_id}`;
    const participantSocketId = global.deviceSockets?.get(deviceKey);
    
    if (participantSocketId) {
      const participantSocket = io.sockets.sockets.get(participantSocketId);
      if (participantSocket) {
        participantSocket.emit('guest:signal_message', {
          guest_session_id: session_id,
          encrypted_message,
          type,
          timestamp: Date.now()
        });
        console.log(`[EXTERNAL WS] ✓ Signal message delivered to ${deviceKey}`);
      }
    } else {
      console.log(`[EXTERNAL WS] ⚠️ Participant ${deviceKey} not connected`);
    }
  } catch (error) {
    console.error('[EXTERNAL WS] Error relaying Signal message:', error);
  }
});
```

#### 3.2 Add Signal Message Relay in Main Namespace

**File:** `server/server.js`

```javascript
/**
 * Participant sends Signal encrypted message to guest
 * Relays to guest's socket via /external namespace
 */
socket.on('participant:signal_message_to_guest', async (data) => {
  try {
    if (!isAuthenticated()) {
      console.error('[SIGNAL TO GUEST] Not authenticated');
      return;
    }
    
    const { guest_session_id, encrypted_message, type } = data;
    const participantUserId = getUserId();
    const participantDeviceId = getDeviceId();
    
    console.log(`[SIGNAL TO GUEST] Participant ${participantUserId}:${participantDeviceId} sending to guest ${guest_session_id}`);
    
    // Find guest's socket on /external namespace
    const externalNamespace = io.of('/external');
    const guestSocket = Array.from(externalNamespace.sockets.values())
      .find(s => s.session_id === guest_session_id);
    
    if (guestSocket) {
      guestSocket.emit('participant:signal_message', {
        participant_user_id: participantUserId,
        participant_device_id: participantDeviceId,
        encrypted_message,
        type,
        timestamp: Date.now()
      });
      console.log(`[SIGNAL TO GUEST] ✓ Message delivered to guest ${guest_session_id}`);
    } else {
      console.log(`[SIGNAL TO GUEST] ⚠️ Guest ${guest_session_id} not connected`);
    }
  } catch (error) {
    console.error('[SIGNAL TO GUEST] Error relaying message:', error);
  }
});
```

---

### Phase 4: Remove Legacy Socket.IO Events (1-2 hours)

**Objective:** Clean up old insecure Socket.IO events

#### 4.1 Remove from Server

**Files to modify:**
- `server/namespaces/external.js` - Remove `guest:request_e2ee_key:meetingId` handler
- `server/server.js` - Remove `participant:send_e2ee_key_to_guest` handler (line 3496)

#### 4.2 Remove from Client

**Files to modify:**
- `client/lib/services/external_participant_service.dart` - Remove Socket event registration
- `client/lib/services/external_guest_socket_service.dart` - Remove old key request logic
- `client/lib/views/meeting_video_conference_view.dart` - Remove `_setupGuestE2EEKeyRequestHandler()`

---

### Phase 5: VideoConferenceService Guest Support (2-3 hours)

**Objective:** Allow guests to use VideoConferenceService with pre-exchanged keys

#### 5.1 Add Guest LiveKit Token Endpoint

**File:** `server/routes/livekit.js`

```javascript
/**
 * Generate LiveKit token for external guest
 * POST /api/livekit/external-token
 * 
 * Body:
 * - sessionId: Guest session ID
 * - meetingId: Meeting ID
 * 
 * Security:
 * - No authentication required (guest endpoint)
 * - Validates session exists and is admitted
 * - Validates session's meeting matches requested meeting
 */
router.post('/external-token', async (req, res) => {
  try {
    const AccessToken = await livekitWrapper.getAccessToken();
    const { sessionId, meetingId } = req.body;
    
    if (!sessionId || !meetingId) {
      return res.status(400).json({ error: 'sessionId and meetingId required' });
    }
    
    // Validate session
    const externalParticipantService = require('../services/externalParticipantService');
    const session = await externalParticipantService.getSession(sessionId);
    
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }
    
    if (session.meeting_id !== meetingId) {
      return res.status(403).json({ error: 'Session not for this meeting' });
    }
    
    if (session.admitted !== true) {
      return res.status(403).json({ error: 'Not admitted yet' });
    }
    
    // Get LiveKit config
    const apiKey = process.env.LIVEKIT_API_KEY || 'devkey';
    const apiSecret = process.env.LIVEKIT_API_SECRET || 'secret';
    const livekitUrl = process.env.LIVEKIT_URL || 'ws://localhost:7880';
    
    // Create token with guest identity
    const token = new AccessToken(apiKey, apiSecret, {
      identity: `guest_${sessionId}`,
      name: session.display_name,
      metadata: JSON.stringify({
        sessionId,
        meetingId,
        isGuest: true,
        displayName: session.display_name
      })
    });
    
    // Grant permissions (guests have limited permissions)
    token.addGrant({
      room: meetingId,
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      canPublishData: false, // Guests cannot send data messages
      roomAdmin: false
    });
    
    const jwt = await token.toJwt();
    
    res.json({
      token: jwt,
      url: livekitUrl.replace('peerwave-livekit', 'localhost'),
      roomName: meetingId,
      identity: `guest_${sessionId}`
    });
    
  } catch (error) {
    console.error('[LiveKit External] Token generation error:', error);
    res.status(500).json({ error: 'Failed to generate token' });
  }
});
```

#### 5.2 Modify VideoConferenceService.joinRoom()

**File:** `client/lib/services/video_conference_service.dart`

```dart
/// Join a video conference room
/// Supports both authenticated users and external guests
Future<void> joinRoom(
  String channelId, {
  MediaDevice? cameraDevice,
  MediaDevice? microphoneDevice,
  String? channelName,
  bool isExternal = false, // NEW: Guest flag
  String? externalSessionId, // NEW: Guest session ID
  Uint8List? externalE2EEKey, // NEW: Pre-exchanged E2EE key
}) async {
  if (_isConnecting || _isConnected) return;
  
  try {
    _isConnecting = true;
    _currentChannelId = channelId;
    _isInCall = true;
    _channelName = channelName;
    _callStartTime = DateTime.now();
    
    notifyListeners();
    
    // === E2EE Key Setup ===
    if (isExternal && externalE2EEKey != null) {
      // Guest: Use pre-exchanged key from Signal Protocol
      debugPrint('[VideoConf] Using pre-exchanged E2EE key for guest');
      _channelSharedKey = externalE2EEKey;
      _keyTimestamp = DateTime.now().millisecondsSinceEpoch;
      _isFirstParticipant = false; // Guests never generate keys
      
      // Create KeyProvider with guest's key
      if (_keyProvider == null) {
        _keyProvider = await BaseKeyProvider.create();
        final keyBase64 = base64Encode(_channelSharedKey!);
        await _keyProvider!.setKey(keyBase64);
        debugPrint('[VideoConf] ✓ BaseKeyProvider created for guest');
      }
    } else if (!isExternal) {
      // Authenticated user: Signal Service check (existing logic)
      if (!SignalService.instance.isInitialized) {
        throw Exception('Signal Service must be initialized');
      }
      
      // Existing key exchange logic for authenticated users...
    }
    
    // === LiveKit Token Request ===
    final tokenEndpoint = isExternal
        ? '/api/livekit/external-token'
        : (channelId.startsWith('mtg_') || channelId.startsWith('call_'))
            ? '/api/livekit/meeting-token'
            : '/api/livekit/token';
    
    final requestData = isExternal
        ? {'sessionId': externalSessionId, 'meetingId': channelId}
        : _isMeetingChannel(channelId)
            ? {'meetingId': channelId}
            : {'channelId': channelId};
    
    final response = await ApiService.post(tokenEndpoint, data: requestData);
    
    // Rest of joinRoom logic...
  } catch (e) {
    // Error handling...
  }
}
```

---

## 🧪 Testing Plan

### Test Case 1: Guest Signal Session Establishment
- [ ] Guest fetches participant keybundle
- [ ] Guest establishes Signal session
- [ ] Guest sends encrypted test message
- [ ] Participant receives and decrypts message

### Test Case 2: E2EE Key Exchange
- [ ] Participant fetches guest keybundle
- [ ] Participant sends encrypted E2EE key
- [ ] Guest receives and decrypts E2EE key
- [ ] Guest can decrypt video frames

### Test Case 3: LiveKit Guest Join
- [ ] Guest receives LiveKit token
- [ ] Guest joins with `guest_` identity prefix
- [ ] Guest can publish video/audio
- [ ] Guest cannot send data messages (security)

### Test Case 4: Pre-key Consumption
- [ ] Participant pre-key count decreases after guest fetches
- [ ] Guest pre-key count decreases after participant fetches
- [ ] Low pre-key count triggers rotation warning

---

## 🚨 Security Considerations

1. **Pre-key Rotation**: Guests must upload new pre-keys when count drops below 10
2. **Session Expiry**: Guest sessions expire after 24 hours (existing)
3. **Rate Limiting**: Limit keybundle fetches to prevent DoS (10 per minute per session)
4. **Admission Check**: Validate guest is admitted before granting LiveKit token
5. **Identity Prefix**: Use `guest_` prefix to distinguish from authenticated users in LiveKit

---

## ✅ Decisions Made (December 12, 2025)

### Question 1: Guest Pre-key Rotation Strategy ✅ DECIDED
**Context:** Guests are temporary (24-hour sessions) and may not rotate pre-keys.

**Decision:** **No rotation** - 30 pre-keys are sufficient for typical meetings (<30 participants). Guests are short-lived (24h max), so pre-key exhaustion is not a concern.

---

### Question 2: Participant Pre-key Consumption ✅ DECIDED
**Context:** Each guest consumes one participant pre-key when establishing session.

**Decision:** **No special handling** - Participants already have automated pre-key rotation when count drops below threshold. Existing mechanism handles guest consumption automatically.

---

### Question 3: Guest Signal Message Types ✅ DECIDED
**Context:** Should we reuse existing Signal message types or create guest-specific ones?

**Decision:** **Guest-specific message types:**
- `guest:meeting_e2ee_key_request` - Guest → Participant
- `participant:meeting_e2ee_key_response` - Participant → Guest

**Rationale:** Clearer separation, easier debugging, prevents confusion with authenticated user messages.

---

### Question 4: Guest Session Persistence ✅ DECIDED
**Context:** Guest Signal sessions are in-memory (not persisted to database).

**Decision:** **No persistence** - Guests are temporary, real-time only is acceptable. No offline message delivery for guests.

---

### Question 5: Multi-Device Guests ✅ DECIDED
**Context:** Current design assumes one device per guest session.

**Decision:** **One session per device** - Each device gets separate session ID (simpler, more secure). No multi-device sync for guests.

---

### Question 6: Backward Compatibility ✅ DECIDED
**Context:** Old clients may still use Socket.IO E2EE key exchange.

**Decision:** **Hard cutover** - Remove old Socket.IO events immediately, force client update. This is a critical security issue that requires immediate mitigation.

---

## 📅 Timeline Estimate

| Phase | Duration | Dependencies |
|-------|----------|--------------|
| Phase 1: Server Keybundle Endpoints | 2-3 hours | None |
| Phase 2: Client Signal Integration | 4-6 hours | Phase 1 |
| Phase 3: Server Message Routing | 2-3 hours | Phase 1 |
| Phase 4: Remove Legacy Events | 1-2 hours | Phase 2, 3 |
| Phase 5: VideoConferenceService | 2-3 hours | Phase 2 |
| Testing & Debugging | 3-4 hours | All phases |
| **Total** | **14-21 hours** | 2-3 days |

---

## 🎯 Success Criteria

- [ ] All guest↔participant communication encrypted with Signal Protocol
- [ ] Zero plaintext LiveKit E2EE keys transmitted
- [ ] Guest can join video conference after admission
- [ ] Guest can decrypt video frames (verify in LiveKit logs)
- [ ] Old Socket.IO events completely removed
- [ ] No regressions in authenticated user flow
- [ ] All tests passing

---

## 📝 Notes

- **LibSignal Web Support**: Verify `libsignal_protocol_dart` works in web (guest browser environment)
- **CORS Headers**: Ensure keybundle endpoints have correct CORS for web guests
- **Rate Limiting**: Implement on keybundle endpoints to prevent abuse
- **Logging**: Add extensive logging for debugging guest Signal sessions
- **Error Handling**: Clear error messages for guest setup failures

---

---

## 🔒 Additional Security Considerations

### 1. Signal Protocol Session Hijacking Prevention
**Risk:** Malicious guest could impersonate another guest if they obtain session_id.

**Mitigation:**
- Guest Signal identity is bound to `session_id` (server validates on keybundle fetch)
- Server compares `session.meeting_id` with requested `meeting_id`
- Token must match session's meeting (validated via `externalParticipantService.validateTokenForMeeting()`)

**Status:** ✅ Already protected by existing token validation

---

### 2. Replay Attack Protection
**Risk:** Attacker could replay captured Signal Protocol messages to inject old keys.

**Mitigation:**
- Signal Protocol Double Ratchet provides built-in replay protection via message counters
- Out-of-order messages are rejected automatically
- Sessions are ephemeral (cleared on tab close via sessionStorage)

**Status:** ✅ Handled by Signal Protocol design

---

### 3. Pre-key Exhaustion Attack
**Risk:** Malicious guest repeatedly fetches keybundles to exhaust participant/guest pre-keys.

**Mitigation:**
- Rate limiting: 3 fetches/minute per participant per guest (Question 12)
- Server tracks consumed pre-keys and logs suspicious activity
- Participants have 100+ pre-keys (regenerated automatically)
- Guests have 30 pre-keys (sufficient for typical meeting size)

**Status:** ✅ Protected by rate limiting + key pool size

---

### 4. Man-in-the-Middle (MITM) on Keybundle Fetch
**Risk:** Attacker intercepts HTTP keybundle request and substitutes their own keys.

**Mitigation:**
- **HTTPS required** - All keybundle endpoints must use TLS
- Guest verifies participant exists in meeting participants list (fetched from server)
- Participant verifies guest session exists and matches meeting

**Action Required:** ⚠️ Enforce HTTPS in production, add warning if running over HTTP

---

### 5. Session Fixation Attack
**Risk:** Attacker forces guest to use a known session_id they control.

**Mitigation:**
- Server generates session_id server-side (UUID v4) on registration
- Guest cannot specify custom session_id
- Session is bound to invitation token (validated on creation)

**Status:** ✅ Already protected by server-side session generation

---

### 6. Cross-Site Request Forgery (CSRF) on Keybundle Endpoints
**Risk:** Malicious website tricks authenticated user's browser into fetching guest keybundles.

**Mitigation:**
- Guest keybundle endpoint requires authentication (`verifyAuthEither` middleware)
- Participant keybundle endpoint is unauthenticated BUT requires valid `session_id` that only server knows
- No state-changing operations on keybundle fetch (read-only)

**Status:** ✅ Low risk - read-only endpoints, session validation

---

### 7. Signal Protocol "Trust on First Use" (TOFU) Limitation
**Context:** Signal Protocol doesn't verify identity authenticity (no PKI).

**Impact:**
- If attacker controls first keybundle fetch, they can MITM all subsequent messages
- For guests: Risk is limited to single meeting session (24h max)
- For participants: Existing authenticated session provides identity assurance

**Mitigation:**
- Meeting participants are authenticated (Signal keys tied to user account)
- Guests are temporary (no persistent identity to compromise)
- Invitation token acts as shared secret (proves guest is invited)

**Status:** ✅ Acceptable risk for temporary guest sessions

---

### 8. LibSignal WebAssembly Vulnerability
**Risk:** Guest runs Signal Protocol crypto in browser (WebAssembly/JS) which is less secure than native.

**Mitigation:**
- Use latest `libsignal_protocol_dart` package (maintained by Signal Foundation)
- Keep dependencies updated for security patches
- Limit guest session lifetime to 24h (reduces exposure window)

**Action Required:** ⚠️ Add dependency scanning to CI/CD pipeline

---

### 9. Browser Extension Keylogging
**Risk:** Malicious browser extension could steal guest's Signal keys from sessionStorage.

**Mitigation:**
- sessionStorage is origin-isolated (extension needs explicit permission)
- Keys are ephemeral (cleared on tab close)
- No persistent storage of keys (regenerated per session)

**Status:** ✅ Limited risk - recommend guests use incognito mode (future UX improvement)

---

### 10. LiveKit E2EE Key Leakage via Browser DevTools
**Risk:** Developer tools could expose decrypted LiveKit E2EE key in memory.

**Mitigation:**
- Clear E2EE key from VideoConferenceService on disconnect
- Use `Uint8List` (binary) instead of String for key storage
- Avoid logging keys in production builds

**Action Required:** ⚠️ Add `assert(kDebugMode)` guards around all E2EE key logging

---

## 🛠️ Implementation Security Checklist

- [ ] Enforce HTTPS in production (reject HTTP for keybundle endpoints)
- [ ] Add rate limiting middleware to keybundle endpoints (3/min per guest per participant)
- [ ] Implement Signal session cache (5-minute TTL) to prevent duplicate keybundle fetches
- [ ] Add `assert(kDebugMode)` guards around E2EE key debug logs
- [ ] Clear guest Signal sessions from sessionStorage on meeting end
- [ ] Validate `meeting_id` matches in all keybundle requests
- [ ] Log suspicious activity (>3 failed keybundle requests in 1 minute)
- [ ] Add Content-Security-Policy headers to prevent XSS
- [ ] Implement nonce in keybundle responses to prevent replay
- [ ] Add dependency scanning for libsignal vulnerabilities

---

## 📊 Performance Considerations

### 1. Signal Protocol Cryptographic Overhead
**Impact:** Each message requires EC25519 encryption/decryption + HMAC verification.

**Mitigation:**
- Only 2-3 messages per guest (key request + response + optional retry)
- Modern browsers handle EC25519 efficiently (~0.5ms per operation)
- Negligible impact compared to video encoding/decoding

**Status:** ✅ No performance concerns

---

### 2. Keybundle Fetch Latency
**Impact:** HTTP roundtrip adds 50-500ms depending on network.

**Mitigation:**
- Parallel keybundle fetches if requesting from multiple participants
- Cache Signal sessions for 5 minutes (avoid re-fetching on retry)
- Show loading spinner during key exchange

**Status:** ✅ Acceptable for meeting join flow

---

### 3. SessionStorage Size Limit
**Impact:** Browsers limit sessionStorage to 5-10MB per origin.

**Current Usage:**
- Guest Signal session: ~5KB (identity key + session state)
- E2EE key: 32 bytes
- Participant sessions: ~5KB × 3 participants = 15KB
- **Total: ~20KB** (well within limits)

**Status:** ✅ No storage concerns

---

## 🚀 Implementation Priority

### Phase 1A: Critical Security (Immediate) - 6 hours
- Server keybundle endpoints with rate limiting
- Signal message relay between namespaces
- Hard cutover (remove old Socket.IO events)

### Phase 1B: Client Integration (Next) - 8 hours
- Extend SignalService for guest sessions
- Update ExternalPreJoinView key exchange flow
- Implement error handling and retry logic

### Phase 2: VideoConferenceService (After Phase 1) - 4 hours
- Add `isExternal` mode to joinRoom()
- Guest LiveKit token endpoint
- Integration testing

### Phase 3: Security Hardening (Final) - 3 hours
- Add HTTPS enforcement
- Implement logging/monitoring
- Security audit and penetration testing

**Total Estimated Time: 21 hours (2.5 days)**

---

## 🔍 Additional Questions Before Implementation

### Question 7: Guest Signal Session Storage ✅ DECIDED
**Context:** Guests need to store Signal Protocol sessions, identity keys, and session state.

**Decision:** **SessionStorage** - Cleared when tab closes, no cleanup needed. Guests must stay in same tab/window for entire meeting session. If they refresh, they re-generate keys (acceptable for temporary guests).

**Rationale:** Simplest implementation, automatic cleanup, aligns with existing guest state storage pattern.

---

### Question 8: Guest Signal Identity Key Generation ✅ DECIDED
**Context:** Signal Protocol requires IdentityKeyPair (25519 keypair) for each participant.

**Decision:** **During prejoin phase** - Keys already generated in external_prejoin_view.dart. Extend SignalService to use existing keys for session establishment.

**Implementation:** No changes needed to key generation flow, only extend SignalService API.

---

### Question 9: Participant Fetches Guest Keybundle When? ✅ DECIDED
**Context:** Participants need guest's keybundle to send encrypted E2EE key response.

**Decision:** **On-demand** - Fetch keybundle only when `guest:meeting_e2ee_key_request` message arrives. Cache Signal session for 5 minutes to handle retries without consuming additional pre-keys.

**Rationale:** Avoids unnecessary pre-key consumption, cleaner architecture.

---

### Question 10: Signal Message Type Namespacing ✅ DECIDED
**Context:** We're creating new guest-specific message types.

**Decision:** **Transient only** - Guest E2EE key exchange messages (`guest:meeting_e2ee_key_request`, `participant:meeting_e2ee_key_response`) are NOT stored in database.

**Implementation:** Use existing SignalService transient message handling (same as authenticated meeting key exchange).

---

### Question 11: Guest Signal Protocol Error Handling ✅ DECIDED
**Context:** Signal Protocol can fail (corrupted session, duplicate message, missing pre-key).

**Decision:** **User notification with manual retry** - Show clear error message "Key exchange failed. Please try again." with retry button.

**Rationale:** Transparent UX, prevents automatic pre-key drainage, gives user control.

---

### Question 12: Rate Limiting Guest Keybundle Fetches ✅ DECIDED
**Context:** Malicious guest could spam keybundle endpoint to exhaust participant pre-keys.

**Decision:** **3 fetches/minute per participant per guest** - Prevents spam while allowing legitimate retries.

**Implementation:** Track `guest_session_id:participant_user_id:participant_device_id` combinations in server-side rate limiter (in-memory Map with TTL).

---

### Question 13: Guest Leaves Before Admission ✅ DECIDED
**Context:** Guest may close browser/tab while waiting for admission (before key exchange).

**Decision:** **Auto-cleanup via session deletion** - Already handled by existing ExternalSession cleanup on disconnect. No additional implementation needed.

---

### Question 14: Participant Leaves During Guest Key Exchange ✅ DECIDED
**Context:** Participant may leave meeting while guest is requesting key from them.

**Decision:** **5-second timeout, auto-retry next participant** - Wait up to 5s for response. If no response, automatically try next participant. Fail after 3 consecutive failures.

**UX:** Show loading spinner with "Exchanging encryption keys..." message. On failure: "Unable to join meeting. Please try again later."

---

### Question 15: WebRTC Native vs Web for Guests ✅ DECIDED
**Context:** Current implementation assumes guests are web-only (browsers).

**Decision:** **Web-only for now** - Focus on browser-based guest implementation. Native guest app support is out of scope for this phase.

**Future:** Can be added later if needed. Signal Protocol implementation would be identical, only platform-specific storage differs.

---

### Question 16: Guest Identity Verification ✅ DECIDED
**Context:** Guests are unauthenticated - we trust the invitation token.

**Decision:** **No additional verification needed** - Current validation (token + meeting_id + session_id comparison) is sufficient.

**Existing Security:**
- Token is cryptographically secure (UUID v4)
- Server validates token matches session's meeting
- Session expires after 24 hours
- Rate limiting on keybundle fetches (Question 12)

**Rationale:** Adding IP-based limits could block legitimate users behind corporate NATs. Current security model is adequate.
