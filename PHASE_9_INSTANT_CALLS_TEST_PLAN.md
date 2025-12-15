# Phase 9: Instant Calls End-to-End Test Plan

## Overview
Comprehensive testing plan for the instant call feature implementation (Phases 1-8).

## Test Environment Setup
- **Requirements**: Two test accounts with multiple devices each
- **Server**: Development server running locally or staging environment
- **Client**: Flutter desktop app (Windows)
- **Network**: Stable internet connection for LiveKit
- **Signal**: E2EE keys generated for both test accounts

---

## Test Scenarios

### 1. Channel Instant Calls

#### 1.1 Basic Channel Call Flow (Happy Path)
**Setup**: Alice and Bob are members of #general channel

**Steps**:
1. Alice clicks phone icon in channel header
2. Pre-join view appears with device selection
3. Alice clicks "Join Call"
4. Bob receives incoming call notification (IncomingCallListener)
5. Bob clicks "Accept"
6. Bob joins via pre-join view
7. Both users see each other in video grid
8. Alice clicks "Leave Call"

**Expected Results**:
- ✅ Call initiates successfully
- ✅ Bob receives encrypted Signal notification
- ✅ Video grid shows both participants
- ✅ Audio/video streams work
- ✅ No missed call notifications sent

**Critical Checks**:
- Call notification decrypts correctly
- LiveKit room created with `call_` prefix
- Both users can toggle audio/video
- Call ends cleanly when Alice leaves

---

#### 1.2 Channel Call with Timeout
**Setup**: Alice and Bob are members of #general channel

**Steps**:
1. Alice initiates call in #general
2. Bob receives notification
3. **Bob ignores notification for 60 seconds**
4. Notification auto-dismisses
5. Alice eventually leaves call

**Expected Results**:
- ✅ Auto-dismiss timer counts down from 60s
- ✅ Notification slides out after 60s
- ✅ `call:decline` sent with `reason: 'timeout'`
- ✅ Bob immediately receives missed call Signal notification
- ✅ Bob sees missed call in activity feed
- ✅ Alice sees Bob's waiting tile removed

**Critical Checks**:
- Missed call sent IMMEDIATELY on timeout (not when Alice leaves)
- Signal message type is `'missingcall'`
- Activity notification shows correct caller/channel info
- No duplicate notifications

---

#### 1.3 Channel Call with Manual Decline
**Setup**: Alice and Bob are members of #general channel

**Steps**:
1. Alice initiates call in #general
2. Bob receives notification
3. **Bob clicks "Decline" button**
4. Alice eventually leaves call

**Expected Results**:
- ✅ Notification dismisses immediately
- ✅ `call:decline` sent with `reason: 'declined'`
- ✅ **NO missed call notification sent to Bob**
- ✅ Alice sees Bob's waiting tile removed
- ✅ Bob does NOT see activity notification

**Critical Checks**:
- Manual decline differentiated from timeout
- No Signal message sent for manual decline
- Waiting tile removed immediately

---

#### 1.4 Channel Call with Offline User
**Setup**: Alice, Bob, and Charlie are members of #general. Charlie is offline.

**Steps**:
1. Alice initiates call in #general
2. Bob accepts and joins
3. Charlie is offline (never receives notification)
4. Alice and Bob talk for a while
5. **Alice leaves call (call ends)**
6. Charlie comes online later

**Expected Results**:
- ✅ Charlie receives missed call notification when Alice leaves
- ✅ Signal message sent to Charlie when call ends
- ✅ Charlie sees missed call in activity feed when online
- ✅ Bob does NOT receive missed call (he joined)

**Critical Checks**:
- Offline users get notifications when call ends
- Only users who never joined/declined get notified
- Notification payload includes correct call details

---

#### 1.5 Multiple Users with Mixed Responses
**Setup**: Alice, Bob, Charlie, Dave in #general

**Steps**:
1. Alice initiates call
2. Bob accepts immediately
3. Charlie times out (60s)
4. Dave declines manually
5. Alice leaves call

**Expected Results**:
- ✅ Bob: Joined, no missed call
- ✅ Charlie: Timed out, gets missed call at 60s mark
- ✅ Dave: Declined, no missed call
- ✅ Alice sees correct waiting tiles (Bob joined, Charlie/Dave removed)

**Critical Checks**:
- Each user tracked independently
- Charlie gets notification at timeout, not at call end
- Dave gets no notification
- No duplicate notifications

---

### 2. Direct (1:1) Instant Calls

#### 2.1 Basic Direct Call Flow
**Setup**: Alice initiates direct call to Bob

**Steps**:
1. Alice opens DM with Bob
2. Alice clicks phone icon
3. Bob receives incoming call notification
4. Bob accepts
5. Both join video call
6. Alice hangs up

**Expected Results**:
- ✅ Direct call created with unique meeting ID
- ✅ Bob receives encrypted notification
- ✅ Video grid shows both users
- ✅ Call ends cleanly

**Critical Checks**:
- Meeting ID has `call_` prefix
- Only Bob receives notification (not broadcast)
- Signal encryption works for 1:1
- No other users notified

---

#### 2.2 Direct Call Timeout
**Setup**: Alice calls Bob directly

**Steps**:
1. Alice initiates call to Bob
2. Bob ignores for 60 seconds
3. Notification auto-dismisses
4. Alice leaves call

**Expected Results**:
- ✅ Bob gets missed call notification at 60s
- ✅ Alice sees waiting tile disappear at 60s
- ✅ Activity feed shows missed call from Alice

---

#### 2.3 Direct Call Manual Decline
**Setup**: Alice calls Bob directly

**Steps**:
1. Alice initiates call to Bob
2. Bob clicks "Decline"
3. Alice leaves call

**Expected Results**:
- ✅ Bob does NOT get missed call notification
- ✅ Alice sees waiting tile disappear immediately
- ✅ No activity notification for Bob

---

### 3. Multi-Device Scenarios

#### 3.1 Same User, Multiple Devices
**Setup**: Alice logged in on Desktop and Mobile

**Steps**:
1. Bob calls Alice
2. Both devices receive notification
3. Alice accepts on Desktop
4. Mobile notification should dismiss

**Expected Results**:
- ✅ Both devices show notification
- ✅ Accepting on one device dismisses on all
- ✅ Only one instance of Alice joins call
- ✅ No duplicate missed calls

**Critical Checks**:
- Multi-device dismiss works via socket.io
- Signal notification received on both devices
- Proper device identity handling

---

### 4. Edge Cases

#### 4.1 Rapid Accept/Decline
**Steps**:
1. Alice calls Bob
2. Bob quickly clicks Accept then Decline
3. Check state consistency

**Expected Results**:
- ✅ Last action wins
- ✅ No race conditions
- ✅ Proper cleanup

---

#### 4.2 Network Interruption During Call
**Steps**:
1. Alice and Bob in active call
2. Alice loses network connection
3. Alice reconnects

**Expected Results**:
- ✅ LiveKit handles reconnection
- ✅ No phantom missed calls
- ✅ Call state recovers

---

#### 4.3 Server Restart During Call
**Steps**:
1. Active call in progress
2. Restart server
3. Observe behavior

**Expected Results**:
- ✅ LiveKit call continues (separate service)
- ✅ Socket.io reconnects
- ✅ No data loss for ongoing call

---

#### 4.4 Spam Prevention (Multiple Calls)
**Steps**:
1. Alice initiates 5 calls to Bob rapidly
2. Observe notification behavior

**Expected Results**:
- ✅ Only one notification per call
- ✅ Notifications stack vertically
- ✅ Each can be accepted/declined independently

---

### 5. Signal Encryption Validation

#### 5.1 Encrypted Call Notifications
**Steps**:
1. Alice calls Bob
2. Inspect Signal message in database
3. Verify payload encrypted

**Expected Results**:
- ✅ Payload is base64 encrypted ciphertext
- ✅ Only Bob can decrypt
- ✅ Includes correct call metadata after decryption

**Tools**: Database inspection, Signal service logs

---

#### 5.2 Encrypted Missed Call Notifications
**Steps**:
1. Alice calls Bob
2. Bob times out
3. Inspect missed call Signal message

**Expected Results**:
- ✅ Type is `'missingcall'`
- ✅ Payload encrypted
- ✅ Decrypts to show caller, channel, timestamp

---

### 6. Performance Tests

#### 6.1 Large Channel Call
**Setup**: Channel with 20 members

**Steps**:
1. Alice initiates call in large channel
2. Measure notification delivery time
3. Observe server load

**Expected Results**:
- ✅ All online users receive notification within 2s
- ✅ Server handles 20+ Socket.io emits
- ✅ No performance degradation

---

#### 6.2 Waiting Tiles Performance
**Setup**: 10 users invited to call

**Steps**:
1. Alice invites 10 users
2. Observe waiting tile rendering
3. Users join one by one

**Expected Results**:
- ✅ Waiting tiles render smoothly
- ✅ Profile pictures load
- ✅ Tiles disappear when users join
- ✅ No UI lag

---

### 7. UI/UX Validation

#### 7.1 Pre-Join Device Selection
**Steps**:
1. Initiate call
2. Test camera/microphone switching
3. Preview local video

**Expected Results**:
- ✅ Device list populates
- ✅ Preview updates when switching
- ✅ Selected devices used in call

---

#### 7.2 Incoming Call Notification UI
**Steps**:
1. Receive incoming call
2. Observe slide-in animation
3. Check countdown timer
4. Test Accept/Decline buttons

**Expected Results**:
- ✅ Smooth slide-in from left
- ✅ Countdown shows 60...59...58...
- ✅ Buttons responsive
- ✅ Proper color coding (green accept, red decline)

---

#### 7.3 Waiting Tiles in Video Grid
**Steps**:
1. Initiate call with 3 invitees
2. Check waiting tile appearance
3. One user joins
4. Observe tile transition

**Expected Results**:
- ✅ Waiting tiles show "Waiting..." indicator
- ✅ Profile picture displays
- ✅ Tile smoothly transitions to video when user joins
- ✅ Grid reflows properly

---

## Regression Tests

### R1. Existing Meeting Functionality
**Verify**: Scheduled meetings still work as before
- ✅ Meeting creation
- ✅ Meeting join
- ✅ Meeting participants
- ✅ No instant call code affects meetings

### R2. Regular Channel Messaging
**Verify**: Channel chat unaffected
- ✅ Send/receive messages
- ✅ E2EE encryption
- ✅ File sharing

### R3. Direct Messaging
**Verify**: DMs work normally
- ✅ Send/receive DMs
- ✅ Signal encryption
- ✅ Message history

---

## Automated Testing Opportunities

### Unit Tests Needed
```dart
// call_service_test.dart
- test('notifyChannelMembers returns user IDs')
- test('declineCall emits correct reason')
- test('acceptCall sends socket event')

// incoming_call_listener_test.dart
- test('timeout triggers after 60 seconds')
- test('manual decline sends declined reason')
- test('accept navigates to prejoin')

// video_conference_view_test.dart
- test('tracks invited users from widget parameter')
- test('tracks joined users from participant stream')
- test('sends missed calls to offline users on leave')
```

### Integration Tests Needed
```dart
// instant_call_flow_test.dart
- test('full channel call flow')
- test('full direct call flow')
- test('timeout sends missed call notification')
- test('manual decline does not send notification')
```

---

## Bug Tracking Template

### Issue Format
```markdown
**Test Scenario**: [e.g., 1.2 Channel Call with Timeout]
**Expected**: [What should happen]
**Actual**: [What actually happened]
**Steps to Reproduce**:
1. ...
2. ...

**Environment**:
- Client Version: 
- Server Commit:
- OS: Windows
- Network: Stable/Unstable

**Logs**: [Attach relevant logs]
**Screenshots**: [If UI issue]
```

---

## Success Criteria

### Phase 9 Complete When:
- ✅ All 7 main test categories pass
- ✅ No critical bugs found
- ✅ Performance acceptable (notifications < 2s)
- ✅ UI/UX smooth and responsive
- ✅ Signal encryption verified
- ✅ No regressions in existing features

### Known Limitations (Document if any):
- Maximum concurrent calls per user
- Maximum participants in instant call
- Timeout values (fixed at 60s)
- Notification sound configuration

---

## Test Execution Log

### Tester: _____________
### Date: _____________

| Scenario | Result | Notes | Issues |
|----------|--------|-------|--------|
| 1.1 Basic Channel Call | ⬜ Pass ⬜ Fail | | |
| 1.2 Channel Timeout | ⬜ Pass ⬜ Fail | | |
| 1.3 Channel Decline | ⬜ Pass ⬜ Fail | | |
| 1.4 Offline User | ⬜ Pass ⬜ Fail | | |
| 1.5 Mixed Responses | ⬜ Pass ⬜ Fail | | |
| 2.1 Basic Direct Call | ⬜ Pass ⬜ Fail | | |
| 2.2 Direct Timeout | ⬜ Pass ⬜ Fail | | |
| 2.3 Direct Decline | ⬜ Pass ⬜ Fail | | |
| 3.1 Multi-Device | ⬜ Pass ⬜ Fail | | |
| 4.1 Rapid Actions | ⬜ Pass ⬜ Fail | | |
| 4.2 Network Interruption | ⬜ Pass ⬜ Fail | | |
| 4.3 Server Restart | ⬜ Pass ⬜ Fail | | |
| 4.4 Spam Prevention | ⬜ Pass ⬜ Fail | | |
| 5.1 Call Encryption | ⬜ Pass ⬜ Fail | | |
| 5.2 Missed Call Encryption | ⬜ Pass ⬜ Fail | | |
| 6.1 Large Channel | ⬜ Pass ⬜ Fail | | |
| 6.2 Waiting Tiles | ⬜ Pass ⬜ Fail | | |
| 7.1 Pre-Join UI | ⬜ Pass ⬜ Fail | | |
| 7.2 Notification UI | ⬜ Pass ⬜ Fail | | |
| 7.3 Waiting Tiles UI | ⬜ Pass ⬜ Fail | | |
| R1 Meetings | ⬜ Pass ⬜ Fail | | |
| R2 Channel Chat | ⬜ Pass ⬜ Fail | | |
| R3 Direct Messages | ⬜ Pass ⬜ Fail | | |

---

## Next Steps After Testing

1. **If all tests pass**: Mark feature as complete, merge to main branch
2. **If bugs found**: Document, prioritize, and fix critical issues
3. **Performance issues**: Profile and optimize bottlenecks
4. **UI improvements**: Gather feedback and iterate on design
5. **Documentation**: Update user-facing docs and API reference

---

## Related Documentation
- [CHANNEL_INSTANT_CALLS_ACTION_PLAN.md](CHANNEL_INSTANT_CALLS_ACTION_PLAN.md)
- [PHASE_8_MISSED_CALL_TIMEOUT_IMPLEMENTATION.md](PHASE_8_MISSED_CALL_TIMEOUT_IMPLEMENTATION.md)
- [SOCKET_IO_EVENTS_REFERENCE.md](SOCKET_IO_EVENTS_REFERENCE.md)
