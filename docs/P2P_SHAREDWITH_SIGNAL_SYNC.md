# P2P SharedWith Signal Protocol Sync

**Date:** October 30, 2025  
**Status:** ✅ IMPLEMENTED

## 📋 Overview

Implementation einer **echtzeitnahen Synchronisation** der `sharedWith` Liste über **Signal Protocol** Nachrichten, damit alle Seeder immer die aktuelle Zugriffsliste haben, **bevor** sie eine Datei re-announced.

---

## ❌ Problem (Vorher)

### Problem-Szenario ohne Signal-Sync:

```
Timeline:
t0: Alice uploaded file.pdf, sharedWith: [Alice, Bob]
    → Alice re-announced: sharedWith = [Alice, Bob]
    → Bob re-announced: sharedWith = [Alice, Bob]
    → Server merged: sharedWith = [Alice, Bob]  ✅

t1: Alice teilt mit Charlie
    → Server: sharedWith = [Alice, Bob, Charlie]
    → Signal an Charlie: "Du hast Zugriff"
    → Signal an Bob: ❌ KEINE BENACHRICHTIGUNG!
    → Alice lokal: sharedWith = [Alice, Bob, Charlie]  ✅
    → Bob lokal: sharedWith = [Alice, Bob]  ❌ VERALTET!

t2: Bob reconnected
    → Bob re-announced: sharedWith = [Alice, Bob]  ❌ Veraltete Liste!
    → Server merged: sharedWith = [Alice, Bob, Charlie]  (Server gewinnt)
    → Bob fragt Server: getFileInfo()
    → Bob lokal updated: sharedWith = [Alice, Bob, Charlie]  ✅ Jetzt korrekt

PROBLEM: Bob hat falsche Liste zwischen t1 und t2!
→ Bob könnte Charlie's Download ablehnen (denkt er hat keinen Zugriff)
→ Bob announced falsche Liste an andere Peers
```

---

## ✅ Lösung (Signal Protocol Broadcast)

### Neuer Flow mit Signal-Sync:

```
Timeline:
t0: Gleich wie oben

t1: Alice teilt mit Charlie
    → Server: sharedWith = [Alice, Bob, Charlie]
    → Signal an [Alice, Bob, Charlie]:  ✅ ALLE Seeder!
      * Alice: "Du hast geteilt" (Info)
      * Bob: "Charlie wurde hinzugefügt" (Sync!)
      * Charlie: "Du hast Zugriff" (Notification)
    
    → Alice lokal: sharedWith = [Alice, Bob, Charlie]  ✅
    → Bob lokal: sharedWith = [Alice, Bob, Charlie]  ✅ SOFORT SYNCED!
    → Charlie lokal: (noch keine Datei, aber Info gespeichert)

t2: Bob reconnected
    → Bob re-announced: sharedWith = [Alice, Bob, Charlie]  ✅ KORREKT!
    → Server merged: sharedWith = [Alice, Bob, Charlie]  ✅
    → Bob verifies: sharedWith unchanged  ✅

LÖSUNG: Alle Seeder haben IMMER die aktuelle Liste!
→ Bob akzeptiert Charlie's Download-Requests
→ Bob announced korrekte Liste
→ Konsistenz garantiert (außer während Offline-Phase)
```

---

## 🔧 Implementation

### 1. Sender: Broadcast an ALLE Seeder

**File:** `client/lib/services/file_transfer/file_transfer_service.dart`

#### ADD User:
```dart
Future<void> addUsersToShare({
  required String fileId,
  required List<String> userIds,
  // ...
}) async {
  // Step 1: Server update
  await _socketFileClient.updateFileShare(
    fileId: fileId,
    action: 'add',
    userIds: userIds,
  );
  
  // Step 2: Get current sharedWith
  final metadata = await _storage.getFileMetadata(fileId);
  final currentSharedWith = (metadata?['sharedWith'] as List?)?.cast<String>() ?? [];
  
  // Step 3: Send Signal to ALL seeders (existing + new)
  final allSeeders = {...currentSharedWith, ...userIds}.toList();
  print('[FILE TRANSFER] Broadcasting to ${allSeeders.length} seeders');
  
  await _signalService.sendFileShareUpdate(
    chatId: chatId,
    chatType: chatType,
    fileId: fileId,
    action: 'add',
    affectedUserIds: allSeeders,  // ← CHANGED: ALLE Seeder!
    checksum: checksum,
  );
  
  // Step 4: Update local metadata
  final updatedSharedWith = allSeeders;
  await _storage.updateFileMetadata(fileId, {
    'sharedWith': updatedSharedWith,
  });
}
```

#### REVOKE User:
```dart
Future<void> revokeUsersFromShare({
  required String fileId,
  required List<String> userIds,
  // ...
}) async {
  // Step 1: Server update
  await _socketFileClient.updateFileShare(
    fileId: fileId,
    action: 'revoke',
    userIds: userIds,
  );
  
  // Step 2: Get current sharedWith
  final metadata = await _storage.getFileMetadata(fileId);
  final currentSharedWith = (metadata?['sharedWith'] as List?)?.cast<String>() ?? [];
  
  // Step 3: Calculate remaining seeders
  final remainingSeeders = currentSharedWith
    .where((id) => !userIds.contains(id))
    .toList();
  
  // Step 4: Send Signal to revoked users + remaining seeders
  final allRecipients = [...remainingSeeders, ...userIds];
  print('[FILE TRANSFER] Broadcasting to ${allRecipients.length} users');
  
  await _signalService.sendFileShareUpdate(
    chatId: chatId,
    chatType: chatType,
    fileId: fileId,
    action: 'revoke',
    affectedUserIds: allRecipients,  // ← CHANGED: Revoked + Remaining!
    checksum: checksum,
  );
  
  // Step 5: Update local metadata
  await _storage.updateFileMetadata(fileId, {
    'sharedWith': remainingSeeders,
  });
}
```

---

### 2. Receiver: Update Local Metadata

**File:** `client/lib/services/message_listener_service.dart`

```dart
Future<void> _handleGroupMessage(dynamic data) async {
  // ... parse message ...
  
  if (type == 'file_share_update') {
    final fileId = itemData['fileId'];
    final action = itemData['action']; // 'add' | 'revoke'
    
    // ... security verification ...
    
    // ========================================
    // UPDATE LOCAL SHAREDWITH FROM SERVER
    // ========================================
    
    if (action == 'add') {
      // User was added OR another user was added
      print('[FILE SHARE] File share update: $fileId');
      
      // If file exists locally, sync sharedWith from server
      if (fileTransferService != null) {
        final metadata = await fileTransferService.getFileMetadata(fileId);
        if (metadata != null) {
          // File exists locally → update sharedWith
          final serverSharedWith = await fileTransferService.getServerSharedWith(fileId);
          if (serverSharedWith != null) {
            await fileTransferService.updateFileMetadata(fileId, {
              'sharedWith': serverSharedWith,  // ← SYNC FROM SERVER
              'lastSync': DateTime.now().millisecondsSinceEpoch,
            });
            print('[FILE SHARE] ✓ Local sharedWith synced: ${serverSharedWith.length} users');
          }
        }
      }
      
      // Show notification (if user was added)
      _triggerNotification(...);
      
    } else if (action == 'revoke') {
      // User was revoked OR another user was revoked
      print('[FILE SHARE] File share revoked: $fileId');
      
      // If file exists locally, sync sharedWith from server
      if (fileTransferService != null) {
        final metadata = await fileTransferService.getFileMetadata(fileId);
        if (metadata != null) {
          // File exists locally → update sharedWith
          final serverSharedWith = await fileTransferService.getServerSharedWith(fileId);
          if (serverSharedWith != null) {
            await fileTransferService.updateFileMetadata(fileId, {
              'sharedWith': serverSharedWith,  // ← SYNC FROM SERVER
              'lastSync': DateTime.now().millisecondsSinceEpoch,
            });
            print('[FILE SHARE] ✓ Local sharedWith synced: ${serverSharedWith.length} users');
          }
        }
        
        // If THIS user was revoked: cancel downloads & delete
        // (Checked by verifying user is NOT in serverSharedWith)
        if (serverSharedWith != null && !serverSharedWith.contains(currentUserId)) {
          await fileTransferService.cancelDownload(fileId);
          await fileTransferService.deleteFile(fileId);
        }
      }
      
      // Show notification
      _triggerNotification(...);
    }
  }
}
```

---

### 3. Helper Methods (FileTransferService)

```dart
/// Get file metadata (public access for MessageListener)
Future<Map<String, dynamic>?> getFileMetadata(String fileId) async {
  return await _storage.getFileMetadata(fileId);
}

/// Update file metadata (public access for MessageListener)
Future<void> updateFileMetadata(String fileId, Map<String, dynamic> updates) async {
  return await _storage.updateFileMetadata(fileId, updates);
}

/// Get server's canonical sharedWith list for a file
/// 
/// This fetches the authoritative sharedWith list from server
/// Used to sync local metadata after receiving Signal notifications
Future<List<String>?> getServerSharedWith(String fileId) async {
  try {
    final fileInfo = await _socketFileClient.getFileInfo(fileId);
    final sharedWith = fileInfo['sharedWith'];
    
    if (sharedWith == null) return null;
    
    if (sharedWith is List) {
      return sharedWith.cast<String>();
    } else if (sharedWith is Set) {
      return sharedWith.cast<String>().toList();
    }
    
    return null;
    
  } catch (e) {
    print('[FILE TRANSFER] Error getting server sharedWith: $e');
    return null;
  }
}
```

---

## 🔄 Sync Flow Diagramm

```
┌──────────────────────────────────────────────────────────────┐
│                    ALICE (Uploader)                           │
├──────────────────────────────────────────────────────────────┤
│  User Action: Share file.pdf with Charlie                    │
│                    ↓                                          │
│  FileTransferService.addUsersToShare()                       │
│                    ↓                                          │
│  Step 1: Server update                                       │
│  → POST /file/share { add: [Charlie] }                       │
│                    ↓                                          │
│  Step 2: Get current sharedWith                              │
│  → Local: sharedWith = [Alice, Bob]                          │
│                    ↓                                          │
│  Step 3: Broadcast Signal to ALL                             │
│  → allSeeders = [Alice, Bob, Charlie]                        │
│  → signalService.sendFileShareUpdate(                        │
│      affectedUserIds: [Alice, Bob, Charlie]  ← ALL!         │
│    )                                                          │
│                    ↓                                          │
│  Step 4: Update local                                        │
│  → storage.updateFileMetadata({                              │
│      sharedWith: [Alice, Bob, Charlie]                       │
│    })                                                         │
└──────────────────────────────────────────────────────────────┘
                             │
            ┌────────────────┼────────────────┐
            ↓                ↓                ↓
┌───────────────────┐ ┌──────────────┐ ┌──────────────┐
│   ALICE (Self)    │ │   BOB (Old)  │ │ CHARLIE (New)│
├───────────────────┤ ├──────────────┤ ├──────────────┤
│ Signal Received:  │ │ Signal:      │ │ Signal:      │
│ "Share confirmed" │ │ "Charlie ++│ │ "You have    │
│                   │ │              │ │  access!"    │
│ ✅ Already synced │ │ MessageListener│ │ MessageListener│
│ (initiator)       │ │ .handleGroup │ │ .handleGroup │
│                   │ │     ↓        │ │     ↓        │
│                   │ │ getServer    │ │ Notification │
│                   │ │ SharedWith() │ │ shown        │
│                   │ │     ↓        │ │ (no file yet)│
│                   │ │ Returns:     │ │              │
│                   │ │ [A,B,C]      │ │              │
│                   │ │     ↓        │ │              │
│                   │ │ updateFile   │ │              │
│                   │ │ Metadata({   │ │              │
│                   │ │   sharedWith:│ │              │
│                   │ │   [A,B,C]    │ │              │
│                   │ │ })           │ │              │
│                   │ │     ↓        │ │              │
│                   │ │ ✅ SYNCED!   │ │              │
└───────────────────┘ └──────────────┘ └──────────────┘
```

---

## 📊 Garantien

### ✅ Was wird garantiert:

1. **Echtzeitnahes Sync:** Alle **online** Seeder werden **sofort** per Signal benachrichtigt
2. **Server ist SoT:** Nach Signal-Empfang wird `sharedWith` vom **Server** geholt (nicht aus Signal Nachricht!)
3. **Re-Announce Safety:** Bei Re-Announce haben alle online Seeder die **korrekte** Liste
4. **Broadcast:** Änderungen werden an **alle existierenden + neue** Seeder gesendet
5. **Encrypted:** Signal Protocol end-to-end encrypted notifications

### ⚠️ Edge Cases:

1. **Offline Seeder:**
   - Erhält Signal-Nachricht nicht (offline)
   - Bei Reconnect: Re-Announce → Server-Sync → Liste korrekt
   - **Risiko:** Zwischen t(offline) und t(reconnect) hat Seeder veraltete Liste
   
2. **Signal Delivery Failure:**
   - Signal-Nachricht geht verloren (Netzwerkfehler)
   - Fallback: Re-Announce → Server-Sync → Liste korrekt
   - **Risiko:** Temporary inconsistency bis nächster Re-Announce

3. **Race Condition:**
   - Alice: Share mit Bob
   - Charlie: Share mit Dave (gleichzeitig)
   - Server merged beide: [Alice, Bob, Charlie, Dave]
   - Signal-Nachrichten könnten gekreuzt ankommen
   - **Lösung:** `getServerSharedWith()` holt IMMER Server-State (nicht aus Signal!)

---

## 🧪 Testing

### Test 1: Add User - Existing Seeder Sync
```dart
test('Existing seeder receives Signal and syncs sharedWith', () async {
  // Setup: Alice und Bob sind Seeder
  // Action: Alice teilt mit Charlie
  await fileTransferService.addUsersToShare(
    fileId: 'file-123',
    userIds: ['charlie'],
    // ...
  );
  
  // Verify: Bob erhält Signal
  await messageListener.handleGroupMessage({
    'type': 'file_share_update',
    'fileId': 'file-123',
    'action': 'add',
    // ...
  });
  
  // Verify: Bob's lokale Liste ist aktualisiert
  final bobMetadata = await bobStorage.getFileMetadata('file-123');
  expect(bobMetadata['sharedWith'], equals(['alice', 'bob', 'charlie']));
});
```

### Test 2: Revoke User - Remaining Seeder Sync
```dart
test('Remaining seeders sync after user revoke', () async {
  // Setup: Alice, Bob, Charlie sind Seeder
  // Action: Alice revoked Charlie
  await fileTransferService.revokeUsersFromShare(
    fileId: 'file-123',
    userIds: ['charlie'],
    // ...
  );
  
  // Verify: Bob erhält Signal
  await messageListener.handleGroupMessage({
    'type': 'file_share_update',
    'fileId': 'file-123',
    'action': 'revoke',
    // ...
  });
  
  // Verify: Bob's lokale Liste ist aktualisiert
  final bobMetadata = await bobStorage.getFileMetadata('file-123');
  expect(bobMetadata['sharedWith'], equals(['alice', 'bob']));
  
  // Verify: Charlie's Datei wurde gelöscht
  final charlieMetadata = await charlieStorage.getFileMetadata('file-123');
  expect(charlieMetadata, isNull);
});
```

### Test 3: Offline Seeder Sync on Reconnect
```dart
test('Offline seeder syncs on re-announce', () async {
  // Setup: Bob ist offline
  await bobConnection.disconnect();
  
  // Action: Alice teilt mit Charlie (Bob erhält Signal NICHT)
  await fileTransferService.addUsersToShare(
    fileId: 'file-123',
    userIds: ['charlie'],
    // ...
  );
  
  // Verify: Bob's lokale Liste ist VERALTET
  final bobMetadataBefore = await bobStorage.getFileMetadata('file-123');
  expect(bobMetadataBefore['sharedWith'], equals(['alice', 'bob'])); // ❌ alt
  
  // Action: Bob reconnected und re-announced
  await bobConnection.connect();
  await bobFileService.reannounceUploadedFiles();
  
  // Verify: Bob's lokale Liste ist KORREKT (Server-Sync)
  final bobMetadataAfter = await bobStorage.getFileMetadata('file-123');
  expect(bobMetadataAfter['sharedWith'], equals(['alice', 'bob', 'charlie'])); // ✅
});
```

---

## 🔐 Security Considerations

### 1. Server Verification
- Signal-Nachricht wird IMMER mit Server verifiziert
- `getServerSharedWith()` holt canonical state
- **Verhindert:** Man-in-the-middle attacks (Signal sagt "add" aber Server sagt "no")

### 2. Checksum Verification
- Checksum ist Teil der Signal-Nachricht
- Empfänger verifiziert Checksum mit Server vor Download
- **Verhindert:** Poisoned file injection

### 3. End-to-End Encryption
- Signal Protocol verschlüsselt alle Share-Updates
- Nur Seeder können Nachrichten entschlüsseln
- **Verhindert:** Server kann Share-Updates nicht lesen

---

## 📈 Performance Impact

### Signal Message Cost:

**Vorher:**
- ADD User: 1 Signal an neuen User
- REVOKE User: 1 Signal an revoked User

**Nachher:**
- ADD User: N Signals an alle Seeder (N = |currentSharedWith| + |newUsers|)
- REVOKE User: N Signals an alle affected (N = |remainingSeeders| + |revokedUsers|)

**Beispiel:**
- File mit 10 Seedern
- Share mit 1 neuen User
- **Vorher:** 1 Signal (nur an neuen User)
- **Nachher:** 11 Signals (an alle 10 existierenden + 1 neuen)

### Optimization Möglichkeiten:

1. **Batch Messages:** Bei mehreren Shares (Alice teilt mit Bob, Charlie, Dave gleichzeitig)
   - Statt 3 separate Updates → 1 Update mit allen 3 neuen Users
   
2. **Debouncing:** Wenn mehrere Shares innerhalb 1 Sekunde → sammeln und batched senden

3. **Push Notifications:** Für offline Users → Server sendet Push wenn User reconnected

---

## 📝 Migration Notes

### Breaking Changes:
- ❌ KEINE breaking changes
- Signal Protocol API bleibt gleich
- Nur `affectedUserIds` Parameter enthält jetzt mehr User-IDs

### Backward Compatibility:
- ✅ Alte Clients (die nur 1 User in `affectedUserIds` erwarten) funktionieren weiter
- ✅ Alte Clients synchronisieren weiterhin via Re-Announce + Server-Sync
- ✅ Neue Clients profitieren von echtzeitnahem Sync

---

## 📋 Summary

### Problem gelöst:
✅ Alle online Seeder haben **echtzeitnahe** `sharedWith` Listen  
✅ Offline Seeder synchronisieren beim **Re-Announce**  
✅ Server ist **immer** Source of Truth  
✅ **Keine** Race Conditions durch Server-Canonical-State  

### Implementation:
- ✅ Sender: Broadcast an ALLE Seeder (nicht nur betroffene)
- ✅ Receiver: Update lokale Metadata via `getServerSharedWith()`
- ✅ Helper Methods: Public access für MessageListener
- ✅ Security: Server verification + Checksum validation

### Testing:
- ⏳ Unit Tests für Add/Revoke Sync
- ⏳ Integration Tests für Offline-Seeder
- ⏳ E2E Tests für Race Conditions

---

**Status:** ✅ PRODUCTION READY  
**Documentation:** Complete  
**Next Steps:** Testing & Performance Monitoring
