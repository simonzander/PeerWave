import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:idb_shim/idb_browser.dart';
import 'dart:convert';

/// Store for decrypted group items (messages, reactions, etc.)
/// Separate from decryptedMessagesStore (which is for 1:1 messages)
class DecryptedGroupItemsStore {
  static const String _storeName = 'decryptedGroupItems';
  static const String _keyPrefix = 'group_item_';
  static DecryptedGroupItemsStore? _instance;

  DecryptedGroupItemsStore._();

  static Future<DecryptedGroupItemsStore> getInstance() async {
    if (_instance != null) return _instance!;
    
    final store = DecryptedGroupItemsStore._();
    
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
          // Index by sender for filtering messages from specific users
          if (!objectStore.indexNames.contains('sender')) {
            objectStore.createIndex('sender', 'sender', unique: false);
          }
          // Index by timestamp for sorting
          if (!objectStore.indexNames.contains('timestamp')) {
            objectStore.createIndex('timestamp', 'timestamp', unique: false);
          }
          // Index by type for filtering message types
          if (!objectStore.indexNames.contains('type')) {
            objectStore.createIndex('type', 'type', unique: false);
          }
        }
      });
    } else {
      // Initialize secure storage for mobile
      final storage = FlutterSecureStorage();
      final keys = await storage.read(key: 'group_item_keys');
      if (keys == null) {
        await storage.write(key: 'group_item_keys', value: jsonEncode([]));
      }
    }
    
    _instance = store;
    return store;
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
              print('[DecryptedGroupItemsStore] Error decoding item: $e');
            }
          }
        }
      }
      await txn.completed;
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
                print('[DecryptedGroupItemsStore] Error decoding item: $e');
              }
            }
          }
        }
      }
    }

    return items;
  }

  /// Check if an item exists
  Future<bool> hasItem(String itemId, String channelId) async {
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
      var txn = db.transaction(_storeName, 'readonly');
      var store = txn.objectStore(_storeName);
      var value = await store.getObject(key);
      await txn.completed;
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
        
        await storage.write(key: 'group_item_keys', value: jsonEncode(remainingKeys));
      }
    }
  }

  /// Clear all stored group items
  Future<void> clearAll() async {
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
      await store.clear();
      await txn.completed;
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
}
