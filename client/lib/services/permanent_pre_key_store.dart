import 'socket_service.dart';
import 'package:collection/collection.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb_browser.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// A persistent pre-key store for Signal pre-keys.
/// Uses IndexedDB on web and FlutterSecureStorage on native.
class PermanentPreKeyStore extends PreKeyStore {

  /// Checks if enough prekeys are available, generates and stores more if needed.
  Future<void> checkPreKeys() async {
    final allKeys = await _getAllPreKeyIds();
    if (allKeys.length < 20) {
      print("Not enough pre keys, generating more");
      var lastId = allKeys.isNotEmpty ? allKeys.reduce((a, b) => a > b ? a : b) : 0;
      if (lastId == 9007199254740991) {
        lastId = 0;
      }
      var newPreKeys = generatePreKeys(lastId + 1, lastId + 110);
      for (var newPreKey in newPreKeys) {
        await storePreKey(newPreKey.id, newPreKey);
      }
    }
  }

  /// Loads prekeys from remote server and stores them locally.
  Future<void> loadRemotePreKeys() async {
    SocketService().registerListener("getPreKeysResponse", (data) async {
      print(data);
      for (var item in data) {
        if (item['prekey_id'] != null && item['prekey_data'] != null) {
          await storePreKey(item['prekey_id'],
              PreKeyRecord.fromBuffer(base64Decode(item['prekey_data'])));
        }
      }
      if (data.isEmpty) {
        print("No pre keys found, generating more");
        var newPreKeys = generatePreKeys(0, 110);
        for (var newPreKey in newPreKeys) {
          await storePreKey(newPreKey.id, newPreKey);
        }
      }
      if (data.length <= 20) {
        print("Not enough pre keys found, generating more");
        var lastId = data.isNotEmpty
            ? data.map((e) => e['prekey_id']).reduce((a, b) => a > b ? a : b)
            : 0;
        if (lastId == 9007199254740991) {
          lastId = 0;
        }
        var newPreKeys = generatePreKeys(lastId + 1, lastId + 110);
        for (var newPreKey in newPreKeys) {
          await storePreKey(newPreKey.id, newPreKey);
        }
      }
    });
    final localPreKeys = await _getAllPreKeyIds();
    if (localPreKeys.length >= 20) {
      return;
    }
    SocketService().emit("getPreKeys", null);
  }

  /// Helper: Get all prekey IDs (for both web and native)
  Future<List<int>> _getAllPreKeyIds() async {
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
      await txn.completed;
      return keys
          .whereType<String>()
          .map((k) => int.tryParse(k.replaceFirst(_keyPrefix, '')))
          .whereNotNull()
          .toList();
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'prekey_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        return keys
            .map((k) => int.tryParse(k.replaceFirst(_keyPrefix, '')))
            .whereNotNull()
            .toList();
      }
      return [];
    }
  }
  final String _storeName = 'peerwaveSignalPreKeys';
  final String _keyPrefix = 'prekey_';

  PermanentPreKeyStore();

  String _preKey(int preKeyId) => '$_keyPrefix$preKeyId';

  @override
  Future<bool> containsPreKey(int preKeyId) async {
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
      var value = await store.getObject(_preKey(preKeyId));
      await txn.completed;
      return value != null;
    } else {
      final storage = FlutterSecureStorage();
      var value = await storage.read(key: _preKey(preKeyId));
      return value != null;
    }
  }

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    if (await containsPreKey(preKeyId)) {
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
        var value = await store.getObject(_preKey(preKeyId));
        await txn.completed;
        if (value is String) {
          return PreKeyRecord.fromBuffer(base64Decode(value));
        } else if (value is Uint8List) {
          return PreKeyRecord.fromBuffer(value);
        } else {
          throw Exception('Invalid prekey data');
        }
      } else {
        final storage = FlutterSecureStorage();
        var value = await storage.read(key: _preKey(preKeyId));
        if (value != null) {
          return PreKeyRecord.fromBuffer(base64Decode(value));
        } else {
          throw Exception('No such prekeyrecord! - $preKeyId');
        }
      }
    } else {
      throw Exception('No such prekeyrecord! - $preKeyId');
    }
  }

  @override
  Future<void> removePreKey(int preKeyId) async {
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
      await store.delete(_preKey(preKeyId));
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      await storage.delete(key: _preKey(preKeyId));
    }
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    print("Storing pre key: $preKeyId");
    SocketService().emit("storePreKey", {
      'id': preKeyId,
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
      await store.put(base64Encode(serialized), _preKey(preKeyId));
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      await storage.write(key: _preKey(preKeyId), value: base64Encode(serialized));
      // Track prekey key
      String? keysJson = await storage.read(key: 'prekey_keys');
      List<String> keys = [];
      if (keysJson != null) {
        keys = List<String>.from(jsonDecode(keysJson));
      }
      final preKeyStr = _preKey(preKeyId);
      if (!keys.contains(preKeyStr)) {
        keys.add(preKeyStr);
        await storage.write(key: 'prekey_keys', value: jsonEncode(keys));
      }
    }
  }
}
