import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../../../../api_service.dart';
import '../../../../socket_service.dart';
import '../../../../storage/sqlite_message_store.dart';
import '../../encryption_service.dart';
import '../../key_manager.dart';
import '../../session_manager.dart';

/// Mixin for 1-to-1 messaging operations
mixin OneToOneMessagingMixin {
  // Required getters from main service
  EncryptionService get encryptionService;
  ApiService get apiService;
  SocketService get socketService;
  String get currentUserId;
  int get currentDeviceId;

  SessionManager get sessionStore;
  SignalKeyManager get preKeyStore;
  SignalKeyManager get signedPreKeyStore;
  SignalKeyManager get identityStore;

  /// Send 1-to-1 encrypted message to a user
  ///
  /// Handles:
  /// - Multi-device messaging (encrypts for all recipient devices)
  /// - Session establishment if needed
  /// - Message encryption using Signal Protocol
  /// - Local message storage
  Future<String> send1to1Message({
    required String recipientUserId,
    required String type,
    required String payload,
    String? itemId,
  }) async {
    final generatedItemId = itemId ?? const Uuid().v4();

    debugPrint('[1-TO-1] Sending message to $recipientUserId (type: $type)');

    try {
      // Get recipient's devices
      final devices = await _fetchRecipientDevices(recipientUserId);

      if (devices.isEmpty) {
        throw Exception('No devices found for user $recipientUserId');
      }

      debugPrint(
        '[1-TO-1] Found ${devices.length} devices for $recipientUserId',
      );

      // Encrypt for each device
      final encryptedMessages = <Map<String, dynamic>>[];

      for (final device in devices) {
        // Handle both String and int device_id from API
        final deviceIdRaw = device['device_id'];
        final deviceId = deviceIdRaw is int
            ? deviceIdRaw
            : int.parse(deviceIdRaw.toString());
        final recipientAddress = SignalProtocolAddress(
          recipientUserId,
          deviceId,
        );

        try {
          // Check if session exists, establish if needed via SessionManager
          final hasSession = await sessionStore.containsSession(
            recipientAddress,
          );

          if (!hasSession) {
            debugPrint(
              '[1-TO-1] No session with $recipientUserId:$deviceId, establishing...',
            );
            // Use SessionManager to establish session (handles fetching bundles, building session)
            final success = await sessionStore.establishSessionWithUser(
              recipientUserId,
            );
            if (!success) {
              throw Exception(
                'Failed to establish session with $recipientUserId',
              );
            }
          }

          // Encrypt message
          final ciphertext = await encryptionService.encryptMessage(
            recipientAddress: recipientAddress,
            plaintext: Uint8List.fromList(utf8.encode(payload)),
          );

          encryptedMessages.add({
            'deviceId': deviceId,
            'ciphertext': base64Encode(ciphertext.serialize()),
            'cipherType': ciphertext.getType(),
          });
        } catch (e) {
          debugPrint('[1-TO-1] Failed to encrypt for device $deviceId: $e');
          // Continue with other devices
        }
      }

      if (encryptedMessages.isEmpty) {
        throw Exception('Failed to encrypt message for any device');
      }

      // Send to server - one emit per device
      for (final message in encryptedMessages) {
        final data = {
          'itemId': generatedItemId,
          'recipient': recipientUserId,
          'recipientDeviceId': message['deviceId'] as int,
          'type': type,
          'payload': message['ciphertext'] as String,
          'cipherType': (message['cipherType'] as int).toString(),
          'timestamp': DateTime.now().toIso8601String(),
        };

        debugPrint(
          '[1-TO-1] Sending to device ${message['deviceId']}: itemId=$generatedItemId, cipherType=${message['cipherType']}',
        );
        socketService.emit("sendItem", data);
      }

      // Store locally
      await storeOutgoingMessage(
        itemId: generatedItemId,
        recipientId: recipientUserId,
        message: payload,
        type: type,
      );

      debugPrint('[1-TO-1] ✓ Message sent: $generatedItemId');
      return generatedItemId;
    } catch (e, stackTrace) {
      debugPrint('[1-TO-1] ❌ Failed to send message: $e');
      debugPrint('[1-TO-1] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Fetch all devices for a user
  Future<List<Map<String, dynamic>>> _fetchRecipientDevices(
    String userId,
  ) async {
    final response = await apiService.get('/signal/prekey_bundle/$userId');

    // The response is a list of PreKeyBundles for recipient's devices
    // AND sender's other devices (for multi-device sync)
    final devices =
        (response.data is String ? jsonDecode(response.data) : response.data)
            as List;

    // Filter out only the current sender device (don't send to ourselves)
    // Keep all recipient devices + sender's other devices
    final filteredDevices = devices.where((device) {
      final deviceUserId = device['userId'] as String?;
      final deviceIdRaw = device['device_id'];
      final deviceId = deviceIdRaw is int
          ? deviceIdRaw
          : int.parse(deviceIdRaw.toString());

      // Filter out current device (don't send to ourselves)
      final isCurrentDevice =
          (deviceUserId == currentUserId && deviceId == currentDeviceId);
      return !isCurrentDevice;
    }).toList();

    debugPrint(
      '[1-TO-1] Filtered ${filteredDevices.length} devices (from ${devices.length} total, excluding current device)',
    );

    return filteredDevices.cast<Map<String, dynamic>>();
  }

  /// Store outgoing message locally
  Future<void> storeOutgoingMessage({
    required String itemId,
    required String recipientId,
    required String message,
    required String type,
  }) async {
    try {
      final messageStore = await SqliteMessageStore.getInstance();
      await messageStore.storeSentMessage(
        itemId: itemId,
        recipientId: recipientId,
        message: message,
        timestamp: DateTime.now().toIso8601String(),
        type: type,
      );
    } catch (e) {
      debugPrint('[1-TO-1] Failed to store outgoing message: $e');
    }
  }
}
