# P2P SharedWith Merge Implementation

## 📋 Overview

**Goal:** Implement democratic P2P file sharing where any downloader can expand the share list, with automatic synchronization across all holders via WebSocket and Signal messages.

**Approved Parameters:**
- ✅ Maximum `sharedWith` size: **1000 users**
- ✅ Anonymous sharing (no history tracking)
- ✅ No rate limiting (keep it simple)

---

## 🎯 Core Principles

1. **Any seeder can expand sharedWith** - Reality of P2P
2. **Server merges all announcements** - Union of all lists
3. **No removal mechanism** - Users self-remove by deleting locally
4. **Hybrid sync** - WebSocket (online) + Signal (offline) + Query (reconnect)
5. **Uploader can only delete own chunks** - No global delete authority
6. **Anonymous** - No tracking of who added whom
7. **1000 user limit** - Prevent memory/performance issues

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Client Side                              │
├─────────────────────────────────────────────────────────────┤
│  Before Re-announcement:                                    │
│  1. Query server for current sharedWith                     │
│  2. Check Signal messages for updates                       │
│  3. Merge with local sharedWith                             │
│  4. Announce with merged list                               │
├─────────────────────────────────────────────────────────────┤
│  Real-time Updates:                                         │
│  - Listen: file:sharedWith-updated (WebSocket)              │
│  - Handle: file:sharedWith-update (Signal)                  │
│  - Update local storage on both channels                    │
└─────────────────────────────────────────────────────────────┘
                              ↕
┌─────────────────────────────────────────────────────────────┐
│                    Server Side                              │
├─────────────────────────────────────────────────────────────┤
│  FileRegistry:                                              │
│  - Merge sharedWith on reannounce (union)                   │
│  - Enforce 1000 user limit                                  │
│  - Broadcast to online seeders (WebSocket)                  │
│  - Send Signal messages to offline holders                  │
├─────────────────────────────────────────────────────────────┤
│  Socket Events:                                             │
│  - announceFile: Merge and broadcast                        │
│  - file:get-sharedWith: Query current state                 │
│  - file:sharedWith-updated: Notify online users             │
└─────────────────────────────────────────────────────────────┘
```

---

## 📦 Implementation Steps

### **Phase 1: Server - FileRegistry Merge Logic**

#### File: `server/store/fileRegistry.js`

**Changes:**
1. Add merge logic to `reannounceFile()`
2. Enforce 1000 user limit
3. Return updated `sharedWith` list

```javascript
/**
 * Re-announce a file (add/update seeder)
 * Merges sharedWith lists from all seeders
 */
reannounceFile(fileId, seederUserId, seederDeviceId, seederSocketId, metadata) {
  const file = this.files.get(fileId);
  
  if (!file) {
    console.log(`[FileRegistry] Cannot reannounce non-existent file: ${fileId}`);
    return null;
  }
  
  // MERGE sharedWith lists (union)
  const newSharedWith = metadata.sharedWith || [];
  const currentSharedWith = file.sharedWith || [];
  
  // Combine and deduplicate
  const mergedSharedWith = [...new Set([...currentSharedWith, ...newSharedWith])];
  
  // Enforce 1000 user limit
  if (mergedSharedWith.length > 1000) {
    console.warn(`[FileRegistry] sharedWith list too large (${mergedSharedWith.length}), truncating to 1000`);
    file.sharedWith = mergedSharedWith.slice(0, 1000);
  } else {
    file.sharedWith = mergedSharedWith;
  }
  
  // Update or add seeder
  const existingSeederIndex = file.seeders.findIndex(
    s => s.userId === seederUserId && s.deviceId === seederDeviceId
  );
  
  const seederData = {
    userId: seederUserId,
    deviceId: seederDeviceId,
    socketId: seederSocketId,
    availableChunks: metadata.availableChunks || [],
    chunkQuality: metadata.chunkQuality || 0,
    lastSeen: Date.now(),
  };
  
  if (existingSeederIndex >= 0) {
    file.seeders[existingSeederIndex] = seederData;
  } else {
    file.seeders.push(seederData);
  }
  
  file.lastActivity = Date.now();
  
  console.log(`[FileRegistry] Reannounced ${fileId} by ${seederUserId} (device ${seederDeviceId})`);
  console.log(`[FileRegistry] Merged sharedWith: ${file.sharedWith.length} users`);
  
  return {
    success: true,
    sharedWith: file.sharedWith,
    seedersCount: file.seeders.length
  };
}

/**
 * Get current sharedWith list for a file
 */
getSharedWith(fileId) {
  const file = this.files.get(fileId);
  return file ? file.sharedWith : null;
}
```

---

### **Phase 2: Server - Socket Event Handlers**

#### File: `server/server.js`

**Add new event: `file:get-sharedWith`**

```javascript
// Query current sharedWith list (for sync before reannouncement)
socket.on('file:get-sharedWith', (data, callback) => {
  try {
    const { fileId } = data;
    
    if (!fileId) {
      return callback({ success: false, error: 'Missing fileId' });
    }
    
    const sharedWith = fileRegistry.getSharedWith(fileId);
    
    if (sharedWith !== null) {
      callback({
        success: true,
        sharedWith: sharedWith
      });
    } else {
      callback({ success: false, error: 'File not found' });
    }
  } catch (error) {
    console.error('[SOCKET] Error getting sharedWith:', error);
    callback({ success: false, error: error.message });
  }
});
```

**Update `announceFile` event:**

```javascript
socket.on('announceFile', async (data, callback) => {
  try {
    const { fileId, mimeType, fileSize, checksum, chunkCount, availableChunks, sharedWith } = data;
    
    // Validation...
    
    const existingFile = fileRegistry.getFile(fileId);
    
    if (existingFile) {
      // REANNOUNCEMENT - Merge sharedWith
      const result = fileRegistry.reannounceFile(
        fileId,
        userId,
        deviceId,
        socket.id,
        {
          availableChunks,
          chunkQuality,
          sharedWith // Pass for merging
        }
      );
      
      if (!result) {
        return callback({ success: false, error: 'Reannouncement failed' });
      }
      
      // Broadcast updated sharedWith to all online seeders (WebSocket)
      const seeders = fileRegistry.getSeeders(fileId);
      seeders.forEach(seeder => {
        if (seeder.socketId !== socket.id) { // Don't notify sender
          io.to(seeder.socketId).emit('file:sharedWith-updated', {
            fileId,
            sharedWith: result.sharedWith
          });
        }
      });
      
      // Send Signal messages to all holders (async, non-blocking)
      setImmediate(() => {
        sendSharedWithUpdateSignal(fileId, result.sharedWith).catch(err => {
          console.error('[SIGNAL] Error sending sharedWith update:', err);
        });
      });
      
      console.log(`[P2P FILE] Notifying ${sharedUsers.length} authorized users about file reannouncement`);
      
      // Notify authorized users about reannouncement
      sharedUsers.forEach(targetUserId => {
        const userSockets = activeConnections.get(targetUserId);
        if (userSockets) {
          userSockets.forEach(targetSocket => {
            io.to(targetSocket).emit('file:available', {
              fileId,
              mimeType,
              fileSize,
              checksum,
              chunkCount,
              seedersCount: seeders.length,
              chunkQuality,
              uploaderId: existingFile.uploaderId,
              sharedWith: result.sharedWith // Send merged list
            });
          });
        }
      });
      
      callback({ 
        success: true, 
        chunkQuality,
        sharedWith: result.sharedWith // Return merged list to client
      });
      
    } else {
      // NEW FILE - First announcement
      // ... existing code ...
      
      fileRegistry.addFile(fileId, userId, {
        mimeType,
        fileSize,
        checksum,
        chunkCount,
        uploaderId: userId,
        uploaderDeviceId: deviceId,
        uploaderSocketId: socket.id,
        sharedWith: sharedWith || [], // Initial sharedWith
        availableChunks,
        chunkQuality
      });
      
      // ... rest of existing code ...
    }
  } catch (error) {
    console.error('[SOCKET] Error in announceFile:', error);
    callback({ success: false, error: error.message });
  }
});
```

**Add Signal message helper function:**

```javascript
/**
 * Send Signal messages to all users in sharedWith list about update
 */
async function sendSharedWithUpdateSignal(fileId, sharedWith) {
  try {
    console.log(`[SIGNAL] Sending sharedWith update for ${fileId} to ${sharedWith.length} users`);
    
    for (const userId of sharedWith) {
      try {
        // Create encrypted Signal message
        const message = {
          type: 'file:sharedWith-update',
          fileId: fileId,
          sharedWith: sharedWith,
          timestamp: Date.now()
        };
        
        // Send via existing Signal message infrastructure
        await sendSignalMessage(userId, message);
        
      } catch (err) {
        console.error(`[SIGNAL] Failed to send update to ${userId}:`, err);
        // Continue with other users
      }
    }
    
    console.log(`[SIGNAL] Completed sending sharedWith updates for ${fileId}`);
  } catch (error) {
    console.error('[SIGNAL] Error in sendSharedWithUpdateSignal:', error);
  }
}
```

---

### **Phase 3: Client - File Reannounce Service**

#### File: `client/lib/services/file_transfer/file_reannounce_service.dart`

**Update `reannounceFile()` to sync before announcement:**

```dart
/// Re-announce a single file (with sharedWith sync)
Future<bool> reannounceFile(String fileId) async {
  try {
    final fileMetadata = await storage.getFileMetadata(fileId);
    
    if (fileMetadata == null) {
      debugPrint('[REANNOUNCE] File not found: $fileId');
      return false;
    }
    
    // STEP 1: Query server for current sharedWith state
    try {
      final serverSharedWith = await socketClient.getSharedWith(fileId);
      if (serverSharedWith != null) {
        debugPrint('[REANNOUNCE] Server sharedWith: ${serverSharedWith.length} users');
        
        // Merge with local sharedWith
        final localSharedWith = (fileMetadata['sharedWith'] as List?)?.cast<String>() ?? [];
        final mergedSharedWith = {...localSharedWith, ...serverSharedWith}.toList();
        
        // Update local storage
        await storage.updateFileMetadata(fileId, {
          'sharedWith': mergedSharedWith,
        });
        
        debugPrint('[REANNOUNCE] Merged sharedWith: ${mergedSharedWith.length} users');
      }
    } catch (e) {
      debugPrint('[REANNOUNCE] Warning: Could not sync sharedWith from server: $e');
      // Continue with local sharedWith
    }
    
    // STEP 2: Check Signal messages for updates (async, don't block)
    _checkSignalMessagesForSharedWithUpdates(fileId).catchError((e) {
      debugPrint('[REANNOUNCE] Warning: Could not check Signal messages: $e');
    });
    
    // STEP 3: Get final sharedWith from storage
    final updatedMetadata = await storage.getFileMetadata(fileId);
    final sharedWith = (updatedMetadata['sharedWith'] as List?)?.cast<String>();
    
    // Get available chunks
    final availableChunks = await storage.getAvailableChunks(fileId);
    
    if (availableChunks.isEmpty) {
      debugPrint('[REANNOUNCE] No chunks available for: $fileId');
      return false;
    }
    
    // STEP 4: Announce with merged sharedWith
    final result = await socketClient.announceFile(
      fileId: fileId,
      mimeType: updatedMetadata['mimeType'] as String? ?? 'application/octet-stream',
      fileSize: updatedMetadata['fileSize'] as int? ?? 0,
      checksum: updatedMetadata['checksum'] as String? ?? '',
      chunkCount: updatedMetadata['chunkCount'] as int? ?? 0,
      availableChunks: availableChunks,
      sharedWith: sharedWith, // Send merged list
    );
    
    // STEP 5: Update local storage with server's final merged list
    if (result['sharedWith'] != null) {
      await storage.updateFileMetadata(fileId, {
        'sharedWith': result['sharedWith'],
        'lastActivity': DateTime.now().toIso8601String(),
      });
      
      debugPrint('[REANNOUNCE] Updated local sharedWith from server: ${result['sharedWith'].length} users');
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

/// Check Signal messages for sharedWith updates (async helper)
Future<void> _checkSignalMessagesForSharedWithUpdates(String fileId) async {
  // This will be handled by MessageListenerService
  // Just a placeholder for future integration
  debugPrint('[REANNOUNCE] Checking Signal messages for $fileId updates...');
}
```

**Update `reannounceAllFiles()` similarly:**

```dart
// In the loop where we reannounce files:

// STEP 1: Query server for current sharedWith
try {
  final serverSharedWith = await socketClient.getSharedWith(fileId);
  if (serverSharedWith != null) {
    final localSharedWith = (fileMetadata['sharedWith'] as List?)?.cast<String>() ?? [];
    final mergedSharedWith = {...localSharedWith, ...serverSharedWith}.toList();
    
    await storage.updateFileMetadata(fileId, {
      'sharedWith': mergedSharedWith,
    });
    
    fileMetadata['sharedWith'] = mergedSharedWith; // Update in-memory
  }
} catch (e) {
  debugPrint('[REANNOUNCE] Warning: Could not sync sharedWith for $fileId: $e');
}

// Then proceed with announcement using merged sharedWith
```

---

### **Phase 4: Client - Socket File Client**

#### File: `client/lib/services/file_transfer/socket_file_client.dart`

**Add method to query sharedWith:**

```dart
/// Get current sharedWith list from server
Future<List<String>?> getSharedWith(String fileId) async {
  final completer = Completer<List<String>?>();
  
  socket.emitWithAck('file:get-sharedWith', {
    'fileId': fileId,
  }, ack: (data) {
    if (data['success'] == true && data['sharedWith'] != null) {
      final sharedWith = (data['sharedWith'] as List).cast<String>();
      completer.complete(sharedWith);
    } else {
      completer.complete(null);
    }
  });
  
  return completer.future;
}
```

**Setup listener for WebSocket updates:**

```dart
/// Setup listeners for file events
void setupListeners() {
  // ... existing listeners ...
  
  // Real-time sharedWith updates (WebSocket)
  socket.on('file:sharedWith-updated', (data) async {
    try {
      final fileId = data['fileId'] as String?;
      final sharedWith = (data['sharedWith'] as List?)?.cast<String>();
      
      if (fileId == null || sharedWith == null) {
        debugPrint('[FILE CLIENT] Invalid sharedWith update data');
        return;
      }
      
      debugPrint('[FILE CLIENT] Received sharedWith update for $fileId: ${sharedWith.length} users');
      
      // Update local storage
      await storage.updateFileMetadata(fileId, {
        'sharedWith': sharedWith,
      });
      
      debugPrint('[FILE CLIENT] ✓ Updated local sharedWith for $fileId');
      
    } catch (e) {
      debugPrint('[FILE CLIENT] Error handling sharedWith update: $e');
    }
  });
}
```

---

### **Phase 5: Client - Signal Message Handler**

#### File: `client/lib/services/message_listener_service.dart`

**Add handler for sharedWith updates via Signal:**

```dart
// In _handleIncomingMessage or wherever Signal messages are processed:

void _handleFileSharedWithUpdate(Map<String, dynamic> decrypted) {
  try {
    final fileId = decrypted['fileId'] as String?;
    final sharedWith = (decrypted['sharedWith'] as List?)?.cast<String>();
    
    if (fileId == null || sharedWith == null) {
      debugPrint('[SIGNAL] Invalid sharedWith update');
      return;
    }
    
    debugPrint('[SIGNAL] Received sharedWith update for $fileId: ${sharedWith.length} users');
    
    // Update local storage (file transfer service has storage reference)
    _updateFileSharedWith(fileId, sharedWith);
    
  } catch (e) {
    debugPrint('[SIGNAL] Error handling sharedWith update: $e');
  }
}

Future<void> _updateFileSharedWith(String fileId, List<String> sharedWith) async {
  try {
    // Get storage from file transfer service
    final storage = FileTransferService.instance.storage;
    
    if (storage != null) {
      await storage.updateFileMetadata(fileId, {
        'sharedWith': sharedWith,
      });
      
      debugPrint('[SIGNAL] ✓ Updated local sharedWith for $fileId');
    }
  } catch (e) {
    debugPrint('[SIGNAL] Error updating sharedWith: $e');
  }
}

// Register handler in message processing:
if (decrypted['type'] == 'file:sharedWith-update') {
  _handleFileSharedWithUpdate(decrypted);
}
```

---

## 🧪 Testing Checklist

### Scenario 1: Basic Merge
- [ ] Alice uploads file, sharedWith=[Alice, Bob]
- [ ] Bob downloads file
- [ ] Bob shares with Carol by uploading (sharedWith=[Alice, Bob, Carol])
- [ ] Server merges to [Alice, Bob, Carol]
- [ ] Alice receives WebSocket update
- [ ] Alice's local storage shows [Alice, Bob, Carol]

### Scenario 2: Offline Sync
- [ ] Alice shares file with Bob
- [ ] Bob goes offline
- [ ] Carol downloads and shares with Dave
- [ ] Server merges: [Alice, Bob, Carol, Dave]
- [ ] Bob comes back online
- [ ] Bob queries server before reannouncement
- [ ] Bob's local storage updates to [Alice, Bob, Carol, Dave]

### Scenario 3: Signal Message Sync
- [ ] Alice shares with Bob
- [ ] Bob offline
- [ ] Carol shares with Dave
- [ ] Signal message sent to Alice, Bob, Carol, Dave
- [ ] Bob comes online
- [ ] Bob processes Signal message
- [ ] Bob's local storage updates

### Scenario 4: 1000 User Limit
- [ ] File has 999 users in sharedWith
- [ ] New user announces with +2 users
- [ ] Server truncates to 1000
- [ ] Log warning shown
- [ ] Callback returns truncated list

### Scenario 5: Self-Removal
- [ ] Alice, Bob, Carol all have file
- [ ] Bob deletes file locally (no chunks)
- [ ] Bob can no longer announce
- [ ] Alice and Carol still seed
- [ ] sharedWith still shows Bob (but he can't seed)

---

## 📊 Performance Considerations

### Server Memory:
- **1000 users × 36 chars/UUID = ~36KB per file**
- With 10,000 active files = ~360MB for sharedWith data
- Acceptable for modern servers

### WebSocket Broadcasts:
- Each reannouncement triggers N-1 WebSocket messages (N = seeders)
- With 100 seeders = 99 messages per reannouncement
- Low overhead (small JSON payload)

### Signal Messages:
- Async, non-blocking
- Only sent when sharedWith actually changes
- Each message ~1-2KB encrypted
- Scales well with existing Signal infrastructure

---

## 🔒 Security Notes

1. **No prevention of resharing** - Accepted reality
2. **Anonymous merging** - No tracking of who added whom
3. **No validation of permissions** - Trust model
4. **Server doesn't verify** - Clients control their lists
5. **1000 user cap** - Prevents DoS via massive lists

---

## ✅ Implementation Status

- [ ] **Phase 1**: Server FileRegistry merge logic
- [ ] **Phase 2**: Server Socket event handlers
- [ ] **Phase 3**: Client reannounce service sync
- [ ] **Phase 4**: Client Socket file client methods
- [ ] **Phase 5**: Client Signal message handler
- [ ] **Testing**: All scenarios validated
- [ ] **Documentation**: Updated user guide

---

## 📝 Notes

- Keep implementation simple (no rate limiting, no history)
- Hybrid sync ensures reliability (WebSocket + Signal + Query)
- 1000 user limit is pragmatic balance
- Anonymous design protects privacy
- Self-removal through chunk deletion is elegant solution

---

**Approved and ready for implementation** ✅
