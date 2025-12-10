# Socket.IO Events Reference - Meetings & Calls

**Backend Implementation:** Complete ✅  
**Frontend Integration:** Pending  
**Server Status:** Running on port 3000

---

## 📋 Overview

This document provides a complete reference for all Socket.IO events used in the meetings and instant calls feature. Frontend developers should implement listeners for all "Server → Client" events and emitters for all "Client → Server" events.

---

## 🔌 Connection & Authentication

All Socket.IO events require authentication via the existing `getUserId()` helper. Ensure the client socket is authenticated before emitting any events.

**Helper Function:**
```javascript
// Backend: Emits to all connected devices for a userId
function emitToUser(io, userId, eventName, data) {
  // Finds all sockets matching userId across multiple devices
  // Emits event to each socket
}
```

---

## 📅 Meeting Events

### 1. Create Meeting
**Direction:** Client → Server  
**Event:** `meeting:create`  
**Payload:**
```javascript
{
  title: string,           // Encrypted with Signal Protocol
  description: string,     // Encrypted with Signal Protocol
  startTime: datetime,     // ISO 8601 format
  endTime: datetime,       // ISO 8601 format
  participants: string[],  // Array of userIds
  allowExternal: boolean   // Allow external guests via link
}
```
**Response (callback):**
```javascript
{
  success: boolean,
  meeting: Meeting,        // Full meeting object with participants
  error?: string
}
```
**Broadcast to Participants:**
```javascript
// Event: meeting:created
{
  meeting: Meeting,
  encrypted_data: {
    title: string,       // Signal encrypted
    description: string, // Signal encrypted
    avatar: string       // Signal encrypted
  }
}
```

**TODO:** Backend needs to implement Signal Protocol encryption for `meeting:created` event.

---

### 2. Update Meeting
**Direction:** Client → Server  
**Event:** `meeting:update`  
**Payload:**
```javascript
{
  meeting_id: string,      // mtg_abc123
  title?: string,          // Optional
  description?: string,    // Optional
  startTime?: datetime,    // Optional
  endTime?: datetime       // Optional
}
```
**Response (callback):**
```javascript
{
  success: boolean,
  meeting: Meeting,
  error?: string
}
```
**Broadcast to Participants:**
```javascript
// Event: meeting:updated
{
  meeting: Meeting
}
```

---

### 3. Start Meeting
**Direction:** Client → Server  
**Event:** `meeting:start`  
**Payload:**
```javascript
{
  meeting_id: string       // mtg_abc123
}
```
**Response (callback):**
```javascript
{
  success: boolean,
  error?: string
}
```
**Broadcast to Participants:**
```javascript
// Event: meeting:started
{
  meeting_id: string
}
```

---

### 4. Register Participant (Join Meeting)
**Direction:** Client → Server  
**Event:** `meeting:register-participant`  
**Payload:**
```javascript
{
  meeting_id: string       // mtg_abc123
}
```
**Response (callback):**
```javascript
{
  success: boolean,
  error?: string
}
```
**Broadcast (if first participant):**
```javascript
// Event: meeting:first_participant_joined
{
  meeting_id: string
}
```

**Note:** First participant joining triggers conditional external access (if enabled).

---

### 5. Leave Meeting
**Direction:** Client → Server  
**Event:** `meeting:leave`  
**Payload:**
```javascript
{
  meeting_id: string       // mtg_abc123 or call_abc123
}
```
**Response (callback):**
```javascript
{
  success: boolean,
  error?: string
}
```

**Note:** If instant call and last participant, triggers immediate cleanup.

---

### 6. Invite Users to Active Meeting
**Direction:** Client → Server  
**Event:** `meeting:invite-live`  
**Payload:**
```javascript
{
  meeting_id: string,      // mtg_abc123
  user_ids: string[]       // Array of userIds to invite
}
```
**Response (callback):**
```javascript
{
  success: boolean,
  error?: string
}
```
**Broadcast to Invited Users:**
```javascript
// Event: meeting:live_invite_sent
{
  meeting: Meeting,        // Full meeting object
  invited_by: string       // userId who sent invitation
}
```

---

### 7. Generate External Invitation Link
**Direction:** Client → Server  
**Event:** `meeting:generate_link`  
**Payload:**
```javascript
{
  meeting_id: string       // mtg_abc123
}
```
**Response (callback):**
```javascript
{
  success: boolean,
  token: string,           // UUID invitation token
  error?: string
}
```
**Broadcast to Room:**
```javascript
// Event: meeting:link_generated
{
  meeting_id: string,
  token: string            // For showing in UI
}
```

---

## 📞 Call Events (Instant Calls)

### 8. Create Instant Call
**Direction:** Client → Server  
**Event:** `call:create`  
**Payload:**
```javascript
{
  title: string,           // Optional, e.g., "Call with Alice"
  participants: string[]   // Array of userIds
}
```
**Response (callback):**
```javascript
{
  success: boolean,
  call: Meeting,           // Full meeting object with is_instant_call=true
  error?: string
}
```

**Note:** No broadcast at this stage. Use `call:notify` to send ringtones.

---

### 9. Send Call Ringtone
**Direction:** Client → Server  
**Event:** `call:notify`  
**Payload:**
```javascript
{
  call_id: string,         // call_abc123
  recipients: string[]     // Array of userIds to notify
}
```
**Response (callback):**
```javascript
{
  success: boolean,
  notified_count: number,  // Number of online users notified
  error?: string
}
```
**Broadcast to Online Recipients:**
```javascript
// Event: call:incoming
{
  call: Meeting,
  caller: {
    user_id: string,
    display_name: string,  // Signal encrypted
    avatar: string         // Signal encrypted
  }
}
```

**TODO:** Backend needs to implement Signal Protocol encryption for caller info.

**Frontend Implementation:**
- Play ringtone audio when receiving `call:incoming`
- Show full-width top bar with caller info (name, avatar)
- Provide Accept/Decline buttons

---

### 10. Accept Call
**Direction:** Client → Server  
**Event:** `call:accept`  
**Payload:**
```javascript
{
  call_id: string          // call_abc123
}
```
**Response (callback):**
```javascript
{
  success: boolean,
  error?: string
}
```
**Broadcast to All Participants:**
```javascript
// Event: call:accepted
{
  call_id: string,
  user_id: string,         // Who accepted
  timestamp: datetime
}
```

**Frontend Implementation:**
- Stop ringtone
- Navigate to video conference screen
- Update participant list to show "accepted" status

---

### 11. Decline Call
**Direction:** Client → Server  
**Event:** `call:decline`  
**Payload:**
```javascript
{
  call_id: string          // call_abc123
}
```
**Response (callback):**
```javascript
{
  success: boolean,
  error?: string
}
```
**Broadcast to Caller:**
```javascript
// Event: call:declined
{
  call_id: string,
  user_id: string,         // Who declined
  timestamp: datetime
}
```

**Frontend Implementation:**
- Stop ringtone
- Dismiss incoming call overlay
- Update caller's participant list (show "declined" status)

---

## 👥 External Participant Events

### 12. Guest Joins Room (WebSocket)
**Direction:** Client → Server  
**Event:** `meeting:guest_join`  
**Payload:**
```javascript
{
  meeting_id: string,      // mtg_abc123
  session_id: string,      // Guest's session UUID
  display_name: string     // Guest's name (encrypted)
}
```
**Response (callback):**
```javascript
{
  success: boolean,
  error?: string
}
```
**Broadcast to All Server Users:**
```javascript
// Event: meeting:guest_join
{
  meeting_id: string,
  session_id: string,
  display_name: string,    // For admission overlay UI
  timestamp: datetime
}
```

**Frontend Implementation:**
- Show admission request overlay with guest name
- Provide Admit/Decline buttons
- Play notification sound (optional)

---

### 13. Admit External Guest
**Direction:** Client → Server  
**Event:** `meeting:admit_guest`  
**Payload:**
```javascript
{
  meeting_id: string,      // mtg_abc123
  session_id: string       // Guest's session UUID
}
```
**Response (callback):**
```javascript
{
  success: boolean,
  error?: string
}
```
**Broadcast to Room (including guest):**
```javascript
// Event: meeting:admission_status
{
  meeting_id: string,
  session_id: string,
  status: 'admitted',
  admitted_by: string      // userId who admitted
}
```

**Frontend Implementation (Guest):**
- Listen for `meeting:admission_status` with `status='admitted'`
- Navigate to video conference screen
- Show "Connecting..." state

---

### 14. Decline External Guest
**Direction:** Client → Server  
**Event:** `meeting:decline_guest`  
**Payload:**
```javascript
{
  meeting_id: string,      // mtg_abc123
  session_id: string       // Guest's session UUID
}
```
**Response (callback):**
```javascript
{
  success: boolean,
  error?: string
}
```
**Broadcast to Room (including guest):**
```javascript
// Event: meeting:admission_status
{
  meeting_id: string,
  session_id: string,
  status: 'declined'
}
```

**Frontend Implementation (Guest):**
- Listen for `meeting:admission_status` with `status='declined'`
- Show "Access denied" message
- Provide "Request again" button or exit

---

## 🟢 Presence Events

### 15. Send Heartbeat
**Direction:** Client → Server  
**Event:** `presence:heartbeat`  
**Payload:** None (uses socket authentication)  
**Frequency:** Every 60 seconds

**Response (callback):**
```javascript
{
  success: boolean,
  error?: string
}
```
**Broadcast to All Users:**
```javascript
// Event: presence:user_connected
{
  user_id: string,
  status: 'online',
  timestamp: datetime
}
```

**Frontend Implementation:**
- Create timer in PresenceService.dart
- Emit `presence:heartbeat` every 60 seconds
- Listen for `presence:user_connected` to update UI

---

### 16. User Disconnected (Server-initiated)
**Direction:** Server → Client  
**Event:** `presence:user_disconnected`  
**Payload:**
```javascript
{
  user_id: string,
  last_seen: datetime
}
```

**Frontend Implementation:**
- Listen for this event globally
- Update online status indicators across all views (channels, 1:1 chats, participants)
- Show "Last seen X minutes ago" in user profiles

**Triggered By:**
- Socket disconnect (WebSocket closed)
- Presence cron job (no heartbeat for 2+ minutes)

---

## 🔄 Disconnect Handler Enhancements

When a user disconnects (WebSocket closes), the server automatically:

1. **Mark User Offline:**
   - Calls `PresenceService.markOffline(userId)`
   - Broadcasts `presence:user_disconnected` to all users

2. **Cleanup Instant Calls:**
   - Calls `meetingCleanupService.handleParticipantDisconnect(userId)`
   - Deletes instant call if last participant left

3. **Mark External Session Left:**
   - If socket has `externalSessionId`, marks session as left
   - Notifies server users

**Frontend Impact:**
- No explicit leave event needed when user closes app
- Instant calls auto-cleanup when app closed
- External guests auto-leave when connection lost

---

## 📱 Frontend Implementation Checklist

### Service Layer
- [ ] Create `MeetingService.dart` with Socket.IO listeners
- [ ] Create `InstantCallService.dart` (wrapper around MeetingService)
- [ ] Create `PresenceService.dart` with 60s heartbeat timer
- [ ] Create `ExternalParticipantService.dart` for guest flow

### Event Listeners (Add to Socket Service)
- [ ] `meeting:created` - Update meetings list
- [ ] `meeting:updated` - Update meeting details
- [ ] `meeting:started` - Navigate to video screen
- [ ] `meeting:first_participant_joined` - Enable external access
- [ ] `meeting:live_invite_sent` - Show notification
- [ ] `meeting:link_generated` - Update UI with link
- [ ] `call:incoming` - Play ringtone, show overlay
- [ ] `call:accepted` - Stop ringtone, update UI
- [ ] `call:declined` - Stop ringtone, update UI
- [ ] `meeting:guest_join` - Show admission request overlay
- [ ] `meeting:admission_status` - Handle admit/decline response
- [ ] `presence:user_connected` - Update online status indicators
- [ ] `presence:user_disconnected` - Update offline status

### Event Emitters (Add to Service Classes)
- [ ] `meeting:create` - Create scheduled meeting
- [ ] `meeting:update` - Edit meeting details
- [ ] `meeting:start` - Start meeting from scheduled
- [ ] `meeting:register-participant` - Join meeting
- [ ] `meeting:leave` - Leave meeting/call
- [ ] `meeting:invite-live` - Invite to active meeting
- [ ] `meeting:generate_link` - Get external invitation link
- [ ] `call:create` - Create instant call
- [ ] `call:notify` - Send ringtones to recipients
- [ ] `call:accept` - Accept incoming call
- [ ] `call:decline` - Decline incoming call
- [ ] `meeting:guest_join` - Guest joins room (external participants)
- [ ] `meeting:admit_guest` - Admit external guest
- [ ] `meeting:decline_guest` - Decline external guest
- [ ] `presence:heartbeat` - Send every 60s

### UI Components
- [ ] IncomingCallOverlay - Full-width top bar with Accept/Decline
- [ ] AdmissionRequestOverlay - Show external guest requests
- [ ] MeetingNotificationBar - 15-min warning + start notification
- [ ] OnlineStatusIndicator - Green dot for online users
- [ ] MeetingsList - Upcoming/past meetings view
- [ ] LiveInviteDialog - Invite users to active meeting

---

## 🔐 Signal Protocol Encryption TODOs

The following events need Signal Protocol encryption for sensitive data:

### meeting:created
**Fields to Encrypt:**
- `title`
- `description`
- `avatar` (if present)

### call:incoming
**Fields to Encrypt:**
- `caller.display_name`
- `caller.avatar`

**Implementation Note:** Backend handlers have `// TODO: Encrypt with Signal Protocol` comments. Frontend should handle decryption when receiving these events.

---

## 🧪 Testing Recommendations

### Unit Tests
- Test each Socket.IO event emitter/listener
- Mock socket responses for different scenarios
- Test error handling (network failures, auth errors)

### Integration Tests
- Multi-device scenarios (same user on phone + desktop)
- Meeting lifecycle (create → start → join → leave → cleanup)
- Instant call flow (create → notify → accept → end)
- External participant admission flow
- Presence tracking across disconnects/reconnects

### Manual Testing
- Ringtone plays correctly with caller info
- External guests can join via link
- Admission overlay shows pending guests
- Online status updates in real-time
- Instant calls delete immediately when all leave

---

## 📊 Event Flow Diagrams

### Instant Call Flow
```
1. User A clicks "Call" on User B's profile
   → Client emits: call:create { participants: [userB_id] }
   
2. Server creates meeting with is_instant_call=true
   → Server responds: { call: Meeting }
   
3. Client emits: call:notify { call_id, recipients: [userB_id] }
   
4. Server checks if User B online
   → Server emits to User B: call:incoming { call, caller: { name, avatar } }
   
5. User B's client plays ringtone, shows overlay
   
6. User B clicks "Accept"
   → Client emits: call:accept { call_id }
   
7. Server broadcasts to all participants
   → Server emits: call:accepted { call_id, user_id: userB_id }
   
8. Both clients navigate to video conference screen
```

### External Participant Flow
```
1. Server user generates invitation link
   → Client emits: meeting:generate_link { meeting_id }
   → Server responds: { token: UUID }
   
2. Guest clicks link → validates token (REST API)
   → GET /api/meetings/external/join/:token
   
3. Guest enters name, device selection
   → POST /api/meetings/external/register { meeting_id, display_name, keys }
   → Response: { session_id }
   
4. Guest socket joins room
   → Client emits: meeting:guest_join { meeting_id, session_id, display_name }
   → Server broadcasts to room: meeting:guest_join
   
5. Server users see admission request overlay
   
6. Server user clicks "Admit"
   → Client emits: meeting:admit_guest { meeting_id, session_id }
   → Server broadcasts to room: meeting:admission_status { status: 'admitted' }
   
7. Guest client navigates to video screen
```

---

## 🔗 Related Documentation

- **Backend Implementation:** [MEETINGS_BACKEND_IMPLEMENTATION_COMPLETE.md](./MEETINGS_BACKEND_IMPLEMENTATION_COMPLETE.md)
- **Action Plan:** [MEETINGS_AND_CALLS_ACTION_PLAN.md](./MEETINGS_AND_CALLS_ACTION_PLAN.md)
- **REST API Reference:** See route files in `server/routes/`

---

**Document Version:** 1.0  
**Last Updated:** December 9, 2024  
**Backend Status:** ✅ Complete and Running  
**Frontend Status:** ⏸️ Awaiting Implementation
