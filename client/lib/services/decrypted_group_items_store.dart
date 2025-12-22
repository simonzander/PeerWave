import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'storage/sqlite_group_message_store.dart';
import 'device_scoped_storage_service.dart';

/// Store for decrypted group items (messages, reactions, etc.)
/// Uses DeviceScopedStorageService for device-scoped encrypted storage on web.
/// Uses SQLite for better performance, with fallback to old storage
class DecryptedGroupItemsStore {
  static const String _storeName = 'decryptedGroupItems';
  static const String _keyPrefix = 'group_item_';
  static DecryptedGroupItemsStore? _instance;

  DecryptedGroupItemsStore._();

  static Future<DecryptedGroupItemsStore> getInstance() async {
    if (_instance != null) return _instance!;

    _instance = DecryptedGroupItemsStore._();
    return _instance!;
  }

  /// Store a decrypted group item
  Future<void> storeDecryptedGroupItem({
    required String itemId,
    required String channelId,
    required String sender,
    required int senderDevice,
    required String message,
    required String timestamp,
    String type = 'message',
  }) async {
    // Try SQLite first
    try {
      final sqliteStore = await SqliteGroupMessageStore.getInstance();
      await sqliteStore.storeDecryptedGroupItem(
        itemId: itemId,
        channelId: channelId,
        sender: sender,
        senderDevice: senderDevice,
        message: message,
        timestamp: timestamp,
        type: type,
      );
      debugPrint('[GROUP ITEMS] ✓ Stored in SQLite: $itemId');
    } catch (e) {
      debugPrint('[GROUP ITEMS] ⚠ SQLite failed, using fallback: $e');
    }

    // Also store in old storage (dual write for safety)
    final key = '$_keyPrefix${channelId}_$itemId';
    final data = jsonEncode({
      'itemId': itemId,
      'channelId': channelId,
      'sender': sender,
      'senderDevice': senderDevice,
      'message': message,
      'timestamp': timestamp,
      'type': type,
      'decryptedAt': DateTime.now().toIso8601String(),
    });

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      await storage.putEncrypted(_storeName, _storeName, key, data);
    } else {
      final storage = FlutterSecureStorage();
      await storage.write(key: key, value: data);

      // Track keys
      String? keysJson = await storage.read(key: 'group_item_keys');
      List<String> keys = [];
      if (keysJson != null) {
        keys = List<String>.from(jsonDecode(keysJson));
      }
      if (!keys.contains(key)) {
        keys.add(key);
        await storage.write(key: 'group_item_keys', value: jsonEncode(keys));
      }
    }
  }

  /// Get all decrypted items for a specific channel
  Future<List<Map<String, dynamic>>> getChannelItems(String channelId) async {
    // Try SQLite first
    try {
      final sqliteStore = await SqliteGroupMessageStore.getInstance();
      final messages = await sqliteStore.getChannelMessages(channelId);

      if (messages.isNotEmpty) {
        debugPrint(
          '[GROUP ITEMS] ✓ Loaded ${messages.length} messages from SQLite',
        );

        // Convert SQLite format to expected format
        return messages
            .map(
              (msg) => {
                'itemId': msg['item_id'],
                'channelId': msg['channel_id'],
                'sender': msg['sender'],
                'senderDevice': msg['sender_device_id'] ?? 0,
                'message': msg['message'],
                'timestamp': msg['timestamp'],
                'type': msg['type'] ?? 'message',
                'decryptedAt': msg['decrypted_at'],
                'reactions': msg['reactions'] ?? '{}', // Include reactions
              },
            )
            .toList();
      }
    } catch (e) {
      debugPrint('[GROUP ITEMS] ⚠ SQLite failed, using fallback: $e');
    }

    // Fallback to old storage
    final items = <Map<String, dynamic>>[];
    final prefix = '$_keyPrefix$channelId';

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      final keys = await storage.getAllKeys(_storeName, _storeName);

      for (var key in keys) {
        if (key.startsWith(prefix)) {
          var value = await storage.getDecrypted(_storeName, _storeName, key);
          if (value != null) {
            try {
              final item = jsonDecode(value);
              items.add(item);
            } catch (e) {
              debugPrint('[DecryptedGroupItemsStore] Error decoding item: $e');
            }
          }
        }
      }
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'group_item_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        for (var key in keys) {
          if (key.startsWith(prefix)) {
            String? value = await storage.read(key: key);
            if (value != null) {
              try {
                final item = jsonDecode(value);
                items.add(item);
              } catch (e) {
                debugPrint(
                  '[DecryptedGroupItemsStore] Error decoding item: $e',
                );
              }
            }
          }
        }
      }
    }

    debugPrint(
      '[GROUP ITEMS] ✓ Loaded ${items.length} messages from fallback storage',
    );
    return items;
  }

  /// Check if an item exists
  Future<bool> hasItem(String itemId, String channelId) async {
    final key = '$_keyPrefix${channelId}_$itemId';

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      var value = await storage.getDecrypted(_storeName, _storeName, key);
      return value != null;
    } else {
      final storage = FlutterSecureStorage();
      String? value = await storage.read(key: key);
      return value != null;
    }
  }

  /// Clear a single item by itemId and channelId
  Future<void> clearItem(String itemId, String channelId) async {
    final key = '$_keyPrefix${channelId}_$itemId';

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      await storage.deleteEncrypted(_storeName, _storeName, key);
    } else {
      final storage = FlutterSecureStorage();
      await storage.delete(key: key);

      // Update tracked keys
      String? keysJson = await storage.read(key: 'group_item_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        keys.remove(key);
        await storage.write(key: 'group_item_keys', value: jsonEncode(keys));
      }
    }
  }

  /// Clear all items for a channel
  Future<void> clearChannelItems(String channelId) async {
    final prefix = '$_keyPrefix$channelId';

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      final keys = await storage.getAllKeys(_storeName, _storeName);

      for (var key in keys) {
        if (key.startsWith(prefix)) {
          await storage.deleteEncrypted(_storeName, _storeName, key);
        }
      }
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'group_item_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        List<String> remainingKeys = [];

        for (var key in keys) {
          if (key.startsWith(prefix)) {
            await storage.delete(key: key);
          } else {
            remainingKeys.add(key);
          }
        }

        await storage.write(
          key: 'group_item_keys',
          value: jsonEncode(remainingKeys),
        );
      }
    }
  }

  /// Clear all stored group items
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
      String? keysJson = await storage.read(key: 'group_item_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        for (var key in keys) {
          await storage.delete(key: key);
        }
        await storage.write(key: 'group_item_keys', value: jsonEncode([]));
      }
    }
  }

  /// Get all unique channel IDs (for cleanup operations)
  Future<Set<String>> getAllChannels() async {
    final Set<String> channels = {};

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      final keys = await storage.getAllKeys(_storeName, _storeName);

      for (var key in keys) {
        // Extract channelId from key format: group_item_{channelId}_{itemId}
        if (key.startsWith(_keyPrefix)) {
          final parts = key.substring(_keyPrefix.length).split('_');
          if (parts.isNotEmpty) {
            channels.add(parts[0]);
          }
        }
      }
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'group_item_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));

        for (var key in keys) {
          // Extract channelId from key format: group_item_{channelId}_{itemId}
          if (key.startsWith(_keyPrefix)) {
            final parts = key.substring(_keyPrefix.length).split('_');
            if (parts.isNotEmpty) {
              channels.add(parts[0]);
            }
          }
        }
      }
    }

    return channels;
  }

  /// Delete all decrypted items for a channel
  Future<void> deleteChannelItems(String channelId) async {
    debugPrint('[GROUP ITEMS] Deleting all items for channel: $channelId');

    // Delete from SQLite
    try {
      final sqliteStore = await SqliteGroupMessageStore.getInstance();
      await sqliteStore.deleteChannelMessages(channelId);
      debugPrint('[GROUP ITEMS] ✓ Deleted from SQLite');
    } catch (e) {
      debugPrint('[GROUP ITEMS] ⚠ SQLite deletion failed: $e');
    }

    // Delete from old storage
    final prefix = '$_keyPrefix$channelId';
    int deletedCount = 0;

    if (kIsWeb) {
      final storage = DeviceScopedStorageService.instance;
      final keys = await storage.getAllKeys(_storeName, _storeName);

      for (var key in keys) {
        if (key.startsWith(prefix)) {
          await storage.deleteEncrypted(_storeName, _storeName, key);
          deletedCount++;
        }
      }
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'group_item_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        List<String> remainingKeys = [];

        for (var key in keys) {
          if (key.startsWith(prefix)) {
            await storage.delete(key: key);
            deletedCount++;
          } else {
            remainingKeys.add(key);
          }
        }

        // Update keys list
        await storage.write(
          key: 'group_item_keys',
          value: jsonEncode(remainingKeys),
        );
      }
    }

    debugPrint(
      '[GROUP ITEMS] ✓ Deleted $deletedCount items from old storage for channel: $channelId',
    );
  }
}
