import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../../../../socket_service.dart'
    if (dart.library.io) '../../../../socket_service_native.dart';
import '../../../../storage/sqlite_group_message_store.dart';
import '../../../../api_service.dart';
import '../../../../../core/events/event_bus.dart' as app_events;
import '../../encryption_service.dart';
import '../../key_manager.dart';
import '../../session_manager.dart';

/// Mixin for group messaging operations
mixin GroupMessagingMixin {
  // Required getters from main service
  EncryptionService get encryptionService;
  SocketService get socketService;
  ApiService get apiService;
  String get currentUserId;
  int get currentDeviceId;

  SignalKeyManager get senderKeyStore;
  SqliteGroupMessageStore get groupMessageStore;

  // SessionManager for establishing 1-to-1 sessions with group members
  // (needed for sender key distribution)
  SessionManager get sessionStore;

  // Queue for messages waiting on sender keys
  // Key: "groupId:senderId:deviceId", Value: List of pending messages
  static final Map<String, List<Map<String, dynamic>>>
  _pendingSenderKeyMessages = {};

  // Track when we last sent our sender key to each device
  // Key: "groupId:userId:deviceId", Value: timestamp
  // 1-hour deduplication window (in-memory, reset on app restart)
  static final Map<String, DateTime> _lastSenderKeySentToDevice = {};

  static const int _senderKeyConcurrency = 15;

  List<Map<String, dynamic>> _filterMembersByActive(
    List<dynamic> members,
    List<String>? activeMemberIds,
  ) {
    if (activeMemberIds == null) {
      return members.cast<Map<String, dynamic>>();
    }

    final activeSet = activeMemberIds.toSet();
    return members
        .where((member) => activeSet.contains(member['userId']))
        .cast<Map<String, dynamic>>()
        .toList();
  }

  Future<void> _runWithConcurrency(
    List<Future<void> Function()> tasks,
    int concurrency,
  ) async {
    for (var i = 0; i < tasks.length; i += concurrency) {
      final batch = tasks
          .skip(i)
          .take(concurrency)
          .map((task) => task())
          .toList();
      await Future.wait(batch);
    }
  }

  /// Send encrypted group message using sender keys
  ///
  /// Handles:
  /// - Sender key creation and distribution
  /// - Group message encryption
  /// - Sender key rotation when needed
  /// - Local message storage
  Future<String> sendGroupMessage({
    required String channelId,
    required String message,
    String? itemId,
  }) async {
    final generatedItemId = itemId ?? const Uuid().v4();

    debugPrint('[GROUP] Sending message to $channelId');

    try {
      // Ensure sender key exists
      await ensureSenderKeyForGroup(channelId, applyDeviceCap: true);

      // Encrypt with sender key
      final encrypted = await encryptGroupMessage(channelId, message);

      // Send to server
      final data = {
        'channelId': channelId,
        'itemId': generatedItemId,
        'payload':
            encrypted['ciphertext'], // Server expects 'payload', not 'message'
        'cipherType': 4, // Sender Key
        'timestamp': DateTime.now().toIso8601String(),
        'type': 'message',
      };

      socketService.emit("sendGroupItem", data);

      // Store locally
      await groupMessageStore.storeSentGroupItem(
        itemId: generatedItemId,
        channelId: channelId,
        message: message,
        timestamp: data['timestamp'] as String,
        type: 'message',
      );

      debugPrint('[GROUP] ✓ Message sent: $generatedItemId');
      return generatedItemId;
    } catch (e, stackTrace) {
      debugPrint('[GROUP] ❌ Failed to send message: $e');
      debugPrint('[GROUP] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Ensure sender key exists for group
  ///
  /// Parameters:
  /// - [groupId]: The group/channel ID
  /// - [force]: Force redistribution regardless of deduplication metadata (default: false)
  ///            Used in PreJoin to ensure keys are sent to all participants
  Future<void> ensureSenderKeyForGroup(
    String groupId, {
    bool force = false,
    List<String>? activeMemberIds,
    bool applyDeviceCap = false,
  }) async {
    final myAddress = SignalProtocolAddress(currentUserId, currentDeviceId);
    final senderKeyName = SenderKeyName(groupId, myAddress);

    // Check if we have a sender key
    final hasSenderKey = await senderKeyStore.containsSenderKey(senderKeyName);

    if (!hasSenderKey) {
      debugPrint('[GROUP] Creating sender key for group $groupId');
      await createAndDistributeSenderKey(
        groupId,
        activeMemberIds: activeMemberIds,
        applyDeviceCap: applyDeviceCap,
      );

      // Verify it was created successfully
      final verified = await senderKeyStore.containsSenderKey(senderKeyName);
      if (!verified) {
        throw Exception('Failed to create sender key for group $groupId');
      }
      debugPrint('[GROUP] ✓ Sender key created and verified');
    } else {
      debugPrint('[GROUP] Sender key already exists for group $groupId');
      // Check if any members need our sender key (targeted distribution)
      if (force) {
        debugPrint('[GROUP] Force=true: Redistributing to all members...');
      } else {
        debugPrint('[GROUP] Checking which members need our sender key...');
      }
      await _sendSenderKeyToMembersWeNeedKeysFrom(
        groupId,
        force: force,
        activeMemberIds: activeMemberIds,
        applyDeviceCap: applyDeviceCap,
      );
    }
  }

  /// Send our sender key to members we don't have sender keys from
  ///
  /// This is called before sending each message to ensure bidirectional key exchange.
  /// Uses 1-hour deduplication per device to avoid redundant sends.
  ///
  /// Parameters:
  /// - [groupId]: The group/channel ID
  /// - [force]: Bypass deduplication and send to all members (default: false)
  Future<void> _sendSenderKeyToMembersWeNeedKeysFrom(
    String groupId, {
    bool force = false,
    List<String>? activeMemberIds,
    bool applyDeviceCap = false,
  }) async {
    try {
      debugPrint('[GROUP] Checking if any members need our sender key...');

      // Fetch group members
      final membersResponse = await apiService.get(
        '/api/channels/$groupId/members',
      );
      if (membersResponse.statusCode != 200) {
        debugPrint(
          '[GROUP] ⚠️ Could not fetch members, skipping sender key check',
        );
        return;
      }

      final rawMembers = membersResponse.data is List
          ? membersResponse.data as List
          : (membersResponse.data as Map)['members'] as List? ?? [];
      final memberList = _filterMembersByActive(rawMembers, activeMemberIds);

      final now = DateTime.now();

      final tasks = <Future<void> Function()>[];

      for (final memberData in memberList) {
        final memberId = memberData['userId'] as String;

        // Skip own user
        if (memberId == currentUserId) continue;

        // Get device IDs for this member
        var deviceIds = await sessionStore.getDeviceIdsForUser(memberId);

        if (applyDeviceCap) {
          deviceIds = await sessionStore.filterActiveDeviceIds(
            memberId,
            deviceIds,
          );
        }

        if (deviceIds.isEmpty) {
          final established = await sessionStore.establishSessionWithUser(
            memberId,
            applyDeviceCap: applyDeviceCap,
          );

          if (established) {
            deviceIds = await sessionStore.getDeviceIdsForUser(memberId);
            if (applyDeviceCap) {
              deviceIds = await sessionStore.filterActiveDeviceIds(
                memberId,
                deviceIds,
              );
            }
          }
        }

        for (final deviceId in deviceIds) {
          // Check if we have their sender key
          final memberAddress = SignalProtocolAddress(memberId, deviceId);
          final memberSenderKeyName = SenderKeyName(groupId, memberAddress);
          final weHaveTheirKey = await senderKeyStore.containsSenderKey(
            memberSenderKeyName,
          );

          if (!weHaveTheirKey || force) {
            // We don't have their key, or force=true: send ours (with optional deduplication)
            final dedupeKey = '$groupId:$memberId:$deviceId';
            final lastSent = _lastSenderKeySentToDevice[dedupeKey];

            if (!force &&
                lastSent != null &&
                now.difference(lastSent).inHours < 1) {
              debugPrint(
                '[GROUP]   ⏭️ Skip $memberId:$deviceId (sent ${now.difference(lastSent).inMinutes}m ago)',
              );
              continue;
            }

            final reason = force ? 'forced redistribution' : 'we need theirs';
            debugPrint(
              '[GROUP]   → Sending sender key to $memberId:$deviceId ($reason)',
            );

            tasks.add(() async {
              try {
                await _sendSenderKeyToDevice(
                  groupId,
                  memberId,
                  deviceId,
                  applyDeviceCap: applyDeviceCap,
                );
                _lastSenderKeySentToDevice[dedupeKey] = now;
                debugPrint('[GROUP]   ✓ Sent to $memberId:$deviceId');
              } catch (e) {
                debugPrint(
                  '[GROUP]   ⚠️ Failed to send to $memberId:$deviceId: $e',
                );
              }
            });
          }
        }
      }

      await _runWithConcurrency(tasks, _senderKeyConcurrency);
    } catch (e) {
      debugPrint('[GROUP] ⚠️ Error checking sender keys: $e');
      // Don't throw - message can still be sent
    }
  }

  /// Create sender key and distribute to group (Signal Protocol compliant)
  ///
  /// Process:
  /// 1. Create sender key locally
  /// 2. Fetch group members from server
  /// 3. For each member, fetch ALL their devices
  /// 4. Establish 1-to-1 sessions with each device (if needed)
  /// 5. Encrypt distribution message individually for each device
  /// 6. Send encrypted copies to each device (skip own devices)
  Future<void> createAndDistributeSenderKey(
    String groupId, {
    List<String>? activeMemberIds,
    bool applyDeviceCap = false,
  }) async {
    final myAddress = SignalProtocolAddress(currentUserId, currentDeviceId);
    final senderKeyName = SenderKeyName(groupId, myAddress);

    debugPrint('[GROUP] Creating sender key for group $groupId');

    // Step 1: Create sender key distribution message
    // This also creates and stores the sender key internally
    final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);
    final distributionMessage = await groupSessionBuilder.create(senderKeyName);
    final distributionBytes = distributionMessage.serialize();

    debugPrint('[GROUP] ✓ Sender key created locally');

    // Step 2: Fetch group members
    final membersResponse = await apiService.get(
      '/api/channels/$groupId/members',
    );

    if (membersResponse.statusCode != 200) {
      throw Exception(
        'Failed to fetch group members: ${membersResponse.statusCode}',
      );
    }

    // Handle both List and Map responses
    final rawMembers = membersResponse.data is List
        ? membersResponse.data as List
        : (membersResponse.data as Map)['members'] as List? ?? [];
    final memberList = _filterMembersByActive(rawMembers, activeMemberIds);

    debugPrint('[GROUP] Fetched ${memberList.length} group members');

    int successCount = 0;
    int failCount = 0;

    // Step 3-6: For each member, establish sessions and distribute to all devices
    final tasks = <Future<void> Function()>[];

    for (final memberData in memberList) {
      try {
        final memberId = memberData['userId'] as String;

        debugPrint('[GROUP] Processing member: $memberId');
        debugPrint(
          '[GROUP]   currentUserId=$currentUserId, memberId=$memberId, equal=${memberId == currentUserId}',
        );

        // Skip ALL of our own devices (multi-device support)
        if (memberId == currentUserId) {
          debugPrint('[GROUP]   Skipping own user (all devices)');
          continue;
        }

        // Step 3: Get device IDs from local session storage
        var deviceIds = await sessionStore.getDeviceIdsForUser(memberId);

        if (applyDeviceCap) {
          deviceIds = await sessionStore.filterActiveDeviceIds(
            memberId,
            deviceIds,
          );
        }

        if (deviceIds.isEmpty) {
          debugPrint('[GROUP]   Fetching prekey bundles for $memberId...');
          final bundlesEstablished = await sessionStore
              .establishSessionWithUser(
                memberId,
                applyDeviceCap: applyDeviceCap,
              );

          if (!bundlesEstablished) {
            debugPrint(
              '[GROUP]   ✗ Failed to fetch prekey bundles for $memberId',
            );
            failCount++;
            continue;
          }

          deviceIds = await sessionStore.getDeviceIdsForUser(memberId);
          if (applyDeviceCap) {
            deviceIds = await sessionStore.filterActiveDeviceIds(
              memberId,
              deviceIds,
            );
          }
        }

        if (deviceIds.isEmpty) {
          debugPrint('[GROUP]   ✗ No devices found for $memberId');
          failCount++;
          continue;
        }

        // Step 5-6: Encrypt and send to each device
        // SessionCipher.encrypt() automatically:
        // - Returns PreKeySignalMessage if no session (establishes session)
        // - Returns SignalMessage if session exists
        // This bundles session establishment with sender key distribution!
        for (final deviceId in deviceIds) {
          tasks.add(() async {
            try {
              debugPrint('[GROUP]     Distributing to $memberId:$deviceId');

              // Encrypt distribution message for this specific device
              final memberAddress = SignalProtocolAddress(memberId, deviceId);
              final sessionCipher = sessionStore.createSessionCipher(
                memberAddress,
              );
              final encryptedDistribution = await sessionCipher.encrypt(
                distributionBytes,
              );

              // Send encrypted distribution via HTTP
              final response = await apiService.post(
                '/api/signal/distribute-sender-key',
                data: {
                  'groupId': groupId,
                  'recipientId': memberId,
                  'recipientDeviceId': deviceId,
                  'encryptedDistribution': base64Encode(
                    encryptedDistribution.serialize(),
                  ),
                  'messageType': encryptedDistribution.getType(),
                },
              );

              if (response.statusCode == 200 || response.statusCode == 201) {
                successCount++;
                debugPrint(
                  '[GROUP]       ✓ Distributed to $memberId:$deviceId',
                );

                // Update deduplication cache to prevent reciprocal loops
                final dedupeKey = '$groupId:$memberId:$deviceId';
                _lastSenderKeySentToDevice[dedupeKey] = DateTime.now();
              } else {
                debugPrint(
                  '[GROUP]       ✗ Failed (HTTP ${response.statusCode})',
                );
                failCount++;
              }
            } catch (e) {
              debugPrint('[GROUP]     ✗ Error with device: $e');
              failCount++;
            }
          });
        }
      } catch (e) {
        debugPrint('[GROUP]   ✗ Failed to process member: $e');
        failCount++;
      }
    }

    await _runWithConcurrency(tasks, _senderKeyConcurrency);

    debugPrint(
      '[GROUP] ✓ Sender key distribution complete: $successCount succeeded, $failCount failed',
    );

    if (successCount == 0 && failCount > 0) {
      throw Exception('Failed to distribute sender key to any group members');
    }
  }

  /// Send sender key to a specific device
  /// Used when we don't have their sender key yet
  Future<void> _sendSenderKeyToDevice(
    String groupId,
    String userId,
    int deviceId, {
    bool applyDeviceCap = false,
  }) async {
    final myAddress = SignalProtocolAddress(currentUserId, currentDeviceId);
    final senderKeyName = SenderKeyName(groupId, myAddress);

    // Ensure we have a sender key (create if needed)
    final hasSenderKey = await senderKeyStore.containsSenderKey(senderKeyName);
    if (!hasSenderKey) {
      debugPrint('[GROUP] Creating sender key before sending to device');
      final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);
      await groupSessionBuilder.create(senderKeyName);
    }

    // Get the distribution message
    final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);
    final distributionMessage = await groupSessionBuilder.create(senderKeyName);
    final distributionBytes = distributionMessage.serialize();

    // Establish session with device (if not already established)
    await sessionStore.establishSessionWithUser(
      userId,
      applyDeviceCap: applyDeviceCap,
    );

    // Encrypt and send to device
    final deviceAddress = SignalProtocolAddress(userId, deviceId);
    final sessionCipher = sessionStore.createSessionCipher(deviceAddress);
    final encryptedDistribution = await sessionCipher.encrypt(
      distributionBytes,
    );

    // Send via HTTP
    await apiService.post(
      '/api/signal/distribute-sender-key',
      data: {
        'groupId': groupId,
        'recipientId': userId,
        'recipientDeviceId': deviceId,
        'encryptedDistribution': base64Encode(
          encryptedDistribution.serialize(),
        ),
        'messageType': encryptedDistribution.getType(),
      },
    );
  }

  /// Process incoming sender key distribution
  ///
  /// When we receive a sender key distribution from another user:
  /// 1. Decrypt the CiphertextMessage using SessionCipher (1-to-1 session)
  /// 2. Deserialize decrypted bytes as SenderKeyDistributionMessage
  /// 3. Store their sender key using GroupSessionBuilder
  /// 4. Process any queued messages from them
  /// 5. AUTOMATICALLY send OUR sender key back to them (reciprocal exchange)
  Future<void> processSenderKeyDistribution(
    String groupId,
    String senderId,
    int senderDeviceId,
    Uint8List encryptedDistributionBytes,
    int messageType,
  ) async {
    final senderAddress = SignalProtocolAddress(senderId, senderDeviceId);

    // Step 1: Decrypt the CiphertextMessage using SessionCipher
    // The sender key distribution is encrypted via 1-to-1 session
    debugPrint(
      '[GROUP] Decrypting sender key distribution from $senderId:$senderDeviceId (messageType: $messageType)',
    );

    final sessionCipher = sessionStore.createSessionCipher(senderAddress);

    Uint8List distributionMessageBytes;
    if (messageType == CiphertextMessage.prekeyType) {
      // PreKeySignalMessage - establishes new session
      final preKeyMsg = PreKeySignalMessage(encryptedDistributionBytes);
      distributionMessageBytes = await sessionCipher.decryptWithCallback(
        preKeyMsg,
        (plaintext) {}, // Callback not needed here
      );
    } else {
      // SignalMessage - uses existing session
      final signalMsg = SignalMessage.fromSerialized(
        encryptedDistributionBytes,
      );
      distributionMessageBytes = await sessionCipher.decryptFromSignal(
        signalMsg,
      );
    }

    // Step 2: Deserialize as SenderKeyDistributionMessage
    final senderKeyName = SenderKeyName(groupId, senderAddress);
    final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);

    final distributionMessage =
        SenderKeyDistributionMessageWrapper.fromSerialized(
          Uint8List.fromList(distributionMessageBytes),
        );

    // Step 3: Store the sender key
    await groupSessionBuilder.process(senderKeyName, distributionMessage);

    debugPrint(
      '[GROUP] ✓ Processed sender key from $senderId:$senderDeviceId for group $groupId',
    );

    // Step 4: Reciprocal exchange - send OUR sender key back to the sender
    // Only send to the specific device that sent us their key (not broadcast)
    // Check if they already have our key to prevent unnecessary sends
    try {
      // Check if User A already has our (User B's) sender key
      final ourAddress = SignalProtocolAddress(currentUserId, currentDeviceId);
      final ourSenderKeyName = SenderKeyName(groupId, ourAddress);
      final weHaveOurKey = await senderKeyStore.containsSenderKey(
        ourSenderKeyName,
      );

      if (!weHaveOurKey) {
        debugPrint(
          '[GROUP]   ⏭️ Skip reciprocal send - we don\'t have our own sender key yet',
        );
      } else {
        // Check deduplication timer to prevent loops
        final dedupeKey = '$groupId:$senderId:$senderDeviceId';
        final lastSent = _lastSenderKeySentToDevice[dedupeKey];
        final now = DateTime.now();

        if (lastSent != null && now.difference(lastSent).inHours < 1) {
          debugPrint(
            '[GROUP]   ⏭️ Skip reciprocal send to $senderId:$senderDeviceId (sent ${now.difference(lastSent).inMinutes}m ago)',
          );
        } else {
          debugPrint(
            '[GROUP]   → Sending OUR sender key back to $senderId:$senderDeviceId (reciprocal exchange)',
          );
          await _sendSenderKeyToDevice(groupId, senderId, senderDeviceId);
          _lastSenderKeySentToDevice[dedupeKey] = now;
          debugPrint(
            '[GROUP]   ✓ Reciprocal sender key sent to $senderId:$senderDeviceId',
          );
        }
      }
    } catch (e) {
      debugPrint('[GROUP]   ⚠️ Failed to send reciprocal sender key: $e');
      // Don't throw - we still processed their key successfully
    }

    // Step 5: Process any pending messages that were waiting for this sender key
    await _processPendingMessagesForSender(groupId, senderId, senderDeviceId);
  }

  /// Process pending messages that were waiting for a sender key
  Future<void> _processPendingMessagesForSender(
    String groupId,
    String senderId,
    int senderDeviceId,
  ) async {
    final queueKey = '$groupId:$senderId:$senderDeviceId';
    final pendingMessages = _pendingSenderKeyMessages[queueKey];

    if (pendingMessages == null || pendingMessages.isEmpty) {
      return;
    }

    debugPrint(
      '[GROUP] Processing ${pendingMessages.length} pending messages for $senderId:$senderDeviceId in $groupId',
    );

    // Remove from queue first to avoid infinite loops
    _pendingSenderKeyMessages.remove(queueKey);

    // Process each pending message
    for (final messageData in pendingMessages) {
      try {
        debugPrint(
          '[GROUP] Retrying pending message: ${messageData['itemId']}',
        );

        // Decrypt the message now that we have the sender key
        final plaintext = await decryptGroupMessage(
          messageData,
          senderId,
          senderDeviceId,
        );

        // Trigger the message processing callback
        final onMessageDecrypted =
            messageData['_onDecrypted'] as Function(String)?;
        if (onMessageDecrypted != null) {
          onMessageDecrypted(plaintext);
        }

        debugPrint(
          '[GROUP] ✓ Processed pending message: ${messageData['itemId']}',
        );
      } catch (e) {
        debugPrint('[GROUP] ✗ Failed to process pending message: $e');
      }
    }
  }

  /// Encrypt message for group using sender key
  Future<Map<String, dynamic>> encryptGroupMessage(
    String groupId,
    String message,
  ) async {
    final ciphertext = await encryptionService.encryptGroupMessage(
      groupId: groupId,
      currentUserId: currentUserId,
      currentDeviceId: currentDeviceId,
      message: message,
    );

    return {'ciphertext': ciphertext};
  }

  /// Decrypt group message using sender key
  Future<String> decryptGroupMessage(
    Map<String, dynamic> data,
    String sender,
    int senderDeviceId, {
    Function(String)? onDecrypted,
  }) async {
    final groupId = data['channel'] as String;
    final senderAddress = SignalProtocolAddress(sender, senderDeviceId);
    final senderKeyName = SenderKeyName(groupId, senderAddress);

    // Check if we have sender key
    final hasSenderKey = await senderKeyStore.containsSenderKey(senderKeyName);

    if (!hasSenderKey) {
      debugPrint(
        '[GROUP] Missing sender key - queueing message and requesting from server',
      );

      // Queue this message for processing once sender key arrives
      final queueKey = '$groupId:$sender:$senderDeviceId';
      _pendingSenderKeyMessages.putIfAbsent(queueKey, () => []);

      // Store callback with message data
      final messageData = Map<String, dynamic>.from(data);
      messageData['_onDecrypted'] = onDecrypted;
      _pendingSenderKeyMessages[queueKey]!.add(messageData);

      debugPrint(
        '[GROUP] Message queued (${_pendingSenderKeyMessages[queueKey]!.length} pending for $sender:$senderDeviceId)',
      );

      // Request sender key from the specific device, then fall back to server request
      try {
        await requestSenderKeyFromDevice(
          groupId: groupId,
          targetUserId: sender,
          targetDeviceId: senderDeviceId,
        );
      } catch (e) {
        debugPrint('[GROUP] ⚠️ Targeted sender key request failed: $e');
      }

      await requestSenderKey(groupId, sender, senderDeviceId);
      throw Exception('Sender key not available yet - message queued');
    }

    // Decrypt
    final encryptedData = data['payload'] as String;
    final plaintext = await encryptionService.decryptGroupMessage(
      groupId: groupId,
      senderAddress: senderAddress,
      encryptedData: encryptedData,
    );

    return plaintext;
  }

  /// Request sender key from server
  Future<void> requestSenderKey(
    String groupId,
    String userId,
    int deviceId,
  ) async {
    socketService.emit('requestSenderKey', {
      'groupId': groupId,
      'userId': userId,
      'deviceId': deviceId,
    });
  }

  /// Re-request sender keys for queued messages (best-effort, in-memory only).
  Future<void> retryPendingSenderKeyRequests() async {
    if (_pendingSenderKeyMessages.isEmpty) return;

    debugPrint(
      '[GROUP] Retrying sender key requests for ${_pendingSenderKeyMessages.length} pending entries',
    );

    final keys = _pendingSenderKeyMessages.keys.toList();
    for (final key in keys) {
      final parts = key.split(':');
      if (parts.length < 3) continue;

      final groupId = parts[0];
      final userId = parts[1];
      final deviceId = int.tryParse(parts[2]);
      if (deviceId == null) continue;

      try {
        await requestSenderKeyFromDevice(
          groupId: groupId,
          targetUserId: userId,
          targetDeviceId: deviceId,
        );
      } catch (e) {
        debugPrint('[GROUP] Retry targeted sender key request failed: $e');
      }

      try {
        await requestSenderKey(groupId, userId, deviceId);
      } catch (e) {
        debugPrint('[GROUP] Retry sender key request failed: $e');
      }
    }
  }

  // ========================================================================
  // Additional methods for screen compatibility (match old SignalService API)
  // ========================================================================

  /// Check if sender key exists for a specific user/device in group
  Future<bool> hasSenderKey(
    String channelId,
    String userId,
    int deviceId,
  ) async {
    final senderAddress = SignalProtocolAddress(userId, deviceId);
    final senderKeyName = SenderKeyName(channelId, senderAddress);
    return await senderKeyStore.containsSenderKey(senderKeyName);
  }

  /// Send group item with any type (message, file, emote, etc.)
  Future<String> sendGroupItem({
    required String channelId,
    required String message,
    required String itemId,
    String type = 'message',
    Map<String, dynamic>? metadata,
  }) async {
    debugPrint('[GROUP] Sending $type to $channelId');

    try {
      // Ensure sender key exists
      await ensureSenderKeyForGroup(channelId);

      // Encrypt with sender key
      final encrypted = await encryptGroupMessage(channelId, message);

      // Send to server
      final data = {
        'channelId': channelId,
        'itemId': itemId,
        'type': type,
        'payload': encrypted['ciphertext'],
        'cipherType': 4, // Sender Key
        'timestamp': DateTime.now().toIso8601String(),
      };

      socketService.emit("sendGroupItem", data);

      // Store locally (only for displayable types, skip ephemeral/system messages)
      const displayableTypes = {'message', 'file', 'image', 'voice'};
      const ephemeralTypes = {
        // E2EE key exchange
        'video_e2ee_key_request',
        'video_e2ee_key_response',
        // Signal Protocol control messages
        'read_receipt',
        'delivery_receipt',
        'senderKeyRequest',
        'fileKeyRequest',
        'signal:senderKeyDistribution',
        // Call signaling
        'call_notification',
      };

      if (displayableTypes.contains(type) && !ephemeralTypes.contains(type)) {
        await groupMessageStore.storeSentGroupItem(
          itemId: itemId,
          channelId: channelId,
          message: message,
          timestamp: data['timestamp'] as String,
          type: type,
        );
      } else if (ephemeralTypes.contains(type)) {
        debugPrint(
          '[GROUP] Skipping storage for ephemeral message type: $type',
        );
      }

      debugPrint('[GROUP] ✓ $type sent: $itemId');
      return itemId;
    } catch (e, stackTrace) {
      debugPrint('[GROUP] ❌ Failed to send $type: $e');
      debugPrint('[GROUP] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Mark group item as read
  void markGroupItemAsRead(String itemId) {
    socketService.emit('markGroupItemAsRead', {'itemId': itemId});
    debugPrint('[GROUP] Marked item as read: $itemId');
  }

  // ========================================================================
  // TARGETED SENDER KEY REQUEST/RESPONSE (On-Demand Exchange)
  // ========================================================================

  /// Request sender key from a specific device
  ///
  /// This sends a targeted request to a specific user:device that has the sender key.
  /// The recipient will respond by sending their sender key directly to us.
  ///
  /// Parameters:
  /// - [groupId]: The group/channel ID
  /// - [targetUserId]: User ID to request from
  /// - [targetDeviceId]: Device ID to request from
  Future<void> requestSenderKeyFromDevice({
    required String groupId,
    required String targetUserId,
    required int targetDeviceId,
  }) async {
    debugPrint(
      '[GROUP] Requesting sender key from $targetUserId:$targetDeviceId for group $groupId',
    );

    try {
      // Ensure we have our own sender key before requesting
      await ensureSenderKeyForGroup(groupId);

      // Send request via sendGroupItem (encrypted with sender key)
      final requestId = const Uuid().v4();
      await sendGroupItem(
        channelId: groupId,
        message: jsonEncode({
          'requesterId': currentUserId,
          'requesterDeviceId': currentDeviceId,
          'targetUserId': targetUserId,
          'targetDeviceId': targetDeviceId,
          'groupId': groupId,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
        itemId: requestId,
        type: 'sender_key_request',
      );

      debugPrint(
        '[GROUP] ✓ Sender key request sent to $targetUserId:$targetDeviceId',
      );
    } catch (e) {
      debugPrint('[GROUP] ❌ Failed to request sender key: $e');
      rethrow;
    }
  }

  /// Handle incoming sender key request
  ///
  /// When we receive a request for our sender key, send it directly to the requester.
  /// This bypasses deduplication to ensure the requester gets the key immediately.
  ///
  /// Parameters:
  /// - [requestData]: Decoded request message containing requester info
  Future<void> handleSenderKeyRequest(Map<String, dynamic> requestData) async {
    final String requesterId = requestData['requesterId'] as String;
    final int requesterDeviceId = requestData['requesterDeviceId'] as int;
    final String groupId = requestData['groupId'] as String;
    final String targetUserId = requestData['targetUserId'] as String;
    final int targetDeviceId = requestData['targetDeviceId'] as int;

    debugPrint(
      '[GROUP] 📨 Sender key request received from $requesterId:$requesterDeviceId',
    );

    // Check if this request is for us
    if (targetUserId != currentUserId || targetDeviceId != currentDeviceId) {
      debugPrint(
        '[GROUP]   ⏭️ Request not for us (target: $targetUserId:$targetDeviceId, us: $currentUserId:$currentDeviceId)',
      );
      return;
    }

    try {
      // Ensure we have our sender key
      await ensureSenderKeyForGroup(groupId);

      // Send our sender key to the requester (bypass deduplication)
      debugPrint(
        '[GROUP]   → Sending sender key to requester $requesterId:$requesterDeviceId',
      );
      await _sendSenderKeyToDevice(groupId, requesterId, requesterDeviceId);

      // Also send a response message so they know we responded
      final responseId = const Uuid().v4();
      await sendGroupItem(
        channelId: groupId,
        message: jsonEncode({
          'responderId': currentUserId,
          'responderDeviceId': currentDeviceId,
          'requesterId': requesterId,
          'requesterDeviceId': requesterDeviceId,
          'groupId': groupId,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
        itemId: responseId,
        type: 'sender_key_response',
      );

      debugPrint(
        '[GROUP]   ✓ Sender key sent to requester $requesterId:$requesterDeviceId',
      );
    } catch (e) {
      debugPrint('[GROUP]   ❌ Failed to respond to sender key request: $e');
    }
  }

  /// Handle incoming sender key response
  ///
  /// Confirmation that our sender key request was processed.
  /// The actual sender key arrives via processSenderKeyDistribution.
  ///
  /// Parameters:
  /// - [responseData]: Decoded response message
  Future<void> handleSenderKeyResponse(
    Map<String, dynamic> responseData,
  ) async {
    final String responderId = responseData['responderId'] as String;
    final int responderDeviceId = responseData['responderDeviceId'] as int;
    final String requesterId = responseData['requesterId'] as String;
    final int requesterDeviceId = responseData['requesterDeviceId'] as int;

    // Check if this response is for us
    if (requesterId != currentUserId || requesterDeviceId != currentDeviceId) {
      return;
    }

    debugPrint(
      '[GROUP] ✓ Sender key response received from $responderId:$responderDeviceId',
    );
  }

  // ========================================================================
  // EVENTBUS LISTENER REGISTRATION
  // ========================================================================

  /// Register EventBus listeners for sender key requests/responses
  ///
  /// Call this during SignalClient initialization to enable targeted sender key exchange.
  /// These listeners handle incoming sender_key_request and sender_key_response messages.
  Future<void> registerSenderKeyEventBusListeners() async {
    debugPrint(
      '[GROUP] Registering EventBus listeners for sender key exchange...',
    );

    // Listen for sender key requests
    app_events.EventBus.instance
        .on<Map<String, dynamic>>(app_events.AppEvent.senderKeyRequest)
        .listen((data) async {
          debugPrint('[GROUP] EventBus: sender_key_request received');
          try {
            final Map<String, dynamic> requestData = Map<String, dynamic>.from(
              data,
            );
            await handleSenderKeyRequest(requestData);
          } catch (e) {
            debugPrint('[GROUP] Error handling sender key request: $e');
          }
        });

    // Listen for sender key responses
    app_events.EventBus.instance
        .on<Map<String, dynamic>>(app_events.AppEvent.senderKeyResponse)
        .listen((data) async {
          debugPrint('[GROUP] EventBus: sender_key_response received');
          try {
            final Map<String, dynamic> responseData = Map<String, dynamic>.from(
              data,
            );
            await handleSenderKeyResponse(responseData);
          } catch (e) {
            debugPrint('[GROUP] Error handling sender key response: $e');
          }
        });

    debugPrint(
      '[GROUP] ✓ EventBus listeners registered for sender key exchange',
    );
  }
}
