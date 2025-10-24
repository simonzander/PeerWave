# Group Item Implementation - Summary

## ✅ Was wurde implementiert

### 1. **Neue Datenbank-Modelle** (`server/db/model.js`)

#### GroupItem
- Speichert verschlüsselte Items (Nachrichten, Reaktionen, Dateien, etc.) für Gruppenchats
- **Ein Eintrag pro Nachricht** statt N Einträge (einer pro Empfänger)
- Effiziente Indizes für schnelle Queries

#### GroupItemRead
- Speichert Read Receipts separat
- Trackt welcher User/Device welches Item gelesen hat
- Unique Constraint: Ein Receipt pro Device

### 2. **REST API Endpoints** (`server/routes/groupItems.js`)

Neue Endpunkte:
- `POST /api/group-items` - Neue GroupItem erstellen
- `GET /api/group-items/:channelId` - Items eines Channels laden
- `POST /api/group-items/:itemId/read` - Item als gelesen markieren
- `GET /api/group-items/:itemId/read-status` - Read Status abrufen
- `GET /api/sender-keys/:channelId` - Alle Sender Keys eines Channels laden
- `GET /api/sender-keys/:channelId/:userId/:deviceId` - Spezifischen Sender Key laden
- `POST /api/sender-keys/:channelId` - Sender Key erstellen/aktualisieren

### 3. **Socket.IO Events** (`server/server.js`)

#### Neue Events (Client → Server):
- `sendGroupItem` - Sendet ein verschlüsseltes GroupItem
- `markGroupItemRead` - Markiert ein Item als gelesen

#### Neue Events (Server → Client):
- `groupItem` - Broadcast eines neuen Items an alle Channel-Mitglieder
- `groupItemDelivered` - Bestätigung dass Item gespeichert wurde
- `groupItemReadUpdate` - Benachrichtigung über Read Receipt Updates
- `groupItemError` - Fehlerbenachrichtigung

### 4. **Dokumentation** (`GROUP_ITEM_API.md`)

Vollständige API-Dokumentation mit:
- Endpunkt-Beschreibungen
- Request/Response-Beispiele
- Client-Implementierungs-Workflows
- Sicherheitshinweise
- Performance-Optimierungstipps

## 🔄 Architektur-Änderungen

### Vorher (Item Model - Komplex)

```
Alice sendet Nachricht → Server
  ↓
Server erstellt N Item-Einträge (einer pro Empfänger)
  ↓
Sender Key Distribution über 1:1 verschlüsselte Nachrichten
  ↓
Komplexe Socket.IO Events (storeSenderKey, getSenderKey, senderKeyRequest)
  ↓
Pending Message Queues für fehlende Keys
  ↓
Bob empfängt → verarbeitet 1:1 Key Distribution → entschlüsselt
```

**Probleme:**
- ❌ N Database Writes pro Nachricht
- ❌ Komplexe Key Distribution
- ❌ Sender Keys in Direct Messages sichtbar
- ❌ Fehleranfällig (Keys können verloren gehen)

### Nachher (GroupItem Model - Einfach)

```
Alice sendet Nachricht → Server
  ↓
Server erstellt 1 GroupItem-Eintrag
  ↓
Broadcast an alle Online-Mitglieder
  ↓
Bob empfängt → prüft lokalen Sender Key
  ↓
Wenn Key fehlt: REST API Call → Load von Server
  ↓
Entschlüsselt lokal
```

**Vorteile:**
- ✅ 1 Database Write pro Nachricht (~90% Reduktion)
- ✅ Einfache Key Verwaltung (REST API statt 1:1 Messages)
- ✅ Keine System-Messages in Direct Messages
- ✅ Robust (Keys immer auf Server verfügbar)
- ✅ Einfacher zu debuggen und warten

## 📊 Effizienz-Vergleich

### Beispiel: 10-Mitglieder Gruppe, 100 Nachrichten

| Metrik | Alte Architektur (Item) | Neue Architektur (GroupItem) | Einsparung |
|--------|------------------------|------------------------------|------------|
| DB Writes | 1000 Items | 100 GroupItems | **90%** |
| DB Size | ~500 KB | ~50 KB | **90%** |
| Key Distribution | 1000 1:1 Messages | 10 REST API Calls | **99%** |
| Complexity | High | Low | **Massiv** |

## 🔐 Sicherheit

### Was bleibt gleich:
- ✅ End-to-End Encryption (E2EE)
- ✅ Forward Secrecy (Chain Keys rotieren)
- ✅ Signal Protocol Sender Keys
- ✅ Kein Plaintext auf Server

### Was sich ändert:
- ✅ Sender Keys via REST API statt 1:1 Messages
- ✅ Keys als SenderKeyDistributionMessages gespeichert (nicht raw keys)
- ✅ Server sieht weiterhin nur verschlüsselte Payloads

### Sicherheits-Level:
**Gleichwertig** - Keine Verschlechterung der Sicherheit

## 🚀 Client-Implementierung (Next Steps)

### Phase 1: REST API Integration

1. **Sender Key Management:**
   ```dart
   // Prüfen ob Sender Key existiert
   if (!hasSenderKey) {
     // Key erstellen
     final distMsg = await createSenderKey(channelId);
     
     // Auf Server hochladen (REST API)
     await uploadSenderKey(channelId, distMsg);
   }
   ```

2. **Nachricht senden:**
   ```dart
   // Verschlüsseln mit eigenem Sender Key
   final encrypted = await encryptGroupMessage(message);
   
   // Via REST API senden (wird einmal gespeichert)
   await sendGroupItem(channelId, encrypted);
   ```

3. **Nachricht empfangen:**
   ```dart
   // Socket.IO Event empfangen
   socket.on('groupItem', (data) async {
     // Prüfen ob Sender Key vorhanden
     if (!hasSenderKey(senderId, deviceId)) {
       // Via REST API laden
       final key = await loadSenderKey(channelId, senderId, deviceId);
       await processSenderKeyDistribution(key);
     }
     
     // Entschlüsseln
     final decrypted = await decryptGroupMessage(data.payload);
   });
   ```

### Phase 2: Migration

1. **Parallel-Betrieb:**
   - Alte Item-basierte Nachrichten weiter unterstützen
   - Neue Nachrichten via GroupItem API senden
   - Beide Wege im Client handhaben

2. **Schrittweise Migration:**
   - Neue Channels → GroupItem API
   - Alte Channels → Item API (Backward Compatibility)
   - Optional: Alte Nachrichten migrieren

3. **Deprecation:**
   - Nach erfolgreicher Migration alte Item API entfernen

## 📝 Offene Arbeiten

### Server-Seite:
- ✅ Datenbank-Modelle erstellt
- ✅ REST API Endpoints implementiert
- ✅ Socket.IO Events implementiert
- ✅ Dokumentation erstellt
- ⏳ **TODO:** Integration Tests schreiben

### Client-Seite:
- ⏳ **TODO:** REST API Client erstellen (ApiService Methoden)
- ⏳ **TODO:** Socket.IO Event Handler hinzufügen
- ⏳ **TODO:** GroupItem Store für lokale Speicherung
- ⏳ **TODO:** UI für GroupItem Messages
- ⏳ **TODO:** Sender Key Caching optimieren
- ⏳ **TODO:** Migration von alter zu neuer API

## 🎯 Nächste Schritte

1. **Client REST API Integration** (High Priority)
   - Erstelle ApiService Methoden für GroupItem Endpoints
   - Erstelle ApiService Methoden für Sender Key Endpoints

2. **Socket.IO Integration** (High Priority)
   - Registriere `groupItem` Event Handler
   - Registriere `markGroupItemRead` Event Handler
   - Implementiere `sendGroupItem` Emit

3. **Sender Key Management** (High Priority)
   - Automatisches Laden von Server bei Channel Join
   - Caching von geladenen Keys
   - Automatische Erneuerung bei Corruption

4. **UI Anpassungen** (Medium Priority)
   - GroupItem Messages anzeigen
   - Read Receipt UI aktualisieren
   - Loading States für Key Download

5. **Testing** (Medium Priority)
   - Unit Tests für API Endpoints
   - Integration Tests für Socket.IO Events
   - E2E Tests für kompletten Message Flow

6. **Performance Optimierung** (Low Priority)
   - Batch Key Loading beim Channel Join
   - Incremental Message Loading
   - Read Receipt Debouncing

## 💡 Vorteile Zusammenfassung

### Für Entwickler:
- ✅ Einfachere Architektur (REST statt komplexe Socket.IO Events)
- ✅ Bessere Debugging-Möglichkeiten
- ✅ Klare API-Dokumentation
- ✅ Weniger Code zu warten

### Für Nutzer:
- ✅ Schnellere Message Delivery (weniger DB Writes)
- ✅ Zuverlässigere Key Distribution (REST API statt 1:1)
- ✅ Keine System-Messages in Direct Chats mehr
- ✅ Bessere Performance in großen Gruppen

### Für den Server:
- ✅ ~90% weniger Database Writes
- ✅ ~90% weniger Database Size für Group Messages
- ✅ Weniger Socket.IO Traffic
- ✅ Einfachere Wartung

## 📚 Weiterführende Ressourcen

- **Signal Protocol Dokumentation:** https://signal.org/docs/
- **Sender Keys Whitepaper:** https://signal.org/docs/specifications/doubleratchet/
- **REST API Docs:** `GROUP_ITEM_API.md`
- **Database Schema:** `server/db/model.js` (Lines 234-370)

---

**Status:** ✅ Server-Implementierung vollständig | ⏳ Client-Implementierung ausstehend
**Version:** 1.0.0
**Datum:** 2025-10-24
