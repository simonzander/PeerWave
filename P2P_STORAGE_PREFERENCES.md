# Storage-Präferenzen für P2P File Sharing

## 📦 Verfügbare Storage-Optionen in PeerWave

### Web (Flutter Web)

#### 1. IndexedDB (via `idb_shim: ^2.6.6+2`) ✅ EMPFOHLEN

**Verwendung:**
```dart
import 'package:idb_shim/idb_browser.dart';

// Database öffnen
final idbFactory = idbFactoryBrowser;
final db = await idbFactory.open('PeerWaveFiles', version: 1,
  onUpgradeNeeded: (VersionChangeEvent event) {
    Database db = event.database;
    
    // ObjectStore: files
    db.createObjectStore('files', keyPath: 'fileId');
    
    // ObjectStore: chunks
    db.createObjectStore('chunks', keyPath: ['fileId', 'chunkIndex']);
    
    // ObjectStore: fileKeys
    db.createObjectStore('fileKeys', keyPath: 'fileId');
  }
);

// Chunk speichern
final tx = db.transaction('chunks', idbModeReadWrite);
final store = tx.objectStore('chunks');
await store.put({
  'fileId': 'uuid-v4',
  'chunkIndex': 0,
  'encryptedData': chunkBytes, // Uint8List
  'iv': ivBytes,
  'chunkHash': 'sha256-hash',
  'status': 'complete'
});
await tx.completed;
```

**Vorteile:**
- ✅ Große Speicherkapazität (bis zu mehreren GB, Browser-abhängig)
- ✅ Asynchrone API (nicht-blockierend)
- ✅ Strukturierte Daten (ObjectStores, Indexes)
- ✅ Transaktionen (ACID-garantien)
- ✅ Perfekt für Binärdaten (Uint8List)
- ✅ Persistenz über Browser-Sessions

**Nachteile:**
- ❌ Quota-Limits (User kann mehr Speicher gewähren)
- ❌ Komplexere API als localStorage

**Speicherkapazität:**
- Chrome/Edge: ~60% des freien Speicherplatzes
- Firefox: ~50% des freien Speicherplatzes
- Safari: ~1 GB (kann erweitert werden)

**Best Practice:**
```dart
// Prüfe verfügbaren Speicher
if (window.navigator.storage != null) {
  final estimate = await window.navigator.storage.estimate();
  print('Available: ${estimate.quota - estimate.usage} bytes');
}
```

#### 2. localStorage (via `js: ^0.6.7`) ⚠️ NUR FÜR METADATEN

**Verwendung:**
```dart
import 'package:js/js.dart';

@JS('window.localStorage.setItem')
external void localStorageSetItem(String key, String value);

@JS('window.localStorage.getItem')
external String? localStorageGetItem(String key);

// Metadaten speichern
localStorageSetItem('uploaded_files', jsonEncode([
  {'fileId': 'uuid-v4', 'status': 'uploaded'},
]));
```

**Vorteile:**
- ✅ Sehr einfache API (synchron)
- ✅ Schneller Zugriff
- ✅ Gut für kleine Flags/Status

**Nachteile:**
- ❌ Max ~5-10 MB (Browser-abhängig)
- ❌ Nur String-Storage (muss JSON.encode/decode)
- ❌ Synchrone API (blockiert UI bei großen Daten)
- ❌ NICHT geeignet für Chunks!

**Verwendung in PeerWave:**
- ✅ Einfache Flags: `autoReannounce`, `lastSync`
- ✅ FileIds-Listen (klein)
- ❌ KEINE Chunks oder große Daten

#### 3. shared_preferences (via `shared_preferences: ^2.0.6`) ⚠️ NUR FÜR SETTINGS

**Verwendung:**
```dart
import 'package:shared_preferences/shared_preferences.dart';

final prefs = await SharedPreferences.getInstance();

// Settings
await prefs.setBool('autoReannounce', true);
await prefs.setInt('maxUploadSlots', 6);
await prefs.setStringList('recentFileIds', ['uuid1', 'uuid2']);
```

**Verwendung in PeerWave:**
- ✅ User-Settings (Upload-Slots, Auto-Reannounce)
- ✅ Feature-Flags
- ❌ KEINE File-Daten oder Chunks

---

### Native (Android/iOS/Desktop)

#### 1. FlutterSecureStorage (via `flutter_secure_storage: ^9.0.0`) ✅ FÜR KEYS & METADATEN

**Verwendung:**
```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const storage = FlutterSecureStorage();

// File-Key speichern (verschlüsselt!)
await storage.write(
  key: 'file_${fileId}_key',
  value: base64Encode(fileKeyBytes)
);

// Metadaten speichern
await storage.write(
  key: 'file_${fileId}_metadata',
  value: jsonEncode({
    'fileId': fileId,
    'fileName': 'document.pdf',
    'fileSize': 1048576,
    'checksum': 'sha256-hash',
    'status': 'uploaded'
  })
);

// Chunk-Metadaten (NICHT Chunk-Daten!)
await storage.write(
  key: 'file_${fileId}_chunks',
  value: jsonEncode([
    {'chunkIndex': 0, 'status': 'complete', 'filePath': '/path/to/chunk0.enc'}
  ])
);
```

**Vorteile:**
- ✅ Verschlüsseltes Storage (AES-256)
- ✅ Plattform-unabhängig (Android Keystore, iOS Keychain)
- ✅ Perfekt für Secrets (File-Keys, Tokens)
- ✅ Einfache API

**Nachteile:**
- ❌ Nicht optimal für große Daten (Chunks)
- ❌ Performance-Overhead bei vielen Reads/Writes
- ❌ Key-Value-Store (keine strukturierten Queries)

**Verwendung in PeerWave:**
- ✅ File-Keys (AES-256)
- ✅ File-Metadaten
- ✅ Chunk-Metadaten (Index, Status, Path)
- ❌ KEINE Chunk-Daten direkt (zu groß)

#### 2. path_provider + Dart File API 🔄 EMPFOHLEN FÜR CHUNKS

**Neue Dependency benötigt:**
```yaml
# pubspec.yaml
dependencies:
  path_provider: ^2.1.0  # ← NEU HINZUFÜGEN
```

**Verwendung:**
```dart
import 'dart:io';
import 'package:path_provider/path_provider.dart';

// Chunk-Verzeichnis erstellen
Future<Directory> getChunkDirectory(String fileId) async {
  final appDir = await getApplicationDocumentsDirectory();
  final chunkDir = Directory('${appDir.path}/file_chunks/$fileId');
  
  if (!await chunkDir.exists()) {
    await chunkDir.create(recursive: true);
  }
  
  return chunkDir;
}

// Chunk speichern
Future<void> saveChunk(String fileId, int chunkIndex, Uint8List encryptedData) async {
  final chunkDir = await getChunkDirectory(fileId);
  final chunkFile = File('${chunkDir.path}/chunk_$chunkIndex.enc');
  
  await chunkFile.writeAsBytes(encryptedData);
  
  print('Saved chunk $chunkIndex to ${chunkFile.path}');
}

// Chunk laden
Future<Uint8List?> loadChunk(String fileId, int chunkIndex) async {
  final chunkDir = await getChunkDirectory(fileId);
  final chunkFile = File('${chunkDir.path}/chunk_$chunkIndex.enc');
  
  if (!await chunkFile.exists()) {
    return null;
  }
  
  return await chunkFile.readAsBytes();
}

// Alle Chunks löschen
Future<void> deleteAllChunks(String fileId) async {
  final chunkDir = await getChunkDirectory(fileId);
  
  if (await chunkDir.exists()) {
    await chunkDir.delete(recursive: true);
  }
}
```

**Vorteile:**
- ✅ Sehr gute Performance für große Dateien
- ✅ Keine Größenlimits (nur Speicherplatz)
- ✅ Native Dateisystem-API
- ✅ Einfach zu implementieren
- ✅ Chunk-weise Speicherung (ideal für P2P)

**Nachteile:**
- ❌ Keine Verschlüsselung (muss selbst implementiert werden)
- ❌ Keine strukturierten Queries (nur Dateisystem)

**Verwendung in PeerWave:**
- ✅ Chunk-Daten als verschlüsselte Dateien
- ✅ Großer Storage (nur durch Speicherplatz limitiert)
- ✅ Bessere Performance als FlutterSecureStorage

#### 3. shared_preferences (via `shared_preferences: ^2.0.6`) ⚠️ NUR FÜR SETTINGS

Gleiche Verwendung wie Web (siehe oben).

---

## 🎯 Empfohlene Storage-Strategie

### Web

```
┌─────────────────────────────────────────────────────────┐
│                    IndexedDB (idb_shim)                 │
├─────────────────────────────────────────────────────────┤
│  ObjectStore: files                                     │
│  - fileId, fileName, fileSize, mimeType, checksum       │
│  - status, uploaderId, createdAt, chatType, chatId      │
│  - autoReannounce, lastReannounce                       │
├─────────────────────────────────────────────────────────┤
│  ObjectStore: chunks                                    │
│  - fileId, chunkIndex, encryptedData (Uint8List)        │
│  - iv, chunkHash, status, timestamp                     │
├─────────────────────────────────────────────────────────┤
│  ObjectStore: fileKeys                                  │
│  - fileId, encryptedKey (Signal-verschlüsselt)          │
│  - decryptedKey (CryptoKey, nur in Memory!)             │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│              localStorage (nur Flags/Status)            │
├─────────────────────────────────────────────────────────┤
│  'autoReannounce' → 'true'                              │
│  'lastSyncTimestamp' → '1698420000000'                  │
└─────────────────────────────────────────────────────────┘
```

### Native (Android/iOS/Desktop)

```
┌─────────────────────────────────────────────────────────┐
│          FlutterSecureStorage (Metadaten & Keys)        │
├─────────────────────────────────────────────────────────┤
│  'file_${fileId}_metadata' → JSON({                     │
│    fileId, fileName, fileSize, mimeType, checksum,      │
│    status, uploaderId, createdAt, chatType, chatId      │
│  })                                                      │
├─────────────────────────────────────────────────────────┤
│  'file_${fileId}_key' → base64(AES-256-Key)             │
├─────────────────────────────────────────────────────────┤
│  'file_${fileId}_chunks' → JSON([                       │
│    { chunkIndex: 0, status: 'complete',                 │
│      filePath: '/path/chunk_0.enc' }                    │
│  ])                                                      │
├─────────────────────────────────────────────────────────┤
│  'uploaded_files' → JSON(['uuid1', 'uuid2'])            │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│         path_provider + Dart File API (Chunks)          │
├─────────────────────────────────────────────────────────┤
│  <app_documents_dir>/file_chunks/                       │
│    ├── ${fileId}/                                       │
│    │   ├── chunk_0.enc  (verschlüsselte Daten)          │
│    │   ├── chunk_1.enc                                  │
│    │   └── ...                                          │
│    └── ${fileId2}/                                      │
│        └── ...                                          │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│        SharedPreferences (User-Settings)                │
├─────────────────────────────────────────────────────────┤
│  'autoReannounce' → true                                │
│  'maxUploadSlots' → 6                                   │
│  'downloadOnlyWiFi' → true                              │
└─────────────────────────────────────────────────────────┘
```

---

## 💾 Speicher-Vergleich

| Storage-Methode | Max Size | Performance | Encryption | Best For |
|----------------|----------|-------------|------------|----------|
| **Web: IndexedDB** | ~GB | ⚡⚡⚡ Fast | ❌ Manual | Chunks, Metadaten |
| **Web: localStorage** | ~10 MB | ⚡⚡⚡⚡ Very Fast | ❌ No | Flags, Status |
| **Native: FlutterSecureStorage** | ~MB | ⚡⚡ Medium | ✅ Yes | Keys, Metadaten |
| **Native: path_provider** | Unlimited | ⚡⚡⚡⚡ Very Fast | ❌ Manual | Chunks |
| **SharedPreferences** | ~MB | ⚡⚡⚡ Fast | ❌ No | Settings |

---

## 🔒 Verschlüsselung

### Chunk-Verschlüsselung (Web + Native)

```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart'; // Hinzufügen: crypto: ^3.0.3

// AES-GCM Verschlüsselung
Future<Map<String, dynamic>> encryptChunk(Uint8List chunkData, Uint8List fileKey) async {
  // Generate random IV (12 bytes für GCM)
  final iv = Uint8List.fromList(List.generate(12, (_) => Random.secure().nextInt(256)));
  
  // Web Crypto API (Web)
  if (kIsWeb) {
    final key = await window.crypto.subtle.importKey(
      'raw',
      fileKey.buffer,
      {'name': 'AES-GCM'},
      false,
      ['encrypt']
    );
    
    final encrypted = await window.crypto.subtle.encrypt(
      {'name': 'AES-GCM', 'iv': iv.buffer, 'tagLength': 128},
      key,
      chunkData.buffer
    );
    
    return {
      'encryptedData': Uint8List.view(encrypted),
      'iv': iv
    };
  }
  
  // Native: pointycastle (oder FFI-basierte Crypto-Library)
  // Alternativ: encrypt package (encrypt: ^5.0.3)
  final encrypter = Encrypter(AES(Key(fileKey), mode: AESMode.gcm));
  final encrypted = encrypter.encryptBytes(chunkData, iv: IV(iv));
  
  return {
    'encryptedData': encrypted.bytes,
    'iv': iv
  };
}
```

---

## 📊 Storage-Service Implementierung

### Abstrakte Storage-Schnittstelle

```dart
// client/lib/services/file_transfer/storage_interface.dart

abstract class FileStorageInterface {
  // File Metadaten
  Future<void> saveFileMetadata(String fileId, Map<String, dynamic> metadata);
  Future<Map<String, dynamic>?> getFileMetadata(String fileId);
  Future<List<Map<String, dynamic>>> getFilesByStatus(String status);
  Future<void> deleteFile(String fileId);
  
  // Chunks
  Future<void> saveChunk(String fileId, int chunkIndex, Uint8List encryptedData, Uint8List iv, String chunkHash);
  Future<Map<String, dynamic>?> getChunk(String fileId, int chunkIndex);
  Future<List<int>> getCompleteChunks(String fileId);
  Future<void> deleteChunks(String fileId);
  
  // File Keys
  Future<void> saveFileKey(String fileId, String encryptedKey);
  Future<String?> getFileKey(String fileId);
}
```

### Web-Implementierung (IndexedDB)

```dart
// client/lib/services/file_transfer/indexeddb_storage.dart

import 'package:idb_shim/idb_browser.dart';
import 'storage_interface.dart';

class IndexedDBStorage implements FileStorageInterface {
  static const String DB_NAME = 'PeerWaveFiles';
  static const int DB_VERSION = 1;
  
  Database? _db;
  
  Future<void> init() async {
    final idbFactory = idbFactoryBrowser;
    
    _db = await idbFactory.open(DB_NAME, version: DB_VERSION,
      onUpgradeNeeded: (VersionChangeEvent event) {
        final db = event.database;
        
        // ObjectStore: files
        if (!db.objectStoreNames.contains('files')) {
          final store = db.createObjectStore('files', keyPath: 'fileId');
          store.createIndex('status', 'status', unique: false);
          store.createIndex('uploaderId', 'uploaderId', unique: false);
        }
        
        // ObjectStore: chunks
        if (!db.objectStoreNames.contains('chunks')) {
          final store = db.createObjectStore('chunks', keyPath: ['fileId', 'chunkIndex']);
          store.createIndex('fileId', 'fileId', unique: false);
          store.createIndex('status', 'status', unique: false);
        }
        
        // ObjectStore: fileKeys
        if (!db.objectStoreNames.contains('fileKeys')) {
          db.createObjectStore('fileKeys', keyPath: 'fileId');
        }
      }
    );
  }
  
  @override
  Future<void> saveFileMetadata(String fileId, Map<String, dynamic> metadata) async {
    final tx = _db!.transaction('files', idbModeReadWrite);
    final store = tx.objectStore('files');
    await store.put(metadata);
    await tx.completed;
  }
  
  @override
  Future<Map<String, dynamic>?> getFileMetadata(String fileId) async {
    final tx = _db!.transaction('files', idbModeReadOnly);
    final store = tx.objectStore('files');
    final result = await store.getObject(fileId);
    return result as Map<String, dynamic>?;
  }
  
  @override
  Future<List<Map<String, dynamic>>> getFilesByStatus(String status) async {
    final tx = _db!.transaction('files', idbModeReadOnly);
    final store = tx.objectStore('files');
    final index = store.index('status');
    
    final results = <Map<String, dynamic>>[];
    final cursor = index.openCursor(key: status, autoAdvance: true);
    
    await for (final c in cursor) {
      results.add(c.value as Map<String, dynamic>);
    }
    
    return results;
  }
  
  @override
  Future<void> saveChunk(String fileId, int chunkIndex, Uint8List encryptedData, 
                         Uint8List iv, String chunkHash) async {
    final tx = _db!.transaction('chunks', idbModeReadWrite);
    final store = tx.objectStore('chunks');
    
    await store.put({
      'fileId': fileId,
      'chunkIndex': chunkIndex,
      'encryptedData': encryptedData,
      'iv': iv,
      'chunkHash': chunkHash,
      'status': 'complete',
      'timestamp': DateTime.now().millisecondsSinceEpoch
    });
    
    await tx.completed;
  }
  
  @override
  Future<List<int>> getCompleteChunks(String fileId) async {
    final tx = _db!.transaction('chunks', idbModeReadOnly);
    final store = tx.objectStore('chunks');
    final index = store.index('fileId');
    
    final chunkIndexes = <int>[];
    final cursor = index.openCursor(key: fileId, autoAdvance: true);
    
    await for (final c in cursor) {
      final data = c.value as Map<String, dynamic>;
      if (data['status'] == 'complete') {
        chunkIndexes.add(data['chunkIndex'] as int);
      }
    }
    
    return chunkIndexes;
  }
  
  // ... weitere Methoden
}
```

### Native-Implementierung (FlutterSecureStorage + path_provider)

```dart
// client/lib/services/file_transfer/secure_storage_manager.dart

import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'storage_interface.dart';

class SecureStorageManager implements FileStorageInterface {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  
  @override
  Future<void> saveFileMetadata(String fileId, Map<String, dynamic> metadata) async {
    await _storage.write(
      key: 'file_${fileId}_metadata',
      value: jsonEncode(metadata)
    );
  }
  
  @override
  Future<Map<String, dynamic>?> getFileMetadata(String fileId) async {
    final json = await _storage.read(key: 'file_${fileId}_metadata');
    return json != null ? jsonDecode(json) : null;
  }
  
  @override
  Future<List<Map<String, dynamic>>> getFilesByStatus(String status) async {
    // Hole alle File-IDs
    final uploadedFilesJson = await _storage.read(key: 'uploaded_files');
    if (uploadedFilesJson == null) return [];
    
    final fileIds = List<String>.from(jsonDecode(uploadedFilesJson));
    
    // Filter nach Status
    final results = <Map<String, dynamic>>[];
    for (final fileId in fileIds) {
      final metadata = await getFileMetadata(fileId);
      if (metadata != null && metadata['status'] == status) {
        results.add(metadata);
      }
    }
    
    return results;
  }
  
  @override
  Future<void> saveChunk(String fileId, int chunkIndex, Uint8List encryptedData,
                         Uint8List iv, String chunkHash) async {
    // Chunk als Datei speichern (path_provider)
    final chunkDir = await _getChunkDirectory(fileId);
    final chunkFile = File('${chunkDir.path}/chunk_$chunkIndex.enc');
    await chunkFile.writeAsBytes(encryptedData);
    
    // IV separat speichern
    final ivFile = File('${chunkDir.path}/chunk_${chunkIndex}_iv.bin');
    await ivFile.writeAsBytes(iv);
    
    // Metadaten aktualisieren
    await _updateChunkMetadata(fileId, chunkIndex, chunkHash, 'complete', chunkFile.path);
  }
  
  Future<Directory> _getChunkDirectory(String fileId) async {
    final appDir = await getApplicationDocumentsDirectory();
    final chunkDir = Directory('${appDir.path}/file_chunks/$fileId');
    
    if (!await chunkDir.exists()) {
      await chunkDir.create(recursive: true);
    }
    
    return chunkDir;
  }
  
  Future<void> _updateChunkMetadata(String fileId, int chunkIndex, 
                                     String chunkHash, String status, String filePath) async {
    // Lade bestehende Chunk-Metadaten
    final chunksJson = await _storage.read(key: 'file_${fileId}_chunks');
    final chunks = chunksJson != null ? List<Map<String, dynamic>>.from(jsonDecode(chunksJson)) : [];
    
    // Update oder hinzufügen
    final existingIndex = chunks.indexWhere((c) => c['chunkIndex'] == chunkIndex);
    final chunkMeta = {
      'chunkIndex': chunkIndex,
      'chunkHash': chunkHash,
      'status': status,
      'filePath': filePath,
      'timestamp': DateTime.now().millisecondsSinceEpoch
    };
    
    if (existingIndex >= 0) {
      chunks[existingIndex] = chunkMeta;
    } else {
      chunks.add(chunkMeta);
    }
    
    // Speichern
    await _storage.write(
      key: 'file_${fileId}_chunks',
      value: jsonEncode(chunks)
    );
  }
  
  @override
  Future<List<int>> getCompleteChunks(String fileId) async {
    final chunksJson = await _storage.read(key: 'file_${fileId}_chunks');
    if (chunksJson == null) return [];
    
    final chunks = List<Map<String, dynamic>>.from(jsonDecode(chunksJson));
    
    return chunks
      .where((c) => c['status'] == 'complete')
      .map((c) => c['chunkIndex'] as int)
      .toList();
  }
  
  // ... weitere Methoden
}
```

---

## 🚀 Nächste Schritte

1. **Entscheidung**: Native Storage-Strategie
   - ✅ Option A: `path_provider` hinzufügen (bessere Performance)
   - ⚠️ Option B: Nur `FlutterSecureStorage` (einfacher, aber langsamer)

2. **Implementierung**: Storage-Layer
   - [ ] `storage_interface.dart` erstellen
   - [ ] `indexeddb_storage.dart` (Web)
   - [ ] `secure_storage_manager.dart` (Native)
   - [ ] Conditional Import für Web/Native

3. **Testing**: Storage-Tests
   - [ ] Unit-Tests für alle Storage-Methoden
   - [ ] Performance-Tests (große Files)
   - [ ] Quota-Handling (Web)

4. **Integration**: FileTransferService
   - [ ] Verwende abstrakte Storage-Schnittstelle
   - [ ] Plattform-Detection (kIsWeb)
   - [ ] Fehler-Handling

**Empfehlung**: Option A mit `path_provider` für bessere Performance bei großen Dateien! 🚀
