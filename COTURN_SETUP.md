# PeerWave COTURN Setup Guide

🚀 **Eigener STUN+TURN Server mit Docker**

## 📋 Inhaltsverzeichnis

1. [Überblick](#überblick)
2. [Installation](#installation)
3. [Konfiguration](#konfiguration)
4. [Integration in PeerWave](#integration-in-peerwave)
5. [Testing](#testing)
6. [Monitoring](#monitoring)
7. [Kosten & Performance](#kosten--performance)

---

## Überblick

**coturn** ist ein Open-Source STUN+TURN Server, der perfekt für WebRTC geeignet ist.

### Features
- ✅ STUN + TURN in einem Server
- ✅ UDP und TCP Support
- ✅ TLS/DTLS für sichere Verbindungen
- ✅ Docker Support (einfaches Deployment)
- ✅ REST API für dynamische Credentials
- ✅ Prometheus Metrics für Monitoring

### Vorteile gegenüber Public STUN
| Feature | Public STUN | Eigener coturn |
|---------|-------------|----------------|
| **Erfolgsrate** | 60-70% | 95-99% |
| **Kontrolle** | ❌ | ✅ |
| **Privacy** | ⚠️ (Google kennt IPs) | ✅ (volle Kontrolle) |
| **Monitoring** | ❌ | ✅ |
| **Kosten** | Kostenlos | ~5€/Monat |

---

## Installation

### Voraussetzungen
- Docker + Docker Compose
- Linux Server (empfohlen: Hetzner Cloud CPX11 - 5€/Monat)
- Öffentliche IP-Adresse
- Offene Ports: 3478, 49152-65535 (UDP)

### Setup Schritte

#### 1. Repository klonen
```bash
cd /opt/peerwave/server
```

#### 2. Setup ausführen
```bash
chmod +x coturn/setup.sh
./coturn/setup.sh
```

Das Script:
- ✅ Generiert Shared Secret
- ✅ Erkennt externe IP automatisch
- ✅ Konfiguriert turnserver.conf
- ✅ Erstellt Credential Helper

#### 3. COTURN starten
```bash
docker-compose -f docker-compose.coturn.yml up -d
```

#### 4. Firewall konfigurieren
```bash
# UFW (Ubuntu)
sudo ufw allow 3478/udp
sudo ufw allow 3478/tcp
sudo ufw allow 49152:65535/udp

# firewalld (CentOS/RHEL)
sudo firewall-cmd --permanent --add-port=3478/udp
sudo firewall-cmd --permanent --add-port=3478/tcp
sudo firewall-cmd --permanent --add-port=49152-65535/udp
sudo firewall-cmd --reload
```

---

## Konfiguration

### turnserver.conf

Die wichtigsten Einstellungen:

```conf
# Server IPs
listening-ip=0.0.0.0
external-ip=YOUR_SERVER_IP  # Automatisch erkannt

# Ports
listening-port=3478
tls-listening-port=5349

# Authentication
use-auth-secret
static-auth-secret=YOUR_SHARED_SECRET

# Performance
min-port=49152
max-port=65535
```

### Shared Secret Authentifizierung

**Vorteile:**
- ✅ Keine User-Datenbank nötig
- ✅ Temporäre Credentials (auto-expiring)
- ✅ HMAC-basiert (sicher)
- ✅ Perfekt für dynamische Apps

**Wie es funktioniert:**
```
1. Client fragt Server nach Credentials
2. Server generiert: username = timestamp:userid
3. Server berechnet: password = HMAC(username, shared_secret)
4. Client nutzt Credentials für TURN
5. COTURN validiert HMAC
6. Credentials expiren nach TTL (z.B. 24h)
```

---

## Integration in PeerWave

### 1. Environment Variables (.env)

```bash
# COTURN Configuration
TURN_SERVER_URL=turn:your-server.com:3478
STUN_SERVER_URL=stun:your-server.com:3478
TURN_SHARED_SECRET=your-shared-secret-from-setup
TURN_TTL=86400  # 24 Stunden
```

### 2. Backend Integration (server.js)

```javascript
const { setupIceServersRoute } = require('./lib/turn-credentials');

// Config laden
const TURN_CONFIG = {
  turnServerUrl: process.env.TURN_SERVER_URL,
  stunServerUrl: process.env.STUN_SERVER_URL,
  turnSharedSecret: process.env.TURN_SHARED_SECRET,
  turnTtl: 86400
};

// Route registrieren
setupIceServersRoute(app, TURN_CONFIG);
```

### 3. Client Integration (Flutter)

```dart
// services/ice_servers_service.dart
class IceServersService {
  Future<List<Map<String, dynamic>>> getIceServers() async {
    try {
      final response = await http.get(
        Uri.parse('${ApiService.baseUrl}/api/ice-servers'),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return List<Map<String, dynamic>>.from(data['iceServers']);
      }
    } catch (e) {
      print('Error fetching ICE servers: $e');
    }
    
    // Fallback: Public STUN
    return [
      {'urls': 'stun:stun.l.google.com:19302'}
    ];
  }
}

// Verwendung in WebRTC Setup
final iceServers = await IceServersService().getIceServers();

final rtcConfig = {
  'iceServers': iceServers,
  'iceCandidatePoolSize': 10,
};

final peerConnection = await createPeerConnection(rtcConfig);
```

### 4. Hybrid Strategie (Empfohlen!)

```javascript
// Kombination: Public STUN + Eigener TURN
const { getHybridIceServers } = require('./lib/turn-credentials');

app.get('/api/ice-servers', (req, res) => {
  const iceServers = getHybridIceServers({
    publicStunServers: [
      'stun:stun.l.google.com:19302',
      'stun:stun1.l.google.com:19302'
    ],
    stunServerUrl: process.env.STUN_SERVER_URL,
    turnServerUrl: process.env.TURN_SERVER_URL,
    turnSharedSecret: process.env.TURN_SHARED_SECRET,
    turnTtl: 86400
  });
  
  res.json({ iceServers });
});
```

**Vorteile der Hybrid-Strategie:**
- ✅ Public STUN für die meisten Fälle (60-70%)
- ✅ Eigener TURN als Fallback (30-40%)
- ✅ Beste Balance aus Kosten und Zuverlässigkeit
- ✅ Hohe Erfolgsrate (95%+)

---

## Testing

### 1. COTURN Status prüfen

```bash
# Container Status
docker-compose -f docker-compose.coturn.yml ps

# Logs ansehen
docker-compose -f docker-compose.coturn.yml logs -f coturn

# Container Shell
docker exec -it peerwave-coturn sh
```

### 2. Credentials generieren

```bash
./coturn/generate-credentials.sh
```

Output:
```
Username: 1730000000:peerwave-1698420000
Password: xT5n8KpQ...
TTL: 24 hours

WebRTC Config:
{
  username: '1730000000:peerwave-1698420000',
  credential: 'xT5n8KpQ...'
}
```

### 3. STUN/TURN testen

**Online Tool:**
https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/

**Eingabe:**
```
STUN URI: stun:your-server.com:3478
TURN URI: turn:your-server.com:3478
Username: (aus generate-credentials.sh)
Password: (aus generate-credentials.sh)
```

**Erwartetes Ergebnis:**
```
✅ srflx (Server Reflexive) - STUN funktioniert
✅ relay - TURN funktioniert
```

### 4. Backend Credentials Test

```bash
# Node.js Helper testen
node server/lib/turn-credentials.js
```

---

## Monitoring

### 1. Prometheus Metrics

COTURN exportiert automatisch Metrics auf Port 9641.

**Wichtige Metriken:**
```
# Aktive Allocations (TURN Sessions)
coturn_allocations_total

# Traffic
coturn_traffic_peer_rx_bytes
coturn_traffic_peer_tx_bytes

# Errors
coturn_errors_total
```

### 2. Grafana Dashboard

Beispiel Queries:
```promql
# Aktive TURN Sessions
sum(coturn_allocations_total)

# Traffic Rate
rate(coturn_traffic_peer_tx_bytes[5m])

# Error Rate
rate(coturn_errors_total[5m])
```

### 3. Simple Monitoring Script

```bash
#!/bin/bash
# monitor-coturn.sh

echo "COTURN Status"
echo "============="

# Container Running?
STATUS=$(docker inspect -f '{{.State.Status}}' peerwave-coturn 2>/dev/null)
echo "Container Status: $STATUS"

# Logs (letzte 10 Zeilen)
echo -e "\nRecent Logs:"
docker logs --tail 10 peerwave-coturn 2>&1 | grep -i error || echo "No errors"

# Listening Ports
echo -e "\nListening Ports:"
docker exec peerwave-coturn netstat -tuln | grep 3478 || echo "Port not open"
```

---

## Kosten & Performance

### Server Kosten (Hetzner Cloud)

| Server Type | vCPU | RAM | Traffic | Preis/Monat | Empfehlung |
|-------------|------|-----|---------|-------------|------------|
| **CPX11** | 2 | 2 GB | 20 TB | **4.85€** | ✅ **Perfekt für Start** |
| CPX21 | 3 | 4 GB | 20 TB | 9.65€ | Für viele Nutzer |
| CPX31 | 4 | 8 GB | 20 TB | 18.25€ | High Traffic |

### Traffic Schätzung

**Annahmen:**
- 100 aktive Nutzer/Tag
- 30% benötigen TURN (70% nutzen STUN)
- Durchschnittlich 50 MB File Transfer pro TURN Session

**Berechnung:**
```
30 TURN Sessions × 50 MB × 30 Tage = 45 GB/Monat
```

**Ergebnis:** CPX11 (20 TB Traffic) ist **massiv überdimensioniert** ✅

### Performance Monitoring

**Wichtige Werte:**
```bash
# CPU Usage (sollte < 50% sein)
docker stats peerwave-coturn --no-stream

# Netzwerk Traffic
docker stats peerwave-coturn --no-stream | awk '{print $8, $10}'

# Aktive Connections
docker exec peerwave-coturn netstat -an | grep :3478 | wc -l
```

---

## Empfehlung für PeerWave

### Phase 1: MVP (Jetzt)

```yaml
Strategie: Hybrid STUN/TURN
STUN: 
  - Public STUN (kostenlos, 60-70% Erfolg)
  - Eigener STUN (schneller, lokaler)
TURN:
  - Eigener coturn (30-40% Fallback)
Kosten: ~5€/Monat
Erfolgsrate: 95%+
Setup-Zeit: 30 Minuten
```

**Vorteile:**
- ✅ Sehr hohe Erfolgsrate
- ✅ Volle Kontrolle + Privacy
- ✅ Minimal Kosten
- ✅ Einfaches Setup (Docker)
- ✅ Production-ready

### Später: Skalierung

Bei vielen Nutzern (1000+):
- Mehrere TURN Server in verschiedenen Regionen
- Load Balancing via DNS (turn1.peerwave.com, turn2.peerwave.com)
- Geo-IP basiertes Routing

---

## Troubleshooting

### Problem: Keine TURN Candidates

**Ursache:** Firewall blockiert Ports

**Lösung:**
```bash
# Ports prüfen
sudo netstat -tuln | grep 3478
sudo netstat -tuln | grep 49152

# Firewall Status
sudo ufw status
sudo firewall-cmd --list-all

# Ports öffnen
sudo ufw allow 3478/udp
sudo ufw allow 49152:65535/udp
```

### Problem: Authentication Failed

**Ursache:** Falsche Credentials oder abgelaufene

**Lösung:**
```bash
# Neue Credentials generieren
./coturn/generate-credentials.sh

# Shared Secret prüfen
docker exec peerwave-coturn cat /etc/coturn/turnserver.conf | grep static-auth-secret
```

### Problem: Hohe CPU Last

**Ursache:** Zu viele Sessions oder DDoS

**Lösung:**
```bash
# Quotas aktivieren in turnserver.conf
user-quota=50
total-quota=500
max-bps=1024000  # 1 MB/s per user
```

---

## Zusammenfassung

✅ **Setup in 30 Minuten mit Docker**
✅ **Kosten: ~5€/Monat (Hetzner CPX11)**
✅ **Erfolgsrate: 95%+ (Hybrid Strategie)**
✅ **Production-ready mit Monitoring**
✅ **Perfekt für PeerWave P2P File Sharing**

**Nächster Schritt:**
```bash
cd /opt/peerwave/server
chmod +x coturn/setup.sh
./coturn/setup.sh
docker-compose -f docker-compose.coturn.yml up -d
```

🎉 **Done!**
