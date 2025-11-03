# P2P File Sharing - Usability & UX Verbesserungen

**Stand**: 27. Oktober 2025  
**Status**: Design-Erweiterungen für bessere User Experience

---

## 🎯 Übersicht der Verbesserungen

Basierend auf kritischer Analyse der geplanten Implementation wurden folgende Verbesserungen identifiziert:

### **Kritische Verbesserungen** 🔴 (MÜSSEN implementiert werden)
1. ✅ **Pause/Resume** → Verhindert Datenverlust bei Unterbrechung
2. ✅ **Server-Relay Fallback** → 100% Erfolgsrate statt 95%
3. ✅ **Seeder-Benachrichtigungen** → "File now available" Notifications
4. ✅ **Uploader-Status Widget** → Zeige wann man offline gehen kann

### **Wichtige Verbesserungen** 🟡 (SOLLTEN implementiert werden)
5. ✅ **Preview/Thumbnails** → User sieht was er downloadet
6. ✅ **ETA & Speed Display** → Bessere User-Information
7. ✅ **Power Management** → Battery-freundlich

### **Nice-to-Have** 🟢 (KÖNNEN implementiert werden)
8. ✅ **Server-Cache für kleine Files** → Erste Chunks cachen
9. ✅ **Auto-Resume nach Crash** → Robustheit
10. ✅ **Background Mode Warning** → User-Awareness

---

## 🔴 KRITISCHE VERBESSERUNGEN

### 1. Pause/Resume System

#### Problem
- User startet 500 MB Download
- Chrome crashed / WiFi lost / Mobile screen off
- **Resultat**: Kompletter Download verloren, muss von vorne beginnen

#### Lösung: Robustes State Management

```dart
// client/lib/services/file_transfer/download_manager.dart

class DownloadManager {
  final Map<String, DownloadState> _activeDownloads = {};
  
  // Download State
  class DownloadState {
    final String fileId;
    final Set<int> completedChunks;
    final Set<int> pendingChunks;
    final int totalChunks;
    final DateTime startedAt;
    final DateTime? pausedAt;
    bool isPaused;
    
    DownloadState({
      required this.fileId,
      required this.completedChunks,
      required this.pendingChunks,
      required this.totalChunks,
      required this.startedAt,
      this.pausedAt,
      this.isPaused = false,
    });
    
    Map<String, dynamic> toJson() => {
      'fileId': fileId,
      'completedChunks': completedChunks.toList(),
      'pendingChunks': pendingChunks.toList(),
      'totalChunks': totalChunks,
      'startedAt': startedAt.toIso8601String(),
      'pausedAt': pausedAt?.toIso8601String(),
      'isPaused': isPaused,
    };
    
    factory DownloadState.fromJson(Map<String, dynamic> json) => DownloadState(
      fileId: json['fileId'],
      completedChunks: Set<int>.from(json['completedChunks']),
      pendingChunks: Set<int>.from(json['pendingChunks']),
      totalChunks: json['totalChunks'],
      startedAt: DateTime.parse(json['startedAt']),
      pausedAt: json['pausedAt'] != null ? DateTime.parse(json['pausedAt']) : null,
      isPaused: json['isPaused'] ?? false,
    );
  }
  
  // Pause Download
  Future<void> pauseDownload(String fileId) async {
    final state = _activeDownloads[fileId];
    if (state == null) return;
    
    state.isPaused = true;
    state.pausedAt = DateTime.now();
    
    // Persist state to storage
    await _storage.saveDownloadState(fileId, state.toJson());
    
    // Close all peer connections for this file
    await _closePeerConnections(fileId);
    
    // Emit pause event
    _downloadStreamController.add(DownloadEvent(
      type: DownloadEventType.paused,
      fileId: fileId,
    ));
    
    print('✅ Download paused: $fileId');
  }
  
  // Resume Download
  Future<void> resumeDownload(String fileId) async {
    // Load state from storage
    final savedState = await _storage.getDownloadState(fileId);
    
    if (savedState == null) {
      print('❌ No saved state found for $fileId');
      return;
    }
    
    final state = DownloadState.fromJson(savedState);
    state.isPaused = false;
    _activeDownloads[fileId] = state;
    
    // Emit resume event
    _downloadStreamController.add(DownloadEvent(
      type: DownloadEventType.resumed,
      fileId: fileId,
      progress: state.completedChunks.length / state.totalChunks,
    ));
    
    // Reconnect to seeders
    await _reconnectToSeeders(fileId);
    
    // Continue downloading missing chunks
    final missingChunks = List.generate(state.totalChunks, (i) => i)
      .where((i) => !state.completedChunks.contains(i))
      .toList();
    
    await _downloadChunks(fileId, missingChunks);
    
    print('✅ Download resumed: $fileId (${state.completedChunks.length}/${state.totalChunks} chunks completed)');
  }
  
  // Auto-Resume on App Restart
  Future<void> resumeAllPausedDownloads() async {
    final pausedDownloads = await _storage.getAllPausedDownloads();
    
    if (pausedDownloads.isEmpty) return;
    
    print('📂 Found ${pausedDownloads.length} paused downloads');
    
    for (final stateJson in pausedDownloads) {
      final state = DownloadState.fromJson(stateJson);
      
      // Show notification to user
      _showResumeNotification(state.fileId);
    }
  }
  
  void _showResumeNotification(String fileId) {
    // Get file metadata
    final metadata = _storage.getFileMetadata(fileId);
    
    if (metadata == null) return;
    
    showNotification(
      title: 'Pausierter Download',
      body: '${metadata['fileName']} (${_formatProgress(fileId)})',
      actions: ['Fortsetzen', 'Abbrechen'],
      onActionPressed: (action) {
        if (action == 'Fortsetzen') {
          resumeDownload(fileId);
        } else {
          cancelDownload(fileId);
        }
      }
    );
  }
}
```

#### UI Integration

```dart
// widgets/file_download_card.dart

class FileDownloadCard extends StatefulWidget {
  final FileDownloadInfo fileInfo;
  
  @override
  _FileDownloadCardState createState() => _FileDownloadCardState();
}

class _FileDownloadCardState extends State<FileDownloadCard> {
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // File info
            Row(
              children: [
                Icon(getFileIcon(widget.fileInfo.mimeType), size: 40),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.fileInfo.fileName,
                        style: TextStyle(fontWeight: FontWeight.bold)
                      ),
                      Text(
                        '${formatFileSize(widget.fileInfo.fileSize)} • ${widget.fileInfo.seederCount} Seeders',
                        style: TextStyle(color: Colors.grey)
                      ),
                    ]
                  )
                )
              ]
            ),
            
            SizedBox(height: 12),
            
            // Progress bar
            LinearProgressIndicator(
              value: widget.fileInfo.progress,
              backgroundColor: Colors.grey[200],
              valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
            ),
            
            SizedBox(height: 8),
            
            // Progress text
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${(widget.fileInfo.progress * 100).toStringAsFixed(0)}%'),
                Text('${widget.fileInfo.eta} • ${widget.fileInfo.speed}'),
              ]
            ),
            
            SizedBox(height: 12),
            
            // Action buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (widget.fileInfo.isPaused)
                  ElevatedButton.icon(
                    icon: Icon(Icons.play_arrow),
                    label: Text('Fortsetzen'),
                    onPressed: () => DownloadManager.instance.resumeDownload(widget.fileInfo.fileId),
                  )
                else
                  ElevatedButton.icon(
                    icon: Icon(Icons.pause),
                    label: Text('Pausieren'),
                    onPressed: () => DownloadManager.instance.pauseDownload(widget.fileInfo.fileId),
                  ),
                
                SizedBox(width: 8),
                
                OutlinedButton.icon(
                  icon: Icon(Icons.cancel),
                  label: Text('Abbrechen'),
                  onPressed: () => _confirmCancel(),
                )
              ]
            )
          ]
        )
      )
    );
  }
}
```

---

### 2. Server-Relay Fallback

#### Problem
- WebRTC P2P scheitert bei ~5% der Verbindungen
- Corporate Firewalls blockieren WebRTC komplett
- User sieht nur "Connection Failed" ohne Alternative

#### Lösung: Automatischer Fallback über Server

```javascript
// server/routes/file-relay.js

const express = require('express');
const router = express.Router();

// Relay-Cache für aktive Transfers
const relayTransfers = new Map();

// Relay Request Handler
io.on('connection', (socket) => {
  
  // Client requests relay fallback
  socket.on('file:request-relay', async (data) => {
    const { fileId, chunkIndex } = data;
    
    console.log(`🔄 Relay request: File ${fileId}, Chunk ${chunkIndex}`);
    
    // Find available seeder
    const seeders = fileRegistry.get(fileId)?.seeders || [];
    const availableSeeder = seeders.find(s => 
      s.chunks.includes(chunkIndex) && s.socketId !== socket.id
    );
    
    if (!availableSeeder) {
      socket.emit('file:relay-error', {
        fileId,
        chunkIndex,
        error: 'No seeder available'
      });
      return;
    }
    
    // Create relay transfer
    const relayId = `${fileId}-${chunkIndex}-${Date.now()}`;
    relayTransfers.set(relayId, {
      fileId,
      chunkIndex,
      requesterId: socket.id,
      seederId: availableSeeder.socketId,
      createdAt: Date.now()
    });
    
    // Request chunk from seeder
    io.to(availableSeeder.socketId).emit('file:relay-chunk-request', {
      relayId,
      fileId,
      chunkIndex,
      requesterId: socket.id
    });
  });
  
  // Seeder sends chunk data
  socket.on('file:relay-chunk-data', async (data) => {
    const { relayId, encryptedChunk } = data;
    
    const relay = relayTransfers.get(relayId);
    if (!relay) {
      console.warn('⚠️ Unknown relay ID:', relayId);
      return;
    }
    
    // Forward chunk to requester
    io.to(relay.requesterId).emit('file:relay-chunk-received', {
      fileId: relay.fileId,
      chunkIndex: relay.chunkIndex,
      encryptedChunk: encryptedChunk // Already encrypted!
    });
    
    // Cleanup relay
    relayTransfers.delete(relayId);
    
    console.log(`✅ Relayed chunk ${relay.chunkIndex} for file ${relay.fileId}`);
  });
});

// Cleanup old relays (after 30 seconds)
setInterval(() => {
  const now = Date.now();
  for (const [relayId, relay] of relayTransfers.entries()) {
    if (now - relay.createdAt > 30000) {
      relayTransfers.delete(relayId);
      console.log(`🗑️ Cleaned up stale relay: ${relayId}`);
    }
  }
}, 10000);

module.exports = router;
```

#### Client Integration

```dart
// client/lib/services/file_transfer/webrtc_manager.dart

class WebRTCManager {
  bool _useRelay = false;
  DateTime? _lastConnectionAttempt;
  int _connectionFailures = 0;
  
  // Try P2P connection with timeout
  Future<bool> connectToPeer(String peerId, String fileId) async {
    _lastConnectionAttempt = DateTime.now();
    
    try {
      // Attempt WebRTC connection
      final connected = await _createPeerConnection(peerId, fileId)
        .timeout(Duration(seconds: 30));
      
      if (connected) {
        _connectionFailures = 0;
        return true;
      }
    } catch (e) {
      _connectionFailures++;
      print('⚠️ WebRTC connection failed: $e');
    }
    
    // After 3 failures or 30 seconds, suggest relay
    if (_connectionFailures >= 3 || 
        DateTime.now().difference(_lastConnectionAttempt!).inSeconds > 30) {
      
      final useRelay = await _askUserForRelay();
      
      if (useRelay) {
        _useRelay = true;
        return true;
      }
    }
    
    return false;
  }
  
  Future<bool> _askUserForRelay() async {
    final result = await showDialog<bool>(
      context: navigatorKey.currentContext!,
      builder: (context) => AlertDialog(
        title: Text('Verbindungsproblem'),
        content: Text(
          'Direkte P2P-Verbindung fehlgeschlagen.\n\n'
          'Möchtest du über Server-Relay herunterladen?\n\n'
          '⚠️ Hinweis: Langsamer, aber funktioniert immer.'
        ),
        actions: [
          TextButton(
            child: Text('Weiter versuchen'),
            onPressed: () => Navigator.pop(context, false)
          ),
          ElevatedButton(
            child: Text('Server-Relay nutzen'),
            onPressed: () => Navigator.pop(context, true)
          )
        ]
      )
    );
    
    return result ?? false;
  }
  
  // Download chunk via relay
  Future<Uint8List?> downloadChunkViaRelay(String fileId, int chunkIndex) async {
    final completer = Completer<Uint8List?>();
    
    // Listen for chunk response
    socket.once('file:relay-chunk-received', (data) {
      if (data['fileId'] == fileId && data['chunkIndex'] == chunkIndex) {
        completer.complete(Uint8List.fromList(data['encryptedChunk']));
      }
    });
    
    // Request chunk via relay
    socket.emit('file:request-relay', {
      'fileId': fileId,
      'chunkIndex': chunkIndex
    });
    
    // Timeout after 30 seconds
    return completer.future.timeout(
      Duration(seconds: 30),
      onTimeout: () {
        print('⚠️ Relay timeout for chunk $chunkIndex');
        return null;
      }
    );
  }
}
```

---

### 3. Seeder-Benachrichtigungen

#### Problem
- User B ist offline → sieht File-Link in Chat
- Klickt Download → "No seeders available"
- **Frustration**: Wann ist die Datei verfügbar?

#### Lösung: Smart Availability Notifications

```dart
// client/lib/services/file_availability_service.dart

class FileAvailabilityService {
  static final FileAvailabilityService instance = FileAvailabilityService._();
  FileAvailabilityService._();
  
  final Map<String, FileAvailabilityWatcher> _watchers = {};
  
  // Watch file availability
  Future<void> watchForAvailability(String fileId, String fileName) async {
    if (_watchers.containsKey(fileId)) {
      print('ℹ️ Already watching file: $fileId');
      return;
    }
    
    final watcher = FileAvailabilityWatcher(
      fileId: fileId,
      fileName: fileName,
      createdAt: DateTime.now()
    );
    
    _watchers[fileId] = watcher;
    
    // Save to storage
    await _storage.saveAvailabilityWatcher(fileId, watcher.toJson());
    
    // Listen for seeder online event
    socket.on('file:seeder-online', (data) {
      if (data['fileId'] == fileId) {
        _onSeederAvailable(fileId, fileName);
      }
    });
    
    print('👀 Watching for availability: $fileName');
  }
  
  void _onSeederAvailable(String fileId, String fileName) {
    // Show notification
    showNotification(
      title: 'Datei jetzt verfügbar',
      body: '$fileName kann jetzt heruntergeladen werden',
      payload: fileId,
      actions: ['Jetzt downloaden', 'Später'],
      onActionPressed: (action) {
        if (action == 'Jetzt downloaden') {
          // Navigate to download
          navigatorKey.currentState?.pushNamed(
            '/download',
            arguments: {'fileId': fileId}
          );
        }
      }
    );
    
    // Remove watcher
    _watchers.remove(fileId);
    _storage.deleteAvailabilityWatcher(fileId);
  }
  
  // Stop watching
  Future<void> stopWatching(String fileId) async {
    _watchers.remove(fileId);
    await _storage.deleteAvailabilityWatcher(fileId);
    socket.off('file:seeder-online');
  }
  
  // Restore watchers on app restart
  Future<void> restoreWatchers() async {
    final savedWatchers = await _storage.getAllAvailabilityWatchers();
    
    for (final watcherJson in savedWatchers) {
      final watcher = FileAvailabilityWatcher.fromJson(watcherJson);
      await watchForAvailability(watcher.fileId, watcher.fileName);
    }
    
    print('✅ Restored ${savedWatchers.length} availability watchers');
  }
}

class FileAvailabilityWatcher {
  final String fileId;
  final String fileName;
  final DateTime createdAt;
  
  FileAvailabilityWatcher({
    required this.fileId,
    required this.fileName,
    required this.createdAt,
  });
  
  Map<String, dynamic> toJson() => {
    'fileId': fileId,
    'fileName': fileName,
    'createdAt': createdAt.toIso8601String(),
  };
  
  factory FileAvailabilityWatcher.fromJson(Map<String, dynamic> json) =>
    FileAvailabilityWatcher(
      fileId: json['fileId'],
      fileName: json['fileName'],
      createdAt: DateTime.parse(json['createdAt']),
    );
}
```

#### UI Integration

```dart
// widgets/file_message_card.dart (when no seeders)

if (seederCount == 0) {
  Container(
    padding: EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.orange.withOpacity(0.1),
      borderRadius: BorderRadius.circular(8)
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.warning, color: Colors.orange),
            SizedBox(width: 8),
            Text(
              'Keine Seeders online',
              style: TextStyle(
                color: Colors.orange.shade700,
                fontWeight: FontWeight.bold
              )
            )
          ]
        ),
        SizedBox(height: 8),
        Text(
          'Die Datei ist momentan nicht verfügbar.',
          style: TextStyle(fontSize: 12)
        ),
        SizedBox(height: 8),
        ElevatedButton.icon(
          icon: Icon(Icons.notifications_active),
          label: Text('Benachrichtige mich'),
          onPressed: () async {
            await FileAvailabilityService.instance
              .watchForAvailability(fileId, fileName);
            
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '✅ Du wirst benachrichtigt sobald die Datei verfügbar ist'
                ),
                duration: Duration(seconds: 3)
              )
            );
          }
        )
      ]
    )
  )
}
```

---

### 4. Uploader-Status Widget

#### Problem
- User A uploaded File → "Kann ich jetzt offline gehen?"
- Keine Info über: Wer downloaded? Wie viele haben es schon?

#### Lösung: Real-Time Status Widget

```dart
// client/lib/widgets/file_upload_status_widget.dart

class FileUploadStatusWidget extends StatefulWidget {
  final String fileId;
  final String fileName;
  
  const FileUploadStatusWidget({
    Key? key,
    required this.fileId,
    required this.fileName,
  }) : super(key: key);
  
  @override
  _FileUploadStatusWidgetState createState() => _FileUploadStatusWidgetState();
}

class _FileUploadStatusWidgetState extends State<FileUploadStatusWidget> {
  int _seederCount = 1; // Uploader selbst
  int _completedDownloads = 0;
  List<ActiveDownloader> _activeDownloaders = [];
  bool _canGoOffline = false;
  
  @override
  void initState() {
    super.initState();
    _setupListeners();
    _requestStatus();
  }
  
  void _setupListeners() {
    // Listen to real-time updates
    socket.on('file:seeder-update', (data) {
      if (data['fileId'] == widget.fileId) {
        setState(() {
          _seederCount = data['seederCount'] ?? 1;
          _completedDownloads = data['completedDownloads'] ?? 0;
          _canGoOffline = _seederCount >= 2;
        });
      }
    });
    
    socket.on('file:active-downloads', (data) {
      if (data['fileId'] == widget.fileId) {
        setState(() {
          _activeDownloaders = (data['downloaders'] as List)
            .map((d) => ActiveDownloader.fromJson(d))
            .toList();
        });
      }
    });
  }
  
  void _requestStatus() {
    socket.emit('file:request-status', {'fileId': widget.fileId});
  }
  
  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(Icons.cloud_upload, color: Colors.blue),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Deine geteilte Datei',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16
                    )
                  )
                ),
                IconButton(
                  icon: Icon(Icons.refresh),
                  onPressed: _requestStatus
                )
              ]
            ),
            
            Divider(),
            
            // File info
            ListTile(
              leading: Icon(Icons.insert_drive_file, size: 32),
              title: Text(widget.fileName),
              contentPadding: EdgeInsets.zero,
            ),
            
            SizedBox(height: 12),
            
            // Statistics
            Row(
              children: [
                Expanded(
                  child: _buildStatCard(
                    icon: Icons.people,
                    label: 'Seeders',
                    value: '$_seederCount',
                    color: Colors.green
                  )
                ),
                SizedBox(width: 12),
                Expanded(
                  child: _buildStatCard(
                    icon: Icons.download_done,
                    label: 'Fertig',
                    value: '$_completedDownloads',
                    color: Colors.blue
                  )
                )
              ]
            ),
            
            SizedBox(height: 12),
            
            // Active downloaders
            if (_activeDownloaders.isNotEmpty) ...[
              Text(
                'Aktive Downloads (${_activeDownloaders.length})',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14
                )
              ),
              SizedBox(height: 8),
              ..._activeDownloaders.map((downloader) => Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      child: Text(downloader.userName[0].toUpperCase())
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(downloader.userName),
                          LinearProgressIndicator(
                            value: downloader.progress,
                            backgroundColor: Colors.grey[200],
                          )
                        ]
                      )
                    ),
                    SizedBox(width: 8),
                    Text('${(downloader.progress * 100).toStringAsFixed(0)}%')
                  ]
                )
              )),
              SizedBox(height: 12),
            ],
            
            // Status message
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _canGoOffline 
                  ? Colors.green.withOpacity(0.1)
                  : Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8)
              ),
              child: Row(
                children: [
                  Icon(
                    _canGoOffline ? Icons.check_circle : Icons.warning,
                    color: _canGoOffline ? Colors.green : Colors.orange
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _canGoOffline
                        ? '✅ Du kannst jetzt offline gehen! Andere Seeders halten die Datei verfügbar.'
                        : '⚠️ Bleibe online bis jemand die Datei vollständig heruntergeladen hat.',
                      style: TextStyle(
                        color: _canGoOffline 
                          ? Colors.green.shade700
                          : Colors.orange.shade700,
                        fontSize: 13
                      )
                    )
                  )
                ]
              )
            )
          ]
        )
      )
    );
  }
  
  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color
  }) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8)
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 28),
          SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: color
            )
          ),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: Colors.grey[700])
          )
        ]
      )
    );
  }
  
  @override
  void dispose() {
    socket.off('file:seeder-update');
    socket.off('file:active-downloads');
    super.dispose();
  }
}

class ActiveDownloader {
  final String userId;
  final String userName;
  final double progress;
  
  ActiveDownloader({
    required this.userId,
    required this.userName,
    required this.progress,
  });
  
  factory ActiveDownloader.fromJson(Map<String, dynamic> json) => ActiveDownloader(
    userId: json['userId'],
    userName: json['userName'],
    progress: (json['progress'] as num).toDouble(),
  );
}
```

#### Server Support

```javascript
// server/routes/file-status.js

socket.on('file:request-status', (data) => {
  const { fileId } = data;
  const file = fileRegistry.get(fileId);
  
  if (!file) {
    socket.emit('file:status-error', { error: 'File not found' });
    return;
  }
  
  // Count seeders (users with all chunks)
  const seeders = file.seeders.filter(s => s.chunks.length === file.chunkCount);
  
  // Count completed downloads
  const completedDownloads = file.completedDownloads || 0;
  
  // Get active downloaders
  const activeDownloaders = file.leechers
    .filter(l => l.chunks.length > 0 && l.chunks.length < file.chunkCount)
    .map(l => ({
      userId: l.userId,
      userName: l.userName,
      progress: l.chunks.length / file.chunkCount
    }));
  
  socket.emit('file:seeder-update', {
    fileId,
    seederCount: seeders.length,
    completedDownloads
  });
  
  socket.emit('file:active-downloads', {
    fileId,
    downloaders: activeDownloaders
  });
});

// Broadcast updates when status changes
function broadcastFileStatus(fileId) {
  const file = fileRegistry.get(fileId);
  if (!file) return;
  
  const uploaderSocketId = file.uploaderId;
  
  if (uploaderSocketId) {
    io.to(uploaderSocketId).emit('file:seeder-update', {
      fileId,
      seederCount: file.seeders.length,
      completedDownloads: file.completedDownloads || 0
    });
  }
}
```

---

## 🟡 WICHTIGE VERBESSERUNGEN

### 5. Preview/Thumbnails System

#### Problem
- User sieht "document.pdf" in Chat
- **Frage**: "Was ist das? Brauche ich das?"
- Muss komplette Datei downloaden nur um Inhalt zu sehen

#### Lösung: Thumbnail-Generation & Preview

```dart
// client/lib/services/file_preview_service.dart

import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:pdf_render/pdf_render.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

class FilePreviewService {
  static const int MAX_PREVIEW_SIZE = 50 * 1024; // 50 KB max
  static const int THUMBNAIL_SIZE = 200; // 200x200 px
  
  /// Generate preview/thumbnail for file
  Future<Uint8List?> generatePreview(File file, String mimeType) async {
    try {
      if (mimeType.startsWith('image/')) {
        return await _generateImageThumbnail(file);
      } else if (mimeType == 'application/pdf') {
        return await _generatePdfThumbnail(file);
      } else if (mimeType.startsWith('video/')) {
        return await _generateVideoThumbnail(file);
      }
      
      return null; // No preview for other types
    } catch (e) {
      print('⚠️ Preview generation failed: $e');
      return null;
    }
  }
  
  Future<Uint8List?> _generateImageThumbnail(File file) async {
    final bytes = await file.readAsBytes();
    final image = img.decodeImage(bytes);
    
    if (image == null) return null;
    
    // Resize to thumbnail
    final thumbnail = img.copyResize(
      image,
      width: THUMBNAIL_SIZE,
      height: THUMBNAIL_SIZE,
      interpolation: img.Interpolation.average
    );
    
    // Encode as JPEG (smaller)
    final jpegBytes = img.encodeJpg(thumbnail, quality: 80);
    
    // Check size limit
    if (jpegBytes.length > MAX_PREVIEW_SIZE) {
      // Reduce quality if too large
      return img.encodeJpg(thumbnail, quality: 60);
    }
    
    return Uint8List.fromList(jpegBytes);
  }
  
  Future<Uint8List?> _generatePdfThumbnail(File file) async {
    // Render first page as image
    final document = await PdfDocument.openFile(file.path);
    final page = await document.getPage(1);
    final pageImage = await page.render(
      width: THUMBNAIL_SIZE,
      height: THUMBNAIL_SIZE,
    );
    
    await page.close();
    await document.dispose();
    
    return pageImage?.bytes;
  }
  
  Future<Uint8List?> _generateVideoThumbnail(File file) async {
    final thumbnailPath = await VideoThumbnail.thumbnailFile(
      video: file.path,
      imageFormat: ImageFormat.JPEG,
      maxWidth: THUMBNAIL_SIZE,
      quality: 80,
    );
    
    if (thumbnailPath == null) return null;
    
    final thumbnailFile = File(thumbnailPath);
    return await thumbnailFile.readAsBytes();
  }
  
  /// Upload file with preview
  Future<void> uploadWithPreview({
    required File file,
    required String fileName,
    required String mimeType,
    required String chatId,
    required String recipientId,
  }) async {
    // 1. Generate preview (if possible)
    final preview = await generatePreview(file, mimeType);
    
    print(preview != null 
      ? '✅ Preview generated: ${preview.length} bytes'
      : 'ℹ️ No preview for $mimeType'
    );
    
    // 2. Continue with normal file upload
    final fileId = await FileTransferService.instance.uploadFile(
      file: file,
      fileName: fileName,
      mimeType: mimeType,
      chatId: chatId,
    );
    
    // 3. Send Signal message with preview
    final signalMessage = {
      'type': 'file_share',
      'fileId': fileId,
      'fileName': fileName,
      'mimeType': mimeType,
      'fileSize': await file.length(),
      'encryptedKey': await _getFileKey(fileId),
      'preview': preview != null ? base64Encode(preview) : null, // ← Preview!
      'checksum': await _calculateChecksum(file),
      'chunkCount': _calculateChunkCount(await file.length()),
    };
    
    await SignalService.instance.sendItem(
      recipientUserId: recipientId,
      type: 'file_share',
      payload: jsonEncode(signalMessage),
      itemId: fileId,
    );
    
    print('✅ File shared with preview: $fileName');
  }
}
```

#### UI Integration

```dart
// widgets/file_message_card.dart

class FileMessageCard extends StatelessWidget {
  final FileShareMessage message;
  
  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Preview Image (if available)
          if (message.preview != null)
            Stack(
              children: [
                Image.memory(
                  message.preview!,
                  height: 200,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
                // Overlay with file type icon
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20)
                    ),
                    child: Icon(
                      _getFileIcon(message.mimeType),
                      color: Colors.white,
                      size: 20
                    )
                  )
                )
              ]
            ),
          
          // File info
          Padding(
            padding: EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (message.preview == null)
                      Icon(_getFileIcon(message.mimeType), size: 32),
                    if (message.preview == null)
                      SizedBox(width: 12),
                    
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            message.fileName,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          SizedBox(height: 4),
                          Text(
                            '${formatFileSize(message.fileSize)} • ${message.seederCount} Seeders',
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 13
                            )
                          )
                        ]
                      )
                    ),
                    
                    // Download button
                    IconButton(
                      icon: Icon(Icons.download_rounded),
                      onPressed: () => _startDownload(context),
                      color: Colors.blue,
                      iconSize: 28,
                    )
                  ]
                ),
              ]
            )
          )
        ]
      )
    );
  }
  
  IconData _getFileIcon(String mimeType) {
    if (mimeType.startsWith('image/')) return Icons.image;
    if (mimeType.startsWith('video/')) return Icons.video_file;
    if (mimeType.startsWith('audio/')) return Icons.audio_file;
    if (mimeType == 'application/pdf') return Icons.picture_as_pdf;
    if (mimeType.contains('zip') || mimeType.contains('rar')) return Icons.folder_zip;
    return Icons.insert_drive_file;
  }
}
```

**Dependencies:**

```yaml
# pubspec.yaml (add these)
dependencies:
  image: ^4.1.3              # Image processing
  pdf_render: ^1.4.0         # PDF thumbnail
  video_thumbnail: ^0.5.3    # Video thumbnail
```

---

### 6. ETA & Speed Display

#### Problem
- User sieht "67%" → **Frage**: "Wie lange noch?"
- Keine Info über Download-Geschwindigkeit

#### Lösung: Smart ETA Calculator

```dart
// client/lib/services/file_transfer/download_eta_calculator.dart

class DownloadETACalculator {
  final List<SpeedSample> _speedSamples = [];
  static const int MAX_SAMPLES = 20; // Last 20 seconds
  
  DateTime _lastUpdate = DateTime.now();
  int _lastBytes = 0;
  
  void updateProgress(int downloadedBytes) {
    final now = DateTime.now();
    final elapsed = now.difference(_lastUpdate).inMilliseconds;
    
    // Update every second
    if (elapsed >= 1000) {
      final bytesInInterval = downloadedBytes - _lastBytes;
      final speed = (bytesInInterval / elapsed) * 1000; // Bytes per second
      
      _speedSamples.add(SpeedSample(
        timestamp: now,
        speed: speed,
      ));
      
      // Keep only last MAX_SAMPLES
      while (_speedSamples.length > MAX_SAMPLES) {
        _speedSamples.removeAt(0);
      }
      
      _lastUpdate = now;
      _lastBytes = downloadedBytes;
    }
  }
  
  /// Get estimated time remaining
  String getETA(int downloadedBytes, int totalBytes) {
    if (_speedSamples.isEmpty) return 'Berechne...';
    
    // Calculate weighted average (recent samples have more weight)
    double totalWeightedSpeed = 0;
    double totalWeight = 0;
    
    for (int i = 0; i < _speedSamples.length; i++) {
      final weight = (i + 1).toDouble(); // More recent = higher weight
      totalWeightedSpeed += _speedSamples[i].speed * weight;
      totalWeight += weight;
    }
    
    final avgSpeed = totalWeightedSpeed / totalWeight;
    
    if (avgSpeed <= 0) return 'Gestoppt';
    
    final remainingBytes = totalBytes - downloadedBytes;
    final remainingSeconds = (remainingBytes / avgSpeed).ceil();
    
    return _formatDuration(remainingSeconds);
  }
  
  /// Get current download speed
  String getCurrentSpeed() {
    if (_speedSamples.isEmpty) return '0 B/s';
    
    // Use last 5 samples for current speed
    final recentSamples = _speedSamples.length > 5 
      ? _speedSamples.sublist(_speedSamples.length - 5)
      : _speedSamples;
    
    final avgSpeed = recentSamples
      .map((s) => s.speed)
      .reduce((a, b) => a + b) / recentSamples.length;
    
    return _formatSpeed(avgSpeed);
  }
  
  String _formatDuration(int seconds) {
    if (seconds < 60) {
      return '$seconds Sek.';
    } else if (seconds < 3600) {
      final minutes = (seconds / 60).ceil();
      return '$minutes Min.';
    } else if (seconds < 86400) {
      final hours = (seconds / 3600).floor();
      final minutes = ((seconds % 3600) / 60).ceil();
      return '${hours}h ${minutes}m';
    } else {
      final days = (seconds / 86400).ceil();
      return '$days Tage';
    }
  }
  
  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) {
      return '${bytesPerSecond.toStringAsFixed(0)} B/s';
    } else if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    } else {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(2)} MB/s';
    }
  }
  
  void reset() {
    _speedSamples.clear();
    _lastUpdate = DateTime.now();
    _lastBytes = 0;
  }
}

class SpeedSample {
  final DateTime timestamp;
  final double speed; // bytes per second
  
  SpeedSample({
    required this.timestamp,
    required this.speed,
  });
}
```

#### UI Integration

```dart
// widgets/download_progress_widget.dart

class DownloadProgressWidget extends StatefulWidget {
  final String fileId;
  
  @override
  _DownloadProgressWidgetState createState() => _DownloadProgressWidgetState();
}

class _DownloadProgressWidgetState extends State<DownloadProgressWidget> {
  final _etaCalculator = DownloadETACalculator();
  
  double _progress = 0;
  int _downloadedBytes = 0;
  int _totalBytes = 0;
  String _eta = 'Berechne...';
  String _speed = '0 KB/s';
  
  @override
  void initState() {
    super.initState();
    _setupProgressListener();
  }
  
  void _setupProgressListener() {
    DownloadManager.instance.onProgress(widget.fileId).listen((event) {
      setState(() {
        _downloadedBytes = event.downloadedBytes;
        _totalBytes = event.totalBytes;
        _progress = _downloadedBytes / _totalBytes;
        
        // Update ETA calculator
        _etaCalculator.updateProgress(_downloadedBytes);
        
        // Get ETA and speed
        _eta = _etaCalculator.getETA(_downloadedBytes, _totalBytes);
        _speed = _etaCalculator.getCurrentSpeed();
      });
    });
  }
  
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Progress bar
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: _progress,
            minHeight: 8,
            backgroundColor: Colors.grey[200],
            valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
          )
        ),
        
        SizedBox(height: 8),
        
        // Progress info
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Left: Percentage
            Text(
              '${(_progress * 100).toStringAsFixed(1)}%',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14
              )
            ),
            
            // Right: Speed and ETA
            Text(
              '$_speed • $_eta',
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: 12
              )
            )
          ]
        ),
        
        SizedBox(height: 4),
        
        // Downloaded / Total
        Text(
          '${formatFileSize(_downloadedBytes)} / ${formatFileSize(_totalBytes)}',
          style: TextStyle(
            color: Colors.grey[600],
            fontSize: 11
          )
        )
      ]
    );
  }
}
```

---

### 7. Power Management

#### Problem
- Mobile Downloads drain battery massiv
- Seeding im Hintergrund → Phone wird heiß
- User beschwert sich über Akku-Verbrauch

#### Lösung: Adaptive Power Management

```dart
// client/lib/services/power_management_service.dart

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

class PowerManagementService {
  static final PowerManagementService instance = PowerManagementService._();
  PowerManagementService._();
  
  final Battery _battery = Battery();
  bool _isLowPowerMode = false;
  bool _isCharging = false;
  bool _isWiFi = false;
  
  // User preferences
  bool onlyWiFiDownload = true;
  bool onlyChargingSeeding = false;
  bool pauseWhenBackground = true;
  bool reducedSlotsWhenLowBattery = true;
  
  Future<void> init() async {
    // Load preferences
    final prefs = await SharedPreferences.getInstance();
    onlyWiFiDownload = prefs.getBool('onlyWiFiDownload') ?? true;
    onlyChargingSeeding = prefs.getBool('onlyChargingSeeding') ?? false;
    pauseWhenBackground = prefs.getBool('pauseWhenBackground') ?? true;
    reducedSlotsWhenLowBattery = prefs.getBool('reducedSlotsWhenLowBattery') ?? true;
    
    // Monitor battery
    _battery.onBatteryStateChanged.listen(_onBatteryStateChanged);
    
    // Monitor connectivity
    Connectivity().onConnectivityChanged.listen(_onConnectivityChanged);
    
    // Initial state
    _updateBatteryState();
    _updateConnectivityState();
    
    print('✅ Power Management initialized');
  }
  
  void _onBatteryStateChanged(BatteryState state) {
    _isCharging = state == BatteryState.charging || state == BatteryState.full;
    _updateBatteryState();
  }
  
  Future<void> _updateBatteryState() async {
    final level = await _battery.batteryLevel;
    _isLowPowerMode = level < 20 && !_isCharging;
    
    print('🔋 Battery: $level% ${_isCharging ? "(charging)" : ""}');
    
    if (_isLowPowerMode) {
      _applyLowPowerRestrictions();
    }
  }
  
  void _onConnectivityChanged(ConnectivityResult result) {
    _isWiFi = result == ConnectivityResult.wifi;
    _updateConnectivityState();
  }
  
  void _updateConnectivityState() {
    print('📡 Connectivity: ${_isWiFi ? "WiFi" : "Mobile Data"}');
    
    if (!_isWiFi && onlyWiFiDownload) {
      _pauseAllDownloads();
      _showNotification(
        'Downloads pausiert',
        'Nur WiFi-Downloads aktiviert. Verbinde dich mit WiFi um fortzufahren.'
      );
    }
  }
  
  void _applyLowPowerRestrictions() {
    if (!reducedSlotsWhenLowBattery) return;
    
    // Reduce concurrent transfers
    FileTransferService.instance.setMaxUploadSlots(2);
    FileTransferService.instance.setMaxDownloadSlots(2);
    
    _showNotification(
      'Energie-Sparmodus',
      'Batterie niedrig. Transfers verlangsamt um Akku zu schonen.'
    );
  }
  
  void _pauseAllDownloads() {
    final activeDownloads = DownloadManager.instance.getActiveDownloads();
    
    for (final fileId in activeDownloads) {
      DownloadManager.instance.pauseDownload(fileId);
    }
  }
  
  /// Get adaptive transfer settings based on power state
  TransferSettings getTransferSettings() {
    if (_isLowPowerMode) {
      return TransferSettings(
        maxUploadSlots: 2,
        maxDownloadSlots: 2,
        chunkRequestDelay: 500, // ms
        allowBackground: false,
      );
    } else if (!_isCharging) {
      return TransferSettings(
        maxUploadSlots: 4,
        maxDownloadSlots: 4,
        chunkRequestDelay: 200,
        allowBackground: !pauseWhenBackground,
      );
    } else {
      // Charging = full power
      return TransferSettings(
        maxUploadSlots: 6,
        maxDownloadSlots: 6,
        chunkRequestDelay: 100,
        allowBackground: true,
      );
    }
  }
  
  /// Check if download should be allowed
  bool canDownload() {
    if (onlyWiFiDownload && !_isWiFi) {
      return false;
    }
    return true;
  }
  
  /// Check if seeding should be allowed
  bool canSeed() {
    if (onlyChargingSeeding && !_isCharging) {
      return false;
    }
    return true;
  }
  
  /// Show power settings dialog
  Future<void> showPowerSettings(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Energie-Einstellungen'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: Text('Nur bei WiFi downloaden'),
                subtitle: Text('Verhindert Mobile-Daten Verbrauch'),
                value: onlyWiFiDownload,
                onChanged: (val) async {
                  onlyWiFiDownload = val;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('onlyWiFiDownload', val);
                }
              ),
              
              SwitchListTile(
                title: Text('Nur beim Laden seeden'),
                subtitle: Text('Schont Akku auf Mobil-Geräten'),
                value: onlyChargingSeeding,
                onChanged: (val) async {
                  onlyChargingSeeding = val;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('onlyChargingSeeding', val);
                }
              ),
              
              SwitchListTile(
                title: Text('Im Hintergrund pausieren'),
                subtitle: Text('Spart Akku wenn App nicht sichtbar'),
                value: pauseWhenBackground,
                onChanged: (val) async {
                  pauseWhenBackground = val;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('pauseWhenBackground', val);
                }
              ),
              
              SwitchListTile(
                title: Text('Langsamer bei niedrigem Akku'),
                subtitle: Text('Reduziert Transfers bei < 20%'),
                value: reducedSlotsWhenLowBattery,
                onChanged: (val) async {
                  reducedSlotsWhenLowBattery = val;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('reducedSlotsWhenLowBattery', val);
                }
              )
            ]
          )
        ),
        actions: [
          TextButton(
            child: Text('Schließen'),
            onPressed: () => Navigator.pop(context)
          )
        ]
      )
    );
  }
}

class TransferSettings {
  final int maxUploadSlots;
  final int maxDownloadSlots;
  final int chunkRequestDelay;
  final bool allowBackground;
  
  TransferSettings({
    required this.maxUploadSlots,
    required this.maxDownloadSlots,
    required this.chunkRequestDelay,
    required this.allowBackground,
  });
}
```

**Dependencies:**

```yaml
# pubspec.yaml (add these)
dependencies:
  battery_plus: ^4.0.2
  connectivity_plus: ^5.0.1
```

---

## 🟢 NICE-TO-HAVE

### 8. Server-Cache für kleine Files

#### Problem
- Uploader teilt kleine Datei (5 MB) → geht offline
- Downloader kann nicht mehr laden, obwohl File klein ist

#### Lösung: Server cached erste Chunks temporär

```javascript
// server/lib/file-cache.js

const LRU = require('lru-cache');

class FileCacheService {
  constructor() {
    // LRU Cache: Max 500 MB total
    this.cache = new LRU({
      max: 500 * 1024 * 1024, // 500 MB
      length: (chunk) => chunk.data.length,
      maxAge: 24 * 60 * 60 * 1000 // 24 hours
    });
    
    this.stats = {
      hits: 0,
      misses: 0,
      cachedFiles: 0
    };
  }
  
  // Check if file should be cached
  shouldCache(fileSize) {
    return fileSize <= 50 * 1024 * 1024; // Cache files < 50 MB
  }
  
  // Cache chunk
  cacheChunk(fileId, chunkIndex, encryptedData) {
    const key = `${fileId}:${chunkIndex}`;
    
    this.cache.set(key, {
      data: encryptedData,
      cachedAt: Date.now()
    });
    
    console.log(`📦 Cached chunk ${chunkIndex} for file ${fileId}`);
  }
  
  // Get cached chunk
  getCachedChunk(fileId, chunkIndex) {
    const key = `${fileId}:${chunkIndex}`;
    const cached = this.cache.get(key);
    
    if (cached) {
      this.stats.hits++;
      console.log(`✅ Cache HIT: ${key}`);
      return cached.data;
    }
    
    this.stats.misses++;
    console.log(`❌ Cache MISS: ${key}`);
    return null;
  }
  
  // Request uploader to cache chunks
  requestCaching(socket, fileId, chunkCount) {
    const chunksToCache = Math.min(chunkCount, 10); // First 10 chunks max
    
    socket.emit('file:request-initial-chunks', {
      fileId,
      chunks: Array.from({ length: chunksToCache }, (_, i) => i)
    });
    
    console.log(`📨 Requested ${chunksToCache} chunks for caching: ${fileId}`);
  }
  
  // Get stats
  getStats() {
    return {
      ...this.stats,
      cacheSize: this.cache.length,
      hitRate: this.stats.hits / (this.stats.hits + this.stats.misses) || 0
    };
  }
}

const fileCacheService = new FileCacheService();

// Socket.IO Integration
io.on('connection', (socket) => {
  
  // Handle file offer
  socket.on('file:offer', async (data) => {
    const { fileId, fileSize, chunkCount } = data;
    
    // Cache small files
    if (fileCacheService.shouldCache(fileSize)) {
      fileCacheService.requestCaching(socket, fileId, chunkCount);
    }
  });
  
  // Uploader sends chunks for caching
  socket.on('file:cache-chunk', (data) => {
    const { fileId, chunkIndex, encryptedData } = data;
    fileCacheService.cacheChunk(fileId, chunkIndex, Buffer.from(encryptedData));
  });
  
  // Downloader requests chunk (check cache first)
  socket.on('file:request-chunk', (data) => {
    const { fileId, chunkIndex, requesterId } = data;
    
    // Try cache first
    const cachedChunk = fileCacheService.getCachedChunk(fileId, chunkIndex);
    
    if (cachedChunk) {
      // Serve from cache
      io.to(requesterId).emit('file:chunk-data', {
        fileId,
        chunkIndex,
        encryptedData: cachedChunk,
        source: 'server-cache'
      });
      return;
    }
    
    // Fallback: relay from seeder
    // ... (existing relay logic)
  });
});

module.exports = fileCacheService;
```

---

### 9. Auto-Resume nach Crash

#### Problem
- Browser crashed während Download
- User öffnet App wieder → **Keine Info** über pausierte Downloads

#### Lösung: Automatic Recovery

```dart
// client/lib/services/crash_recovery_service.dart

class CrashRecoveryService {
  static final CrashRecoveryService instance = CrashRecoveryService._();
  CrashRecoveryService._();
  
  Future<void> checkForCrashedDownloads() async {
    // Get all downloads that were in progress
    final activeDownloads = await _storage.getAllDownloadStates();
    
    final now = DateTime.now();
    final crashedDownloads = <DownloadState>[];
    
    for (final state in activeDownloads) {
      // Check if download was active recently
      final lastUpdate = state['lastUpdate'] != null 
        ? DateTime.parse(state['lastUpdate'])
        : null;
      
      if (lastUpdate != null) {
        final timeSinceUpdate = now.difference(lastUpdate);
        
        // If last update > 5 minutes ago and not paused = crashed
        if (timeSinceUpdate.inMinutes > 5 && !state['isPaused']) {
          crashedDownloads.add(DownloadState.fromJson(state));
        }
      }
    }
    
    if (crashedDownloads.isEmpty) {
      print('✅ No crashed downloads found');
      return;
    }
    
    print('⚠️ Found ${crashedDownloads.length} crashed downloads');
    
    // Show recovery notification
    _showRecoveryNotification(crashedDownloads);
  }
  
  void _showRecoveryNotification(List<DownloadState> downloads) {
    if (downloads.length == 1) {
      final download = downloads.first;
      
      showNotification(
        title: 'Download unterbrochen',
        body: '${download.fileName} wurde nicht fertig geladen (${(download.progress * 100).toStringAsFixed(0)}%)',
        actions: ['Fortsetzen', 'Verwerfen'],
        onActionPressed: (action) {
          if (action == 'Fortsetzen') {
            DownloadManager.instance.resumeDownload(download.fileId);
          } else {
            DownloadManager.instance.cancelDownload(download.fileId);
          }
        }
      );
    } else {
      // Multiple downloads
      showNotification(
        title: 'Downloads unterbrochen',
        body: '${downloads.length} Downloads wurden nicht fertig geladen',
        actions: ['Alle fortsetzen', 'Verwalten'],
        onActionPressed: (action) {
          if (action == 'Alle fortsetzen') {
            for (final download in downloads) {
              DownloadManager.instance.resumeDownload(download.fileId);
            }
          } else {
            // Open downloads page
            navigatorKey.currentState?.pushNamed('/downloads');
          }
        }
      );
    }
  }
  
  // Mark download as active (heartbeat)
  Future<void> markDownloadActive(String fileId) async {
    await _storage.updateDownloadState(fileId, {
      'lastUpdate': DateTime.now().toIso8601String()
    });
  }
}

// Call in main.dart on app startup
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // ... other init
  
  // Check for crashed downloads
  await CrashRecoveryService.instance.checkForCrashedDownloads();
  
  runApp(MyApp());
}
```

---

### 10. Background Mode Warning

#### Problem
- User teilt File → schließt App sofort
- Andere können nicht downloaden
- **User weiß nicht** dass er online bleiben muss

#### Lösung: Intelligent Warning System

```dart
// client/lib/services/background_warning_service.dart

class BackgroundWarningService {
  static final BackgroundWarningService instance = BackgroundWarningService._();
  BackgroundWarningService._();
  
  bool _hasActiveUploads = false;
  bool _hasActiveDownloads = false;
  bool _userAcknowledgedWarning = false;
  
  // Check if warning should be shown
  bool shouldShowWarning() {
    if (_userAcknowledgedWarning) return false;
    
    // Only warn if user is the only seeder
    return _hasActiveUploads && !_hasOtherSeeders();
  }
  
  bool _hasOtherSeeders() {
    final uploads = FileTransferService.instance.getActiveUploads();
    
    for (final upload in uploads) {
      final seederCount = upload['seederCount'] ?? 1;
      if (seederCount < 2) {
        return false; // Only 1 seeder (user)
      }
    }
    
    return true; // Other seeders exist
  }
  
  // Show warning when app goes to background
  Future<void> onAppPaused() async {
    if (!shouldShowWarning()) return;
    
    final result = await showDialog<bool>(
      context: navigatorKey.currentContext!,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning, color: Colors.orange),
            SizedBox(width: 8),
            Text('App im Hintergrund')
          ]
        ),
        content: Text(
          'Du hast Dateien geteilt die andere noch herunterladen.\n\n'
          '⚠️ Wenn du die App schließt können andere nicht mehr downloaden.\n\n'
          'Bleibe online bis jemand die Datei vollständig hat.'
        ),
        actions: [
          TextButton(
            child: Text('Verstanden'),
            onPressed: () {
              _userAcknowledgedWarning = true;
              Navigator.pop(context, true);
            }
          ),
          ElevatedButton(
            child: Text('Uploads pausieren'),
            onPressed: () {
              _pauseAllUploads();
              Navigator.pop(context, false);
            }
          )
        ]
      )
    );
    
    if (result == true) {
      // User acknowledged, allow background
      print('✅ User acknowledged background warning');
    }
  }
  
  void _pauseAllUploads() {
    final uploads = FileTransferService.instance.getActiveUploads();
    
    for (final upload in uploads) {
      FileTransferService.instance.pauseUpload(upload['fileId']);
    }
    
    showNotification(
      'Uploads pausiert',
      'Deine geteilten Dateien sind vorübergehend offline'
    );
  }
  
  // Monitor app lifecycle
  void init() {
    WidgetsBinding.instance.addObserver(_AppLifecycleObserver(this));
  }
}

class _AppLifecycleObserver extends WidgetsBindingObserver {
  final BackgroundWarningService service;
  
  _AppLifecycleObserver(this.service);
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      service.onAppPaused();
    }
  }
}

// Init in main.dart
void main() {
  // ...
  BackgroundWarningService.instance.init();
  runApp(MyApp());
}
```

---

## 📊 Implementation Roadmap

### **Phase 1: MVP** (Woche 1-2)
- ✅ Basic P2P Transfer
- ✅ **Pause/Resume** (KRITISCH)
- ✅ Basic Progress UI

### **Phase 2: Robustheit** (Woche 3-4)
- ✅ **Server-Relay Fallback** (KRITISCH)
- ✅ **Seeder Notifications**
- ✅ **ETA Calculator**

### **Phase 3: UX Polish** (Woche 5-6)
- ✅ **Preview System**
- ✅ **Uploader Status Widget**
- ✅ **Power Management**

### **Phase 4: Nice-to-Have** (Woche 7+)
- ✅ Server-Cache
- ✅ Auto-Resume
- ✅ Background Warning

---

## 🎯 Prioritäten-Matrix

| Feature | User Impact | Implementation Effort | Priority |
|---------|-------------|----------------------|----------|
| Pause/Resume | ⭐⭐⭐⭐⭐ | Medium | 🔴 CRITICAL |
| Server-Relay | ⭐⭐⭐⭐⭐ | Medium | 🔴 CRITICAL |
| Seeder Notifications | ⭐⭐⭐⭐ | Low | 🔴 CRITICAL |
| Uploader Status | ⭐⭐⭐⭐ | Medium | 🔴 CRITICAL |
| Preview/Thumbnails | ⭐⭐⭐⭐ | High | 🟡 IMPORTANT |
| ETA & Speed | ⭐⭐⭐ | Low | 🟡 IMPORTANT |
| Power Management | ⭐⭐⭐ | Medium | 🟡 IMPORTANT |
| Server Cache | ⭐⭐ | Medium | 🟢 NICE-TO-HAVE |
| Auto-Resume | ⭐⭐⭐ | Low | 🟢 NICE-TO-HAVE |
| Background Warning | ⭐⭐ | Low | 🟢 NICE-TO-HAVE |

---

## ✅ Success Metrics

Nach Implementation dieser Verbesserungen erwarten wir:

1. **Download Success Rate**: 95% → 99% (durch Server-Relay)
2. **User Frustration**: 40% → 10% (durch Pause/Resume)
3. **Abandoned Downloads**: 30% → 5% (durch ETA & Notifications)
4. **Uploader Engagement**: +50% (durch Status-Feedback)
5. **Battery Complaints**: -70% (durch Power Management)

**Bereit für Implementation!** 🚀
