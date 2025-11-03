# P2P File Sharing - Offene Entscheidungen & Fragen

**Stand**: 27. Oktober 2025  
**Status**: Design-Phase abgeschlossen, bereit für Implementierung

---

## 🎯 Kritische Entscheidungen (MUSS vor Implementation geklärt werden)

### 1. Native Storage-Strategie ⚠️ HOHE PRIORITÄT

**Frage**: Welche Storage-Lösung für Chunks auf Native Platforms (Android/iOS)?

**Optionen**:

| Option | Vorteile | Nachteile | Performance |
|--------|----------|-----------|-------------|
| **A: path_provider** | ✅ Beste Performance<br>✅ Unbegrenzter Speicher<br>✅ Native Dateisystem | ❌ Neue Dependency<br>❌ Manuelle Verschlüsselung | ⚡⚡⚡⚡ |
| **B: FlutterSecureStorage** | ✅ Bereits vorhanden<br>✅ Auto-Verschlüsselung<br>✅ Einfache API | ❌ Langsam bei großen Daten<br>❌ Nicht für Chunks optimiert | ⚡⚡ |

**Empfehlung**: **Option A (path_provider)**

**Begründung**:
- P2P File Sharing benötigt hohe I/O-Performance (parallele Chunk-Transfers)
- FlutterSecureStorage ist für kleine Secrets optimiert, nicht für GB-große Dateien
- Chunk-Verschlüsselung müssen wir sowieso selbst implementieren (AES-GCM)
- Zusätzliche Dependency ist gerechtfertigt für bessere UX

**Aufwand**:
```yaml
# pubspec.yaml
dependencies:
  path_provider: ^2.1.0  # +1 Dependency
```

**Deine Entscheidung**:
- [ ] ✅ Option A: path_provider hinzufügen
- [ ] ⚠️ Option B: FlutterSecureStorage verwenden
- [ ] 🤔 Andere Lösung: _______________

---

### 2. Signal Message Format für File-Keys 🔐 HOHE PRIORITÄT

**Frage**: Wie wird der File-Key in Signal-Nachrichten übertragen?

**Kontext**: Server soll fileName/mimeType nicht kennen → Dual-Message-Architektur

**Aktueller Plan**:
```dart
// Signal Message (encrypted)
{
  "type": "file-download-link",
  "fileId": "uuid-v4",
  "fileName": "document.pdf",      // Nur in Signal-Message
  "mimeType": "application/pdf",   // Nur in Signal-Message
  "fileSize": 1048576,
  "checksum": "sha256-hash",
  "chunkCount": 16,
  "encryptedKey": "base64...",     // File-Key (AES-256)
  "uploaderId": "user-uuid",
  "timestamp": 1698420000000
}
```

**Offene Fragen**:

1. **Message Type**: Neue Custom-Message oder vorhandenen Type erweitern?
   - [ ] Neuer Type: `"file-download-link"`
   - [ ] Erweitere: Vorhandenen Message-Type (welcher?)
   - [ ] Andere Lösung: _______________

2. **Sender Key Support**: Ist Sender Key bereits für Gruppen implementiert?
   - [ ] ✅ Ja, bereits vorhanden (wo?)
   - [ ] ❌ Nein, muss noch implementiert werden
   - [ ] 🤔 Nicht sicher, muss geprüft werden

3. **File-Key Encryption**:
   - **1:1 Chats**: File-Key mit PreKey verschlüsseln?
   - **Gruppen**: File-Key mit Sender Key verschlüsseln?
   
   **Deine Entscheidung**:
   - [ ] ✅ Ja, wie geplant (PreKey für 1:1, Sender Key für Gruppen)
   - [ ] ⚠️ Nur PreKey für beide (einfacher, aber langsamer für Gruppen)
   - [ ] 🤔 Andere Lösung: _______________

**Benötigte Information**:
Wir müssen bestehende Signal-Integration analysieren:
- Wo ist SignalService implementiert?
- Welche Message-Types existieren bereits?
- Wie werden Custom-Messages gehandhabt?

**Action Item**:
- [ ] Prüfe: `client/lib/services/signal_service.dart`
- [ ] Prüfe: `client/lib/models/signal_message.dart`
- [ ] Dokumentiere: Bestehende Message-Types

---

### 3. Seeder Limits & Storage Quota 💾 MITTLERE PRIORITÄT

**Frage**: Soll es Limits für Seeding geben?

**Szenarien**:

1. **User uploaded 100 Files (je 500 MB) = 50 GB Storage**
   - Soll automatisch gestoppt werden?
   - Warning anzeigen?
   
2. **Browser/Device Speicher ist voll**
   - Download verhindern?
   - Älteste Chunks löschen?

**Optionen**:

| Limit-Type | Option | Auswirkung |
|------------|--------|------------|
| **Max Seeding Files** | Unlimited | User entscheidet selbst |
| | Max 50 Files | Automatischer Cleanup nach 50 |
| | Max X GB | Storage-basiert (z.B. 10 GB) |
| **Storage Quota** | Warn at 90% | User-Notification |
| | Stop at 95% | Download verhindern |
| | Auto-cleanup | Älteste unvollständige löschen |

**Empfehlung**:
- ✅ **Kein Hard-Limit** für Anzahl Files (User-Kontrolle)
- ✅ **Storage-Warning** bei < 100 MB frei
- ✅ **Auto-Cleanup** für unvollständige Downloads (30 Tage)
- ✅ **UI zeigt Storage-Usage** (Settings-Page)

**Deine Entscheidung**:
- [ ] ✅ Empfehlung akzeptieren
- [ ] ⚠️ Hard-Limit hinzufügen: _____ Files / _____ GB
- [ ] 🤔 Andere Lösung: _______________

---

### 4. WebRTC STUN/TURN Server Configuration 🌐 HOHE PRIORITÄT

**Status:** ✅ GEKLÄRT  
**Entscheidung:** Hybrid coturn (eigener STUN+TURN Server)

**Frage**: Welche STUN/TURN Server sollen verwendet werden?

**Kontext**: WebRTC benötigt STUN/TURN für NAT-Traversal

**Optionen**:

**A) Public STUN Server (Kostenlos)**
```dart
final config = {
  'iceServers': [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
  ]
};
```
- ✅ Kostenlos
- ✅ Sofort verfügbar
- ⚠️ Funktioniert nur mit Symmetric NAT
- ❌ Kein TURN (bei restriktiven Firewalls problematisch)

**B) Eigener TURN Server (Self-hosted)**
```bash
# coturn Server auf eigenem VPS
apt-get install coturn
```
- ✅ Volle Kontrolle
- ✅ TURN Support (funktioniert immer)
- ❌ Server-Kosten (~5-10€/Monat)
- ❌ Wartungsaufwand

**C) Managed TURN Service (z.B. Twilio, Xirsys)**
```dart
// Twilio TURN
{'urls': 'turn:global.turn.twilio.com:3478?transport=udp',
 'username': 'xxx',
 'credential': 'xxx'}
```
- ✅ Keine Wartung
- ✅ Hohe Verfügbarkeit
- ❌ Kosten pro GB Transfer
- ❌ Vendor Lock-in

**D) Hybrid (STUN + Eigener TURN)**
```dart
final config = {
  'iceServers': [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'turn:your-server.com:3478',
     'username': 'user',
     'credential': 'pass'}
  ]
};
```
- ✅ Best of both worlds
- ✅ Fallback bei NAT-Problemen
- ⚠️ Moderate Kosten

**Empfehlung für MVP**: **Option A (Public STUN)**
- Funktioniert für ~80% der Nutzer
- Später auf Hybrid upgraden

**Empfehlung für Production**: **Option D (Hybrid)**

**✅ ENTSCHEIDUNG: Hybrid coturn (eigener STUN+TURN Server)**

**Setup:**
- Docker-Compose: `docker-compose.coturn.yml` ✅ ERSTELLT
- Config: `coturn/turnserver.conf` ✅ ERSTELLT
- Setup Script: `coturn/setup.sh` ✅ ERSTELLT
- Backend Integration: `lib/turn-credentials.js` ✅ ERSTELLT
- Dokumentation: `COTURN_SETUP.md` ✅ ERSTELLT

**Konfiguration:**
```javascript
// Hybrid ICE Servers
const iceServers = [
  { urls: 'stun:stun.l.google.com:19302' },     // Public STUN (kostenlos)
  { urls: 'stun:your-server.com:3478' },        // Eigener STUN
  { 
    urls: 'turn:your-server.com:3478',          // Eigener TURN
    username: 'dynamic-hmac-username',
    credential: 'dynamic-hmac-password'
  }
];
```

**Vorteile:**
- ✅ 95%+ Erfolgsrate (Public STUN 60-70% + TURN Fallback 30%)
- ✅ Günstig: ~5€/Monat (Hetzner CPX11)
- ✅ Volle Kontrolle + Privacy
- ✅ Production-ready in 30 Minuten

**Deine Entscheidung**:
- [x] D: Hybrid (coturn STUN+TURN als MVP)

**Action Item**:
- [x] STUN/TURN Server konfigurieren (coturn Docker Setup)
- [x] Credentials Helper erstellen (`lib/turn-credentials.js`)
- [x] Dokumentation (`COTURN_SETUP.md`)
- [ ] `.env` konfigurieren (nach Server Deployment)
- [ ] Firewall Ports öffnen (3478, 49152-65535)

---

### 5. UI/UX Design Decisions 🎨 MITTLERE PRIORITÄT

**Status:** ✅ GEKLÄRT

**Frage**: Wie soll File-Sharing in der UI aussehen?

#### 5.1 File Upload Button

**Wo soll der Upload-Button sein?**

| Option | Screenshot-Position | Vorteile | Nachteile |
|--------|---------------------|----------|-----------|
| A | Inline im Chat (neben Textfeld) | ✅ Schnell erreichbar<br>✅ Wie WhatsApp | ⚠️ Braucht Platz |
| B | Separate Modal/Dialog | ✅ Mehr Optionen<br>✅ Übersichtlich | ❌ Extra Klick |
| C | Context-Menu (Long-press) | ✅ Platzsparend | ❌ Nicht intuitiv |

**Empfehlung**: **Option A (Inline)**
```
┌────────────────────────────────────┐
│  📎 📷 [Text eingeben...] 🎤 📤  │
│  ↑   ↑                       ↑   ↑ │
│ Datei Foto                Emoji Send│
└────────────────────────────────────┘
```

**✅ ENTSCHEIDUNG: A (Inline Button wie WhatsApp)**

**Deine Entscheidung**:
- [x] A: Inline Button (wie WhatsApp)
- [ ] B: Separate Modal
- [ ] C: Context-Menu

#### 5.2 File Download Link (in Chat-Nachricht)

**Wie soll die File-Message aussehen?**

**Option A: Compact Card**
```
┌────────────────────────────────┐
│ 📄 document.pdf                │
│ 5.2 MB • 🌱 3 seeders          │
│ [⬇️ Download]                  │
└────────────────────────────────┘
```

**Option B: Expanded Card mit Progress**
```
┌────────────────────────────────┐
│ 📄 document.pdf                │
│ 5.2 MB • Uploaded by @alice    │
│ ▓▓▓▓▓▓▓▓░░░░ 67% (3.5 MB)     │
│ 🌱 3 seeders • ⚡ 2.1 MB/s     │
│ [⏸ Pause] [❌ Cancel]          │
└────────────────────────────────┘
```

**Empfehlung**: **Option B (Expanded)** - Mehr Kontext, bessere UX

**✅ ENTSCHEIDUNG: B (Expanded mit Progress, Seeder-Count, Speed)**

**Deine Entscheidung**:
- [ ] A: Compact
- [x] B: Expanded (mit allen Details)
- [ ] Andere: _______________

#### 5.3 Upload/Download Progress

**Wo soll der Progress angezeigt werden?**

| Option | Position | Vorteile | Nachteile |
|--------|----------|----------|-----------|
| A | Inline in Chat-Bubble | ✅ Kontextuell | ❌ Scrollt weg |
| B | Floating Overlay (unten) | ✅ Immer sichtbar | ❌ Blockiert Platz |
| C | Notification-Bar (oben) | ✅ Nicht störend | ⚠️ Wenig Details |
| D | Separate Downloads-Page | ✅ Übersichtlich | ❌ Extra Navigation |

**Empfehlung**: **Option B (Floating)** + **Option D (Downloads-Page)**
- Floating für aktive Downloads
- Downloads-Page für Historie

**✅ ENTSCHEIDUNG: B + D (Hybrid)**
- Floating Overlay für aktive Transfers
- Bestehender "Files" Menüeintrag in `dashboard_page.dart` wird zur Downloads/History-Page

**Deine Entscheidung**:
- [ ] A: Inline only
- [ ] B: Floating Overlay
- [ ] C: Notification-Bar
- [ ] D: Separate Page
- [x] B + D: Hybrid (Floating + Files-Page)

**Implementation Notes:**
```dart
// dashboard_page.dart Menü hat bereits:
// - "Files" Entry → Wird zur Download/Upload History Page
// - Zeigt alle Transfers (aktiv + abgeschlossen)
// - Seeder Status, Storage Management
```

#### 5.4 Material Design 3 Theming

**Soll Material Design 3 verwendet werden?**

- [ ] ✅ Ja, Material 3 (modernes Design)
- [x] ⚠️ Nein, Material 2 (konsistent mit Rest der App)
- [ ] 🤔 Prüfen: Was verwendet PeerWave aktuell?

**✅ ENTSCHEIDUNG: Konsistent mit bestehender App (wahrscheinlich Material 2)**

**Action Item**:
- [x] UI/UX Decisions getroffen
- [ ] Prüfe `client/lib/main.dart` → ThemeData version (während Implementation)
- [ ] File-Message Widget erstellen (Expanded Card)
- [ ] Floating Progress Overlay implementieren
- [ ] "Files" Page erweitern (Dashboard Menü nutzen)

---

## 📋 Offene Fragen (Nicht-blockierend, können später entschieden werden)

**Status:** ✅ ALLE GEKLÄRT mit Defaults

### 6. Batch vs. Single Reannounce 🔄 NIEDRIGE PRIORITÄT

**Status:** ✅ GEKLÄRT

**Aus**: `P2P_AUTO_REANNOUNCE_IMPLEMENTATION.md`

**Frage**: Soll Reannounce gebatched werden (alle Files auf einmal) oder einzeln?

**Optionen**:
- **A: Single**: Jede Datei einzeln reannounce
  - ✅ Einfacher
  - ❌ Viele Socket-Events bei vielen Files
  
- **B: Batch (Max 10)**: Bis zu 10 Files pro Request
  - ✅ Weniger Netzwerk-Overhead
  - ✅ Besser für viele Files
  - ⚠️ Komplexere Implementierung

**Empfehlung**: **Batch mit Max 10 Files**

**✅ ENTSCHEIDUNG: B (Batch max 10 Files)**

**Deine Entscheidung**:
- [ ] A: Single
- [x] B: Batch (max 10 Files pro Request)

---

### 7. Reannounce Retry-Logik 🔁 NIEDRIGE PRIORITÄT

**Status:** ✅ GEKLÄRT

**Frage**: Was wenn Reannounce fehlschlägt (Network-Error)?

**Empfehlung**: **Exponential Backoff**
```dart
final retryDelays = [1000, 2000, 4000, 8000]; // ms
for (final delay in retryDelays) {
  await Future.delayed(Duration(milliseconds: delay));
  try {
    await reannounce();
    break; // Success
  } catch (e) {
    // Continue to next retry
  }
}
```

**✅ ENTSCHEIDUNG: Exponential Backoff (1s → 2s → 4s → 8s)**

**Deine Entscheidung**:
- [x] ✅ Exponential Backoff (1s → 2s → 4s → 8s)
- [ ] ⚠️ Kein Retry (fail silently)
- [ ] Andere: _______________

---

### 8. Reannounce User-Notification 📢 NIEDRIGE PRIORITÄT

**Status:** ✅ GEKLÄRT

**Frage**: Soll User benachrichtigt werden dass Files reannounced wurden?

**Optionen**:
- **A: Silent**: Keine Notification (läuft im Hintergrund)
- **B: Success Toast**: "3 files shared again"
- **C: Detailed Notification**: Liste der Files

**Empfehlung**: **Option A (Silent)** - Nur bei Fehler notifizieren

**✅ ENTSCHEIDUNG: A (Silent, nur bei Fehler notifizieren)**

**Deine Entscheidung**:
- [x] A: Silent (nur Fehler zeigen)
- [ ] B: Success Toast
- [ ] C: Detailed Notification

---

### 9. TTL-Reset Strategie ⏰ NIEDRIGE PRIORITÄT

**Status:** ✅ GEKLÄRT

**Frage**: Soll TTL komplett resetet werden oder nur wenn kurz vor Ablauf?

**Aktueller Plan**: Nur wenn < 3 Tage verbleibend

```javascript
const timeRemaining = file.expiresAt - now;
const threeDays = 3 * 24 * 60 * 60 * 1000;

if (timeRemaining < threeDays) {
  file.expiresAt = now + (30 * 24 * 60 * 60 * 1000); // Reset zu 30 Tagen
}
```

**✅ ENTSCHEIDUNG: Nur wenn < 3 Tage verbleibend**

**Deine Entscheidung**:
- [x] ✅ Nur wenn < 3 Tage verbleibend
- [ ] ⚠️ Immer komplett reseten
- [ ] Andere Schwelle: _____ Tage

---

### 10. Garbage Collection Schedule 🧹 NIEDRIGE PRIORITÄT

**Status:** ✅ GEKLÄRT

**Frage**: Wann soll Garbage Collection laufen?

**Empfehlung**:
- ✅ **Bei Startup** (onConnect)
- ✅ **Alle 24 Stunden** im Hintergrund
- ✅ **Manuell** über Settings-Button

**Zusätzliche Optionen**:
- [ ] Vor jedem Download (zu oft?)
- [ ] Nur bei Speicherknappheit
- [ ] Andere: _______________

**✅ ENTSCHEIDUNG: Bei Startup + alle 24h + manuell**

**Deine Entscheidung**:
- [x] ✅ Bei Startup + alle 24h + manueller Button
- [ ] Andere: _______________

---

### 11. Complete Seeder Protection 🛡️ DESIGN-FRAGE

**Status:** ✅ GEKLÄRT

**Frage**: Sollen Seeders mit vollständigen Downloads NIEMALS entfernt werden?

**Aktueller Plan**: ✅ Ja, complete Seeders sind permanent (bis Uploader löscht)

**Szenario**: User hat 50 Files vollständig geseeded = 25 GB Speicher

**Alternativen**:
- **A: Permanent** (aktueller Plan)
  - ✅ Maximale Verfügbarkeit
  - ❌ Speicher kann volllaufen
  
- **B: 90 Tage TTL auch für Complete**
  - ✅ Automatischer Cleanup
  - ❌ Files verschwinden irgendwann

- **C: User-Einstellung** ("Keep seeding" Checkbox pro File)
  - ✅ User-Kontrolle
  - ⚠️ Komplexere UI

**✅ ENTSCHEIDUNG: C (User-Kontrolle via Settings)**
- Complete Seeders bleiben standardmäßig permanent
- User kann in Settings/Files-Page Seeders stoppen
- Manuelle Kontrolle über eigenen Speicher

**Deine Entscheidung**:
- [ ] A: Permanent
- [ ] B: 90 Tage TTL
- [x] C: User-Einstellung (Kontrolle via Settings)
- [ ] Andere: _______________

---

### 12. Uploader Delete Confirmation 🗑️ UX-FRAGE

**Status:** ✅ GEKLÄRT

**Frage**: Wie viele Bestätigungs-Schritte für "Delete Share"?

**Optionen**:

**A: Ein Dialog**
```
┌─────────────────────────────────┐
│ Delete Share                    │
│                                 │
│ This will delete the file for  │
│ ALL users (seeders & leechers).│
│                                 │
│ Are you sure?                   │
│                                 │
│ [Cancel] [Delete for Everyone] │
└─────────────────────────────────┘
```

**B: Zwei Schritte (wie Account-Delete)**
```
Step 1: Dialog (siehe oben)
Step 2: Type "DELETE" to confirm
```

**Empfehlung**: **Option A (Ein Dialog)** - Delete Share ist nicht so kritisch wie Account-Delete

**✅ ENTSCHEIDUNG: A (Ein Dialog mit klarer Warnung)**

**Deine Entscheidung**:
- [x] A: Ein Dialog (klar formuliert)
- [ ] B: Zwei Schritte (zu viel für File-Delete)

---

### 13. Partial Cleanup bei unvollständigen Downloads 🗂️ TECHNICAL

**Status:** ✅ GEKLÄRT

**Frage**: Sollen bei unvollständigen Downloads nur fehlende Chunks gelöscht werden oder alle?

**Szenario**: User hat 10/16 Chunks heruntergeladen, dann 30 Tage inaktiv

**Optionen**:
- **A: Alle löschen** (einfacher)
  - ✅ Sauberer Storage
  - ✅ Keine fragmentierten Files
  - ❌ Progress verloren
  
- **B: Nur fehlende löschen** (komplexer)
  - ✅ Progress bleibt erhalten
  - ❌ Fragmentierter Storage
  - ❌ Komplexere Logik

**Empfehlung**: **Option A (Alle löschen)** - Einfacher und sauberer

**✅ ENTSCHEIDUNG: A (Alle Chunks löschen bei Cleanup)**
- Einfachere Implementation
- Sauberer Storage
- Bei Bedarf kann File erneut gedownloadet werden

**Deine Entscheidung**:
- [x] A: Alle löschen (sauber + einfach)
- [ ] B: Nur fehlende

---

## 🚀 Action Items vor Start der Implementierung

### ✅ Alle CRITICAL Entscheidungen GEKLÄRT:

1. **[x] CRITICAL: Native Storage-Strategie entscheiden** (#1)
   - ✅ path_provider hinzufügen (bessere Performance)

2. **[x] CRITICAL: Signal Message Integration analysieren** (#2)
   - ✅ Neuer Type "file_share" 
   - ✅ Sender Key bereits implementiert (PermanentSenderKeyStore)

3. **[x] CRITICAL: WebRTC STUN/TURN Server konfigurieren** (#4)
   - ✅ Hybrid coturn Lösung (eigener STUN+TURN)
   - ✅ Docker Setup + Backend Integration erstellt
   - ⏳ Deployment nach Implementation Phase 1
### ✅ Alle Empfehlungen übernommen:

4. **[x] HIGH: UI/UX Design** (#5)
   - ✅ Inline File Upload Button (wie WhatsApp)
   - ✅ Expanded Card mit Progress/Seeders
   - ✅ Floating Overlay + Files-Page (Dashboard Menü)

5. **[x] MEDIUM: Storage Quota Limits** (#3)
   - ⏳ Während Implementation mit Defaults (2GB Web, 10GB Native)

6. **[x] LOW: Batch Reannounce** (#6)
   - ✅ Batch mit max 10 Files

7. **[x] LOW: Retry Logic** (#7)
   - ✅ Exponential Backoff (1s → 2s → 4s → 8s)

8. **[x] LOW: Notifications** (#8)
   - ✅ Silent (nur bei Fehler)

9. **[x] LOW: TTL Reset** (#9)
   - ✅ Nur wenn < 3 Tage übrig

10. **[x] LOW: GC Schedule** (#10)
    - ✅ Bei Startup + alle 24h + manuell

11. **[x] MEDIUM: Seeder Protection** (#11)
    - ✅ User-Kontrolle via Settings

12. **[x] LOW: Delete Confirmation** (#12)
    - ✅ Ein Dialog mit klarer Warnung

13. **[x] LOW: Partial Cleanup** (#13)
    - ✅ Alle Chunks löschen bei Cleanup

---

## 📊 Entscheidungs-Matrix

| # | Frage | Priorität | Status | Entscheidung |
|---|-------|-----------|--------|--------------|
| 1 | Native Storage | 🔴 CRITICAL | ✅ GEKLÄRT | **path_provider hinzufügen** |
| 2 | Signal Messages | 🔴 CRITICAL | ✅ GEKLÄRT | **Neuer Type "file_share"** (Sender Key ready!) |
| 3 | Storage Quota | 🟡 MEDIUM | ✅ GEKLÄRT | **Defaults: 2GB Web, 10GB Native** |
| 4 | STUN/TURN | 🔴 CRITICAL | ✅ GEKLÄRT | **Hybrid coturn** (eigener STUN+TURN, 5€/Monat) |
| 5 | UI/UX Design | 🟡 MEDIUM | ✅ GEKLÄRT | **Inline Button + Expanded Card + Floating+Files-Page** |
| 6 | Batch Reannounce | 🟢 LOW | ✅ GEKLÄRT | **Batch max 10 Files** |
| 7 | Retry Logic | 🟢 LOW | ✅ GEKLÄRT | **Exponential Backoff (1s→2s→4s→8s)** |
| 8 | Notifications | 🟢 LOW | ✅ GEKLÄRT | **Silent (nur Fehler)** |
| 9 | TTL Reset | 🟢 LOW | ✅ GEKLÄRT | **Nur wenn < 3 Tage übrig** |
| 10 | GC Schedule | 🟢 LOW | ✅ GEKLÄRT | **Startup + 24h + manuell** |
| 11 | Seeder Protection | 🟡 MEDIUM | ✅ GEKLÄRT | **User-Kontrolle via Settings** |
| 12 | Delete Confirmation | 🟢 LOW | ✅ GEKLÄRT | **Ein Dialog mit Warnung** |
| 13 | Partial Cleanup | 🟢 LOW | ✅ GEKLÄRT | **Alle Chunks löschen** |

---

## 🎯 Entscheidungsstatus

### ✅ ALLE FRAGEN GEKLÄRT! 

**Kritische Entscheidungen (3/3):**
- ✅ Native Storage: path_provider
- ✅ Signal Integration: Type "file_share" 
- ✅ STUN/TURN: Hybrid coturn

**Mittlere Priorität (3/3):**
- ✅ Storage Quota: 2GB Web, 10GB Native
- ✅ UI/UX: WhatsApp-Style mit Files-Page
- ✅ Seeder Protection: User-Kontrolle

**Niedrige Priorität (7/7):**
- ✅ Batch Reannounce: Max 10 Files
- ✅ Retry: Exponential Backoff
- ✅ Notifications: Silent
- ✅ TTL Reset: < 3 Tage
- ✅ GC Schedule: Startup + 24h + manuell
- ✅ Delete Confirmation: Ein Dialog
- ✅ Partial Cleanup: Alle löschen

---

## 🚀 Bereit für Implementation!

**Alle Entscheidungen getroffen - Phase 1 kann starten:**

1. **Foundation Setup** (Woche 1-2)
   - ✅ Decisions finalisiert
   - ⏳ path_provider zu pubspec.yaml hinzufügen
   - ⏳ Storage Layer implementieren
   - ⏳ Chunking System bauen
   - ⏳ Encryption implementieren

2. **WebRTC Integration** (Woche 3-4)
   - ⏳ WebRTC Setup
   - ⏳ Signal "file_share" Messages
   - ⏳ coturn Server deployen
   - ⏳ DataChannel Transfer

3. **UI Implementation** (Woche 5-6)
   - ⏳ Inline Upload Button
   - ⏳ Expanded File Cards
   - ⏳ Floating Progress Overlay
   - ⏳ Files-Page (Dashboard Menü)

**Nächster Schritt:** Implementation Roadmap erstellen? �
