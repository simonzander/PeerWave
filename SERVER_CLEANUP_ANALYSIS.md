# Server Cleanup & Delete Rules Analysis

**Datum:** 4. November 2025  
**Ziel:** Überprüfung der Server-Delete-Regeln und Cleanup-Konfiguration

---

## 📊 **Aktuelle Server-Delete-Regeln**

### 1. **1:1 Messages (Items-Tabelle)**

#### Client-initiierte Löschung
**Event:** `deleteItem`  
**Datei:** `server/server.js` Zeile 2152-2187

**Regel:**
```javascript
Item.destroy({
  where: {
    itemId: itemId,
    receiver: userId,      // ✅ Nur für aktuellen Empfänger
    deviceReceiver: deviceId  // ✅ Nur für aktuelles Device
  }
});
```

**Status:** ✅ **KORREKT**
- Löscht nur die Message für das **spezifische Device** des Empfängers
- Multi-Device Support: Andere Devices des gleichen Users behalten die Message
- Sender behält Kopie (nicht vom Empfänger gelöscht)

**Aufgerufen von Client:**
- Nach erfolgreicher Entschlüsselung (signal_service.dart Zeile 893)
- Nach Read Receipt verarbeitet (signal_service.dart Zeile 890-893)

---

### 2. **Group Messages (GroupItems-Tabelle)**

#### Automatische Löschung nach "All Read"
**Event:** `markGroupItemRead`  
**Datei:** `server/server.js` Zeile 2341-2412

**Regel:**
```javascript
// Wenn ALLE Mitglieder gelesen haben:
if (allRead) {
  // 1. Lösche alle Read Receipts
  await GroupItemRead.destroy({
    where: { itemId: groupItem.uuid }
  });
  
  // 2. Lösche die Group Message
  await groupItem.destroy();
}
```

**Status:** ✅ **KORREKT**
- Löscht Group Message nur wenn **ALLE Mitglieder** gelesen haben
- Privacy-Feature: Keine Nachricht bleibt unnötig auf Server
- Read Receipts werden zuerst gelöscht

**Problem:** ⚠️ **Keine manuelle Client-Delete-Option**
- Es gibt **KEIN** `socket.on("deleteGroupItem")` Event
- Client kann Group Messages nicht manuell vom Server löschen
- Signal Service ruft `deleteGroupItemFromServer()` auf, aber Server hat keinen Handler!

---

## 🧹 **Cronjob Cleanup (Automatisch)**

**Datei:** `server/jobs/cleanup.js`  
**Konfiguration:** `server/config/config.js`

### Aktuelle Einstellungen

```javascript
config.cleanup = {
    // Inactive users: Mark users as inactive after X days without client update
    inactiveUserDays: 30,
    
    // Old messages: Delete items (messages, receipts) after X days
    deleteOldItemsDays: 90,  // ⚠️ 90 TAGE!
    
    // Cronjob schedule (runs every day at 2:00 AM)
    cronSchedule: '0 2 * * *'
};
```

### Cleanup-Tasks

#### 1. **markInactiveUsers()**
- Markiert User als `active: false` wenn **ALLE** Clients seit 30 Tagen inaktiv
- ✅ Löscht KEINE Daten, nur Status-Update

#### 2. **deleteOldItems()** ⚠️ **PROBLEM HIER!**
```javascript
Item.destroy({
  where: {
    createdAt: {
      [Op.lt]: daysAgo  // Älter als 90 Tage
    }
  }
});
```

**Status:** ⚠️ **LÖSCHT ALLES NACH 90 TAGEN**
- Löscht **ALLE Items** älter als 90 Tage
- Unabhängig davon ob Client sie schon gelöscht hat
- **KEIN Unterschied** zwischen:
  - Gelesenen Messages (sollten gelöscht werden)
  - Ungelesenen Messages (könnten wichtig sein)
  - System Messages (read_receipts, etc.)

#### 3. **cleanupFileRegistry()**
- Löscht abgelaufene P2P File-Registry Einträge
- ✅ Korrekt implementiert

---

## 🔥 **Identifizierte Probleme**

### Problem 1: Zu lange Server-Retention (90 Tage)
**Auswirkung:**
- Items bleiben 90 Tage auf Server, auch wenn Client sie längst gelöscht hat
- Datenbank wächst unnötig
- Privacy-Problem: Messages bleiben länger als nötig

**Empfehlung:**
```javascript
deleteOldItemsDays: 7,  // Statt 90 Tage
```

**Begründung:**
- Client löscht Items sofort nach Verarbeitung (receiveItem)
- 7 Tage Puffer für Offline-Devices
- Reduziert Server-Storage massiv

---

### Problem 2: Fehlender deleteGroupItem Handler
**Auswirkung:**
- Client ruft `deleteGroupItemFromServer()` auf, aber Server ignoriert es
- Group Messages bleiben bis "All Read" oder 90-Tage-Cleanup

**Empfehlung:**
Füge Socket-Handler hinzu (siehe unten)

---

### Problem 3: Keine Unterscheidung nach Message-Typ
**Auswirkung:**
- System Messages (read_receipts) werden auch 90 Tage aufbewahrt
- Diese werden vom Client sofort nach Verarbeitung gelöscht
- Viele "tote" Einträge auf Server

**Empfehlung:**
```javascript
// Separate Cleanup-Intervalle nach Type
config.cleanup = {
    deleteSystemMessagesDays: 1,    // read_receipt, etc.
    deleteRegularMessagesDays: 7,   // message, file
};
```

---

## ✅ **Empfohlene Änderungen**

### 1. Config.js Update

```javascript
// server/config/config.js

config.cleanup = {
    // Inactive users: Mark users as inactive after X days without client update
    inactiveUserDays: 30,
    
    // ✅ NEU: Separate Retention für verschiedene Message-Types
    deleteSystemMessagesDays: 1,     // read_receipt, senderKeyRequest, etc.
    deleteRegularMessagesDays: 7,    // message, file (Puffer für Offline-Devices)
    deleteGroupMessagesDays: 30,     // Group messages (falls nicht "all read")
    
    // Cronjob schedule (runs every day at 2:00 AM)
    cronSchedule: '0 2 * * *'
};
```

### 2. Cleanup.js Update

```javascript
// server/jobs/cleanup.js

async function deleteOldItems() {
    try {
        const now = new Date();
        
        // 1. Delete system messages (read_receipt, etc.) after 1 day
        const systemMessageTypes = ['read_receipt', 'senderKeyRequest', 'senderKeyDistribution', 
                                    'fileKeyRequest', 'fileKeyResponse', 'delivery_receipt'];
        const systemDaysAgo = new Date(now);
        systemDaysAgo.setDate(systemDaysAgo.getDate() - config.cleanup.deleteSystemMessagesDays);
        
        const systemDeleted = await writeQueue.enqueue(
            () => Item.destroy({
                where: {
                    type: { [Op.in]: systemMessageTypes },
                    createdAt: { [Op.lt]: systemDaysAgo }
                }
            }),
            'deleteOldSystemMessages'
        );
        console.log(`[CLEANUP] ✓ Deleted ${systemDeleted} old system messages`);
        
        // 2. Delete regular messages (message, file) after 7 days
        const regularDaysAgo = new Date(now);
        regularDaysAgo.setDate(regularDaysAgo.getDate() - config.cleanup.deleteRegularMessagesDays);
        
        const regularDeleted = await writeQueue.enqueue(
            () => Item.destroy({
                where: {
                    type: { [Op.in]: ['message', 'file'] },
                    createdAt: { [Op.lt]: regularDaysAgo }
                }
            }),
            'deleteOldRegularMessages'
        );
        console.log(`[CLEANUP] ✓ Deleted ${regularDeleted} old regular messages`);
        
        // 3. Delete old group messages after 30 days
        const groupDaysAgo = new Date(now);
        groupDaysAgo.setDate(groupDaysAgo.getDate() - config.cleanup.deleteGroupMessagesDays);
        
        const groupDeleted = await writeQueue.enqueue(
            () => GroupItem.destroy({
                where: {
                    createdAt: { [Op.lt]: groupDaysAgo }
                }
            }),
            'deleteOldGroupMessages'
        );
        console.log(`[CLEANUP] ✓ Deleted ${groupDeleted} old group messages`);
        
        return { systemDeleted, regularDeleted, groupDeleted };
    } catch (error) {
        console.error('[CLEANUP] ❌ Error deleting old items:', error);
        throw error;
    }
}
```

### 3. Server.js - Neuer deleteGroupItem Handler

```javascript
// server/server.js - Nach deleteItem Event (Zeile ~2187)

socket.on("deleteGroupItem", async (data, callback) => {
  try {
    if (
      !socket.handshake.session.uuid ||
      !socket.handshake.session.deviceId ||
      socket.handshake.session.authenticated !== true
    ) {
      return callback?.({ success: false, error: "Not authenticated" });
    }

    const userId = socket.handshake.session.uuid;
    const { itemId } = data;

    if (!itemId) {
      return callback?.({ success: false, error: "Missing itemId" });
    }

    // Find the group item
    const groupItem = await GroupItem.findOne({
      where: { itemId: itemId }
    });

    if (!groupItem) {
      return callback?.({ success: false, error: "Group item not found" });
    }

    // Only allow sender to delete their own messages
    if (groupItem.sender !== userId) {
      return callback?.({ success: false, error: "Not authorized" });
    }

    // Delete all read receipts first
    await writeQueue.enqueue(async () => {
      await GroupItemRead.destroy({
        where: { itemId: groupItem.uuid }
      });
    }, `deleteGroupItemReads-${itemId}`);
    
    // Delete the group item
    await writeQueue.enqueue(async () => {
      await groupItem.destroy();
    }, `deleteGroupItem-${itemId}`);

    console.log(`[GROUP ITEM] User ${userId} deleted group item ${itemId}`);
    
    callback?.({ success: true });
  } catch (error) {
    console.error('[GROUP ITEM] Error deleting group item:', error);
    callback?.({ success: false, error: error.message });
  }
});
```

---

## 📊 **Erwartete Verbesserungen**

### Vorher (Aktuell)
- **System Messages:** Bleiben 90 Tage → **90x zu lang!**
- **Regular Messages:** Bleiben 90 Tage → **13x zu lang!**
- **Group Messages:** Keine manuelle Löschung möglich
- **Datenbank:** Wächst unnötig groß

### Nachher (Mit Änderungen)
- **System Messages:** Gelöscht nach 1 Tag → **89 Tage Ersparnis**
- **Regular Messages:** Gelöscht nach 7 Tagen → **83 Tage Ersparnis**
- **Group Messages:** Manuell löschbar + 30 Tage Retention
- **Datenbank:** ~90% weniger Einträge

---

## 🎯 **Zusammenfassung**

### Aktuelle Probleme
1. ⚠️ Server-Cleanup zu langsam (90 Tage statt 1-7 Tage)
2. ⚠️ Fehlender `deleteGroupItem` Handler
3. ⚠️ Keine Unterscheidung nach Message-Type

### Empfohlene Lösung
1. ✅ Config-Update: Separate Retention-Zeiten (1/7/30 Tage)
2. ✅ Cleanup-Update: Type-basierte Löschung
3. ✅ Socket-Handler: `deleteGroupItem` Event hinzufügen

### Geschätzter Aufwand
- **Config:** 5 Minuten
- **Cleanup.js:** 30 Minuten
- **Server.js:** 15 Minuten
- **Testing:** 30 Minuten
- **Total:** ~1.5 Stunden

---

**Status:** Ready for Implementation  
**Priority:** HIGH (Database wächst unnötig)
