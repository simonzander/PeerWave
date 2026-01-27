import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:idb_shim/idb_browser.dart';
import 'storage_interface.dart';
import '../device_identity_service.dart';
import '../web/encrypted_storage_wrapper.dart';

/// IndexedDB implementation for Web platform with device-scoped storage
///
/// Database naming: PeerWaveFiles_{deviceId}
/// - Device isolation: Each device has its own database
/// - Encrypted file keys: Keys encrypted with WebAuthn-derived key
/// - Chunks: Already encrypted (no change)
/// - Metadata: Plain (ok for metadata)
class IndexedDBStorage implements FileStorageInterface {
  static const String dbBaseName = 'PeerWaveFiles';
  static const int dbVersion = 1;

  static const String storeFiles = 'files';
  static const String storeChunks = 'chunks';
  static const String storeFileKeys = 'fileKeys';

  Database? _db;
  final IdbFactory _idbFactory = idbFactoryBrowser;
  final DeviceIdentityService _deviceIdentity = DeviceIdentityService.instance;
  final EncryptedStorageWrapper _encryption = EncryptedStorageWrapper();

  String? _deviceScopedDbName;

  /// Get device-scoped database name
  String get _dbName {
    if (_deviceScopedDbName != null) {
      return _deviceScopedDbName!;
    }

    if (!_deviceIdentity.isInitialized) {
      throw Exception('[FILE_STORAGE] Device identity not initialized');
    }

    final deviceId = _deviceIdentity.deviceId;
    _deviceScopedDbName = '${dbBaseName}_$deviceId';
    debugPrint('[FILE_STORAGE] Device-scoped DB name: $_deviceScopedDbName');
    return _deviceScopedDbName!;
  }

  @override
  Future<void> initialize() async {
    debugPrint('[FILE_STORAGE] ========================================');
    debugPrint('[FILE_STORAGE] Initializing device-scoped file storage');
    debugPrint('[FILE_STORAGE] ========================================');

    // Open device-scoped database
    _db = await _idbFactory.open(
      _dbName,
      version: dbVersion,
      onUpgradeNeeded: (VersionChangeEvent event) {
        final db = event.database;

        debugPrint(
          '[FILE_STORAGE] Creating database schema v${event.newVersion}',
        );

        // Files ObjectStore
        if (!db.objectStoreNames.contains(storeFiles)) {
          final filesStore = db.createObjectStore(
            storeFiles,
            keyPath: 'fileId',
          );
          filesStore.createIndex('status', 'status', unique: false);
          filesStore.createIndex('createdAt', 'createdAt', unique: false);
          filesStore.createIndex('isSeeder', 'isSeeder', unique: false);
          debugPrint('[FILE_STORAGE] ✓ Created files store');
        }

        // Chunks ObjectStore (composite key: fileId + chunkIndex)
        if (!db.objectStoreNames.contains(storeChunks)) {
          final chunksStore = db.createObjectStore(
            storeChunks,
            autoIncrement: true,
          );
          chunksStore.createIndex('fileId', 'fileId', unique: false);
          chunksStore.createIndex('fileId_chunkIndex', [
            'fileId',
            'chunkIndex',
          ], unique: true);
          debugPrint('[FILE_STORAGE] ✓ Created chunks store');
        }

        // File Keys ObjectStore (stores encrypted keys)
        if (!db.objectStoreNames.contains(storeFileKeys)) {
          db.createObjectStore(storeFileKeys, keyPath: 'fileId');
          debugPrint('[FILE_STORAGE] ✓ Created fileKeys store (encrypted)');
        }
      },
    );

    debugPrint('[FILE_STORAGE] ✓ Device-scoped file storage initialized');
  }

  @override
  Future<void> dispose() async {
    _db?.close();
    _db = null;
  }

  // ============================================
  // FILE METADATA
  // ============================================

  @override
  Future<void> saveFileMetadata(Map<String, dynamic> metadata) async {
    final tx = _db!.transaction(storeFiles, idbModeReadWrite);
    final store = tx.objectStore(storeFiles);
    await store.put(metadata);
    await tx.completed;
  }

  @override
  Future<Map<String, dynamic>?> getFileMetadata(String fileId) async {
    final tx = _db!.transaction(storeFiles, idbModeReadOnly);
    final store = tx.objectStore(storeFiles);
    final result = await store.getObject(fileId);
    return result as Map<String, dynamic>?;
  }

  @override
  Future<List<Map<String, dynamic>>> getAllFiles() async {
    final tx = _db!.transaction(storeFiles, idbModeReadOnly);
    final store = tx.objectStore(storeFiles);
    final results = await store.getAll();
    return results.cast<Map<String, dynamic>>();
  }

  @override
  Future<void> updateFileMetadata(
    String fileId,
    Map<String, dynamic> updates,
  ) async {
    final tx = _db!.transaction(storeFiles, idbModeReadWrite);
    final store = tx.objectStore(storeFiles);

    final existing = await store.getObject(fileId) as Map<String, dynamic>?;
    if (existing != null) {
      final updated = {...existing, ...updates};
      await store.put(updated);
    }
    await tx.completed;
  }

  @override
  Future<void> deleteFile(String fileId) async {
    // Delete file metadata
    final fileTx = _db!.transaction(storeFiles, idbModeReadWrite);
    await fileTx.objectStore(storeFiles).delete(fileId);
    await fileTx.completed;

    // Delete all chunks
    final chunkTx = _db!.transaction(storeChunks, idbModeReadWrite);
    final chunksStore = chunkTx.objectStore(storeChunks);
    final index = chunksStore.index('fileId');

    await for (final cursor in index.openCursor(
      key: fileId,
      autoAdvance: true,
    )) {
      await cursor.delete();
    }
    await chunkTx.completed;

    // Delete file key
    await deleteFileKey(fileId);
  }

  // ============================================
  // CHUNKS
  // ============================================

  @override
  Future<void> saveChunk(
    String fileId,
    int chunkIndex,
    Uint8List encryptedData, {
    Uint8List? iv,
    String? chunkHash,
  }) async {
    final tx = _db!.transaction(storeChunks, idbModeReadWrite);
    final store = tx.objectStore(storeChunks);

    await store.put({
      'fileId': fileId,
      'chunkIndex': chunkIndex,
      'encryptedData': encryptedData,
      'iv': iv ?? Uint8List(0),
      'chunkHash': chunkHash ?? '',
      'chunkSize': encryptedData.length,
      'status': 'complete',
      'timestamp': DateTime.now().toIso8601String(),
    });

    await tx.completed;
  }

  @override
  Future<bool> saveChunkSafe(
    String fileId,
    int chunkIndex,
    Uint8List encryptedData, {
    Uint8List? iv,
    String? chunkHash,
  }) async {
    // Check if chunk already exists
    final existingChunk = await getChunk(fileId, chunkIndex);

    if (existingChunk != null && existingChunk.length == encryptedData.length) {
      debugPrint(
        '[STORAGE] Chunk $chunkIndex already exists, skipping duplicate',
      );
      return false; // Not saved (duplicate)
    }

    if (existingChunk != null) {
      debugPrint('[STORAGE] ⚠️ Chunk $chunkIndex size mismatch, overwriting');
    }

    // Save chunk
    await saveChunk(
      fileId,
      chunkIndex,
      encryptedData,
      iv: iv,
      chunkHash: chunkHash,
    );
    return true; // Saved successfully
  }

  @override
  Future<Uint8List?> getChunk(String fileId, int chunkIndex) async {
    final tx = _db!.transaction(storeChunks, idbModeReadOnly);
    final store = tx.objectStore(storeChunks);
    final index = store.index('fileId_chunkIndex');

    final key = await index.getKey([fileId, chunkIndex]);
    if (key == null) return null;

    final result = await store.getObject(key);
    if (result == null) return null;

    final data = result as Map<String, dynamic>;
    final rawData = data['encryptedData'];

    // Handle different serialization formats from IndexedDB
    if (rawData is Uint8List) {
      return rawData;
    } else if (rawData is List) {
      return Uint8List.fromList(List<int>.from(rawData));
    } else if (rawData is String) {
      // Should not happen, but handle just in case
      debugPrint('[STORAGE] ⚠️ Chunk data is String, this should not happen');
      return null;
    }

    return null;
  }

  @override
  Future<Map<String, dynamic>?> getChunkMetadata(
    String fileId,
    int chunkIndex,
  ) async {
    final tx = _db!.transaction(storeChunks, idbModeReadOnly);
    final store = tx.objectStore(storeChunks);
    final index = store.index('fileId_chunkIndex');

    final key = await index.getKey([fileId, chunkIndex]);
    if (key == null) return null;

    final result = await store.getObject(key);
    if (result == null) return null;

    final data = result as Map<String, dynamic>;

    // Handle IV serialization - might be List or Uint8List
    final rawIv = data['iv'];
    Uint8List? iv;
    if (rawIv is Uint8List) {
      iv = rawIv;
    } else if (rawIv is List) {
      iv = Uint8List.fromList(List<int>.from(rawIv));
    }

    return {
      'fileId': data['fileId'],
      'chunkIndex': data['chunkIndex'],
      'chunkHash': data['chunkHash'],
      'iv': iv,
      'chunkSize': data['chunkSize'],
      'status': data['status'],
      'timestamp': data['timestamp'],
    };
  }

  @override
  Future<void> deleteChunk(String fileId, int chunkIndex) async {
    final tx = _db!.transaction(storeChunks, idbModeReadWrite);
    final store = tx.objectStore(storeChunks);
    final index = store.index('fileId_chunkIndex');

    final key = await index.getKey([fileId, chunkIndex]);
    if (key != null) {
      await store.delete(key);
    }
    await tx.completed;
  }

  @override
  Future<List<int>> getAvailableChunks(String fileId) async {
    final tx = _db!.transaction(storeChunks, idbModeReadOnly);
    final store = tx.objectStore(storeChunks);
    final index = store.index('fileId');

    final chunks = <int>[];
    await for (final cursor in index.openCursor(
      key: fileId,
      autoAdvance: true,
    )) {
      final data = cursor.value as Map<String, dynamic>;
      if (data['status'] == 'complete') {
        chunks.add(data['chunkIndex'] as int);
      }
    }

    return chunks..sort();
  }

  @override
  Future<int> getChunkCount(String fileId) async {
    final metadata = await getFileMetadata(fileId);
    return metadata?['chunkCount'] ?? 0;
  }

  // ============================================
  // FILE KEYS
  // ============================================

  // ============================================
  // FILE KEYS (ENCRYPTED STORAGE)
  // ============================================

  @override
  Future<void> saveFileKey(String fileId, Uint8List key) async {
    debugPrint('[FILE_STORAGE] Saving encrypted file key for $fileId');
    debugPrint('[FILE_STORAGE]   Key length: ${key.length} bytes');

    try {
      // Encrypt the file key using WebAuthn-derived encryption
      final encryptedKeyEnvelope = await _encryption.encryptForStorage(key);

      final tx = _db!.transaction(storeFileKeys, idbModeReadWrite);
      final store = tx.objectStore(storeFileKeys);

      await store.put({
        'fileId': fileId,
        'encryptedKey': encryptedKeyEnvelope, // {iv, encryptedData, version}
        'timestamp': DateTime.now().toIso8601String(),
      });

      await tx.completed;
      debugPrint('[FILE_STORAGE] ✓ File key encrypted and saved');
    } catch (e) {
      debugPrint('[FILE_STORAGE] ✗ Failed to encrypt file key: $e');
      rethrow;
    }
  }

  @override
  Future<Uint8List?> getFileKey(String fileId) async {
    debugPrint('[FILE_STORAGE] Retrieving encrypted file key for $fileId');

    try {
      final tx = _db!.transaction(storeFileKeys, idbModeReadOnly);
      final store = tx.objectStore(storeFileKeys);

      final result = await store.getObject(fileId);
      await tx.completed;

      if (result == null) {
        debugPrint('[FILE_STORAGE] ✗ No file key found for $fileId');
        return null;
      }

      final data = result as Map<String, dynamic>;
      final encryptedKeyEnvelope = data['encryptedKey'];

      if (encryptedKeyEnvelope == null) {
        debugPrint('[FILE_STORAGE] ✗ No encrypted key data found');
        return null;
      }

      // Decrypt the encrypted key
      final decryptedKey = await _encryption.decryptFromStorage(
        encryptedKeyEnvelope as Map<String, dynamic>,
      );

      // Convert back to Uint8List
      if (decryptedKey is Uint8List) {
        debugPrint(
          '[FILE_STORAGE] ✓ File key decrypted: ${decryptedKey.length} bytes',
        );
        return decryptedKey;
      } else if (decryptedKey is List) {
        final bytes = Uint8List.fromList(decryptedKey.cast<int>());
        debugPrint(
          '[FILE_STORAGE] ✓ File key decrypted: ${bytes.length} bytes',
        );
        return bytes;
      }

      debugPrint(
        '[FILE_STORAGE] ✗ Invalid decrypted key type: ${decryptedKey.runtimeType}',
      );
      return null;
    } catch (e) {
      debugPrint('[FILE_STORAGE] ✗ Failed to decrypt file key: $e');
      rethrow;
    }
  }

  @override
  Future<void> deleteFileKey(String fileId) async {
    final tx = _db!.transaction(storeFileKeys, idbModeReadWrite);
    await tx.objectStore(storeFileKeys).delete(fileId);
    await tx.completed;
  }

  // ============================================
  // STORAGE MANAGEMENT
  // ============================================

  @override
  Future<int> getStorageUsed() async {
    // Estimate total storage used
    int total = 0;

    // Files metadata size (approximation)
    final files = await getAllFiles();
    total += files.length * 1024; // ~1KB per file metadata

    // Chunks size
    final chunkTx = _db!.transaction(storeChunks, idbModeReadOnly);
    final chunksStore = chunkTx.objectStore(storeChunks);

    await for (final cursor in chunksStore.openCursor(autoAdvance: true)) {
      final data = cursor.value as Map<String, dynamic>;
      total += (data['chunkSize'] as int?) ?? 0;
    }

    return total;
  }

  @override
  Future<int> getStorageAvailable() async {
    // Try to get StorageManager estimate
    // Note: This is browser-specific and may not work everywhere
    try {
      // This would need js interop in real implementation
      // For now, return a conservative estimate
      return 100 * 1024 * 1024; // 100 MB
    } catch (e) {
      return 100 * 1024 * 1024; // Fallback to 100 MB
    }
  }

  @override
  Future<void> clearAll() async {
    final tx = _db!.transaction([
      storeFiles,
      storeChunks,
      storeFileKeys,
    ], idbModeReadWrite);

    await tx.objectStore(storeFiles).clear();
    await tx.objectStore(storeChunks).clear();
    await tx.objectStore(storeFileKeys).clear();

    await tx.completed;
  }
}
