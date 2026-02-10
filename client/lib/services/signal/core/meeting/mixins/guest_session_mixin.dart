import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../../../../api_service.dart';
import '../../../../socket_service.dart'
    if (dart.library.io) '../../../../socket_service_native.dart';
import '../../encryption_service.dart';
import '../../key_manager.dart';
import '../../session_manager.dart';

/// Mixin for guest session management and sender key distribution
mixin GuestSessionMixin {
  // Required getters from main service
  EncryptionService get encryptionService;
  ApiService get apiService;
  SocketService get socketService;
  String? Function() get getCurrentUserId;
  int? Function() get getCurrentDeviceId;

  SessionManager get sessionStore;
  SignalKeyManager get preKeyStore;
  SignalKeyManager get signedPreKeyStore;
  SignalKeyManager get identityStore;
  SignalKeyManager get senderKeyStore;

  /// Distribute sender key to external guest for encrypted meeting
  Future<void> distributeKeyToExternalGuest({
    required String guestSessionId,
    required String meetingId,
  }) async {
    try {
      debugPrint(
        '[GUEST_SESSION] Distributing sender key to guest $guestSessionId for meeting $meetingId',
      );

      final currentUserId = getCurrentUserId();
      final currentDeviceId = getCurrentDeviceId();

      if (currentUserId == null || currentDeviceId == null) {
        throw Exception('User info not set');
      }

      // 1. Fetch guest's Signal keys
      final response = await apiService.get(
        '/api/meetings/$meetingId/external/$guestSessionId/keys',
      );

      final responseData = response.data;
      if (responseData is! Map<String, dynamic>) {
        throw Exception(
          'Unexpected guest keybundle response: ${responseData.runtimeType}',
        );
      }
      final bundleData = responseData;

      // 2. Build session with guest
      final guestAddress = SignalProtocolAddress('guest:$guestSessionId', 0);

      final signedPreKey = bundleData['signed_pre_key'] as Map<String, dynamic>;
      final oneTimePreKey =
          bundleData['one_time_pre_key'] as Map<String, dynamic>?;

      final bundle = PreKeyBundle(
        0, // External guests do not provide a registration ID
        0, // Guests have device ID 0
        oneTimePreKey != null ? oneTimePreKey['keyId'] as int : null,
        oneTimePreKey != null
            ? Curve.decodePoint(
                base64Decode(oneTimePreKey['publicKey'] as String),
                0,
              )
            : null,
        signedPreKey['keyId'] as int,
        Curve.decodePoint(base64Decode(signedPreKey['publicKey'] as String), 0),
        base64Decode(signedPreKey['signature'] as String),
        IdentityKey.fromBytes(
          base64Decode(bundleData['identity_key'] as String),
          0,
        ),
      );

      final sessionBuilder = SessionBuilder(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        guestAddress,
      );

      await sessionBuilder.processPreKeyBundle(bundle);
      debugPrint('[GUEST_SESSION] ✓ Session established with guest');

      // 3. Create sender key distribution message
      final myAddress = SignalProtocolAddress(currentUserId, currentDeviceId);
      final senderKeyName = SenderKeyName(meetingId, myAddress);

      final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);
      final distributionMessage = await groupSessionBuilder.create(
        senderKeyName,
      );

      // 4. Encrypt distribution message for guest
      final sessionCipher = SessionCipher(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        guestAddress,
      );

      final distributionBytes = distributionMessage.serialize();
      final encryptedDistribution = await sessionCipher.encrypt(
        distributionBytes,
      );

      // 5. Send to guest via server
      socketService.emit('meeting:distributeSenderKeyToGuest', {
        'guestSessionId': guestSessionId,
        'meetingId': meetingId,
        'encryptedDistribution': base64Encode(
          encryptedDistribution.serialize(),
        ),
        'cipherType': encryptedDistribution.getType(),
      });

      debugPrint('[GUEST_SESSION] ✓ Sender key distributed to guest');
    } catch (e, stackTrace) {
      debugPrint('[GUEST_SESSION] ❌ Failed to distribute key to guest: $e');
      debugPrint('[GUEST_SESSION] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Send LiveKit E2EE key to external guest using Signal Protocol
  Future<void> sendE2EEKeyToExternalGuest({
    required String guestSessionId,
    required String meetingId,
    required String encryptedKey,
    String? requestId,
  }) async {
    try {
      debugPrint(
        '[GUEST_SESSION] Sending E2EE key to guest $guestSessionId for meeting $meetingId',
      );

      // 1. Fetch guest's Signal keys
      final response = await apiService.get(
        '/api/meetings/$meetingId/external/$guestSessionId/keys',
      );

      final responseData = response.data;
      if (responseData is! Map<String, dynamic>) {
        throw Exception(
          'Unexpected guest keybundle response: ${responseData.runtimeType}',
        );
      }
      final bundleData = responseData;

      // 2. Build session with guest
      final guestAddress = SignalProtocolAddress('guest:$guestSessionId', 0);

      final signedPreKey = bundleData['signed_pre_key'] as Map<String, dynamic>;
      final oneTimePreKey =
          bundleData['one_time_pre_key'] as Map<String, dynamic>?;

      final bundle = PreKeyBundle(
        0, // External guests do not provide a registration ID
        0, // Guests have device ID 0
        oneTimePreKey != null ? oneTimePreKey['keyId'] as int : null,
        oneTimePreKey != null
            ? Curve.decodePoint(
                base64Decode(oneTimePreKey['publicKey'] as String),
                0,
              )
            : null,
        signedPreKey['keyId'] as int,
        Curve.decodePoint(base64Decode(signedPreKey['publicKey'] as String), 0),
        base64Decode(signedPreKey['signature'] as String),
        IdentityKey.fromBytes(
          base64Decode(bundleData['identity_key'] as String),
          0,
        ),
      );

      final sessionBuilder = SessionBuilder(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        guestAddress,
      );

      await sessionBuilder.processPreKeyBundle(bundle);
      debugPrint('[GUEST_SESSION] ✓ Session established with guest');

      // 3. Encrypt payload for guest
      final sessionCipher = SessionCipher(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        guestAddress,
      );

      final payload = jsonEncode({
        'meetingId': meetingId,
        'encryptedKey': encryptedKey,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      final encryptedMessage = await sessionCipher.encrypt(
        Uint8List.fromList(utf8.encode(payload)),
      );

      // 4. Send to guest via server
      socketService.emit('participant:meeting_e2ee_key_response', {
        'guest_session_id': guestSessionId,
        'meeting_id': meetingId,
        'ciphertext': base64Encode(encryptedMessage.serialize()),
        'messageType': encryptedMessage.getType(),
        if (requestId != null) 'request_id': requestId,
      });

      debugPrint('[GUEST_SESSION] ✓ Encrypted E2EE key sent to guest');
    } catch (e, stackTrace) {
      debugPrint('[GUEST_SESSION] ❌ Failed to send E2EE key to guest: $e');
      debugPrint('[GUEST_SESSION] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Create session with authenticated participant for meeting
  Future<void> createSessionWithParticipant({
    required String participantUserId,
    required int participantDeviceId,
  }) async {
    try {
      debugPrint(
        '[GUEST_SESSION] Creating session with participant $participantUserId:$participantDeviceId',
      );

      final participantAddress = SignalProtocolAddress(
        participantUserId,
        participantDeviceId,
      );

      // Check if session already exists
      final hasSession = await sessionStore.containsSession(participantAddress);

      if (hasSession) {
        debugPrint('[GUEST_SESSION] Session already exists');
        return;
      }

      // Delegate to SessionManager to establish session
      debugPrint(
        '[GUEST_SESSION] No session with $participantUserId:$participantDeviceId, establishing...',
      );
      final success = await sessionStore.establishSessionWithUser(
        participantUserId,
      );
      if (!success) {
        throw Exception('Failed to establish session with $participantUserId');
      }

      debugPrint('[GUEST_SESSION] ✓ Session created with participant');
    } catch (e, stackTrace) {
      debugPrint(
        '[GUEST_SESSION] ❌ Failed to create session with participant: $e',
      );
      debugPrint('[GUEST_SESSION] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Distribute sender key to authenticated participant
  Future<void> distributeKeyToParticipant({
    required String participantUserId,
    required int participantDeviceId,
    required String meetingId,
  }) async {
    try {
      debugPrint(
        '[GUEST_SESSION] Distributing sender key to participant $participantUserId:$participantDeviceId',
      );

      final currentUserId = getCurrentUserId();
      final currentDeviceId = getCurrentDeviceId();

      if (currentUserId == null || currentDeviceId == null) {
        throw Exception('User info not set');
      }

      // Ensure session exists
      await createSessionWithParticipant(
        participantUserId: participantUserId,
        participantDeviceId: participantDeviceId,
      );

      // Create sender key distribution message
      final myAddress = SignalProtocolAddress(currentUserId, currentDeviceId);
      final senderKeyName = SenderKeyName(meetingId, myAddress);

      final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);
      final distributionMessage = await groupSessionBuilder.create(
        senderKeyName,
      );

      // Encrypt for participant
      final participantAddress = SignalProtocolAddress(
        participantUserId,
        participantDeviceId,
      );

      final sessionCipher = SessionCipher(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        participantAddress,
      );

      final distributionBytes = distributionMessage.serialize();
      final encryptedDistribution = await sessionCipher.encrypt(
        distributionBytes,
      );

      // Send via server
      socketService.emit('meeting:distributeSenderKeyToParticipant', {
        'participantUserId': participantUserId,
        'participantDeviceId': participantDeviceId,
        'meetingId': meetingId,
        'encryptedDistribution': base64Encode(
          encryptedDistribution.serialize(),
        ),
        'cipherType': encryptedDistribution.getType(),
      });

      debugPrint('[GUEST_SESSION] ✓ Sender key distributed to participant');
    } catch (e, stackTrace) {
      debugPrint(
        '[GUEST_SESSION] ❌ Failed to distribute key to participant: $e',
      );
      debugPrint('[GUEST_SESSION] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Process received sender key distribution for meeting
  Future<void> processReceivedSenderKeyForMeeting({
    required String meetingId,
    required String senderId,
    required int senderDeviceId,
    required Uint8List encryptedDistribution,
    required int cipherType,
  }) async {
    try {
      debugPrint(
        '[GUEST_SESSION] Processing sender key from $senderId:$senderDeviceId for meeting $meetingId',
      );

      final senderAddress = SignalProtocolAddress(senderId, senderDeviceId);

      // Decrypt distribution message
      final sessionCipher = SessionCipher(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        senderAddress,
      );

      Uint8List distributionBytes;

      if (cipherType == CiphertextMessage.prekeyType) {
        final prekeyMessage = PreKeySignalMessage(encryptedDistribution);
        distributionBytes = await sessionCipher.decrypt(prekeyMessage);
      } else {
        final signalMessage = SignalMessage.fromSerialized(
          encryptedDistribution,
        );
        distributionBytes = await sessionCipher.decryptFromSignal(
          signalMessage,
        );
      }

      // Process distribution message
      final distributionMessage =
          SenderKeyDistributionMessageWrapper.fromSerialized(distributionBytes);

      final senderKeyName = SenderKeyName(meetingId, senderAddress);
      final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);

      await groupSessionBuilder.process(senderKeyName, distributionMessage);

      debugPrint('[GUEST_SESSION] ✓ Sender key processed for meeting');
    } catch (e, stackTrace) {
      debugPrint('[GUEST_SESSION] ❌ Failed to process sender key: $e');
      debugPrint('[GUEST_SESSION] Stack trace: $stackTrace');
      rethrow;
    }
  }
}
