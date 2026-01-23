import 'dart:async';
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
///
/// IMPORTANT: All storage operations wait for device identity to be initialized.
/// This ensures proper device-scoped encryption is ready before any data access.
class DeviceScopedStorageService {
  static final DeviceScopedStorageService instance =
      DeviceScopedStorageService._();
  DeviceScopedStorageService._();

  final DeviceIdentityService _deviceIdentity = DeviceIdentityService.instance;
  IdbFactory? _idbFactory; // Lazy initialization
  final EncryptedStorageWrapper _encryption = EncryptedStorageWrapper();

  // Waiting mechanism for device identity initialization
  final List<Completer<void>> _waitingForInit = [];

  // Cache open databases to avoid closing them prematurely
  final Map<String, Database> _databaseCache = {};
  final Map<String, Future<Database>> _pendingOpens = {};

  /// Get or initialize the IdbFactory (lazy initialization)
  Future<IdbFactory> _getIdbFactory() async {
    if (_idbFactory != null) {
      return _idbFactory!;
    }
    _idbFactory = await _getStaticIdbFactory();
    return _idbFactory!;
  }

  /// Get the appropriate IdbFactory for the current platform (static)
  static Future<IdbFactory> _getStaticIdbFactory() async {
    if (kIsWeb) {
      // Web: Use browser implementation
      debugPrint('[DEVICE_STORAGE] Using idbFactoryBrowser for web');
      return web.getIdbFactoryWeb();
    } else {
      // Native: Use SQLite-backed implementation for persistence
      debugPrint(
        '[DEVICE_STORAGE] Using idbFactorySqflite for native persistence',
      );
      return await native.getIdbFactoryNative();
    }
  }

  /// Wait for device identity to be initialized
  /// Returns immediately if already initialized
  Future<void> _waitForDeviceIdentity() async {
    if (_deviceIdentity.isInitialized) {
      return;
    }

    debugPrint(
      '[DEVICE_STORAGE] ⏳ Waiting for device identity to be initialized...',
    );

    // Create a completer to wait for initialization
    final completer = Completer<void>();
    _waitingForInit.add(completer);

    // Poll for initialization (with timeout)
    final timeout = DateTime.now().add(const Duration(seconds: 30));
    while (!_deviceIdentity.isInitialized) {
      if (DateTime.now().isAfter(timeout)) {
        _waitingForInit.remove(completer);
        throw Exception('Timeout waiting for device identity initialization');
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }

    debugPrint('[DEVICE_STORAGE] ✓ Device identity initialized, continuing...');
    _waitingForInit.remove(completer);
    completer.complete();
  }

  /// Get device-specific database name
  /// Waits for device identity to be initialized if needed
  /// [serverUrl] - Optional server URL for multi-server support
  Future<String> getDeviceDatabaseName(
    String baseName, {
    String? serverUrl,
  }) async {
    await _waitForDeviceIdentity();

    // Get server-specific deviceId if serverUrl provided
    final deviceId = serverUrl != null
        ? (_deviceIdentity.getDeviceIdForServer(serverUrl) ??
              _deviceIdentity.deviceId)
        : _deviceIdentity.deviceId;

    return '${baseName}_$deviceId';
  }

  /// Open device-specific database (with caching to prevent premature closes)
  /// [serverUrl] - Optional server URL for multi-server support
  Future<Database> openDeviceDatabase(
    String baseName, {
    int version = 1,
    required void Function(VersionChangeEvent) onUpgradeNeeded,
    String? serverUrl,
  }) async {
    final dbName = await getDeviceDatabaseName(baseName, serverUrl: serverUrl);

    // Check cache first
    if (_databaseCache.containsKey(dbName)) {
      debugPrint('[DEVICE_STORAGE] Reusing cached database: $dbName');
      return _databaseCache[dbName]!;
    }

    // Check if already opening (prevent duplicate opens)
    if (_pendingOpens.containsKey(dbName)) {
      debugPrint('[DEVICE_STORAGE] Waiting for pending open: $dbName');
      return await _pendingOpens[dbName]!;
    }

    debugPrint('[DEVICE_STORAGE] Opening encrypted database: $dbName');

    // Create future for this open operation
    final openFuture = _openDatabaseInternal(dbName, version, onUpgradeNeeded);
    _pendingOpens[dbName] = openFuture;

    try {
      final db = await openFuture;
      _databaseCache[dbName] = db;
      return db;
    } finally {
      _pendingOpens.remove(dbName);
    }
  }

  /// Internal database open with error recovery
  Future<Database> _openDatabaseInternal(
    String dbName,
    int version,
    void Function(VersionChangeEvent) onUpgradeNeeded,
  ) async {
    try {
      final factory = await _getIdbFactory();
      return await factory.open(
        dbName,
        version: version,
        onUpgradeNeeded: onUpgradeNeeded,
      );
    } catch (e) {
      // Check if this is a "database_closed" error (hot reload issue)
      if (e.toString().contains('database_closed')) {
        debugPrint(
          '[DEVICE_STORAGE] ⚠️ Database closed error detected (hot reload?) - reinitializing factory',
        );

        // Clear all caches
        _databaseCache.clear();
        _pendingOpens.clear();

        // Reset the factory cache to force recreation
        if (!kIsWeb) {
          native.resetIdbFactoryNative();
          // Recreate the factory and update instance
          _idbFactory = await native.getIdbFactoryNative();
          debugPrint('[DEVICE_STORAGE] ✓ Factory reinitialized');

          // Retry with new factory
          return await _idbFactory!.open(
            dbName,
            version: version,
            onUpgradeNeeded: onUpgradeNeeded,
          );
        }
      }

      // Re-throw if not a database_closed error or if web platform
      rethrow;
    }
  }

  /// Store encrypted data in device-specific database
  /// [serverUrl] - Optional server URL for multi-server support
  Future<void> storeEncrypted(
    String baseName,
    String storeName,
    String key,
    dynamic value, {
    String? serverUrl,
  }) async {
    // 1. Encrypt the data
    final envelope = await _encryption.encryptForStorage(value);

    // 2. Open device-specific database
    final db = await openDeviceDatabase(
      baseName,
      serverUrl: serverUrl,
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
    // Note: db.close() removed - database is cached for reuse

    debugPrint('[DEVICE_STORAGE] ✓ Stored encrypted data: $key');
  }

  /// Retrieve and decrypt data from device-specific database
  /// [serverUrl] - Optional server URL for multi-server support
  Future<dynamic> getDecrypted(
    String baseName,
    String storeName,
    String key, {
    String? serverUrl,
  }) async {
    // 1. Open device-specific database
    final db = await openDeviceDatabase(
      baseName,
      serverUrl: serverUrl,
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
    // Note: db.close() removed - database is cached for reuse

    if (envelope == null) {
      debugPrint('[DEVICE_STORAGE] ✗ Key not found: $key');
      return null;
    }

    // 3. Decrypt data
    try {
      final decrypted = await _encryption.decryptFromStorage(
        envelope as Map<String, dynamic>,
      );
      debugPrint('[DEVICE_STORAGE] ✓ Retrieved and decrypted data: $key');
      return decrypted;
    } catch (e) {
      debugPrint('[DEVICE_STORAGE] ✗ Decryption failed for $key: $e');
      rethrow;
    }
  }

  /// Delete encrypted data from device-scoped database
  /// [serverUrl] - Optional server URL for multi-server support
  Future<void> deleteEncrypted(
    String baseName,
    String storeName,
    dynamic key, {
    String? serverUrl,
  }) async {
    await _waitForDeviceIdentity();

    if (key == null) {
      debugPrint('[DEVICE_STORAGE] ⚠️ Attempted to delete null key - skipping');
      return;
    }

    try {
      final db = await openDeviceDatabase(
        baseName,
        serverUrl: serverUrl,
        onUpgradeNeeded: (VersionChangeEvent event) {
          final db = event.database;
          if (!db.objectStoreNames.contains(storeName)) {
            db.createObjectStore(storeName, autoIncrement: false);
          }
        },
      );

      final txn = db.transaction(storeName, 'readwrite');
      final store = txn.objectStore(storeName);

      // Check if key exists before deleting to avoid SQLite warnings
      final exists = await store.getObject(key);
      if (exists != null) {
        await store.delete(key);
        debugPrint('[DEVICE_STORAGE] ✓ Deleted data: $key');
      } else {
        debugPrint('[DEVICE_STORAGE] ℹ️ Key not found (already deleted): $key');
      }

      await txn.completed;
    } catch (e) {
      debugPrint('[DEVICE_STORAGE] ✗ Delete failed for $key: $e');
      rethrow;
    }
  }

  /// Get all keys from device-scoped database (for iteration)
  Future<List<String>> getAllKeys(String baseName, String storeName) async {
    await _waitForDeviceIdentity();

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

      // 🔧 REDUCED VERBOSITY: Only log when opening new databases, not when reusing
      if (!db.objectStoreNames.contains(storeName)) {
        debugPrint(
          '[DEVICE_STORAGE] Database opened, checking object stores...',
        );
        debugPrint(
          '[DEVICE_STORAGE] Available object stores: ${db.objectStoreNames}',
        );
      }
      debugPrint('[DEVICE_STORAGE] Looking for store: $storeName');

      if (!db.objectStoreNames.contains(storeName)) {
        debugPrint(
          '[DEVICE_STORAGE] ⚠️ Object store "$storeName" does not exist!',
        );
        // Note: db.close() removed - database is cached for reuse
        return [];
      }

      final txn = db.transaction(storeName, 'readonly');
      final store = txn.objectStore(storeName);

      // 🔧 REDUCED VERBOSITY: Removed cursor iteration log (called frequently)
      final keys = <String>[];
      final cursor = store.openCursor(autoAdvance: true);

      await cursor.forEach((c) {
        final key = c.key.toString();
        // 🔧 REMOVED: Verbose key logging (causes spam with 100+ prekeys)
        // debugPrint('[DEVICE_STORAGE] Found key: $key');
        keys.add(key);
      });

      await txn.completed;
      // Note: db.close() removed - database is cached for reuse

      debugPrint('[DEVICE_STORAGE] ✓ Found ${keys.length} total keys');
      return keys;
    } catch (e) {
      debugPrint('[DEVICE_STORAGE] ✗ Failed to get all keys: $e');
      rethrow;
    }
  }

  /// Close all cached databases
  Future<void> closeAllDatabases() async {
    debugPrint(
      '[DEVICE_STORAGE] Closing ${_databaseCache.length} cached databases...',
    );

    for (final entry in _databaseCache.entries) {
      try {
        entry.value.close();
        debugPrint('[DEVICE_STORAGE] ✓ Closed: ${entry.key}');
      } catch (e) {
        debugPrint('[DEVICE_STORAGE] ⚠️ Error closing ${entry.key}: $e');
      }
    }

    _databaseCache.clear();
    _pendingOpens.clear();

    debugPrint('[DEVICE_STORAGE] ✓ All databases closed and cache cleared');
  }

  /// Delete all databases for current device
  Future<void> deleteAllDeviceDatabases() async {
    if (!_deviceIdentity.isInitialized) {
      debugPrint('[DEVICE_STORAGE] No device identity - skipping cleanup');
      return;
    }

    // Close all cached databases first
    await closeAllDatabases();

    debugPrint(
      '[DEVICE_STORAGE] Deleting all databases for device: ${_deviceIdentity.deviceId}',
    );

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

    final factory = await _getIdbFactory();
    for (final baseName in baseDatabases) {
      final dbName = await getDeviceDatabaseName(baseName);
      try {
        await factory.deleteDatabase(dbName);
        deletedCount++;
        debugPrint('[DEVICE_STORAGE] ✓ Deleted: $dbName');
      } catch (e) {
        errorCount++;
        debugPrint('[DEVICE_STORAGE] ✗ Failed to delete $dbName: $e');
      }
    }

    debugPrint(
      '[DEVICE_STORAGE] Cleanup complete: $deletedCount deleted, $errorCount errors',
    );
  }
}
