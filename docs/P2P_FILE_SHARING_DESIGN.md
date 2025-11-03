# P2P File Sharing über Signal - Implementierungsplan

## 📋 Zusammenfassung der Anforderungen

### Kernfeatures
1. **File Sharing**: 1:1 und Gruppen-Chats über Signal
2. **WebRTC P2P Transfer**: Direkte Browser-zu-Browser Übertragung
3. **Torrent-ähnliche Chunks**: Mehrere Nutzer können gleichzeitig Teile teilen
4. **E2E Verschlüsselung**: Chunks mit PreKey verschlüsselt
5. **Persistenz**: UUID + Checksum im lokalen Storage
6. **Server als Koordinator**: Nur Metadaten, keine File-Daten

### Technologie-Stack
- **WebRTC DataChannel**: Für P2P File-Transfer
- **Socket.IO**: Signaling & Koordination (bereits vorhanden)
- **Signal Protocol**: Für Chunk-Verschlüsselung
- **IndexedDB**: Lokaler Storage für File-Chunks
- **Existing Architecture**: Integration in vorhandenes Signal-System

### UX-Verbesserungen ✨ NEU
**Siehe**: `P2P_USABILITY_IMPROVEMENTS.md`

**Kritische Features:**
- ✅ Pause/Resume (Verhindert Datenverlust)
- ✅ Server-Relay Fallback (100% Erfolgsrate)
- ✅ Seeder-Benachrichtigungen (Availability Alerts)
- ✅ Uploader-Status Widget (Real-Time Feedback)

**Wichtige Features:**
- ✅ Preview/Thumbnails (User sieht Inhalt)
- ✅ ETA & Speed Display (Bessere Info)
- ✅ Power Management (Battery-freundlich)

**Nice-to-Have:**
- ✅ Server-Cache (Kleine Files)
- ✅ Auto-Resume nach Crash
- ✅ Background Warning

---

## 🏗️ Architektur-Überblick

```
┌─────────────────────────────────────────────────────────────────┐
│                         USER A (Sender)                         │
│  ┌──────────────┐  ┌────────────┐  ┌──────────────────────┐   │
│  │  File Picker │→ │ Chunk      │→ │ IndexedDB            │   │
│  │              │  │ Generator  │  │ (UUID, Checksum)     │   │
│  └──────────────┘  └────────────┘  └──────────────────────┘   │
│         │                                    │                   │
│         │                                    │ Encrypt with      │
│         │                                    │ Signal PreKey     │
│         ▼                                    ▼                   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │            WebRTC DataChannel (Encrypted Chunks)        │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ Socket.IO Signaling
                              │ (Metadata only)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      SERVER (Koordinator)                        │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  File Registry (In-Memory)                               │  │
│  │  {                                                        │  │
│  │    fileId: "uuid-v4",                                    │  │
│  │    checksum: "sha256-hash",                              │  │
│  │    fileName: "document.pdf",                             │  │
│  │    fileSize: 1048576,                                    │  │
│  │    chunkCount: 16,                                       │  │
│  │    seeders: [                                            │  │
│  │      { userId, deviceId, chunks: [0,1,2,3...15] }       │  │
│  │    ],                                                     │  │
│  │    leechers: [ { userId, deviceId, chunks: [0,1] } ]    │  │
│  │  }                                                        │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ Socket.IO Signaling
                              │ (Metadata + WebRTC ICE)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      USER B (Receiver)                           │
│  ┌──────────────┐  ┌────────────┐  ┌──────────────────────┐   │
│  │  Click Link  │→ │ Download   │→ │ Decrypt & Verify     │   │
│  │  (Socket)    │  │ Manager    │  │ Checksum             │   │
│  └──────────────┘  └────────────┘  └──────────────────────┘   │
│         │                │                    │                  │
│         │                │ Parallel Download  │                  │
│         │                │ from multiple      │                  │
│         │                │ seeders            │                  │
│         ▼                ▼                    ▼                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │       WebRTC DataChannel + IndexedDB Storage            │   │
│  └─────────────────────────────────────────────────────────┘   │
│         │                                    │                   │
│         │ Complete? ─────────────────────────┤                  │
│         ▼                                    │                   │
│  ┌──────────────┐                           │                  │
│  │ Save File    │                           │ Become Seeder     │
│  │ (Download)   │                           │ (Share Chunks)    │
│  └──────────────┘                           └───────────────────┘
└─────────────────────────────────────────────────────────────────┘
```

---

## 📦 Chunk-System Design

### Chunk-Spezifikation
```javascript
const CHUNK_SIZE = 64 * 1024; // 64 KB pro Chunk (optimal für WebRTC) ✅ CONFIRMED
const MAX_FILE_SIZE = 2 * 1024 * 1024 * 1024; // 2 GB Limit ✅ CONFIRMED

const ChunkMetadata = {
  fileId: 'uuid-v4',           // Eindeutige File-ID
  chunkIndex: 0,               // Chunk-Position (0-basiert)
  chunkHash: 'sha256-hash',    // Hash des unverschlüsselten Chunks
  encryptedData: Uint8Array,   // Verschlüsselte Chunk-Daten
  timestamp: Date.now()
};

// ⚠️ WICHTIG: fileName und mimeType werden NICHT auf Server gespeichert!
// Sie werden verschlüsselt in der Signal-Nachricht übertragen (Download-Link)
const FileMetadata = {
  fileId: 'uuid-v4',
  fileName: 'document.pdf',        // ❌ NICHT auf Server (nur in Signal-Message)
  fileSize: 1048576,               // ✅ Bytes (auf Server für Chunk-Count)
  mimeType: 'application/pdf',     // ❌ NICHT auf Server (nur in Signal-Message)
  checksum: 'sha256-hash',         // ✅ Hash der gesamten Datei (auf Server)
  chunkCount: 16,                  // ✅ Math.ceil(fileSize / CHUNK_SIZE)
  chunkSize: 64 * 1024,
  uploaderId: 'user-uuid',
  uploadDeviceId: 'device-uuid',
  createdAt: Date.now(),
  
  // Signal-Verschlüsselung
  signalSessionId: 'session-id',  // Für 1:1
  groupId: 'group-uuid',          // Für Gruppen (Sender Key)
  
  // Chunk-Status
  chunks: [
    { index: 0, hash: 'sha256', status: 'complete' },
    { index: 1, hash: 'sha256', status: 'downloading' },
    // ...
  ]
};
```

### Chunk-Verschlüsselung

#### Option 1: Signal PreKey (Empfohlen für 1:1)
```javascript
// Sender: Verschlüssle jeden Chunk mit Signal Session
const encryptedChunk = await signalProtocol.encrypt(
  recipientAddress,  // User + Device
  chunkData
);

// Receiver: Entschlüssle Chunk
const decryptedChunk = await signalProtocol.decrypt(
  senderAddress,
  encryptedChunk
);
```

**Vorteile**:
- ✅ Nutzt vorhandene Signal-Sessions
- ✅ Perfect Forward Secrecy
- ✅ Authentifizierung des Senders

**Nachteile**:
- ❌ Jeder Chunk braucht eigene Signal-Nachricht (Overhead)
- ❌ Ratchet-State muss synchron bleiben

#### Option 2: Symmetric Key (Empfohlen für Gruppen)
```javascript
// 1. Generiere symmetrischen Schlüssel für File
const fileKey = crypto.getRandomValues(new Uint8Array(32)); // AES-256

// 2. Teile Schlüssel über Signal Sender Key (Gruppe)
await signalProtocol.sendSenderKey(groupId, fileKey);

// 3. Verschlüssle Chunks mit AES-GCM
const encryptedChunk = await crypto.subtle.encrypt(
  {
    name: 'AES-GCM',
    iv: crypto.getRandomValues(new Uint8Array(12)),
    tagLength: 128
  },
  fileKey,
  chunkData
);
```

**Vorteile**:
- ✅ Schneller (kein Signal-Overhead pro Chunk)
- ✅ Skaliert für viele Chunks
- ✅ Funktioniert mit Sender Key System

**Nachteile**:
- ❌ File-Key muss sicher über Signal geteilt werden

### **Empfehlung: Hybrid-Ansatz**
- **1:1 Chats**: Symmetric Key (über Signal PreKey geteilt)
- **Gruppen**: Symmetric Key (über Sender Key geteilt)
- **Chunks**: AES-GCM mit File-Key verschlüsselt

**Begründung**: Signal-Protocol ist für kurze Nachrichten optimiert, nicht für große Dateien. Ein File-Key reduziert Overhead und nutzt trotzdem Signal für Key-Distribution.

---

## 🔄 Flow-Diagramme

### 1. File Upload Flow (1:1 Chat)

```
┌─────────────┐
│ USER SELECTS│
│    FILE     │
└──────┬──────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 1. Generate File Metadata          │
│    - UUID, Checksum (SHA-256)      │
│    - Split into Chunks (64KB)      │
│    - Generate Chunk Hashes         │
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 2. Generate File Encryption Key    │
│    - AES-256 Key (random)          │
│    - Encrypt Key with Signal       │
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 3. Store Chunks in Local Storage   │
│    - Web: IndexedDB (idb_shim)     │
│    - Native: FlutterSecureStorage  │
│    - Encrypt each chunk (AES-GCM)  │
│    - Store with fileId + index     │
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 4. Send TWO Messages:               │
│                                     │
│    A) Socket.IO → Server            │
│       (OHNE fileName/mimeType!)     │
│       {                             │
│         type: 'file-offer',         │
│         fileId: 'uuid',             │
│         fileSize: 1048576,          │
│         checksum: 'sha256',         │
│         chunkCount: 16              │
│       }                             │
│                                     │
│    B) Signal Message → Recipient    │
│       (Verschlüsselt!)              │
│       {                             │
│         type: 'file-download-link', │
│         fileId: 'uuid',             │
│         fileName: 'document.pdf',   │← Nur hier!
│         mimeType: 'application/pdf',│← Nur hier!
│         encryptedKey: 'base64',     │← File-Key
│         checksum: 'sha256',         │
│         chunkCount: 16              │
│       }                             │
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 5. Server: Store Metadata          │
│    - Add to fileRegistry            │
│    - Register as Seeder             │
│    - TTL: 30 Tage                   │
│    - Auto-Reannounce: true          │
│    ❌ KEIN fileName/mimeType!       │
└─────────────────────────────────────┘
```

### 2. File Download Flow

```
┌─────────────┐
│ USER CLICKS │
│  FILE LINK  │ ← Signal-Nachricht mit fileName/mimeType/encryptedKey
└──────┬──────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 1. Extract from Signal Message     │
│    - fileId                         │
│    - fileName (verschlüsselt!)      │
│    - mimeType (verschlüsselt!)      │
│    - encryptedKey (Signal)          │
│    - checksum                       │
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 2. Request Seeder List (Socket)    │
│    Server returns:                  │
│    {                                │
│      fileId, fileSize, chunkCount,  │
│      seeders: [                     │
│        { userId, deviceId,          │
│          chunks: [0,1,2...15] }     │
│      ]                              │
│    }                                │
│    ❌ KEIN fileName/mimeType!       │
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 3. Decrypt File Key (Signal)       │
│    - Extract encryptedKey from msg  │
│    - Decrypt with Signal Session    │
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 4. Connect to Seeders (WebRTC)     │
│    - WebRTC Offer/Answer via Socket │
│    - Establish DataChannel          │
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 5. Download Chunks (Parallel)      │
│    - Request chunks from seeders    │
│    - Rarest-first strategy          │
│    - Pipeline multiple requests     │
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 6. Decrypt & Verify Chunks         │
│    - Decrypt with File Key (AES)    │
│    - Verify Chunk Hash              │
│    - Store in Local Storage         │
│      (IndexedDB or SecureStorage)   │
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 7. Assemble File                   │
│    - Concatenate all chunks         │
│    - Verify file checksum           │
│    - Trigger browser download       │
│      with CORRECT fileName!         │← Aus Signal-Message
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 8. Become Seeder                   │
│    - Notify server: chunk list      │
│    - Accept peer connections        │
│    - TTL: 30 Tage                   │
└─────────────────────────────────────┘
```

### 3. P2P Chunk-Transfer (WebRTC)

```
SEEDER A (has chunks 0-7)     SERVER           SEEDER B (has chunks 8-15)
     │                           │                        │
     │─── Register chunks ──────→│                        │
     │                           │←──── Register chunks ──│
     │                           │                        │
     │                      LEECHER C                     │
     │                           │                        │
     │←───────── Request Seeder List ────────────────────┤
     │                           │                        │
     │                    { seeders: [A, B] }             │
     │                           │                        │
     │←── WebRTC Offer (A) ──────┼────────────────────────│
     │─── WebRTC Answer ────────→│                        │
     │                           │                        │
     │                           │←── WebRTC Offer (B) ───┤
     │                           │─── WebRTC Answer ─────→│
     │                           │                        │
     │←── Request Chunk 0 ───────────────────────────────│
     │─── Send Chunk 0 (encrypted) ──────────────────────→│
     │                           │                        │
     │                           │←── Request Chunk 8 ────┤
     │                           │─── Send Chunk 8 ───────→│
     │                           │                        │
     │← Parallel download from both seeders              →│
     │                           │                        │
     │───────── Update chunk progress (Socket) ──────────→│
     │                           │                        │
```

### 4. Auto-Reannounce Flow (Uploader kommt wieder online)

```
┌─────────────────────────────────────┐
│ UPLOADER GOES OFFLINE               │
│ - Disconnect event                  │
│ - Server removes from seeders list  │
│ - File bleibt in Registry (30 Tage) │
└──────┬──────────────────────────────┘
       │
       │ ... Time passes ...
       │
       ▼
┌─────────────────────────────────────┐
│ UPLOADER RECONNECTS                 │
│ - Socket.IO authenticate event      │
│ - Client checks local storage       │
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 1. Load Uploaded Files              │
│    - Query IndexedDB/SecureStorage  │
│    - Find files with status='uploaded'│
│    - Extract fileIds                │
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 2. Check Server Registry            │
│    socket.emit('file:check-exists', │
│      { fileIds: ['uuid1', 'uuid2'] })│
│                                     │
│    Server responds:                 │
│    { exists: ['uuid1'], missing: [] }│
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 3. Reannounce Files                │
│    FOR EACH existing fileId:        │
│      socket.emit('file:reannounce', │
│        {                            │
│          fileId: 'uuid1',           │
│          chunks: [0,1,2...15]       │
│        })                           │
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 4. Server Updates Registry          │
│    - Add uploader to seeders list   │
│    - Update lastUploadRequest       │
│    - Reset TTL (if needed)          │
│    - Notify waiting leechers        │
└──────┬──────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ 5. Notify Interested Users          │
│    socket.to(chatRoom).emit(        │
│      'file:uploader-online',        │
│      { fileId: 'uuid1' }            │
│    )                                │
└─────────────────────────────────────┘
```

---

## 🗂️ Datenstrukturen

### Storage-Präferenzen (Verfügbar in PeerWave)

#### Web (Flutter Web)
```yaml
# Bereits verfügbar:
- idb_shim: ^2.6.6+2           # IndexedDB Wrapper
- shared_preferences: ^2.0.6    # Simple Key-Value Store
- js: ^0.6.7                    # JavaScript Interop (localStorage)

# Verwendung:
✅ IndexedDB (via idb_shim):
   - Große Dateien/Chunks (2 GB möglich)
   - Strukturierte Daten
   - Async API
   - Persistenz über Sessions
   
✅ localStorage (via js package):
   - Einfache Metadaten (fileIds, Status)
   - Synchrone API
   - Max ~10 MB (Browser-abhängig)
   - Nicht für Chunks!
```

#### Native (Flutter Android/iOS)
```yaml
# Bereits verfügbar:
- flutter_secure_storage: ^9.0.0  # Encrypted Key-Value Store
- shared_preferences: ^2.0.6      # Simple Key-Value Store

# Verwendung:
✅ FlutterSecureStorage:
   - Verschlüsseltes Storage
   - File Keys, Metadaten
   - Chunks (mit Einschränkung: Performance bei großen Daten)
   
⚠️ SharedPreferences:
   - Nur für einfache Flags/Status
   - NICHT für Chunks (zu klein)
   
🔄 Empfehlung: path_provider + Dart File API
   - Chunks als verschlüsselte Dateien speichern
   - Metadaten in FlutterSecureStorage
   - Bessere Performance für große Dateien
```

### IndexedDB Schema (Web)

```javascript
// Database: 'PeerWaveFiles'
// Version: 1

// ObjectStore: 'files'
{
  keyPath: 'fileId',
  indexes: {
    'checksum': { unique: false },
    'uploaderId': { unique: false },
    'createdAt': { unique: false },
    'status': { unique: false } // 'uploading', 'uploaded', 'downloading', 'seeding'
  }
}

// ObjectStore: 'chunks'
{
  keyPath: ['fileId', 'chunkIndex'],
  indexes: {
    'fileId': { unique: false },
    'status': { unique: false }
  }
}

// ObjectStore: 'fileKeys'
{
  keyPath: 'fileId',
  autoIncrement: false
}

// Beispiel-Daten:
files: {
  fileId: 'uuid-v4',
  fileName: 'document.pdf',        // ✅ Lokal gespeichert (verschlüsselt)
  fileSize: 1048576,
  mimeType: 'application/pdf',     // ✅ Lokal gespeichert (verschlüsselt)
  checksum: 'sha256-hash',
  chunkCount: 16,
  uploaderId: 'user-uuid',          // Falls ich der Uploader bin
  createdAt: Date.now(),
  status: 'seeding',                // 'uploading', 'uploaded', 'downloading', 'seeding'
  downloadProgress: 0.75,           // 0.0 - 1.0
  chatType: 'direct',               // 'direct' oder 'group'
  chatId: 'recipient-uuid'
}

chunks: {
  fileId: 'uuid-v4',
  chunkIndex: 0,
  chunkHash: 'sha256-hash',
  encryptedData: Uint8Array,
  iv: Uint8Array,  // AES-GCM IV
  status: 'complete', // 'pending', 'downloading', 'complete', 'error'
  timestamp: Date.now()
}

fileKeys: {
  fileId: 'uuid-v4',
  encryptedKey: 'base64',  // Mit Signal verschlüsselt (für Re-Encrypt bei Reannounce)
  decryptedKey: CryptoKey  // AES-256 Key (nur im Memory, nicht persistent!)
}
```

### Native Storage Schema (Flutter)

```dart
// FlutterSecureStorage Keys:

// File Metadaten
'file_${fileId}_metadata' → JSON({
  fileId: String,
  fileName: String,        // ✅ Lokal gespeichert (verschlüsselt)
  fileSize: int,
  mimeType: String,        // ✅ Lokal gespeichert (verschlüsselt)
  checksum: String,
  chunkCount: int,
  uploaderId: String?,
  createdAt: int,
  status: String,
  downloadProgress: double,
  chatType: String,
  chatId: String
})

// File Key (AES)
'file_${fileId}_key' → base64(AES-256-Key)

// Chunk-Metadaten (Liste)
'file_${fileId}_chunks' → JSON([
  {
    chunkIndex: 0,
    chunkHash: String,
    status: String,
    filePath: String  // Pfad zur verschlüsselten Chunk-Datei
  }
])

// path_provider Storage (Dateisystem):
// <app_documents_dir>/file_chunks/${fileId}/chunk_${chunkIndex}.enc
// → Verschlüsselte Chunk-Daten als Dateien
```
```

### Server In-Memory Registry

```javascript
// server/store/fileRegistry.js
const fileRegistry = new Map();

// ⚠️ WICHTIG: Server kennt KEINE fileName oder mimeType!
// Diese werden verschlüsselt in Signal-Nachricht übertragen
// Struktur:
fileRegistry.set(fileId, {
  fileId: 'uuid-v4',
  // fileName: NICHT GESPEICHERT (Privacy!)
  fileSize: 1048576,
  checksum: 'sha256-hash',
  chunkCount: 16,
  uploaderId: 'user-uuid',
  uploadDeviceId: 'device-uuid',
  
  // Für 1:1 oder Gruppe
  chatType: 'direct', // 'direct' oder 'group'
  chatId: 'user-uuid', // recipientId für 1:1, groupId für Gruppe
  
  // Seeder-Tracking
  seeders: [
    {
      userId: 'user-uuid',
      deviceId: 'device-uuid',
      socketId: 'socket-id',
      chunks: [0, 1, 2, 3, 4, 5, 6, 7], // Verfügbare Chunks
      uploadSlots: 4,  // Max parallele Uploads
      activeUploads: 2, // Aktuell aktive Uploads
      lastSeen: Date.now() // Für Auto-Offline-Detection
    }
  ],
  
  // Leecher-Tracking
  leechers: [
    {
      userId: 'user-uuid',
      deviceId: 'device-uuid',
      socketId: 'socket-id',
      chunks: [0, 1, 2], // Bereits heruntergeladene Chunks
      downloadedBytes: 196608,
      progress: 0.1875 // 3/16 chunks
    }
  ],
  
  // Statistiken
  stats: {
    totalDownloads: 5,
    totalSeeders: 2,
    createdAt: Date.now(),
    lastActivity: Date.now(), // Letzte Download-Anfrage
    lastUploadRequest: Date.now() // Letztes Mal Uploader war online
  },
  
  // TTL für automatisches Cleanup
  // ✅ 30 TAGE: Falls keine Aktivität, wird File vom Server entfernt
  expiresAt: Date.now() + (30 * 24 * 60 * 60 * 1000), // 30 Tage
  
  // Auto-Reannounce wenn Uploader wieder online kommt
  autoReannounce: true, // Uploader stellt File automatisch wieder bereit
  originalUploaderId: 'user-uuid', // Original-Uploader (für Auto-Reannounce)
  originalDeviceId: 'device-uuid'
});
```

---

## 🔌 Socket.IO Events

### Client → Server

```javascript
// 1. File anbieten (Seeder) - OHNE fileName/mimeType!
socket.emit('file:offer', {
  fileId: 'uuid-v4',
  // fileName: NICHT GESENDET (wird in Signal-Message verschlüsselt)
  // mimeType: NICHT GESENDET (wird in Signal-Message verschlüsselt)
  fileSize: 1048576,
  checksum: 'sha256-hash',
  chunkCount: 16,
  chatType: 'direct', // 'direct' | 'group'
  chatId: 'recipient-uuid' // userId für 1:1, groupId für Gruppe
  // encryptedKey: NICHT HIER (wird in Signal-Message gesendet)
});

// 2. Chunk-Status aktualisieren
socket.emit('file:update-chunks', {
  fileId: 'uuid-v4',
  chunks: [0, 1, 2, 3], // Verfügbare Chunks
  status: 'seeding' // 'downloading' | 'seeding' | 'complete'
});

// 3. Seeder-Liste anfragen
socket.emit('file:request-seeders', {
  fileId: 'uuid-v4'
}, (response) => {
  // response: { seeders: [...], leechers: [...] }
});

// 4. File-Download starten
socket.emit('file:start-download', {
  fileId: 'uuid-v4'
});

// 5. File-Download abschließen
socket.emit('file:complete', {
  fileId: 'uuid-v4'
});

// 6. WebRTC Signaling für File-Transfer
socket.emit('file:webrtc-offer', {
  fileId: 'uuid-v4',
  targetUserId: 'user-uuid',
  targetDeviceId: 'device-uuid',
  offer: RTCSessionDescription
});

socket.emit('file:webrtc-answer', {
  fileId: 'uuid-v4',
  targetUserId: 'user-uuid',
  targetDeviceId: 'device-uuid',
  answer: RTCSessionDescription
});

socket.emit('file:webrtc-ice', {
  fileId: 'uuid-v4',
  targetUserId: 'user-uuid',
  targetDeviceId: 'device-uuid',
  candidate: RTCIceCandidate
});

// 7. ✅ NEU: Auto-Reannounce wenn Uploader wieder online
socket.emit('file:reannounce', {
  fileId: 'uuid-v4',
  chunks: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15] // Alle Chunks verfügbar
});
```

### Server → Client

```javascript
// 1. Neues File verfügbar (an Chat-Teilnehmer)
// ⚠️ Server sendet NUR Metadaten, KEINE fileName/mimeType
// Diese kommen verschlüsselt in der Signal-Nachricht
socket.emit('file:available', {
  fileId: 'uuid-v4',
  // fileName: NICHT HIER (in Signal-Message)
  fileSize: 1048576,
  // mimeType: NICHT HIER (in Signal-Message)
  checksum: 'sha256-hash',
  chunkCount: 16,
  uploaderId: 'user-uuid',
  uploadDeviceId: 'device-uuid',
  // encryptedKey: NICHT HIER (in Signal-Message)
  chatType: 'direct',
  chatId: 'chat-id'
});

// 2. Seeder-Liste Update
socket.emit('file:seeders-update', {
  fileId: 'uuid-v4',
  seeders: [
    {
      userId: 'user-uuid',
      deviceId: 'device-uuid',
      chunks: [0, 1, 2, 3, 4, 5, 6, 7],
      uploadSlots: 4,
      activeUploads: 1
    }
  ]
});

// 3. WebRTC Signaling
socket.emit('file:webrtc-offer', {
  fileId: 'uuid-v4',
  fromUserId: 'user-uuid',
  fromDeviceId: 'device-uuid',
  offer: RTCSessionDescription
});

socket.emit('file:webrtc-answer', { /* ... */ });
socket.emit('file:webrtc-ice', { /* ... */ });

// 4. File-Transfer abgeschlossen
socket.emit('file:download-complete', {
  fileId: 'uuid-v4',
  userId: 'user-uuid'
});

// 5. Error-Events
socket.emit('file:error', {
  fileId: 'uuid-v4',
  error: 'Seeder offline',
  code: 'SEEDER_OFFLINE'
});

// 6. ✅ NEU: Uploader wieder online (File wieder verfügbar)
socket.emit('file:uploader-online', {
  fileId: 'uuid-v4',
  uploaderId: 'user-uuid',
  uploadDeviceId: 'device-uuid'
});
```

---

## 📁 Dateistruktur

### Client (Flutter)

```
client/lib/
├── services/
│   ├── file_transfer/
│   │   ├── file_transfer_service.dart          # Hauptservice
│   │   ├── chunk_manager.dart                  # Chunk-Verwaltung
│   │   ├── webrtc_manager.dart                 # WebRTC Connections
│   │   ├── indexeddb_storage.dart              # IndexedDB Interface
│   │   ├── encryption_service.dart             # File-Key Encryption
│   │   └── download_manager.dart               # Download-Logik
│   └── signal_service.dart                     # (bereits vorhanden)
├── models/
│   ├── file_metadata.dart
│   ├── chunk_metadata.dart
│   └── seeder_info.dart
├── widgets/
│   ├── file_transfer/
│   │   ├── file_upload_button.dart
│   │   ├── file_download_card.dart
│   │   ├── transfer_progress_indicator.dart
│   │   └── seeder_list_widget.dart
└── screens/
    └── chat/
        └── file_transfer_overlay.dart
```

### Server (Node.js)

```
server/
├── store/
│   └── fileRegistry.js                         # In-Memory File Registry
├── routes/
│   └── fileTransfer.js                         # HTTP Endpoints (optional)
├── services/
│   ├── fileCoordinator.js                      # Seeder/Leecher Management
│   └── fileCleanup.js                          # TTL & Cleanup
└── server.js                                   # Socket.IO Event-Handler
    (Erweitern mit file:* events)
```

### Public (falls Web-Client)

```
public/
├── file-transfer/
│   ├── file-transfer-client.js                 # WebRTC Client
│   ├── chunk-worker.js                         # Web Worker für Chunks
│   └── indexeddb-storage.js                    # IndexedDB Wrapper
```

---

## 🔐 Security Considerations

### 1. Verschlüsselung
- ✅ **File-Key**: AES-256, zufällig generiert pro File
- ✅ **Key-Distribution**: Über Signal PreKey/Sender Key
- ✅ **Chunk-Encryption**: AES-GCM mit File-Key
- ✅ **Authentifizierung**: Signal-Session gewährleistet Authentizität

### 2. Integritätsprüfung
- ✅ **Chunk-Hash**: SHA-256 pro Chunk (vor Verschlüsselung)
- ✅ **File-Hash**: SHA-256 über gesamte Datei
- ✅ **Verification**: Hash-Check vor Speicherung in IndexedDB

### 3. Access Control
- ✅ **Server**: Prüft ob User zu Chat gehört (1:1 oder Gruppe)
- ✅ **Client**: Kann nur Files entschlüsseln mit korrektem Signal-Key
- ✅ **Seeder-Verifizierung**: Nur authentifizierte Nutzer

### 4. Privacy
- ✅ **Server kennt keine File-Inhalte**: Nur Metadaten
- ✅ **Chunks sind verschlüsselt**: Selbst bei Leak keine Lesbarkeit
- ✅ **No Plaintext Storage**: Chunks nur verschlüsselt in IndexedDB

### 5. DoS-Protection
- ✅ **Upload-Slots**: Max parallele Uploads pro Seeder (4-8)
- ✅ **File-TTL**: Auto-Cleanup nach 24h (konfigurierbar)
- ✅ **Max File Size**: Limit (z.B. 2 GB)
- ✅ **Rate Limiting**: Socket.IO Events throtteln

---

## 🚀 Implementierungs-Phasen

### Phase 1: Foundation (Woche 1)
**Ziel**: Basis-Infrastruktur ohne P2P

**Tasks**:
1. ✅ IndexedDB Schema erstellen
2. ✅ File-Chunking-Logik implementieren
3. ✅ File-Key Encryption/Decryption (AES-256)
4. ✅ Server: File Registry (In-Memory)
5. ✅ Socket.IO Events: `file:offer`, `file:available`
6. ✅ UI: File-Upload-Button in Chat

**Deliverable**: User kann File hochladen → Chunks in IndexedDB → Notification an Empfänger

### Phase 2: Basic Transfer (Woche 2)
**Ziel**: 1:1 File-Transfer ohne P2P (Server-vermittelt)

**Tasks**:
1. ✅ WebRTC DataChannel Setup (Point-to-Point)
2. ✅ Signaling über Socket.IO (offer/answer/ice)
3. ✅ Chunk-Download von einem Seeder
4. ✅ Entschlüsselung & Verifizierung
5. ✅ File-Assembly & Browser-Download
6. ✅ UI: Download-Progress-Bar

**Deliverable**: User A sendet File → User B lädt herunter über WebRTC

### Phase 3: Multi-Peer (Woche 3)
**Ziel**: Torrent-ähnlicher Download von mehreren Seedern

**Tasks**:
1. ✅ Seeder-Tracking im Server (chunk-Liste)
2. ✅ Leecher → Seeder Matching (Rarest-First-Strategie)
3. ✅ Parallele WebRTC-Connections
4. ✅ Chunk-Request-Pipelining
5. ✅ Automatic Seeding nach Download
6. ✅ UI: Seeder-Liste anzeigen

**Deliverable**: User B lädt Chunks von User A + User C parallel

### Phase 4: Gruppen-Support (Woche 4)
**Ziel**: File-Sharing in Signal-Gruppen

**Tasks**:
1. ✅ Integration mit Sender Key System
2. ✅ File-Key Distribution an Gruppe
3. ✅ Group-File-Registry im Server
4. ✅ UI: Group-File-List
5. ✅ Permissions: Nur Gruppe kann File entschlüsseln

**Deliverable**: File-Sharing in Gruppen-Chats

### Phase 5: Optimization (Woche 5+)
**Ziel**: Performance & UX-Verbesserungen

**Tasks**:
- ✅ Web Worker für Chunk-Processing
- ✅ Chunk-Caching-Strategien
- ✅ Resume interrupted downloads
- ✅ Bandwidth-Management
- ✅ UI: Drag & Drop
- ✅ Mobile-Support (Flutter native)
- ✅ Statistiken & Monitoring

---

## 🛠️ Technische Details

### WebRTC DataChannel Setup

```javascript
// 1. Create RTCPeerConnection
const pc = new RTCPeerConnection({
  iceServers: [
    { urls: 'stun:stun.l.google.com:19302' }
  ]
});

// 2. Create DataChannel
const dataChannel = pc.createDataChannel('file-transfer', {
  ordered: true,        // Chunks müssen in Reihenfolge ankommen
  maxRetransmits: 3     // Bei Packet-Loss
});

// 3. Signaling via Socket.IO
socket.on('file:webrtc-offer', async ({ offer, fromUserId, fromDeviceId }) => {
  await pc.setRemoteDescription(offer);
  const answer = await pc.createAnswer();
  await pc.setLocalDescription(answer);
  socket.emit('file:webrtc-answer', {
    answer,
    targetUserId: fromUserId,
    targetDeviceId: fromDeviceId
  });
});

// 4. ICE Candidates
pc.onicecandidate = (event) => {
  if (event.candidate) {
    socket.emit('file:webrtc-ice', {
      candidate: event.candidate,
      targetUserId: recipientUserId,
      targetDeviceId: recipientDeviceId
    });
  }
};

// 5. DataChannel Events
dataChannel.onopen = () => {
  console.log('[FILE-TRANSFER] DataChannel open');
};

dataChannel.onmessage = async (event) => {
  const chunk = JSON.parse(event.data);
  await handleIncomingChunk(chunk);
};
```

### Chunk-Download-Strategie

```javascript
// Rarest-First-Strategie (wie BitTorrent)
class DownloadManager {
  constructor(fileId, chunkCount, seeders) {
    this.fileId = fileId;
    this.chunkCount = chunkCount;
    this.seeders = seeders; // [{ userId, chunks: [...] }]
    this.downloadedChunks = new Set();
    this.pendingChunks = new Map(); // chunkIndex → seederId
  }
  
  // Bestimme seltensten Chunk
  getRarestChunk() {
    const chunkCounts = new Map();
    
    // Zähle wie oft jeder Chunk verfügbar ist
    for (const seeder of this.seeders) {
      for (const chunkIndex of seeder.chunks) {
        if (!this.downloadedChunks.has(chunkIndex) &&
            !this.pendingChunks.has(chunkIndex)) {
          chunkCounts.set(chunkIndex, (chunkCounts.get(chunkIndex) || 0) + 1);
        }
      }
    }
    
    // Finde Chunk mit niedrigster Verfügbarkeit
    let rarestChunk = null;
    let minCount = Infinity;
    
    for (const [chunkIndex, count] of chunkCounts) {
      if (count < minCount) {
        minCount = count;
        rarestChunk = chunkIndex;
      }
    }
    
    return rarestChunk;
  }
  
  // Wähle besten Seeder für Chunk
  selectSeederForChunk(chunkIndex) {
    const availableSeeders = this.seeders.filter(s =>
      s.chunks.includes(chunkIndex) &&
      s.activeUploads < s.uploadSlots
    );
    
    if (availableSeeders.length === 0) return null;
    
    // Wähle Seeder mit wenigsten aktiven Uploads
    return availableSeeders.reduce((best, current) =>
      current.activeUploads < best.activeUploads ? current : best
    );
  }
  
  // Starte parallele Downloads
  async startDownload() {
    const MAX_PARALLEL = 4; // Parallele Chunk-Downloads
    
    while (this.downloadedChunks.size < this.chunkCount) {
      // Starte neue Downloads bis MAX_PARALLEL erreicht
      while (this.pendingChunks.size < MAX_PARALLEL) {
        const chunkIndex = this.getRarestChunk();
        if (chunkIndex === null) break; // Keine Chunks verfügbar
        
        const seeder = this.selectSeederForChunk(chunkIndex);
        if (!seeder) break; // Kein Seeder verfügbar
        
        this.pendingChunks.set(chunkIndex, seeder.userId);
        this.requestChunk(seeder, chunkIndex);
      }
      
      // Warte auf nächsten Chunk-Download
      await this.waitForChunk();
    }
    
    console.log('[DOWNLOAD] File complete!');
  }
  
  async requestChunk(seeder, chunkIndex) {
    const dataChannel = this.getDataChannel(seeder.userId);
    
    dataChannel.send(JSON.stringify({
      type: 'chunk-request',
      fileId: this.fileId,
      chunkIndex: chunkIndex
    }));
  }
}
```

### File-Key-Distribution über Signal

```javascript
// Sender: Generiere und teile File-Key
async function shareFileKey(fileId, recipientUserId) {
  // 1. Generiere AES-256 Key
  const fileKey = await crypto.subtle.generateKey(
    { name: 'AES-GCM', length: 256 },
    true, // extractable
    ['encrypt', 'decrypt']
  );
  
  // 2. Exportiere Key
  const exportedKey = await crypto.subtle.exportKey('raw', fileKey);
  const keyBuffer = new Uint8Array(exportedKey);
  
  // 3. Verschlüssle mit Signal Session
  const recipientAddress = new libsignal.SignalProtocolAddress(
    recipientUserId,
    recipientDeviceId
  );
  
  const sessionCipher = new libsignal.SessionCipher(
    signalStore,
    recipientAddress
  );
  
  const encryptedKey = await sessionCipher.encrypt(keyBuffer.buffer);
  
  // 4. Sende über Socket
  socket.emit('file:offer', {
    fileId,
    fileName,
    fileSize,
    checksum,
    chunkCount,
    encryptedKey: btoa(String.fromCharCode(...new Uint8Array(encryptedKey.body)))
  });
  
  // 5. Speichere Key lokal
  await indexedDB.fileKeys.put({
    fileId,
    decryptedKey: keyBuffer
  });
}

// Empfänger: Entschlüssle File-Key
async function decryptFileKey(fileId, encryptedKeyBase64, senderUserId) {
  // 1. Decode Base64
  const encryptedKey = Uint8Array.from(
    atob(encryptedKeyBase64),
    c => c.charCodeAt(0)
  );
  
  // 2. Entschlüssle mit Signal Session
  const senderAddress = new libsignal.SignalProtocolAddress(
    senderUserId,
    senderDeviceId
  );
  
  const sessionCipher = new libsignal.SessionCipher(
    signalStore,
    senderAddress
  );
  
  const decryptedKey = await sessionCipher.decryptPreKeyWhisperMessage(
    encryptedKey.buffer,
    'binary'
  );
  
  // 3. Importiere als CryptoKey
  const fileKey = await crypto.subtle.importKey(
    'raw',
    decryptedKey,
    { name: 'AES-GCM' },
    true,
    ['encrypt', 'decrypt']
  );
  
  // 4. Speichere Key lokal
  await indexedDB.fileKeys.put({
    fileId,
    decryptedKey: new Uint8Array(decryptedKey)
  });
  
  return fileKey;
}
```

### Chunk-Verschlüsselung mit AES-GCM

```javascript
// Verschlüssle Chunk
async function encryptChunk(chunkData, fileKey) {
  const iv = crypto.getRandomValues(new Uint8Array(12)); // 96-bit IV für GCM
  
  const encryptedData = await crypto.subtle.encrypt(
    {
      name: 'AES-GCM',
      iv: iv,
      tagLength: 128 // 128-bit authentication tag
    },
    fileKey,
    chunkData
  );
  
  return {
    iv: iv,
    encryptedData: new Uint8Array(encryptedData)
  };
}

// Entschlüssle Chunk
async function decryptChunk(encryptedChunk, fileKey) {
  const decryptedData = await crypto.subtle.decrypt(
    {
      name: 'AES-GCM',
      iv: encryptedChunk.iv,
      tagLength: 128
    },
    fileKey,
    encryptedChunk.encryptedData
  );
  
  return new Uint8Array(decryptedData);
}

// Verifiziere Chunk-Hash
async function verifyChunkHash(chunkData, expectedHash) {
  const hashBuffer = await crypto.subtle.digest('SHA-256', chunkData);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  const computedHash = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
  
  return computedHash === expectedHash;
}
```

---

## 🎯 Performance-Optimierungen

### 1. Chunk-Size-Tuning
```javascript
// Optimal für WebRTC DataChannel
const OPTIMAL_CHUNK_SIZE = 64 * 1024; // 64 KB

// Zu klein: Viel Overhead
// Zu groß: Blockierung bei Packet-Loss
```

### 2. Pipelining
```javascript
// Nicht warten bis Chunk fertig, sondern mehrere parallel
const PIPELINE_DEPTH = 4; // 4 Chunks gleichzeitig

for (let i = 0; i < PIPELINE_DEPTH; i++) {
  requestNextChunk(); // Async
}
```

### 3. Web Worker für Crypto
```javascript
// chunk-worker.js
self.onmessage = async (e) => {
  const { action, data } = e.data;
  
  if (action === 'encrypt') {
    const encrypted = await encryptChunk(data.chunk, data.key);
    self.postMessage({ encrypted });
  } else if (action === 'decrypt') {
    const decrypted = await decryptChunk(data.chunk, data.key);
    self.postMessage({ decrypted });
  }
};

// Main Thread
const worker = new Worker('/chunk-worker.js');
worker.postMessage({ action: 'encrypt', data: { chunk, key } });
```

### 4. IndexedDB Batch-Writes
```javascript
// Nicht jeder Chunk einzeln, sondern batched
const BATCH_SIZE = 10;
let batchBuffer = [];

async function storeChunk(chunk) {
  batchBuffer.push(chunk);
  
  if (batchBuffer.length >= BATCH_SIZE) {
    await flushBatch();
  }
}

async function flushBatch() {
  const tx = db.transaction(['chunks'], 'readwrite');
  for (const chunk of batchBuffer) {
    tx.objectStore('chunks').put(chunk);
  }
  await tx.complete;
  batchBuffer = [];
}
```

---

## ❓ Offene Fragen

### 1. File-Size-Limit?
**Empfehlung**: 2 GB für Web, unbegrenzt für native App
- Web: IndexedDB Storage Quota (~50% freier Speicher)
- Native: Dateisystem-Limits

### 2. TTL für Files?
**✅ CONFIRMED**: 30 Tage (konfigurierbar)
- Nach 30 Tagen ohne Aktivität wird File vom Server entfernt
- "Aktivität" = Download-Anfrage ODER Uploader-Reannounce
- Clients können länger speichern (lokale Entscheidung)
- `lastActivity` wird bei jeder Download-Anfrage aktualisiert
- `lastUploadRequest` wird bei Uploader-Reannounce aktualisiert
- TTL-Reset wenn Uploader wieder online kommt

### 3. Max Seeders/Leechers?
**Empfehlung**: 
- Max 50 Seeders pro File (sonst Seeder-Liste zu groß)
- Unbegrenzt Leechers (werden zu Seedern)

### 4. Bandwidth-Management?
**Empfehlung**:
- Upload: Max 4-8 Slots pro Seeder
- Download: Max 4 parallele Chunks
- Optional: User-konfigurierbare Limits

### 5. Resume Downloads?
**Empfehlung**: Ja!
- Chunks in IndexedDB persistieren Status
- Bei Reconnect: Fortsetzen ab letztem Chunk

### 6. Mobile Data Warning?
**Empfehlung**: Ja!
- Bei Mobilfunk: Warnung vor großen Downloads
- Option: "Nur über WLAN"

---

## 📊 Monitoring & Telemetry

### Wichtige Metriken

```javascript
// Client-seitig
const metrics = {
  // Download-Performance
  downloadSpeed: 1.5 * 1024 * 1024, // bytes/s
  uploadSpeed: 0.5 * 1024 * 1024,
  avgChunkTime: 500, // ms
  
  // Chunk-Statistiken
  chunksDownloaded: 12,
  chunksTotal: 16,
  chunksVerified: 12,
  chunksFailed: 2,
  
  // Seeder-Statistiken
  activeSeeders: 3,
  totalSeeders: 5,
  bestSeeder: { userId: '...', speed: 2.5 * 1024 * 1024 },
  
  // WebRTC
  activeConnections: 3,
  connectionAttempts: 5,
  connectionFailures: 2,
  
  // Errors
  errors: [
    { type: 'CHUNK_HASH_MISMATCH', chunkIndex: 5 },
    { type: 'SEEDER_TIMEOUT', seederId: '...' }
  ]
};

// Server-seitig
const serverMetrics = {
  totalFiles: 1234,
  totalSeeders: 567,
  totalLeechers: 89,
  avgSeedersPerFile: 2.5,
  totalBytesTransferred: 1024 * 1024 * 1024 * 500, // 500 GB
  
  // Top Files
  topFiles: [
    { fileId: '...', name: 'video.mp4', downloads: 45 }
  ]
};
```

---

## 🔍 Testing-Strategie

### Unit Tests
```javascript
// chunk-manager.test.js
describe('ChunkManager', () => {
  test('splits file into correct number of chunks', () => {
    const fileSize = 1048576; // 1 MB
    const chunkSize = 64 * 1024; // 64 KB
    const chunkCount = Math.ceil(fileSize / chunkSize);
    expect(chunkCount).toBe(16);
  });
  
  test('encrypts and decrypts chunk correctly', async () => {
    const fileKey = await generateFileKey();
    const originalChunk = new Uint8Array([1, 2, 3, 4, 5]);
    
    const encrypted = await encryptChunk(originalChunk, fileKey);
    const decrypted = await decryptChunk(encrypted, fileKey);
    
    expect(decrypted).toEqual(originalChunk);
  });
  
  test('verifies chunk hash', async () => {
    const chunkData = new Uint8Array([1, 2, 3, 4, 5]);
    const hash = await computeChunkHash(chunkData);
    
    expect(await verifyChunkHash(chunkData, hash)).toBe(true);
    expect(await verifyChunkHash(new Uint8Array([1, 2, 3]), hash)).toBe(false);
  });
});
```

### Integration Tests
```javascript
// file-transfer.integration.test.js
describe('File Transfer Integration', () => {
  test('complete 1:1 file transfer', async () => {
    // Setup
    const sender = new FileTransferClient(userA);
    const receiver = new FileTransferClient(userB);
    
    // Upload file
    const fileId = await sender.uploadFile(testFile);
    
    // Receiver gets notification
    await receiver.waitForFileNotification(fileId);
    
    // Download file
    const downloadedFile = await receiver.downloadFile(fileId);
    
    // Verify
    expect(downloadedFile.checksum).toBe(testFile.checksum);
  });
  
  test('multi-peer download', async () => {
    // Setup 3 users
    const seederA = new FileTransferClient(userA);
    const seederB = new FileTransferClient(userB);
    const leecher = new FileTransferClient(userC);
    
    // Seeders upload file
    await seederA.uploadFile(testFile);
    await seederB.uploadFile(testFile);
    
    // Leecher downloads from both
    const download = leecher.downloadFile(fileId);
    
    // Verify chunks came from both seeders
    const chunkSources = await download.getChunkSources();
    expect(chunkSources).toContain(userA.id);
    expect(chunkSources).toContain(userB.id);
  });
});
```

### E2E Tests (Playwright/Cypress)
```javascript
// file-transfer.e2e.js
test('user can upload and download file', async ({ page }) => {
  // Login as User A
  await page.goto('/login');
  await loginAsUser(page, userA);
  
  // Open chat with User B
  await page.click('[data-test="chat-user-b"]');
  
  // Upload file
  await page.setInputFiles('[data-test="file-input"]', './test-files/document.pdf');
  await page.waitForSelector('[data-test="file-uploaded"]');
  
  // Login as User B (new context)
  const pageB = await browser.newPage();
  await pageB.goto('/login');
  await loginAsUser(pageB, userB);
  
  // Open chat with User A
  await pageB.click('[data-test="chat-user-a"]');
  
  // Wait for file notification
  await pageB.waitForSelector('[data-test="file-available"]');
  
  // Download file
  await pageB.click('[data-test="download-file"]');
  
  // Wait for download complete
  await pageB.waitForSelector('[data-test="download-complete"]');
  
  // Verify checksum
  const checksum = await pageB.getAttribute('[data-test="file-checksum"]', 'data-checksum');
  expect(checksum).toBe(expectedChecksum);
});
```

---

## 📝 Nächste Schritte

### ✅ Bestätigte Parameter:

1. **Chunk-Size**: 64 KB ✅ CONFIRMED
2. **File-Size-Limit**: 2 GB ✅ CONFIRMED
3. **TTL**: 30 Tage ✅ CONFIRMED (mit Auto-Reannounce)
4. **Upload-Slots**: 4-8 pro Seeder ✅
5. **Max Seeders**: 50 pro File ✅
6. **Privacy**: fileName/mimeType NICHT auf Server ✅
7. **Auto-Reannounce**: Uploader stellt File automatisch wieder bereit ✅

### Storage-Strategie:

#### Web:
- ✅ **IndexedDB** (via `idb_shim`) für Chunks
- ✅ **localStorage** (via `js` package) für einfache Flags
- ✅ Bereits vorhanden, keine neuen Dependencies

#### Native:
- ✅ **FlutterSecureStorage** für Metadaten & Keys
- 🔄 **path_provider + Dart File API** für Chunks (empfohlen)
  - Alternative: FlutterSecureStorage (funktioniert, aber langsamer)
- ⚠️ Neue Dependency: `path_provider: ^2.1.0` (empfohlen)

### Signal-Message-Format:

```dart
// Verschlüsselte Signal-Nachricht an Empfänger
{
  "type": "file-download-link",
  "fileId": "uuid-v4",
  "fileName": "document.pdf",           // ✅ Nur in Signal-Message
  "mimeType": "application/pdf",        // ✅ Nur in Signal-Message
  "fileSize": 1048576,
  "checksum": "sha256-hash",
  "chunkCount": 16,
  "encryptedKey": "base64...",          // File-Key (AES-256)
  "uploaderId": "user-uuid",
  "timestamp": 1698420000000
}
```

### Sofortige Entscheidungen benötigt:

### Weitere Informationen benötigt:

1. **Native Storage**:
   - ✅ FlutterSecureStorage vorhanden
   - ❓ Soll ich `path_provider` hinzufügen für bessere Performance?
   - Alternative: Nur FlutterSecureStorage (funktioniert, aber langsamer bei vielen Chunks)

2. **Signal Integration**:
   - ❓ Existiert Signal-Message-Type-System für Custom Messages?
   - ❓ Wie wird aktuell mit "unbekannten" Message-Types umgegangen?
   - ❓ Sender Key für Gruppen bereits implementiert?

3. **UI/UX Preferences**:
   - ❓ Material Design 3 Style?
   - ❓ Inline in Chat oder separates Modal für File-Transfer?
   - ❓ Notification-Strategie für "Uploader wieder online"?

4. **Auto-Reannounce Timing**:
   - ❓ Sofort beim Reconnect oder verzögert (z.B. 5 Sekunden)?
   - ❓ Batch-Reannounce oder einzeln pro File?

---

## 🎬 Zusammenfassung & Implementation Roadmap

### Was haben wir?
- ✅ Klare Architektur (P2P mit Server-Koordination)
- ✅ Sicherheitskonzept (AES + Signal für Key-Distribution)
- ✅ Chunk-System-Design (64KB Chunks, Rarest-First)
- ✅ Datenstrukturen (IndexedDB + Server Registry)
- ✅ Socket.IO Events-Spezifikation
- ✅ Implementierungs-Phasen (5 Wochen)
- ✅ **UX-Verbesserungen definiert** (siehe `P2P_USABILITY_IMPROVEMENTS.md`)
- ✅ **Alle kritischen Entscheidungen getroffen** (siehe `P2P_DECISIONS_TODO.md`)

### Entscheidungen Status
- ✅ Native Storage: **path_provider** + FlutterSecureStorage
- ✅ Signal Integration: **Neuer Type "file_share"** (Sender Key ready!)
- ✅ STUN/TURN: **Hybrid coturn** (eigener Server, 5€/Monat)
- ✅ Storage Quota: **2GB Web, 10GB Native** (Defaults)
- ✅ UI/UX Design: **WhatsApp-Style** mit Files-Page
- ✅ Alle niedrigen Prioritäten: **Defaults akzeptiert**

### 🚀 Finale Implementation Roadmap

#### **Phase 1: Foundation** (Woche 1-2)
**Ziel:** Basis-Infrastruktur ohne UI

**Backend:**
- [ ] File Registry (In-Memory Map)
- [ ] Socket.IO Events (file:offer, file:request-chunk)
- [ ] FileGarbageCollector (30-day TTL)
- [ ] **Server-Relay Fallback** 🔴
- [ ] **Server-Cache für kleine Files** 🟢

**Client:**
- [ ] Storage Layer (IndexedDB + path_provider)
- [ ] Chunking System (64 KB Chunks)
- [ ] AES-GCM Encryption
- [ ] File-Key Generation
- [ ] **Pause/Resume State Management** 🔴

**Deliverable:** Backend kann Chunks koordinieren, Client kann Files chunken & speichern

---

#### **Phase 2: P2P Transfer** (Woche 3-4)
**Ziel:** WebRTC DataChannel funktioniert

**Backend:**
- [ ] WebRTC Signaling (offer/answer/ice)
- [ ] Seeder/Leecher Tracking
- [ ] coturn Server deployen
- [ ] TURN Credentials Service

**Client:**
- [ ] WebRTC Manager
- [ ] DataChannel Setup
- [ ] Chunk Download (Single Seeder)
- [ ] Chunk Upload (Seeding)
- [ ] **ETA Calculator** 🟡
- [ ] **Auto-Resume nach Crash** 🟢

**Deliverable:** 1:1 File Transfer funktioniert (ohne UI)

---

#### **Phase 3: Signal Integration** (Woche 5)
**Ziel:** Files über Signal-Chats teilen

**Client:**
- [ ] Signal "file_share" Message Type
- [ ] File-Key Distribution (PreKey/Sender Key)
- [ ] Message Callback Handler
- [ ] **Preview/Thumbnail Generation** 🟡

**Deliverable:** User kann File in Chat teilen, andere sehen Link

---

#### **Phase 4: UI/UX** (Woche 6-7)
**Ziel:** Polierte User Experience

**Client UI:**
- [ ] Inline Upload Button (📎 wie WhatsApp)
- [ ] Expanded File-Message Card
- [ ] Floating Progress Overlay
- [ ] Files-Page (Dashboard Menü)
- [ ] **Uploader Status Widget** 🔴
- [ ] **Seeder-Benachrichtigungen** 🔴
- [ ] **Power Management Settings** 🟡
- [ ] **Background Mode Warning** 🟢

**Deliverable:** Vollständige UI wie geplant

---

#### **Phase 5: Multi-Seeder & Optimierung** (Woche 8-9)
**Ziel:** Torrent-ähnliche Features

**Client:**
- [ ] Parallel Download (mehrere Seeders)
- [ ] Rarest-First Strategy
- [ ] Chunk Pipelining
- [ ] Auto-Reannounce (bei Reconnect)
- [ ] Upload/Download Stats

**Backend:**
- [ ] Multi-Seeder Coordination
- [ ] Chunk-Availability Tracking
- [ ] Performance Monitoring

**Deliverable:** Production-ready P2P System

---

### 📊 Prioritäten-Übersicht

| Phase | Core Features | UX Improvements | Status |
|-------|---------------|-----------------|--------|
| 1 | Foundation | Pause/Resume 🔴, Server-Relay 🔴 | Ready to start |
| 2 | WebRTC | ETA 🟡, Auto-Resume 🟢 | Ready to start |
| 3 | Signal | Preview 🟡 | Ready to start |
| 4 | UI/UX | Status Widget 🔴, Notifications 🔴, Power 🟡 | Ready to start |
| 5 | Optimization | Auto-Reannounce | Ready to start |

**Legende:**
- 🔴 = Kritisch (MÜSSEN implementiert werden)
- 🟡 = Wichtig (SOLLTEN implementiert werden)
- 🟢 = Nice-to-Have (KÖNNEN implementiert werden)

---

### 🎯 Empfohlener Start

**Nächste Schritte (in Reihenfolge):**

1. **Dependencies hinzufügen**
   ```yaml
   # pubspec.yaml
   dependencies:
     path_provider: ^2.1.0
     image: ^4.1.3
     pdf_render: ^1.4.0
     video_thumbnail: ^0.5.3
     battery_plus: ^4.0.2
     connectivity_plus: ^5.0.1
   ```

2. **Storage Layer implementieren**
   - `client/lib/services/file_transfer/storage_interface.dart`
   - `client/lib/services/file_transfer/indexeddb_storage.dart`
   - `client/lib/services/file_transfer/secure_storage_manager.dart`

3. **Chunking System**
   - `client/lib/services/file_transfer/chunking_service.dart`
   - `client/lib/services/file_transfer/encryption_service.dart`

4. **Backend Foundation**
   - `server/lib/file-registry.js`
   - `server/routes/file-transfer.js`
   - `server/lib/file-cache.js` (Server-Cache)

5. **coturn deployen**
   ```bash
   cd server
   chmod +x coturn/setup.sh
   ./coturn/setup.sh
   docker-compose -f docker-compose.coturn.yml up -d
   ```

---

### ✅ Erfolgs-Kriterien

Nach vollständiger Implementation:

**Funktionalität:**
- ✅ User kann Files in 1:1 und Gruppen-Chats teilen
- ✅ P2P Transfer über WebRTC funktioniert
- ✅ 95%+ Erfolgsrate (mit Relay Fallback: 99%+)
- ✅ Pause/Resume ohne Datenverlust
- ✅ Multi-Seeder Support (Torrent-ähnlich)

**User Experience:**
- ✅ < 3 Sekunden von Upload-Click bis File geteilt
- ✅ Real-Time Progress mit ETA
- ✅ Thumbnails für Images/PDFs/Videos
- ✅ Benachrichtigungen wenn File verfügbar
- ✅ Uploader sieht wann er offline gehen kann

**Performance:**
- ✅ < 500ms Chunk-Download-Latenz
- ✅ < 20% CPU bei aktiven Transfers
- ✅ < 100 MB RAM-Verbrauch (Client)
- ✅ Funktioniert auf Low-End Mobile Devices

**Sicherheit:**
- ✅ E2E Verschlüsselung (AES-256-GCM)
- ✅ Signal Protocol für Key-Distribution
- ✅ Server kennt fileName/mimeType NICHT
- ✅ Chunk-Integrity mit SHA-256

---

## 🚀 LET'S BUILD IT!

Alle Entscheidungen getroffen ✅  
Alle Verbesserungen geplant ✅  
Dokumentation vollständig ✅  

**Bereit für Implementation!** 🎉
- Implementiere Phase 1+2 als MVP
- Sammle Feedback von echten Usern
- Iteriere basierend auf Learnings

---

## 🤔 Deine Meinung?

Welche Aspekte möchtest du als nächstes vertiefen?

1. **Code-Beispiele**: Konkrete Implementierung für spezifische Module?
2. **UI/UX Design**: Wireframes für File-Transfer-Interface?
3. **Signal Integration**: Deep-Dive in Key-Distribution?
4. **Performance**: Benchmarking-Strategie?
5. **Security Audit**: Penetration-Testing-Plan?
6. **Deployment**: Server-Scaling-Strategie?

Oder hast du spezifische Fragen zu bestimmten Aspekten? 🚀
