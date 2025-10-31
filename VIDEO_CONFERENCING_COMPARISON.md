# Video Conferencing Architektur Vergleich
## WhatsApp, Teams, Zoom vs. mediasoup für PeerWave

**Erstellt:** 31. Oktober 2025  
**Ziel:** Vergleich verschiedener Video-Call Architekturen für PeerWave Entscheidung

---

## 🎥 Architektur-Übersicht

### 1. **Peer-to-Peer (P2P)**
```
┌─────────┐         ┌─────────┐
│Client A │◄───────►│Client B │
└─────────┘         └─────────┘
```
**Direkte Verbindung ohne Server (außer Signaling)**

### 2. **Selective Forwarding Unit (SFU)**
```
┌─────────┐         ┌─────────┐
│Client A │◄───────►│   SFU   │◄───────►┌─────────┐
└─────────┘         │ Server  │         │Client C │
                    └─────────┘         └─────────┘
                         ▲
                         │
                    ┌─────────┐
                    │Client B │
                    └─────────┘
```
**Server leitet Streams weiter (kein Transcoding)**

### 3. **Multipoint Control Unit (MCU)**
```
┌─────────┐         ┌─────────┐         ┌─────────┐
│Client A │────────►│   MCU   │────────►│Client B │
└─────────┘         │ Server  │         └─────────┘
                    │ (Mixer) │
┌─────────┐         └─────────┘
│Client C │────────►                    
└─────────┘         
```
**Server mischt alle Streams zu einem (hohe CPU Last)**

---

## 📱 WhatsApp Video Calls

### Architektur:
- **1:1 Calls:** ✅ **Pure P2P** (direkteste Verbindung)
- **Gruppen-Calls (2-8 Personen):** ✅ **P2P Mesh**
- **Große Gruppen (8-32):** ⚠️ **Hybrid SFU** (seit 2021)

### Technologie:
```
┌─────────────────────────────────────────┐
│ WhatsApp Video Call Stack              │
├─────────────────────────────────────────┤
│ • Signaling: WhatsApp Server (XMPP)    │
│ • Media Transport: WebRTC (P2P/SFU)    │
│ • TURN Server: Facebook Infrastructure │
│ • E2EE: Signal Protocol (SRTP)         │
│ • Codec: VP8/VP9, Opus                 │
└─────────────────────────────────────────┘
```

### E2EE Implementation:
```
┌──────────────────────────────────────────────┐
│ WhatsApp E2EE für Video                     │
├──────────────────────────────────────────────┤
│ Layer 1: Signal Protocol (Key Exchange)     │
│ Layer 2: SRTP (Secure RTP für Media)        │
│ Layer 3: DTLS (Transport Security)          │
│                                              │
│ ✅ Server kann Media NICHT sehen            │
│ ✅ Keys nur auf Clients                     │
│ ⚠️ Server sieht Metadaten (wer, wann, wie  │
│    lange - aber NICHT Inhalt)               │
└──────────────────────────────────────────────┘
```

### Details:
- **P2P Vorteil:** Niedrigste Latenz, keine Server-Kosten für Media
- **P2P Nachteil:** Funktioniert nicht hinter strict NAT/Firewalls
- **Fallback:** TURN Relay wenn P2P scheitert
- **Limitierung:** Max 32 Teilnehmer (Hardware-abhängig)
- **E2EE:** Ja, mit Signal Protocol + SRTP
- **Recording:** Nicht möglich (E2EE)

### Skalierung:
```
Teilnehmer | Architektur        | Upload pro Client
-----------|--------------------|-----------------
2          | P2P                | 1 Stream (→ Peer)
4          | P2P Mesh           | 3 Streams (→ alle)
8          | P2P Mesh / SFU     | 7 Streams / 1 Stream
16+        | SFU (Hybrid)       | 1 Stream (→ SFU)
32+        | NICHT unterstützt  | -
```

**Problem bei P2P Mesh:** Mit 8 Teilnehmern muss Client A:
- 7x Upload (zu jedem anderen)
- 7x Download (von jedem anderen)
- = **Sehr hohe Bandwidth** (7-14 Mbps Upload!)

**WhatsApp Lösung (2021 Update):**
- < 8 Personen: P2P Mesh (beste Qualität)
- \> 8 Personen: Automatischer Wechsel zu SFU
- SFU reduziert Upload auf 1 Stream

---

## 💼 Microsoft Teams

### Architektur:
- **Immer SFU** (auch bei 1:1!)
- **Cloud-basiert** (Azure Media Services)
- **Keine P2P** (außer in speziellen Enterprise Setups)

### Technologie:
```
┌─────────────────────────────────────────┐
│ Microsoft Teams Stack                   │
├─────────────────────────────────────────┤
│ • Signaling: Microsoft Graph API        │
│ • Media: Azure Media Services (SFU)     │
│ • Transport: HTTPS/WebSockets + SRTP    │
│ • E2EE: ❌ NICHT für reguläre Calls    │
│          ✅ Nur "End-to-End Encrypted   │
│             Calls" (opt-in, limitiert)  │
│ • Codec: H.264, Opus                    │
│ • Recording: ✅ Ja (Cloud-based)        │
└─────────────────────────────────────────┘
```

### SFU Vorteile bei Teams:
1. **Skalierbar:** Bis zu 1000 Teilnehmer (View-only)
2. **Zuverlässig:** Server-Infrastruktur (Azure)
3. **Features:** Recording, Transcription, Live Captions
4. **Enterprise:** Compliance, Data Retention
5. **Quality:** Adaptive Bitrate, Simulcast

### E2EE bei Teams:
```
┌──────────────────────────────────────────────┐
│ Teams E2EE (Optional, seit 2021)            │
├──────────────────────────────────────────────┤
│ Standard Calls:                              │
│   ❌ Kein E2EE (Server kann entschlüsseln)  │
│   ✅ Transport Encryption (TLS/DTLS)        │
│   ✅ Recording möglich                       │
│   ✅ Transcription möglich                   │
│                                              │
│ "End-to-End Encrypted Calls":               │
│   ✅ E2EE (DTLS-SRTP + zusätzliche Layer)   │
│   ❌ Recording NICHT möglich                 │
│   ❌ Transcription NICHT möglich             │
│   ❌ Max 50 Teilnehmer                       │
│   ⚠️ Opt-in (nicht default!)                │
└──────────────────────────────────────────────┘
```

**Wichtig:** Teams verwendet **standardmäßig KEIN E2EE**!
- Server (Microsoft) kann Streams entschlüsseln
- Begründung: Features wie Recording, Transcription
- E2EE nur als "opt-in" für Privacy-kritische Calls

### Skalierung:
```
Teilnehmer | Modus                    | Client Upload
-----------|--------------------------|----------------
2-50       | Active Participants      | 1 Stream (→ SFU)
50-1000    | View-only (Broadcast)    | 0 Streams (nur empfangen)
1000+      | Live Event (separate API)| -
```

---

## 🎥 Zoom

### Architektur:
- **Hybrid:** SFU (default) oder MCU (bei schlechter Bandwidth)
- **Cloud-basiert** (eigene Infrastruktur)
- **Intelligent routing** (nächster Server)

### Technologie:
```
┌─────────────────────────────────────────┐
│ Zoom Stack                              │
├─────────────────────────────────────────┤
│ • Signaling: Zoom MMR (Multimedia      │
│   Router) - proprietär                  │
│ • Media: SFU (default) / MCU (fallback)│
│ • Transport: UDP/TCP + AES-256-GCM      │
│ • E2EE: ✅ Optional (seit 2020)         │
│ • Codec: Proprietary + H.264, Opus      │
│ • Recording: ✅ Ja (lokal + Cloud)      │
└─────────────────────────────────────────┘
```

### Besonderheit: Adaptive MCU
```
┌──────────────────────────────────────────────┐
│ Zoom's Intelligente Architektur             │
├──────────────────────────────────────────────┤
│ Gute Verbindung:                             │
│   → SFU Mode (alle Streams separat)         │
│                                              │
│ Schlechte Verbindung (ein Client):          │
│   → MCU Mode nur für diesen Client          │
│   → Server mischt Streams zu 1 (Gallery)    │
│   → Andere Clients bleiben in SFU           │
│                                              │
│ ✅ Best of both worlds                       │
└──────────────────────────────────────────────┘
```

### E2EE bei Zoom:
```
┌──────────────────────────────────────────────┐
│ Zoom E2EE (seit Oktober 2020)               │
├──────────────────────────────────────────────┤
│ Standard Meetings:                           │
│   ❌ Kein E2EE                               │
│   ✅ AES-256 GCM Transport Encryption       │
│   ✅ Server kann entschlüsseln (für Features)│
│                                              │
│ E2E Encrypted Meetings (opt-in):            │
│   ✅ E2EE mit GCM-256                        │
│   ❌ Recording NICHT möglich                 │
│   ❌ Cloud Recording NICHT möglich           │
│   ❌ Transcription NICHT möglich             │
│   ❌ Breakout Rooms NICHT möglich            │
│   ❌ Polling NICHT möglich                   │
│   ⚠️ Host muss verifizieren (Security Code) │
└──────────────────────────────────────────────┘
```

### Skalierung:
- **Free:** Bis 100 Teilnehmer (40 min Limit)
- **Pro:** Bis 100 Teilnehmer (unlimited)
- **Business:** Bis 300 Teilnehmer
- **Enterprise:** Bis 1000 Teilnehmer
- **Webinar:** Bis 50.000 View-only

---

## 🆚 Architektur Vergleich

| Feature | WhatsApp | Teams | Zoom | mediasoup (PeerWave) |
|---------|----------|-------|------|---------------------|
| **Architektur** | P2P/SFU Hybrid | Pure SFU | SFU/MCU Hybrid | Pure SFU |
| **E2EE Default** | ✅ Ja | ❌ Nein | ❌ Nein | ✅ Möglich (opt-in) |
| **E2EE Optional** | - | ✅ Ja (limitiert) | ✅ Ja (limitiert) | ✅ Ja |
| **Max Teilnehmer** | 32 | 1000 | 1000 | ~200 (per Worker) |
| **Recording** | ❌ Nein | ✅ Ja (ohne E2EE) | ✅ Ja (ohne E2EE) | ✅ Ja (ohne E2EE) |
| **Cloud/Self-Host** | Cloud | Cloud | Cloud | ✅ Self-Hosted |
| **Open Source** | ❌ Nein | ❌ Nein | ❌ Nein | ✅ Ja (mediasoup) |
| **Latenz** | 🟢 Sehr niedrig (P2P) | 🟡 Mittel | 🟡 Mittel | 🟡 Mittel (SFU) |
| **Bandwidth (Client)** | 🔴 Hoch bei >8 Peers | 🟢 Niedrig (1 Upload) | 🟢 Niedrig | 🟢 Niedrig |
| **Server CPU** | 🟢 Niedrig (nur Signaling) | 🔴 Hoch | 🔴 Sehr hoch (MCU) | 🟡 Mittel |
| **Kosten** | Keine (Facebook zahlt) | $$ (Azure) | $$ (Zoom Cloud) | $ (eigener Server) |

---

## 🔐 E2EE Implementation Details

### WhatsApp (Signal Protocol + SRTP):
```javascript
// Simplified WhatsApp E2EE Flow

// 1. Key Exchange (Signal Protocol)
const sessionKey = await signalProtocol.establishSession(peerA, peerB);

// 2. Derive Media Keys
const mediaSendKey = hkdf(sessionKey, 'WhatsApp-Media-Send');
const mediaRecvKey = hkdf(sessionKey, 'WhatsApp-Media-Recv');

// 3. SRTP Encryption (native WebRTC)
const rtpSender = peerConnection.addTrack(videoTrack);
rtpSender.setParameters({
  crypto: {
    algorithm: 'AES_128_CM_SHA1_80',  // SRTP Standard
    key: mediaSendKey
  }
});

// 4. Server (WhatsApp) sieht:
// - Encrypted RTP packets ✅
// - Metadata (IP, timestamp) ⚠️
// - CANNOT decrypt media ✅
```

**Vorteil:** Native SRTP (Hardware-beschleunigt)  
**Nachteil:** Nur in P2P/Mesh möglich, NICHT mit klassischem SFU

### Teams E2EE (opt-in):
```javascript
// Simplified Teams E2EE Flow

// Standard Call (KEIN E2EE):
// 1. Client → TLS → Azure Media Service
// 2. Azure entschlüsselt → verarbeitet → verschlüsselt neu
// 3. Azure → TLS → Client
// ❌ Azure kann Media lesen

// E2EE Call (opt-in):
// 1. DTLS-SRTP Keys zwischen Clients (via Server)
// 2. Client A → DTLS-SRTP → Server (Relay) → Client B
// 3. Server kann Encryption Header sehen, aber NICHT Payload
// ✅ Server kann Media NICHT lesen
// ❌ Aber: Kein Recording, Transcription, etc.
```

### Zoom E2EE (seit 2020):
```javascript
// Simplified Zoom E2EE Flow

// 1. AES-256-GCM Key Generation (Client-Side)
const meetingKey = crypto.getRandomValues(new Uint8Array(32));

// 2. Key Distribution (RSA encrypted)
const encryptedKey = await rsaEncrypt(meetingKey, hostPublicKey);
// → Sent via Zoom Server (aber Server kann nicht lesen)

// 3. Frame Encryption (Insertable Streams - ähnlich wie PeerWave!)
rtpSender.createEncodedStreams().readable
  .pipeThrough(new TransformStream({
    transform(encodedFrame, controller) {
      const encrypted = aes256gcm.encrypt(encodedFrame.data, meetingKey);
      encodedFrame.data = encrypted;
      controller.enqueue(encodedFrame);
    }
  }))
  .pipeTo(rtpSender.writable);

// 4. Security Code Verification (Manual)
const securityCode = sha256(meetingKey).slice(0, 6); // 6 digits
// Host zeigt Code → alle Teilnehmer vergleichen
```

**Zoom's Approach ähnelt unserem mediasoup E2EE Plan!**

---

## 🏗️ Welche Architektur für PeerWave?

### Analyse der Requirements:

#### ✅ **SFU (mediasoup) ist die richtige Wahl für PeerWave:**

**Gründe:**

1. **Skalierbarkeit:**
   - WhatsApp P2P limitiert auf ~8-32 Personen
   - PeerWave soll größere Gruppen unterstützen
   - SFU: Client sendet nur 1 Stream, empfängt N Streams

2. **Self-Hosted:**
   - Teams/Zoom = Cloud-only (Vendor Lock-in)
   - mediasoup = Open Source, Self-Hosted
   - Volle Kontrolle über Daten & Infrastruktur

3. **E2EE möglich:**
   - Mit Insertable Streams API (wie Zoom)
   - Optional/Toggle (wie Teams/Zoom)
   - Verwendet bestehende Signal Protocol Infrastruktur

4. **Bandwidth-effizient:**
   - Client: 1x Upload (statt N bei P2P)
   - Server: Nur Forwarding (kein Transcoding wie MCU)
   - < 1 Mbps pro HD Stream

5. **Performance:**
   - Worker-basiert (CPU-Cores nutzen)
   - ~200 Connections per Worker
   - Horizontal skalierbar

6. **Feature-Flexibilität:**
   - Recording möglich (ohne E2EE)
   - Simulcast für adaptive Quality
   - Screen Sharing
   - Active Speaker Detection

### ❌ **Warum NICHT P2P (wie WhatsApp)?**

1. **Bandwidth Problem:** 
   - 8 Teilnehmer = 7 Upload Streams = 7-14 Mbps Upload
   - Home Internet: 5-10 Mbps Upload typisch
   - → Qualität bricht zusammen

2. **NAT Traversal:**
   - ~20% der Verbindungen scheitern ohne TURN
   - TURN = Server Relay = nicht mehr "Pure P2P"
   - SFU ist dann effizienter

3. **Keine Features:**
   - Recording unmöglich (kein zentraler Punkt)
   - Keine Server-side Processing
   - Keine Transcription

### ❌ **Warum NICHT MCU (wie alte Zoom Version)?**

1. **Hohe Server CPU:**
   - Jeder Stream muss dekodiert werden
   - Alle Streams müssen gemischt werden
   - Re-Encoding für jeden Client
   - = 10x höhere CPU als SFU

2. **Verlust an Qualität:**
   - Zwangs-Transcoding (Quality Loss)
   - Keine Client-side Qualität Kontrolle
   - Fixed Layout (Grid)

3. **Teuer:**
   - Braucht viel CPU/GPU Power
   - Nicht horizontal skalierbar

---

## 🎯 Empfehlung für PeerWave

### **Implementiere SFU (mediasoup) mit optionalem E2EE**

**Phase 1: Basic SFU (wie geplant)**
- ✅ mediasoup als SFU
- ✅ WebRTC Transport
- ✅ Simulcast für adaptive Quality
- ✅ Recording Support
- ✅ Bis zu ~200 simultane Connections

**Phase 2: E2EE Layer (optional)**
- ✅ Insertable Streams API (wie Zoom)
- ✅ Signal Protocol für Key Exchange
- ✅ AES-256-GCM Frame Encryption
- ✅ UI Toggle (wie Teams/Zoom)
- ⚠️ Recording disabled wenn E2EE aktiv

**Phase 3: Hybrid P2P Fallback (später, optional)**
- Für 1:1 Calls: Pure P2P (wie WhatsApp)
- Für 2-4 Personen: P2P Mesh (optional)
- Für 5+ Personen: SFU (immer)
- → Best of both worlds

### **Architektur Entscheidung:**

```
┌─────────────────────────────────────────────────────┐
│ PeerWave Video Architecture (Empfehlung)           │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Default: SFU (mediasoup)                          │
│  ├─ Skalierbar (5-200+ Teilnehmer)                │
│  ├─ Self-Hosted (Docker)                           │
│  ├─ Bandwidth-effizient                            │
│  └─ Feature-rich (Recording, etc.)                 │
│                                                     │
│  Optional: E2EE Layer                              │
│  ├─ Insertable Streams API                         │
│  ├─ Signal Protocol Keys                           │
│  ├─ Toggle in UI                                   │
│  └─ Deaktiviert: Recording, Transcription          │
│                                                     │
│  Future: P2P Optimization für 1:1                  │
│  ├─ Direct P2P für niedrigste Latenz              │
│  ├─ Fallback zu SFU bei NAT Problemen             │
│  └─ Automatischer Wechsel bei 3+ Personen         │
│                                                     │
└─────────────────────────────────────────────────────┘
```

---

## 📊 Feature Matrix

| Feature | WhatsApp | Teams (Standard) | Teams (E2EE) | Zoom (Standard) | Zoom (E2EE) | **PeerWave (SFU)** | **PeerWave (SFU+E2EE)** |
|---------|----------|------------------|--------------|-----------------|-------------|-------------------|------------------------|
| E2E Encrypted | ✅ | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ |
| Recording | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | ❌ |
| Transcription | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | ❌ |
| Self-Hosted | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ |
| Max Participants | 32 | 1000 | 50 | 1000 | 200 | 200+ | 200+ |
| Bandwidth (Client) | 🔴 High | 🟢 Low | 🟢 Low | 🟢 Low | 🟢 Low | 🟢 Low | 🟢 Low |
| Server CPU | 🟢 Low | 🔴 High | 🔴 High | 🔴 Very High | 🟡 Medium | 🟡 Medium | 🟡 Medium |
| Open Source | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ |
| Privacy | 🟢 Excellent | 🔴 Poor | 🟢 Good | 🔴 Poor | 🟢 Good | 🟡 Good | 🟢 Excellent |
| Latency | 🟢 <100ms | 🟡 150-300ms | 🟡 150-300ms | 🟡 150-300ms | 🟡 150-300ms | 🟡 150-300ms | 🟡 150-300ms |

---

## 💡 Key Learnings

### 1. **E2EE = Trade-offs**
Alle großen Anbieter bieten E2EE als **opt-in**, nicht default:
- ✅ E2EE → Max Privacy
- ❌ E2EE → Keine Features (Recording, AI, etc.)

**PeerWave sollte das gleiche machen:** Toggle für E2EE

### 2. **SFU ist der Standard**
Teams, Zoom, moderne WhatsApp Gruppen = alle nutzen SFU:
- Skaliert besser als P2P
- Weniger Client Bandwidth als P2P
- Weniger Server CPU als MCU

### 3. **Insertable Streams für E2EE**
Zoom's Approach (seit 2020) = unser geplanter Approach:
- Frame-level Encryption
- Client-side Keys
- Server bleibt "blind"

### 4. **P2P nur für 1:1 sinnvoll**
WhatsApp nutzt P2P clever:
- 1:1 = Pure P2P (niedrigste Latenz)
- Gruppen > 8 = SFU (Skalierung)

**PeerWave kann das später auch implementieren (Phase 3)**

---

## 🚀 Fazit

### ✅ **Der mediasoup Action Plan ist optimal!**

Unsere geplante Architektur entspricht **industry best practices**:

1. **SFU wie Teams/Zoom** → Skalierbar, Feature-rich
2. **Insertable Streams E2EE wie Zoom** → Privacy + Flexibilität
3. **Self-Hosted wie Jitsi** → Volle Kontrolle
4. **Signal Protocol Integration** → Bewährt (WhatsApp, Signal)

**Vorteile gegenüber Konkurrenz:**
- ✅ Open Source (kein Vendor Lock-in)
- ✅ Self-Hosted (Datenkontrolle)
- ✅ E2EE + Recording (togglebar)
- ✅ Integriert mit bestehendem Signal Protocol Stack

**Start wie geplant mit mediasoup SFU + E2EE!** 🎯

---

**Version:** 1.0  
**Autor:** PeerWave Team  
**Quellen:**
- WhatsApp Engineering Blog
- Microsoft Teams Documentation
- Zoom Security Whitepaper
- mediasoup Documentation
- WebRTC W3C Specifications
