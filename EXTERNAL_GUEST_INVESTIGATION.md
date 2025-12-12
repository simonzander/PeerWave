# External Guest Meeting Join - Investigation Report

**Date:** December 12, 2025  
**Status:** 🔴 MULTIPLE CRITICAL ISSUES FOUND

---

## Executive Summary

External guest admission system has **3 critical failures** preventing proper operation:

1. ❌ **Foreign Key Constraint Error** - Sender keys cannot be stored
2. ❌ **Socket Room Join Failure** - Meeting hosts not receiving notifications
3. ❌ **Meeting ID vs Channel ID Confusion** - Wrong identifier used for encryption

---

## Issue #1: SignalSenderKey Foreign Key Constraint Violation

### Error
```
SQLITE_CONSTRAINT: FOREIGN KEY constraint failed
INSERT INTO `SignalSenderKeys` (`id`,`channel`,`client`,`owner`,`sender_key`,`createdAt`,`updatedAt`)
```

### Root Cause
**Location:** [server/db/model.js](server/db/model.js#L239-L276)

The `SignalSenderKey` model defines:
```javascript
channel: {
    type: DataTypes.UUID,
    allowNull: false,
    references: {
        model: 'Channels',    // ❌ PROBLEM: References Channels table
        key: 'uuid'
    }
}
```

**BUT:** The client is passing a **Meeting ID**, not a Channel UUID!

**Location:** [client/lib/services/signal_service.dart](client/lib/services/signal_service.dart#L4794-L4797)
```dart
SocketService().emit('storeSenderKey', {
    'groupId': groupId,  // This is a MEETING ID for meetings
    'senderKey': senderKeyBase64,
});
```

### Impact
- ✅ Works for **Signal text channels** (they have channel UUIDs)
- ❌ Fails for **meetings** (meetings don't have channel records)
- Guest sender key distribution **completely broken**

### Why This Matters
When a meeting host tries to create a sender key for the meeting to encrypt group messages for guests, the server rejects it because:
1. Meeting ID (e.g., `mtg_abc123`) is passed as `groupId`
2. Server tries to insert into `SignalSenderKeys.channel`
3. Foreign key constraint checks if `mtg_abc123` exists in `Channels.uuid`
4. It doesn't exist → **FOREIGN KEY constraint failed**

---

## Issue #2: Native Client Not Joining Socket Room

### Problem
Native clients (Windows app) are **NOT** joining the Socket.IO room `meeting:${meetingId}`.

### Evidence

**Server Code:** [server/routes/external.js](server/routes/external.js#L115-L125)
```javascript
// Notify meeting participants about waiting guest
if (io) {
    io.to(`meeting:${result.meeting.meeting_id}`).emit('meeting:guest_waiting', {
        session_id: session.session_id,
        // ...
    });
    console.log(`[EXTERNAL] Notified meeting ${result.meeting.meeting_id} about waiting guest: ${display_name}`);
}
```

**Client Code:** [client/lib/views/meeting_video_conference_view.dart](client/lib/views/meeting_video_conference_view.dart#L123-L125)
```dart
// Join socket room for meeting events (admission notifications, etc.)
SocketService().emit('meeting:join-room', {
    'meeting_id': widget.meetingId,
});
```

**Server Handler:** [server/server.js](server/server.js#L3413-L3423)
```javascript
socket.on('meeting:join-room', async (data) => {
    const userId = getUserId();
    if (!userId) return;  // ❌ Might be failing here
    
    const { meeting_id } = data;
    if (!meeting_id) return;
    
    socket.join(`meeting:${meeting_id}`);
    console.log(`[MEETING] User ${userId} joined meeting room: ${meeting_id}`);
});
```

### Hypothesis
1. **Web client** joins room successfully (has session)
2. **Native client** might be failing authentication check (`if (!userId) return;`)
3. No room join → No admission notifications received
4. Guest waits forever, host sees nothing

### Missing Log Evidence
- ❌ No log: `"[MEETING] User {uuid} joined meeting room: {meetingId}"` from native client
- ❌ No evidence that `meeting:join-room` event was received

---

## Issue #3: Conceptual Mismatch - Meetings Are Not Channels

### The Problem
The system treats **meetings** and **signal text channels** as the same thing for encryption, but they're fundamentally different:

| Feature | Signal Text Channel | Meeting |
|---------|-------------------|---------|
| Database Table | `Channels` ✅ | `meetings` (via meetingService) ✅ |
| Has UUID | Yes (channel.uuid) | Yes (meeting.meeting_id) |
| Has SenderKeys | Yes (stored in SignalSenderKeys) | **SHOULD** but can't due to FK constraint |
| LiveKit Integration | No | Yes |
| External Guests | No | Yes |

### Current Architecture Flaw

**SignalSenderKey table** assumes:
- `channel` field references `Channels.uuid`
- All encrypted groups are "channels"

**Reality:**
- Meetings also need sender keys for group encryption
- Meetings are NOT in the Channels table
- Foreign key constraint prevents meeting sender keys

---

## Issue #4: Error Message from Client Log

### Client Error
```
Polling error: TypeError: "<!DOCTYPE html>..." is not a subtype of type 'Map<String, dynamic>'
```

### Analysis
This indicates the Flutter **web** client is receiving HTML instead of JSON from a polling endpoint. This is likely:
1. A failed API request returning the Flutter web index.html
2. Suggests web client routing issues
3. Not directly related to admission system but indicates broader problems

---

## Architecture Issues Summary

### What Works ✅
1. **External session creation** - Guest registers successfully
2. **Session storage** - In-memory database stores guest data
3. **Socket event emission** - Server emits `meeting:guest_waiting`
4. **Admission overlay initialization** - Client widget loads

### What Fails ❌
1. **Sender key storage for meetings** - Foreign key constraint
2. **Native client room join** - No logs indicate successful join
3. **Admission notifications** - Never reach native client
4. **Key exchange completion** - Cannot proceed without sender keys

---

## Data Flow Analysis

### Expected Flow
```
1. Guest enters token → Server validates → Session created
2. Server emits: io.to('meeting:mtg_123').emit('meeting:guest_waiting')
3. Native client in room 'meeting:mtg_123' receives event
4. AdmissionOverlay shows guest
5. Host clicks "Admit"
6. Guest proceeds with key exchange
```

### Actual Flow
```
1. Guest enters token → ✅ Server validates → ✅ Session created
2. Server emits: io.to('meeting:mtg_123').emit('meeting:guest_waiting') ✅
3. Native client: ❌ NOT in room (authentication issue?)
4. AdmissionOverlay: ❌ Never receives event
5. Host: ❌ Sees nothing
6. Guest: Stuck on waiting screen forever
```

### Sender Key Flow (Broken)
```
1. Native client creates sender key for meeting: 'mtg_123'
2. Client emits: storeSenderKey { groupId: 'mtg_123', ... }
3. Server attempts: INSERT INTO SignalSenderKeys (channel='mtg_123', ...)
4. SQLite checks: Does 'mtg_123' exist in Channels.uuid?
5. Result: ❌ NO → FOREIGN KEY constraint failed
6. Error logged, sender key not stored
7. Guest key exchange: ❌ Cannot proceed
```

---

## Root Cause Analysis

### Primary Root Cause: Database Schema Design Flaw

**Problem:** `SignalSenderKeys.channel` has foreign key to `Channels.uuid`

**Why it's wrong:**
- Meetings (`meeting_id`) are valid encryption groups
- Meetings are not in the `Channels` table
- Schema assumes only text channels need group encryption
- Architectural oversight from Phase 8 implementation

### Secondary Root Cause: Socket Room Join Failure

**Problem:** Native client not joining `meeting:${meetingId}` room

**Possible reasons:**
1. Authentication check failing in `meeting:join-room` handler
2. Event not being emitted by native client
3. Timing issue (emitted before socket connected)
4. Native client using different authentication method (HMAC)

---

## Required Fixes

### Fix #1: Database Schema Change (CRITICAL)
**File:** [server/db/model.js](server/db/model.js#L239-L276)

**Option A: Remove Foreign Key (Quick Fix)**
```javascript
const SignalSenderKey = sequelize.define('SignalSenderKey', {
    channel: {
        type: DataTypes.STRING,  // Changed from UUID
        allowNull: false,
        // REMOVED: references to Channels table
    },
    // ... rest of model
});
```

**Option B: Polymorphic Association (Proper Fix)**
```javascript
const SignalSenderKey = sequelize.define('SignalSenderKey', {
    group_id: {
        type: DataTypes.STRING,
        allowNull: false,
    },
    group_type: {
        type: DataTypes.ENUM('channel', 'meeting'),
        allowNull: false,
    },
    // ... rest of model
});
```

### Fix #2: Socket Room Join Debug
**File:** [server/server.js](server/server.js#L3413)

Add extensive logging:
```javascript
socket.on('meeting:join-room', async (data) => {
    console.log('[MEETING:JOIN-ROOM] Event received:', data);
    console.log('[MEETING:JOIN-ROOM] Socket authenticated:', isAuthenticated());
    
    const userId = getUserId();
    console.log('[MEETING:JOIN-ROOM] User ID:', userId);
    
    if (!userId) {
        console.error('[MEETING:JOIN-ROOM] ❌ No user ID - authentication failed');
        return;
    }
    
    const { meeting_id } = data;
    if (!meeting_id) {
        console.error('[MEETING:JOIN-ROOM] ❌ No meeting_id in data');
        return;
    }
    
    socket.join(`meeting:${meeting_id}`);
    console.log(`[MEETING:JOIN-ROOM] ✓ User ${userId} joined room: meeting:${meeting_id}`);
    
    // List all rooms this socket is in
    console.log('[MEETING:JOIN-ROOM] Socket rooms:', Array.from(socket.rooms));
});
```

### Fix #3: Client-Side Logging
**File:** [client/lib/views/meeting_video_conference_view.dart](client/lib/views/meeting_video_conference_view.dart#L123)

```dart
debugPrint('[MeetingVideo] Attempting to join socket room: meeting:${widget.meetingId}');
SocketService().emit('meeting:join-room', {
    'meeting_id': widget.meetingId,
});
debugPrint('[MeetingVideo] ✓ Emitted meeting:join-room event');

// Add confirmation listener
SocketService().on('meeting:room_joined', (data) {
    debugPrint('[MeetingVideo] ✓ Confirmed joined room: $data');
});
```

---

## Testing Plan

### Test 1: Verify Native Client Socket Authentication
1. Start native Windows client
2. Join a meeting as host
3. Check server logs for:
   - `[MEETING:JOIN-ROOM] Event received`
   - `[MEETING:JOIN-ROOM] User {uuid} joined room`
4. If missing → Authentication issue

### Test 2: Verify Guest Session Creation
1. Create meeting invitation
2. Open link in browser (unauthenticated)
3. Enter guest name
4. Check server logs for:
   - `[EXTERNAL] Created session {id} for meeting {meeting_id}`
   - `[EXTERNAL] Notified meeting {meeting_id} about waiting guest`

### Test 3: Verify Room Emission
1. In server, add logging to `io.to(...)` calls
2. Verify which sockets are in room `meeting:${meetingId}`
3. Check if native client socket ID is in the room

### Test 4: Database Schema Fix Verification
1. Remove foreign key constraint
2. Restart server
3. Attempt sender key storage for meeting
4. Should succeed without constraint error

---

## Current Meeting Storage Architecture

### Database: `meetings` table (SQLite)
**Location:** [server/migrations/add_meetings_system.js](server/migrations/add_meetings_system.js)

```sql
CREATE TABLE meetings (
    meeting_id STRING PRIMARY KEY,        -- 'mtg_xxx' or 'call_xxx'
    title STRING NOT NULL,
    created_by STRING NOT NULL,
    start_time DATE NOT NULL,
    end_time DATE NOT NULL,
    is_instant_call BOOLEAN DEFAULT false,  -- TRUE for instant calls
    source_channel_id STRING,               -- Channel origin (for instant calls)
    source_user_id STRING,                  -- Target user (for 1:1 calls)
    allow_external BOOLEAN DEFAULT false,
    invitation_token STRING UNIQUE,
    voice_only BOOLEAN DEFAULT false,
    ...
)
```

### Storage Strategy (Hybrid)
**Scheduled Meetings:** Database (persistent) + Memory (runtime state)
**Instant Calls:** Memory ONLY (no DB writes)

### Key Exchange Types by Channel Type

| Type | Storage | Encryption | Key Distribution |
|------|---------|-----------|------------------|
| **Text Channel** | DB (`Channels` table) | Signal SenderKey | Server stores in `SignalSenderKeys` |
| **Video Channel** | DB (`Channels` table) | Signal SenderKey | Server stores in `SignalSenderKeys` |
| **Meetings** | DB (`meetings` table) | Signal 1:1 PreKey | ❌ **NO STORAGE** - direct exchange |
| **Instant Calls** | Memory only | Signal 1:1 PreKey | ❌ **NO STORAGE** - direct exchange |

---

## Recommendation: DO NOT Create Separate Table

### Analysis

**Current Issue:** `SignalSenderKeys.channel` references `Channels.uuid`, but meetings use `meeting_id` from `meetings` table.

**Why NOT to create a new table:**
1. ✅ Meetings **already have their own table** (`meetings`)
2. ✅ Meetings use **different encryption** (1:1 PreKey, not SenderKey)
3. ✅ Meeting participants exchange keys **directly**, not via server
4. ✅ Instant calls are **memory-only** by design (ephemeral)

**The real problem:** Meetings were **never meant** to use `SignalSenderKeys` table!

---

## Solution: Fix the Misunderstanding

### Current Encryption Design (CORRECT)

**Text/Video Channels (Signal Groups):**
- Use Signal SenderKey protocol
- Server stores SenderKey distribution messages
- Table: `SignalSenderKeys` with FK to `Channels`

**Meetings/Calls (Signal 1:1):**
- Use Signal PreKey protocol (session-based)
- Participants exchange keys **peer-to-peer** via Signal sessions
- **NO server-side SenderKey storage needed**

### Why the Error Occurred

The client code in [signal_service.dart](client/lib/services/signal_service.dart#L4794) tries to store sender keys for meetings:

```dart
// This should ONLY run for text/video CHANNELS, not meetings!
SocketService().emit('storeSenderKey', {
    'groupId': groupId,  // ❌ Passing meeting_id here
    'senderKey': senderKeyBase64,
});
```

**Root Cause:** The client **incorrectly** treats meetings as Signal group chats requiring SenderKeys.

---

## Correct Architecture Fix

### Option 1: Remove SenderKey Storage for Meetings (RECOMMENDED)

**Fix:** Modify client to NOT store sender keys for meetings at all.

**Rationale:**
- Meetings use 1:1 Signal sessions for key exchange
- Each participant has a session with every other participant
- No group SenderKey needed
- Matches Signal Protocol design for small groups

**Implementation:**
```dart
// In signal_service.dart, when creating sender key:
if (groupId.startsWith('mtg_') || groupId.startsWith('call_')) {
    // Skip server storage for meetings - use 1:1 sessions only
    debugPrint('[SIGNAL] Meeting detected, skipping SenderKey storage');
    return;
}

// Only store for channels
SocketService().emit('storeSenderKey', {
    'groupId': groupId,
    'senderKey': senderKeyBase64,
});
```

### Option 2: Remove Foreign Key Constraint (QUICK FIX)

**Fix:** Make `SignalSenderKeys.channel` accept ANY string ID.

```javascript
const SignalSenderKey = sequelize.define('SignalSenderKey', {
    channel: {
        type: DataTypes.STRING,  // Changed from UUID
        allowNull: false,
        // REMOVED: Foreign key reference
    },
    // ...
});
```

**Pros:**
- Quick fix, unblocks development
- Allows storing sender keys for meetings

**Cons:**
- Meetings don't actually need SenderKeys (1:1 sessions suffice)
- Wastes storage
- Conceptual mismatch

### Option 3: Polymorphic Reference (OVER-ENGINEERED)

**Fix:** Add `group_type` field to distinguish channels from meetings.

**Verdict:** ❌ **NOT RECOMMENDED** - Adds complexity for no benefit since meetings shouldn't use SenderKeys anyway.

---

## Recommended Solution

### Step 1: Fix Foreign Key Constraint (Immediate)
Remove FK constraint to unblock development:

**File:** [server/db/model.js](server/db/model.js#L239-L276)
```javascript
const SignalSenderKey = sequelize.define('SignalSenderKey', {
    channel: {
        type: DataTypes.STRING,  // Accept any identifier
        allowNull: false,
        // No foreign key - can be channel UUID or meeting_id
    },
    // ... rest unchanged
});
```

### Step 2: Update Client Logic (Proper Fix)
Prevent meetings from using SenderKey protocol:

**File:** [client/lib/services/signal_service.dart](client/lib/services/signal_service.dart#L4790-L4800)
```dart
// Check if this is a meeting (starts with 'mtg_' or 'call_')
final isMeeting = groupId.startsWith('mtg_') || groupId.startsWith('call_');

if (!isMeeting && serialized.isNotEmpty) {
    // Only store sender keys for actual channels
    SocketService().emit('storeSenderKey', {
        'groupId': groupId,
        'senderKey': senderKeyBase64,
    });
}
```

### Step 3: Document Architecture
Add comments clarifying:
- Channels use SenderKey (group encryption)
- Meetings use 1:1 sessions (peer-to-peer encryption)
- External guests exchange keys via temporary sessions

---

## Conclusion

The external guest admission system has **fundamental architectural issues**:

1. **Database schema** doesn't support meetings as encryption groups
2. **Socket room membership** is not being established for native clients  
3. **Notification delivery** fails due to missing room membership
4. **Meetings incorrectly use SenderKey protocol** instead of 1:1 sessions

**Priority:** 
1. Fix database schema FIRST (remove FK constraint)
2. Update client to skip SenderKey for meetings
3. Debug socket room join issue

**Expected Timeline:**
- Schema fix: 15 minutes
- Client logic update: 30 minutes
- Socket debug: 30-60 minutes (requires log analysis)
- Full testing: 30 minutes

**Success Criteria:**
- ✅ Sender keys can be stored for meetings (or skipped entirely)
- ✅ Native client receives `meeting:guest_waiting` events
- ✅ Admission overlay displays waiting guests
- ✅ Guest can be admitted and join meeting
- ✅ Meeting encryption uses 1:1 sessions (not SenderKey)
