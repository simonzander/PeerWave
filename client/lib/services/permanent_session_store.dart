import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb_browser.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// A persistent session store for Signal sessions.
/// Uses IndexedDB on web and FlutterSecureStorage on native.
class PermanentSessionStore extends SessionStore {
  final String _storeName = 'peerwaveSignalSessions';
  final String _keyPrefix = 'session_';

  PermanentSessionStore();

  static Future<PermanentSessionStore> create() async {
    final store = PermanentSessionStore();
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
      String? keysJson = await storage.read(key: 'session_keys');
      if (keysJson == null) {
        await storage.write(key: 'session_keys', value: jsonEncode([]));
      }
    }
    return store;
  }

  // Helper: Compose a unique key for a session
  String _sessionKey(SignalProtocolAddress address) =>
      '$_keyPrefix${address.getName()}_${address.getDeviceId()}';

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async {
    print('[PermanentSessionStore] containsSession: address = $address');
    try {
      // Debug: print address info and types
      print('[PermanentSessionStore] containsSession: address.getName() = \'${address.getName()}\', address.getDeviceId() = ${address.getDeviceId()} (type: \'${address.getDeviceId().runtimeType}\')');
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
        var key = _sessionKey(address);
        print('[PermanentSessionStore] containsSession: session key = $key');
        var value = await store.getObject(key);
        await txn.completed;
        print('[PermanentSessionStore] containsSession: value = $value');
        return value != null;
      } else {
        final storage = FlutterSecureStorage();
        var key = _sessionKey(address);
        print('[PermanentSessionStore] containsSession: session key = $key');
        var value = await storage.read(key: key);
        print('[PermanentSessionStore] containsSession: value = $value');
        return value != null;
      }
    } catch (e, st) {
      print('[PermanentSessionStore][ERROR] containsSession exception: $e\n$st');
      rethrow;
    }
  }

  @override
  Future<void> deleteAllSessions(String name) async {
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
        if (key is String && key.startsWith(_keyPrefix + name + '_')) {
          await store.delete(key);
        }
      }
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'session_keys');
      List<String> keys = [];
      if (keysJson != null) {
        keys = List<String>.from(jsonDecode(keysJson));
      }
      List<String> toDelete = keys.where((k) => k.startsWith(_keyPrefix + name + '_')).toList();
      for (var key in toDelete) {
        await storage.delete(key: key);
        keys.remove(key);
      }
      await storage.write(key: 'session_keys', value: jsonEncode(keys));
    }
  }

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async {
  final sessionKey = _sessionKey(address);
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
      await store.delete(_sessionKey(address));
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      await storage.delete(key: sessionKey);
      // Remove from tracked session keys
      String? keysJson = await storage.read(key: 'session_keys');
      List<String> keys = [];
      if (keysJson != null) {
        keys = List<String>.from(jsonDecode(keysJson));
      }
      keys.remove(sessionKey);
      await storage.write(key: 'session_keys', value: jsonEncode(keys));
    }
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    final deviceIds = <int>[];
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
        if (key is String && key.startsWith(_keyPrefix + name + '_')) {
          var deviceIdStr = key.substring((_keyPrefix + name + '_').length);
          var deviceId = int.tryParse(deviceIdStr);
          if (deviceId != null && deviceId != 1) {
            deviceIds.add(deviceId);
          }
        }
      }
      await txn.completed;
    } else {
      // Not supported in FlutterSecureStorage without key tracking
    }
    return deviceIds;
  }

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    try {
      if (await containsSession(address)) {
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
          var value = await store.getObject(_sessionKey(address));
          await txn.completed;
          if (value is String) {
            return SessionRecord.fromSerialized(base64Decode(value));
          } else if (value is Uint8List) {
            return SessionRecord.fromSerialized(value);
          } else {
            return SessionRecord();
          }
        } else {
          final storage = FlutterSecureStorage();
          var value = await storage.read(key: _sessionKey(address));
          if (value != null) {
            return SessionRecord.fromSerialized(base64Decode(value));
          } else {
            return SessionRecord();
          }
        }
      } else {
        return SessionRecord();
      }
    } on Exception catch (e) {
      throw AssertionError(e);
    }
  }

  @override
  Future<void> storeSession(
      SignalProtocolAddress address, SessionRecord record) async {
    final serialized = record.serialize();
  final sessionKey = _sessionKey(address);
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
      await store.put(base64Encode(serialized), _sessionKey(address));
      await txn.completed;
    } else {
      final storage = FlutterSecureStorage();
      await storage.write(key: sessionKey, value: base64Encode(serialized));
      // Track session key
      String? keysJson = await storage.read(key: 'session_keys');
      List<String> keys = [];
      if (keysJson != null) {
        keys = List<String>.from(jsonDecode(keysJson));
      }
      if (!keys.contains(sessionKey)) {
        keys.add(sessionKey);
        await storage.write(key: 'session_keys', value: jsonEncode(keys));
      }
    }
  }
}
