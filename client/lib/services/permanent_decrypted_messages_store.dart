import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb_browser.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A persistent store for decrypted received messages.
/// Uses IndexedDB on web and FlutterSecureStorage on native.
/// This prevents DuplicateMessageException by caching decrypted messages
/// so they don't need to be decrypted multiple times.
class PermanentDecryptedMessagesStore {
  final String _storeName = 'peerwaveDecryptedMessages';
  final String _keyPrefix = 'decrypted_msg_';
  
  PermanentDecryptedMessagesStore();

  static Future<PermanentDecryptedMessagesStore> create() async {
    final store = PermanentDecryptedMessagesStore();
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
      String? keysJson = await storage.read(key: 'decrypted_message_keys');
      if (keysJson == null) {
        await storage.write(key: 'decrypted_message_keys', value: jsonEncode([]));
      }
    }
    return store;
  }

  /// Check if a message has already been decrypted
  Future<bool> hasDecryptedMessage(String itemId) async {
    final key = '$_keyPrefix$itemId';

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
      var value = await store.getObject(key);
      await txn.completed;
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
      var value = await store.getObject(key);
      await txn.completed;
      
      if (value is String) {
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

  /// Store a decrypted message
  Future<void> storeDecryptedMessage({
    required String itemId,
    required String message,
  }) async {
    final key = '$_keyPrefix$itemId';
    final data = jsonEncode({
      'itemId': itemId,
      'message': message,
      'decryptedAt': DateTime.now().toIso8601String(),
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
      String? keysJson = await storage.read(key: 'decrypted_message_keys');
      List<String> keys = [];
      if (keysJson != null) {
        keys = List<String>.from(jsonDecode(keysJson));
      }
      if (!keys.contains(key)) {
        keys.add(key);
        await storage.write(key: 'decrypted_message_keys', value: jsonEncode(keys));
      }
    }
  }

  /// Delete a specific decrypted message
  Future<void> deleteDecryptedMessage(String itemId) async {
    final key = '$_keyPrefix$itemId';

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
      String? keysJson = await storage.read(key: 'decrypted_message_keys');
      List<String> keys = [];
      if (keysJson != null) {
        keys = List<String>.from(jsonDecode(keysJson));
      }
      keys.remove(key);
      await storage.write(key: 'decrypted_message_keys', value: jsonEncode(keys));
    }
  }

  /// Clear all decrypted messages
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
      String? keysJson = await storage.read(key: 'decrypted_message_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        for (var key in keys) {
          await storage.delete(key: key);
        }
        await storage.write(key: 'decrypted_message_keys', value: jsonEncode([]));
      }
    }
  }
}
