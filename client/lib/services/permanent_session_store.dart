import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb_browser.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'device_scoped_storage_service.dart';

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
    debugPrint('[PermanentSessionStore] containsSession: address = $address');
    try {
      debugPrint('[PermanentSessionStore] containsSession: address.getName() = \'${address.getName()}\', address.getDeviceId() = ${address.getDeviceId()} (type: \'${address.getDeviceId().runtimeType}\')');
      if (kIsWeb) {
        // Use encrypted device-scoped storage
        final storage = DeviceScopedStorageService.instance;
        var key = _sessionKey(address);
        debugPrint('[PermanentSessionStore] containsSession: session key = $key');
        var value = await storage.getDecrypted(_storeName, _storeName, key);
        debugPrint('[PermanentSessionStore] containsSession: value = $value');
        return value != null;
      } else {
        final storage = FlutterSecureStorage();
        var key = _sessionKey(address);
        debugPrint('[PermanentSessionStore] containsSession: session key = $key');
        var value = await storage.read(key: key);
        debugPrint('[PermanentSessionStore] containsSession: value = $value');
        return value != null;
      }
    } catch (e, st) {
      debugPrint('[PermanentSessionStore][ERROR] containsSession exception: $e\n$st');
      rethrow;
    }
  }

  @override
  Future<void> deleteAllSessions(String name) async {
  if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      final keys = await storage.getAllKeys(_storeName, _storeName);
      
      for (var key in keys) {
        if (key.startsWith(_keyPrefix + name + '_')) {
          await storage.deleteEncrypted(_storeName, _storeName, key);
        }
      }
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
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      await storage.deleteEncrypted(_storeName, _storeName, sessionKey);
    } else{
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
      // 🔒 Use encrypted storage
      final storage = DeviceScopedStorageService.instance;
      var keys = await storage.getAllKeys(_storeName, _storeName);
      
      for (var key in keys) {
        if (key.startsWith(_keyPrefix + name + '_')) {
          var deviceIdStr = key.substring((_keyPrefix + name + '_').length);
          var deviceId = int.tryParse(deviceIdStr);
          if (deviceId != null && deviceId != 1) {
            deviceIds.add(deviceId);
          }
        }
      }
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
          // Use encrypted device-scoped storage
          final storage = DeviceScopedStorageService.instance;
          var value = await storage.getDecrypted(_storeName, _storeName, _sessionKey(address));
          
          if (value != null) {
            return SessionRecord.fromSerialized(base64Decode(value));
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
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      await storage.putEncrypted(_storeName, _storeName, sessionKey, base64Encode(serialized));
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

