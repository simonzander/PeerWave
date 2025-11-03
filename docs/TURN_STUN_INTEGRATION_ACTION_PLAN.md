# TURN/STUN Server Integration Action Plan

## 📋 Übersicht
Integration des coturn TURN/STUN-Servers in den Flutter Client über den `/client/meta` Endpoint. Der Client soll dynamisch die ICE Server Konfiguration vom Node.js Server beziehen und diese für WebRTC DataChannel Verbindungen verwenden.

## 🎯 Ziele
1. Zentrale Verwaltung der TURN/STUN Credentials in Docker
2. Node.js Server generiert dynamische TURN-Credentials (für Sicherheit)
3. Flutter Client bezieht ICE Server Config über `/client/meta`
4. WebRTC Service nutzt die dynamischen ICE Server für P2P Verbindungen

---

## 📝 TODO Liste

### Phase 1: Docker & Environment Setup
**Ziel:** Zentrale Secret-Verwaltung für alle Container

#### ✅ TODO 1.1: Docker Environment Variables konfigurieren
- [ ] `.env` Datei im Root-Verzeichnis erstellen
- [ ] TURN_SECRET für coturn definieren
- [ ] TURN_SERVER_HOST (interner Docker-Name)
- [ ] TURN_SERVER_PORT (3478 für TURN/STUN)
- [ ] Externe IP/Domain für TURN-Server (für Client)
- [ ] docker-compose.yml anpassen für `.env` Support

**Dateien:**
- `/.env` (neu erstellen)
- `/docker-compose.yml` (anpassen)
- `/docker-compose.prod.yml` (anpassen)

**Details:**
```env
# .env
TURN_SECRET=<sicherer-random-secret>
TURN_SERVER_EXTERNAL_HOST=your-domain.com  # Öffentliche IP/Domain
TURN_SERVER_INTERNAL_HOST=peerwave-coturn  # Docker-interner Name
TURN_SERVER_PORT=3478
TURN_SERVER_PORT_TLS=5349
TURN_REALM=peerwave.local
```

---

#### ✅ TODO 1.2: coturn Konfiguration anpassen
- [ ] `turnserver.conf` für dynamische Auth-Secret anpassen
- [ ] External IP Auto-Detection sicherstellen
- [ ] Realm konfigurieren

**Dateien:**
- `/server/coturn/turnserver.conf`

**Details:**
- `use-auth-secret` aktiviert lassen
- `static-auth-secret` aus Environment Variable beziehen
- Sicherstellen, dass `external-ip` automatisch erkannt wird

---

### Phase 2: Node.js Server - TURN Credential Generation
**Ziel:** Server generiert zeitlich begrenzte TURN-Credentials (RFC 5389)

#### ✅ TODO 2.1: TURN Credential Helper erstellen
- [ ] Neues Modul für TURN-Credential-Generierung erstellen
- [ ] Zeitlich begrenzte Credentials (TTL: z.B. 24 Stunden)
- [ ] HMAC-SHA1 Hash für Username/Password generieren

**Dateien:**
- `/server/lib/turnCredentials.js` (neu erstellen)

**Details:**
```javascript
// Pseudo-Code
function generateTurnCredentials(username, secret, ttl = 86400) {
  const timestamp = Math.floor(Date.now() / 1000) + ttl;
  const turnUsername = `${timestamp}:${username}`;
  const hmac = crypto.createHmac('sha1', secret);
  hmac.update(turnUsername);
  const turnPassword = hmac.digest('base64');
  
  return {
    username: turnUsername,
    password: turnPassword,
    ttl: timestamp
  };
}
```

---

#### ✅ TODO 2.2: `/client/meta` Endpoint erweitern
- [ ] Bestehenden `/client/meta` Endpoint um ICE Server Config erweitern
- [ ] TURN-Credentials für aktuellen User generieren
- [ ] STUN und TURN Server URLs hinzufügen
- [ ] Config für Development und Production unterscheiden

**Dateien:**
- `/server/routes/client.js` (bestehender Endpoint anpassen)

**Details:**
```javascript
// Response Format
{
  "name": "PeerWave",
  "version": "1.0.0",
  "iceServers": [
    {
      "urls": ["stun:your-domain.com:3478"]
    },
    {
      "urls": [
        "turn:your-domain.com:3478?transport=udp",
        "turn:your-domain.com:3478?transport=tcp"
      ],
      "username": "1730419200:user123",
      "credential": "base64-hmac-hash"
    },
    {
      "urls": ["turns:your-domain.com:5349?transport=tcp"],
      "username": "1730419200:user123",
      "credential": "base64-hmac-hash"
    }
  ]
}
```

**Wichtig:** 
- Session-basierte User-ID verwenden für Credentials
- Fallback auf Google STUN wenn coturn nicht verfügbar

---

#### ✅ TODO 2.3: Config-Modul für TURN Server erweitern
- [ ] `config.js` um TURN-Server Konfiguration erweitern
- [ ] Environment Variables auslesen

**Dateien:**
- `/server/config/config.js`

**Details:**
```javascript
config.turn = {
  secret: process.env.TURN_SECRET,
  host: process.env.TURN_SERVER_EXTERNAL_HOST,
  internalHost: process.env.TURN_SERVER_INTERNAL_HOST,
  port: parseInt(process.env.TURN_SERVER_PORT || '3478'),
  tlsPort: parseInt(process.env.TURN_SERVER_PORT_TLS || '5349'),
  realm: process.env.TURN_REALM || 'peerwave.local',
  ttl: 86400 // 24 Stunden
};
```

---

### Phase 3: Flutter Client - Dynamic ICE Server Config
**Ziel:** Client lädt ICE Server Config beim Start und nutzt diese für WebRTC

#### ✅ TODO 3.1: API Service für `/client/meta` erweitern
- [ ] Bestehenden API Call für `/client/meta` erweitern
- [ ] ICE Server Config parsen und speichern

**Dateien:**
- `/client/lib/services/api_service.dart` (oder ähnlich)

**Details:**
```dart
class ClientMetaResponse {
  final String name;
  final String version;
  final List<IceServer> iceServers;
  
  ClientMetaResponse.fromJson(Map<String, dynamic> json)
    : name = json['name'],
      version = json['version'],
      iceServers = (json['iceServers'] as List)
          .map((e) => IceServer.fromJson(e))
          .toList();
}

class IceServer {
  final List<String> urls;
  final String? username;
  final String? credential;
  
  IceServer.fromJson(Map<String, dynamic> json)
    : urls = List<String>.from(json['urls']),
      username = json['username'],
      credential = json['credential'];
}
```

---

#### ✅ TODO 3.2: WebRTC Service für dynamische ICE Server anpassen
- [ ] `WebRTCFileService` Constructor für dynamische ICE Servers anpassen
- [ ] ICE Server Config als Parameter übergeben (statt Hardcoded)
- [ ] Fallback auf Google STUN wenn Server-Config fehlt

**Dateien:**
- `/client/lib/services/file_transfer/webrtc_service.dart`

**Aktueller Code:**
```dart
WebRTCFileService({
  this.iceServers = const {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ]
  },
});
```

**Neuer Code:**
```dart
WebRTCFileService({
  Map<String, dynamic>? iceServers,
}) : iceServers = iceServers ?? {
  'iceServers': [
    {'urls': 'stun:stun.l.google.com:19302'},  // Fallback
  ]
};
```

---

#### ✅ TODO 3.3: Provider/Service für ICE Server Config erstellen
- [ ] Singleton Service für globale ICE Server Config
- [ ] Config beim App-Start laden
- [ ] Config an WebRTC Service übergeben

**Dateien:**
- `/client/lib/services/ice_config_service.dart` (neu erstellen)

**Details:**
```dart
class IceConfigService {
  static final IceConfigService _instance = IceConfigService._internal();
  factory IceConfigService() => _instance;
  IceConfigService._internal();
  
  Map<String, dynamic>? _iceServers;
  
  Future<void> loadConfig() async {
    final meta = await ApiService().getClientMeta();
    _iceServers = {
      'iceServers': meta.iceServers.map((server) => {
        'urls': server.urls,
        if (server.username != null) 'username': server.username,
        if (server.credential != null) 'credential': server.credential,
      }).toList()
    };
  }
  
  Map<String, dynamic> getIceServers() {
    return _iceServers ?? {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'}
      ]
    };
  }
}
```

---

#### ✅ TODO 3.4: App Initialization anpassen
- [ ] ICE Config beim App-Start laden
- [ ] WebRTC Service mit dynamischer Config initialisieren
- [ ] Loading State während Config-Laden anzeigen

**Dateien:**
- `/client/lib/main.dart`
- Relevante Screens die WebRTC Service nutzen

**Details:**
```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // ICE Server Config laden
  await IceConfigService().loadConfig();
  
  runApp(MyApp());
}
```

---

### Phase 4: Testing & Validation
**Ziel:** Sicherstellen, dass die Integration funktioniert

#### ✅ TODO 4.1: Docker Container testen
- [ ] `.env` Datei validieren
- [ ] Docker Compose starten: `docker-compose up -d`
- [ ] coturn Logs prüfen: `docker logs peerwave-coturn`
- [ ] Node.js Server Logs prüfen: `docker logs peerwave-server`
- [ ] TURN Server von extern erreichbar? (Port-Forwarding checken)

**Commands:**
```bash
# Container starten
docker-compose up -d

# Logs checken
docker-compose logs -f

# TURN Server testen
# https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/
```

---

#### ✅ TODO 4.2: Node.js Server Endpoint testen
- [ ] `/client/meta` aufrufen
- [ ] Response validieren (ICE Servers vorhanden?)
- [ ] TURN Credentials validieren (Format korrekt?)

**Test:**
```bash
curl http://localhost:3000/client/meta
```

**Expected Response:**
```json
{
  "name": "PeerWave",
  "version": "1.0.0",
  "iceServers": [
    {
      "urls": ["stun:your-domain.com:3478"]
    },
    {
      "urls": ["turn:your-domain.com:3478"],
      "username": "1730419200:user123",
      "credential": "..."
    }
  ]
}
```

---

#### ✅ TODO 4.3: Flutter Client testen
- [ ] App starten
- [ ] ICE Server Config geladen? (Debug-Logs prüfen)
- [ ] WebRTC Verbindung aufbauen
- [ ] Browser DevTools: ICE Candidate Gathering prüfen
- [ ] TURN Server wird verwendet? (relay candidate sichtbar?)

**Validation:**
- Chrome DevTools → Console → `RTCPeerConnection` Logs
- Suche nach `candidate:...relay...` (TURN wird genutzt)
- Suche nach `srflx` (STUN wird genutzt)

---

#### ✅ TODO 4.4: WebRTC Trickle ICE Test
- [ ] Online Tool nutzen: https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/
- [ ] TURN Server Config eingeben
- [ ] Test durchführen → Sollte "relay" Candidates finden

---

### Phase 5: Security & Production Hardening
**Ziel:** Sicherheit und Production-Readiness

#### ✅ TODO 5.1: Secret Management
- [ ] `.env` zu `.gitignore` hinzufügen
- [ ] `.env.example` mit Platzhaltern erstellen
- [ ] Dokumentation für Secret-Setup erstellen

**Dateien:**
- `/.env.example` (neu erstellen)
- `/.gitignore` (erweitern)

---

#### ✅ TODO 5.2: TURN Credential Rotation
- [ ] TTL für Credentials auf sinnigen Wert setzen (24h)
- [ ] Client sollte Config regelmäßig neu laden (bei Bedarf)
- [ ] Expired Credentials Handling

**Details:**
- TTL im Response mitgeben
- Client prüft TTL und lädt Config neu wenn nötig

---

#### ✅ TODO 5.3: Production Configuration
- [ ] `docker-compose.prod.yml` mit Production-Settings
- [ ] TLS für TURNS aktivieren (Port 5349)
- [ ] Zertifikate für TLS bereitstellen
- [ ] Firewall-Regeln dokumentieren

**Firewall Ports:**
- 3478/udp (STUN/TURN)
- 3478/tcp (STUN/TURN)
- 5349/tcp (TURNS - TLS)
- 49152-65535/udp (TURN Relay Ports)

---

#### ✅ TODO 5.4: Monitoring & Logging
- [ ] coturn Prometheus Exporter aktivieren (optional)
- [ ] TURN-Usage Logs analysieren
- [ ] Failed Connection Alerts einrichten

---

### Phase 6: Documentation
**Ziel:** Setup-Dokumentation für Entwickler und Admins

#### ✅ TODO 6.1: Setup-Dokumentation
- [ ] README.md erweitern
- [ ] Docker Setup Guide
- [ ] Environment Variables dokumentieren
- [ ] Troubleshooting Section

**Dateien:**
- `/TURN_STUN_SETUP.md` (neu erstellen)

---

#### ✅ TODO 6.2: API Dokumentation
- [ ] `/client/meta` Response Format dokumentieren
- [ ] ICE Server Config Schema dokumentieren

---

## 📊 Implementierungs-Reihenfolge

### Sprint 1: Backend Setup (Tag 1)
1. TODO 1.1 - Docker Environment Variables
2. TODO 1.2 - coturn Konfiguration
3. TODO 2.1 - TURN Credential Helper
4. TODO 2.2 - `/client/meta` Endpoint erweitern
5. TODO 2.3 - Config-Modul erweitern

**Deliverable:** Node.js Server liefert dynamische TURN-Credentials

---

### Sprint 2: Frontend Integration (Tag 2)
6. TODO 3.1 - API Service erweitern
7. TODO 3.2 - WebRTC Service anpassen
8. TODO 3.3 - ICE Config Service erstellen
9. TODO 3.4 - App Initialization anpassen

**Deliverable:** Flutter Client nutzt dynamische ICE Server

---

### Sprint 3: Testing & Hardening (Tag 3)
10. TODO 4.1 - Docker Container testen
11. TODO 4.2 - Server Endpoint testen
12. TODO 4.3 - Flutter Client testen
13. TODO 4.4 - WebRTC Trickle ICE Test
14. TODO 5.1 - Secret Management
15. TODO 5.2 - Credential Rotation

**Deliverable:** Getestete und sichere Integration

---

### Sprint 4: Production & Docs (Tag 4)
16. TODO 5.3 - Production Configuration
17. TODO 5.4 - Monitoring & Logging
18. TODO 6.1 - Setup-Dokumentation
19. TODO 6.2 - API Dokumentation

**Deliverable:** Production-Ready Setup mit Dokumentation

---

## 🔧 Wichtige Hinweise

### Security Best Practices
1. **Nie** das TURN_SECRET im Code hardcoden
2. TURN-Credentials zeitlich begrenzen (TTL)
3. `.env` nie in Git committen
4. TLS für TURNS in Production nutzen

### Performance Optimierungen
1. STUN immer zuerst versuchen (kostenlos, schnell)
2. TURN nur als Fallback (verbraucht Server-Bandbreite)
3. Relay Port Range limitieren (nur so viel wie nötig)

### Troubleshooting Tipps
1. **Keine ICE Candidates:** Firewall/NAT Problem
2. **Nur host Candidates:** STUN/TURN nicht erreichbar
3. **Verbindung schlägt fehl:** TURN Credentials falsch
4. **Timeout:** Port-Forwarding fehlt

---

## 📚 Weitere Ressourcen

### WebRTC Testing Tools
- **Trickle ICE Test:** https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/
- **coturn Test:** https://icetest.info/

### Dokumentation
- **RFC 5389:** TURN Protocol
- **RFC 5766:** TURN Extensions
- **coturn Docs:** https://github.com/coturn/coturn

### Docker
- **coturn Image:** https://hub.docker.com/r/coturn/coturn
- **Docker Compose Docs:** https://docs.docker.com/compose/

---

## ✅ Definition of Done

**Die Integration ist abgeschlossen wenn:**

1. ✅ `.env` Datei existiert und alle Secrets enthält
2. ✅ Docker Container starten fehlerfrei
3. ✅ `/client/meta` liefert dynamische TURN-Credentials
4. ✅ Flutter Client lädt ICE Server Config beim Start
5. ✅ WebRTC Verbindungen nutzen TURN Server (relay candidates)
6. ✅ Trickle ICE Test zeigt erfolgreiche TURN-Verbindung
7. ✅ Dokumentation ist vollständig
8. ✅ `.env.example` existiert für Setup-Guide

---

**Erstellt am:** 31. Oktober 2025  
**Version:** 1.0  
**Status:** Ready for Implementation 🚀
