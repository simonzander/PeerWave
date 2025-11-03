# Auto-Reannounce Implementation

## 📋 Zusammenfassung

Dieses Dokument beschreibt die vollständige Implementierung des Auto-Reannounce-Systems mit **Seeder-Persistenz** und **Garbage Collection** für das PeerWave P2P File Sharing System.

### ✨ Hauptfeatures

1. **Auto-Reannounce**: Uploader und Seeders werden automatisch wieder verfügbar, wenn sie online kommen
2. **Seeder-Persistenz**: Jeder Seeder (nicht nur Uploader) hält die Datei online
3. **30-Tage Seeder-TTL**: Inaktive Seeders mit unvollständigen Downloads werden nach 30 Tagen entfernt
4. **Complete Seeder Protection**: Seeders mit vollständigen Downloads bleiben permanent (niemals automatisch entfernt)
5. **Uploader-Delete**: Nur der ursprüngliche Uploader kann die Datei für ALLE löschen
6. **Garbage Collection**: Automatisches Cleanup von inaktiven/gelöschten Dateien und Chunks
7. **Storage-Aware**: Prüft verfügbaren Speicher und vermeidet Quota-Probleme

### 🔑 Kern-Regeln

| Regel | Beschreibung | Gilt für |
|-------|-------------|----------|
| **Seeder halten File online** | Solange mind. 1 Seeder existiert, bleibt die Datei verfügbar | Alle Seeders |
| **Uploader kann löschen** | Nur ursprünglicher Uploader kann Share für ALLE löschen | Nur Uploader |
| **30-Tage TTL (incomplete)** | Seeder mit unvollständigem Download werden nach 30 Tagen Inaktivität entfernt | Incomplete Seeders |
| **Permanent (complete)** | Seeder mit vollständigem Download werden NIEMALS automatisch entfernt | Complete Seeders |
| **Chunks cleanup** | Beim Seeder-Removal werden alle Chunks gelöscht | Alle entfernten Seeders |

### 🏗️ Architektur-Übersicht

```
┌─────────────────────────────────────────────────────────────┐
│                    Client (Dart/Flutter)                    │
├─────────────────────────────────────────────────────────────┤
│  FileReannounceService                                      │
│  - onConnect(): Auto-Reannounce on Socket connect          │
│  - deleteShare(): Uploader deletes for everyone            │
│  - updateSeederActivity(): Track chunk uploads             │
├─────────────────────────────────────────────────────────────┤
│  FileGarbageCollector                                       │
│  - runCleanup(): Remove inactive seeders                   │
│  - deleteFile(): Delete file + chunks                      │
│  - getStorageStats(): Monitor storage usage                │
├─────────────────────────────────────────────────────────────┤
│  Storage (IndexedDB / FlutterSecureStorage)                │
│  - files: fileId, uploaderId, isSeeder, lastActivity       │
│  - chunks: encrypted data, IV, hash                        │
└─────────────────────────────────────────────────────────────┘
                              ↕ Socket.IO
┌─────────────────────────────────────────────────────────────┐
│                    Server (Node.js)                         │
├─────────────────────────────────────────────────────────────┤
│  FileRegistry (In-Memory)                                   │
│  - addFile(): Register new file (30-day TTL)               │
│  - reannounceFile(): Add/update seeder                     │
│  - deleteShare(): Uploader deletes (notify all)            │
│  - cleanupExpiredFiles(): Remove expired files             │
│  - cleanupInactiveSeeders(): Remove inactive seeders       │
│  - updateActivity(): Track seeder activity                 │
├─────────────────────────────────────────────────────────────┤
│  Socket.IO Events                                           │
│  - file:check-exists: Check which files still exist        │
│  - file:reannounce: Seeder comes online                    │
│  - file:delete-share: Uploader deletes                     │
│  - file:chunk-uploaded: Track seeder activity              │
│  - file:share-deleted: Notify about deletion               │
│  - file:seeder-removed: Notify about GC removal            │
└─────────────────────────────────────────────────────────────┘
```

## 🎯 Ziel
Wenn der ursprüngliche Uploader einer Datei wieder online kommt, soll diese automatisch wieder als Seeder verfügbar sein, ohne dass der User manuell eingreifen muss.

### Seeder-Persistenz-Regeln

1. **Seeders halten Datei online**: Jeder Seeder (auch nicht-Uploader) hält die Datei aktiv, solange er Chunks hat
2. **Uploader-Kontrolle**: Nur der ursprüngliche Uploader kann die Dateifreigabe explizit löschen
3. **30-Tage Seeder-TTL**: Seeder werden automatisch entfernt, wenn:
   - Kein Download vom Seeder für 30 Tage
   - Datei nie vollständig heruntergeladen wurde
4. **Garbage Collection**: Beim Seeder-Removal werden unvollständige Chunks lokal gelöscht

## 🔄 Flow-Übersicht

```
User Disconnect  →  Server entfernt Seeder  →  File bleibt in Registry (30 Tage)
                                                        ↓
User Reconnect   ←  Client prüft Uploads   ←  Server prüft Registry
                                                        ↓
Client sendet    →  Server aktualisiert    →  Notify Leechers
file:reannounce     Seeder-Liste
```

### Seeder-Lifecycle

```
Upload Complete  →  Seeder Active  →  Serving Downloads  →  lastSeederActivity updated
                         ↓                                           ↓
                   Online/Offline                            30 days no activity?
                         ↓                                           ↓
                   Auto-Reannounce  ←─────────────────────  Garbage Collection
                                                                     ↓
                                                            Delete incomplete chunks
                                                                     ↓
                                                            Remove from seeder list
```

### Uploader Delete Flow

```
Uploader clicks   →  Confirm Dialog  →  file:delete-share event  →  Server removes file
"Delete Share"                                                              ↓
                                                              Notify all seeders/leechers
                                                                     ↓
                                                         All clients: Garbage Collection
```

## 📋 Client-Implementierung

### 1. Storage-Struktur für Uploads

```dart
// Web (IndexedDB)
files: {
  fileId: 'uuid-v4',
  fileName: 'document.pdf',
  fileSize: 1048576,
  mimeType: 'application/pdf',
  checksum: 'sha256-hash',
  chunkCount: 16,
  status: 'uploaded',        // ← Wichtig für Auto-Reannounce
  uploaderId: 'my-user-uuid', // ← Ich bin der Uploader
  createdAt: Date.now(),
  chatType: 'direct',
  chatId: 'recipient-uuid',
  
  // Reannounce-relevante Felder
  autoReannounce: true,       // ← Soll automatisch reannounced werden?
  lastReannounce: Date.now(), // ← Letztes Reannounce
  reannounceCount: 5,         // ← Wie oft bereits reannounced
  
  // Seeder-Status (für Non-Uploader)
  isSeeder: true,                    // ← Bin ich ein Seeder (auch wenn nicht Uploader)?
  lastSeederActivity: Date.now(),    // ← Letzte Download-Aktivität von mir
  seederSince: Date.now(),           // ← Seit wann bin ich Seeder?
  downloadComplete: true,            // ← Habe ich die Datei vollständig?
  
  // Garbage Collection
  markedForDeletion: false,          // ← Soll gelöscht werden?
  deletionReason: null               // ← 'seeder-ttl' | 'uploader-deleted' | 'manual'
}

// Native (FlutterSecureStorage)
'uploaded_files' → JSON([
  { fileId: 'uuid-v4', status: 'uploaded', autoReannounce: true },
  // ...
])

'seeded_files' → JSON([
  { 
    fileId: 'uuid-v4', 
    isSeeder: true, 
    lastSeederActivity: Date.now(),
    downloadComplete: false,
    chunks: [0, 1, 2, 5, 7] // Partial chunks
  },
  // ...
])
```

### 2. FileReannounceService

```dart
// client/lib/services/file_transfer/file_reannounce_service.dart

import 'package:flutter/foundation.dart';
import '../socket_service.dart';
import 'indexeddb_storage.dart'; // Web
import 'secure_storage_manager.dart'; // Native
import 'garbage_collector.dart'; // NEW

class FileReannounceService {
  final SocketService _socketService;
  final IndexedDBStorage? _webStorage; // Web-only
  final SecureStorageManager? _nativeStorage; // Native-only
  final FileGarbageCollector _garbageCollector;
  
  FileReannounceService(this._socketService)
      : _webStorage = kIsWeb ? IndexedDBStorage() : null,
        _nativeStorage = !kIsWeb ? SecureStorageManager() : null,
        _garbageCollector = FileGarbageCollector();
  
  /// Called when Socket.IO connection is established
  Future<void> onConnect() async {
    print('[REANNOUNCE] Socket connected, checking for uploaded files...');
    
    // 1. Run garbage collection first (cleanup old files)
    await _garbageCollector.runCleanup(_getStorage());
    
    // 2. Load all uploaded files
    final uploadedFiles = await _getUploadedFiles();
    
    // 3. Load all seeded files (where I'm a seeder but not uploader)
    final seededFiles = await _getSeededFiles();
    
    final allFiles = [...uploadedFiles, ...seededFiles];
    
    if (allFiles.isEmpty) {
      print('[REANNOUNCE] No uploaded or seeded files found');
      return;
    }
    
    print('[REANNOUNCE] Found ${uploadedFiles.length} uploads, ${seededFiles.length} seeded files');
    
    // 4. Check which files still exist on server
    final fileIds = allFiles.map((f) => f['fileId'] as String).toList();
    final existingFiles = await _checkFilesExist(fileIds);
    
    print('[REANNOUNCE] Server has ${existingFiles.length}/${fileIds.length} files in registry');
    
    // 5. Reannounce existing files
    for (final fileId in existingFiles) {
      final fileData = allFiles.firstWhere((f) => f['fileId'] == fileId);
      
      if (fileData['autoReannounce'] == true) {
        await _reannounceFile(fileId, fileData);
      }
    }
    
    // 6. Cleanup files that no longer exist on server
    final missingFiles = fileIds.where((id) => !existingFiles.contains(id)).toList();
    if (missingFiles.isNotEmpty) {
      print('[REANNOUNCE] Cleaning up ${missingFiles.length} expired files');
      await _cleanupMissingFiles(missingFiles);
    }
  }
  
  /// Get all uploaded files from storage
  Future<List<Map<String, dynamic>>> _getUploadedFiles() async {
    if (kIsWeb) {
      return await _webStorage!.getFilesByStatus('uploaded');
    } else {
      return await _nativeStorage!.getUploadedFiles();
    }
  }
  
  /// Get all seeded files (where I'm a seeder but not uploader)
  Future<List<Map<String, dynamic>>> _getSeededFiles() async {
    if (kIsWeb) {
      return await _webStorage!.getSeededFiles();
    } else {
      return await _nativeStorage!.getSeededFiles();
    }
  }
  
  /// Get storage instance (for garbage collector)
  dynamic _getStorage() {
    return kIsWeb ? _webStorage : _nativeStorage;
  }
  
  /// Check which files still exist on server
  Future<List<String>> _checkFilesExist(List<String> fileIds) async {
    // Batch-Request an Server
    final response = await _socketService.emitWithAck('file:check-exists', {
      'fileIds': fileIds
    });
    
    return List<String>.from(response['exists'] ?? []);
  }
  
  /// Reannounce a single file
  Future<void> _reannounceFile(String fileId, Map<String, dynamic> fileData) async {
    try {
      print('[REANNOUNCE] Reannouncing file: $fileId');
      
      // Get all available chunks
      final chunks = await _getAvailableChunks(fileId);
      
      if (chunks.isEmpty) {
        print('[REANNOUNCE] No chunks available for $fileId, skipping');
        return;
      }
      
      // Send reannounce event
      _socketService.emit('file:reannounce', {
        'fileId': fileId,
        'chunks': chunks,
        'uploadSlots': 6, // Default: 6 parallele Uploads
        'isOriginalUploader': fileData['uploaderId'] != null, // NEW
        'downloadComplete': fileData['downloadComplete'] ?? false // NEW
      });
      
      // Update local storage
      await _updateReannounceTimestamp(fileId);
      
      print('[REANNOUNCE] Successfully reannounced $fileId with ${chunks.length} chunks');
    } catch (e) {
      print('[REANNOUNCE] Error reannouncing $fileId: $e');
    }
  }
  
  /// Handle uploader-initiated file deletion
  Future<void> deleteShare(String fileId) async {
    try {
      print('[REANNOUNCE] Deleting share: $fileId');
      
      // Check if user is original uploader
      final metadata = await _getFileMetadata(fileId);
      if (metadata == null) {
        print('[REANNOUNCE] File not found: $fileId');
        return;
      }
      
      // Only uploader can delete share
      final myUserId = await _socketService.getCurrentUserId();
      if (metadata['uploaderId'] != myUserId) {
        print('[REANNOUNCE] Not authorized to delete share: $fileId');
        throw Exception('Only uploader can delete share');
      }
      
      // Send delete event to server
      _socketService.emit('file:delete-share', {
        'fileId': fileId
      });
      
      // Delete local chunks and metadata
      await _garbageCollector.deleteFile(fileId, _getStorage(), reason: 'uploader-deleted');
      
      print('[REANNOUNCE] Successfully deleted share: $fileId');
    } catch (e) {
      print('[REANNOUNCE] Error deleting share $fileId: $e');
      rethrow;
    }
  }
  
  /// Update seeder activity (called after successful upload to peer)
  Future<void> updateSeederActivity(String fileId) async {
    try {
      if (kIsWeb) {
        await _webStorage!.updateFile(fileId, {
          'lastSeederActivity': DateTime.now().millisecondsSinceEpoch
        });
      } else {
        await _nativeStorage!.updateSeederActivity(fileId);
      }
      
      print('[REANNOUNCE] Updated seeder activity for $fileId');
    } catch (e) {
      print('[REANNOUNCE] Error updating seeder activity: $e');
    }
  }
  
  /// Get list of available chunks for a file
  Future<List<int>> _getAvailableChunks(String fileId) async {
    if (kIsWeb) {
      return await _webStorage!.getCompleteChunks(fileId);
    } else {
      return await _nativeStorage!.getCompleteChunks(fileId);
    }
  }
  
  /// Get file metadata
  Future<Map<String, dynamic>?> _getFileMetadata(String fileId) async {
    if (kIsWeb) {
      return await _webStorage!.getFileMetadata(fileId);
    } else {
      return await _nativeStorage!.getFileMetadata(fileId);
    }
  }
  
  /// Update last reannounce timestamp
  Future<void> _updateReannounceTimestamp(String fileId) async {
    if (kIsWeb) {
      await _webStorage!.updateFile(fileId, {
        'lastReannounce': DateTime.now().millisecondsSinceEpoch,
        'reannounceCount': FieldValue.increment(1)
      });
    } else {
      await _nativeStorage!.updateFileReannounce(fileId);
    }
  }
  
  /// Cleanup files that no longer exist on server
  Future<void> _cleanupMissingFiles(List<String> fileIds) async {
    for (final fileId in fileIds) {
      try {
        await _garbageCollector.deleteFile(fileId, _getStorage(), reason: 'server-expired');
        print('[REANNOUNCE] Cleaned up expired file: $fileId');
      } catch (e) {
        print('[REANNOUNCE] Error cleaning up $fileId: $e');
      }
    }
  }
}
```

### 3. FileGarbageCollector (NEW)

```dart
// client/lib/services/file_transfer/garbage_collector.dart

import 'package:flutter/foundation.dart';
import 'indexeddb_storage.dart';
import 'secure_storage_manager.dart';

class FileGarbageCollector {
  static const int SEEDER_TTL_DAYS = 30;
  
  /// Run full garbage collection
  Future<void> runCleanup(dynamic storage) async {
    print('[GC] Starting garbage collection...');
    
    final now = DateTime.now().millisecondsSinceEpoch;
    final thirtyDaysAgo = now - (SEEDER_TTL_DAYS * 24 * 60 * 60 * 1000);
    
    // Get all seeded files
    final seededFiles = await storage.getSeededFiles();
    
    int cleaned = 0;
    
    for (final file in seededFiles) {
      final fileId = file['fileId'] as String;
      final lastActivity = file['lastSeederActivity'] as int?;
      final downloadComplete = file['downloadComplete'] as bool? ?? false;
      
      // Rule: Delete if no activity for 30 days AND download not complete
      if (lastActivity != null && lastActivity < thirtyDaysAgo && !downloadComplete) {
        print('[GC] Removing inactive seeder: $fileId (last activity: ${_formatDate(lastActivity)})');
        await deleteFile(fileId, storage, reason: 'seeder-ttl');
        cleaned++;
      }
    }
    
    print('[GC] Cleanup complete: removed $cleaned files');
  }
  
  /// Delete file and all associated chunks
  Future<void> deleteFile(String fileId, dynamic storage, {required String reason}) async {
    try {
      print('[GC] Deleting file $fileId (reason: $reason)');
      
      // 1. Get file metadata to check if download is complete
      final metadata = await storage.getFileMetadata(fileId);
      final downloadComplete = metadata?['downloadComplete'] as bool? ?? false;
      
      // 2. Delete all chunks (physical files on native, DB entries on web)
      await storage.deleteChunks(fileId);
      
      // 3. Delete file metadata
      await storage.deleteFile(fileId);
      
      // 4. Remove from seeded_files list
      await storage.removeFromSeededFiles(fileId);
      
      // 5. Remove from uploaded_files list (if present)
      await storage.removeFromUploadedFiles(fileId);
      
      print('[GC] Deleted file $fileId (${downloadComplete ? "complete" : "incomplete"})');
    } catch (e) {
      print('[GC] Error deleting file $fileId: $e');
      rethrow;
    }
  }
  
  /// Delete specific chunks (for partial cleanup)
  Future<void> deleteChunks(String fileId, List<int> chunkIndexes, dynamic storage) async {
    try {
      print('[GC] Deleting ${chunkIndexes.length} chunks from $fileId');
      
      for (final chunkIndex in chunkIndexes) {
        await storage.deleteChunk(fileId, chunkIndex);
      }
      
      print('[GC] Deleted ${chunkIndexes.length} chunks from $fileId');
    } catch (e) {
      print('[GC] Error deleting chunks: $e');
    }
  }
  
  /// Get storage usage statistics
  Future<Map<String, dynamic>> getStorageStats(dynamic storage) async {
    final seededFiles = await storage.getSeededFiles();
    final uploadedFiles = await storage.getUploadedFiles();
    
    int totalChunks = 0;
    int totalBytes = 0;
    int completeFiles = 0;
    int incompleteFiles = 0;
    
    for (final file in [...seededFiles, ...uploadedFiles]) {
      final fileId = file['fileId'] as String;
      final chunks = await storage.getCompleteChunks(fileId);
      final fileSize = file['fileSize'] as int? ?? 0;
      final downloadComplete = file['downloadComplete'] as bool? ?? false;
      
      totalChunks += chunks.length;
      totalBytes += fileSize;
      
      if (downloadComplete) {
        completeFiles++;
      } else {
        incompleteFiles++;
      }
    }
    
    return {
      'totalFiles': seededFiles.length + uploadedFiles.length,
      'completeFiles': completeFiles,
      'incompleteFiles': incompleteFiles,
      'totalChunks': totalChunks,
      'totalBytes': totalBytes,
      'totalMB': (totalBytes / (1024 * 1024)).toStringAsFixed(2)
    };
  }
  
  String _formatDate(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}
```

### 4. Integration in SocketService

```dart
// client/lib/services/socket_service.dart

class SocketService {
  late Socket _socket;
  late FileReannounceService _reannounceService;
  
  void initSocket() {
    _socket = io('http://localhost:4000', <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
    });
    
    // Initialize reannounce service
    _reannounceService = FileReannounceService(this);
    
    // Connection events
    _socket.on('connect', (_) async {
      print('[SOCKET] Connected');
      
      // Authenticate first
      _socket.emit('authenticate');
      
      // Wait for authentication response
      await Future.delayed(Duration(seconds: 1));
      
      // Then trigger auto-reannounce
      await _reannounceService.onConnect();
    });
    
    _socket.on('disconnect', (_) {
      print('[SOCKET] Disconnected');
    });
    
    // File reannounce events
    _socket.on('file:uploader-online', (data) {
      print('[SOCKET] Uploader back online: ${data['fileId']}');
      // Notify UI that seeder is available again
      _handleUploaderOnline(data);
    });
    
    // File deletion event (uploader deleted share)
    _socket.on('file:share-deleted', (data) {
      print('[SOCKET] Share deleted by uploader: ${data['fileId']}');
      _handleShareDeleted(data);
    });
  }
  
  void _handleUploaderOnline(Map<String, dynamic> data) {
    // Notify FileDownloadManager that new seeder is available
    // UI can show notification: "File is now available for download"
  }
  
  void _handleShareDeleted(Map<String, dynamic> data) async {
    final fileId = data['fileId'] as String;
    final reason = data['reason'] as String? ?? 'uploader-deleted';
    
    print('[SOCKET] Deleting file $fileId (reason: $reason)');
    
    // Run garbage collection for this file
    final gc = FileGarbageCollector();
    final storage = kIsWeb ? IndexedDBStorage() : SecureStorageManager();
    
    await gc.deleteFile(fileId, storage, reason: reason);
    
    // Notify UI
    // "File was deleted by uploader"
  }
}
```

## 🖥️ Server-Implementierung

### 1. File Registry Updates

```javascript
// server/store/fileRegistry.js

class FileRegistry {
  constructor() {
    this.files = new Map(); // fileId → FileMetadata
    this.cleanupInterval = null;
  }
  
  /**
   * Initialize file registry with TTL cleanup
   */
  init() {
    // Run cleanup every hour
    this.cleanupInterval = setInterval(() => {
      this.cleanupExpiredFiles();
    }, 60 * 60 * 1000); // 1 hour
    
    console.log('[FILE-REGISTRY] Initialized with 30-day TTL');
  }
  
  /**
   * Add or update file in registry
   */
  addFile(fileId, metadata) {
    const now = Date.now();
    const existingFile = this.files.get(fileId);
    
    const fileData = {
      fileId,
      fileSize: metadata.fileSize,
      checksum: metadata.checksum,
      chunkCount: metadata.chunkCount,
      uploaderId: metadata.uploaderId,
      uploadDeviceId: metadata.uploadDeviceId,
      chatType: metadata.chatType,
      chatId: metadata.chatId,
      
      seeders: existingFile?.seeders || [],
      leechers: existingFile?.leechers || [],
      
      stats: {
        totalDownloads: existingFile?.stats?.totalDownloads || 0,
        totalSeeders: existingFile?.stats?.totalSeeders || 1,
        createdAt: existingFile?.stats?.createdAt || now,
        lastActivity: now,
        lastUploadRequest: now
      },
      
      // 30 Tage TTL
      expiresAt: now + (30 * 24 * 60 * 60 * 1000),
      
      autoReannounce: true,
      originalUploaderId: metadata.uploaderId,
      originalDeviceId: metadata.uploadDeviceId,
      
      // Seeder persistence
      persistBySeeders: true,  // File stays alive as long as seeders exist
      deleted: false           // Uploader-initiated deletion flag
    };
    
    this.files.set(fileId, fileData);
    console.log(`[FILE-REGISTRY] Added file ${fileId} (TTL: 30 days, persist by seeders: true)`);
    
    return fileData;
  }
  
  /**
   * Reannounce file (uploader came back online)
   */
  reannounceFile(fileId, userId, deviceId, chunks, options = {}) {
    const file = this.files.get(fileId);
    
    if (!file) {
      console.log(`[FILE-REGISTRY] Cannot reannounce ${fileId}: not found`);
      return null;
    }
    
    // Check if file was deleted by uploader
    if (file.deleted) {
      console.log(`[FILE-REGISTRY] Cannot reannounce ${fileId}: share was deleted by uploader`);
      return null;
    }
    
    const now = Date.now();
    const isOriginalUploader = file.originalUploaderId === userId;
    const downloadComplete = options.downloadComplete || false;
    
    // Remove old seeder entry if exists
    file.seeders = file.seeders.filter(s => 
      !(s.userId === userId && s.deviceId === deviceId)
    );
    
    // Add as new seeder
    file.seeders.push({
      userId,
      deviceId,
      socketId: null, // Will be set when WebRTC connection established
      chunks,
      uploadSlots: options.uploadSlots || 6,
      activeUploads: 0,
      lastSeen: now,
      lastActivity: now, // NEW: Track last upload activity
      isOriginalUploader,
      downloadComplete,
      seederSince: now
    });
    
    // Update stats
    file.stats.lastActivity = now;
    file.stats.lastUploadRequest = now;
    file.stats.totalSeeders = file.seeders.length;
    
    // Reset TTL (optional - nur wenn File kurz vor Ablauf)
    const timeRemaining = file.expiresAt - now;
    const threeDays = 3 * 24 * 60 * 60 * 1000;
    
    if (timeRemaining < threeDays) {
      file.expiresAt = now + (30 * 24 * 60 * 60 * 1000);
      console.log(`[FILE-REGISTRY] Reset TTL for ${fileId} (was expiring soon)`);
    }
    
    console.log(`[FILE-REGISTRY] Reannounced ${fileId} by ${userId} (uploader: ${isOriginalUploader}, complete: ${downloadComplete}) with ${chunks.length} chunks`);
    
    return file;
  }
  
  /**
   * Check if files exist in registry
   */
  checkFilesExist(fileIds) {
    const exists = [];
    const missing = [];
    
    for (const fileId of fileIds) {
      if (this.files.has(fileId)) {
        exists.push(fileId);
      } else {
        missing.push(fileId);
      }
    }
    
    return { exists, missing };
  }
  
  /**
   * Cleanup expired files (30 days TTL)
   */
  cleanupExpiredFiles() {
    const now = Date.now();
    let cleaned = 0;
    
    for (const [fileId, file] of this.files.entries()) {
      // Rule 1: File deleted by uploader
      if (file.deleted) {
        this.files.delete(fileId);
        cleaned++;
        console.log(`[FILE-REGISTRY] Cleaned up deleted file ${fileId}`);
        continue;
      }
      
      // Rule 2: TTL expired AND no active seeders
      if (now > file.expiresAt && file.seeders.length === 0) {
        this.files.delete(fileId);
        cleaned++;
        console.log(`[FILE-REGISTRY] Cleaned up expired file ${fileId} (no seeders)`);
        continue;
      }
      
      // Rule 3: Inactive seeders (30 days no activity AND incomplete download)
      this.cleanupInactiveSeeders(file);
      
      // Rule 4: File persists if ANY seeder exists (even if TTL expired)
      if (file.seeders.length > 0) {
        // Keep file alive! Seeders hold it online
        console.log(`[FILE-REGISTRY] File ${fileId} kept alive by ${file.seeders.length} seeders`);
      }
    }
    
    if (cleaned > 0) {
      console.log(`[FILE-REGISTRY] Cleanup: removed ${cleaned} expired files`);
    }
  }
  
  /**
   * Remove inactive seeders from a file
   */
  cleanupInactiveSeeders(file) {
    const now = Date.now();
    const thirtyDaysAgo = now - (30 * 24 * 60 * 60 * 1000);
    
    const initialSeederCount = file.seeders.length;
    
    file.seeders = file.seeders.filter(seeder => {
      // Keep seeder if:
      // 1. Download is complete (complete seeders never expire)
      // 2. Last activity within 30 days
      const keepSeeder = 
        seeder.downloadComplete === true || 
        seeder.lastActivity > thirtyDaysAgo;
      
      if (!keepSeeder) {
        console.log(`[FILE-REGISTRY] Removing inactive seeder ${seeder.userId}:${seeder.deviceId} from ${file.fileId} (last activity: ${new Date(seeder.lastActivity).toISOString()})`);
        
        // Notify client to cleanup chunks
        this.notifySeederRemoval(file.fileId, seeder.userId, seeder.deviceId, 'seeder-ttl');
      }
      
      return keepSeeder;
    });
    
    if (file.seeders.length < initialSeederCount) {
      file.stats.totalSeeders = file.seeders.length;
      console.log(`[FILE-REGISTRY] Removed ${initialSeederCount - file.seeders.length} inactive seeders from ${file.fileId}`);
    }
  }
  
  /**
   * Uploader deletes share (removes file for everyone)
   */
  deleteShare(fileId, userId) {
    const file = this.files.get(fileId);
    
    if (!file) {
      console.log(`[FILE-REGISTRY] Cannot delete ${fileId}: not found`);
      return { success: false, error: 'File not found' };
    }
    
    // Only original uploader can delete
    if (file.originalUploaderId !== userId) {
      console.log(`[FILE-REGISTRY] User ${userId} is not authorized to delete ${fileId}`);
      return { success: false, error: 'Not authorized' };
    }
    
    // Mark as deleted
    file.deleted = true;
    file.deletedAt = Date.now();
    file.deletedBy = userId;
    
    console.log(`[FILE-REGISTRY] Share deleted: ${fileId} by ${userId}`);
    
    // Notify all seeders and leechers
    this.notifyShareDeleted(file);
    
    // Remove from registry after notifications sent
    setTimeout(() => {
      this.files.delete(fileId);
      console.log(`[FILE-REGISTRY] Removed deleted file ${fileId} from registry`);
    }, 5000); // 5 second delay for notifications
    
    return { success: true };
  }
  
  /**
   * Notify clients about share deletion
   */
  notifyShareDeleted(file) {
    const notification = {
      fileId: file.fileId,
      reason: 'uploader-deleted',
      deletedBy: file.originalUploaderId,
      timestamp: file.deletedAt
    };
    
    // Notify all seeders
    for (const seeder of file.seeders) {
      const deviceKey = `${seeder.userId}:${seeder.deviceId}`;
      const socketId = deviceSockets.get(deviceKey);
      
      if (socketId) {
        io.to(socketId).emit('file:share-deleted', notification);
      }
    }
    
    // Notify all leechers
    for (const leecher of file.leechers) {
      const deviceKey = `${leecher.userId}:${leecher.deviceId}`;
      const socketId = deviceSockets.get(deviceKey);
      
      if (socketId) {
        io.to(socketId).emit('file:share-deleted', notification);
      }
    }
    
    console.log(`[FILE-REGISTRY] Notified ${file.seeders.length} seeders and ${file.leechers.length} leechers about deletion of ${file.fileId}`);
  }
  
  /**
   * Notify client about seeder removal (for garbage collection)
   */
  notifySeederRemoval(fileId, userId, deviceId, reason) {
    const deviceKey = `${userId}:${deviceId}`;
    const socketId = deviceSockets.get(deviceKey);
    
    if (socketId) {
      io.to(socketId).emit('file:seeder-removed', {
        fileId,
        reason,
        timestamp: Date.now()
      });
      
      console.log(`[FILE-REGISTRY] Notified ${userId}:${deviceId} about seeder removal for ${fileId}`);
    }
  }
  
  /**
   * Update last activity (on download request)
   */
  updateActivity(fileId, userId, deviceId) {
    const file = this.files.get(fileId);
    if (!file) return;
    
    const now = Date.now();
    
    // Update file stats
    file.stats.lastActivity = now;
    
    // Update seeder activity (important for 30-day TTL)
    const seeder = file.seeders.find(s => 
      s.userId === userId && s.deviceId === deviceId
    );
    
    if (seeder) {
      seeder.lastActivity = now;
      console.log(`[FILE-REGISTRY] Updated seeder activity for ${userId}:${deviceId} on ${fileId}`);
    }
  }
  
  /**
   * Remove seeder when disconnected
   */
  removeSeeder(fileId, userId, deviceId) {
    const file = this.files.get(fileId);
    if (!file) return;
    
    file.seeders = file.seeders.filter(s => 
      !(s.userId === userId && s.deviceId === deviceId)
    );
    
    file.stats.totalSeeders = file.seeders.length;
    
    console.log(`[FILE-REGISTRY] Removed seeder ${userId}:${deviceId} from ${fileId}`);
  }
}

module.exports = new FileRegistry();
```

### 2. Socket.IO Event Handler

```javascript
// server/server.js

const fileRegistry = require('./store/fileRegistry');

// Initialize file registry
fileRegistry.init();

io.sockets.on('connection', socket => {
  
  // ... existing events ...
  
  /**
   * Check if files exist in registry
   */
  socket.on('file:check-exists', (data, callback) => {
    try {
      const { fileIds } = data;
      
      if (!Array.isArray(fileIds) || fileIds.length === 0) {
        callback({ error: 'Invalid fileIds' });
        return;
      }
      
      const result = fileRegistry.checkFilesExist(fileIds);
      
      console.log(`[FILE] Check exists: ${result.exists.length} found, ${result.missing.length} missing`);
      
      callback(result);
    } catch (error) {
      console.error('[FILE] Error checking file existence:', error);
      callback({ error: 'Internal error', exists: [], missing: fileIds });
    }
  });
  
  /**
   * Reannounce file (uploader came back online)
   */
  socket.on('file:reannounce', (data) => {
    try {
      const { fileId, chunks, uploadSlots, isOriginalUploader, downloadComplete } = data;
      const userId = socket.handshake.session.uuid;
      const deviceId = socket.handshake.session.deviceId;
      
      if (!userId || !deviceId) {
        console.error('[FILE] Reannounce failed: not authenticated');
        return;
      }
      
      const file = fileRegistry.reannounceFile(fileId, userId, deviceId, chunks, {
        uploadSlots: uploadSlots || 6,
        isOriginalUploader: isOriginalUploader || false,
        downloadComplete: downloadComplete || false
      });
      
      if (!file) {
        console.error(`[FILE] Reannounce failed for ${fileId}`);
        return;
      }
      
      // Notify all users in the chat
      const chatRoom = file.chatType === 'direct' 
        ? `direct:${file.chatId}:${userId}` 
        : `group:${file.chatId}`;
      
      socket.to(chatRoom).emit('file:uploader-online', {
        fileId,
        uploaderId: userId,
        uploadDeviceId: deviceId,
        isOriginalUploader
      });
      
      // Also notify waiting leechers
      for (const leecher of file.leechers) {
        const leecherDeviceKey = `${leecher.userId}:${leecher.deviceId}`;
        const leecherSocketId = deviceSockets.get(leecherDeviceKey);
        
        if (leecherSocketId) {
          io.to(leecherSocketId).emit('file:uploader-online', {
            fileId,
            uploaderId: userId,
            uploadDeviceId: deviceId,
            isOriginalUploader
          });
        }
      }
      
      console.log(`[FILE] Reannounced ${fileId}, notified ${file.leechers.length} leechers`);
    } catch (error) {
      console.error('[FILE] Error reannouncing file:', error);
    }
  });
  
  /**
   * Delete share (uploader only)
   */
  socket.on('file:delete-share', (data, callback) => {
    try {
      const { fileId } = data;
      const userId = socket.handshake.session.uuid;
      
      if (!userId) {
        console.error('[FILE] Delete share failed: not authenticated');
        callback?.({ success: false, error: 'Not authenticated' });
        return;
      }
      
      const result = fileRegistry.deleteShare(fileId, userId);
      
      if (result.success) {
        console.log(`[FILE] Share deleted: ${fileId} by ${userId}`);
      } else {
        console.error(`[FILE] Delete share failed: ${result.error}`);
      }
      
      callback?.(result);
    } catch (error) {
      console.error('[FILE] Error deleting share:', error);
      callback?.({ success: false, error: 'Internal error' });
    }
  });
  
  /**
   * Update seeder activity (called after successful chunk upload)
   */
  socket.on('file:chunk-uploaded', (data) => {
    try {
      const { fileId, chunkIndex } = data;
      const userId = socket.handshake.session.uuid;
      const deviceId = socket.handshake.session.deviceId;
      
      if (!userId || !deviceId) return;
      
      fileRegistry.updateActivity(fileId, userId, deviceId);
      
      console.log(`[FILE] Chunk uploaded: ${fileId}/${chunkIndex} by ${userId}:${deviceId}`);
    } catch (error) {
      console.error('[FILE] Error updating chunk upload:', error);
    }
  });
  
  /**
   * Disconnect handler - remove seeder
   */
  socket.on('disconnect', () => {
    const userId = socket.handshake.session.uuid;
    const deviceId = socket.handshake.session.deviceId;
    
    if (!userId || !deviceId) return;
    
    // Remove user from all files as seeder
    for (const [fileId, file] of fileRegistry.files.entries()) {
      if (file.seeders.some(s => s.userId === userId && s.deviceId === deviceId)) {
        fileRegistry.removeSeeder(fileId, userId, deviceId);
      }
    }
  });
});
```

## 🎨 UI/UX Considerations

### Notification für "Uploader wieder online"

```dart
// client/lib/widgets/file_transfer/uploader_online_notification.dart

class UploaderOnlineNotification extends StatelessWidget {
  final String fileName;
  final VoidCallback onDownload;
  
  const UploaderOnlineNotification({
    required this.fileName,
    required this.onDownload,
    super.key
  });
  
  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.green[50],
      child: ListTile(
        leading: Icon(Icons.cloud_upload, color: Colors.green),
        title: Text('File available'),
        subtitle: Text('$fileName is now available for download'),
        trailing: ElevatedButton(
          onPressed: onDownload,
          child: Text('Download'),
        ),
      ),
    );
  }
}
```

### Status-Anzeige in Chat

```dart
// File-Status-Icons in Chat-Nachricht
enum FileStatus {
  uploading,    // 🔄 Wird gerade hochgeladen
  uploaded,     // ✅ Erfolgreich hochgeladen
  seeding,      // 🌱 Wird gerade geteilt
  downloading,  // ⬇️ Wird heruntergeladen
  complete,     // ✅ Download abgeschlossen
  offline,      // 🔴 Seeder offline (aber in Registry)
  expired,      // ⏰ TTL abgelaufen
}

// In Chat-Nachricht anzeigen:
// "document.pdf (5 MB) 🌱 Seeding"
// "document.pdf (5 MB) 🔴 Offline (expires in 25 days)"
// "document.pdf (5 MB) ✅ Available"
```

### Delete Share Button (Nur für Uploader)

```dart
// client/lib/widgets/file_transfer/file_share_card.dart

class FileShareCard extends StatelessWidget {
  final FileMetadata file;
  final bool isUploader;
  
  const FileShareCard({
    required this.file,
    required this.isUploader,
    super.key
  });
  
  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(Icons.insert_drive_file),
        title: Text(file.fileName),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${_formatFileSize(file.fileSize)} • ${file.seeders.length} seeders'),
            if (isUploader)
              Text('You are the uploader', style: TextStyle(color: Colors.green)),
          ],
        ),
        trailing: isUploader
          ? IconButton(
              icon: Icon(Icons.delete_forever, color: Colors.red),
              tooltip: 'Delete share for everyone',
              onPressed: () => _confirmDeleteShare(context),
            )
          : null,
      ),
    );
  }
  
  Future<void> _confirmDeleteShare(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete Share'),
        content: Text(
          'This will delete the file for ALL users (seeders and downloaders).\n\n'
          'Are you sure?'
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text('Delete for Everyone'),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      await _deleteShare();
    }
  }
  
  Future<void> _deleteShare() async {
    try {
      final socketService = context.read<SocketService>();
      final reannounceService = context.read<FileReannounceService>();
      
      await reannounceService.deleteShare(file.fileId);
      
      // Show success message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Share deleted successfully')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
  
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
```

### Share Deleted Notification

```dart
// client/lib/widgets/file_transfer/share_deleted_notification.dart

class ShareDeletedNotification extends StatelessWidget {
  final String fileName;
  final String deletedBy;
  
  const ShareDeletedNotification({
    required this.fileName,
    required this.deletedBy,
    super.key
  });
  
  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.red[50],
      child: ListTile(
        leading: Icon(Icons.delete_forever, color: Colors.red),
        title: Text('File share deleted'),
        subtitle: Text('$fileName was deleted by the uploader'),
        trailing: IconButton(
          icon: Icon(Icons.close),
          onPressed: () {
            // Dismiss notification
          },
        ),
      ),
    );
  }
}
```

## 📊 Monitoring & Logging

### Server-Logs

```javascript
// Wichtige Log-Events:
[FILE-REGISTRY] Added file abc-123 (TTL: 30 days, persist by seeders: true)
[FILE-REGISTRY] Reannounced abc-123 by user-456 (uploader: true, complete: true) with 16 chunks
[FILE-REGISTRY] Reset TTL for abc-123 (was expiring soon)
[FILE-REGISTRY] Removed seeder user-456:device-789 from abc-123
[FILE-REGISTRY] Removing inactive seeder user-789:device-123 from abc-123 (last activity: 2025-09-27)
[FILE-REGISTRY] File abc-123 kept alive by 2 seeders
[FILE-REGISTRY] Share deleted: abc-123 by user-456
[FILE-REGISTRY] Notified 3 seeders and 1 leechers about deletion of abc-123
[FILE-REGISTRY] Cleanup: removed 3 expired files
[FILE-REGISTRY] File abc-123 expires in 2 days
[FILE-REGISTRY] Updated seeder activity for user-456:device-789 on abc-123
```

### Client-Logs

```dart
[REANNOUNCE] Socket connected, checking for uploaded files...
[GC] Starting garbage collection...
[GC] Removing inactive seeder: def-456 (last activity: 2025-09-01)
[GC] Deleted file def-456 (incomplete)
[GC] Cleanup complete: removed 1 files
[REANNOUNCE] Found 5 uploads, 3 seeded files
[REANNOUNCE] Server has 7/8 files in registry
[REANNOUNCE] Reannouncing file: abc-123
[REANNOUNCE] Successfully reannounced abc-123 with 16 chunks
[REANNOUNCE] Cleaning up 1 expired files
[REANNOUNCE] Cleaned up expired file: old-file-789
[REANNOUNCE] Deleting share: abc-123
[GC] Deleting file abc-123 (reason: uploader-deleted)
[GC] Deleted file abc-123 (complete)
[REANNOUNCE] Successfully deleted share: abc-123
[REANNOUNCE] Updated seeder activity for abc-123
[SOCKET] Share deleted by uploader: abc-123
[SOCKET] Deleting file abc-123 (reason: uploader-deleted)
```

## 🧪 Testing

### Unit Tests

```dart
// test/services/file_reannounce_service_test.dart

void main() {
  group('FileReannounceService', () {
    test('reannounces all uploaded files on connect', () async {
      // Setup
      final storage = MockStorage();
      final socket = MockSocketService();
      final service = FileReannounceService(socket, storage);
      
      storage.addFile('file-1', status: 'uploaded');
      storage.addFile('file-2', status: 'uploaded');
      
      // Act
      await service.onConnect();
      
      // Assert
      expect(socket.emittedEvents, contains('file:check-exists'));
      expect(socket.emittedEvents, contains('file:reannounce'));
    });
    
    test('cleans up files that no longer exist on server', () async {
      // Setup
      final storage = MockStorage();
      final socket = MockSocketService();
      socket.setCheckExistsResponse(['file-1']); // Only file-1 exists
      
      storage.addFile('file-1', status: 'uploaded');
      storage.addFile('file-2', status: 'uploaded'); // Will be cleaned
      
      // Act
      await service.onConnect();
      
      // Assert
      expect(storage.hasFile('file-1'), true);
      expect(storage.hasFile('file-2'), false); // Cleaned up
    });
    
    test('reannounces seeded files (non-uploader)', () async {
      // Setup
      final storage = MockStorage();
      final socket = MockSocketService();
      
      storage.addSeededFile('file-3', 
        isSeeder: true, 
        downloadComplete: false,
        chunks: [0, 1, 2, 3, 4]
      );
      
      socket.setCheckExistsResponse(['file-3']);
      
      // Act
      await service.onConnect();
      
      // Assert
      expect(socket.emittedEvents, contains('file:reannounce'));
      final reannounceData = socket.getEventData('file:reannounce');
      expect(reannounceData['isOriginalUploader'], false);
      expect(reannounceData['downloadComplete'], false);
    });
  });
  
  group('FileGarbageCollector', () {
    test('removes inactive seeders with incomplete downloads', () async {
      // Setup
      final storage = MockStorage();
      final gc = FileGarbageCollector();
      
      // Add file with old lastSeederActivity and incomplete download
      final thirtyOneDaysAgo = DateTime.now().millisecondsSinceEpoch - (31 * 24 * 60 * 60 * 1000);
      storage.addSeededFile('file-old',
        lastSeederActivity: thirtyOneDaysAgo,
        downloadComplete: false
      );
      
      // Act
      await gc.runCleanup(storage);
      
      // Assert
      expect(storage.hasFile('file-old'), false); // Cleaned up
    });
    
    test('keeps seeders with complete downloads', () async {
      // Setup
      final storage = MockStorage();
      final gc = FileGarbageCollector();
      
      // Add file with old activity BUT complete download
      final thirtyOneDaysAgo = DateTime.now().millisecondsSinceEpoch - (31 * 24 * 60 * 60 * 1000);
      storage.addSeededFile('file-complete',
        lastSeederActivity: thirtyOneDaysAgo,
        downloadComplete: true // ← Complete downloads never expire
      );
      
      // Act
      await gc.runCleanup(storage);
      
      // Assert
      expect(storage.hasFile('file-complete'), true); // NOT cleaned up
    });
    
    test('deletes file and chunks on uploader deletion', () async {
      // Setup
      final storage = MockStorage();
      final gc = FileGarbageCollector();
      
      storage.addFile('file-to-delete', status: 'uploaded', chunkCount: 16);
      
      // Act
      await gc.deleteFile('file-to-delete', storage, reason: 'uploader-deleted');
      
      // Assert
      expect(storage.hasFile('file-to-delete'), false);
      expect(storage.chunksExist('file-to-delete'), false);
    });
  });
  
  group('FileReannounceService - Delete Share', () {
    test('uploader can delete share', () async {
      // Setup
      final storage = MockStorage();
      final socket = MockSocketService();
      final service = FileReannounceService(socket, storage);
      
      socket.setCurrentUserId('uploader-1');
      storage.addFile('file-1', status: 'uploaded', uploaderId: 'uploader-1');
      
      // Act
      await service.deleteShare('file-1');
      
      // Assert
      expect(socket.emittedEvents, contains('file:delete-share'));
      expect(storage.hasFile('file-1'), false);
    });
    
    test('non-uploader cannot delete share', () async {
      // Setup
      final storage = MockStorage();
      final socket = MockSocketService();
      final service = FileReannounceService(socket, storage);
      
      socket.setCurrentUserId('user-2'); // Not the uploader
      storage.addFile('file-1', status: 'uploaded', uploaderId: 'uploader-1');
      
      // Act & Assert
      expect(
        () => service.deleteShare('file-1'),
        throwsA(isA<Exception>())
      );
    });
  });
}
```

### Integration Tests

```javascript
// test/integration/file-reannounce.test.js

describe('File Reannounce', () => {
  it('should reannounce file when uploader reconnects', async () => {
    // Setup
    const uploader = createTestClient('uploader-1', 'device-1');
    const leecher = createTestClient('leecher-1', 'device-1');
    
    // Uploader uploads file
    await uploader.emit('file:offer', {
      fileId: 'test-file',
      fileSize: 1048576,
      checksum: 'abc123',
      chunkCount: 16
    });
    
    // Uploader disconnects
    await uploader.disconnect();
    
    // Check file still in registry
    const registry = fileRegistry.get('test-file');
    expect(registry).toBeDefined();
    expect(registry.seeders.length).toBe(0);
    
    // Uploader reconnects
    await uploader.reconnect();
    await uploader.emit('file:reannounce', {
      fileId: 'test-file',
      chunks: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
      isOriginalUploader: true,
      downloadComplete: true
    });
    
    // Check file has seeder again
    const updated = fileRegistry.get('test-file');
    expect(updated.seeders.length).toBe(1);
    expect(updated.seeders[0].userId).toBe('uploader-1');
    expect(updated.seeders[0].downloadComplete).toBe(true);
    
    // Check leecher was notified
    expect(leecher.receivedEvents).toContain('file:uploader-online');
  });
  
  it('should keep file alive with seeders even after TTL', async () => {
    // Setup
    const uploader = createTestClient('uploader-1', 'device-1');
    const seeder1 = createTestClient('seeder-1', 'device-1');
    const seeder2 = createTestClient('seeder-2', 'device-1');
    
    // Upload file
    await uploader.emit('file:offer', {
      fileId: 'test-file',
      fileSize: 1048576,
      checksum: 'abc123',
      chunkCount: 16
    });
    
    // Seeders announce
    await seeder1.emit('file:reannounce', {
      fileId: 'test-file',
      chunks: [0, 1, 2, 3, 4, 5, 6, 7],
      downloadComplete: false
    });
    
    await seeder2.emit('file:reannounce', {
      fileId: 'test-file',
      chunks: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
      downloadComplete: true
    });
    
    // Simulate TTL expiration (set expiresAt to past)
    const file = fileRegistry.get('test-file');
    file.expiresAt = Date.now() - 1000; // Expired 1 second ago
    
    // Run cleanup
    fileRegistry.cleanupExpiredFiles();
    
    // File should still exist (kept alive by seeders)
    expect(fileRegistry.get('test-file')).toBeDefined();
    expect(fileRegistry.get('test-file').seeders.length).toBe(2);
  });
  
  it('should remove inactive seeders with incomplete downloads', async () => {
    // Setup
    const uploader = createTestClient('uploader-1', 'device-1');
    const inactiveSeeder = createTestClient('seeder-1', 'device-1');
    
    // Upload file
    await uploader.emit('file:offer', {
      fileId: 'test-file',
      fileSize: 1048576,
      checksum: 'abc123',
      chunkCount: 16
    });
    
    // Inactive seeder announces
    await inactiveSeeder.emit('file:reannounce', {
      fileId: 'test-file',
      chunks: [0, 1, 2],
      downloadComplete: false
    });
    
    // Simulate 31 days of inactivity
    const file = fileRegistry.get('test-file');
    file.seeders[0].lastActivity = Date.now() - (31 * 24 * 60 * 60 * 1000);
    
    // Run cleanup
    fileRegistry.cleanupExpiredFiles();
    
    // Inactive seeder should be removed
    expect(file.seeders.length).toBe(0);
    
    // Client should be notified
    expect(inactiveSeeder.receivedEvents).toContain('file:seeder-removed');
  });
  
  it('should delete share when uploader requests', async () => {
    // Setup
    const uploader = createTestClient('uploader-1', 'device-1');
    const seeder = createTestClient('seeder-1', 'device-1');
    const leecher = createTestClient('leecher-1', 'device-1');
    
    // Upload file
    await uploader.emit('file:offer', {
      fileId: 'test-file',
      fileSize: 1048576,
      checksum: 'abc123',
      chunkCount: 16
    });
    
    // Seeder announces
    await seeder.emit('file:reannounce', {
      fileId: 'test-file',
      chunks: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
      downloadComplete: true
    });
    
    // Uploader deletes share
    const result = await uploader.emitWithAck('file:delete-share', {
      fileId: 'test-file'
    });
    
    expect(result.success).toBe(true);
    
    // Check all parties notified
    expect(seeder.receivedEvents).toContain('file:share-deleted');
    expect(leecher.receivedEvents).toContain('file:share-deleted');
    
    // File should be marked as deleted
    const file = fileRegistry.get('test-file');
    expect(file.deleted).toBe(true);
    
    // Wait for cleanup
    await sleep(6000);
    
    // File should be removed from registry
    expect(fileRegistry.get('test-file')).toBeUndefined();
  });
  
  it('should prevent non-uploader from deleting share', async () => {
    // Setup
    const uploader = createTestClient('uploader-1', 'device-1');
    const seeder = createTestClient('seeder-1', 'device-1');
    
    // Upload file
    await uploader.emit('file:offer', {
      fileId: 'test-file',
      fileSize: 1048576,
      checksum: 'abc123',
      chunkCount: 16
    });
    
    // Seeder tries to delete (should fail)
    const result = await seeder.emitWithAck('file:delete-share', {
      fileId: 'test-file'
    });
    
    expect(result.success).toBe(false);
    expect(result.error).toBe('Not authorized');
    
    // File should still exist
    expect(fileRegistry.get('test-file')).toBeDefined();
  });
  
  it('should update seeder activity on chunk upload', async () => {
    // Setup
    const seeder = createTestClient('seeder-1', 'device-1');
    
    // Announce as seeder
    await seeder.emit('file:reannounce', {
      fileId: 'test-file',
      chunks: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
      downloadComplete: true
    });
    
    const file = fileRegistry.get('test-file');
    const initialActivity = file.seeders[0].lastActivity;
    
    // Wait 1 second
    await sleep(1000);
    
    // Upload chunk
    await seeder.emit('file:chunk-uploaded', {
      fileId: 'test-file',
      chunkIndex: 5
    });
    
    // Check activity updated
    const updatedActivity = file.seeders[0].lastActivity;
    expect(updatedActivity).toBeGreaterThan(initialActivity);
  });
});
```

## 🚀 Deployment-Checkliste

- [ ] Client: `FileReannounceService` implementiert
- [ ] Client: `FileGarbageCollector` implementiert
- [ ] Client: Integration in `SocketService`
- [ ] Client: Storage-Layer (IndexedDB/SecureStorage) unterstützt `status`, `autoReannounce`, `lastSeederActivity`, `downloadComplete`
- [ ] Client: UI: Delete Share Button (nur für Uploader)
- [ ] Client: UI: Share Deleted Notification
- [ ] Server: `FileRegistry` mit TTL-Cleanup und Seeder-Persistenz
- [ ] Server: Socket-Events `file:check-exists`, `file:reannounce`, `file:delete-share`, `file:chunk-uploaded`
- [ ] Server: Notification-System für `file:uploader-online`, `file:share-deleted`, `file:seeder-removed`
- [ ] Server: Cleanup-Job läuft alle 60 Minuten
- [ ] Tests: Unit-Tests für `FileReannounceService`
- [ ] Tests: Unit-Tests für `FileGarbageCollector`
- [ ] Tests: Integration-Tests für Reannounce-Flow
- [ ] Tests: Integration-Tests für Delete-Share-Flow
- [ ] Tests: Integration-Tests für Seeder-TTL-Cleanup
- [ ] Monitoring: Logs für Reannounce-Events
- [ ] Monitoring: Logs für Garbage-Collection
- [ ] Monitoring: Storage-Usage-Statistiken
- [ ] Documentation: User-Guide für Auto-Reannounce
- [ ] Documentation: User-Guide für Delete Share

## 🎯 Performance-Optimierungen

1. **Batch-Reannounce**: Bei vielen Uploads (>10), verzögere Reannounce um 2-5 Sekunden
2. **Caching**: Speichere `chunk-Verfügbarkeit` in Memory, nicht jedes Mal aus Storage laden
3. **Rate-Limiting**: Max 1 Reannounce pro File alle 60 Sekunden
4. **Lazy-Loading**: Lade nur Metadaten beim Reconnect, Chunks erst bei Bedarf
5. **Incremental GC**: Garbage Collection in kleinen Batches statt alles auf einmal
6. **Background Cleanup**: GC im Web Worker (Web) oder Isolate (Native) ausführen
7. **Chunk-Verification**: Nur bei Bedarf Hash-Checks durchführen, nicht bei jedem Load

## 📝 Offene Fragen

1. **Batch vs. Single**: Soll Reannounce gebatched werden (alle Files auf einmal) oder einzeln?
   - **Empfehlung**: Batch mit Max 10 Files pro Request
   
2. **Retry-Logik**: Was wenn Reannounce fehlschlägt (Network-Error)?
   - **Empfehlung**: Retry mit Exponential Backoff (1s, 2s, 4s, 8s)
   
3. **User-Notification**: Soll User benachrichtigt werden dass Files reannounced wurden?
   - **Empfehlung**: Nur Silent-Reannounce, keine Notification (außer bei Fehler)
   
4. **TTL-Reset**: Soll TTL komplett resetet werden oder nur wenn kurz vor Ablauf?
   - **Empfehlung**: Nur wenn < 3 Tage verbleibend (siehe Implementation)

5. **Complete Seeders**: Sollen Seeders mit kompletten Downloads NIEMALS entfernt werden?
   - **Empfehlung**: ✅ Ja, complete Seeders sind permanent (bis Uploader löscht oder User manuell löscht)

6. **Partial Cleanup**: Sollen bei unvollständigen Downloads nur fehlende Chunks gelöscht werden oder alle?
   - **Empfehlung**: ✅ Alle Chunks löschen (einfacher, verhindert fragmentierten Storage)

7. **Uploader Delete Confirmation**: Soll zweistufige Bestätigung (Dialog + Typed Confirmation)?
   - **Empfehlung**: Nur ein Dialog ausreichend (nicht so kritisch wie Account-Deletion)

8. **GC Schedule**: Wann soll Garbage Collection laufen?
   - **Empfehlung**: 
     - Bei Startup (onConnect)
     - Alle 24 Stunden im Hintergrund
     - Manuell über Settings-Button

9. **Storage Quota**: Was wenn Browser/Device Speicher voll ist?
   - **Empfehlung**: 
     - Prüfe vor Download ob Speicher ausreichend
     - Zeige Warning bei < 100 MB freiem Speicher
     - Automatisches Cleanup ältester unvollständiger Downloads

10. **Seeder Limits**: Max Anzahl simultaner Seeding-Files pro User?
    - **Empfehlung**: Kein Limit, aber UI zeigt Storage-Usage an
