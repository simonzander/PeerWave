import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../../event_bus.dart';
import '../../storage/sqlite_message_store.dart';
import '../../permanent_pre_key_store.dart';
import '../../permanent_session_store.dart';
import '../../permanent_signed_pre_key_store.dart';
import '../../permanent_identity_key_store.dart';
import 'message_sender.dart';
import 'encryption_service.dart';

/// MessageReceiver Service
///
/// Handles all inbound message operations including:
/// - Message decryption (PreKey and Whisper messages)
/// - Session recovery and error handling
/// - Failed message storage and UI callbacks
/// - Automatic session reestablishment
///
/// Dependencies:
/// - EncryptionService: For decryption operations and store access
/// - MessageSender: For session recovery via sendItem
///
/// Usage:
/// ```dart
/// // Self-initializing factory
/// final messageReceiver = await MessageReceiver.create(
///   encryptionService: encryptionService,
///   messageSender: messageSender,
///   receiveItemCallbacks: {},
///   regeneratePreKeyAsync: (id) async {},
/// );
/// ```
class MessageReceiver {
  final EncryptionService encryptionService;
  final MessageSender messageSender;
  final Map<String, List<Function(Map<String, dynamic>)>> receiveItemCallbacks;
  final Function(int) regeneratePreKeyAsync;

  // Rate limiting for session recovery
  final Map<String, DateTime> _sessionRecoveryLastAttempt = {};

  bool _initialized = false;

  // Delegate to EncryptionService for stores
  PermanentSessionStore get sessionStore => encryptionService.sessionStore;
  PermanentPreKeyStore get preKeyStore => encryptionService.preKeyStore;
  PermanentSignedPreKeyStore get signedPreKeyStore =>
      encryptionService.signedPreKeyStore;
  PermanentIdentityKeyStore get identityStore =>
      encryptionService.identityStore;

  bool get isInitialized => _initialized;

  // Private constructor
  MessageReceiver._({
    required this.encryptionService,
    required this.messageSender,
    required this.receiveItemCallbacks,
    required this.regeneratePreKeyAsync,
  });

  /// Self-initializing factory
  static Future<MessageReceiver> create({
    required EncryptionService encryptionService,
    required MessageSender messageSender,
    required Map<String, List<Function(Map<String, dynamic>)>>
    receiveItemCallbacks,
    required Function(int) regeneratePreKeyAsync,
  }) async {
    final receiver = MessageReceiver._(
      encryptionService: encryptionService,
      messageSender: messageSender,
      receiveItemCallbacks: receiveItemCallbacks,
      regeneratePreKeyAsync: regeneratePreKeyAsync,
    );
    await receiver.init();
    return receiver;
  }

  /// Initialize (no stores to create - all from EncryptionService)
  Future<void> init() async {
    if (_initialized) {
      debugPrint('[MESSAGE_RECEIVER] Already initialized');
      return;
    }

    debugPrint(
      '[MESSAGE_RECEIVER] Initialized (using EncryptionService stores)',
    );
    _initialized = true;
  }

  // ============================================================================
  // MESSAGE DECRYPTION
  // ============================================================================
  ///
  /// Handles PreKey messages (session establishment) and Whisper messages (normal).
  /// Automatically recovers from session corruption and key mismatches.
  ///
  /// Parameters:
  /// - [senderAddress]: SignalProtocolAddress of the sender
  /// - [payload]: Base64-encoded encrypted message OR plain JSON for system messages
  /// - [cipherType]: 3 = PreKey, 1 = SignalMessage, 0 = Unencrypted
  /// - [itemId]: Optional message ID for error tracking
  ///
  /// Returns decrypted plaintext or empty string on failure
  Future<String> decryptItem({
    required SignalProtocolAddress senderAddress,
    required String payload,
    required int cipherType,
    String? itemId,
  }) async {
    // Handle unencrypted system messages
    if (cipherType == 0) {
      debugPrint(
        '[MESSAGE_RECEIVER] Processing unencrypted system message (cipherType 0)',
      );
      return payload;
    }

    try {
      final sessionCipher = SessionCipher(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        senderAddress,
      );

      final serialized = base64Decode(payload);

      // Decrypt PreKey message (first message that establishes session)
      if (cipherType == CiphertextMessage.prekeyType) {
        final preKeyMsg = PreKeySignalMessage(serialized);

        Uint8List plaintext;
        try {
          plaintext = await sessionCipher.decryptWithCallback(
            preKeyMsg,
            (pt) {},
          );
        } on UntrustedIdentityException catch (e) {
          debugPrint(
            '[MESSAGE_RECEIVER] UntrustedIdentityException during PreKey decryption',
          );

          // Auto-trust and rebuild session
          await _handleUntrustedIdentity(e, senderAddress);

          // Retry decryption with trusted identity
          try {
            final newSessionCipher = SessionCipher(
              sessionStore,
              preKeyStore,
              signedPreKeyStore,
              identityStore,
              senderAddress,
            );
            plaintext = await newSessionCipher.decryptWithCallback(
              preKeyMsg,
              (pt) {},
            );
            debugPrint(
              '[MESSAGE_RECEIVER] ✓ PreKey message decrypted after identity update',
            );
          } catch (retryError) {
            final errorStr = retryError.toString().toLowerCase();
            if (errorStr.contains('prekey') ||
                errorStr.contains('no valid') ||
                errorStr.contains('invalidkey') ||
                errorStr.contains('signedprekeyrecord') ||
                errorStr.contains('signature')) {
              debugPrint(
                '[MESSAGE_RECEIVER] ⚠️ PreKey decryption failed after identity trust: $retryError',
              );
              return '';
            }
            rethrow;
          }
        } catch (e) {
          // Handle PreKey-specific errors
          final errorStr = e.toString();

          // Check if this is actually a Bad Mac error
          if (errorStr.contains('Bad Mac') ||
              errorStr.toLowerCase().contains('bad mac')) {
            rethrow; // Let Bad Mac handler below catch it
          }

          final errorStrLower = errorStr.toLowerCase();

          if (errorStrLower.contains('prekey') ||
              errorStrLower.contains('no valid') ||
              errorStrLower.contains('invalidkey') ||
              errorStrLower.contains('signedprekeyrecord') ||
              errorStrLower.contains('signature')) {
            debugPrint(
              '[MESSAGE_RECEIVER] ⚠️ PreKey/SignedPreKey decryption failed: $e',
            );

            // Store failed message
            if (itemId != null) {
              await _storeFailedMessage(
                itemId: itemId,
                senderAddress: senderAddress,
                reason: 'invalid_prekey',
                message: 'Decryption failed - invalid encryption keys',
              );
            }

            // Initiate recovery
            await _initiateRecovery(senderAddress);
            return '';
          }
          rethrow;
        }

        // Remove used PreKey after successful session establishment
        final preKeyIdOptional = preKeyMsg.getPreKeyId();
        int? preKeyId;
        if (preKeyIdOptional.isPresent == true) {
          preKeyId = preKeyIdOptional.value;
        }

        if (preKeyId != null) {
          debugPrint('[MESSAGE_RECEIVER] Removing used PreKey $preKeyId');
          await preKeyStore.removePreKey(preKeyId);

          // Regenerate consumed PreKey asynchronously
          regeneratePreKeyAsync(preKeyId);

          // Trigger server sync check
          Future.delayed(Duration(seconds: 2), () {
            debugPrint('[MESSAGE_RECEIVER] Triggering PreKey sync check...');
            // Note: SocketService emit would be here in the original
          });
        }

        return utf8.decode(plaintext);
      } else if (cipherType == CiphertextMessage.whisperType) {
        // Normal Whisper message
        final signalMsg = SignalMessage.fromSerialized(serialized);

        try {
          final plaintext = await sessionCipher.decryptFromSignal(signalMsg);
          debugPrint('[MESSAGE_RECEIVER] Decrypted whisper message');
          return utf8.decode(plaintext);
        } catch (e) {
          // Handle NoSessionException
          if (e.toString().contains('NoSessionException')) {
            debugPrint(
              '[MESSAGE_RECEIVER] ⚠️ NoSessionException - no session exists for ${senderAddress.getName()}:${senderAddress.getDeviceId()}',
            );

            // Store failed message
            if (itemId != null) {
              await _storeFailedMessage(
                itemId: itemId,
                senderAddress: senderAddress,
                reason: 'no_session',
                message: 'Decryption failed - no session',
              );
            }

            // Initiate double ratchet recovery
            await _initiateDoubleRatchetRecovery(senderAddress);
            return '';
          }

          // Handle InvalidMessageException / Bad MAC (session corruption)
          if (e.toString().contains('InvalidMessageException') ||
              e.toString().contains('Bad Mac')) {
            debugPrint(
              '[MESSAGE_RECEIVER] ⚠️ InvalidMessageException - session corrupted',
            );

            // Store failed message
            if (itemId != null) {
              await _storeFailedMessage(
                itemId: itemId,
                senderAddress: senderAddress,
                reason: 'bad_mac',
                message: 'Decryption failed - session corrupted',
              );
            }

            // Delete corrupted session
            await sessionStore.deleteSession(senderAddress);
            debugPrint('[MESSAGE_RECEIVER] ✓ Corrupted session deleted');

            // Initiate double ratchet recovery
            await _initiateDoubleRatchetRecovery(senderAddress, badMac: true);
            return '';
          }

          rethrow;
        }
      } else if (cipherType == CiphertextMessage.senderKeyType) {
        throw Exception(
          'CipherType 4 (senderKeyType) detected - group messages must use GroupCipher.',
        );
      } else {
        throw Exception('Unknown cipherType: $cipherType');
      }
    } catch (e, st) {
      debugPrint(
        '[MESSAGE_RECEIVER] Exception while decrypting message: $e\n$st',
      );
      return 'Decryption failed';
    }
  }

  /// Store failed message in database and trigger UI callbacks
  Future<void> _storeFailedMessage({
    required String itemId,
    required SignalProtocolAddress senderAddress,
    required String reason,
    required String message,
  }) async {
    try {
      final messageStore = await SqliteMessageStore.getInstance();
      final messageTimestamp = DateTime.now().toIso8601String();
      final sender = senderAddress.getName();
      final senderDeviceId = senderAddress.getDeviceId();

      await messageStore.storeReceivedMessage(
        itemId: itemId,
        sender: sender,
        senderDeviceId: senderDeviceId,
        message: message,
        timestamp: messageTimestamp,
        type: 'message',
        status: 'decrypt_failed',
        metadata: {'reason': reason},
      );
      debugPrint(
        '[MESSAGE_RECEIVER] ✓ Stored failed message with decrypt_failed status',
      );

      // Emit EventBus event and trigger callbacks
      final decryptFailedItem = {
        'itemId': itemId,
        'type': 'message',
        'sender': sender,
        'senderDeviceId': senderDeviceId,
        'message': message,
        'timestamp': messageTimestamp,
        'status': 'decrypt_failed',
        'isOwnMessage': false,
        'conversationWith': sender,
      };

      EventBus.instance.emit(AppEvent.newMessage, decryptFailedItem);
      EventBus.instance.emit(AppEvent.newConversation, {
        'conversationId': sender,
        'isChannel': false,
        'isOwnMessage': false,
      });

      // Trigger receiveItem callbacks
      final key = 'message:$sender';
      if (receiveItemCallbacks.containsKey(key)) {
        for (final callback in receiveItemCallbacks[key]!) {
          try {
            callback(decryptFailedItem);
          } catch (e) {
            debugPrint('[MESSAGE_RECEIVER] Callback error: $e');
          }
        }
      }
    } catch (storageError) {
      debugPrint(
        '[MESSAGE_RECEIVER] ✗ Failed to store decrypt_failed message: $storageError',
      );
    }
  }

  /// Initiate session recovery (for PreKey errors)
  Future<void> _initiateRecovery(SignalProtocolAddress senderAddress) async {
    try {
      final senderId = senderAddress.getName();
      final deviceId = senderAddress.getDeviceId();
      final recoveryKey = '$senderId:$deviceId';

      // Rate limiting
      final lastAttempt = _sessionRecoveryLastAttempt[recoveryKey];
      if (lastAttempt != null) {
        final timeSinceLastAttempt = DateTime.now().difference(lastAttempt);
        if (timeSinceLastAttempt.inSeconds < 30) {
          debugPrint(
            '[MESSAGE_RECEIVER] ⚠️ Recovery already attempted ${timeSinceLastAttempt.inSeconds}s ago - skipping',
          );
          return;
        }
      }

      _sessionRecoveryLastAttempt[recoveryKey] = DateTime.now();

      // Delete our session with sender (if any)
      final recipientAddress = SignalProtocolAddress(senderId, deviceId);
      final hadSession = await sessionStore.containsSession(recipientAddress);
      if (hadSession) {
        await sessionStore.deleteSession(recipientAddress);
        debugPrint(
          '[MESSAGE_RECEIVER] ✓ Deleted our session with sender for clean state',
        );
      }

      debugPrint(
        '[MESSAGE_RECEIVER] ℹ️ Session deleted - will recover on next message',
      );
    } catch (e) {
      debugPrint('[MESSAGE_RECEIVER] ⚠️ Failed to initiate recovery: $e');
    }
  }

  /// Initiate double ratchet recovery (for NoSession or BadMAC errors)
  Future<void> _initiateDoubleRatchetRecovery(
    SignalProtocolAddress senderAddress, {
    bool badMac = false,
  }) async {
    debugPrint('[MESSAGE_RECEIVER] 🔄 Initiating double ratchet recovery');

    try {
      final senderId = senderAddress.getName();
      final deviceId = senderAddress.getDeviceId();
      final recoveryKey = '$senderId:$deviceId';

      // Rate limiting
      final lastAttempt = _sessionRecoveryLastAttempt[recoveryKey];
      if (lastAttempt != null) {
        final timeSinceLastAttempt = DateTime.now().difference(lastAttempt);
        if (timeSinceLastAttempt.inSeconds < 30) {
          debugPrint(
            '[MESSAGE_RECEIVER] ⚠️ Recovery already attempted ${timeSinceLastAttempt.inSeconds}s ago - skipping',
          );
          return;
        }
      }

      _sessionRecoveryLastAttempt[recoveryKey] = DateTime.now();

      // Fetch sender's PreKeyBundle
      final bundles = await messageSender.fetchPreKeyBundleForUser(senderId);

      // Find bundle for specific device
      Map<String, dynamic>? bundle;
      try {
        bundle = bundles.firstWhere((b) => b['deviceId'] == deviceId);
      } catch (e) {
        bundle = null;
      }

      if (bundle == null) {
        debugPrint('[MESSAGE_RECEIVER] ✗ No bundle found for device $deviceId');
        return;
      }

      debugPrint('[MESSAGE_RECEIVER] ✓ Fetched sender\'s PreKeyBundle');

      // Build Signal PreKeyBundle
      final signalPreKeyBundle = PreKeyBundle(
        bundle['registrationId'],
        bundle['deviceId'],
        bundle['preKeyId'],
        bundle['preKeyPublic'],
        bundle['signedPreKeyId'],
        bundle['signedPreKeyPublic'],
        bundle['signedPreKeySignature'],
        bundle['identityKey'],
      );

      // Establish new session
      final sessionBuilder = SessionBuilder(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        senderAddress,
      );

      await sessionBuilder.processPreKeyBundle(signalPreKeyBundle);
      debugPrint('[MESSAGE_RECEIVER] ✓ New session established with sender');

      // Send system message to establish bidirectional session
      debugPrint('[MESSAGE_RECEIVER] 📤 Sending system:session_reset message');

      try {
        final recoveryReason = badMac
            ? 'bad_mac_recovery'
            : 'no_session_recovery';
        await messageSender.sendItem(
          recipientUserId: senderId,
          type: 'system:session_reset',
          payload: jsonEncode({
            'message':
                'Encryption session recovered. Your last sent messages may not have been decrypted. Consider resending recent messages.',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'reason': recoveryReason,
          }),
          forcePreKeyMessage: false,
        );

        debugPrint('[MESSAGE_RECEIVER] ✓ Session recovery complete');
      } catch (sendError) {
        debugPrint(
          '[MESSAGE_RECEIVER] ⚠️ Failed to send system message: $sendError',
        );
      }
    } catch (recoveryError) {
      debugPrint(
        '[MESSAGE_RECEIVER] ✗ Session recovery failed: $recoveryError',
      );
    }
  }

  /// Handle untrusted identity exception
  Future<void> _handleUntrustedIdentity(
    UntrustedIdentityException e,
    SignalProtocolAddress address,
  ) async {
    debugPrint(
      '[MESSAGE_RECEIVER] Auto-trusting new identity for ${address.getName()}',
    );

    // Fetch fresh PreKeyBundle with current identity key from server
    final userId = address.getName();
    final deviceId = address.getDeviceId();
    final bundles = await messageSender.fetchPreKeyBundleForUser(userId);
    final targetBundle = bundles.firstWhere(
      (b) => b['userId'] == userId && b['deviceId'] == deviceId,
      orElse: () => throw Exception('No bundle found for $userId:$deviceId'),
    );

    // Extract and save the new identity key
    final newIdentityKey = targetBundle['identityKey'] as IdentityKey;
    await identityStore.saveIdentity(address, newIdentityKey);

    // Delete old session to force rebuild
    if (await sessionStore.containsSession(address)) {
      await sessionStore.deleteSession(address);
    }

    debugPrint('[MESSAGE_RECEIVER] ✓ Identity trusted and session reset');
  }
}
