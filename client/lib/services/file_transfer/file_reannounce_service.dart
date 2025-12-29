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

  FileReannounceService({required this.storage, required this.socketClient}) {
    _setupSharedWithListener();
  }

  /// Setup listener for real-time sharedWith updates (WebSocket)
  void _setupSharedWithListener() {
    socketClient.onSharedWithUpdated((data) async {
      try {
        final fileId = data['fileId'] as String?;
        final sharedWith = (data['sharedWith'] as List?)?.cast<String>();

        if (fileId == null || sharedWith == null) {
          debugPrint('[REANNOUNCE] Invalid sharedWith update data');
          return;
        }

        debugPrint(
          '[REANNOUNCE] Received sharedWith update for $fileId: ${sharedWith.length} users',
        );

        // Update local storage
        await storage.updateFileMetadata(fileId, {'sharedWith': sharedWith});

        debugPrint('[REANNOUNCE] ✓ Updated local sharedWith for $fileId');
      } catch (e) {
        debugPrint('[REANNOUNCE] Error handling sharedWith update: $e');
      }
    });
  }

  /// Re-announce all files from local storage
  ///
  /// This should be called after successful login/authentication
  Future<ReannounceResult> reannounceAllFiles() async {
    try {
      debugPrint(
        '[REANNOUNCE] Checking local storage for files to re-announce...',
      );

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

      debugPrint(
        '[REANNOUNCE] Found ${allFiles.length} files in local storage',
      );

      int reannounced = 0;
      int failed = 0;
      final List<String> errors = [];

      for (final fileMetadata in allFiles) {
        try {
          // Re-announce all files where we have chunks (seeder, partial, or downloading)
          final isSeeder = fileMetadata['isSeeder'] as bool? ?? false;
          final status = fileMetadata['status'] as String? ?? '';

          // Include partial downloads and active downloads as seeders
          final canSeed =
              isSeeder ||
              status == 'partial' ||
              status == 'downloading' ||
              status == 'seeding' ||
              status == 'uploaded';

          if (!canSeed) {
            debugPrint(
              '[REANNOUNCE] Skipping ${fileMetadata['fileId']}: Cannot seed (status: $status)',
            );
            continue;
          }

          final fileId = fileMetadata['fileId'] as String;
          final fileName = fileMetadata['fileName'] as String?;
          final chunkCount = fileMetadata['chunkCount'] as int? ?? 0;

          debugPrint(
            '[REANNOUNCE] Re-announcing file: $fileName ($fileId) - status: $status',
          );

          // Get available chunks
          final availableChunks = await storage.getAvailableChunks(fileId);

          if (availableChunks.isEmpty) {
            debugPrint('[REANNOUNCE] Skipping $fileId: No chunks available');
            errors.add('$fileName: No chunks available');
            failed++;
            continue;
          }

          final chunkQuality = chunkCount > 0
              ? ((availableChunks.length / chunkCount) * 100).round()
              : 0;

          debugPrint(
            '[REANNOUNCE] $fileId has ${availableChunks.length}/$chunkCount chunks ($chunkQuality%)',
          );

          // STEP 1: Query server for current sharedWith state
          List<String>? mergedSharedWith;
          try {
            final serverSharedWith = await socketClient.getSharedWith(fileId);
            if (serverSharedWith != null) {
              debugPrint(
                '[REANNOUNCE] Server sharedWith: ${serverSharedWith.length} users',
              );

              // Merge with local sharedWith
              final localSharedWith =
                  (fileMetadata['sharedWith'] as List?)?.cast<String>() ?? [];
              mergedSharedWith = {
                ...localSharedWith,
                ...serverSharedWith,
              }.toList();

              // Update local storage
              await storage.updateFileMetadata(fileId, {
                'sharedWith': mergedSharedWith,
              });

              debugPrint(
                '[REANNOUNCE] Merged sharedWith: ${mergedSharedWith.length} users',
              );
            } else {
              // Server doesn't have file, use local
              mergedSharedWith = (fileMetadata['sharedWith'] as List?)
                  ?.cast<String>();
            }
          } catch (e) {
            debugPrint(
              '[REANNOUNCE] Warning: Could not sync sharedWith from server: $e',
            );
            // Continue with local sharedWith
            mergedSharedWith = (fileMetadata['sharedWith'] as List?)
                ?.cast<String>();
          }

          // STEP 2: Announce to network with merged sharedWith
          final result = await socketClient.announceFile(
            fileId: fileId,
            mimeType:
                fileMetadata['mimeType'] as String? ??
                'application/octet-stream',
            fileSize: fileMetadata['fileSize'] as int? ?? 0,
            checksum: fileMetadata['checksum'] as String? ?? '',
            chunkCount: fileMetadata['chunkCount'] as int? ?? 0,
            availableChunks: availableChunks,
            sharedWith: mergedSharedWith,
          );

          // STEP 3: Update local storage with server's final merged list
          if (result['sharedWith'] != null) {
            await storage.updateFileMetadata(fileId, {
              'sharedWith': result['sharedWith'],
              'lastActivity': DateTime.now().toIso8601String(),
              'isSeeder': true,
            });

            debugPrint(
              '[REANNOUNCE] Updated local sharedWith from server: ${result['sharedWith'].length} users',
            );
          } else {
            // Fallback: just update lastActivity and seeder status
            await storage.updateFileMetadata(fileId, {
              'lastActivity': DateTime.now().toIso8601String(),
              'isSeeder': true,
            });
          }

          debugPrint(
            '[REANNOUNCE] ✓ Successfully re-announced: $fileName ($chunkQuality% complete)',
          );
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

      debugPrint(
        '[REANNOUNCE] ================================================',
      );
      debugPrint('[REANNOUNCE] Re-announce complete:');
      debugPrint('[REANNOUNCE]   Total files: ${result.totalFiles}');
      debugPrint('[REANNOUNCE]   Re-announced: ${result.reannounced}');
      debugPrint('[REANNOUNCE]   Failed: ${result.failed}');
      debugPrint(
        '[REANNOUNCE] ================================================',
      );

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

  /// Re-announce a single file (with sharedWith sync)
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

      // STEP 1: Query server for current sharedWith state
      List<String>? mergedSharedWith;
      try {
        final serverSharedWith = await socketClient.getSharedWith(fileId);
        if (serverSharedWith != null) {
          debugPrint(
            '[REANNOUNCE] Server sharedWith: ${serverSharedWith.length} users',
          );

          // Merge with local sharedWith
          final localSharedWith =
              (fileMetadata['sharedWith'] as List?)?.cast<String>() ?? [];
          mergedSharedWith = {...localSharedWith, ...serverSharedWith}.toList();

          // Update local storage
          await storage.updateFileMetadata(fileId, {
            'sharedWith': mergedSharedWith,
          });

          debugPrint(
            '[REANNOUNCE] Merged sharedWith: ${mergedSharedWith.length} users',
          );
        } else {
          // Server doesn't have file, use local
          mergedSharedWith = (fileMetadata['sharedWith'] as List?)
              ?.cast<String>();
        }
      } catch (e) {
        debugPrint(
          '[REANNOUNCE] Warning: Could not sync sharedWith from server: $e',
        );
        // Continue with local sharedWith
        mergedSharedWith = (fileMetadata['sharedWith'] as List?)
            ?.cast<String>();
      }

      // STEP 2: Announce to network with merged sharedWith
      final result = await socketClient.announceFile(
        fileId: fileId,
        mimeType:
            fileMetadata['mimeType'] as String? ?? 'application/octet-stream',
        fileSize: fileMetadata['fileSize'] as int? ?? 0,
        checksum: fileMetadata['checksum'] as String? ?? '',
        chunkCount: fileMetadata['chunkCount'] as int? ?? 0,
        availableChunks: availableChunks,
        sharedWith: mergedSharedWith,
      );

      // STEP 3: Update local storage with server's final merged list
      if (result['sharedWith'] != null) {
        await storage.updateFileMetadata(fileId, {
          'sharedWith': result['sharedWith'],
          'lastActivity': DateTime.now().toIso8601String(),
        });

        debugPrint(
          '[REANNOUNCE] Updated local sharedWith from server: ${result['sharedWith'].length} users',
        );
      } else {
        // Fallback: just update lastActivity
        await storage.updateFileMetadata(fileId, {
          'lastActivity': DateTime.now().toIso8601String(),
        });
      }

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
