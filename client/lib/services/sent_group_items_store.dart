import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:idb_shim/idb_browser.dart';
import 'dart:convert';

/// Store for sent group items (messages, reactions, etc.)
/// Separate from sentMessagesStore (which is for 1:1 messages)
class SentGroupItemsStore {
  static const String _storeName = 'sentGroupItems';
  static const String _keyPrefix = 'sent_group_item_';
  static SentGroupItemsStore? _instance;

  SentGroupItemsStore._();

  static Future<SentGroupItemsStore> getInstance() async {
    if (_instance != null) return _instance!;
    
    final store = SentGroupItemsStore._();
    
    if (kIsWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      await idbFactory.open(_storeName, version: 2,
          onUpgradeNeeded: (VersionChangeEvent event) {
        Database db = event.database;
        ObjectStore objectStore;
        
        // Create or get the object store
        if (!db.objectStoreNames.contains(_storeName)) {
          objectStore = db.createObjectStore(_storeName, autoIncrement: false);
        } else {
          objectStore = event.transaction.objectStore(_storeName);
        }
        
        // Add indexes for faster queries (v2)
        if (event.oldVersion < 2) {
          // Index by channelId for filtering items from specific channels
          if (!objectStore.indexNames.contains('channelId')) {
            objectStore.createIndex('channelId', 'channelId', unique: false);
          }
          // Index by timestamp for sorting
          if (!objectStore.indexNames.contains('timestamp')) {
            objectStore.createIndex('timestamp', 'timestamp', unique: false);
          }
          // Index by status for filtering by delivery status
          if (!objectStore.indexNames.contains('status')) {
            objectStore.createIndex('status', 'status', unique: false);
          }
          // Index by type for filtering message types
          if (!objectStore.indexNames.contains('type')) {
            objectStore.createIndex('type', 'type', unique: false);
          }
        }
      });
    } else {
      final storage = FlutterSecureStorage();
      final keys = await storage.read(key: 'sent_group_item_keys');
      if (keys == null) {
        await storage.write(key: 'sent_group_item_keys', value: jsonEncode([]));
      }
    }
    
    _instance = store;
    return store;
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
      final IdbFactory idbFactory = idbFactoryBrowser;
      final db = await idbFactory.open(_storeName, version: 2,
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
      
      // Track keys
      String? keysJson = await storage.read(key: 'sent_group_item_keys');
      List<String> keys = [];
      if (keysJson != null) {
        keys = List<String>.from(jsonDecode(keysJson));
      }
      if (!keys.contains(key)) {
        keys.add(key);
        await storage.write(key: 'sent_group_item_keys', value: jsonEncode(keys));
      }
    }
  }

  /// Load all sent items for a channel
  Future<List<Map<String, dynamic>>> loadSentItems(String channelId) async {
    final items = <Map<String, dynamic>>[];
    final prefix = '$_keyPrefix$channelId';

    if (kIsWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      final db = await idbFactory.open(_storeName, version: 2,
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
              final item = jsonDecode(value);
              items.add(item);
            } catch (e) {
              print('[SentGroupItemsStore] Error decoding item: $e');
            }
          }
        }
      }
      await txn.completed;
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
                print('[SentGroupItemsStore] Error decoding item: $e');
              }
            }
          }
        }
      }
    }

    return items;
  }

  /// Update item status
  Future<void> updateStatus(String itemId, String channelId, String status) async {
    final key = '$_keyPrefix${channelId}_$itemId';

    if (kIsWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      final db = await idbFactory.open(_storeName, version: 2,
          onUpgradeNeeded: (VersionChangeEvent event) {
        Database db = event.database;
        if (!db.objectStoreNames.contains(_storeName)) {
          db.createObjectStore(_storeName, autoIncrement: false);
        }
      });
      var txn = db.transaction(_storeName, 'readwrite');
      var store = txn.objectStore(_storeName);
      var value = await store.getObject(key);
      
      if (value is String) {
        try {
          final item = jsonDecode(value);
          item['status'] = status;
          await store.put(jsonEncode(item), key);
        } catch (e) {
          print('[SentGroupItemsStore] Error updating status: $e');
        }
      }
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      String? value = await storage.read(key: key);
      if (value != null) {
        try {
          final item = jsonDecode(value);
          item['status'] = status;
          await storage.write(key: key, value: jsonEncode(item));
        } catch (e) {
          print('[SentGroupItemsStore] Error updating status: $e');
        }
      }
    }
  }

  /// Update delivery/read counts
  Future<void> updateCounts(String itemId, String channelId, {
    int? deliveredCount,
    int? readCount,
    int? totalCount,
  }) async {
    final key = '$_keyPrefix${channelId}_$itemId';

    if (kIsWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      final db = await idbFactory.open(_storeName, version: 2,
          onUpgradeNeeded: (VersionChangeEvent event) {
        Database db = event.database;
        if (!db.objectStoreNames.contains(_storeName)) {
          db.createObjectStore(_storeName, autoIncrement: false);
        }
      });
      var txn = db.transaction(_storeName, 'readwrite');
      var store = txn.objectStore(_storeName);
      var value = await store.getObject(key);
      
      if (value is String) {
        try {
          final item = jsonDecode(value);
          if (deliveredCount != null) item['deliveredCount'] = deliveredCount;
          if (readCount != null) item['readCount'] = readCount;
          if (totalCount != null) item['totalCount'] = totalCount;
          await store.put(jsonEncode(item), key);
        } catch (e) {
          print('[SentGroupItemsStore] Error updating counts: $e');
        }
      }
      await txn.completed;
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
          print('[SentGroupItemsStore] Error updating counts: $e');
        }
      }
    }
  }

  /// Clear a single item for a channel
  Future<void> clearChannelItem(String channelId, String itemId) async {
    final key = '$_keyPrefix${channelId}_$itemId';

    if (kIsWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      final db = await idbFactory.open(_storeName, version: 2,
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

      String? keysJson = await storage.read(key: 'sent_group_item_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        keys.remove(key);
        await storage.write(key: 'sent_group_item_keys', value: jsonEncode(keys));
      }
    }
  }

  /// Clear all items for a channel
  Future<void> clearChannelItems(String channelId) async {
    final prefix = '$_keyPrefix$channelId';

    if (kIsWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      final db = await idbFactory.open(_storeName, version: 2,
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
        
        await storage.write(key: 'sent_group_item_keys', value: jsonEncode(remainingKeys));
      }
    }
  }

  /// Get all unique channel IDs (for cleanup operations)
  Future<Set<String>> getAllChannels() async {
    final Set<String> channels = {};

    if (kIsWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      final db = await idbFactory.open(_storeName, version: 2,
          onUpgradeNeeded: (VersionChangeEvent event) {
        Database db = event.database;
        if (!db.objectStoreNames.contains(_storeName)) {
          db.createObjectStore(_storeName, autoIncrement: false);
        }
      });
      var txn = db.transaction(_storeName, 'readonly');
      var store = txn.objectStore(_storeName);
      var index = store.index('channelId');
      
      // Use openKeyCursor to efficiently get unique channelIds
      var cursor = index.openKeyCursor(autoAdvance: true);
      await for (var cursorWithValue in cursor) {
        final channelId = cursorWithValue.key;
        if (channelId is String) {
          channels.add(channelId);
        }
      }
      
      await txn.completed;
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
}
