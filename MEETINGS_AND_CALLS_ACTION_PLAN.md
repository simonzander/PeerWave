# Meetings & Instant Calls Feature - Action Plan

## ✅ Phase 1 Backend Implementation: COMPLETE (2024-12-09)

**Status:** Backend infrastructure and Socket.IO real-time events fully implemented and tested.

### Completed Components:
- ✅ Database schema (6 tables via migration)
- ✅ MeetingService (463 lines) - Core business logic
- ✅ MeetingCleanupService (264 lines) - Cron jobs + instant call cleanup
- ✅ PresenceService (236 lines) - 1-minute heartbeat tracking
- ✅ ExternalParticipantService (329 lines) - Guest sessions
- ✅ REST API (5 route files, 45+ endpoints)
- ✅ Socket.IO events (15 real-time handlers)
- ✅ Helper functions (emitToUser for multi-device broadcast)

**Server Status:** Running successfully with all services initialized.

---

## Overview
This document outlines the implementation plan for adding scheduled meetings, instant calls, online status tracking, and external participant support to PeerWave.

**🔑 Key Architecture Principle:**
**Instant calls ARE meetings that start immediately.** Maximize code reuse by treating temp channels as meetings with minimal conditional logic. Both 1:1 and group instant calls use the exact same implementation - only participant count differs. This prevents double coding and ensures consistent behavior across all video features.

---

## 🎯 Core Features

### 1. **Meetings System**
Scheduled video-only channels with start/end times, automatic cleanup (8h after end), and pre-meeting notifications (15 min before + at start time).

### 2. **Instant Calls**
Video-only "calls" created on-demand from 1:1 chats or group channels with phone-style ringtone notifications. **Stored in same `meetings` table** with `is_instant_call = TRUE`. No distinction between "1:1" and "group" calls - all are just calls with N participants. **Now supports external participants via invitation links** (same as meetings). Cleanup immediately when all participants leave, or after 8 hours fallback.

**Key Points:**
- Same table, same service, same UI as meetings
- Ringtone plays AFTER Signal decryption (so caller name/avatar available)
- Can add participants mid-call (same meetingId preserved)
- External guests can join via link (manual admission required)

### 3. **Online Status System**
Real-time presence tracking (1-minute heartbeat) for users in active conversations and channels. Only online/offline states (no "away").

### 4. **External Participants**
Guest access to meetings via invitation links with temporary E2EE credentials. Video-only, expires when all server users leave or after 24h max.

### 5. **Event Bus Integration**
Real-time UI updates (with batching) across all views for messages, status changes, and notifications. Debounced to prevent UI thrashing.

### 6. **Meeting Permissions System**
Separate role system for meetings (Owner, Manager, Member) with granular permissions for meeting controls.

---

## 🏗️ Unified Architecture: Meetings = Instant Calls

**Core Principle:** Instant calls are meetings with `startTime = now()` and `isInstantCall = true`. Same table, same service, same UI.

### Backend Unification ✅
- **Single table:** `meetings` table stores both (is_instant_call flag)
- **Single service:** `MeetingService` handles everything
- **Single model:** Meeting object with `isInstantCall` property
- **Unified cleanup:**
  - Instant calls: Delete immediately when all participants leave
  - Scheduled meetings: Delete 8 hours after end
  - Fallback: Delete anything older than 8 hours

```javascript
// Single function for meetings and calls
function createMeeting(data) {
  if (data.isInstantCall) {
    data.startTime = new Date(); // Start now
    data.status = 'in_progress';
    data.title = data.title || 'Call';
  }
  // External participants supported for both
  return db.insert('meetings', data);
}
```

### Frontend Unification ✅
- **Single model:** `Meeting` class with `isInstantCall` boolean
- **Single service:** `InstantCallService` is a thin wrapper around `MeetingService`
- **Single UI:** `VideoConferenceView` for both (same component)
- **Single invite dialog:** `LiveInviteDialog` for both (no conditions needed)
- **No 1:1 vs Group distinction:** All calls are just "calls" with N participants
- **External participants:** Supported for both meetings AND calls

### What's Different (Minimal)
- **Instant calls only:**
  - Ringtone notification (plays AFTER Signal decryption for caller name)
  - Accept/Decline buttons in notification overlay
  - No scheduling UI (start time is now)
  - Immediate cleanup when all leave
- **Scheduled meetings only:**
  - 15-minute warning notifications
  - Join button (vs Accept button)
  - Show in Meetings page
  - Cleanup 8 hours after end

### Key Decisions Applied ✅
1. ✅ Merged temp_channels into meetings table
2. ✅ Single Meeting model with isInstantCall flag
3. ✅ Call endpoints are wrappers
4. ✅ meetingId stays the same when adding participants
5. ✅ No "1:1" vs "group" distinction - just "calls"
6. ✅ Immediate cleanup when all leave, 8h fallback
7. ✅ External participants supported for calls (via link)
8. ✅ Ringtone plays after Signal decryption completes

---

## 🔄 Code Reuse & Patterns

### Existing Components to Leverage:

**1. User Management Patterns (from `channel_members_screen.dart`):**
- User search with `ApiService.searchUsers()` (debounced, returns displayName + uuid)
- Profile loading via `UserProfileService.instance.getProfileOrLoad()` with reactive callbacks
- Square avatar builder with base64/network image support and fallback initials
- Role assignment dialogs with dropdown selection
- Kick/remove user confirmation dialogs
- Loading states and error handling patterns

**2. Settings Screen Patterns (from `channel_settings_screen.dart`):**
- Form validation with TextEditingController listeners
- Unsaved changes detection (`_hasChanges` flag)
- Role dropdown selection with `RoleProvider.getRolesByScope()`
- Privacy toggle (Switch) for meeting visibility
- Danger zone UI pattern for delete actions
- Permission-based UI rendering (owner-only actions)
- GoRouter navigation after delete: `context.go('/app/meetings')`

**3. PreJoin Flow (from `video_conference_prejoin_view.dart`):**
- Device enumeration: `Hardware.instance.enumerateDevices()`
- Permission requests: `LocalVideoTrack.createCameraTrack()` + `LocalAudioTrack.createMicrophoneTrack()`
- Camera preview with `RTCVideoView` widget
- Device selection dropdowns (cameras, microphones)
- Participant registration: `SocketService().emit('video:register-participant')`
- E2EE key exchange flow (generate or request)
- Sender key preloading: `ApiService.dio.get('/client/channels/:channelId/participants')`
- Join button state management (disabled until ready)

**4. Video Conference UI (from `video_conference_view.dart`):**
- Smart grid layout with screen share detection
- Participant visibility management (max visible calculation based on screen size)
- Audio state tracking with `ValueNotifier<bool>` for speaking indicators
- Profile caching to prevent flickering (`_displayNameCache`, `_profilePictureCache`)
- Control buttons: audio/video toggle, screen share, device selectors
- Context menu for participants (volume, mute, pin/unpin)
- E2EE status indicators
- Real-time participant updates via `Consumer<VideoConferenceService>`
- **NEW: Invite button** (for meetings/calls) - Opens dialog to:
  - Invite server users (search + select)
  - Generate external invite link (meetings only)
  - Show recently invited users with status (pending/joined)

### Key Services to Reuse:

**API Patterns:**
```dart
// User search (meetings participant selection)
final resp = await ApiService.searchUsers(widget.host, query);
final users = (resp.data as List).map((u) => {
  'uuid': u['uuid'],
  'displayName': u['displayName'],
}).toList();

// Channel/meeting updates
final resp = await ApiService.updateChannel(
  host, meetingId,
  name: title,
  description: description,
);

// Delete channel/meeting
final resp = await ApiService.delete(
  '\$hostUrl/client/meetings/\$meetingId',
);
```

**Profile Loading:**
```dart
final profile = UserProfileService.instance.getProfileOrLoad(
  userId,
  onLoaded: (profile) {
    if (mounted) setState(() {
      _profileCache[userId] = profile;
    });
  },
);
```

**Socket.IO Patterns:**
```dart
// Request with response
final completer = Completer<Map<String, dynamic>>();
void listener(dynamic data) {
  completer.complete(data);
}
SocketService().registerListener('meeting:info', listener);
SocketService().emit('meeting:check-status', {'meetingId': meetingId});
final result = await completer.future.timeout(Duration(seconds: 5));
SocketService().unregisterListener('meeting:info', listener);
```

**Permission Checks:**
```dart
final canManageRoles = roleProvider.isAdmin ||
    roleProvider.isMeetingOwner(meetingId) ||
    roleProvider.hasMeetingPermission(meetingId, 'role.assign');
```

---

## 📋 Implementation Phases

---

## **PHASE 1: Backend Infrastructure** (3-4 days)

### 1.1 Database Schema Updates

**New Tables:**

```sql
-- Meetings table (SEPARATE from channels - no channel_id reference)
CREATE TABLE meetings (
  meeting_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT,
  created_by TEXT NOT NULL,
  start_time TIMESTAMP NOT NULL,
  end_time TIMESTAMP NOT NULL,
  is_recurring BOOLEAN DEFAULT FALSE,
  recurrence_pattern TEXT, -- 'daily', 'weekly', 'monthly', NULL (future feature)
  max_participants INTEGER,
  allow_external BOOLEAN DEFAULT FALSE,
  external_join_token TEXT UNIQUE, -- For invitation links
  status TEXT DEFAULT 'scheduled', -- 'scheduled', 'in_progress', 'ended', 'cancelled'
  
  -- Meeting-specific settings
  voice_only BOOLEAN DEFAULT FALSE, -- Force audio-only mode
  mute_on_join BOOLEAN DEFAULT FALSE, -- Participants muted when joining
  waiting_room_enabled BOOLEAN DEFAULT FALSE, -- Host must admit participants
  
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_start_time (start_time),
  INDEX idx_created_by (created_by),
  INDEX idx_status (status)
);

-- Meeting participants (separate from channel members)
CREATE TABLE meeting_participants (
  participant_id INTEGER PRIMARY KEY AUTOINCREMENT,
  meeting_id TEXT REFERENCES meetings(meeting_id) ON DELETE CASCADE,
  user_id TEXT NOT NULL,
  role_id TEXT NOT NULL, -- 'owner', 'manager', 'member'
  status TEXT DEFAULT 'invited', -- 'invited', 'accepted', 'declined', 'attended'
  joined_at TIMESTAMP,
  left_at TIMESTAMP,
  duration_seconds INTEGER, -- How long they were in the meeting
  UNIQUE(meeting_id, user_id),
  INDEX idx_meeting_user (meeting_id, user_id)
);

-- Meeting roles (separate role system for meetings)
CREATE TABLE meeting_roles (
  role_id TEXT PRIMARY KEY,
  role_name TEXT NOT NULL,
  is_default BOOLEAN DEFAULT FALSE,
  -- Permissions
  can_start_meeting BOOLEAN DEFAULT FALSE,
  can_invite_participants BOOLEAN DEFAULT FALSE,
  can_remove_participants BOOLEAN DEFAULT FALSE,
  can_mute_participants BOOLEAN DEFAULT FALSE,
  can_end_meeting BOOLEAN DEFAULT FALSE,
  can_share_screen BOOLEAN DEFAULT TRUE,
  can_enable_camera BOOLEAN DEFAULT TRUE,
  can_enable_microphone BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Pre-populate default meeting roles
INSERT INTO meeting_roles (role_id, role_name, is_default, can_start_meeting, can_invite_participants, can_remove_participants, can_mute_participants, can_end_meeting, can_share_screen, can_enable_camera, can_enable_microphone) VALUES
('meeting_owner', 'Owner', TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE),
('meeting_manager', 'Manager', TRUE, TRUE, TRUE, FALSE, TRUE, FALSE, TRUE, TRUE, TRUE),
('meeting_member', 'Member', TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, TRUE, TRUE, TRUE);

-- Note: can_invite_participants = TRUE allows inviting during active meeting + generating external links
-- Note: Instant calls also stored in this table with is_instant_call = TRUE
-- Note: Instant calls support external participants via invitation links (same as meetings)

-- Online status tracking (1-minute heartbeat)
CREATE TABLE user_presence (
  user_id TEXT PRIMARY KEY,
  status TEXT DEFAULT 'offline', -- 'online', 'offline' (no 'away' for simplicity)
  last_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  last_heartbeat TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  socket_id TEXT, -- Current socket connection ID
  INDEX idx_status (status),
  INDEX idx_last_heartbeat (last_heartbeat)
);

-- External participants (temporary guests for meetings)
CREATE TABLE external_participants (
  session_id TEXT PRIMARY KEY,
  meeting_id TEXT REFERENCES meetings(meeting_id) ON DELETE CASCADE,
  display_name TEXT NOT NULL,
  email TEXT, -- Optional
  identity_key_public TEXT NOT NULL, -- Temporary Signal identity
  signed_pre_key TEXT NOT NULL,
  pre_keys TEXT NOT NULL, -- JSON array
  admission_status TEXT DEFAULT 'pending', -- 'pending', 'admitted', 'declined'
  admitted_by TEXT REFERENCES users(uuid), -- Which user admitted the guest
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMP NOT NULL, -- Expires when all server users leave or 24h max
  is_active BOOLEAN DEFAULT TRUE,
  INDEX idx_meeting_id (meeting_id),
  INDEX idx_expires_at (expires_at),
  INDEX idx_is_active (is_active),
  INDEX idx_admission_status (admission_status)
);

-- Meeting notifications (track which users have been notified)
CREATE TABLE meeting_notifications (
  notification_id INTEGER PRIMARY KEY AUTOINCREMENT,
  meeting_id TEXT REFERENCES meetings(meeting_id) ON DELETE CASCADE,
  user_id TEXT NOT NULL,
  notification_type TEXT NOT NULL, -- '15_min_before', 'at_start'
  sent_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  dismissed_at TIMESTAMP,
  is_dismissed BOOLEAN DEFAULT FALSE,
  UNIQUE(meeting_id, user_id, notification_type),
  INDEX idx_meeting_user (meeting_id, user_id)
);
```

**Questions:**
- ~~Should meetings table reference existing channels, or be completely independent?~~ ✅ **ANSWERED: Completely independent**

---

### 1.2 REST API Endpoints

**Meeting Management:**
```
POST   /api/meetings                    # Create meeting (any authenticated user)
GET    /api/meetings                    # List meetings (filter: upcoming/past/my)
GET    /api/meetings/:meetingId         # Get meeting details
PATCH  /api/meetings/:meetingId         # Update meeting (owner/manager only)
DELETE /api/meetings/:meetingId         # Cancel meeting (owner only)
POST   /api/meetings/:meetingId/join    # Join meeting (opens WebRTC channel)

GET    /api/meetings/upcoming           # Meetings starting within 24 hours
GET    /api/meetings/past               # Meetings ended within 8 hours (includes duration, participants)
GET    /api/meetings/my                 # User's meetings (created or invited)

# Participants
POST   /api/meetings/:meetingId/participants       # Invite users (owner/manager) - works during active meeting
DELETE /api/meetings/:meetingId/participants/:userId # Remove participant (owner/manager)
PATCH  /api/meetings/:meetingId/participants/:userId # Update status (accept/decline)
POST   /api/meetings/:meetingId/invite-live     # Invite users to active meeting (owner/manager/with permission)
POST   /api/meetings/:meetingId/generate-link   # Generate new external invite link during meeting (owner/manager)

# Meeting roles
GET    /api/meetings/roles              # Get available meeting roles
POST   /api/meetings/:meetingId/roles   # Assign role to participant (owner only)

# Meeting settings
PATCH  /api/meetings/:meetingId/settings # Update voice_only, mute_on_join, etc. (owner/manager)

# Bulk operations
DELETE /api/meetings/bulk              # Delete multiple meetings/calls (owner/admin)
                                        # Body: { meetingIds: ['mtg_123', 'call_456'] }
                                        # Returns: { deleted: 5, failed: 0, errors: [] }
```

**Instant Calls:**
```
# NOTE: These are WRAPPER endpoints that call meeting endpoints internally
# Backend stores calls in meetings table with is_instant_call = TRUE
POST   /api/calls/instant               # Wrapper → createMeeting(isInstantCall: true)
GET    /api/calls/:callId               # Wrapper → GET /api/meetings/:meetingId
DELETE /api/calls/:callId               # Wrapper → DELETE /api/meetings/:meetingId
POST   /api/calls/notify                # Call-specific: Notify online participants (trigger ringtone)
POST   /api/calls/accept                # Call-specific: Accept incoming call (then → joinMeeting)
POST   /api/calls/decline               # Call-specific: Decline incoming call
GET    /api/calls/:callId/participants  # Wrapper → GET /api/meetings/:meetingId/participants
POST   /api/calls/:callId/invite        # Wrapper → POST /api/meetings/:meetingId/invite-live
POST   /api/calls/:callId/generate-link # Wrapper → POST /api/meetings/:meetingId/generate-link (NEW: calls support external)
```

**Unified Backend Implementation:**
```javascript
// Single function for both meetings and calls
function createMeeting(data) {
  if (data.isInstantCall) {
    data.startTime = new Date(); // Start immediately
    data.status = 'in_progress';
    data.title = data.title || 'Call';
    // Calls also support external participants now
  }
  return db.insert('meetings', data); // Same table
}

// Call endpoints are simple wrappers
app.post('/api/calls/instant', (req, res) => {
  req.body.isInstantCall = true;
  return createMeeting(req.body);
});
```

**Online Status (1-minute heartbeat):**
```
POST   /api/presence/heartbeat          # Update user's heartbeat (every 60s)
GET    /api/presence/users              # Get status for specific users (bulk)
GET    /api/presence/channel/:channelId # Get status for channel members
GET    /api/presence/conversation/:userId # Get status for 1:1 chat opponent
```

**External Participants:**
```
GET    /api/meetings/external/join/:token    # Validate meeting invitation (valid 1h before to 1h after start time)
POST   /api/meetings/external/register       # Register external participant (temp keys)
GET    /api/meetings/external/keys/:sessionId # Get pre-key bundle for external user
DELETE /api/meetings/external/session/:sessionId # End external session
```

**Questions:**
- ~~Should instant calls be discoverable (listed somewhere), or only accessible via direct link/notification?~~ ✅ **ANSWERED: Only via notification/direct link**
- ~~How should we handle meeting conflicts (same user invited to overlapping meetings)?~~ ✅ **NOT BLOCKING: Show all in upcoming, user decides**

---

### 1.3 Backend Services

**MeetingService (server/services/meetingService.js):**
- Create/update/delete meetings **AND instant calls** (same table, same functions)
- Participant management (shared between meetings and calls)
- Meeting lifecycle (scheduled → in_progress → ended)
- **Cleanup logic:**
  - Instant calls (is_instant_call = TRUE): 
    - **Primary:** WebSocket disconnect events - when last participant disconnects, DELETE immediately
    - **Fallback:** Cron job every 5 min checks for calls with all participants having left_at set
  - Scheduled meetings: 
    - DELETE at scheduled_end_time + 8 hours (NOT actual end time)
    - Example: Meeting 2pm-3pm ends at 2:30pm → cleanup at 11pm (3pm + 8h)
  - Fallback: Delete any meeting older than 8 hours regardless of type
- **Key insight:** Instant calls stored in meetings table with `is_instant_call = TRUE`
- **Call notifications:** Handled by MeetingService (ringtone after Signal decryption, accept/decline events)

**PresenceService (server/services/presenceService.js):**
- Track user heartbeats (Socket.IO)
- Update online/away/offline status
- Broadcast status changes via event bus
- Cleanup stale connections

**ExternalParticipantService (server/services/externalParticipantService.js):**
- Generate temporary Signal Protocol keys
- Store external participant sessions
- Validate invitation tokens (valid 1h before to 1h after start time)
- Handle reconnections (reuse keys from SessionStorage if available)
- Auto-cleanup expired sessions

**Questions:**
- ~~How should we handle external participants who lose connection - allow rejoin, or create new session?~~ ✅ **ANSWERED: Check SessionStorage for keys - if found, reuse; if missing, generate new keys**

---

### 1.4 Socket.IO Events

**New Socket Events:**

**Legend:**
- 🔒 **Signal Encrypted** - Use Signal Protocol message encryption (contains sensitive data like names, avatars, titles)
- 🔓 **Plain Socket** - Direct Socket.IO emit (only UUIDs/IDs, no sensitive information)

```javascript
// Meetings
🔒 'meeting:created'        → Signal({ meetingId, title, startTime, createdBy })
🔒 'meeting:updated'        → Signal({ meetingId, changes }) // changes may contain title/description
🔒 'meeting:cancelled'      → Signal({ meetingId, reason })
🔒 'meeting:reminder'       → Signal({ meetingId, title, startTime, minutesBefore: 15 })
🔓 'meeting:register-participant' → { meetingId, userId } // Plain socket
🔓 'meeting:started'        → { meetingId }
🔓 'meeting:ended'          → { meetingId, duration, participantCount } // duration/count are not sensitive
🔒 'meeting:participant_joined' → Signal({ meetingId, userId, displayName })
🔒 'meeting:participant_left'   → Signal({ meetingId, userId, displayName })
🔒 'meeting:live_invite_sent'   → Signal({ meetingId, userId, displayName, invitedBy }) // Notify invited user during active meeting
🔓 'meeting:invite_link_generated' → { meetingId, invitationToken, expiresAt } // To meeting participants only

// External Guest Admission (Waiting Room)
🔒 'meeting:guest_waiting'  → Signal({ meetingId, sessionId, displayName }) // Broadcast to all participants
🔓 'meeting:guest_admitted' → { sessionId, admittedBy } // To guest only, just UUIDs
🔓 'meeting:guest_declined' → { sessionId, declinedBy } // To guest only, just UUIDs
🔓 'meeting:admit_guest'    → { meetingId, sessionId } // From participant to admit
🔓 'meeting:decline_guest'  → { meetingId, sessionId } // From participant to decline

// Instant Calls (Phone-style ringing)
// NOTE: Uses meetingId (same as scheduled meetings, just with is_instant_call = TRUE)
🔒 'call:incoming'          → Signal({ meetingId, callerId, callerName, callerAvatar, timestamp })
                              // Ringtone plays AFTER Signal decryption completes (caller info available)
🔓 'call:ringing'           → { meetingId, userId } // Caller sees who's being notified
🔒 'call:accepted'          → Signal({ meetingId, userId, displayName, avatar }) // Update waiting grid
🔒 'call:declined'          → Signal({ meetingId, userId, displayName }) // Show snackbar to caller
🔓 'call:ended'             → { meetingId, duration, endedBy }
🔒 'call:participant_waiting' → Signal({ meetingId, participants: [{userId, displayName, avatar}] }) // For grid display
🔒 'call:live_invite'         → Signal({ meetingId, callerId, callerName, invitedBy }) // Invite to ongoing call

// Presence (1-minute heartbeat)
🔓 'presence:update'        → { userId, status: 'online'|'offline', lastSeen } // Status not sensitive
🔓 'presence:bulk_update'   → { users: [{ userId, status, lastSeen }] } // Batch updates every minute
🔓 'presence:user_connected' → { userId } // Immediate update when user comes online
🔓 'presence:user_disconnected' → { userId, lastSeen } // When socket disconnects

// External Participants
🔒 'external:joined'        → Signal({ meetingId, sessionId, displayName }) // Guest joined meeting
🔒 'external:left'          → Signal({ meetingId, sessionId, displayName }) // Guest left
🔓 'external:all_server_users_left' → { meetingId } // Trigger external session cleanup
```

**Signal Protocol Usage Pattern:**
```javascript
// Backend - Sending encrypted event
const encryptedPayload = await signalEncrypt({
  meetingId: meeting.id,
  title: meeting.title,
  startTime: meeting.startTime,
  createdBy: meeting.createdBy
}, recipientUserId);

socket.emit('meeting:created', { encryptedMessage: encryptedPayload });

// Frontend - Receiving encrypted event
SocketService().registerListener('meeting:created', (data) async {
  final decrypted = await signalDecrypt(data['encryptedMessage']);
  final payload = jsonDecode(decrypted);
  // Use payload.meetingId, payload.title, etc.
});
```

**Plain Socket Usage Pattern:**
```javascript
// Backend - Direct emit (UUIDs only)
socket.emit('meeting:register-participant', { 
  meetingId: meeting.id,
  userId: user.id 
});

// Frontend - Direct listener
SocketService().registerListener('meeting:register-participant', (data) {
  final meetingId = data['meetingId'];
  final userId = data['userId'];
  // Process immediately, no decryption needed
});
```

**Questions:**
- ~~Should we use separate Socket.IO namespaces for meetings (/meetings) and calls (/calls)?~~ ✅ **ANSWERED: No, use events in default namespace**
- ~~How should we handle Socket.IO reconnection for presence tracking?~~ ✅ **Send immediate presence:update on reconnect**

---

## **PHASE 2: Frontend Infrastructure** (3-4 days)

### 2.1 State Management & Services

**New Services:**

**`client/lib/services/meeting_service.dart`:**
```dart
class MeetingService {
  static final MeetingService instance = MeetingService._();
  MeetingService._();
  
  // CRUD operations
  Future<Meeting> createMeeting({
    required String title,
    String? description,
    required DateTime startTime,
    required DateTime endTime,
    required List<String> participantUserIds,
    int? maxParticipants,
    bool allowExternal = false,
    bool voiceOnly = false,
    bool muteOnJoin = false,
    bool waitingRoomEnabled = false,
  });
  
  Future<List<Meeting>> getUpcomingMeetings();
  Future<List<Meeting>> getPastMeetings(); // Last 8 hours only
  Future<List<Meeting>> getMyMeetings();
  Future<Meeting> getMeetingDetails(String meetingId);
  
  Future<void> updateMeeting(String meetingId, Map<String, dynamic> updates);
  Future<void> cancelMeeting(String meetingId);
  
  // Participants
  Future<void> inviteParticipants(String meetingId, List<String> userIds);
  Future<void> removeParticipant(String meetingId, String userId);
  Future<void> acceptMeetingInvite(String meetingId);
  Future<void> declineMeetingInvite(String meetingId);
  
  // Join meeting (opens WebRTC channel)
  Future<void> joinMeeting(String meetingId);
  
  // Real-time updates via Socket.IO
  void listenToMeetingEvents();
  
  // Notifications (managed by NotificationService)
  Future<void> dismissNotification(String meetingId, String notificationType);
  
  // Live invitations during active meeting
  Future<void> inviteDuringMeeting(String meetingId, List<String> userIds);
  Future<String> generateExternalLink(String meetingId); // Returns invitation token
  Stream<Map<String, dynamic>> get recentInvitesStream; // Track invite status
}
```

**`client/lib/services/instant_call_service.dart`:**
```dart
// Thin wrapper around MeetingService for call-specific UI/notifications
class InstantCallService {
  static final InstantCallService instance = InstantCallService._();
  InstantCallService._();
  
  final _meetingService = MeetingService.instance;
  
  // Create instant call (returns Meeting object with isInstantCall = true)
  Future<Meeting> createInstantCall({
    required String sourceId, // channelId or userId
    required List<String> participantIds,
  }) async {
    // Call is just a meeting with immediate start
    return await _meetingService.createMeeting(
      title: 'Call',
      startTime: DateTime.now(),
      endTime: DateTime.now().add(Duration(hours: 4)), // Max duration
      participantUserIds: participantIds,
      isInstantCall: true,
      sourceChannelId: sourceId.contains('channel') ? sourceId : null,
      sourceUserId: participantIds.length == 1 ? participantIds[0] : null,
    );
  }
  
  // Call-specific: Notify participants with ringtone (after Signal decryption)
  Future<void> notifyParticipants(String meetingId, List<String> userIds) async {
    SocketService().emit('call:notify', {'meetingId': meetingId, 'userIds': userIds});
  }
  
  // Call-specific: Accept call (then delegates to joinMeeting)
  Future<void> acceptCall(String meetingId) async {
    await ApiService.dio.post('/api/calls/accept', data: {'meetingId': meetingId});
    return await _meetingService.joinMeeting(meetingId);
  }
  
  // Call-specific: Decline call
  Future<void> declineCall(String meetingId) async {
    await ApiService.dio.post('/api/calls/decline', data: {'meetingId': meetingId});
  }
  
  // End call (delegates to deleteMeeting - triggers immediate cleanup)
  Future<void> endCall(String meetingId) async {
    return await _meetingService.deleteMeeting(meetingId);
  }
  
  // Get waiting participants (delegates to meeting participants)
  Future<List<MeetingParticipant>> getWaitingParticipants(String meetingId) async {
    return await _meetingService.getMeetingParticipants(meetingId);
  }
  
  // Invite during call (delegates to meeting live invite)
  Future<void> inviteDuringCall(String meetingId, List<String> userIds) async {
    return await _meetingService.inviteDuringMeeting(meetingId, userIds);
  }
  
  // Generate external link for call (NEW: calls support external participants)
  Future<String> generateExternalLink(String meetingId) async {
    return await _meetingService.generateExternalLink(meetingId);
  }
  
  // Listen to call events (wraps meeting events)
  void listenToCallEvents() {
    SocketService().registerListener('call:incoming', _handleIncomingCall);
    SocketService().registerListener('call:accepted', _handleCallAccepted);
    SocketService().registerListener('call:declined', _handleCallDeclined);
  }
  
  // Current call state (filters meetings where isInstantCall = true)
  Stream<Meeting?> get currentCallStream => _meetingService.activeMeetingsStream
      .map((meetings) => meetings.firstWhere((m) => m.isInstantCall, orElse: () => null));
}
```

**`client/lib/services/presence_service.dart`:**
```dart
class PresenceService {
  static final PresenceService instance = PresenceService._();
  PresenceService._();
  
  Timer? _heartbeatTimer;
  final Map<String, UserPresence> _userPresenceCache = {};
  final StreamController<Map<String, UserPresence>> _presenceController = 
      StreamController.broadcast();
  
  // Heartbeat management (every 60 seconds)
  void startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _sendHeartbeat(),
    );
    _sendHeartbeat(); // Send immediately
  }
  
  void stopHeartbeat() {
    _heartbeatTimer?.cancel();
  }
  
  Future<void> _sendHeartbeat() async {
    await ApiService.post('/api/presence/heartbeat', {});
  }
  
  // Status tracking
  Stream<Map<String, UserPresence>> get userPresenceStream => 
      _presenceController.stream;
  
  Future<Map<String, UserPresence>> getStatusForUsers(List<String> userIds);
  Future<Map<String, UserPresence>> getStatusForChannel(String channelId);
  Future<UserPresence?> getStatusForUser(String userId);
  
  // Check if user is online
  bool isUserOnline(String userId) {
    return _userPresenceCache[userId]?.isOnline ?? false;
  }
  
  // Listen to presence updates via Socket.IO
  void listenToPresenceUpdates() {
    SocketService().socket?.on('presence:update', (data) {
      _handlePresenceUpdate(data);
    });
    
    SocketService().socket?.on('presence:bulk_update', (data) {
      _handleBulkPresenceUpdate(data);
    });
  }
  
  void _handlePresenceUpdate(dynamic data) {
    final userId = data['userId'] as String;
    final status = data['status'] as String;
    final lastSeen = DateTime.parse(data['lastSeen'] as String);
    
    _userPresenceCache[userId] = UserPresence(
      userId: userId,
      status: _parseStatus(status),
      lastSeen: lastSeen,
    );
    
    _presenceController.add(_userPresenceCache);
  }
  
  void _handleBulkPresenceUpdate(dynamic data) {
    final users = data['users'] as List;
    for (final user in users) {
      _handlePresenceUpdate(user);
    }
  }
  
  PresenceStatus _parseStatus(String status) {
    switch (status) {
      case 'online': return PresenceStatus.online;
      default: return PresenceStatus.offline;
    }
  }
}
```

**`client/lib/services/external_participant_service.dart`:**
```dart
class ExternalParticipantService {
  static final ExternalParticipantService instance = 
      ExternalParticipantService._();
  ExternalParticipantService._();
  
  // Join as external guest
  Future<ExternalSession> joinAsExternal({
    required String invitationToken,
    required String displayName,
    String? email,
  }) async {
    // 1. Validate invitation token (valid 1h before to 1h after meeting start time)
    final validateResp = await ApiService.get(
      '/api/meetings/external/join/$invitationToken',
    );
    
    final meetingId = validateResp.data['meetingId'] as String;
    final meetingTitle = validateResp.data['title'] as String;
    
    // 2. Check SessionStorage for existing keys (reconnection scenario)
    final existingSession = await _loadFromSessionStorage();
    
    IdentityKeyPair identityKeyPair;
    SignedPreKey signedPreKey;
    List<PreKey> preKeys;
    
    if (existingSession != null) {
      // Reuse existing keys from SessionStorage
      identityKeyPair = existingSession.identityKeyPair;
      signedPreKey = existingSession.signedPreKey;
      preKeys = existingSession.preKeys;
    } else {
      // Generate new temporary Signal Protocol keys
      identityKeyPair = await _generateIdentityKeyPair();
      signedPreKey = await _generateSignedPreKey(identityKeyPair);
      preKeys = await _generatePreKeys(identityKeyPair, count: 100);
    }
    
    // 3. Register with server
    final registerResp = await ApiService.post(
      '/api/meetings/external/register',
      {
        'invitationToken': invitationToken,
        'displayName': displayName,
        'email': email,
        'identityKeyPublic': base64Encode(identityKeyPair.publicKey),
        'signedPreKey': signedPreKey.toJson(),
        'preKeys': preKeys.map((k) => k.toJson()).toList(),
      },
    );
    
    final sessionId = registerResp.data['sessionId'] as String;
    final expiresAt = DateTime.parse(registerResp.data['expiresAt'] as String);
    
    // 4. Store in session storage (survives refresh, not tab close)
    await _storeInSessionStorage(sessionId, identityKeyPair, preKeys);
    
    return ExternalSession(
      sessionId: sessionId,
      meetingId: meetingId,
      displayName: displayName,
      email: email,
      expiresAt: expiresAt,
    );
  }
  
  // Get pre-key bundle for external participant
  Future<PreKeyBundle> getExternalPreKeys(String sessionId) async {
    final resp = await ApiService.get(
      '/api/meetings/external/keys/$sessionId',
    );
    return PreKeyBundle.fromJson(resp.data);
  }
  
  // Cleanup when leaving
  Future<void> endSession(String sessionId) async {
    await ApiService.delete('/api/meetings/external/session/$sessionId');
    await _clearSessionStorage();
  }
  
  // Private helper methods for key generation and session management
  Future<IdentityKeyPair> _generateIdentityKeyPair() async { /* ... */ }
  Future<SignedPreKey> _generateSignedPreKey(IdentityKeyPair identityKeyPair) async { /* ... */ }
  Future<List<PreKey>> _generatePreKeys(IdentityKeyPair identityKeyPair, {required int count}) async { /* ... */ }
  Future<ExistingSession?> _loadFromSessionStorage() async { /* Check if keys exist in SessionStorage */ }
  Future<void> _storeInSessionStorage(String sessionId, IdentityKeyPair keys, SignedPreKey signedPreKey, List<PreKey> preKeys) async { /* ... */ }
  Future<void> _clearSessionStorage() async { /* ... */ }
}
```

**Questions:**
- ~~Should presence heartbeat be handled by a global singleton, or each screen independently?~~ ✅ **ANSWERED: Global singleton (PresenceService.instance)**
- ~~How should we prioritize presence updates if there are 100+ users in a large channel?~~ ✅ **Use bulk_update event, update cache, batch emit**

---

### 2.2 Event Bus Extensions

**Update `client/lib/services/event_bus.dart`:**

```dart
enum AppEvent {
  // Existing events...
  
  // Meetings
  meetingCreated,
  meetingUpdated,
  meetingCancelled,
  meetingStarting,      // 15 min before
  meetingStarted,
  meetingEnded,
  
  // Instant Calls
  incomingCall,
  callAccepted,
  callDeclined,
  callEnded,
  
  // Presence
  presenceUpdated,
  presenceBulkUpdated,
  
  // External Participants
  externalJoined,
  externalLeft,
  
  // UI Updates
  channelListRefresh,
  messageListRefresh,
  contextPanelRefresh,
}
```

**Event Bus Listeners for Auto-Refresh:**
- Channel overview list → listen to `channelListRefresh`, `presenceUpdated`
- Message overview list → listen to `messageListRefresh`, new messages
- Context panel → listen to `contextPanelRefresh`, channel updates

**Questions:**
- ~~Should we debounce event bus updates to avoid excessive rebuilds?~~ ✅ **ANSWERED: Yes, 300-500ms debouncing (already implemented in code examples)**
- ~~How should we handle event bus events when the app is in the background?~~ ✅ **ANSWERED: Events are queued by EventBus, processed when app returns to foreground**

---

### 2.3 Models

**New Model Classes:**

```dart
// client/lib/models/meeting.dart
class Meeting {
  final String meetingId;
  final String? channelId;
  final String title;
  final String? description;
  final String createdBy;
  final DateTime startTime;
  final DateTime endTime;
  final bool isRecurring;
  final String? recurrencePattern;
  final int? maxParticipants;
  final bool allowExternal;
  final String? externalJoinToken;
  final MeetingStatus status;
  final List<MeetingParticipant> participants;
  
  bool get isUpcoming => DateTime.now().isBefore(startTime);
  bool get isInProgress => DateTime.now().isAfter(startTime) && DateTime.now().isBefore(endTime);
  bool get hasEnded => DateTime.now().isAfter(endTime);
  bool get shouldNotify => startTime.difference(DateTime.now()).inMinutes <= 15;
}

enum MeetingStatus { scheduled, inProgress, ended, cancelled }

// client/lib/models/meeting_participant.dart
class MeetingParticipant {
  final String userId;
  final String displayName;
  final ParticipantStatus status;
  final DateTime? joinedAt;
  final DateTime? leftAt;
}

enum ParticipantStatus { invited, accepted, declined, attended }

// client/lib/models/temp_channel.dart
class TempChannel {
  final String tempChannelId;
  final String createdBy;
  final TempChannelType channelType;
  final String? sourceChannelId;
  final DateTime createdAt;
  final DateTime expiresAt;
  final bool isActive;
}

enum TempChannelType { oneOnOneCall, groupCall }

// client/lib/models/user_presence.dart
class UserPresence {
  final String userId;
  final PresenceStatus status;
  final DateTime lastSeen;
  
  bool get isOnline => status == PresenceStatus.online;
}

enum PresenceStatus { online, away, offline }

// client/lib/models/external_session.dart
class ExternalSession {
  final String sessionId;
  final String meetingId;
  final String displayName;
  final String? email;
  final DateTime expiresAt;
  final String identityKeyPublic;
  final String signedPreKey;
  final List<String> preKeys;
}
```

---

## **PHASE 3: UI Components** (4-5 days)

### 3.1 Navigation Sidebar

**Update `client/lib/screens/dashboard_scaffold.dart`:**
- Add "Meetings" navigation item between "Activities" and "People"
- Icon: `Icons.video_call` or `Icons.event`
- Badge: Show count of meetings starting within 1 hour (red badge)
- Badge updates in real-time via EventBus

**Questions:**
- ~~Should the Meetings badge include only meetings the user created, or all they're invited to?~~ ✅ **ANSWERED: All meetings user is invited to**
- ~~Should there be a visual indicator (pulsing dot) when a meeting is about to start?~~ ✅ **ANSWERED: Yes, show pulsing red badge**

---

### 3.2 Meetings Page

**New Screen: `client/lib/screens/meetings/meetings_screen.dart`**

**Layout (List View Only):**
```
┌─────────────────────────────────────────┐
│  Meetings                    [+ Create] │
├─────────────────────────────────────────┤
│  [Upcoming] [Past (8h)]                 │  ← Filter chips
├─────────────────────────────────────────┤
│  📅 Upcoming                            │
│  ┌───────────────────────────────────┐ │
│  │ ⏰ Daily Standup                   │ │
│  │ 🕐 Today 10:00 - 10:30            │ │
│  │ 👤 5 participants                  │ │
│  │ ● Meeting in progress             │ │  ← Only if started
│  │ [Join Meeting]                     │ │  ← Only if started
│  └───────────────────────────────────┘ │
│                                         │
│  ┌───────────────────────────────────┐ │
│  │ ⏰ Sprint Planning                 │ │
│  │ 🕑 Tomorrow 14:00 - 15:30         │ │
│  │ 👤 12 participants • Invited       │ │
│  │ [Accept] [Decline] [Details]      │ │
│  └───────────────────────────────────┘ │
│                                         │
│  📋 Past (last 8 hours)                │
│  ┌───────────────────────────────────┐ │
│  │ 📅 Morning Sync (Meeting)          │ │
│  │ 🕐 Today 09:00 - 09:15            │ │
│  │ ✓ Ended - 15 min • 8 participants │ │
│  │ [View Details]                     │ │
│  └───────────────────────────────────┘ │
│  ┌───────────────────────────────────┐ │
│  │ 📞 Call with Alice (Call)          │ │
│  │ 🕐 Today 08:30 - 08:45            │ │
│  │ ✓ Ended - 15 min • 2 participants │ │  ← Instant call shown with phone icon
│  │ [View Details]                     │ │
│  └───────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

**Features:**
- Tabs/Chips: "Upcoming" (default) and "Past (8h)"
- Search bar for meeting titles
- Real-time updates via EventBus (new meetings, status changes)
- "Join Meeting" button only visible when meeting status = 'in_progress'
- Past meetings show: duration (e.g., "15 min"), participant count
- Filter badges: "My Meetings", "All", "Created by Me"

**Questions:**
- ~~Should we show a mini calendar widget to quickly navigate to specific dates?~~ ✅ **ANSWERED: No, list view only**
- ~~Should past meetings be collapsible to save space?~~ ✅ **ANSWERED: No, show last 8 hours in flat list**

---

### 3.3 Create/Edit Meeting Dialog

**New Component: `client/lib/widgets/meeting_dialog.dart`**

**Implementation Pattern (based on `channel_settings_screen.dart`):**

```dart
class MeetingDialog extends StatefulWidget {
  final String? meetingId; // null for create, set for edit
  final Meeting? existingMeeting;
  
  @override
  State<MeetingDialog> createState() => _MeetingDialogState();
}

class _MeetingDialogState extends State<MeetingDialog> {
  late TextEditingController _titleController;
  late TextEditingController _descriptionController;
  DateTime? _startTime;
  DateTime? _endTime;
  List<String> _selectedParticipants = [];
  bool _allowExternal = false;
  int? _maxParticipants;
  bool _voiceOnly = false;
  bool _muteOnJoin = false;
  bool _hasChanges = false;
  bool _isSaving = false;
  
  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: widget.existingMeeting?.title ?? '',
    );
    _descriptionController = TextEditingController(
      text: widget.existingMeeting?.description ?? '',
    );
    
    // Add listeners for change detection
    _titleController.addListener(_onFieldChanged);
    _descriptionController.addListener(_onFieldChanged);
  }
  
  void _onFieldChanged() {
    setState(() => _hasChanges = true);
  }
  
  Future<void> _saveMeeting() async {
    if (_titleController.text.trim().isEmpty) {
      _showError('Meeting title cannot be empty');
      return;
    }
    
    setState(() => _isSaving = true);
    
    try {
      final meetingService = MeetingService.instance;
      
      if (widget.meetingId == null) {
        // Create new meeting
        await meetingService.createMeeting(
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim(),
          startTime: _startTime!,
          endTime: _endTime!,
          participantUserIds: _selectedParticipants,
          maxParticipants: _maxParticipants,
          allowExternal: _allowExternal,
          voiceOnly: _voiceOnly,
          muteOnJoin: _muteOnJoin,
        );
      } else {
        // Update existing meeting
        await meetingService.updateMeeting(widget.meetingId!, {
          'title': _titleController.text.trim(),
          'description': _descriptionController.text.trim(),
          // ... other fields
        });
      }
      
      if (mounted) {
        Navigator.of(context).pop(true); // Return true to indicate success
      }
    } catch (e) {
      if (mounted) _showError('Failed to save meeting: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}
```

**Fields:**
- Title (TextField with validation, same pattern as channel name)
- Description (TextField with maxLines: 3, same as channel description)
- Start Date & Time (DatePicker + TimePicker)
- Duration (dropdown: 15min, 30min, 1h, 2h, custom)
- Participants (multi-select from ApiService.searchUsers(), shows online status via PresenceService)
- Allow External Participants (SwitchListTile, same pattern as isPrivate toggle)
- Max Participants (TextField with keyboardType: TextInputType.number)

**Meeting Settings (Expandable Section):**
- Voice Only Mode (SwitchListTile) - Disable cameras for all participants
- Mute on Join (SwitchListTile) - Participants muted when entering

**Note:** Waiting Room (PreJoin page with device selection + E2EE key exchange) is **mandatory** for all meetings. Invited server users are auto-admitted after prejoin. External guests must be manually admitted by any meeting participant.

**Questions:**
- ~~Should we validate meeting conflicts (user already has a meeting at that time)?~~ ✅ **ANSWERED: No validation, show warning only**
- ~~Should meeting creators be able to set permissions (who can share screen, etc.)?~~ ✅ **ANSWERED: Yes, via role assignment (owner/manager/member)**

---

### 3.4 Pre-Meeting Notification Bar

**New Component: `client/lib/widgets/meeting_notification_bar.dart`**

**Display:**
- Show 15 minutes before meeting starts (dismissible)
- Show again at meeting start time (dismissible)
- Position: Top of screen, above navigation (floating overlay)
- Style: Blue background (colorScheme.primary)
- Also appears in Activities page if user is invited

**15-Minute Warning (Dismissible):**
```
┌──────────────────────────────────────────────────────┐
│ 🎥 Meeting starting in 14 minutes: "Daily Standup"   │
│ [Dismiss] [View Details]                              │
└──────────────────────────────────────────────────────┘
```

**At Start Time (dismissible):**
```
┌──────────────────────────────────────────────────────┐
│ 🔴 Meeting started: "Daily Standup"                   │
│ [Join Now] [View Details]                             │
└──────────────────────────────────────────────────────┘
```

**Behavior:**
- 15-min notification can be dismissed, stored in `meeting_notifications` table
- Start-time notification cannot be dismissed, stays until user joins or 5 min pass
- Notification persists across page navigation
- No sound (only Activities notification shows badge)

**Questions:**
- ~~Should we play a sound when the notification appears?~~ ✅ **ANSWERED: No sound, only visual notification**
- ~~Should the notification persist across page navigation?~~ ✅ **ANSWERED: Yes, floating overlay above everything**

---

### 3.5 Instant Call Button & Dialog

**Update Existing AppBars:**
- Add call button (📞 `Icons.phone` icon) in 1:1 chat and channel AppBars
- Position: Left of Members and Settings icons
- Icon color: `colorScheme.primary`

**Instant Call Behavior:**

**Key Insight:** There's no distinction between "1:1" and "group" calls - they're all just **calls** with different participant counts. A 2-person call can become a 3-person call seamlessly.

**From 1:1 Chat:**
- Click call button → Create meeting with `isInstantCall: true` + notify opponent
- No dialog shown, direct phone-style call
- Ringtone plays **AFTER** Signal decryption completes (so caller name/avatar available)
- Shows waiting screen with opponent's avatar (greyed overlay until they accept)
- **During call:** Click invite button → Add more participants → Still the same call (same meetingId)

**From Group Channel:**
- Click call button → Show participant selection dialog
- Only online members are pre-selected
- Offline members shown but disabled
- **During call:** Click invite button → Add more participants (same as from 1:1 chat)

**Group Call Dialog: `client/lib/widgets/instant_call_dialog.dart`**

```
┌─────────────────────────────────────┐
│  Start Instant Call                 │
├─────────────────────────────────────┤
│  Call participants:                  │
│  ☑ Alice (online)                    │
│  ☑ Bob (online)                      │
│  ☐ Charlie (offline) [disabled]      │
│                                      │
│  Note: Only online members will be   │
│  notified. Video call only.          │
│                                      │
│  [Cancel]       [Start Call]        │
└─────────────────────────────────────┘
```

**Behavior:**
- Creates temp channel immediately when "Start Call" clicked
- Sends `call:incoming` event to all selected online users
- Caller enters waiting screen with profile picture grid
- Call starts when first participant accepts

**Questions:**
- ~~Should offline users receive a notification when they come online?~~ ✅ **ANSWERED: No, only online users are notified**
- ~~Should the call automatically end if the creator leaves, or continue with remaining participants?~~ ✅ **ANSWERED: Continue with remaining participants until all leave**

---

### 3.6 Incoming Call Notification

**New Component: `client/lib/widgets/incoming_call_overlay.dart`**

**Display:**
- Full-width top bar (higher priority than meeting notification)
- Plays ringtone sound (`assets/sounds/call_ringtone.mp3`) - loops until answered/declined
- Shows caller name and avatar
- Actions: Decline (red), Accept (green)
- Auto-dismiss after 30 seconds → caller gets "declined" feedback

**Top Bar Layout:**
```
┌─────────────────────────────────────────────────────┐
│  📞 [Avatar] Alice is calling...                     │
│  1:1 Call                                            │
│  [🔴 Decline]              [🟢 Accept]              │
└─────────────────────────────────────────────────────┘
```

**Behavior:**
- Decline → Send `call:declined` event → Show snackbar to caller
- Accept → Send `call:accepted` event → Navigate to VideoConferenceView
- Timeout (30s) → Auto-decline, same as manual decline
- Multiple incoming calls → Queue them, show one at a time
- Notification stays on top even during page navigation

**Caller Feedback (Snackbar):**
- "Alice declined the call"
- "Alice didn't answer" (timeout)
- "Alice accepted the call" (update waiting grid)

**Questions:**
- ~~Should calls auto-decline after 30 seconds if unanswered?~~ ✅ **ANSWERED: Yes, 30 seconds timeout**
- ~~Should there be a "Do Not Disturb" mode that rejects all instant calls?~~ ✅ **ANSWERED: Future feature, not in MVP**

---

### 3.7 Call Waiting Screen

**NOTE:** This is the exact same component used for meetings - reuse `VideoConferenceView` with "Waiting for participants" overlay. No separate call waiting component needed.

**New Component: `client/lib/widgets/call_waiting_screen.dart`**

**Display (for caller while waiting for participants to accept):**

```
┌─────────────────────────────────────────┐
│              Calling...                  │
├─────────────────────────────────────────┤
│  ┌──────┐  ┌──────┐  ┌──────┐           │
│  │ [A] │  │ [B] │  │ [C] │           │  ← Profile pictures in grid
│  │Alice │  │ Bob  │  │Carol│           │
│  │ ...  │  │ ...  │  │ ...  │           │  ← Grey overlay + "..." = waiting
│  └──────┘  └──────┘  └──────┘           │
│                                          │
│  Waiting for participants to join...     │
│                                          │
│  [End Call]                              │
└─────────────────────────────────────────┘
```

**When participant accepts:**
- Remove grey overlay from their avatar
- Show green checkmark ✓
- Update text: "Alice joined"
- Automatically transition to VideoConferenceView when first person accepts

**Behavior:**
- Caller sees all invited participants as greyed out initially
- Each acceptance updates the grid in real-time (`call:accepted` event)
- Caller can end call before anyone joins → send `call:ended` to all
- Grid supports scrolling if more than 6 participants

**Questions:**
- ~~How should we display the waiting grid?~~ ✅ **ANSWERED: Profile pictures with grey overlay until accepted**

---

### 3.8 Live Invite Dialog (During Active Meeting/Call)

**New Component: `client/lib/widgets/live_invite_dialog.dart`**

**Display (from within VideoConferenceView):**
```
┌─────────────────────────────────────────┐
│  Invite to Meeting                       │
├─────────────────────────────────────────┤
│  [Server Users] [External Link]          │  ← Tabs
├─────────────────────────────────────────┤
│  Server Users Tab:                       │
│  ┌─────────────────────────────────────┐│
│  │ [Search users...]                    ││
│  └─────────────────────────────────────┘│
│  ☐ Alice (online)                        │
│  ☐ Bob (offline)                         │
│  ☐ Carol (online)                        │
│                                          │
│  Recently Invited:                       │
│  • Dave - Joined ✓                       │
│  • Eve - Pending...                      │
│                                          │
│  [Cancel]              [Send Invites]    │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│  Invite to Meeting                       │
├─────────────────────────────────────────┤
│  [Server Users] [External Link]          │  ← Tabs
├─────────────────────────────────────────┤
│  External Link Tab:                      │
│  ┌─────────────────────────────────────┐│
│  │ https://peerwave.app/join/meeting/  ││
│  │ abc123def456                         ││
│  │ [Copy Link] [📋]                     ││
│  └─────────────────────────────────────┘│
│                                          │
│  Valid: 1 hour before to 1 hour after   │
│  Meeting: Today 14:00 - 15:30           │
│                                          │
│  Note: External guests will need         │
│  manual admission after prejoin.         │
│                                          │
│  [Generate New Link] [Close]             │
└─────────────────────────────────────────┘
```

**Behavior:**

**Server Users Tab:**
- Search bar with `ApiService.searchUsers()` (same pattern as meeting creation)
- Show online status indicators
- Multi-select checkboxes
- Show "Recently Invited" section with real-time status:
  - Pending: User notified, hasn't joined yet
  - Joined: User successfully joined the meeting
  - Declined: User declined the invitation
- Click "Send Invites" → POST `/api/meetings/:meetingId/invite-live`
- Selected users receive notification via Socket.IO `meeting:live_invite_sent`
- Notification shows: "Alice invited you to join 'Daily Standup' (in progress)"
- User can click "Join Now" → Goes through prejoin → Auto-admitted (server user)

**External Link Tab (Meetings Only):**
- Show current invitation link (if exists)
- "Copy Link" button copies to clipboard
- "Generate New Link" creates fresh token (invalidates old one)
- Show meeting time window (±1h validity)
- Show reminder about manual admission for external guests

**Instant Calls:**
- **NEW:** Show both "Server Users" AND "External Link" tabs (calls now support external participants)
- **Exact same component as meetings** - no conditional logic needed
- All calls use identical UI - no distinction between "1:1" and "group"
- Server users: Get phone-style notification with ringtone (after Signal decryption)
- External guests: Use invitation link → Manual admission (same as meetings)

**Permissions:**
- Owner/Manager: Always can invite
- Member: Only if `can_invite_participants = TRUE`
- Button hidden if no permission

**Access:**
- Button in VideoConferenceView toolbar (next to screen share)
- Icon: `Icons.person_add` or `Icons.group_add`
- Tooltip: "Invite participants"

**Questions:**
- ~~Should members be able to invite during active meeting?~~ ✅ **ANSWERED: Yes, if they have can_invite_participants permission**
- ~~Should external link generation invalidate old links?~~ ✅ **ANSWERED: Yes, for security reasons**

---

### 3.9 Event Bus UI Updates

**Update Components to Listen to Event Bus (with batching):**

**Channels Overview (`client/lib/screens/dashboard/channels_content.dart`):**
```dart
void initState() {
  super.initState();
  
  // Debounce timer for batching updates
  Timer? _refreshDebounce;
  
  // Listen to channel list refresh events (batched)
  EventBus.instance.on(AppEvent.channelListRefresh).listen((_) {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _loadChannels();
    });
  });
  
  // Listen to presence updates (bulk updates every minute)
  EventBus.instance.on(AppEvent.presenceBulkUpdated).listen((data) {
    if (!mounted) return;
    setState(() {
      final users = data['users'] as Map<String, UserPresence>;
      _updateChannelOnlineStatus(users);
    });
  });
  
  // Immediate update for user connected/disconnected
  EventBus.instance.on(AppEvent.presenceUpdated).listen((data) {
    if (!mounted) return;
    setState(() {
      _updateSingleUserStatus(data['userId'], data['status']);
    });
  });
}
```

**Messages Overview (`client/lib/screens/dashboard/messages_content.dart`):**
```dart
void initState() {
  super.initState();
  
  Timer? _messageRefreshDebounce;
  
  // Listen to new messages (batched to avoid rapid rebuilds)
  SignalService.instance.registerItemCallback('message', (item) {
    _messageRefreshDebounce?.cancel();
    _messageRefreshDebounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() {
          _updateConversationPreview(item);
        });
      }
    });
    
    // Update unread count immediately (no debounce)
    EventBus.instance.emit(AppEvent.messageListRefresh, {
      'conversationId': item['sender'],
    });
  });
  
  // Listen to presence updates
  EventBus.instance.on(AppEvent.presenceBulkUpdated).listen((data) {
    if (!mounted) return;
    setState(() {
      final users = data['users'] as Map<String, UserPresence>;
      _updateUserOnlineStatus(users);
    });
  });
}
```

**Context Panel (`client/lib/widgets/context_panel.dart`):**
```dart
void initState() {
  super.initState();
  
  Timer? _contextRefreshDebounce;
  
  EventBus.instance.on(AppEvent.contextPanelRefresh).listen((_) {
    _contextRefreshDebounce?.cancel();
    _contextRefreshDebounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) _refreshContextData();
    });
  });
  
  // Presence updates (no debounce needed, already batched)
  EventBus.instance.on(AppEvent.presenceBulkUpdated).listen((data) {
    if (!mounted) return;
    setState(() {
      _updateMemberPresence(data['users']);
    });
  });
}
```

**Meetings Page (`client/lib/screens/meetings/meetings_screen.dart`):**
```dart
void initState() {
  super.initState();
  
  // Meeting events (no debounce, immediate updates)
  EventBus.instance.on(AppEvent.meetingCreated).listen((data) {
    if (mounted) _addMeetingToList(Meeting.fromJson(data));
  });
  
  EventBus.instance.on(AppEvent.meetingUpdated).listen((data) {
    if (mounted) _updateMeetingInList(data['meetingId'], data['changes']);
  });
  
  EventBus.instance.on(AppEvent.meetingStarted).listen((data) {
    if (mounted) {
      setState(() {
        _updateMeetingStatus(data['meetingId'], MeetingStatus.inProgress);
      });
    }
  });
}
```

**Questions:**
- ~~Should we add a "pull to refresh" gesture as manual fallback?~~ ✅ **ANSWERED: Yes, add to all list views**
- ~~How should we handle rapid-fire events (e.g., 10 messages in 1 second)?~~ ✅ **ANSWERED: Debounce UI updates (300-500ms), immediate for critical (calls, meetings)**

---

### 3.9 Online Status Indicators

**New Component: `client/lib/widgets/online_status_indicator.dart`**

**Display:**
- Small colored dot next to user avatars (8x8px circle)
- Green (#4CAF50): Online (socket connected)
- Gray (#9E9E9E): Offline

**Placement:**
- User avatars in channel member lists
- User avatars in 1:1 conversation list
- User avatars in call waiting grid
- Participant selection dialogs

**Implementation:**
```dart
class OnlineStatusIndicator extends StatelessWidget {
  final String userId;
  final double size;
  
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, UserPresence>>(
      stream: PresenceService.instance.userPresenceStream,
      builder: (context, snapshot) {
        final isOnline = snapshot.data?[userId]?.isOnline ?? false;
        
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isOnline ? Colors.green : Colors.grey,
            border: Border.all(color: Colors.white, width: 2),
          ),
        );
      },
    );
  }
}
```

**Questions:**
- ~~Should we show "Last seen X minutes ago" tooltip on hover?~~ ✅ **ANSWERED: Future feature, not in MVP**
- ~~Should we add custom status messages (e.g., "In a meeting", "Out for lunch")?~~ ✅ **ANSWERED: Future feature, not in MVP**

---

## **PHASE 4: External Participant Support** (3-4 days)

### 4.1 External Invitation System

**Meeting Invitation Link:**
```
https://peerwave.example.com/join/meeting/abc123def456

Format: /join/meeting/:invitationToken
```

**Join Flow for External Users:**

1. **Landing Page (`client/lib/screens/external/meeting_join_screen.dart`):**
   - Show meeting title, start time, host name
   - Form: Display Name (required, text input)
   - Privacy notice: "Your video and audio will be end-to-end encrypted. You will be removed when all participants leave."
   - [Join Meeting] button (enabled 1h before to 1h after start time)
   - Countdown timer if joining early: "Meeting starts in 14 minutes"
   - Error message if outside time window: "This invitation is only valid 1 hour before and after the meeting start time."

2. **Key Generation (or Reuse):**
   - Check SessionStorage for existing keys (reconnection scenario)
   - If keys found: Reuse existing identity, signed pre-key, and pre-keys
   - If keys missing: Generate new temporary Signal Protocol keys (identity, signed pre-key, 100 pre-keys)
   - Keys stored in **SessionStorage** (survives refresh, lost on tab close)
   - POST to `/api/meetings/external/register` to store on server
   - Server assigns 24-hour expiration (max), but session ends when all server users leave

3. **PreJoin Page (`client/lib/screens/external/external_prejoin_view.dart`):**
   - **Reuse PreJoin Logic from `video_conference_prejoin_view.dart`:**

```dart
class ExternalPreJoinView extends StatefulWidget {
  final String invitationToken;
  final String displayName;
  final String? email;
  
  @override
  State<ExternalPreJoinView> createState() => _ExternalPreJoinViewState();
}

class _ExternalPreJoinViewState extends State<ExternalPreJoinView> {
  List<MediaDevice> _cameras = [];
  List<MediaDevice> _microphones = [];
  MediaDevice? _selectedCamera;
  MediaDevice? _selectedMicrophone;
  bool _isLoadingDevices = true;
  LocalVideoTrack? _previewTrack;
  bool _isCameraEnabled = true;
  bool _hasE2EEKey = false;
  bool _isExchangingKey = false;
  
  @override
  void initState() {
    super.initState();
    _initializePreJoin();
  }
  
  Future<void> _initializePreJoin() async {
    // Step 1: Load media devices (SAME as regular prejoin)
    await _loadMediaDevices();
    
    // Step 2: Generate temporary E2EE keys via ExternalParticipantService
    await _generateOrLoadE2EEKeys();
    
    // Step 3: Start camera preview (SAME as regular prejoin)
    if (_isCameraEnabled && _selectedCamera != null) {
      await _startCameraPreview();
    }
  }
  
  Future<void> _loadMediaDevices() async {
    // REUSE EXACT LOGIC from video_conference_prejoin_view.dart:
    // - Hardware.instance.enumerateDevices()
    // - Request permissions with temp tracks
    // - Filter videoinput/audioinput
    // - Auto-select first device
  }
  
  Future<void> _generateOrLoadE2EEKeys() async {
    setState(() => _isExchangingKey = true);
    
    try {
      final session = await ExternalParticipantService.instance.joinAsExternal(
        invitationToken: widget.invitationToken,
        displayName: widget.displayName,
        email: widget.email,
      );
      
      setState(() {
        _hasE2EEKey = true;
        _isExchangingKey = false;
      });
    } catch (e) {
      setState(() {
        _isExchangingKey = false;
        _keyExchangeError = e.toString();
      });
    }
  }
  
  Future<void> _startCameraPreview() async {
    // REUSE EXACT LOGIC from video_conference_prejoin_view.dart
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Join Meeting')),
      body: Column(
        children: [
          // Video preview (REUSE _buildVideoPreview from prejoin)
          _buildVideoPreview(),
          
          // Device selection (REUSE _buildDeviceSelection)
          _buildDeviceSelection(),
          
          // E2EE status (REUSE _buildE2EEStatus)
          _buildE2EEStatus(),
          
          // External participant notice
          ListTile(
            leading: Icon(Icons.info_outline, color: Colors.orange),
            title: Text('Joining as Guest'),
            subtitle: Text(
              'You will be removed when all participants leave or after 24 hours.',
            ),
          ),
          
          // Join button
          _buildJoinButton(),
        ],
      ),
    );
  }
}
```

   - **Key Differences from Regular PreJoin:**
     - No participant count check (external users don't need this)
     - Uses `ExternalParticipantService.joinAsExternal()` instead of `VideoConferenceService`
     - Shows "Guest" badge and session expiration notice
     - Keys stored in SessionStorage (handled by service)
   - **Reused Components:**
     - Device enumeration and selection dropdowns
     - Camera preview with RTCVideoView
     - E2EE status indicator
     - Control buttons (camera/mic toggle)

4. **Meeting Entry:**
   - Navigate to VideoConferenceView with external session ID
   - E2EE works normally using temporary keys
   - Session expires when: (1) All server users leave, OR (2) 24 hours pass
   - External user kicked out when session expires

**Questions:**
- ~~Should external participants see a countdown if they join early?~~ ✅ **ANSWERED: Yes, show countdown on landing page**
- ~~Should we require email for external participants, or make it optional?~~ ✅ **ANSWERED: No email required**
- ~~What happens if an external user refreshes the page - lose session or restore?~~ ✅ **ANSWERED: Restore from SessionStorage (keys preserved until tab close)**

---

### 4.2 External Participant UI

**Restrictions for External Users:**
- Video-only: No text chat, no file sharing
- Cannot see message history or previous meeting content
- Cannot access channels, direct messages, or other PeerWave features
- Cannot create meetings or invite others
- Kicked out automatically when all server users leave
- Maximum session duration: 24 hours (then forced disconnect)

**Video Conference Features (Same as Regular Users):**
- Enable/disable video camera
- Enable/disable microphone
- Screen sharing (if meeting allows)
- See all participants
- Reactions/hand raise (if implemented)

**UI Indicators:**
- Badge next to external participant names: "Guest" (grey badge)
- Meeting host sees list of external participants in participants panel
- Option to remove external participants (meeting owner/manager only)
- External participants cannot see each other's "Guest" badge (privacy)

**Session Expiration Handling:**
- 5-minute warning: "You will be disconnected in 5 minutes when the last participant leaves"
- Auto-disconnect with message: "Meeting ended - all participants have left"
- No ability to rejoin (token becomes invalid)

**Questions:**
- ~~Should external participants' video quality be limited to save bandwidth?~~ ✅ **ANSWERED: No limits, same quality as regular users**
- ~~Should we show a watermark on screen for external participants?~~ ✅ **ANSWERED: No watermark, just "Guest" badge in participant list**

---

## **PHASE 5: Integration & Testing** (2-3 days)

### 5.1 Integration Tasks

- [ ] Connect MeetingService to REST API
- [ ] Connect InstantCallService to Socket.IO events (wrapper for meeting events)
- [ ] Connect PresenceService to heartbeat system
- [ ] Integrate event bus with all UI components
- [ ] Add unified cleanup cron job:
  - **Instant calls (is_instant_call = TRUE):** Delete immediately when all participants leave
  - **Scheduled meetings:** Delete 8 hours after end_time
  - **Fallback:** Delete any meeting/call older than 8 hours (safety net)
- [ ] Add external session cleanup cron job (delete expired sessions)

### 5.2 Testing Checklist

**Meetings:**
- [ ] Create meeting with valid data
- [ ] Create meeting with overlapping times (conflict detection)
- [ ] Edit meeting details
- [ ] Cancel meeting
- [ ] Join meeting 15 minutes before start
- [ ] Join meeting after start time
- [ ] Meeting appears in "Upcoming" list
- [ ] Meeting moves to "Past" list after ending
- [ ] Meeting deleted 8 hours after end
- [ ] Pre-meeting notification appears at 15 min before
- [ ] Multiple participants can join same meeting

**Instant Calls:**
- [ ] Start instant call from 1:1 chat (creates meeting with is_instant_call = TRUE)
- [ ] Start instant call from group channel
- [ ] Receive incoming call notification (ringtone plays after decryption)
- [ ] Accept call → navigate to video view
- [ ] Decline call → notify caller
- [ ] Call ends when all participants leave
- [ ] Call (meeting record) deleted immediately when all participants leave
- [ ] Call deleted after 8 hours if abandoned (fallback cleanup)
- [ ] Offline users do NOT receive call notification
- [ ] Can add participants to active call (same meetingId preserved)
- [ ] Can generate external invite link during call
- [ ] External guest can join call via link → manual admission required

**Online Status:**
- [ ] User status updates to "online" on login
- [ ] User status updates to "away" after 5 min inactivity
- [ ] User status updates to "offline" on disconnect
- [ ] Status updates appear in real-time on channel member list
- [ ] Status updates appear in real-time on 1:1 conversation list
- [ ] Only relevant user statuses are tracked (conversations + channels)

**External Participants:**
- [ ] Generate invitation link for meeting
- [ ] External user can access join page within time window (±1h of start)
- [ ] External user blocked outside time window (±1h of start)
- [ ] External user can enter display name
- [ ] Temporary keys generated and stored in SessionStorage
- [ ] External user can join meeting
- [ ] External user can send/receive video
- [ ] External user can send/receive audio
- [ ] External user cannot see message history
- [ ] External user cannot access other PeerWave features
- [ ] External user can reconnect using existing SessionStorage keys
- [ ] External user generates new keys if SessionStorage is empty
- [ ] External session expires after meeting ends
- [ ] External session expires after 24 hours

**Event Bus:**
- [ ] Channel list refreshes when new channel created
- [ ] Message list refreshes when new message received
- [ ] Context panel refreshes when channel updated
- [ ] No excessive re-renders (check with Flutter DevTools)
- [ ] Events still work after hot reload

---

## 📊 Estimated Timeline

| Phase | Duration | Priority |
|-------|----------|----------|
| Phase 1: Backend Infrastructure | 3-4 days | 🔴 Critical |
| Phase 2: Frontend Infrastructure | 3-4 days | 🔴 Critical |
| Phase 3: UI Components | 4-5 days | 🟡 High |
| Phase 4: External Participants | 3-4 days | 🟢 Medium |
| Phase 5: Integration & Testing | 2-3 days | 🔴 Critical |
| **Total** | **15-20 days** | |

---

## 🎨 Design Considerations

### Color Scheme
**IMPORTANT: Use theme colors only - no static colors**
- Meeting notification bar: `colorScheme.primary`
- Incoming call overlay: `colorScheme.secondary`
- Online status: `colorScheme.tertiary` or `Colors.green` from theme
- Offline status: `colorScheme.onSurface.withOpacity(0.38)`
- All colors must adapt to light/dark theme automatically

### Icons
- Meetings: `Icons.event` or `Icons.video_call`
- Instant Call: `Icons.phone` or `Icons.videocam`
- Join Meeting: `Icons.meeting_room`
- External Participant: `Icons.person_add`

### Animations
- Meeting notification slide-in from top
- Call notification fade-in with scale
- Online status pulse effect
- Channel list smooth updates

---

## 🔒 Security Considerations

1. **External Participants:**
   - Temporary keys must be securely generated (use libsignal)
   - Session tokens must be cryptographically random (use `crypto.randomBytes`)
   - Sessions must expire (max 24 hours)
   - Rate limiting on invitation endpoint (max 10 joins per token)

2. **Instant Calls:**
   - Only authenticated users can create calls
   - Temp channels must have access control (only invited users)
   - Temp channels must auto-expire

3. **Presence Tracking:**
   - Only track users in active conversations/channels (privacy)
   - Heartbeat data should not be stored long-term
   - Users should be able to hide their online status (future feature)

---

## ✅ Requirements Confirmed

### Meetings
1. ✅ **Completely separate entities** from channels - new database tables, own permission system
2. ✅ **Reuse WebRTC channel logic** - same video infrastructure, just different context
3. ✅ **Any authenticated user can create meetings**
4. ✅ **Video-only** - no text chat in meetings
5. ✅ **New role system for meetings**: Owner (creator), Manager (pre-generated), Member (pre-generated)
6. ✅ **Meeting notifications**: 
   - Top bar shows 15 min before (dismissible)
   - Shows again at start time (dismissible)
   - Activity notifications only if user is invited
   - All meetings visible in Meetings page

### Instant Calls
7. ✅ **Immediate notification** like phone call with ringtone
8. ✅ **Top bar with Accept/Decline**
9. ✅ **Decline feedback**: Caller gets snackbar notification
10. ✅ **Accept behavior**: WebRTC temp channel starts immediately
11. ✅ **Waiting screen for instant calls**: Caller sees profile pictures in grid with greyed overlay until joiners accept
12. ✅ **Only online users** get call notifications
13. ✅ **Temp channel lifetime**: Until all participants leave
14. ✅ **Video-only** - no text chat

### Online Status
15. ✅ **Heartbeat interval**: 1 minute
16. ✅ **Online definition**: Logged in with active socket connection
17. ✅ **No typing indicators**

### External Participants
18. ✅ **Stay duration**: Until all server users leave the meeting
19. ✅ **Video-only** - no text chat, no message history
20. ✅ **PreJoin page**: Display name entry (similar to regular prejoin)
21. ✅ **Access control**: Valid invitation link required
22. ✅ **Invitation validity**: 1 hour before to 1 hour after meeting start time
23. ✅ **Reconnection**: Reuse keys from SessionStorage if available, otherwise generate new

### Event Bus
24. ✅ **No live typing indicators**
25. ✅ **Real-time message counts** across all views
26. ✅ **Batch event updates** to avoid UI thrashing

### Permissions
27. ✅ **Meeting permissions**: Separate from channels, creator controls settings
28. ✅ **Meeting options**: Voice-only mode, mute on join, etc.

### UI/UX
29. ✅ **Meetings page**: List view (not calendar)
30. ✅ **Join button**: Only shown when meeting is started
31. ✅ **Past meetings**: Show duration and participants (last 8 hours only)
32. ✅ **Meeting page layout**: Chips for "Past" and "Upcoming"

---

## ✅ Open Questions - ANSWERED

### Database & Backend

1. ✅ **Participant leave tracking:** How do we detect when "all participants have left" for immediate cleanup?
   - **ANSWER: WebSocket disconnect events**
   - Implementation: Listen to `disconnect` events, update `left_at` timestamp
   - When last participant disconnects → trigger immediate DELETE
   - Fallback cron job (every 5 min) checks for orphaned calls

2. ✅ **MeetingId format:** Should instant calls have different ID prefixes?
   - **ANSWER: Yes, use different prefixes**
   - Scheduled meetings: `mtg_abc123`
   - Instant calls: `call_abc123`
   - Benefits: Easier debugging, logs filtering, analytics

3. ✅ **External participants in calls:** Should we limit max session duration for call external guests?
   - **ANSWER: No, same 24h limit for both**
   - Consistency: External guests treated equally in meetings and calls
   - Session ends when: all server users leave OR 24h expires (whichever first)

### Frontend & UX

4. ✅ **Call history:** Should instant calls appear in Meetings page "Past" list?
   - **ANSWER: Yes, show all in unified list**
   - Display both meetings and calls in "Past (8h)" section
   - Visual distinction: Phone icon (📞) for calls, Calendar icon (📅) for meetings
   - Same "View Details" dialog for both

5. ✅ **Mid-call participant addition UX:** When adding 3rd person to 2-person call:
   - **ANSWER: Silent addition (no message)**
   - No "upgraded to group call" notification
   - Participant just joins seamlessly
   - Same meetingId, same call, just more people

6. ✅ **Ringtone timing:** After Signal decryption completes:
   - **ANSWER: Play ringtone immediately**
   - No artificial delay
   - Assumption: Signal decryption is fast (<100ms)
   - Smooth UX: Decrypt → Show name/avatar → Play ringtone (atomic)

7. ✅ **External link for active calls:** If user generates external link during call:
   - **ANSWER: Yes, separate landing page with call-specific UX**
   - Show: "Call in progress - X participants currently active"
   - Different from meetings: Emphasize it's a live call (more urgent)
   - After landing → use same PreJoin functions (camera/mic selection)
   - Then → manual admission by any participant

### E2EE & Security

8. ✅ **E2EE key exchange when adding participants mid-call:**
   - **ANSWER: Standard E2EE exchange - new participants go through PreJoin**
   - New joiner completes PreJoin page (device + E2EE key exchange)
   - Requests sender keys from all existing participants
   - Existing participants don't need to do anything
   - Same pattern as joining scheduled meeting late

9. ✅ **External participant key reuse across calls:**
   - **ANSWER: Yes, keys can be reused**
   - SessionStorage preserves keys across multiple meeting/call joins
   - External user can join Meeting A, leave, then join Call B with same keys
   - Only regenerate if: SessionStorage cleared OR keys expired
   - Benefit: Faster rejoins, better UX

### API & Integration

10. ✅ **Call wrapper endpoint responses:**
    - **RECOMMENDATION: Return full Meeting objects (Option A)**
    - Rationale: Client code can handle Meeting universally
    - No need for separate Call vs Meeting handling
    - Frontend just checks `meeting.isInstantCall` flag for UI differences
    - Cleaner architecture, less code duplication

11. ✅ **Bulk operations:** Can we delete multiple meetings/calls at once?
    - **ANSWER: Yes, add bulk delete endpoint**
    - Endpoint: `DELETE /api/meetings/bulk` with `{ meetingIds: [...] }`
    - Admin only (permission check)
    - Use case: Cleanup abandoned calls, mass cancellations
    - Returns: `{ deleted: 5, failed: 0, errors: [] }`

12. ✅ **Meeting/Call transitions:** Can a scheduled meeting be "converted" to instant call?
    - **ANSWER: No conversion, but meetings can start early**
    - Users (not external guests) can start meeting before scheduled time
    - `is_instant_call` flag remains FALSE (it's still a scheduled meeting)
    - Cleanup timing: Based on scheduled end_time (not actual end time)
    - Example: Meeting scheduled 2pm-3pm, starts at 1:50pm, ends 2:40pm
      - Cleanup happens at 3pm + 8h = 11pm (based on schedule, not actual)

---

## 🆕 Additional Open Questions

### 1. Early Meeting Start - Participant Admission
✅ **Question:** When a scheduled meeting starts early (before scheduled time):
- Should external guests be able to join early via invitation link?

**ANSWER: Conditional access based on meeting activity**
- External guest arrives at prejoin page anytime
- **If no participants joined yet:**
  - Prejoin page shows: "Meeting hasn't started yet - Please wait"
  - "Ask for Access" button is DISABLED
  - Guest must wait until at least one participant joins
- **If at least one participant has joined:**
  - "Ask for Access" button becomes ENABLED
  - Guest clicks button → Enters waiting room
  - Any active participant can admit the guest
- **Implementation:** Backend checks `meeting_participants` for any `joined_at IS NOT NULL`

### 4. Early Meeting End - Cleanup Timing
✅ **Question:** If meeting scheduled 2pm-3pm but all participants leave at 2:30pm:
- When should cleanup happen?

**ANSWER: Smart cleanup based on actual vs scheduled**
- **If all leave BEFORE scheduled end_time:**
  - Example: Meeting 2pm-3pm, all leave at 2:30pm
  - Cleanup immediately (treat like instant call)
- **If meeting ends AFTER scheduled end_time:**
  - Example: Meeting 2pm-3pm, all leave at 3:10pm  
  - Cleanup at scheduled_end_time + 8h = 11pm
- **Logic:** `IF (all_left_at < end_time) THEN delete_immediately ELSE delete_at(end_time + 8h)`
- Benefits: Saves database space for early-ending meetings, preserves history for long meetings

### 5. Participant Count in "Past" List
✅ **Question:** For calls/meetings in "Past" list:
- Which participant count to show?

**ANSWER: Total unique participants who joined**
- Count everyone who joined at any point (has `joined_at` timestamp)
- Display: "✓ Ended - 15 min • 8 participants"
- Benefits: Shows meeting reach/engagement
- **Implementation:** `SELECT COUNT(DISTINCT user_id) FROM meeting_participants WHERE joined_at IS NOT NULL`

### 7. External Admission During Early Start
✅ **Question:** If server users start meeting early, how do external guests join?

**ANSWER: Conditional "Ask for Access" based on participant presence**
- External guest lands on prejoin page anytime
- **Backend check:** Does meeting have any participants with `joined_at IS NOT NULL`?
- **If no participants joined:**
  - Prejoin page shows: "Meeting hasn't started yet"
  - "Ask for Access" button DISABLED (greyed out)
  - Display: "The meeting will begin soon. Please wait..."
- **If at least one participant joined:**
  - "Ask for Access" button ENABLED
  - Guest completes device selection
  - Clicks button → Backend creates admission request
  - All active participants see admission overlay
  - Any participant can admit/decline
- **Implementation:** Socket.IO event `meeting:participant_count` broadcasts when first user joins

### 2. Call ID Prefix in Database
✅ **Question:** You want `call_abc123` prefix for instant calls:
- Should this be the actual `meeting_id` value in database?

**ANSWER: Store prefix directly in database**
- Meetings: `meeting_id = 'mtg_' + uuid`
- Instant calls: `meeting_id = 'call_' + uuid`
- Benefits:
  - Simpler queries: `WHERE meeting_id LIKE 'call_%'`
  - Easier debugging in logs
  - No API layer transformation needed
- **Implementation:** ID generation logic checks `is_instant_call` flag

### 3. Bulk Delete Permission Scope
✅ **Question:** For bulk delete endpoint:
- Who should be able to bulk delete meetings/calls?

**ANSWER: Owners can bulk delete their meetings**
- Endpoint: `DELETE /api/meetings/bulk`
- Body: `{ meetingIds: ['mtg_123', 'call_456'] }`
- Permission check: User must be owner (created_by) of each meeting
- Returns: `{ deleted: 5, failed: 2, errors: [{meetingId: 'mtg_xyz', reason: 'Not owner'}] }`
- Admin override: System admins can delete any meetings
- **Implementation:** Loop through IDs, check ownership, collect results

### 6. SessionStorage Key Reuse Security
✅ **Question:** You said external keys can be reused across meetings:
- Should there be limits on reuse?

**ANSWER: No limits on key reuse**
- External user can join unlimited meetings/calls with same keys
- Keys valid until:
  - Tab closes (SessionStorage cleared)
  - User manually clears browser data
  - No time-based expiration
  - No usage count limit
- Benefits: Best UX, faster rejoins, less key generation overhead
- Security: Keys are still temporary (lost on tab close), session-specific
- **Implementation:** Always check SessionStorage first, only generate if missing

### 8. "Call in Progress" Landing Page Details
✅ **Question:** For external joining active call/meeting, what to show on landing page?

**ANSWER: Different visibility for internal vs external participants**
- **Server users (internal) see:**
  - Full participant list: "Alice, Bob, and Carol are in the call"
  - Profile pictures + names
  - Who started the call
- **External guests see:**
  - Count only: "3 participants currently active"
  - No names or avatars (privacy protection)
  - Generic: "Call in progress"
- **Implementation:**
  - API endpoint `/api/meetings/:id/preview`
  - If authenticated user: Return full participant list
  - If external token: Return only count
- **Benefits:** Transparency for internal users, privacy for external guests

### 9. Webhook for Meeting/Call Events
✅ **Question:** Should PeerWave support webhooks for external integrations?

**ANSWER: Yes, implement webhook system**
- **Phase 6 feature** (post-MVP, but plan architecture now)
- **Webhook events:**
  - `meeting.created`, `meeting.started`, `meeting.ended`, `meeting.cancelled`
  - `call.started`, `call.ended`
  - `participant.joined`, `participant.left`
  - `external.joined`, `external.admitted`, `external.declined`
- **Configuration:**
  - Per-channel or global webhook URLs
  - HMAC signature for verification
  - Retry logic (3 attempts with exponential backoff)
- **Use cases:** Calendar sync, attendance tracking, billing, analytics, CRM integration
- **Database table (design now):**
  ```sql
  CREATE TABLE webhooks (
    webhook_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL, -- Webhook owner
    url TEXT NOT NULL,
    secret TEXT NOT NULL, -- For HMAC signing
    events TEXT NOT NULL, -- JSON array ['meeting.started', 'call.ended']
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  ```

### 10. Meeting Recording Support
✅ **Question:** Should the schema include fields for future recording feature?

**ANSWER: Plan separate recordings table, create when implementing**
- **Don't add fields to meetings table now**
- **Future design (Phase 7+):**
  ```sql
  CREATE TABLE meeting_recordings (
    recording_id TEXT PRIMARY KEY,
    meeting_id TEXT REFERENCES meetings(meeting_id) ON DELETE CASCADE,
    started_by TEXT NOT NULL, -- Who started recording
    started_at TIMESTAMP NOT NULL,
    ended_at TIMESTAMP,
    duration INTEGER, -- Seconds
    file_size INTEGER, -- Bytes
    storage_url TEXT, -- S3/local path
    format TEXT DEFAULT 'webm', -- Video format
    is_transcribed BOOLEAN DEFAULT FALSE,
    transcript_url TEXT,
    is_deleted BOOLEAN DEFAULT FALSE,
    deleted_at TIMESTAMP,
    INDEX idx_meeting_id (meeting_id)
  );
  ```
- **Benefits:** Clean separation, easier to add later, no schema bloat now
- **Note:** Keep in documentation but don't implement yet

---

## 🎯 Final Open Questions

### Implementation Details

1. ❓ **External guest "Ask for Access" button state management:**
   - How does frontend know if any participant has joined?
   - Socket.IO event when first participant joins?
   - Or poll API endpoint every 5 seconds?
   - **Recommendation:** Socket.IO event `meeting:first_participant_joined` (real-time)

2. ❓ **Smart cleanup implementation:**
   - For "immediate delete when all leave before scheduled end", should we:
   - A) Trigger on last WebSocket disconnect
   - B) Cron job checks every 5 min for `all_left_at < end_time AND all_left_at IS NOT NULL`
   - C) Both (WebSocket primary, cron fallback)
   - **Recommendation:** Option C (reliability)

3. ❓ **Bulk delete transaction handling:**
   - If deleting 100 meetings and one fails at #50:
   - A) Rollback all (atomic)
   - B) Continue, report failures (partial success)
   - C) Stop at first failure
   - **Recommendation:** Option B - Continue and report failures (most useful)

4. ❓ **Webhook retry failures:**
   - After 3 failed webhook attempts:
   - A) Disable webhook automatically
   - B) Send email to webhook owner
   - C) Log and continue silently
   - D) A + B (disable and notify)
   - **Recommendation:** Option D - Disable webhook + notify owner

5. ❓ **Call ID generation timing:**
   - When to generate `call_abc123` prefix?
   - A) Before database INSERT (in service layer)
   - B) Database trigger on INSERT (if is_instant_call = TRUE)
   - C) Application layer default value
   - **Recommendation:** Option A - Service layer (explicit control)

### Performance & Scale

6. ❓ **"Past" list query performance:**
   - With 10,000+ meetings in database:
   - Should we index `end_time` + `is_instant_call` for "Past 8h" query?
   - Or create materialized view?
   - **Recommendation:** Composite index `(end_time DESC, is_instant_call)` sufficient

7. ❓ **Participant count caching:**
   - Total unique participants: `COUNT(DISTINCT user_id WHERE joined_at IS NOT NULL)`
   - Cache this on meeting record (participant_count column)?
   - Or calculate on-the-fly?
   - **Recommendation:** Cache - update when participant joins/leaves

8. ❓ **WebSocket event fanout:**
   - For meetings with 100+ participants:
   - How to broadcast `meeting:participant_joined` efficiently?
   - A) Loop and emit to each
   - B) Room-based broadcast
   - C) Batch emit
   - **Recommendation:** Option B - Socket.IO rooms (scalable)

### Security & Privacy

9. ❓ **External guest preview API security:**
   - Endpoint `/api/meetings/:id/preview` (shows participant count/names)
   - Should external guests authenticate with invitation token?
   - Or allow anonymous preview?
   - **Recommendation:** Require token - prevent meeting enumeration attacks

10. ❓ **Admission request spam prevention:**
    - External guest can spam "Ask for Access" button?
    - A) Rate limit: 3 requests per 5 minutes per session
    - B) Cooldown: 30 seconds between requests
    - C) Block after 5 declined requests
    - D) All of the above
    - **Recommendation:** Option D - Comprehensive anti-spam

### UX & Edge Cases

11. ❓ **Meeting starts early + external guest waiting:**
    - Guest lands on prejoin at 1:50pm (meeting scheduled 2pm)
    - Sees "Meeting hasn't started yet" message
    - Server user joins at 1:55pm
    - How does guest know meeting started?
    - A) Auto-refresh page every 10 seconds
    - B) Socket.IO event updates button state
    - C) Guest must manually refresh
    - **Recommendation:** Option B - Socket.IO real-time update

12. ❓ **Bulk delete progress indicator:**
    - When deleting 500 meetings:
    - A) Show progress bar (1/500, 2/500, ...)
    - B) Show spinner until complete
    - C) Background job + notification when done
    - **Recommendation:** Option C for large batches (>50), Option A for small batches

13. ❓ **Smart cleanup edge case:**
    - Meeting 2pm-3pm, Alice joins 2pm, leaves 2:10pm (before scheduled end)
    - Bob joins 2:50pm (before scheduled end)
    - When does cleanup happen?
    - A) When Bob leaves (last participant before scheduled end)
    - B) Wait until 3pm + 8h (someone joined before scheduled end)
    - **Recommendation:** Option B - If anyone joined before scheduled end, use scheduled cleanup

14. ❓ **External guest key reuse - E2EE implications:**
    - Guest joins Meeting A, leaves
    - Later joins Call B with same keys
    - Does this weaken E2EE security? (Same identity across sessions)
    - Should we prompt "Generate new keys for this call?"
    - **Recommendation:** Safe - keys are per-session, not per-meeting. No prompt needed.

15. ❓ **Call history privacy:**
    - User sees "📞 Call with Alice (Call)" in Past list
    - Should this be visible to:
    - A) All call participants
    - B) Only call creator
    - C) Participants + channel members (if from channel)
    - **Recommendation:** Option A - All participants (they were there)

---

## ✅ Document Status: **IMPLEMENTATION READY**

All critical questions answered. Action plan is complete and ready for development.

**Next Step:** Begin Phase 1 - Backend Infrastructure
    - C) Participants + channel members (if from channel)
    - **Recommendation:** Option A - All participants (they were there)

---

**Do you want to answer these 15 questions now, or should I proceed with the recommendations marked above?**

Alternatively, if you're satisfied with the current state, I can mark the document as **"Implementation Ready"** and we can start Phase 1!

## 🚪 Waiting Room / PreJoin Clarification

**Important:** "Waiting Room" and "PreJoin" are the **same thing** - they both refer to the device selection page where E2EE keys are exchanged.

### For All Users (Server + External):

**PreJoin Page Components:**
1. **Device Selection:**
   - Camera dropdown (enumerate devices)
   - Microphone dropdown (enumerate devices)
   - Camera preview with RTCVideoView
   - Toggle buttons (enable/disable camera/mic)

2. **E2EE Key Exchange:**
   - First participant: Generate E2EE key
   - Subsequent participants: Request E2EE key from first participant
   - Signal Protocol encryption/decryption
   - Status indicator: "🔒 Encrypted connection"

3. **Join Button:**
   - Enabled after device selection + E2EE key exchange
   - Behavior differs based on user type (see below)

### Auto-Admission vs Manual Admission:

**Server Users (Invited Participants):**
- ✅ Invited to meeting via participant selection
- ✅ Complete prejoin (device + E2EE)
- ✅ Click "Join Meeting" → **Auto-admitted immediately**
- ✅ Enter VideoConferenceView without waiting
- **No manual approval needed**

**External Guests (Invitation Link):**
- ✅ Access prejoin via invitation token only
- ✅ Enter display name on landing page
- ✅ Complete prejoin (device + E2EE)
- ⏳ Click "Join Meeting" → **Button shows spinner**
- ⏳ See message: "Waiting for a participant to admit you"
- ⏳ All current meeting participants see admission overlay:
  ```
  ┌────────────────────────────────────┐
  │ Guest Waiting to Join              │
  │                                    │
  │ [Display Name]                     │
  │                                    │
  │ [Decline]        [Admit]          │
  └────────────────────────────────────┘
  ```
- ✅ Any participant clicks "Admit" → Guest enters meeting
- ❌ Any participant clicks "Decline" → Guest sees "Request declined", join button disabled, must reload page to retry

### Implementation Notes:

**Backend Check After PreJoin:**
```javascript
// After E2EE key exchange completes
if (user.isServerUser && user.isInvited) {
  // Auto-admit
  socket.emit('meeting:auto_admitted', { meetingId, userId });
  // User proceeds to VideoConferenceView
} else if (user.isExternal) {
  // Manual admission required
  socket.broadcast.to(meetingId).emit('meeting:guest_waiting', {
    sessionId: user.sessionId,
    displayName: user.displayName,
  });
  // User waits for admission
}
```

**Socket Events:**
- `meeting:guest_waiting` - Notify meeting participants that external guest completed prejoin
- `meeting:guest_admitted` - Participant admits the guest
- `meeting:guest_declined` - Participant declines the guest

**Database:**
- No `waitingRoomEnabled` column needed (it's always enabled)
- Track admission status in `external_participants.admission_status` (pending/admitted/declined)

---

## 🛠️ Implementation Details

### Participant Management Patterns

**1. User Search & Selection (Reuse from `channel_members_screen.dart`):**

```dart
// In meeting participant selection dialog
Future<void> _searchUsers(String query) async {
  if (query.length < 2) {
    setState(() => _searchResults = []);
    return;
  }
  
  setState(() => _isSearching = true);
  
  try {
    final resp = await ApiService.searchUsers(widget.host, query);
    final users = (resp.data as List).map((u) => {
      'uuid': u['uuid'] as String,
      'displayName': u['displayName'] as String,
    }).toList();
    
    setState(() {
      _searchResults = users;
      _isSearching = false;
    });
  } catch (e) {
    debugPrint('[MeetingDialog] Search error: $e');
    setState(() => _isSearching = false);
  }
}

// Build user tile with avatar and online status
Widget _buildUserTile(Map<String, String> user) {
  final userId = user['uuid']!;
  final displayName = user['displayName']!;
  final isOnline = PresenceService.instance.isUserOnline(userId);
  
  return ListTile(
    leading: Stack(
      children: [
        _buildSquareAvatar(userId, displayName),
        Positioned(
          right: 0,
          bottom: 0,
          child: OnlineStatusIndicator(userId: userId, size: 8),
        ),
      ],
    ),
    title: Text(displayName),
    subtitle: Text(isOnline ? 'Online' : 'Offline'),
    trailing: Checkbox(
      value: _selectedParticipants.contains(userId),
      onChanged: (selected) {
        setState(() {
          if (selected == true) {
            _selectedParticipants.add(userId);
          } else {
            _selectedParticipants.remove(userId);
          }
        });
      },
    ),
  );
}
```

**2. Profile Avatar Builder (Reuse from `channel_members_screen.dart`):**

```dart
Widget _buildSquareAvatar(String userId, String displayName) {
  final profile = UserProfileService.instance.getProfileOrLoad(
    userId,
    onLoaded: (profile) {
      if (mounted) setState(() {
        _profileCache[userId] = profile;
      });
    },
  );
  
  final pictureData = profile?['picture'] as String?;
  final effectiveName = profile?['displayName'] as String? ?? displayName;
  
  ImageProvider? imageProvider;
  if (pictureData != null && pictureData.isNotEmpty) {
    try {
      if (pictureData.startsWith('data:image/')) {
        final base64Data = pictureData.split(',')[1];
        final bytes = base64Decode(base64Data);
        imageProvider = MemoryImage(bytes);
      } else if (pictureData.startsWith('http')) {
        imageProvider = NetworkImage(pictureData);
      }
    } catch (e) {
      debugPrint('[Avatar] Error parsing picture: $e');
    }
  }
  
  return Container(
    width: 40,
    height: 40,
    decoration: BoxDecoration(
      color: imageProvider == null
          ? Theme.of(context).colorScheme.primaryContainer
          : null,
      borderRadius: BorderRadius.circular(4),
      image: imageProvider != null
          ? DecorationImage(image: imageProvider, fit: BoxFit.cover)
          : null,
    ),
    child: imageProvider == null
        ? Center(
            child: Text(
              effectiveName.isNotEmpty ? effectiveName[0].toUpperCase() : '?',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          )
        : null,
  );
}
```

### Video Conference Integration

**Meeting Join Flow (Adapt from `video_conference_prejoin_view.dart`):**

```dart
class MeetingJoinScreen extends StatefulWidget {
  final String meetingId;
  
  @override
  State<MeetingJoinScreen> createState() => _MeetingJoinScreenState();
}

class _MeetingJoinScreenState extends State<MeetingJoinScreen> {
  // REUSE ALL STATE from video_conference_prejoin_view.dart:
  // - Device selection state
  // - E2EE key exchange state
  // - Preview track state
  // - Participant check state
  
  @override
  void initState() {
    super.initState();
    _initializePreJoin();
  }
  
  Future<void> _initializePreJoin() async {
    // 1. Check socket connection (SAME)
    // 2. Ensure Signal Service initialized (SAME)
    // 3. Load media devices (SAME)
    // 4. Register as meeting participant (NEW socket event)
    await _registerAsMeetingParticipant();
    // 5. Check participant status (ADAPTED for meetings)
    await _checkMeetingParticipantStatus();
    // 6. Load sender keys (SAME)
    await _loadMeetingSenderKeys();
    // 7. E2EE key exchange (SAME logic, different event)
    if (_isFirstParticipant) {
      await _generateE2EEKey();
    } else {
      await _requestE2EEKey();
    }
    // 8. Start preview (SAME)
    if (_isCameraEnabled && _selectedCamera != null) {
      await _startCameraPreview();
    }
  }
  
  Future<void> _registerAsMeetingParticipant() async {
    SocketService().emit('meeting:register-participant', {
      'meetingId': widget.meetingId,
    });
  }
  
  Future<void> _checkMeetingParticipantStatus() async {
    // SAME pattern as video:check-participants but with meeting:check-participants
    final completer = Completer<Map<String, dynamic>>();
    
    void listener(dynamic data) {
      completer.complete(data);
    }
    
    SocketService().registerListener('meeting:participants-info', listener);
    SocketService().emit('meeting:check-participants', {
      'meetingId': widget.meetingId,
    });
    
    final result = await completer.future.timeout(Duration(seconds: 5));
    SocketService().unregisterListener('meeting:participants-info', listener);
    
    setState(() {
      _isFirstParticipant = result['isFirst'] as bool;
      _participantCount = result['count'] as int;
    });
  }
  
  Future<void> _joinMeeting() async {
    if (!_hasE2EEKey) return;
    
    // Navigate to video conference view (SAME as channels)
    final videoService = VideoConferenceService.instance;
    final success = await videoService.joinChannel(
      channelId: widget.meetingId, // Use meetingId as channelId
      channelName: _meetingTitle,
      selectedCamera: _selectedCamera,
      selectedMicrophone: _selectedMicrophone,
    );
    
    if (success && mounted) {
      // Navigate to VideoConferenceView (REUSE existing view)
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => VideoConferenceView(
            channelId: widget.meetingId,
            channelName: _meetingTitle,
            selectedCamera: _selectedCamera,
            selectedMicrophone: _selectedMicrophone,
          ),
        ),
      );
    }
  }
}
```

**Key Point:** Meetings reuse `VideoConferenceView` and `VideoConferenceService` - the only difference is the context (meeting vs channel). The WebRTC logic, grid layout, controls, and E2EE are identical.

### Permission System Integration

**Meeting Permission Checks (Pattern from `channel_members_screen.dart`):**

```dart
// In meetings screen/dialogs
final roleProvider = Provider.of<RoleProvider>(context);

final canCreateMeeting = roleProvider.isAdmin || 
    roleProvider.hasGlobalPermission('meeting.create');

final canEditMeeting = roleProvider.isAdmin ||
    roleProvider.isMeetingOwner(meetingId) ||
    roleProvider.hasMeetingPermission(meetingId, 'meeting.edit');

final canDeleteMeeting = roleProvider.isAdmin ||
    roleProvider.isMeetingOwner(meetingId);

final canInviteParticipants = roleProvider.isAdmin ||
    roleProvider.isMeetingOwner(meetingId) ||
    roleProvider.hasMeetingPermission(meetingId, 'meeting.invite');

final canRemoveParticipants = roleProvider.isAdmin ||
    roleProvider.isMeetingOwner(meetingId) ||
    roleProvider.hasMeetingPermission(meetingId, 'meeting.kick');
```

**Role Assignment UI (Reuse from `channel_members_screen.dart`):**

```dart
Future<void> _showAssignMeetingRoleDialog(MeetingParticipant participant) async {
  Role? selectedRole;
  
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('Assign Role to \${participant.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButton<Role>(
              value: selectedRole,
              hint: const Text('Select a role'),
              isExpanded: true,
              items: _availableMeetingRoles.map((role) {
                return DropdownMenuItem(
                  value: role,
                  child: Text(role.name),
                );
              }).toList(),
              onChanged: (role) {
                setState(() => selectedRole = role);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: selectedRole == null
                ? null
                : () => Navigator.pop(context, true),
            child: const Text('Assign'),
          ),
        ],
      ),
    ),
  );
  
  if (result == true && selectedRole != null) {
    try {
      await MeetingService.instance.assignMeetingRole(
        meetingId: widget.meetingId,
        userId: participant.userId,
        roleId: selectedRole!.uuid,
      );
      _showSuccess('Role assigned successfully');
      _loadParticipants();
    } catch (e) {
      _showError(e.toString());
    }
  }
}
```

---

## 📖 User Scenarios & Flows

### Scenario 1: Creating and Joining a Scheduled Meeting

**Actors:** Alice (Meeting Creator), Bob, Carol (Participants)

**Flow:**

1. **Alice creates a meeting:**
   - Navigates to Meetings page via sidebar icon
   - Clicks "+ Create" button
   - Fills out meeting dialog:
     - Title: "Sprint Planning"
     - Description: "Q1 2025 Sprint Planning Session"
     - Start time: Tomorrow 14:00
     - Duration: 1h 30min
     - Participants: Searches and selects Bob, Carol
     - `is_instant_call` = FALSE (scheduled meeting)
   - Clicks "Save"
   - Backend creates meeting in `meetings` table, assigns Alice as Owner role
   - Signal message `meeting:created` event
   - Bob and Carol see meeting in their "Upcoming" list

2. **Bob accepts the invitation:**
   - Opens Meetings page
   - Sees "Sprint Planning" with status "Invited"
   - Clicks "Accept"
   - Status changes to "Accepted"
   - Alice receives notification via EventBus

3. **15 minutes before meeting:**
   - All participants receive top bar notification
   - "🎥 Meeting starting in 14 minutes: Sprint Planning"
   - Notification is dismissible
   - Sidebar badge shows pulsing red dot
   - Activities page shows notification (notification marked as readed if dismissed click or meeting joined)

4. **At meeting start time (14:00):**
   - Meeting status changes to 'in_progress'
   - Top bar notification changes to "🔴 Meeting started: Sprint Planning"
   - "Join Meeting" button appears in meeting list
   - dismissible for 5 minutes 
   - Activities page shows notification (notification marked as readed if dismissed click or meeting joined)

5. **Alice joins first:**
   - Clicks "Join Meeting"
   - Navigates to MeetingJoinScreen (prejoin)
   - System checks: Socket connected, Signal Service initialized
   - Loads cameras and microphones
   - Registers as participant via `meeting:register-participant`
   - Checks participant status (she's first)
   - Generates E2EE key via VideoConferenceService
   - Starts camera preview
   - Clicks "Join"
   - Enters VideoConferenceView (reused from channels)
   - Sees herself in video grid

6. **Bob joins 2 minutes later:**
   - Clicks "Join Meeting"
   - Goes through prejoin flow (Waiting Room = PreJoin page)
   - Selects camera and microphone
   - System detects he's NOT first participant
   - Requests E2EE key from Alice via Socket.IO
   - Receives encrypted key, decrypts with Signal Protocol
   - System checks: Bob is invited server user → **Auto-admitted**
   - Joins VideoConferenceView immediately
   - Both Alice and Bob see each other in grid

7. **Carol joins 3 minutes later:**
   - Clicks "Join Meeting"
   - Goes through prejoin flow
   - Selects camera and microphone
   - E2EE key exchange completes
   - System checks: Carol is invited server user → **Auto-admitted**
   - Joins VideoConferenceView immediately
   - All three see each other in 3-person grid

8. **Meeting ends:**
   - Alice clicks "End Meeting" (Owner permission)
   - Confirmation dialog: "End meeting for all participants?"
   - Confirms
   - Backend updates meeting status to 'ended'
   - Records duration and participant stats
   - All participants disconnected
   - Socket.IO emits `meeting:ended` event
   - Meeting moves to "Past (8h)" list with duration "1h 32min • 3 participants"

9. **8 hours after meeting:**
   - Cron job runs
   - Deletes meeting from database
   - Meeting no longer visible in UI

---

### Scenario 2: Instant Call from 1:1 Chat

**Actors:** Alice, Bob

**Flow:**

1. **Alice initiates call:**
   - In 1:1 chat with Bob
   - Clicks phone icon (📞) in AppBar
   - Backend checks Bob's presence status
   - Bob is online (heartbeat within 60s)
   - if Bob is offline stop process and snackbar Bob isn't available (send Signal message notification Alice tried to call you)
   - System creates temp channel:
     - `temp_channel_id`: Generated UUID
     - `created_by`: Alice's user ID
     - `channel_type`: '1:1_call'
     - `source_user_id`: Bob's user ID
     - `expires_at`: Now + 4 hours
   - get prejoin page and select devices and shows bob online status
   - if Alice joins the call emit
   - Socket.IO emits `call:incoming` to Bob

2. **Alice sees waiting screen:**
   - Navigates to Call Screen (similar Meeting Screen or Channel Video Screen after preJoin)
   - Shows Bob's profile picture with grey overlay
   - Text: "..."
   - "Waiting for participants to join..."
   - [End Call] button visible
   - Ringtone playing on Alice's device (caller feedback)

3. **Bob receives call notification:**
   - Top bar appears (IncomingCallOverlay)
   - Shows: "📞 [Alice's Avatar] Alice is calling... 1:1 Call"
   - Ringtone loops (`assets/sounds/call_ringtone.mp3`)
   - Two buttons: [🔴 Decline] [🟢 Accept]
   - 30-second countdown timer

4. **Bob accepts call:**
   - Clicks [🟢 Accept]
   - Socket.IO emits `call:accepted` event
   - Bob navigates to VideoConferencePreJoinView
   - Quick device selection
   - E2EE key exchange (same as meetings)
   - if bob Joins after prejoin view - Alice's waiting screen updates:
     - Grey overlay removed from Bob's avatar
     - Green checkmark ✓ appears
     - Text: "Bob joined"
   - Both entered VideoConferenceView
   - 2-person video call starts

5. **During call:**
   - Both can toggle camera/mic
   - Both can share screen
   - Call continues until both leave

6. **Alice leaves first:**
   - Clicks "Leave" button
   - She disconnects
   - Bob remains in call
   - Bob sees "Alice left" notification
   - Bob can continue (temp channel still active)

7. **Bob leaves:**
   - Clicks "Leave"
   - Last participant leaves
   - Backend detects: All participants left
   - Immediately deletes temp channel from database
   - Call duration recorded
   - Socket.IO emits `call:ended` event

**Alternative: Bob declines:**
- Bob clicks [🔴 Decline]
- Socket.IO emits `call:declined` event
- Alice sees snackbar: "Bob declined the call"
- Temp channel deleted immediately
- Alice returns to 1:1 chat

**Alternative: Bob doesn't answer (30s timeout):**
- Overlay auto-dismisses after 30s
- Socket.IO emits `call:declined` event (timeout)
- Alice sees snackbar: "Bob didn't answer"
- Temp channel deleted
- Alice returns to 1:1 chat
- Bob get notification via signal message type missed call

---

### Scenario 3: Group Instant Call from Channel

**Actors:** Alice (Caller), Bob, Carol, Dave (Channel Members)

**Flow:**

1. **Alice initiates group call:**
   - In channel "Engineering Team"
   - Clicks phone icon (📞) in AppBar
   - get prejoin page and select devices and see the online status
   - `channel_type`: 'group_call'
   - `source_channel_id`: Engineering Team ID
   - `expires_at`: Now + 4 hours
   - Bob goes through prejoin, joins call
   - Shows all channel members with online status:
     - ☑ Bob (online) [pre-selected]
     - ☑ Carol (online) [pre-selected]
     - ☐ Dave (offline) [disabled, grayed out]
   - Note: "Only online members will be notified. Video call only."
   - Alice clicks "Start Call" and navigate to the call grid with overlay on participants "Waiting for participants to join..."

2. **System creates temp channel:**
   - Backend checks presence: Bob and Carol online
   - Socket.IO emits `call:incoming` to Bob and Carol
   - Dave receives NO notification (offline)

3. **Alice sees waiting screen:**
   - CallWaitingScreen with 3-person grid
   - Alice (self): Normal avatar
   - Bob: Grey overlay, "..."
   - Carol: Grey overlay, "..."
   - Text: "Waiting for participants to join..."

4. **Bob accepts immediately:**
   - Receives call notification
   - Clicks Accept
   - Bob goes through prejoin, joins call
   - Socket.IO emits `call:accepted`
   - Alice's grid updates:
     - Bob: Grey overlay removed, green ✓
     - Text: "Bob joined"
   - Alice and Bob in 2-person video

5. **Carol declines:**
   - Receives call notification
   - Clicks Decline
   - Socket.IO emits `call:declined`
   - Alice's grid updates:
     - Carol: Avatar removed from grid
   - Alice sees snackbar: "Carol declined the call"

6. **Call continues with Alice and Bob:**
   - 2-person video call
   - Temp channel remains active
   - Dave comes online 10 minutes later
   - Dave sees NO notification (call already in progress)

7. **Call ends:**
   - Alice clicks "End Call"
   - Both participants disconnect
   - Temp channel immediately deleted
   - Call duration: 15 minutes

---

### Scenario 4: External Participant Joins Meeting

**Actors:** Alice (Meeting Owner), Bob (Internal), Charlie (External Guest)

**Flow:**

1. **Alice creates meeting with external access:**
   - Creates meeting "Client Demo"
   - Start time: Today 16:00
   - Enables "Allow External Participants"
   - Backend generates invitation token
   - External join URL: `https://peerwave.app/join/meeting/abc123def456`
   - Alice shares link with Charlie via email

2. **Charlie clicks link at 15:30 (30 min early):**
   - Browser opens landing page (MeetingJoinScreen)
   - Shows:
     - Meeting title: "Client Demo"
     - Start time: "Today at 4:00 PM"
     - Host: "Alice"
   - Form: "Enter your display name"
   - Charlie enters: "Charlie (Acme Corp)"
   - Clicks "Join Meeting"
   - Backend validates:
     - Token valid?  ✅
     - Time window (±1h)? ❌ (too early)
   - Shows countdown: "Meeting starts in 29 minutes"
   - [Join Meeting] button disabled

3. **Charlie waits and refreshes at 15:55:**
   - Countdown now shows: "Meeting starts in 4 minutes"
   - Time window now valid (within 1h before start)
   - [Join Meeting] button enabled
   - Clicks "Join Meeting"

4. **External key generation:**
   - ExternalParticipantService checks SessionStorage
   - No keys found (first time)
   - Generates temporary Signal Protocol keys:
     - Identity key pair
     - Signed pre-key
     - 100 pre-keys
   - Stores in SessionStorage (survives refresh, lost on tab close)
   - POST to `/api/meetings/external/register`:
     ```json
     {
       "invitationToken": "abc123def456",
       "displayName": "Charlie (Acme Corp)",
       "identityKeyPublic": "...",
       "signedPreKey": "...",
       "preKeys": [...]
     }
     ```
   - Backend creates session:
     - `session_id`: Generated UUID
     - `meeting_id`: Meeting ID
     - `expires_at`: Min(meeting end + 24h, now + 24h)
     - Stores keys in database

5. **Charlie goes to prejoin:**
   - ExternalPreJoinView appears
   - Same UI as regular prejoin
   - Device selection (camera/microphone)
   - Camera preview
   - E2EE status: "✅ Encrypted connection"
   - Additional notice:
     - "Joining as Guest"
     - "You will be removed when all participants leave or after 24 hours"
   - Clicks "Join Meeting"

6. **Alice and Bob already in meeting:**
   - Alice created at 16:00, Bob joined at 16:02
   - Both see encrypted video

7. **Charlie joins at 16:05 (external guest - needs admission):**
   - Completes prejoin: device selection + E2EE key exchange
   - Charlie's keys already registered
   - Clicks "Join Meeting"
   - Button shows spinning loader: "Waiting for admission..."
   - Charlie sees: "Waiting for a participant to admit you"
   - **Alice and Bob see admission overlay:**
     ```
     ┌────────────────────────────────────┐
     │ Guest Waiting to Join              │
     │                                    │
     │ Charlie (Acme Corp)                │
     │                                    │
     │ [Decline]        [Admit]          │
     └────────────────────────────────────┘
     ```
   - Alice clicks "Admit"
   - Socket.IO emits `meeting:guest_admitted`
   - Charlie enters VideoConferenceView
   - All three see each other
   - Charlie has "Guest" badge (grey) in participant list
   - Charlie CANNOT see text chat history
   - Charlie CAN use camera, mic, see participants

   **If declined:**
   - Any participant clicks "Decline"
   - Charlie sees: "Your request to join was declined"
   - Join button disabled permanently
   - Charlie must reload page (get new session) to try again

8. **Alice shares screen:**
   - Clicks screen share
   - All participants (including Charlie) see screen
   - Layout switches to horizontal (80% screen, 20% cameras)

9. **Bob leaves at 16:30:**
   - Bob disconnects
   - Alice and Charlie remain
   - Charlie's session still valid (server user Alice present)

10. **Alice leaves at 16:45 (last server user):**
    - Alice disconnects
    - Backend detects: All server users left
    - Socket.IO emits `external:all_server_users_left`
    - Charlie sees warning:
      - "You will be disconnected in 5 seconds"
      - "Meeting ended - all participants have left"
    - Charlie forcibly disconnected
    - External session deleted from database
    - Charlie cannot rejoin (session expired)

**Alternative: Charlie refreshes browser during meeting:**
- Browser refresh at 16:20
- SessionStorage preserved
- ExternalPreJoinView loads
- Checks SessionStorage: Keys found ✅
- Reuses existing keys (no regeneration)
- Rejoins meeting seamlessly
- E2EE continues with same session

**Alternative: Charlie closes tab and reopens:**
- Tab closed at 16:15
- SessionStorage cleared
- Clicks invitation link again at 16:20
- Landing page loads
- Enters display name
- Clicks "Join Meeting"
- ExternalParticipantService checks SessionStorage: Empty
- Generates NEW keys
- Creates NEW session
- POST to `/api/meetings/external/register` (new session_id)
- Joins with fresh E2EE session

---

### Scenario 5: Presence Tracking and Online Status

**Actors:** Alice, Bob, Carol

**Flow:**

1. **Alice logs in:**
   - App starts
   - PresenceService.startHeartbeat() called
   - Sends immediate heartbeat: POST `/api/presence/heartbeat`
   - Backend updates:
     - `user_presence.status = 'online'`
     - `user_presence.last_heartbeat = NOW()`
     - `user_presence.socket_id = <Alice's socket ID>`
   - Socket.IO emits `presence:user_connected` event
   - All users in Alice's conversations/channels receive update

2. **Bob sees Alice come online:**
   - Bob is viewing 1:1 chat list
   - EventBus receives `presence:user_connected` event
   - PresenceService updates cache: `_userPresenceCache['alice'] = online`
   - StreamController emits update
   - UI rebuilds (OnlineStatusIndicator)
   - Alice's avatar now shows green dot (8x8px, #4CAF50)

3. **Every 60 seconds (heartbeat):**
   - PresenceService Timer fires
   - POST `/api/presence/heartbeat` (all online users)
   - Backend updates `last_heartbeat` timestamp
   - Every minute, backend sends bulk update:
     - Socket.IO emits `presence:bulk_update` event
     - Payload: `{ users: [{userId, status, lastSeen}, ...] }`
   - Frontend updates cache in batch
   - UI debounced (no rebuild storm)

4. **Carol opens channel member list:**
   - Navigates to "Engineering Team" members
   - Component calls: `PresenceService.getStatusForChannel(channelId)`
   - Returns cached presence for: Alice, Bob, Dave
   - Renders member list with status indicators:
     - Alice: Green dot (online)
     - Bob: Green dot (online)
     - Dave: Grey dot (offline, last seen 2h ago)

5. **Alice's network drops:**
   - Socket disconnects
   - Backend detects disconnect event
   - Updates `user_presence.status = 'offline'`
   - Updates `user_presence.last_seen = NOW()`
   - Socket.IO emits `presence:user_disconnected` event
   - Bob and Carol see Alice's green dot turn grey immediately

6. **Alice reconnects (30s later):**
   - Socket reconnects
   - PresenceService detects reconnection
   - Sends immediate heartbeat
   - Backend updates status to 'online'
   - Socket.IO emits `presence:user_connected`
   - Bob and Carol see Alice's dot turn green again

7. **Bob closes app:**
   - App disposed
   - PresenceService.stopHeartbeat() called
   - Timer cancelled
   - Socket disconnects gracefully
   - Backend marks Bob as offline
   - Alice and Carol see Bob's status update to grey

---

### Scenario 6: Meeting Role Management

**Actors:** Alice (Owner), Bob (Manager), Carol (Member)

**Flow:**

1. **Alice creates meeting and assigns roles:**
   - Creates "Q1 All Hands" meeting
   - Invites Bob and Carol
   - After creation, opens meeting details
   - Clicks "Manage Roles"
   - Sees participant list with current roles:
     - Alice: Owner (cannot change)
     - Bob: Member (default)
     - Carol: Member (default)
   - Clicks "..." next to Bob → "Assign Role"
   - Dialog shows role dropdown:
     - Owner (disabled, only one owner)
     - Manager ✓
     - Member
   - Selects "Manager", clicks "Assign"
   - POST `/api/meetings/:meetingId/roles`
   - Backend updates `meeting_participants.role_id = 'meeting_manager'`
   - Bob now has Manager permissions

2. **Meeting permissions in action:**

   **Alice (Owner) can:**
   - ✅ Start meeting
   - ✅ Invite participants
   - ✅ Remove participants
   - ✅ Mute participants
   - ✅ End meeting
   - ✅ Assign roles
   - ✅ Update meeting settings

   **Bob (Manager) can:**
   - ✅ Start meeting
   - ✅ Invite participants
   - ❌ Remove participants (owner only)
   - ✅ Mute participants
   - ❌ End meeting (owner only)
   - ❌ Assign roles (owner only)
   - ✅ Update meeting settings

   **Carol (Member) can:**
   - ❌ Start meeting (manager/owner only)
   - ❌ Invite participants
   - ❌ Remove participants
   - ❌ Mute participants
   - ❌ End meeting
   - ❌ Assign roles
   - ❌ Update settings
   - ✅ Share screen
   - ✅ Enable camera
   - ✅ Enable microphone

3. **During meeting - Bob (Manager) mutes Carol:**
   - All three in video call
   - Carol speaking loudly, echo problem
   - Bob right-clicks Carol's video tile
   - Context menu shows: "Mute Participant" (enabled for Bob)
   - Bob clicks "Mute"
   - Backend checks: `meeting_roles.can_mute_participants = TRUE` for Bob ✅
   - Carol's microphone forcibly muted
   - Carol sees notification: "You were muted by Bob"
   - Carol can unmute herself (member permission)

4. **Alice ends meeting:**
   - Clicks "End Meeting" button (only visible to owner)
   - Confirmation: "End meeting for all 3 participants?"
   - Confirms
   - All participants disconnected
   - Meeting status → 'ended'

---

### Scenario 7: Temp Channel Cleanup

**Actors:** System (Background Jobs)

**Flow:**

**Case 1: Normal cleanup (all participants leave)**

1. **11:00 AM:** Alice starts instant call with Bob
   - Temp channel created
   - `expires_at = 11:00 AM + 4h = 3:00 PM`

2. **11:15 AM:** Bob leaves
   - Backend checks: Alice still present
   - Temp channel remains active

3. **11:20 AM:** Alice leaves
   - Backend detects: Last participant left
   - Immediately deletes temp channel:
     ```sql
     DELETE FROM temp_channels WHERE temp_channel_id = '...';
     -- CASCADE deletes temp_channel_participants
     ```
   - Total lifetime: 20 minutes

**Case 2: Fallback cleanup (abandoned channel)**

1. **11:00 AM:** Alice starts call, Bob joins

2. **11:05 AM:** Network issue - both clients crash
   - Sockets disconnect
   - Participants marked as 'left' in database
   - BUT temp channel NOT deleted (cleanup job didn't run yet)

3. **11:15 AM:** Cron job runs (every 5 minutes)
   - Queries:
     ```sql
     SELECT * FROM temp_channels 
     WHERE expires_at < NOW() OR 
           (SELECT COUNT(*) FROM temp_channel_participants 
            WHERE temp_channel_id = temp_channels.temp_channel_id 
            AND status = 'joined') = 0;
     ```
   - Finds abandoned channel
   - Deletes it

4. **Maximum lifetime:** 4 hours (fallback)
   - Even if bug prevents normal cleanup
   - Cron job at 3:05 PM deletes channel

---

### Scenario 8: Live Invitation During Active Meeting

**Actors:** Alice (Owner), Bob, Carol (In Meeting), Dave (To Be Invited), Eve (External Guest)

**Flow:**

1. **Meeting in progress:**
   - Alice, Bob, Carol are in "Sprint Review" meeting
   - Started 15 minutes ago
   - 3-person video call active

2. **Alice realizes Dave should join:**
   - Alice clicks "Invite" button in VideoConferenceView toolbar
   - LiveInviteDialog appears
   - "Server Users" tab selected by default

3. **Alice searches and selects Dave:**
   - Types "Dave" in search bar
   - Dave appears in results (online)
   - Checks Dave's checkbox
   - Clicks "Send Invites"

4. **Backend processes invitation:**
   - POST `/api/meetings/:meetingId/invite-live`
   - Backend checks Alice has `can_invite_participants` permission ✅
   - Updates `meeting_participants` table:
     - Insert: `{ userId: Dave, status: 'invited', invited_at: NOW() }`
   - Socket.IO emits encrypted `meeting:live_invite_sent` to Dave
   - Socket.IO emits to all meeting participants:
     - Alice, Bob, Carol see in "Recently Invited": "Dave - Pending..."

5. **Dave receives notification:**
   - Top bar notification appears (IncomingMeetingInvite overlay)
   - Shows: "🎥 Alice invited you to join 'Sprint Review' (in progress)"
   - Buttons: [Decline] [Join Now]
   - No timeout (persists until action)

6. **Dave clicks "Join Now":**
   - Navigates to MeetingJoinScreen (prejoin)
   - Selects camera and microphone
   - E2EE key exchange (requests key from Alice)
   - System checks: Dave is invited server user → **Auto-admitted**
   - Enters VideoConferenceView
   - Socket.IO emits `meeting:participant_joined`
   - All participants see Dave join
   - Alice's "Recently Invited" updates: "Dave - Joined ✓"

7. **Alice wants to invite external stakeholder:**
   - Clicks "Invite" button again
   - Switches to "External Link" tab
   - Shows: Current link (if exists) OR "No link generated yet"

8. **Alice generates external link:**
   - Clicks "Generate New Link"
   - POST `/api/meetings/:meetingId/generate-link`
   - Backend checks Alice has `can_invite_participants` permission ✅
   - Backend generates new invitation token
   - Stores in database: `{ meetingId, token, createdAt, createdBy: Alice }`
   - Returns URL: `https://peerwave.app/join/meeting/xyz789ghi012`
   - Socket.IO emits `meeting:invite_link_generated` (plain) to all participants
   - Dialog updates with new link

9. **Alice copies and shares link:**
   - Clicks "Copy Link" button
   - Link copied to clipboard
   - Shares via external email/chat
   - Closes dialog

10. **Eve (external) clicks link:**
    - Opens landing page
    - Enters display name: "Eve (Stakeholder)"
    - Meeting is already in progress (valid time window)
    - Clicks "Join Meeting"
    - Goes through prejoin (device + E2EE)
    - Clicks "Join Meeting" → **Spinner appears**
    - Sees: "Waiting for admission..."

11. **Meeting participants see admission request:**
    - Admission overlay appears for Alice, Bob, Carol, Dave
    - Shows: "Guest Waiting to Join: Eve (Stakeholder)"
    - Buttons: [Decline] [Admit]

12. **Bob admits Eve:**
    - Bob clicks "Admit"
    - Socket.IO emits `meeting:guest_admitted`
    - Updates `external_participants.admission_status = 'admitted'`
    - Updates `external_participants.admitted_by = Bob's UUID`
    - Eve enters meeting
    - All 5 participants in video call

**Alternative: Dave declines invitation:**
- Dave clicks "Decline" on notification
- Socket.IO emits update
- Alice's "Recently Invited" updates: "Dave - Declined"
- Meeting continues with 3 participants

**Alternative: Generate new link (invalidate old):**
- Alice generates second external link
- Backend marks old token as invalid: `{ isActive: false }`
- Old link stops working
- New link becomes active
- Security: Prevents old links from being used if compromised

---

### Scenario 9: Live Invitation During Active Call

**Actors:** Alice (Caller), Bob (In Call), Carol (To Be Invited)

**Flow:**

1. **Call in progress:**
   - Alice and Bob in 1:1 instant call
   - Started 5 minutes ago

2. **Alice wants to add Carol:**
   - Clicks "Invite" button in video call toolbar
   - LiveInviteDialog appears (simplified for calls)
   - Only "Server Users" tab (no external links for calls)

3. **Alice selects Carol:**
   - Searches for Carol
   - Carol shows as online
   - Checks Carol's checkbox
   - Clicks "Send Invites"

4. **Backend processes:**
   - POST `/api/calls/temp/:tempChannelId/invite`
   - Checks Alice is call creator or has permission ✅
   - Inserts into `temp_channel_participants`: `{ userId: Carol, status: 'invited' }`
   - Socket.IO emits encrypted `call:live_invite` to Carol

5. **Carol receives call notification:**
   - Same as regular call notification
   - Top bar: "📞 Alice invited you to join a call (in progress)"
   - Buttons: [Decline] [Accept]
   - Ringtone plays
   - 30-second timeout

6. **Carol accepts:**
   - Goes through prejoin
   - E2EE key exchange
   - Joins call
   - Now 3-person call (Alice, Bob, Carol)

7. **Call continues until all leave:**
   - Normal call lifecycle
   - Cleanup when last participant leaves

**Differences from Regular Call:**
- No waiting screen (call already active)
- Invited user sees "call in progress" indicator
- Joins existing temp channel (doesn't create new one)

---

### Scenario 10: Meeting Notification Flow

**Actors:** Alice, Bob

**Flow:**

1. **Alice creates meeting:**
   - Title: "Daily Standup"
   - Start: Tomorrow 10:00 AM
   - Invites Bob
   - Meeting saved

2. **Tomorrow at 9:45 AM (15 min before):**
   - Backend cron job runs every minute
   - Checks:
     ```sql
     SELECT * FROM meetings 
     WHERE start_time BETWEEN NOW() AND NOW() + INTERVAL '15 minutes'
     AND status = 'scheduled';
     ```
   - Finds "Daily Standup"
   - For each participant (Alice, Bob):
     - Checks `meeting_notifications` table:
       ```sql
       SELECT * FROM meeting_notifications 
       WHERE meeting_id = '...' 
       AND user_id = 'alice' 
       AND notification_type = '15_min_before';
       ```
     - Not found → Create notification:
       ```sql
       INSERT INTO meeting_notifications 
       (meeting_id, user_id, notification_type, sent_at)
       VALUES ('...', 'alice', '15_min_before', NOW());
       ```
     - Socket.IO emit:
       ```javascript
       socket.emit('meeting:reminder', {
         meetingId: '...',
         title: 'Daily Standup',
         startTime: '2025-12-10T10:00:00Z',
         minutesBefore: 15
       });
       ```

3. **Alice's client receives event:**
   - MeetingNotificationBar appears at top
   - "🎥 Meeting starting in 14 minutes: Daily Standup"
   - Buttons: [Dismiss] [View Details]
   - Sidebar badge shows pulsing red dot

4. **Alice dismisses notification:**
   - Clicks [Dismiss]
   - Frontend calls:
     ```dart
     await MeetingService.instance.dismissNotification(
       meetingId,
       '15_min_before'
     );
     ```
   - Backend updates:
     ```sql
     UPDATE meeting_notifications 
     SET is_dismissed = TRUE, dismissed_at = NOW()
     WHERE meeting_id = '...' AND user_id = 'alice' 
     AND notification_type = '15_min_before';
     ```
   - Notification bar disappears

5. **At 10:00 AM (start time):**
   - Cron job runs
   - Finds meeting at start time
   - Updates:
     ```sql
     UPDATE meetings SET status = 'in_progress' 
     WHERE meeting_id = '...' AND start_time <= NOW();
     ```
   - For each participant:
     - Checks notification:
       ```sql
       SELECT * FROM meeting_notifications 
       WHERE meeting_id = '...' 
       AND user_id = 'alice' 
       AND notification_type = 'at_start';
       ```
     - Not found → Create and emit:
       ```javascript
       socket.emit('meeting:reminder', {
         meetingId: '...',
         title: 'Daily Standup',
         startTime: '2025-12-10T10:00:00Z',
         minutesBefore: 0 // Indicates start time
       });
       ```

6. **Alice sees start notification:**
   - MeetingNotificationBar reappears (even if dismissed before)
   - "🔴 Meeting started: Daily Standup"
   - Buttons: [Join Now] [View Details]
   - This notification is dismissible
   - Automatically dismisses after 5 minutes if not interacted with

7. **Bob never dismissed 15-min warning:**
   - At 10:00 AM, notification updates in place
   - Text changes from "starting in..." to "Meeting started"
   - [Dismiss] button changes to [Join Now]

---

## 🎯 Summary

All open questions have been answered. The solution provides:

1. **Scheduled Meetings** - Complete lifecycle from creation to cleanup
2. **Instant Calls** - Phone-style calling with waiting rooms
3. **Presence Tracking** - Real-time online/offline status
4. **External Participants** - Secure guest access with E2EE
5. **Role-Based Permissions** - Granular meeting controls
6. **Smart Cleanup** - Immediate + fallback strategies
7. **Rich Notifications** - Multi-stage reminders with dismissal tracking
8. **Seamless Integration** - Reuses existing video infrastructure

---

## 📦 Dependencies

**Backend (Node.js):**
- `node-cron` - Meeting cleanup jobs
- `socket.io` - Real-time events
- Existing: `express`, `sqlite3`, `@signalapp/libsignal-client`

**Frontend (Flutter):**
- `uuid` - Generate IDs
- `intl` - Date/time formatting
- Existing: `flutter_webrtc`, `livekit_client`, `socket_io_client`

---

## 🚀 Next Steps

1. **Review this action plan** and answer the open questions
2. **Prioritize features** - Which features are MVP, which can be deferred?
3. **Assign tasks** - If working in a team, who handles backend vs frontend?
4. **Set milestones** - Create GitHub issues/project board
5. **Begin Phase 1** - Start with database schema and REST API

---

## 📝 Notes

- This plan assumes familiarity with existing PeerWave architecture (Signal Protocol, WebRTC, event bus)
- Some features can be implemented incrementally (e.g., start with meetings, add instant calls later)
- External participant support is the most complex feature - can be Phase 2 if needed
- Performance testing will be critical for presence tracking with 100+ users

---

**Document Version:** 2.0 (Requirements Confirmed)  
**Created:** 2025-12-08  
**Last Updated:** 2025-12-09  
**Status:** ✅ Ready for Implementation

---

## 📊 Quick Reference

**Key Decisions:**
- ✅ Meetings: Separate entities, video-only, any user can create
- ✅ Instant Calls: Phone-style ringtone, only online users notified, cleanup when all leave (4h max)
- ✅ Presence: 1-minute heartbeat, online/offline only
- ✅ External: SessionStorage (reuse keys on reconnect), invitation valid ±1h of start time, no email required, video-only
- ✅ UI Updates: Batched with debouncing (300-500ms)

**Database Tables:** 8 new tables (meetings, meeting_participants, meeting_roles, temp_channels, temp_channel_participants, user_presence, external_participants, meeting_notifications)

**REST API:** 25+ new endpoints

**Socket.IO Events:** 20+ new events

**New Services:** 4 (MeetingService, InstantCallService, PresenceService, ExternalParticipantService)

**New Screens:** 3 (MeetingsScreen, MeetingJoinScreen, ExternalPreJoinView)

**New Widgets:** 6 (MeetingDialog, MeetingNotificationBar, IncomingCallOverlay, CallWaitingScreen, OnlineStatusIndicator, InstantCallDialog)
