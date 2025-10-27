# 🚀 PHASE 1 IMPLEMENTATION - Storage & Foundation

**Status:** Bereit zu starten  
**Datum:** 27. Oktober 2025  
**Ziel:** Basis-Infrastruktur für P2P File Sharing

---

## 📋 Phase 1 Übersicht (Woche 1-2)

**Deliverable:** Backend kann Chunks koordinieren, Client kann Files chunken & speichern

### Backend Tasks
- [ ] File Registry (In-Memory Map)
- [ ] Socket.IO Events (file:offer, file:request-chunk)
- [ ] FileGarbageCollector (30-day TTL)
- [ ] **Server-Relay Fallback** 🔴
- [ ] **Server-Cache für kleine Files** 🟢

### Client Tasks
- [ ] Storage Layer (IndexedDB + path_provider)
- [ ] Chunking System (64 KB Chunks)
- [ ] AES-GCM Encryption
- [ ] File-Key Generation
- [ ] **Pause/Resume State Management** 🔴

---

## 🎯 Step-by-Step Implementation Plan

### Step 1: Dependencies hinzufügen (10 Min)

```bash
# Im client/ Verzeichnis
cd client
flutter pub add path_provider image pdf_render video_thumbnail battery_plus connectivity_plus crypto

# pubspec.yaml sollte dann enthalten:
# path_provider: ^2.1.0
# image: ^4.1.3
# pdf_render: ^1.4.0
# video_thumbnail: ^0.5.3
# battery_plus: ^4.0.2
# connectivity_plus: ^5.0.1
# crypto: ^3.0.3 (für SHA-256)
```

### Step 2: Storage Interface erstellen (30 Min)

**Datei:** `client/lib/services/file_transfer/storage_interface.dart`

```dart
abstract class FileStorageInterface {
  // File Metadaten
  Future<void> saveFileMetadata(Map<String, dynamic> metadata);
  Future<Map<String, dynamic>?> getFileMetadata(String fileId);
  Future<List<Map<String, dynamic>>> getAllFiles();
  Future<void> deleteFile(String fileId);
  
  // Chunks
  Future<void> saveChunk(String fileId, int chunkIndex, Uint8List data);
  Future<Uint8List?> getChunk(String fileId, int chunkIndex);
  Future<void> deleteChunk(String fileId, int chunkIndex);
  Future<List<int>> getAvailableChunks(String fileId);
  
  // File-Keys
  Future<void> saveFileKey(String fileId, Uint8List key);
  Future<Uint8List?> getFileKey(String fileId);
}
```

### Step 3: IndexedDB Storage implementieren (1-2 Std)

**Datei:** `client/lib/services/file_transfer/indexeddb_storage.dart`

- ObjectStore: `files` (fileId, fileName, fileSize, etc.)
- ObjectStore: `chunks` (fileId+chunkIndex, encryptedData, iv, hash)
- ObjectStore: `fileKeys` (fileId, encryptedKey)

### Step 4: Native Storage implementieren (1-2 Std)

**Datei:** `client/lib/services/file_transfer/native_storage.dart`

- FlutterSecureStorage für Metadaten + Keys
- path_provider für Chunk-Dateien
- Verzeichnisstruktur: `<app_docs>/file_chunks/<fileId>/chunk_<index>.enc`

### Step 5: Chunking Service erstellen (2 Std)

**Datei:** `client/lib/services/file_transfer/chunking_service.dart`

```dart
class ChunkingService {
  static const int CHUNK_SIZE = 64 * 1024; // 64 KB
  
  Future<List<Uint8List>> splitFileIntoChunks(Uint8List fileData);
  Future<Uint8List> assembleChunksIntoFile(List<Uint8List> chunks);
  String calculateChunkHash(Uint8List chunk); // SHA-256
  String calculateFileChecksum(Uint8List fileData); // SHA-256
}
```

### Step 6: Encryption Service erstellen (2 Std)

**Datei:** `client/lib/services/file_transfer/encryption_service.dart`

```dart
class EncryptionService {
  // File-Key Generation
  Uint8List generateFileKey(); // 256-bit AES key
  
  // AES-GCM Encryption
  Future<Map<String, dynamic>> encryptChunk(Uint8List chunk, Uint8List fileKey);
  Future<Uint8List> decryptChunk(Uint8List encryptedChunk, Uint8List iv, Uint8List fileKey);
}
```

### Step 7: Backend File Registry (2 Std)

**Datei:** `server/store/fileRegistry.js`

```javascript
class FileRegistry {
  constructor() {
    this.files = new Map(); // fileId -> FileEntry
  }
  
  addFile(fileId, metadata) { }
  getFile(fileId) { }
  updateSeeders(fileId, userId, deviceId, chunks) { }
  removeSeedder(fileId, userId, deviceId) { }
  cleanup() { } // Remove expired files
}
```

### Step 8: Socket.IO Events (Backend, 2 Std)

**Datei:** `server/server.js` (erweitern)

Implementiere Events:
- `file:offer` - Client bietet File an
- `file:update-chunks` - Chunk-Status Update
- `file:request-seeders` - Seeder-Liste anfragen
- `file:available` - Server notified über neues File

### Step 9: Download Manager mit Pause/Resume (3 Std)

**Datei:** `client/lib/services/file_transfer/download_manager.dart`

```dart
class DownloadManager {
  Map<String, DownloadState> _activeDownloads = {};
  
  Future<void> startDownload(String fileId);
  Future<void> pauseDownload(String fileId);
  Future<void> resumeDownload(String fileId);
  Future<void> cancelDownload(String fileId);
  
  // State Persistence
  Future<void> _saveDownloadState(String fileId);
  Future<void> _loadDownloadState(String fileId);
}
```

---

## 🧪 Testing Checklist

### Storage Tests
- [ ] IndexedDB: File speichern & laden
- [ ] IndexedDB: Chunk speichern & laden
- [ ] IndexedDB: File löschen (cascading chunks)
- [ ] Native: Chunk-Dateien erstellen
- [ ] Native: Metadaten in FlutterSecureStorage
- [ ] Native: Verzeichnis-Cleanup

### Chunking Tests
- [ ] 1 MB File → 16 Chunks (64 KB)
- [ ] 100 KB File → 2 Chunks (64KB + 36KB)
- [ ] Chunk-Hash Verifikation (SHA-256)
- [ ] File-Checksum Verifikation

### Encryption Tests
- [ ] File-Key Generation (256-bit)
- [ ] Chunk Encryption (AES-GCM)
- [ ] Chunk Decryption + IV
- [ ] Encrypted Chunk-Größe (~64KB + overhead)

### Backend Tests
- [ ] File Registry: addFile()
- [ ] File Registry: updateSeeders()
- [ ] File Registry: getFile()
- [ ] Socket.IO: file:offer Event
- [ ] Socket.IO: file:request-seeders Event

---

## 📁 Neue Dateien (Phase 1)

```
client/lib/services/file_transfer/
├── storage_interface.dart           # Abstract Interface
├── indexeddb_storage.dart          # Web Implementation
├── native_storage.dart             # Mobile/Desktop Implementation
├── chunking_service.dart           # 64KB Chunking
├── encryption_service.dart         # AES-GCM
├── download_manager.dart           # Pause/Resume
└── file_key_generator.dart         # 256-bit Keys

server/
├── store/
│   └── fileRegistry.js             # In-Memory File Registry
└── lib/
    └── file-coordinator.js         # Seeder/Leecher Management
```

---

## ⏱️ Zeitplan

| Task | Aufwand | Status |
|------|---------|--------|
| Dependencies | 10 Min | ⬜ |
| Storage Interface | 30 Min | ⬜ |
| IndexedDB Storage | 2 Std | ⬜ |
| Native Storage | 2 Std | ⬜ |
| Chunking Service | 2 Std | ⬜ |
| Encryption Service | 2 Std | ⬜ |
| File Registry (Backend) | 2 Std | ⬜ |
| Socket.IO Events | 2 Std | ⬜ |
| Download Manager | 3 Std | ⬜ |
| Testing | 2 Std | ⬜ |
| **TOTAL** | **~19 Std** | **0%** |

---

## 🎯 Definition of Done

Phase 1 ist abgeschlossen wenn:

✅ **Client:**
- IndexedDB speichert Files + Chunks (Web)
- path_provider speichert Chunks (Native)
- Files werden in 64KB Chunks aufgeteilt
- Chunks werden mit AES-GCM verschlüsselt
- SHA-256 Hashes für Chunk-Verifikation
- Download kann pausiert & resumed werden

✅ **Backend:**
- FileRegistry speichert File-Metadaten
- Socket.IO Events funktionieren
- Seeder können registriert werden
- Cleanup-Job läuft

✅ **Integration:**
- Client kann File-Metadaten an Server senden
- Server tracked Seeders
- Client kann Seeder-Liste abrufen

---

## 🚦 Nächste Schritte nach Phase 1

**Phase 2 (Woche 3-4): P2P Transfer**
- WebRTC Signaling
- DataChannel Setup
- Chunk Download von Seeder
- coturn Integration

**Bereit zu starten?** Los geht's mit Step 1! 🚀
