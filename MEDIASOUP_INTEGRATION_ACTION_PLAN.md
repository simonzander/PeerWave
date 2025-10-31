# MediaSoup Integration Action Plan
## Video Conferencing für WebRTC Channels

---

## 📋 Übersicht

**Ziel:** Integration von mediasoup SFU (Selective Forwarding Unit) für Multi-Party Video/Audio Conferencing in PeerWave Channels vom Typ "webrtc".

**Warum mediasoup?**
- ✅ Hochperformanter SFU für WebRTC
- ✅ Simulcast Support (multiple quality streams)
- ✅ Client-Side Bandwidth Adaptation
- ✅ Screen Sharing Support
- ✅ E2E Media Control
- ✅ Production-ready und skalierbar

**Architektur:**
```
┌─────────────┐         ┌──────────────┐         ┌─────────────┐
│   Flutter   │ WebRTC  │   Node.js    │ WebRTC  │   Flutter   │
│   Client 1  │◄───────►│   mediasoup  │◄───────►│   Client 2  │
│  (Encrypt)  │ 🔒E2EE │   SFU Server │ 🔒E2EE │  (Decrypt)  │
│             │         │   (Blind)    │         │             │
└─────────────┘         └──────────────┘         └─────────────┘
                               │
                        Socket.IO Signaling
                               │
                        ┌──────┴──────┐
                        │   Database  │
                        │  (Channel)  │
                        └─────────────┘

🔐 E2EE IMMER AKTIV - Server kann Streams NICHT entschlüsseln
```

---

## 🎯 Projektumfang

### In Scope:
- ✅ mediasoup Server in Docker Container
- ✅ Video/Audio Streaming (Multi-Party)
- ✅ Screen Sharing
- ✅ Speaker Detection
- ✅ Bandwidth Adaptation
- ✅ **E2E Encryption für Media Streams** (Insertable Streams API) - **IMMER AKTIV**
- ❌ Recording Support (NICHT möglich mit E2EE Standard)

### Out of Scope (für später):
- ❌ Recording & Playback (unmöglich mit E2EE Standard)
- ❌ AI Features (Transcription, Translation - unmöglich mit E2EE)
- ❌ Virtual Backgrounds
- ❌ Server-Side Recording (unmöglich mit E2EE)
- ❌ E2EE Toggle/Opt-out (Privacy first: Immer verschlüsselt!)

---

## 📝 TODO Liste

---

## Phase 1: Docker & mediasoup Setup

### ✅ TODO 1.1: mediasoup Dependencies installieren
**Ziel:** Node.js Server mit mediasoup-Abhängigkeiten ausstatten

**Dateien:**
- `/server/package.json`

**Änderungen:**
```json
{
  "dependencies": {
    "mediasoup": "^3.14.0",
    "mediasoup-client": "^3.7.0"  // Wird auch serverseitig für Types gebraucht
  }
}
```

**Wichtig:** mediasoup benötigt:
- Node.js >= 16
- C++ Build Tools (bereits im Dockerfile: `g++`)
- Python 3 (bereits im Dockerfile)

---

### ✅ TODO 1.2: Dockerfile für mediasoup optimieren
**Ziel:** Docker Container kann mediasoup nativ kompilieren

**Dateien:**
- `/server/Dockerfile`

**Änderungen:**
```dockerfile
FROM node:lts-alpine

# mediasoup benötigt zusätzliche Build-Tools
RUN apk add --no-cache \
    python3 \
    make \
    g++ \
    linux-headers

WORKDIR /usr/src/app

COPY package*.json ./
RUN npm ci --omit=dev && \
    npm cache clean --force

COPY . .

# mediasoup Ports exponieren
EXPOSE 3000 40000-40099/udp 40000-40099/tcp

CMD ["node", "server.js"]
```

**Port Range Erklärung:**
- `3000`: HTTP/WebSocket (Signaling)
- `40000-40099`: RTP/RTCP (Media Transport)
  - 100 Ports = ~50 simultane Verbindungen
  - Production: Mehr Ports (z.B. 40000-49999 für 5000 Verbindungen)

---

### ✅ TODO 1.3: docker-compose.yml für mediasoup anpassen
**Ziel:** Port-Mapping und Resource Limits für mediasoup

**Dateien:**
- `/docker-compose.yml`

**Änderungen:**
```yaml
services:
  peerwave-server:
    build:
      context: ./server
      dockerfile: Dockerfile
    container_name: peerwave-server
    restart: unless-stopped
    ports:
      - "3000:3000"
      # mediasoup RTP Ports (UDP + TCP)
      - "40000-40099:40000-40099/udp"
      - "40000-40099:40000-40099/tcp"
    volumes:
      - ./server/db:/usr/src/app/db
      - ./server/cert:/usr/src/app/cert:ro
    environment:
      - NODE_ENV=${NODE_ENV:-development}
      - PORT=${PORT:-3000}
      # mediasoup Config
      - MEDIASOUP_MIN_PORT=40000
      - MEDIASOUP_MAX_PORT=40099
      - MEDIASOUP_LISTEN_IP=0.0.0.0
      - MEDIASOUP_ANNOUNCED_IP=${MEDIASOUP_ANNOUNCED_IP:-127.0.0.1}
      # TURN Config (existing)
      - TURN_SECRET=${TURN_SECRET}
      - TURN_SERVER_EXTERNAL_HOST=${TURN_SERVER_EXTERNAL_HOST:-localhost}
      - TURN_SERVER_INTERNAL_HOST=${TURN_SERVER_INTERNAL_HOST:-peerwave-coturn}
      - TURN_SERVER_PORT=${TURN_SERVER_PORT:-3478}
      - TURN_SERVER_PORT_TLS=${TURN_SERVER_PORT_TLS:-5349}
      - TURN_REALM=${TURN_REALM:-peerwave.local}
      - TURN_CREDENTIAL_TTL=${TURN_CREDENTIAL_TTL:-86400}
    # Resource Limits für Video Processing
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 2G
        reservations:
          cpus: '0.5'
          memory: 512M
    networks:
      - peerwave-network
    depends_on:
      - peerwave-coturn
```

**Environment Variables Erklärung:**
- `MEDIASOUP_MIN_PORT` / `MAX_PORT`: Port-Range für RTP
- `MEDIASOUP_LISTEN_IP`: 0.0.0.0 (alle Interfaces im Container)
- `MEDIASOUP_ANNOUNCED_IP`: Öffentliche IP/Domain für Clients (wichtig!)

---

### ✅ TODO 1.4: .env Datei erweitern
**Ziel:** mediasoup Konfiguration zentral verwalten

**Dateien:**
- `/.env`

**Änderungen:**
```bash
# ... existing config ...

# ============================================================
# MediaSoup Video Conferencing
# ============================================================

# RTP Port Range (100 Ports = ~50 concurrent connections)
MEDIASOUP_MIN_PORT=40000
MEDIASOUP_MAX_PORT=40099

# Listen IP (0.0.0.0 for all interfaces in Docker)
MEDIASOUP_LISTEN_IP=0.0.0.0

# Announced IP (Public IP/Domain for clients)
# Development: localhost oder 127.0.0.1
# Production: your-domain.com oder öffentliche IP
MEDIASOUP_ANNOUNCED_IP=localhost

# Worker Settings
MEDIASOUP_NUM_WORKERS=auto  # auto = CPU cores, oder feste Zahl (z.B. 4)

# Media Codecs (comma-separated)
MEDIASOUP_VIDEO_CODECS=VP8,VP9,H264
MEDIASOUP_AUDIO_CODECS=opus

# Bandwidth Limits (in kbps)
MEDIASOUP_MAX_INCOMING_BITRATE=1500
MEDIASOUP_MAX_OUTGOING_BITRATE=1500
```

---

## Phase 2: Server-Side mediasoup Implementation

### ✅ TODO 2.1: mediasoup Config Modul erstellen
**Ziel:** Zentrale mediasoup Konfiguration mit Worker Management

**Dateien:**
- `/server/config/mediasoup.config.js` (neu)

**Struktur:**
```javascript
const os = require('os');

module.exports = {
  // Worker settings
  worker: {
    rtcMinPort: parseInt(process.env.MEDIASOUP_MIN_PORT || '40000'),
    rtcMaxPort: parseInt(process.env.MEDIASOUP_MAX_PORT || '40099'),
    logLevel: process.env.NODE_ENV === 'production' ? 'warn' : 'debug',
    logTags: [
      'info',
      'ice',
      'dtls',
      'rtp',
      'srtp',
      'rtcp'
    ]
  },

  // Router settings
  router: {
    mediaCodecs: [
      {
        kind: 'audio',
        mimeType: 'audio/opus',
        clockRate: 48000,
        channels: 2
      },
      {
        kind: 'video',
        mimeType: 'video/VP8',
        clockRate: 90000,
        parameters: {
          'x-google-start-bitrate': 1000
        }
      },
      {
        kind: 'video',
        mimeType: 'video/VP9',
        clockRate: 90000,
        parameters: {
          'profile-id': 2,
          'x-google-start-bitrate': 1000
        }
      },
      {
        kind: 'video',
        mimeType: 'video/H264',
        clockRate: 90000,
        parameters: {
          'packetization-mode': 1,
          'profile-level-id': '42e01f',
          'level-asymmetry-allowed': 1,
          'x-google-start-bitrate': 1000
        }
      }
    ]
  },

  // WebRTC Transport settings
  webRtcTransport: {
    listenIps: [
      {
        ip: process.env.MEDIASOUP_LISTEN_IP || '0.0.0.0',
        announcedIp: process.env.MEDIASOUP_ANNOUNCED_IP || '127.0.0.1'
      }
    ],
    initialAvailableOutgoingBitrate: 1000000,
    minimumAvailableOutgoingBitrate: 600000,
    maxSctpMessageSize: 262144,
    maxIncomingBitrate: parseInt(process.env.MEDIASOUP_MAX_INCOMING_BITRATE || '1500') * 1000,
  },

  // Number of workers
  numWorkers: process.env.MEDIASOUP_NUM_WORKERS === 'auto' 
    ? os.cpus().length 
    : parseInt(process.env.MEDIASOUP_NUM_WORKERS || '2')
};
```

---

### ✅ TODO 2.2: mediasoup Worker Manager erstellen
**Ziel:** Worker Pool Management für Load Balancing

**Dateien:**
- `/server/lib/mediasoup/workerManager.js` (neu)

**Funktionalität:**
```javascript
const mediasoup = require('mediasoup');
const config = require('../../config/mediasoup.config');

class WorkerManager {
  constructor() {
    this.workers = [];
    this.nextWorkerIndex = 0;
  }

  async init() {
    // Erstelle Worker Pool
    for (let i = 0; i < config.numWorkers; i++) {
      const worker = await mediasoup.createWorker({
        logLevel: config.worker.logLevel,
        logTags: config.worker.logTags,
        rtcMinPort: config.worker.rtcMinPort,
        rtcMaxPort: config.worker.rtcMaxPort
      });

      worker.on('died', () => {
        console.error(`[MediaSoup] Worker ${i} died, restarting...`);
        this.restartWorker(i);
      });

      this.workers.push(worker);
      console.log(`[MediaSoup] Worker ${i} created (PID: ${worker.pid})`);
    }
  }

  // Round-Robin Worker Selection
  getNextWorker() {
    const worker = this.workers[this.nextWorkerIndex];
    this.nextWorkerIndex = (this.nextWorkerIndex + 1) % this.workers.length;
    return worker;
  }

  async restartWorker(index) {
    // Worker neu starten bei Absturz
    // Implementation...
  }

  async close() {
    for (const worker of this.workers) {
      worker.close();
    }
  }
}

module.exports = new WorkerManager();
```

---

### ✅ TODO 2.3: Room Manager für Video Channels erstellen
**Ziel:** Room = mediasoup Router pro WebRTC Channel

**Dateien:**
- `/server/lib/mediasoup/roomManager.js` (neu)

**Konzept:**
- Jeder Channel (Typ "webrtc") = 1 mediasoup Router
- Router verwaltet alle Transports, Producers, Consumers
- Room wird beim ersten Teilnehmer erstellt

**Struktur:**
```javascript
class Room {
  constructor(channelId, router) {
    this.id = channelId;
    this.router = router;
    this.peers = new Map(); // userId -> Peer
    this.createdAt = Date.now();
  }

  addPeer(userId, socketId) {
    // Peer hinzufügen
  }

  removePeer(userId) {
    // Peer entfernen + cleanup
  }

  getPeer(userId) {
    return this.peers.get(userId);
  }

  getPeers() {
    return Array.from(this.peers.values());
  }

  async close() {
    // Alle Peers disconnecten
    // Router schließen
  }
}

class RoomManager {
  constructor() {
    this.rooms = new Map(); // channelId -> Room
  }

  async createRoom(channelId) {
    const worker = workerManager.getNextWorker();
    const router = await worker.createRouter({
      mediaCodecs: config.router.mediaCodecs
    });

    const room = new Room(channelId, router);
    this.rooms.set(channelId, room);
    
    console.log(`[MediaSoup] Room created for channel ${channelId}`);
    return room;
  }

  getRoom(channelId) {
    return this.rooms.get(channelId);
  }

  async getOrCreateRoom(channelId) {
    let room = this.getRoom(channelId);
    if (!room) {
      room = await this.createRoom(channelId);
    }
    return room;
  }

  async closeRoom(channelId) {
    const room = this.rooms.get(channelId);
    if (room) {
      await room.close();
      this.rooms.delete(channelId);
      console.log(`[MediaSoup] Room closed for channel ${channelId}`);
    }
  }
}

module.exports = new RoomManager();
```

---

### ✅ TODO 2.4: Peer Manager erstellen
**Ziel:** Peer = User in einem Room mit Transports & Producers/Consumers

**Dateien:**
- `/server/lib/mediasoup/peerManager.js` (neu)

**Struktur:**
```javascript
class Peer {
  constructor(userId, socketId, room) {
    this.id = userId;
    this.socketId = socketId;
    this.room = room;
    
    // WebRTC Transports (send = vom Client, recv = zum Client)
    this.sendTransport = null;
    this.recvTransport = null;
    
    // Media Producers (was der Peer sendet)
    this.producers = new Map(); // kind -> Producer (video/audio/screen)
    
    // Media Consumers (was der Peer empfängt von anderen)
    this.consumers = new Map(); // consumerId -> Consumer
    
    this.rtpCapabilities = null;
  }

  async createWebRtcTransport(direction) {
    // direction: 'send' oder 'recv'
    const transport = await this.room.router.createWebRtcTransport({
      ...config.webRtcTransport,
      appData: { peerId: this.id, direction }
    });

    if (direction === 'send') {
      this.sendTransport = transport;
    } else {
      this.recvTransport = transport;
    }

    return {
      id: transport.id,
      iceParameters: transport.iceParameters,
      iceCandidates: transport.iceCandidates,
      dtlsParameters: transport.dtlsParameters
    };
  }

  async produce(kind, rtpParameters, appData = {}) {
    if (!this.sendTransport) {
      throw new Error('Send transport not created');
    }

    const producer = await this.sendTransport.produce({
      kind,
      rtpParameters,
      appData: { ...appData, peerId: this.id }
    });

    this.producers.set(producer.id, producer);
    
    // Notify andere Peers über neuen Producer
    this.room.broadcastNewProducer(this.id, producer);

    return producer;
  }

  async consume(producerId, rtpCapabilities) {
    if (!this.recvTransport) {
      throw new Error('Recv transport not created');
    }

    if (!this.room.router.canConsume({
      producerId,
      rtpCapabilities
    })) {
      console.warn(`Cannot consume producer ${producerId}`);
      return null;
    }

    const consumer = await this.recvTransport.consume({
      producerId,
      rtpCapabilities,
      paused: true // Start paused, client resumed wenn bereit
    });

    this.consumers.set(consumer.id, consumer);
    
    return consumer;
  }

  async close() {
    // Close all transports & producers & consumers
    // Implementation...
  }
}
```

---

### ✅ TODO 2.5: Socket.IO Signaling Handler erstellen
**Ziel:** WebRTC Signaling über Socket.IO für mediasoup

**Dateien:**
- `/server/routes/mediasoup.signaling.js` (neu)

**Socket Events:**
```javascript
// Client → Server Events:
- 'join-room': User betritt Video Channel
- 'leave-room': User verlässt Video Channel
- 'getRtpCapabilities': Client fragt Router Capabilities ab
- 'createWebRtcTransport': Client erstellt Send/Recv Transport
- 'connectWebRtcTransport': DTLS Handshake
- 'produce': Client startet Media Stream (video/audio/screen)
- 'consume': Client möchte Stream von anderem Peer empfangen
- 'resumeConsumer': Client ist bereit für Media Empfang

// Server → Client Events:
- 'roomJoined': Bestätigung + Room Info + Existing Peers
- 'newPeer': Neuer Peer im Room
- 'peerLeft': Peer hat Room verlassen
- 'newProducer': Peer hat neuen Stream gestartet
- 'producerClosed': Peer hat Stream beendet
```

**Handler Struktur:**
```javascript
module.exports = (io, socket) => {
  // User joins video room
  socket.on('join-room', async ({ channelId, userId }) => {
    try {
      const room = await roomManager.getOrCreateRoom(channelId);
      const peer = new Peer(userId, socket.id, room);
      
      room.addPeer(userId, socket.id);
      socket.join(channelId);
      
      // Send existing peers to new peer
      const existingPeers = room.getPeers().filter(p => p.id !== userId);
      
      socket.emit('roomJoined', {
        rtpCapabilities: room.router.rtpCapabilities,
        peers: existingPeers.map(p => ({
          id: p.id,
          producers: Array.from(p.producers.keys())
        }))
      });
      
      // Notify others about new peer
      socket.to(channelId).emit('newPeer', { peerId: userId });
      
      console.log(`[MediaSoup] Peer ${userId} joined room ${channelId}`);
    } catch (error) {
      console.error('[MediaSoup] Error joining room:', error);
      socket.emit('error', { message: error.message });
    }
  });

  socket.on('leave-room', async ({ channelId, userId }) => {
    // Implementation...
  });

  socket.on('getRtpCapabilities', async ({ channelId }, callback) => {
    // Implementation...
  });

  socket.on('createWebRtcTransport', async (data, callback) => {
    // Implementation...
  });

  socket.on('connectWebRtcTransport', async (data, callback) => {
    // Implementation...
  });

  socket.on('produce', async (data, callback) => {
    // Implementation...
  });

  socket.on('consume', async (data, callback) => {
    // Implementation...
  });

  // Cleanup on disconnect
  socket.on('disconnect', async () => {
    // Find and remove peer from all rooms
    // Implementation...
  });
};
```

---

### ✅ TODO 2.6: server.js Integration
**Ziel:** mediasoup beim Server-Start initialisieren

**Dateien:**
- `/server/server.js`

**Änderungen:**
```javascript
const workerManager = require('./lib/mediasoup/workerManager');
const mediasoupSignaling = require('./routes/mediasoup.signaling');

// ... existing code ...

// Initialize mediasoup workers
(async () => {
  console.log('[MediaSoup] Initializing workers...');
  await workerManager.init();
  console.log('[MediaSoup] Workers ready');
})();

// Socket.IO setup
io.on('connection', (socket) => {
  console.log('Socket connected:', socket.id);
  
  // Existing handlers...
  
  // MediaSoup signaling
  mediasoupSignaling(io, socket);
});

// Graceful shutdown
process.on('SIGINT', async () => {
  console.log('[Server] Shutting down...');
  await workerManager.close();
  process.exit(0);
});
```

---

## Phase 3: Flutter Client - mediasoup-client Integration

### ✅ TODO 3.1: mediasoup_client Dependency hinzufügen
**Ziel:** Flutter Paket für mediasoup

**Dateien:**
- `/client/pubspec.yaml`

**Änderungen:**
```yaml
dependencies:
  flutter:
    sdk: flutter
  # ... existing dependencies ...
  
  # MediaSoup WebRTC
  mediasoup_client_flutter: ^0.8.0
  # oder: mediasoup_client: ^x.x.x (je nach verfügbarer Version)
```

**Alternative:** Falls kein Flutter-Package verfügbar:
- `flutter_webrtc` (bereits vorhanden) + mediasoup-client JS via Web
- Eigene Native Bridge bauen

---

### ✅ TODO 3.2: MediaSoup Service erstellen
**Ziel:** Flutter Service für mediasoup Client Operations

**Dateien:**
- `/client/lib/services/mediasoup/mediasoup_service.dart` (neu)

**Struktur:**
```dart
import 'package:mediasoup_client_flutter/mediasoup_client_flutter.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class MediaSoupService {
  Device? _device;
  Transport? _sendTransport;
  Transport? _recvTransport;
  
  Map<String, Producer> _producers = {}; // local streams
  Map<String, Consumer> _consumers = {}; // remote streams
  
  // Initialize Device with RTP Capabilities from server
  Future<void> loadDevice(Map<String, dynamic> rtpCapabilities) async {
    _device = Device();
    await _device!.load(
      routerRtpCapabilities: RtpCapabilities.fromMap(rtpCapabilities)
    );
  }
  
  // Create Send Transport (for local media)
  Future<void> createSendTransport(Map<String, dynamic> transportData) async {
    _sendTransport = _device!.createSendTransport(
      id: transportData['id'],
      iceParameters: IceParameters.fromMap(transportData['iceParameters']),
      iceCandidates: (transportData['iceCandidates'] as List)
          .map((e) => IceCandidate.fromMap(e))
          .toList(),
      dtlsParameters: DtlsParameters.fromMap(transportData['dtlsParameters'])
    );
    
    _sendTransport!.on('connect', (DtlsParameters dtlsParameters) async {
      // Send DTLS params to server
      await _socketService.emit('connectWebRtcTransport', {
        'transportId': _sendTransport!.id,
        'dtlsParameters': dtlsParameters.toMap()
      });
    });
    
    _sendTransport!.on('produce', (Producer producer) async {
      // Notify server about new producer
      final response = await _socketService.emitWithAck('produce', {
        'transportId': _sendTransport!.id,
        'kind': producer.kind,
        'rtpParameters': producer.rtpParameters.toMap()
      });
      return response['id'];
    });
  }
  
  // Create Recv Transport (for remote media)
  Future<void> createRecvTransport(Map<String, dynamic> transportData) async {
    // Similar to send transport
  }
  
  // Produce local media (camera/microphone/screen)
  Future<Producer> produceMedia({
    required MediaStreamTrack track,
    required String kind, // 'video' or 'audio'
    Map<String, dynamic>? appData
  }) async {
    if (_sendTransport == null) {
      throw Exception('Send transport not created');
    }
    
    final producer = await _sendTransport!.produce(
      track: track,
      codecOptions: kind == 'video' 
        ? ProducerCodecOptions(
            videoGoogleStartBitrate: 1000
          )
        : null,
      appData: appData
    );
    
    _producers[producer.id] = producer;
    return producer;
  }
  
  // Consume remote media
  Future<Consumer> consumeMedia({
    required String producerId,
    required String peerId,
    required String kind
  }) async {
    if (_recvTransport == null) {
      throw Exception('Recv transport not created');
    }
    
    final response = await _socketService.emitWithAck('consume', {
      'producerId': producerId,
      'rtpCapabilities': _device!.rtpCapabilities.toMap()
    });
    
    final consumer = await _recvTransport!.consume(
      id: response['id'],
      producerId: producerId,
      kind: kind,
      rtpParameters: RtpParameters.fromMap(response['rtpParameters'])
    );
    
    _consumers[consumer.id] = consumer;
    
    // Resume consumer
    await _socketService.emit('resumeConsumer', {
      'consumerId': consumer.id
    });
    
    return consumer;
  }
  
  // Close all connections
  Future<void> close() async {
    for (final producer in _producers.values) {
      producer.close();
    }
    for (final consumer in _consumers.values) {
      consumer.close();
    }
    _sendTransport?.close();
    _recvTransport?.close();
  }
}
```

---

### ✅ TODO 3.3: Video Room Provider erstellen
**Ziel:** State Management für Video Conference

**Dateien:**
- `/client/lib/providers/video_room_provider.dart` (neu)

**Struktur:**
```dart
class VideoRoomProvider extends ChangeNotifier {
  final MediaSoupService _mediaSoup;
  final SocketService _socket;
  
  String? _currentRoomId;
  Map<String, Peer> _peers = {}; // peerId -> Peer
  
  // Local media streams
  MediaStream? _localVideoStream;
  MediaStream? _localAudioStream;
  MediaStream? _screenShareStream;
  
  // States
  bool _isJoined = false;
  bool _isCameraOn = false;
  bool _isMicOn = false;
  bool _isScreenSharing = false;
  
  Future<void> joinRoom(String channelId) async {
    try {
      // Request to join
      _socket.emit('join-room', {
        'channelId': channelId,
        'userId': _currentUserId
      });
      
      // Listen for room joined
      _socket.on('roomJoined', (data) async {
        await _mediaSoup.loadDevice(data['rtpCapabilities']);
        
        // Create transports
        final sendTransportData = await _socket.emitWithAck(
          'createWebRtcTransport',
          {'direction': 'send'}
        );
        await _mediaSoup.createSendTransport(sendTransportData);
        
        final recvTransportData = await _socket.emitWithAck(
          'createWebRtcTransport',
          {'direction': 'recv'}
        );
        await _mediaSoup.createRecvTransport(recvTransportData);
        
        // Add existing peers
        for (final peer in data['peers']) {
          _addPeer(peer['id'], peer['producers']);
        }
        
        _isJoined = true;
        _currentRoomId = channelId;
        notifyListeners();
      });
      
      // Listen for new peers
      _socket.on('newPeer', (data) {
        _addPeer(data['peerId'], []);
      });
      
      // Listen for new producers
      _socket.on('newProducer', (data) async {
        await _consumeNewProducer(
          data['peerId'],
          data['producerId'],
          data['kind']
        );
      });
      
    } catch (e) {
      print('[VideoRoom] Error joining room: $e');
    }
  }
  
  Future<void> startCamera() async {
    final stream = await navigator.mediaDevices.getUserMedia({
      'video': {
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
        'frameRate': {'ideal': 30}
      }
    });
    
    _localVideoStream = stream;
    final track = stream.getVideoTracks()[0];
    
    await _mediaSoup.produceMedia(
      track: track,
      kind: 'video',
      appData: {'type': 'camera'}
    );
    
    _isCameraOn = true;
    notifyListeners();
  }
  
  Future<void> startMicrophone() async {
    // Similar to camera
  }
  
  Future<void> startScreenShare() async {
    // Similar but with getDisplayMedia
  }
  
  void leaveRoom() {
    _socket.emit('leave-room', {
      'channelId': _currentRoomId,
      'userId': _currentUserId
    });
    
    _mediaSoup.close();
    _cleanup();
  }
}
```

---

### ✅ TODO 3.4: Video Conference Screen UI erstellen
**Ziel:** UI für Multi-Party Video Conference

**Dateien:**
- `/client/lib/screens/video/video_conference_screen.dart` (neu)

**UI Components:**
```dart
class VideoConferenceScreen extends StatelessWidget {
  final String channelId;
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Video Grid (alle Teilnehmer)
          VideoGrid(),
          
          // Local Video (klein, oben rechts)
          Positioned(
            top: 20,
            right: 20,
            child: LocalVideoView()
          ),
          
          // Controls (unten)
          Positioned(
            bottom: 20,
            left: 0,
            right: 0,
            child: VideoControls()
          ),
          
          // Participant List (links, ausklappbar)
          ParticipantList(),
          
          // Chat (rechts, ausklappbar)
          ChatSidebar()
        ],
      ),
    );
  }
}

class VideoGrid extends StatelessWidget {
  // Grid Layout für alle Remote Streams
  // 1 Person: Full Screen
  // 2 Personen: Side by Side
  // 3-4 Personen: 2x2 Grid
  // 5-9 Personen: 3x3 Grid
  // etc.
}

class VideoControls extends StatelessWidget {
  // Buttons:
  // - Mute/Unmute Microphone
  // - Turn Camera On/Off
  // - Start/Stop Screen Sharing
  // - Leave Call
  // - Settings (Resolution, Bandwidth)
}
```

---

## Phase 4: Channel Integration

### ✅ TODO 4.1: Channel Model erweitern
**Ziel:** WebRTC Channels können Video Conference starten

**Dateien:**
- `/server/db/model.js`
- Existing Channel model

**Prüfen:** Channel hat bereits `type` Feld
- `type: 'webrtc'` → für Video Channels
- `type: 'signal'` → für End-to-End Encrypted Chat

**Evtl. erweitern:**
```javascript
// Channel Settings für Video Conference
videoSettings: {
  maxParticipants: 10,
  allowScreenShare: true,
  recordingEnabled: false,
  defaultVideoQuality: '720p' // 360p, 720p, 1080p
}
```

---

### ✅ TODO 4.2: Channel UI für Video Button erweitern
**Ziel:** "Join Video Call" Button in WebRTC Channels

**Dateien:**
- `/client/lib/screens/channel/channel_screen.dart` (oder ähnlich)

**UI Änderungen:**
```dart
// In Channel Header/Toolbar:
if (channel.type == 'webrtc') {
  IconButton(
    icon: Icon(Icons.videocam),
    tooltip: 'Join Video Call',
    onPressed: () {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => VideoConferenceScreen(
            channelId: channel.id
          )
        )
      );
    }
  )
}
```

---

### ✅ TODO 4.3: Room Presence Management
**Ziel:** Zeige wer gerade im Video Call ist

**Features:**
- Badge mit Anzahl aktiver Teilnehmer
- Liste der aktuellen Teilnehmer
- "Join" Notification wenn jemand beitritt

**Implementation:**
- Server tracked aktive Peers pro Room
- Emit `room-participants-changed` Event
- Client zeigt Badge/Liste

---

## Phase 5: Advanced Features

### ✅ TODO 5.1: E2E Encryption für Media Streams (Insertable Streams)
**Ziel:** End-to-End verschlüsselte Video/Audio Streams mit WebRTC Insertable Streams API

**⚠️ Wichtig:** 
- mediasoup SFU kann verschlüsselte Frames NICHT entschlüsseln (Server ist blind)
- Verwendet **Insertable Streams API** (Chrome/Edge) oder **Encoded Transform API** (Safari)
- Basiert auf bestehender Signal Protocol Infrastruktur aus PeerWave

**Architektur:**
```
┌────────────┐   Encrypted    ┌──────────┐   Encrypted    ┌────────────┐
│  Client A  │──────RTP───────►│mediasoup │──────RTP───────►│  Client B  │
│ (Encrypt)  │                 │   SFU    │                 │ (Decrypt)  │
└────────────┘                 │ (Blind)  │                 └────────────┘
     │                         └──────────┘                      │
     │                                                           │
     └──────────── Signal Protocol Key Exchange ────────────────┘
                  (via existing Signal infrastructure)
```

---

#### TODO 5.1.1: Crypto Worker für Frame En/Decryption
**Ziel:** Dedicated Web Worker für Video/Audio Frame Verschlüsselung

**Dateien:**
- `/client/web/workers/media_crypto_worker.js` (neu)

**Implementation:**
```javascript
// media_crypto_worker.js
// Läuft in separatem Thread für Performance

let cryptoKey = null;
let frameCounter = 0;

// Import WebCrypto API
self.importScripts('https://cdn.jsdelivr.net/npm/@noble/ciphers/+esm');

// Initialize encryption key (from Signal Protocol)
self.addEventListener('message', async (event) => {
  const { type, data } = event.data;
  
  switch (type) {
    case 'init':
      await initializeCrypto(data.key, data.salt);
      self.postMessage({ type: 'ready' });
      break;
      
    case 'encrypt':
      const encryptedFrame = await encryptFrame(data.frame, data.metadata);
      self.postMessage({ 
        type: 'encrypted', 
        frame: encryptedFrame,
        frameId: data.frameId 
      });
      break;
      
    case 'decrypt':
      const decryptedFrame = await decryptFrame(data.frame, data.metadata);
      self.postMessage({ 
        type: 'decrypted', 
        frame: decryptedFrame,
        frameId: data.frameId 
      });
      break;
      
    case 'rotate-key':
      await rotateKey(data.newKey, data.salt);
      self.postMessage({ type: 'key-rotated' });
      break;
  }
});

async function initializeCrypto(keyMaterial, salt) {
  // Derive AES-GCM key from Signal Protocol session key
  const keyData = new TextEncoder().encode(keyMaterial);
  const baseKey = await crypto.subtle.importKey(
    'raw',
    keyData,
    'PBKDF2',
    false,
    ['deriveKey']
  );
  
  cryptoKey = await crypto.subtle.deriveKey(
    {
      name: 'PBKDF2',
      salt: new TextEncoder().encode(salt),
      iterations: 100000,
      hash: 'SHA-256'
    },
    baseKey,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt']
  );
}

async function encryptFrame(frameData, metadata) {
  frameCounter++;
  
  // IV = timestamp + frameCounter (12 bytes)
  const iv = new Uint8Array(12);
  const timestamp = BigInt(Date.now());
  const dataView = new DataView(iv.buffer);
  dataView.setBigUint64(0, timestamp, false);
  dataView.setUint32(8, frameCounter, false);
  
  // Encrypt frame payload with AES-GCM
  const encrypted = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv },
    cryptoKey,
    frameData
  );
  
  // Prepend IV to encrypted data
  const result = new Uint8Array(iv.length + encrypted.byteLength);
  result.set(iv, 0);
  result.set(new Uint8Array(encrypted), iv.length);
  
  return result;
}

async function decryptFrame(encryptedData, metadata) {
  // Extract IV (first 12 bytes)
  const iv = encryptedData.slice(0, 12);
  const ciphertext = encryptedData.slice(12);
  
  try {
    const decrypted = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv },
      cryptoKey,
      ciphertext
    );
    
    return new Uint8Array(decrypted);
  } catch (error) {
    console.error('[Crypto Worker] Decryption failed:', error);
    // Return zeroed frame on error (black screen/silence)
    return new Uint8Array(ciphertext.length);
  }
}

async function rotateKey(newKeyMaterial, salt) {
  // Key rotation für Forward Secrecy
  await initializeCrypto(newKeyMaterial, salt);
  frameCounter = 0;
}
```

---

#### TODO 5.1.2: Insertable Streams Transform
**Ziel:** WebRTC Insertable Streams Integration für Frame Interception

**Dateien:**
- `/client/lib/services/mediasoup/media_encryption_service.dart` (neu)

**Web Implementation (Flutter Web):**
```dart
@JS()
library media_encryption;

import 'package:js/js.dart';
import 'dart:html' as html;

class MediaEncryptionService {
  html.Worker? _cryptoWorker;
  bool _isInitialized = false;
  String? _currentSessionKey;
  
  // Initialize crypto worker
  Future<void> initialize(String sessionKey, String salt) async {
    _cryptoWorker = html.Worker('workers/media_crypto_worker.js');
    
    // Send init message
    _cryptoWorker!.postMessage({
      'type': 'init',
      'data': {
        'key': sessionKey,
        'salt': salt
      }
    });
    
    // Wait for ready
    final completer = Completer<void>();
    _cryptoWorker!.onMessage.listen((event) {
      if (event.data['type'] == 'ready') {
        _isInitialized = true;
        completer.complete();
      }
    });
    
    await completer.future;
    _currentSessionKey = sessionKey;
  }
  
  // Apply encryption transform to producer
  Future<void> encryptProducer(Producer producer) async {
    if (!_isInitialized) {
      throw Exception('Encryption not initialized');
    }
    
    // Get RTCRtpSender from producer
    final sender = _getProducerSender(producer);
    
    // Create TransformStream with crypto worker
    final transformStream = html.TransformStream(
      transformer: _createEncryptTransformer()
    );
    
    // Apply transform to encoded frames
    // RTCRtpSender.createEncodedStreams() for Insertable Streams
    _applyInsertableStreams(sender, transformStream, 'encrypt');
  }
  
  // Apply decryption transform to consumer
  Future<void> decryptConsumer(Consumer consumer) async {
    if (!_isInitialized) {
      throw Exception('Encryption not initialized');
    }
    
    // Get RTCRtpReceiver from consumer
    final receiver = _getConsumerReceiver(consumer);
    
    // Create TransformStream with crypto worker
    final transformStream = html.TransformStream(
      transformer: _createDecryptTransformer()
    );
    
    // Apply transform to encoded frames
    _applyInsertableStreams(receiver, transformStream, 'decrypt');
  }
  
  // Create encryption transformer
  dynamic _createEncryptTransformer() {
    return html.Transformer(
      transform: (chunk, controller) async {
        // chunk = RTCEncodedVideoFrame or RTCEncodedAudioFrame
        final frameData = chunk.data;
        final metadata = {
          'timestamp': chunk.timestamp,
          'type': chunk.type,
          'frameId': chunk.timestamp
        };
        
        // Send to worker for encryption
        final completer = Completer<Uint8List>();
        
        _cryptoWorker!.onMessage.listen((event) {
          if (event.data['type'] == 'encrypted' && 
              event.data['frameId'] == metadata['frameId']) {
            completer.complete(event.data['frame']);
          }
        });
        
        _cryptoWorker!.postMessage({
          'type': 'encrypt',
          'data': {
            'frame': frameData,
            'metadata': metadata,
            'frameId': metadata['frameId']
          }
        });
        
        final encryptedData = await completer.future;
        
        // Replace frame data with encrypted version
        chunk.data = encryptedData;
        controller.enqueue(chunk);
      }
    );
  }
  
  // Create decryption transformer (similar structure)
  dynamic _createDecryptTransformer() {
    // Similar to _createEncryptTransformer but calls 'decrypt'
    // ...
  }
  
  // Rotate encryption key (Forward Secrecy)
  Future<void> rotateKey(String newSessionKey, String salt) async {
    _cryptoWorker!.postMessage({
      'type': 'rotate-key',
      'data': {
        'newKey': newSessionKey,
        'salt': salt
      }
    });
    
    // Wait for confirmation
    await _waitForWorkerResponse('key-rotated');
    _currentSessionKey = newSessionKey;
  }
  
  void dispose() {
    _cryptoWorker?.terminate();
    _isInitialized = false;
  }
}
```

**Native Bridge für Mobile (iOS/Android):**
```dart
// Alternative für native Plattformen (komplex)
// Verwendet Platform Channels + native Crypto APIs
// iOS: Security.framework, Android: javax.crypto
```

---

#### TODO 5.1.3: Signal Protocol Integration für Key Exchange
**Ziel:** Verwende bestehende Signal Sessions für Media Key Exchange

**Dateien:**
- `/client/lib/services/mediasoup/media_key_exchange.dart` (neu)

**Konzept:**
```dart
class MediaKeyExchange {
  final SignalProtocolService _signal;
  
  // Derive media encryption key from Signal session
  Future<MediaSessionKey> deriveMediaKey(String peerId) async {
    // Get Signal Protocol session with peer
    final session = await _signal.getSession(peerId);
    
    if (session == null) {
      throw Exception('No Signal session with peer $peerId');
    }
    
    // Derive media key using HKDF
    // Input: Signal session key
    // Output: Separate key for media encryption
    final mediaKey = await _deriveKeyWithHKDF(
      sessionKey: session.currentSendingChainKey,
      salt: 'PeerWave-Media-Encryption-v1',
      info: 'media-aes-gcm-key'
    );
    
    return MediaSessionKey(
      peerId: peerId,
      key: mediaKey,
      createdAt: DateTime.now(),
      expiresAt: DateTime.now().add(Duration(hours: 24))
    );
  }
  
  // Key rotation every 1 hour for Forward Secrecy
  Future<void> rotateMediaKeys(List<String> peerIds) async {
    for (final peerId in peerIds) {
      try {
        // Ratchet Signal session forward
        await _signal.ratchetSession(peerId);
        
        // Derive new media key
        final newKey = await deriveMediaKey(peerId);
        
        // Update encryption service
        await _encryptionService.rotateKey(
          newKey.key,
          'rotation-${DateTime.now().millisecondsSinceEpoch}'
        );
        
        print('[Media E2EE] Key rotated for peer $peerId');
      } catch (e) {
        print('[Media E2EE] Key rotation failed for $peerId: $e');
      }
    }
  }
  
  Future<String> _deriveKeyWithHKDF({
    required Uint8List sessionKey,
    required String salt,
    required String info
  }) async {
    // HKDF (HMAC-based Key Derivation Function)
    // RFC 5869 implementation
    // ...
  }
}

class MediaSessionKey {
  final String peerId;
  final String key;
  final DateTime createdAt;
  final DateTime expiresAt;
  
  MediaSessionKey({
    required this.peerId,
    required this.key,
    required this.createdAt,
    required this.expiresAt
  });
  
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}
```

---

#### TODO 5.1.4: MediaSoup Service E2EE Integration
**Ziel:** Automatisches En/Decryption für alle Producers/Consumers - **IMMER AKTIV**

**Dateien:**
- `/client/lib/services/mediasoup/mediasoup_service.dart` (erweitern)

**Änderungen:**
```dart
class MediaSoupService {
  final MediaEncryptionService _encryption;
  final MediaKeyExchange _keyExchange;
  
  // E2EE ist IMMER aktiv - kein Toggle!
  bool get isE2EEEnabled => true;  // 🔒 Konstante
  
  // ... existing code ...
  
  // ALLE Producers werden automatisch verschlüsselt
  Future<Producer> produceMedia({
    required MediaStreamTrack track,
    required String kind,
    Map<String, dynamic>? appData
  }) async {
    if (_sendTransport == null) {
      throw new Exception('Send transport not created');
    }
    
    final producer = await _sendTransport!.produce(
      track: track,
      codecOptions: kind == 'video' 
        ? ProducerCodecOptions(videoGoogleStartBitrate: 1000)
        : null,
      appData: appData
    );
    
    // 🔒 IMMER verschlüsseln (kein if-check!)
    await _encryption.encryptProducer(producer);
    
    _producers[producer.id] = producer;
    
    print('[MediaSoup E2EE] Producer ${producer.id} encrypted (always-on)');
    return producer;
  }
  
  // ALLE Consumers werden automatisch entschlüsselt
  Future<Consumer> consumeMedia({
    required String producerId,
    required String peerId,
    required String kind
  }) async {
    if (_recvTransport == null) {
      throw Exception('Recv transport not created');
    }
    
    // Get or establish media encryption key with peer
    final mediaKey = await _keyExchange.deriveMediaKey(peerId);
    await _encryption.initialize(mediaKey.key, 'consumer-$peerId');
    
    final response = await _socketService.emitWithAck('consume', {
      'producerId': producerId,
      'rtpCapabilities': _device!.rtpCapabilities.toMap()
    });
    
    final consumer = await _recvTransport!.consume(
      id: response['id'],
      producerId: producerId,
      kind: kind,
      rtpParameters: RtpParameters.fromMap(response['rtpParameters'])
    );
    
    // 🔓 IMMER entschlüsseln (kein if-check!)
    await _encryption.decryptConsumer(consumer);
    
    _consumers[consumer.id] = consumer;
    
    // Resume consumer
    await _socketService.emit('resumeConsumer', {
      'consumerId': consumer.id
    });
    
    print('[MediaSoup E2EE] Consumer ${consumer.id} decryption active (always-on)');
    return consumer;
  }
  
  // Key rotation timer (PFLICHT für Security)
  Timer? _keyRotationTimer;
  
  void startKeyRotation() {
    // Rotate keys every 1 hour (IMMER aktiv)
    _keyRotationTimer = Timer.periodic(
      Duration(hours: 1),
      (_) async {
        final peerIds = _consumers.values
          .map((c) => c.appData['peerId'] as String)
          .toSet()
          .toList();
        
        print('[E2EE] Starting mandatory key rotation for ${peerIds.length} peers');
        await _keyExchange.rotateMediaKeys(peerIds);
      }
    );
    
    print('[E2EE] Automatic key rotation enabled (every 1 hour)');
  }
  
  @override
  Future<void> close() async {
    _keyRotationTimer?.cancel();
    _encryption.dispose();
    // ... rest of cleanup ...
  }
}
```

**Wichtig:** 
- ❌ Kein `if (e2eeEnabled)` Check!
- ✅ Encryption läuft IMMER
- ✅ Key Rotation IMMER aktiv
- 🔒 Privacy by Default

---

#### TODO 5.1.5: Server-Side: E2EE Mandatory Flag
**Ziel:** Server signalisiert, dass E2EE PFLICHT ist (kein Opt-out möglich)

**Dateien:**
- `/server/lib/mediasoup/roomManager.js` (erweitern)

**Änderungen:**
```javascript
class Room {
  constructor(channelId, router) {
    this.id = channelId;
    this.router = router;
    this.peers = new Map();
    this.e2eeEnabled = true;  // 🔒 IMMER true (keine Option)
    this.e2eeMandatory = true; // 🔒 PFLICHT-Flag
    this.createdAt = Date.now();
  }
  
  // ... existing code ...
  
  async createPeer(userId, socketId, capabilities) {
    const peer = new Peer(userId, socketId, this);
    
    // E2EE ist PFLICHT - Client muss unterstützen!
    if (!capabilities.e2eeSupported) {
      throw new Error(
        'E2EE is mandatory for video calls. ' +
        'Please use a supported browser (Chrome, Edge, Safari 15.4+)'
      );
    }
    
    peer.e2eeEnabled = true; // Immer true
    
    this.peers.set(userId, peer);
    return peer;
  }
  
  // Notify peers about E2EE status
  getPeerInfo(peer) {
    return {
      id: peer.id,
      producers: Array.from(peer.producers.keys()),
      e2eeEnabled: true, // 🔒 Immer true
      e2eeMandatory: true, // 🔒 Info für Client
      joinedAt: peer.joinedAt
    };
  }
}
```

**Socket.IO Event Updates:**
```javascript
socket.on('join-room', async ({ channelId, userId, e2eeSupported }) => {
  try {
    const room = await roomManager.getOrCreateRoom(channelId);
    
    // Prüfe Browser Support für E2EE
    if (!e2eeSupported) {
      return socket.emit('error', {
        code: 'E2EE_NOT_SUPPORTED',
        message: 'Your browser does not support end-to-end encryption. ' +
                 'Please use Chrome 86+, Edge 86+, or Safari 15.4+',
        severity: 'critical'
      });
    }
    
    const peer = await room.createPeer(userId, socket.id, {
      e2eeSupported: true
    });
    
    socket.emit('roomJoined', {
      rtpCapabilities: room.router.rtpCapabilities,
      e2eeEnabled: true, // 🔒 Immer true
      e2eeMandatory: true, // 🔒 Client MUSS E2EE nutzen
      peers: room.getPeers()
        .filter(p => p.id !== userId)
        .map(p => room.getPeerInfo(p))
    });
    
    console.log(`[MediaSoup] Peer ${userId} joined E2EE-only room ${channelId}`);
    
    // ...
  } catch (error) {
    console.error('[MediaSoup] Error joining room:', error);
    socket.emit('error', { 
      message: error.message,
      code: 'JOIN_FAILED'
    });
  }
});
```

**Wichtig:** Server akzeptiert KEINE unverschlüsselten Verbindungen!
- ✅ Browser-Check vor Join
- ✅ Clear Error Messages
- ❌ Kein Fallback auf unencrypted

---

#### TODO 5.1.6: UI Indicators für E2EE Status
**Ziel:** Zeige dass E2EE IMMER aktiv ist (kein Toggle, nur Info)

**Dateien:**
- `/client/lib/screens/video/video_conference_screen.dart` (erweitern)

**UI Änderungen:**
```dart
// In Video Tile für jeden Participant:
Widget buildVideoTile(Peer peer) {
  return Stack(
    children: [
      // Video Stream
      RTCVideoView(peer.videoRenderer),
      
      // 🔒 E2EE Indicator (top-left) - IMMER angezeigt
      Positioned(
        top: 8,
        left: 8,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.green.withOpacity(0.9),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white, width: 1)
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock, size: 14, color: Colors.white),
              SizedBox(width: 4),
              Text(
                'E2E Encrypted',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  shadows: [
                    Shadow(blurRadius: 2, color: Colors.black45)
                  ]
                )
              )
            ],
          ),
        )
      ),
      
      // Name Label (bottom)
      Positioned(
        bottom: 8,
        left: 8,
        right: 8,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8)
          ),
          child: Text(
            peer.name,
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w500
            )
          )
        )
      )
    ],
  );
}

// Info Banner beim Join (einmalig)
Widget buildE2EEWelcomeBanner() {
  return Container(
    padding: EdgeInsets.all(16),
    margin: EdgeInsets.all(12),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: [Colors.green.shade700, Colors.green.shade900]
      ),
      borderRadius: BorderRadius.circular(12),
      boxShadow: [
        BoxShadow(
          color: Colors.black26,
          blurRadius: 8,
          offset: Offset(0, 2)
        )
      ]
    ),
    child: Row(
      children: [
        Icon(Icons.verified_user, color: Colors.white, size: 32),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '🔒 End-to-End Encrypted Call',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold
                )
              ),
              SizedBox(height: 4),
              Text(
                'Your video and audio are fully encrypted. '
                'Nobody can intercept your conversation - not even the server.',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.9),
                  fontSize: 13
                )
              )
            ],
          )
        ),
        IconButton(
          icon: Icon(Icons.info_outline, color: Colors.white),
          onPressed: () => showEncryptionInfo(context),
          tooltip: 'Encryption Details'
        )
      ],
    ),
  );
}

// ❌ KEIN Toggle - nur Info Dialog
void showEncryptionInfo(BuildContext context) {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Row(
        children: [
          Icon(Icons.lock, color: Colors.green, size: 28),
          SizedBox(width: 8),
          Text('End-to-End Encryption')
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'All PeerWave video calls are end-to-end encrypted by default.',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 15
            )
          ),
          SizedBox(height: 16),
          _buildInfoRow('🔒', 'Algorithm', 'AES-256-GCM'),
          _buildInfoRow('🔑', 'Key Exchange', 'Signal Protocol'),
          _buildInfoRow('🔄', 'Key Rotation', 'Every 1 hour'),
          _buildInfoRow('🛡️', 'Server Access', 'Zero (blind SFU)'),
          _buildInfoRow('👥', 'Privacy', 'Maximum'),
          SizedBox(height: 16),
          Container(
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green.shade200)
            ),
            child: Row(
              children: [
                Icon(Icons.verified, color: Colors.green, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This encryption is always active and cannot be disabled.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.green.shade900,
                      fontWeight: FontWeight.w500
                    )
                  )
                )
              ],
            ),
          ),
          SizedBox(height: 12),
          Text(
            '⚠️ Note: Recording is not available due to end-to-end encryption. '
            'You can use screen recording on your device instead.',
            style: TextStyle(
              color: Colors.grey.shade600,
              fontSize: 11,
              fontStyle: FontStyle.italic
            )
          )
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Got it')
        )
      ],
    )
  );
}

Widget _buildInfoRow(String emoji, String label, String value) {
  return Padding(
    padding: EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Text(emoji, style: TextStyle(fontSize: 16)),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            '$label:',
            style: TextStyle(
              color: Colors.grey.shade700,
              fontSize: 13
            )
          )
        ),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13
          )
        )
      ],
    )
  );
}
```

**Wichtig:**
- ✅ E2EE Badge IMMER sichtbar (bei allen Participants)
- ✅ Welcome Banner beim ersten Join
- ✅ Info Dialog mit Details
- ❌ KEIN Toggle zum Deaktivieren
- ❌ KEIN "Recording" Button (unmöglich mit E2EE)

---

#### TODO 5.1.7: Performance Optimization & Testing
**Ziel:** E2EE darf Performance nicht massiv beeinträchtigen

**Performance Targets:**
- **Encryption Overhead:** < 5% CPU increase
- **Latency:** < 10ms additional delay
- **Frame Drop:** < 1% at 720p30

**Optimierungen:**
```javascript
// In crypto worker:

// 1. Frame Batching (encrypt multiple frames together)
const frameBatch = [];
const BATCH_SIZE = 5;

async function encryptFrameBatch(frames) {
  // Encrypt multiple frames in parallel
  return Promise.all(frames.map(f => encryptFrame(f)));
}

// 2. Cache IV generation (reuse timestamp)
let cachedTimestamp = 0;
const ivCache = new Map();

function getOrCreateIV(frameNumber) {
  const now = Date.now();
  if (now !== cachedTimestamp) {
    ivCache.clear();
    cachedTimestamp = now;
  }
  
  if (!ivCache.has(frameNumber)) {
    ivCache.set(frameNumber, generateIV(now, frameNumber));
  }
  return ivCache.get(frameNumber);
}

// 3. Use WebAssembly for AES (if available)
let wasmCrypto = null;

async function initWasm() {
  try {
    const wasm = await import('./aes_gcm.wasm');
    wasmCrypto = wasm;
    console.log('[Crypto] Using WASM acceleration');
  } catch (e) {
    console.log('[Crypto] Falling back to WebCrypto API');
  }
}
```

**Testing:**
```dart
// Load test with E2EE enabled
void testE2EEPerformance() async {
  final stopwatch = Stopwatch()..start();
  
  // Encrypt 1000 frames
  for (int i = 0; i < 1000; i++) {
    final frame = generateTestFrame(1280, 720);
    await encryptionService.encryptFrame(frame);
  }
  
  stopwatch.stop();
  final avgTime = stopwatch.elapsedMicroseconds / 1000;
  
  print('[E2EE Test] Average encryption time: ${avgTime}μs per frame');
  // Target: < 1000μs (1ms) per frame at 720p
}
```

---

#### TODO 5.1.8: Browser Fallback für unsupported Browsers
**Ziel:** Clear Error Message wenn Browser E2EE nicht unterstützt (kein Fallback!)

**Browser Support:**
- ✅ Chrome 86+ (Insertable Streams)
- ✅ Edge 86+
- ✅ Safari 15.4+ (Encoded Transform)
- ❌ Firefox (noch nicht supported, Stand 2025) - **Call NICHT möglich**

**Implementation:**
```dart
class MediaEncryptionService {
  bool _isSupported = false;
  
  Future<void> checkSupport() async {
    // Check for Insertable Streams API
    final hasInsertableStreams = js.context.hasProperty('RTCRtpSender') &&
      js.context['RTCRtpSender'].hasProperty('createEncodedStreams');
    
    // Check for Encoded Transform API (Safari)
    final hasEncodedTransform = js.context.hasProperty('RTCRtpSender') &&
      js.context['RTCRtpSender'].hasProperty('transform');
    
    _isSupported = hasInsertableStreams || hasEncodedTransform;
    
    if (!_isSupported) {
      print('[E2EE] ❌ Browser does not support media encryption');
      print('[E2EE] ❌ Video calls are NOT possible');
    } else {
      print('[E2EE] ✅ Browser supports E2EE media encryption');
    }
  }
  
  Future<void> initialize(String sessionKey, String salt) async {
    await checkSupport();
    
    if (!_isSupported) {
      // HARD ERROR - kein Fallback!
      throw UnsupportedError(
        'Your browser does not support end-to-end encryption.\n'
        'PeerWave video calls require E2EE.\n\n'
        'Please use:\n'
        '• Chrome 86 or newer\n'
        '• Edge 86 or newer\n'
        '• Safari 15.4 or newer\n\n'
        'Firefox is not yet supported.'
      );
    }
    
    // Continue with normal initialization
    // ...
  }
  
  Future<void> encryptProducer(Producer producer) async {
    if (!_isSupported) {
      throw UnsupportedError('E2EE not supported - call should not have started');
    }
    
    // Apply encryption transform
    // ...
  }
}
```

**UI Error Screen für unsupported browsers:**
```dart
class UnsupportedBrowserScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.red.shade50,
      body: Center(
        child: Container(
          padding: EdgeInsets.all(24),
          margin: EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 20,
                offset: Offset(0, 4)
              )
            ]
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.browser_not_supported,
                size: 80,
                color: Colors.red.shade600
              ),
              SizedBox(height: 24),
              Text(
                'Browser Not Supported',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.red.shade900
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 16),
              Text(
                'Your browser does not support end-to-end encryption, '
                'which is required for PeerWave video calls.',
                style: TextStyle(
                  fontSize: 15,
                  color: Colors.grey.shade800,
                  height: 1.5
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 24),
              Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(12)
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Please use one of these browsers:',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14
                      )
                    ),
                    SizedBox(height: 12),
                    _buildBrowserRow('✅', 'Google Chrome 86+'),
                    _buildBrowserRow('✅', 'Microsoft Edge 86+'),
                    _buildBrowserRow('✅', 'Safari 15.4+'),
                    SizedBox(height: 8),
                    _buildBrowserRow('❌', 'Firefox (not yet supported)'),
                  ],
                ),
              ),
              SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: Icon(Icons.arrow_back),
                label: Text('Go Back'),
                style: ElevatedButton.styleFrom(
                  padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  backgroundColor: Colors.blue.shade700
                )
              )
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildBrowserRow(String icon, String text) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(icon, style: TextStyle(fontSize: 16)),
          SizedBox(width: 8),
          Text(text, style: TextStyle(fontSize: 14))
        ],
      )
    );
  }
}

// Check beim Join
Future<void> joinVideoCall(String channelId) async {
  try {
    // Check browser support BEFORE joining
    await MediaEncryptionService().checkSupport();
    
    if (!MediaEncryptionService().isSupported) {
      // Show error screen
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => UnsupportedBrowserScreen()
        )
      );
      return;
    }
    
    // Continue with join
    // ...
    
  } catch (e) {
    showErrorDialog(context, e.toString());
  }
}
```

**Wichtig:**
- ❌ KEIN Fallback auf unencrypted
- ❌ KEIN "Continue anyway" Button
- ✅ Clear Error Message
- ✅ Liste unterstützter Browser
- ✅ Hard Block für unsupported browsers

**Rationale:**
- E2EE ist PFLICHT, nicht optional
- Unverschlüsselte Calls widersprechen Privacy-Promise
- Besser gar kein Call als unsicherer Call
- Wie WhatsApp: Funktioniert nur mit unterstützten Clients

---

### ✅ TODO 5.2: Simulcast Support
**Ziel:** Multiple Quality Layers für Bandwidth Adaptation

**Server:**
```javascript
// In mediasoup.config.js Router Codecs:
{
  kind: 'video',
  mimeType: 'video/VP8',
  clockRate: 90000,
  parameters: {
    'x-google-start-bitrate': 1000
  },
  // Enable simulcast
  rtcpFeedback: [
    { type: 'nack' },
    { type: 'nack', parameter: 'pli' },
    { type: 'ccm', parameter: 'fir' },
    { type: 'goog-remb' }
  ]
}
```

**Client:**
```dart
// In produce:
final producer = await _sendTransport!.produce(
  track: track,
  encodings: [
    {'maxBitrate': 100000, 'scaleResolutionDownBy': 4}, // Low
    {'maxBitrate': 300000, 'scaleResolutionDownBy': 2}, // Medium
    {'maxBitrate': 900000}  // High
  ]
);
```

---

### ✅ TODO 5.2: Active Speaker Detection
**Ziel:** Highlight aktiven Sprecher

**Server:**
```javascript
// AudioLevelObserver
const audioLevelObserver = await router.createAudioLevelObserver({
  maxEntries: 1,
  threshold: -70,
  interval: 800
});

audioLevelObserver.on('volumes', (volumes) => {
  const { producer, volume } = volumes[0];
  io.to(roomId).emit('activeSpeaker', {
    peerId: producer.appData.peerId,
    volume
  });
});
```

**Client:**
```dart
_socket.on('activeSpeaker', (data) {
  setState(() {
    _activeSpeakerId = data['peerId'];
  });
});

// In UI: Highlight active speaker video
```

---

### ✅ TODO 5.3: Screen Sharing
**Ziel:** Desktop/Window/Tab Sharing

**Client:**
```dart
Future<void> startScreenShare() async {
  final stream = await navigator.mediaDevices.getDisplayMedia({
    'video': {
      'width': {'ideal': 1920},
      'height': {'ideal': 1080}
    }
  });
  
  final track = stream.getVideoTracks()[0];
  
  await _mediaSoup.produceMedia(
    track: track,
    kind: 'video',
    appData: {'type': 'screen'}  // Kennzeichnung als Screen
  );
  
  // Stop event listener
  track.onended = () {
    stopScreenShare();
  };
}
```

**UI:** Screen Share nimmt mehr Platz ein als normale Camera Streams

---

### ✅ TODO 5.4: Picture-in-Picture Mode
**Ziel:** Video Conference minimieren, aber weiterlaufen lassen

**Client:**
```dart
// PiP Support für Mobile/Web
await _videoElement.requestPictureInPicture();
```

---

### ✅ TODO 5.5: Recording Support
**Ziel:** ❌ **NICHT implementieren** (unmöglich mit mandatory E2EE)

**Warum Recording nicht möglich:**
- Server kann verschlüsselte Frames nicht entschlüsseln
- Client-side Recording wäre möglich, aber:
  - Nur eigene Perspektive (nicht alle Teilnehmer)
  - Quality/Performance Probleme
  - Storage auf Client-Device

**Alternative für Users:**
```dart
// Info Dialog wenn User nach Recording fragt
void showRecordingNotAvailable(BuildContext context) {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Row(
        children: [
          Icon(Icons.info_outline, color: Colors.blue),
          SizedBox(width: 8),
          Text('Recording Not Available')
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Call recording is not available in PeerWave because all calls '
            'are end-to-end encrypted for your privacy.',
            style: TextStyle(height: 1.5)
          ),
          SizedBox(height: 16),
          Container(
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green.shade200)
            ),
            child: Row(
              children: [
                Icon(Icons.lock, color: Colors.green, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Your privacy is protected. The server cannot decrypt '
                    'your video or audio.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.green.shade900
                    )
                  )
                )
              ],
            ),
          ),
          SizedBox(height: 16),
          Text(
            'Alternative:',
            style: TextStyle(fontWeight: FontWeight.w600)
          ),
          SizedBox(height: 8),
          Text(
            '• Use your device\'s screen recording feature\n'
            '• Recordings stay on your device\n'
            '• You control your own data',
            style: TextStyle(fontSize: 13, height: 1.5)
          )
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Understood')
        )
      ],
    )
  );
}
```

**Wichtig:**
- ❌ Kein "Record" Button in UI
- ✅ FAQ/Help Section erklärt warum
- ✅ Privacy > Features
- ✅ User kann Screen Recording nutzen (lokal)

---

## Phase 6: Testing & Optimization

### ✅ TODO 6.1: E2EE Security Audit
**Ziel:** Sicherheitsüberprüfung der E2EE Implementation

**Audit Checklist:**
- [ ] Key derivation mit HKDF korrekt
- [ ] IV wird nie wiederverwendet (nonce uniqueness)
- [ ] Forward Secrecy durch Key Rotation
- [ ] Kein Key Material in Logs
- [ ] Secure key storage (Memory only, kein localStorage)
- [ ] Proper error handling (keine Info Leaks)
- [ ] Side-channel resistance (constant-time ops wo möglich)

**Penetration Tests:**
- [ ] Man-in-the-Middle Attack (sollte scheitern)
- [ ] Replay Attack (IV Check sollte blocken)
- [ ] Server Compromise (kann Frames nicht lesen)
- [ ] Browser DevTools Inspection (Keys nicht sichtbar)

---

### ✅ TODO 6.2: E2EE Performance Testing
**Ziel:** Benchmark E2EE vs. Unencrypted Performance

**Test Scenarios:**
```dart
// Scenario 1: Encryption Overhead
void testEncryptionOverhead() async {
  // Baseline: Unencrypted frame processing
  final baseline = await measureFrameProcessing(
    frameCount: 1000,
    resolution: '720p',
    encrypted: false
  );
  
  // With E2EE
  final withE2EE = await measureFrameProcessing(
    frameCount: 1000,
    resolution: '720p',
    encrypted: true
  );
  
  final overhead = (withE2EE - baseline) / baseline * 100;
  print('Encryption overhead: ${overhead.toStringAsFixed(2)}%');
  // Target: < 5%
}

// Scenario 2: Multi-party E2EE
void testMultiPartyE2EE() async {
  // 5 participants, all encrypted
  final metrics = await simulateConference(
    participants: 5,
    duration: Duration(minutes: 5),
    e2eeEnabled: true
  );
  
  print('CPU usage: ${metrics.avgCpuPercent}%');
  print('Frame drops: ${metrics.frameDrops}');
  print('Avg latency: ${metrics.avgLatencyMs}ms');
  
  // Targets:
  // - CPU < 60%
  // - Frame drops < 1%
  // - Latency < 200ms
}

// Scenario 3: Key Rotation Impact
void testKeyRotation() async {
  final conference = await startConference(participants: 3);
  
  // Measure before rotation
  final before = await conference.getMetrics();
  
  // Trigger key rotation
  await conference.rotateKeys();
  
  // Measure after rotation
  final after = await conference.getMetrics();
  
  final impact = after.avgLatencyMs - before.avgLatencyMs;
  print('Key rotation latency impact: ${impact}ms');
  // Target: < 50ms spike
}
```

**Results Documentation:**
```markdown
## E2EE Performance Results

### Hardware: Intel i7-12700K, 16GB RAM, Chrome 120

| Scenario | Without E2EE | With E2EE | Overhead |
|----------|--------------|-----------|----------|
| 720p30 1:1 | 8% CPU | 10% CPU | +25% |
| 1080p30 1:1 | 18% CPU | 22% CPU | +22% |
| 720p30 5-party | 35% CPU | 42% CPU | +20% |
| 1080p30 5-party | 65% CPU | 78% CPU | +20% |

### Latency Impact:
- Baseline: 80ms
- With E2EE: 95ms (+15ms)
- Key Rotation: +30ms spike (recovers in 2s)

### Conclusion: ✅ E2EE overhead acceptable (<25%)
```

---

### ✅ TODO 6.3: Load Testing
**Ziel:** Wie viele concurrent users kann der Server handeln?

**Tools:**
- `mediasoup-load-test` oder eigene Scripts
- Simuliere 10, 50, 100 simultane Teilnehmer

**Metrics:**
- CPU Usage
- Memory Usage
- Network Bandwidth
- Latency

---

### ✅ TODO 6.4: Network Quality Monitoring
**Ziel:** Client-side Network Stats anzeigen

**Client:**
```dart
// Get Transport Stats
final stats = await _sendTransport!.getStats();

// Parse Stats
final rtt = stats['roundTripTime'];
final packetLoss = stats['packetLossPercentage'];
final bitrate = stats['bitrate'];

// Show in UI
if (packetLoss > 5) {
  showWarning('Poor connection quality');
}
```

---

### ✅ TODO 6.5: Adaptive Bitrate
**Ziel:** Automatische Quality Anpassung bei schlechter Verbindung

**Client:**
```dart
// Monitor consumer stats
_consumers.forEach((id, consumer) async {
  final stats = await consumer.getStats();
  
  if (stats.packetLossPercentage > 5) {
    // Request lower quality layer
    await consumer.setPreferredLayers({
      'spatialLayer': 0,  // Lowest quality
      'temporalLayer': 0
    });
  }
});
```

---

## Phase 7: Production Hardening

### ✅ TODO 7.1: E2EE Key Management in Production
**Ziel:** Sichere Key Storage und Rotation in Production

**Key Storage Best Practices:**
```dart
class SecureKeyStorage {
  // NIEMALS localStorage/sessionStorage für Keys!
  
  // Option 1: Memory only (verloren bei Reload)
  static Map<String, MediaSessionKey> _memoryKeys = {};
  
  // Option 2: Encrypted secure storage (mobile)
  static final _secureStorage = FlutterSecureStorage();
  
  // Option 3: IndexedDB mit encryption (web)
  static Database? _indexedDB;
  
  // Store key securely
  static Future<void> storeKey(String peerId, MediaSessionKey key) async {
    // Mobile: Use secure storage
    if (Platform.isAndroid || Platform.isIOS) {
      await _secureStorage.write(
        key: 'media_key_$peerId',
        value: jsonEncode(key.toJson()),
        // Android: EncryptedSharedPreferences
        // iOS: Keychain with kSecAttrAccessibleAfterFirstUnlock
      );
    }
    
    // Web: Memory only (oder encrypted IndexedDB)
    else {
      _memoryKeys[peerId] = key;
      // Optional: Encrypted IndexedDB mit user password
    }
  }
  
  // Retrieve key
  static Future<MediaSessionKey?> getKey(String peerId) async {
    if (Platform.isAndroid || Platform.isIOS) {
      final json = await _secureStorage.read(key: 'media_key_$peerId');
      return json != null ? MediaSessionKey.fromJson(jsonDecode(json)) : null;
    } else {
      return _memoryKeys[peerId];
    }
  }
  
  // Delete key (after rotation or room leave)
  static Future<void> deleteKey(String peerId) async {
    if (Platform.isAndroid || Platform.isIOS) {
      await _secureStorage.delete(key: 'media_key_$peerId');
    } else {
      _memoryKeys.remove(peerId);
    }
  }
  
  // Clear all keys (logout, security measure)
  static Future<void> clearAllKeys() async {
    if (Platform.isAndroid || Platform.isIOS) {
      await _secureStorage.deleteAll();
    } else {
      _memoryKeys.clear();
    }
  }
}
```

**Automatic Key Rotation:**
```dart
class KeyRotationScheduler {
  Timer? _rotationTimer;
  final Duration rotationInterval;
  
  KeyRotationScheduler({
    this.rotationInterval = const Duration(hours: 1)
  });
  
  void start(VideoRoomProvider room) {
    _rotationTimer = Timer.periodic(rotationInterval, (_) async {
      try {
        print('[Key Rotation] Starting scheduled rotation...');
        
        // Get all active peers
        final peerIds = room.activePeers.map((p) => p.id).toList();
        
        // Rotate keys
        await room.mediaKeyExchange.rotateMediaKeys(peerIds);
        
        // Cleanup old keys
        await _cleanupExpiredKeys();
        
        print('[Key Rotation] ✅ Completed for ${peerIds.length} peers');
      } catch (e) {
        print('[Key Rotation] ❌ Failed: $e');
        // Retry after 5 minutes
        Future.delayed(Duration(minutes: 5), () async {
          await room.mediaKeyExchange.rotateMediaKeys(peerIds);
        });
      }
    });
  }
  
  Future<void> _cleanupExpiredKeys() async {
    // Remove keys older than 24h (safety cleanup)
    // Implementation...
  }
  
  void stop() {
    _rotationTimer?.cancel();
  }
}
```

---

### ✅ TODO 7.2: SSL/TLS für Production
**Ziel:** HTTPS für signaling, DTLS für media

**Requirements:**
- Valid SSL Certificate
- nginx Reverse Proxy (optional)
- Update `MEDIASOUP_ANNOUNCED_IP` to public domain

---

### ✅ TODO 7.3: Firewall Configuration
**Ziel:** Ports für RTP/RTCP öffnen

**Required Ports:**
```
# Signaling
3000/tcp (HTTPS)

# Media
40000-40099/udp (RTP/RTCP)
40000-40099/tcp (Fallback)
```

**Firewall Rules:**
```bash
# UFW (Ubuntu)
sudo ufw allow 3000/tcp
sudo ufw allow 40000:40099/udp
sudo ufw allow 40000:40099/tcp

# iptables
iptables -A INPUT -p tcp --dport 3000 -j ACCEPT
iptables -A INPUT -p udp --dport 40000:40099 -j ACCEPT
```

---

### ✅ TODO 7.4: Monitoring & Logging
**Ziel:** Production monitoring setup

**Tools:**
- Prometheus + Grafana
- mediasoup built-in metrics
- Custom health checks

**Metrics to track:**
- Active rooms
- Active peers
- CPU/Memory per worker
- Bandwidth usage
- Failed connections
- **E2EE metrics:** Encryption/Decryption errors, Key rotation success rate

**E2EE Specific Monitoring:**
```javascript
// Server-side: Track E2EE usage
const e2eeMetrics = {
  roomsWithE2EE: 0,
  roomsWithoutE2EE: 0,
  totalEncryptedFrames: 0  // Estimated
};

// Log E2EE adoption
setInterval(() => {
  const adoption = (e2eeMetrics.roomsWithE2EE / 
    (e2eeMetrics.roomsWithE2EE + e2eeMetrics.roomsWithoutE2EE)) * 100;
  
  console.log(`[Metrics] E2EE Adoption: ${adoption.toFixed(1)}%`);
}, 60000);
```

---

### ✅ TODO 7.5: Horizontal Scaling (Advanced)
**Ziel:** Multiple mediasoup servers mit Load Balancer

**Architecture:**
```
          ┌─────────────┐
          │Load Balancer│
          └──────┬──────┘
                 │
      ┌──────────┼──────────┐
      │          │          │
┌─────▼────┐ ┌──▼────┐ ┌───▼────┐
│mediasoup1│ │mediasoup2│ │mediasoup3│
└──────────┘ └──────────┘ └────────┘
```

**Implementation:**
- Redis für shared state
- Room assignment algorithm
- Inter-server communication für cross-server rooms
- **E2EE Consideration:** Keys müssen nicht zwischen Servern geteilt werden (Client-to-Client)

---

## Phase 8: E2EE Documentation & User Education

### ✅ TODO 8.1: User-facing E2EE Documentation
**Ziel:** Erkläre E2EE für End-Users verständlich

**Dateien:**
- `/docs/E2EE_USER_GUIDE.md` (neu)

**Inhalt:**
```markdown
# End-to-End Encrypted Video Calls

## What is E2EE?

End-to-End Encryption (E2EE) means that your video and audio streams are 
encrypted on your device before being sent, and only decrypted on the 
receiving devices. **Nobody else can see or hear your conversation** - 
not even PeerWave servers.

## How it works

1. 🔐 Your camera/microphone produces video/audio
2. 🔒 Your device encrypts each frame with AES-256
3. 📡 Encrypted data is sent through PeerWave servers
4. 🔓 Recipient's device decrypts the frames
5. 🎥 Recipient sees/hears you

**The server never sees your unencrypted media.**

## Enabling E2EE

1. Open a video call in a Channel
2. Click the 🔒 icon in the toolbar
3. Toggle "End-to-End Encryption"
4. All participants must have E2EE enabled

## Important Notes

⚠️ **Limitations with E2EE:**
- ❌ Server cannot record calls
- ❌ No server-side transcription
- ❌ Some browsers don't support E2EE (Firefox)
- ⚠️ Slightly higher CPU usage (~20%)

✅ **Benefits:**
- 🔒 Maximum privacy
- 🛡️ Protection against server breaches
- 🔑 Keys rotate every hour (forward secrecy)

## Verification

Look for the green 🔒 badge on each participant's video tile.
If you see it, their stream is encrypted.

## Technical Details

- **Algorithm:** AES-256-GCM
- **Key Exchange:** Signal Protocol (Double Ratchet)
- **Key Rotation:** Every 60 minutes
- **Browser Support:** Chrome, Edge, Safari 15.4+
```

---

### ✅ TODO 8.2: Developer Documentation
**Ziel:** Technical docs für Entwickler

**Dateien:**
- `/docs/E2EE_DEVELOPER_GUIDE.md` (neu)

**Inhalt:**
```markdown
# E2EE Developer Guide

## Architecture Overview

PeerWave's E2EE implementation uses the **WebRTC Insertable Streams API** 
to intercept RTP frames before transmission and after reception.

### Components

1. **Crypto Worker** (`media_crypto_worker.js`)
   - Web Worker for async encryption/decryption
   - AES-256-GCM implementation
   - Frame batching for performance

2. **Media Encryption Service** (`media_encryption_service.dart`)
   - Manages crypto worker lifecycle
   - Applies transforms to producers/consumers
   - Handles key rotation

3. **Media Key Exchange** (`media_key_exchange.dart`)
   - Derives media keys from Signal Protocol sessions
   - HKDF-based key derivation
   - Automatic key rotation scheduler

### Encryption Flow

```
Producer (Local) → [Insertable Streams Transform] → Encrypted RTP
                          ↓
                    Crypto Worker
                          ↓
                   AES-256-GCM Encrypt
                          ↓
                  Prepend IV (12 bytes)
                          ↓
                     Send to SFU
```

### Key Derivation

```dart
// Derive media key from Signal session
final sessionKey = signalSession.currentSendingChainKey;

// HKDF with PeerWave-specific salt
final mediaKey = await hkdf(
  ikm: sessionKey,
  salt: 'PeerWave-Media-Encryption-v1',
  info: 'aes-gcm-256',
  length: 32 // 256 bits
);
```

### Performance Optimization

- Use Web Workers (prevents UI blocking)
- Batch frame encryption (5 frames at once)
- Cache IV generation (reuse timestamp)
- Consider WebAssembly for crypto ops

### Browser Compatibility

| Browser | API | Status |
|---------|-----|--------|
| Chrome 86+ | Insertable Streams | ✅ Full Support |
| Edge 86+ | Insertable Streams | ✅ Full Support |
| Safari 15.4+ | Encoded Transform | ✅ Full Support |
| Firefox | - | ❌ Not Supported |

### Security Considerations

- **Never log key material**
- **Use memory-only storage for keys**
- **Rotate keys every 60 minutes**
- **Validate IV uniqueness**
- **Handle decryption failures gracefully**

### Testing

```bash
# Run E2EE unit tests
flutter test test/e2ee_test.dart

# Performance benchmarks
flutter run test/e2ee_benchmark.dart

# Security audit
npm run security-audit
```

### Troubleshooting

**Problem:** High CPU usage  
**Solution:** Check crypto worker batching, consider reducing resolution

**Problem:** Decryption failures  
**Solution:** Verify key synchronization, check for clock skew

**Problem:** Browser not supported  
**Solution:** Show fallback warning, continue with DTLS-only

## API Reference

See inline documentation in source files.
```

---

### ✅ TODO 8.3: Security Audit Report Template
**Ziel:** Vorlage für regelmäßige Security Audits

**Dateien:**
- `/docs/E2EE_SECURITY_AUDIT_TEMPLATE.md` (neu)

**Template:**
```markdown
# E2EE Security Audit Report

**Date:** YYYY-MM-DD  
**Auditor:** Name  
**Version:** PeerWave vX.Y.Z

## Executive Summary

Brief overview of findings...

## Scope

- [ ] Crypto implementation review
- [ ] Key management audit
- [ ] Side-channel analysis
- [ ] Penetration testing
- [ ] Code review

## Findings

### Critical Issues
*None* or list issues

### High Priority
...

### Medium Priority
...

### Low Priority / Recommendations
...

## Test Results

### Encryption Strength
- Algorithm: AES-256-GCM ✅
- Key length: 256 bits ✅
- IV uniqueness: Verified ✅

### Key Management
- Derivation: HKDF-SHA256 ✅
- Storage: Memory only ✅
- Rotation: Every 60min ✅
- Forward Secrecy: Yes ✅

### Attack Resistance
- Man-in-the-Middle: Protected ✅
- Replay Attack: IV check blocks ✅
- Server Compromise: Frames unreadable ✅
- Browser DevTools: Keys not exposed ✅

## Recommendations

1. ...
2. ...
3. ...

## Conclusion

Overall security assessment: **PASS** / FAIL

## Appendix

Detailed test logs, penetration test results, etc.
```

---

## 📊 Success Metrics (Updated with E2EE)

### ✅ Phase 1-2 Complete:
- [ ] Docker container startet mit mediasoup
- [ ] Workers werden initialisiert
- [ ] Rooms können erstellt werden
- [ ] Socket.IO signaling funktioniert

### ✅ Phase 3-4 Complete:
- [ ] Flutter Client kann Room joinen
- [ ] Camera/Microphone streaming funktioniert
- [ ] Peer-to-Peer video sichtbar
- [ ] Multiple participants (3+ Personen)

### ✅ Phase 5 Complete (Basic + E2EE):
- [ ] Simulcast aktiv
- [ ] Active speaker detection
- [ ] Screen sharing
- [ ] Picture-in-Picture
- [ ] **E2EE encryption working (MANDATORY)**
- [ ] **Crypto worker performing < 5% overhead**
- [ ] **Key rotation automatic (every 1h)**
- [ ] **E2EE indicators in UI (always visible)**
- [ ] **Browser check blocks unsupported clients**

### ✅ Phase 6 Complete (Testing):
- [ ] E2EE security audit passed
- [ ] Performance tests show < 25% E2EE overhead
- [ ] Load tested (50+ concurrent users)
- [ ] Browser compatibility verified
- [ ] Fallback for unsupported browsers working

### ✅ Production Ready:
- [ ] SSL/TLS enabled
- [ ] **E2EE key management secure (memory-only, no localStorage)**
- [ ] **Automatic key rotation in production (every 1h)**
- [ ] **Browser compatibility enforced (Chrome/Edge/Safari only)**
- [ ] Monitoring setup (incl. E2EE metrics)
- [ ] Documentation complete (user + developer)
- [ ] **Security audit report completed**
- [ ] **Clear messaging: Recording not available (by design)**

---

## 🚨 Wichtige Überlegungen

### E2EE Spezifische Überlegungen:

**Vorteile:**
- ✅ **Maximale Privacy:** Server kann Streams nicht entschlüsseln
- ✅ **Zero-Knowledge:** Selbst bei Server Compromise sind Streams sicher
- ✅ **Forward Secrecy:** Key Rotation alle 60 Minuten
- ✅ **Compliance:** DSGVO/GDPR konform
- ✅ **Trust:** Wie WhatsApp - E2EE immer aktiv
- ✅ **Einfachheit:** Kein Toggle = kein Fehler möglich

**Nachteile:**
- ❌ **Server-side Recording unmöglich:** Nur Client-side (lokal)
- ❌ **Keine Transcription:** Server kann Audio nicht verarbeiten
- ❌ **Browser Support:** Firefox (noch) nicht unterstützt → Call unmöglich
- ❌ **Performance Overhead:** ~20-25% mehr CPU Auslastung
- ❌ **Debugging schwieriger:** Verschlüsselte Frames nicht inspizierbar
- ❌ **Keine Cloud-Features:** Kein AI, Translation, Live Captions

**Wann E2EE Standard sinnvoll ist:**
- ✅ **Privacy-First Application** (wie PeerWave)
- ✅ Sensitive Communications (Business, Healthcare, Legal)
- ✅ DSGVO/GDPR Compliance zwingend
- ✅ Trust-Building (User wissen: IMMER sicher)
- ✅ Competitive Advantage (vs. Teams/Zoom)

**Trade-off Entscheidung:**
- 🔒 **PeerWave = Privacy First**
- ✅ E2EE Standard = Richtige Wahl
- ❌ Features (Recording, AI) = Nachrangig
- ✅ Wie WhatsApp, Signal: Security > Features

### Performance:
- **1 Worker = ~200 concurrent connections**
- **CPU-Bound**: Mehr CPU Cores = mehr Kapazität
- **Bandwidth**: 1 Mbps per HD video stream (↑ + ↓)
- **E2EE Overhead**: +20-25% CPU für Encryption/Decryption
- **Memory**: +50MB per room mit E2EE (crypto workers)

### Costs:
- **Server**: 4 CPU Cores, 8GB RAM minimum für 50 users
  - Mit E2EE: 6 CPU Cores, 10GB RAM empfohlen
- **Bandwidth**: ~50 Mbps für 50 simultane HD streams
- **Scaling**: Horizontal scaling ab 200+ users

### Alternatives:
- **Jitsi**: Open Source, ähnlich wie mediasoup
- **LiveKit**: Cloud-hosted SFU
- **Agora.io**: Commercial service

---

## 📝 Implementation Timeline (Updated with E2EE)

### Week 1: Foundation
- Phase 1 & 2 (Docker + Server)
- Basic room management
- Socket.IO signaling

### Week 2: Client Integration
- Phase 3 (Flutter Client)
- Basic video streaming
- 1:1 video calls

### Week 3: Multi-Party
- Phase 4 (Channel Integration)
- Grid layout für 3+ participants
- Basic controls

### Week 4: Advanced Features
- Phase 5.1: **E2EE Implementation**
  - Crypto worker setup
  - Insertable Streams integration
  - Key exchange with Signal Protocol
- Phase 5.2-5.4: Simulcast, Active Speaker, Screen Sharing

### Week 5: E2EE Testing & Hardening
- Phase 6: Security audit, Performance testing
- Phase 7.1: Key management in production
- E2EE documentation

### Week 6: Production & Polish
- Phase 7: SSL, Firewall, Monitoring
- Phase 8: User education, Developer docs
- Final testing & deployment

**Total:** ~6 weeks for MVP mit E2EE video conferencing  
**Alternative:** ~5 weeks ohne E2EE (Phase 5.1, 6.1-6.2, 7.1, 8 überspringen)

---

## 📚 Resources

### Documentation:
- **mediasoup:** https://mediasoup.org/documentation/
- **mediasoup-client:** https://mediasoup.org/documentation/v3/mediasoup-client/
- **WebRTC:** https://webrtc.org/
- **Insertable Streams:** https://w3c.github.io/webrtc-encoded-transform/
- **Signal Protocol:** https://signal.org/docs/
- **WebCrypto API:** https://developer.mozilla.org/en-US/docs/Web/API/Web_Crypto_API

### Example Projects:
- **mediasoup-demo:** https://github.com/versatica/mediasoup-demo
- **mediasoup-sample-app:** https://github.com/Dirvann/mediasoup-sfu-webrtc-video-rooms
- **WebRTC E2EE Samples:** https://webrtc.github.io/samples/src/content/insertable-streams/

### Flutter:
- **flutter_webrtc:** https://pub.dev/packages/flutter_webrtc
- **mediasoup_client_flutter:** (Search pub.dev for latest)
- **flutter_secure_storage:** https://pub.dev/packages/flutter_secure_storage

### Security:
- **OWASP WebRTC Security:** https://owasp.org/www-community/controls/WebRTC_Security
- **RFC 5869 (HKDF):** https://datatracker.ietf.org/doc/html/rfc5869
- **AES-GCM Security:** https://csrc.nist.gov/publications/detail/sp/800-38d/final

---

**Erstellt am:** 31. Oktober 2025  
**Version:** 3.0 (E2EE als Standard - kein Opt-out)  
**Status:** Ready for Implementation 🚀  
**Geschätzter Aufwand:** 
- **Mit E2EE Standard:** 6 Wochen (1 Entwickler)
- **E2EE ist integraler Bestandteil, nicht optional**

**🔒 Design Philosophy:** "Privacy by Default, nicht by Choice"
- ✅ Wie WhatsApp: E2EE immer aktiv
- ✅ Keine Kompromisse bei Security
- ✅ User muss nicht entscheiden (kann nicht falsch wählen)
- ❌ Keine Features auf Kosten von Privacy
