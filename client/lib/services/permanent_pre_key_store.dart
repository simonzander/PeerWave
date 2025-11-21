import 'socket_service.dart' if (dart.library.io) 'socket_service_native.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
// import 'package:flutter_secure_storage/flutter_secure_storage.dart'; // ❌ LEGACY - Not used anymore
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'device_scoped_storage_service.dart';
import 'api_service.dart';
import '../web_config.dart';
import 'server_config_web.dart' if (dart.library.io) 'server_config_native.dart';

/// A persistent pre-key store for Signal pre-keys.
/// Uses IndexedDB on web and FlutterSecureStorage on native.
class PermanentPreKeyStore extends PreKeyStore {
  /// 🔒 Guard to prevent concurrent checkPreKeys() calls
  bool _isCheckingPreKeys = false;
  
  /// Store multiple prekeys at once via HTTP POST (batch upload)
  /// Returns true if successful, false otherwise
  Future<bool> storePreKeysBatch(List<PreKeyRecord> preKeys) async {
    if (preKeys.isEmpty) return true;
    
    debugPrint("[PREKEY STORE] Storing ${preKeys.length} PreKeys via HTTP batch upload");
    
    try {
      // Get server URL (platform-specific)
      String? serverUrl;
      if (kIsWeb) {
        serverUrl = await loadWebApiServer();
      } else {
        // Native: Get from ServerConfigService
        final activeServer = ServerConfigService.getActiveServer();
        serverUrl = activeServer?.serverUrl;
      }
      
      final urlString = ApiService.ensureHttpPrefix(serverUrl ?? '');
      
      // Prepare payload
      final preKeyPayload = preKeys.map((k) => {
        'id': k.id,
        'data': base64Encode(k.getKeyPair().publicKey.serialize()),
      }).toList();
      
      // Send via HTTP POST
      final response = await ApiService.post(
        '$urlString/signal/prekeys/batch',
        data: { 'preKeys': preKeyPayload }
      );
      
      if (response.statusCode == 200) {
        debugPrint("[PREKEY STORE] ✓ Batch upload successful: ${preKeys.length} keys stored on server");
        
        // Store locally after successful server upload
        for (final record in preKeys) {
          await storePreKey(record.id, record, sendToServer: false);
        }
        
        return true;
      } else if (response.statusCode == 202) {
        // 202 Accepted: Write is queued but not yet completed on server
        debugPrint("[PREKEY STORE] ⏳ Batch upload accepted (processing in background): ${preKeys.length} keys");
        
        // Store locally immediately (client-side storage is fast)
        for (final record in preKeys) {
          await storePreKey(record.id, record, sendToServer: false);
        }
        
        // Add a short delay to allow server background write to complete
        // This prevents immediately checking status before write finishes
        debugPrint("[PREKEY STORE] Waiting 2s for background processing to complete...");
        await Future.delayed(const Duration(seconds: 2));
        
        return true; // Consider this a success - write will complete in background
      } else {
        debugPrint("[PREKEY STORE] ✗ Batch upload failed with status ${response.statusCode}");
        return false;
      }
    } catch (e) {
      debugPrint("[PREKEY STORE] ✗ Batch upload error: $e");
      return false;
    }
  }
  
  /// Store multiple prekeys at once and emit them in a single call.
  Future<void> storePreKeys(List<PreKeyRecord> preKeys) async {
    if (preKeys.isEmpty) return;
    debugPrint("Storing ${preKeys.length} pre keys in batch");
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

  /// Get all PreKey IDs without decrypting (fast for validation/gap analysis)
  Future<List<int>> getAllPreKeyIds() async {
    return await _getAllPreKeyIds();
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
    // 🔒 Prevent concurrent calls (race condition protection)
    if (_isCheckingPreKeys) {
      debugPrint("[PREKEY STORE] checkPreKeys already running, skipping...");
      return;
    }
    
    try {
      _isCheckingPreKeys = true;
      
      final allKeyIds = await _getAllPreKeyIds();
      
      // � OPTIMIZED: Use gap-filling with contiguous range batching
      if (allKeyIds.length < 20) {
        debugPrint("[PREKEY STORE] Not enough pre keys (${allKeyIds.length}/110), generating more");
        
        // Find missing IDs in range 0-109
        final existingIds = allKeyIds.toSet();
        final missingIds = List.generate(110, (i) => i)
            .where((id) => !existingIds.contains(id))
            .toList();
        
        final neededKeys = 110 - allKeyIds.length;
        debugPrint("[PREKEY STORE] Need to generate $neededKeys keys, found ${missingIds.length} missing IDs in range 0-109");
        
        if (missingIds.length != neededKeys) {
          debugPrint("[PREKEY STORE] ⚠️ Mismatch detected! This should not happen.");
        }
        
        // Find contiguous ranges for batch generation
        final contiguousRanges = _findContiguousRanges(missingIds.take(neededKeys).toList());
        debugPrint("[PREKEY STORE] Found ${contiguousRanges.length} range(s) to generate");
        
        final newPreKeys = <PreKeyRecord>[];
        for (final range in contiguousRanges) {
          if (range.length > 1) {
            // BATCH GENERATION: Multiple contiguous IDs (FAST!)
            final start = range.first;
            final end = range.last;
            debugPrint("[PREKEY STORE] Batch generating PreKeys $start-$end (${range.length} keys)");
            final keys = generatePreKeys(start, end);
            newPreKeys.addAll(keys);
          } else {
            // SINGLE GENERATION: Isolated gap
            final id = range.first;
            debugPrint("[PREKEY STORE] Single generating PreKey $id");
            final keys = generatePreKeys(id, id);
            if (keys.isNotEmpty) {
              newPreKeys.add(keys.first);
            }
          }
        }
        
        await storePreKeys(newPreKeys);
        debugPrint("[PREKEY STORE] ✓ Generated and stored ${newPreKeys.length} new pre keys (filling gaps with batching)");
      }
    } finally {
      _isCheckingPreKeys = false;
    }
  }
  
  /// Helper: Find contiguous ranges in a list of IDs for batch generation
  List<List<int>> _findContiguousRanges(List<int> ids) {
    if (ids.isEmpty) return [];
    
    final sortedIds = List<int>.from(ids)..sort();
    final ranges = <List<int>>[];
    var currentRange = <int>[sortedIds[0]];
    
    for (int i = 1; i < sortedIds.length; i++) {
      if (sortedIds[i] == currentRange.last + 1) {
        // Contiguous - add to current range
        currentRange.add(sortedIds[i]);
      } else {
        // Gap found - save current range, start new one
        ranges.add(currentRange);
        currentRange = [sortedIds[i]];
      }
    }
    ranges.add(currentRange); // Add last range
    
    return ranges;
  }

  /* LEGACY REMOTE LOAD - COMMENTED OUT FOR DEBUGGING
  /// Loads prekeys from remote server and stores them locally.
  /// IMPORTANT: Always queries server to detect sync issues (e.g. server has 0, local has 43)
  Future<void> loadRemotePreKeys() async {
    // REMOVED: Early exit based on local count
    // Old buggy code: if (localPreKeys.length >= 20) return;
    // This prevented detection of server/client desync!
    
    debugPrint('[PREKEY STORE] Querying server for PreKey sync check...');
    SocketService().emit("getPreKeys", null);
  }
  */ // END LEGACY REMOTE LOAD

  /// Helper: Get all prekey IDs (for both web and native)
  Future<List<int>> _getAllPreKeyIds() async {
    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    final keys = await storage.getAllKeys(_storeName, _storeName);
    
    return keys
        .where((k) => k.startsWith(_keyPrefix))
        .map((k) => int.tryParse(k.replaceFirst(_keyPrefix, '')))
        .whereType<int>()
        .toList();
    
    /* LEGACY NATIVE STORAGE - DISABLED
    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      final keys = await storage.getAllKeys(_storeName, _storeName);
      
      return keys
          .where((k) => k.startsWith(_keyPrefix))
          .map((k) => int.tryParse(k.replaceFirst(_keyPrefix, '')))
          .whereType<int>()
          .toList();
    } else {
      final storage = FlutterSecureStorage();
      String? keysJson = await storage.read(key: 'prekey_keys');
      if (keysJson != null) {
        List<String> keys = List<String>.from(jsonDecode(keysJson));
        return keys
            .map((k) => int.tryParse(k.replaceFirst(_keyPrefix, '')))
            .whereType<int>()
            .toList();
      }
      return [];
    }
    */
  }
  
  final String _storeName = 'peerwaveSignalPreKeys';
  final String _keyPrefix = 'prekey_';

  PermanentPreKeyStore() {
    debugPrint('[PREKEY STORE] 🔧 Constructor called - LEGACY AUTO-GENERATION DISABLED FOR DEBUGGING');
    
    // 🚫 TEMPORARILY DISABLED: Legacy auto-generation logic
    // This constructor automatically generated PreKeys based on server sync
    // We're disabling it to isolate the current setup issue
    
    /* LEGACY CODE - COMMENTED OUT FOR DEBUGGING
    // Listener for server PreKey query response
    SocketService().registerListener("getPreKeysResponse", (data) async {
      debugPrint('[PREKEY STORE] Server has ${data.length} PreKeys');
      final localPreKeys = await _getAllPreKeyIds();
      debugPrint('[PREKEY STORE] Local has ${localPreKeys.length} PreKeys');
      
      // CRITICAL FIX: Detect server/client desync
      // Case 1: Server has 0 PreKeys, but we have local PreKeys → Upload all
      if (data.isEmpty && localPreKeys.isNotEmpty) {
        debugPrint('[PREKEY STORE] ⚠️  SYNC ISSUE: Server has 0 PreKeys, but local has ${localPreKeys.length}!');
        debugPrint('[PREKEY STORE] Uploading all local PreKeys to server...');
        final allLocalKeys = await getAllPreKeys();
        await storePreKeys(allLocalKeys);
        return;
      }
      
      // Case 2: Server has 0 PreKeys and local also empty → Generate new
      if (data.isEmpty) {
        debugPrint('[PREKEY STORE] No PreKeys found anywhere, generating 110 new ones');
        // generatePreKeys is INCLUSIVE: generatePreKeys(0, 109) generates 110 keys (0-109)
        var newPreKeys = generatePreKeys(0, 109);
        debugPrint('[PREKEY STORE] Generated ${newPreKeys.length} pre keys (IDs 0-109)');
        await storePreKeys(newPreKeys);
        return;
      }
      
      // Case 3: Server has < 20 PreKeys (low threshold)
      if (data.length < 20) {
        debugPrint('[PREKEY STORE] Server only has ${data.length} PreKeys (threshold: 20)');
        
        // Sub-case: Local has enough → Upload to server
        if (localPreKeys.length >= 20) {
          debugPrint('[PREKEY STORE] Local has enough (${localPreKeys.length}), uploading to server');
          final allLocalKeys = await getAllPreKeys();
          await storePreKeys(allLocalKeys);
          return;
        }
        
        // Sub-case: Both low → Generate more
        debugPrint('[PREKEY STORE] Both server and local are low, generating more');
        var lastId = data.isNotEmpty
            ? data.map((e) => e['prekey_id']).reduce((a, b) => a > b ? a : b)
            : -1; // Start from -1 so first key will be 0
        if (lastId == 9007199254740991) {
          lastId = -1;
        }
        
        // Calculate how many keys needed to reach 110
        final currentCount = data.length;
        final neededKeys = 110 - currentCount;
        debugPrint('[PREKEY STORE] Need $neededKeys more keys (current: $currentCount, target: 110)');
        
        // generatePreKeys is INCLUSIVE: to generate neededKeys, use (lastId + 1) to (lastId + neededKeys)
        final startId = lastId + 1;
        final endId = lastId + neededKeys;
        debugPrint('[PREKEY STORE] Generating keys from $startId to $endId');
        
        var newPreKeys = generatePreKeys(startId, endId);
        debugPrint('[PREKEY STORE] Generated ${newPreKeys.length} pre keys');
        await storePreKeys(newPreKeys);
        return;
      }
      
      // Case 4: Server has >= 20 PreKeys → All good
      debugPrint('[PREKEY STORE] ✅ Server has sufficient PreKeys (${data.length})');
    });
    
    // NEW: Listener for PreKey sync response after storePreKeys
    SocketService().registerListener("storePreKeysResponse", (response) async {
      if (response['success'] == true) {
        final List<dynamic> serverPreKeyIds = response['serverPreKeyIds'] ?? [];
        debugPrint('[PREKEY STORE] 🔄 Sync verification: Server has ${serverPreKeyIds.length} PreKey IDs');
        
        // Perform sync cleanup
        await _syncWithServerIds(serverPreKeyIds.cast<int>());
      } else {
        debugPrint('[PREKEY STORE] ❌ PreKey upload failed: ${response['error']}');
      }
    });
    
    loadRemotePreKeys();
    */ 
    // END LEGACY CODE
  }
  
  /* LEGACY SYNC METHOD - COMMENTED OUT FOR DEBUGGING
  /// Synchronize local PreKeys with server IDs
  /// Deletes local PreKeys that don't exist on server
  Future<void> _syncWithServerIds(List<int> serverIds) async {
    final localIds = await _getAllPreKeyIds();
    debugPrint('[PREKEY STORE] 🔍 Comparing local (${localIds.length}) with server (${serverIds.length})');
    
    // Find local PreKeys that are NOT on server
    final orphanedIds = localIds.where((id) => !serverIds.contains(id)).toList();
    
    if (orphanedIds.isNotEmpty) {
      debugPrint('[PREKEY STORE] ⚠️  Found ${orphanedIds.length} orphaned local PreKeys: $orphanedIds');
      debugPrint('[PREKEY STORE] 🗑️  Deleting orphaned PreKeys from local storage...');
      
      for (final id in orphanedIds) {
        try {
          // CRITICAL: sendToServer=false prevents double-deletion on server
          await removePreKey(id, sendToServer: false);
          debugPrint('[PREKEY STORE] ✅ Deleted orphaned PreKey $id (local only)');
        } catch (e) {
          debugPrint('[PREKEY STORE] ❌ Failed to delete PreKey $id: $e');
        }
      }
      
      debugPrint('[PREKEY STORE] ✅ Sync cleanup complete - removed ${orphanedIds.length} orphaned PreKeys');
    } else {
      debugPrint('[PREKEY STORE] ✅ Perfect sync - all local PreKeys exist on server');
    }
    
    // Verify final state
    final finalLocalIds = await _getAllPreKeyIds();
    debugPrint('[PREKEY STORE] 📊 Final state: Local=${finalLocalIds.length}, Server=${serverIds.length}');
  }
  */ // END LEGACY SYNC METHOD

  String _preKey(int preKeyId) => '$_keyPrefix$preKeyId';

  @override
  Future<bool> containsPreKey(int preKeyId) async {
    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    final value = await storage.getDecrypted(_storeName, _storeName, _preKey(preKeyId));
    return value != null;
    
    /* LEGACY NATIVE STORAGE - DISABLED
    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      final value = await storage.getDecrypted(_storeName, _storeName, _preKey(preKeyId));
      return value != null;
    } else {
      final storage = FlutterSecureStorage();
      var value = await storage.read(key: _preKey(preKeyId));
      return value != null;
    }
    */
  }

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    if (await containsPreKey(preKeyId)) {
      // ✅ ONLY encrypted device-scoped storage (Web + Native)
      final storage = DeviceScopedStorageService.instance;
      final value = await storage.getDecrypted(_storeName, _storeName, _preKey(preKeyId));
      
      if (value != null) {
        return PreKeyRecord.fromBuffer(base64Decode(value));
      } else {
        throw Exception('Invalid prekey data');
      }
      
      /* LEGACY NATIVE STORAGE - DISABLED
      if (kIsWeb) {
        // Use encrypted device-scoped storage
        final storage = DeviceScopedStorageService.instance;
        final value = await storage.getDecrypted(_storeName, _storeName, _preKey(preKeyId));
        
        if (value != null) {
          return PreKeyRecord.fromBuffer(base64Decode(value));
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
      */
    } else {
      throw Exception('No such prekeyrecord! - $preKeyId');
    }
  }

  @override
  Future<void> removePreKey(int preKeyId, {bool sendToServer = true}) async {
    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    await storage.deleteEncrypted(_storeName, _storeName, _preKey(preKeyId));
    
    /* LEGACY NATIVE STORAGE - DISABLED
    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      await storage.deleteEncrypted(_storeName, _storeName, _preKey(preKeyId));
    } else {
      final storage = FlutterSecureStorage();
      await storage.delete(key: _preKey(preKeyId));
    }
    */
    
    // Only send to server if requested (skip during sync cleanup)
    if (sendToServer) {
      SocketService().emit("removePreKey", {'id': preKeyId});
    }
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record, {bool sendToServer = true}) async {
    debugPrint("Storing pre key: $preKeyId");
    if (sendToServer) {
      SocketService().emit("storePreKey", {
        'id': preKeyId,
        'data': base64Encode(record.getKeyPair().publicKey.serialize()),
      });
    }
    final serialized = record.serialize();
    
    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    await storage.putEncrypted(_storeName, _storeName, _preKey(preKeyId), base64Encode(serialized));
    
    /* LEGACY NATIVE STORAGE - DISABLED
    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      await storage.putEncrypted(_storeName, _storeName, _preKey(preKeyId), base64Encode(serialized));
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
    */
  }
}

