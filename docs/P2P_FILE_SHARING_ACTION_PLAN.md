# P2P File Sharing - Action Plan
## Share-Based Access Control & Partial Download System

**Erstellt:** 30. Oktober 2025  
**Status:** In Planung  
**Priorität:** Hoch

---

## 🎯 Zielstellung

**Kernziele:**
1. Dateien können nur heruntergeladen werden, wenn sie mit einer Gruppe oder einem Nutzer geshared wurden
2. Nutzer können Dateien teilweise downloaden, starten aber parallel seeding
3. Alle Nutzer in `sharedWith` können die Datei ebenfalls teilen
4. Automatisches Re-Announce nach Login
5. Visuelles Feedback über Chunk-Verfügbarkeit (Qualität der Datei)

---

## 📋 Anforderungen (User Stories)

### US-1: Automatisches Announce beim Upload
**Als** Nutzer  
**möchte ich**, dass hochgeladene Dateien automatisch dem Server announced werden  
**damit** andere Nutzer mit Zugriff die Datei herunterladen können

**Akzeptanzkriterien:**
- ✅ Nach erfolgreichem Upload wird `announceFile()` automatisch aufgerufen
- ✅ `sharedWith` enthält initial nur den Creator
- ✅ Metadaten werden in localStorage/IndexedDB gespeichert

### US-2: Re-Announce nach Login
**Als** Nutzer  
**möchte ich**, dass meine hochgeladenen Dateien nach erneutem Login automatisch wieder announced werden  
**damit** ich keine Dateien manuell wieder verfügbar machen muss

**Akzeptanzkriterien:**
- ✅ Beim Login werden alle Dateien mit Status `uploaded` oder `seeding` aus localStorage geladen
- ✅ Für jede Datei wird `announceFile()` mit aktueller Chunk-Liste aufgerufen
- ✅ `sharedWith` wird vom Server wiederhergestellt (bereits vorhanden)

### US-3: sharedWith in Announce-Payload
**Als** System  
**möchte ich**, dass jedes Announce `sharedWith` enthält  
**damit** der Server weiß, wer Zugriff auf die Datei hat

**Akzeptanzkriterien:**
- ✅ `announceFile()` sendet `sharedWith` Array (userIds und/oder channelIds)
- ✅ Server aktualisiert `file.sharedWith` Set
- ✅ Server validiert, dass nur Creator `sharedWith` ändern kann

### US-4: Access Control bei Download
**Als** System  
**möchte ich**, dass Downloads nur mit gültigem `sharedWith` Eintrag möglich sind  
**damit** keine unbefugten Zugriffe stattfinden

**Akzeptanzkriterien:**
- ✅ `getFileInfo()` prüft `canAccess(userId, fileId)`
- ✅ `getAvailableChunks()` prüft `canAccess(userId, fileId)`
- ✅ `registerLeecher()` prüft `canAccess(userId, fileId)`
- ✅ Bei Zugriffsverweigerung: Fehlermeldung "Access denied"

### US-5: Signal Message für sharedWith Updates
**Als** Nutzer  
**möchte ich**, dass alle betroffenen Nutzer über Änderungen in `sharedWith` informiert werden  
**damit** ich sofort weiß, wenn mir Zugriff gewährt oder entzogen wird

**Akzeptanzkriterien:**
- ✅ Bei `shareFile()`: Signal-Nachricht an Ziel-Nutzer
- ✅ Bei `unshareFile()`: Signal-Nachricht an Ziel-Nutzer
- ✅ Nachricht enthält: fileId, fileName (verschlüsselt), fromUserId, action
- ✅ Empfänger aktualisiert lokale Metadaten

### US-6: Lokale Metadaten-Updates via Signal
**Als** Nutzer  
**möchte ich**, dass meine lokalen Metadaten automatisch aktualisiert werden  
**damit** ich immer die aktuellen Zugriffsinformationen habe

**Akzeptanzkriterien:**
- ✅ Beim Empfang von "fileShared" Signal: Metadaten aktualisieren
- ✅ Beim Empfang von "fileUnshared" Signal: Metadaten aktualisieren
- ✅ Nur Nutzer mit bereits heruntergeladener/laufender Datei reagieren
- ✅ Andere Nutzer verwerfen die Nachricht

### US-7: Seeding während Download
**Als** Nutzer  
**möchte ich**, dass ich bereits heruntergeladene Chunks sofort teilen kann  
**damit** andere Nutzer schneller downloaden können

**Akzeptanzkriterien:**
- ✅ Nach jedem erfolgreich heruntergeladenen Chunk: `updateAvailableChunks()`
- ✅ Status wechselt von `downloading` zu `seeding` sobald erster Chunk da ist
- ✅ Andere Leecher können Chunks von mir anfragen

### US-8: Visueller Chunk-Status Indikator
**Als** Downloader  
**möchte ich** sehen, ob alle Chunks verfügbar sind  
**damit** ich entscheiden kann, ob ich den Download starte

**Akzeptanzkriterien:**
- ✅ UI zeigt "Chunk Quality" an (z.B. "15/16 Chunks verfügbar")
- ✅ Farbcodierung: Grün (100%), Gelb (>80%), Rot (<80%)
- ✅ Real-time Updates bei Seeder-Changes
- ✅ Tooltip mit Details (welche Chunks fehlen)

### US-9: Partieller Download
**Als** Nutzer  
**möchte ich** Dateien auch dann downloaden können, wenn nicht alle Chunks verfügbar sind  
**damit** ich zumindest einen Teil der Datei nutzen kann

**Akzeptanzkriterien:**
- ✅ Download startet auch bei <100% Chunk-Verfügbarkeit
- ✅ Warnung: "Datei unvollständig - Download fortsetzen?"
- ✅ Heruntergeladene Chunks werden markiert
- ✅ Bei Verfügbarkeit fehlender Chunks: Auto-Resume

### US-10: Auto-Resume nach Login
**Als** Nutzer  
**möchte ich**, dass unvollständige Downloads nach Login fortgesetzt werden  
**damit** ich keine Downloads manuell neu starten muss

**Akzeptanzkriterien:**
- ✅ Beim Login: Prüfung aller Dateien mit Status `downloading`
- ✅ Für jede unvollständige Datei: Verfügbarkeit prüfen
- ✅ Bei verfügbaren Chunks: Download automatisch fortsetzen
- ✅ UI-Benachrichtigung: "Fortsetze Download von X Dateien"

### US-11: Socket.listen für neue Announces
**Als** Nutzer  
**möchte ich** benachrichtigt werden, wenn Chunks für meine unvollständigen Downloads verfügbar werden  
**damit** ich den Download fortsetzen kann

**Akzeptanzkriterien:**
- ✅ `onFileAnnounced()` Listener prüft lokale Downloads
- ✅ Bei Match: Prüfung ob neue Chunks verfügbar
- ✅ Bei neuen Chunks: Auto-Resume des Downloads
- ✅ UI-Benachrichtigung: "Neue Chunks verfügbar für file.pdf"
- ✅ **Seeder wird automatisch zu sharedWith hinzugefügt beim Announce** ← NEU
- ✅ **Auto-Resume auch bei Announce-Events (nicht nur seederUpdate)** ← NEU

### US-12: Callback nur für sharedWith Nutzer
**Als** System  
**möchte ich**, dass Announce-Callbacks nur an autorisierte Nutzer gehen  
**damit** keine Privacy-Leaks entstehen

**Akzeptanzkriterien:**
- ✅ Server filtert Sockets nach `userId in sharedWith`
- ✅ Nur gefilterte Sockets erhalten `fileAnnounced` Event
- ✅ Event enthält KEINE fileName/mimeType (Privacy!)
- ✅ Logging: "Notified X authorized users"

---

## 🏗️ Technische Änderungen

### Backend (Server)

#### 1. File Registry Updates (`server/store/fileRegistry.js`)

**Änderung 1.1: sharedWith Management in announceFile()**
```javascript
announceFile(userId, deviceId, fileMetadata) {
  const { fileId, mimeType, fileSize, checksum, chunkCount, availableChunks, sharedWith } = fileMetadata;
  // ...existing code...
  
  if (!file) {
    // New file
    file = {
      fileId,
      mimeType,
      fileSize,
      checksum,
      chunkCount,
      creator: userId,
      sharedWith: new Set(sharedWith || [userId]), // ← NEU: Merge mit Payload
      createdAt: Date.now(),
      lastActivity: Date.now(),
      seeders: new Set(),
      leechers: new Set(),
      totalSeeds: 0,
      totalDownloads: 0,
    };
  } else {
    // Existing file - Update sharedWith
    
    // ← NEU: Seeder wird automatisch zu sharedWith hinzugefügt
    file.sharedWith.add(userId);
    
    // Wenn vom Creator: Merge mit payload sharedWith
    if (file.creator === userId && sharedWith) {
      sharedWith.forEach(id => file.sharedWith.add(id));
    }
    
    file.lastActivity = Date.now();
  }
  
  // ...rest of existing code...
}
```

**Wichtig:** Jeder Seeder wird automatisch zu `sharedWith` hinzugefügt, damit:
- Seeder kann File-Info abrufen
- Seeder kann eigene Chunks sehen
- Seeder wird bei Updates benachrichtigt

**Änderung 1.2: Chunk-Quality-Berechnung**
```javascript
/**
 * Calculate chunk availability quality
 * Returns percentage of available chunks (0-100)
 */
getChunkQuality(fileId) {
  const file = this.files.get(fileId);
  if (!file) return 0;
  
  // Collect all unique chunks from all seeders
  const availableChunks = new Set();
  
  if (file.seederChunks) {
    for (const chunks of file.seederChunks.values()) {
      chunks.forEach(idx => availableChunks.add(idx));
    }
  }
  
  const quality = (availableChunks.size / file.chunkCount) * 100;
  return Math.round(quality);
}

/**
 * Get missing chunk indices
 */
getMissingChunks(fileId) {
  const file = this.files.get(fileId);
  if (!file) return [];
  
  const availableChunks = new Set();
  
  if (file.seederChunks) {
    for (const chunks of file.seederChunks.values()) {
      chunks.forEach(idx => availableChunks.add(idx));
    }
  }
  
  const missing = [];
  for (let i = 0; i < file.chunkCount; i++) {
    if (!availableChunks.has(i)) {
      missing.push(i);
    }
  }
  
  return missing;
}
```

#### 2. Socket Event Updates (`server/server.js`)

**Änderung 2.1: announceFile mit sharedWith**
```javascript
socket.on("announceFile", async (data, callback) => {
  try {
    if (!socket.handshake.session.uuid || !socket.handshake.session.deviceId) {
      return callback?.({ success: false, error: "Not authenticated" });
    }

    const userId = socket.handshake.session.uuid;
    const deviceId = socket.handshake.session.deviceId;
    const { fileId, mimeType, fileSize, checksum, chunkCount, availableChunks, sharedWith } = data;

    console.log(`[P2P FILE] Device ${userId}:${deviceId} announcing file: ${fileId.substring(0, 16)}...`);
    console.log(`[P2P FILE] Shared with: ${sharedWith ? sharedWith.join(', ') : 'only creator'}`);

    // Register file with sharedWith
    const fileInfo = fileRegistry.announceFile(userId, deviceId, {
      fileId,
      mimeType,
      fileSize,
      checksum,
      chunkCount,
      availableChunks,
      sharedWith // ← NEU
    });

    callback?.({ success: true, fileInfo });

    // LÖSUNG 12: Notify only authorized users (from sharedWith)
    const authorizedUsers = fileRegistry.getSharedUsers(fileId);
    console.log(`[P2P FILE] Notifying ${authorizedUsers.length} authorized users about file announcement`);
    
    const targetSockets = Array.from(io.sockets.sockets.values())
      .filter(s => 
        s.handshake.session?.uuid && 
        authorizedUsers.includes(s.handshake.session.uuid) &&
        s.id !== socket.id
      );
    
    targetSockets.forEach(targetSocket => {
      targetSocket.emit("fileAnnounced", {
        fileId,
        userId,
        deviceId,
        mimeType,
        fileSize,
        seederCount: fileInfo.seederCount,
        chunkQuality: fileRegistry.getChunkQuality(fileId) // ← NEU
      });
    });

  } catch (error) {
    console.error('[P2P FILE] Error announcing file:', error);
    callback?.({ success: false, error: error.message });
  }
});
```

**Änderung 2.2: getFileInfo mit Quality**
```javascript
socket.on("getFileInfo", async (data, callback) => {
  try {
    if (!socket.handshake.session.uuid) {
      return callback?.({ success: false, error: "Not authenticated" });
    }

    const userId = socket.handshake.session.uuid;
    const { fileId } = data;
    
    // Permission Check
    if (!fileRegistry.canAccess(userId, fileId)) {
      console.log(`[P2P FILE] User ${userId} denied access to file ${fileId}`);
      return callback?.({ success: false, error: "Access denied" });
    }

    const fileInfo = fileRegistry.getFileInfo(fileId);
    if (!fileInfo) {
      return callback?.({ success: false, error: "File not found" });
    }
    
    // Add quality info
    fileInfo.chunkQuality = fileRegistry.getChunkQuality(fileId);
    fileInfo.missingChunks = fileRegistry.getMissingChunks(fileId);
    
    callback?.({ success: true, fileInfo });
    
  } catch (error) {
    console.error('[P2P FILE] Error getting file info:', error);
    callback?.({ success: false, error: error.message });
  }
});
```

**Änderung 2.3: updateAvailableChunks mit Broadcast**
```javascript
socket.on("updateAvailableChunks", async (data, callback) => {
  try {
    if (!socket.handshake.session.uuid || !socket.handshake.session.deviceId) {
      return callback?.({ success: false, error: "Not authenticated" });
    }

    const userId = socket.handshake.session.uuid;
    const deviceId = socket.handshake.session.deviceId;
    const { fileId, availableChunks } = data;

    console.log(`[P2P FILE] Device ${userId}:${deviceId} updating chunks for ${fileId}: ${availableChunks.length} chunks`);

    const success = fileRegistry.updateAvailableChunks(userId, deviceId, fileId, availableChunks);
    
    if (!success) {
      return callback?.({ success: false, error: "File not found" });
    }

    callback?.({ success: true });

    // Notify authorized users about chunk update
    const authorizedUsers = fileRegistry.getSharedUsers(fileId);
    const fileInfo = fileRegistry.getFileInfo(fileId);
    const chunkQuality = fileRegistry.getChunkQuality(fileId);
    
    const targetSockets = Array.from(io.sockets.sockets.values())
      .filter(s => 
        s.handshake.session?.uuid && 
        authorizedUsers.includes(s.handshake.session.uuid) &&
        s.id !== socket.id
      );
    
    targetSockets.forEach(targetSocket => {
      targetSocket.emit("fileSeederUpdate", {
        fileId,
        seederCount: fileInfo.seederCount,
        chunkQuality // ← NEU: Quality update
      });
    });

  } catch (error) {
    console.error('[P2P FILE] Error updating chunks:', error);
    callback?.({ success: false, error: error.message });
  }
});
```

---

### Frontend (Client)

#### 3. Socket Client Updates (`client/lib/services/file_transfer/socket_file_client.dart`)

**Änderung 3.1: announceFile mit sharedWith**
```dart
/// Announce a file with shared users/channels
Future<Map<String, dynamic>> announceFile({
  required String fileId,
  required String mimeType,
  required int fileSize,
  required String checksum,
  required int chunkCount,
  required List<int> availableChunks,
  List<String>? sharedWith, // ← NEU: Optional (default: nur creator)
}) async {
  final completer = Completer<Map<String, dynamic>>();
  
  socket.emitWithAck('announceFile', {
    'fileId': fileId,
    'mimeType': mimeType,
    'fileSize': fileSize,
    'checksum': checksum,
    'chunkCount': chunkCount,
    'availableChunks': availableChunks,
    'sharedWith': sharedWith, // ← NEU
  }, ack: (data) {
    if (data['success'] == true) {
      debugPrint('[FILE CLIENT] ✓ File announced with quality: ${data['fileInfo']?['chunkQuality'] ?? 0}%');
      completer.complete(data);
    } else {
      completer.completeError(data['error'] ?? 'Unknown error');
    }
  });
  
  return completer.future;
}
```

**Änderung 3.2: Listen for Chunk Quality Updates**
```dart
/// Listen for seeder and quality updates
void onFileSeederUpdate(Function(Map<String, dynamic>) callback) {
  _addEventListener('fileSeederUpdate', callback);
}

void _setupEventListeners() {
  // ...existing code...
  
  socket.on('fileSeederUpdate', (data) {
    debugPrint('[FILE CLIENT] Seeder update: ${data['fileId']} - Quality: ${data['chunkQuality']}%');
    _notifyListeners('fileSeederUpdate', data);
  });
}
```

#### 4. File Transfer Service Updates (`client/lib/services/file_transfer/file_transfer_service.dart`)

**Änderung 4.1: Auto-Announce nach Upload**
```dart
/// Upload file and automatically announce
Future<String> uploadAndAnnounceFile({
  required Uint8List fileBytes,
  required String fileName,
  required String mimeType,
  List<String>? sharedWith, // ← NEU: Optional share list
}) async {
  try {
    // Step 1: Upload (existing code)
    final fileId = _generateFileId();
    final checksum = await _calculateChecksum(fileBytes);
    
    // Step 2: Chunk and encrypt
    final chunks = await _chunkFile(fileBytes);
    final encryptedChunks = await _encryptChunks(chunks, fileId);
    
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
      'uploaderId': await _socketService.getCurrentUserId(),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'sharedWith': sharedWith ?? [], // ← NEU: Store locally
    });
    
    for (int i = 0; i < encryptedChunks.length; i++) {
      await _storage.saveChunk(fileId, i, encryptedChunks[i]);
    }
    
    // Step 4: AUTO-ANNOUNCE ← NEU
    print('[FILE TRANSFER] Auto-announcing file: $fileId');
    await _socketFileClient.announceFile(
      fileId: fileId,
      mimeType: mimeType,
      fileSize: fileBytes.length,
      checksum: checksum,
      chunkCount: chunks.length,
      availableChunks: List.generate(chunks.length, (i) => i),
      sharedWith: sharedWith, // ← NEU
    );
    
    print('[FILE TRANSFER] ✓ Upload complete and announced: $fileId');
    return fileId;
    
  } catch (e) {
    print('[FILE TRANSFER] Error in uploadAndAnnounceFile: $e');
    rethrow;
  }
}
```

**Änderung 4.2: Re-Announce beim Login**
```dart
/// Re-announce all uploaded files after login
/// Call this in app initialization after socket connects
Future<void> reannounceUploadedFiles() async {
  try {
    print('[FILE TRANSFER] Re-announcing uploaded files...');
    
    // Get all files with status 'uploaded' or 'seeding'
    final allFiles = await _storage.getAllFileMetadata();
    final uploadedFiles = allFiles.where((file) => 
      file['status'] == 'uploaded' || file['status'] == 'seeding'
    ).toList();
    
    print('[FILE TRANSFER] Found ${uploadedFiles.length} files to re-announce');
    
    for (final file in uploadedFiles) {
      final fileId = file['fileId'] as String;
      
      // Get available chunks
      final availableChunks = await _storage.getAvailableChunkIndices(fileId);
      
      if (availableChunks.isEmpty) {
        print('[FILE TRANSFER] Warning: No chunks found for $fileId, skipping');
        continue;
      }
      
      // Re-announce with sharedWith
      final sharedWith = List<String>.from(file['sharedWith'] ?? []);
      
      print('[FILE TRANSFER] Re-announcing: $fileId (${availableChunks.length} chunks)');
      
      await _socketFileClient.announceFile(
        fileId: fileId,
        mimeType: file['mimeType'] as String,
        fileSize: file['fileSize'] as int,
        checksum: file['checksum'] as String,
        chunkCount: file['chunkCount'] as int,
        availableChunks: availableChunks,
        sharedWith: sharedWith.isNotEmpty ? sharedWith : null,
      );
      
      // Update status
      await _storage.updateFileMetadata(fileId, {
        'status': 'seeding',
        'lastAnnounceTime': DateTime.now().millisecondsSinceEpoch,
      });
    }
    
    print('[FILE TRANSFER] ✓ Re-announce complete');
    
  } catch (e) {
    print('[FILE TRANSFER] Error re-announcing files: $e');
  }
}
```

**Änderung 4.3: Partial Download Support**
```dart
/// Download file with partial download support
Future<void> downloadFile({
  required String fileId,
  required Function(double) onProgress,
  bool allowPartial = true, // ← NEU: Allow incomplete downloads
}) async {
  try {
    print('[FILE TRANSFER] Starting download: $fileId (partial: $allowPartial)');
    
    // Step 1: Get file info and check quality
    final fileInfo = await _socketFileClient.getFileInfo(fileId);
    final chunkQuality = fileInfo['chunkQuality'] as int? ?? 0;
    
    print('[FILE TRANSFER] Chunk quality: $chunkQuality%');
    
    // Step 2: Warn if incomplete
    if (chunkQuality < 100 && !allowPartial) {
      throw Exception('File incomplete (${chunkQuality}% available). Enable partial downloads.');
    }
    
    // Step 3: Register as leecher
    await _socketFileClient.registerLeecher(fileId);
    
    // Step 4: Get available chunks from seeders
    final seeders = await _socketFileClient.getAvailableChunks(fileId);
    
    // Step 5: Download available chunks
    final downloadedChunks = <int, Uint8List>{};
    final totalChunks = fileInfo['chunkCount'] as int;
    
    for (int i = 0; i < totalChunks; i++) {
      // Check if chunk is available from any seeder
      final hasChunk = seeders.values.any((seeder) => seeder.chunks.contains(i));
      
      if (!hasChunk) {
        print('[FILE TRANSFER] Chunk $i not available, skipping');
        continue;
      }
      
      // Download chunk
      final chunk = await _downloadChunkFromSeeders(fileId, i, seeders);
      if (chunk != null) {
        downloadedChunks[i] = chunk;
        
        // Store chunk
        await _storage.saveChunk(fileId, i, chunk);
        
        // Update available chunks and START SEEDING ← NEU
        await _socketFileClient.updateAvailableChunks(
          fileId, 
          downloadedChunks.keys.toList(),
        );
        
        // Update progress
        onProgress(downloadedChunks.length / totalChunks);
      }
    }
    
    // Step 6: Update status
    final isComplete = downloadedChunks.length == totalChunks;
    await _storage.updateFileMetadata(fileId, {
      'status': isComplete ? 'complete' : 'partial',
      'downloadComplete': isComplete,
      'isSeeder': true, // ← Already seeding
      'downloadedChunks': downloadedChunks.keys.toList(),
    });
    
    if (isComplete) {
      print('[FILE TRANSFER] ✓ Download complete: $fileId');
    } else {
      print('[FILE TRANSFER] ⚠ Partial download: $fileId (${downloadedChunks.length}/$totalChunks chunks)');
    }
    
  } catch (e) {
    print('[FILE TRANSFER] Error downloading file: $e');
    rethrow;
  }
}
```

**Änderung 4.4: Auto-Resume Incomplete Downloads**
```dart
/// Resume incomplete downloads after login
Future<void> resumeIncompleteDownloads() async {
  try {
    print('[FILE TRANSFER] Checking for incomplete downloads...');
    
    final allFiles = await _storage.getAllFileMetadata();
    final incompleteFiles = allFiles.where((file) => 
      file['status'] == 'downloading' || file['status'] == 'partial'
    ).toList();
    
    print('[FILE TRANSFER] Found ${incompleteFiles.length} incomplete downloads');
    
    for (final file in incompleteFiles) {
      final fileId = file['fileId'] as String;
      
      // Check if file still exists on server
      try {
        final fileInfo = await _socketFileClient.getFileInfo(fileId);
        final chunkQuality = fileInfo['chunkQuality'] as int? ?? 0;
        
        if (chunkQuality > 0) {
          print('[FILE TRANSFER] Resuming download: $fileId (quality: $chunkQuality%)');
          
          // Resume download in background
          downloadFile(
            fileId: fileId,
            onProgress: (progress) {
              print('[FILE TRANSFER] Resume progress for $fileId: ${(progress * 100).toInt()}%');
            },
            allowPartial: true,
          ).catchError((e) {
            print('[FILE TRANSFER] Error resuming $fileId: $e');
          });
        } else {
          print('[FILE TRANSFER] No chunks available for $fileId, skipping');
        }
      } catch (e) {
        print('[FILE TRANSFER] File $fileId not found on server, cleaning up');
        // Optionally: Delete local chunks
      }
    }
    
  } catch (e) {
    print('[FILE TRANSFER] Error resuming downloads: $e');
  }
}
```

**Änderung 4.5: Listen for Announce Updates (mit Auto-Resume)**
```dart
/// Setup listener for new file announcements (for resume)
void setupAnnounceListener() {
  // ← NEU: Gemeinsame Resume-Logik für beide Events
  Future<void> _checkAndResumeDownload(String fileId, int chunkQuality) async {
    // Check if we have this file as incomplete download
    final metadata = await _storage.getFileMetadata(fileId);
    if (metadata != null && 
        (metadata['status'] == 'downloading' || metadata['status'] == 'partial')) {
      
      print('[FILE TRANSFER] Found incomplete download for $fileId, checking for new chunks');
      
      // Get our downloaded chunks
      final ourChunks = List<int>.from(metadata['downloadedChunks'] ?? []);
      final totalChunks = metadata['chunkCount'] as int;
      
      if (ourChunks.length < totalChunks) {
        // Check if new chunks are actually available
        try {
          final fileInfo = await _socketFileClient.getFileInfo(fileId);
          final availableChunks = _getAvailableChunksFromSeeders(fileInfo['seederChunks']);
          
          // Check if there are chunks we don't have yet
          final newChunks = availableChunks.where((idx) => !ourChunks.contains(idx)).toList();
          
          if (newChunks.isNotEmpty) {
            print('[FILE TRANSFER] Found ${newChunks.length} new chunks, auto-resuming download for $fileId');
            
            // Resume download
            downloadFile(
              fileId: fileId,
              onProgress: (progress) {
                print('[FILE TRANSFER] Auto-resume progress: ${(progress * 100).toInt()}%');
              },
              allowPartial: true,
            ).catchError((e) {
              print('[FILE TRANSFER] Error auto-resuming: $e');
            });
          } else {
            print('[FILE TRANSFER] No new chunks available yet for $fileId');
          }
        } catch (e) {
          print('[FILE TRANSFER] Error checking new chunks: $e');
        }
      }
    }
  }
  
  // ← NEU: Beide Events nutzen gleiche Logik
  _socketFileClient.onFileAnnounced((data) async {
    final fileId = data['fileId'] as String;
    final chunkQuality = data['chunkQuality'] as int? ?? 0;
    
    print('[FILE TRANSFER] File announced: $fileId (quality: $chunkQuality%)');
    await _checkAndResumeDownload(fileId, chunkQuality);
  });
  
  _socketFileClient.onFileSeederUpdate((data) async {
    final fileId = data['fileId'] as String;
    final chunkQuality = data['chunkQuality'] as int? ?? 0;
    
    print('[FILE TRANSFER] Seeder update: $fileId (quality: $chunkQuality%)');
    await _checkAndResumeDownload(fileId, chunkQuality);
  });
}

/// Helper: Extract available chunks from seeder map
List<int> _getAvailableChunksFromSeeders(Map<String, dynamic>? seederChunks) {
  if (seederChunks == null) return [];
  
  final availableChunks = <int>{};
  for (final chunks in seederChunks.values) {
    if (chunks is List) {
      availableChunks.addAll(List<int>.from(chunks));
    }
  }
  
  return availableChunks.toList()..sort();
}
```

#### 5. Signal Integration (`client/lib/services/signal/signal_service.dart`)

**Änderung 5.1: Share Update Messages**
```dart
/// Send file share update message
Future<void> sendFileShareUpdate({
  required String fileId,
  required String targetUserId,
  required String action, // 'shared' or 'unshared'
  required Map<String, dynamic> fileMetadata,
}) async {
  try {
    // Encrypt file metadata for Signal message
    final encryptedMetadata = await _encryptForUser(
      targetUserId, 
      jsonEncode(fileMetadata),
    );
    
    // Send Signal message
    await _signalClient.sendMessage(
      recipientId: targetUserId,
      message: jsonEncode({
        'type': 'file_share_update',
        'action': action,
        'fileId': fileId,
        'metadata': encryptedMetadata,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    
    print('[SIGNAL] Sent file share update to $targetUserId: $action');
    
  } catch (e) {
    print('[SIGNAL] Error sending file share update: $e');
    rethrow;
  }
}

/// Handle incoming file share updates
void _handleFileShareUpdate(Map<String, dynamic> message) async {
  try {
    final action = message['action'] as String;
    final fileId = message['fileId'] as String;
    final encryptedMetadata = message['metadata'] as String;
    
    // Decrypt metadata
    final metadataJson = await _decryptMessage(encryptedMetadata);
    final metadata = jsonDecode(metadataJson);
    
    print('[SIGNAL] Received file share update: $action for $fileId');
    
    // Check if we have this file (downloaded or downloading)
    final localMetadata = await _fileStorage.getFileMetadata(fileId);
    
    if (localMetadata == null) {
      print('[SIGNAL] File $fileId not found locally, ignoring update');
      return; // Discard message
    }
    
    // Update local metadata
    if (action == 'shared') {
      await _fileStorage.updateFileMetadata(fileId, {
        'sharedWith': metadata['sharedWith'],
        'lastShareUpdate': DateTime.now().millisecondsSinceEpoch,
      });
      
      // Show notification
      _showNotification('File shared', 'You now have access to ${metadata['fileName']}');
      
    } else if (action == 'unshared') {
      await _fileStorage.updateFileMetadata(fileId, {
        'sharedWith': metadata['sharedWith'],
        'accessRevoked': true,
        'lastShareUpdate': DateTime.now().millisecondsSinceEpoch,
      });
      
      // Show notification
      _showNotification('Access revoked', 'Your access to ${metadata['fileName']} has been revoked');
    }
    
  } catch (e) {
    print('[SIGNAL] Error handling file share update: $e');
  }
}
```

#### 6. UI Updates (`client/lib/screens/file_transfer/file_manager_screen.dart`)

**Änderung 6.1: Chunk Quality Indicator**
```dart
/// Build chunk quality indicator
Widget _buildChunkQualityIndicator(Map<String, dynamic> file) {
  final chunkQuality = file['chunkQuality'] as int? ?? 0;
  final missingChunks = List<int>.from(file['missingChunks'] ?? []);
  
  Color qualityColor;
  String qualityText;
  
  if (chunkQuality == 100) {
    qualityColor = Colors.green;
    qualityText = 'Complete';
  } else if (chunkQuality >= 80) {
    qualityColor = Colors.orange;
    qualityText = 'Mostly Available';
  } else {
    qualityColor = Colors.red;
    qualityText = 'Incomplete';
  }
  
  return Tooltip(
    message: missingChunks.isEmpty 
      ? 'All chunks available'
      : 'Missing chunks: ${missingChunks.take(5).join(", ")}${missingChunks.length > 5 ? "..." : ""}',
    child: Row(
      children: [
        Icon(Icons.cloud_done, color: qualityColor, size: 16),
        SizedBox(width: 4),
        Text(
          '$chunkQuality%',
          style: TextStyle(
            color: qualityColor,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(width: 4),
        Text(
          qualityText,
          style: TextStyle(
            color: qualityColor,
            fontSize: 12,
          ),
        ),
      ],
    ),
  );
}
```

**Änderung 6.2: Partial Download Warning**
```dart
/// Show partial download warning dialog
Future<bool> _showPartialDownloadWarning(int chunkQuality) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Row(
        children: [
          Icon(Icons.warning, color: Colors.orange),
          SizedBox(width: 8),
          Text('Incomplete File'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This file is only $chunkQuality% available.',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 8),
          Text(
            'You can download the available parts now and automatically resume when more chunks become available.',
          ),
          SizedBox(height: 16),
          Text(
            'Do you want to start the partial download?',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text('Download Available Parts'),
        ),
      ],
    ),
  );
  
  return confirmed ?? false;
}
```

**Änderung 6.3: Auto-Resume Notification**
```dart
/// Show auto-resume notification
void _showAutoResumeNotification(int fileCount) {
  if (fileCount == 0) return;
  
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: [
          Icon(Icons.download, color: Colors.white),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Resuming $fileCount incomplete download${fileCount > 1 ? "s" : ""}...',
            ),
          ),
        ],
      ),
      duration: Duration(seconds: 3),
      action: SnackBarAction(
        label: 'View',
        onPressed: () {
          // Navigate to downloads
        },
      ),
    ),
  );
}
```

---

## 🔄 Integration Flow

### Flow 1: Upload & Announce
```
1. User wählt Datei aus
2. uploadAndAnnounceFile() aufrufen
   ├─ Datei chunken
   ├─ Chunks verschlüsseln
   ├─ In localStorage speichern
   └─ announceFile() mit sharedWith=[creator]
3. Server empfängt announce
   ├─ File Registry aktualisieren
   ├─ sharedWith Set erstellen
   └─ Nur Creator kann initial zugreifen
4. UI: "Upload complete and announced"
```

### Flow 2: Re-Announce nach Login
```
1. App startet, Socket verbindet
2. reannounceUploadedFiles() aufrufen
   ├─ Alle uploaded/seeding Files laden
   ├─ Für jedes File:
   │  ├─ Chunks aus localStorage laden
   │  ├─ sharedWith aus Metadata laden
   │  └─ announceFile() mit sharedWith
3. Server empfängt re-announce
   ├─ Existierendes File finden
   ├─ sharedWith Set wiederherstellen
   ├─ Seeder hinzufügen
   └─ Authorized users benachrichtigen
4. UI: "Re-announced X files"
```

### Flow 3: Share File via Signal
```
1. User A: shareFile(targetUserId: "userB")
2. Server: sharedWith.add("userB")
3. Server: emit("fileSharedWithYou") → User B Socket
4. Server: send Signal message → User B
5. User B Signal Service:
   ├─ Empfängt encrypted message
   ├─ Prüft: File lokal vorhanden?
   │  ├─ Ja: Update metadata
   │  └─ Nein: Ignore
6. User B UI: "User A shared file.pdf with you"
```

### Flow 4: Partial Download
```
1. User klickt Download
2. getFileInfo() → chunkQuality = 75%
3. UI: Show warning dialog
4. User bestätigt partial download
5. downloadFile(allowPartial: true)
   ├─ Download verfügbare chunks (75%)
   ├─ Nach jedem Chunk:
   │  ├─ saveChunk()
   │  └─ updateAvailableChunks() → Start seeding!
   └─ Status: 'partial'
6. setupAnnounceListener() → Auto-resume bei neuen chunks
```

### Flow 5: Auto-Resume nach Login & bei Announce
```
1. App startet
2. resumeIncompleteDownloads()
   ├─ Finde alle partial/downloading Files
   ├─ Für jedes File:
   │  ├─ getFileInfo() → Check quality
   │  ├─ Wenn quality > 0:
   │  │  └─ downloadFile(allowPartial: true)
3. setupAnnounceListener() ← NEU: Auch für Announce-Events
   ├─ Bei fileAnnounced: ← NEU
   │  ├─ Prüfe: Incomplete download?
   │  ├─ Hole aktuelle Chunk-Liste
   │  ├─ Vergleiche mit lokalen Chunks
   │  └─ Wenn neue Chunks: Auto-resume
   ├─ Bei fileSeederUpdate:
   │  └─ Gleiche Logik
4. UI: Show resume notifications
```

**Wichtig:** 
- Auto-Resume funktioniert jetzt bei **beiden** Events (Announce + SeederUpdate)
- Prüfung auf tatsächlich neue Chunks (nicht nur Quality-Change)
- Seeder wird automatisch zu sharedWith hinzugefügt beim Announce

---

## 📝 Checkliste für Implementation

### Backend Tasks
- [ ] **Task 1.1**: File Registry - sharedWith in announceFile() integrieren
  - [ ] Seeder automatisch zu sharedWith hinzufügen ← NEU
- [ ] **Task 1.2**: File Registry - getChunkQuality() implementieren
- [ ] **Task 1.3**: File Registry - getMissingChunks() implementieren
- [ ] **Task 2.1**: Socket Events - announceFile mit sharedWith erweitern
- [ ] **Task 2.2**: Socket Events - getFileInfo mit quality erweitern
- [ ] **Task 2.3**: Socket Events - updateAvailableChunks mit broadcast erweitern
- [ ] **Task 2.4**: Socket Events - Targeted notifications für alle File events

### Frontend Tasks
- [ ] **Task 3.1**: Socket Client - announceFile mit sharedWith Parameter
- [ ] **Task 3.2**: Socket Client - onFileSeederUpdate Listener
- [ ] **Task 4.1**: File Transfer - uploadAndAnnounceFile() implementieren
- [ ] **Task 4.2**: File Transfer - reannounceUploadedFiles() implementieren
- [ ] **Task 4.3**: File Transfer - downloadFile() mit partial support
- [ ] **Task 4.4**: File Transfer - resumeIncompleteDownloads() implementieren
- [ ] **Task 4.5**: File Transfer - setupAnnounceListener() implementieren
  - [ ] Auto-Resume auch bei Announce-Events ← NEU
  - [ ] Helper: _getAvailableChunksFromSeeders() ← NEU
  - [ ] Gemeinsame Resume-Logik für beide Events ← NEU
- [ ] **Task 5.1**: Signal Service - sendFileShareUpdate() implementieren
- [ ] **Task 5.2**: Signal Service - _handleFileShareUpdate() implementieren
- [ ] **Task 6.1**: UI - Chunk quality indicator in file list
- [ ] **Task 6.2**: UI - Partial download warning dialog
- [ ] **Task 6.3**: UI - Auto-resume notification

### Integration Tasks
- [ ] **Task 7.1**: App Initialization - Call reannounceUploadedFiles() on login
- [ ] **Task 7.2**: App Initialization - Call resumeIncompleteDownloads() on login
- [ ] **Task 7.3**: App Initialization - Setup announce listener
- [ ] **Task 7.4**: Signal Handler - Register file share update handler
- [ ] **Task 7.5**: Upload Flow - Replace manual announce with auto-announce

---

## 🧪 Test-Szenarien

### Test 1: Auto-Announce beim Upload
**Setup:** User A uploaded neue Datei  
**Erwartung:**
- ✅ announceFile() wird automatisch aufgerufen
- ✅ sharedWith enthält nur User A
- ✅ Server kann File Info zurückgeben
- ✅ Andere User sehen File NICHT

### Test 2: Re-Announce nach Logout/Login
**Setup:** User A hat 3 Files uploaded, loggt aus und wieder ein  
**Erwartung:**
- ✅ Alle 3 Files werden re-announced
- ✅ sharedWith wird wiederhergestellt
- ✅ Seeder-Status ist aktiv
- ✅ Authorized users werden benachrichtigt

### Test 3: Share File via Signal
**Setup:** User A teilt File mit User B  
**Erwartung:**
- ✅ Server aktualisiert sharedWith
- ✅ User B erhält Socket notification
- ✅ User B erhält Signal message
- ✅ User B kann File Info abrufen
- ✅ User B kann Download starten

### Test 4: Partial Download
**Setup:** File hat nur 60% chunks verfügbar  
**Erwartung:**
- ✅ UI zeigt "60% available"
- ✅ Warning dialog wird angezeigt
- ✅ Download startet mit verfügbaren chunks
- ✅ Nach jedem Chunk: updateAvailableChunks()
- ✅ Status: 'partial'
- ✅ User wird Seeder für heruntergeladene chunks

### Test 5: Auto-Resume bei neuen Chunks (Announce Event)
**Setup:** User B hat partial download (5/10 chunks), User C announced File mit chunks 6-10  
**Erwartung:**
- ✅ User B erhält fileAnnounced event
- ✅ Listener erkennt incomplete download
- ✅ Prüfung: Chunks 6-10 sind neu verfügbar
- ✅ Download wird automatisch fortgesetzt für chunks 6-10
- ✅ UI zeigt "Resuming download... 5 new chunks available"
- ✅ User C wird automatisch zu sharedWith hinzugefügt beim Announce

### Test 5b: Auto-Resume bei Seeder Update
**Setup:** User B hat partial download, User A (original uploader) kommt online  
**Erwartung:**
- ✅ User B erhält fileSeederUpdate event
- ✅ Gleiche Logik wie Test 5
- ✅ Auto-Resume funktioniert auch hier

### Test 6: Signal Share Update
**Setup:** User A teilt File mit User B, User B hat File bereits teilweise  
**Erwartung:**
- ✅ User B erhält Signal message
- ✅ Lokale Metadata wird aktualisiert
- ✅ User B sieht neuen Zugriff in UI
- ✅ User ohne File verwirft Nachricht

---

## 📊 Metriken & Monitoring

### Success Metrics
- **Auto-Announce Rate**: >95% aller Uploads werden announced
- **Re-Announce Success**: >95% nach Login
- **Partial Download Usage**: % Downloads bei <100% quality
- **Auto-Resume Success**: % erfolgreicher Auto-Resumes
- **Signal Message Delivery**: >95% Zustellrate

### Logging Points
```javascript
// Backend
[P2P FILE] File announced with sharedWith: [user1, user2]
[P2P FILE] Seeder user3 auto-added to sharedWith for fileId=abc
[P2P FILE] Notified 5 authorized users
[P2P FILE] Chunk quality update: fileId=abc, quality=85%
[P2P FILE] Re-announce: fileId=abc, userId=xyz

// Frontend  
[FILE TRANSFER] Auto-announcing file: abc
[FILE TRANSFER] Re-announcing 5 files after login
[FILE TRANSFER] Partial download started: 60% available
[FILE TRANSFER] File announced: abc (quality: 75%)
[FILE TRANSFER] Found incomplete download for abc, checking for new chunks
[FILE TRANSFER] Found 3 new chunks, auto-resuming download for abc
[FILE TRANSFER] Auto-resume progress: 85%
[SIGNAL] File share update received: shared
```

---

## 🔒 Security Considerations

### Privacy
- ✅ fileName/mimeType NIEMALS auf Server (nur in Signal messages)
- ✅ Nur authorized users erhalten fileAnnounced events
- ✅ canAccess() prüft bei allen sensiblen Operations

### Access Control
- ✅ Download nur mit sharedWith Eintrag möglich
- ✅ Chunk-Anfragen prüfen canAccess()
- ✅ Signal messages verschlüsselt

### Data Integrity
- ✅ Chunk-Hashes werden verifiziert
- ✅ Checksum-Prüfung bei File-Assembly
- ✅ Corrupt chunks werden neu angefordert

---

## 🚀 Deployment Plan

### Phase 1: Backend Updates (Tag 1)
1. File Registry Änderungen
2. Socket Event Updates
3. Chunk Quality Berechnung
4. Deployment auf Test-Server
5. Backend Tests

### Phase 2: Client Core (Tag 2-3)
1. Socket Client Updates
2. File Transfer Service Updates
3. Auto-Announce Implementierung
4. Re-Announce Implementierung
5. Client Unit Tests

### Phase 3: Partial Download (Tag 4)
1. Partial Download Logic
2. Seeding während Download
3. Auto-Resume Logic
4. Integration Tests

### Phase 4: Signal Integration (Tag 5)
1. Share Update Messages
2. Message Handling
3. Lokale Metadata Updates
4. E2E Tests

### Phase 5: UI Updates (Tag 6)
1. Chunk Quality Indicator
2. Partial Download Warning
3. Auto-Resume Notifications
4. UI/UX Tests

### Phase 6: Integration & Testing (Tag 7)
1. Full Integration
2. E2E Test Suite
3. Performance Tests
4. Bug Fixes

### Phase 7: Production Deployment (Tag 8)
1. Final Review
2. Deployment auf Production
3. Monitoring Setup
4. User Communication

---

## 📚 Referenzen

**Bestehende Dokumentation:**
- `P2P_FILE_SHARING_DESIGN.md` - Basis-Design
- `P2P_PROBLEM3_SHARE_BASED_ARCHITECTURE.md` - Share-Based System
- `P2P_AUTO_REANNOUNCE_IMPLEMENTATION.md` - Auto-Reannounce

**Code-Referenzen:**
- `server/store/fileRegistry.js` - File Registry
- `server/server.js` - Socket Events
- `client/lib/services/file_transfer/socket_file_client.dart` - Socket Client
- `client/lib/screens/file_transfer/file_manager_screen.dart` - UI

---

## ✅ Action Items Summary

**Immediate (This Week):**
1. Implement Backend Changes (Tasks 1.1-2.4)
2. Implement Frontend Core (Tasks 3.1-4.2)
3. Deploy to Test Environment

**Next Week:**
1. Implement Partial Download (Tasks 4.3-4.5)
2. Implement Signal Integration (Tasks 5.1-5.2)
3. Implement UI Updates (Tasks 6.1-6.3)
4. Integration Testing

**Week After:**
1. Production Deployment
2. Monitor Metrics
3. Collect User Feedback
4. Iterate based on feedback

---

**Status:** ✅ Ready for Implementation  
**Estimated Effort:** 8 Entwicklungstage  
**Risk Level:** Medium (bestehende Architektur, gut dokumentiert)
