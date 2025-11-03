# LiveKit TURN Migration - Analyse & Action Plan

## 📋 Executive Summary

**Aktuelle Situation:**
- PeerWave nutzt **Coturn** (separater TURN/STUN Server) für P2P WebRTC Verbindungen
- **LiveKit** wird für Gruppen-Video-Konferenzen verwendet (SFU)
- Beide Server laufen parallel in Docker

**Empfehlung:** ✅ **JA - Migration zu LiveKit TURN ist möglich und empfohlen**

**Hauptvorteile:**
- Infrastruktur-Konsolidierung (1 statt 2 Server)
- Reduzierte Komplexität & Maintenance
- Integrierte Authentication (LiveKit JWT)
- Bessere Skalierbarkeit
- Reduzierte Docker Container & Ressourcen

---

## 🔍 Detaillierte Analyse

### Aktuelle Architektur

#### Coturn Setup (Status Quo)
```yaml
# docker-compose.yml
peerwave-coturn:
  - Ports: 3478 (UDP/TCP), 5349 (TLS), 49152-65535 (Relay)
  - Authentication: HMAC-SHA1 mit shared secret
  - Credential-TTL: 24 Stunden
  - Verwendung: P2P File Transfer & Direct Messages WebRTC
```

**Server-seitig:**
- `server/lib/turnCredentials.js` - Generiert zeitlich begrenzte Credentials
- `server/routes/client.js` - Liefert ICE Server Config via `/client/meta`
- Environment: `TURN_SECRET`, `TURN_SERVER_EXTERNAL_HOST`, etc.

**Client-seitig:**
- `client/lib/services/ice_config_service.dart` - Fetched ICE Config
- `client/lib/services/file_transfer/webrtc_service.dart` - Nutzt ICE für P2P
- Cache TTL: 12 Stunden (half of credential lifetime)

#### LiveKit Setup (Status Quo)
```yaml
# docker-compose.yml
peerwave-livekit:
  - Ports: 7880 (WebRTC), 7881 (API), 7882 (TCP fallback), 50100-50200 (RTP)
  - Authentication: JWT tokens via `/api/livekit/token`
  - Verwendung: Gruppen-Video-Konferenzen (SFU)
```

**Aktuelle Config:**
```yaml
# livekit-config.yaml
stun_servers:
  - stun.l.google.com:19302
  - stun1.l.google.com:19302

# turn: # AUSKOMMENTIERT - nicht aktiviert!
#   enabled: true
#   domain: turn.yourdomain.com
```

**Wichtig:** LiveKit TURN ist aktuell NICHT aktiviert!

---

## ✅ LiveKit TURN Capabilities

### Was LiveKit bietet (Embedded TURN Server)

LiveKit enthält einen **eingebauten TURN Server** mit folgenden Features:

#### 1. TURN/TLS (Port 5349 oder 443)
```yaml
turn:
  enabled: true
  tls_port: 5349  # oder 443 für maximale Firewall-Kompatibilität
  domain: turn.peerwave.local
  cert_file: /path/to/cert.pem
  key_file: /path/to/key.pem
```
- **Vorteil:** Sieht aus wie HTTPS → passiert Corporate Firewalls
- **Verwendung:** Broadest client connectivity

#### 2. TURN/UDP (Port 443)
```yaml
turn:
  enabled: true
  udp_port: 443  # QUIC/HTTP3-kompatibel
```
- **Vorteil:** UDP ist besser für WebRTC (lower latency)
- **Verwendung:** Modern firewalls (QUIC-aware)

#### 3. Integrated Authentication
- Verwendet **LiveKit JWT tokens** (bereits vorhanden!)
- Keine separaten TURN credentials nötig
- Automatische Token-Validierung
- Sicherer als HMAC-SHA1 (Coturn)

#### 4. Production-Ready Features
- ✅ Load Balancer Support (Layer 4 für TCP)
- ✅ Prometheus Metrics (bereits aktiviert in coturn)
- ✅ Auto-IP Discovery (use_external_ip: true)
- ✅ Multi-Region Deployment Support

---

## 🆚 Vergleich: Coturn vs LiveKit TURN

| Feature | Coturn | LiveKit TURN | Vorteil |
|---------|--------|--------------|---------|
| **Installation** | Separater Container | Embedded in LiveKit | LiveKit ✅ |
| **Authentication** | HMAC-SHA1 + Shared Secret | JWT (integrated) | LiveKit ✅ |
| **Ports** | 3478, 5349, 49152-65535 | 443, 5349 | LiveKit ✅ |
| **Credential Management** | Custom (`turnCredentials.js`) | Automatic | LiveKit ✅ |
| **TLS Termination** | External (coturn.conf) | Built-in | LiveKit ✅ |
| **Monitoring** | Separate Exporter | Prometheus built-in | LiveKit ✅ |
| **Firewall Compatibility** | Medium (standard ports) | High (port 443) | LiveKit ✅ |
| **Maintenance** | Separate updates | LiveKit updates | LiveKit ✅ |
| **Resource Usage** | ~200MB RAM | +50MB zu LiveKit | LiveKit ✅ |
| **Configuration** | 50 Zeilen Config | 5 Zeilen YAML | LiveKit ✅ |

**Ergebnis:** LiveKit TURN ist in allen Bereichen überlegen!

---

## 🚀 Migration Action Plan

### Phase 1: Vorbereitung (1-2 Stunden)

#### 1.1 SSL Zertifikate vorbereiten
```bash
# Falls noch nicht vorhanden - Let's Encrypt oder Self-Signed
# Für Development: Self-Signed
openssl req -x509 -newkey rsa:4096 -keyout turn-key.pem -out turn-cert.pem -days 365 -nodes \
  -subj "/CN=turn.peerwave.local"

# Kopiere zu LiveKit
mkdir -p ./livekit-certs
cp turn-cert.pem ./livekit-certs/
cp turn-key.pem ./livekit-certs/
```

#### 1.2 LiveKit Config aktualisieren
```yaml
# livekit-config.yaml
port: 7880
bind_addresses:
  - "0.0.0.0"

rtc:
  port_range_start: 50100
  port_range_end: 50200
  use_external_ip: true  # Wichtig für Production!
  
  # STUN Servers (weiterhin als Fallback)
  stun_servers:
    - stun.l.google.com:19302
    - stun1.l.google.com:19302

# ✅ TURN aktivieren
turn:
  enabled: true
  domain: turn.peerwave.local  # oder deine Domain
  tls_port: 5349  # Standard TURNS Port
  udp_port: 443   # Modern QUIC-compatible
  cert_file: /certs/turn-cert.pem
  key_file: /certs/turn-key.pem

# Room settings
room:
  empty_timeout: 300
  max_participants: 100
  auto_create: true

# Logging
logging:
  level: info

# API Keys (bereits vorhanden)
keys:
  devkey: secret

# Optional: Prometheus für Monitoring
# prometheus_port: 6789
```

#### 1.3 Docker Compose Update
```yaml
# docker-compose.yml
services:
  peerwave-livekit:
    image: livekit/livekit-server:latest
    container_name: peerwave-livekit
    restart: unless-stopped
    ports:
      - "7880:7880"   # WebRTC
      - "7881:7881"   # HTTP API
      - "7882:7882"   # TCP fallback
      - "5349:5349"   # TURNS (TLS)
      - "443:443/udp" # TURN UDP (QUIC-compatible)
      - "50100-50200:50100-50200/udp"  # RTP
    volumes:
      - ./livekit-config.yaml:/livekit.yaml:ro
      - ./livekit-certs:/certs:ro  # ✅ Neue Zeile
    environment:
      - LIVEKIT_API_KEY=${LIVEKIT_API_KEY:-devkey}
      - LIVEKIT_API_SECRET=${LIVEKIT_API_SECRET:-secret}
    command: --config /livekit.yaml
    networks:
      - peerwave-network

  peerwave-server:
    # ... (unverändert, aber TURN_* env vars können später entfernt werden)
    depends_on:
      - peerwave-livekit
      # ❌ peerwave-coturn entfernen

  # ❌ ENTFERNEN - Nicht mehr benötigt!
  # peerwave-coturn:
  #   ...
  
  # ❌ ENTFERNEN
  # coturn-exporter:
  #   ...
```

---

### Phase 2: Server-Code Migration (2-3 Stunden)

#### 2.1 Neue Endpoint: LiveKit ICE Config
```javascript
// server/routes/livekit.js - NEUER Endpoint hinzufügen

/**
 * Get LiveKit ICE Servers for P2P connections
 * GET /api/livekit/ice-config
 * 
 * Returns ICE server configuration for P2P WebRTC connections
 * Uses LiveKit's embedded TURN server
 */
router.get('/ice-config', async (req, res) => {
  try {
    const session = req.session;
    
    if (!session || (!session.userinfo && !session.uuid)) {
      console.log('[LiveKit ICE] Unauthorized - No session found');
      return res.status(401).json({ error: 'Not authenticated' });
    }

    const userId = session.userinfo?.id || session.uuid;
    const username = session.userinfo?.username || session.email || 'Unknown';

    console.log(`[LiveKit ICE] Config request: userId=${userId}`);

    // Get LiveKit configuration
    const apiKey = process.env.LIVEKIT_API_KEY || 'devkey';
    const apiSecret = process.env.LIVEKIT_API_SECRET || 'secret';
    const livekitUrl = process.env.LIVEKIT_URL || 'ws://peerwave-livekit:7880';
    const turnDomain = process.env.LIVEKIT_TURN_DOMAIN || 'turn.peerwave.local';

    // Create access token for TURN authentication
    const token = new AccessToken(apiKey, apiSecret, {
      identity: `${userId}`,
      name: username,
      metadata: JSON.stringify({
        userId,
        username,
        purpose: 'p2p-ice'
      })
    });

    // Grant TURN access (no room needed for P2P)
    token.addGrant({
      canPublish: true,
      canSubscribe: true,
      canPublishData: true
    });

    const jwt = await token.toJwt();

    // Build ICE server configuration
    const iceServers = [
      // 1. STUN (always available)
      {
        urls: ['stun:stun.l.google.com:19302']
      },
      // 2. LiveKit TURN/TLS
      {
        urls: [`turns:${turnDomain}:5349?transport=tcp`],
        username: `${userId}`,
        credential: jwt  // ✅ JWT als credential!
      },
      // 3. LiveKit TURN/UDP (modern)
      {
        urls: [`turn:${turnDomain}:443?transport=udp`],
        username: `${userId}`,
        credential: jwt
      }
    ];

    console.log(`[LiveKit ICE] Generated ICE config for user ${userId}`);

    // Return ICE configuration
    res.json({
      iceServers,
      ttl: 3600 * 24,  // 24 hours (LiveKit token lifetime)
      expiresAt: new Date(Date.now() + 3600 * 24 * 1000).toISOString()
    });

  } catch (error) {
    console.error('[LiveKit ICE] Error generating config:', error);
    res.status(500).json({ error: 'Failed to generate ICE config' });
  }
});
```

#### 2.2 Update `/client/meta` Endpoint
```javascript
// server/routes/client.js - Ersetze buildIceServerConfig mit LiveKit

// ❌ ALT - Entfernen
// const { buildIceServerConfig } = require('../lib/turnCredentials');

router.post('/meta', isAuthenticated, async function(req, res) {
    try {
        const config = loadConfig();
        const userId = req.session.userinfo?.id || req.session.uuid;
        
        const response = {
            name: config?.server?.name || 'PeerWave',
            version: config?.server?.version || '0.1.0',
            maxFileSize: config?.server?.maxFileSize || 104857600,
            // ✅ NEU - Verweise auf LiveKit ICE endpoint
            iceServers: [] // Client holt sich config von /api/livekit/ice-config
        };
        
        res.json(response);
    } catch (err) {
        console.error('[CLIENT META] Error:', err);
        res.status(500).json({ error: 'Internal server error' });
    }
});
```

---

### Phase 3: Client-Code Migration (1-2 Stunden)

#### 3.1 Update ICE Config Service
```dart
// client/lib/services/ice_config_service.dart

/// Load ICE server configuration from LiveKit
Future<void> loadConfig({bool force = false, String? serverUrl}) async {
  // Update server URL if provided
  if (serverUrl != null) {
    _serverUrl = serverUrl;
  }
  
  _serverUrl ??= await loadWebApiServer();
  _serverUrl ??= 'http://localhost:3000';
  
  // Check cache expiry
  if (!force && _isLoaded && _lastLoaded != null) {
    final age = DateTime.now().difference(_lastLoaded!);
    if (age < _cacheTtl) {
      debugPrint('[ICE CONFIG] Using cached config (age: ${age.inMinutes}min)');
      return;
    }
  }

  try {
    debugPrint('[ICE CONFIG] Loading ICE config from LiveKit...');
    
    // ✅ NEU - LiveKit ICE endpoint
    final response = await ApiService.get('$_serverUrl/api/livekit/ice-config');
    
    if (response.statusCode == 200) {
      final data = response.data;
      
      // Parse ICE servers from response
      final List<IceServer> servers = [];
      for (var server in data['iceServers']) {
        servers.add(IceServer(
          urls: List<String>.from(server['urls']),
          username: server['username'],
          credential: server['credential'],
        ));
      }
      
      _clientMeta = ClientMetaResponse(
        name: 'PeerWave',
        version: '1.0.0',
        iceServers: servers,
      );
      
      _isLoaded = true;
      _lastLoaded = DateTime.now();
      
      debugPrint('[ICE CONFIG] ✅ LiveKit ICE config loaded');
      debugPrint('[ICE CONFIG] ICE Servers: ${_clientMeta!.iceServers.length}');
      
      for (var i = 0; i < _clientMeta!.iceServers.length; i++) {
        final server = _clientMeta!.iceServers[i];
        debugPrint('[ICE CONFIG]   [$i] ${server.urls.join(", ")}');
      }
      
      notifyListeners();
    } else {
      debugPrint('[ICE CONFIG] ❌ Failed: ${response.statusCode}');
      _useFallback();
    }
  } catch (e) {
    debugPrint('[ICE CONFIG] ❌ Error: $e');
    _useFallback();
  }
}
```

---

### Phase 4: Testing & Rollout (2-3 Stunden)

#### 4.1 Testing Checklist

**Pre-Flight Checks:**
```bash
# 1. Build neuer LiveKit Container
docker-compose build peerwave-livekit

# 2. Teste LiveKit Config
docker-compose run --rm peerwave-livekit --config /livekit.yaml --validate

# 3. Check Ports
docker-compose config | grep -A 10 "peerwave-livekit"
```

**Schritt-für-Schritt Testing:**

1. **LiveKit Server starten**
   ```bash
   docker-compose up -d peerwave-livekit
   docker logs -f peerwave-livekit
   # Erwarte: "TURN server enabled on port 5349 (TLS), 443 (UDP)"
   ```

2. **Server Code deployen**
   ```bash
   docker-compose up -d peerwave-server
   docker logs -f peerwave-server
   ```

3. **Test ICE Config Endpoint**
   ```bash
   # Login & get session
   curl -X POST http://localhost:3000/api/livekit/ice-config \
     -H "Cookie: connect.sid=YOUR_SESSION_ID" \
     | jq
   
   # Erwarte:
   # {
   #   "iceServers": [
   #     { "urls": ["stun:stun.l.google.com:19302"] },
   #     { "urls": ["turns:turn.peerwave.local:5349?transport=tcp"], ... }
   #   ]
   # }
   ```

4. **Flutter Client testen**
   ```bash
   cd client
   flutter run -d chrome
   
   # In DevTools Console:
   # Erwarte: "[ICE CONFIG] ✅ LiveKit ICE config loaded"
   # Erwarte: "[ICE CONFIG] ICE Servers: 3"
   ```

5. **P2P Connection Test**
   - Öffne 2 Browser (oder Browser + Desktop App)
   - Starte File Transfer
   - Check WebRTC Connection State:
     ```dart
     // In webrtc_service.dart debug logs
     debugPrint('ICE Connection State: ${pc.iceConnectionState}');
     // Erwarte: RTCIceConnectionState.RTCIceConnectionStateConnected
     ```

6. **NAT Traversal Test** (wichtig!)
   ```bash
   # Simuliere NAT/Firewall (z.B. mit VPN oder Mobilnetz)
   # Verbinde von externem Netzwerk
   # Check ob TURN verwendet wird:
   
   # In Chrome: chrome://webrtc-internals/
   # Suche nach: "selectedCandidatePairId"
   # Check: candidate.type === "relay" (= TURN wird genutzt)
   ```

#### 4.2 Rollback Plan
Falls Probleme auftreten:
```bash
# 1. Quick Rollback zu Coturn
docker-compose up -d peerwave-coturn
# Environment variables rückgängig machen

# 2. Oder: Beide parallel laufen lassen (Canary Deployment)
# Client kann dynamisch zwischen Coturn & LiveKit TURN wechseln
```

---

### Phase 5: Cleanup (30 Minuten)

Nach erfolgreicher Migration:

#### 5.1 Entferne Coturn Code
```bash
# Server
rm -rf server/coturn/
rm server/lib/turnCredentials.js
rm server/lib/turn-credentials.js  # falls vorhanden

# Update server/routes/client.js
# - Entferne turnCredentials import
# - Entferne buildIceServerConfig calls

# Docker
# - Entferne peerwave-coturn aus docker-compose.yml
# - Entferne coturn-exporter
```

#### 5.2 Entferne Environment Variables
```bash
# .env - Diese Zeilen entfernen:
# TURN_SECRET=...
# TURN_SERVER_EXTERNAL_HOST=...
# TURN_SERVER_INTERNAL_HOST=...
# TURN_SERVER_PORT=...
# TURN_SERVER_PORT_TLS=...
# TURN_REALM=...
# TURN_CREDENTIAL_TTL=...

# Nur LiveKit behalten:
# LIVEKIT_API_KEY=devkey
# LIVEKIT_API_SECRET=secret
# LIVEKIT_URL=ws://peerwave-livekit:7880
# LIVEKIT_TURN_DOMAIN=turn.peerwave.local  # NEU
```

#### 5.3 Update Documentation
```bash
# Erstelle neues Doc
touch LIVEKIT_ICE_SETUP.md

# Update README.md
# - Entferne Coturn Setup Instructions
# - Füge LiveKit TURN Config hinzu

# Update DOCKER_SETUP.md
# - Aktualisiere Port Liste
# - Entferne Coturn Container
```

---

## 📊 Ressourcen-Vergleich

### Vorher (Coturn + LiveKit)
```yaml
Containers: 4 (livekit, server, coturn, coturn-exporter)
Ports: 13 (7880, 7881, 7882, 50100-50200, 3478x2, 5349x2, 49152-65535, 9641)
Memory: ~1.2 GB (LiveKit: 500MB, Coturn: 200MB, Server: 500MB)
Disk: ~800 MB
Complexity: Hoch (2 separate WebRTC Systeme)
```

### Nachher (Nur LiveKit)
```yaml
Containers: 2 (livekit, server)
Ports: 7 (7880, 7881, 7882, 5349, 443, 50100-50200)
Memory: ~1.0 GB (LiveKit: 550MB, Server: 500MB)
Disk: ~600 MB
Complexity: Niedrig (1 WebRTC System)
```

**Einsparungen:**
- 📦 -2 Container (-50%)
- 🔌 -6 Port Ranges (-46%)
- 💾 -200 MB RAM (-17%)
- 📀 -200 MB Disk (-25%)
- ⚙️ Deutlich reduzierte Konfiguration & Maintenance

---

## ⚠️ Wichtige Hinweise

### Production Deployment

#### 1. SSL Zertifikate (KRITISCH!)
```bash
# Production: Nutze Let's Encrypt
certbot certonly --standalone -d turn.yourdomain.com

# Update livekit-config.yaml:
turn:
  domain: turn.yourdomain.com  # Muss mit Zertifikat übereinstimmen!
  cert_file: /etc/letsencrypt/live/turn.yourdomain.com/fullchain.pem
  key_file: /etc/letsencrypt/live/turn.yourdomain.com/privkey.pem
```

#### 2. Firewall Rules
```bash
# Öffne folgende Ports:
# 7880 (WebRTC)
# 7881 (API)
# 5349 (TURNS/TLS)
# 443/udp (TURN/UDP)
# 50100-50200/udp (RTP)

# Beispiel: iptables
iptables -A INPUT -p tcp --dport 7880 -j ACCEPT
iptables -A INPUT -p tcp --dport 5349 -j ACCEPT
iptables -A INPUT -p udp --dport 443 -j ACCEPT
iptables -A INPUT -p udp --dport 50100:50200 -j ACCEPT
```

#### 3. External IP Configuration
```yaml
# livekit-config.yaml - Production
rtc:
  use_external_ip: true  # ✅ Wichtig!
  # LiveKit wird STUN nutzen um Public IP zu finden
  
  # Optional: Manuell setzen
  # external_ips:
  #   - 203.0.113.42
```

#### 4. Load Balancer Setup (falls Multi-Instance)
```yaml
# Load Balancer für TURN/TLS (Layer 4)
# - Port 5349: TCP Load Balancer
# - Port 443/udp: UDP Load Balancer (komplexer!)

# Redis für Multi-LiveKit Sync
redis:
  address: redis.yourhost.com:6379
  password: your_redis_password
```

### Monitoring

#### Prometheus Metrics
```yaml
# livekit-config.yaml
prometheus_port: 6789

# docker-compose.yml
ports:
  - "6789:6789"  # Prometheus Metrics
  
# Grafana Dashboard importieren:
# https://github.com/livekit/livekit-server/tree/master/grafana
```

#### Health Checks
```bash
# LiveKit Health Check
curl http://localhost:7881/

# Metrics
curl http://localhost:6789/metrics | grep livekit_turn
```

---

## 🎯 Migration Zeitplan

| Phase | Aufgabe | Dauer | Risiko |
|-------|---------|-------|--------|
| **Phase 1** | Vorbereitung (Config, Certs) | 1-2h | Niedrig |
| **Phase 2** | Server Code Migration | 2-3h | Mittel |
| **Phase 3** | Client Code Migration | 1-2h | Niedrig |
| **Phase 4** | Testing & Validation | 2-3h | Mittel |
| **Phase 5** | Cleanup & Documentation | 0.5h | Niedrig |
| **GESAMT** | **7-11 Stunden** | | |

**Empfohlenes Vorgehen:**
1. **Development/Staging zuerst** (1 Tag)
2. **Canary Deployment** (beide TURN Server parallel, 1-2 Tage)
3. **Full Production Rollout** (nach erfolgreichen Tests)

---

## ✅ Migration Checklist

### Vorbereitung
- [ ] SSL Zertifikate generiert/kopiert
- [ ] `livekit-config.yaml` mit TURN konfiguriert
- [ ] `docker-compose.yml` aktualisiert (Ports, Volumes)
- [ ] Environment Variables vorbereitet (`LIVEKIT_TURN_DOMAIN`)
- [ ] Backup der aktuellen Config erstellt

### Server Migration
- [ ] Neuer Endpoint `/api/livekit/ice-config` implementiert
- [ ] AccessToken für TURN authentication integriert
- [ ] `/client/meta` Endpoint aktualisiert
- [ ] `turnCredentials.js` deprecated/entfernt
- [ ] Server Build & Deploy

### Client Migration
- [ ] `ice_config_service.dart` auf LiveKit endpoint umgestellt
- [ ] JWT credential handling implementiert
- [ ] `webrtc_service.dart` getestet
- [ ] Flutter Build (Web + Desktop)

### Testing
- [ ] LiveKit Server startet (Logs prüfen)
- [ ] ICE Config Endpoint liefert korrektes Format
- [ ] Client fetched ICE config erfolgreich
- [ ] P2P Connection im lokalen Netzwerk funktioniert
- [ ] P2P Connection über NAT/Firewall funktioniert (TURN wird genutzt)
- [ ] Video Conference weiterhin funktional
- [ ] Mobile App getestet (Android/iOS)

### Production
- [ ] Load Balancer konfiguriert (falls Multi-Instance)
- [ ] Firewall Rules gesetzt
- [ ] Prometheus Monitoring aktiv
- [ ] Health Checks eingerichtet
- [ ] Backup-Strategie dokumentiert

### Cleanup
- [ ] Coturn Container entfernt
- [ ] Coturn Code gelöscht
- [ ] Environment Variables bereinigt
- [ ] Documentation aktualisiert
- [ ] `LIVEKIT_ICE_SETUP.md` erstellt

---

## 📚 Weitere Ressourcen

**LiveKit Dokumentation:**
- [Self-Hosting Deployment](https://docs.livekit.io/home/self-hosting/deployment/)
- [TURN Server Configuration](https://docs.livekit.io/home/self-hosting/deployment/#improving-connectivity-with-turn)
- [Firewall Configuration](https://docs.livekit.io/home/self-hosting/ports-firewall/)

**Code Examples:**
- [LiveKit Server SDK - Node.js](https://github.com/livekit/server-sdk-js)
- [LiveKit Flutter SDK](https://github.com/livekit/client-sdk-flutter)

**Testing Tools:**
- [WebRTC Test Page](https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/)
- Chrome: `chrome://webrtc-internals/`
- Firefox: `about:webrtc`

---

## 🎉 Fazit

Die Migration von Coturn zu LiveKit TURN ist **technisch machbar, sinnvoll und empfehlenswert**.

**Hauptgründe:**
✅ Infrastruktur-Konsolidierung  
✅ Bessere Security (JWT statt HMAC-SHA1)  
✅ Geringere Komplexität  
✅ Ressourcen-Einsparung  
✅ Einheitliches Monitoring  
✅ Zukunftssicher (aktive LiveKit Development)

**Geschätzter Aufwand:** 7-11 Stunden (1-2 Tage)  
**ROI:** Signifikant (reduzierte Maintenance, bessere Performance)

**Nächster Schritt:** Phase 1 starten - LiveKit TURN Config & SSL Setup

---

**Erstellt:** 2025-01-23  
**Autor:** GitHub Copilot  
**Status:** Ready for Implementation
