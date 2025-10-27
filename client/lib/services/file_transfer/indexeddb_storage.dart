import 'dart:typed_data';
import 'package:idb_shim/idb_browser.dart';
import 'storage_interface.dart';

/// IndexedDB implementation for Web platform
class IndexedDBStorage implements FileStorageInterface {
  static const String DB_NAME = 'PeerWaveFiles';
  static const int DB_VERSION = 1;
  
  static const String STORE_FILES = 'files';
  static const String STORE_CHUNKS = 'chunks';
  static const String STORE_FILE_KEYS = 'fileKeys';
  
  Database? _db;
  final IdbFactory _idbFactory = idbFactoryBrowser;
  
  @override
  Future<void> initialize() async {
    _db = await _idbFactory.open(
      DB_NAME,
      version: DB_VERSION,
      onUpgradeNeeded: (VersionChangeEvent event) {
        final db = event.database;
        
        // Files ObjectStore
        if (!db.objectStoreNames.contains(STORE_FILES)) {
          final filesStore = db.createObjectStore(STORE_FILES, keyPath: 'fileId');
          filesStore.createIndex('status', 'status', unique: false);
          filesStore.createIndex('createdAt', 'createdAt', unique: false);
          filesStore.createIndex('isSeeder', 'isSeeder', unique: false);
        }
        
        // Chunks ObjectStore (composite key: fileId + chunkIndex)
        if (!db.objectStoreNames.contains(STORE_CHUNKS)) {
          final chunksStore = db.createObjectStore(STORE_CHUNKS, autoIncrement: true);
          chunksStore.createIndex('fileId', 'fileId', unique: false);
          chunksStore.createIndex('fileId_chunkIndex', ['fileId', 'chunkIndex'], unique: true);
        }
        
        // File Keys ObjectStore
        if (!db.objectStoreNames.contains(STORE_FILE_KEYS)) {
          db.createObjectStore(STORE_FILE_KEYS, keyPath: 'fileId');
        }
      },
    );
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
    final tx = _db!.transaction(STORE_FILES, idbModeReadWrite);
    final store = tx.objectStore(STORE_FILES);
    await store.put(metadata);
    await tx.completed;
  }
  
  @override
  Future<Map<String, dynamic>?> getFileMetadata(String fileId) async {
    final tx = _db!.transaction(STORE_FILES, idbModeReadOnly);
    final store = tx.objectStore(STORE_FILES);
    final result = await store.getObject(fileId);
    return result as Map<String, dynamic>?;
  }
  
  @override
  Future<List<Map<String, dynamic>>> getAllFiles() async {
    final tx = _db!.transaction(STORE_FILES, idbModeReadOnly);
    final store = tx.objectStore(STORE_FILES);
    final results = await store.getAll();
    return results.cast<Map<String, dynamic>>();
  }
  
  @override
  Future<void> updateFileMetadata(String fileId, Map<String, dynamic> updates) async {
    final tx = _db!.transaction(STORE_FILES, idbModeReadWrite);
    final store = tx.objectStore(STORE_FILES);
    
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
    final fileTx = _db!.transaction(STORE_FILES, idbModeReadWrite);
    await fileTx.objectStore(STORE_FILES).delete(fileId);
    await fileTx.completed;
    
    // Delete all chunks
    final chunkTx = _db!.transaction(STORE_CHUNKS, idbModeReadWrite);
    final chunksStore = chunkTx.objectStore(STORE_CHUNKS);
    final index = chunksStore.index('fileId');
    
    await for (final cursor in index.openCursor(key: fileId, autoAdvance: true)) {
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
    required Uint8List iv,
    required String chunkHash,
  }) async {
    final tx = _db!.transaction(STORE_CHUNKS, idbModeReadWrite);
    final store = tx.objectStore(STORE_CHUNKS);
    
    await store.put({
      'fileId': fileId,
      'chunkIndex': chunkIndex,
      'encryptedData': encryptedData,
      'iv': iv,
      'chunkHash': chunkHash,
      'chunkSize': encryptedData.length,
      'status': 'complete',
      'timestamp': DateTime.now().toIso8601String(),
    });
    
    await tx.completed;
  }
  
  @override
  Future<Uint8List?> getChunk(String fileId, int chunkIndex) async {
    final tx = _db!.transaction(STORE_CHUNKS, idbModeReadOnly);
    final store = tx.objectStore(STORE_CHUNKS);
    final index = store.index('fileId_chunkIndex');
    
    final key = await index.getKey([fileId, chunkIndex]);
    if (key == null) return null;
    
    final result = await store.getObject(key);
    if (result == null) return null;
    
    final data = result as Map<String, dynamic>;
    return data['encryptedData'] as Uint8List;
  }
  
  @override
  Future<Map<String, dynamic>?> getChunkMetadata(String fileId, int chunkIndex) async {
    final tx = _db!.transaction(STORE_CHUNKS, idbModeReadOnly);
    final store = tx.objectStore(STORE_CHUNKS);
    final index = store.index('fileId_chunkIndex');
    
    final key = await index.getKey([fileId, chunkIndex]);
    if (key == null) return null;
    
    final result = await store.getObject(key);
    if (result == null) return null;
    
    final data = result as Map<String, dynamic>;
    return {
      'fileId': data['fileId'],
      'chunkIndex': data['chunkIndex'],
      'chunkHash': data['chunkHash'],
      'iv': data['iv'],
      'chunkSize': data['chunkSize'],
      'status': data['status'],
      'timestamp': data['timestamp'],
    };
  }
  
  @override
  Future<void> deleteChunk(String fileId, int chunkIndex) async {
    final tx = _db!.transaction(STORE_CHUNKS, idbModeReadWrite);
    final store = tx.objectStore(STORE_CHUNKS);
    final index = store.index('fileId_chunkIndex');
    
    final key = await index.getKey([fileId, chunkIndex]);
    if (key != null) {
      await store.delete(key);
    }
    await tx.completed;
  }
  
  @override
  Future<List<int>> getAvailableChunks(String fileId) async {
    final tx = _db!.transaction(STORE_CHUNKS, idbModeReadOnly);
    final store = tx.objectStore(STORE_CHUNKS);
    final index = store.index('fileId');
    
    final chunks = <int>[];
    await for (final cursor in index.openCursor(key: fileId, autoAdvance: true)) {
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
  
  @override
  Future<void> saveFileKey(String fileId, Uint8List key) async {
    final tx = _db!.transaction(STORE_FILE_KEYS, idbModeReadWrite);
    final store = tx.objectStore(STORE_FILE_KEYS);
    
    await store.put({
      'fileId': fileId,
      'key': key,
      'timestamp': DateTime.now().toIso8601String(),
    });
    
    await tx.completed;
  }
  
  @override
  Future<Uint8List?> getFileKey(String fileId) async {
    final tx = _db!.transaction(STORE_FILE_KEYS, idbModeReadOnly);
    final store = tx.objectStore(STORE_FILE_KEYS);
    
    final result = await store.getObject(fileId);
    if (result == null) return null;
    
    final data = result as Map<String, dynamic>;
    return data['key'] as Uint8List;
  }
  
  @override
  Future<void> deleteFileKey(String fileId) async {
    final tx = _db!.transaction(STORE_FILE_KEYS, idbModeReadWrite);
    await tx.objectStore(STORE_FILE_KEYS).delete(fileId);
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
    final chunkTx = _db!.transaction(STORE_CHUNKS, idbModeReadOnly);
    final chunksStore = chunkTx.objectStore(STORE_CHUNKS);
    
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
    final tx = _db!.transaction(
      [STORE_FILES, STORE_CHUNKS, STORE_FILE_KEYS],
      idbModeReadWrite,
    );
    
    await tx.objectStore(STORE_FILES).clear();
    await tx.objectStore(STORE_CHUNKS).clear();
    await tx.objectStore(STORE_FILE_KEYS).clear();
    
    await tx.completed;
  }
}
