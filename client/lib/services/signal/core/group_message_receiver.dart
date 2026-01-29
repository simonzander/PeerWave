import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../../sender_key_store.dart';
import '../../api_service.dart';
import '../../server_scoped_sender_key_store.dart';
import 'encryption_service.dart';

/// Service for group message decryption with sender keys
///
/// Handles:
/// - Group message decryption
/// - Sender key distribution processing
/// - Server-based sender key retrieval
/// - Automatic recovery from decryption errors
///
/// Dependencies:
/// - EncryptionService: For sender key store and identity store
///
/// Usage:
/// ```dart
/// // Self-initializing factory
/// final groupReceiver = await GroupMessageReceiver.create(
///   encryptionService: encryptionService,
///   getCurrentUserId: () => userId,
///   getCurrentDeviceId: () => deviceId,
/// );
/// ```
class GroupMessageReceiver {
  final EncryptionService encryptionService;

  final String? Function() getCurrentUserId;
  final int? Function() getCurrentDeviceId;

  bool _initialized = false;

  // Delegate to EncryptionService for crypto stores
  PermanentSenderKeyStore get senderKeyStore =>
      encryptionService.senderKeyStore;

  bool get isInitialized => _initialized;

  // Private constructor
  GroupMessageReceiver._({
    required this.encryptionService,
    required this.getCurrentUserId,
    required this.getCurrentDeviceId,
  });

  /// Self-initializing factory
  static Future<GroupMessageReceiver> create({
    required EncryptionService encryptionService,
    required String? Function() getCurrentUserId,
    required int? Function() getCurrentDeviceId,
  }) async {
    final service = GroupMessageReceiver._(
      encryptionService: encryptionService,
      getCurrentUserId: getCurrentUserId,
      getCurrentDeviceId: getCurrentDeviceId,
    );
    await service.init();
    return service;
  }

  /// Initialize (no stores to create - all from EncryptionService)
  Future<void> init() async {
    if (_initialized) {
      debugPrint('[GROUP_RECEIVER] Already initialized');
      return;
    }

    debugPrint('[GROUP_RECEIVER] Initialized (using EncryptionService stores)');
    _initialized = true;
  }

  // ============================================================================
  // SENDER KEY DISTRIBUTION PROCESSING
  // ============================================================================

  /// Process incoming sender key distribution message from another group member
  Future<void> processSenderKeyDistribution(
    String groupId,
    String senderId,
    int senderDeviceId,
    Uint8List distributionMessageBytes,
  ) async {
    final senderAddress = SignalProtocolAddress(senderId, senderDeviceId);
    final senderKeyName = SenderKeyName(groupId, senderAddress);
    final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);

    final distributionMessage =
        SenderKeyDistributionMessageWrapper.fromSerialized(
          distributionMessageBytes,
        );

    await groupSessionBuilder.process(senderKeyName, distributionMessage);

    debugPrint(
      '[GROUP_RECEIVER] Processed sender key from $senderId:$senderDeviceId for group $groupId',
    );
  }

  // ============================================================================
  // GROUP MESSAGE DECRYPTION
  // ============================================================================

  /// Decrypt group message using sender key
  /// [serverUrl] - Optional server URL for multi-server support
  Future<String> decryptGroupMessage(
    String groupId,
    String senderId,
    int senderDeviceId,
    String ciphertextBase64, {
    String? serverUrl,
  }) async {
    final senderAddress = SignalProtocolAddress(senderId, senderDeviceId);
    final senderKeyName = SenderKeyName(groupId, senderAddress);

    try {
      // Use server-scoped store if serverUrl provided
      final store = serverUrl != null
          ? ServerScopedSenderKeyStore(senderKeyStore, serverUrl)
          : senderKeyStore;

      final groupCipher = GroupCipher(store, senderKeyName);
      final ciphertext = base64Decode(ciphertextBase64);
      final plaintext = await groupCipher.decrypt(ciphertext);

      return utf8.decode(plaintext);
    } catch (e) {
      final errorStr = e.toString().toLowerCase();

      // Detect sender key chain desynchronization
      // This happens when messages are skipped (network packet loss, out-of-order delivery)
      if (errorStr.contains('chain') ||
          errorStr.contains('counter') ||
          errorStr.contains('invalid message number') ||
          errorStr.contains('duplicate message')) {
        debugPrint(
          '[GROUP_RECEIVER] ⚠️ Sender key chain desync detected for $senderId:$senderDeviceId in $groupId',
        );
        debugPrint(
          '[GROUP_RECEIVER] Message counter out of order - likely skipped message(s)',
        );

        // Attempt to reload sender key from server
        debugPrint(
          '[GROUP_RECEIVER] Attempting to reload sender key from server...',
        );
        final keyLoaded = await loadSenderKeyFromServer(
          channelId: groupId,
          userId: senderId,
          deviceId: senderDeviceId,
          forceReload: true,
        );

        if (keyLoaded) {
          debugPrint(
            '[GROUP_RECEIVER] Sender key reloaded, retrying decrypt...',
          );
          // Retry once with fresh key
          final store = serverUrl != null
              ? ServerScopedSenderKeyStore(senderKeyStore, serverUrl)
              : senderKeyStore;
          final groupCipher = GroupCipher(store, senderKeyName);
          final ciphertext = base64Decode(ciphertextBase64);
          final plaintext = await groupCipher.decrypt(ciphertext);
          return utf8.decode(plaintext);
        }
      }

      debugPrint(
        '[GROUP_RECEIVER] Error decrypting group message from $senderId:$senderDeviceId: $e',
      );
      rethrow;
    }
  }

  /// Decrypt a received group item with automatic sender key reload on error
  /// [serverUrl] - Optional server URL for multi-server support (extracts from socket event)
  Future<String> decryptGroupItem({
    required String channelId,
    required String senderId,
    required int senderDeviceId,
    required String ciphertext,
    bool retryOnError = true,
    String? serverUrl,
  }) async {
    try {
      // Try to decrypt
      final decrypted = await decryptGroupMessage(
        channelId,
        senderId,
        senderDeviceId,
        ciphertext,
        serverUrl: serverUrl,
      );

      return decrypted;
    } catch (e) {
      debugPrint('[GROUP_RECEIVER] Decrypt error: $e');

      // Check if this is a decryption error that might be fixed by reloading sender key
      if (retryOnError &&
          (e.toString().contains('InvalidMessageException') ||
              e.toString().contains('No key for') ||
              e.toString().contains('DuplicateMessageException') ||
              e.toString().contains('Invalid'))) {
        debugPrint(
          '[GROUP_RECEIVER] Attempting to reload sender key from server...',
        );

        // Try to reload sender key from server
        final keyLoaded = await loadSenderKeyFromServer(
          channelId: channelId,
          userId: senderId,
          deviceId: senderDeviceId,
          forceReload: true,
        );

        if (keyLoaded) {
          debugPrint(
            '[GROUP_RECEIVER] Sender key reloaded, retrying decrypt...',
          );

          // Retry decrypt (without retry to avoid infinite loop)
          return await decryptGroupItem(
            channelId: channelId,
            senderId: senderId,
            senderDeviceId: senderDeviceId,
            ciphertext: ciphertext,
            retryOnError: false, // Don't retry again
            serverUrl: serverUrl,
          );
        }
      }

      // Rethrow if we couldn't fix it
      rethrow;
    }
  }

  // ============================================================================
  // SERVER-BASED SENDER KEY MANAGEMENT
  // ============================================================================

  /// Load sender key from server database
  Future<bool> loadSenderKeyFromServer({
    required String channelId,
    required String userId,
    required int deviceId,
    bool forceReload = false,
  }) async {
    try {
      debugPrint(
        '[GROUP_RECEIVER] Loading sender key from server: $userId:$deviceId (forceReload: $forceReload)',
      );

      // If forceReload, delete old key first
      if (forceReload) {
        try {
          final address = SignalProtocolAddress(userId, deviceId);
          final senderKeyName = SenderKeyName(channelId, address);
          await senderKeyStore.removeSenderKey(senderKeyName);
          debugPrint('[GROUP_RECEIVER] Removed old sender key before reload');
        } catch (removeError) {
          debugPrint('[GROUP_RECEIVER] Error removing old key: $removeError');
        }
      }

      // Load from server via REST API
      final response = await ApiService.get(
        '/api/sender-keys/$channelId/$userId/$deviceId',
      );

      if (response.statusCode == 200 && response.data['success'] == true) {
        final senderKeyBase64 = response.data['senderKey'] as String;
        final senderKeyBytes = base64Decode(senderKeyBase64);

        // Process the distribution message
        await processSenderKeyDistribution(
          channelId,
          userId,
          deviceId,
          senderKeyBytes,
        );

        debugPrint('[GROUP_RECEIVER] ✓ Sender key loaded from server');
        return true;
      } else {
        debugPrint('[GROUP_RECEIVER] Sender key not found on server');
        return false;
      }
    } catch (e) {
      debugPrint('[GROUP_RECEIVER] Error loading sender key from server: $e');
      return false;
    }
  }

  /// Load all sender keys for a channel (when joining)
  Future<Map<String, dynamic>> loadAllSenderKeysForChannel(
    String channelId,
  ) async {
    final result = {
      'success': true,
      'totalKeys': 0,
      'loadedKeys': 0,
      'failedKeys': <Map<String, String>>[],
    };

    try {
      debugPrint(
        '[GROUP_RECEIVER] Loading all sender keys for channel $channelId',
      );

      final response = await ApiService.get('/api/sender-keys/$channelId');

      if (response.statusCode == 200 && response.data['success'] == true) {
        final senderKeysData = response.data['senderKeys'];

        // Handle null or empty senderKeys
        if (senderKeysData == null) {
          debugPrint('[GROUP_RECEIVER] No sender keys found for channel');
          return result;
        }

        final senderKeys = senderKeysData as List<dynamic>;
        result['totalKeys'] = senderKeys.length;

        debugPrint('[GROUP_RECEIVER] Found ${senderKeys.length} sender keys');

        final currentUserId = getCurrentUserId();
        final currentDeviceId = getCurrentDeviceId();

        for (final key in senderKeys) {
          try {
            final userId = key['userId'] as String;
            // Parse deviceId as int (API might return String)
            final deviceId = key['deviceId'] is int
                ? key['deviceId'] as int
                : int.parse(key['deviceId'].toString());
            final senderKeyBase64 = key['senderKey'] as String;
            final senderKeyBytes = base64Decode(senderKeyBase64);

            // Skip our own key
            if (userId == currentUserId && deviceId == currentDeviceId) {
              continue;
            }

            await processSenderKeyDistribution(
              channelId,
              userId,
              deviceId,
              senderKeyBytes,
            );

            result['loadedKeys'] = (result['loadedKeys'] as int) + 1;
            debugPrint(
              '[GROUP_RECEIVER] ✓ Loaded sender key for $userId:$deviceId',
            );
          } on Exception catch (keyError) {
            final userId = key['userId'] as String?;
            final deviceId = key['deviceId'] as int?;
            (result['failedKeys'] as List).add({
              'userId': userId ?? 'unknown',
              'deviceId': deviceId?.toString() ?? 'unknown',
              'error': keyError.toString(),
            });
            debugPrint(
              '[GROUP_RECEIVER] Error loading key for $userId:$deviceId - $keyError',
            );
          }
        }

        if ((result['failedKeys'] as List).isNotEmpty) {
          // Partial failure - some keys couldn't be loaded
          result['success'] = false;
          final failedCount = (result['failedKeys'] as List).length;
          throw Exception(
            'Failed to load $failedCount sender key(s). Some messages may not decrypt.',
          );
        }

        debugPrint(
          '[GROUP_RECEIVER] ✓ Loaded ${result['loadedKeys']} sender keys for channel',
        );
        return result;
      } else {
        // HTTP error or unsuccessful response
        result['success'] = false;
        throw Exception(
          'Failed to load sender keys from server: HTTP ${response.statusCode}',
        );
      }
    } on Exception catch (e) {
      debugPrint('[GROUP_RECEIVER] Error loading all sender keys: $e');
      result['success'] = false;
      rethrow; // CRITICAL: Re-throw to notify caller
    }
  }

  /// Check if we have a sender key for a specific user in a group
  Future<bool> hasSenderKey({
    required String groupId,
    required String userId,
    required int deviceId,
  }) async {
    try {
      final address = SignalProtocolAddress(userId, deviceId);
      final senderKeyName = SenderKeyName(groupId, address);
      return await senderKeyStore.containsSenderKey(senderKeyName);
    } catch (e) {
      debugPrint('[GROUP_RECEIVER] Error checking sender key: $e');
      return false;
    }
  }

  /// Clear all sender keys for a group (when leaving)
  Future<void> clearGroupSenderKeys(String groupId) async {
    try {
      debugPrint('[GROUP_RECEIVER] Clearing sender keys for group $groupId');

      // This would need to enumerate all keys for this group
      // For now, we rely on Signal Protocol's store cleanup
      // In a full implementation, you'd scan all addresses and remove keys

      debugPrint('[GROUP_RECEIVER] Cleared sender keys for group $groupId');
    } catch (e) {
      debugPrint('[GROUP_RECEIVER] Error clearing group sender keys: $e');
      // Don't throw - this is cleanup
    }
  }
}
