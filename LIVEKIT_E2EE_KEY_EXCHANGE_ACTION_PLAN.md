# LiveKit E2EE Key Exchange - Action Plan

**Erstellt:** 2. November 2025  
**Status:** Ready for Implementation  
**Ziel:** End-to-End Encryption (E2EE) Key Exchange für LiveKit WebRTC Channels mit Signal Protocol

---

## 📋 ARCHITEKTUR-ÜBERSICHT

### 🔑 Key Management

**Zwei separate Keys:**
1. **Signal SenderKey** (Group Messaging)
   - Verschlüsselt Signal Protocol Nachrichten im Channel
   - Wird automatisch beim ersten `sendGroupItem` erstellt
   - Verwendet für: Chat Messages, File Shares, **E2EE Key Exchange**

2. **LiveKit E2EE Key** (WebRTC Frames)
   - Verschlüsselt Video/Audio Frames (AES-256)
   - Wird vom First Participant generiert
   - Über Signal Protocol an andere Participants verteilt
   - **Pro Session ein neuer Key** (Forward Secrecy)

### 🎯 Wichtige Design-Entscheidungen

#### Race Condition Lösung
**Problem:** 3 Nutzer joinen gleichzeitig → alle generieren unterschiedliche Keys

**Lösung:** **Timestamp-basierte Priorisierung**
- Jeder Key hat einen Timestamp (Generierungszeit)
- Bei Key Exchange: **Ältester Timestamp gewinnt**
- Alle Participants übernehmen den Key mit dem ältesten Timestamp
- Garantiert: Alle haben denselben Key, auch bei simultaneous join

#### Key Rotation Strategie
**Scenario 1:** First Participant verlässt Channel
- Second Participant (nächster in der Reihe) übernimmt Key-Weitergabe
- Behält den existierenden Key bei (kein neuer Key)
- Teilt Key mit neuen Joinern

**Scenario 2:** Alle Participants verlassen Channel
- Channel wird "leer"
- Nächster Joiner wird First Participant
- Generiert **neuen Key** → Forward Secrecy
- Jede Session hat eigenen Key

#### Server RAM Storage
**Participant Tracking:**
- Server speichert aktive Participants im RAM (Map)
- Pro Channel: Liste von `{ userId, socketId, joinedAt, hasE2EEKey }`
- Cleanup bei:
  - Socket disconnect
  - Explicit leave
  - Browser close

**Warum RAM?**
- ✅ Keine Persistierung sensibler Daten
- ✅ Automatic cleanup bei Server restart
- ✅ Fast access für First Participant Check

---

## 🔧 IMPLEMENTIERUNGS-PHASEN

---

## **PHASE 0.5: SIGNAL PROTOCOL FÜR WEBRTC CHANNELS**

### Kontext
WebRTC Channels (`type: 'webrtc'`) benötigen Signal Protocol für E2EE Key Exchange. 

**Wichtig:** Signal SenderKey wird **automatisch** beim ersten `sendGroupItem` erstellt. Kein separates Setup erforderlich!

### Schritt 0.5.1: Dokumentation & Klarstellung

**Was funktioniert bereits:**
- Signal Channels (`type: 'signal'`) nutzen Signal Protocol für Messages ✅
- WebRTC Channels können ebenfalls `sendGroupItem` nutzen ✅
- SenderKey wird on-demand erstellt (lazy initialization) ✅

**Was wir tun:**
- Dokumentieren dass WebRTC Channels Signal Protocol nutzen können
- Sicherstellen dass Client Signal Service vor Video Call initialisiert

### Schritt 0.5.2: Client Signal Service Check

**Datei:** `client/lib/services/video_conference_service.dart`

```dart
/// Join a video conference room
Future<void> joinRoom(String channelId) async {
  if (_isConnecting || _isConnected) {
    print('[VideoConf] Already connecting or connected');
    return;
  }

  try {
    _isConnecting = true;
    _currentChannelId = channelId;
    notifyListeners();

    print('[VideoConf] Joining room for channel: $channelId');

    // WICHTIG: Signal Service muss initialisiert sein für Key Exchange
    if (!SignalService.instance.isInitialized) {
      throw Exception('Signal Service must be initialized before joining video call. Key exchange requires Signal Protocol.');
    }

    // Initialize E2EE
    await _initializeE2EE();
    // ...
```

**Ziel:** Sicherstellen dass Signal Service ready ist für Key Exchange

---

## **PHASE 1: SERVER INFRASTRUCTURE**

### Schritt 1.1: In-Memory Participant Storage

**Datei:** `server/server.js`

**Einfügen nach Line ~100 (nach imports, vor Socket.IO setup):**

```javascript
// ============================================
// VIDEO CONFERENCE PARTICIPANT TRACKING (RAM)
// ============================================

/**
 * In-Memory Storage für aktive WebRTC Channel Participants
 * Structure: Map<channelId, Set<ParticipantInfo>>
 * 
 * ParticipantInfo: {
 *   userId: string,
 *   socketId: string,
 *   joinedAt: number (timestamp),
 *   hasE2EEKey: boolean
 * }
 * 
 * Cleanup: Automatic on disconnect, manual on leave
 */
const activeVideoParticipants = new Map();

/**
 * Add participant to active participants list
 */
function addVideoParticipant(channelId, userId, socketId) {
    if (!activeVideoParticipants.has(channelId)) {
        activeVideoParticipants.set(channelId, new Set());
    }
    
    const participants = activeVideoParticipants.get(channelId);
    
    // Remove existing entry for this user (if reconnecting)
    participants.forEach(p => {
        if (p.userId === userId) participants.delete(p);
    });
    
    // Add new entry
    participants.add({
        userId,
        socketId,
        joinedAt: Date.now(),
        hasE2EEKey: false
    });
    
    console.log(`[VIDEO PARTICIPANTS] Added ${userId} to channel ${channelId} (total: ${participants.size})`);
}

/**
 * Remove participant from active participants list
 */
function removeVideoParticipant(channelId, socketId) {
    if (!activeVideoParticipants.has(channelId)) return;
    
    const participants = activeVideoParticipants.get(channelId);
    let removedUserId = null;
    
    participants.forEach(p => {
        if (p.socketId === socketId) {
            removedUserId = p.userId;
            participants.delete(p);
        }
    });
    
    // Cleanup empty channels
    if (participants.size === 0) {
        activeVideoParticipants.delete(channelId);
        console.log(`[VIDEO PARTICIPANTS] Channel ${channelId} empty - removed from tracking`);
    } else {
        console.log(`[VIDEO PARTICIPANTS] Removed ${removedUserId} from channel ${channelId} (remaining: ${participants.size})`);
    }
}

/**
 * Get all participants for a channel
 */
function getVideoParticipants(channelId) {
    if (!activeVideoParticipants.has(channelId)) {
        return [];
    }
    return Array.from(activeVideoParticipants.get(channelId));
}

/**
 * Update participant E2EE key status
 */
function updateParticipantKeyStatus(channelId, socketId, hasKey) {
    if (!activeVideoParticipants.has(channelId)) return;
    
    const participants = activeVideoParticipants.get(channelId);
    participants.forEach(p => {
        if (p.socketId === socketId) {
            p.hasE2EEKey = hasKey;
            console.log(`[VIDEO PARTICIPANTS] Updated ${p.userId} key status: ${hasKey}`);
        }
    });
}
```

**Ziel:** RAM-basierte Participant Verwaltung für First Participant Check

---

### Schritt 1.2: Socket.IO Events für Participant Management

**Datei:** `server/server.js`

**Einfügen nach Video E2EE Handlers (nach Line ~1815):**

```javascript
  // ============================================
  // VIDEO CONFERENCE PARTICIPANT MANAGEMENT
  // ============================================

  /**
   * Check participants in a channel (called by PreJoin screen)
   * Client asks: "How many participants are in this channel? Am I first?"
   */
  socket.on("video:check-participants", async (data) => {
    try {
      if (!socket.handshake.session.uuid) {
        console.error('[VIDEO PARTICIPANTS] Check blocked - not authenticated');
        socket.emit("video:participants-info", { error: "Not authenticated" });
        return;
      }

      const { channelId } = data;
      const userId = socket.handshake.session.uuid;

      if (!channelId) {
        console.error('[VIDEO PARTICIPANTS] Missing channelId');
        socket.emit("video:participants-info", { error: "Missing channelId" });
        return;
      }

      // Check if user is member of channel
      const membership = await ChannelMembers.findOne({
        where: {
          userId: userId,
          channelId: channelId
        }
      });

      if (!membership) {
        console.error('[VIDEO PARTICIPANTS] User not member of channel');
        socket.emit("video:participants-info", { error: "Not a member of this channel" });
        return;
      }

      // Get active participants
      const participants = getVideoParticipants(channelId);
      
      // Filter out requesting user from count (they're not "in" yet)
      const otherParticipants = participants.filter(p => p.userId !== userId);
      
      console.log(`[VIDEO PARTICIPANTS] Check for channel ${channelId}: ${otherParticipants.length} active participants`);

      socket.emit("video:participants-info", {
        channelId: channelId,
        participantCount: otherParticipants.length,
        isFirstParticipant: otherParticipants.length === 0,
        participants: otherParticipants.map(p => ({
          userId: p.userId,
          joinedAt: p.joinedAt,
          hasE2EEKey: p.hasE2EEKey
        }))
      });
    } catch (error) {
      console.error('[VIDEO PARTICIPANTS] Error checking participants:', error);
      socket.emit("video:participants-info", { error: "Internal server error" });
    }
  });

  /**
   * Register as participant (called by PreJoin screen after device selection)
   * Client says: "I'm about to join, add me to the list"
   */
  socket.on("video:register-participant", async (data) => {
    try {
      if (!socket.handshake.session.uuid) {
        console.error('[VIDEO PARTICIPANTS] Register blocked - not authenticated');
        return;
      }

      const { channelId } = data;
      const userId = socket.handshake.session.uuid;

      if (!channelId) {
        console.error('[VIDEO PARTICIPANTS] Missing channelId');
        return;
      }

      // Verify channel membership
      const membership = await ChannelMembers.findOne({
        where: {
          userId: userId,
          channelId: channelId
        }
      });

      if (!membership) {
        console.error('[VIDEO PARTICIPANTS] User not member of channel');
        return;
      }

      // Add to active participants
      addVideoParticipant(channelId, userId, socket.id);

      // Join Socket.IO room for this channel
      socket.join(channelId);

      // Notify other participants
      socket.to(channelId).emit("video:participant-joined", {
        userId: userId,
        joinedAt: Date.now()
      });

      console.log(`[VIDEO PARTICIPANTS] User ${userId} registered for channel ${channelId}`);
    } catch (error) {
      console.error('[VIDEO PARTICIPANTS] Error registering participant:', error);
    }
  });

  /**
   * Confirm E2EE key received (called after successful key exchange)
   * Client says: "I have the encryption key now"
   */
  socket.on("video:confirm-e2ee-key", async (data) => {
    try {
      if (!socket.handshake.session.uuid) {
        console.error('[VIDEO PARTICIPANTS] Key confirm blocked - not authenticated');
        return;
      }

      const { channelId } = data;
      const userId = socket.handshake.session.uuid;

      if (!channelId) {
        console.error('[VIDEO PARTICIPANTS] Missing channelId');
        return;
      }

      // Update key status
      updateParticipantKeyStatus(channelId, socket.id, true);

      // Notify other participants
      socket.to(channelId).emit("video:participant-key-confirmed", {
        userId: userId
      });

      console.log(`[VIDEO PARTICIPANTS] User ${userId} confirmed E2EE key for channel ${channelId}`);
    } catch (error) {
      console.error('[VIDEO PARTICIPANTS] Error confirming key:', error);
    }
  });

  /**
   * Leave channel (called when user closes video call)
   * Client says: "I'm leaving the call"
   */
  socket.on("video:leave-channel", async (data) => {
    try {
      if (!socket.handshake.session.uuid) {
        console.error('[VIDEO PARTICIPANTS] Leave blocked - not authenticated');
        return;
      }

      const { channelId } = data;
      const userId = socket.handshake.session.uuid;

      if (!channelId) {
        console.error('[VIDEO PARTICIPANTS] Missing channelId');
        return;
      }

      // Remove from active participants
      removeVideoParticipant(channelId, socket.id);

      // Leave Socket.IO room
      socket.leave(channelId);

      // Notify other participants
      socket.to(channelId).emit("video:participant-left", {
        userId: userId
      });

      console.log(`[VIDEO PARTICIPANTS] User ${userId} left channel ${channelId}`);
    } catch (error) {
      console.error('[VIDEO PARTICIPANTS] Error leaving channel:', error);
    }
  });
```

**Ziel:** Real-time Participant Tracking mit Socket.IO Events

---

### Schritt 1.3: Automatic Cleanup on Disconnect

**Datei:** `server/server.js`

**Update existing disconnect handler (finde "socket.on('disconnect')"):**

```javascript
  socket.on("disconnect", () => {
    const userId = socket.handshake.session?.uuid;
    const deviceId = socket.handshake.session?.deviceId;
    
    console.log(`[SOCKET] Client disconnected: ${socket.id} (User: ${userId}, Device: ${deviceId})`);
    
    // Existing cleanup code...
    if (userId && deviceId) {
      deviceSockets.delete(`${userId}:${deviceId}`);
    }

    // NEW: Cleanup video participants
    activeVideoParticipants.forEach((participants, channelId) => {
      const beforeSize = participants.size;
      removeVideoParticipant(channelId, socket.id);
      const afterSize = getVideoParticipants(channelId).length;
      
      if (beforeSize !== afterSize) {
        // Notify other participants in this channel
        socket.to(channelId).emit("video:participant-left", {
          userId: userId
        });
      }
    });
  });
```

**Ziel:** Automatic cleanup bei Connection Loss

---

## **PHASE 2: CLIENT - PREJOIN SEITE**

### Schritt 2.1: PreJoin View erstellen

**Datei:** `client/lib/views/video_conference_prejoin_view.dart` (NEU)

```dart
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import '../services/video_conference_service.dart';
import '../services/signal_service.dart';
import '../services/socket_service.dart';
import 'video_conference_view.dart';

/// PreJoin screen for video conference
/// Shows device selection and handles E2EE key exchange BEFORE joining
class VideoConferencePreJoinView extends StatefulWidget {
  final String channelId;
  final String channelName;
  
  const VideoConferencePreJoinView({
    Key? key,
    required this.channelId,
    required this.channelName,
  }) : super(key: key);

  @override
  State<VideoConferencePreJoinView> createState() => _VideoConferencePreJoinViewState();
}

class _VideoConferencePreJoinViewState extends State<VideoConferencePreJoinView> {
  // Device Selection
  List<MediaDevice> _cameras = [];
  List<MediaDevice> _microphones = [];
  MediaDevice? _selectedCamera;
  MediaDevice? _selectedMicrophone;
  bool _isLoadingDevices = true;
  
  // Participant Info
  bool _isFirstParticipant = false;
  int _participantCount = 0;
  bool _isCheckingParticipants = true;
  
  // E2EE Key Exchange
  bool _hasE2EEKey = false;
  bool _isExchangingKey = false;
  String? _keyExchangeError;
  
  // Preview Track
  LocalVideoTrack? _previewTrack;
  bool _isCameraEnabled = true;
  bool _isMicrophoneEnabled = true;
  
  @override
  void initState() {
    super.initState();
    _initializePreJoin();
  }
  
  @override
  void dispose() {
    _previewTrack?.dispose();
    super.dispose();
  }
  
  /// Initialize PreJoin flow
  Future<void> _initializePreJoin() async {
    try {
      // Step 1: Ensure Signal Service is initialized
      if (!SignalService.instance.isInitialized) {
        print('[PreJoin] Initializing Signal Service...');
        await SignalService.instance.initialize();
      }
      
      // Step 2: Load available media devices
      await _loadMediaDevices();
      
      // Step 3: Register as participant (enters "waiting room")
      await _registerAsParticipant();
      
      // Step 4: Check if first participant
      await _checkParticipantStatus();
      
      // Step 5: Handle E2EE key exchange
      if (_isFirstParticipant) {
        // First participant generates key locally (not shared yet)
        setState(() {
          _hasE2EEKey = true;
          print('[PreJoin] First participant - will generate E2EE key on join');
        });
      } else {
        // Request E2EE key from existing participants
        await _requestE2EEKey();
      }
      
      // Step 6: Start camera preview
      if (_isCameraEnabled && _selectedCamera != null) {
        await _startCameraPreview();
      }
      
    } catch (e) {
      print('[PreJoin] Initialization error: $e');
      setState(() {
        _keyExchangeError = 'Initialization failed: $e';
      });
    }
  }
  
  /// Load available cameras and microphones
  Future<void> _loadMediaDevices() async {
    try {
      setState(() => _isLoadingDevices = true);
      
      final devices = await Hardware.instance.enumerateDevices();
      
      _cameras = devices.where((d) => d.kind == 'videoinput').toList();
      _microphones = devices.where((d) => d.kind == 'audioinput').toList();
      
      // Select first available devices
      _selectedCamera = _cameras.isNotEmpty ? _cameras.first : null;
      _selectedMicrophone = _microphones.isNotEmpty ? _microphones.first : null;
      
      setState(() => _isLoadingDevices = false);
      
      print('[PreJoin] Loaded ${_cameras.length} cameras, ${_microphones.length} microphones');
    } catch (e) {
      print('[PreJoin] Error loading devices: $e');
      setState(() {
        _isLoadingDevices = false;
        _keyExchangeError = 'Failed to load media devices: $e';
      });
    }
  }
  
  /// Register as participant on server
  Future<void> _registerAsParticipant() async {
    try {
      SocketService().emit('video:register-participant', {
        'channelId': widget.channelId,
      });
      print('[PreJoin] Registered as participant');
    } catch (e) {
      print('[PreJoin] Error registering participant: $e');
    }
  }
  
  /// Check participant status (am I first?)
  Future<void> _checkParticipantStatus() async {
    try {
      setState(() => _isCheckingParticipants = true);
      
      // Listen for response
      final completer = Completer<Map<String, dynamic>>();
      
      void listener(dynamic data) {
        if (data['channelId'] == widget.channelId) {
          completer.complete(Map<String, dynamic>.from(data));
        }
      }
      
      SocketService().registerListener('video:participants-info', listener);
      
      // Request participant info
      SocketService().emit('video:check-participants', {
        'channelId': widget.channelId,
      });
      
      // Wait for response (timeout 5s)
      final result = await completer.future.timeout(
        Duration(seconds: 5),
        onTimeout: () => {'error': 'Timeout'},
      );
      
      SocketService().unregisterListener('video:participants-info', listener);
      
      if (result.containsKey('error')) {
        throw Exception(result['error']);
      }
      
      setState(() {
        _isFirstParticipant = result['isFirstParticipant'] ?? false;
        _participantCount = result['participantCount'] ?? 0;
        _isCheckingParticipants = false;
      });
      
      print('[PreJoin] Participant check: first=$_isFirstParticipant, count=$_participantCount');
    } catch (e) {
      print('[PreJoin] Error checking participants: $e');
      setState(() {
        _isCheckingParticipants = false;
        _keyExchangeError = 'Failed to check participants: $e';
      });
    }
  }
  
  /// Request E2EE key from existing participants
  Future<void> _requestE2EEKey() async {
    try {
      setState(() {
        _isExchangingKey = true;
        _keyExchangeError = null;
      });
      
      print('[PreJoin] Requesting E2EE key...');
      
      // Send key request via Signal Protocol
      final success = await VideoConferenceService.instance.requestE2EEKey(widget.channelId);
      
      setState(() {
        _hasE2EEKey = success;
        _isExchangingKey = false;
        
        if (!success) {
          _keyExchangeError = 'Failed to receive encryption key from other participants';
        }
      });
      
      if (success) {
        print('[PreJoin] ✓ E2EE key received successfully');
      } else {
        print('[PreJoin] ⚠️ E2EE key exchange failed');
      }
    } catch (e) {
      print('[PreJoin] Error requesting E2EE key: $e');
      setState(() {
        _hasE2EEKey = false;
        _isExchangingKey = false;
        _keyExchangeError = 'Key exchange error: $e';
      });
    }
  }
  
  /// Start camera preview
  Future<void> _startCameraPreview() async {
    try {
      if (_selectedCamera == null) return;
      
      _previewTrack = await LocalVideoTrack.createCameraTrack(
        CameraCaptureOptions(
          deviceId: _selectedCamera!.deviceId,
        ),
      );
      
      setState(() {});
      print('[PreJoin] Camera preview started');
    } catch (e) {
      print('[PreJoin] Error starting camera preview: $e');
    }
  }
  
  /// Join the video call
  Future<void> _joinChannel() async {
    if (!_hasE2EEKey) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot join: Encryption key not ready')),
      );
      return;
    }
    
    try {
      // Confirm E2EE key status to server
      SocketService().emit('video:confirm-e2ee-key', {
        'channelId': widget.channelId,
      });
      
      // Navigate to actual video conference view
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => VideoConferenceView(
            channelId: widget.channelId,
            // Pass selected devices
            selectedCamera: _selectedCamera,
            selectedMicrophone: _selectedMicrophone,
          ),
        ),
      );
    } catch (e) {
      print('[PreJoin] Error joining channel: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to join: $e')),
      );
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Join ${widget.channelName}'),
      ),
      body: _isLoadingDevices
          ? Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Video Preview
                Expanded(
                  flex: 3,
                  child: Container(
                    color: Colors.black,
                    child: _previewTrack != null && _isCameraEnabled
                        ? VideoTrackRenderer(_previewTrack!)
                        : Center(
                            child: Icon(
                              Icons.videocam_off,
                              size: 64,
                              color: Colors.white54,
                            ),
                          ),
                  ),
                ),
                
                // Controls
                Expanded(
                  flex: 2,
                  child: Container(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      children: [
                        // Device Selection
                        _buildDeviceSelection(),
                        
                        SizedBox(height: 16),
                        
                        // E2EE Status
                        _buildE2EEStatus(),
                        
                        Spacer(),
                        
                        // Join Button
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: ElevatedButton(
                            onPressed: _hasE2EEKey && !_isExchangingKey ? _joinChannel : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                            ),
                            child: Text(
                              _hasE2EEKey 
                                  ? 'Join Call' 
                                  : (_isExchangingKey ? 'Exchanging Keys...' : 'Waiting for Encryption Key...'),
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
  
  /// Build device selection UI
  Widget _buildDeviceSelection() {
    return Column(
      children: [
        // Camera Selection
        if (_cameras.isNotEmpty)
          DropdownButtonFormField<MediaDevice>(
            value: _selectedCamera,
            decoration: InputDecoration(
              labelText: 'Camera',
              prefixIcon: Icon(Icons.videocam),
              border: OutlineInputBorder(),
            ),
            items: _cameras.map((device) {
              return DropdownMenuItem(
                value: device,
                child: Text(device.label),
              );
            }).toList(),
            onChanged: (device) async {
              setState(() => _selectedCamera = device);
              // Restart preview with new camera
              await _previewTrack?.dispose();
              if (_isCameraEnabled) {
                await _startCameraPreview();
              }
            },
          ),
        
        SizedBox(height: 8),
        
        // Microphone Selection
        if (_microphones.isNotEmpty)
          DropdownButtonFormField<MediaDevice>(
            value: _selectedMicrophone,
            decoration: InputDecoration(
              labelText: 'Microphone',
              prefixIcon: Icon(Icons.mic),
              border: OutlineInputBorder(),
            ),
            items: _microphones.map((device) {
              return DropdownMenuItem(
                value: device,
                child: Text(device.label),
              );
            }).toList(),
            onChanged: (device) {
              setState(() => _selectedMicrophone = device);
            },
          ),
      ],
    );
  }
  
  /// Build E2EE status indicator
  Widget _buildE2EEStatus() {
    if (_isCheckingParticipants) {
      return ListTile(
        leading: CircularProgressIndicator(),
        title: Text('Checking participants...'),
        subtitle: Text('Verifying who else is in the call'),
      );
    }
    
    if (_isFirstParticipant) {
      return ListTile(
        leading: Icon(Icons.lock, color: Colors.green, size: 32),
        title: Text('You are the first participant'),
        subtitle: Text('Encryption key will be generated when you join'),
      );
    }
    
    if (_isExchangingKey) {
      return ListTile(
        leading: CircularProgressIndicator(),
        title: Text('Exchanging encryption keys...'),
        subtitle: Text('$_participantCount ${_participantCount == 1 ? "participant" : "participants"} in call'),
      );
    }
    
    if (_hasE2EEKey) {
      return ListTile(
        leading: Icon(Icons.lock, color: Colors.green, size: 32),
        title: Text('End-to-end encryption ready'),
        subtitle: Text('Keys exchanged securely via Signal Protocol'),
      );
    }
    
    return ListTile(
      leading: Icon(Icons.error, color: Colors.red, size: 32),
      title: Text('Key exchange failed'),
      subtitle: Text(_keyExchangeError ?? 'Unknown error'),
      trailing: TextButton(
        onPressed: _requestE2EEKey,
        child: Text('Retry'),
      ),
    );
  }
}
```

**Ziel:** PreJoin Screen mit Device Selection + E2EE Key Exchange

---

### Schritt 2.2: VideoConferenceView anpassen

**Datei:** `client/lib/views/video_conference_view.dart`

**Update Constructor:**

```dart
class VideoConferenceView extends StatefulWidget {
  final String channelId;
  final MediaDevice? selectedCamera;     // NEU
  final MediaDevice? selectedMicrophone; // NEU
  
  const VideoConferenceView({
    Key? key,
    required this.channelId,
    this.selectedCamera,        // NEU
    this.selectedMicrophone,    // NEU
  }) : super(key: key);

  @override
  State<VideoConferenceView> createState() => _VideoConferenceViewState();
}
```

**In `_VideoConferenceViewState.initState()`:**

```dart
@override
void initState() {
  super.initState();
  _videoService = VideoConferenceService.instance;
  _videoService.addListener(_updateUI);
  
  // Join with pre-selected devices
  _videoService.joinRoom(
    widget.channelId,
    cameraDevice: widget.selectedCamera,      // NEU
    microphoneDevice: widget.selectedMicrophone, // NEU
  );
}
```

**Ziel:** Video Call nutzt ausgewählte Devices von PreJoin

---

### Schritt 2.3: Navigation Flow Update

**Datei:** `client/lib/views/channel_view.dart`

**Update "Join Video Call" Button:**

```dart
// Finde den "Join Video Call" button und ersetze die onPressed Funktion:

Future<void> _joinVideoCall() async {
  // Navigate to PreJoin screen (NOT directly to video call)
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => VideoConferencePreJoinView(
        channelId: widget.channelId,
        channelName: widget.channel.name ?? 'Video Call',
      ),
    ),
  );
}
```

**Ziel:** User kommt zuerst auf PreJoin Seite

---

## **PHASE 3: E2EE KEY EXCHANGE MIT TIMESTAMP**

### Schritt 3.1: Message Types Update

**Datei:** `client/lib/services/message_listener_service.dart`

**Update Line ~200 (itemType check):**

```dart
        // Check for special message types
        if (itemType == 'file_share_update') {
          await _processFileShareUpdate(
            itemId: itemId,
            channelId: channelId,
            senderId: senderId,
            senderDeviceId: senderDeviceId,
            timestamp: timestamp,
            decryptedPayload: decrypted,
          );
          return; // Don't store as regular message
        }

        // NEW: Handle video E2EE key exchange (request AND response)
        if (itemType == 'video_e2ee_key_request' || 
            itemType == 'video_e2ee_key_response') {
          await _processVideoE2EEKey(
            itemId: itemId,
            channelId: channelId,
            senderId: senderId,
            senderDeviceId: senderDeviceId,
            timestamp: timestamp,
            decryptedPayload: decrypted,
            messageType: itemType, // Pass itemType for differentiation
          );
          return; // Don't store as regular message
        }

        // REMOVE OLD: Legacy video_e2ee_key handler
        // if (itemType == 'video_e2ee_key') { ... }
```

**Ziel:** Neue Message Types für Request/Response

---

### Schritt 3.2: ProcessVideoE2EEKey Update

**Datei:** `client/lib/services/message_listener_service.dart`

**Replace `_processVideoE2EEKey` function (Line ~467):**

```dart
  /// Process video E2EE key exchange (request or response)
  Future<void> _processVideoE2EEKey({
    required String itemId,
    required String channelId,
    required String senderId,
    required int senderDeviceId,
    required String? timestamp,
    required String decryptedPayload,
    String? messageType,
  }) async {
    try {
      print('[MESSAGE_LISTENER] Processing video E2EE key: type=$messageType from $senderId');
      
      // Parse the decrypted JSON payload
      final Map<String, dynamic> keyData = jsonDecode(decryptedPayload);
      
      // Extract timestamp from payload
      final keyTimestamp = keyData['timestamp'] as int?;
      if (keyTimestamp == null) {
        print('[MESSAGE_LISTENER] ⚠️ Key message missing timestamp - ignoring');
        return;
      }
      
      // Handle based on message type
      if (messageType == 'video_e2ee_key_request') {
        // Someone is requesting the key
        final requesterId = keyData['requesterId'] as String?;
        print('[MESSAGE_LISTENER] Received key request from $requesterId (timestamp: $keyTimestamp)');
        
        if (_videoConferenceService != null && _videoConferenceService!.isConnected) {
          await _videoConferenceService!.handleKeyRequest(
            requesterId: requesterId ?? senderId,
            requestTimestamp: keyTimestamp,
          );
        }
        return;
      }
      
      if (messageType == 'video_e2ee_key_response') {
        // Someone sent us the key
        final encryptedKey = keyData['key'] as String?;
        final senderId = keyData['senderId'] as String?;
        
        print('[MESSAGE_LISTENER] Received key response from $senderId (timestamp: $keyTimestamp)');
        
        if (encryptedKey != null && _videoConferenceService != null) {
          await _videoConferenceService!.handleE2EEKey(
            senderUserId: senderId ?? senderId,
            encryptedKey: encryptedKey,
            channelId: channelId,
            timestamp: keyTimestamp, // Pass timestamp for race condition check!
          );
        }
        return;
      }
      
      print('[MESSAGE_LISTENER] ⚠️ Unknown video E2EE message type: $messageType');
      
    } catch (e) {
      print('[MESSAGE_LISTENER] Error processing video E2EE key: $e');
    }
  }
```

**Ziel:** Parse timestamp aus Payload und weiterleiten

---

### Schritt 3.3: VideoConferenceService - Key Exchange mit Timestamp

**Datei:** `client/lib/services/video_conference_service.dart`

**Add fields (nach Line ~33):**

```dart
  // E2EE components
  BaseKeyProvider? _keyProvider;
  Uint8List? _channelSharedKey;  // ONE shared key for the entire channel
  int? _keyTimestamp;  // Timestamp of current key (for race condition resolution)
  Map<String, Uint8List> _participantKeys = {};  // userId -> encryption key (legacy, for backward compat)
  Completer<bool>? _keyReceivedCompleter;  // For waiting on key exchange
```

**Add new method `requestE2EEKey` (static, vor `_initializeE2EE`):**

```dart
  /// Request E2EE Key from existing participants (called by NON-first participants)
  /// Returns true if key was received successfully, false otherwise
  static Future<bool> requestE2EEKey(String channelId) async {
    final service = VideoConferenceService.instance;
    
    try {
      print('[VideoConf] Requesting E2EE key for channel $channelId');
      
      final requestTimestamp = DateTime.now().millisecondsSinceEpoch;
      
      // Send key request via Signal Protocol (encrypted group message)
      await SignalService.instance.sendGroupItem(
        channelId: channelId,
        message: jsonEncode({
          'requesterId': SocketService().userId,
          'timestamp': requestTimestamp,
        }),
        itemId: 'video_key_req_$requestTimestamp',
        type: 'video_e2ee_key_request', // NEW itemType!
      );
      
      // Wait for key response (handled by MessageListenerService)
      service._keyReceivedCompleter = Completer<bool>();
      
      // Timeout after 10 seconds
      return await service._keyReceivedCompleter!.future.timeout(
        Duration(seconds: 10),
        onTimeout: () {
          print('[VideoConf] ⚠️ Key request timeout - no response received');
          return false;
        },
      );
    } catch (e) {
      print('[VideoConf] Error requesting E2EE key: $e');
      return false;
    }
  }
```

**Update `handleE2EEKey` method (Line ~147):**

```dart
  /// Handle received E2EE Key with TIMESTAMP RACE CONDITION check
  Future<void> handleE2EEKey({
    required String senderUserId,
    required String encryptedKey,
    required String channelId,
    required int timestamp, // NEW!
  }) async {
    try {
      if (channelId != _currentChannelId) {
        print('[VideoConf] Ignoring key for different channel');
        return;
      }

      // Empty key = Key Request (legacy, shouldn't happen with new message types)
      if (encryptedKey.isEmpty) {
        print('[VideoConf] Received empty key (legacy request format) from $senderUserId');
        await handleKeyRequest(
          requesterId: senderUserId,
          requestTimestamp: timestamp,
        );
        return;
      }

      print('[VideoConf] Received E2EE key from $senderUserId (timestamp: $timestamp)');
      
      // Decode key
      final keyBytes = base64Decode(encryptedKey);
      
      // ============================================
      // RACE CONDITION CHECK: Timestamp comparison
      // ============================================
      if (_channelSharedKey != null && _keyTimestamp != null) {
        if (timestamp > _keyTimestamp!) {
          // Newer key - REJECT
          print('[VideoConf] ⚠️ Ignoring NEWER key (timestamp $timestamp > $_keyTimestamp)');
          print('[VideoConf] → Rule: OLDER timestamp wins! Keeping current key.');
          return;
        } else if (timestamp < _keyTimestamp!) {
          // Older key - ACCEPT and REPLACE
          print('[VideoConf] ✓ Accepting OLDER key (timestamp $timestamp < $_keyTimestamp)');
          print('[VideoConf] → Replacing our key with older one (older wins!)');
        } else {
          // Same timestamp - keys should be identical
          print('[VideoConf] ℹ️ Same timestamp ($timestamp) - keys should match');
          // Accept anyway to confirm
        }
      } else {
        // First key we're receiving
        print('[VideoConf] ✓ First key received for this session');
      }
      
      // Accept key
      _channelSharedKey = keyBytes;
      _keyTimestamp = timestamp;
      
      // Set in KeyProvider
      if (_keyProvider != null) {
        try {
          final keyBase64 = base64Encode(_channelSharedKey!);
          await _keyProvider!.setKey(keyBase64);
          print('[VideoConf] ✓ E2EE key accepted and set (timestamp: $timestamp)');
          print('[VideoConf] ✓ Frame-level encryption now active');
        } catch (e) {
          print('[VideoConf] ⚠️ Failed to set key in KeyProvider: $e');
        }
      } else {
        print('[VideoConf] ✓ Key stored (KeyProvider not available)');
      }
      
      // Notify waiting completer (for PreJoin screen)
      if (_keyReceivedCompleter != null && !_keyReceivedCompleter!.isCompleted) {
        _keyReceivedCompleter!.complete(true);
      }
      
      notifyListeners();
    } catch (e) {
      print('[VideoConf] Error handling E2EE key: $e');
      if (_keyReceivedCompleter != null && !_keyReceivedCompleter!.isCompleted) {
        _keyReceivedCompleter!.complete(false);
      }
    }
  }
```

**Update `handleKeyRequest` method:**

```dart
  /// Handle incoming key request from another participant
  /// Send our SHARED CHANNEL KEY to them via Signal Protocol
  Future<void> handleKeyRequest({
    required String requesterId,
    required int requestTimestamp,
  }) async {
    try {
      if (_channelSharedKey == null || _currentChannelId == null) {
        print('[VideoConf] ⚠️ Key not initialized, cannot respond to key request');
        return;
      }

      print('[VideoConf] Received key request from $requesterId (timestamp: $requestTimestamp)');
      
      // Send our SHARED CHANNEL KEY with ORIGINAL timestamp
      // CRITICAL: Use _keyTimestamp (original key generation time), NOT requestTimestamp!
      // This ensures "oldest timestamp wins" rule works correctly
      final keyBase64 = base64Encode(_channelSharedKey!);
      final responseTimestamp = DateTime.now().millisecondsSinceEpoch;
      
      await SignalService.instance.sendGroupItem(
        channelId: _currentChannelId!,
        message: jsonEncode({
          'key': keyBase64,
          'senderId': SocketService().userId,
          'timestamp': _keyTimestamp ?? requestTimestamp, // Use original key timestamp!
        }),
        itemId: 'video_key_resp_$responseTimestamp',
        type: 'video_e2ee_key_response', // NEW itemType!
      );
      
      print('[VideoConf] ✓ Sent E2EE key to $requesterId (original timestamp: ${_keyTimestamp})');
    } catch (e) {
      print('[VideoConf] Error handling key request: $e');
    }
  }
```

**Update `_initializeE2EE` method (Line ~60):**

```dart
  /// Initialize E2EE with Signal Protocol key exchange
  Future<void> _initializeE2EE() async {
    try {
      print('[VideoConf] Initializing E2EE with Signal Protocol');
      
      // Generate ONE shared key for this channel with timestamp
      final random = Random.secure();
      _channelSharedKey = Uint8List.fromList(
        List.generate(32, (_) => random.nextInt(256))
      );
      
      // Store generation timestamp for race condition resolution
      _keyTimestamp = DateTime.now().millisecondsSinceEpoch;
      print('[VideoConf] Generated key with timestamp: $_keyTimestamp');
      
      // Create BaseKeyProvider with the compiled e2ee.worker.dart.js
      try {
        _keyProvider = await BaseKeyProvider.create();
        
        // Set the shared key in KeyProvider
        final keyBase64 = base64Encode(_channelSharedKey!);
        await _keyProvider!.setKey(keyBase64);
        
        print('[VideoConf] ✓ BaseKeyProvider created with e2ee.worker.dart.js');
        print('[VideoConf] ✓ Shared encryption key set (32 bytes AES-256)');
      } catch (e) {
        print('[VideoConf] ⚠️ Failed to create BaseKeyProvider: $e');
        print('[VideoConf] ⚠️ Falling back to transport encryption only');
        _keyProvider = null;
      }
      
      print('[VideoConf] ✓ E2EE initialized with shared channel key (timestamp: $_keyTimestamp)');
    } catch (e) {
      print('[VideoConf] E2EE initialization error: $e');
      rethrow;
    }
  }
```

**Ziel:** Timestamp-basierte Race Condition Lösung implementiert

---

## **PHASE 4: KEY ROTATION BEI PARTICIPANT LEAVE**

### Schritt 4.1: Track First Participant

**Datei:** `client/lib/services/video_conference_service.dart`

**Add field:**

```dart
  String? _firstParticipantId;  // Track who generated the original key
```

**Update `_setupRoomListeners` method:**

```dart
  void _setupRoomListeners() {
    if (_room == null) return;

    // Listen for participant joined
    _room!.addListener(() {
      // Existing code...
      
      // Track first participant (oldest by joinedAt)
      if (_firstParticipantId == null && _remoteParticipants.isNotEmpty) {
        final sortedParticipants = _remoteParticipants.values.toList()
          ..sort((a, b) => a.joinedAt.compareTo(b.joinedAt));
        _firstParticipantId = sortedParticipants.first.identity;
        print('[VideoConf] First participant identified: $_firstParticipantId');
      }
    });

    // Listen for participant left
    _room!.addListener(() {
      // Check if first participant left
      if (_firstParticipantId != null && 
          !_remoteParticipants.containsKey(_firstParticipantId)) {
        print('[VideoConf] ⚠️ First participant ($_firstParticipantId) left the call');
        
        if (_remoteParticipants.isEmpty) {
          // All participants left - prepare for new session
          print('[VideoConf] All participants left - key will be regenerated for next session');
          _handleAllParticipantsLeft();
        } else {
          // Second participant becomes key distributor
          final sortedParticipants = _remoteParticipants.values.toList()
            ..sort((a, b) => a.joinedAt.compareTo(b.joinedAt));
          _firstParticipantId = sortedParticipants.first.identity;
          print('[VideoConf] New key distributor: $_firstParticipantId');
          // Keep the same key - just new distributor
        }
      }
    });
  }
```

**Add method:**

```dart
  /// Handle scenario when all participants leave
  /// Clears E2EE key so next session generates new one
  void _handleAllParticipantsLeft() {
    print('[VideoConf] Clearing E2EE key for new session (Forward Secrecy)');
    
    // Clear key data
    _channelSharedKey = null;
    _keyTimestamp = null;
    _firstParticipantId = null;
    
    // KeyProvider stays active but will get new key on next session
    // Don't dispose _keyProvider - we might reconnect
    
    print('[VideoConf] ✓ Ready for new session with fresh key');
  }
```

**Ziel:** Key Rotation - Neuer Key pro Session

---

### Schritt 4.2: Client Leave Event

**Datei:** `client/lib/services/video_conference_service.dart`

**Update `leaveRoom` method:**

```dart
  Future<void> leaveRoom() async {
    if (!_isConnected && !_isConnecting) {
      print('[VideoConf] Not connected to any room');
      return;
    }

    try {
      print('[VideoConf] Leaving room...');

      // Notify server we're leaving
      if (_currentChannelId != null) {
        SocketService().emit('video:leave-channel', {
          'channelId': _currentChannelId,
        });
      }

      // Dispose room and tracks
      await _room?.disconnect();
      await _room?.dispose();
      
      // Don't dispose KeyProvider yet - might reconnect
      // Just clear room reference
      if (_room != null) {
        _room?.removeListener(_updateRoomState);
        _room = null;
      }

      _participantKeys.clear();
      
      // Keep _channelSharedKey for potential reconnect
      // Only clear on handleAllParticipantsLeft()

      _isConnected = false;
      _isConnecting = false;
      _currentChannelId = null;
      _currentRoomName = null;
      _remoteParticipants.clear();

      notifyListeners();
      print('[VideoConf] Left room successfully');
    } catch (e) {
      print('[VideoConf] Error leaving room: $e');
    }
  }
```

**Ziel:** Proper cleanup mit Server notification

---

## **PHASE 5: TESTING & VALIDATION**

### Test Scenario 1: Single User (First Participant)

**Steps:**
1. User A öffnet PreJoin screen
2. Server meldet: `isFirstParticipant: true`
3. PreJoin screen zeigt: "You are the first participant"
4. User A klickt "Join Call"
5. `_initializeE2EE()` generiert Key mit timestamp
6. Video call startet

**Expected Result:**
- ✅ No key exchange needed
- ✅ Key generated locally with current timestamp
- ✅ BaseKeyProvider initialized
- ✅ Video frames encrypted

---

### Test Scenario 2: Two Users (Key Exchange)

**Steps:**
1. User A joined (first)
2. User B öffnet PreJoin screen
3. Server meldet: `isFirstParticipant: false, participantCount: 1`
4. PreJoin screen startet Key Exchange
5. User B sendet `video_e2ee_key_request` via Signal Protocol
6. User A empfängt Request → sendet `video_e2ee_key_response` mit key + timestamp
7. User B empfängt Key → setzt in KeyProvider
8. PreJoin screen zeigt: "End-to-end encryption ready"
9. User B klickt "Join Call"

**Expected Result:**
- ✅ User B receives same key as User A
- ✅ Both have identical timestamp
- ✅ Both can decrypt each other's video frames

---

### Test Scenario 3: Race Condition (3 Simultaneous Joins)

**Steps:**
1. User A, B, C öffnen PreJoin gleichzeitig
2. Alle sehen: `isFirstParticipant: false` (race condition!)
3. Alle generieren eigene Keys mit timestamps:
   - User A: timestamp 1000 (ältester)
   - User B: timestamp 1005
   - User C: timestamp 1010 (neuester)
4. Alle senden `video_e2ee_key_request`
5. Alle empfangen 3 different keys mit verschiedenen timestamps
6. Race Condition Logic:
   - Alle vergleichen timestamps
   - Alle übernehmen Key mit timestamp 1000 (User A's key)
   - Verwerfen eigene Keys (neuere timestamps)

**Expected Result:**
- ✅ All users end up with User A's key (oldest timestamp)
- ✅ All have timestamp 1000
- ✅ All can decrypt frames

---

### Test Scenario 4: Key Rotation (First Participant Leaves)

**Steps:**
1. User A (first, timestamp 1000), User B joined
2. User A leaves call
3. User C öffnet PreJoin
4. User C sendet `video_e2ee_key_request`
5. User B (now key distributor) sendet response mit originalem Key (timestamp 1000)
6. User C empfängt Key

**Expected Result:**
- ✅ User B can still distribute key (not regenerated)
- ✅ User C receives same key with original timestamp 1000
- ✅ Key continuity maintained

---

### Test Scenario 5: New Session (All Left)

**Steps:**
1. User A, B, C in call mit Key (timestamp 1000)
2. Alle verlassen call
3. Server: `activeVideoParticipants` für Channel wird leer
4. User D öffnet PreJoin (später)
5. Server meldet: `isFirstParticipant: true`
6. User D generiert NEUEN Key mit timestamp 2000

**Expected Result:**
- ✅ New session starts with fresh key
- ✅ Old key (timestamp 1000) not reused
- ✅ Forward Secrecy maintained

---

### Test Scenario 6: Reconnection

**Steps:**
1. User A, B in call
2. User A loses network → disconnect
3. User A reconnects → öffnet PreJoin
4. Server meldet: `isFirstParticipant: false`
5. User A fordert Key neu an
6. User B sendet Key (original timestamp)

**Expected Result:**
- ✅ User A receives same key again
- ✅ Can rejoin with existing encryption
- ✅ No key mismatch

---

## 📊 ZUSAMMENFASSUNG

### Implementierungs-Status

| Phase | Komponente | Dateien | Status |
|-------|-----------|---------|---------|
| 0.5 | Signal Protocol für WebRTC | `video_conference_service.dart` | ⏳ Todo |
| 1.1 | Server RAM Storage | `server.js` | ⏳ Todo |
| 1.2 | Socket.IO Events | `server.js` | ⏳ Todo |
| 1.3 | Disconnect Cleanup | `server.js` | ⏳ Todo |
| 2.1 | PreJoin View | `video_conference_prejoin_view.dart` (NEU) | ⏳ Todo |
| 2.2 | VideoConferenceView Update | `video_conference_view.dart` | ⏳ Todo |
| 2.3 | Navigation Flow | `channel_view.dart` | ⏳ Todo |
| 3.1 | Message Types | `message_listener_service.dart` | ⏳ Todo |
| 3.2 | Process Video Key | `message_listener_service.dart` | ⏳ Todo |
| 3.3 | Key Exchange + Timestamp | `video_conference_service.dart` | ⏳ Todo |
| 4.1 | First Participant Tracking | `video_conference_service.dart` | ⏳ Todo |
| 4.2 | Leave Event | `video_conference_service.dart` | ⏳ Todo |
| 5 | Testing | Alle Test Scenarios | ⏳ Todo |

---

### Security Features

✅ **Zwei separate Keys** (Signal SenderKey + LiveKit E2EE Key)  
✅ **Timestamp-basierte Race Condition Lösung** (Ältester gewinnt)  
✅ **Key Rotation pro Session** (Forward Secrecy)  
✅ **Kein Join ohne Key Exchange** (PreJoin enforced)  
✅ **Keys nur im RAM** (Nie in Datenbank)  
✅ **Signal Protocol Transport** (E2EE für Key Exchange selbst)  
✅ **Automatic Cleanup** (Disconnect handling)  

---

### Encryption Layers

1. **Transport Layer**: WSS (WebSocket Secure)
2. **Key Exchange Layer**: Signal Protocol Sender Key (AES-256)
3. **WebRTC Transport**: DTLS/SRTP (Standard WebRTC)
4. **Frame Layer**: LiveKit E2EE (AES-256 per frame)

**Result:** Mehrschichtige Verschlüsselung mit End-to-End Garantie

---

## 🚀 NÄCHSTE SCHRITTE

1. **Bestätigung:** Action Plan reviewed und approved
2. **Implementierung:** Phase für Phase durcharbeiten
3. **Testing:** Alle 6 Test Scenarios durchführen
4. **Dokumentation:** User Guide für E2EE Video Calls
5. **Deployment:** Production rollout

---

**Erstellt von:** GitHub Copilot  
**Datum:** 2. November 2025  
**Version:** 1.0
