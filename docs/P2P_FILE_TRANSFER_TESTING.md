# P2P File Transfer - Testing Guide

## 🚀 Quick Start

### 1. Access the File Transfer Hub

Nach dem Login gib diese URL im Browser ein:

```
http://localhost:3000/file-transfer
```

Dies öffnet den **P2P File Sharing Hub** mit drei Optionen:
- 📤 **Upload File** - Eine Datei hochladen und teilen
- 📁 **Browse Files** - Verfügbare Dateien entdecken
- 📥 **Downloads** - Aktive Downloads überwachen

---

## 🧪 Test-Szenarien

### Szenario 1: Einzelner Benutzer - Upload & Browse

1. **Öffne Browser 1** (z.B. Chrome):
   - Login: `http://localhost:3000/login`
   - Navigiere zu: `http://localhost:3000/file-transfer`

2. **Upload File**:
   - Klicke "Upload File"
   - Wähle eine kleine Datei (< 10 MB empfohlen)
   - Beobachte den Progress:
     - Chunking (0-20%)
     - Encryption (20-80%)
     - Storage (80-100%)
     - Network Announcement (100%)

3. **Browse Files**:
   - Gehe zurück zur Hub-Seite
   - Klicke "Browse Files"
   - Du solltest deine hochgeladene Datei sehen mit:
     - ✅ Seeder Badge (1 Seeder - du selbst)
     - Dateiname, Größe, MIME-Type

---

### Szenario 2: Zwei Benutzer - P2P Download

**⚠️ WICHTIG**: Aktuell ist die **File Key Distribution** noch nicht implementiert.  
Der Download wird mit einem Fehler enden, aber du kannst die UI und WebRTC-Verbindung testen.

1. **Browser 1 (User A)**:
   - Login als User A
   - `http://localhost:3000/file-transfer`
   - Upload eine Datei (wie in Szenario 1)

2. **Browser 2 (User B)** (Inkognito/anderer Browser):
   - Login als User B
   - `http://localhost:3000/file-transfer`
   - Klicke "Browse Files"
   - Du solltest User A's Datei sehen (1 Seeder)

3. **Download starten (User B)**:
   - Klicke auf die Datei → "Details"
   - Klicke "Download"
   - **Erwartetes Verhalten**:
     - ✅ Download registriert
     - ✅ WebRTC Signaling startet
     - ❌ Error: "File key distribution needed"
   
   - In Browser Console siehst du:
     ```
     [P2P WEBRTC] Relaying offer for file...
     [P2P WEBRTC] Relaying ICE candidate...
     ```

4. **Downloads Screen (User B)**:
   - `http://localhost:3000/downloads`
   - Siehst du den Download mit Status "Failed" oder "Queued"

---

## 📋 UI-Features zum Testen

### Upload Screen (`/file-upload`)
- ✅ File Picker (Drag & Drop + Click)
- ✅ File Preview (Name, Size, Type Icon)
- ✅ Multi-Stage Progress Bar
- ✅ Stage Indicators (Chunking ✓, Encryption ✓, Storage ✓, Announce ✓)
- ✅ Success Message
- ✅ Cancel Button

### Browse Screen (`/file-browser`)
- ✅ Search Bar (sucht nach Dateinamen)
- ✅ File List Cards:
  - File Icon (basierend auf MIME-Type)
  - Filename, Size
  - Seeder Badge
  - Download Button
- ✅ File Details Modal:
  - File Info (Size, Type, Chunks)
  - Seeder List
  - Download Button
- ✅ Refresh Button
- ✅ Empty State (wenn keine Dateien)
- ✅ "Upload File" Link

### Downloads Screen (`/downloads`)
- ✅ Empty State mit "Browse Files" Link
- ✅ Active/Paused/Completed Sections
- ✅ Per-File Cards:
  - Progress Bar
  - Status Badge
  - Speed & ETA
  - Connected Seeders Chips
  - Pause/Resume/Cancel Buttons
- ✅ File Type Icons

---

## 🐛 Debugging

### Browser Console aktivieren:
- **Chrome**: F12 oder Rechtsklick → Inspect → Console
- **Firefox**: F12 → Console

### Wichtige Log-Ausgaben:

**Backend (Docker Logs)**:
```powershell
docker-compose logs -f
```
Achte auf:
- `[P2P FILE] User ... announcing file: ...`
- `[P2P WEBRTC] Relaying offer/answer/ICE...`

**Frontend (Browser Console)**:
Achte auf:
- Socket.IO connection status
- File upload progress
- WebRTC signaling events
- Download manager status

---

## ⚙️ Bekannte Einschränkungen

### 1. File Key Distribution fehlt ❌
**Problem**: Encryption keys werden nicht zwischen Peers geteilt.  
**Auswirkung**: Downloads können nicht entschlüsselt werden.  
**Workaround**: Für Phase 3 geplant.

**Manueller Test (nur für Entwicklung)**:
Temporär kannst du die Encryption in `file_upload_screen.dart` deaktivieren:
```dart
// Zeile ~328: Kommentiere die Encryption aus
// final fileKey = encryptionService.generateKey();
// ... encryption code ...
```

### 2. WebRTC Chunk Transfer nicht implementiert ❌
**Problem**: `P2PCoordinator._requestChunkFromPeer()` wirft `UnimplementedError`.  
**Auswirkung**: Chunks werden nicht über WebRTC DataChannel gesendet.  
**Workaround**: Muss noch implementiert werden.

### 3. Storage Initialization
**Problem**: `fileStorage.initialize()` wird in `main.dart` aufgerufen, aber Fehlerbehandlung fehlt.  
**Auswirkung**: Bei Storage-Fehlern könnte die App crashen.  
**Workaround**: Browser-Console auf IndexedDB-Fehler prüfen.

---

## ✅ Was funktioniert

- ✅ File Upload mit Chunking & Encryption
- ✅ File Announcement an Network
- ✅ File Registry (Backend)
- ✅ File Discovery & Search
- ✅ WebRTC Signaling Relay (Backend)
- ✅ Download Manager UI
- ✅ Progress Tracking
- ✅ Provider/DI Setup
- ✅ Navigation & Routing
- ✅ All UI Screens

---

## 🎯 Nächste Schritte

### Phase 3 - Verbleibende Features:
1. **File Key Distribution** (kritisch für Downloads)
   - Option A: Sender Key System nutzen (für Gruppen)
   - Option B: RSA Public/Private Key Encryption
   - Option C: Via encrypted Socket.IO Nachricht

2. **WebRTC Chunk Transfer Implementation**
   - Binary chunk sending via RTCDataChannel
   - Chunk verification & retries

3. **Integration Testing**
   - End-to-End Upload → Download Flow
   - Multi-seeder scenarios
   - Network error handling

---

## 📞 Support

Bei Problemen:
1. Check Browser Console für Errors
2. Check `docker-compose logs -f` für Backend-Logs
3. Prüfe ob Socket.IO connected ist
4. Prüfe ob IndexedDB funktioniert (Application → Storage → IndexedDB)

## 🎉 Happy Testing!
