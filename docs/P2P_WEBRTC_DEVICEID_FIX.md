# P2P WebRTC Connection Problem - Device ID Missing

## 🔍 Problem-Analyse

### Symptome aus Logs:
```
[P2P] WARNING: No deviceId for peer 148475f2-a00e-4178-a4e1-9f5d05008580, cannot send signaling message
[P2P] WARNING: Cannot send ICE candidate - no deviceId for peer 148475f2-a00e-4178-a4e1-9f5d05008580
[WebRTC] Peer connection state: RTCPeerConnectionState.RTCPeerConnectionStateConnecting
```

### Root Cause:
Die `deviceId` wird **NUR** gespeichert, wenn Alice (Downloader) eine **WebRTC-Nachricht empfängt** (offer, answer, ICE candidate).

**ABER:** Beim normalen Download-Flow:
1. Alice ruft `getAvailableChunks()` auf → bekommt nur `userId` ohne `deviceId`
2. Alice startet Download und sendet Offer → **keine deviceId bekannt**
3. Alice kann keine gezielten WebRTC-Signale senden → **muss broadcast verwenden**
4. ICE-Kandidaten können nicht gesendet werden → **Verbindung bleibt bei "connecting" hängen**

### Betroffene Dateien:
- **Client:** `client/lib/services/file_transfer/p2p_coordinator.dart`
- **Client:** `client/lib/services/file_transfer/socket_file_client.dart`
- **Server:** `server/server.js` (getAvailableChunks handler)

---

## ✅ LÖSUNG 1: deviceId in getAvailableChunks() Response hinzufügen ⭐ **EMPFOHLEN**

### Warum diese Lösung?
- ✅ Keine zusätzlichen Roundtrips
- ✅ deviceId sofort beim Download-Start verfügbar
- ✅ Funktioniert auch nach Browser-Refresh
- ✅ Minimale Code-Änderungen

### Server-Seite Änderungen (server.js):

**Aktuelle Implementation (Zeile ~1070-1090):**
```javascript
socket.on("getAvailableChunks", async (data, callback) => {
  try {
    const { fileId } = data;
    const chunks = fileRegistry.getAvailableChunks(fileId);

    callback?.({ success: true, chunks });

  } catch (error) {
    console.error('[P2P FILE] Error getting available chunks:', error);
    callback?.({ success: false, error: error.message });
  }
});
```

**Neue Implementation:**
```javascript
socket.on("getAvailableChunks", async (data, callback) => {
  try {
    const { fileId } = data;
    const chunks = fileRegistry.getAvailableChunks(fileId);
    
    // NEUE LOGIK: Add deviceId for each seeder
    const chunksWithDeviceIds = {};
    
    for (const [userId, chunkList] of Object.entries(chunks)) {
      // Get deviceId from active clients
      // Note: This assumes seeders are online. For offline seeders, deviceId would be null.
      let deviceId = null;
      
      // Find any active socket for this userId
      const activeSockets = Array.from(io.sockets.sockets.values())
        .filter(s => s.handshake.session.uuid === userId);
      
      if (activeSockets.length > 0) {
        // Use the first available device
        deviceId = activeSockets[0].handshake.session.deviceId;
      }
      
      chunksWithDeviceIds[userId] = {
        chunks: chunkList,
        deviceId: deviceId  // ← HINZUGEFÜGT
      };
    }

    callback?.({ success: true, chunks: chunksWithDeviceIds });
    
    console.log(`[P2P FILE] Sent available chunks with deviceIds for file ${fileId}`);

  } catch (error) {
    console.error('[P2P FILE] Error getting available chunks:', error);
    callback?.({ success: false, error: error.message });
  }
});
```

### Client-Seite Änderungen (socket_file_client.dart):

**Aktuelle Implementation (Zeile ~161-183):**
```dart
Future<Map<String, List<int>>> getAvailableChunks(String fileId) async {
  final completer = Completer<Map<String, List<int>>>();
  
  socket.emitWithAck('getAvailableChunks', {
    'fileId': fileId,
  }, ack: (data) {
    if (data['success'] == true) {
      final chunks = <String, List<int>>{};
      final rawChunks = data['chunks'] as Map;
      
      for (final entry in rawChunks.entries) {
        chunks[entry.key] = List<int>.from(entry.value);
      }
      
      completer.complete(chunks);
    } else {
      completer.completeError(data['error'] ?? 'Failed to get chunks');
    }
  });
  
  return completer.future;
}
```

**Neue Implementation:**
```dart
/// Get available chunks from seeders (with deviceIds)
Future<Map<String, SeederInfo>> getAvailableChunks(String fileId) async {
  final completer = Completer<Map<String, SeederInfo>>();
  
  socket.emitWithAck('getAvailableChunks', {
    'fileId': fileId,
  }, ack: (data) {
    if (data['success'] == true) {
      final seeders = <String, SeederInfo>{};
      final rawChunks = data['chunks'] as Map;
      
      for (final entry in rawChunks.entries) {
        final userId = entry.key as String;
        final seederData = entry.value as Map;
        
        seeders[userId] = SeederInfo(
          chunks: List<int>.from(seederData['chunks']),
          deviceId: seederData['deviceId'] as String?,
        );
      }
      
      completer.complete(seeders);
    } else {
      completer.completeError(data['error'] ?? 'Failed to get chunks');
    }
  });
  
  return completer.future;
}

/// Seeder information with chunks and deviceId
class SeederInfo {
  final List<int> chunks;
  final String? deviceId;
  
  SeederInfo({
    required this.chunks,
    this.deviceId,
  });
}
```

### P2P Coordinator Änderungen (p2p_coordinator.dart):

**Im startDownload() oder startDownloadWithKeyRequest():**

```dart
// VORHER: Map<String, List<int>> seederChunks
// NACHHER: Map<String, SeederInfo> seederChunks

// Store device IDs immediately
for (final entry in seederChunks.entries) {
  final userId = entry.key;
  final seederInfo = entry.value;
  
  if (seederInfo.deviceId != null) {
    _peerDevices[userId] = seederInfo.deviceId!;
    debugPrint('[P2P] ✓ Stored deviceId for $userId: ${seederInfo.deviceId}');
  } else {
    debugPrint('[P2P] ⚠ No deviceId for $userId (offline or unavailable)');
  }
  
  // Use chunks as before
  _seederAvailability[fileId] = {
    userId: seederInfo.chunks
  };
}
```

---

## ✅ LÖSUNG 2: deviceId über file:announce Event bereitstellen

### Server-Seite (announceFile handler):

**Aktuelle Implementation:**
```javascript
socket.broadcast.emit("fileAnnounced", {
  fileId,
  mimeType,
  fileSize,
  seederCount: fileInfo.seederCount
});
```

**Neue Implementation:**
```javascript
socket.broadcast.emit("fileAnnounced", {
  fileId,
  mimeType,
  fileSize,
  seederCount: fileInfo.seederCount,
  userId: socket.handshake.session.uuid,        // ← HINZUGEFÜGT
  deviceId: socket.handshake.session.deviceId   // ← HINZUGEFÜGT
});
```

### Client-Seite:

```dart
// In P2PCoordinator._setupSignalCallbacks() oder socket listener
socket.on('fileAnnounced', (data) {
  final userId = data['userId'] as String?;
  final deviceId = data['deviceId'] as String?;
  
  if (userId != null && deviceId != null) {
    _peerDevices[userId] = deviceId;
    debugPrint('[P2P] ✓ File announced by $userId:$deviceId');
  }
});
```

---

## ✅ LÖSUNG 3: WebRTC Connection Cleanup nach Download

### Problem:
Connections bleiben nach erfolgreichem Download offen → State-Konflikte bei erneutem Download

### Implementation in p2p_coordinator.dart:

```dart
/// Cleanup after download completes or fails
Future<void> _cleanupDownload(String fileId) async {
  debugPrint('[P2P] Cleaning up download: $fileId');
  
  // Close all WebRTC connections for this file
  final peers = _fileConnections[fileId] ?? {};
  for (final peerId in peers) {
    try {
      await webrtcService.disconnect(peerId);
      debugPrint('[P2P] ✓ Disconnected from peer $peerId');
    } catch (e) {
      debugPrint('[P2P] ✗ Error disconnecting from $peerId: $e');
    }
  }
  
  // Clear all state for this file
  _fileConnections.remove(fileId);
  _activeChunkRequests.remove(fileId);
  _seederAvailability.remove(fileId);
  _chunkQueue.remove(fileId);
  _chunksInFlightPerPeer.clear();
  _throttlers.remove(fileId);
  _batchMetadataCache.removeWhere((key, _) => key.startsWith('$fileId:'));
  
  debugPrint('[P2P] ✓ Cleanup complete for $fileId');
}
```

**Aufruf in _completeDownload() und _handleDownloadError():**

```dart
// In _completeDownload (nach erfolgreicher Verifizierung):
await _cleanupDownload(fileId);

// In _handleDownloadError:
await _cleanupDownload(fileId);
```

---

## ✅ LÖSUNG 4: Connection Timeout für stuck connections

### Implementation in webrtc_service.dart:

```dart
Future<void> createOffer(String peerId) async {
  // ... existing code ...
  
  // Add connection timeout
  Timer(Duration(seconds: 30), () async {
    final connection = _connections[peerId];
    if (connection != null) {
      final state = await connection.getConnectionState();
      if (state != RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        debugPrint('[WebRTC] ⏱ Connection timeout for $peerId (state: $state)');
        debugPrint('[WebRTC] Disconnecting stuck connection...');
        await disconnect(peerId);
      }
    }
  });
}
```

**Alternative: Periodic Cleanup Job:**

```dart
// In WebRTCFileService constructor
Timer.periodic(Duration(seconds: 60), (_) => _cleanupStuckConnections());

void _cleanupStuckConnections() {
  final now = DateTime.now();
  
  _connections.forEach((peerId, connection) async {
    final state = await connection.getConnectionState();
    
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnecting ||
        state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      
      debugPrint('[WebRTC] Cleaning up stuck connection: $peerId (state: $state)');
      await disconnect(peerId);
    }
  });
}
```

---

## ✅ LÖSUNG 5: isSeeder Flag nach Download-Completion setzen

### Problem:
Downloads werden nicht als Seeder markiert → Re-Announce überspringt sie

### Implementation in download_manager.dart (Zeile ~410-425):

**Aktuell:**
```dart
await storage.updateFileMetadata(fileId, {
  'status': 'completed',
  'lastActivity': DateTime.now().toIso8601String(),
});
```

**Fix:**
```dart
await storage.updateFileMetadata(fileId, {
  'status': 'completed',
  'isSeeder': true,  // ← HINZUFÜGEN (nach erfolgreichem Download wird User zum Seeder)
  'lastActivity': DateTime.now().toIso8601String(),
});

// Optional: Automatisch im Netzwerk ankündigen
try {
  final availableChunks = await storage.getAvailableChunks(fileId);
  final metadata = await storage.getFileMetadata(fileId);
  
  if (metadata != null && availableChunks.isNotEmpty) {
    await socketClient.announceFile(
      fileId: fileId,
      mimeType: metadata['mimeType'] as String? ?? 'application/octet-stream',
      fileSize: metadata['fileSize'] as int? ?? 0,
      checksum: metadata['checksum'] as String? ?? '',
      chunkCount: metadata['chunkCount'] as int? ?? 0,
      availableChunks: availableChunks,
    );
    debugPrint('[DOWNLOAD] ✓ File announced to network after completion');
  }
} catch (e) {
  debugPrint('[DOWNLOAD] ⚠ Failed to announce completed file: $e');
}
```

---

## 📋 Implementierungs-Reihenfolge (Empfohlen)

### Phase 1: Kritische Fixes (SOFORT)
1. **LÖSUNG 1** - deviceId in getAvailableChunks() ← **BLOCKIERT ALLE DOWNLOADS**
2. **LÖSUNG 5** - isSeeder nach Download ← **RE-ANNOUNCE FUNKTIONIERT NICHT**

### Phase 2: Stabilität (WICHTIG)
3. **LÖSUNG 3** - Connection Cleanup ← **VERHINDERT MEMORY LEAKS**
4. **LÖSUNG 4** - Connection Timeout ← **VERHINDERT STUCK CONNECTIONS**

### Phase 3: Bonus (OPTIONAL)
5. **LÖSUNG 2** - file:announce deviceId ← **NICE-TO-HAVE FÜR REAL-TIME**

---

## 🧪 Testing Checklist

Nach Implementation testen:

- [ ] Download von File starten (Alice → Bob)
- [ ] Log prüfen: Keine "No deviceId" Warnings mehr
- [ ] Connection State erreicht "connected"
- [ ] Chunks werden erfolgreich übertragen
- [ ] Download completes
- [ ] File wird als "isSeeder: true" markiert
- [ ] Nach Re-Login: File wird re-announced
- [ ] Browser Refresh während Download → Connection wird sauber geschlossen
- [ ] Zweiter Download von gleichem File funktioniert
- [ ] Connection Timeout nach 30s bei stuck connection

---

## 📝 Zusätzliche Notizen

### fileRegistry.js Enhancement (Optional)

Wenn `deviceId` gespeichert werden soll:

```javascript
// In store/fileRegistry.js
announceFile(userId, fileData) {
  // ... existing code ...
  
  this.seeders[userId] = {
    ...fileData,
    deviceId: null  // Will be set later
  };
}

// New method
setSeederDeviceId(userId, deviceId) {
  if (this.seeders[userId]) {
    this.seeders[userId].deviceId = deviceId;
  }
}
```

### Debug Logging hinzufügen

```dart
// In p2p_coordinator.dart
void _debugPeerDevices() {
  debugPrint('[P2P] ========================================');
  debugPrint('[P2P] Current peer device mappings:');
  _peerDevices.forEach((userId, deviceId) {
    debugPrint('[P2P]   $userId → $deviceId');
  });
  debugPrint('[P2P] ========================================');
}
```

---

## ⚠️ Bekannte Edge Cases

1. **Seeder offline während getAvailableChunks:**
   - deviceId wird null sein
   - Client sollte graceful fallback haben (broadcast)

2. **Multi-Device Seeder:**
   - Server gibt nur ERSTEN Device zurück
   - Alternative: Array von deviceIds zurückgeben

3. **Browser Refresh während Transfer:**
   - Neue deviceId nach Refresh
   - Alte Connection muss timeout

---

## 📚 Weitere Ressourcen

- WebRTC Connection States: https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/connectionState
- ICE Candidate Gathering: https://webrtc.org/getting-started/peer-connections
- DataChannel Buffering: https://developer.mozilla.org/en-US/docs/Web/API/RTCDataChannel/bufferedAmount

---

## ⚠️ PROBLEM 2: Race Condition beim Download-Completion

### Symptome aus Logs:
```
[P2P] Download progress: 10/10 chunks
[P2P] ✓ DOWNLOAD COMPLETE: 1761730523480_468284056
[P2P] Assembling file and triggering download...
[P2P] ASSEMBLING FILE: download_17617305
[P2P] Loading 10 chunks from storage...

# GLEICHZEITIG empfängt Downloader noch Chunks vom Seeder:
[P2P] Ignoring duplicate chunk 9 from 148475f2-a00e-4178-a4e1-9f5d05008580
[P2P] ERROR: Received chunk but no active requests from 148475f2-a00e-4178-a4e1-9f5d05008580
[P2P] ERROR: Received chunk but no active requests from 148475f2-a00e-4178-a4e1-9f5d05008580
[P2P] ERROR: Received chunk but no active requests from 148475f2-a00e-4178-a4e1-9f5d05008580

# DANN schlägt Assembly fehl:
[P2P] ERROR completing download: Exception: Failed to decrypt chunk 2
```

### Root Cause:
**Race Condition zwischen Download-Completion und eingehenden Chunks:**

1. **Downloader (Alice):**
   - Chunk 9 received → "10/10 chunks complete"
   - Startet sofort `_completeDownload()` → lädt Chunks aus Storage
   - Löscht `_activeChunkRequests[fileId]` und andere State

2. **Seeder (Bob):**
   - Hat bereits Chunk 7, 8, 9 gesendet (parallel requests)
   - Chunks sind noch unterwegs im Netzwerk (WebRTC buffer)
   - Kommen NACH "Download complete" beim Downloader an

3. **Resultat:**
   - Downloader hat keinen State mehr für diese Chunks
   - Chunks werden ignoriert oder verwerfen
   - **Assembly schlägt fehl**: "Failed to decrypt chunk 2"
   - Grund: Chunk 2 wurde möglicherweise durch späten Chunk überschrieben

### Betroffene Dateien:
- `client/lib/services/file_transfer/p2p_coordinator.dart`
- `client/lib/services/file_transfer/webrtc_service.dart`
- `client/lib/services/file_transfer/download_manager.dart`

---

## ✅ LÖSUNG 6: Graceful Download-Completion mit Drain-Phase

### Problem:
Download wird sofort als "complete" markiert, obwohl noch Chunks unterwegs sind.

### Lösung:
**3-Phase Download-Completion:**

1. **Phase 1: All Chunks Received** (aktuell)
2. **Phase 2: Drain Phase** (NEU) - Warte auf in-flight chunks
3. **Phase 3: Assembly & Verification**

### Implementation in p2p_coordinator.dart:

```dart
// State tracking
enum DownloadPhase {
  downloading,
  draining,      // ← NEU: Warte auf in-flight chunks
  assembling,
  verifying,
  complete,
}

// Add to class variables
final Map<String, DownloadPhase> _downloadPhases = {};
final Map<String, DateTime> _drainStartTime = {};
static const Duration _drainTimeout = Duration(seconds: 5);

// Modified chunk processing
Future<void> _handleDataChannelMessage(String fileId, String peerId, dynamic data) async {
  // Check if download is in drain phase
  if (_downloadPhases[fileId] == DownloadPhase.draining) {
    debugPrint('[P2P] Received chunk during drain phase from $peerId');
    // Process chunk normally but don't request new ones
  }
  
  if (_downloadPhases[fileId] == DownloadPhase.assembling ||
      _downloadPhases[fileId] == DownloadPhase.complete) {
    debugPrint('[P2P] ⚠ Ignoring late chunk from $peerId (download already assembling/complete)');
    return;
  }
  
  // ... existing chunk processing ...
  
  // After processing chunk
  if (task.downloadedChunks >= task.chunkCount) {
    debugPrint('[P2P] All chunks received, entering DRAIN PHASE');
    _downloadPhases[fileId] = DownloadPhase.draining;
    _drainStartTime[fileId] = DateTime.now();
    
    // Stop requesting new chunks
    _stopChunkRequests(fileId);
    
    // Wait for in-flight chunks
    await _drainInFlightChunks(fileId);
    
    // Now safe to complete
    await _completeDownload(fileId, task);
  }
}

/// Stop requesting new chunks for this download
void _stopChunkRequests(String fileId) {
  debugPrint('[P2P] Stopping chunk requests for $fileId');
  
  // Clear queue
  _chunkQueue.remove(fileId);
  
  // Cancel any pending timers/requests
  // (Implementation depends on your timer structure)
}

/// Wait for all in-flight chunks to arrive
Future<void> _drainInFlightChunks(String fileId) async {
  debugPrint('[P2P] ========================================');
  debugPrint('[P2P] DRAIN PHASE: Waiting for in-flight chunks');
  
  final activeRequests = _activeChunkRequests[fileId] ?? {};
  final inFlightCount = activeRequests.length;
  
  debugPrint('[P2P] In-flight chunks: $inFlightCount');
  
  if (inFlightCount == 0) {
    debugPrint('[P2P] No in-flight chunks, proceeding immediately');
    return;
  }
  
  // Wait up to 5 seconds for chunks to arrive
  final startTime = DateTime.now();
  const checkInterval = Duration(milliseconds: 100);
  
  while (DateTime.now().difference(startTime) < _drainTimeout) {
    final remaining = (_activeChunkRequests[fileId] ?? {}).length;
    
    if (remaining == 0) {
      final elapsed = DateTime.now().difference(startTime);
      debugPrint('[P2P] ✓ All in-flight chunks received (${elapsed.inMilliseconds}ms)');
      debugPrint('[P2P] ========================================');
      return;
    }
    
    await Future.delayed(checkInterval);
  }
  
  // Timeout - some chunks didn't arrive
  final remaining = (_activeChunkRequests[fileId] ?? {}).length;
  debugPrint('[P2P] ⚠ Drain timeout: $remaining chunks still missing');
  debugPrint('[P2P] Missing chunks: ${(_activeChunkRequests[fileId] ?? {}).keys.toList()}');
  debugPrint('[P2P] ========================================');
  
  // Clear the requests anyway
  _activeChunkRequests[fileId]?.clear();
}

/// Modified complete download
Future<void> _completeDownload(String fileId, DownloadTask task) async {
  debugPrint('[P2P] ================================================');
  debugPrint('[P2P] PHASE 3: ASSEMBLING & VERIFYING');
  debugPrint('[P2P] ================================================');
  
  _downloadPhases[fileId] = DownloadPhase.assembling;
  
  try {
    // ... existing assembly code ...
    
    _downloadPhases[fileId] = DownloadPhase.complete;
    
    // Cleanup
    await _cleanupDownload(fileId);
    
  } catch (e, stackTrace) {
    debugPrint('[P2P] ERROR completing download: $e');
    _downloadPhases[fileId] = DownloadPhase.downloading;
    // Handle error
  }
}
```

---

## ✅ LÖSUNG 7: Chunk Request Cancellation beim Seeder

### Problem:
Seeder sendet weiter Chunks, auch wenn Downloader schon fertig ist.

### Lösung:
**Stop-Signal vom Downloader an Seeder:**

### Implementation in p2p_coordinator.dart (Downloader):

```dart
/// Send stop signal to all seeders
Future<void> _notifySeedersDownloadComplete(String fileId) async {
  final peers = _fileConnections[fileId] ?? {};
  
  for (final peerId in peers) {
    try {
      debugPrint('[P2P] Sending download complete signal to $peerId');
      
      await webrtcService.sendData(peerId, jsonEncode({
        'type': 'download_complete',
        'fileId': fileId,
        'timestamp': DateTime.now().toIso8601String(),
      }));
      
    } catch (e) {
      debugPrint('[P2P] Failed to notify $peerId: $e');
    }
  }
}

// Call in _drainInFlightChunks after all chunks received:
await _notifySeedersDownloadComplete(fileId);
```

### Implementation in p2p_coordinator.dart (Seeder):

```dart
// In _handleDataChannelMessage (text message handler)
void _handleTextMessage(String fileId, String peerId, Map<String, dynamic> message) {
  final type = message['type'] as String?;
  
  if (type == 'download_complete') {
    debugPrint('[P2P SEEDER] Downloader $peerId completed download of $fileId');
    _handleDownloadComplete(fileId, peerId);
    return;
  }
  
  // ... existing chunk request handling ...
}

void _handleDownloadComplete(String fileId, String peerId) {
  // Cancel any pending chunk sends to this peer
  _pendingChunkSends[peerId]?.cancel();
  _pendingChunkSends.remove(peerId);
  
  // Remove from active connections
  _fileConnections[fileId]?.remove(peerId);
  
  debugPrint('[P2P SEEDER] ✓ Stopped sending chunks to $peerId');
}
```

---

## ✅ LÖSUNG 8: Idempotent Chunk Processing

### Problem:
Duplicate/late chunks können Storage corrumpieren.

### Lösung:
**Atomic Chunk Storage mit Version Check:**

### Implementation in storage_interface.dart:

```dart
/// Save chunk with duplicate protection
Future<void> saveChunkSafe(String fileId, int chunkIndex, Uint8List encryptedData) async {
  // Check if chunk already exists and is complete
  final existingChunk = await getChunk(fileId, chunkIndex);
  
  if (existingChunk != null && existingChunk.length == encryptedData.length) {
    debugPrint('[STORAGE] Chunk $chunkIndex already exists (${existingChunk.length} bytes), skipping');
    return;
  }
  
  if (existingChunk != null) {
    debugPrint('[STORAGE] ⚠ Chunk $chunkIndex exists but size mismatch: ${existingChunk.length} != ${encryptedData.length}');
    debugPrint('[STORAGE] Overwriting with new data');
  }
  
  // Atomic write
  await saveChunk(fileId, chunkIndex, encryptedData);
  
  debugPrint('[STORAGE] ✓ Chunk $chunkIndex saved (${encryptedData.length} bytes)');
}
```

### Implementation in p2p_coordinator.dart:

```dart
// Modified chunk processing
Future<void> _processChunk(String fileId, String peerId, int chunkIndex, Uint8List encryptedChunk) async {
  final task = _downloads[fileId];
  if (task == null) {
    debugPrint('[P2P] ⚠ No task found for $fileId, ignoring chunk');
    return;
  }
  
  // Check if already processed
  if (task.completedChunks.contains(chunkIndex)) {
    debugPrint('[P2P] Chunk $chunkIndex already completed, ignoring duplicate');
    return;
  }
  
  // Check if download is already complete
  if (_downloadPhases[fileId] == DownloadPhase.assembling ||
      _downloadPhases[fileId] == DownloadPhase.complete) {
    debugPrint('[P2P] ⚠ Download already complete, ignoring late chunk $chunkIndex');
    return;
  }
  
  try {
    // Save chunk atomically
    await storage.saveChunkSafe(fileId, chunkIndex, encryptedChunk);
    
    // Mark as complete ONLY if save succeeded
    task.completedChunks.add(chunkIndex);
    task.downloadedChunks = task.completedChunks.length;
    
    // Remove from active requests
    _activeChunkRequests[fileId]?.remove(chunkIndex);
    _completeChunkRequest(peerId, fileId);
    
    debugPrint('[P2P] ✓ Chunk $chunkIndex saved and marked complete');
    
  } catch (e) {
    debugPrint('[P2P] ✗ Failed to save chunk $chunkIndex: $e');
    // Don't mark as complete, allow retry
  }
}
```

---

## ✅ LÖSUNG 9: Storage Verification vor Assembly

### Problem:
"Failed to decrypt chunk 2" deutet auf korrupte Daten im Storage.

### Lösung:
**Pre-Assembly Storage Verification:**

### Implementation in download_manager.dart:

```dart
Future<void> _completeDownload(String fileId, DownloadTask task) async {
  debugPrint('[DOWNLOAD] ================================================');
  debugPrint('[DOWNLOAD] Verifying stored chunks before assembly...');
  
  // PHASE 1: Verify all chunks exist and have data
  final missingChunks = <int>[];
  final corruptChunks = <int>[];
  
  for (int i = 0; i < task.chunkCount; i++) {
    try {
      final chunk = await storage.getChunk(fileId, i);
      
      if (chunk == null || chunk.isEmpty) {
        missingChunks.add(i);
        continue;
      }
      
      // Verify chunk structure (IV + encrypted data + auth tag)
      if (chunk.length < 12 + 16) { // Minimum: 12 byte IV + 16 byte auth tag
        debugPrint('[DOWNLOAD] ⚠ Chunk $i too small: ${chunk.length} bytes');
        corruptChunks.add(i);
        continue;
      }
      
      debugPrint('[DOWNLOAD] ✓ Chunk $i verified: ${chunk.length} bytes');
      
    } catch (e) {
      debugPrint('[DOWNLOAD] ✗ Error reading chunk $i: $e');
      corruptChunks.add(i);
    }
  }
  
  // Report verification results
  if (missingChunks.isNotEmpty || corruptChunks.isNotEmpty) {
    debugPrint('[DOWNLOAD] ================================================');
    debugPrint('[DOWNLOAD] ✗ STORAGE VERIFICATION FAILED');
    debugPrint('[DOWNLOAD] Missing chunks: $missingChunks');
    debugPrint('[DOWNLOAD] Corrupt chunks: $corruptChunks');
    debugPrint('[DOWNLOAD] ================================================');
    
    throw Exception('Storage verification failed: ${missingChunks.length} missing, ${corruptChunks.length} corrupt');
  }
  
  debugPrint('[DOWNLOAD] ✓ All ${task.chunkCount} chunks verified');
  debugPrint('[DOWNLOAD] ================================================');
  
  // PHASE 2: Assembly
  debugPrint('[DOWNLOAD] Assembling file...');
  final chunks = <Uint8List>[];
  
  for (int i = 0; i < task.chunkCount; i++) {
    final encryptedChunk = await storage.getChunk(fileId, i)!;
    
    try {
      final decryptedChunk = await encryptionService.decryptChunk(
        encryptedChunk,
        task.fileKey!,
      );
      
      chunks.add(decryptedChunk);
      debugPrint('[DOWNLOAD] ✓ Decrypted chunk $i: ${decryptedChunk.length} bytes');
      
    } catch (e, stackTrace) {
      debugPrint('[DOWNLOAD] ✗ Failed to decrypt chunk $i: $e');
      debugPrint('[DOWNLOAD] Stack trace: $stackTrace');
      debugPrint('[DOWNLOAD] Chunk size: ${encryptedChunk.length} bytes');
      debugPrint('[DOWNLOAD] Key size: ${task.fileKey!.length} bytes');
      throw Exception('Failed to decrypt chunk $i: $e');
    }
  }
  
  // ... continue with assembly ...
}
```

---

## ✅ LÖSUNG 10: Connection State Management

### Problem:
Nach Download-Completion werden Connections nicht sauber geschlossen.

### Lösung:
**Explizite Disconnect nach Download:**

### Implementation in p2p_coordinator.dart:

```dart
Future<void> _cleanupDownload(String fileId) async {
  debugPrint('[P2P] ================================================');
  debugPrint('[P2P] Cleaning up download: $fileId');
  
  // PHASE 1: Notify seeders
  await _notifySeedersDownloadComplete(fileId);
  
  // PHASE 2: Wait for graceful disconnect
  await Future.delayed(Duration(milliseconds: 500));
  
  // PHASE 3: Force disconnect all peers
  final peers = _fileConnections[fileId] ?? {};
  debugPrint('[P2P] Disconnecting from ${peers.length} peers');
  
  for (final peerId in peers) {
    try {
      await webrtcService.disconnect(peerId);
      debugPrint('[P2P] ✓ Disconnected from $peerId');
    } catch (e) {
      debugPrint('[P2P] ⚠ Error disconnecting from $peerId: $e');
    }
  }
  
  // PHASE 4: Clear all state
  _fileConnections.remove(fileId);
  _activeChunkRequests.remove(fileId);
  _seederAvailability.remove(fileId);
  _chunkQueue.remove(fileId);
  _downloadPhases.remove(fileId);
  _drainStartTime.remove(fileId);
  _throttlers.remove(fileId);
  
  _chunksInFlightPerPeer.clear();
  _batchMetadataCache.removeWhere((key, _) => key.startsWith('$fileId:'));
  
  debugPrint('[P2P] ✓ All state cleared for $fileId');
  debugPrint('[P2P] ================================================');
}
```

---

## 📋 Aktualisierte Implementierungs-Reihenfolge

### Phase 1: Kritische Fixes (SOFORT)
1. **LÖSUNG 1** - deviceId in getAvailableChunks() ← **BLOCKIERT ALLE DOWNLOADS**
2. **LÖSUNG 8** - Idempotent Chunk Processing ← **VERHINDERT CORRUPTION**
3. **LÖSUNG 9** - Storage Verification ← **ERKENNT PROBLEME FRÜH**

### Phase 2: Race Condition Fixes (WICHTIG)
4. **LÖSUNG 6** - Drain Phase ← **BEHEBT RACE CONDITION**
5. **LÖSUNG 7** - Stop Signal ← **VERHINDERT SPÄTE CHUNKS**
6. **LÖSUNG 10** - Connection Cleanup ← **SAUBERE DISCONNECTS**

### Phase 3: Stabilität (WICHTIG)
7. **LÖSUNG 3** - Connection Cleanup (original)
8. **LÖSUNG 4** - Connection Timeout
9. **LÖSUNG 5** - isSeeder nach Download

### Phase 4: Bonus (OPTIONAL)
10. **LÖSUNG 2** - file:announce deviceId

---

## 🧪 Erweiterte Testing Checklist

Nach Implementation testen:

### Basic Flow:
- [ ] Download von File starten (Alice → Bob)
- [ ] Log prüfen: Keine "No deviceId" Warnings
- [ ] Connection State erreicht "connected"
- [ ] Chunks werden erfolgreich übertragen

### Race Condition Tests:
- [ ] Download completes erfolgreich
- [ ] Keine "ERROR: Received chunk but no active requests" Errors
- [ ] Keine "Failed to decrypt chunk" Errors
- [ ] "Drain phase" erscheint in Logs
- [ ] "All in-flight chunks received" im Log

### Cleanup Tests:
- [ ] Connection wird nach Download geschlossen
- [ ] File wird als "isSeeder: true" markiert
- [ ] Zweiter Download von gleichem File funktioniert
- [ ] Browser Refresh während Download → Connection timeout

### Edge Cases:
- [ ] Sehr kleine Datei (1 Chunk)
- [ ] Sehr große Datei (100+ Chunks)
- [ ] Parallel Downloads von mehreren Files
- [ ] Seeder disconnected während Download

---

## 🔄 PROBLEM 3: File Sharing Architecture - Privacy & Targeting

### Aktuelle Probleme:

1. **Broadcast-Based File Sharing:**
   ```javascript
   // server.js (Zeile 918)
   socket.broadcast.emit("fileAnnounced", {
     fileId, mimeType, fileSize, seederCount
   });
   ```
   - ❌ Alle User sehen alle Files (keine Privacy)
   - ❌ Kein Konzept von "shared with"
   - ❌ Keine 1:1 oder Channel-basierte Shares

2. **userId-based Registry:**
   ```javascript
   // fileRegistry.js
   announceFile(userId, fileMetadata) {
     file.creator = userId;  // ❌ Nur userId, keine deviceId
     file.seeders.add(userId);  // ❌ Kann nicht unterscheiden welches Device
   }
   ```
   - ❌ File muss auf ALLEN Devices des Users verfügbar sein
   - ❌ Keine Unterscheidung welches Device tatsächlich seeded
   - ❌ Disconnect cleanup fehlerhaft (alle Devices eines Users betroffen)

3. **Fehlende Share-Scope:**
   - ❌ Keine Möglichkeit File nur mit bestimmten Usern zu teilen
   - ❌ Keine Channel-Integration
   - ❌ Keine 1:1 Message Integration

### Deine Überlegung (Analysiert):

**✅ KORREKT:** 
- "Dateien nur in 1:1 chats oder channels teilen"
- "mit gesamtem user oder channel geshared (keine deviceId im Share-Scope)"
- "File muss nicht auf allen Geräten verfügbar sein"
- "deviceSockets als Hybrid: userId:deviceId → socketId"

**Architektur-Prinzipien:**
```
SHARE SCOPE (wer sieht das File):
  - userId (1:1 share mit User, ALLE seine Devices können downloaden)
  - channelId (Group share, ALLE Channel-Members können downloaden)

SEEDER TRACKING (wer hat das File):
  - userId:deviceId (welches SPEZIFISCHE Device seeded aktuell)
  - Nutzt deviceSockets Map für online-check
```

**Beispiel-Flow:**
```
Alice (Device 1) teilt File mit Bob:
  ✅ Share: [Bob.userId]
  ✅ Seeder: [Alice.userId:Device1]
  
Bob (Device 2) lädt herunter:
  ✅ Kann zugreifen (Bob.userId in Share)
  ✅ Verbindet zu Alice:Device1 (einziger aktiver Seeder)
  
Alice (Device 2) kommt online:
  ✅ Kann auch seeden (falls File vorhanden)
  ✅ Seeder: [Alice.userId:Device1, Alice.userId:Device2]
  
Alice (Device 1) disconnected:
  ✅ Nur Alice:Device1 aus Seeders entfernt
  ✅ Alice:Device2 bleibt Seeder
```

---

## ✅ LÖSUNG 11: Share-Based File Registry (Privacy-First Architecture)

### Änderungen an fileRegistry.js:

```javascript
class FileRegistry {
  constructor() {
    // Map: fileId -> FileMetadata
    this.files = new Map();
    
    // Map: deviceKey (userId:deviceId) -> Set of fileIds
    this.deviceSeeds = new Map();  // ← GEÄNDERT: war userSeeds
    
    // Map: fileId -> Set of deviceKeys (userId:deviceId)
    this.fileSeeders = new Map();  // ← GEÄNDERT: enthält jetzt deviceKeys
    
    // Map: fileId -> Set of deviceKeys (downloader devices)
    this.fileLeechers = new Map();  // ← GEÄNDERT: enthält deviceKeys
    
    // TTL bleibt gleich
    this.FILE_TTL = 30 * 24 * 60 * 60 * 1000;
  }

  /**
   * Announce a file (specific device has chunks available)
   * 
   * @param {string} userId - User ID
   * @param {string} deviceId - Device ID
   * @param {object} fileMetadata - File metadata
   * @param {array} sharedWith - Array of userIds or channelIds to share with
   * @returns {object} Updated file info
   */
  announceFile(userId, deviceId, fileMetadata, sharedWith = []) {
    const { fileId, mimeType, fileSize, checksum, chunkCount, availableChunks } = fileMetadata;
    const deviceKey = `${userId}:${deviceId}`;
    
    // Get or create file entry
    let file = this.files.get(fileId);
    
    if (!file) {
      // New file announcement
      file = {
        fileId,
        mimeType,
        fileSize,
        checksum,
        chunkCount,
        sharedWith: new Set(sharedWith),  // ← NEU: Share scope
        createdAt: Date.now(),
        lastActivity: Date.now(),
        seeders: new Set(),  // deviceKeys
        leechers: new Set(),  // deviceKeys
        totalSeeds: 0,
        totalDownloads: 0,
      };
      this.files.set(fileId, file);
      this.fileSeeders.set(fileId, new Set());
      this.fileLeechers.set(fileId, new Set());
      
      console.log(`[FILE REGISTRY] New file ${fileId.substring(0, 16)}... shared with: ${Array.from(file.sharedWith).join(', ')}`);
    } else {
      // Update existing file
      file.lastActivity = Date.now();
      
      // Merge sharedWith (in case more targets added)
      if (sharedWith && sharedWith.length > 0) {
        sharedWith.forEach(target => file.sharedWith.add(target));
      }
    }
    
    // Add device as seeder
    file.seeders.add(deviceKey);
    this.fileSeeders.get(fileId).add(deviceKey);
    
    // Update device's seed list
    if (!this.deviceSeeds.has(deviceKey)) {
      this.deviceSeeds.set(deviceKey, new Set());
    }
    this.deviceSeeds.get(deviceKey).add(fileId);
    
    // Store available chunks for this device
    if (!file.seederChunks) {
      file.seederChunks = new Map();
    }
    file.seederChunks.set(deviceKey, availableChunks || []);
    
    file.totalSeeds++;
    
    console.log(`[FILE REGISTRY] Device ${deviceKey} now seeding ${fileId.substring(0, 16)}...`);
    
    return this.getFileInfo(fileId);
  }

  /**
   * Unannounce a file (specific device no longer seeding)
   * 
   * @param {string} userId - User ID
   * @param {string} deviceId - Device ID
   * @param {string} fileId - File ID
   * @returns {boolean} Success
   */
  unannounceFile(userId, deviceId, fileId) {
    const deviceKey = `${userId}:${deviceId}`;
    const file = this.files.get(fileId);
    if (!file) return false;
    
    // Remove device as seeder
    file.seeders.delete(deviceKey);
    this.fileSeeders.get(fileId)?.delete(deviceKey);
    
    // Remove from device's seed list
    this.deviceSeeds.get(deviceKey)?.delete(fileId);
    
    // Remove seeder chunks
    file.seederChunks?.delete(deviceKey);
    
    // Update activity
    file.lastActivity = Date.now();
    
    console.log(`[FILE REGISTRY] Device ${deviceKey} no longer seeding ${fileId.substring(0, 16)}...`);
    
    // If no more seeders, mark for cleanup
    if (file.seeders.size === 0) {
      file.noSeedersTimestamp = Date.now();
      console.log(`[FILE REGISTRY] File ${fileId.substring(0, 16)}... has no more seeders`);
    }
    
    return true;
  }

  /**
   * Check if user has access to file
   * 
   * @param {string} userId - User ID
   * @param {string} fileId - File ID
   * @param {array} userChannels - Array of channelIds user is member of
   * @returns {boolean} Has access
   */
  canAccessFile(userId, fileId, userChannels = []) {
    const file = this.files.get(fileId);
    if (!file) return false;
    
    // Check if shared directly with user
    if (file.sharedWith.has(userId)) {
      return true;
    }
    
    // Check if shared with any of user's channels
    for (const channelId of userChannels) {
      if (file.sharedWith.has(channelId)) {
        return true;
      }
    }
    
    return false;
  }

  /**
   * Get files accessible by user (based on sharedWith)
   * 
   * @param {string} userId - User ID
   * @param {array} userChannels - Array of channelIds user is member of
   * @returns {array} Array of file info
   */
  getAccessibleFiles(userId, userChannels = []) {
    const results = [];
    
    for (const file of this.files.values()) {
      // Skip files with no seeders
      if (file.seeders.size === 0) continue;
      
      // Check access
      if (this.canAccessFile(userId, file.fileId, userChannels)) {
        results.push(this.getFileInfo(file.fileId));
      }
    }
    
    return results;
  }

  /**
   * Handle device disconnect - clean up only this device's announcements
   * 
   * @param {string} userId - User ID
   * @param {string} deviceId - Device ID
   */
  handleDeviceDisconnect(userId, deviceId) {
    const deviceKey = `${userId}:${deviceId}`;
    const deviceFiles = this.deviceSeeds.get(deviceKey);
    
    if (!deviceFiles) return;
    
    console.log(`[FILE REGISTRY] Device ${deviceKey} disconnected, cleaning up ${deviceFiles.size} file(s)`);
    
    for (const fileId of deviceFiles) {
      this.unannounceFile(userId, deviceId, fileId);
    }
    
    // Remove from all leecher lists
    for (const [fileId, leechers] of this.fileLeechers.entries()) {
      if (leechers.has(deviceKey)) {
        this.unregisterLeecher(userId, deviceId, fileId);
      }
    }
    
    this.deviceSeeds.delete(deviceKey);
  }

  /**
   * Register device as downloading
   */
  registerLeecher(userId, deviceId, fileId) {
    const deviceKey = `${userId}:${deviceId}`;
    const file = this.files.get(fileId);
    if (!file) return false;
    
    file.leechers.add(deviceKey);
    this.fileLeechers.get(fileId).add(deviceKey);
    file.totalDownloads++;
    file.lastActivity = Date.now();
    
    return true;
  }

  /**
   * Unregister device as downloading
   */
  unregisterLeecher(userId, deviceId, fileId) {
    const deviceKey = `${userId}:${deviceId}`;
    const file = this.files.get(fileId);
    if (!file) return false;
    
    file.leechers.delete(deviceKey);
    this.fileLeechers.get(fileId).delete(deviceKey);
    file.lastActivity = Date.now();
    
    return true;
  }

  /**
   * Get available chunks with online device check
   * Uses deviceSockets to verify device is actually online
   * 
   * @param {string} fileId - File ID
   * @param {Map} deviceSockets - Map from server.js (userId:deviceId -> socketId)
   * @returns {object} Map of deviceKey -> { chunks, socketId }
   */
  getAvailableChunks(fileId, deviceSockets) {
    const file = this.files.get(fileId);
    if (!file || !file.seederChunks) return {};
    
    const result = {};
    
    for (const [deviceKey, chunks] of file.seederChunks.entries()) {
      // Check if device is actually online
      const socketId = deviceSockets.get(deviceKey);
      
      if (socketId) {
        result[deviceKey] = {
          chunks,
          socketId,  // ← Für direkte Socket-Kommunikation
        };
      } else {
        console.log(`[FILE REGISTRY] Seeder ${deviceKey} offline, skipping`);
      }
    }
    
    return result;
  }
}

module.exports = new FileRegistry();
```

---

## ✅ LÖSUNG 12: Server-Side Socket Handler Updates

### Änderungen an server.js:

```javascript
// ===== P2P FILE SHARING - Updated Handlers =====

/**
 * Announce a file with share scope
 */
socket.on("announceFile", async (data, callback) => {
  try {
    if (!socket.handshake.session.uuid || !socket.handshake.session.deviceId || 
        socket.handshake.session.authenticated !== true) {
      console.error('[P2P FILE] ERROR: Not authenticated');
      return callback?.({ success: false, error: "Not authenticated" });
    }

    const userId = socket.handshake.session.uuid;
    const deviceId = socket.handshake.session.deviceId;
    const { fileId, mimeType, fileSize, checksum, chunkCount, availableChunks, sharedWith } = data;

    // Validate sharedWith
    if (!sharedWith || !Array.isArray(sharedWith) || sharedWith.length === 0) {
      console.error('[P2P FILE] ERROR: sharedWith is required (userIds or channelIds)');
      return callback?.({ success: false, error: "Must specify who to share with (users or channels)" });
    }

    console.log(`[P2P FILE] Device ${userId}:${deviceId} announcing file: ${fileId.substring(0, 16)}...`);
    console.log(`[P2P FILE] Shared with: ${sharedWith.join(', ')}`);

    const fileInfo = fileRegistry.announceFile(userId, deviceId, {
      fileId,
      mimeType,
      fileSize,
      checksum,
      chunkCount,
      availableChunks
    }, sharedWith);

    callback?.({ success: true, fileInfo });

    // ← ÄNDERUNG: Nicht mehr broadcast, sondern targeted notify
    await notifyFileShared(fileId, sharedWith, {
      fileId,
      mimeType,
      fileSize,
      seederCount: fileInfo.seederCount,
      fromUserId: userId,
      fromDeviceId: deviceId,
    });

  } catch (error) {
    console.error('[P2P FILE] Error announcing file:', error);
    callback?.({ success: false, error: error.message });
  }
});

/**
 * Notify users/channels about shared file (targeted, not broadcast)
 */
async function notifyFileShared(fileId, sharedWith, fileInfo) {
  for (const target of sharedWith) {
    // Check if target is a channelId (starts with channel prefix or UUID pattern)
    const isChannel = target.includes('channel') || target.length > 40;
    
    if (isChannel) {
      // Get all channel members
      const members = await ChannelMembers.findAll({
        where: { channelId: target },
        include: [{ model: User, attributes: ['uuid'] }]
      });
      
      // Get all devices of channel members
      const memberUserIds = members.map(m => m.userId);
      const memberDevices = await Client.findAll({
        where: { owner: { [require('sequelize').Op.in]: memberUserIds } }
      });
      
      // Send to each online device
      for (const client of memberDevices) {
        const deviceKey = `${client.owner}:${client.device_id}`;
        const socketId = deviceSockets.get(deviceKey);
        
        if (socketId) {
          io.to(socketId).emit("fileShared", {
            ...fileInfo,
            sharedIn: 'channel',
            channelId: target,
          });
        }
      }
      
      console.log(`[P2P FILE] Notified ${memberDevices.length} devices in channel ${target}`);
      
    } else {
      // Target is a userId - get all their devices
      const userDevices = await Client.findAll({
        where: { owner: target }
      });
      
      for (const client of userDevices) {
        const deviceKey = `${client.owner}:${client.device_id}`;
        const socketId = deviceSockets.get(deviceKey);
        
        if (socketId) {
          io.to(socketId).emit("fileShared", {
            ...fileInfo,
            sharedIn: 'direct',
            fromUserId: fileInfo.fromUserId,
          });
        }
      }
      
      console.log(`[P2P FILE] Notified ${userDevices.length} devices of user ${target}`);
    }
  }
}

/**
 * Unannounce file - updated for device-based tracking
 */
socket.on("unannounceFile", async (data, callback) => {
  try {
    if (!socket.handshake.session.uuid || !socket.handshake.session.deviceId) {
      return callback?.({ success: false, error: "Not authenticated" });
    }

    const userId = socket.handshake.session.uuid;
    const deviceId = socket.handshake.session.deviceId;
    const { fileId } = data;

    console.log(`[P2P FILE] Device ${userId}:${deviceId} unannouncing file: ${fileId}`);

    const success = fileRegistry.unannounceFile(userId, deviceId, fileId);
    callback?.({ success });

  } catch (error) {
    console.error('[P2P FILE] Error unannouncing file:', error);
    callback?.({ success: false, error: error.message });
  }
});

/**
 * Get files accessible by current user
 */
socket.on("getAccessibleFiles", async (callback) => {
  try {
    if (!socket.handshake.session.uuid) {
      return callback?.({ success: false, error: "Not authenticated" });
    }

    const userId = socket.handshake.session.uuid;
    
    // Get user's channels
    const memberships = await ChannelMembers.findAll({
      where: { userId: userId },
      attributes: ['channelId']
    });
    const userChannels = memberships.map(m => m.channelId);
    
    const files = fileRegistry.getAccessibleFiles(userId, userChannels);
    
    callback?.({ success: true, files });

  } catch (error) {
    console.error('[P2P FILE] Error getting accessible files:', error);
    callback?.({ success: false, error: error.message });
  }
});

/**
 * Get available chunks - updated with deviceSockets check
 */
socket.on("getAvailableChunks", async (data, callback) => {
  try {
    const { fileId } = data;
    const userId = socket.handshake.session.uuid;
    
    // Check access
    const memberships = await ChannelMembers.findAll({
      where: { userId: userId },
      attributes: ['channelId']
    });
    const userChannels = memberships.map(m => m.channelId);
    
    if (!fileRegistry.canAccessFile(userId, fileId, userChannels)) {
      return callback?.({ success: false, error: "Access denied" });
    }
    
    // Get chunks with online check
    const chunks = fileRegistry.getAvailableChunks(fileId, deviceSockets);

    callback?.({ success: true, chunks });

  } catch (error) {
    console.error('[P2P FILE] Error getting available chunks:', error);
    callback?.({ success: false, error: error.message });
  }
});

/**
 * Updated disconnect handler - device-specific cleanup
 */
socket.on("disconnect", () => {
  if(socket.handshake.session.uuid && socket.handshake.session.deviceId) {
    const userId = socket.handshake.session.uuid;
    const deviceId = socket.handshake.session.deviceId;
    const deviceKey = `${userId}:${deviceId}`;
    
    deviceSockets.delete(deviceKey);
    
    // Clean up ONLY this device's file announcements
    fileRegistry.handleDeviceDisconnect(userId, deviceId);
    
    console.log(`[SERVER] Device ${deviceKey} disconnected, cleanup complete`);
  }
  
  // ... rest of disconnect logic ...
});
```

---

## ✅ LÖSUNG 13: Client-Side Updates

### Änderungen an socket_file_client.dart:

```dart
/// Announce file with share scope
Future<bool> announceFile({
  required String fileId,
  required String mimeType,
  required int fileSize,
  required String checksum,
  required int chunkCount,
  required List<int> availableChunks,
  required List<String> sharedWith,  // ← NEU: userIds oder channelIds
}) async {
  final completer = Completer<bool>();

  socket.emitWithAck('announceFile', {
    'fileId': fileId,
    'mimeType': mimeType,
    'fileSize': fileSize,
    'checksum': checksum,
    'chunkCount': chunkCount,
    'availableChunks': availableChunks,
    'sharedWith': sharedWith,  // ← NEU
  }, ack: (data) {
    if (data['success'] == true) {
      debugPrint('[FILE CLIENT] ✓ File announced to: ${sharedWith.join(", ")}');
      completer.complete(true);
    } else {
      debugPrint('[FILE CLIENT] ✗ Announce failed: ${data['error']}');
      completer.complete(false);
    }
  });

  return completer.future;
}

/// Get files shared with me (1:1 or channels)
Future<List<Map<String, dynamic>>> getAccessibleFiles() async {
  final completer = Completer<List<Map<String, dynamic>>>();
  
  socket.emitWithAck('getAccessibleFiles', null, ack: (data) {
    if (data['success'] == true) {
      final files = (data['files'] as List)
        .map((f) => Map<String, dynamic>.from(f))
        .toList();
      completer.complete(files);
    } else {
      completer.completeError(data['error'] ?? 'Failed to get files');
    }
  });
  
  return completer.future;
}

/// Listen for files shared with me
void onFileShared(Function(Map<String, dynamic> fileInfo) callback) {
  socket.on('fileShared', (data) {
    debugPrint('[FILE CLIENT] File shared with me: ${data['fileId']}');
    debugPrint('[FILE CLIENT] Shared in: ${data['sharedIn']}'); // 'direct' or 'channel'
    callback(Map<String, dynamic>.from(data));
  });
}

/// Get available chunks - now returns deviceKeys with online status
Future<Map<String, SeederInfo>> getAvailableChunks(String fileId) async {
  final completer = Completer<Map<String, SeederInfo>>();
  
  socket.emitWithAck('getAvailableChunks', {
    'fileId': fileId,
  }, ack: (data) {
    if (data['success'] == true) {
      final seeders = <String, SeederInfo>{};
      final rawChunks = data['chunks'] as Map;
      
      for (final entry in rawChunks.entries) {
        final deviceKey = entry.key as String;  // userId:deviceId
        final seederData = entry.value as Map;
        
        // Parse deviceKey
        final parts = deviceKey.split(':');
        final userId = parts[0];
        final deviceId = parts.length > 1 ? parts[1] : null;
        
        seeders[userId] = SeederInfo(
          chunks: List<int>.from(seederData['chunks']),
          deviceId: deviceId,  // ← NOW AVAILABLE
          socketId: seederData['socketId'] as String?,
        );
      }
      
      completer.complete(seeders);
    } else {
      completer.completeError(data['error'] ?? 'Failed to get chunks');
    }
  });
  
  return completer.future;
}

class SeederInfo {
  final List<int> chunks;
  final String? deviceId;  // ← NEU
  final String? socketId;  // ← NEU: für direkte Kommunikation
  
  SeederInfo({
    required this.chunks,
    this.deviceId,
    this.socketId,
  });
}
```

---

## ✅ LÖSUNG 14: UI Integration - File Sharing in Chats/Channels

### Implementation in direct_messages_screen.dart:

```dart
// Add share file button in message input area
IconButton(
  icon: Icon(Icons.attach_file),
  onPressed: () => _shareFileInChat(),
),

Future<void> _shareFileInChat() async {
  // Pick file from local storage
  final fileId = await _pickLocalFile();
  if (fileId == null) return;
  
  // Get file metadata
  final metadata = await storage.getFileMetadata(fileId);
  if (metadata == null) return;
  
  final fileName = metadata['fileName'] as String;
  final fileSize = metadata['fileSize'] as int;
  
  // Confirm share
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Share File'),
      content: Text('Share "$fileName" (${_formatSize(fileSize)}) with ${widget.otherUser.name}?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text('Share'),
        ),
      ],
    ),
  );
  
  if (confirmed != true) return;
  
  // Announce file with share scope
  final socketClient = SocketFileClient(socket: SocketService().socket!);
  
  final availableChunks = await storage.getAvailableChunks(fileId);
  
  final success = await socketClient.announceFile(
    fileId: fileId,
    mimeType: metadata['mimeType'] as String,
    fileSize: fileSize,
    checksum: metadata['checksum'] as String,
    chunkCount: metadata['chunkCount'] as int,
    availableChunks: availableChunks,
    sharedWith: [widget.otherUser.uuid],  // ← 1:1 share
  );
  
  if (success) {
    // Send message notification
    await _sendFileShareMessage(fileId, fileName, fileSize);
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('File shared with ${widget.otherUser.name}')),
    );
  }
}
```

### Implementation in signal_group_chat_screen.dart:

```dart
Future<void> _shareFileInChannel() async {
  // Similar flow but with channelId
  final success = await socketClient.announceFile(
    fileId: fileId,
    // ... metadata ...
    sharedWith: [widget.channelId],  // ← Channel share
  );
  
  if (success) {
    await _sendGroupFileShareMessage(fileId, fileName, fileSize);
  }
}
```

---

## 📋 Migration Plan

### Phase 1: Server-Side (Backend)
1. Update `fileRegistry.js` → device-based tracking
2. Update `server.js` handlers → announceFile, getAvailableChunks
3. Add `notifyFileShared()` function
4. Update disconnect handler

### Phase 2: Client-Side (Frontend)
5. Update `socket_file_client.dart` → new API
6. Update `p2p_coordinator.dart` → handle deviceKeys
7. Update UI screens → add share buttons

### Phase 3: Testing
8. Test 1:1 file share
9. Test channel file share
10. Test multi-device scenarios
11. Test disconnect cleanup

### Rollback Strategy:
- Keep old broadcasts for 1 week
- Dual API support (old + new)
- Feature flag: `USE_SHARE_BASED_FILES`

---

## 🎯 Zusammenfassung der Änderungen

| Component | Alt | Neu |
|-----------|-----|-----|
| **File Tracking** | userId | userId:deviceId (deviceKey) |
| **Share Scope** | broadcast (alle) | sharedWith: [userIds, channelIds] |
| **Discovery** | broadcast.emit() | targeted emit() |
| **Access Control** | keine | canAccessFile() check |
| **Disconnect** | löscht alle User-Files | löscht nur Device-Files |
| **Seeder Info** | chunks only | chunks + deviceId + socketId |

---

## 🔄 PROBLEM 4: File Sharing via Signal Messages (Chat-Integration)

### Aktuelles Problem:

1. **Kein Chat-basiertes File Sharing:**
   - Files können nur über separate File Browser geteilt werden
   - Keine Integration in 1:1 oder Channel Chats
   - User müssen zwischen Chat und File Manager wechseln

2. **Kein Message-basierter Discovery:**
   - Keine File-Nachrichten im Chat
   - Keine direkten Download-Links
   - Keine Metadata-Übertragung via Signal

3. **Kein In-Chat Upload:**
   - User können keine Files direkt aus Chat hochladen
   - Kein seamless UX wie WhatsApp/Telegram

### Gewünschter Flow:

#### **Flow 1: Share aus File Manager**
```
1. Alice öffnet File Manager
2. Alice wählt File aus → klickt "Share"
3. Dialog: "Share mit Bob (1:1)" oder "Share in #general (Channel)"
4. Alice wählt Bob
5. Signal Message (type: fileShare) wird an Bob gesendet
   - enthält: fileId, fileName, fileSize, mimeType, checksum, chunkCount
6. Bob sieht File-Message im Chat mit Download-Button
7. Bob klickt Download
8. Key Request via Signal (existing P2P flow)
9. Download startet via WebRTC
```

#### **Flow 2: Direct Upload aus Chat**
```
1. Bob öffnet Chat mit Alice
2. Bob klickt Attach-Button (📎)
3. File Picker öffnet sich
4. Bob wählt File (z.B. photo.jpg)
5. File wird lokal gespeichert (IndexedDB)
6. Signal Message (type: fileShare) wird automatisch gesendet
7. Alice sieht File-Message im Chat
8. Alice klickt Download → WebRTC Transfer
```

#### **Flow 3: Channel File Upload**
```
1. Bob öffnet #general Channel
2. Bob klickt Attach-Button
3. File wird hochgeladen
4. Signal Group Message (type: fileShare) via Sender Key
5. Alle Channel Members sehen File-Message
6. Downloads via WebRTC P2P
```

---

## ✅ LÖSUNG 15: Signal Message Type für File Sharing

### Neuer Message Type in Signal Protocol:

```dart
// In signal_service.dart oder message types

enum SignalMessageType {
  text,
  image,
  fileShare,  // ← NEU
  reaction,
  readReceipt,
  // ...
}

class FileShareMessage {
  final String fileId;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final String checksum;
  final int chunkCount;
  final String? thumbnailBase64;  // Optional preview
  final DateTime sharedAt;
  
  FileShareMessage({
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.checksum,
    required this.chunkCount,
    this.thumbnailBase64,
    required this.sharedAt,
  });
  
  Map<String, dynamic> toJson() => {
    'fileId': fileId,
    'fileName': fileName,
    'fileSize': fileSize,
    'mimeType': mimeType,
    'checksum': checksum,
    'chunkCount': chunkCount,
    'thumbnailBase64': thumbnailBase64,
    'sharedAt': sharedAt.toIso8601String(),
  };
  
  factory FileShareMessage.fromJson(Map<String, dynamic> json) {
    return FileShareMessage(
      fileId: json['fileId'] as String,
      fileName: json['fileName'] as String,
      fileSize: json['fileSize'] as int,
      mimeType: json['mimeType'] as String,
      checksum: json['checksum'] as String,
      chunkCount: json['chunkCount'] as int,
      thumbnailBase64: json['thumbnailBase64'] as String?,
      sharedAt: DateTime.parse(json['sharedAt'] as String),
    );
  }
}
```

---

## ✅ LÖSUNG 16: File Manager Share UI

### Implementation in file_manager_screen.dart:

```dart
// Add share button to file card
Widget _buildFileCard(Map<String, dynamic> file) {
  return Card(
    child: ListTile(
      // ... existing UI ...
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Share Button
          IconButton(
            icon: Icon(Icons.share),
            tooltip: 'Share File',
            onPressed: () => _showShareDialog(file),
          ),
          // ... existing buttons ...
        ],
      ),
    ),
  );
}

/// Show dialog to select share target (1:1 or Channel)
Future<void> _showShareDialog(Map<String, dynamic> file) async {
  final fileId = file['fileId'] as String;
  final fileName = file['fileName'] as String;
  final fileSize = file['fileSize'] as int;
  
  showModalBottomSheet(
    context: context,
    builder: (context) => ShareTargetSelector(
      fileId: fileId,
      fileName: fileName,
      fileSize: fileSize,
      onShare: (target) => _shareFile(file, target),
    ),
  );
}

/// Share file with selected target
Future<void> _shareFile(
  Map<String, dynamic> file,
  ShareTarget target,
) async {
  try {
    final fileId = file['fileId'] as String;
    final fileName = file['fileName'] as String;
    final fileSize = file['fileSize'] as int;
    final mimeType = file['mimeType'] as String;
    final checksum = file['checksum'] as String;
    final chunkCount = file['chunkCount'] as int;
    
    // Create FileShareMessage
    final fileShareMsg = FileShareMessage(
      fileId: fileId,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      checksum: checksum,
      chunkCount: chunkCount,
      sharedAt: DateTime.now(),
    );
    
    // Send via Signal
    if (target.isUser) {
      // 1:1 Share
      await _sendFileShareMessage1to1(
        target.userId!,
        target.deviceId!,
        fileShareMsg,
      );
    } else if (target.isChannel) {
      // Channel Share
      await _sendFileShareMessageChannel(
        target.channelId!,
        fileShareMsg,
      );
    }
    
    // Update local storage: mark as shared
    await storage.updateFileMetadata(fileId, {
      'sharedWith': target.isUser ? target.userId : target.channelId,
      'sharedAt': DateTime.now().toIso8601String(),
    });
    
    // Show confirmation
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('File shared: $fileName'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context); // Close share dialog
    }
    
  } catch (e) {
    debugPrint('[FILE MANAGER] Error sharing file: $e');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to share file: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}

/// Send file share message (1:1)
Future<void> _sendFileShareMessage1to1(
  String recipientUserId,
  int recipientDeviceId,
  FileShareMessage fileMsg,
) async {
  final signalService = SignalService.instance;
  
  // Encrypt message payload
  final plaintext = jsonEncode(fileMsg.toJson());
  
  await signalService.sendMessage(
    recipientUserId: recipientUserId,
    recipientDeviceId: recipientDeviceId,
    message: plaintext,
    type: 'fileShare',  // ← NEU
  );
  
  debugPrint('[FILE SHARE] Sent to $recipientUserId:$recipientDeviceId');
}

/// Send file share message (Channel)
Future<void> _sendFileShareMessageChannel(
  String channelId,
  FileShareMessage fileMsg,
) async {
  final signalService = SignalService.instance;
  
  // Encrypt with Sender Key
  final plaintext = jsonEncode(fileMsg.toJson());
  
  await signalService.sendGroupMessage(
    channelId: channelId,
    message: plaintext,
    type: 'fileShare',  // ← NEU
  );
  
  debugPrint('[FILE SHARE] Sent to channel $channelId');
}
```

### ShareTargetSelector Widget:

```dart
class ShareTargetSelector extends StatefulWidget {
  final String fileId;
  final String fileName;
  final int fileSize;
  final Function(ShareTarget) onShare;
  
  const ShareTargetSelector({
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.onShare,
    Key? key,
  }) : super(key: key);
  
  @override
  State<ShareTargetSelector> createState() => _ShareTargetSelectorState();
}

class _ShareTargetSelectorState extends State<ShareTargetSelector> {
  List<User> _recentChats = [];
  List<Channel> _channels = [];
  bool _isLoading = true;
  
  @override
  void initState() {
    super.initState();
    _loadTargets();
  }
  
  Future<void> _loadTargets() async {
    // Load recent 1:1 chats
    // Load user's channels
    setState(() => _isLoading = false);
  }
  
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.share, color: Theme.of(context).primaryColor),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Share File',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      widget.fileName,
                      style: Theme.of(context).textTheme.bodyMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _formatSize(widget.fileSize),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 24),
          
          // Recent Chats Section
          Text('Recent Chats', style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: 8),
          ..._recentChats.map((user) => ListTile(
            leading: CircleAvatar(child: Text(user.name[0])),
            title: Text(user.name),
            onTap: () => widget.onShare(ShareTarget.user(user.uuid, user.deviceId)),
          )),
          
          SizedBox(height: 16),
          
          // Channels Section
          Text('Channels', style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: 8),
          ..._channels.map((channel) => ListTile(
            leading: Icon(Icons.tag),
            title: Text(channel.name),
            onTap: () => widget.onShare(ShareTarget.channel(channel.id)),
          )),
        ],
      ),
    );
  }
  
  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class ShareTarget {
  final String? userId;
  final int? deviceId;
  final String? channelId;
  
  bool get isUser => userId != null;
  bool get isChannel => channelId != null;
  
  ShareTarget.user(this.userId, this.deviceId) : channelId = null;
  ShareTarget.channel(this.channelId) : userId = null, deviceId = null;
}
```

---

## ✅ LÖSUNG 17: Direct File Upload from Chat

### Implementation in direct_messages_screen.dart:

```dart
// Add attach button to message input
Widget _buildMessageInput() {
  return Row(
    children: [
      // Attach File Button
      IconButton(
        icon: Icon(Icons.attach_file),
        onPressed: _handleFileAttach,
        tooltip: 'Attach File',
      ),
      
      // Text input
      Expanded(
        child: TextField(
          controller: _messageController,
          decoration: InputDecoration(hintText: 'Type a message...'),
        ),
      ),
      
      // Send button
      IconButton(
        icon: Icon(Icons.send),
        onPressed: _sendMessage,
      ),
    ],
  );
}

/// Handle file attach button press
Future<void> _handleFileAttach() async {
  try {
    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Preparing file...'),
          ],
        ),
      ),
    );
    
    // Pick file
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.any,
    );
    
    if (result == null || result.files.isEmpty) {
      Navigator.pop(context); // Close loading dialog
      return;
    }
    
    final file = result.files.first;
    final fileBytes = file.bytes;
    
    if (fileBytes == null) {
      throw Exception('Failed to read file data');
    }
    
    // Check file size
    final maxSize = FileTransferConfig.getMaxFileSize();
    if (file.size > maxSize) {
      Navigator.pop(context);
      await showFileSizeErrorDialog(context, file.size, file.name);
      return;
    }
    
    // Store file locally
    final fileId = await _storeFileLocally(file.name, fileBytes);
    
    // Get file metadata
    final metadata = await storage.getFileMetadata(fileId);
    
    Navigator.pop(context); // Close loading dialog
    
    // Send file share message
    await _sendFileShareMessage(metadata!);
    
    // Show success
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('File shared: ${file.name}'),
        backgroundColor: Colors.green,
      ),
    );
    
  } catch (e) {
    Navigator.pop(context); // Close loading dialog if open
    debugPrint('[CHAT] Error attaching file: $e');
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Failed to attach file: $e'),
        backgroundColor: Colors.red,
      ),
    );
  }
}

/// Store file locally in IndexedDB
Future<String> _storeFileLocally(String fileName, Uint8List fileBytes) async {
  final fileId = '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(999999999)}';
  
  // Chunk and encrypt file
  final chunks = chunkingService.chunkFile(fileBytes);
  final fileKey = encryptionService.generateFileKey();
  final checksum = chunkingService.calculateFileChecksum(fileBytes);
  
  // Save metadata
  await storage.saveFileMetadata({
    'fileId': fileId,
    'fileName': fileName,
    'mimeType': lookupMimeType(fileName) ?? 'application/octet-stream',
    'fileSize': fileBytes.length,
    'checksum': checksum,
    'chunkCount': chunks.length,
    'status': 'completed',
    'isSeeder': true,  // We are seeding this file
    'createdAt': DateTime.now().toIso8601String(),
    'lastActivity': DateTime.now().toIso8601String(),
  });
  
  // Save encryption key
  await storage.saveFileKey(fileId, fileKey);
  
  // Encrypt and save chunks
  for (int i = 0; i < chunks.length; i++) {
    final encryptedChunk = await encryptionService.encryptChunk(chunks[i], fileKey);
    await storage.saveChunk(fileId, i, encryptedChunk);
  }
  
  debugPrint('[CHAT] File stored locally: $fileId ($fileName, ${fileBytes.length} bytes)');
  
  return fileId;
}

/// Send file share message
Future<void> _sendFileShareMessage(Map<String, dynamic> metadata) async {
  final fileShareMsg = FileShareMessage(
    fileId: metadata['fileId'] as String,
    fileName: metadata['fileName'] as String,
    fileSize: metadata['fileSize'] as int,
    mimeType: metadata['mimeType'] as String,
    checksum: metadata['checksum'] as String,
    chunkCount: metadata['chunkCount'] as int,
    sharedAt: DateTime.now(),
  );
  
  // Send via Signal (1:1)
  final signalService = SignalService.instance;
  await signalService.sendMessage(
    recipientUserId: widget.otherUser.uuid,
    recipientDeviceId: widget.otherUser.deviceId,
    message: jsonEncode(fileShareMsg.toJson()),
    type: 'fileShare',
  );
  
  debugPrint('[CHAT] File share message sent');
}
```

### Implementation in signal_group_chat_screen.dart:

```dart
/// Channel file upload (similar to 1:1 but with Sender Key)
Future<void> _handleFileAttach() async {
  // ... same file picking and storage logic ...
  
  // Send via Sender Key
  final fileShareMsg = FileShareMessage(/*...*/);
  
  await signalService.sendGroupMessage(
    channelId: widget.channelId,
    message: jsonEncode(fileShareMsg.toJson()),
    type: 'fileShare',
  );
}
```

---

## ✅ LÖSUNG 18: File Message Rendering in Chat

### File Message Widget:

```dart
class FileMessageBubble extends StatelessWidget {
  final FileShareMessage fileMsg;
  final bool isSender;
  final VoidCallback onDownload;
  
  const FileMessageBubble({
    required this.fileMsg,
    required this.isSender,
    required this.onDownload,
    Key? key,
  }) : super(key: key);
  
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isSender ? Colors.blue[100] : Colors.grey[200],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // File Icon + Info
          Row(
            children: [
              Icon(
                _getFileIcon(fileMsg.mimeType),
                size: 40,
                color: Theme.of(context).primaryColor,
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileMsg.fileName,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: 4),
                    Text(
                      _formatSize(fileMsg.fileSize),
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          
          SizedBox(height: 12),
          
          // Download Button (only for receiver)
          if (!isSender)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onDownload,
                icon: Icon(Icons.download),
                label: Text('Download'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          
          // Already Shared indicator (for sender)
          if (isSender)
            Row(
              children: [
                Icon(Icons.check_circle, size: 16, color: Colors.green),
                SizedBox(width: 4),
                Text(
                  'Shared',
                  style: TextStyle(color: Colors.green, fontSize: 12),
                ),
              ],
            ),
          
          // Timestamp
          SizedBox(height: 4),
          Text(
            _formatTime(fileMsg.sharedAt),
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }
  
  IconData _getFileIcon(String mimeType) {
    if (mimeType.startsWith('image/')) return Icons.image;
    if (mimeType.startsWith('video/')) return Icons.video_file;
    if (mimeType.startsWith('audio/')) return Icons.audio_file;
    if (mimeType.contains('pdf')) return Icons.picture_as_pdf;
    if (mimeType.contains('zip') || mimeType.contains('archive')) return Icons.archive;
    return Icons.insert_drive_file;
  }
  
  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  
  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    
    return '${time.day}/${time.month}/${time.year}';
  }
}
```

### Integration in direct_messages_screen.dart:

```dart
Widget _buildMessageBubble(Map<String, dynamic> message) {
  final type = message['type'] as String?;
  final isSender = message['sender'] == SignalService.instance.currentUserId;
  
  // Check if file share message
  if (type == 'fileShare') {
    final payload = jsonDecode(message['payload'] as String);
    final fileMsg = FileShareMessage.fromJson(payload);
    
    return FileMessageBubble(
      fileMsg: fileMsg,
      isSender: isSender,
      onDownload: () => _handleFileDownload(fileMsg),
    );
  }
  
  // Regular text message
  return TextMessageBubble(/*...*/);
}

/// Handle file download from chat
Future<void> _handleFileDownload(FileShareMessage fileMsg) async {
  try {
    debugPrint('[CHAT] Starting file download: ${fileMsg.fileName}');
    
    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Downloading ${fileMsg.fileName}...'),
          ],
        ),
      ),
    );
    
    // Start P2P download (same as file_browser_screen)
    final p2pCoordinator = Provider.of<P2PCoordinator>(context, listen: false);
    
    // Request encryption key via Signal (existing P2P flow)
    await p2pCoordinator.startDownloadWithKeyRequest(
      fileId: fileMsg.fileId,
      fileName: fileMsg.fileName,
      mimeType: fileMsg.mimeType,
      fileSize: fileMsg.fileSize,
      checksum: fileMsg.checksum,
      chunkCount: fileMsg.chunkCount,
      seederChunks: {
        widget.otherUser.uuid: List.generate(fileMsg.chunkCount, (i) => i),
      },
    );
    
    Navigator.pop(context); // Close loading dialog
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Download started: ${fileMsg.fileName}'),
        backgroundColor: Colors.green,
      ),
    );
    
  } catch (e) {
    Navigator.pop(context); // Close loading dialog
    debugPrint('[CHAT] File download error: $e');
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Download failed: $e'),
        backgroundColor: Colors.red,
      ),
    );
  }
}
```

---

## ✅ LÖSUNG 19: Message Listener für File Share Messages

### Update in message_listener_service.dart:

```dart
void _handleReceiveItem(dynamic data) {
  final type = data['type'] as String?;
  final payload = data['payload'] as String?;
  
  // Check for file share message
  if (type == 'fileShare' && payload != null) {
    debugPrint('[MESSAGE_LISTENER] Received file share message');
    
    try {
      final fileShareData = jsonDecode(payload);
      final fileMsg = FileShareMessage.fromJson(fileShareData);
      
      // Notify UI about new file share
      _notifyFileShareReceived(fileMsg, data);
      
    } catch (e) {
      debugPrint('[MESSAGE_LISTENER] Error parsing file share: $e');
    }
    
    return;
  }
  
  // Handle other message types...
}

void _notifyFileShareReceived(FileShareMessage fileMsg, dynamic messageData) {
  // Store in local message database for chat display
  // Trigger UI update
  // Show notification
  
  debugPrint('[MESSAGE_LISTENER] File share notification: ${fileMsg.fileName}');
}
```

### Update in signal_group_chat_screen.dart:

```dart
void _handleGroupItem(dynamic data) {
  final type = data['type'] as String?;
  
  if (type == 'fileShare') {
    final payload = jsonDecode(data['payload'] as String);
    final fileMsg = FileShareMessage.fromJson(payload);
    
    setState(() {
      _messages.add({
        'type': 'fileShare',
        'fileMsg': fileMsg,
        'sender': data['sender'],
        'timestamp': data['timestamp'],
      });
    });
  }
}
```

---

## 📋 Implementation Checklist - File Sharing via Signal

### Phase 1: Message Types & Core Logic
- [ ] Define `FileShareMessage` class
- [ ] Update `SignalMessageType` enum
- [ ] Add file share serialization/deserialization
- [ ] Test Signal encryption for file metadata

### Phase 2: File Manager Integration
- [ ] Add Share button to file cards
- [ ] Implement `ShareTargetSelector` widget
- [ ] Implement `_shareFile()` method
- [ ] Add 1:1 and Channel share flows
- [ ] Test file sharing from File Manager

### Phase 3: Chat Upload Integration
- [ ] Add attach button to DM screen
- [ ] Add attach button to Group screen
- [ ] Implement `_handleFileAttach()` method
- [ ] Implement `_storeFileLocally()` method
- [ ] Test direct file upload from chat

### Phase 4: Chat Rendering
- [ ] Create `FileMessageBubble` widget
- [ ] Integrate in `_buildMessageBubble()`
- [ ] Add download button logic
- [ ] Test file message display

### Phase 5: Download from Chat
- [ ] Implement `_handleFileDownload()` method
- [ ] Reuse P2P download flow from file_browser
- [ ] Test key request via Signal
- [ ] Test WebRTC transfer

### Phase 6: Message Listener
- [ ] Update `_handleReceiveItem()` for fileShare type
- [ ] Update `_handleGroupItem()` for fileShare type
- [ ] Add notification support
- [ ] Test real-time file share reception

### Phase 7: Testing
- [ ] Test 1:1 file share (Alice → Bob)
- [ ] Test Channel file share (Alice → #general)
- [ ] Test direct upload from DM
- [ ] Test direct upload from Channel
- [ ] Test multi-device scenarios
- [ ] Test offline/online transitions

---

## 🎯 User Experience Flow Diagram

```
┌─────────────────────────────────────────────────────────┐
│              FILE SHARING VIA CHAT                      │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  METHOD 1: Share from File Manager                     │
│  ┌──────────────────────────────────────────────────┐  │
│  │ 1. Open File Manager                             │  │
│  │ 2. Click "Share" on file                         │  │
│  │ 3. Select target (Bob or #channel)               │  │
│  │ 4. Signal Message sent (encrypted metadata)      │  │
│  │ 5. Receiver sees file in chat                    │  │
│  │ 6. Click Download → P2P transfer                 │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  METHOD 2: Direct Upload from Chat                     │
│  ┌──────────────────────────────────────────────────┐  │
│  │ 1. Open Chat (1:1 or Channel)                    │  │
│  │ 2. Click Attach button (📎)                      │  │
│  │ 3. Select file from device                       │  │
│  │ 4. File stored locally (IndexedDB)               │  │
│  │ 5. Signal Message auto-sent                      │  │
│  │ 6. Receiver sees file instantly in chat          │  │
│  │ 7. Click Download → P2P transfer                 │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  TECHNICAL FLOW:                                        │
│  ┌──────────────────────────────────────────────────┐  │
│  │ Sender: File Metadata → Signal Encryption       │  │
│  │         → Socket.IO → Receiver                   │  │
│  │                                                  │  │
│  │ Receiver: Decrypt Metadata → Display in Chat    │  │
│  │           → User clicks Download                 │  │
│  │           → Key Request (Signal)                 │  │
│  │           → WebRTC P2P Transfer                  │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

**Erstellt am:** 2025-10-29  
**Letzte Aktualisierung:** 2025-10-29 (Problem 4 hinzugefügt - Chat File Sharing)  
**Status:** TODO - Nicht implementiert  
**Priorität:** HOCH (Kernfeature für UX)
