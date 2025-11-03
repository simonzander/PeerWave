# 🐳 Docker Setup für PeerWave

## 📋 Übersicht

Diese Anleitung zeigt die Docker-basierte Development und Production Umgebung für PeerWave mit Node.js Server und coturn STUN/TURN Server.

---

## 🚀 Quick Start

### 1. Prerequisites

```bash
# Docker Desktop installiert?
docker --version
docker-compose --version

# Node.js (für lokale Development)
node --version  # v18+ empfohlen
```

### 2. Environment Setup

```bash
# .env Datei erstellen
cp .env.example .env

# .env bearbeiten (wichtig: TURN_SECRET anpassen!)
notepad .env
```

**Wichtig:** Generiere ein sicheres `TURN_SECRET`:
```bash
# PowerShell
-join ((65..90) + (97..122) + (48..57) | Get-Random -Count 32 | % {[char]$_})
```

### 3. Docker Containers starten

```bash
# Development Mode (mit Source Code Mounting)
docker-compose up

# Oder im Hintergrund
docker-compose up -d

# Logs anschauen
docker-compose logs -f
```

**Services verfügbar unter:**
- Node.js Server: http://localhost:4000
- coturn STUN/TURN: localhost:3478 (UDP/TCP)
- coturn Monitoring: http://localhost:9641 (optional)

---

## 🎯 VS Code Integration

### Tasks (Strg+Shift+B)

**Docker Tasks:**
- ✅ `Docker: Build All` - Alle Container bauen
- ✅ `Docker: Start Development` - Server + coturn starten
- ✅ `Docker: Stop All` - Alle Container stoppen
- ✅ `Docker: Logs (Follow)` - Live-Logs anzeigen
- ✅ `Docker: Restart All` - Alle Container neu starten

**Local Development Tasks:**
- ✅ `Local: Start Node.js Server` - Node.js direkt starten (ohne Docker)
- ✅ `Local: Start Flutter Client` - Flutter Client starten
- ✅ `Local: Start Server and Client` - Beide parallel starten

**Build Tasks:**
- ✅ `Flutter: Build Web` - Web-Build erstellen
- ✅ `Flutter: Build Web and Copy` - Build + ins server/web/ kopieren

### Launch Configurations (F5)

**Compounds (mehrere gleichzeitig):**
1. 🚀 **Local: Debug Server + Flutter Client** - Lokale Development
2. 🚀 **Local: Debug Server + Flutter Chrome** - Mit Chrome DevTools
3. 🐳 **Docker: Attach to Running Server** - An Docker-Container anhängen

**Single Configs:**
- 🟢 **Local: Debug Node.js Server** - Server lokal debuggen
- 🔵 **Local: Debug Flutter Client** - Flutter debuggen
- 🌐 **Local: Debug Flutter Chrome** - Flutter in Chrome
- 🐳 **Docker: Attach Node.js Server** - An Docker-Server anhängen
- 🐳 **Docker: Launch Server with Debug** - Docker mit Inspector starten

---

## 📁 Projektstruktur

```
PeerWave/
├── docker-compose.yml              # Development Setup
├── docker-compose.prod.yml         # Production Setup
├── .env.example                    # Template für .env
├── .env                            # Deine Secrets (nicht committen!)
│
├── server/
│   ├── Dockerfile                  # Node.js Server Image
│   ├── .dockerignore              # Was Docker ignoriert
│   ├── package.json
│   ├── server.js
│   │
│   ├── coturn/
│   │   ├── turnserver.conf        # coturn Konfiguration
│   │   ├── data/                  # coturn Daten (persistent)
│   │   └── setup.sh               # Setup-Script
│   │
│   ├── db/                         # SQLite Datenbank (persistent)
│   └── cert/                       # SSL Zertifikate (persistent)
│
└── .vscode/
    ├── tasks.json                  # Build/Run Tasks
    └── launch.json                 # Debug Configs
```

---

## 🔧 Docker Commands Cheat Sheet

### Container Management

```bash
# Alle Container starten
docker-compose up -d

# Nur Server starten
docker-compose up -d peerwave-server

# Nur coturn starten
docker-compose up -d peerwave-coturn

# Container stoppen
docker-compose stop

# Container stoppen + löschen
docker-compose down

# Container + Volumes löschen (⚠️ Daten weg!)
docker-compose down -v

# Container neu bauen
docker-compose build

# Einzelnen Container neu bauen
docker-compose build peerwave-server

# Container neu starten
docker-compose restart
```

### Logs & Debugging

```bash
# Alle Logs anschauen
docker-compose logs

# Live-Logs folgen
docker-compose logs -f

# Nur Server-Logs
docker-compose logs -f peerwave-server

# Nur coturn-Logs
docker-compose logs -f peerwave-coturn

# Letzte 100 Zeilen
docker-compose logs --tail=100
```

### Container Zugriff

```bash
# Shell im Server-Container
docker exec -it peerwave-server sh

# Shell im coturn-Container
docker exec -it peerwave-coturn sh

# Datei aus Container kopieren
docker cp peerwave-server:/usr/src/app/db/peerwave.sqlite ./backup.sqlite

# Datei in Container kopieren
docker cp ./config.js peerwave-server:/usr/src/app/config/
```

### Status & Monitoring

```bash
# Container Status anzeigen
docker-compose ps

# Ressourcen-Verbrauch
docker stats peerwave-server peerwave-coturn

# Container Details
docker inspect peerwave-server

# Netzwerk-Details
docker network inspect peerwave_peerwave-network
```

---

## 🌐 Netzwerk-Kommunikation

### Docker Network

Alle Container sind im `peerwave-network` (Bridge Network):

```
┌─────────────────────────────────────────────┐
│        peerwave-network (bridge)            │
│                                             │
│  ┌─────────────────┐  ┌─────────────────┐ │
│  │ peerwave-server │  │ peerwave-coturn │ │
│  │  (Node.js)      │  │  (STUN/TURN)    │ │
│  │  Port: 4000     │  │  Port: 3478     │ │
│  └─────────────────┘  └─────────────────┘ │
│          │                    │            │
│          └────────┬───────────┘            │
│                   │                        │
└───────────────────┼────────────────────────┘
                    │
                    ▼
              Host (localhost)
         Port 4000 → peerwave-server
         Port 3478 → peerwave-coturn
```

### Service Discovery

Server kann coturn erreichen via:
```javascript
// In Node.js Server
const TURN_HOST = process.env.TURN_SERVER_HOST || 'peerwave-coturn';
const TURN_PORT = process.env.TURN_SERVER_PORT || 3478;
```

### Port Mapping

| Service | Container Port | Host Port | Protokoll |
|---------|---------------|-----------|-----------|
| Node.js | 4000 | 4000 | HTTP |
| coturn STUN/TURN | 3478 | 3478 | UDP/TCP |
| coturn TURNS | 5349 | 5349 | UDP/TCP |
| coturn Relay | 49152-49252 | 49152-49252 | UDP |
| coturn Exporter | 9641 | 9641 | HTTP |

---

## 🔒 Production Deployment

### 1. Production Setup

```bash
# .env für Production konfigurieren
NODE_ENV=production
TURN_SECRET=<super-secure-secret>

# Production Build
docker-compose -f docker-compose.prod.yml build

# Production starten
docker-compose -f docker-compose.prod.yml up -d

# Status prüfen
docker-compose -f docker-compose.prod.yml ps

# Logs checken
docker-compose -f docker-compose.prod.yml logs -f
```

### 2. Unterschiede Dev vs. Production

| Aspekt | Development | Production |
|--------|-------------|------------|
| Source Code | Volume gemountet (hot-reload) | In Image gebacken |
| node_modules | Im Container | Im Image |
| Restart Policy | `unless-stopped` | `always` |
| Logging | Standard output | JSON mit Rotation (10MB, 3 Files) |
| coturn Network | Bridge (ports mapped) | `host` (bessere Performance) |
| Health Checks | Ja | Ja |
| User | node (non-root) | node (non-root) |

### 3. Health Checks

Server hat automatischen Health Check:
```bash
# Manuell testen
curl http://localhost:4000/health
```

Health Check läuft alle 30 Sekunden:
- Start grace period: 40s
- Timeout: 10s
- Retries: 3

---

## 🛠️ Troubleshooting

### Problem: Container startet nicht

```bash
# Logs anschauen
docker-compose logs peerwave-server

# Container-Status prüfen
docker-compose ps

# Einzeln starten für mehr Details
docker-compose up peerwave-server
```

### Problem: Port bereits belegt

```bash
# Welcher Prozess nutzt Port 4000?
netstat -ano | findstr :4000

# Process mit PID stoppen
taskkill /PID <PID> /F

# Oder anderen Port in docker-compose.yml
ports:
  - "4001:4000"  # Host:Container
```

### Problem: coturn erreicht Server nicht

```bash
# Netzwerk prüfen
docker network inspect peerwave_peerwave-network

# DNS-Auflösung testen (im Server-Container)
docker exec peerwave-server ping peerwave-coturn

# Environment-Variablen prüfen
docker exec peerwave-server env | grep TURN
```

### Problem: Source Code Änderungen nicht sichtbar

```bash
# Development Mode nutzt Volume-Mounting
# Prüfe docker-compose.yml:
volumes:
  - ./server:/usr/src/app  # ← Sollte vorhanden sein

# Container neu starten
docker-compose restart peerwave-server

# Falls immer noch nicht: Neu bauen
docker-compose up -d --build
```

### Problem: Permission Errors

```bash
# Dockerfile nutzt USER node (non-root)
# Stelle sicher dass Verzeichnisse beschreibbar sind

# Fix für db/ Verzeichnis
chmod -R 777 server/db

# Fix für coturn/data/
chmod -R 777 server/coturn/data
```

### Problem: Out of Memory

```bash
# Memory-Limit für Container setzen (docker-compose.yml)
services:
  peerwave-server:
    deploy:
      resources:
        limits:
          memory: 512M

# Oder global Docker Memory erhöhen (Docker Desktop Settings)
```

---

## 📊 Monitoring

### coturn Prometheus Exporter

```bash
# Mit Monitoring-Profil starten
docker-compose --profile monitoring up -d

# Metrics abrufen
curl http://localhost:9641/metrics
```

### Docker Stats

```bash
# Live-Monitoring
docker stats peerwave-server peerwave-coturn

# Einmalig
docker stats --no-stream
```

---

## 🔄 Updates & Maintenance

### Container Updates

```bash
# Neueste Images pullen
docker-compose pull

# Container mit neuen Images starten
docker-compose up -d

# Alte Images aufräumen
docker image prune -a
```

### Backup

```bash
# Datenbank sichern
docker cp peerwave-server:/usr/src/app/db/peerwave.sqlite ./backup/

# coturn Daten sichern
docker cp peerwave-coturn:/var/lib/coturn ./backup/coturn/

# Oder mit Volume Backup
docker run --rm -v peerwave_coturn-data:/data -v $(pwd)/backup:/backup alpine tar czf /backup/coturn-data.tar.gz -C /data .
```

### Restore

```bash
# Datenbank wiederherstellen
docker cp ./backup/peerwave.sqlite peerwave-server:/usr/src/app/db/

# Container neu starten
docker-compose restart peerwave-server
```

---

## ✅ Best Practices

1. **Nie Secrets committen**: `.env` immer in `.gitignore`
2. **Health Checks nutzen**: Server hat `/health` Endpoint
3. **Volumes für persistente Daten**: `db/`, `cert/`, `coturn/data/`
4. **Non-root User**: Dockerfile nutzt `USER node`
5. **Layer Caching**: `package.json` vor Source Code kopieren
6. **Log Rotation**: Production nutzt JSON Driver mit Limits
7. **Restart Policies**: `unless-stopped` (dev), `always` (prod)
8. **Netzwerk-Isolation**: Eigenes `peerwave-network`

---

## 🎓 Nächste Schritte

Nach Docker Setup:

1. **Dependencies hinzufügen** (für P2P File Sharing):
   ```bash
   cd client
   flutter pub add path_provider image pdf_render video_thumbnail battery_plus connectivity_plus
   ```

2. **Phase 1 Implementation starten**:
   - Storage Layer (IndexedDB + path_provider)
   - Chunking System (64 KB Chunks)
   - AES-GCM Encryption

3. **coturn testen**:
   ```bash
   # coturn Credentials generieren
   docker exec peerwave-coturn turnutils_uclient -v localhost
   ```

4. **VS Code Tasks nutzen**:
   - `Strg+Shift+B` → Docker Tasks
   - `F5` → Debug Configurations

---

## 📚 Weitere Ressourcen

- **Docker Compose Docs**: https://docs.docker.com/compose/
- **coturn Wiki**: https://github.com/coturn/coturn/wiki
- **Node.js Best Practices**: https://github.com/goldbergyoni/nodebestpractices
- **Flutter Web Deployment**: https://docs.flutter.dev/deployment/web

---

**Bereit für Phase 1 Implementation!** 🚀
