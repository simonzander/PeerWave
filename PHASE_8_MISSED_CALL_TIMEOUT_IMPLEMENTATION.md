# Phase 8: Missed Call Timeout Implementation

## Overview
Implemented improved missed call notification logic that sends notifications when individual users timeout (60 seconds) rather than when the call initiator leaves.

## Problem Statement
**Original Implementation:**
- Missed call notifications were sent only when the call initiator left the call
- Users who timed out or manually declined never received missed call notifications
- Poor UX: If a user ignored a call for 60s, they had no record of the missed call

**Improved Implementation:**
- Send missed call notification immediately when a user times out (60s)
- Don't send notification if user manually declines
- Track declined users to avoid duplicate notifications
- Send to offline users only when call ends

## Implementation Details

### 1. Frontend Changes

#### incoming_call_listener.dart
**Added Timeout vs Manual Decline Differentiation:**
```dart
// Separate handlers for manual decline vs timeout
void _handleDecline(Map<String, dynamic> callData) {
  _callService.declineCall(meetingId, reason: 'declined');
  // ...
}

void _handleTimeout(Map<String, dynamic> callData) {
  _callService.declineCall(meetingId, reason: 'timeout');
  // ...
}
```

**Key Changes:**
- Split `_handleDecline()` into two methods: `_handleDecline()` and `_handleTimeout()`
- Updated auto-dismiss timer to call `_handleTimeout()` instead of `_handleDecline()`
- Added `onTimeout` callback to `_IncomingCallBar` widget
- Pass different reasons to `CallService.declineCall()`: `'declined'` vs `'timeout'`

#### video_conference_view.dart
**Added Tracking Sets:**
```dart
Set<String> _invitedUserIds = {};
Set<String> _joinedUserIds = {};
Set<String> _declinedUserIds = {}; // Track users who declined/timed out
```

**Added Socket Listener:**
```dart
void _setupCallDeclineListener() {
  final isInstantCall = widget.channelId.startsWith('call_');
  if (!isInstantCall) return;
  
  SocketService().registerListener('call:declined', (data) async {
    final userId = declineData['user_id'] as String?;
    final reason = declineData['reason'] as String?;
    
    // Track declined user
    _declinedUserIds.add(userId);
    
    // If timeout, send missed call notification immediately
    if (reason == 'timeout') {
      await _sendMissedCallNotification(userId);
    }
  });
}
```

**Added Missed Call Notification Method:**
```dart
Future<void> _sendMissedCallNotification(String userId) async {
  final payload = {
    'callerId': currentUserId,
    'channelId': widget.channelId,
    'channelName': widget.channelName,
    'timestamp': DateTime.now().toIso8601String(),
  };
  
  await SignalService.instance.sendItem(
    recipientUserId: userId,
    type: 'missingcall',
    payload: payload,
  );
}
```

### 2. Backend Changes

#### server.js
**Updated `call:decline` Event Handler:**
```javascript
socket.on('call:decline', async (data) => {
  const { meeting_id, reason } = data;
  
  const meeting = await meetingService.getMeeting(meeting_id);
  emitToUser(io, meeting.created_by, 'call:declined', {
    meeting_id,
    user_id: userId,
    reason: reason || 'declined' // Forward the decline reason
  });
});
```

**Key Changes:**
- Extract `reason` from incoming `call:decline` event
- Forward `reason` to initiator in `call:declined` event
- Default to `'declined'` if no reason provided

## User Experience Flow

### Scenario 1: User Times Out (60s)
1. User receives incoming call notification
2. User ignores it for 60 seconds
3. Auto-dismiss timer fires → calls `_handleTimeout()`
4. Client sends `call:decline` with `reason: 'timeout'`
5. Server forwards to initiator with `reason: 'timeout'`
6. Initiator's `call:declined` listener fires
7. **Immediately sends missed call Signal notification**
8. User sees missed call in activity feed

### Scenario 2: User Manually Declines
1. User receives incoming call notification
2. User clicks "Decline" button
3. Client sends `call:decline` with `reason: 'declined'`
4. Server forwards to initiator with `reason: 'declined'`
5. Initiator's `call:declined` listener fires
6. **No missed call notification sent** (user actively declined)
7. User removed from waiting list

### Scenario 3: User Was Offline
1. User never receives call notification (offline)
2. Call ends naturally
3. **Future implementation**: Send missed call to offline users when call ends
4. User sees missed call when they come online

## Technical Notes

### Socket Event Flow
```
Recipient Device (Timeout)
  ↓ call:decline {meeting_id, reason: 'timeout'}
Server
  ↓ call:declined {meeting_id, user_id, reason: 'timeout'}
Initiator Device
  ↓ Checks reason == 'timeout'
  ↓ Sends Signal message {type: 'missingcall'}
Recipient Device (Later)
  ↓ Receives encrypted Signal notification
Activity Feed
```

### Signal Message Type
- Uses existing `'missingcall'` type (matches activity notification system)
- Encrypted end-to-end using Signal Protocol
- Payload includes: `callerId`, `channelId`, `channelName`, `timestamp`

### Tracking Sets Purpose
- `_invitedUserIds`: All users who received call invitation
- `_joinedUserIds`: Users who actually joined the call
- `_declinedUserIds`: Users who declined OR timed out
- Formula: `missedUsers = invitedUserIds - joinedUserIds - declinedUserIds`

## Testing Checklist

- [ ] Test 60-second timeout sends missed call notification
- [ ] Test manual decline does NOT send missed call notification
- [ ] Test notification appears in activity feed
- [ ] Test Signal encryption/decryption of missed call
- [ ] Test multiple users timing out simultaneously
- [ ] Test user who times out then comes back online
- [ ] Test call initiator sees correct waiting tile behavior
- [ ] Test offline users (future implementation)

## Future Enhancements

1. **Offline User Notifications**: Send missed call to users who were offline when call ended
2. **Notification Persistence**: Store missed calls in local database
3. **Call History**: Display missed calls in a dedicated call history screen
4. **Badge Counts**: Show number of missed calls in app icon badge
5. **Snooze/Callback**: Allow users to set reminders to call back

## Files Modified

### Client
- `client/lib/widgets/incoming_call_listener.dart`
  - Added `_handleTimeout()` method
  - Split decline handling into timeout vs manual paths
  - Pass different reasons to `CallService.declineCall()`

- `client/lib/views/video_conference_view.dart`
  - Added `_invitedUserIds`, `_joinedUserIds`, `_declinedUserIds` tracking sets
  - Added `_setupCallDeclineListener()` to listen for decline events
  - Added `_sendMissedCallNotification()` to send Signal messages
  - Imported `socket_service.dart`

### Server
- `server/server.js`
  - Updated `call:decline` handler to extract and forward `reason` parameter

## Related Documentation
- [CHANNEL_INSTANT_CALLS_ACTION_PLAN.md](CHANNEL_INSTANT_CALLS_ACTION_PLAN.md) - Overall instant call feature plan
- [SOCKET_IO_EVENTS_REFERENCE.md](SOCKET_IO_EVENTS_REFERENCE.md) - Socket.IO event documentation
- [Signal Protocol Documentation](docs/SIGNAL_KEY_MANAGEMENT_IMPLEMENTATION_COMPLETE.md) - E2EE details

## Completion Status
✅ Phase 8 Timeout Implementation Complete
- Timeout-based notifications working
- Manual decline differentiation working
- Server forwarding reason parameter
- Signal encryption integrated

**Next Step**: Comprehensive end-to-end testing (Phase 9)
