import 'socket_service.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb_browser.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// A persistent signed pre-key store for Signal signed pre-keys.
/// Uses IndexedDB on web and FlutterSecureStorage on native.
class PermanentSignedPreKeyStore extends SignedPreKeyStore {

final IdentityKeyPair identityKeyPair;

  final String _storeName = 'peerwaveSignalSignedPreKeys';
  final String _keyPrefix = 'signedprekey_';

  PermanentSignedPreKeyStore(this.identityKeyPair);

  String _signedPreKey(int signedPreKeyId) => '$_keyPrefix$signedPreKeyId';

  Future<void> loadRemoteSignedPreKeys() async {
    SocketService().registerListener("getSignedPreKeysResponse", (data) async {
      print(data);
      for (var item in data) {
        if (item['signed_prekey_id'] != null && item['signed_prekey_data'] != null && item['createdAt'] != null) {
          await storeSignedPreKey(
            item['signed_prekey_id'],
            SignedPreKeyRecord.fromSerialized(base64Decode(item['signed_prekey_data'])),
          );
          if (DateTime.parse(item['createdAt']).millisecondsSinceEpoch < DateTime.now().millisecondsSinceEpoch - 1 * 24 * 60 * 60 * 1000) {
            // If preSignedKey is older than 1 day, create new one
            var newPreSignedKey = generateSignedPreKey(identityKeyPair, data.length);
            await storeSignedPreKey(newPreSignedKey.id, newPreSignedKey);
            await removeSignedPreKey(item['signed_prekey_id']);
          }
        }
      }
      if (data.isEmpty) {
        print("No signed pre keys found, creating new one");
        var newPreSignedKey = generateSignedPreKey(identityKeyPair, 0);
        await storeSignedPreKey(newPreSignedKey.id, newPreSignedKey);
      }
    });
    SocketService().emit("getSignedPreKeys", null);
  }

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
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
        await txn.completed;
        if (value is String) {
          return SignedPreKeyRecord.fromSerialized(base64Decode(value));
        } else if (value is Uint8List) {
          return SignedPreKeyRecord.fromSerialized(value);
        } else {
          throw Exception('Invalid signed prekey data');
        }
      } else {
        final storage = FlutterSecureStorage();
        var value = await storage.read(key: _signedPreKey(signedPreKeyId));
        if (value != null) {
          return SignedPreKeyRecord.fromSerialized(base64Decode(value));
        } else {
          throw Exception('No such signedprekeyrecord! $signedPreKeyId');
        }
      }
    } else {
      throw Exception('No such signedprekeyrecord! $signedPreKeyId');
    }
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    final results = <SignedPreKeyRecord>[];
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
            results.add(SignedPreKeyRecord.fromSerialized(base64Decode(value)));
          } else if (value is Uint8List) {
            results.add(SignedPreKeyRecord.fromSerialized(value));
          }
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
          if (value != null) {
            results.add(SignedPreKeyRecord.fromSerialized(base64Decode(value)));
          }
        }
      }
    }
    return results;
  }

  @override
  Future<void> storeSignedPreKey(int signedPreKeyId, SignedPreKeyRecord record) async {
    print("Storing signed pre key: $signedPreKeyId");
    SocketService().emit("storeSignedPreKey", {
      'id': signedPreKeyId,
      'data': base64Encode(record.serialize()),
    });
    final serialized = record.serialize();
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
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      await storage.write(key: _signedPreKey(signedPreKeyId), value: base64Encode(serialized));
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
    print("Removing signed pre key: $signedPreKeyId");
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
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      await storage.delete(key: _signedPreKey(signedPreKeyId));
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
