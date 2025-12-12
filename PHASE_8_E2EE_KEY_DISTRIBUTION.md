# Phase 8: E2EE Key Distribution for External Guests

## Overview
This phase enables server users (authenticated participants) to establish Signal Protocol sessions with external guests and distribute the meeting's E2EE sender key so guests can participate in encrypted group messaging.

## Architecture

### Key Flow
1. **Server User Joins Meeting** → Queries for admitted external guests
2. **Fetch Guest Keys** → GET `/api/meetings/external/keys/:sessionId`
3. **Establish Signal Session** → Use `SessionBuilder.processPreKeyBundle()`
4. **Consume Pre-Key** → POST `/api/meetings/external/session/:sessionId/consume-prekey`
5. **Encrypt Sender Key** → Use `SessionCipher.encrypt()` with guest's session
6. **Send via Socket.IO** → Emit `meeting:senderKeyForGuest` event
7. **Guest Receives** → Decrypt sender key, store in SenderKeyStore
8. **Guest Can Now Decrypt** → Full E2EE participation

### Security Considerations
- **Guest receives only** - Cannot create/distribute sender keys (server user privilege)
- **One-time pre-keys** - Consumed after use for forward secrecy
- **Per-session encryption** - Each guest gets individually encrypted sender key
- **Automatic replenishment** - Guest monitors and regenerates pre-keys when low

## Implementation

### Backend Changes

#### 1. Socket.IO Events (server.js)

```javascript
// Event: Server user requests sender key distribution to guest
socket.on('meeting:distributeSenderKeyToGuest', async (data) => {
  const { meetingId, guestSessionId, encryptedSenderKey } = data;
  
  // Verify sender is authenticated and in meeting
  if (!req.session?.uuid) {
    return;
  }

  try {
    // Get guest's socket connection
    const guestSession = await externalParticipantService.getSession(guestSessionId);
    if (!guestSession || guestSession.admission_status !== 'admitted') {
      socket.emit('meeting:senderKeyDistributionFailed', {
        error: 'Guest not found or not admitted'
      });
      return;
    }

    // Find guest's socket (stored when they join meeting)
    // Note: Need to implement guest socket tracking
    const guestSocketId = guestSocketConnections.get(guestSessionId);
    if (!guestSocketId) {
      socket.emit('meeting:senderKeyDistributionFailed', {
        error: 'Guest not connected'
      });
      return;
    }

    // Send encrypted sender key to guest
    io.to(guestSocketId).emit('meeting:receiveSenderKey', {
      meetingId,
      senderId: req.session.uuid,
      senderDeviceId: data.senderDeviceId,
      encryptedSenderKey, // Base64 encrypted Signal message
    });

    socket.emit('meeting:senderKeyDistributed', { guestSessionId });
  } catch (error) {
    console.error('Error distributing sender key to guest:', error);
    socket.emit('meeting:senderKeyDistributionFailed', { error: error.message });
  }
});

// Track guest socket connections
const guestSocketConnections = new Map(); // sessionId -> socketId

socket.on('external:registerSocket', (data) => {
  const { sessionId } = data;
  guestSocketConnections.set(sessionId, socket.id);
  
  socket.on('disconnect', () => {
    guestSocketConnections.delete(sessionId);
  });
});
```

### Frontend Changes

#### 2. Signal Service Enhancement (client/lib/services/signal_service.dart)

```dart
/// Establish Signal session with external guest and send encrypted sender key
Future<void> distributeKeyToExternalGuest({
  required String guestSessionId,
  required String meetingId,
}) async {
  try {
    debugPrint('[SIGNAL] Distributing sender key to guest $guestSessionId');

    // 1. Fetch guest's Signal keys
    final keys = await ExternalParticipantService().getKeysForSession(guestSessionId);
    
    final identityKeyPublic = keys['identityKeyPublic'] as String;
    final signedPreKey = keys['signedPreKey'] as Map<String, dynamic>;
    final preKey = keys['preKey'] as Map<String, dynamic>?;
    
    if (preKey == null) {
      throw Exception('No available pre-keys for guest');
    }

    // 2. Build PreKeyBundle
    final guestAddress = SignalProtocolAddress(guestSessionId, 1); // Device 1 for guests
    
    final preKeyBundle = PreKeyBundle(
      registrationId: 0, // Not used for external guests
      deviceId: 1,
      preKeyId: preKey['id'],
      Uint8List.fromList(base64Decode(preKey['publicKey'])),
      signedPreKey['id'],
      Uint8List.fromList(base64Decode(signedPreKey['publicKey'])),
      Uint8List.fromList(base64Decode(signedPreKey['signature'] ?? '')),
      Uint8List.fromList(base64Decode(identityKeyPublic)),
    );

    // 3. Establish session
    final sessionBuilder = SessionBuilder(
      sessionStore,
      preKeyStore,
      signedPreKeyStore,
      identityStore,
      guestAddress,
    );
    
    await sessionBuilder.processPreKeyBundle(preKeyBundle);
    debugPrint('[SIGNAL] Session established with guest');

    // 4. Consume the pre-key
    await ExternalParticipantService().consumePreKey(
      sessionId: guestSessionId,
      preKeyId: preKey['id'],
    );

    // 5. Get meeting sender key
    final senderAddress = SignalProtocolAddress(_currentUserId!, _currentDeviceId!);
    final senderKeyName = SenderKeyName(meetingId, senderAddress);
    final senderKeyRecord = await senderKeyStore.loadSenderKey(senderKeyName);
    final senderKeyBytes = senderKeyRecord.serialize();

    // 6. Encrypt sender key for guest
    final sessionCipher = SessionCipher(
      sessionStore,
      preKeyStore,
      signedPreKeyStore,
      identityStore,
      guestAddress,
    );
    
    final encryptedSenderKey = await sessionCipher.encrypt(senderKeyBytes);
    final encryptedBase64 = base64Encode(encryptedSenderKey.serialize());

    // 7. Send via Socket.IO
    SocketService().emit('meeting:distributeSenderKeyToGuest', {
      'meetingId': meetingId,
      'guestSessionId': guestSessionId,
      'senderDeviceId': _currentDeviceId,
      'encryptedSenderKey': encryptedBase64,
    });

    debugPrint('[SIGNAL] Encrypted sender key sent to guest');
  } catch (e, stack) {
    debugPrint('[SIGNAL] Error distributing key to guest: $e\n$stack');
    rethrow;
  }
}
```

#### 3. Guest Key Reception (client/lib/views/external_prejoin_view.dart or meeting view)

```dart
/// Listen for encrypted sender key from server users
void _setupSenderKeyListener() {
  SocketService().registerListener('meeting:receiveSenderKey', (data) async {
    try {
      final meetingId = data['meetingId'];
      final senderId = data['senderId'];
      final senderDeviceId = data['senderDeviceId'];
      final encryptedSenderKey = data['encryptedSenderKey'];

      debugPrint('[GUEST] Received encrypted sender key from $senderId:$senderDeviceId');

      // 1. Decrypt sender key using our Signal session
      final senderAddress = SignalProtocolAddress(senderId, senderDeviceId);
      final sessionCipher = SessionCipher(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        senderAddress,
      );

      final encryptedMessage = PreKeySignalMessage.fromSerialized(
        base64Decode(encryptedSenderKey),
      );

      Uint8List? decryptedBytes;
      await sessionCipher.decryptWithCallback(encryptedMessage, (plaintext) {
        decryptedBytes = plaintext;
      });

      if (decryptedBytes == null) {
        throw Exception('Failed to decrypt sender key');
      }

      // 2. Store sender key in our SenderKeyStore
      final groupSenderAddress = SignalProtocolAddress(senderId, senderDeviceId);
      final senderKeyName = SenderKeyName(meetingId, groupSenderAddress);
      
      // Process as sender key distribution message
      final distributionMessage = SenderKeyDistributionMessageWrapper.fromSerialized(
        decryptedBytes!,
      );
      
      final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);
      await groupSessionBuilder.process(senderKeyName, distributionMessage);

      debugPrint('[GUEST] Sender key stored successfully - can now decrypt messages');

    } catch (e, stack) {
      debugPrint('[GUEST] Error processing sender key: $e\n$stack');
    }
  });
}
```

#### 4. Auto-Distribution on Guest Admission (client/lib/views/meeting_view.dart)

```dart
/// When a guest is admitted, automatically distribute sender key
void _setupGuestAdmissionListener() {
  ExternalParticipantService().onGuestAdmitted.listen((session) async {
    if (session.meetingId == widget.meetingId) {
      debugPrint('[MEETING] Guest ${session.displayName} admitted - distributing keys');
      
      try {
        await SignalService.instance.distributeKeyToExternalGuest(
          guestSessionId: session.sessionId,
          meetingId: widget.meetingId,
        );
      } catch (e) {
        debugPrint('[MEETING] Failed to distribute key to guest: $e');
        // Show notification to user
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to set up encryption for ${session.displayName}'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  });
}
```

## Testing Checklist

- [ ] Server user can fetch guest's Signal keys
- [ ] Pre-key is consumed after session establishment
- [ ] Sender key is encrypted correctly
- [ ] Socket.IO event delivers to correct guest
- [ ] Guest can decrypt sender key
- [ ] Guest can decrypt meeting messages
- [ ] Guest pre-key count decrements
- [ ] Auto-replenishment triggers when low
- [ ] Multiple server users can independently establish sessions
- [ ] Guest receives sender keys from all server participants

## Known Limitations

1. **Guest Cannot Create Sender Keys** - This is by design. Only authenticated server users can create/distribute group keys.

2. **Initial Key Distribution Delay** - There's a brief window after admission where guest cannot decrypt messages until first server user distributes key.

3. **Server User Must Be Present** - At least one server user must be in the meeting to distribute keys to guests (enforced by "waiting for host" flow).

## Future Enhancements

1. **Key Rotation** - Implement sender key rotation when guests leave
2. **Batch Distribution** - Distribute to multiple guests in parallel
3. **Key Request** - Allow guests to request sender key if not received
4. **Offline Queue** - Queue key distribution if guest temporarily disconnected
