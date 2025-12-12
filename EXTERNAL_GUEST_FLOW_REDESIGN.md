# External Guest Flow Redesign - Action Plan

**Date:** December 12, 2025  
**Status:** 📋 PLANNING PHASE

---

## Executive Summary

This document outlines the complete redesign of the external guest admission flow to implement a **key-exchange-before-admission** model instead of the current **admission-before-key-exchange** approach.

### Key Change
**Current:** Register → Wait for admission → Exchange keys → Join room  
**New:** Register → Exchange keys → Request admission → Join if accepted

---

## Technical Architecture

### WebSocket Communication
- **Main Namespace (`/`)**: Authenticated participants only (HMAC session validation)
- **External Namespace (`/external`)**: Unauthenticated guests (session_id + token validation)
- **Cross-Namespace Routing**: Server routes messages between namespaces using `global.io` and `global.deviceSockets`

### Socket.IO Rooms (WebSocket Listeners)
These are **NOT** LiveKit media rooms - they are WebSocket message routing rooms:
- **`meeting:${meetingId}`**: Broadcast room for all participants + guests in a meeting
- **`guest:${sessionId}`**: Personal inbox for each guest to receive direct messages
- **Dual Room Strategy**: Guests join both rooms to receive broadcasts and direct messages

### E2EE Key Exchange Flow
Keys are exchanged via **Socket.IO Signal 1:1 messages** (WebSocket), NOT through LiveKit WebRTC DataChannel:

1. **Guest → Participant** (Broadcast):
   - Event: `guest:request_e2ee_key`
   - Sent to: `meeting:${meetingId}` room (all participants receive)
   - Payload: `{ sessionId, displayName }`

2. **Participant → Guest** (Direct):
   - Event: `participant:send_e2ee_key_to_guest`
   - Server routes to: `guest:${sessionId}` room (specific guest receives)
   - Payload: Signal encrypted message with E2EE key

3. **Guest establishes Signal session** with each participant before requesting admission

---

## New Guest Flow (Detailed)

### Phase 1: Token Validation & Registration
```
1. Guest navigates to /join/meeting/:token
2. HTTP GET /api/meetings/external/join/:token
   - Validates token
   - Returns meeting info (title, description, start_time, etc.)
3. Guest creates Signal identity/prekeys
   - Web: sessionStorage
   - Native: memory
4. HTTP POST /api/meetings/external/register
   - Upload Signal keys to server
   - Create ExternalSession with status: 'waiting'
   - Server stores session (no admission notification yet)
```

### Phase 2: Participant Discovery & Key Exchange (NEW)
```
5. Guest queries LiveKit room participants (NEW ENDPOINT NEEDED)
   - HTTP GET /api/meetings/:meetingId/livekit-participants
   - Returns list of current participants (authenticated users only, no guests)
   
6. If no participants found:
   → Show message: "Meeting has not started yet"
   → Option to refresh/retry
   → Block "Join Meeting" button
   
7. If participants found:
   → For each participant:
      a. Send Signal 1:1 message: "video_e2ee_key_request"
         - Message contains guest's session_id
         - Sent via existing Signal message infrastructure
      b. Wait for "video_e2ee_key_response" from participant
         - Response contains encrypted E2EE key
         - Guest decrypts with their Signal session
   
8. Key Exchange Status Display:
   ✓ Keys received from all participants
      → Enable "Join Meeting" button
   ⚠ Partial key exchange (some participants responded)
      → Show warning + "Retry Key Exchange" button
      → Enable "Join Meeting" button (can join with partial encryption)
   ✗ No keys received
      → Show error + "Retry Key Exchange" button
      → Disable "Join Meeting" button
```

### Phase 3: Request Admission (NEW)
```
9. Guest clicks "Join Meeting" button
   → HTTP POST /api/meetings/:meetingId/external/:sessionId/request-admission
   → Server emits Socket.IO event: meeting:guest_admission_request
   → All authenticated participants receive admission overlay
   
10. Admission Overlay (for participants):
    - Shows guest display name
    - Shows guest session info
    - "Admit" button
    - "Decline" button
    - First-come-first-served logic
```

### Phase 4: Admission Response
```
11a. If ADMITTED (first participant clicks "Admit"):
    → HTTP POST /api/meetings/:meetingId/external/:sessionId/admit
    → Server updates session: admission_status = 'admitted'
    → Server emits: meeting:guest_admitted (to all participants)
    → Server emits: meeting:admission_granted (to guest specifically)
    → Guest proceeds to LiveKit room join
    → Guest joins as normal participant with E2EE keys
    
11b. If DECLINED (first participant clicks "Decline"):
    → HTTP POST /api/meetings/:meetingId/external/:sessionId/decline
    → Server updates session: admission_status = 'declined'
    → Server emits: meeting:guest_declined (to all participants)
    → Server emits: meeting:admission_denied (to guest specifically)
    → Guest sees: "Your request to join was declined"
    → Options:
       - "Refresh Page" - restart entire flow
       - "Try Again" - send new admission request
       - Link shown to click token URL again
```

---

## Architecture Changes

### 1. New API Endpoints

#### GET `/api/meetings/:meetingId/livekit-participants?token=xxx`
**Purpose:** Get current authenticated participants in LiveKit room  
**Auth:** Requires valid guest invitation token  
**Security:** Validates token matches meetingId before returning data  
**Response:**
```json
{
  "participants": [
    {
      "user_id": "uuid",
      "display_name": "John Doe",
      "device_id": 1
    }
  ],
  "count": 2,
  "room_active": true
}
```

#### GET `/api/meetings/external/keys/:sessionId?token=xxx`
**Purpose:** Get guest's Signal prekey bundle (for participants to establish sessions)  
**Auth:** Requires valid invitation token  
**Security:** Validates token matches session's meeting before returning keys  
**Response:**
```json
{
  "identity_key_public": "base64...",
  "signed_pre_key": {
    "id": 1,
    "public_key": "base64...",
    "signature": "base64..."
  },
  "pre_keys": [
    { "id": 1, "public_key": "base64..." }
  ]
}
```

#### POST `/api/meetings/:meetingId/external/:sessionId/request-admission`
**Purpose:** Guest initiates admission request (after key exchange)  
**Auth:** None  
**Body:** `{ session_id: "..." }`  
**Actions:**
- Emit `meeting:guest_admission_request` to all participants
- Log admission request

#### Socket.IO Event: `meeting:admission_granted`
**Direction:** Server → Guest  
**Trigger:** When first participant clicks "Admit"  
**Payload:**
```javascript
{
  session_id: "...",
  meeting_id: "mtg_xxx",
  admitted_by: "user_uuid"
}
```

#### Socket.IO Event: `meeting:admission_denied`
**Direction:** Server → Guest  
**Trigger:** When first participant clicks "Decline"  
**Payload:**
```javascript
{
  session_id: "...",
  meeting_id: "mtg_xxx",
  declined_by: "user_uuid"
}
```

### 2. Modified API Endpoints

#### POST `/api/meetings/external/register`
**Changes:**
- ✅ Create session
- ✅ Store Signal keys
- ❌ DO NOT emit `meeting:guest_waiting` (removed)
- ❌ DO NOT notify participants yet

#### POST `/api/meetings/:meetingId/external/:sessionId/admit`
**Changes:**
- Add check: Verify session is in 'admission_requested' status
- First-come-first-served: If already admitted/declined, return error
- Emit `meeting:admission_granted` to specific guest (not broadcast)

#### POST `/api/meetings/:meetingId/external/:sessionId/decline`
**Changes:**
- Add check: Verify session is in 'admission_requested' status
- First-come-first-served: If already admitted/declined, return error
- Emit `meeting:admission_denied` to specific guest

### 3. Database Schema Changes

#### ExternalSession Table
Simplified admission status with boolean:
```javascript
admitted: {
  type: DataTypes.BOOLEAN,
  allowNull: true,
  defaultValue: null
  // null: Not yet requested or declined (can retry)
  // false: Currently requesting admission (waiting for response)
  // true: Admitted (can join)
}

last_admission_request: {
  type: DataTypes.DATE,
  allowNull: true
  // Used for cooldown tracking (5 second minimum between retries)
}
```

**Status Flow:**
1. `admitted = null` - Session created, keys uploaded (or declined and can retry)
2. `admitted = false` - Guest clicked "Join Meeting", awaiting response
3. `admitted = true` - Participant clicked "Admit" (can join)
4. Reset to `null` when declined (allows unlimited retries with cooldown)

---

## Client-Side Changes

### 1. New External Guest PreJoin View

**File:** `client/lib/views/external_prejoin_view.dart`

**Current State Machine:**
```
Loading → Registered → Waiting for Admission → Admitted → Joining
```

**New State Machine:**
```
Loading → Registered → Discovering Participants → Key Exchange → Ready to Join → Requesting Admission → [Admitted/Declined] → Joining/Blocked
```

#### New States:
1. **DiscoveringParticipants**
   - Shows: "Checking who's in the meeting..."
   - Polls LiveKit participants endpoint
   - Transitions:
     - No participants → NoParticipantsFound
     - Participants found → KeyExchange

2. **NoParticipantsFound**
   - Shows: "The meeting hasn't started yet"
   - Button: "Refresh" (retry participant discovery)
   - Join button: Disabled

3. **KeyExchange**
   - Shows: "Exchanging encryption keys with X participants..."
   - Progress indicator: "2/3 keys received"
   - For each participant:
     - Send `video_e2ee_key_request` via Signal 1:1
     - Wait for `video_e2ee_key_response`
   - Transitions:
     - All keys received → ReadyToJoin
     - Partial keys → PartialKeyExchange
     - Timeout → KeyExchangeFailed

4. **PartialKeyExchange**
   - Shows: Warning message "⚠️ Received keys from 2/3 participants"
   - Button: "Retry Key Exchange"
   - Join button: Enabled (with warning)

5. **KeyExchangeFailed**
   - Shows: "❌ Failed to exchange encryption keys"
   - Button: "Retry Key Exchange"
   - Join button: Disabled

6. **ReadyToJoin**
   - Shows: "✓ Ready to join meeting"
   - Button: "Join Meeting" (enabled)
   - On click → RequestingAdmission

7. **RequestingAdmission**
   - Shows: "Requesting permission to join..."
   - Waiting for admission response via Socket.IO
   - Timeout: 60 seconds
   - Transitions:
     - Admitted → Joining (proceed to LiveKit)
     - Declined → AdmissionDeclined

8. **AdmissionDeclined**
   - Shows: "Your request to join was declined"
   - Buttons:
     - "Try Again" → RequestingAdmission
     - "Refresh Page" → Reload
   - Shows invitation link to re-enter

#### New UI Components:

**Participant Discovery Panel:**
```dart
Widget _buildParticipantDiscovery() {
  return Card(
    child: Column(
      children: [
        Text('Participants in meeting'),
        if (_isDiscovering) 
          CircularProgressIndicator()
        else if (_participants.isEmpty)
          Text('Meeting not started yet')
        else
          ListView.builder(
            itemCount: _participants.length,
            itemBuilder: (context, index) {
              final participant = _participants[index];
              final hasKey = _keyExchangeStatus[participant.userId] == true;
              return ListTile(
                title: Text(participant.displayName),
                trailing: hasKey 
                  ? Icon(Icons.check_circle, color: Colors.green)
                  : CircularProgressIndicator(),
              );
            },
          ),
      ],
    ),
  );
}
```

**Key Exchange Status:**
```dart
Widget _buildKeyExchangeStatus() {
  final receivedKeys = _keyExchangeStatus.values.where((v) => v == true).length;
  final totalParticipants = _participants.length;
  
  return Column(
    children: [
      LinearProgressIndicator(
        value: totalParticipants > 0 ? receivedKeys / totalParticipants : 0,
      ),
      Text('$receivedKeys/$totalParticipants encryption keys received'),
      if (receivedKeys < totalParticipants)
        ElevatedButton(
          onPressed: _retryKeyExchange,
          child: Text('Retry Key Exchange'),
        ),
    ],
  );
}
```

### 2. Admission Overlay Changes

**File:** `client/lib/widgets/admission_overlay.dart`

**Current Behavior:**
- Listens to `meeting:guest_waiting`
- Shows guest immediately after registration

**New Behavior:**
- Listens to `meeting:guest_admission_request` (new event)
- Shows guest only AFTER they've clicked "Join Meeting"
- Displays additional info: "Guest has completed key exchange"

**UI Changes:**
```dart
ListTile(
  title: Text(guest.displayName),
  subtitle: Text('✓ Encryption keys ready'), // NEW
  trailing: Row(
    children: [
      ElevatedButton(
        onPressed: () => _admitGuest(guest),
        child: Text('Admit'),
      ),
      SizedBox(width: 8),
      ElevatedButton(
        onPressed: () => _declineGuest(guest),
        style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
        child: Text('Decline'),
      ),
    ],
  ),
);
```

### 3. Signal Service Changes

**File:** `client/lib/services/signal_service.dart`

#### New Method: `sendE2EEKeyRequestToGuest()`
```dart
/// Send E2EE key request response to external guest
/// Guest initiated the request, we respond with encrypted key
Future<void> sendE2EEKeyResponseToGuest({
  required String guestSessionId,
  required String meetingId,
  required Uint8List encryptedE2EEKey,
}) async {
  // Send via Signal 1:1 message
  // Use guest's Signal session (established via their uploaded prekeys)
}
```

#### New Message Handler: Handle guest key requests
```dart
// In message listener
if (messageType == 'video_e2ee_key_request' && fromExternal) {
  // Guest is requesting our E2EE key
  final guestSessionId = decryptedData['session_id'];
  final meetingId = decryptedData['meeting_id'];
  
  // Get our E2EE key for this meeting
  final e2eeKey = await _getE2EEKeyForMeeting(meetingId);
  
  // Encrypt with guest's Signal session
  final encryptedKey = await encryptE2EEKeyForGuest(
    guestSessionId: guestSessionId,
    e2eeKey: e2eeKey,
  );
  
  // Send response
  await sendE2EEKeyResponseToGuest(
    guestSessionId: guestSessionId,
    meetingId: meetingId,
    encryptedE2EEKey: encryptedKey,
  );
}
```

---

## Server-Side Changes

### 1. New Route Handler

**File:** `server/routes/external.js`

```javascript
/**
 * Get LiveKit room participants (authenticated users only)
 * GET /api/meetings/:meetingId/livekit-participants?token=xxx
 * Requires valid guest invitation token
 */
router.get('/meetings/:meetingId/livekit-participants', async (req, res) => {
  try {
    const { meetingId } = req.params;
    const { token } = req.query;
    
    // Validate token matches this meeting
    const validationResult = await validateExternalToken(token, meetingId);
    if (!validationResult.valid) {
      return res.status(403).json({ error: 'Invalid or expired token' });
    }
    
    // Get LiveKit room participants
    const roomName = meetingId;
    const participants = await livekitRoomService.listParticipants(roomName);
    
    // Filter out external guests (only return authenticated users)
    const authenticatedParticipants = participants.filter(p => {
      return !p.identity.startsWith('guest_');
    });
    
    // Map to useful format
    const participantList = await Promise.all(
      authenticatedParticipants.map(async (p) => {
        // Parse identity (format: "userId:deviceId")
        const [userId, deviceId] = p.identity.split(':');
        
        // Get user info from database
        const user = await User.findOne({ where: { uuid: userId } });
        
        return {
          user_id: userId,
          device_id: parseInt(deviceId),
          display_name: user?.displayName || 'Unknown',
          livekit_identity: p.identity
        };
      })
    );
    
    res.json({
      participants: participantList,
      count: participantList.length,
      room_active: participantList.length > 0
    });
  } catch (error) {
    console.error('[EXTERNAL] Error getting LiveKit participants:', error);
    res.status(500).json({ error: 'Failed to get participants' });
  }
});

/**
 * Request admission (after key exchange)
 * POST /api/meetings/:meetingId/external/:sessionId/request-admission
 */
router.post('/meetings/:meetingId/external/:sessionId/request-admission', async (req, res) => {
  try {
    const { meetingId, sessionId } = req.params;
    
    // Get session
    const session = await externalParticipantService.getSession(sessionId);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }
    
    // Check cooldown (5 seconds between retries)
    if (session.last_admission_request) {
      const timeSinceLastRequest = Date.now() - new Date(session.last_admission_request).getTime();
      if (timeSinceLastRequest < 5000) {
        return res.status(429).json({ 
          error: 'Please wait before retrying',
          retry_after: Math.ceil((5000 - timeSinceLastRequest) / 1000)
        });
      }
    }
    
    // Update status to 'requesting' (admitted = false)
    await externalParticipantService.updateAdmissionStatus(
      sessionId,
      false, // admitted = false (requesting)
      new Date() // last_admission_request timestamp
    );
    
    // Emit admission request to all participants
    if (io) {
      io.to(`meeting:${meetingId}`).emit('meeting:guest_admission_request', {
        session_id: sessionId,
        meeting_id: meetingId,
        display_name: session.display_name,
        admission_status: 'admission_requested'
      });
      console.log(`[EXTERNAL] Guest ${sessionId} requested admission to ${meetingId}`);
    }
    
    res.json({ success: true, status: 'admission_requested' });
  } catch (error) {
    console.error('[EXTERNAL] Error requesting admission:', error);
    res.status(500).json({ error: 'Failed to request admission' });
  }
});
```

### 2. Modified Route Handlers

**File:** `server/routes/external.js`

```javascript
/**
 * POST /api/meetings/external/register
 * CHANGED: No longer emits meeting:guest_waiting
 */
router.post('/meetings/external/register', async (req, res) => {
  // ... existing code ...
  
  // Create session
  const session = await externalParticipantService.createSession({
    meeting_id: result.meeting.meeting_id,
    display_name,
    identity_key_public: keys.identity_key_public,
    signed_pre_key: keys.signed_pre_key,
    pre_keys: keys.pre_keys
  });
  
  // REMOVED: No admission notification here anymore
  // Guest will trigger admission request AFTER key exchange
  
  res.status(201).json({
    session_id: session.session_id,
    meeting_id: session.meeting_id,
    // ... rest of response
  });
});

/**
 * POST /api/meetings/:meetingId/external/:sessionId/admit
 * CHANGED: Emit to specific guest, not broadcast
 */
router.post('/meetings/:meetingId/external/:sessionId/admit', async (req, res) => {
  try {
    const { meetingId, sessionId } = req.params;
    const { admitted_by } = req.body;
    
    // Get current session
    const session = await externalParticipantService.getSession(sessionId);
    
    // First-come-first-served check
    if (session.admitted !== false) {
      return res.status(409).json({ 
        error: 'Session already processed',
        current_status: session.admitted === true ? 'admitted' : 'not requesting'
      });
    }
    
    // Update to admitted
    const updated = await externalParticipantService.updateAdmissionStatus(
      sessionId,
      true, // admitted = true
      admitted_by
    );
    
    // Emit to ALL participants (for overlay removal)
    io.to(`meeting:${meetingId}`).emit('meeting:guest_admitted', {
      session_id: sessionId,
      meeting_id: meetingId,
      display_name: updated.display_name,
      admission_status: 'admitted',
      admitted_by: admitted_by
    });
    
    // Emit SPECIFIC event to guest (so they can proceed)
    io.to(`meeting:${meetingId}`).emit('meeting:admission_granted', {
      session_id: sessionId,
      meeting_id: meetingId,
      admitted_by: admitted_by
    });
    
    console.log(`[EXTERNAL] Guest ${sessionId} ADMITTED to ${meetingId} by ${admitted_by}`);
    
    res.json(updated);
  } catch (error) {
    console.error('[EXTERNAL] Error admitting guest:', error);
    res.status(500).json({ error: 'Failed to admit guest' });
  }
});

/**
 * POST /api/meetings/:meetingId/external/:sessionId/decline
 * CHANGED: Emit denial to specific guest
 */
router.post('/meetings/:meetingId/external/:sessionId/decline', async (req, res) => {
  try {
    const { meetingId, sessionId } = req.params;
    const { declined_by } = req.body;
    
    // Get current session
    const session = await externalParticipantService.getSession(sessionId);
    
    // First-come-first-served check
    if (session.admitted !== false) {
      return res.status(409).json({ 
        error: 'Session already processed',
        current_status: session.admitted === true ? 'admitted' : 'not requesting'
      });
    }
    
    // Update to declined (reset to null for retry)
    const updated = await externalParticipantService.updateAdmissionStatus(
      sessionId,
      null, // admitted = null (allows retry with cooldown)
      declined_by
    );
    
    // Emit to ALL participants (for overlay removal)
    io.to(`meeting:${meetingId}`).emit('meeting:guest_declined', {
      session_id: sessionId,
      meeting_id: meetingId,
      display_name: updated.display_name,
      admission_status: 'declined',
      declined_by: declined_by
    });
    
    // Emit SPECIFIC event to guest (so they see denial)
    io.to(`meeting:${meetingId}`).emit('meeting:admission_denied', {
      session_id: sessionId,
      meeting_id: meetingId,
      declined_by: declined_by,
      reason: 'Host declined your request'
    });
    
    console.log(`[EXTERNAL] Guest ${sessionId} DECLINED from ${meetingId} by ${declined_by}`);
    
    res.json(updated);
  } catch (error) {
    console.error('[EXTERNAL] Error declining guest:', error);
    res.status(500).json({ error: 'Failed to decline guest' });
  }
});
```

### 3. LiveKit Room Service Integration

**File:** `server/services/roomService.js` (or create if doesn't exist)

```javascript
const { RoomServiceClient } = require('livekit-server-sdk');

const roomService = new RoomServiceClient(
  process.env.LIVEKIT_URL,
  process.env.LIVEKIT_API_KEY,
  process.env.LIVEKIT_API_SECRET
);

/**
 * List participants in a LiveKit room
 * @param {string} roomName - LiveKit room name
 * @returns {Promise<Array>} List of participants
 */
async function listParticipants(roomName) {
  try {
    const participants = await roomService.listParticipants(roomName);
    return participants;
  } catch (error) {
    // Room might not exist yet
    if (error.message.includes('not found')) {
      return [];
    }
    throw error;
  }
}

module.exports = {
  listParticipants,
  // ... other room service methods
};
```

### 4. Guest Keybundle Endpoint

**File:** `server/routes/external.js`

```javascript
/**
 * Get guest's Signal prekey bundle
 * GET /api/meetings/external/keys/:sessionId?token=xxx
 * Used by participants to establish Signal session with guest
 */
router.get('/meetings/external/keys/:sessionId', async (req, res) => {
  try {
    const { sessionId } = req.params;
    const { token } = req.query;
    
    // Get session
    const session = await externalParticipantService.getSession(sessionId);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }
    
    // Validate token matches session's meeting
    const validationResult = await validateExternalToken(token, session.meeting_id);
    if (!validationResult.valid) {
      return res.status(403).json({ error: 'Invalid or expired token' });
    }
    
    // Return guest's Signal prekey bundle
    res.json({
      identity_key_public: session.identity_key_public,
      signed_pre_key: session.signed_pre_key,
      pre_keys: session.pre_keys
    });
  } catch (error) {
    console.error('[EXTERNAL] Error getting guest keys:', error);
    res.status(500).json({ error: 'Failed to get guest keys' });
  }
});
```

---

## Signal Protocol Integration

### Guest → Participant Key Request Flow

```
1. Guest has participant list: [
     { user_id: "uuid-1", device_id: 1 },
     { user_id: "uuid-2", device_id: 2 }
   ]

2. For each participant:
   a. Build Signal address: SignalProtocolAddress(user_id, device_id)
   
   b. Establish Signal session (if not exists):
      - Fetch participant's prekey bundle from server
      - Process prekey bundle to create session
   
   c. Create key request message:
      {
        type: "video_e2ee_key_request",
        meeting_id: "mtg_xxx",
        session_id: "guest_session_id",
        request_id: "unique_request_id"
      }
   
   d. Encrypt message with Signal session
   
   e. Send via HTTP POST /api/signal/send-message
      - Recipient: participant (user_id, device_id)
      - Encrypted payload
   
   f. Wait for response message:
      - Participant decrypts request
      - Participant retrieves E2EE key for meeting
      - Participant encrypts E2EE key with guest's session
      - Sends encrypted response

3. Guest receives response:
   - Decrypt with Signal session
   - Extract E2EE key
   - Store in memory
   - Mark participant as "key received"
```

### Participant → Guest Key Response Flow

```
1. Participant receives Signal message (type: video_e2ee_key_request)

2. Parse request:
   - meeting_id: Which meeting
   - session_id: Guest's session ID
   - request_id: For tracking

3. Retrieve E2EE key:
   - Get participant's E2EE key for this meeting
   - (Stored locally after joining/creating LiveKit room)

4. Build Signal session with guest:
   - Fetch guest's prekeys from server
     GET /api/meetings/external/keys/:sessionId
   - Process prekey bundle
   - Create session

5. Create response message:
   {
     type: "video_e2ee_key_response",
     meeting_id: "mtg_xxx",
     request_id: "matches_request",
     e2ee_key: <encrypted_bytes>
   }

6. Encrypt with guest's Signal session

7. Send response:
   - Need way to send to external session
   - Option A: Store in ExternalSession table, guest polls
   - Option B: WebSocket to guest (needs connection tracking)
   - Option C: Signal message to session_id (treat as virtual user)
```

---

## Questions & Considerations

### 1. **How do guests send/receive Signal messages?**

**✅ DECIDED: WebSocket with Token+SessionId Auth**

**Implementation:**
- **Guest WebSocket Connection:**
  - Namespace: `/external` (separate from authenticated users)
  - Auth: `{ session_id: 'xxx', token: 'invite_token' }`
  - Server validates session exists AND token matches meeting
  - Guest joins room: `meeting:${meetingId}`
  - Guest also joins personal room: `guest:${sessionId}` for direct messages

- **Message Types:**
  - `e2ee-key-guest-request-{meeting_id}` - Guest → Participant
  - `e2ee-key-guest-response-{meeting_id}` - Participant → Guest

- **Participant Response Flow:**
  - Listens for guest-specific message types in `meeting:${meetingId}` room
  - Fetches guest's keybundle: `GET /api/meetings/external/keys/:sessionId?token=xxx`
  - Establishes Signal session with guest
  - Sends E2EE key response to `guest:${sessionId}` room (direct to guest)

- **Security:**
  - Token validation prevents unauthorized access
  - Session expiry (24h) auto-disconnects guests
  - Rate limiting on message sending

### 2. **Participant discovery timing**

**✅ DECIDED: Auto-polling with manual refresh and smart timeout**

**Implementation:**
- Show "Waiting for meeting to start..." message
- **Auto-poll every 10 seconds** for participants
- "Refresh" button for manual check
- **Timeout after 15 minutes** → stop polling, show retry button
- **Smart status messages:**
  - If 0 participants AND `current_time < meeting.end_time` → "Meeting hasn't started yet"
  - If 0 participants AND `current_time >= meeting.end_time` → "Meeting appears to have ended"
- Retry button allows guest to restart polling

### 3. **Key exchange timeout**

**✅ DECIDED: 30 seconds total (first-response-wins)**

**Implementation:**
- Timeout: **30 seconds total** (not per participant)
- **First valid E2EE key received = success** (ignore additional responses)
- Guest only needs ONE participant's key to join
- If no response within 30s → show retry button
- Simplifies flow: no partial key tracking needed

### 4. **Multiple admission requests**

**✅ DECIDED: Unlimited retries with cooldown**

**Implementation:**
- **No limit** on retry attempts
- **5-second cooldown** between retry attempts (prevent spam)
- Guest can retry admission indefinitely after cooldown
- Reset `admitted` to `false` on retry (from `null` after decline)
- Re-emit admission request event
- Participants see updated request
- First-come-first-served still applies for each attempt
- Track `last_admission_request` timestamp for cooldown enforcement

### 5. **LiveKit Room Service API**

**✅ VERIFIED: LiveKit SDK available with fallback**

**Current Implementation:**
- ✅ `livekit-server-sdk` v2.7.2 installed
- ✅ `RoomServiceClient` available for participant listing
- ✅ Dynamic loading via wrapper: `server/lib/livekit-wrapper.js`
- ✅ Already used in `server/routes/client.js` line 1258
- ✅ Fallback polling mechanism exists if needed

**Usage:**
```javascript
const RoomServiceClient = await livekitWrapper.getRoomServiceClient();
const roomService = new RoomServiceClient(livekitUrl, apiKey, apiSecret);
const participants = await roomService.listParticipants(roomName);
```

### 6. **Guest cleanup**

**Implementation:**
- Status 'declined': Keep for 24 hours (guest might retry unlimited times)
- Status 'admitted' + guest joined: Keep until meeting ends
- Status 'waiting': Clean up after 24 hours
- All sessions: Clean up on session expiry (24h from creation)

### 7. **Admission overlay persistence**

**Implementation:**
- On mount, query waiting guests: GET `/api/meetings/:meetingId/external/waiting`
- Show all guests in 'admission_requested' status
- Real-time updates via Socket.IO

---

## Implementation Phases

### Phase 1: Backend Infrastructure (Week 1)
- [ ] Create `GET /api/meetings/:meetingId/livekit-participants?token=xxx` endpoint with validation
- [ ] Create `GET /api/meetings/external/keys/:sessionId?token=xxx` endpoint
- [ ] Create `POST /api/meetings/:meetingId/external/:sessionId/request-admission` endpoint with cooldown
- [ ] Modify `POST /api/meetings/external/register` (remove admission notification)
- [ ] Modify `POST /api/meetings/:meetingId/external/:sessionId/admit` (use boolean status)
- [ ] Modify `POST /api/meetings/:meetingId/external/:sessionId/decline` (reset to null)
- [ ] Add new Socket.IO events: `meeting:guest_admission_request`, `meeting:admission_granted`, `meeting:admission_denied`
- [ ] Integrate LiveKit RoomService for participant listing
- [ ] Change ExternalSession schema: `admitted` (boolean) + `last_admission_request` (timestamp)
- [ ] Implement token validation helper function
- [ ] Add meeting end_time check for smart status messages

### Phase 2: Guest Signal Messaging (1.5-2 Weeks)

**⚠️ TECHNICAL CLARIFICATION:**
- **Socket.IO Rooms**: The `meeting:${meetingId}` and `guest:${sessionId}` are **Socket.IO listener rooms** for WebSocket communication, NOT LiveKit media rooms
- **E2EE Key Exchange**: Keys are exchanged via **Socket.IO Signal 1:1 messages** (WebSocket), NOT through LiveKit WebRTC DataChannel
- **Dual Namespace Architecture**: Guests connect to `/external` namespace (unauthenticated), participants use main namespace (authenticated)

**✅ PHASE 2 COMPLETE (100%)**

**Tasks:**
- [x] Implement guest WebSocket connection on `/external` namespace
- [x] Add auth validation: session_id + token matching
- [x] Implement dual room joining: `meeting:${meetingId}` + `guest:${sessionId}`
- [x] Add guest message routing for special message types
- [x] Implement guest → participant key request flow (broadcast to meeting room)
- [x] Implement participant → guest key response flow (direct to guest room)
- [x] Add rate limiting on guest message sending (100 msg/min)
- [x] Implement session expiry auto-disconnect (24h)
- [x] Client-side: Implement guest WebSocket connection in Flutter (`external_guest_socket_service.dart`)
- [x] Client-side: Implement Signal protocol session setup

### Phase 3: Guest UI (Week 3)

**✅ PHASE 3 COMPLETE (100%)**

**Tasks:**
- [x] Redesign `external_prejoin_view.dart` state machine with enum states
- [x] Implement participant discovery UI with count display (polls `/api/meetings/:meetingId/livekit-participants`)
- [x] Implement smart status messages (not started vs ended)
- [x] Implement 15-minute polling timeout with retry button
- [x] Implement key exchange UI (30s timeout, first-response-wins)
- [x] Implement admission request UI with 5-second cooldown
- [x] Implement admission granted/denied handling
- [x] Add "Retry" buttons for key exchange and admission
- [x] Test complete guest flow (pending backend fixes)

### Phase 4: Participant UI (Week 4)

**✅ PHASE 4 COMPLETE (100%)**

**Tasks:**
- [x] Update `admission_overlay.dart` to listen for `meeting:guest_admission_request` event
- [x] Show guest info (display name, session ID, wait time) in overlay
- [x] Implement notification sound when guest requests admission
- [x] Implement first-come-first-served UI feedback (shows message if already processed)
- [x] Add error handling for already-processed sessions
- [x] Auto-expand overlay when new admission request arrives
- [x] Track processed sessions to prevent duplicate actions

### Phase 5: Testing & Polish (Week 5)
- [ ] E2E testing: Guest join with 1 participant
- [ ] E2E testing: Guest join with multiple participants
- [ ] E2E testing: No participants (meeting not started)
- [ ] E2E testing: Declined admission
- [ ] E2E testing: Multiple guests simultaneously
- [ ] E2E testing: Participant joins after guest
- [ ] Load testing: 10+ guests waiting
- [ ] Fix bugs and edge cases

---

## Success Criteria

✅ Guest can discover LiveKit participants before admission  
✅ Guest exchanges E2EE keys with all participants via Signal 1:1  
✅ Guest sees clear status for each key exchange  
✅ Guest can retry failed key exchanges  
✅ Guest cannot join until clicking "Join Meeting"  
✅ Participants receive admission request AFTER key exchange  
✅ First participant to respond (admit/decline) takes precedence  
✅ Guest receives clear feedback on admission status  
✅ Declined guest can retry or refresh  
✅ All flows work without SenderKey table (meetings use 1:1 sessions)

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Guest WebSocket auth complexity | High | Use session_id + token auth, separate `/external` namespace |
| Signal message delivery to guests | High | Use dedicated `guest:${sessionId}` rooms for direct messaging |
| Token scraping participant list | Medium | Validate token matches meetingId on every request |
| Multiple admission requests spam | Low | 5-second cooldown enforced server-side |
| LiveKit room not created yet | Low | Auto-refresh, differentiate not-started vs ended |
| Guest loses connection during key exchange | Medium | Save progress in sessionStorage, resume on reconnect |
| First-response timeout edge case | Low | Clear 30s total timeout, retry button |
| Database write queue timeout | Medium | Already handled (5s timeout with background write) |

---

## Decisions on Open Questions

### Q1: Should guests see other waiting guests?
**✅ DECISION:** No
- Reason: Privacy concerns and unnecessary complexity
- Keep it simple for v1

### Q2: Maximum retry attempts for admission?
**✅ DECISION:** Unlimited retries with 5-second cooldown
- Prevents spam while allowing persistent guests
- Cooldown enforced via `last_admission_request` timestamp

### Q3: Show participant count to guests before key exchange?
**✅ DECISION:** Yes
- Display: "X participants in the meeting"
- Helps guest decide if meeting is active
- Shown during participant discovery phase

### Q4: Notification sound for admission requests?
**✅ DECISION:** Yes
- Browser notification sound when guest requests admission
- Helps participants notice requests faster
- Optional: Desktop notification (if permissions granted)

### Q5: Guests join LiveKit room before admission?
**✅ DECISION:** No
- Too complex and security risk
- Stick with current plan: admit first, then join

---

## Next Steps

1. **Review this document** with team
2. **Clarify open questions**
3. **Estimate effort** for each phase
4. **Assign tasks** to developers
5. **Create tickets** in project management tool
6. **Begin Phase 1** implementation

---

## Notes

- This redesign makes the guest flow more transparent and user-friendly
- Key exchange before admission ensures E2EE is ready before joining
- First-come-first-served prevents race conditions
- Clear error states help guests understand what's happening
- Retry mechanisms make the flow more robust
