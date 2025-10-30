# P2P File Metadata Storage - SharedWith Architecture

**Date:** October 30, 2025  
**Status:** ✅ DOCUMENTED

## 📋 Overview

Dokumentation der lokalen Speicherung von `sharedWith` Informationen für P2P File Sharing, damit Seeder immer die aktuelle Zugriffsliste haben.

---

## 🗄️ Storage-Architektur

### Storage-Implementierungen:

1. **Web:** IndexedDB
2. **Native (Android/iOS):** path_provider + FlutterSecureStorage

### File Metadata Struktur:

```dart
class FileMetadata {
  final String fileId;              // Eindeutige File-ID
  final String fileName;            // Dateiname (verschlüsselt gespeichert)
  final String mimeType;            // MIME-Type
  final int fileSize;               // Dateigröße in Bytes
  final String checksum;            // SHA-256 Checksum
  final int chunkCount;             // Anzahl Chunks
  final String uploaderId;          // User-ID des Uploaders
  final DateTime createdAt;         // Erstellungszeitpunkt
  final String chatType;            // 'direct' | 'group'
  final String chatId;              // Chat-ID
  final String status;              // 'uploading' | 'uploaded' | 'downloading' | 'complete' | 'partial' | 'seeding'
  final bool isSeeder;              // Ist dieser User ein Seeder?
  final bool autoReannounce;        // Auto-reannounce beim Login?
  final DateTime? lastActivity;     // Letzte Aktivität
  final String? deletionReason;     // Löschgrund (falls gelöscht)
  
  // ✅ WICHTIG für P2P:
  final List<String> sharedWith;    // ← Liste der User-IDs mit Zugriff
  final int? lastSync;              // ← Letzter Sync mit Server (Timestamp in ms)
}
```

---

## 🔄 SharedWith Lifecycle

### 1. **Initial Upload**

**Wann:** Wenn User eine Datei hochlädt

```dart
// file_transfer_service.dart: uploadAndAnnounceFile()
await _storage.saveFileMetadata({
  'fileId': fileId,
  'fileName': fileName,
  // ...
  'sharedWith': sharedWith ?? [],  // ← Initiale Liste (kann leer sein)
  'status': 'uploaded',
});

// Auto-announce an Server
await _socketFileClient.announceFile(
  fileId: fileId,
  // ...
  sharedWith: sharedWith,  // ← Server erhält initiale Liste
);
```

**Resultat:**
- Lokal: `sharedWith` in IndexedDB/SecureStorage gespeichert
- Server: `sharedWith` in FileRegistry (In-Memory)

---

### 2. **Share mit neuem User (SIGNAL PROTOCOL SYNC)**

**Wann:** Creator teilt File mit zusätzlichem User

```dart
// file_transfer_service.dart: addUsersToShare()
// Step 1: Server update
await _socketFileClient.updateFileShare(
  fileId: fileId,
  action: 'add',
  userIds: ['newUser123'],
);

// Step 2: Get current sharedWith
final currentSharedWith = (metadata['sharedWith'] as List?)?.cast<String>() ?? [];

// Step 3: Signal Protocol Nachricht an ALLE Seeder (existing + new)
final allSeeders = {...currentSharedWith, ...userIds}.toList();

await _signalService.sendFileShareUpdate(
  chatId: chatId,
  chatType: chatType,
  fileId: fileId,
  action: 'add',
  affectedUserIds: allSeeders,  // ← ALLE Seeder (nicht nur neue!)
  // ...
);

// Step 4: Lokale Metadata aktualisieren
await _storage.updateFileMetadata(fileId, {
  'sharedWith': allSeeders,  // ← Lokale Liste aktualisiert
});
```

**Empfang bei anderen Seedern (z.B. Bob):**
```dart
// message_listener_service.dart: _handleGroupMessage()
if (action == 'add') {
  // Update local sharedWith from server
  final serverSharedWith = await fileTransferService.getServerSharedWith(fileId);
  await fileTransferService.updateFileMetadata(fileId, {
    'sharedWith': serverSharedWith,  // ← Server ist Source of Truth!
    'lastSync': DateTime.now().millisecondsSinceEpoch,
  });
}
```

**Resultat:**
- Lokal (Uploader): `sharedWith` enthält jetzt `['originalUser', 'newUser123']`
- Lokal (Andere Seeder): `sharedWith` **sofort** aktualisiert via Signal!
- Server: `sharedWith` Set aktualisiert
- Signal: Verschlüsselte Benachrichtigung an **ALLE** Seeder

**WICHTIG:** Alle **online** Seeder erhalten **echtzeitnahe** Updates!

---

### 3. **Re-Announce nach Login (FALLBACK SYNC)**

**Wann:** User loggt sich ein oder reconnected

```dart
// file_transfer_service.dart: reannounceUploadedFiles()
for (final file in uploadedFiles) {
  // Lokale sharedWith Liste laden
  final sharedWith = (file['sharedWith'] as List?)?.cast<String>() ?? [];
  
  // An Server senden
  await _socketFileClient.announceFile(
    fileId: fileId,
    // ...
    sharedWith: sharedWith.isNotEmpty ? sharedWith : null,  // ← Lokale Liste verwendet
  );
  
  // HIGH #2: Server-State zurück synchronisieren
  final fileInfo = await _socketFileClient.getFileInfo(fileId);
  final serverSharedWith = fileInfo['sharedWith'] ?? [];
  
  // Lokale Liste mit Server-Canonical-State aktualisieren
  await _storage.updateFileMetadata(fileId, {
    'sharedWith': serverSharedWith,  // ← Server ist Source of Truth
    'lastSync': DateTime.now().millisecondsSinceEpoch,
  });
}
```

**Wichtig:**
1. **Lokale Liste wird zuerst verwendet** für Re-Announce
2. **Dann wird Server-State zurückgelesen** (Canonical Source of Truth)
3. **Lokale Liste wird aktualisiert** mit Server-State

**Warum dieser 2-Schritt-Prozess?**
- **Problem:** Andere Seeder könnten offline sein und ihre Änderungen sind nur auf Server
- **Lösung:** Server merged alle Änderungen und gibt canonical state zurück
- **Garantie:** Nach Sync ist lokale Liste = Server-Liste

---

### 4. **Revoke User Access**

**Wann:** Creator entzieht User den Zugriff

```dart
// file_transfer_service.dart: revokeUsersFromShare()
// Step 1: Server update
await _socketFileClient.updateFileShare(
  fileId: fileId,
  action: 'revoke',
  userIds: ['removedUser'],
);

// Step 2: Signal Protocol Nachricht an entfernte User
await _signalService.sendFileShareUpdate(...);

// Step 3: Lokale Metadata aktualisieren
final currentSharedWith = metadata['sharedWith'] ?? [];
final updatedSharedWith = currentSharedWith
  .where((id) => !userIds.contains(id))
  .toList();

await _storage.updateFileMetadata(fileId, {
  'sharedWith': updatedSharedWith,  // ← User entfernt
});
```

---

## 🔒 Server ist Source of Truth

### Problem-Szenario ohne Sync:

```
Timeline:
t0: Alice uploaded file.pdf, sharedWith: [Alice, Bob]

t1: Alice disconnected
t2: Bob (via UI) teilt mit Charlie
    → Server: sharedWith = [Alice, Bob, Charlie]
    → Alice lokal: sharedWith = [Alice, Bob]  ❌ Veraltet!

t3: Alice reconnected
    → Alice re-announced mit [Alice, Bob]
    
t4 (OHNE SYNC):
    → Server überschreibt mit [Alice, Bob]
    → Charlie verliert Zugriff!  ❌❌❌
```

### Lösung mit HIGH #2 Sync:

```
Timeline:
t0-t2: Gleich wie oben

t3: Alice reconnected
    → Alice re-announced mit [Alice, Bob] (lokale Liste)
    → Server MERGED mit existing [Alice, Bob, Charlie]
    → Alice fragt Server: getFileInfo()
    → Server antwortet: sharedWith = [Alice, Bob, Charlie]
    → Alice updated lokal: sharedWith = [Alice, Bob, Charlie]  ✅

t4 (MIT SYNC):
    → Alice hat korrekte Liste
    → Charlie behält Zugriff  ✅✅✅
```

---

## 📊 Storage-Locations

### Web (IndexedDB):

```javascript
// Database: "PeerWaveFileStorage"
// ObjectStore: "files"

{
  fileId: "abc-123-def",
  fileName: "document.pdf",
  // ...
  sharedWith: ["user-1", "user-2", "user-3"],
  lastSync: 1730304000000,  // Unix timestamp in ms
  // ...
}
```

**Zugriff:**
```dart
final db = await window.indexedDB.open('PeerWaveFileStorage');
final tx = db.transaction(['files'], 'readonly');
final store = tx.objectStore('files');
final request = store.get(fileId);
final metadata = await request.complete;
final sharedWith = metadata['sharedWith'];
```

---

### Native (Flutter Secure Storage):

```dart
// Key: "file_metadata_${fileId}"
// Value: JSON String

{
  "fileId": "abc-123-def",
  "fileName": "document.pdf",
  // ...
  "sharedWith": ["user-1", "user-2", "user-3"],
  "lastSync": 1730304000000,
  // ...
}
```

**Zugriff:**
```dart
final storage = FlutterSecureStorage();
final jsonString = await storage.read(key: 'file_metadata_$fileId');
final metadata = jsonDecode(jsonString);
final sharedWith = (metadata['sharedWith'] as List).cast<String>();
```

---

## 🎯 Garantien

### Was wird garantiert:

1. ✅ **Persistenz:** `sharedWith` überlebt App-Restart und Browser-Reload
2. ✅ **Konsistenz:** Nach Re-Announce + Sync ist lokale Liste = Server-Liste
3. ✅ **Merge:** Server merged Änderungen von allen Seeders
4. ✅ **Encryption:** In SecureStorage verschlüsselt gespeichert (Native)
5. ✅ **Timestamps:** `lastSync` tracked letzten Sync-Zeitpunkt

### Was wird NICHT garantiert:

1. ❌ **Real-time Sync:** Änderungen werden nur bei Re-Announce synchronisiert
2. ❌ **Offline Änderungen:** Änderungen während Offline gehen verloren (Server wins)
3. ❌ **Konflikt-Auflösung:** Bei Konflikten gewinnt Server (keine CRDT)

---

## 🔄 Update-Flow Diagramm

```
┌─────────────────────────────────────────────────────────────┐
│                    CLIENT (Alice)                            │
├─────────────────────────────────────────────────────────────┤
│  IndexedDB / Secure Storage                                 │
│  ┌────────────────────────────────────┐                     │
│  │ File Metadata                      │                     │
│  │ - fileId: "abc-123"                │                     │
│  │ - sharedWith: [Alice, Bob]        │ ← Lokal gespeichert │
│  │ - lastSync: 1730304000000         │                     │
│  └────────────────────────────────────┘                     │
│                    ↓                                         │
│  FileTransferService.reannounceUploadedFiles()             │
│                    ↓                                         │
│  announceFile(sharedWith: [Alice, Bob]) ───────────────────→│
└─────────────────────────────────────────────────────────────┘
                             │
                             ↓
┌─────────────────────────────────────────────────────────────┐
│                    SERVER (Node.js)                          │
├─────────────────────────────────────────────────────────────┤
│  FileRegistry (In-Memory)                                   │
│  ┌────────────────────────────────────┐                     │
│  │ File Entry                         │                     │
│  │ - fileId: "abc-123"                │                     │
│  │ - sharedWith: Set[Alice, Bob, Charlie] ← MERGED!        │
│  │ - creator: Alice                   │                     │
│  └────────────────────────────────────┘                     │
│                    ↓                                         │
│  getFileInfo(fileId) ←──────────────────────────────────────│
│                    ↓                                         │
│  Returns: { sharedWith: [Alice, Bob, Charlie] } ────────────→│
└─────────────────────────────────────────────────────────────┘
                             │
                             ↓
┌─────────────────────────────────────────────────────────────┐
│                    CLIENT (Alice)                            │
├─────────────────────────────────────────────────────────────┤
│  updateFileMetadata(fileId, {                               │
│    sharedWith: [Alice, Bob, Charlie],  ← Server-State      │
│    lastSync: NOW                                            │
│  })                                                          │
│                    ↓                                         │
│  ┌────────────────────────────────────┐                     │
│  │ File Metadata (UPDATED)            │                     │
│  │ - sharedWith: [Alice, Bob, Charlie]│ ← Jetzt korrekt!  │
│  │ - lastSync: 1730304123456         │                     │
│  └────────────────────────────────────┘                     │
└─────────────────────────────────────────────────────────────┘
```

---

## 🧪 Testing

### Test 1: Lokale Speicherung
```dart
// Upload file
await fileTransferService.uploadAndAnnounceFile(
  fileBytes: bytes,
  fileName: 'test.pdf',
  mimeType: 'application/pdf',
  sharedWith: ['user1', 'user2'],
);

// Verify local storage
final metadata = await storage.getFileMetadata(fileId);
expect(metadata['sharedWith'], equals(['user1', 'user2']));
```

### Test 2: Re-Announce mit Sync
```dart
// Simulate offline changes on server
// (Another seeder added 'user3')

// Re-announce
await fileTransferService.reannounceUploadedFiles();

// Verify local list is updated
final metadata = await storage.getFileMetadata(fileId);
expect(metadata['sharedWith'], equals(['user1', 'user2', 'user3']));
expect(metadata['lastSync'], isNotNull);
```

### Test 3: Share und Revoke
```dart
// Add user
await fileTransferService.addUsersToShare(
  fileId: fileId,
  userIds: ['user4'],
  // ...
);

final metadata1 = await storage.getFileMetadata(fileId);
expect(metadata1['sharedWith'], contains('user4'));

// Revoke user
await fileTransferService.revokeUsersFromShare(
  fileId: fileId,
  userIds: ['user4'],
  // ...
);

final metadata2 = await storage.getFileMetadata(fileId);
expect(metadata2['sharedWith'], isNot(contains('user4')));
```

---

## 📝 Zusammenfassung

### ✅ sharedWith wird gespeichert in:

1. **Lokal (Client):**
   - Web: IndexedDB (`PeerWaveFileStorage` → `files` ObjectStore)
   - Native: FlutterSecureStorage (verschlüsselt)
   - Als Teil der `FileMetadata` Struktur
   - Inklusive `lastSync` Timestamp

2. **Server (Canonical):**
   - In-Memory FileRegistry
   - Als Set (keine Duplikate)
   - Merged von allen Seeders

### 🔄 Synchronisations-Strategie:

1. **Upload:** Client → Server (initiale Liste)
2. **Share/Revoke:** Client → Server → Client (update)
3. **Re-Announce:** Client (lokale Liste) → Server → Client (sync back)

### 🎯 Server ist Source of Truth:
- Alle Änderungen werden über Server gemacht
- Bei Re-Announce wird Server-State zurückgelesen
- Garantiert Konsistenz zwischen allen Seeders

---

**Status:** ✅ PRODUCTION READY  
**Documentation:** Complete  
**Storage Schema:** Defined in `storage_interface.dart`
