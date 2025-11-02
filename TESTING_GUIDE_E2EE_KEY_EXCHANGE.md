# E2EE Key Exchange Testing Guide

**Created:** November 2, 2025  
**Purpose:** Testing LiveKit E2EE Key Exchange with Timestamp-Based Race Condition Resolution

---

## 🎯 What to Test

This guide helps you verify that the E2EE key exchange implementation works correctly, including:
- ✅ Key generation by first participant
- ✅ Key distribution to new participants  
- ✅ Timestamp-based race condition resolution
- ✅ Key rotation on session end
- ✅ Forward secrecy (new keys per session)

---

## 📊 Enhanced Debug Logging

All key components now output enhanced debug logs with visual separators:

### Log Patterns to Look For:

```
═══════════════════════════════════════════════════════════
[VideoConf][TEST] 🔐 INITIALIZING E2EE (FIRST PARTICIPANT)
[VideoConf][TEST] Key Generated: ABC123XYZ... (32 bytes)
[VideoConf][TEST] Key Timestamp: 1730563200000
[VideoConf][TEST] Is First Participant: true
[VideoConf][TEST] ✓ E2EE INITIALIZATION COMPLETE
═══════════════════════════════════════════════════════════
```

```
═══════════════════════════════════════════════════════════
[VideoConf][TEST] 🔑 REQUESTING E2EE KEY
[VideoConf][TEST] Requester ID: user-abc-123
[VideoConf][TEST] Request Timestamp: 1730563205000
[VideoConf][TEST] ⏳ Waiting for key response (10 second timeout)...
═══════════════════════════════════════════════════════════
```

```
═══════════════════════════════════════════════════════════
[VideoConf][TEST] 📨 RECEIVED E2EE KEY MESSAGE
[VideoConf][TEST] Sender: user-xyz-456
[VideoConf][TEST] Timestamp: 1730563200000
[VideoConf][TEST] Current Timestamp: 1730563205000
[VideoConf][TEST] ⚠️ RACE CONDITION DETECTED!
[VideoConf][TEST] ✓ REJECTING NEWER KEY - Keeping our older key
[VideoConf][TEST] Rule: Oldest timestamp wins!
═══════════════════════════════════════════════════════════
```

---

## 🧪 Test Scenarios

### Test 1: Single User (First Participant) ✅

**Objective:** Verify first participant generates key correctly

**Steps:**
1. Open browser console (F12)
2. Navigate to a WebRTC channel
3. Click video call button
4. PreJoin screen opens

**Expected Console Logs:**
```
═══════════════════════════════════════════════════════════
[PreJoin][TEST] 🔍 CHECKING PARTICIPANT STATUS
[PreJoin][TEST] Channel ID: channel-uuid
[PreJoin][TEST] ✅ PARTICIPANT STATUS RECEIVED
[PreJoin][TEST] Is First Participant: true
[PreJoin][TEST] Participant Count: 0
═══════════════════════════════════════════════════════════
```

**On "Join Call" click:**
```
═══════════════════════════════════════════════════════════
[VideoConf][TEST] 🔐 INITIALIZING E2EE (FIRST PARTICIPANT)
[VideoConf][TEST] Key Generated: [16 char preview]... (32 bytes)
[VideoConf][TEST] Key Timestamp: [milliseconds]
[VideoConf][TEST] Is First Participant: true
[VideoConf][TEST] ✓ BaseKeyProvider created with e2ee.worker.dart.js
[VideoConf][TEST] ✓ Key set in KeyProvider (AES-256 frame encryption ready)
[VideoConf][TEST] ✓ E2EE INITIALIZATION COMPLETE
[VideoConf][TEST] ✓ Role: KEY ORIGINATOR (first participant)
═══════════════════════════════════════════════════════════
```

**What to Verify:**
- ✅ "Is First Participant: true"
- ✅ Key timestamp is generated
- ✅ KeyProvider successfully created
- ✅ No errors in console

---

### Test 2: Two Users (Key Exchange) ✅

**Objective:** Verify second participant receives key from first

**Setup:**
1. User A already in call (from Test 1)
2. User B opens PreJoin screen in new browser/incognito tab

**Expected Console Logs (User B):**
```
═══════════════════════════════════════════════════════════
[PreJoin][TEST] 🔍 CHECKING PARTICIPANT STATUS
[PreJoin][TEST] Is First Participant: false
[PreJoin][TEST] Participant Count: 1
═══════════════════════════════════════════════════════════

═══════════════════════════════════════════════════════════
[PreJoin][TEST] 🔐 REQUESTING E2EE KEY FROM PARTICIPANTS
[VideoConf][TEST] 🔑 REQUESTING E2EE KEY
[VideoConf][TEST] ⏳ Waiting for key response (10 second timeout)...
═══════════════════════════════════════════════════════════
```

**Expected Console Logs (User A - responds to request):**
```
═══════════════════════════════════════════════════════════
[MESSAGE_LISTENER][TEST] 📬 PROCESSING VIDEO E2EE KEY MESSAGE
[MESSAGE_LISTENER][TEST] Message Type: video_e2ee_key_request
[MESSAGE_LISTENER][TEST] 📩 KEY REQUEST RECEIVED
[MESSAGE_LISTENER][TEST] Requester: [User B ID]
═══════════════════════════════════════════════════════════

═══════════════════════════════════════════════════════════
[VideoConf][TEST] 📬 HANDLING KEY REQUEST
[VideoConf][TEST] Requester: [User B ID]
[VideoConf][TEST] Our Timestamp: [User A's original timestamp]
[VideoConf][TEST] 📤 Sending key response...
[VideoConf][TEST] ORIGINAL Timestamp: [Same as User A's generation time]
[VideoConf][TEST] ✓ Key response sent via Signal Protocol
═══════════════════════════════════════════════════════════
```

**Expected Console Logs (User B - receives key):**
```
═══════════════════════════════════════════════════════════
[MESSAGE_LISTENER][TEST] 📬 PROCESSING VIDEO E2EE KEY MESSAGE
[MESSAGE_LISTENER][TEST] Message Type: video_e2ee_key_response
[MESSAGE_LISTENER][TEST] 🔑 KEY RESPONSE RECEIVED
[MESSAGE_LISTENER][TEST] Key Timestamp: [User A's timestamp]
═══════════════════════════════════════════════════════════

═══════════════════════════════════════════════════════════
[VideoConf][TEST] 📨 RECEIVED E2EE KEY MESSAGE
[VideoConf][TEST] Timestamp: [User A's timestamp]
[VideoConf][TEST] 🔑 This is a KEY RESPONSE
[VideoConf][TEST] ✓ KEY ACCEPTED
[VideoConf][TEST] Updated Timestamp: [User A's timestamp]
[VideoConf][TEST] Is First Participant: false
[VideoConf][TEST] ✓ Key set in BaseKeyProvider
[VideoConf][TEST] ✓ Frame-level AES-256 E2EE now ACTIVE
[VideoConf][TEST] ✅ KEY EXCHANGE SUCCESSFUL
═══════════════════════════════════════════════════════════
```

**What to Verify:**
- ✅ User B sees "Is First Participant: false"
- ✅ User A receives key request
- ✅ User A sends response with ORIGINAL timestamp (not new)
- ✅ User B receives key with User A's timestamp
- ✅ Both users have IDENTICAL timestamp
- ✅ PreJoin "Join Call" button becomes enabled
- ✅ No timeout errors

---

### Test 3: Race Condition (3 Simultaneous Joins) ⚠️

**Objective:** Verify timestamp-based resolution when multiple users join at once

**Setup:**
1. Have 3 users (A, B, C) ready
2. All click video call button at the same time (within 1 second)
3. All might see "Is First Participant: true" initially

**Expected Behavior:**
- All 3 users generate their own keys with different timestamps
- They exchange keys via Signal Protocol
- Race condition logic triggers: **Oldest timestamp wins**
- All 3 converge to using the key with the oldest timestamp

**Expected Console Logs (example for User B receiving older key from A):**
```
═══════════════════════════════════════════════════════════
[VideoConf][TEST] 📨 RECEIVED E2EE KEY MESSAGE
[VideoConf][TEST] Timestamp: 1730563200000 (older)
[VideoConf][TEST] Current Timestamp: 1730563205000 (newer)
[VideoConf][TEST] 🔑 This is a KEY RESPONSE
[VideoConf][TEST] ✓ KEY ACCEPTED (replacing our newer key)
[VideoConf][TEST] Updated Timestamp: 1730563200000
═══════════════════════════════════════════════════════════
```

**Expected Console Logs (when receiving newer key from C):**
```
═══════════════════════════════════════════════════════════
[VideoConf][TEST] 📨 RECEIVED E2EE KEY MESSAGE
[VideoConf][TEST] Our timestamp: 1730563200000 (older)
[VideoConf][TEST] Received timestamp: 1730563210000 (newer)
[VideoConf][TEST] ⚠️ RACE CONDITION DETECTED!
[VideoConf][TEST] ✓ REJECTING NEWER KEY - Keeping our older key
[VideoConf][TEST] Rule: Oldest timestamp wins!
═══════════════════════════════════════════════════════════
```

**What to Verify:**
- ✅ All 3 users end up with the SAME key
- ✅ All 3 users have the SAME timestamp (the oldest one)
- ✅ Users reject keys with newer timestamps
- ✅ Users accept keys with older timestamps
- ✅ All users can decrypt each other's frames

**How to Compare Timestamps:**
1. Open all 3 browser consoles side-by-side
2. Search for "[VideoConf][TEST] Updated Timestamp:"
3. Compare the final timestamp values - they should be identical

---

### Test 4: First Participant Leaves ✅

**Objective:** Verify key continuity when first participant leaves

**Setup:**
1. User A (first, has timestamp T1) in call
2. User B joined (has same timestamp T1)
3. User A closes browser/leaves call
4. User C joins via PreJoin

**Expected Console Logs (User B - now distributes key):**
```
═══════════════════════════════════════════════════════════
[VideoConf][TEST] 📬 HANDLING KEY REQUEST
[VideoConf][TEST] Requester: [User C ID]
[VideoConf][TEST] Our Timestamp: [T1 - original timestamp]
[VideoConf][TEST] Is First Participant: false
[VideoConf][TEST] 📤 Sending key response...
[VideoConf][TEST] ORIGINAL Timestamp: [T1] (NOT new timestamp!)
═══════════════════════════════════════════════════════════
```

**Expected Console Logs (User C - receives original key):**
```
═══════════════════════════════════════════════════════════
[VideoConf][TEST] 📨 RECEIVED E2EE KEY MESSAGE
[VideoConf][TEST] Timestamp: [T1 - original from User A]
[VideoConf][TEST] ✓ KEY ACCEPTED
[VideoConf][TEST] Updated Timestamp: [T1]
═══════════════════════════════════════════════════════════
```

**What to Verify:**
- ✅ User B can still distribute key (even though not first participant)
- ✅ User C receives ORIGINAL timestamp T1 (not new)
- ✅ User B and C have IDENTICAL timestamp
- ✅ No new key generated
- ✅ Key continuity maintained

---

### Test 5: New Session (Forward Secrecy) ✅

**Objective:** Verify new key generated when all participants leave

**Setup:**
1. User A, B, C all in call with key timestamp T1
2. All users leave call (close tabs/browsers)
3. Wait 10 seconds
4. User D joins (new session)

**Expected Console Logs (User D):**
```
═══════════════════════════════════════════════════════════
[PreJoin][TEST] 🔍 CHECKING PARTICIPANT STATUS
[PreJoin][TEST] Is First Participant: true
[PreJoin][TEST] Participant Count: 0
═══════════════════════════════════════════════════════════

═══════════════════════════════════════════════════════════
[VideoConf][TEST] 🔐 INITIALIZING E2EE (FIRST PARTICIPANT)
[VideoConf][TEST] Key Timestamp: [T2 - NEW timestamp, different from T1]
[VideoConf][TEST] Is First Participant: true
═══════════════════════════════════════════════════════════
```

**What to Verify:**
- ✅ User D is first participant (participant count = 0)
- ✅ New key generated with NEW timestamp T2
- ✅ T2 timestamp is DIFFERENT from old T1 timestamp
- ✅ Forward secrecy: old session key not reused
- ✅ Clean session start

---

### Test 6: Reconnection ✅

**Objective:** Verify user can reconnect and receive same key

**Setup:**
1. User A, B in call with timestamp T1
2. User A loses network (close WiFi, airplane mode, etc.)
3. User A reconnects after 5 seconds
4. User A opens PreJoin again

**Expected Console Logs (User A reconnecting):**
```
═══════════════════════════════════════════════════════════
[PreJoin][TEST] 🔍 CHECKING PARTICIPANT STATUS
[PreJoin][TEST] Is First Participant: false
[PreJoin][TEST] Participant Count: 1
═══════════════════════════════════════════════════════════

[VideoConf][TEST] 🔑 REQUESTING E2EE KEY
[VideoConf][TEST] Requester ID: [User A ID]
═══════════════════════════════════════════════════════════
```

**Expected Console Logs (User B - responds):**
```
═══════════════════════════════════════════════════════════
[VideoConf][TEST] 📬 HANDLING KEY REQUEST
[VideoConf][TEST] ORIGINAL Timestamp: [T1 - same as before]
[VideoConf][TEST] ✓ Key response sent
═══════════════════════════════════════════════════════════
```

**Expected Console Logs (User A - receives same key):**
```
═══════════════════════════════════════════════════════════
[VideoConf][TEST] 📨 RECEIVED E2EE KEY MESSAGE
[VideoConf][TEST] Timestamp: [T1 - same as original session]
[VideoConf][TEST] ✓ KEY ACCEPTED
[VideoConf][TEST] Updated Timestamp: [T1]
═══════════════════════════════════════════════════════════
```

**What to Verify:**
- ✅ User A reconnects as non-first participant
- ✅ User A receives SAME key with SAME timestamp T1
- ✅ User A can decrypt frames from User B
- ✅ No key mismatch
- ✅ Seamless reconnection

---

## 🔍 Debugging Tips

### If Key Exchange Fails:

1. **Check Signal Protocol:**
   ```
   [MESSAGE_LISTENER][TEST] Message Type: video_e2ee_key_request
   ```
   - Should appear in console when request sent
   - If not, Signal Protocol might not be initialized

2. **Check Timeout:**
   ```
   [VideoConf][TEST] ❌ KEY REQUEST TIMEOUT - No response in 10 seconds
   ```
   - Means no participant responded
   - Check if first participant is still connected
   - Check Signal Protocol encryption/decryption

3. **Check KeyProvider:**
   ```
   [VideoConf][TEST] ⚠️ KeyProvider not available - frame encryption disabled
   ```
   - e2ee.worker.dart.js might not be compiled
   - Run: `cd client && dart compile js -o web/e2ee.worker.dart.js lib/e2ee/e2ee.worker.dart`

4. **Check Socket.IO:**
   ```
   [PreJoin][TEST] ❌ TIMEOUT waiting for participant info
   ```
   - Socket connection might be down
   - Check server logs for Socket.IO events

### Console Filtering:

To focus on E2EE logs only:
```
Filter: [TEST]
```

To see only key exchange:
```
Filter: KEY
```

To see only race conditions:
```
Filter: RACE CONDITION
```

---

## 📈 Success Metrics

After testing, you should see:

✅ **No Compile Errors**  
✅ **No Runtime Errors**  
✅ **All participants converge to same key**  
✅ **All participants have identical timestamp**  
✅ **Race conditions properly resolved (oldest wins)**  
✅ **Forward secrecy working (new keys per session)**  
✅ **Key distribution works when first participant leaves**  
✅ **Reconnection works seamlessly**

---

## 🎯 Next Steps

After testing is complete and all scenarios pass:

1. **Remove Test Logging** (optional - can keep for production debugging)
   - Search for `[TEST]` tags
   - Replace with shorter production logs

2. **Performance Testing**
   - Test with 5+ participants
   - Check memory usage
   - Verify frame encryption performance

3. **Edge Cases**
   - Multiple reconnections
   - Network fluctuations
   - Server restart scenarios

4. **Documentation Update**
   - Update README with E2EE capabilities
   - Document key exchange flow for new developers
   - Add architecture diagrams

---

## 📝 Test Results Template

Use this template to document test results:

```markdown
## Test Results - [Date]

### Environment:
- Browser: Chrome 120 / Firefox 121 / Safari 17
- OS: Windows 11 / macOS 14 / Linux
- Network: WiFi / Ethernet / 4G

### Test 1: Single User ✅ / ❌
- Timestamp generated: [value]
- KeyProvider created: Yes / No
- Notes: [any observations]

### Test 2: Two Users ✅ / ❌
- User A timestamp: [value]
- User B timestamp: [value]
- Timestamps match: Yes / No
- Key exchange time: [seconds]
- Notes: [any observations]

### Test 3: Race Condition ✅ / ❌
- User A timestamp: [value]
- User B timestamp: [value]
- User C timestamp: [value]
- Final consensus timestamp: [value]
- All users converged: Yes / No
- Notes: [any observations]

### Test 4: First Participant Leaves ✅ / ❌
- Original timestamp preserved: Yes / No
- User C received original key: Yes / No
- Notes: [any observations]

### Test 5: New Session ✅ / ❌
- Old timestamp: [value]
- New timestamp: [value]
- Timestamps different: Yes / No
- Notes: [any observations]

### Test 6: Reconnection ✅ / ❌
- Reconnected successfully: Yes / No
- Same timestamp received: Yes / No
- Notes: [any observations]

### Overall Result: PASS / FAIL
```

---

**Happy Testing! 🎉**
