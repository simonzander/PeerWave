import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../../sender_key_store.dart';
import '../../permanent_identity_key_store.dart';
import '../../socket_service.dart';
import '../../storage/sqlite_message_store.dart';
import '../../sent_group_items_store.dart';
import 'encryption_service.dart';

/// Service for group message encryption and sending with sender keys
///
/// Handles:
/// - Sender key creation and distribution
/// - Group message encryption
/// - Sender key rotation and validation
/// - Server-based sender key backup/storage
///
/// Dependencies:
/// - EncryptionService: For identity store and group cipher operations
///
/// Usage:
/// ```dart
/// // Self-initializing factory
/// final groupSender = await GroupMessageSender.create(
///   encryptionService: encryptionService,
///   getCurrentUserId: () => userId,
///   getCurrentDeviceId: () => deviceId,
///   waitForRegenerationIfNeeded: () async {},
/// );
/// ```
class GroupMessageSender {
  final EncryptionService encryptionService;
  SentGroupItemsStore? _sentGroupItemsStore;

  final String? Function() getCurrentUserId;
  final int? Function() getCurrentDeviceId;
  final Future<void> Function() waitForRegenerationIfNeeded;

  bool _initialized = false;

  // Delegate to EncryptionService for crypto stores
  PermanentSenderKeyStore get senderKeyStore =>
      encryptionService.senderKeyStore;
  PermanentIdentityKeyStore get identityStore =>
      encryptionService.identityStore;

  // Getter for message store
  SentGroupItemsStore get sentGroupItemsStore {
    if (_sentGroupItemsStore == null)
      throw StateError('GroupMessageSender not initialized');
    return _sentGroupItemsStore!;
  }

  bool get isInitialized => _initialized;

  // Private constructor
  GroupMessageSender._({
    required this.encryptionService,
    required this.getCurrentUserId,
    required this.getCurrentDeviceId,
    required this.waitForRegenerationIfNeeded,
  });

  /// Self-initializing factory
  static Future<GroupMessageSender> create({
    required EncryptionService encryptionService,
    required String? Function() getCurrentUserId,
    required int? Function() getCurrentDeviceId,
    required Future<void> Function() waitForRegenerationIfNeeded,
  }) async {
    final service = GroupMessageSender._(
      encryptionService: encryptionService,
      getCurrentUserId: getCurrentUserId,
      getCurrentDeviceId: getCurrentDeviceId,
      waitForRegenerationIfNeeded: waitForRegenerationIfNeeded,
    );
    await service.init();
    return service;
  }

  /// Initialize stores (only sentGroupItemsStore - crypto stores from EncryptionService)
  Future<void> init() async {
    if (_initialized) {
      debugPrint('[GROUP_SENDER] Already initialized');
      return;
    }

    debugPrint('[GROUP_SENDER] Initializing message store...');

    _sentGroupItemsStore = await SentGroupItemsStore.getInstance();

    debugPrint('[GROUP_SENDER] ✓ Initialized');
    _initialized = true;
  }

  // ============================================================================
  // SENDER KEY CREATION & DISTRIBUTION
  // ============================================================================

  /// Create sender key for group and broadcast distribution message
  ///
  /// Creates a new sender key if none exists, or verifies existing key.
  /// For channels (non-meetings), stores key on server and broadcasts distribution message.
  ///
  /// Returns: Serialized sender key distribution message
  Future<Uint8List> createGroupSenderKey(
    String groupId, {
    bool broadcastDistribution = true,
  }) async {
    final currentUserId = getCurrentUserId();
    final currentDeviceId = getCurrentDeviceId();

    if (currentUserId == null || currentDeviceId == null) {
      throw Exception('User info not set. Call setCurrentUserInfo first.');
    }

    final senderAddress = SignalProtocolAddress(currentUserId, currentDeviceId);
    final senderKeyName = SenderKeyName(groupId, senderAddress);

    // Check if sender key already exists and is functional
    try {
      final hasSenderKey = await senderKeyStore.containsSenderKey(
        senderKeyName,
      );

      if (hasSenderKey) {
        debugPrint(
          '[GROUP_SENDER] Sender key already exists for group $groupId',
        );

        // Test if the key is functional (not corrupted)
        try {
          final testCipher = GroupCipher(senderKeyStore, senderKeyName);
          final testMessage = Uint8List.fromList([0x01, 0x02, 0x03]);
          await testCipher.encrypt(testMessage);
          debugPrint('[GROUP_SENDER] Existing sender key is functional');
          // Return empty bytes to indicate key already existed
          return Uint8List(0);
        } on Exception catch (testError) {
          debugPrint(
            '[GROUP_SENDER] ⚠️ Existing sender key is corrupted: $testError',
          );
          debugPrint(
            '[GROUP_SENDER] Deleting corrupted key and regenerating...',
          );
          await senderKeyStore.removeSenderKey(senderKeyName);
          // Fall through to create new key
        }
      }
    } on Exception catch (e) {
      debugPrint('[GROUP_SENDER] Error checking existing sender key: $e');
    }

    // Verify identity key pair before creating sender key
    try {
      final identityKeyPair = await identityStore.getIdentityKeyPair();
      final privateKeyBytes = identityKeyPair.getPrivateKey().serialize();

      if (privateKeyBytes.isEmpty) {
        throw Exception(
          'Identity private key is empty - cannot create sender key',
        );
      }

      debugPrint('[GROUP_SENDER] Identity key pair verified');

      // Auto-recovery: If we somehow have no identity but Signal is initialized,
      // this is a critical error that requires full re-initialization
      if (privateKeyBytes.length < 32) {
        throw Exception(
          'Identity key pair is corrupted (key too short). '
          'Please log out and log back in to regenerate keys.',
        );
      }
    } catch (e) {
      throw Exception(
        'Cannot create sender key: Identity key pair missing or corrupted. '
        'Please log out and log back in. Error: $e',
      );
    }

    // Verify sender key store is initialized
    try {
      await senderKeyStore.loadSenderKey(senderKeyName);
      debugPrint('[GROUP_SENDER] Sender key store is accessible');
    } catch (e) {
      // This is expected to fail if no sender key exists yet - that's normal
      if (e.toString().contains('not found') ||
          e.toString().contains('No sender key')) {
        debugPrint(
          '[GROUP_SENDER] No existing sender key found (normal for first message)',
        );
      } else {
        debugPrint('[GROUP_SENDER] ⚠️ Unexpected sender key store error: $e');
        debugPrint('[GROUP_SENDER] This may indicate storage corruption');
        throw Exception(
          'Cannot create sender key: Sender key store error. '
          'Storage may be corrupted. Try clearing app data. Error: $e',
        );
      }
    }

    try {
      debugPrint(
        '[GROUP_SENDER] Created SenderKeyName for group $groupId, address ${senderAddress.getName()}:${senderAddress.getDeviceId()}',
      );

      final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);
      debugPrint('[GROUP_SENDER] Created GroupSessionBuilder');

      // Create sender key distribution message
      debugPrint('[GROUP_SENDER] Calling groupSessionBuilder.create()...');
      final distributionMessage = await groupSessionBuilder.create(
        senderKeyName,
      );
      debugPrint('[GROUP_SENDER] Successfully created distribution message');

      final serialized = distributionMessage.serialize();
      debugPrint(
        '[GROUP_SENDER] Serialized distribution message, length: ${serialized.length}',
      );

      debugPrint('[GROUP_SENDER] Created sender key for group $groupId');

      // Check if this is a meeting or instant call
      // Meetings and calls use 1:1 Signal sessions, not SenderKey protocol
      final isMeeting =
          groupId.startsWith('mtg_') || groupId.startsWith('call_');

      if (isMeeting) {
        debugPrint(
          '[GROUP_SENDER] Meeting/call detected ($groupId) - skipping server SenderKey storage',
        );
        debugPrint(
          '[GROUP_SENDER] Meetings use 1:1 Signal sessions for encryption, not group SenderKeys',
        );
        // Return early - no server storage or broadcast needed for meetings
        return serialized;
      }

      // Store sender key on server for backup/retrieval (CHANNELS ONLY)
      // Skip if serialized is empty (key already existed)
      if (serialized.isNotEmpty) {
        try {
          final senderKeyBase64 = base64Encode(serialized);
          SocketService().emit('storeSenderKey', {
            'groupId': groupId,
            'senderKey': senderKeyBase64,
          });
          debugPrint(
            '[GROUP_SENDER] Stored sender key on server for channel $groupId',
          );
        } catch (e) {
          debugPrint(
            '[GROUP_SENDER] Warning: Failed to store sender key on server: $e',
          );
          // Don't fail - sender key is already stored locally
        }
      }

      // Broadcast distribution message to all group members (CHANNELS ONLY)
      // Skip if serialized is empty (key already existed)
      if (broadcastDistribution && serialized.isNotEmpty) {
        try {
          debugPrint(
            '[GROUP_SENDER] Broadcasting sender key distribution message...',
          );
          SocketService().emit('broadcastSenderKey', {
            'groupId': groupId,
            'distributionMessage': base64Encode(serialized),
          });
          debugPrint(
            '[GROUP_SENDER] ✓ Sender key distribution message broadcast to channel',
          );
        } catch (e) {
          debugPrint(
            '[GROUP_SENDER] Warning: Failed to broadcast distribution message: $e',
          );
          // Don't fail - recipients can still request it from server
        }
      }

      return serialized;
    } catch (e, stackTrace) {
      debugPrint('[GROUP_SENDER] Error in createGroupSenderKey: $e');
      debugPrint('[GROUP_SENDER] Stack trace: $stackTrace');
      rethrow;
    }
  }

  // ============================================================================
  // GROUP MESSAGE ENCRYPTION
  // ============================================================================

  /// Encrypt message for group using sender key protocol
  ///
  /// Returns map with:
  /// - ciphertext: Base64-encoded encrypted message
  /// - senderId: Current user ID
  /// - senderDeviceId: Current device ID
  Future<Map<String, dynamic>> encryptGroupMessage(
    String groupId,
    String message,
  ) async {
    // 🔒 SYNC-LOCK: Wait if identity regeneration is in progress
    await waitForRegenerationIfNeeded();

    final currentUserId = getCurrentUserId();
    final currentDeviceId = getCurrentDeviceId();

    if (currentUserId == null || currentDeviceId == null) {
      throw Exception('User info not set. Call setCurrentUserInfo first.');
    }

    debugPrint(
      '[GROUP_SENDER] encryptGroupMessage: groupId=$groupId, userId=$currentUserId:$currentDeviceId, messageLength=${message.length}',
    );

    try {
      final senderAddress = SignalProtocolAddress(
        currentUserId,
        currentDeviceId,
      );
      debugPrint(
        '[GROUP_SENDER] Created sender address: ${senderAddress.getName()}:${senderAddress.getDeviceId()}',
      );

      final senderKeyName = SenderKeyName(groupId, senderAddress);
      debugPrint('[GROUP_SENDER] Created sender key name for group $groupId');

      // Check if sender key exists
      final hasSenderKey = await senderKeyStore.containsSenderKey(
        senderKeyName,
      );
      debugPrint('[GROUP_SENDER] Sender key exists: $hasSenderKey');

      if (!hasSenderKey) {
        throw Exception(
          'No sender key found for this group. Please initialize sender key first.',
        );
      }

      // Load the sender key record to verify it's valid
      await senderKeyStore.loadSenderKey(senderKeyName);
      debugPrint('[GROUP_SENDER] Loaded sender key record from store');

      // Validate identity key pair exists before encryption (required for signing)
      try {
        final identityKeyPair = await identityStore.getIdentityKeyPair();
        if (identityKeyPair.getPrivateKey().serialize().isEmpty) {
          throw Exception(
            'Identity private key is empty - cannot sign sender key messages',
          );
        }
        debugPrint('[GROUP_SENDER] Identity key pair validated for signing');
      } catch (e) {
        throw Exception(
          'Identity key pair missing or corrupted: $e. Please regenerate Signal Protocol keys.',
        );
      }

      // ⚠️ CRITICAL: Test sender key validity BEFORE creating GroupCipher
      // This prevents RangeError by detecting corrupted keys early
      debugPrint(
        '[GROUP_SENDER] Testing sender key validity with dummy encryption...',
      );
      try {
        final testCipher = GroupCipher(senderKeyStore, senderKeyName);
        final testMessage = Uint8List.fromList([0x01, 0x02, 0x03]);
        await testCipher.encrypt(testMessage);
        debugPrint('[GROUP_SENDER] ✓ Sender key validation passed');
      } catch (validationError) {
        debugPrint(
          '[GROUP_SENDER] ⚠️ Sender key validation FAILED: $validationError',
        );
        // Trigger RangeError handler to regenerate key
        throw RangeError(
          'Sender key corrupted - validation test failed: $validationError',
        );
      }

      // ✨ ROTATION CHECK: Check if sender key needs rotation (7 days or 1000 messages)
      final needsRotation = await senderKeyStore.needsRotation(senderKeyName);
      if (needsRotation) {
        debugPrint(
          '[GROUP_SENDER] 🔄 Sender key needs rotation - regenerating...',
        );
        try {
          // Remove old key
          await senderKeyStore.removeSenderKey(senderKeyName);

          // Create new sender key and broadcast
          await createGroupSenderKey(groupId, broadcastDistribution: true);
          debugPrint(
            '[GROUP_SENDER] ✓ Sender key rotated successfully for group $groupId',
          );
        } catch (rotationError) {
          debugPrint(
            '[GROUP_SENDER] ⚠️ Warning: Sender key rotation failed: $rotationError',
          );
          // Don't fail the message - continue with existing key if rotation fails
        }
      }

      final groupCipher = GroupCipher(senderKeyStore, senderKeyName);
      debugPrint('[GROUP_SENDER] Created GroupCipher');

      final messageBytes = Uint8List.fromList(utf8.encode(message));
      debugPrint(
        '[GROUP_SENDER] Encoded message to bytes, length: ${messageBytes.length}',
      );

      debugPrint('[GROUP_SENDER] Calling groupCipher.encrypt()...');
      final ciphertext = await groupCipher.encrypt(messageBytes);
      debugPrint(
        '[GROUP_SENDER] Successfully encrypted message, ciphertext length: ${ciphertext.length}',
      );

      // Increment message count for rotation tracking
      await senderKeyStore.incrementMessageCount(senderKeyName);

      return {
        'ciphertext': base64Encode(ciphertext),
        'senderId': currentUserId,
        'senderDeviceId': currentDeviceId,
      };
    } on RangeError catch (e) {
      // RangeError during encryption typically means sender key chain is corrupted
      // This can happen if the key was created but signing key state is empty
      debugPrint(
        '[GROUP_SENDER] RangeError during encryption - sender key chain corrupted: $e',
      );
      debugPrint('[GROUP_SENDER] Attempting to recover sender key...');

      try {
        final currentUserId = getCurrentUserId();
        final currentDeviceId = getCurrentDeviceId();

        final senderAddress = SignalProtocolAddress(
          currentUserId!,
          currentDeviceId!,
        );
        final senderKeyName = SenderKeyName(groupId, senderAddress);

        // Delete corrupted local key
        await senderKeyStore.removeSenderKey(senderKeyName);
        debugPrint('[GROUP_SENDER] Removed corrupted local sender key');

        // Regenerate new sender key
        debugPrint('[GROUP_SENDER] Generating new sender key...');
        await createGroupSenderKey(groupId, broadcastDistribution: true);
        debugPrint(
          '[GROUP_SENDER] ✓ Created and broadcast new sender key for group $groupId',
        );

        // Retry encryption with new key
        final messageBytes = Uint8List.fromList(utf8.encode(message));
        final newGroupCipher = GroupCipher(senderKeyStore, senderKeyName);
        final ciphertext = await newGroupCipher.encrypt(messageBytes);
        debugPrint('[GROUP_SENDER] ✓ Successfully encrypted with new key');

        return {
          'ciphertext': base64Encode(ciphertext),
          'senderId': currentUserId,
          'senderDeviceId': currentDeviceId,
        };
      } catch (recoveryError) {
        debugPrint(
          '[GROUP_SENDER] ❌ Failed to recover from corrupted sender key: $recoveryError',
        );
        throw Exception(
          'Sender key chain corrupted and recovery failed. Please leave and rejoin the channel. Original error: $e',
        );
      }
    } catch (e, stackTrace) {
      debugPrint('[GROUP_SENDER] Error in encryptGroupMessage: $e');
      debugPrint('[GROUP_SENDER] Stack trace: $stackTrace');

      // ⚠️ DO NOT attempt automatic recovery for non-RangeError exceptions

      rethrow;
    }
  }

  // ============================================================================
  // HIGH-LEVEL API (with storage)
  // ============================================================================

  /// Send encrypted group item to channel
  ///
  /// Encrypts the message, stores locally, and broadcasts via Socket.IO
  Future<void> sendGroupItem({
    required String channelId,
    required String message,
    required String itemId,
    String type = 'message',
    Map<String, dynamic>?
    metadata, // Optional metadata (for image/voice messages)
  }) async {
    try {
      final currentUserId = getCurrentUserId();
      final currentDeviceId = getCurrentDeviceId();

      if (currentUserId == null || currentDeviceId == null) {
        throw Exception('User not authenticated');
      }

      // Encrypt with sender key
      final encrypted = await encryptGroupMessage(channelId, message);
      final timestamp = DateTime.now().toIso8601String();

      // ✅ PHASE 4: Skip storage for system message types
      const skipStorageTypes = {
        'fileKeyResponse',
        'senderKeyDistribution',
        'video_e2ee_key_request', // Video E2EE key exchange (ephemeral)
        'video_e2ee_key_response', // Video E2EE key exchange (ephemeral)
        'video_key_request', // Legacy video key request (ephemeral)
        'video_key_response', // Legacy video key response (ephemeral)
      };

      final shouldStore = !skipStorageTypes.contains(type);

      // Store locally first (unless it's a system message)
      if (shouldStore) {
        // Store in old store for backward compatibility (temporary)
        await sentGroupItemsStore.storeSentGroupItem(
          channelId: channelId,
          itemId: itemId,
          message: message,
          timestamp: timestamp,
          type: type,
          status: 'sending',
        );

        // ALSO store in new SQLite database for performance
        try {
          final messageStore = await SqliteMessageStore.getInstance();
          await messageStore.storeSentMessage(
            itemId: itemId,
            recipientId:
                channelId, // Store channelId as recipientId for group messages
            channelId: channelId,
            message: message,
            timestamp: timestamp,
            type: type,
            metadata: metadata,
          );
          debugPrint('[GROUP_SENDER] Stored group item $itemId in SQLite');
        } catch (e) {
          debugPrint(
            '[GROUP_SENDER] ✗ Failed to store group item in SQLite: $e',
          );
        }

        debugPrint('[GROUP_SENDER] Stored group item $itemId locally');
      } else {
        debugPrint(
          '[GROUP_SENDER] Skipping storage for system message type: $type',
        );
      }

      // Send via Socket.IO (always send, even if not stored)
      SocketService().emit("sendGroupItem", {
        'channelId': channelId,
        'itemId': itemId,
        'type': type,
        'payload': encrypted['ciphertext'],
        'cipherType': 4, // Sender Key
        'timestamp': timestamp,
      });

      debugPrint(
        '[GROUP_SENDER] Sent group item $itemId to channel $channelId',
      );
    } catch (e) {
      debugPrint('[GROUP_SENDER] Error sending group item: $e');
      rethrow;
    }
  }

  // ============================================================================
  // SERVER-BASED SENDER KEY MANAGEMENT
  // ============================================================================

  /// Upload our sender key to server
  Future<void> uploadSenderKeyToServer(String channelId) async {
    try {
      final currentUserId = getCurrentUserId();
      final currentDeviceId = getCurrentDeviceId();

      if (currentUserId == null || currentDeviceId == null) {
        throw Exception('User not authenticated');
      }

      final senderAddress = SignalProtocolAddress(
        currentUserId,
        currentDeviceId,
      );
      final senderKeyName = SenderKeyName(channelId, senderAddress);

      // Load sender key
      final senderKeyRecord = await senderKeyStore.loadSenderKey(senderKeyName);

      // Extract distribution message
      final distributionMessage = senderKeyRecord.serialize();
      final senderKeyBase64 = base64Encode(distributionMessage);

      // Upload to server
      SocketService().emit('storeSenderKey', {
        'groupId': channelId,
        'senderKey': senderKeyBase64,
      });

      debugPrint(
        '[GROUP_SENDER] Uploaded sender key to server for channel $channelId',
      );
    } catch (e) {
      debugPrint('[GROUP_SENDER] Error uploading sender key to server: $e');
      rethrow;
    }
  }

  /// Request sender key from specific user (for direct P2P)
  Future<void> requestSenderKey({
    required String groupId,
    required String fromUserId,
  }) async {
    try {
      debugPrint(
        '[GROUP_SENDER] Requesting sender key from $fromUserId for group $groupId',
      );

      SocketService().emit('requestSenderKey', {
        'groupId': groupId,
        'fromUserId': fromUserId,
      });

      debugPrint('[GROUP_SENDER] Sender key request sent');
    } catch (e) {
      debugPrint('[GROUP_SENDER] Error requesting sender key: $e');
      rethrow;
    }
  }
}
