import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb_browser.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A persistent store for locally sent 1:1 messages ONLY.
/// Uses IndexedDB on web and FlutterSecureStorage on native.
/// This allows the sending device to see its own messages after refresh,
/// without storing unencrypted messages on the server.
/// 
/// NOTE: Group messages use SentGroupItemsStore instead.
class PermanentSentMessagesStore {
  final String _storeName = 'peerwaveSentMessages';
  final String _keyPrefix = 'sent_msg_';
  
  PermanentSentMessagesStore();

  static Future<PermanentSentMessagesStore> create() async {
    final store = PermanentSentMessagesStore();
    if (kIsWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      await idbFactory.open(store._storeName, version: 1, onUpgradeNeeded: (VersionChangeEvent event) {
        Database db = event.database;
        if (!db.objectStoreNames.contains(store._storeName)) {
          db.createObjectStore(store._storeName, autoIncrement: false);
        }
      });
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'sent_message_keys');
      if (keysJson == null) {
        await storage.write(key: 'sent_message_keys', value: jsonEncode([]));
      }
    }
    return store;
  }

  /// Store a sent 1:1 message locally (direct message only, no channelId)
  /// @param recipientUserId - The UUID of the conversation partner
  /// @param itemId - Unique message ID
  /// @param message - The plaintext message
  /// @param timestamp - ISO 8601 timestamp
  /// @param status - Message status: 'sending', 'delivered', 'read'
  /// @param type - Message type: 'message', etc. (defaults to 'message')
  Future<void> storeSentMessage({
    required String recipientUserId,
    required String itemId,
    required String message,
    required String timestamp,
    String status = 'sending',
    String type = 'message',
  }) async {
    final key = '$_keyPrefix${recipientUserId}_$itemId';
    final data = jsonEncode({
      'itemId': itemId,
      'recipientUserId': recipientUserId,
      'message': message,
      'timestamp': timestamp,
      'type': type,
      'isLocalSent': true,
      'status': status,
      'deliveredAt': null,
      'readAt': null,
    });

    if (kIsWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      final db = await idbFactory.open(_storeName, version: 1,
          onUpgradeNeeded: (VersionChangeEvent event) {
        Database db = event.database;
        if (!db.objectStoreNames.contains(_storeName)) {
          db.createObjectStore(_storeName, autoIncrement: false);
        }
      });
      var txn = db.transaction(_storeName, 'readwrite');
      var store = txn.objectStore(_storeName);
      await store.put(data, key);
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      await storage.write(key: key, value: data);
      // Track message key
      String? keysJson = await storage.read(key: 'sent_message_keys');
      List<String> keys = [];
      if (keysJson != null) {
        keys = List<String>.from(jsonDecode(keysJson));
      }
      if (!keys.contains(key)) {
        keys.add(key);
        await storage.write(key: 'sent_message_keys', value: jsonEncode(keys));
      }
    }
  }

  /// Load all sent messages for a specific recipient
  Future<List<Map<String, dynamic>>> loadSentMessages(String recipientUserId) async {
    final messages = <Map<String, dynamic>>[];
    final prefix = '$_keyPrefix$recipientUserId';

    if (kIsWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      final db = await idbFactory.open(_storeName, version: 1,
          onUpgradeNeeded: (VersionChangeEvent event) {
        Database db = event.database;
        if (!db.objectStoreNames.contains(_storeName)) {
          db.createObjectStore(_storeName, autoIncrement: false);
        }
      });
      var txn = db.transaction(_storeName, 'readonly');
      var store = txn.objectStore(_storeName);
      var keys = await store.getAllKeys();
      
      for (var key in keys) {
        if (key is String && key.startsWith(prefix)) {
          var value = await store.getObject(key);
          if (value is String) {
            try {
              final msg = jsonDecode(value);
              messages.add(msg);
            } catch (e) {
              print('[SentMessagesStore] Error decoding message: $e');
            }
          }
        }
      }
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'sent_message_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        for (var key in keys) {
          if (key.startsWith(prefix)) {
            var value = await storage.read(key: key);
            if (value != null) {
              try {
                final msg = jsonDecode(value);
                messages.add(msg);
              } catch (e) {
                print('[SentMessagesStore] Error decoding message: $e');
              }
            }
          }
        }
      }
    }

    // Sort by timestamp (oldest first)
    messages.sort((a, b) {
      final timeA = DateTime.tryParse(a['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      final timeB = DateTime.tryParse(b['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      return timeA.compareTo(timeB);
    });

    return messages;
  }

  /// Load all sent messages across all conversations
  Future<List<Map<String, dynamic>>> loadAllSentMessages() async {
    final messages = <Map<String, dynamic>>[];

    if (kIsWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      final db = await idbFactory.open(_storeName, version: 1,
          onUpgradeNeeded: (VersionChangeEvent event) {
        Database db = event.database;
        if (!db.objectStoreNames.contains(_storeName)) {
          db.createObjectStore(_storeName, autoIncrement: false);
        }
      });
      var txn = db.transaction(_storeName, 'readonly');
      var store = txn.objectStore(_storeName);
      var keys = await store.getAllKeys();
      
      for (var key in keys) {
        if (key is String && key.startsWith(_keyPrefix)) {
          var value = await store.getObject(key);
          if (value is String) {
            try {
              final msg = jsonDecode(value);
              messages.add(msg);
            } catch (e) {
              print('[SentMessagesStore] Error decoding message: $e');
            }
          }
        }
      }
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'sent_message_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        for (var key in keys) {
          if (key.startsWith(_keyPrefix)) {
            var value = await storage.read(key: key);
            if (value != null) {
              try {
                final msg = jsonDecode(value);
                messages.add(msg);
              } catch (e) {
                print('[SentMessagesStore] Error decoding message: $e');
              }
            }
          }
        }
      }
    }

    // Sort by timestamp (oldest first)
    messages.sort((a, b) {
      final timeA = DateTime.tryParse(a['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      final timeB = DateTime.tryParse(b['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      return timeA.compareTo(timeB);
    });

    return messages;
  }

  /// Delete a specific sent message
  Future<void> deleteSentMessage(String recipientUserId, String itemId) async {
    final key = '$_keyPrefix${recipientUserId}_$itemId';

    if (kIsWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      final db = await idbFactory.open(_storeName, version: 1,
          onUpgradeNeeded: (VersionChangeEvent event) {
        Database db = event.database;
        if (!db.objectStoreNames.contains(_storeName)) {
          db.createObjectStore(_storeName, autoIncrement: false);
        }
      });
      var txn = db.transaction(_storeName, 'readwrite');
      var store = txn.objectStore(_storeName);
      await store.delete(key);
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      await storage.delete(key: key);
      // Remove from tracked keys
      String? keysJson = await storage.read(key: 'sent_message_keys');
      List<String> keys = [];
      if (keysJson != null) {
        keys = List<String>.from(jsonDecode(keysJson));
      }
      keys.remove(key);
      await storage.write(key: 'sent_message_keys', value: jsonEncode(keys));
    }
  }

  /// Delete all sent messages for a specific recipient
  Future<void> deleteAllSentMessages(String recipientUserId) async {
    final prefix = '$_keyPrefix$recipientUserId';

    if (kIsWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      final db = await idbFactory.open(_storeName, version: 1,
          onUpgradeNeeded: (VersionChangeEvent event) {
        Database db = event.database;
        if (!db.objectStoreNames.contains(_storeName)) {
          db.createObjectStore(_storeName, autoIncrement: false);
        }
      });
      var txn = db.transaction(_storeName, 'readwrite');
      var store = txn.objectStore(_storeName);
      var keys = await store.getAllKeys();
      
      for (var key in keys) {
        if (key is String && key.startsWith(prefix)) {
          await store.delete(key);
        }
      }
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'sent_message_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        List<String> toDelete = keys.where((k) => k.startsWith(prefix)).toList();
        for (var key in toDelete) {
          await storage.delete(key: key);
          keys.remove(key);
        }
        await storage.write(key: 'sent_message_keys', value: jsonEncode(keys));
      }
    }
  }

  /// Mark a message as delivered
  Future<void> markAsDelivered(String itemId) async {
    await _updateMessageStatus(itemId, 'delivered', deliveredAt: DateTime.now().toIso8601String());
  }

  /// Mark a message as read
  Future<void> markAsRead(String itemId) async {
    await _updateMessageStatus(itemId, 'read', readAt: DateTime.now().toIso8601String());
  }

  /// Internal method to update message status
  Future<void> _updateMessageStatus(String itemId, String status, {String? deliveredAt, String? readAt}) async {
    if (kIsWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      final db = await idbFactory.open(_storeName, version: 1,
          onUpgradeNeeded: (VersionChangeEvent event) {
        Database db = event.database;
        if (!db.objectStoreNames.contains(_storeName)) {
          db.createObjectStore(_storeName, autoIncrement: false);
        }
      });
      var txn = db.transaction(_storeName, 'readwrite');
      var store = txn.objectStore(_storeName);
      var keys = await store.getAllKeys();
      
      for (var key in keys) {
        if (key is String && key.contains('_$itemId')) {
          var value = await store.getObject(key);
          if (value is String) {
            try {
              final msg = jsonDecode(value);
              msg['status'] = status;
              if (deliveredAt != null) msg['deliveredAt'] = deliveredAt;
              if (readAt != null) msg['readAt'] = readAt;
              await store.put(jsonEncode(msg), key);
              break;
            } catch (e) {
              print('[SentMessagesStore] Error updating status: $e');
            }
          }
        }
      }
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'sent_message_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        for (var key in keys) {
          if (key.contains('_$itemId')) {
            var value = await storage.read(key: key);
            if (value != null) {
              try {
                final msg = jsonDecode(value);
                msg['status'] = status;
                if (deliveredAt != null) msg['deliveredAt'] = deliveredAt;
                if (readAt != null) msg['readAt'] = readAt;
                await storage.write(key: key, value: jsonEncode(msg));
                break;
              } catch (e) {
                print('[SentMessagesStore] Error updating status: $e');
              }
            }
          }
        }
      }
    }
  }

  /// Clear all sent messages
  Future<void> clearAll() async {
    if (kIsWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      final db = await idbFactory.open(_storeName, version: 1,
          onUpgradeNeeded: (VersionChangeEvent event) {
        Database db = event.database;
        if (!db.objectStoreNames.contains(_storeName)) {
          db.createObjectStore(_storeName, autoIncrement: false);
        }
      });
      var txn = db.transaction(_storeName, 'readwrite');
      var store = txn.objectStore(_storeName);
      await store.clear();
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'sent_message_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        for (var key in keys) {
          await storage.delete(key: key);
        }
        await storage.write(key: 'sent_message_keys', value: jsonEncode([]));
      }
    }
  }
}
