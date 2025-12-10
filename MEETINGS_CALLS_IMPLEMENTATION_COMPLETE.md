# Meetings & Calls System - Implementation Complete ✅

**Date:** December 9, 2025  
**Status:** Phase 1 & 2 Complete - Ready for Integration Testing

---

## 📋 Overview

Full-stack meetings and video conferencing system with:
- ✅ Scheduled meetings with participant management
- ✅ Instant 1-on-1 calls with ringtone notifications
- ✅ Guest admission system for external participants
- ✅ Online presence tracking with heartbeat
- ✅ Real-time Socket.IO notifications
- ✅ End-to-end encryption key exchange for guests

---

## 🏗️ Architecture

### Backend (Node.js/Express)
- **SQLite Database**: 6 tables with writeQueue serialization
- **REST APIs**: 5 route groups on port 3000
- **Socket.IO**: Real-time event broadcasting
- **LiveKit Integration**: Video conferencing backend

### Frontend (Flutter)
- **Services**: 4 singleton services with HTTP + Socket.IO + Streams
- **UI Components**: 5 screens/widgets with Material Design
- **State Management**: StreamControllers for reactive updates
- **Post-Login Init**: Automatic service initialization

---

## 📂 Files Created

### Backend (Previously Complete)
```
server/routes/meetings.js          - Meeting CRUD operations
server/routes/calls.js              - Instant call creation
server/routes/presence.js           - Heartbeat and online status
server/routes/external.js           - Guest admission flow
server/routes/livekit.js            - LiveKit token generation

server/services/meetingService.js   - Meeting business logic
server/services/callService.js      - Call notification logic
server/services/presenceService.js  - Heartbeat cleanup (5min)
server/services/externalService.js  - Guest session management

server/socket-events/meeting-events.js  - Socket.IO handlers
server/socket-events/call-events.js
server/socket-events/presence-events.js
server/socket-events/external-events.js
```

### Flutter Services (Phase 2)
```
client/lib/services/meeting_service.dart              (299 lines)
client/lib/services/call_service.dart                 (205 lines)
client/lib/services/presence_service.dart             (231 lines)
client/lib/services/external_participant_service.dart (184 lines)
```

### Flutter UI (Phase 3)
```
client/lib/screens/meetings_screen.dart              (469 lines)
client/lib/widgets/meeting_dialog.dart               (486 lines)
client/lib/widgets/incoming_call_overlay.dart        (335 lines)
client/lib/views/external_prejoin_view.dart          (325 lines)
client/lib/widgets/admission_overlay.dart            (348 lines)
```

### Flutter Models
```
client/lib/models/meeting.dart                (179 lines)
client/lib/models/meeting_participant.dart    (104 lines)
client/lib/models/user_presence.dart          (73 lines)
client/lib/models/external_session.dart       (122 lines)
```

### Integration
```
client/lib/services/post_login_init_service.dart  - Updated (Phase 4.5 added)
client/lib/main.dart                              - Routes registered
client/lib/services/sound_service.dart            - Ringtone support added
```

---

## 🔄 Service Architecture

### HTTP vs Socket.IO Pattern
**Design Decision:** Flutter's `socket_io_client` doesn't support callbacks in event handlers.

**Solution:**
- **HTTP Requests**: All operations requiring responses (CRUD, queries)
- **Socket.IO Events**: One-way notifications only (broadcasts)
- **Streams**: UI-reactive updates via StreamControllers

### Service Initialization Flow
```dart
PostLoginInitService.initialize()
├─ Phase 1: Network (Socket.IO connect)
├─ Phase 2: Core (Database, Signal)
├─ Phase 3: Data (Profiles, Messages, Roles)
├─ Phase 4: Communication (Listeners, Notifications)
├─ Phase 4.5: Meetings & Calls ← NEW
│   ├─ MeetingService.initializeListeners()
│   ├─ CallService.initializeListeners()
│   ├─ PresenceService.initialize() → Starts 60s heartbeat
│   └─ ExternalParticipantService.initializeListeners()
├─ Phase 5: P2P File Transfer
└─ Phase 6: Video Services
```

On logout: `PresenceService.stopHeartbeat()` called in `PostLoginInitService.reset()`

---

## 📡 Socket.IO Events

### Meeting Events
```javascript
// Emitted by server
'meeting:created'               → MeetingService.onMeetingCreated
'meeting:updated'               → MeetingService.onMeetingUpdated
'meeting:started'               → MeetingService.onMeetingStarted
'meeting:cancelled'             → MeetingService.onMeetingCancelled
'meeting:participant_joined'    → MeetingService.onParticipantJoined
'meeting:participant_left'      → MeetingService.onParticipantLeft
'meeting:first_participant_joined' → (Reserved for future use)

// Emitted by client
'meeting:leave'                 → Leave meeting notification
```

### Call Events
```javascript
// Emitted by server
'call:incoming'                 → CallService.onIncomingCall → Shows IncomingCallOverlay
'call:ringing'                  → CallService.onCallRinging
'call:accepted'                 → CallService.onCallAccepted
'call:declined'                 → CallService.onCallDeclined
'call:ended'                    → CallService.onCallEnded

// Emitted by client
'call:notify'                   → Trigger ringtone on recipient devices
'call:accept'                   → Accept call notification
'call:decline'                  → Decline call notification
'call:end'                      → End call notification
```

### Presence Events
```javascript
// Emitted by server
'presence:update'               → PresenceService.onPresenceUpdate
'presence:user_connected'       → PresenceService.onUserConnected
'presence:user_disconnected'    → PresenceService.onUserDisconnected

// Emitted by client
'presence:heartbeat'            → Every 60 seconds (Timer.periodic)
```

### External Participant Events
```javascript
// Emitted by server
'meeting:guest_waiting'         → ExternalParticipantService.onGuestWaiting
'meeting:guest_admitted'        → ExternalParticipantService.onGuestAdmitted
'meeting:guest_declined'        → ExternalParticipantService.onGuestDeclined
```

---

## 🎨 UI Components

### 1. MeetingsScreen (`/app/meetings`)
**Purpose:** Main meetings management interface

**Features:**
- Tab filters: All, Upcoming, Past, My Meetings
- Meeting cards with status chips
- Pull-to-refresh
- Real-time updates via streams
- FAB opens MeetingDialog for creation
- Smart date formatting (Today/Tomorrow/Date)

**Code Example:**
```dart
StreamBuilder(
  stream: meetingService.onMeetingCreated,
  builder: (context, snapshot) {
    if (snapshot.hasData) {
      _loadMeetings(); // Refresh list
    }
  },
)
```

### 2. MeetingDialog
**Purpose:** Create/edit meeting modal

**Features:**
- Title, description, max participants
- Date/time pickers (start & end)
- Settings: voice only, mute on join, allow external
- Validation: end after start, title required
- Creates meeting via `MeetingService.createMeeting()`

**Code Example:**
```dart
showDialog(
  context: context,
  builder: (context) => MeetingDialog(
    meeting: existingMeeting, // null for creation
  ),
);
```

### 3. IncomingCallOverlay
**Purpose:** Full-width notification bar for incoming calls

**Features:**
- Slide-in animation from top
- Pulsing icon (video/phone)
- Accept (green), Decline (red), Dismiss (X)
- Auto-dismiss after 60 seconds
- Stops ringtone on any action

**Code Example:**
```dart
// In post-login init or service listener:
callService.onIncomingCall.listen((callData) {
  IncomingCallOverlayManager.show(
    context: navigatorKey.currentContext!,
    callData: callData,
    onAccept: () => Navigator.push(...), // Navigate to video
    onDecline: () => callService.declineCall(callData['meeting_id']),
  );
});
```

### 4. ExternalPreJoinView (`/join/:token`)
**Purpose:** Guest name entry and waiting room

**Features:**
- Display name entry with validation (≥2 chars)
- Waiting room with animated hourglass
- Real-time admission status (Socket.IO + 3s polling)
- Auto-navigate on admitted/declined

**Route:**
```
https://yourserver.com/join/abc123token456
```

### 5. AdmissionOverlay
**Purpose:** Host admission control for waiting guests

**Features:**
- Expandable overlay (200px → 320px)
- Badge counter with guest count
- Admit/Decline buttons per guest
- Wait time display (just now/Xm ago)
- Real-time updates via streams

**Usage:**
```dart
Stack(
  children: [
    // Your video conference UI
    AdmissionOverlay(meetingId: currentMeetingId),
  ],
)
```

---

## 🔐 Security

### HMAC Session Authentication
- All API requests include session authentication headers
- `ApiService` automatically adds credentials
- `SocketService` includes auth on connect

### E2EE Key Exchange (External Guests)
```dart
await externalService.updateE2EEKeys(
  sessionId: session.sessionId,
  identityKey: signalProtocol.identityKey,
  signedPreKey: signalProtocol.signedPreKey,
  signature: signalProtocol.signature,
);
```

### Presence Privacy
- Only online/offline status (no location/activity)
- 90-second offline threshold
- Heartbeat stops on logout

---

## 🚀 Usage Examples

### Create Scheduled Meeting
```dart
final meeting = await MeetingService().createMeeting(
  title: 'Team Standup',
  description: 'Daily sync',
  scheduledStart: DateTime.now().add(Duration(hours: 1)),
  scheduledEnd: DateTime.now().add(Duration(hours: 2)),
  maxParticipants: 10,
  isVoiceOnly: false,
  muteOnJoin: true,
  allowExternal: true,
);
```

### Create Instant Call
```dart
final call = await CallService().createCall(
  recipientUserIds: ['user-uuid-123'],
  isVoiceOnly: false,
);

// Notify recipients (triggers ringtone)
await CallService().notifyRecipients(
  meetingId: call.id,
  recipientUserIds: ['user-uuid-123'],
);
```

### Check User Online Status
```dart
// From cache (synchronous)
final isOnline = PresenceService().getCachedOnlineStatus('user-uuid-123');

// From server (async with 2min cache)
final presence = await PresenceService().getUserPresence('user-uuid-123');
print('Last seen: ${presence.lastSeenDisplay}');
```

### Generate Invitation Link
```dart
final link = await MeetingService().createInvitationLink(
  meetingId: meeting.id,
  maxUses: 10,
  expiresIn: 3600, // 1 hour
);

// Share link: https://yourserver.com/join/${link.token}
```

### Admit Guest
```dart
// Listen for waiting guests
externalService.onGuestWaiting.listen((session) {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${session.displayName} wants to join'),
      actions: [
        TextButton(
          onPressed: () => externalService.declineGuest(session.sessionId),
          child: Text('Decline'),
        ),
        ElevatedButton(
          onPressed: () => externalService.admitGuest(session.sessionId),
          child: Text('Admit'),
        ),
      ],
    ),
  );
});
```

---

## 🧪 Testing Flows

### 1. Scheduled Meeting Flow
```
1. User logs in → PresenceService starts heartbeat
2. Navigate to /app/meetings → MeetingsScreen loads
3. Tap FAB → MeetingDialog opens
4. Fill form: title, date/time, settings
5. Tap "Create" → HTTP POST to /api/meetings
6. Server broadcasts 'meeting:created' → All users see update
7. Tap meeting card → Navigate to meeting details (TODO)
8. Tap "Join" → Navigate to video conference
```

### 2. Instant Call Flow
```
1. User A navigates to /app/people
2. Tap call icon next to User B
3. CallService.createCall() → HTTP POST to /api/calls
4. CallService.notifyRecipients() → Socket.IO 'call:notify'
5. User B receives 'call:incoming' → IncomingCallOverlay shows
6. SoundService plays ringtone in loop
7. User B taps "Accept" → Socket.IO 'call:accept'
8. Both users navigate to video conference
9. Ringtone stops
```

### 3. Guest Admission Flow
```
1. Host creates meeting with allowExternal=true
2. Host generates invitation link
3. Guest opens link in browser → /join/:token
4. ExternalPreJoinView loads
5. Guest enters display name → HTTP POST to /api/external/join
6. Server creates session with status 'waiting'
7. Server broadcasts 'meeting:guest_waiting'
8. Host sees AdmissionOverlay with guest info
9. Host taps "Admit" → HTTP POST to /api/external/admit
10. Server broadcasts 'meeting:guest_admitted'
11. Guest's ExternalPreJoinView receives event
12. Guest auto-navigates to video conference
```

### 4. Presence Tracking
```
1. User logs in → PresenceService.initialize() starts Timer
2. Every 60s → Socket.IO 'presence:heartbeat' emitted
3. Server updates user_presence.last_seen_at
4. Other users check status:
   - presenceService.getCachedOnlineStatus('uuid') → true/false
   - If (now - last_seen_at) < 90s → online
5. User logs out → PostLoginInitService.reset() stops heartbeat
6. After 90s → Other users see offline status
```

---

## 🐛 Known Issues & Resolutions

### Issue: Socket.IO Callback Not Supported
**Problem:** Flutter's `socket_io_client` doesn't support callbacks in `.on()` handlers

**Solution:** Use HTTP for operations, Socket.IO for notifications only

**Before:**
```dart
socket.emit('meeting:create', data, (response) {
  // ❌ Callback never fires in Flutter
});
```

**After:**
```dart
// HTTP for operation
final meeting = await ApiService.post('/api/meetings', data: data);

// Socket.IO for notification (separate)
socket.on('meeting:created', (data) {
  _meetingCreatedController.add(Meeting.fromJson(data));
});
```

### Issue: Null DateTime Fields
**Problem:** `Meeting.scheduledStart` and `scheduledEnd` are nullable for instant calls

**Solution:** Add null checks before formatting
```dart
if (meeting.scheduledStart == null) {
  return 'Instant Call';
}
return DateFormat('MMM d, y • h:mm a').format(meeting.scheduledStart!);
```

### Issue: Static vs Instance Methods
**Problem:** Services using instance methods when `ApiService` has static methods

**Solution:** Use static methods directly
```dart
// ❌ Before
final _apiService = ApiService();
await _apiService.get('/api/meetings');

// ✅ After
await ApiService.get('/api/meetings');
```

---

## 📊 Database Schema

### meetings
```sql
CREATE TABLE meetings (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT,
  host_user_id TEXT NOT NULL,
  scheduled_start TEXT,      -- ISO 8601 or NULL for instant
  scheduled_end TEXT,
  max_participants INTEGER,
  is_voice_only INTEGER DEFAULT 0,
  mute_on_join INTEGER DEFAULT 0,
  allow_external INTEGER DEFAULT 0,
  status TEXT DEFAULT 'scheduled',  -- scheduled, in_progress, ended, cancelled
  created_at TEXT NOT NULL
);
```

### meeting_participants
```sql
CREATE TABLE meeting_participants (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  meeting_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  role TEXT DEFAULT 'participant',  -- host, moderator, participant
  status TEXT DEFAULT 'invited',    -- invited, joined, left
  joined_at TEXT,
  left_at TEXT,
  UNIQUE(meeting_id, user_id)
);
```

### user_presence
```sql
CREATE TABLE user_presence (
  user_id TEXT PRIMARY KEY,
  status TEXT DEFAULT 'offline',  -- online, offline, away
  last_seen_at TEXT NOT NULL
);
```

### external_sessions
```sql
CREATE TABLE external_sessions (
  session_id TEXT PRIMARY KEY,
  meeting_id TEXT NOT NULL,
  display_name TEXT NOT NULL,
  admission_status TEXT DEFAULT 'waiting',  -- waiting, admitted, declined
  identity_key TEXT,         -- E2EE Signal Protocol
  signed_pre_key TEXT,
  signature TEXT,
  expires_at TEXT NOT NULL,  -- 24 hours from creation
  created_at TEXT NOT NULL
);
```

### calls
```sql
CREATE TABLE calls (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  meeting_id TEXT NOT NULL UNIQUE,  -- References meetings.id
  caller_user_id TEXT NOT NULL,
  is_instant_call INTEGER DEFAULT 1,
  created_at TEXT NOT NULL
);
```

### meeting_links
```sql
CREATE TABLE meeting_links (
  token TEXT PRIMARY KEY,
  meeting_id TEXT NOT NULL,
  created_by TEXT NOT NULL,
  max_uses INTEGER,
  uses INTEGER DEFAULT 0,
  expires_at TEXT,
  created_at TEXT NOT NULL
);
```

---

## 🔗 API Endpoints

### Meetings
```
POST   /api/meetings              - Create meeting
GET    /api/meetings/:id          - Get meeting details
PUT    /api/meetings/:id          - Update meeting
DELETE /api/meetings/:id          - Cancel meeting
GET    /api/meetings              - List all meetings
GET    /api/meetings/upcoming     - List upcoming meetings
GET    /api/meetings/past         - List past meetings
GET    /api/meetings/my           - List user's meetings
GET    /api/meetings/:id/participants - List participants
POST   /api/meetings/:id/links    - Create invitation link
GET    /api/meetings/:id/links    - List invitation links
```

### Calls
```
POST   /api/calls                 - Create instant call
GET    /api/calls/active          - Get user's active calls
```

### Presence
```
GET    /api/presence/:userId      - Get user presence
POST   /api/presence/bulk         - Get bulk presence (array of userIds)
```

### External Participants
```
POST   /api/external/join         - Guest join meeting (unauthenticated)
PUT    /api/external/:sessionId/keys - Update E2EE keys
GET    /api/external/:sessionId/status - Get session status
POST   /api/external/:sessionId/admit - Admit guest (authenticated)
POST   /api/external/:sessionId/decline - Decline guest
GET    /api/external/meetings/:meetingId/waiting - List waiting guests
DELETE /api/external/:sessionId   - Revoke session
```

### LiveKit
```
POST   /api/livekit/token         - Generate LiveKit access token
```

---

## 📱 Navigation Structure

```
/app/meetings           → MeetingsScreen (authenticated)
/join/:token            → ExternalPreJoinView (unauthenticated guest)
/app/video/:meetingId   → VideoConferenceView (TODO - integrate with existing)
```

---

## ✅ Completion Checklist

### Phase 1: Backend ✅
- [x] 6 database tables with migrations
- [x] 5 REST API route groups
- [x] 4 service modules
- [x] 4 Socket.IO event handlers
- [x] SQLite writeQueue serialization
- [x] HMAC session authentication
- [x] LiveKit token generation

### Phase 2: Flutter Services ✅
- [x] MeetingService (299 lines)
- [x] CallService (205 lines)
- [x] PresenceService (231 lines)
- [x] ExternalParticipantService (184 lines)
- [x] 4 model classes
- [x] HTTP + Socket.IO + Streams pattern
- [x] Error handling and logging

### Phase 3: Flutter UI ✅
- [x] MeetingsScreen (469 lines)
- [x] MeetingDialog (486 lines)
- [x] IncomingCallOverlay (335 lines)
- [x] ExternalPreJoinView (325 lines)
- [x] AdmissionOverlay (348 lines)
- [x] Real-time stream listeners
- [x] Material Design with animations

### Phase 4: Integration ✅
- [x] Service initialization in PostLoginInitService
- [x] Heartbeat stop on logout
- [x] Route registration in GoRouter
- [x] Deep linking support (/join/:token)
- [x] SoundService ringtone support

### Phase 5: Testing ⏳
- [ ] Create scheduled meeting flow
- [ ] Instant call with ringtone flow
- [ ] Guest admission end-to-end
- [ ] Presence heartbeat verification
- [ ] Socket.IO event delivery
- [ ] Video conference navigation (requires existing video UI integration)

---

## 🚧 Remaining Tasks

### 1. Video Conference Integration
**Status:** Backend ready, Flutter UI exists, needs connection

**Required:**
- [ ] Connect `MeetingService.joinMeeting()` to existing video conference view
- [ ] Pass `meetingId` to video view
- [ ] Handle LiveKit token generation via `/api/livekit/token`
- [ ] Show `AdmissionOverlay` during video conference for hosts

**Existing Video UI:**
```
client/lib/services/video_conference_service.dart
client/lib/widgets/call_overlay.dart
client/lib/widgets/call_top_bar.dart
```

### 2. Meeting Details View
**Status:** Not implemented

**Features Needed:**
- Meeting info display (title, description, time, participants)
- Participant list with roles
- "Join Meeting" button
- "Edit Meeting" button (host only)
- "Cancel Meeting" button (host only)
- Generate invitation link (host only)
- Show waiting guests count (with AdmissionOverlay)

**Suggested Route:** `/app/meetings/:id`

### 3. Notifications Integration
**Status:** Socket.IO events work, system notifications pending

**Required:**
- [ ] Desktop notifications for incoming calls
- [ ] Desktop notifications for guest waiting
- [ ] Desktop notifications for meeting starting soon
- [ ] Badge count on meetings nav item

**Existing Service:**
```
client/lib/services/notification_service.dart
client/lib/services/notification_listener_service.dart
```

### 4. Settings UI
**Status:** Not implemented

**Features Needed:**
- Default ringtone selection
- Default microphone/camera for calls
- Auto-answer for trusted contacts
- Meeting notification preferences

**Suggested Route:** `/app/settings/meetings`

### 5. Search & Filters
**Status:** Basic tab filters implemented

**Enhancements:**
- Search meetings by title/description
- Filter by host/participant
- Filter by date range
- Sort by date/participants

---

## 📚 Code Patterns

### Creating a Service
```dart
class MyService {
  static final MyService _instance = MyService._internal();
  factory MyService() => _instance;
  MyService._internal();

  final _socketService = SocketService();
  final _controller = StreamController<MyData>.broadcast();
  
  Stream<MyData> get onMyEvent => _controller.stream;

  void initializeListeners() {
    _socketService.registerListener('my:event', _handleMyEvent);
  }

  void _handleMyEvent(dynamic data) {
    final myData = MyData.fromJson(data);
    _controller.add(myData);
  }

  Future<MyData> doSomething() async {
    return await ApiService.post('/api/my-endpoint', data: {...});
  }

  void dispose() {
    _controller.close();
  }
}
```

### Using a Service in UI
```dart
class MyWidget extends StatefulWidget {
  @override
  State<MyWidget> createState() => _MyWidgetState();
}

class _MyWidgetState extends State<MyWidget> {
  final _myService = MyService();
  StreamSubscription? _subscription;

  @override
  void initState() {
    super.initState();
    _myService.initializeListeners();
    _subscription = _myService.onMyEvent.listen(_handleEvent);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _handleEvent(MyData data) {
    if (mounted) {
      setState(() {
        // Update UI
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MyData>(
      stream: _myService.onMyEvent,
      builder: (context, snapshot) {
        // Build UI based on stream data
      },
    );
  }
}
```

---

## 🎯 Next Steps

1. **Test End-to-End Flows**
   - Run Flutter app and Node.js server
   - Create meeting → Verify in database
   - Instant call → Check ringtone playback
   - Guest admission → Test full flow

2. **Connect to Video Conference**
   - Identify existing video conference entry point
   - Pass `meetingId` to video UI
   - Test LiveKit token generation
   - Integrate AdmissionOverlay in video view

3. **Add Meeting Details View**
   - Create `/app/meetings/:id` route
   - Display meeting info and participants
   - Add "Join" button navigation

4. **System Notifications**
   - Desktop notifications for incoming calls
   - Badge counts on navigation items
   - Sound + notification coordination

5. **Polish & UX**
   - Loading states
   - Error messages
   - Empty states
   - Responsive design for mobile

---

## 📞 Support & Documentation

**Related Documents:**
- `MEETINGS_AND_CALLS_ACTION_PLAN.md` - Original planning
- `MEETINGS_BACKEND_IMPLEMENTATION_COMPLETE.md` - Backend details
- `SOCKET_IO_EVENTS_REFERENCE.md` - Socket.IO event catalog

**Key Files to Review:**
- Backend: `server/routes/meetings.js`, `server/services/meetingService.js`
- Services: `client/lib/services/meeting_service.dart`
- UI: `client/lib/screens/meetings_screen.dart`
- Integration: `client/lib/services/post_login_init_service.dart`

**Testing Commands:**
```bash
# Start backend
cd server
npm start

# Start Flutter app
cd client
flutter run -d windows  # or chrome
```

---

**Implementation Status:** ✅ **COMPLETE**  
**Ready for:** Integration testing and video conference connection

