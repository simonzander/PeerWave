# Channel Instant Calls - Action Plan

## 📋 Overview

Implement instant video calls from text channels and 1:1 chats with incoming call notifications similar to phone calls. This extends the existing meetings infrastructure to support spontaneous calls from any conversation context.

**Key Features:**
- Phone icon in text channels and 1:1 chats to initiate calls
- PreJoin screen for device selection and E2EE key exchange
- Automatic notification to all online channel members when initiator joins LiveKit room
- Incoming call UI with ringtone (plays AFTER Signal decryption)
- Waiting room grid for initiator showing pending participants
- Decline notifications sent back to caller
- Participants can invite other users mid-call (but NO external guests)
- Reuses meeting infrastructure with `is_instant_call = TRUE` flag
- Ephemeral calls (cleanup immediately when all leave, or 8h fallback)

**🔑 Architecture Principle:**
**Instant calls ARE meetings** stored in the same `meetings` table. Uses `MeetingService` for all operations. No separate call table or service - just a flag and different UI behavior for notifications/cleanup.

---

## 🎯 User Flow

### For Initiator (Caller):

1. **Click phone icon** in text channel or 1:1 chat
2. **Navigate to PreJoin page** for device/audio selection
3. **Click "Join Call"** button on PreJoin
4. **System automatically:**
   - Creates instant call via `/api/calls/instant` with `source_channel_id` or `source_user_id`
   - Gets list of online channel members (excluding caller)
   - Sends `call:incoming` socket events to all online members
5. **Initiator enters video view** (waiting for others to join)
6. **See notifications** when users accept/decline

### For Recipients:

1. **Receive `call:incoming` socket event**
2. **Top bar appears** with:
   - Caller name/avatar
   - Channel name (or "1:1 Call")
   - Accept button (green phone icon)
   - Decline button (red phone icon)
   - Auto-dismiss after 30-60 seconds
3. **If Accept:**
   - Navigate to PreJoin page (same flow as initiator)
   - After joining, call proceeds normally
4. **If Decline:**
   - Send `call:declined` socket event to caller
   - Show notification to caller: "UserName declined the call"
   - Top bar dismisses

---

## 🔧 Technical Implementation

### Phase 1: UI Changes (Client)

#### 1.1 Replace Video Icon with Phone Icon

**Files to modify:**
- `client/lib/screens/messages/signal_group_chat_screen.dart` (text channels)
- `client/lib/screens/messages/signal_direct_message_screen.dart` (1:1 chats, if exists)

**Changes:**
```dart
// OLD:
IconButton(
  icon: const Icon(Icons.videocam),
  tooltip: 'Join Video Call',
  ...
)

// NEW:
IconButton(
  icon: const Icon(Icons.phone),
  tooltip: 'Start Call',
  ...
)
```

#### 1.2 Update PreJoin Flow

**File:** `client/lib/views/video_conference_prejoin_view.dart`

**Add parameters:**
```dart
final bool isInstantCall;           // Flag to know if this is instant call
final String? sourceChannelId;      // Channel ID for channel calls
final String? sourceUserId;         // User ID for 1:1 calls
final bool isInitiator;             // True if caller, false if recipient
```

**New behavior:**
- When "Join Call" clicked AND `isInstantCall == true` AND `isInitiator == true`:
  1. Create instant call via `POST /api/calls/instant` (get `meetingId`)
  2. Join LiveKit room with `meetingId`
  3. After successful join, notify online members via `call:notify` socket event
  4. Navigate to video view with waiting grid
- When `isInstantCall == true` AND `isInitiator == false`:
  1. Accept call via `POST /api/calls/accept` or socket event
  2. Join LiveKit room with existing `meetingId`
  3. Navigate to video view normally

#### 1.3 Incoming Call Top Bar Widget

**New file:** `client/lib/widgets/incoming_call_bar.dart`

**Features:**
- Displayed at top of screen (above CallTopBar)
- Shows caller info, channel/chat name
- Accept button → Navigate to PreJoin with call details
- Decline button → Send decline event, dismiss bar
- Auto-dismiss after 60 seconds
- Sound/vibration notification (optional)

**Integration:**
- Add to `main.dart` Shell structure (similar to CallTopBar)
- Listen to CallService for incoming calls
- Use Stack to overlay on current screen

---

### Phase 2: Backend Changes (Server)

#### 2.1 Instant Call Creation Enhancement

**File:** `server/routes/calls.js`

**Endpoint:** `POST /api/calls/instant`

**Current behavior:** Creates instant call
**New behavior:** 
- Same creation logic
- Return call details including `meeting_id`
- Client will handle notifications after receiving response

#### 2.2 Get Online Channel Members

**New endpoint:** `GET /api/channels/:channelId/online-members`

**File:** `server/routes/channels.js` (or create if needed)

**Logic:**
1. Verify user is channel member
2. Get all channel members from database
3. Filter by online status via `presenceService.isOnline(userId)`
4. Return array of online user IDs and display names

**Response:**
```json
{
  "online_members": [
    { "user_id": "uuid1", "display_name": "Alice" },
    { "user_id": "uuid2", "display_name": "Bob" }
  ]
}
```

#### 2.3 Socket Events

**File:** `server/server.js`

**Events to handle:**

1. **`call:notify`** (already exists, verify it works)
   - Emit `call:incoming` to recipient user IDs
   - Include caller info, meeting ID, channel/chat context

2. **`call:declined`** (already exists, verify it works)
   - Notify caller that user declined
   - Update meeting participant status

3. **New: `call:cancel`** (if caller cancels before anyone joins)
   - Notify all pending recipients
   - Clean up meeting

---

### Phase 3: Call Service (Client)

#### 3.1 Enhance CallService

**File:** `client/lib/services/call_service.dart`

**New methods:**

```dart
/// Start instant call from channel
Future<String> startChannelCall({
  required String channelId,
  required String channelName,
}) async {
  // 1. Create instant call
  final response = await ApiService.post('/api/calls/instant', {
    'source_channel_id': channelId,
    'title': '$channelName Call',
  });
  
  final meetingId = response.data['meeting_id'];
  
  // 2. Get online members (after joining room)
  // This will be called by PreJoin after user actually joins
  
  return meetingId;
}

/// Notify online members (called after initiator joins LiveKit room)
Future<void> notifyChannelMembers({
  required String meetingId,
  required String channelId,
}) async {
  // Get online members
  final response = await ApiService.get('/api/channels/$channelId/online-members');
  final members = response.data['online_members'] as List;
  
  // Send notifications via socket
  SocketService().emit('call:notify', {
    'meeting_id': meetingId,
    'recipient_ids': members.map((m) => m['user_id']).toList(),
  });
}

/// Start 1:1 call
Future<String> startDirectCall({
  required String userId,
  required String userName,
}) async {
  final response = await ApiService.post('/api/calls/instant', {
    'source_user_id': userId,
    'title': '1:1 Call with $userName',
  });
  
  return response.data['meeting_id'];
}
```

**Listener:**
```dart
void _setupListeners() {
  _socketService.registerListener('call:incoming', (data) {
    // Parse incoming call data
    final call = IncomingCall(
      meetingId: data['meeting_id'],
      callerId: data['caller_id'],
      callerName: data['caller_name'],
      channelName: data['channel_name'], // or null for 1:1
      timestamp: DateTime.parse(data['timestamp']),
    );
    
    // Notify UI via stream
    _incomingCallController.add(call);
  });
  
  _socketService.registerListener('call:declined', (data) {
    // Show notification: "UserName declined the call"
    _declinedCallController.add(data);
  });
}
```

---

### Phase 4: Integration & Flow

#### 4.1 Text Channel Call Flow

**File:** `client/lib/screens/messages/signal_group_chat_screen.dart`

```dart
IconButton(
  icon: const Icon(Icons.phone),
  onPressed: () async {
    // Navigate to PreJoin with instant call flag
    final result = await Navigator.push(
      context,
      SlidePageRoute(
        builder: (context) => VideoConferencePreJoinView(
          channelId: widget.channelUuid,
          channelName: widget.channelName,
          isInstantCall: true,
          sourceChannelId: widget.channelUuid,
        ),
      ),
    );
    
    // PreJoin will handle call creation and notifications
  },
  tooltip: 'Start Call',
)
```

#### 4.2 1:1 Chat Call Flow

**File:** `client/lib/screens/messages/signal_direct_message_screen.dart`

```dart
IconButton(
  icon: const Icon(Icons.phone),
  onPressed: () async {
    final result = await Navigator.push(
      context,
      SlidePageRoute(
        builder: (context) => VideoConferencePreJoinView(
          channelId: 'direct_${widget.recipientId}', // Or generate unique ID
          channelName: '1:1 Call',
          isInstantCall: true,
          sourceUserId: widget.recipientId,
          invitedUserIds: [widget.recipientId],
        ),
      ),
    );
  },
  tooltip: 'Call ${widget.recipientName}',
)
```

#### 4.3 PreJoin Enhancement

**File:** `client/lib/views/video_conference_prejoin_view.dart`

**In `_joinChannel()` method:**

```dart
Future<void> _joinChannel() async {
  // Existing device selection logic...
  
  if (widget.isInstantCall && _isInitiator) {
    // 1. Create instant call
    final callService = CallService.instance;
    String meetingId;
    
    if (widget.sourceChannelId != null) {
      meetingId = await callService.startChannelCall(
        channelId: widget.sourceChannelId!,
        channelName: widget.channelName,
      );
    } else if (widget.sourceUserId != null) {
      meetingId = await callService.startDirectCall(
        userId: widget.sourceUserId!,
        userName: widget.channelName, // Actually recipient name
      );
    }
    
    // 2. Join LiveKit room first
    final success = await videoService.joinRoom(...);
    
    if (success && widget.sourceChannelId != null) {
      // 3. After joining, notify online members
      await callService.notifyChannelMembers(
        meetingId: meetingId,
        channelId: widget.sourceChannelId!,
      );
    } else if (success && widget.sourceUserId != null) {
      // Notify single user for 1:1
      SocketService().emit('call:notify', {
        'meeting_id': meetingId,
        'recipient_ids': [widget.sourceUserId],
      });
    }
  } else {
    // Normal video channel join or recipient accepting call
    // Existing logic...
  }
  
  // Navigate to video conference view
  Navigator.pop(context, result);
}
```

#### 4.4 Incoming Call UI

**File:** `client/lib/main.dart` (add to Shell structure)

```dart
@override
Widget build(BuildContext context) {
  return Stack(
    children: [
      // Existing app content
      child,
      
      // Incoming call bar (above everything)
      const Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: IncomingCallBar(),
      ),
      
      // Existing CallTopBar
      const Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: CallTopBar(),
      ),
    ],
  );
}
```

**File:** `client/lib/widgets/incoming_call_bar.dart`

```dart
class IncomingCallBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<IncomingCall?>(
      stream: CallService.instance.incomingCalls,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return SizedBox.shrink();
        
        final call = snapshot.data!;
        
        return Container(
          color: Colors.green.shade700,
          padding: EdgeInsets.all(12),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                // Caller avatar
                CircleAvatar(...),
                SizedBox(width: 12),
                
                // Call info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(call.callerName, style: TextStyle(fontWeight: FontWeight.bold)),
                      Text(call.channelName ?? '1:1 Call'),
                    ],
                  ),
                ),
                
                // Decline button
                IconButton(
                  icon: Icon(Icons.phone_disabled, color: Colors.red),
                  onPressed: () => _declineCall(call),
                ),
                
                // Accept button
                IconButton(
                  icon: Icon(Icons.phone, color: Colors.white),
                  onPressed: () => _acceptCall(call),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
  
  void _acceptCall(IncomingCall call) {
    // Navigate to PreJoin
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => VideoConferencePreJoinView(
          channelId: call.meetingId,
          channelName: call.channelName ?? '1:1 Call',
          isInstantCall: true,
          isInitiator: false, // Recipient, not initiator
        ),
      ),
    );
    
    // Dismiss incoming call UI
    CallService.instance.clearIncomingCall(call.meetingId);
  }
  
  void _declineCall(IncomingCall call) {
    // Send decline event
    SocketService().emit('call:decline', {
      'meeting_id': call.meetingId,
    });
    
    // Dismiss UI
    CallService.instance.clearIncomingCall(call.meetingId);
  }
}
```

---

### Phase 5: Participant Invitations & Waiting Grid

#### 5.1 Live Invite Button

**File:** `client/lib/views/meeting_video_conference_view.dart`

**Add "Invite" button to controls:**
- Show for ALL instant calls (`meeting.is_instant_call == true`)
- No external guest invitations (internal users only)
- Reuse `LiveInviteDialog` widget from meetings (already exists)
- Endpoint: `POST /api/calls/:callId/invite` (already implemented)
- Backend sends `call:live_invite` socket event to invited users

#### 5.2 Waiting Grid for Initiator

**File:** `client/lib/views/meeting_video_conference_view.dart`

**New widget:** `ParticipantWaitingGrid`

```dart
class ParticipantWaitingGrid extends StatefulWidget {
  final String meetingId;
  final List<String> invitedUserIds;
  
  @override
  State<ParticipantWaitingGrid> createState() => _ParticipantWaitingGridState();
}

class _ParticipantWaitingGridState extends State<ParticipantWaitingGrid> {
  Map<String, ParticipantStatus> _participantStates = {};
  
  @override
  void initState() {
    super.initState();
    _setupListeners();
    _loadParticipantProfiles();
  }
  
  void _setupListeners() {
    // Listen for accept events
    SocketService().registerListener('call:accepted', (data) {
      final userId = data['userId'];
      setState(() {
        _participantStates[userId] = ParticipantStatus.joined;
      });
    });
    
    // Listen for decline events
    SocketService().registerListener('call:declined', (data) {
      final userId = data['userId'];
      final displayName = data['displayName'];
      
      // Remove from grid
      setState(() {
        _participantStates.remove(userId);
      });
      
      // Show snackbar
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$displayName declined the call')),
      );
    });
  }
  
  @override
  Widget build(BuildContext context) {
    // Grid layout showing:
    // - Grayed out profile pics for pending
    // - Live video tiles for joined
    // - Removed tiles for declined
  }
}
```

**Integration:**
- Show grid overlay on video view when `isInstantCall && isInitiator`
- Grid appears until first participant joins
- After first join, switch to normal video grid layout
- Keep listening for new accepts/declines for live invites

**Endpoint already exists:** `POST /api/calls/:callId/invite` (from meetings infrastructure)

---

## 📝 Answered Questions & Design Decisions

### ✅ 1. **1:1 Call Implementation**
**Answer:** Use `direct_messages_screen.dart` (already exists)
- File: `client/lib/screens/messages/direct_messages_screen.dart`
- Add phone icon to AppBar
- Direct message conversations already have recipient UUID
- Use meeting ID as room identifier

---

### ✅ 2. **Call Timeout & Ringtone**
**Answer:** Auto-dismiss after 60 seconds with ringtone
- Play incoming call sound from `assets/` on recipient device
- Auto-dismiss notification bar after 60 seconds
- Initiator waits in room (doesn't timeout)
- Show countdown timer on notification bar

---

### ✅ 3. **Multiple Incoming Calls**
**Answer:** Stack them vertically
- Multiple notification bars can be displayed simultaneously
- Each has its own accept/decline buttons
- User can choose which call to accept

---

### ✅ 4. **Already in Call Behavior**
**Answer:** Show notification with accept option to switch calls
- User can only be in ONE call/meeting/video channel at a time
- If user accepts new call while in another:
  - Leave current session automatically
  - Join new call
- Don't auto-decline, let user choose

---

### ✅ 5. **Caller Sees Who Declined**
**Answer:** Show display name of who declined
- Notification: "Alice declined the call"
- Individual notifications for each decline
- Helps caller know who is/isn't interested

---

### ✅ 6. **Re-invite Declined Users**
**Answer:** Yes, can be re-invited via invite button
- Declined users not blocked
- Any participant can re-invite via UI

---

### ✅ 7. **Call History & Missed Calls**
**Answer:** Track via Signal messages with special type
- When call ends and user didn't join, initiator sends Signal message with type `missed_call`
- Signal message encrypted and stored in recipient's message store
- Message creates activity notification: "Missed call from Alice" or "Missed call from Alice in #general"
- Notification appears in activity panel (same as other Signal notifications)
- Encrypted at rest, decrypted when user opens app
- Clicking notification navigates to DM or channel conversation
- Actual call data is ephemeral (cleanup already happened)

---

### ✅ 8. **Voice vs Video Calls**
**Answer:** Always start with video
- Single phone icon initiates video call
- Users can disable camera after joining (personal preference)
- No separate voice-only mode

---

### ✅ 9. **Offline Users Handling**
**Answer:** Missed call Signal messages sent after call ends
- Online users get `call:incoming` socket event (real-time)
- Initiator tracks who joined vs who didn't
- After call ends, send `missed_call` Signal message to users who:
  - Were invited but never joined
  - Were offline when invited
- Signal message decrypted into activity notification
- No separate database table needed - reuses Signal infrastructure

---

### ✅ 10. **External Guest Invitations**
**Answer:** Never allow guests in instant calls
- Instant calls are internal-only (team members)
- For external participants, use scheduled meetings
- Keeps instant calls simple and secure

---

### ✅ 11. **Initiator Waiting Experience**
**Answer:** Initiator joins room and waits with participant grid
- Flow: Click phone → PreJoin → Join LiveKit room → Notify others
- While waiting, initiator sees grid of invited participants:
  - Each participant shown as profile picture (grayed out)
  - Text below: "Waiting to join..."
  - If user declines: Remove from grid (via `call:declined` event)
  - If user accepts: Replace with live video tile (via `call:accepted` event)
- Initiator is already in room, not waiting on PreJoin screen
- Grid shows real-time status updates via Socket.IO events

---

### ✅ 12. **Call vs Meeting Distinction**
**Answer:** Unified backend, different frontend behavior
- **Backend:** Same `meetings` table, same `MeetingService`, same endpoints (calls.js wraps meetings logic)
- **Frontend:** 
  - Meetings: Pre-scheduled, 15-min warning, shown in meetings page
  - Calls: Instant creation, ringtone notification, shown in call history notifications only
- **Cleanup:**
  - Calls: Delete immediately when all participants leave
  - Meetings: Delete 8 hours after end time
  - Fallback: Both deleted after 8 hours max
- **External guests:** Meetings support external participants, instant calls do NOT

---

## 🎨 UI/UX Design Decisions

### Incoming Call Notification Bar
- **Widget:** Use/enhance `incoming_call_overlay.dart` (already exists)
- **Sound:** Play `assets/incoming_call.mp3` or similar ringtone
- **Duration:** 60-second auto-dismiss with visible countdown timer
- **Stacking:** Multiple bars stack vertically (CSS z-index based)
- **Actions:** Accept (green phone) / Decline (red phone)
- **Already in call:** Accept = leave current session automatically + join new call
- **Signal Decryption:** Ringtone plays AFTER `call:incoming` event is decrypted (caller name/avatar available)

### Waiting Room Grid (Initiator)
- **Layout:** Reuse existing video grid layout in VideoConferenceView
- **Pending State:** 
  - Add tile to grid for each invited participant
  - Grayed out profile picture (50% opacity)
  - User display name
  - Status text: "Waiting to join..." (animated ellipsis)
- **Declined State:** 
  - Remove tile from grid with slide-out animation
  - Show snackbar: "Alice declined the call"
- **Accepted State:** 
  - Replace grayed tile with live video feed (same tile position)
  - Smooth crossfade transition from placeholder to video
  - No separate widget needed - just update existing grid tile

### Phone Icon Location
- **Text Channels:** AppBar actions (signal_group_chat_screen.dart)
- **1:1 DMs:** AppBar actions (direct_messages_screen.dart)
- **Icon:** `Icons.phone` (not `Icons.videocam`)
- **Tooltip:** "Start Call" (not "Join Video Call")

### Participant Profile Grid
- **Data Source:** UserProfileService for avatars/names
- **Loading:** Profile pictures loaded on-demand, cached
- **Real-time Updates:** Listen to `call:declined` and `call:accepted` socket events
- **Max Grid Size:** Show up to 12 pending participants, scroll if more

---

## 📁 Existing Infrastructure to Reuse

### ✅ Backend Services (Already Implemented):
1. **`meetingService.js`** - Core meeting/call logic (463 lines)
   - `createMeeting()` with `is_instant_call` flag
   - `addParticipant()` for live invites
   - Cleanup logic (immediate on all leave, 8h fallback)
2. **`presenceService.js`** - Online status tracking (236 lines)
   - `isOnline(userId)` for filtering recipients
   - 1-minute heartbeat system
3. **`server.js`** - Socket event handlers
   - `call:notify` - Send incoming call events
   - `call:accept` - Participant accepts call
   - `call:decline` - Participant declines call
   - `call:incoming` - Broadcast to recipients
4. **Routes:**
   - `calls.js` - Instant call endpoints (wrappers around meetings)
   - Already has `/api/calls/instant`, `/api/calls/:callId`, etc.

### ✅ Client Widgets (Already Available):
1. **`incoming_call_notification.dart`** - Meeting invitation notification bar
2. **`incoming_call_overlay.dart`** - Full overlay with accept/decline
3. **`call_service.dart`** - Call management and socket listeners
4. **`meeting_service.dart`** - Meeting/call API client
5. **`direct_messages_screen.dart`** - 1:1 chat UI
6. **`signal_group_chat_screen.dart`** - Text channel UI
7. **`video_conference_prejoin_view.dart`** - Device selection + E2EE key exchange
8. **`user_profile_service.dart`** - Profile picture/name loading

### 🔧 Components to Enhance:
1. **IncomingCallOverlay** 
   - Add ringtone playback from assets folder
   - Use Signal decryption before playing (get caller name/avatar)
   - Add 60-second countdown timer
2. **VideoGridLayout** 
   - Add "waiting" participant tiles (grayed profile pictures)
   - Replace with live video when participant joins
   - Remove tile when participant declines
   - Listen to `call:accepted`/`call:declined` events
3. **MeetingVideoConferenceView**
   - Add waiting tiles to existing grid for instant calls
   - Add live invite button (reuse from meetings)
4. **CallService**
   - Add `startChannelCall()` and `startDirectCall()` methods (✅ DONE)
   - Add `notifyChannelMembers()` after joining LiveKit room (✅ DONE)
   - Listen to `call:declined` for snackbar notifications
   - Track who joined vs who was invited
   - Send `missed_call` Signal messages after call ends

---

## 🔗 Backend Integration Points

### Existing Socket.IO Events (from MEETINGS_AND_CALLS_ACTION_PLAN.md):
Already implemented and ready to use:

```javascript
// Call lifecycle (Signal encrypted)
🔒 'call:incoming'  → Signal({ meetingId, callerId, callerName, callerAvatar, timestamp })
🔒 'call:accepted'  → Signal({ meetingId, userId, displayName, avatar })
🔒 'call:declined'  → Signal({ meetingId, userId, displayName })
🔓 'call:ringing'   → { meetingId, userId } // Who's being notified
🔓 'call:ended'     → { meetingId, duration, endedBy }

// Call waiting grid
🔒 'call:participant_waiting' → Signal({ meetingId, participants: [{userId, displayName, avatar}] })
🔒 'call:live_invite'         → Signal({ meetingId, callerId, callerName, invitedBy })
```

### Existing REST Endpoints (from calls.js):
Already implemented:

```javascript
POST   /api/calls/instant              // Create call (sets is_instant_call=true)
GET    /api/calls/:callId              // Get call details
DELETE /api/calls/:callId              // End call (owner only)
POST   /api/calls/:callId/invite       // Invite users mid-call
GET    /api/calls/:callId/participants // List call participants
```

### New Endpoint Needed:
```javascript
GET /api/channels/:channelId/online-members  // Filter members by presenceService
```

---

## 🎯 Implementation Checklist

### Phase 1: UI Changes (Client)

- [ ] Replace `Icons.videocam` with `Icons.phone` in `signal_group_chat_screen.dart`
- [ ] Replace `Icons.videocam` with `Icons.phone` in `direct_messages_screen.dart`
- [ ] Update tooltip text to "Start Call" instead of "Join Video Call"
- [ ] Add `isInstantCall` and `isInitiator` parameters to `VideoConferencePreJoinView`
- [ ] Test phone icon appears correctly in both screens

### Phase 2: Backend Enhancements (Server)

- [ ] Verify `POST /api/calls/instant` accepts `source_channel_id` and `source_user_id`
- [ ] Create `GET /api/channels/:channelId/online-members` endpoint
  - [ ] Verify user is channel member
  - [ ] Query all channel members from database
  - [ ] Filter by `presenceService.isOnline(userId)`
  - [ ] Return user IDs and display names
- [ ] Verify `call:notify` socket event broadcasts correctly
- [ ] Verify `call:accepted` socket event works
- [ ] Verify `call:declined` socket event works
- [ ] Test multi-device broadcast with `emitToUser()` helper
- [ ] Verify instant call cleanup on all participants leave
- [ ] Test 8-hour fallback cleanup

### Phase 3: Call Service (Client)

- [ ] Add `startChannelCall()` method to CallService
- [ ] Add `startDirectCall()` method to CallService
- [ ] Add `notifyChannelMembers()` method to CallService
- [ ] Implement `call:incoming` listener (with Signal decryption)
- [ ] Play ringtone AFTER Signal decryption completes
- [ ] Implement `call:accepted` listener
- [ ] Implement `call:declined` listener
- [ ] Add auto-dismiss timer (60 seconds) for incoming calls
- [ ] Test ringtone audio playback from assets

### Phase 4: PreJoin Integration (Client)

- [ ] Add instant call creation logic in PreJoin `_joinChannel()`
- [ ] Call `POST /api/calls/instant` when `isInstantCall && isInitiator`
- [ ] Join LiveKit room with returned `meetingId`
- [ ] Call `notifyChannelMembers()` AFTER successful LiveKit join
- [ ] Handle recipient flow (accept → PreJoin → join existing meeting)
- [ ] Test E2EE key exchange works for instant calls
- [ ] Test device selection works before joining

### Phase 5: Incoming Call UI (Client)

- [ ] Enhance `IncomingCallOverlay` widget
  - [ ] Add ringtone playback functionality
  - [ ] Add 60-second countdown timer display
  - [ ] Show caller name/avatar from decrypted event
  - [ ] Add stacking support for multiple calls
- [ ] Integrate into `main.dart` Shell structure
- [ ] Add accept button → navigate to PreJoin
- [ ] Add decline button → emit `call:decline` socket event
- [ ] Test "Already in call" flow (leave current + join new)
- [ ] Test multiple simultaneous incoming calls stacking

### Phase 6: Waiting Grid (Client)

- [ ] Modify `VideoConferenceView` to add waiting tiles for instant calls
- [ ] Add placeholder tiles to existing video grid for each invited participant
  - [ ] Show grayed profile picture (UserAvatar with 50% opacity)
  - [ ] Display name and "Waiting to join..." text
  - [ ] Animated loading indicator
- [ ] Listen to `call:accepted` → replace tile with live video feed
  - [ ] Crossfade animation from placeholder to video
  - [ ] Same grid position, no layout shift
- [ ] Listen to `call:declined` → remove tile from grid
  - [ ] Slide-out animation
  - [ ] Show snackbar: "[Name] declined the call"
- [ ] Load participant profiles via `UserProfileService`
- [ ] Handle initials fallback for missing avatars
- [ ] Test grid updates in real-time

### Phase 7: Live Invitations (Client)

- [ ] Add "Invite" button to video controls (instant calls only)
- [ ] Reuse `LiveInviteDialog` from meetings infrastructure
- [ ] Call `POST /api/calls/:callId/invite` endpoint
- [ ] Handle `call:live_invite` socket event for recipients
- [ ] Test mid-call invitations work
- [ ] Verify invited users receive `call:incoming` notification

### Phase 8: Missed Call Notifications ✅ COMPLETE

**Implementation Summary:**
- ✅ Differentiate timeout (60s) vs manual decline
- ✅ Send missed call notification immediately on timeout
- ✅ Track invited, joined, and declined users
- ✅ Send notifications to offline users when call ends
- ✅ Use Signal encryption for missed call messages

**Details:** See [PHASE_8_MISSED_CALL_TIMEOUT_IMPLEMENTATION.md](PHASE_8_MISSED_CALL_TIMEOUT_IMPLEMENTATION.md)

**Key Changes:**
1. `incoming_call_listener.dart` - Separate timeout vs decline handlers
2. `video_conference_view.dart` - Track user states, listen for decline events
3. `server.js` - Forward decline reason parameter
4. Missed call sent on individual timeout, not when initiator leaves

### Phase 9: End-to-End Testing 🔄 IN PROGRESS

**Test Plan:** See [PHASE_9_INSTANT_CALLS_TEST_PLAN.md](PHASE_9_INSTANT_CALLS_TEST_PLAN.md)

**Test Categories:**
- ✅ Channel instant calls (basic, timeout, decline, offline, mixed)
- ✅ Direct (1:1) instant calls
- ✅ Multi-device scenarios
- ✅ Edge cases (network, spam, rapid actions)
- ✅ Signal encryption validation
- ✅ Performance tests
- ✅ UI/UX validation
- ✅ Regression tests

**Execution:**
- [ ] Manual testing of all scenarios
- [ ] Bug tracking and fixes
- [ ] Performance validation
- [ ] Documentation updates

---

## 📅 Estimated Timeline

- **Phase 1 (UI Icon Changes):** 2-3 hours
- **Phase 2 (Backend Endpoint):** 3-4 hours (only need online-members endpoint)
- **Phase 3 (Call Service Enhancement):** 4-6 hours
- **Phase 4 (PreJoin Integration):** 4-6 hours
- **Phase 5 (Incoming Call UI):** 6-8 hours (enhance existing widget)
- **Phase 6 (Waiting Grid):** 8-10 hours
- **Phase 7 (Live Invitations):** 2-3 hours (already implemented, just test)
- **Phase 8 (Missed Calls):** 4-5 hours
- **Phase 9 (Testing):** 1-2 days

**Total:** 4-5 days

**Note:** Much faster than original estimate because:
- Backend infrastructure already complete (meetings, socket events, cleanup)
- Most endpoints already exist (calls.js is wrapper around meetings)
- Widgets already built (incoming_call_overlay, live_invite_dialog)
- Only new work: online-members endpoint, ringtone, waiting grid

---

## 🔗 Related Files Reference

**Client:**
- `client/lib/screens/messages/signal_group_chat_screen.dart` - Text channel UI
- `client/lib/screens/messages/signal_direct_message_screen.dart` - 1:1 chat UI (if exists)
- `client/lib/views/video_conference_prejoin_view.dart` - PreJoin flow
- `client/lib/views/meeting_video_conference_view.dart` - Video conference UI
- `client/lib/services/call_service.dart` - Call management service
- `client/lib/widgets/incoming_call_bar.dart` - NEW: Incoming call UI
- `client/lib/main.dart` - App shell integration

**Server:**
- `server/routes/calls.js` - Instant call endpoints
- `server/routes/channels.js` - Channel member endpoints
- `server/server.js` - Socket event handlers
- `server/services/meetingService.js` - Meeting/call logic
- `server/services/presenceService.js` - Online status

---

## 💡 Implementation Notes

### Key Architecture Points:
- **Unified Backend:** Instant calls use same `meetings` table and `MeetingService` as scheduled meetings
- **Memory-First Storage:** Calls stored in `meetingMemoryStore`, with optional DB write for scheduled calls only
- **Cleanup Strategy:** Immediate on all leave, 8-hour fallback, cron job safety net
- **Socket Events:** All real-time updates via Socket.IO (Signal encrypted for PII)
- **PreJoin Critical:** E2EE key exchange must complete before joining LiveKit room
- **No External Guests:** Instant calls are internal-only (use scheduled meetings for external)

### Reuse Patterns:
- **Endpoints:** `calls.js` is thin wrapper around `meetingService` methods
- **UI Components:** LiveInviteDialog, IncomingCallOverlay, VideoGridLayout already exist
- **Services:** PresenceService, UserProfileService, MeetingService all ready
- **Socket Handlers:** `call:*` events already implemented and tested

### Signal Protocol Flow:
1. **Send:** Backend encrypts `call:incoming` event with caller name/avatar
2. **Receive:** Client decrypts event via SignalService
3. **Ringtone:** Only play AFTER decryption succeeds (caller info available)
4. **Display:** Show decrypted caller name/avatar in notification UI

### Performance Considerations:
- Profile pictures cached in `UserProfileService` (prevents re-fetching)
- Socket event batching for large participant lists
- Waiting grid shows max 12 participants (scroll for more)
- Ringtone uses AudioPlayer with proper cleanup

### Error Handling:
- Signal decryption failure → show generic "Incoming call" without name
- LiveKit connection failure → show error, allow retry
- Network interruption → Socket.IO auto-reconnect, resend events
- Offline users → store missed call notification, deliver on reconnect

---

## ❓ Final Clarifications - ANSWERED ✅

### Question 1: Ringtone Asset ✅
**Answer:** A) Use existing `assets/sounds/incoming_call.mp3`
- Reference existing asset file
- Play via AudioPlayer plugin
- Stop when call accepted/declined/timeout

---

### Question 2: Call Persistence ✅
**Answer:** A) Wait indefinitely (until initiator manually leaves)
- No auto-end timeout
- Initiator sees waiting grid until they manually leave
- Other participants can still join at any time
- Call cleanup only happens when initiator leaves

---

### Question 3: Profile Picture Fallback ✅
**Answer:** A) Show initials (e.g., "AB" for Alice Brown)
- Extract first letter of first name + first letter of last name
- Use colored circle background (based on user ID hash)
- Same pattern as existing `UserAvatar` widget

---

### Question 4: Multiple Device Notifications ✅
**Answer:** A) Send to ALL devices, with smart dismiss behavior
- Send `call:incoming` to all user's devices via `emitToUser()`
- When ONE device accepts:
  - Emit `call:accepted` to all devices
  - Other devices auto-dismiss notification
  - Other devices do NOT show missed call notification
- When user declines on one device:
  - All devices dismiss notification
  - Show missed call notification later
- Track which device accepted via `acceptedDeviceId` in call state

---

### Question 5: Call End Cleanup ✅
**Answer:** A) Delete immediately from memory AND database
- When last participant leaves:
  - Emit `call:ended` event
  - Delete from `meetingMemoryStore`
  - Delete from database (if was written)
  - Cleanup happens immediately, no grace period
- 8-hour fallback cleanup is safety net only (shouldn't trigger normally)

---

## 🔐 Signal Protocol Integration

### E2EE Key Exchange for Calls

**Critical:** Use same Signal 1:1 message files for E2EE key exchange during calls.

**Implementation Pattern:**

1. **When initiator joins call:**
   - Generate or reuse existing Signal session with each invited participant
   - Use `SignalService.sendItem()` with `type: 'video_e2ee_key_request'`
   - Same pattern as video channels (already implemented)

2. **Recipients receive key request:**
   - Handled by existing `signal_service.dart` callbacks
   - Respond with `type: 'video_e2ee_key_response'`
   - No new code needed - reuse channel key exchange logic

3. **Files to reuse:**
   - `client/lib/services/signal_service.dart` - Key exchange methods
   - `client/lib/services/video_conference_service.dart` - Key distribution logic
   - Same E2EE key exchange flow as joining video channel
   - PreJoin screen already handles this in `_setupReceiveItemCallbacks()`

**Note:** Instant calls use SAME E2EE infrastructure as video channels - no new Signal protocol code needed.

---

## 👥 Participant Invitation Rules

### Who Can Invite:

**✅ Allowed:**
- Any call participant can invite OTHER SERVER USERS
- Use `LiveInviteDialog` (same as meetings)
- Invited users receive `call:live_invite` event
- Invited users go through PreJoin → E2EE key exchange → join

**❌ Not Allowed:**
- NO external guest invitations for instant calls
- External guests ONLY via scheduled meetings
- Generate invite link button HIDDEN for instant calls

**Implementation:**
```dart
// In video controls
if (meeting.is_instant_call) {
  // Show invite button
  IconButton(
    icon: Icons.person_add,
    onPressed: _showLiveInviteDialog, // Server users only
  ),
  
  // DO NOT show generate link button
  // if (!meeting.is_instant_call) {  // Only for meetings
  //   IconButton(
  //     icon: Icons.link,
  //     onPressed: _generateExternalInviteLink,
  //   ),
  // }
}
```

**Backend Endpoint (already exists):**
```javascript
POST /api/calls/:callId/invite
Body: { user_ids: ["uuid1", "uuid2"] }
```

**Socket Event:**
```javascript
🔒 'call:live_invite' → Signal({ meetingId, inviterId, inviterName, invitedBy })
```

---

## ✅ All Questions Resolved

Everything is now clear! Ready to start implementation with:

1. ✅ Ringtone from assets
2. ✅ No auto-timeout for waiting initiator
3. ✅ Initials fallback for avatars
4. ✅ Multi-device handling with smart dismiss
5. ✅ Immediate cleanup on all leave
6. ✅ Reuse Signal 1:1 message files for E2EE
7. ✅ Participant invites allowed (no external guests)

**No additional questions - implementation plan is complete!**
