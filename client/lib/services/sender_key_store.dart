import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb_browser.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Store for Signal Sender Keys used in group chats
/// Implements SenderKeyStore interface from libsignal
class PermanentSenderKeyStore extends SenderKeyStore {
  final String _storeName = 'peerwaveSenderKeys';
  final String _keyPrefix = 'sender_key_';

  PermanentSenderKeyStore();

  static Future<PermanentSenderKeyStore> create() async {
    final store = PermanentSenderKeyStore();
    
    if (kIsWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      await idbFactory.open(store._storeName, version: 1, onUpgradeNeeded: (VersionChangeEvent event) {
        Database db = event.database;
        if (!db.objectStoreNames.contains(store._storeName)) {
          db.createObjectStore(store._storeName, autoIncrement: false);
        }
      });
    } else {
      // Initialize secure storage for native platforms
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'sender_key_list');
      if (keysJson == null) {
        await storage.write(key: 'sender_key_list', value: jsonEncode([]));
      }
    }
    
    return store;
  }

  /// Generate storage key from sender key name
  String _getStorageKey(SenderKeyName senderKeyName) {
    return '$_keyPrefix${senderKeyName.groupId}_${senderKeyName.sender.getName()}_${senderKeyName.sender.getDeviceId()}';
  }

  @override
  Future<void> storeSenderKey(SenderKeyName senderKeyName, SenderKeyRecord record) async {
    final key = _getStorageKey(senderKeyName);
    final serialized = base64Encode(record.serialize());

    // Store metadata for rotation tracking
    final metadata = {
      'createdAt': DateTime.now().toIso8601String(),
      'messageCount': 0,
      'lastRotation': DateTime.now().toIso8601String(),
    };
    final metadataKey = '${key}_metadata';

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
      await store.put(serialized, key);
      
      // Check if metadata exists, if so preserve messageCount
      var existingMetadata = await store.getObject(metadataKey);
      if (existingMetadata != null && existingMetadata is String) {
        try {
          final existing = jsonDecode(existingMetadata);
          metadata['messageCount'] = existing['messageCount'] ?? 0;
        } catch (e) {
          // Ignore parse errors, use default metadata
        }
      }
      
      await store.put(jsonEncode(metadata), metadataKey);
      await txn.completed;
      
      debugPrint('[SENDER_KEY_STORE] Stored sender key for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}');
    } else {
      final storage = FlutterSecureStorage();
      await storage.write(key: key, value: serialized);

      // Check if metadata exists, if so preserve messageCount
      String? existingMetadataJson = await storage.read(key: metadataKey);
      if (existingMetadataJson != null) {
        try {
          final existing = jsonDecode(existingMetadataJson);
          metadata['messageCount'] = existing['messageCount'] ?? 0;
        } catch (e) {
          // Ignore parse errors, use default metadata
        }
      }
      
      await storage.write(key: metadataKey, value: jsonEncode(metadata));

      // Update key list
      String? keysJson = await storage.read(key: 'sender_key_list');
      List<String> keys = keysJson != null ? List<String>.from(jsonDecode(keysJson)) : [];
      if (!keys.contains(key)) {
        keys.add(key);
        await storage.write(key: 'sender_key_list', value: jsonEncode(keys));
      }
      
      debugPrint('[SENDER_KEY_STORE] Stored sender key for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}');
    }
  }

  @override
  Future<SenderKeyRecord> loadSenderKey(SenderKeyName senderKeyName) async {
    final key = _getStorageKey(senderKeyName);

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

      if (value != null && value is String) {
        final bytes = base64Decode(value);
        final record = SenderKeyRecord.fromSerialized(bytes);
        debugPrint('[SENDER_KEY_STORE] Loaded sender key for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}');
        return record;
      }
      // Return new empty record if not found (required by libsignal API)
      debugPrint('[SENDER_KEY_STORE] No sender key found for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}, returning empty record');
      return SenderKeyRecord();
    } else {
      final storage = FlutterSecureStorage();
      var value = await storage.read(key: key);
      
      if (value != null) {
        final bytes = base64Decode(value);
        final record = SenderKeyRecord.fromSerialized(bytes);
        debugPrint('[SENDER_KEY_STORE] Loaded sender key for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}');
        return record;
      }
      // Return new empty record if not found (required by libsignal API)
      debugPrint('[SENDER_KEY_STORE] No sender key found for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}, returning empty record');
      return SenderKeyRecord();
    }
  }

  /// Check if sender key exists
  Future<bool> containsSenderKey(SenderKeyName senderKeyName) async {
    final key = _getStorageKey(senderKeyName);
    
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

  /// Remove sender key for a specific sender in a group
  Future<void> removeSenderKey(SenderKeyName senderKeyName) async {
    final key = _getStorageKey(senderKeyName);

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
      
      debugPrint('[SENDER_KEY_STORE] Removed sender key for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}');
    } else {
      final storage = FlutterSecureStorage();
      await storage.delete(key: key);

      // Update key list
      String? keysJson = await storage.read(key: 'sender_key_list');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        keys.remove(key);
        await storage.write(key: 'sender_key_list', value: jsonEncode(keys));
      }
      
      debugPrint('[SENDER_KEY_STORE] Removed sender key for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}');
    }
  }

  /// Clear all sender keys for a group
  Future<void> clearGroupSenderKeys(String groupId) async {
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
      
      // Get all keys and filter by group
      var cursor = await store.openCursor(autoAdvance: true);
      await cursor.forEach((CursorWithValue c) async {
        final key = c.key as String;
        if (key.contains('${_keyPrefix}${groupId}_')) {
          await store.delete(key);
        }
      });
      
      await txn.completed;
      debugPrint('[SENDER_KEY_STORE] Cleared all sender keys for group $groupId');
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'sender_key_list');
      
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        final groupKeys = keys.where((k) => k.contains('${_keyPrefix}${groupId}_')).toList();
        
        for (final key in groupKeys) {
          await storage.delete(key: key);
          keys.remove(key);
        }
        
        await storage.write(key: 'sender_key_list', value: jsonEncode(keys));
      }
      
      debugPrint('[SENDER_KEY_STORE] Cleared all sender keys for group $groupId');
    }
  }

  /// Get all group IDs that have sender keys
  Future<List<String>> getAllGroupIds() async {
    final Set<String> groupIds = {};

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
      
      var cursor = await store.openCursor(autoAdvance: true);
      await cursor.forEach((CursorWithValue c) {
        final key = c.key as String;
        if (key.startsWith(_keyPrefix)) {
          // Extract groupId from key format: sender_key_<groupId>_<userId>_<deviceId>
          final parts = key.substring(_keyPrefix.length).split('_');
          if (parts.isNotEmpty) {
            groupIds.add(parts[0]);
          }
        }
      });
      
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'sender_key_list');
      
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        for (final key in keys) {
          if (key.startsWith(_keyPrefix)) {
            final parts = key.substring(_keyPrefix.length).split('_');
            if (parts.isNotEmpty) {
              groupIds.add(parts[0]);
            }
          }
        }
      }
    }

    return groupIds.toList();
  }

  /// Increment message count for a sender key
  Future<void> incrementMessageCount(SenderKeyName senderKeyName) async {
    final key = _getStorageKey(senderKeyName);
    final metadataKey = '${key}_metadata';

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
      
      var metadataValue = await store.getObject(metadataKey);
      if (metadataValue != null && metadataValue is String) {
        final metadata = jsonDecode(metadataValue);
        metadata['messageCount'] = (metadata['messageCount'] ?? 0) + 1;
        await store.put(jsonEncode(metadata), metadataKey);
      }
      
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      String? metadataJson = await storage.read(key: metadataKey);
      
      if (metadataJson != null) {
        final metadata = jsonDecode(metadataJson);
        metadata['messageCount'] = (metadata['messageCount'] ?? 0) + 1;
        await storage.write(key: metadataKey, value: jsonEncode(metadata));
      }
    }
  }

  /// Check if sender key needs rotation (7 days or 1000 messages)
  Future<bool> needsRotation(SenderKeyName senderKeyName) async {
    final key = _getStorageKey(senderKeyName);
    final metadataKey = '${key}_metadata';

    Map<String, dynamic>? metadata;

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
      
      var metadataValue = await store.getObject(metadataKey);
      await txn.completed;
      
      if (metadataValue != null && metadataValue is String) {
        metadata = jsonDecode(metadataValue);
      }
    } else {
      final storage = FlutterSecureStorage();
      String? metadataJson = await storage.read(key: metadataKey);
      
      if (metadataJson != null) {
        metadata = jsonDecode(metadataJson);
      }
    }

    if (metadata == null) {
      return false; // No metadata, probably a new key
    }

    // Check age (7 days = 604800 seconds)
    final lastRotation = DateTime.parse(metadata['lastRotation'] ?? metadata['createdAt']);
    final age = DateTime.now().difference(lastRotation);
    if (age.inDays >= 7) {
      debugPrint('[SENDER_KEY_STORE] Sender key age: ${age.inDays} days - rotation needed');
      return true;
    }

    // Check message count (1000 messages)
    final messageCount = metadata['messageCount'] ?? 0;
    if (messageCount >= 1000) {
      debugPrint('[SENDER_KEY_STORE] Sender key message count: $messageCount - rotation needed');
      return true;
    }

    return false;
  }

  /// Update rotation timestamp (called after rotation)
  Future<void> updateRotationTimestamp(SenderKeyName senderKeyName) async {
    final key = _getStorageKey(senderKeyName);
    final metadataKey = '${key}_metadata';

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
      
      var metadataValue = await store.getObject(metadataKey);
      if (metadataValue != null && metadataValue is String) {
        final metadata = jsonDecode(metadataValue);
        metadata['lastRotation'] = DateTime.now().toIso8601String();
        metadata['messageCount'] = 0; // Reset counter
        await store.put(jsonEncode(metadata), metadataKey);
      }
      
      await txn.completed;
      debugPrint('[SENDER_KEY_STORE] Updated rotation timestamp for group ${senderKeyName.groupId}');
    } else {
      final storage = FlutterSecureStorage();
      String? metadataJson = await storage.read(key: metadataKey);
      
      if (metadataJson != null) {
        final metadata = jsonDecode(metadataJson);
        metadata['lastRotation'] = DateTime.now().toIso8601String();
        metadata['messageCount'] = 0; // Reset counter
        await storage.write(key: metadataKey, value: jsonEncode(metadata));
      }
      
      debugPrint('[SENDER_KEY_STORE] Updated rotation timestamp for group ${senderKeyName.groupId}');
    }
  }
}

