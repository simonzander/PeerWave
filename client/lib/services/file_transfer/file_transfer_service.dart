import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'socket_file_client.dart';
import 'storage_interface.dart';
import '../signal_service.dart';

/// File Transfer Service
/// 
/// Handles file upload, download, announce, and re-announce functionality
class FileTransferService {
  final SocketFileClient _socketFileClient;
  final FileStorageInterface _storage;
  final SignalService? _signalService; // Optional for share updates
  
  // ============================================
  // HIGH #6: DOWNLOAD CANCELLATION
  // ============================================
  final Map<String, _DownloadCancelToken> _activeDownloads = {};
  
  FileTransferService({
    required SocketFileClient socketFileClient,
    required FileStorageInterface storage,
    SignalService? signalService,
  })  : _socketFileClient = socketFileClient,
        _storage = storage,
        _signalService = signalService {
    // Setup announce listener for auto-resume
    _setupAnnounceListener();
  }
  
  // ============================================
  // UPLOAD & ANNOUNCE
  // ============================================
  
  /// Upload file and automatically announce
  Future<String> uploadAndAnnounceFile({
    required Uint8List fileBytes,
    required String fileName,
    required String mimeType,
    List<String>? sharedWith,
  }) async {
    try {
      print('[FILE TRANSFER] Starting upload: $fileName (${fileBytes.length} bytes)');
      
      // Step 1: Generate file metadata
      final fileId = _generateFileId();
      final checksum = _calculateChecksum(fileBytes);
      
      // Step 2: Chunk file
      final chunks = _chunkFile(fileBytes);
      print('[FILE TRANSFER] Created ${chunks.length} chunks');
      
      // Step 3: Store locally
      await _storage.saveFileMetadata({
        'fileId': fileId,
        'fileName': fileName,
        'mimeType': mimeType,
        'fileSize': fileBytes.length,
        'checksum': checksum,
        'chunkCount': chunks.length,
        'status': 'uploaded',
        'isSeeder': true,
        'downloadComplete': true,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'sharedWith': sharedWith ?? [],
      });
      
      for (int i = 0; i < chunks.length; i++) {
        await _storage.saveChunk(fileId, i, chunks[i]);
      }
      
      // Step 4: AUTO-ANNOUNCE
      print('[FILE TRANSFER] Auto-announcing file: $fileId');
      await _socketFileClient.announceFile(
        fileId: fileId,
        mimeType: mimeType,
        fileSize: fileBytes.length,
        checksum: checksum,
        chunkCount: chunks.length,
        availableChunks: List.generate(chunks.length, (i) => i),
        sharedWith: sharedWith,
      );
      
      print('[FILE TRANSFER] ✓ Upload complete and announced: $fileId');
      return fileId;
      
    } catch (e) {
      print('[FILE TRANSFER] Error in uploadAndAnnounceFile: $e');
      rethrow;
    }
  }
  
  // ============================================
  // RE-ANNOUNCE
  // ============================================
  
  /// Re-announce all uploaded files after login
  Future<void> reannounceUploadedFiles() async {
    try {
      print('[FILE TRANSFER] Re-announcing uploaded files...');
      
      // Get all files with status 'uploaded', 'seeding', 'partial', or 'downloading'
      // Also announce partial downloads so they can seed their available chunks
      final allFiles = await _storage.getAllFiles();
      final uploadedFiles = allFiles.where((file) => 
        file['status'] == 'uploaded' || 
        file['status'] == 'seeding' ||
        file['status'] == 'partial' ||
        file['status'] == 'downloading'
      ).toList();
      
      print('[FILE TRANSFER] Found ${uploadedFiles.length} files to re-announce (including partial downloads)');
      
      for (final file in uploadedFiles) {
        final fileId = file['fileId'] as String;
        
        try {
          // Get available chunks
          final availableChunks = await _getAvailableChunkIndices(fileId);
          
          if (availableChunks.isEmpty) {
            print('[FILE TRANSFER] Warning: No chunks found for $fileId, skipping');
            continue;
          }
          
          // Re-announce with sharedWith
          final sharedWith = (file['sharedWith'] as List?)?.cast<String>() ?? [];
          final status = file['status'] as String;
          
          print('[FILE TRANSFER] Re-announcing: $fileId (${availableChunks.length} chunks, status: $status)');
          
          await _socketFileClient.announceFile(
            fileId: fileId,
            mimeType: file['mimeType'] as String,
            fileSize: file['fileSize'] as int,
            checksum: file['checksum'] as String,
            chunkCount: file['chunkCount'] as int,
            availableChunks: availableChunks,
            sharedWith: sharedWith.isNotEmpty ? sharedWith : null,
          );
          
          // HIGH #2: Sync state with server after re-announce
          try {
            print('[FILE TRANSFER] HIGH #2: Syncing state with server for $fileId');
            
            // Query server for current file state
            final fileInfo = await _socketFileClient.getFileInfo(fileId);
            final serverSharedWith = (fileInfo['sharedWith'] as List?)?.cast<String>() ?? [];
            
            // Update local metadata with server's canonical state
            // Keep original status if partial/downloading
            final newStatus = (status == 'partial' || status == 'downloading') ? status : 'seeding';
            
            await _storage.updateFileMetadata(fileId, {
              'status': newStatus,
              'lastAnnounceTime': DateTime.now().millisecondsSinceEpoch,
              'sharedWith': serverSharedWith,
              'lastSync': DateTime.now().millisecondsSinceEpoch,
              'isSeeder': true, // Mark as seeder even if partial
            });
            
            print('[FILE TRANSFER] ✓ State synced: $fileId (${availableChunks.length}/${file['chunkCount']} chunks) shared with ${serverSharedWith.length} users');
          } catch (e) {
            print('[FILE TRANSFER] ⚠ Failed to sync state for $fileId: $e');
            
            // Still update basic status even if sync fails
            // Keep original status if partial/downloading
            final status = file['status'] as String;
            final newStatus = (status == 'partial' || status == 'downloading') ? status : 'seeding';
            
            await _storage.updateFileMetadata(fileId, {
              'status': newStatus,
              'lastAnnounceTime': DateTime.now().millisecondsSinceEpoch,
              'isSeeder': true,
            });
          }
        } catch (e) {
          print('[FILE TRANSFER] Error re-announcing $fileId: $e');
        }
      }
      
      print('[FILE TRANSFER] ✓ Re-announce complete');
      
    } catch (e) {
      print('[FILE TRANSFER] Error re-announcing files: $e');
    }
  }
  
  // ============================================
  // DOWNLOAD
  // ============================================
  
  /// Download file with partial download support
  Future<void> downloadFile({
    required String fileId,
    required Function(double) onProgress,
    bool allowPartial = true,
  }) async {
    // HIGH #6: Create cancel token for this download
    final cancelToken = _DownloadCancelToken();
    _activeDownloads[fileId] = cancelToken;
    
    try {
      print('[FILE TRANSFER] Starting download: $fileId (partial: $allowPartial)');
      
      // Step 1: Get file info and check quality
      final fileInfo = await _socketFileClient.getFileInfo(fileId);
      final chunkQuality = fileInfo['chunkQuality'] as int? ?? 0;
      
      print('[FILE TRANSFER] Chunk quality: $chunkQuality%');
      
      // Step 2: Warn if incomplete
      if (chunkQuality < 100 && !allowPartial) {
        throw Exception('File incomplete ($chunkQuality% available). Enable partial downloads.');
      }
      
      // Step 2.5: Save initial metadata and announce as seeder (0 chunks)
      // This allows others to see we're downloading and potentially download from us
      print('[FILE TRANSFER] Step 2.5: Saving initial metadata and announcing...');
      
      try {
        await _storage.saveFileMetadata({
          'fileId': fileId,
          'fileName': fileInfo['fileName'] ?? 'unknown',
          'mimeType': fileInfo['mimeType'] ?? 'application/octet-stream',
          'fileSize': fileInfo['fileSize'] ?? 0,
          'checksum': fileInfo['checksum'] ?? '',
          'chunkCount': fileInfo['chunkCount'] ?? 0,
          'status': 'downloading',
          'isSeeder': true, // Mark as seeder even with 0 chunks
          'downloadComplete': false,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'sharedWith': (fileInfo['sharedWith'] as List?)?.cast<String>() ?? [],
          'downloadedChunks': [], // Start with no chunks
        });
        
        // Announce ourselves as seeder (with 0 chunks initially)
        await _socketFileClient.announceFile(
          fileId: fileId,
          mimeType: fileInfo['mimeType'] ?? 'application/octet-stream',
          fileSize: fileInfo['fileSize'] ?? 0,
          checksum: fileInfo['checksum'] ?? '',
          chunkCount: fileInfo['chunkCount'] ?? 0,
          availableChunks: [], // No chunks yet
          sharedWith: (fileInfo['sharedWith'] as List?)?.cast<String>(),
        );
        
        print('[FILE TRANSFER] ✓ Announced as seeder with 0 chunks (downloading)');
      } catch (e) {
        print('[FILE TRANSFER] Warning: Could not save metadata or announce: $e');
        // Continue with download anyway
      }
      
      // Step 3: Register as leecher
      await _socketFileClient.registerLeecher(fileId);
      
      // Step 4: Get available chunks from seeders
      final seeders = await _socketFileClient.getAvailableChunks(fileId);
      
      // Step 5: Download available chunks
      final downloadedChunks = <int>[];
      final verifiedChunks = <int>[]; // Track chunks that passed verification
      final totalChunks = fileInfo['chunkCount'] as int;
      
      for (int i = 0; i < totalChunks; i++) {
        // HIGH #6: Check if download was canceled
        if (cancelToken.isCanceled) {
          print('[FILE TRANSFER] Download canceled by user: $fileId');
          throw DownloadCanceledException('Download canceled during chunk $i');
        }
        
        // Check if chunk is available from any seeder
        final hasChunk = _isChunkAvailable(i, seeders);
        
        if (!hasChunk) {
          print('[FILE TRANSFER] Chunk $i not available, skipping');
          continue;
        }
        
        // TODO: Implement actual chunk download from seeders
        // For now, just mark as downloaded
        downloadedChunks.add(i);
        
        // ========================================
        // PARTIAL SEEDING: Verify chunk hash before announcing
        // ========================================
        final isChunkValid = await _verifyChunkHash(fileId, i);
        
        if (isChunkValid) {
          verifiedChunks.add(i);
          print('[FILE TRANSFER] ✓ Chunk $i verified');
          
          // Only announce verified chunks for partial seeding
          await _socketFileClient.updateAvailableChunks(fileId, verifiedChunks);
        } else {
          print('[FILE TRANSFER] ⚠️ Chunk $i failed verification - not announcing');
          // Don't add to verifiedChunks, so it won't be announced
        }
        
        // Update progress
        onProgress(downloadedChunks.length / totalChunks);
      }
      
      // Step 6: Update status
      final isComplete = downloadedChunks.length == totalChunks;
      final allChunksVerified = verifiedChunks.length == downloadedChunks.length;
      
      // Step 7: Verify complete file checksum if download is complete
      if (isComplete && allChunksVerified) {
        print('[FILE TRANSFER] Step 7: Verifying complete file checksum...');
        final isValid = await _verifyFileChecksum(fileId);
        
        if (!isValid) {
          print('[SECURITY] ❌ File checksum verification FAILED! File corrupted or tampered.');
          
          // ========================================
          // SMART ERROR RECOVERY
          // ========================================
          // Instead of deleting entire file, identify and re-download only corrupted chunks
          
          print('[FILE TRANSFER] Starting smart error recovery...');
          final corruptedChunks = await _findCorruptedChunks(fileId);
          
          if (corruptedChunks.isEmpty) {
            // No corrupted chunks found, but checksum still fails
            // This means the file as a whole is corrupted (metadata issue?)
            print('[FILE TRANSFER] ⚠️ No corrupted chunks found, but checksum fails');
            print('[FILE TRANSFER] Deleting entire file for clean re-download');
            await _deleteCorruptedFile(fileId);
            throw Exception('File integrity check failed - checksum mismatch (metadata corrupted)');
          }
          
          // Recover by re-downloading only corrupted chunks
          await _recoverCorruptedFile(fileId, corruptedChunks);
          
          print('[FILE TRANSFER] ✓ Corrupted chunks marked for re-download');
          print('[FILE TRANSFER] File will automatically re-download ${corruptedChunks.length} chunks');
          
          // Update metadata to downloading state (don't set seeding yet)
          await _storage.updateFileMetadata(fileId, {
            'status': 'downloading',
            'downloadComplete': false,
            'isSeeder': true, // Still seeding verified chunks
            'downloadedChunks': verifiedChunks, // Only verified chunks
          });
          
          // ========================================
          // IMPORTANT: Still announce verified chunks!
          // ========================================
          // Even though file is corrupted, we can still seed verified chunks
          print('[FILE TRANSFER] Announcing verified chunks during recovery...');
          
          try {
            final metadata = await _storage.getFileMetadata(fileId);
            if (metadata != null) {
              await _socketFileClient.announceFile(
                fileId: fileId,
                mimeType: metadata['mimeType'] as String,
                fileSize: metadata['fileSize'] as int,
                checksum: metadata['checksum'] as String,
                chunkCount: metadata['chunkCount'] as int,
                availableChunks: verifiedChunks, // Only verified chunks
                sharedWith: (metadata['sharedWith'] as List?)?.cast<String>(),
              );
              
              print('[FILE TRANSFER] ✓ Announced ${verifiedChunks.length} verified chunks during recovery');
            }
          } catch (e) {
            print('[FILE TRANSFER] Warning: Could not announce during recovery: $e');
          }
          
          // Don't throw - file is in recovery state
          // The auto-resume mechanism will pick it up
          return;
        }
        
        print('[FILE TRANSFER] ✓ File checksum verified - file is authentic');
      } else if (!allChunksVerified) {
        print('[FILE TRANSFER] ⚠️ Some chunks failed verification (${downloadedChunks.length - verifiedChunks.length} failed)');
      }
      
      // Step 8: Update metadata with verified chunks only
      await _storage.updateFileMetadata(fileId, {
        'status': (isComplete && allChunksVerified) ? 'seeding' : 'partial',
        'downloadComplete': isComplete && allChunksVerified,
        'isSeeder': true,
        'downloadedChunks': verifiedChunks, // Use verifiedChunks instead of downloadedChunks
      });
      
      // ========================================
      // AUTO-ANNOUNCE AS SEEDER (Critical!)
      // ========================================
      // After download (complete OR partial), announce to server
      // so other peers can download from us
      
      print('[FILE TRANSFER] Step 9: Announcing as seeder...');
      
      try {
        final metadata = await _storage.getFileMetadata(fileId);
        if (metadata != null) {
          await _socketFileClient.announceFile(
            fileId: fileId,
            mimeType: metadata['mimeType'] as String,
            fileSize: metadata['fileSize'] as int,
            checksum: metadata['checksum'] as String,
            chunkCount: metadata['chunkCount'] as int,
            availableChunks: verifiedChunks, // ✅ Only announce verified chunks
            sharedWith: (metadata['sharedWith'] as List?)?.cast<String>(),
          );
          
          print('[FILE TRANSFER] ✓ Announced as seeder with ${verifiedChunks.length}/$totalChunks verified chunks');
        }
      } catch (e) {
        print('[FILE TRANSFER] Warning: Could not announce as seeder: $e');
        // Don't fail the download if announce fails
      }
      
      if (isComplete && allChunksVerified) {
        print('[FILE TRANSFER] ✓ Download complete: $fileId');
      } else {
        print('[FILE TRANSFER] ⚠ Partial download: $fileId (${verifiedChunks.length}/$totalChunks verified chunks)');
      }
      
    } catch (e) {
      if (e is DownloadCanceledException) {
        print('[FILE TRANSFER] Download canceled: $fileId');
        // Don't rethrow - this is expected
      } else {
        print('[FILE TRANSFER] Error downloading file: $e');
        rethrow;
      }
    } finally {
      // HIGH #6: Remove cancel token when download completes/fails
      _activeDownloads.remove(fileId);
    }
  }
  
  // ============================================
  // AUTO-RESUME
  // ============================================
  
  /// Resume incomplete downloads after login
  Future<void> resumeIncompleteDownloads() async {
    try {
      print('[FILE TRANSFER] Checking for incomplete downloads...');
      
      final allFiles = await _storage.getAllFiles();
      final incompleteFiles = allFiles.where((file) => 
        file['status'] == 'downloading' || file['status'] == 'partial'
      ).toList();
      
      print('[FILE TRANSFER] Found ${incompleteFiles.length} incomplete downloads');
      
      for (final file in incompleteFiles) {
        final fileId = file['fileId'] as String;
        
        try {
          final fileInfo = await _socketFileClient.getFileInfo(fileId);
          final chunkQuality = fileInfo['chunkQuality'] as int? ?? 0;
          
          if (chunkQuality > 0) {
            print('[FILE TRANSFER] Resuming download: $fileId (quality: $chunkQuality%)');
            
            // Resume download in background
            unawaited(downloadFile(
              fileId: fileId,
              onProgress: (progress) {
                print('[FILE TRANSFER] Resume progress for $fileId: ${(progress * 100).toInt()}%');
              },
              allowPartial: true,
            ).catchError((e) {
              print('[FILE TRANSFER] Error resuming $fileId: $e');
            }));
          } else {
            print('[FILE TRANSFER] No chunks available for $fileId, skipping');
          }
        } catch (e) {
          print('[FILE TRANSFER] File $fileId not found on server: $e');
        }
      }
      
    } catch (e) {
      print('[FILE TRANSFER] Error resuming downloads: $e');
    }
  }
  
  /// Setup listener for new file announcements (for auto-resume)
  void _setupAnnounceListener() {
    // Common resume logic for both events
    Future<void> checkAndResumeDownload(String fileId, int chunkQuality) async {
      try {
        // Check if we have this file as incomplete download
        final metadata = await _storage.getFileMetadata(fileId);
        if (metadata == null || 
            (metadata['status'] != 'downloading' && metadata['status'] != 'partial')) {
          return;
        }
        
        print('[FILE TRANSFER] Found incomplete download for $fileId, checking for new chunks');
        
        // Get our downloaded chunks
        final ourChunks = (metadata['downloadedChunks'] as List?)?.cast<int>() ?? [];
        final totalChunks = metadata['chunkCount'] as int;
        
        if (ourChunks.length >= totalChunks) {
          return; // Already complete
        }
        
        // Check if new chunks are actually available
        final fileInfo = await _socketFileClient.getFileInfo(fileId);
        final availableChunks = _getAvailableChunksFromSeeders(
          fileInfo['seederChunks'] as Map<String, dynamic>?
        );
        
        // Check if there are chunks we don't have yet
        final newChunks = availableChunks.where((idx) => !ourChunks.contains(idx)).toList();
        
        if (newChunks.isNotEmpty) {
          print('[FILE TRANSFER] Found ${newChunks.length} new chunks, auto-resuming download for $fileId');
          
          // Resume download
          unawaited(downloadFile(
            fileId: fileId,
            onProgress: (progress) {
              print('[FILE TRANSFER] Auto-resume progress: ${(progress * 100).toInt()}%');
            },
            allowPartial: true,
          ).catchError((e) {
            print('[FILE TRANSFER] Error auto-resuming: $e');
          }));
        } else {
          print('[FILE TRANSFER] No new chunks available yet for $fileId');
        }
      } catch (e) {
        print('[FILE TRANSFER] Error checking new chunks: $e');
      }
    }
    
    // Listen to both events
    _socketFileClient.onFileAnnounced((data) async {
      final fileId = data['fileId'] as String;
      final chunkQuality = data['chunkQuality'] as int? ?? 0;
      final newSharedWith = (data['sharedWith'] as List?)?.cast<String>() ?? [];
      
      print('[FILE TRANSFER] File announced: $fileId (quality: $chunkQuality%)');
      
      // Merge sharedWith from announcement with local metadata
      if (newSharedWith.isNotEmpty) {
        final existingMetadata = await _storage.getFileMetadata(fileId);
        if (existingMetadata != null) {
          final existingSharedWith = (existingMetadata['sharedWith'] as List?)?.cast<String>() ?? [];
          
          // Merge: combine both lists and remove duplicates
          final mergedSharedWith = <String>{...existingSharedWith, ...newSharedWith}.toList();
          
          if (mergedSharedWith.length != existingSharedWith.length) {
            print('[FILE TRANSFER] Merging sharedWith: ${existingSharedWith.length} -> ${mergedSharedWith.length} users');
            
            // Update metadata with merged sharedWith
            await _storage.saveFileMetadata({
              ...existingMetadata,
              'sharedWith': mergedSharedWith,
              'lastActivity': DateTime.now().toIso8601String(),
            });
          }
        }
      }
      
      await checkAndResumeDownload(fileId, chunkQuality);
    });
    
    _socketFileClient.onFileSeederUpdate((data) async {
      final fileId = data['fileId'] as String;
      final chunkQuality = data['chunkQuality'] as int? ?? 0;
      
      print('[FILE TRANSFER] Seeder update: $fileId (quality: $chunkQuality%)');
      await checkAndResumeDownload(fileId, chunkQuality);
    });
  }
  
  // ============================================
  // HELPER METHODS
  // ============================================
  
  /// Generate unique file ID
  String _generateFileId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = DateTime.now().microsecondsSinceEpoch;
    return '$timestamp-$random';
  }
  
  /// Calculate file checksum (SHA-256)
  String _calculateChecksum(Uint8List bytes) {
    final digest = sha256.convert(bytes);
    return digest.toString();
  }
  
  /// Chunk file into 64KB chunks
  List<Uint8List> _chunkFile(Uint8List bytes) {
    const chunkSize = 64 * 1024; // 64 KB
    final chunks = <Uint8List>[];
    
    for (int i = 0; i < bytes.length; i += chunkSize) {
      final end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
      chunks.add(bytes.sublist(i, end));
    }
    
    return chunks;
  }
  
  /// Get available chunk indices from storage
  Future<List<int>> _getAvailableChunkIndices(String fileId) async {
    final metadata = await _storage.getFileMetadata(fileId);
    if (metadata == null) return [];
    
    final chunkCount = metadata['chunkCount'] as int;
    final availableChunks = <int>[];
    
    for (int i = 0; i < chunkCount; i++) {
      final chunk = await _storage.getChunk(fileId, i);
      if (chunk != null) {
        availableChunks.add(i);
      }
    }
    
    return availableChunks;
  }
  
  /// Extract available chunks from seeder map
  List<int> _getAvailableChunksFromSeeders(Map<String, dynamic>? seederChunks) {
    if (seederChunks == null) return [];
    
    final availableChunks = <int>{};
    for (final chunks in seederChunks.values) {
      if (chunks is List) {
        availableChunks.addAll(chunks.cast<int>());
      }
    }
    
    return availableChunks.toList()..sort();
  }
  
  /// Check if chunk is available from any seeder
  bool _isChunkAvailable(int chunkIndex, Map<String, dynamic> seeders) {
    for (final seederData in seeders.values) {
      if (seederData is Map) {
        final chunks = seederData['chunks'] as List?;
        if (chunks?.contains(chunkIndex) ?? false) {
          return true;
        }
      }
    }
    return false;
  }
  
  // ============================================
  // SHARE MANAGEMENT
  // ============================================
  
  /// Add users to file share (via Signal Protocol + Server)
  Future<void> addUsersToShare({
    required String fileId,
    required String chatId,
    required String chatType, // 'group' | 'direct'
    required List<String> userIds,
    String? encryptedFileKey,
  }) async {
    if (_signalService == null) {
      print('[FILE TRANSFER] Warning: SignalService not available, cannot send share updates');
      return;
    }
    
    try {
      // Step 1: Update server FIRST (critical!)
      print('[FILE TRANSFER] Step 1/3: Updating server share...');
      
      final serverUpdate = await _socketFileClient.updateFileShare(
        fileId: fileId,
        action: 'add',
        userIds: userIds,
      );
      
      if (serverUpdate['success'] != true) {
        throw Exception('Server update failed: ${serverUpdate['error']}');
      }
      
      print('[FILE TRANSFER] ✓ Server updated: ${serverUpdate['successCount']} users added');
      
      // Get file metadata to include checksum and current sharedWith
      final metadata = await _storage.getFileMetadata(fileId);
      final checksum = metadata?['checksum'] as String?;
      final currentSharedWith = (metadata?['sharedWith'] as List?)?.cast<String>() ?? [];
      
      // Step 2: Send Signal Protocol message (encrypted notification)
      // IMPORTANT: Send to ALL seeders (not just affected users) to sync their sharedWith lists
      print('[FILE TRANSFER] Step 2/3: Sending encrypted Signal notification...');
      
      final allSeeders = {...currentSharedWith, ...userIds}.toList();
      print('[FILE TRANSFER] Broadcasting to ${allSeeders.length} seeders (keeping all in sync)');
      
      await _signalService.sendFileShareUpdate(
        chatId: chatId,
        chatType: chatType,
        fileId: fileId,
        action: 'add',
        affectedUserIds: allSeeders,  // ← ALL seeders (existing + new)
        checksum: checksum, // ← Include checksum for verification
        encryptedFileKey: encryptedFileKey,
      );
      
      print('[FILE TRANSFER] ✓ Signal notifications sent to all ${allSeeders.length} seeders');
      
      // Step 3: Update local metadata
      print('[FILE TRANSFER] Step 3/3: Updating local metadata...');
      
      if (metadata != null) {
        final currentSharedWith = (metadata['sharedWith'] as List?)?.cast<String>() ?? [];
        final updatedSharedWith = {...currentSharedWith, ...userIds}.toList();
        
        await _storage.updateFileMetadata(fileId, {
          'sharedWith': updatedSharedWith,
        });
      }
      
      // Step 4: Re-announce file with updated sharedWith list
      // This ensures server's FileRegistry has the current sharedWith state
      print('[FILE TRANSFER] Step 4/4: Re-announcing file with updated share list...');
      
      try {
        if (metadata != null) {
          final availableChunks = await _getAvailableChunkIndices(fileId);
          final updatedSharedWith = {...currentSharedWith, ...userIds}.toList();
          
          await _socketFileClient.announceFile(
            fileId: fileId,
            mimeType: metadata['mimeType'] as String,
            fileSize: metadata['fileSize'] as int,
            checksum: metadata['checksum'] as String,
            chunkCount: metadata['chunkCount'] as int,
            availableChunks: availableChunks,
            sharedWith: updatedSharedWith, // ← Updated sharedWith list
          );
          
          print('[FILE TRANSFER] ✓ File re-announced with ${updatedSharedWith.length} users in sharedWith');
        }
      } catch (e) {
        print('[FILE TRANSFER] Warning: Could not re-announce file: $e');
        // Don't fail the share operation if re-announce fails
        // File is already shared via server and Signal
      }
      
      print('[FILE TRANSFER] ✓ Added ${userIds.length} users to share: $fileId');
    } catch (e) {
      print('[FILE TRANSFER] Error adding users to share: $e');
      
      // TODO: Implement rollback if Signal message fails
      // For now, server update is kept even if Signal fails
      
      rethrow;
    }
  }
  
  /// Revoke users from file share (via Signal Protocol + Server)
  Future<void> revokeUsersFromShare({
    required String fileId,
    required String chatId,
    required String chatType,
    required List<String> userIds,
  }) async {
    if (_signalService == null) {
      print('[FILE TRANSFER] Warning: SignalService not available, cannot send share updates');
      return;
    }
    
    try {
      // Step 1: Update server FIRST
      print('[FILE TRANSFER] Step 1/3: Updating server share...');
      
      final serverUpdate = await _socketFileClient.updateFileShare(
        fileId: fileId,
        action: 'revoke',
        userIds: userIds,
      );
      
      if (serverUpdate['success'] != true) {
        throw Exception('Server update failed: ${serverUpdate['error']}');
      }
      
      print('[FILE TRANSFER] ✓ Server updated: ${serverUpdate['successCount']} users revoked');
      
      // Get file metadata to include checksum and current sharedWith
      final metadata = await _storage.getFileMetadata(fileId);
      final checksum = metadata?['checksum'] as String?;
      final currentSharedWith = (metadata?['sharedWith'] as List?)?.cast<String>() ?? [];
      
      // Step 2: Send Signal Protocol message
      // IMPORTANT: Send to remaining seeders (after revoke) to sync their sharedWith lists
      print('[FILE TRANSFER] Step 2/3: Sending encrypted Signal notification...');
      
      final remainingSeeders = currentSharedWith.where((id) => !userIds.contains(id)).toList();
      final allRecipients = [...remainingSeeders, ...userIds]; // Include revoked users for notification
      print('[FILE TRANSFER] Broadcasting to ${allRecipients.length} users (revoked + remaining seeders)');
      
      await _signalService.sendFileShareUpdate(
        chatId: chatId,
        chatType: chatType,
        fileId: fileId,
        action: 'revoke',
        affectedUserIds: allRecipients,  // ← Revoked users + remaining seeders
        checksum: checksum, // ← Include checksum for verification
      );
      
      print('[FILE TRANSFER] ✓ Signal notifications sent to ${allRecipients.length} users');
      
      // Step 3: Update local metadata
      print('[FILE TRANSFER] Step 3/3: Updating local metadata...');
      
      if (metadata != null) {
        final currentSharedWith = (metadata['sharedWith'] as List?)?.cast<String>() ?? [];
        final updatedSharedWith = currentSharedWith.where((id) => !userIds.contains(id)).toList();
        
        await _storage.updateFileMetadata(fileId, {
          'sharedWith': updatedSharedWith,
        });
      }
      
      // Step 4: Re-announce file with updated sharedWith list
      // This ensures server's FileRegistry has the current sharedWith state
      print('[FILE TRANSFER] Step 4/4: Re-announcing file with updated share list...');
      
      try {
        if (metadata != null) {
          final availableChunks = await _getAvailableChunkIndices(fileId);
          final remainingSeeders = currentSharedWith.where((id) => !userIds.contains(id)).toList();
          
          await _socketFileClient.announceFile(
            fileId: fileId,
            mimeType: metadata['mimeType'] as String,
            fileSize: metadata['fileSize'] as int,
            checksum: metadata['checksum'] as String,
            chunkCount: metadata['chunkCount'] as int,
            availableChunks: availableChunks,
            sharedWith: remainingSeeders.isNotEmpty ? remainingSeeders : null, // ← Updated sharedWith list
          );
          
          print('[FILE TRANSFER] ✓ File re-announced with ${remainingSeeders.length} users in sharedWith');
        }
      } catch (e) {
        print('[FILE TRANSFER] Warning: Could not re-announce file: $e');
        // Don't fail the revoke operation if re-announce fails
        // File access is already revoked via server and Signal
      }
      
      print('[FILE TRANSFER] ✓ Revoked ${userIds.length} users from share: $fileId');
    } catch (e) {
      print('[FILE TRANSFER] Error revoking users from share: $e');
      rethrow;
    }
  }
  
  // ============================================
  // SELF-REVOKE
  // ============================================
  
  /// Remove yourself from a file's share list
  /// 
  /// Use case: User wants to stop seeding a file or free up storage
  Future<void> removeSelfFromShare({
    required String fileId,
    required String chatId,
    required String chatType,
  }) async {
    try {
      print('[FILE TRANSFER] Self-revoking from file: $fileId');
      
      // Get current user ID (from session/auth)
      // Note: You'll need to get this from your auth service
      // For now, this is a placeholder - adapt to your auth implementation
      final currentUserId = await _getCurrentUserId();
      
      if (currentUserId == null) {
        throw Exception('Cannot determine current user ID');
      }
      
      // Use existing revoke method with self as target
      await revokeUsersFromShare(
        fileId: fileId,
        chatId: chatId,
        chatType: chatType,
        userIds: [currentUserId],
      );
      
      print('[FILE TRANSFER] ✓ Successfully removed self from share');
      
    } catch (e) {
      print('[FILE TRANSFER] Error removing self from share: $e');
      rethrow;
    }
  }
  
  /// Helper to get current user ID
  /// TODO: Integrate with your authentication service
  Future<String?> _getCurrentUserId() async {
    // This should be implemented based on your auth system
    // For example:
    // return await _authService.getCurrentUserId();
    // or from shared preferences, etc.
    throw UnimplementedError('_getCurrentUserId() needs to be implemented with your auth service');
  }
  
  // ============================================
  // PUBLIC METADATA ACCESS (for MessageListener)
  // ============================================
  
  /// Get file metadata (public access for MessageListener)
  Future<Map<String, dynamic>?> getFileMetadata(String fileId) async {
    return await _storage.getFileMetadata(fileId);
  }
  
  /// Save file metadata (public access for MessageListener)
  Future<void> saveFileMetadata(Map<String, dynamic> metadata) async {
    return await _storage.saveFileMetadata(metadata);
  }
  
  /// Update file metadata (public access for MessageListener)
  Future<void> updateFileMetadata(String fileId, Map<String, dynamic> updates) async {
    return await _storage.updateFileMetadata(fileId, updates);
  }
  
  /// Get server's canonical sharedWith list for a file
  /// 
  /// This fetches the authoritative sharedWith list from server
  /// Used to sync local metadata after receiving Signal notifications
  Future<List<String>?> getServerSharedWith(String fileId) async {
    try {
      final fileInfo = await _socketFileClient.getFileInfo(fileId);
      
      final sharedWith = fileInfo['sharedWith'];
      if (sharedWith == null) {
        return null;
      }
      
      if (sharedWith is List) {
        return sharedWith.cast<String>();
      } else if (sharedWith is Set) {
        return sharedWith.cast<String>().toList();
      }
      
      print('[FILE TRANSFER] Warning: Unexpected sharedWith type: ${sharedWith.runtimeType}');
      return null;
      
    } catch (e) {
      print('[FILE TRANSFER] Error getting server sharedWith: $e');
      return null;
    }
  }
  
  // ============================================
  // CHECKSUM VERIFICATION (CRITICAL #11 FIX)
  // ============================================
  
  /// Verify file checksum against server's canonical checksum
  /// 
  /// Returns true if checksum matches, false otherwise
  Future<bool> _verifyFileChecksum(String fileId) async {
    try {
      // Get local file metadata
      final metadata = await _storage.getFileMetadata(fileId);
      if (metadata == null) {
        print('[SECURITY] ❌ No metadata found for $fileId');
        return false;
      }
      
      final expectedChecksum = metadata['checksum'] as String?;
      if (expectedChecksum == null) {
        print('[SECURITY] ⚠️ No checksum in metadata for $fileId');
        return false;
      }
      
      // Get all chunks and calculate actual checksum
      final chunkCount = metadata['chunkCount'] as int;
      final chunks = <Uint8List>[];
      
      for (int i = 0; i < chunkCount; i++) {
        final chunk = await _storage.getChunk(fileId, i);
        if (chunk == null) {
          print('[SECURITY] ❌ Missing chunk $i for $fileId');
          return false;
        }
        chunks.add(chunk);
      }
      
      // Combine all chunks
      final totalSize = chunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
      final fileBytes = Uint8List(totalSize);
      int offset = 0;
      for (final chunk in chunks) {
        fileBytes.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      
      // Calculate checksum
      final actualChecksum = sha256.convert(fileBytes).toString();
      
      // Compare checksums
      final isValid = actualChecksum == expectedChecksum;
      
      if (isValid) {
        print('[SECURITY] ✅ Checksum valid for $fileId');
        print('[SECURITY]    Expected: ${expectedChecksum.substring(0, 16)}...');
        print('[SECURITY]    Actual:   ${actualChecksum.substring(0, 16)}...');
      } else {
        print('[SECURITY] ❌ Checksum mismatch for $fileId');
        print('[SECURITY]    Expected: $expectedChecksum');
        print('[SECURITY]    Actual:   $actualChecksum');
      }
      
      return isValid;
      
    } catch (e) {
      print('[SECURITY] Error verifying checksum: $e');
      return false;
    }
  }
  
  /// Verify checksum before starting download (check against server)
  /// 
  /// This is called when receiving a share notification
  Future<bool> verifyChecksumBeforeDownload(String fileId, String expectedChecksum) async {
    try {
      print('[SECURITY] Verifying checksum before download...');
      
      // Get file info from server
      final fileInfo = await _socketFileClient.getFileInfo(fileId);
      final serverChecksum = fileInfo['checksum'] as String?;
      
      if (serverChecksum == null) {
        print('[SECURITY] ⚠️ No checksum from server for $fileId');
        return false;
      }
      
      // Compare Signal message checksum with server checksum
      final isValid = serverChecksum == expectedChecksum;
      
      if (isValid) {
        print('[SECURITY] ✅ Checksum matches server');
        print('[SECURITY]    Expected: ${expectedChecksum.substring(0, 16)}...');
        print('[SECURITY]    Server:   ${serverChecksum.substring(0, 16)}...');
      } else {
        print('[SECURITY] ❌ Checksum mismatch!');
        print('[SECURITY]    From Signal: $expectedChecksum');
        print('[SECURITY]    From Server: $serverChecksum');
        print('[SECURITY]    ⚠️ File may be compromised - download blocked!');
      }
      
      return isValid;
      
    } catch (e) {
      print('[SECURITY] Error verifying checksum: $e');
      return false;
    }
  }
  
  /// Verify individual chunk hash
  /// 
  /// Returns true if chunk hash matches expected hash from metadata
  Future<bool> _verifyChunkHash(String fileId, int chunkIndex) async {
    try {
      final chunk = await _storage.getChunk(fileId, chunkIndex);
      final chunkMetadata = await _storage.getChunkMetadata(fileId, chunkIndex);
      
      if (chunk == null || chunkMetadata == null) {
        print('[FILE TRANSFER] Chunk $chunkIndex missing');
        return false;
      }
      
      // Get expected chunk hash
      final expectedHash = chunkMetadata['chunkHash'] as String?;
      if (expectedHash == null) {
        print('[FILE TRANSFER] Chunk $chunkIndex has no hash metadata');
        // If no hash in metadata, we can't verify - assume valid
        return true;
      }
      
      // Calculate actual hash
      final actualHash = sha256.convert(chunk).toString();
      
      if (actualHash != expectedHash) {
        print('[FILE TRANSFER] ❌ Chunk $chunkIndex hash mismatch');
        print('[FILE TRANSFER]    Expected: ${expectedHash.substring(0, 16)}...');
        print('[FILE TRANSFER]    Actual:   ${actualHash.substring(0, 16)}...');
        return false;
      }
      
      return true;
      
    } catch (e) {
      print('[FILE TRANSFER] Error verifying chunk hash: $e');
      return false;
    }
  }
  
  /// Find corrupted chunks by hashing each chunk individually
  /// 
  /// Returns list of chunk indices that are corrupted
  Future<List<int>> _findCorruptedChunks(String fileId) async {
    try {
      print('[FILE TRANSFER] Analyzing chunks for corruption...');
      
      final metadata = await _storage.getFileMetadata(fileId);
      if (metadata == null) {
        print('[FILE TRANSFER] No metadata found');
        return [];
      }
      
      final chunkCount = metadata['chunkCount'] as int? ?? 0;
      final corruptedChunks = <int>[];
      
      for (int i = 0; i < chunkCount; i++) {
        final chunk = await _storage.getChunk(fileId, i);
        final chunkMetadata = await _storage.getChunkMetadata(fileId, i);
        
        if (chunk == null || chunkMetadata == null) {
          print('[FILE TRANSFER] Chunk $i missing');
          corruptedChunks.add(i);
          continue;
        }
        
        // Get expected chunk hash
        final expectedHash = chunkMetadata['chunkHash'] as String?;
        if (expectedHash == null) {
          print('[FILE TRANSFER] Chunk $i has no hash metadata');
          continue; // Can't verify without hash
        }
        
        // Calculate actual hash
        final actualHash = sha256.convert(chunk).toString();
        
        if (actualHash != expectedHash) {
          print('[FILE TRANSFER] ❌ Chunk $i corrupted (hash mismatch)');
          corruptedChunks.add(i);
        }
      }
      
      print('[FILE TRANSFER] Found ${corruptedChunks.length} corrupted chunks: $corruptedChunks');
      return corruptedChunks;
      
    } catch (e) {
      print('[FILE TRANSFER] Error finding corrupted chunks: $e');
      return [];
    }
  }
  
  /// Smart error recovery - only delete and re-download corrupted chunks
  Future<void> _recoverCorruptedFile(String fileId, List<int> corruptedChunks) async {
    try {
      print('[FILE TRANSFER] Starting smart recovery for $fileId');
      print('[FILE TRANSFER] Re-downloading ${corruptedChunks.length} corrupted chunks...');
      
      // Delete only corrupted chunks
      for (final chunkIndex in corruptedChunks) {
        await _storage.deleteChunk(fileId, chunkIndex);
        print('[FILE TRANSFER] Deleted corrupted chunk $chunkIndex');
      }
      
      // Update metadata to trigger re-download
      final metadata = await _storage.getFileMetadata(fileId);
      if (metadata != null) {
        final downloadedChunks = (metadata['downloadedChunks'] as List?)?.cast<int>() ?? [];
        
        // Remove corrupted chunks from downloaded list
        final updatedChunks = downloadedChunks.where((c) => !corruptedChunks.contains(c)).toList();
        
        await _storage.updateFileMetadata(fileId, {
          'status': 'downloading', // Back to downloading state
          'downloadComplete': false,
          'downloadedChunks': updatedChunks,
          'corruptedChunksFound': corruptedChunks.length,
          'lastRecoveryAttempt': DateTime.now().millisecondsSinceEpoch,
        });
        
        print('[FILE TRANSFER] ✓ Metadata updated, ready for re-download');
      }
      
    } catch (e) {
      print('[FILE TRANSFER] Error during recovery: $e');
      rethrow;
    }
  }
  
  /// Delete corrupted file (all chunks and metadata)
  /// Only used when recovery is not possible
  Future<void> _deleteCorruptedFile(String fileId) async {
    try {
      print('[FILE TRANSFER] Deleting corrupted file: $fileId');
      
      // Delete file using storage interface (handles chunks + metadata)
      await _storage.deleteFile(fileId);
      
      print('[FILE TRANSFER] ✓ Corrupted file deleted');
      
    } catch (e) {
      print('[FILE TRANSFER] Error deleting corrupted file: $e');
    }
  }
  
  // ============================================
  // HIGH #6: DOWNLOAD CANCELLATION
  // ============================================
  
  /// Cancel an active download
  Future<void> cancelDownload(String fileId) async {
    final cancelToken = _activeDownloads[fileId];
    if (cancelToken != null) {
      print('[FILE TRANSFER] Canceling download: $fileId');
      cancelToken.cancel();
      _activeDownloads.remove(fileId);
      
      // Update file metadata to 'canceled'
      try {
        await _storage.updateFileMetadata(fileId, {
          'status': 'canceled',
          'canceledAt': DateTime.now().millisecondsSinceEpoch,
        });
      } catch (e) {
        print('[FILE TRANSFER] Error updating canceled status: $e');
      }
    } else {
      print('[FILE TRANSFER] No active download found for: $fileId');
    }
  }
  
  /// Delete file and all chunks
  Future<void> deleteFile(String fileId) async {
    try {
      print('[FILE TRANSFER] Deleting file: $fileId');
      await _storage.deleteFile(fileId);
      print('[FILE TRANSFER] ✓ File deleted: $fileId');
    } catch (e) {
      print('[FILE TRANSFER] Error deleting file: $e');
      rethrow;
    }
  }
}

/// Cancel token for download operations
class _DownloadCancelToken {
  bool _isCanceled = false;
  
  bool get isCanceled => _isCanceled;
  
  void cancel() {
    _isCanceled = true;
  }
}

/// Exception thrown when download is canceled
class DownloadCanceledException implements Exception {
  final String message;
  DownloadCanceledException([this.message = 'Download was canceled']);
  
  @override
  String toString() => 'DownloadCanceledException: $message';
}

/// Extension for unawaited futures
void unawaited(Future<void> future) {
  // Intentionally empty - just to suppress warnings
}
