import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../../api_service.dart';
import '../../socket_service.dart';
import '../../permanent_identity_key_store.dart';
import '../../permanent_pre_key_store.dart';
import '../../permanent_session_store.dart';
import '../../permanent_signed_pre_key_store.dart';
import '../../sender_key_store.dart';

/// Guest Session Manager
///
/// Handles Signal Protocol session management for external meeting guests:
/// - Session creation with guests (external participants without accounts)
/// - Session creation with authenticated participants
/// - Sender key distribution to guests
///
/// This service manages the cryptographic setup needed for guests to participate
/// in encrypted meetings.
class GuestSessionManager {
  final PermanentSessionStore sessionStore;
  final PermanentPreKeyStore preKeyStore;
  final PermanentSignedPreKeyStore signedPreKeyStore;
  final PermanentIdentityKeyStore identityStore;
  final PermanentSenderKeyStore senderKeyStore;
  final String? Function() getCurrentUserId;
  final int? Function() getCurrentDeviceId;

  GuestSessionManager({
    required this.sessionStore,
    required this.preKeyStore,
    required this.signedPreKeyStore,
    required this.identityStore,
    required this.senderKeyStore,
    required this.getCurrentUserId,
    required this.getCurrentDeviceId,
  });

  /// Distribute sender key to external guest for encrypted meeting
  Future<void> distributeKeyToExternalGuest({
    required String guestSessionId,
    required String meetingId,
  }) async {
    try {
      debugPrint(
        '[GUEST_SESSION_MANAGER] Distributing sender key to guest $guestSessionId for meeting $meetingId',
      );

      final currentUserId = getCurrentUserId();
      final currentDeviceId = getCurrentDeviceId();

      if (currentUserId == null || currentDeviceId == null) {
        throw Exception('User info not set. Call setCurrentUserInfo first.');
      }

      // 1. Fetch guest's Signal keys
      final response = await ApiService.get(
        '/api/meetings/external/keys/$guestSessionId',
      );
      final keys = response.data as Map<String, dynamic>;

      final identityKeyPublic = keys['identityKeyPublic'] as String?;
      final signedPreKeyData = keys['signedPreKey'];
      final preKeyData = keys['preKey'];

      if (identityKeyPublic == null ||
          signedPreKeyData == null ||
          preKeyData == null) {
        throw Exception('Incomplete keys for guest $guestSessionId');
      }

      // Parse signed pre-key
      final signedPreKey = signedPreKeyData is String
          ? jsonDecode(signedPreKeyData)
          : signedPreKeyData as Map<String, dynamic>;

      final preKey = preKeyData is String
          ? jsonDecode(preKeyData)
          : preKeyData as Map<String, dynamic>;

      debugPrint(
        '[GUEST_SESSION_MANAGER] Fetched guest keys - preKeyId: ${preKey['id']}',
      );

      // 2. Build PreKeyBundle
      final guestAddress = SignalProtocolAddress(
        guestSessionId,
        1,
      ); // Device 1 for guests

      final preKeyBytes = base64Decode(preKey['publicKey'] as String);
      final signedPreKeyBytes = base64Decode(
        signedPreKey['publicKey'] as String,
      );
      final identityKeyBytes = base64Decode(identityKeyPublic);

      final preKeyBundle = PreKeyBundle(
        0, // registrationId not used for external guests
        1, // deviceId
        preKey['id'] as int,
        Curve.decodePoint(preKeyBytes, 0),
        signedPreKey['id'] as int,
        Curve.decodePoint(signedPreKeyBytes, 0),
        base64Decode(signedPreKey['signature'] as String? ?? ''),
        IdentityKey(Curve.decodePoint(identityKeyBytes, 0)),
      );

      debugPrint('[GUEST_SESSION_MANAGER] Built PreKeyBundle for guest');

      // 3. Establish session
      final sessionBuilder = SessionBuilder(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        guestAddress,
      );

      await sessionBuilder.processPreKeyBundle(preKeyBundle);
      debugPrint('[GUEST_SESSION_MANAGER] Session established with guest');

      // 4. Consume the pre-key on server
      try {
        await ApiService.post(
          '/api/meetings/external/session/$guestSessionId/consume-prekey',
          data: {'pre_key_id': preKey['id']},
        );
        debugPrint('[GUEST_SESSION_MANAGER] Consumed pre-key ${preKey['id']}');
      } catch (e) {
        debugPrint(
          '[GUEST_SESSION_MANAGER] Warning: Failed to consume pre-key: $e',
        );
        // Continue - session is established locally
      }

      // 5. Get meeting sender key
      final senderAddress = SignalProtocolAddress(
        currentUserId,
        currentDeviceId,
      );
      final senderKeyName = SenderKeyName(meetingId, senderAddress);

      final hasSenderKey = await senderKeyStore.containsSenderKey(
        senderKeyName,
      );
      if (!hasSenderKey) {
        throw Exception(
          'No sender key found for meeting $meetingId. Create sender key first.',
        );
      }

      final senderKeyRecord = await senderKeyStore.loadSenderKey(senderKeyName);
      final senderKeyBytes = senderKeyRecord.serialize();
      debugPrint(
        '[GUEST_SESSION_MANAGER] Loaded sender key, size: ${senderKeyBytes.length} bytes',
      );

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

      debugPrint(
        '[GUEST_SESSION_MANAGER] Encrypted sender key, type: ${encryptedSenderKey.getType()}',
      );

      // 7. Send via Socket.IO
      SocketService.instance.emit('meeting:distributeSenderKeyToGuest', {
        'meetingId': meetingId,
        'guestSessionId': guestSessionId,
        'senderDeviceId': currentDeviceId,
        'encryptedSenderKey': encryptedBase64,
        'messageType': encryptedSenderKey
            .getType(), // PreKey or Whisper message
      });

      debugPrint(
        '[GUEST_SESSION_MANAGER] Encrypted sender key sent to guest via Socket.IO',
      );
    } catch (e, stack) {
      debugPrint('[GUEST_SESSION_MANAGER] Error distributing key to guest: $e');
      debugPrint('[GUEST_SESSION_MANAGER] Stack trace: $stack');
      rethrow;
    }
  }

  /// Get or create session with external guest
  Future<SignalProtocolAddress> getOrCreateGuestSession({
    required String meetingId,
    required String guestSessionId,
  }) async {
    // Create address for guest (using session ID as "user ID")
    final address = SignalProtocolAddress('guest_$guestSessionId', 0);

    // Check if session already exists
    if (await sessionStore.containsSession(address)) {
      debugPrint(
        '[GUEST_SESSION_MANAGER] ✓ Using existing guest session: $guestSessionId',
      );
      return address;
    }

    debugPrint(
      '[GUEST_SESSION_MANAGER] Creating new guest session, fetching keybundle...',
    );

    // Fetch guest's Signal keybundle from server
    final response = await ApiService.get(
      '/api/meetings/$meetingId/external/$guestSessionId/keys',
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to fetch guest keybundle: ${response.statusCode}',
      );
    }

    final keybundle = response.data is String
        ? jsonDecode(response.data)
        : response.data;

    // Build PreKeyBundle
    final identityKey = IdentityKey(
      Curve.decodePoint(
        Uint8List.fromList(base64Decode(keybundle['identity_key'])),
        0,
      ),
    );

    final signedPreKey = keybundle['signed_pre_key'];
    final oneTimePreKey = keybundle['one_time_pre_key'];

    final bundle = PreKeyBundle(
      0, // Registration ID (not used for guests)
      0, // Device ID
      oneTimePreKey != null ? oneTimePreKey['keyId'] : null,
      oneTimePreKey != null
          ? Curve.decodePoint(
              Uint8List.fromList(base64Decode(oneTimePreKey['publicKey'])),
              0,
            )
          : null,
      signedPreKey['keyId'],
      Curve.decodePoint(
        Uint8List.fromList(base64Decode(signedPreKey['publicKey'])),
        0,
      ),
      Uint8List.fromList(base64Decode(signedPreKey['signature'])),
      identityKey,
    );

    // Process bundle to create session
    final sessionBuilder = SessionBuilder(
      sessionStore,
      preKeyStore,
      signedPreKeyStore,
      identityStore,
      address,
    );

    await sessionBuilder.processPreKeyBundle(bundle);
    debugPrint(
      '[GUEST_SESSION_MANAGER] ✓ Created new guest session: $guestSessionId',
    );

    return address;
  }

  /// Get or create session with authenticated participant
  Future<SignalProtocolAddress> getOrCreateParticipantSession({
    required String meetingId,
    required String participantUserId,
    required int participantDeviceId,
  }) async {
    // Create address for participant
    final address = SignalProtocolAddress(
      participantUserId,
      participantDeviceId,
    );

    // Check if session already exists
    if (await sessionStore.containsSession(address)) {
      debugPrint(
        '[GUEST_SESSION_MANAGER] ✓ Using existing participant session: $participantUserId:$participantDeviceId',
      );
      return address;
    }

    debugPrint(
      '[GUEST_SESSION_MANAGER] Creating new participant session, fetching keybundle...',
    );

    // For guests: we need sessionStorage-based fetch since we don't have authentication
    // The external_guest_socket_service.dart will need to inject sessionId/token
    final sessionId =
        ''; // TODO: Get from sessionStorage or ExternalParticipantService
    final response = await ApiService.get(
      '/api/meetings/external/$sessionId/participant/$participantUserId/$participantDeviceId/keys',
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to fetch participant keybundle: ${response.statusCode}',
      );
    }

    final keybundle = response.data is String
        ? jsonDecode(response.data)
        : response.data;

    // Build PreKeyBundle
    final identityKey = IdentityKey(
      Curve.decodePoint(
        Uint8List.fromList(base64Decode(keybundle['identity_key'])),
        0,
      ),
    );

    final signedPreKey = keybundle['signed_pre_key'];
    final oneTimePreKey = keybundle['one_time_pre_key'];

    final bundle = PreKeyBundle(
      0, // Registration ID
      participantDeviceId,
      oneTimePreKey != null ? oneTimePreKey['keyId'] : null,
      oneTimePreKey != null
          ? Curve.decodePoint(
              Uint8List.fromList(base64Decode(oneTimePreKey['publicKey'])),
              0,
            )
          : null,
      signedPreKey['keyId'],
      Curve.decodePoint(
        Uint8List.fromList(base64Decode(signedPreKey['publicKey'])),
        0,
      ),
      Uint8List.fromList(base64Decode(signedPreKey['signature'])),
      identityKey,
    );

    // Process bundle to create session
    final sessionBuilder = SessionBuilder(
      sessionStore,
      preKeyStore,
      signedPreKeyStore,
      identityStore,
      address,
    );

    await sessionBuilder.processPreKeyBundle(bundle);
    debugPrint(
      '[GUEST_SESSION_MANAGER] ✓ Created new participant session: $participantUserId:$participantDeviceId',
    );

    return address;
  }
}
