import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'device_scoped_storage_service.dart';

/// A persistent session store for Signal sessions.
/// Uses encrypted device-scoped storage (IndexedDB on web, native platform storage on Windows/macOS/Linux).
class PermanentSessionStore extends SessionStore {
  final String _storeName = 'peerwaveSignalSessions';
  final String _keyPrefix = 'session_';

  PermanentSessionStore();

  static Future<PermanentSessionStore> create() async {
    final store = PermanentSessionStore();

    // Device-scoped database will be created automatically by DeviceScopedStorageService
    // on first putEncrypted() call. No need to pre-create the database.

    return store;
  }

  // Helper: Compose a unique key for a session
  String _sessionKey(SignalProtocolAddress address) =>
      '$_keyPrefix${address.getName()}_${address.getDeviceId()}';

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async {
    debugPrint('[PermanentSessionStore] containsSession: address = $address');
    try {
      debugPrint(
        '[PermanentSessionStore] containsSession: address.getName() = \'${address.getName()}\', address.getDeviceId() = ${address.getDeviceId()} (type: \'${address.getDeviceId().runtimeType}\')',
      );
      // ✅ ONLY encrypted device-scoped storage (Web + Native)
      final storage = DeviceScopedStorageService.instance;
      var key = _sessionKey(address);
      debugPrint('[PermanentSessionStore] containsSession: session key = $key');
      var value = await storage.getDecrypted(_storeName, _storeName, key);
      debugPrint('[PermanentSessionStore] containsSession: value = $value');
      return value != null;
    } catch (e, st) {
      debugPrint(
        '[PermanentSessionStore][ERROR] containsSession exception: $e\n$st',
      );
      rethrow;
    }
  }

  @override
  Future<void> deleteAllSessions(String name) async {
    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    final keys = await storage.getAllKeys(_storeName, _storeName);

    for (var key in keys) {
      if (key.startsWith('$_keyPrefix$name}_')) {
        await storage.deleteEncrypted(_storeName, _storeName, key);
      }
    }
  }

  /// Delete ALL sessions (for all users and devices)
  /// Used when regenerating identity keys - all sessions become invalid
  Future<void> deleteAllSessionsCompletely() async {
    debugPrint('[PermanentSessionStore] Deleting ALL sessions...');
    final storage = DeviceScopedStorageService.instance;
    final keys = await storage.getAllKeys(_storeName, _storeName);

    int deletedCount = 0;
    for (var key in keys) {
      if (key.startsWith(_keyPrefix)) {
        await storage.deleteEncrypted(_storeName, _storeName, key);
        deletedCount++;
      }
    }
    debugPrint('[PermanentSessionStore] ✓ Deleted $deletedCount sessions');
  }

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async {
    final sessionKey = _sessionKey(address);
    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    await storage.deleteEncrypted(_storeName, _storeName, sessionKey);
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    final deviceIds = <int>[];
    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    var keys = await storage.getAllKeys(_storeName, _storeName);

    for (var key in keys) {
      if (key.startsWith('$_keyPrefix$name}_')) {
        var deviceIdStr = key.substring('$_keyPrefix$name}_'.length);
        var deviceId = int.tryParse(deviceIdStr);
        if (deviceId != null && deviceId != 1) {
          deviceIds.add(deviceId);
        }
      }
    }
    return deviceIds;
  }

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    try {
      if (await containsSession(address)) {
        // ✅ ONLY encrypted device-scoped storage (Web + Native)
        final storage = DeviceScopedStorageService.instance;
        var value = await storage.getDecrypted(
          _storeName,
          _storeName,
          _sessionKey(address),
        );

        if (value != null) {
          return SessionRecord.fromSerialized(base64Decode(value));
        } else {
          return SessionRecord();
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
    SignalProtocolAddress address,
    SessionRecord record,
  ) async {
    final serialized = record.serialize();
    final sessionKey = _sessionKey(address);
    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    await storage.storeEncrypted(
      _storeName,
      _storeName,
      sessionKey,
      base64Encode(serialized),
    );
  }
}
