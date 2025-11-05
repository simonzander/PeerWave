# Signal Keys Synchronisation Analyse

**Datum:** 5. November 2025  
**Status:** 🔍 Analyse - Keine Änderungen implementiert  
**Prinzip:** Client ist Source of Truth

---

## 📋 Zusammenfassung

Diese Analyse untersucht die Synchronisation zwischen Client und Server bei der Signal-Protokoll-Schlüsselverwaltung in PeerWave. Fokus liegt auf:
1. **IdentityKeyPair** (Haupt-Identitätsschlüssel)
2. **SignedPreKey** (Signierter Pre-Key)
3. **PreKeys** (Einweg-Pre-Keys, 110 Stück)
4. **SenderKeys** (Gruppenverschlüsselung)

---

## 🔑 1. IdentityKeyPair (Haupt-Identitätsschlüssel)

### Aktuelle Implementierung

**Client-Seite (`permanent_identity_key_store.dart`):**
```dart
Future<Map<String, String?>> getIdentityKeyPairData() async {
  // 1. Versuche aus lokalem Storage zu laden (IndexedDB/SecureStorage)
  // 2. Falls nicht vorhanden: Generiere neu
  if (publicKeyBase64 == null || privateKeyBase64 == null || registrationId == null) {
    final generated = await _generateIdentityKeyPair();
    // Speichere lokal
    // Upload zum Server
    if (createdNew) {
      SocketService().emit("signalIdentity", {
        'publicKey': publicKeyBase64,
        'registrationId': registrationId,
      });
    }
  }
}
```

**Server-Seite (`server.js:259`):**
```javascript
socket.on("signalIdentity", async (data) => {
  // Speichert public_key und registration_id in Client-Tabelle
  await Client.update(
    { public_key: data.publicKey, registration_id: data.registrationId },
    { where: { owner: uuid, clientid: clientId } }
  );
});
```

**Status-Check (`server.js:464`, `signal_service.dart:619`):**
```javascript
// Server prüft: Ist public_key und registration_id vorhanden?
socket.on("signalStatus", async () => {
  const identityPresent = !!(client && client.public_key && client.registration_id);
  socket.emit("signalStatusResponse", { identity: identityPresent, ... });
});
```

```dart
// Client prüft Status und uploaded wenn fehlt
if (status['identity'] != true) {
  debugPrint('[SIGNAL SERVICE] Uploading missing identity');
  final identityData = await identityStore.getIdentityKeyPairData();
  SocketService().emit("signalIdentity", {...});
}
```

### ✅ Was funktioniert gut

1. **Client ist Source of Truth**: IdentityKeyPair wird NUR auf Client generiert
2. **Automatischer Upload**: Bei Neugenerierung wird automatisch zum Server gesendet
3. **Status-Check**: Server meldet fehlende Keys, Client uploaded bei Bedarf
4. **Unveränderlich**: Private Key bleibt IMMER nur auf Client

### ⚠️ Potenzielle Probleme

#### Problem 1: Keine Abhängigkeitsprüfung bei Neugenerierung
**Szenario:** User löscht IndexedDB/SecureStorage → IdentityKeyPair wird neu generiert

**Was passiert:**
```
1. Client generiert NEUES IdentityKeyPair
2. Uploaded neuen Public Key zum Server
3. ❌ Alte PreKeys und SignedPreKeys sind mit ALTEM IdentityKeyPair signiert
4. ❌ Andere Geräte haben alte PreKeyBundles mit altem Identity Public Key
5. ❌ Verschlüsselte Nachrichten nicht mehr entschlüsselbar
```

**Was SOLLTE passieren:**
```dart
// VORSCHLAG: Bei Neugenerierung von IdentityKeyPair
if (createdNew) {
  debugPrint('[IDENTITY] ⚠️ NEW IdentityKeyPair generated!');
  debugPrint('[IDENTITY] Deleting ALL dependent keys...');
  
  // 1. Lösche ALLE PreKeys (lokal + server)
  await preKeyStore.deleteAllPreKeys();
  SocketService().emit("deleteAllPreKeys", {});
  
  // 2. Lösche ALLE SignedPreKeys (lokal + server)
  await signedPreKeyStore.deleteAllSignedPreKeys();
  SocketService().emit("deleteAllSignedPreKeys", {});
  
  // 3. Lösche ALLE Sessions (lokal + server)
  await sessionStore.deleteAllSessions();
  
  // 4. Generiere NEUE PreKeys mit neuem IdentityKeyPair
  await _regenerateAllKeys();
  
  // 5. Upload neuer Identity
  SocketService().emit("signalIdentity", {...});
}
```

---

## 🔐 2. SignedPreKey

### Aktuelle Implementierung

**Generierung (`signal_service.dart:495`):**
```dart
// Bei init: Generiere wenn nicht vorhanden
final existingSignedKeys = await signedPreKeyStore.loadSignedPreKeys();
if (existingSignedKeys.isEmpty) {
  final signedPreKey = generateSignedPreKey(identityKeyPair, 0);
  await signedPreKeyStore.storeSignedPreKey(signedPreKey.id, signedPreKey);
}
```

**Upload (`permanent_signed_pre_key_store.dart`):**
```dart
@override
Future<void> storeSignedPreKey(int signedPreKeyId, SignedPreKeyRecord record) async {
  // Speichere lokal (IndexedDB/SecureStorage)
  
  if (sendToServer) {
    // Upload zum Server
    SocketService().emit("storeSignedPreKey", {
      'id': signedPreKeyId,
      'data': base64Encode(record.serialize()),
      'signature': base64Encode(record.signature),
    });
  }
}
```

**Server-Speicherung (`server.js:321`):**
```javascript
socket.on("storeSignedPreKey", async (data) => {
  // FindOrCreate: Speichert wenn nicht vorhanden
  await SignalSignedPreKey.findOrCreate({
    where: { signed_prekey_id: data.id, owner: uuid, client: clientId },
    defaults: { signed_prekey_data: data.data, signed_prekey_signature: data.signature }
  });
});
```

**Status-Check (`server.js:482`):**
```javascript
const signedPreKey = await SignalSignedPreKey.findOne({
  where: { owner: uuid, client: clientId },
  order: [['createdAt', 'DESC']]
});
socket.emit("signalStatusResponse", {
  signedPreKey: signedPreKey ? { id: signedPreKey.signed_prekey_id, createdAt: signedPreKey.createdAt } : null
});
```

### ✅ Was funktioniert gut

1. **Automatische Generierung**: Bei fehlendem SignedPreKey wird automatisch generiert
2. **Server-Backup**: SignedPreKey wird auf Server gespeichert
3. **Status-Tracking**: Server meldet aktuellsten SignedPreKey

### ⚠️ Potenzielle Probleme

#### Problem 2: Keine Rotation-Logik
**Empfehlung:** SignedPreKeys sollten periodisch rotiert werden (alle 7-30 Tage)

**Was SOLLTE passieren:**
```dart
// VORSCHLAG: SignedPreKey Rotation
Future<void> checkSignedPreKeyRotation() async {
  final signedKeys = await signedPreKeyStore.loadSignedPreKeys();
  if (signedKeys.isEmpty) return;
  
  final newestKey = signedKeys.first;
  final createdAt = newestKey.timestamp;
  final daysSinceCreation = DateTime.now().difference(createdAt).inDays;
  
  if (daysSinceCreation > 7) {
    debugPrint('[SIGNED_PREKEY] ⚠️ SignedPreKey is $daysSinceCreation days old, rotating...');
    
    // 1. Generiere NEUEN SignedPreKey
    final identityKeyPair = await identityStore.getIdentityKeyPair();
    final newSignedPreKey = generateSignedPreKey(identityKeyPair, signedKeys.length);
    
    // 2. Speichere neuen Key (lokal + server)
    await signedPreKeyStore.storeSignedPreKey(newSignedPreKey.id, newSignedPreKey);
    
    // 3. Behalte alten Key noch 7 Tage (für ausstehende Sessions)
    // 4. Lösche nach 7 Tagen automatisch
  }
}
```

#### Problem 3: Abhängigkeit von IdentityKeyPair
**Wenn IdentityKeyPair neu generiert wird:**
```
❌ Alter SignedPreKey ist mit ALTEM IdentityKeyPair signiert
❌ Signatur ist nicht mehr gültig
✅ MUSS neu generiert werden
```

**Regel:**
```
WENN IdentityKeyPair NEU generiert wird
DANN MÜSSEN ALLE SignedPreKeys NEU generiert werden
```

---

## 🔢 3. PreKeys (Einweg-Schlüssel)

### Aktuelle Implementierung

**Generierung (`signal_service.dart:509-540`):**
```dart
// Progressive Generierung in Batches (10 Keys pro Batch)
final neededPreKeys = 110 - existingPreKeys.length;
if (neededPreKeys > 0) {
  const int batchSize = 10;
  for (int batch = 0; batch < totalBatches; batch++) {
    final preKeys = generatePreKeys(batchStart, batchEnd - 1);
    for (final preKey in preKeys) {
      await preKeyStore.storePreKey(preKey.id, preKey);
    }
  }
}
```

**Upload (`permanent_pre_key_store.dart`):**
```dart
Future<void> storePreKeys(List<PreKeyRecord> preKeys) async {
  // Speichere alle PreKeys lokal
  
  // Upload zum Server (Batch-Upload)
  final preKeyPayload = preKeys.map((pk) => {
    'id': pk.id,
    'data': base64Encode(pk.getKeyPair().publicKey.serialize()),
  }).toList();
  
  SocketService().emit("storePreKeys", { 'preKeys': preKeyPayload });
}
```

**Server-Speicherung (`server.js:380`):**
```javascript
socket.on("storePreKeys", async (data) => {
  // Batch-Speicherung aller PreKeys
  for (const preKey of data.preKeys) {
    // Validierung: Muss 33-Byte Public Key sein
    const decoded = Buffer.from(preKey.data, 'base64');
    if (decoded.length !== 33) continue;
    
    await SignalPreKey.findOrCreate({
      where: { prekey_id: preKey.id, owner: uuid, client: clientId },
      defaults: { prekey_data: preKey.data }
    });
  }
});
```

**Status-Check & Sync (`signal_service.dart:668-730`):**
```dart
Future<void> _ensureSignalKeysPresent(status) async {
  final int serverPreKeysCount = status['preKeys'] ?? 0;
  final localPreKeys = await preKeyStore.getAllPreKeys();
  
  debugPrint('[SIGNAL] Server: $serverPreKeysCount, Local: ${localPreKeys.length}');
  
  if (serverPreKeysCount < 20) {
    if (localPreKeys.isEmpty) {
      // Generiere neue PreKeys
      final newPreKeys = generatePreKeys(0, 110);
      await preKeyStore.storePreKeys(newPreKeys);
    } else if (serverPreKeysCount == 0) {
      // ⚠️ CRITICAL: Server hat 0, aber wir haben lokal Keys!
      // Re-upload ALLER lokalen PreKeys
      debugPrint('[SIGNAL] ⚠️ Re-uploading ALL local PreKeys...');
      // Upload...
    }
  }
}
```

### ✅ Was funktioniert gut

1. **Batch-Upload**: Effiziente Übertragung mehrerer Keys
2. **Sync-Check**: Erkennt Diskrepanz zwischen Client und Server
3. **Auto-Regenerierung**: Bei <20 Keys werden automatisch neue generiert
4. **Validierung**: Server prüft auf gültiges 33-Byte Public Key Format

### ⚠️ Potenzielle Probleme

#### Problem 4: Race Condition bei Sync
**Szenario:** Multiple Tabs/Devices gleichzeitig online

```
Tab 1: Uploaded 110 PreKeys
Tab 2: Checked Status → Server hat 0 → Uploaded 110 PreKeys
Resultat: 220 PreKeys auf Server (Duplikate möglich)
```

**Lösung:**
```dart
// VORSCHLAG: Lock-Mechanismus
static bool _isSyncingPreKeys = false;

Future<void> _syncPreKeys() async {
  if (_isSyncingPreKeys) {
    debugPrint('[PREKEYS] Sync already in progress, skipping...');
    return;
  }
  
  _isSyncingPreKeys = true;
  try {
    // Sync-Logik
  } finally {
    _isSyncingPreKeys = false;
  }
}
```

#### Problem 5: Abhängigkeit von IdentityKeyPair
**Wenn IdentityKeyPair neu generiert wird:**
```
❌ PreKeys können NICHT wiederverwendet werden
❌ PreKeyBundles enthalten alten Identity Public Key
✅ MÜSSEN ALLE neu generiert werden
```

**Regel:**
```
WENN IdentityKeyPair NEU generiert wird
DANN MÜSSEN ALLE PreKeys NEU generiert werden
ODER
WENN SignedPreKey NEU generiert wird (ohne IdentityKeyPair-Änderung)
DANN können PreKeys WIEDERVERWENDET werden (nur neue SignedPreKey im Bundle)
```

#### Problem 6: Keine Cleanup-Strategie
**Frage:** Was passiert mit alten PreKeys auf dem Server?

```javascript
// AKTUELL: PreKeys werden NICHT gelöscht vom Server
// Problem: Server könnte theoretisch unbegrenzt viele PreKeys sammeln
```

**Lösung:**
```javascript
// VORSCHLAG: Server-seitige Rotation
socket.on("cleanupOldPreKeys", async () => {
  // Lösche PreKeys älter als 30 Tage (nicht verwendet)
  const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
  await SignalPreKey.destroy({
    where: {
      owner: uuid,
      client: clientId,
      createdAt: { [Op.lt]: thirtyDaysAgo },
      used: false // Optional: Track ob verwendet
    }
  });
});
```

---

## 👥 4. SenderKeys (Gruppenverschlüsselung)

### Aktuelle Implementierung

**Generierung (`signal_service.dart:1762`):**
```dart
Future<Uint8List> createGroupSenderKey(String groupId, {bool broadcastDistribution = true}) async {
  final senderKeyName = SenderKeyName(groupId, senderAddress);
  
  // Prüfe ob bereits vorhanden
  final existingKey = await senderKeyStore.containsSenderKey(senderKeyName);
  if (existingKey) {
    // Validiere Key durch Test-Verschlüsselung
    try {
      final testCipher = GroupCipher(senderKeyStore, senderKeyName);
      await testCipher.encrypt(testMessage);
      return Uint8List(0); // Key ist gültig
    } catch (e) {
      // Key korrupt → Lösche und regeneriere
      await senderKeyStore.removeSenderKey(senderKeyName);
    }
  }
  
  // Generiere neuen SenderKey
  final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);
  final distributionMessage = await groupSessionBuilder.create(senderKeyName);
  
  // Speichere auf Server
  SocketService().emit('storeSenderKey', {
    'groupId': groupId,
    'senderKey': base64Encode(distributionMessage.serialize()),
  });
  
  // Broadcast an alle Gruppenmitglieder
  if (broadcastDistribution) {
    SocketService().emit('broadcastSenderKey', {
      'groupId': groupId,
      'distributionMessage': base64Encode(distributionMessage.serialize()),
    });
  }
}
```

**Server-Speicherung (`server.js:732`):**
```javascript
socket.on("storeSenderKey", async (data) => {
  const { groupId, senderKey } = data;
  
  // FindOrCreate: Update wenn bereits vorhanden
  await SignalSenderKey.findOrCreate({
    where: { channel: groupId, client: clientId },
    defaults: { sender_key: senderKey }
  });
});
```

**Empfang & Verarbeitung (`signal_service.dart:629-652`):**
```dart
SocketService().registerListener("receiveSenderKeyDistribution", (data) async {
  final groupId = data['groupId'];
  final senderId = data['senderId'];
  final senderDeviceId = data['senderDeviceId'];
  final distributionMessageBase64 = data['distributionMessage'];
  
  await processSenderKeyDistribution(
    groupId,
    senderId,
    senderDeviceId,
    base64Decode(distributionMessageBase64),
  );
});
```

### ✅ Was funktioniert gut

1. **Validierung**: Testet vorhandene Keys auf Korrektheit
2. **Auto-Regenerierung**: Bei korruptem Key wird neu generiert
3. **Broadcast-System**: Alle Gruppenmitglieder erhalten Key-Distribution
4. **Server-Backup**: Keys werden auf Server gespeichert

### ⚠️ Potenzielle Probleme

#### Problem 7: Abhängigkeit von IdentityKeyPair
**Wenn IdentityKeyPair neu generiert wird:**
```
⚠️ SenderKeys sind NICHT direkt von IdentityKeyPair abhängig
⚠️ ABER: Distribution Messages werden mit SessionCipher verschlüsselt
⚠️ SessionCipher basiert auf PreKeyBundles (die IdentityKeyPair enthalten)
```

**Regel:**
```
WENN IdentityKeyPair NEU generiert wird
DANN:
  1. ALLE 1:1 Sessions werden ungültig
  2. ALLE SenderKey-Distributions können nicht empfangen werden
  3. ❌ Gruppenmitglieder können keine neuen Messages entschlüsseln
  
LÖSUNG:
  - SenderKeys müssen NEU verteilt werden
  - ODER: User muss Gruppe neu beitreten
```

#### Problem 8: Keine Rotation-Strategie
**Empfehlung:** SenderKeys sollten periodisch rotiert werden

```dart
// VORSCHLAG: SenderKey Rotation
Future<void> rotateSenderKeyIfNeeded(String groupId) async {
  final senderKeyName = SenderKeyName(groupId, senderAddress);
  final keyMetadata = await senderKeyStore.getKeyMetadata(senderKeyName);
  
  if (keyMetadata == null) return;
  
  final daysSinceCreation = DateTime.now().difference(keyMetadata.createdAt).inDays;
  final messageCount = keyMetadata.messageCount;
  
  // Rotiere bei:
  // - Alter > 30 Tage
  // - Oder > 1000 Messages verschlüsselt
  if (daysSinceCreation > 30 || messageCount > 1000) {
    debugPrint('[SENDERKEY] Rotating for group $groupId (age: $daysSinceCreation days, messages: $messageCount)');
    
    // 1. Lösche alten Key
    await senderKeyStore.removeSenderKey(senderKeyName);
    
    // 2. Generiere und verteile neuen Key
    await createGroupSenderKey(groupId, broadcastDistribution: true);
  }
}
```

---

## 🔄 Abhängigkeitsbaum

```
IdentityKeyPair (Root)
├─→ SignedPreKey (MUSS neu generiert werden)
│   └─→ PreKeys (KÖNNEN wiederverwendet werden)
│
├─→ PreKeys (MÜSSEN neu generiert werden)
│   └─→ PreKeyBundles enthalten IdentityKey
│
├─→ Sessions (MÜSSEN neu aufgebaut werden)
│   └─→ Basieren auf PreKeyBundles
│
└─→ SenderKeys (MÜSSEN neu verteilt werden)
    └─→ Distribution basiert auf Sessions
```

---

## 📝 Empfohlene Regeln

### Regel 1: IdentityKeyPair Neugenerierung
```dart
if (identityKeyPairRegenerated) {
  // ❌ CRITICAL: Alte Verschlüsselung nicht mehr möglich
  
  // 1. Lösche ALLE abhängigen Keys
  await _deleteAllSignalKeys();
  
  // 2. Generiere NEUE Keys
  await _regenerateAllKeys();
  
  // 3. Informiere User
  showWarningDialog('Signal keys regenerated. You may need to restart conversations.');
  
  // 4. Optional: Logout + erneutes Login erzwingen
}

Future<void> _deleteAllSignalKeys() async {
  // PreKeys
  await preKeyStore.deleteAllPreKeys();
  SocketService().emit("deleteAllPreKeys", {});
  
  // SignedPreKeys
  await signedPreKeyStore.deleteAllSignedPreKeys();
  SocketService().emit("deleteAllSignedPreKeys", {});
  
  // Sessions
  await sessionStore.deleteAllSessions();
  
  // SenderKeys
  await senderKeyStore.deleteAllSenderKeys();
  SocketService().emit("deleteAllSenderKeys", {});
}

Future<void> _regenerateAllKeys() async {
  final identityKeyPair = await identityStore.getIdentityKeyPair();
  
  // 1. SignedPreKey
  final signedPreKey = generateSignedPreKey(identityKeyPair, 0);
  await signedPreKeyStore.storeSignedPreKey(signedPreKey.id, signedPreKey);
  
  // 2. PreKeys (110 Stück)
  final preKeys = generatePreKeys(0, 109);
  await preKeyStore.storePreKeys(preKeys);
  
  // 3. Upload Identity
  final identityData = await identityStore.getIdentityKeyPairData();
  SocketService().emit("signalIdentity", {
    'publicKey': identityData['publicKey'],
    'registrationId': identityData['registrationId'],
  });
}
```

### Regel 2: SignedPreKey Neugenerierung (ohne IdentityKeyPair-Änderung)
```dart
if (signedPreKeyRegenerated && !identityKeyPairChanged) {
  // ✅ PreKeys können WIEDERVERWENDET werden
  // Nur neuer SignedPreKey in PreKeyBundles
  
  // 1. Generiere neuen SignedPreKey
  final identityKeyPair = await identityStore.getIdentityKeyPair();
  final newSignedPreKey = generateSignedPreKey(identityKeyPair, nextId);
  
  // 2. Speichere (lokal + server)
  await signedPreKeyStore.storeSignedPreKey(newSignedPreKey.id, newSignedPreKey);
  
  // 3. PreKeys bleiben gültig!
  // 4. Alte Sessions bleiben gültig!
}
```

### Regel 3: PreKeys Rotation
```dart
Future<void> checkPreKeyRotation() async {
  final localPreKeys = await preKeyStore.getAllPreKeys();
  
  if (localPreKeys.length < 20) {
    // Generiere 110 neue PreKeys
    final lastId = localPreKeys.isNotEmpty 
        ? localPreKeys.map((k) => k.id).reduce(max) 
        : 0;
    final newPreKeys = generatePreKeys(lastId + 1, lastId + 110);
    await preKeyStore.storePreKeys(newPreKeys);
  }
}
```

### Regel 4: SenderKey Rotation
```dart
// Bei Gruppen-Beitritt
Future<void> onJoinGroup(String groupId) async {
  // 1. Erstelle SenderKey für diese Gruppe
  await createGroupSenderKey(groupId);
  
  // 2. Lade existierende SenderKeys von anderen Mitgliedern
  await loadAllGroupSenderKeys(groupId);
}

// Periodisch
Future<void> rotateSenderKeys() async {
  // Alle 30 Tage oder 1000 Messages
  for (final groupId in activeGroups) {
    await rotateSenderKeyIfNeeded(groupId);
  }
}
```

---

## 🎯 Implementierungs-Prioritäten

### 🔴 CRITICAL (Muss implementiert werden)

1. **IdentityKeyPair Regenerierung → Dependency Cleanup**
   - Wenn IdentityKeyPair neu generiert wird, ALLE abhängigen Keys löschen
   - File: `permanent_identity_key_store.dart:104-120`
   - Aufwand: 2-3 Stunden
   - Risiko: HOCH (Datenverlust bei unvollständiger Impl.)

2. **Server-seitige Cascade Delete**
   - Bei neuem IdentityKeyPair: Lösche alle PreKeys/SignedPreKeys auf Server
   - File: `server.js` (neue Endpoints)
   - Aufwand: 1-2 Stunden
   - Risiko: MITTEL

### 🟡 HIGH (Sollte implementiert werden)

3. **SignedPreKey Rotation**
   - Automatische Rotation alle 7-30 Tage
   - File: `permanent_signed_pre_key_store.dart`
   - Aufwand: 2-3 Stunden
   - Risiko: NIEDRIG

4. **PreKeys Cleanup auf Server**
   - Lösche ungenutzte PreKeys nach 30 Tagen
   - File: `server.js` (neuer Endpoint)
   - Aufwand: 1-2 Stunden
   - Risiko: NIEDRIG

### 🟢 MEDIUM (Nice to have)

5. **SenderKey Rotation**
   - Automatische Rotation alle 30 Tage / 1000 Messages
   - File: `signal_service.dart:1762`
   - Aufwand: 3-4 Stunden
   - Risiko: NIEDRIG

6. **Sync-Lock Mechanismus**
   - Verhindere Race Conditions bei Multi-Tab/Device
   - File: `signal_service.dart:668`
   - Aufwand: 2-3 Stunden
   - Risiko: NIEDRIG

---

## 📊 Status Quo Bewertung

| Komponente | Client = SoT | Server-Sync | Auto-Upload | Abhängigkeiten | Status |
|------------|--------------|-------------|-------------|----------------|--------|
| IdentityKeyPair | ✅ | ✅ | ✅ | - | ⚠️ Keine Cleanup-Logik |
| SignedPreKey | ✅ | ✅ | ✅ | IdentityKeyPair | ⚠️ Keine Rotation |
| PreKeys | ✅ | ✅ | ✅ | IdentityKeyPair | ⚠️ Race Conditions möglich |
| SenderKeys | ✅ | ✅ | ✅ | Sessions | ⚠️ Keine Rotation |

**Legende:**
- ✅ = Funktioniert gut
- ⚠️ = Funktioniert, aber Verbesserungen möglich
- ❌ = Fehlt oder fehlerhaft

---

## 🔍 Offene Fragen

1. **Was passiert wenn User IndexedDB/SecureStorage löscht?**
   - Aktuell: Neues IdentityKeyPair wird generiert
   - Problem: Alle alten Nachrichten nicht mehr entschlüsselbar
   - Lösung: User-Warnung zeigen?

2. **Wie lange sollen alte SignedPreKeys aufbewahrt werden?**
   - Empfehlung: 7 Tage nach Neugenerierung
   - Grund: Ausstehende Sessions könnten noch alten Key verwenden

3. **Sollten SenderKeys auf Server persistent gespeichert werden?**
   - Pro: Backup bei Device-Verlust
   - Contra: Sicherheitsrisiko (Server hat Zugriff auf Gruppenschlüssel)
   - Aktuell: Werden gespeichert (`SignalSenderKey` Tabelle)

4. **Multi-Device Support?**
   - Aktuell: Jedes Device hat eigene Keys
   - Frage: Sollen Devices Keys teilen können?
   - Problem: Wie synchronisiert man PrivateKeys sicher?

---

## ✅ Fazit

**Aktueller Status:**
- ✅ Client ist korrekt als Source of Truth implementiert
- ✅ Automatischer Upload zu Server funktioniert
- ✅ Status-Check und Sync-Mechanismus vorhanden
- ⚠️ **KRITISCH:** Keine Abhängigkeits-Cleanup bei IdentityKeyPair-Regenerierung
- ⚠️ Keine Key-Rotation (SignedPreKey, SenderKeys)
- ⚠️ Potenzielle Race Conditions bei Multi-Tab

**Empfehlung:**
1. **Sofort:** Implementiere Abhängigkeits-Cleanup bei IdentityKeyPair-Regenerierung
2. **Bald:** Implementiere SignedPreKey Rotation
3. **Optional:** Implementiere SenderKey Rotation und Sync-Lock

**Sicherheitsbewertung:**
- 🟢 Grundarchitektur ist solide
- 🟡 Fehlerbehandlung bei Key-Regenerierung unvollständig
- 🟢 Private Keys bleiben immer auf Client

---

**Autor:** GitHub Copilot  
**Review:** Erforderlich vor Implementierung  
**Nächste Schritte:** Diskussion der Prioritäten mit Team
