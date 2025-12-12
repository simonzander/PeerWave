# External Guest Join with E2EE - Implementation Plan

**Date:** December 11, 2024  
**Status:** Ready for Implementation  
**Estimated Time:** 8-10 hours

---

## 🎯 Overview

Implement Flutter web-based guest join flow for meetings with full E2EE support using Signal Protocol. Guests will generate their own identity keys, pre-keys, and establish encrypted sessions with server participants.

---

## ✅ Requirements Summary (From User Answers)

### Authentication & Routing
- ✅ Authenticated users → redirect to `/app/meetings` (overview page)
- ✅ Unauthenticated users → serve Flutter web app at `/join/meeting/:token`
- ✅ Use GoRouter for routing (standard Flutter navigation)
- ✅ Authenticated users cannot join as guest (always redirected)

### Key Management
- ✅ Use **sessionStorage** (web-only, cross-tab isolation)
- ✅ **No expiration** for identity keys and pre-keys (except signed pre-key = 7 days)
- ✅ Reuse keys across multiple meetings within same browser tab
- ✅ Validate signed pre-key age before reuse (max 7 days)
- ✅ Generate new signed pre-key if expired
- ✅ Generate keys **BEFORE** display name entry (with progress bar like Signal setup)
- ✅ One session per browser tab (kick previous if same tab used again)

### Pre-Key Management
- ✅ **Automatic replenishment** when < 10 pre-keys remaining
- ✅ **Track used pre-keys** (standard Signal flow):
  - Server: Delete pre-key from memory when consumed by participant
  - Guest: Delete pre-key locally after decrypting message
  - Guest: Check server for remaining pre-keys periodically
  - Guest: Upload new batch (30 keys) when threshold reached

### Meeting Join Flow
- ✅ **Block guest join** until at least one server user in meeting
- ✅ Show "Waiting for host..." message with retry button
- ✅ No list of expected participants shown
- ✅ **Waiting room:** Guest sees only "waiting" screen (no video/audio feed)
- ✅ **Admission:** Any server participant can admit/decline (not other guests)
- ✅ **Simultaneous admits:** First-come-first-serve (race condition handled by server)

### E2EE Behavior
- ✅ **Mid-meeting join:** Guests receive existing sender keys from participants
- ✅ **All server users leave:** Hold meeting open until guest also leaves
- ✅ **No participant limit:** Unlimited external guests allowed per meeting
- ✅ **Security:** Identity key reuse acceptable (guests tagged, token required, server user must be present)

---

## 📋 Implementation Phases

### **Phase 1: Server Route Update** (30 mins)

**File:** `server/server.js`

**Task:** Update `/join/meeting/:token` route to check authentication

**Implementation:**
```javascript
app.get('/join/meeting/:token', async (req, res) => {
  const { token } = req.params;
  
  // Validate token format
  if (!token || token.length !== 32) {
    return res.status(400).send('<h1>Invalid invitation link</h1>');
  }
  
  // Check if user is authenticated (HMAC session)
  const sessionCookie = req.cookies['session_id'];
  const hmacToken = req.headers['x-hmac-token'];
  
  let isAuthenticated = false;
  if (sessionCookie || hmacToken) {
    try {
      const userId = await verifyAuthEither(req);
      isAuthenticated = !!userId;
    } catch (err) {
      isAuthenticated = false;
    }
  }
  
  if (isAuthenticated) {
    // Redirect to meetings overview (don't assume user is invited)
    return res.redirect('/app/meetings');
  }
  
  // Serve Flutter web app for unauthenticated guests
  const webAppPath = path.join(__dirname, '../client/build/web/index.html');
  res.sendFile(webAppPath);
});
```

**Deliverable:** Authenticated users redirected to `/app/meetings`, guests get Flutter web app

---

### **Phase 2: E2EE Key Generation View** (2 hours)

**New File:** `client/lib/views/external_key_setup_view.dart`

**Purpose:** Signal-style setup screen that generates E2EE keys before name entry

**Features:**
- Progress bar with steps:
  1. "Checking existing keys..." (check sessionStorage)
  2. "Generating identity keys..." (if needed)
  3. "Generating signed pre-key..." (if needed or expired)
  4. "Generating pre-keys..." (if needed or < 30)
  5. "Validating keys..." (check signed pre-key age)
- Animated progress indicator
- Automatic navigation to name entry when complete

**sessionStorage Keys:**
```javascript
{
  "external_identity_key_public": "base64...",
  "external_identity_key_private": "base64...",
  "external_signed_pre_key": {
    "id": 1,
    "publicKey": "base64...",
    "signature": "base64...",
    "timestamp": 1733932800000  // Unix timestamp
  },
  "external_pre_keys": [
    { "id": 0, "publicKey": "base64..." },
    { "id": 1, "publicKey": "base64..." },
    ...  // 30 keys total
  ],
  "external_next_pre_key_id": 30  // For generating additional keys
}
```

**Key Reuse Logic:**
```dart
Future<void> _initializeKeys() async {
  setState(() => _currentStep = 'Checking existing keys...');
  
  final storedIdentity = sessionStorage['external_identity_key_public'];
  final storedSignedPre = sessionStorage['external_signed_pre_key'];
  final storedPreKeys = sessionStorage['external_pre_keys'];
  
  bool needNewIdentity = storedIdentity == null;
  bool needNewSignedPre = false;
  bool needNewPreKeys = false;
  
  // Check signed pre-key age (7 days max)
  if (storedSignedPre != null) {
    final signedPreJson = jsonDecode(storedSignedPre);
    final timestamp = signedPreJson['timestamp'] as int;
    final age = DateTime.now().millisecondsSinceEpoch - timestamp;
    final daysSinceCreation = age / (1000 * 60 * 60 * 24);
    
    if (daysSinceCreation > 7) {
      needNewSignedPre = true;
    }
  } else {
    needNewSignedPre = true;
  }
  
  // Check pre-keys count
  if (storedPreKeys != null) {
    final preKeysJson = jsonDecode(storedPreKeys) as List;
    if (preKeysJson.length < 30) {
      needNewPreKeys = true;
    }
  } else {
    needNewPreKeys = true;
  }
  
  // Generate only what's needed
  if (needNewIdentity) {
    await _generateIdentityKey();
  }
  
  if (needNewSignedPre) {
    await _generateSignedPreKey();
  }
  
  if (needNewPreKeys) {
    await _generatePreKeys();
  }
  
  setState(() => _currentStep = 'Setup complete!');
  await Future.delayed(Duration(milliseconds: 500));
  _navigateToNameEntry();
}
```

**Deliverable:** E2EE key setup screen with progress bar, automatic key reuse validation

---

### **Phase 3: Enhanced ExternalPreJoinView** (2 hours)

**File:** `client/lib/views/external_prejoin_view.dart`

**Changes:**

1. **Add Device Selection UI** (from `MeetingPreJoinView`):
   - Camera preview with `RTCVideoView`
   - Device dropdowns (cameras, microphones)
   - Audio/video toggle buttons
   - Permission request flow

2. **Add "Waiting for Host" State:**
   ```dart
   enum PreJoinState {
     enteringName,      // Display name form
     checkingMeeting,   // Checking if server users present
     waitingForHost,    // Blocked - no server users yet
     joiningMeeting,    // Uploading keys + joining
     waitingAdmission,  // In waiting room
   }
   ```

3. **Server User Detection:**
   ```dart
   Future<bool> _hasServerParticipants() async {
     try {
       final response = await ApiService.get(
         '/api/meetings/${widget.meetingId}/participants',
         queryParameters: {'status': 'joined', 'exclude_external': 'true'}
       );
       
       final participants = response.data as List;
       return participants.isNotEmpty;
     } catch (e) {
       return false;
     }
   }
   
   Future<void> _handleJoin() async {
     setState(() => _state = PreJoinState.checkingMeeting);
     
     // Check if server users present
     final hasServerUsers = await _hasServerParticipants();
     
     if (!hasServerUsers) {
       setState(() => _state = PreJoinState.waitingForHost);
       _startPollingForHost(); // Poll every 5s
       return;
     }
     
     // Proceed with join
     await _uploadKeysAndJoin();
   }
   ```

4. **Upload E2EE Keys:**
   ```dart
   Future<void> _uploadKeysAndJoin() async {
     setState(() => _state = PreJoinState.joiningMeeting);
     
     // Read from sessionStorage
     final identityPublic = sessionStorage['external_identity_key_public']!;
     final signedPreKey = jsonDecode(sessionStorage['external_signed_pre_key']!);
     final preKeys = jsonDecode(sessionStorage['external_pre_keys']!) as List;
     
     // Register session with E2EE keys
     final session = await _externalService.joinMeeting(
       invitationToken: widget.invitationToken,
       displayName: _nameController.text.trim(),
       identityKeyPublic: identityPublic,
       signedPreKey: signedPreKey,
       preKeys: preKeys,
     );
     
     // Save session to sessionStorage
     sessionStorage['external_session_id'] = session.sessionId;
     
     setState(() => _state = PreJoinState.waitingAdmission);
   }
   ```

**Deliverable:** Full prejoin flow with host detection, device selection, key upload

---

### **Phase 4: Server Key Storage & Tracking** (1.5 hours)

**File:** `server/services/externalParticipantService.js`

**Changes:**

1. **Update `createSession()` to Store Keys:**
   ```javascript
   async createSession(meetingId, displayName, keys) {
     const sessionId = uuidv4();
     
     const session = {
       session_id: sessionId,
       meeting_id: meetingId,
       display_name: displayName,  // Encrypted by client before sending
       identity_key_public: keys.identityKeyPublic,
       signed_pre_key: JSON.stringify(keys.signedPreKey),
       pre_keys: JSON.stringify(keys.preKeys),  // Array of 30 keys
       admission_status: 'waiting',
       expires_at: new Date(Date.now() + 24 * 60 * 60 * 1000),  // 24h
       created_at: new Date(),
     };
     
     await db.query('INSERT INTO external_participants ...', session);
     
     // Also store in memory for fast access
     this.sessions.set(sessionId, session);
     
     return session;
   }
   ```

2. **Add Pre-Key Consumption:**
   ```javascript
   async consumePreKey(sessionId, preKeyId) {
     const session = this.sessions.get(sessionId);
     if (!session) throw new Error('Session not found');
     
     const preKeys = JSON.parse(session.pre_keys);
     const index = preKeys.findIndex(k => k.id === preKeyId);
     
     if (index === -1) throw new Error('Pre-key not found');
     
     // Remove consumed key
     preKeys.splice(index, 1);
     session.pre_keys = JSON.stringify(preKeys);
     
     // Update database
     await db.query(
       'UPDATE external_participants SET pre_keys = ? WHERE session_id = ?',
       [session.pre_keys, sessionId]
     );
     
     return { remainingCount: preKeys.length };
   }
   ```

3. **Add Pre-Key Replenishment:**
   ```javascript
   async replenishPreKeys(sessionId, newPreKeys) {
     const session = this.sessions.get(sessionId);
     if (!session) throw new Error('Session not found');
     
     const existingKeys = JSON.parse(session.pre_keys);
     const allKeys = [...existingKeys, ...newPreKeys];
     
     session.pre_keys = JSON.stringify(allKeys);
     
     await db.query(
       'UPDATE external_participants SET pre_keys = ? WHERE session_id = ?',
       [session.pre_keys, sessionId]
     );
     
     return { totalCount: allKeys.length };
   }
   ```

4. **Add Get Remaining Keys:**
   ```javascript
   async getRemainingPreKeyCount(sessionId) {
     const session = this.sessions.get(sessionId);
     if (!session) throw new Error('Session not found');
     
     const preKeys = JSON.parse(session.pre_keys);
     return { count: preKeys.length, keys: preKeys };
   }
   ```

**File:** `server/routes/external.js`

**Add New Endpoints:**
```javascript
// Consume pre-key (called by server participants when establishing session)
router.post('/meetings/external/session/:sessionId/consume-prekey', verifyAuthEither, async (req, res) => {
  try {
    const { sessionId } = req.params;
    const { preKeyId } = req.body;
    
    const result = await externalService.consumePreKey(sessionId, preKeyId);
    res.json(result);
  } catch (error) {
    res.status(400).json({ error: error.message });
  }
});

// Replenish pre-keys (called by guest client when < 10 remaining)
router.post('/meetings/external/session/:sessionId/prekeys', async (req, res) => {
  try {
    const { sessionId } = req.params;
    const { preKeys } = req.body;
    
    const result = await externalService.replenishPreKeys(sessionId, preKeys);
    res.json(result);
  } catch (error) {
    res.status(400).json({ error: error.message });
  }
});

// Get remaining pre-key count (called by guest to check if replenishment needed)
router.get('/meetings/external/session/:sessionId/prekeys', async (req, res) => {
  try {
    const { sessionId } = req.params;
    const result = await externalService.getRemainingPreKeyCount(sessionId);
    res.json(result);
  } catch (error) {
    res.status(400).json({ error: error.message });
  }
});
```

**Deliverable:** Server tracks pre-key consumption, supports replenishment

---

### **Phase 5: Guest Pre-Key Monitoring** (1 hour)

**File:** `client/lib/services/external_participant_service.dart`

**Add Pre-Key Monitoring:**
```dart
class ExternalParticipantService {
  Timer? _preKeyMonitorTimer;
  static const int PRE_KEY_THRESHOLD = 10;
  static const int PRE_KEY_BATCH_SIZE = 30;
  
  void startPreKeyMonitoring(String sessionId) {
    // Check every 30 seconds
    _preKeyMonitorTimer = Timer.periodic(Duration(seconds: 30), (timer) async {
      await _checkAndReplenishPreKeys(sessionId);
    });
  }
  
  void stopPreKeyMonitoring() {
    _preKeyMonitorTimer?.cancel();
    _preKeyMonitorTimer = null;
  }
  
  Future<void> _checkAndReplenishPreKeys(String sessionId) async {
    try {
      // Get remaining count from server
      final response = await ApiService.get(
        '/api/meetings/external/session/$sessionId/prekeys'
      );
      
      final remainingCount = response.data['count'] as int;
      
      if (remainingCount < PRE_KEY_THRESHOLD) {
        debugPrint('[GUEST] Pre-keys low ($remainingCount), replenishing...');
        await _replenishPreKeys(sessionId);
      }
    } catch (e) {
      debugPrint('[GUEST] Pre-key check failed: $e');
    }
  }
  
  Future<void> _replenishPreKeys(String sessionId) async {
    // Get next ID from sessionStorage
    final nextIdStr = sessionStorage['external_next_pre_key_id'] ?? '30';
    final nextId = int.parse(nextIdStr);
    
    // Generate new batch
    final newPreKeys = await SignalProtocol.generatePreKeys(
      startId: nextId,
      count: PRE_KEY_BATCH_SIZE,
    );
    
    // Upload to server
    await ApiService.post(
      '/api/meetings/external/session/$sessionId/prekeys',
      data: {'preKeys': newPreKeys},
    );
    
    // Update local storage
    final existingKeys = jsonDecode(sessionStorage['external_pre_keys']!) as List;
    final allKeys = [...existingKeys, ...newPreKeys];
    sessionStorage['external_pre_keys'] = jsonEncode(allKeys);
    sessionStorage['external_next_pre_key_id'] = (nextId + PRE_KEY_BATCH_SIZE).toString();
    
    debugPrint('[GUEST] Uploaded $PRE_KEY_BATCH_SIZE new pre-keys');
  }
  
  // Called when guest decrypts message with pre-key
  Future<void> onPreKeyUsed(int preKeyId) async {
    final preKeysStr = sessionStorage['external_pre_keys'];
    if (preKeysStr == null) return;
    
    final preKeys = jsonDecode(preKeysStr) as List;
    preKeys.removeWhere((k) => k['id'] == preKeyId);
    
    sessionStorage['external_pre_keys'] = jsonEncode(preKeys);
    debugPrint('[GUEST] Removed used pre-key $preKeyId (${preKeys.length} remaining)');
  }
}
```

**Deliverable:** Automatic pre-key replenishment when threshold reached

---

### **Phase 6: Admission Flow Integration** (2 hours)

**File:** `client/lib/widgets/admission_overlay.dart`

**Changes:**

1. **Update to Support Any Participant Admit/Decline:**
   ```dart
   // Remove permission checks - any server participant can admit
   ElevatedButton(
     onPressed: () => _admitGuest(guest.sessionId),
     child: Text('Admit'),
   ),
   ElevatedButton(
     onPressed: () => _declineGuest(guest.sessionId),
     child: Text('Decline'),
   ),
   ```

2. **Handle First-Come-First-Serve:**
   ```dart
   Future<void> _admitGuest(String sessionId) async {
     try {
       await ApiService.post(
         '/api/meetings/${widget.meetingId}/external/$sessionId/admit'
       );
       
       // Server will broadcast to all - no local state change needed
       // If another participant admitted first, server returns 409
     } catch (e) {
       if (e.toString().contains('409')) {
         ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text('Guest already admitted by another participant'))
         );
       }
     }
   }
   ```

**File:** `server/routes/external.js`

**Update Admit/Decline Endpoints:**
```javascript
router.post('/meetings/:meetingId/external/:sessionId/admit', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId, sessionId } = req.params;
    const userId = req.user.userId;
    
    // Check if session already admitted/declined
    const session = await externalService.getSession(sessionId);
    if (session.admission_status !== 'waiting') {
      return res.status(409).json({ 
        error: 'Guest already ' + session.admission_status,
        admittedBy: session.admitted_by 
      });
    }
    
    // Admit (first-come-first-serve)
    await externalService.updateAdmissionStatus(sessionId, 'admitted', userId);
    
    // Broadcast to guest
    io.to(`meeting:${meetingId}`).emit('meeting:guest_admitted', {
      sessionId,
      admittedBy: userId,
    });
    
    res.json({ success: true });
  } catch (error) {
    res.status(400).json({ error: error.message });
  }
});
```

**Deliverable:** Any server participant can admit, race conditions handled

---

### **Phase 7: E2EE Key Exchange with Guests** (2 hours)

**File:** `client/lib/services/video_conference_service.dart`

**Add Guest Key Exchange:**
```dart
Future<void> establishSessionWithGuest(String sessionId) async {
  try {
    // Fetch guest's public keys
    final response = await ApiService.get(
      '/api/meetings/external/keys/$sessionId'
    );
    
    final guestKeys = response.data;
    final identityKey = guestKeys['identity_key_public'];
    final signedPreKey = guestKeys['signed_pre_key'];
    final preKeys = guestKeys['pre_keys'] as List;
    
    // Select a pre-key (take first available)
    if (preKeys.isEmpty) {
      throw Exception('Guest has no pre-keys available');
    }
    
    final preKey = preKeys[0];
    
    // Establish Signal session
    await SignalProtocol.processPreKeyBundle(
      sessionId: sessionId,
      identityKey: identityKey,
      signedPreKey: signedPreKey,
      preKey: preKey,
    );
    
    // Notify server to consume the pre-key
    await ApiService.post(
      '/api/meetings/external/session/$sessionId/consume-prekey',
      data: {'preKeyId': preKey['id']},
    );
    
    // Send encrypted sender key to guest via Socket.IO
    final senderKey = await E2EEService.instance.getSenderKey(meetingId);
    final encryptedSenderKey = await SignalProtocol.encrypt(
      sessionId: sessionId,
      message: senderKey,
    );
    
    SocketService().emit('meeting:sender_key', {
      'meetingId': meetingId,
      'recipientSessionId': sessionId,
      'encryptedSenderKey': encryptedSenderKey,
    });
    
    debugPrint('[E2EE] Session established with guest $sessionId');
  } catch (e) {
    debugPrint('[E2EE] Failed to establish session with guest: $e');
  }
}
```

**File:** `client/lib/views/external_prejoin_view.dart`

**Add Sender Key Reception:**
```dart
void _setupSenderKeyListener() {
  SocketService().on('meeting:sender_key', (data) async {
    if (data['recipientSessionId'] != _sessionId) return;
    
    try {
      // Decrypt sender key
      final encryptedKey = data['encryptedSenderKey'];
      final senderKey = await SignalProtocol.decrypt(
        sessionId: data['senderUserId'],  // Server participant's ID
        ciphertext: encryptedKey,
      );
      
      // Store sender key for group decryption
      await E2EEService.instance.storeSenderKey(
        meetingId: widget.meetingId,
        userId: data['senderUserId'],
        senderKey: senderKey,
      );
      
      debugPrint('[GUEST] Received sender key from ${data['senderUserId']}');
      
      // Check if pre-key was used and remove it locally
      if (data['preKeyId'] != null) {
        await _externalService.onPreKeyUsed(data['preKeyId']);
      }
    } catch (e) {
      debugPrint('[GUEST] Failed to decrypt sender key: $e');
    }
  });
}
```

**Socket.IO Event Handler (Server):**
```javascript
// In server/server.js
socket.on('meeting:sender_key', (data) => {
  const { meetingId, recipientSessionId, encryptedSenderKey } = data;
  
  // Forward to specific guest session
  io.to(`session:${recipientSessionId}`).emit('meeting:sender_key', {
    senderUserId: socket.userId,
    meetingId,
    recipientSessionId,
    encryptedSenderKey,
  });
});

// When guest joins, join their session room
socket.on('meeting:guest_register', async (data) => {
  const { sessionId } = data;
  socket.join(`session:${sessionId}`);
});
```

**Deliverable:** Full E2EE key exchange between server users and guests

---

### **Phase 8: Mid-Meeting Sender Key Distribution** (1 hour)

**File:** `client/lib/services/video_conference_service.dart`

**Add Guest Late-Join Handler:**
```dart
// Called when guest is admitted to active meeting
Future<void> distributeExistingSenderKeys(String guestSessionId) async {
  try {
    // Get all participants who have sender keys
    final participants = await _getParticipantsWithSenderKeys();
    
    for (final participant in participants) {
      // Establish session with guest
      await establishSessionWithGuest(guestSessionId);
      
      // Send our sender key to guest
      final senderKey = await E2EEService.instance.getSenderKey(meetingId);
      final encryptedSenderKey = await SignalProtocol.encrypt(
        sessionId: guestSessionId,
        message: senderKey,
      );
      
      SocketService().emit('meeting:sender_key', {
        'meetingId': meetingId,
        'recipientSessionId': guestSessionId,
        'encryptedSenderKey': encryptedSenderKey,
      });
    }
    
    debugPrint('[E2EE] Distributed existing sender keys to guest $guestSessionId');
  } catch (e) {
    debugPrint('[E2EE] Failed to distribute sender keys: $e');
  }
}

// Listen for guest admission
void _setupGuestAdmissionListener() {
  SocketService().on('meeting:guest_admitted', (data) async {
    final sessionId = data['sessionId'];
    
    // All participants send their sender keys to the new guest
    await distributeExistingSenderKeys(sessionId);
  });
}
```

**Deliverable:** Guests receive all sender keys when joining mid-meeting

---

### **Phase 9: Flutter Web Route Configuration** (30 mins)

**File:** `client/lib/main.dart`

**Add Routes:**
```dart
// In GoRouter routes list
GoRoute(
  path: '/key-setup/:token',
  name: 'key-setup',
  builder: (context, state) {
    final token = state.pathParameters['token']!;
    return ExternalKeySetupView(
      invitationToken: token,
      onComplete: () {
        context.go('/join/$token');
      },
    );
  },
),

GoRoute(
  path: '/join/:token',
  name: 'external-join',
  builder: (context, state) {
    final token = state.pathParameters['token']!;
    return ExternalPreJoinView(
      invitationToken: token,
      onAdmitted: () {
        // Navigate to video conference
        final meetingId = sessionStorage['external_meeting_id'];
        context.go('/meeting/$meetingId/video');
      },
      onDeclined: () {
        // Show declined message and close
        context.go('/join-declined');
      },
    );
  },
),

GoRoute(
  path: '/join-declined',
  name: 'join-declined',
  builder: (context, state) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.block, size: 80, color: Colors.red),
            SizedBox(height: 24),
            Text(
              'Access Denied',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text('The meeting host declined your request to join.'),
            SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => window.close(),
              child: Text('Close'),
            ),
          ],
        ),
      ),
    );
  },
),
```

**Update Initial Route Logic:**
```dart
// In main.dart, update initialLocation logic
String _getInitialLocation() {
  final uri = Uri.base;
  
  // Check if URL is /join/meeting/:token
  if (uri.pathSegments.isNotEmpty && 
      uri.pathSegments[0] == 'join' && 
      uri.pathSegments[1] == 'meeting' &&
      uri.pathSegments.length == 3) {
    final token = uri.pathSegments[2];
    return '/key-setup/$token';  // Start with key generation
  }
  
  // Default to login check
  return '/';
}
```

**Deliverable:** Flutter web routing for guest join flow

---

### **Phase 10: Meeting Persistence on Guest Join** (30 mins)

**File:** `server/services/meetingCleanupService.js`

**Update Cleanup Logic:**
```javascript
async cleanupOrphanedInstantCalls() {
  try {
    // Get all instant calls
    const calls = await db.query(`
      SELECT m.meeting_id, m.created_at,
             COUNT(CASE WHEN mp.status = 'joined' AND mp.left_at IS NULL THEN 1 END) as active_count,
             COUNT(CASE WHEN ep.admission_status = 'admitted' THEN 1 END) as guest_count
      FROM meetings m
      LEFT JOIN meeting_participants mp ON m.meeting_id = mp.meeting_id
      LEFT JOIN external_participants ep ON m.meeting_id = ep.meeting_id
      WHERE m.is_instant_call = 1
        AND m.status != 'cancelled'
      GROUP BY m.meeting_id
    `);
    
    let deletedCount = 0;
    
    for (const call of calls) {
      const totalActive = call.active_count + call.guest_count;
      
      // Only delete if NO participants (server or guest) remain
      if (totalActive === 0) {
        const lastActivity = await this._getLastActivityTime(call.meeting_id);
        const minutesSinceActivity = (Date.now() - lastActivity) / (1000 * 60);
        
        // Delete if abandoned for > 10 minutes OR > 8 hours old
        if (minutesSinceActivity > 10 || this._isOlderThan8Hours(call.created_at)) {
          await db.query('DELETE FROM meetings WHERE meeting_id = ?', [call.meeting_id]);
          deletedCount++;
        }
      }
    }
    
    if (deletedCount > 0) {
      console.log(`[MEETING_CLEANUP] Deleted ${deletedCount} orphaned instant calls`);
    }
  } catch (error) {
    console.error('[MEETING_CLEANUP] Error:', error);
  }
}
```

**Deliverable:** Meeting stays open while any guest or server user is present

---

## 🔍 Additional Questions & Clarifications

### 1. **Progress Bar Design**
**Question:** Should the key setup progress bar show:
- A) Step-by-step with text ("Generating identity keys...", "Generating pre-keys...")
- B) Single progress bar with percentage (0% → 100%)
- C) Signal-style animated spinner with single message

**Recommendation:** Option A - More transparent and helps users understand E2EE setup

---

### 2. **Key Setup Error Handling**
**Question:** If key generation fails (e.g., crypto API unavailable):
- A) Show error and block join completely
- B) Retry automatically (max 3 attempts)
- C) Offer "Skip E2EE" option (join without encryption)

**Recommendation:** Option B - Auto-retry with fallback to error message

---

### 3. **Pre-Key Upload Timing**
**Question:** When should guest upload pre-keys to server?
- A) Immediately after generation (during key setup)
- B) Only when clicking "Join" (with display name)
- C) After admission approval

**Recommendation:** Option B - Upload with display name to reduce abandoned sessions

---

### 4. **Guest Session Cleanup**
**Question:** When should guest session be deleted from server?
- A) Immediately when guest leaves meeting
- B) After 24 hours (current expiration)
- C) When browser tab closes (no way to detect reliably)

**Recommendation:** Option A - Delete on leave, with 24h fallback for abandoned sessions

---

### 5. **Multi-Tab Warning**
**Question:** If guest opens invitation link in new tab while already joined:
- A) Show warning: "Already joined in another tab. Close that tab first."
- B) Silently kick previous session and join with new one
- C) Allow both (share same session_id with synchronized state)

**Recommendation:** Option A - Prevent confusion, clearer UX

---

### 6. **Server Participant Leaves & Rejoins**
**Question:** If all server users leave but guest remains, then server user rejoins:
- A) Meeting stays open, new server user establishes new session with guest
- B) Meeting auto-ends when last server user leaves (kick guest)
- C) Guest promoted to "temporary host" until server user returns

**Recommendation:** Option A - Meeting stays open (per user requirement), new E2EE session established

---

### 7. **Guest Display Name Encryption**
**Question:** Should guest display name be encrypted before upload?
- A) Yes - Encrypt with meeting's group key (requires server user present)
- B) No - Store plaintext (visible to all server participants)
- C) Yes - Encrypt with per-participant session keys

**Recommendation:** Option B - Plaintext for admission UI, can encrypt later if needed

---

### 8. **Waiting Room Time Limit**
**Question:** How long should guest wait for admission before timeout?
- A) No timeout - wait indefinitely
- B) 5 minutes - auto-decline after timeout
- C) Until meeting ends - auto-decline if meeting cancelled

**Recommendation:** Option C - Wait until meeting ends, show "Meeting cancelled" if needed

---

### 9. **Pre-Key Replenishment Notification**
**Question:** Should guest see notification when pre-keys are replenished?
- A) Yes - Toast notification: "Security keys refreshed"
- B) No - Silent background operation
- C) Only show if replenishment fails

**Recommendation:** Option B - Silent operation, only notify on error

---

### 10. **Identity Key Rotation**
**Question:** Should identity keys ever be rotated (not just reused)?
- A) Yes - Force new identity every 30 days
- B) Yes - Force new identity every meeting
- C) No - Reuse until browser data cleared

**Recommendation:** Option C - Reuse indefinitely (per user requirement), rotation not needed for guests

---

## 📊 Implementation Checklist

### Backend
- [ ] Update `/join/meeting/:token` route with auth check
- [ ] Add pre-key consumption endpoint (`POST /session/:id/consume-prekey`)
- [ ] Add pre-key replenishment endpoint (`POST /session/:id/prekeys`)
- [ ] Add get remaining keys endpoint (`GET /session/:id/prekeys`)
- [ ] Update admission endpoints for first-come-first-serve
- [ ] Update meeting cleanup to respect guest participants
- [ ] Add Socket.IO handler for sender key distribution
- [ ] Test pre-key tracking (consumption + replenishment)

### Frontend - Key Setup
- [ ] Create `ExternalKeySetupView` with progress bar
- [ ] Implement sessionStorage key reuse logic
- [ ] Add signed pre-key age validation (7 days)
- [ ] Generate missing keys only (incremental generation)
- [ ] Auto-navigate to prejoin when setup complete

### Frontend - PreJoin
- [ ] Add device selection UI (camera preview, dropdowns)
- [ ] Implement server user detection (`_hasServerParticipants()`)
- [ ] Add "Waiting for Host" state with retry
- [ ] Upload E2EE keys with session registration
- [ ] Add waiting room state (no video feed)

### Frontend - E2EE
- [ ] Implement pre-key monitoring service (30s polling)
- [ ] Add automatic pre-key replenishment (< 10 threshold)
- [ ] Handle pre-key deletion on message decrypt
- [ ] Implement sender key reception from server users
- [ ] Add mid-meeting sender key distribution
- [ ] Test guest-to-server and server-to-guest encryption

### Frontend - Routing
- [ ] Add `/key-setup/:token` route
- [ ] Add `/join/:token` route
- [ ] Add `/join-declined` route
- [ ] Update initial location logic for `/join/meeting/:token`

### Testing
- [ ] Test authenticated user redirect to `/app/meetings`
- [ ] Test unauthenticated guest flow (full E2EE setup)
- [ ] Test key reuse across multiple meetings
- [ ] Test signed pre-key expiration (7 days)
- [ ] Test pre-key replenishment when < 10 remaining
- [ ] Test admission race condition (multiple admits)
- [ ] Test guest blocked until server user joins
- [ ] Test mid-meeting join (sender key distribution)
- [ ] Test meeting persistence with guest-only participants
- [ ] Test multi-tab session conflict

---

## 🎯 Success Criteria

✅ **Authentication:**
- Authenticated users redirected to `/app/meetings`
- Unauthenticated users see Flutter web app

✅ **E2EE Key Generation:**
- Progress bar shows key generation steps
- Keys reused if valid in sessionStorage
- Signed pre-key regenerated after 7 days
- Pre-keys replenished automatically when < 10

✅ **Guest Join Flow:**
- Guest blocked until server user present
- Device selection working (camera preview, dropdowns)
- E2EE keys uploaded with session registration
- Waiting room shows no video/audio feed

✅ **Admission:**
- Any server participant can admit/decline
- First-come-first-serve on simultaneous admits
- Guest receives sender keys after admission
- Guest can decrypt all encrypted messages

✅ **Mid-Meeting Join:**
- Guest receives all existing sender keys
- Server users establish session with guest
- Guest pre-keys consumed and tracked

✅ **Meeting Persistence:**
- Meeting stays open while any guest present
- Meeting deleted only when all (server + guest) leave

---

## ⏱️ Estimated Timeline

| Phase | Task | Time |
|-------|------|------|
| 1 | Server Route Update | 30 mins |
| 2 | E2EE Key Setup View | 2 hours |
| 3 | Enhanced PreJoin View | 2 hours |
| 4 | Server Key Storage | 1.5 hours |
| 5 | Guest Pre-Key Monitoring | 1 hour |
| 6 | Admission Flow | 2 hours |
| 7 | E2EE Key Exchange | 2 hours |
| 8 | Mid-Meeting Sender Keys | 1 hour |
| 9 | Flutter Web Routing | 30 mins |
| 10 | Meeting Persistence | 30 mins |
| **Testing** | End-to-End Testing | 2 hours |
| **TOTAL** | | **15 hours** |

**Note:** Original estimate was 8-10 hours. After detailed planning, actual implementation is ~15 hours due to:
- Full E2EE key lifecycle management
- Pre-key monitoring and replenishment
- Mid-meeting sender key distribution
- Additional error handling and edge cases

---

## 🚀 Next Steps

**Please answer the 10 additional questions above** so I can proceed with implementation!

Once confirmed, I'll start with Phase 1 (Server Route Update) and work through sequentially.
