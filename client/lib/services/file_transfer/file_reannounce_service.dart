import 'package:flutter/foundation.dart';
import 'storage_interface.dart';
import 'socket_file_client.dart';

/// Service for re-announcing files after login
/// 
/// When a user logs in, this service checks local storage for files
/// that were previously shared and re-announces them to the network.
class FileReannounceService {
  final FileStorageInterface storage;
  final SocketFileClient socketClient;
  
  FileReannounceService({
    required this.storage,
    required this.socketClient,
  });
  
  /// Re-announce all files from local storage
  /// 
  /// This should be called after successful login/authentication
  Future<ReannounceResult> reannounceAllFiles() async {
    try {
      debugPrint('[REANNOUNCE] Checking local storage for files to re-announce...');
      
      final allFiles = await storage.getAllFiles();
      
      if (allFiles.isEmpty) {
        debugPrint('[REANNOUNCE] No files found in local storage');
        return ReannounceResult(
          totalFiles: 0,
          reannounced: 0,
          failed: 0,
          errors: [],
        );
      }
      
      debugPrint('[REANNOUNCE] Found ${allFiles.length} files in local storage');
      
      int reannounced = 0;
      int failed = 0;
      final List<String> errors = [];
      
      for (final fileMetadata in allFiles) {
        try {
          // Only re-announce files where we are the seeder
          final isSeeder = fileMetadata['isSeeder'] as bool? ?? false;
          if (!isSeeder) {
            debugPrint('[REANNOUNCE] Skipping ${fileMetadata['fileId']}: Not a seeder');
            continue;
          }
          
          final fileId = fileMetadata['fileId'] as String;
          final fileName = fileMetadata['fileName'] as String?;
          
          debugPrint('[REANNOUNCE] Re-announcing file: $fileName ($fileId)');
          
          // Get available chunks
          final availableChunks = await storage.getAvailableChunks(fileId);
          
          if (availableChunks.isEmpty) {
            debugPrint('[REANNOUNCE] Skipping $fileId: No chunks available');
            errors.add('$fileName: No chunks available');
            failed++;
            continue;
          }
          
          // Announce to network
          await socketClient.announceFile(
            fileId: fileId,
            mimeType: fileMetadata['mimeType'] as String? ?? 'application/octet-stream',
            fileSize: fileMetadata['fileSize'] as int? ?? 0,
            checksum: fileMetadata['checksum'] as String? ?? '',
            chunkCount: fileMetadata['chunkCount'] as int? ?? 0,
            availableChunks: availableChunks,
          );
          
          // Update lastActivity timestamp
          await storage.updateFileMetadata(fileId, {
            'lastActivity': DateTime.now().toIso8601String(),
          });
          
          debugPrint('[REANNOUNCE] ✓ Successfully re-announced: $fileName');
          reannounced++;
          
        } catch (e) {
          debugPrint('[REANNOUNCE] ✗ Failed to re-announce file: $e');
          errors.add('${fileMetadata['fileName']}: $e');
          failed++;
        }
      }
      
      final result = ReannounceResult(
        totalFiles: allFiles.length,
        reannounced: reannounced,
        failed: failed,
        errors: errors,
      );
      
      debugPrint('[REANNOUNCE] ================================================');
      debugPrint('[REANNOUNCE] Re-announce complete:');
      debugPrint('[REANNOUNCE]   Total files: ${result.totalFiles}');
      debugPrint('[REANNOUNCE]   Re-announced: ${result.reannounced}');
      debugPrint('[REANNOUNCE]   Failed: ${result.failed}');
      debugPrint('[REANNOUNCE] ================================================');
      
      return result;
      
    } catch (e, stackTrace) {
      debugPrint('[REANNOUNCE] ERROR: $e');
      debugPrint('[REANNOUNCE] Stack trace: $stackTrace');
      
      return ReannounceResult(
        totalFiles: 0,
        reannounced: 0,
        failed: 0,
        errors: ['Fatal error: $e'],
      );
    }
  }
  
  /// Re-announce a single file
  Future<bool> reannounceFile(String fileId) async {
    try {
      final fileMetadata = await storage.getFileMetadata(fileId);
      
      if (fileMetadata == null) {
        debugPrint('[REANNOUNCE] File not found: $fileId');
        return false;
      }
      
      // Get available chunks
      final availableChunks = await storage.getAvailableChunks(fileId);
      
      if (availableChunks.isEmpty) {
        debugPrint('[REANNOUNCE] No chunks available for: $fileId');
        return false;
      }
      
      // Announce to network
      await socketClient.announceFile(
        fileId: fileId,
        mimeType: fileMetadata['mimeType'] as String? ?? 'application/octet-stream',
        fileSize: fileMetadata['fileSize'] as int? ?? 0,
        checksum: fileMetadata['checksum'] as String? ?? '',
        chunkCount: fileMetadata['chunkCount'] as int? ?? 0,
        availableChunks: availableChunks,
      );
      
      // Update lastActivity
      await storage.updateFileMetadata(fileId, {
        'lastActivity': DateTime.now().toIso8601String(),
      });
      
      debugPrint('[REANNOUNCE] ✓ Successfully re-announced: $fileId');
      return true;
      
    } catch (e) {
      debugPrint('[REANNOUNCE] ✗ Failed to re-announce file $fileId: $e');
      return false;
    }
  }
}

/// Result of re-announce operation
class ReannounceResult {
  final int totalFiles;
  final int reannounced;
  final int failed;
  final List<String> errors;
  
  ReannounceResult({
    required this.totalFiles,
    required this.reannounced,
    required this.failed,
    required this.errors,
  });
  
  bool get hasErrors => errors.isNotEmpty;
  bool get allSuccessful => reannounced == totalFiles && failed == 0;
}
