import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'device_scoped_storage_service.dart';

/// A persistent store for decrypted received 1:1 messages ONLY.
/// Uses DeviceScopedStorageService for device-scoped encrypted storage on web.
/// Uses FlutterSecureStorage on native.
/// This prevents DuplicateMessageException by caching decrypted messages
/// so they don't need to be decrypted multiple times.
///
/// NOTE: Group messages use DecryptedGroupItemsStore instead.
class PermanentDecryptedMessagesStore {
  final String _storeName = 'peerwaveDecryptedMessages';
  final String _keyPrefix = 'decrypted_msg_';

  PermanentDecryptedMessagesStore();

  static Future<PermanentDecryptedMessagesStore> create() async {
    final store = PermanentDecryptedMessagesStore();
    if (kIsWeb) {
      // Device-scoped storage will be initialized automatically
      // No need to manually open IndexedDB
      debugPrint(
        '[DECRYPTED_MESSAGES_STORE] Using device-scoped encrypted storage',
      );
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'decrypted_message_keys');
      if (keysJson == null) {
        await storage.write(
          key: 'decrypted_message_keys',
          value: jsonEncode([]),
        );
      }
    }
    return store;
  }

  /// Check if a message has already been decrypted
  Future<bool> hasDecryptedMessage(String itemId) async {
    final key = '$_keyPrefix$itemId';

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      var value = await storage.getDecrypted(_storeName, _storeName, key);
      return value != null;
    } else {
      final storage = FlutterSecureStorage();
      var value = await storage.read(key: key);
      return value != null;
    }
  }

  /// Get a decrypted message by itemId
  Future<String?> getDecryptedMessage(String itemId) async {
    final key = '$_keyPrefix$itemId';

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      var value = await storage.getDecrypted(_storeName, _storeName, key);

      if (value != null) {
        final data = jsonDecode(value);
        return data['message'];
      }
      return null;
    } else {
      final storage = FlutterSecureStorage();
      var value = await storage.read(key: key);
      if (value != null) {
        final data = jsonDecode(value);
        return data['message'];
      }
      return null;
    }
  }

  /// Get the full decrypted message object with metadata
  Future<Map<String, dynamic>?> getDecryptedMessageFull(String itemId) async {
    final key = '$_keyPrefix$itemId';

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      var value = await storage.getDecrypted(_storeName, _storeName, key);

      if (value != null) {
        return jsonDecode(value) as Map<String, dynamic>;
      }
      return null;
    } else {
      final storage = FlutterSecureStorage();
      var value = await storage.read(key: key);
      if (value != null) {
        return jsonDecode(value) as Map<String, dynamic>;
      }
      return null;
    }
  }

  /// Get all decrypted messages from a specific sender (1:1 direct messages only)
  Future<List<Map<String, dynamic>>> getMessagesFromSender(
    String senderId,
  ) async {
    final List<Map<String, dynamic>> messages = [];

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      final keys = await storage.getAllKeys(_storeName, _storeName);

      for (var key in keys) {
        if (key.startsWith(_keyPrefix)) {
          var value = await storage.getDecrypted(_storeName, _storeName, key);
          if (value != null) {
            final data = jsonDecode(value) as Map<String, dynamic>;
            if (data['sender'] == senderId && data['type'] != 'read_receipt') {
              messages.add(data);
            }
          }
        }
      }
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'decrypted_message_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        for (var key in keys) {
          var value = await storage.read(key: key);
          if (value != null) {
            final data = jsonDecode(value) as Map<String, dynamic>;
            if (data['sender'] == senderId && data['type'] != 'read_receipt') {
              messages.add(data);
            }
          }
        }
      }
    }

    return messages;
  }

  /// Get all unique sender IDs from stored messages
  Future<Set<String>> getAllUniqueSenders() async {
    final Set<String> senders = {};

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      final keys = await storage.getAllKeys(_storeName, _storeName);

      for (var key in keys) {
        if (key.startsWith(_keyPrefix)) {
          var value = await storage.getDecrypted(_storeName, _storeName, key);
          if (value != null) {
            final data = jsonDecode(value) as Map<String, dynamic>;
            final sender = data['sender'] as String?;
            if (sender != null &&
                sender != 'self' &&
                data['type'] != 'read_receipt') {
              senders.add(sender);
            }
          }
        }
      }
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'decrypted_message_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        for (var key in keys) {
          var value = await storage.read(key: key);
          if (value != null) {
            final data = jsonDecode(value) as Map<String, dynamic>;
            final sender = data['sender'] as String?;
            if (sender != null &&
                sender != 'self' &&
                data['type'] != 'read_receipt') {
              senders.add(sender);
            }
          }
        }
      }
    }

    return senders;
  }

  /// Store a decrypted 1:1 message (direct message only, no channelId)
  Future<void> storeDecryptedMessage({
    required String itemId,
    required String message,
    String? sender,
    int? senderDeviceId,
    String? timestamp,
    String? type,
  }) async {
    final key = '$_keyPrefix$itemId';
    final data = jsonEncode({
      'itemId': itemId,
      'message': message,
      'sender': sender,
      'senderDeviceId': senderDeviceId,
      'timestamp': timestamp,
      'type': type,
      'decryptedAt': DateTime.now().toIso8601String(),
    });

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      await storage.storeEncrypted(_storeName, _storeName, key, data);
    } else {
      final storage = FlutterSecureStorage();
      await storage.write(key: key, value: data);
      // Track message key
      String? keysJson = await storage.read(key: 'decrypted_message_keys');
      List<String> keys = [];
      if (keysJson != null) {
        keys = List<String>.from(jsonDecode(keysJson));
      }
      if (!keys.contains(key)) {
        keys.add(key);
        await storage.write(
          key: 'decrypted_message_keys',
          value: jsonEncode(keys),
        );
      }
    }
  }

  /// Delete a specific decrypted message
  Future<void> deleteDecryptedMessage(String itemId) async {
    final key = '$_keyPrefix$itemId';

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      await storage.deleteEncrypted(_storeName, _storeName, key);
    } else {
      final storage = FlutterSecureStorage();
      await storage.delete(key: key);
      // Remove from tracked keys
      String? keysJson = await storage.read(key: 'decrypted_message_keys');
      List<String> keys = [];
      if (keysJson != null) {
        keys = List<String>.from(jsonDecode(keysJson));
      }
      keys.remove(key);
      await storage.write(
        key: 'decrypted_message_keys',
        value: jsonEncode(keys),
      );
    }
  }

  /// Clear all decrypted messages
  Future<void> clearAll() async {
    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      final keys = await storage.getAllKeys(_storeName, _storeName);

      for (var key in keys) {
        await storage.deleteEncrypted(_storeName, _storeName, key);
      }
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'decrypted_message_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        for (var key in keys) {
          await storage.delete(key: key);
        }
        await storage.write(
          key: 'decrypted_message_keys',
          value: jsonEncode([]),
        );
      }
    }
  }
}
