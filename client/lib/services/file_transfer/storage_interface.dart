import 'dart:typed_data';

/// Abstract interface for file storage implementations
/// 
/// Implementations:
/// - IndexedDB (Web)
/// - path_provider + FlutterSecureStorage (Native)
abstract class FileStorageInterface {
  // ============================================
  // FILE METADATA
  // ============================================
  
  /// Save file metadata (fileId, fileName, fileSize, etc.)
  Future<void> saveFileMetadata(Map<String, dynamic> metadata);
  
  /// Get file metadata by fileId
  Future<Map<String, dynamic>?> getFileMetadata(String fileId);
  
  /// Get all files (for UI listing)
  Future<List<Map<String, dynamic>>> getAllFiles();
  
  /// Delete file and all associated chunks
  Future<void> deleteFile(String fileId);
  
  /// Update file metadata (e.g., status, progress)
  Future<void> updateFileMetadata(String fileId, Map<String, dynamic> updates);
  
  // ============================================
  // CHUNKS
  // ============================================
  
  /// Save encrypted chunk data
  Future<void> saveChunk(String fileId, int chunkIndex, Uint8List encryptedData, {
    Uint8List? iv,
    String? chunkHash,
  });
  
  /// Get encrypted chunk data
  Future<Uint8List?> getChunk(String fileId, int chunkIndex);
  
  /// Get chunk metadata (hash, IV, status)
  Future<Map<String, dynamic>?> getChunkMetadata(String fileId, int chunkIndex);
  
  /// Delete single chunk
  Future<void> deleteChunk(String fileId, int chunkIndex);
  
  /// Get list of available chunk indices for a file
  Future<List<int>> getAvailableChunks(String fileId);
  
  /// Get total number of chunks for a file
  Future<int> getChunkCount(String fileId);
  
  // ============================================
  // FILE KEYS (Encryption Keys)
  // ============================================
  
  /// Save file encryption key (256-bit AES key)
  Future<void> saveFileKey(String fileId, Uint8List key);
  
  /// Get file encryption key
  Future<Uint8List?> getFileKey(String fileId);
  
  /// Delete file key
  Future<void> deleteFileKey(String fileId);
  
  // ============================================
  // STORAGE MANAGEMENT
  // ============================================
  
  /// Get total storage used (bytes)
  Future<int> getStorageUsed();
  
  /// Get available storage (bytes)
  Future<int> getStorageAvailable();
  
  /// Clear all data (for testing/reset)
  Future<void> clearAll();
  
  /// Initialize storage (create databases, directories, etc.)
  Future<void> initialize();
  
  /// Close/cleanup storage connections
  Future<void> dispose();
}

/// File metadata structure
class FileMetadata {
  final String fileId;
  final String fileName;
  final String mimeType;
  final int fileSize;
  final String checksum; // SHA-256
  final int chunkCount;
  final String uploaderId;
  final DateTime createdAt;
  final String chatType; // 'direct' | 'group'
  final String chatId;
  final String status; // 'uploading' | 'uploaded' | 'downloading' | 'complete' | 'paused' | 'failed'
  final bool isSeeder; // Is this user seeding the file?
  final bool autoReannounce; // Auto-reannounce when coming online
  final DateTime? lastActivity;
  final String? deletionReason; // 'seeder-ttl' | 'uploader-deleted' | 'manual'
  
  FileMetadata({
    required this.fileId,
    required this.fileName,
    required this.mimeType,
    required this.fileSize,
    required this.checksum,
    required this.chunkCount,
    required this.uploaderId,
    required this.createdAt,
    required this.chatType,
    required this.chatId,
    required this.status,
    this.isSeeder = false,
    this.autoReannounce = true,
    this.lastActivity,
    this.deletionReason,
  });
  
  Map<String, dynamic> toJson() => {
    'fileId': fileId,
    'fileName': fileName,
    'mimeType': mimeType,
    'fileSize': fileSize,
    'checksum': checksum,
    'chunkCount': chunkCount,
    'uploaderId': uploaderId,
    'createdAt': createdAt.toIso8601String(),
    'chatType': chatType,
    'chatId': chatId,
    'status': status,
    'isSeeder': isSeeder,
    'autoReannounce': autoReannounce,
    'lastActivity': lastActivity?.toIso8601String(),
    'deletionReason': deletionReason,
  };
  
  factory FileMetadata.fromJson(Map<String, dynamic> json) => FileMetadata(
    fileId: json['fileId'],
    fileName: json['fileName'],
    mimeType: json['mimeType'],
    fileSize: json['fileSize'],
    checksum: json['checksum'],
    chunkCount: json['chunkCount'],
    uploaderId: json['uploaderId'],
    createdAt: DateTime.parse(json['createdAt']),
    chatType: json['chatType'],
    chatId: json['chatId'],
    status: json['status'],
    isSeeder: json['isSeeder'] ?? false,
    autoReannounce: json['autoReannounce'] ?? true,
    lastActivity: json['lastActivity'] != null ? DateTime.parse(json['lastActivity']) : null,
    deletionReason: json['deletionReason'],
  );
}

/// Chunk metadata structure
class ChunkMetadata {
  final String fileId;
  final int chunkIndex;
  final int chunkSize;
  final String chunkHash; // SHA-256
  final Uint8List iv; // AES-GCM IV
  final String status; // 'pending' | 'downloading' | 'complete' | 'failed'
  final DateTime timestamp;
  
  ChunkMetadata({
    required this.fileId,
    required this.chunkIndex,
    required this.chunkSize,
    required this.chunkHash,
    required this.iv,
    required this.status,
    required this.timestamp,
  });
  
  Map<String, dynamic> toJson() => {
    'fileId': fileId,
    'chunkIndex': chunkIndex,
    'chunkSize': chunkSize,
    'chunkHash': chunkHash,
    'iv': iv,
    'status': status,
    'timestamp': timestamp.toIso8601String(),
  };
  
  factory ChunkMetadata.fromJson(Map<String, dynamic> json) => ChunkMetadata(
    fileId: json['fileId'],
    chunkIndex: json['chunkIndex'],
    chunkSize: json['chunkSize'],
    chunkHash: json['chunkHash'],
    iv: json['iv'],
    status: json['status'],
    timestamp: DateTime.parse(json['timestamp']),
  );
}
