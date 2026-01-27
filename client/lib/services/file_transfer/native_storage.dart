import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:peerwave_client/core/storage/app_directories.dart';
import 'storage_interface.dart';

/// Native platform storage implementation (Android/iOS/Desktop)
///
/// Uses:
/// - FlutterSecureStorage for metadata & keys
/// - AppDirectories cache for chunks
class NativeStorage implements FileStorageInterface {
  static const String keyFilesList = 'files_list';
  static const String keyFilePrefix = 'file_';
  static const String keyChunkMetaPrefix = 'chunks_';
  static const String keyFileKeyPrefix = 'filekey_';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  Directory? _chunksDirectory;

  @override
  Future<void> initialize() async {
    // Use structured cache directory for file chunks
    _chunksDirectory = Directory(
      '${AppDirectories.cacheDirectory.path}/file_chunks',
    );

    // Create directory if it doesn't exist
    if (!await _chunksDirectory!.exists()) {
      await _chunksDirectory!.create(recursive: true);
    }
  }

  @override
  Future<void> dispose() async {
    // Nothing to clean up
  }

  // ============================================
  // FILE METADATA
  // ============================================

  @override
  Future<void> saveFileMetadata(Map<String, dynamic> metadata) async {
    final fileId = metadata['fileId'] as String;

    // Save individual file metadata
    await _secureStorage.write(
      key: '$keyFilePrefix$fileId',
      value: jsonEncode(metadata),
    );

    // Update files list
    final filesList = await _getFilesList();
    if (!filesList.contains(fileId)) {
      filesList.add(fileId);
      await _saveFilesList(filesList);
    }
  }

  @override
  Future<Map<String, dynamic>?> getFileMetadata(String fileId) async {
    final json = await _secureStorage.read(key: '$keyFilePrefix$fileId');
    if (json == null) return null;
    return jsonDecode(json) as Map<String, dynamic>;
  }

  @override
  Future<List<Map<String, dynamic>>> getAllFiles() async {
    final filesList = await _getFilesList();
    final files = <Map<String, dynamic>>[];

    for (final fileId in filesList) {
      final metadata = await getFileMetadata(fileId);
      if (metadata != null) {
        files.add(metadata);
      }
    }

    return files;
  }

  @override
  Future<void> updateFileMetadata(
    String fileId,
    Map<String, dynamic> updates,
  ) async {
    final existing = await getFileMetadata(fileId);
    if (existing != null) {
      final updated = {...existing, ...updates};
      await saveFileMetadata(updated);
    }
  }

  @override
  Future<void> deleteFile(String fileId) async {
    // Delete metadata
    await _secureStorage.delete(key: '$keyFilePrefix$fileId');

    // Delete from files list
    final filesList = await _getFilesList();
    filesList.remove(fileId);
    await _saveFilesList(filesList);

    // Delete all chunks
    final fileDir = await _getFileChunkDirectory(fileId);
    if (await fileDir.exists()) {
      await fileDir.delete(recursive: true);
    }

    // Delete chunk metadata
    await _secureStorage.delete(key: '$keyChunkMetaPrefix$fileId');

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
    // Save chunk data to file
    final chunkFile = await _getChunkFile(fileId, chunkIndex);
    await chunkFile.writeAsBytes(encryptedData);

    // Save chunk metadata
    await _saveChunkMetadata(fileId, chunkIndex, {
      'chunkIndex': chunkIndex,
      'chunkHash': chunkHash ?? '',
      'iv': iv != null ? base64Encode(iv) : '',
      'chunkSize': encryptedData.length,
      'status': 'complete',
      'timestamp': DateTime.now().toIso8601String(),
      'filePath': chunkFile.path,
    });
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
    final chunkFile = await _getChunkFile(fileId, chunkIndex);
    if (!await chunkFile.exists()) return null;

    return await chunkFile.readAsBytes();
  }

  @override
  Future<Map<String, dynamic>?> getChunkMetadata(
    String fileId,
    int chunkIndex,
  ) async {
    final allMeta = await _getAllChunkMetadata(fileId);
    final meta = allMeta[chunkIndex.toString()];

    if (meta == null) return null;

    // Convert base64 IV string back to Uint8List
    final ivString = meta['iv'] as String?;
    Uint8List? iv;
    if (ivString != null && ivString.isNotEmpty) {
      iv = base64Decode(ivString);
    }

    return {
      ...meta,
      'iv': iv, // Replace string with Uint8List
    };
  }

  @override
  Future<void> deleteChunk(String fileId, int chunkIndex) async {
    // Delete chunk file
    final chunkFile = await _getChunkFile(fileId, chunkIndex);
    if (await chunkFile.exists()) {
      await chunkFile.delete();
    }

    // Update chunk metadata
    final allMeta = await _getAllChunkMetadata(fileId);
    allMeta.remove(chunkIndex.toString());
    await _saveAllChunkMetadata(fileId, allMeta);
  }

  @override
  Future<List<int>> getAvailableChunks(String fileId) async {
    final allMeta = await _getAllChunkMetadata(fileId);
    final chunks = <int>[];

    for (final entry in allMeta.entries) {
      if (entry.value['status'] == 'complete') {
        chunks.add(int.parse(entry.key));
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
    await _secureStorage.write(
      key: '$keyFileKeyPrefix$fileId',
      value: base64Encode(key),
    );
  }

  @override
  Future<Uint8List?> getFileKey(String fileId) async {
    final encoded = await _secureStorage.read(key: '$keyFileKeyPrefix$fileId');
    if (encoded == null) return null;
    return base64Decode(encoded);
  }

  @override
  Future<void> deleteFileKey(String fileId) async {
    await _secureStorage.delete(key: '$keyFileKeyPrefix$fileId');
  }

  // ============================================
  // STORAGE MANAGEMENT
  // ============================================

  @override
  Future<int> getStorageUsed() async {
    if (_chunksDirectory == null) return 0;

    int total = 0;

    // Calculate size of all chunk files
    await for (final entity in _chunksDirectory!.list(recursive: true)) {
      if (entity is File) {
        try {
          final stat = await entity.stat();
          total += stat.size;
        } catch (e) {
          // Ignore files that can't be read
        }
      }
    }

    return total;
  }

  @override
  Future<int> getStorageAvailable() async {
    // This is platform-specific and would need native plugins
    // For now, return a conservative estimate
    return 1024 * 1024 * 1024; // 1 GB
  }

  @override
  Future<void> clearAll() async {
    // Delete all files
    final filesList = await _getFilesList();
    for (final fileId in filesList) {
      await deleteFile(fileId);
    }

    // Clear files list
    await _secureStorage.delete(key: keyFilesList);

    // Delete chunks directory
    if (_chunksDirectory != null && await _chunksDirectory!.exists()) {
      await _chunksDirectory!.delete(recursive: true);
      await _chunksDirectory!.create();
    }
  }

  // ============================================
  // HELPER METHODS
  // ============================================

  Future<List<String>> _getFilesList() async {
    final json = await _secureStorage.read(key: keyFilesList);
    if (json == null) return [];
    return List<String>.from(jsonDecode(json));
  }

  Future<void> _saveFilesList(List<String> filesList) async {
    await _secureStorage.write(key: keyFilesList, value: jsonEncode(filesList));
  }

  Future<Directory> _getFileChunkDirectory(String fileId) async {
    final dir = Directory('${_chunksDirectory!.path}/$fileId');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _getChunkFile(String fileId, int chunkIndex) async {
    final dir = await _getFileChunkDirectory(fileId);
    return File('${dir.path}/chunk_$chunkIndex.enc');
  }

  Future<Map<String, Map<String, dynamic>>> _getAllChunkMetadata(
    String fileId,
  ) async {
    final json = await _secureStorage.read(key: '$keyChunkMetaPrefix$fileId');
    if (json == null) return {};

    final decoded = jsonDecode(json) as Map<String, dynamic>;
    return decoded.map((k, v) => MapEntry(k, v as Map<String, dynamic>));
  }

  Future<void> _saveAllChunkMetadata(
    String fileId,
    Map<String, Map<String, dynamic>> metadata,
  ) async {
    await _secureStorage.write(
      key: '$keyChunkMetaPrefix$fileId',
      value: jsonEncode(metadata),
    );
  }

  Future<void> _saveChunkMetadata(
    String fileId,
    int chunkIndex,
    Map<String, dynamic> metadata,
  ) async {
    final allMeta = await _getAllChunkMetadata(fileId);
    allMeta[chunkIndex.toString()] = metadata;
    await _saveAllChunkMetadata(fileId, allMeta);
  }
}
