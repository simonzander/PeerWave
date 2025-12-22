import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'storage/sqlite_group_message_store.dart';
import 'device_scoped_storage_service.dart';

/// Store for sent group items (messages, reactions, etc.)
/// Uses DeviceScopedStorageService for device-scoped encrypted storage on web.
/// Uses SQLite for better performance, with fallback to old storage
class SentGroupItemsStore {
  static const String _storeName = 'sentGroupItems';
  static const String _keyPrefix = 'sent_group_item_';
  static SentGroupItemsStore? _instance;

  SentGroupItemsStore._();

  static Future<SentGroupItemsStore> getInstance() async {
    if (_instance != null) return _instance!;

    _instance = SentGroupItemsStore._();
    return _instance!;
  }

  /// Store a sent group item
  Future<void> storeSentGroupItem({
    required String channelId,
    required String itemId,
    required String message,
    required String timestamp,
    String status = 'sending',
    String type = 'message',
  }) async {
    // Try SQLite first
    try {
      final sqliteStore = await SqliteGroupMessageStore.getInstance();
      await sqliteStore.storeSentGroupItem(
        itemId: itemId,
        channelId: channelId,
        message: message,
        timestamp: timestamp,
        type: type,
      );
      debugPrint('[SENT GROUP ITEMS] ✓ Stored in SQLite: $itemId');
    } catch (e) {
      debugPrint('[SENT GROUP ITEMS] ⚠ SQLite failed, using fallback: $e');
    }

    // Also store in old storage (dual write for safety)
    final key = '$_keyPrefix${channelId}_$itemId';
    final data = jsonEncode({
      'itemId': itemId,
      'channelId': channelId,
      'message': message,
      'timestamp': timestamp,
      'type': type,
      'status': status,
      'deliveredCount': 0,
      'readCount': 0,
      'totalCount': 0,
    });

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      await storage.putEncrypted(_storeName, _storeName, key, data);
    } else {
      final storage = FlutterSecureStorage();
      await storage.write(key: key, value: data);

      // Track keys
      String? keysJson = await storage.read(key: 'sent_group_item_keys');
      List<String> keys = [];
      if (keysJson != null) {
        keys = List<String>.from(jsonDecode(keysJson));
      }
      if (!keys.contains(key)) {
        keys.add(key);
        await storage.write(
          key: 'sent_group_item_keys',
          value: jsonEncode(keys),
        );
      }
    }
  }

  /// Load all sent items for a channel
  Future<List<Map<String, dynamic>>> loadSentItems(String channelId) async {
    // Try SQLite first
    try {
      final sqliteStore = await SqliteGroupMessageStore.getInstance();
      final messages = await sqliteStore.getChannelMessages(channelId);

      // Filter for sent messages only
      final sentMessages = messages
          .where((msg) => msg['direction'] == 'sent')
          .toList();

      if (sentMessages.isNotEmpty) {
        debugPrint(
          '[SENT GROUP ITEMS] ✓ Loaded ${sentMessages.length} messages from SQLite',
        );

        // Convert SQLite format to expected format
        return sentMessages
            .map(
              (msg) => {
                'itemId': msg['item_id'],
                'channelId': msg['channel_id'],
                'message': msg['message'],
                'timestamp': msg['timestamp'],
                'type': msg['type'] ?? 'message',
                'status': 'sent', // All stored messages are sent
                'deliveredCount': 0,
                'readCount': 0,
                'totalCount': 0,
              },
            )
            .toList();
      }
    } catch (e) {
      debugPrint('[SENT GROUP ITEMS] ⚠ SQLite failed, using fallback: $e');
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
              debugPrint('[SentGroupItemsStore] Error decoding item: $e');
            }
          }
        }
      }
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'sent_group_item_keys');
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
                debugPrint('[SentGroupItemsStore] Error decoding item: $e');
              }
            }
          }
        }
      }
    }

    debugPrint(
      '[SENT GROUP ITEMS] ✓ Loaded ${items.length} messages from fallback storage',
    );
    return items;
  }

  /// Update item status
  Future<void> updateStatus(
    String itemId,
    String channelId,
    String status,
  ) async {
    final key = '$_keyPrefix${channelId}_$itemId';

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      var value = await storage.getDecrypted(_storeName, _storeName, key);

      if (value != null) {
        try {
          final item = jsonDecode(value);
          item['status'] = status;
          await storage.putEncrypted(
            _storeName,
            _storeName,
            key,
            jsonEncode(item),
          );
        } catch (e) {
          debugPrint('[SentGroupItemsStore] Error updating status: $e');
        }
      }
    } else {
      final storage = FlutterSecureStorage();
      String? value = await storage.read(key: key);
      if (value != null) {
        try {
          final item = jsonDecode(value);
          item['status'] = status;
          await storage.write(key: key, value: jsonEncode(item));
        } catch (e) {
          debugPrint('[SentGroupItemsStore] Error updating status: $e');
        }
      }
    }
  }

  /// Update delivery/read counts
  Future<void> updateCounts(
    String itemId,
    String channelId, {
    int? deliveredCount,
    int? readCount,
    int? totalCount,
  }) async {
    final key = '$_keyPrefix${channelId}_$itemId';

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      var value = await storage.getDecrypted(_storeName, _storeName, key);

      if (value != null) {
        try {
          final item = jsonDecode(value);
          if (deliveredCount != null) item['deliveredCount'] = deliveredCount;
          if (readCount != null) item['readCount'] = readCount;
          if (totalCount != null) item['totalCount'] = totalCount;
          await storage.putEncrypted(
            _storeName,
            _storeName,
            key,
            jsonEncode(item),
          );
        } catch (e) {
          debugPrint('[SentGroupItemsStore] Error updating counts: $e');
        }
      }
    } else {
      final storage = FlutterSecureStorage();
      String? value = await storage.read(key: key);
      if (value != null) {
        try {
          final item = jsonDecode(value);
          if (deliveredCount != null) item['deliveredCount'] = deliveredCount;
          if (readCount != null) item['readCount'] = readCount;
          if (totalCount != null) item['totalCount'] = totalCount;
          await storage.write(key: key, value: jsonEncode(item));
        } catch (e) {
          debugPrint('[SentGroupItemsStore] Error updating counts: $e');
        }
      }
    }
  }

  /// Clear a single item for a channel
  Future<void> clearChannelItem(String channelId, String itemId) async {
    final key = '$_keyPrefix${channelId}_$itemId';

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      await storage.deleteEncrypted(_storeName, _storeName, key);
    } else {
      final storage = FlutterSecureStorage();
      await storage.delete(key: key);

      String? keysJson = await storage.read(key: 'sent_group_item_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        keys.remove(key);
        await storage.write(
          key: 'sent_group_item_keys',
          value: jsonEncode(keys),
        );
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
      String? keysJson = await storage.read(key: 'sent_group_item_keys');
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
          key: 'sent_group_item_keys',
          value: jsonEncode(remainingKeys),
        );
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
        // Extract channelId from key format: sent_group_item_{channelId}_{itemId}
        if (key.startsWith(_keyPrefix)) {
          final parts = key.substring(_keyPrefix.length).split('_');
          if (parts.isNotEmpty) {
            channels.add(parts[0]);
          }
        }
      }
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'sent_group_item_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));

        for (var key in keys) {
          // Extract channelId from key format: sent_group_item_{channelId}_{itemId}
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

  /// Delete all sent items for a channel
  Future<void> deleteChannelItems(String channelId) async {
    debugPrint('[SENT GROUP ITEMS] Deleting all items for channel: $channelId');

    // Delete from SQLite
    try {
      final sqliteStore = await SqliteGroupMessageStore.getInstance();
      await sqliteStore.deleteChannelMessages(channelId);
      debugPrint('[SENT GROUP ITEMS] ✓ Deleted from SQLite');
    } catch (e) {
      debugPrint('[SENT GROUP ITEMS] ⚠ SQLite deletion failed: $e');
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
      String? keysJson = await storage.read(key: 'sent_group_item_keys');
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
          key: 'sent_group_item_keys',
          value: jsonEncode(remainingKeys),
        );
      }
    }

    debugPrint(
      '[SENT GROUP ITEMS] ✓ Deleted $deletedCount items from old storage for channel: $channelId',
    );
  }
}
