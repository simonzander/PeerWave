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
  /// Store multiple prekeys at once and emit them in a single call.
  Future<void> storePreKeys(List<PreKeyRecord> preKeys) async {
    if (preKeys.isEmpty) return;
    print("Storing ${preKeys.length} pre keys in batch");
    // Prepare for emit
    final preKeyPayload = preKeys.map((k) => {
      'id': k.id,
      'data': base64Encode(k.getKeyPair().publicKey.serialize()),
    }).toList();
    
    // CRITICAL FIX: Server expects { preKeys: [...] } not just [...]
    SocketService().emit("storePreKeys", { 'preKeys': preKeyPayload });
    
    // Store locally
    for (final record in preKeys) {
      await storePreKey(record.id, record, sendToServer: false);
    }
  }

  /// Returns all locally stored PreKeyRecords.
  Future<List<PreKeyRecord>> getAllPreKeys() async {
    final ids = await _getAllPreKeyIds();
    List<PreKeyRecord> preKeys = [];
    for (final id in ids) {
      try {
        final preKey = await loadPreKey(id);
        preKeys.add(preKey);
      } catch (_) {
        // Ignore missing or corrupted prekeys
      }
    }
    return preKeys;
  }

  /// Checks if enough prekeys are available, generates and stores more if needed.
  Future<void> checkPreKeys() async {
    final allKeys = await _getAllPreKeyIds();
    if (allKeys.length < 20) {
      print("[PREKEY STORE] Not enough pre keys (${allKeys.length}/110), generating more");
      var lastId = allKeys.isNotEmpty ? allKeys.reduce((a, b) => a > b ? a : b) : -1;
      if (lastId == 9007199254740991) {
        lastId = -1; // Reset to -1 so we start from 0 again
      }
      
      // Calculate how many keys we need to reach 110 total
      final neededKeys = 110 - allKeys.length;
      print("[PREKEY STORE] Need to generate $neededKeys more keys (current: ${allKeys.length}, target: 110)");
      
      // generatePreKeys is INCLUSIVE: generatePreKeys(a, b) generates (b - a + 1) keys
      // To generate exactly `neededKeys`, we do: generatePreKeys(lastId + 1, lastId + neededKeys)
      final startId = lastId + 1;
      final endId = lastId + neededKeys;
      print("[PREKEY STORE] Generating keys from $startId to $endId ($neededKeys keys)");
      
      var newPreKeys = generatePreKeys(startId, endId);
      await storePreKeys(newPreKeys);
      print("[PREKEY STORE] ✓ Generated and stored ${newPreKeys.length} new pre keys");
    }
  }

  /// Loads prekeys from remote server and stores them locally.
  /// IMPORTANT: Always queries server to detect sync issues (e.g. server has 0, local has 43)
  Future<void> loadRemotePreKeys() async {
    // REMOVED: Early exit based on local count
    // Old buggy code: if (localPreKeys.length >= 20) return;
    // This prevented detection of server/client desync!
    
    print('[PREKEY STORE] Querying server for PreKey sync check...');
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

  PermanentPreKeyStore() {
    // Listener for server PreKey query response
    SocketService().registerListener("getPreKeysResponse", (data) async {
      print('[PREKEY STORE] Server has ${data.length} PreKeys');
      final localPreKeys = await _getAllPreKeyIds();
      print('[PREKEY STORE] Local has ${localPreKeys.length} PreKeys');
      
      // CRITICAL FIX: Detect server/client desync
      // Case 1: Server has 0 PreKeys, but we have local PreKeys → Upload all
      if (data.isEmpty && localPreKeys.isNotEmpty) {
        print('[PREKEY STORE] ⚠️  SYNC ISSUE: Server has 0 PreKeys, but local has ${localPreKeys.length}!');
        print('[PREKEY STORE] Uploading all local PreKeys to server...');
        final allLocalKeys = await getAllPreKeys();
        await storePreKeys(allLocalKeys);
        return;
      }
      
      // Case 2: Server has 0 PreKeys and local also empty → Generate new
      if (data.isEmpty) {
        print('[PREKEY STORE] No PreKeys found anywhere, generating 110 new ones');
        // generatePreKeys is INCLUSIVE: generatePreKeys(0, 109) generates 110 keys (0-109)
        var newPreKeys = generatePreKeys(0, 109);
        print('[PREKEY STORE] Generated ${newPreKeys.length} pre keys (IDs 0-109)');
        await storePreKeys(newPreKeys);
        return;
      }
      
      // Case 3: Server has < 20 PreKeys (low threshold)
      if (data.length < 20) {
        print('[PREKEY STORE] Server only has ${data.length} PreKeys (threshold: 20)');
        
        // Sub-case: Local has enough → Upload to server
        if (localPreKeys.length >= 20) {
          print('[PREKEY STORE] Local has enough (${localPreKeys.length}), uploading to server');
          final allLocalKeys = await getAllPreKeys();
          await storePreKeys(allLocalKeys);
          return;
        }
        
        // Sub-case: Both low → Generate more
        print('[PREKEY STORE] Both server and local are low, generating more');
        var lastId = data.isNotEmpty
            ? data.map((e) => e['prekey_id']).reduce((a, b) => a > b ? a : b)
            : -1; // Start from -1 so first key will be 0
        if (lastId == 9007199254740991) {
          lastId = -1;
        }
        
        // Calculate how many keys needed to reach 110
        final currentCount = data.length;
        final neededKeys = 110 - currentCount;
        print('[PREKEY STORE] Need $neededKeys more keys (current: $currentCount, target: 110)');
        
        // generatePreKeys is INCLUSIVE: to generate neededKeys, use (lastId + 1) to (lastId + neededKeys)
        final startId = lastId + 1;
        final endId = lastId + neededKeys;
        print('[PREKEY STORE] Generating keys from $startId to $endId');
        
        var newPreKeys = generatePreKeys(startId, endId);
        print('[PREKEY STORE] Generated ${newPreKeys.length} pre keys');
        await storePreKeys(newPreKeys);
        return;
      }
      
      // Case 4: Server has >= 20 PreKeys → All good
      print('[PREKEY STORE] ✅ Server has sufficient PreKeys (${data.length})');
    });
    
    // NEW: Listener for PreKey sync response after storePreKeys
    SocketService().registerListener("storePreKeysResponse", (response) async {
      if (response['success'] == true) {
        final List<dynamic> serverPreKeyIds = response['serverPreKeyIds'] ?? [];
        print('[PREKEY STORE] 🔄 Sync verification: Server has ${serverPreKeyIds.length} PreKey IDs');
        
        // Perform sync cleanup
        await _syncWithServerIds(serverPreKeyIds.cast<int>());
      } else {
        print('[PREKEY STORE] ❌ PreKey upload failed: ${response['error']}');
      }
    });
    
    loadRemotePreKeys();
  }
  
  /// Synchronize local PreKeys with server IDs
  /// Deletes local PreKeys that don't exist on server
  Future<void> _syncWithServerIds(List<int> serverIds) async {
    final localIds = await _getAllPreKeyIds();
    print('[PREKEY STORE] 🔍 Comparing local (${localIds.length}) with server (${serverIds.length})');
    
    // Find local PreKeys that are NOT on server
    final orphanedIds = localIds.where((id) => !serverIds.contains(id)).toList();
    
    if (orphanedIds.isNotEmpty) {
      print('[PREKEY STORE] ⚠️  Found ${orphanedIds.length} orphaned local PreKeys: $orphanedIds');
      print('[PREKEY STORE] 🗑️  Deleting orphaned PreKeys from local storage...');
      
      for (final id in orphanedIds) {
        try {
          // CRITICAL: sendToServer=false prevents double-deletion on server
          await removePreKey(id, sendToServer: false);
          print('[PREKEY STORE] ✅ Deleted orphaned PreKey $id (local only)');
        } catch (e) {
          print('[PREKEY STORE] ❌ Failed to delete PreKey $id: $e');
        }
      }
      
      print('[PREKEY STORE] ✅ Sync cleanup complete - removed ${orphanedIds.length} orphaned PreKeys');
    } else {
      print('[PREKEY STORE] ✅ Perfect sync - all local PreKeys exist on server');
    }
    
    // Verify final state
    final finalLocalIds = await _getAllPreKeyIds();
    print('[PREKEY STORE] 📊 Final state: Local=${finalLocalIds.length}, Server=${serverIds.length}');
  }

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
  Future<void> removePreKey(int preKeyId, {bool sendToServer = true}) async {
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
    
    // Only send to server if requested (skip during sync cleanup)
    if (sendToServer) {
      SocketService().emit("removePreKey", {'id': preKeyId});
    }
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record, {bool sendToServer = true}) async {
    print("Storing pre key: $preKeyId");
    if (sendToServer) {
      SocketService().emit("storePreKey", {
        'id': preKeyId,
        'data': base64Encode(record.getKeyPair().publicKey.serialize()),
      });
    }
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
