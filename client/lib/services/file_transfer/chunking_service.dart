import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Service for splitting files into chunks and reassembling them
///
/// Features:
/// - 64KB chunk size (optimal for WebRTC DataChannel)
/// - SHA-256 hash per chunk for integrity verification
/// - Overall file checksum calculation
/// - Progress callbacks for UI feedback
class ChunkingService {
  /// Optimal chunk size for WebRTC DataChannel (64 KB)
  static const int chunkSize = 64 * 1024; // 64 KB

  /// Calculate how many chunks a file will have
  static int calculateChunkCount(int fileSize) {
    return (fileSize / chunkSize).ceil();
  }

  /// Calculate the size of a specific chunk
  static int calculateChunkSize(int fileSize, int chunkIndex) {
    final totalChunks = calculateChunkCount(fileSize);

    // Last chunk might be smaller
    if (chunkIndex == totalChunks - 1) {
      final remainder = fileSize % chunkSize;
      return remainder > 0 ? remainder : chunkSize;
    }

    return chunkSize;
  }

  /// Split a file into chunks
  ///
  /// Returns a list of chunks with their metadata:
  /// - chunkIndex: Position in file (0-based)
  /// - data: Raw chunk data
  /// - hash: SHA-256 hash of the chunk
  /// - size: Chunk size in bytes
  Future<List<ChunkData>> splitIntoChunks(
    Uint8List fileData, {
    void Function(int chunkIndex, int totalChunks)? onProgress,
  }) async {
    final chunks = <ChunkData>[];
    final totalChunks = calculateChunkCount(fileData.length);

    for (int i = 0; i < totalChunks; i++) {
      final start = i * chunkSize;
      final end = (start + chunkSize).clamp(0, fileData.length);

      // Extract chunk data
      final chunkData = fileData.sublist(start, end);

      // Calculate SHA-256 hash
      final hash = sha256.convert(chunkData).toString();

      chunks.add(
        ChunkData(
          chunkIndex: i,
          data: chunkData,
          hash: hash,
          size: chunkData.length,
        ),
      );

      // Progress callback
      onProgress?.call(i + 1, totalChunks);
    }

    return chunks;
  }

  /// Extract a single chunk from file data
  ///
  /// Useful for streaming scenarios where you don't want to
  /// split the entire file into memory at once
  ChunkData extractChunk(Uint8List fileData, int chunkIndex) {
    final start = chunkIndex * chunkSize;
    final end = (start + chunkSize).clamp(0, fileData.length);

    final chunkData = fileData.sublist(start, end);
    final hash = sha256.convert(chunkData).toString();

    return ChunkData(
      chunkIndex: chunkIndex,
      data: chunkData,
      hash: hash,
      size: chunkData.length,
    );
  }

  /// Reassemble chunks back into the original file
  ///
  /// Verifies chunk hashes before assembly
  /// Returns null if verification fails
  Future<Uint8List?> assembleChunks(
    List<ChunkData> chunks, {
    bool verifyHashes = true,
    void Function(int chunkIndex, int totalChunks)? onProgress,
  }) async {
    if (chunks.isEmpty) return null;

    // Sort chunks by index
    final sortedChunks = List<ChunkData>.from(chunks)
      ..sort((a, b) => a.chunkIndex.compareTo(b.chunkIndex));

    // Verify hash integrity if requested
    if (verifyHashes) {
      for (final chunk in sortedChunks) {
        final calculatedHash = sha256.convert(chunk.data).toString();
        if (calculatedHash != chunk.hash) {
          // Hash mismatch - chunk corrupted
          return null;
        }
        onProgress?.call(chunk.chunkIndex + 1, sortedChunks.length);
      }
    }

    // Calculate total size
    final totalSize = sortedChunks.fold<int>(
      0,
      (sum, chunk) => sum + chunk.size,
    );

    // Allocate buffer for complete file
    final result = Uint8List(totalSize);

    // Copy chunks into buffer
    int offset = 0;
    for (final chunk in sortedChunks) {
      result.setRange(offset, offset + chunk.size, chunk.data);
      offset += chunk.size;
    }

    return result;
  }

  /// Calculate SHA-256 checksum of entire file
  ///
  /// This is the final checksum stored in file metadata
  String calculateFileChecksum(Uint8List fileData) {
    return sha256.convert(fileData).toString();
  }

  /// Verify file checksum matches expected value
  bool verifyFileChecksum(Uint8List fileData, String expectedChecksum) {
    final actualChecksum = calculateFileChecksum(fileData);
    return actualChecksum == expectedChecksum;
  }

  /// Calculate checksum from assembled chunks (without loading full file)
  ///
  /// Useful for verifying downloads without keeping entire file in memory
  Future<String> calculateChecksumFromChunks(List<ChunkData> chunks) async {
    // Sort chunks by index
    final sortedChunks = List<ChunkData>.from(chunks)
      ..sort((a, b) => a.chunkIndex.compareTo(b.chunkIndex));

    // Concatenate all chunk data
    final buffer = BytesBuilder();
    for (final chunk in sortedChunks) {
      buffer.add(chunk.data);
    }

    // Calculate hash of complete data
    final digest = sha256.convert(buffer.toBytes());
    return digest.toString();
  }

  /// Verify a specific chunk's integrity
  bool verifyChunkHash(Uint8List chunkData, String expectedHash) {
    final actualHash = sha256.convert(chunkData).toString();
    return actualHash == expectedHash;
  }

  /// Get chunk metadata without data (for announcements)
  ChunkMetadataLight getChunkMetadata(int chunkIndex, int fileSize) {
    final totalChunks = calculateChunkCount(fileSize);
    final chunkSize = calculateChunkSize(fileSize, chunkIndex);

    return ChunkMetadataLight(
      chunkIndex: chunkIndex,
      chunkSize: chunkSize,
      totalChunks: totalChunks,
    );
  }
}

/// Chunk data with hash for integrity verification
class ChunkData {
  final int chunkIndex;
  final Uint8List data;
  final String hash; // SHA-256
  final int size;

  ChunkData({
    required this.chunkIndex,
    required this.data,
    required this.hash,
    required this.size,
  });

  /// Convert to JSON (without data - for metadata storage)
  Map<String, dynamic> toMetadataJson() {
    return {'chunkIndex': chunkIndex, 'hash': hash, 'size': size};
  }

  /// Convert data to base64 (for network transfer)
  String get dataBase64 => base64Encode(data);

  @override
  String toString() =>
      'ChunkData(index: $chunkIndex, size: $size, hash: ${hash.substring(0, 8)}...)';
}

/// Lightweight chunk metadata (without data)
class ChunkMetadataLight {
  final int chunkIndex;
  final int chunkSize;
  final int totalChunks;

  ChunkMetadataLight({
    required this.chunkIndex,
    required this.chunkSize,
    required this.totalChunks,
  });

  Map<String, dynamic> toJson() {
    return {
      'chunkIndex': chunkIndex,
      'chunkSize': chunkSize,
      'totalChunks': totalChunks,
    };
  }

  factory ChunkMetadataLight.fromJson(Map<String, dynamic> json) {
    return ChunkMetadataLight(
      chunkIndex: json['chunkIndex'] as int,
      chunkSize: json['chunkSize'] as int,
      totalChunks: json['totalChunks'] as int,
    );
  }
}
