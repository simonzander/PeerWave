import 'socket_service.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb_browser.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Wrapper for a signed pre-key and its metadata.
class StoredSignedPreKey {
  final SignedPreKeyRecord record;
  final DateTime? createdAt;
  StoredSignedPreKey({required this.record, this.createdAt});
}

/// A persistent signed pre-key store for Signal signed pre-keys.
/// Uses IndexedDB on web and FlutterSecureStorage on native.
class PermanentSignedPreKeyStore extends SignedPreKeyStore {

  /// Loads a signed prekey and its metadata (createdAt).
  Future<StoredSignedPreKey?> loadStoredSignedPreKey(int signedPreKeyId) async {
    if (await containsSignedPreKey(signedPreKeyId)) {
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
        var value = await store.getObject(_signedPreKey(signedPreKeyId));
        var metaValue = await store.getObject(_signedPreKeyMeta(signedPreKeyId));
        await txn.completed;
        SignedPreKeyRecord? record;
        if (value is String) {
          record = SignedPreKeyRecord.fromSerialized(base64Decode(value));
        } else if (value is Uint8List) {
          record = SignedPreKeyRecord.fromSerialized(value);
        } else {
          throw Exception('Invalid signed prekey data');
        }
        DateTime? createdAt;
        if (metaValue is String) {
          var meta = jsonDecode(metaValue);
          if (meta is Map && meta['createdAt'] != null) {
            createdAt = DateTime.parse(meta['createdAt']);
          }
        }
        return StoredSignedPreKey(record: record, createdAt: createdAt);
      } else {
        final storage = FlutterSecureStorage();
        var value = await storage.read(key: _signedPreKey(signedPreKeyId));
        var metaValue = await storage.read(key: _signedPreKeyMeta(signedPreKeyId));
        if (value != null) {
          var record = SignedPreKeyRecord.fromSerialized(base64Decode(value));
          DateTime? createdAt;
          if (metaValue != null) {
            var meta = jsonDecode(metaValue);
            if (meta is Map && meta['createdAt'] != null) {
              createdAt = DateTime.parse(meta['createdAt']);
            }
          }
          return StoredSignedPreKey(record: record, createdAt: createdAt);
        } else {
          throw Exception('No such signedprekeyrecord! $signedPreKeyId');
        }
      }
    } else {
      return null;
    }
  }

  /// Loads all signed prekeys and their metadata.
  Future<List<StoredSignedPreKey>> loadAllStoredSignedPreKeys() async {
    final results = <StoredSignedPreKey>[];
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
        if (key is String && key.startsWith(_keyPrefix) && !key.endsWith('_meta')) {
          var value = await store.getObject(key);
          var metaValue = await store.getObject(key + '_meta');
          SignedPreKeyRecord? record;
          if (value is String) {
            record = SignedPreKeyRecord.fromSerialized(base64Decode(value));
          } else if (value is Uint8List) {
            record = SignedPreKeyRecord.fromSerialized(value);
          }
          DateTime? createdAt;
          if (metaValue is String) {
            var meta = jsonDecode(metaValue);
            if (meta is Map && meta['createdAt'] != null) {
              createdAt = DateTime.parse(meta['createdAt']);
            }
          }
          if (record != null) results.add(StoredSignedPreKey(record: record, createdAt: createdAt));
        }
      }
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'signedprekey_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        for (var key in keys) {
          var value = await storage.read(key: key);
          var metaValue = await storage.read(key: key + '_meta');
          SignedPreKeyRecord? record;
          if (value != null) {
            record = SignedPreKeyRecord.fromSerialized(base64Decode(value));
            DateTime? createdAt;
            if (metaValue != null) {
              var meta = jsonDecode(metaValue);
              if (meta is Map && meta['createdAt'] != null) {
                createdAt = DateTime.parse(meta['createdAt']);
              }
            }
            results.add(StoredSignedPreKey(record: record, createdAt: createdAt));
          }
        }
      }
    }
    return results;
  }

final IdentityKeyPair identityKeyPair;

  final String _storeName = 'peerwaveSignalSignedPreKeys';
  final String _keyPrefix = 'signedprekey_';


  PermanentSignedPreKeyStore(this.identityKeyPair) {
    // Listen for incoming signed prekeys from server
    SocketService().registerListener("getSignedPreKeysResponse", (data) async {
      // Server does not store private keys; nothing to reconstruct here.
      if (data.isEmpty) {
        debugPrint("No signed pre keys found, creating new one");
        var newPreSignedKey = generateSignedPreKey(identityKeyPair, 0);
        await storeSignedPreKey(newPreSignedKey.id, newPreSignedKey);
      }
    });
    // check if we have any signed prekeys, if not create one
    loadAllStoredSignedPreKeys().then((keys) async {
      if (keys.isEmpty) {
        debugPrint("No signed pre keys found locally, creating new one");
        var newPreSignedKey = generateSignedPreKey(identityKeyPair, 0);
        await storeSignedPreKey(newPreSignedKey.id, newPreSignedKey);
        return;
      }
      
      // Sort by createdAt (newest first)
      keys.sort((a, b) {
        if (a.createdAt == null) return 1;
        if (b.createdAt == null) return -1;
        return b.createdAt!.compareTo(a.createdAt!);
      });
      
      // Check if the NEWEST signed prekey is older than 7 days
      final newest = keys.first;
      final createdAt = newest.createdAt;
      if (createdAt != null && DateTime.now().difference(createdAt).inDays > 7) {
        debugPrint("Found expired signed pre key (older than 7 days), creating new one");
        var newPreSignedKey = generateSignedPreKey(identityKeyPair, keys.length);
        await storeSignedPreKey(newPreSignedKey.id, newPreSignedKey);
      }
      
      // Delete all old signed prekeys except the newest one
      for (int i = 1; i < keys.length; i++) {
        debugPrint("Removing old signed pre key: ${keys[i].record.id}");
        await removeSignedPreKey(keys[i].record.id);
      }
    });
  }

  String _signedPreKey(int signedPreKeyId) => '$_keyPrefix$signedPreKeyId';
  String _signedPreKeyMeta(int signedPreKeyId) => '$_keyPrefix${signedPreKeyId}_meta';


  Future<void> loadRemoteSignedPreKeys() async {
    SocketService().emit("getSignedPreKeys", null);
  }

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final stored = await loadStoredSignedPreKey(signedPreKeyId);
    if (stored != null) {
      return stored.record;
    } else {
      throw Exception('No such signedprekeyrecord! $signedPreKeyId');
    }
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    // For compatibility, return only the records (without metadata)
    final stored = await loadAllStoredSignedPreKeys();
    return stored.map((e) => e.record).toList();
  }

  @override
  Future<void> storeSignedPreKey(int signedPreKeyId, SignedPreKeyRecord record) async {
    debugPrint("Storing signed pre key: $signedPreKeyId");
    // Split SignedPreKeyRecord into publicKey and signature for storage
    final publicKey = base64Encode(record.getKeyPair().publicKey.serialize());
    final signature = base64Encode(record.signature);

    // Optionally, you can still store the full serialized record for compatibility
    SocketService().emit("storeSignedPreKey", {
      'id': signedPreKeyId,
      'data': publicKey,
      "signature": signature,
    });
    final serialized = record.serialize();
  final createdAt = DateTime.now().toIso8601String();
  final meta = jsonEncode({'createdAt': createdAt});
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
      await store.put(base64Encode(serialized), _signedPreKey(signedPreKeyId));
      await store.put(meta, _signedPreKeyMeta(signedPreKeyId));
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      await storage.write(key: _signedPreKey(signedPreKeyId), value: base64Encode(serialized));
      await storage.write(key: _signedPreKeyMeta(signedPreKeyId), value: meta);
      // Track signed prekey key
      String? keysJson = await storage.read(key: 'signedprekey_keys');
      List<String> keys = [];
      if (keysJson != null) {
        keys = List<String>.from(jsonDecode(keysJson));
      }
      final preKeyStr = _signedPreKey(signedPreKeyId);
      if (!keys.contains(preKeyStr)) {
        keys.add(preKeyStr);
        await storage.write(key: 'signedprekey_keys', value: jsonEncode(keys));
      }
    }
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async {
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
      var value = await store.getObject(_signedPreKey(signedPreKeyId));
      await txn.completed;
      return value != null;
    } else {
      final storage = FlutterSecureStorage();
      var value = await storage.read(key: _signedPreKey(signedPreKeyId));
      return value != null;
    }
  }

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    debugPrint("Removing signed pre key: $signedPreKeyId");
    SocketService().emit("removeSignedPreKey", {
      'id': signedPreKeyId,
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
      await store.delete(_signedPreKey(signedPreKeyId));
      await store.delete(_signedPreKeyMeta(signedPreKeyId));
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      await storage.delete(key: _signedPreKey(signedPreKeyId));
      await storage.delete(key: _signedPreKeyMeta(signedPreKeyId));
      // Remove from tracked signed prekey keys
      String? keysJson = await storage.read(key: 'signedprekey_keys');
      List<String> keys = [];
      if (keysJson != null) {
        keys = List<String>.from(jsonDecode(keysJson));
      }
      keys.remove(_signedPreKey(signedPreKeyId));
      await storage.write(key: 'signedprekey_keys', value: jsonEncode(keys));
    }
  }
}

