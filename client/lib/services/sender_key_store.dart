import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'device_scoped_storage_service.dart';

/// Store for Signal Sender Keys used in group chats
/// Implements SenderKeyStore interface from libsignal
class PermanentSenderKeyStore extends SenderKeyStore {
  final String _storeName = 'peerwaveSenderKeys';
  final String _keyPrefix = 'sender_key_';

  PermanentSenderKeyStore();

  static Future<PermanentSenderKeyStore> create() async {
    final store = PermanentSenderKeyStore();

    // Device-scoped database will be created automatically by DeviceScopedStorageService
    // on first putEncrypted() call. No need to pre-create the database.

    if (!kIsWeb) {
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
  Future<void> storeSenderKey(
    SenderKeyName senderKeyName,
    SenderKeyRecord record,
  ) async {
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
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;

      // Get existing metadata to preserve messageCount
      final existingMetadata = await storage.getDecrypted(
        _storeName,
        _storeName,
        metadataKey,
      );
      if (existingMetadata != null) {
        try {
          final existing = jsonDecode(existingMetadata);
          metadata['messageCount'] = existing['messageCount'] ?? 0;
        } catch (e) {
          // Ignore parse errors, use default metadata
        }
      }

      // Store encrypted sender key and metadata
      await storage.storeEncrypted(_storeName, _storeName, key, serialized);
      await storage.storeEncrypted(
        _storeName,
        _storeName,
        metadataKey,
        jsonEncode(metadata),
      );

      debugPrint(
        '[SENDER_KEY_STORE] Stored encrypted sender key for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}',
      );
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
      List<String> keys = keysJson != null
          ? List<String>.from(jsonDecode(keysJson))
          : [];
      if (!keys.contains(key)) {
        keys.add(key);
        await storage.write(key: 'sender_key_list', value: jsonEncode(keys));
      }

      debugPrint(
        '[SENDER_KEY_STORE] Stored sender key for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}',
      );
    }
  }

  @override
  Future<SenderKeyRecord> loadSenderKey(SenderKeyName senderKeyName) async {
    final key = _getStorageKey(senderKeyName);

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      final value = await storage.getDecrypted(_storeName, _storeName, key);

      if (value != null) {
        final bytes = base64Decode(value);
        final record = SenderKeyRecord.fromSerialized(bytes);
        debugPrint(
          '[SENDER_KEY_STORE] Loaded encrypted sender key for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}',
        );
        return record;
      }
      // Return new empty record if not found (required by libsignal API)
      debugPrint(
        '[SENDER_KEY_STORE] No sender key found for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}, returning empty record',
      );
      return SenderKeyRecord();
    } else {
      final storage = FlutterSecureStorage();
      var value = await storage.read(key: key);

      if (value != null) {
        final bytes = base64Decode(value);
        final record = SenderKeyRecord.fromSerialized(bytes);
        debugPrint(
          '[SENDER_KEY_STORE] Loaded sender key for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}',
        );
        return record;
      }
      // Return new empty record if not found (required by libsignal API)
      debugPrint(
        '[SENDER_KEY_STORE] No sender key found for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}, returning empty record',
      );
      return SenderKeyRecord();
    }
  }

  /// Load sender key for a specific server (multi-server support)
  Future<SenderKeyRecord> loadSenderKeyForServer(
    SenderKeyName senderKeyName,
    String serverUrl,
  ) async {
    final key = _getStorageKey(senderKeyName);
    final storage = DeviceScopedStorageService.instance;
    final value = await storage.getDecrypted(
      _storeName,
      _storeName,
      key,
      serverUrl: serverUrl,
    );

    if (value != null) {
      final bytes = base64Decode(value);
      return SenderKeyRecord.fromSerialized(bytes);
    }
    return SenderKeyRecord();
  }

  /// Check if sender key exists
  Future<bool> containsSenderKey(SenderKeyName senderKeyName) async {
    final key = _getStorageKey(senderKeyName);

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      final value = await storage.getDecrypted(_storeName, _storeName, key);
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
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      await storage.deleteEncrypted(_storeName, _storeName, key);

      debugPrint(
        '[SENDER_KEY_STORE] Removed encrypted sender key for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}',
      );
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

      debugPrint(
        '[SENDER_KEY_STORE] Removed sender key for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}',
      );
    }
  }

  /// Clear all sender keys for a group
  Future<void> clearGroupSenderKeys(String groupId) async {
    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;

      // Get all keys and filter by group
      final allKeys = await storage.getAllKeys(_storeName, _storeName);
      final groupKeys = allKeys.where(
        (k) => k.contains('$_keyPrefix$groupId}_'),
      );

      for (final key in groupKeys) {
        await storage.deleteEncrypted(_storeName, _storeName, key);
      }

      debugPrint(
        '[SENDER_KEY_STORE] Cleared all encrypted sender keys for group $groupId',
      );
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'sender_key_list');

      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        final groupKeys = keys
            .where((k) => k.contains('$_keyPrefix$groupId}_'))
            .toList();

        for (final key in groupKeys) {
          await storage.delete(key: key);
          keys.remove(key);
        }

        await storage.write(key: 'sender_key_list', value: jsonEncode(keys));
      }

      debugPrint(
        '[SENDER_KEY_STORE] Cleared all sender keys for group $groupId',
      );
    }
  }

  /// Delete ALL sender keys (for all groups)
  /// Used when Identity Key is regenerated - all SenderKeys become invalid
  Future<void> deleteAllSenderKeys() async {
    debugPrint('[SENDER_KEY_STORE] Deleting ALL sender keys...');

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;

      // Get all keys and delete sender keys
      final allKeys = await storage.getAllKeys(_storeName, _storeName);
      final senderKeys = allKeys.where((k) => k.startsWith(_keyPrefix));

      int deletedCount = 0;
      for (final key in senderKeys) {
        await storage.deleteEncrypted(_storeName, _storeName, key);
        deletedCount++;
      }

      debugPrint('[SENDER_KEY_STORE] ✓ Deleted $deletedCount sender keys');
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'sender_key_list');

      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        int deletedCount = keys.length;

        for (final key in keys) {
          await storage.delete(key: key);
          // Also delete metadata
          await storage.delete(key: '${key}_metadata');
        }

        // Clear the list
        await storage.write(key: 'sender_key_list', value: jsonEncode([]));
        debugPrint('[SENDER_KEY_STORE] ✓ Deleted $deletedCount sender keys');
      } else {
        debugPrint('[SENDER_KEY_STORE] No sender keys to delete');
      }
    }
  }

  /// Get all group IDs that have sender keys
  Future<List<String>> getAllGroupIds() async {
    final Set<String> groupIds = {};

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;

      // Get all keys and extract group IDs
      final allKeys = await storage.getAllKeys(_storeName, _storeName);

      for (final key in allKeys) {
        if (key.startsWith(_keyPrefix) && !key.endsWith('_metadata')) {
          // Extract groupId from key format: sender_key_<groupId>_<userId>_<deviceId>
          final parts = key.substring(_keyPrefix.length).split('_');
          if (parts.isNotEmpty) {
            groupIds.add(parts[0]);
          }
        }
      }
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
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;

      final metadataValue = await storage.getDecrypted(
        _storeName,
        _storeName,
        metadataKey,
      );
      if (metadataValue != null) {
        final metadata = jsonDecode(metadataValue);
        metadata['messageCount'] = (metadata['messageCount'] ?? 0) + 1;
        await storage.storeEncrypted(
          _storeName,
          _storeName,
          metadataKey,
          jsonEncode(metadata),
        );
      }
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
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;

      final metadataValue = await storage.getDecrypted(
        _storeName,
        _storeName,
        metadataKey,
      );
      if (metadataValue != null) {
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
    final lastRotation = DateTime.parse(
      metadata['lastRotation'] ?? metadata['createdAt'],
    );
    final age = DateTime.now().difference(lastRotation);
    if (age.inDays >= 7) {
      debugPrint(
        '[SENDER_KEY_STORE] Sender key age: ${age.inDays} days - rotation needed',
      );
      return true;
    }

    // Check message count (1000 messages)
    final messageCount = metadata['messageCount'] ?? 0;
    if (messageCount >= 1000) {
      debugPrint(
        '[SENDER_KEY_STORE] Sender key message count: $messageCount - rotation needed',
      );
      return true;
    }

    return false;
  }

  /// Update rotation timestamp (called after rotation)
  Future<void> updateRotationTimestamp(SenderKeyName senderKeyName) async {
    final key = _getStorageKey(senderKeyName);
    final metadataKey = '${key}_metadata';

    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;

      final metadataValue = await storage.getDecrypted(
        _storeName,
        _storeName,
        metadataKey,
      );
      if (metadataValue != null) {
        final metadata = jsonDecode(metadataValue);
        metadata['lastRotation'] = DateTime.now().toIso8601String();
        metadata['messageCount'] = 0; // Reset counter
        await storage.storeEncrypted(
          _storeName,
          _storeName,
          metadataKey,
          jsonEncode(metadata),
        );
      }

      debugPrint(
        '[SENDER_KEY_STORE] Updated rotation timestamp for group ${senderKeyName.groupId}',
      );
    } else {
      final storage = FlutterSecureStorage();
      String? metadataJson = await storage.read(key: metadataKey);

      if (metadataJson != null) {
        final metadata = jsonDecode(metadataJson);
        metadata['lastRotation'] = DateTime.now().toIso8601String();
        metadata['messageCount'] = 0; // Reset counter
        await storage.write(key: metadataKey, value: jsonEncode(metadata));
      }

      debugPrint(
        '[SENDER_KEY_STORE] Updated rotation timestamp for group ${senderKeyName.groupId}',
      );
    }
  }
}
