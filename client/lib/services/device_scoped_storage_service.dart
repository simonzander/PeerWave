import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb.dart';
import 'device_identity_service.dart';
import 'web/encrypted_storage_wrapper.dart';
import 'idb_factory_web.dart' as web;
import 'idb_factory_native.dart' as native;

/// Service for managing device-scoped encrypted IndexedDB storage
/// 
/// Each device gets:
/// 1. Isolated databases (based on device ID)
/// 2. Encrypted data at rest (AES-GCM-256)
/// 3. WebAuthn-derived encryption keys
class DeviceScopedStorageService {
  static final DeviceScopedStorageService instance = DeviceScopedStorageService._();
  DeviceScopedStorageService._();
  
  final DeviceIdentityService _deviceIdentity = DeviceIdentityService.instance;
  late final IdbFactory _idbFactory = _getIdbFactory();
  final EncryptedStorageWrapper _encryption = EncryptedStorageWrapper();
  
  /// Get the appropriate IdbFactory for the current platform
  IdbFactory _getIdbFactory() {
    if (kIsWeb) {
      // Web: Use browser implementation
      debugPrint('[DEVICE_STORAGE] Using idbFactoryBrowser for web');
      return web.getIdbFactoryWeb();
    } else {
      // Native: Use SQLite-backed implementation for persistence
      debugPrint('[DEVICE_STORAGE] Using idbFactorySqflite for native persistence');
      return native.getIdbFactoryNative();
    }
  }
  
  /// Get device-specific database name
  String getDeviceDatabaseName(String baseName) {
    if (!_deviceIdentity.isInitialized) {
      throw Exception('Device identity not initialized');
    }
    
    final deviceId = _deviceIdentity.deviceId;
    return '${baseName}_$deviceId';
  }
  
  /// Open device-specific database
  Future<Database> openDeviceDatabase(
    String baseName, {
    int version = 1,
    required void Function(VersionChangeEvent) onUpgradeNeeded,
  }) async {
    final dbName = getDeviceDatabaseName(baseName);
    
    debugPrint('[DEVICE_STORAGE] Opening encrypted database: $dbName');
    
    return await _idbFactory.open(
      dbName,
      version: version,
      onUpgradeNeeded: onUpgradeNeeded,
    );
  }
  
  /// Store encrypted data in device-specific database
  Future<void> putEncrypted(
    String baseName,
    String storeName,
    String key,
    dynamic value,
  ) async {
    // 1. Encrypt data
    final envelope = await _encryption.encryptForStorage(value);
    
    // 2. Open device-specific database
    final db = await openDeviceDatabase(
      baseName,
      onUpgradeNeeded: (event) {
        final db = event.database;
        if (!db.objectStoreNames.contains(storeName)) {
          db.createObjectStore(storeName, autoIncrement: false);
        }
      },
    );
    
    // 3. Store encrypted envelope
    final txn = db.transaction(storeName, 'readwrite');
    final store = txn.objectStore(storeName);
    await store.put(envelope, key);
    await txn.completed;
    db.close();
    
    debugPrint('[DEVICE_STORAGE] ✓ Stored encrypted data: $key');
  }
  
  /// Retrieve and decrypt data from device-specific database
  Future<dynamic> getDecrypted(
    String baseName,
    String storeName,
    String key,
  ) async {
    // 1. Open device-specific database
    final db = await openDeviceDatabase(
      baseName,
      onUpgradeNeeded: (event) {
        final db = event.database;
        if (!db.objectStoreNames.contains(storeName)) {
          db.createObjectStore(storeName, autoIncrement: false);
        }
      },
    );
    
    // 2. Load encrypted envelope
    final txn = db.transaction(storeName, 'readonly');
    final store = txn.objectStore(storeName);
    final envelope = await store.getObject(key);
    await txn.completed;
    db.close();
    
    if (envelope == null) {
      debugPrint('[DEVICE_STORAGE] ✗ Key not found: $key');
      return null;
    }
    
    // 3. Decrypt data
    try {
      final decrypted = await _encryption.decryptFromStorage(envelope as Map<String, dynamic>);
      debugPrint('[DEVICE_STORAGE] ✓ Retrieved and decrypted data: $key');
      return decrypted;
    } catch (e) {
      debugPrint('[DEVICE_STORAGE] ✗ Decryption failed for $key: $e');
      rethrow;
    }
  }
  
  /// Delete encrypted data from device-scoped database
  Future<void> deleteEncrypted(String baseName, String storeName, dynamic key) async {
    if (!_deviceIdentity.isInitialized) {
      throw Exception('Device identity not set. Call setDeviceIdentity first.');
    }
    
    try {
      final db = await openDeviceDatabase(
        baseName, // 🔧 FIX: Pass baseName directly (openDeviceDatabase adds hash)
        onUpgradeNeeded: (VersionChangeEvent event) {
          final db = event.database;
          if (!db.objectStoreNames.contains(storeName)) {
            db.createObjectStore(storeName, autoIncrement: false);
          }
        },
      );
      
      final txn = db.transaction(storeName, 'readwrite');
      final store = txn.objectStore(storeName);
      
      await store.delete(key);
      await txn.completed;
      
      debugPrint('[DEVICE_STORAGE] ✓ Deleted data: $key');
    } catch (e) {
      debugPrint('[DEVICE_STORAGE] ✗ Delete failed for $key: $e');
      rethrow;
    }
  }
  
  /// Get all keys from device-scoped database (for iteration)
  Future<List<String>> getAllKeys(String baseName, String storeName) async {
    if (!_deviceIdentity.isInitialized) {
      throw Exception('Device identity not set. Call setDeviceIdentity first.');
    }
    
    try {
      final db = await openDeviceDatabase(
        baseName, // 🔧 FIX: Pass baseName directly (openDeviceDatabase adds hash)
        onUpgradeNeeded: (VersionChangeEvent event) {
          final db = event.database;
          if (!db.objectStoreNames.contains(storeName)) {
            db.createObjectStore(storeName, autoIncrement: false);
          }
        },
      );
      
      debugPrint('[DEVICE_STORAGE] Database opened, checking object stores...');
      debugPrint('[DEVICE_STORAGE] Available object stores: ${db.objectStoreNames}');
      debugPrint('[DEVICE_STORAGE] Looking for store: $storeName');
      
      if (!db.objectStoreNames.contains(storeName)) {
        debugPrint('[DEVICE_STORAGE] ⚠️ Object store "$storeName" does not exist!');
        db.close();
        return [];
      }
      
      final txn = db.transaction(storeName, 'readonly');
      final store = txn.objectStore(storeName);
      
      debugPrint('[DEVICE_STORAGE] Opening cursor to iterate keys...');
      final keys = <String>[];
      final cursor = await store.openCursor(autoAdvance: true);
      
      debugPrint('[DEVICE_STORAGE] Cursor created, iterating...');
      await cursor.forEach((c) {
        final key = c.key.toString();
        debugPrint('[DEVICE_STORAGE] Found key: $key');
        keys.add(key);
      });
      
      await txn.completed;
      db.close();
      
      debugPrint('[DEVICE_STORAGE] ✓ Found ${keys.length} total keys');
      return keys;
    } catch (e) {
      debugPrint('[DEVICE_STORAGE] ✗ Failed to get all keys: $e');
      rethrow;
    }
  }
  
  /// Delete all databases for current device
  Future<void> deleteAllDeviceDatabases() async {
    if (!_deviceIdentity.isInitialized) {
      debugPrint('[DEVICE_STORAGE] No device identity - skipping cleanup');
      return;
    }
    
    debugPrint('[DEVICE_STORAGE] Deleting all databases for device: ${_deviceIdentity.deviceId}');
    
    final baseDatabases = [
      'peerwaveSignal',
      'peerwaveSignalIdentityKeys',
      'peerwavePreKeys',
      'peerwaveSignedPreKeys',
      'peerwaveSenderKeys',
      'peerwaveSessions',
      'peerwaveDecryptedMessages',
      'peerwaveSentMessages',
      'peerwaveDecryptedGroupItems',
      'peerwaveSentGroupItems',
    ];
    
    int deletedCount = 0;
    int errorCount = 0;
    
    for (final baseName in baseDatabases) {
      final dbName = getDeviceDatabaseName(baseName);
      try {
        await _idbFactory.deleteDatabase(dbName);
        deletedCount++;
        debugPrint('[DEVICE_STORAGE] ✓ Deleted: $dbName');
      } catch (e) {
        errorCount++;
        debugPrint('[DEVICE_STORAGE] ✗ Failed to delete $dbName: $e');
      }
    }
    
    debugPrint('[DEVICE_STORAGE] Cleanup complete: $deletedCount deleted, $errorCount errors');
  }
}
