# Phase 2 Implementation: P2P Transfer & UI

**Ziel**: WebRTC DataChannel Setup + File-Transfer UI + Basic Download Flow

**Geschätzte Zeit**: 8-10 Stunden

---

## ✅ Prerequisites (aus Phase 1)
- ✅ Storage Layer (IndexedDB + Native)
- ✅ Chunking Service (64KB chunks)
- ✅ Encryption Service (AES-GCM)
- ✅ Download Manager (mit Pause/Resume)
- ✅ File Registry (Backend)
- ✅ Socket.IO Events (Backend)

---

## 📋 Phase 2 Steps

### **Step 1: WebRTC Service** (2h)
**File**: `client/lib/services/file_transfer/webrtc_service.dart`

**Implementierung**:
- RTCPeerConnection Setup
- DataChannel Creation
- ICE Candidate Handling
- Signaling via Socket.IO
- Connection State Management

**Dependencies**:
```yaml
flutter_webrtc: ^0.11.0  # WebRTC für Flutter
```

---

### **Step 2: P2P Coordinator** (2h)
**File**: `client/lib/services/file_transfer/p2p_coordinator.dart`

**Implementierung**:
- Seeder Discovery
- WebRTC Connection Pool
- Chunk Request Manager
- Multi-Source Download Logic
- Bandwidth Distribution

**Aufgaben**:
- Socket.IO Integration (File Registry queries)
- WebRTC Connection Setup per Seeder
- Chunk Request Queue Management
- Parallel Downloads koordinieren

---

### **Step 3: Socket.IO Client Integration** (1.5h)
**File**: `client/lib/services/file_transfer/socket_file_client.dart`

**Implementierung**:
- Wrapper für P2P File Events
- `announceFile()` - File verfügbar machen
- `searchFiles()` - Files finden
- `getFileInfo()` - Metadaten abrufen
- `registerLeecher()` - Download starten
- Event Listeners für Updates

**Integration**:
- Nutzt existierenden Socket.IO Service
- Adds P2P-specific events

---

### **Step 4: File Upload UI** (1.5h)
**File**: `client/lib/screens/file_transfer/file_upload_screen.dart`

**Features**:
- File Picker (image/video/document)
- Preview Generation (thumbnails)
- Upload Progress
- Chunking Progress
- Encryption Progress
- Announce to Network

**Widget Structure**:
```
FileUploadScreen
├── FilePicker (image_picker package)
├── PreviewWidget (thumbnail)
├── ProgressIndicator (chunking)
├── ProgressIndicator (encryption)
├── UploadButton
└── StatusText
```

---

### **Step 5: File Browser UI** (2h)
**File**: `client/lib/screens/file_transfer/file_browser_screen.dart`

**Features**:
- Available Files List (from network)
- Search Bar
- File Details (name, size, seeders)
- Download Button
- Seeder Count Badge

**Widget Structure**:
```
FileBrowserScreen
├── SearchBar
├── ListView<FileItem>
│   ├── FileIcon (mime type)
│   ├── FileName
│   ├── FileSize
│   ├── SeederCount
│   └── DownloadButton
└── RefreshIndicator
```

---

### **Step 6: Download Progress UI** (1.5h)
**File**: `client/lib/screens/file_transfer/downloads_screen.dart`

**Features**:
- Active Downloads List
- Progress Bar per File
- Pause/Resume Buttons
- Cancel Button
- Speed & ETA Display
- Seeder List per File

**Widget Structure**:
```
DownloadsScreen
├── ListView<DownloadItem>
│   ├── FileName
│   ├── ProgressBar (chunk-based)
│   ├── SpeedText (MB/s)
│   ├── ETAText
│   ├── SeederChips (connected seeders)
│   └── ActionButtons (Pause/Resume/Cancel)
└── CompletedSection
```

---

### **Step 7: WebRTC Signaling (Backend)** (0.5h)
**File**: `server/server.js` (erweitern)

**Neue Events**:
- `file:webrtc-offer` - WebRTC Offer weiterleiten
- `file:webrtc-answer` - WebRTC Answer weiterleiten
- `file:webrtc-ice` - ICE Candidates weiterleiten
- `file:chunk-request` - Chunk-Request an Seeder
- `file:chunk-response` - Chunk-Response an Leecher

**Implementierung**:
- Simple Message Relay (User A → Server → User B)
- No data modification, pure signaling

---

### **Step 8: Integration & Testing** (1.5h)

**Tasks**:
1. Provider Setup (DownloadManager, P2PCoordinator)
2. Navigation Integration (neue Screens)
3. Permissions (File Picker, Storage)
4. Error Handling
5. Logging & Debugging

**Test-Flow**:
1. User A: Upload File → Chunking → Encryption → Announce
2. User B: Browse Files → See User A's File
3. User B: Download → WebRTC Connect → Receive Chunks
4. User B: Verify → Decrypt → Save
5. User B: Becomes Seeder

---

## 🎯 Deliverables

Nach Phase 2:
- ✅ WebRTC DataChannel funktioniert
- ✅ User kann Files hochladen & ankündigen
- ✅ User kann verfügbare Files sehen
- ✅ User kann Files herunterladen (1:1 WebRTC)
- ✅ UI zeigt Progress, Speed, Seeders
- ✅ Pause/Resume funktioniert

---

## 🚀 Nächste Schritte

**Phase 3** (später):
- Multi-Seeder Downloads (parallele Connections)
- Rarest-First Chunk Selection
- Automatic Re-Announce (Auto-Seeding)
- Bandwidth Management

**Phase 4** (später):
- Group File Sharing
- Sender Key Integration
- Group File Registry

---

## 📦 Zusätzliche Dependencies

```yaml
# client/pubspec.yaml
dependencies:
  flutter_webrtc: ^0.11.0        # WebRTC Support
  file_picker: ^8.0.0            # File Selection
  image_picker: ^1.1.0           # Image/Video Selection
  mime: ^2.0.0                   # MIME Type Detection
  path: ^1.9.0                   # Path utilities
```

---

**Bereit zu starten?** Los geht's mit **Step 1: WebRTC Service**! 🚀
