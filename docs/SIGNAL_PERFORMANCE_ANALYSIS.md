# Signal Performance Analyse

**Datum**: 2025-10-29  
**Status**: ⚠️ Performance-Probleme identifiziert

---

## Zusammenfassung der Prüfung

### Frage 1: Werden read_receipts aus der Datenbank auf dem Server gelöscht?

**1:1 Chat (Direct Messages):**
- ✅ **JA** - Read receipts werden gelöscht
- Implementierung in `direct_messages_screen.dart`:
  - Zeile 169: `_deleteMessageFromServer(item['itemId'])` nach Verarbeitung
  - Zeile 335: `await _deleteMessageFromServer(msg['itemId'])` beim Laden vom Server
- Server-Endpoint: `DELETE /items/:itemId` in `server/routes/client.js:893`

**Group Chat:**
- ❌ **NEIN** - Read receipts werden NICHT gelöscht!
- Read receipts werden in `GroupItemRead` Tabelle gespeichert
- Zeile 1711 in `server.js`: Kommentiert mit "Optionally: await groupItem.destroy();"
- **Problem**: GroupItems und GroupItemRead akkumulieren unbegrenzt in der Datenbank

---

### Frage 2: Wird das Item als "read" im localStorage markiert und das read_receipt lokal gelöscht?

**1:1 Chat:**
- ✅ **JA** - Item wird als read markiert
  - Zeile 323 in `direct_messages_screen.dart`: `await SignalService.instance.sentMessagesStore.markAsRead(referencedItemId)`
  - Zeile 118 in `direct_messages_screen.dart`: Status wird auf 'read' gesetzt
- ✅ **JA** - Read receipt wird lokal verarbeitet und vom Server gelöscht

**Group Chat:**
- ✅ **TEILWEISE** - Item wird in UI als read markiert
- ❌ **NEIN** - Keine lokale Speicherung des read-Status in `sentGroupItemsStore`
- **Problem**: Nach Refresh ist der read-Status verloren (nur in Server-DB gespeichert)

---

### Frage 3: Werden message types wie file, fileKeyRequest, fileKeyResponse gelöscht?

**file messages:**
- ❌ **NEIN** - Werden NICHT automatisch gelöscht
- Verhalten wie normale messages:
  - 1:1 Chat: Bleiben bis read receipt vom Empfänger
  - Group Chat: Bleiben dauerhaft in DB

**fileKeyRequest / fileKeyResponse:**
- ✅ **FILTER** - Werden gefiltert, aber nicht gelöscht
- Zeile 287 in `signal_group_chat_screen.dart`:
  ```dart
  if (itemType == 'fileKeyRequest' || itemType == 'fileKeyResponse') {
    return; // Don't display in UI
  }
  ```
- Zeile 140 in `direct_messages_screen.dart`:
  ```dart
  if (itemType == 'senderKeyRequest' || 
      itemType == 'fileKeyRequest' || 
      itemType == 'fileKeyResponse') {
    return; // Don't display system messages in UI
  }
  ```
- **Problem**: Diese System-Nachrichten bleiben dauerhaft in der Datenbank!

---

## Identifizierte Performance-Probleme

### 🔴 Kritisch: Group Chat Items werden nie gelöscht

**Problem:**
- Group Chat Messages (`GroupItem` Tabelle) werden niemals vom Server gelöscht
- Read receipts (`GroupItemRead` Tabelle) akkumulieren unbegrenzt
- Code zeigt nur: `// Optionally: await groupItem.destroy();`

**Impact:**
- Datenbank wächst unbegrenzt
- Queries werden langsamer mit der Zeit
- Server-Performance degradiert
- Speicherplatz wird verschwendet

**Betroffen:**
- Alle Group Chat Messages (type: 'message', 'file', etc.)
- Alle Read Receipts für Group Chats

---

### 🟠 Hoch: System-Nachrichten werden nie gelöscht

**Problem:**
- `fileKeyRequest` und `fileKeyResponse` werden gefiltert (nicht angezeigt), aber nie gelöscht
- `senderKeyRequest` und `senderKeyDistribution` ebenfalls
- Diese Nachrichten dienen nur dem Key-Exchange und sind nach Verarbeitung nutzlos

**Impact:**
- Unnötige Daten in `Item` Tabelle (1:1) oder `GroupItem` Tabelle (Group)
- Jede `/direct/messages/:userId` Abfrage lädt diese nutzlosen Items mit
- Performance-Overhead bei jedem Message-Load

**Betroffen:**
- Alle System-Message-Types:
  - `senderKeyRequest`
  - `senderKeyDistribution`
  - `fileKeyRequest`
  - `fileKeyResponse`

---

### 🟡 Mittel: Group Chat read-Status nicht lokal persistiert

**Problem:**
- 1:1 Chat: `sentMessagesStore.markAsRead()` speichert Status
- Group Chat: Nur UI-Update, keine lokale Persistierung in `sentGroupItemsStore`

**Impact:**
- Nach Browser-Refresh verloren: Welche Messages wurden gelesen
- User muss alte Messages erneut senden, um Status zu sehen
- Inkonsistente UX zwischen 1:1 und Group Chat

**Betroffen:**
- `signal_group_chat_screen.dart` - keine Calls zu `sentGroupItemsStore.updateCounts()`

---

### 🟡 Mittel: File Messages werden wie normale Messages behandelt

**Problem:**
- File Messages haben große Payloads (JSON mit fileId, checksum, encryptedKey, etc.)
- Werden genauso behandelt wie kurze Text-Nachrichten
- Keine spezielle Cleanup-Logik

**Impact:**
- File Metadata bleibt dauerhaft in DB, auch wenn File längst gelöscht
- Größerer Storage-Footprint als nötig
- Potenzielle Inkonsistenz (File gelöscht, aber Message noch da)

---

## Code-Locations für Fixes

### 1. Group Chat Item Deletion (Kritisch)

**Server-Side: `server/server.js:1711`**
```javascript
// If all members have read, optionally delete from server (privacy feature)
if (allRead) {
  console.log(`[GROUP ITEM READ] ✓ Item ${itemId} read by all members`);
  // Optionally: await groupItem.destroy();  // ⚠️ TODO: AKTIVIEREN!
}
```

**Zusätzlich benötigt:**
- Löschen aller zugehörigen `GroupItemRead` Einträge
- Cleanup Job für alte Items (z.B. >30 Tage)

---

### 2. System-Message Deletion

**Option A: Nach Verarbeitung löschen (Client-Side)**

In `direct_messages_screen.dart` nach Zeile 175:
```dart
if (itemType == 'fileKeyRequest' || itemType == 'fileKeyResponse') {
  // Process the message...
  // Then delete from server:
  _deleteMessageFromServer(item['itemId']);
  return;
}
```

In `signal_group_chat_screen.dart` nach Zeile 290:
```dart
if (itemType == 'fileKeyRequest' || itemType == 'fileKeyResponse') {
  // Delete from server (not needed in UI)
  _deleteGroupItemFromServer(itemId);
  return;
}
```

**Option B: Server-Side Auto-Cleanup**

In `server.js` - neue Funktion:
```javascript
async function autoCleanupSystemMessages(itemId, type) {
  if (['fileKeyRequest', 'fileKeyResponse', 'senderKeyRequest', 'senderKeyDistribution'].includes(type)) {
    // Delete after 5 minutes (enough time for all devices to receive)
    setTimeout(async () => {
      await Item.destroy({ where: { itemId } });
      console.log(`[CLEANUP] Auto-deleted system message: ${itemId}`);
    }, 5 * 60 * 1000);
  }
}
```

---

### 3. Group Chat Read Status Persistence (Client-Side)

In `signal_group_chat_screen.dart` - neue Methode hinzufügen:
```dart
void _handleReadReceipt(dynamic data) {
  final itemId = data['itemId'] as String;
  final readCount = data['readCount'] as int;
  final totalMembers = data['totalMembers'] as int;
  
  // Update UI
  setState(() {
    final msgIndex = _messages.indexWhere((m) => m['itemId'] == itemId);
    if (msgIndex != -1) {
      _messages[msgIndex]['readCount'] = readCount;
      _messages[msgIndex]['totalCount'] = totalMembers;
    }
  });
  
  // ⚠️ MISSING: Persist to sentGroupItemsStore
  SignalService.instance.sentGroupItemsStore.updateCounts(
    itemId,
    widget.channelUuid,
    readCount: readCount,
    totalCount: totalMembers,
  );
}
```

---

### 4. File Message Cleanup

**Option A: Beim File-Deletion auch Message löschen**

In File Manager:
```dart
Future<void> deleteFile(String fileId) async {
  // Delete file chunks
  await p2pCoordinator.deleteFile(fileId);
  
  // Delete associated file messages
  await _deleteFileMessages(fileId);
}

Future<void> _deleteFileMessages(String fileId) async {
  // Find all messages with this fileId
  // Delete from server and local stores
}
```

**Option B: Scheduled Cleanup Job**

Server-side cronjob:
```javascript
async function cleanupOrphanedFileMessages() {
  // Find file messages where fileId not in FileRegistry
  // Delete those messages (file already deleted)
}
```

---

## Empfohlene Fix-Priorität

### Phase 1: Kritische Fixes (Sofort)
1. ✅ **Group Item Deletion aktivieren** - Zeile 1711 in `server.js`
2. ✅ **GroupItemRead Cleanup hinzufügen** - Beim Löschen von GroupItem

### Phase 2: Performance Fixes (Diese Woche)
3. ✅ **System-Messages Auto-Cleanup** - Nach 5 Minuten löschen
4. ✅ **Group Chat Read-Status persistieren** - In `sentGroupItemsStore`

### Phase 3: Optimierung (Nächste Woche)
5. 🔄 **File Message Cleanup** - Bei File-Deletion
6. 🔄 **Scheduled Cleanup Job** - Täglich alte Items löschen

---

## Performance-Metriken (geschätzt)

**Aktueller Zustand (nach 1 Monat Nutzung):**
- Group Items: ~10.000 Einträge (nie gelöscht)
- Group Read Receipts: ~50.000 Einträge (10 User × 5.000 Messages)
- System Messages: ~2.000 Einträge (nie gelöscht)
- DB Size: ~50 MB

**Nach Fixes (nach 1 Monat):**
- Group Items: ~500 Einträge (nur ungelesene)
- Group Read Receipts: ~500 Einträge (nur für aktive Items)
- System Messages: ~10 Einträge (max. 5 Minuten alt)
- DB Size: ~5 MB

**Performance-Gewinn: ~90% weniger Datenbank-Größe**

---

## Zusätzliche Überlegungen

### Datenschutz
- Read receipts sollten gelöscht werden (Privacy by Design)
- Alte Messages sollten automatisch gelöscht werden (GDPR)
- User sollte Retention-Zeit konfigurieren können

### Skalierung
- Mit 100+ Users und 1000+ Messages/Tag wird das Problem kritisch
- Ohne Cleanup: DB-Größe wächst exponentiell
- Query-Performance degradiert linear mit DB-Größe

### Testing
- Vor/Nach Performance-Vergleich nötig
- Load Testing mit 10.000+ Messages
- Measure: Query-Zeit, DB-Größe, Memory-Usage

---

## Nächste Schritte

1. **User-Entscheidung**: Welche Fixes sollen implementiert werden?
2. **Testing-Strategy**: Wie testen wir die Änderungen?
3. **Migration**: Cleanup für existierende DB-Einträge?
4. **Monitoring**: Metrics für DB-Größe und Performance?

---

**Erstellt**: 2025-10-29  
**Analysiert von**: GitHub Copilot  
**Status**: ⏳ Wartet auf User-Freigabe für Fixes
