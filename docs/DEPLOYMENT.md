# PeerWave Deployment Guide

This guide covers all deployment scenarios for PeerWave.

## Table of Contents
- [Architecture Overview](#architecture-overview)
- [Deployment Options](#deployment-options)
- [Quick Start with Docker Compose](#quick-start-with-docker-compose)
- [Manual Deployment](#manual-deployment)
- [Building from Source](#building-from-source)
- [Native Client Distribution](#native-client-distribution)
- [Production Deployment](#production-deployment)
- [Configuration Reference](#configuration-reference)
- [Troubleshooting](#troubleshooting)

## Architecture Overview

PeerWave consists of three main components:

```
┌─────────────────────────────────────────────────────────┐
│                    PeerWave Stack                        │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌────────────────────────────────────────────────┐    │
│  │         PeerWave Server (Node.js)              │    │
│  │  • Web Client (Flutter Web)                    │    │
│  │  • REST API & WebSocket                        │    │
│  │  • Signal Protocol E2EE                        │    │
│  │  • SQLite Database                             │    │
│  │  Port: 3000                                    │    │
│  └────────────────────────────────────────────────┘    │
│                                                          │
│  ┌────────────────────────────────────────────────┐    │
│  │         LiveKit Server (Go)                    │    │
│  │  • WebRTC SFU                                  │    │
│  │  • Built-in TURN server                       │    │
│  │  • Video/Audio streaming                      │    │
│  │  Ports: 7880, 7881, 5349, 443, 30100-30400   │    │
│  └────────────────────────────────────────────────┘    │
│                                                          │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│                    Native Clients                        │
├─────────────────────────────────────────────────────────┤
│  • Windows Desktop (Flutter)                            │
│  • macOS Desktop (Flutter) - Coming Soon                │
│  • Linux Desktop (Flutter) - Coming Soon                │
│  • Mobile (Future)                                      │
└─────────────────────────────────────────────────────────┘
```

## Deployment Options

### 1. Docker Compose (Recommended for Production)
- All services in containers
- Easy updates and rollbacks
- Persistent data with volumes
- Best for: Production, staging

### 2. Docker + Manual LiveKit
- Server in container
- Separate LiveKit installation
- Best for: Custom LiveKit configs

### 3. Manual Installation
- Direct Node.js + LiveKit
- No containerization
- Best for: Development, custom setups

### 4. Hybrid (Web + Native)
- Web client via Docker
- Native clients distributed separately
- Best for: End-user deployment

## Quick Start with Docker Compose

### Prerequisites
- Docker 20.10+
- Docker Compose 2.0+
- 2GB RAM minimum
- 10GB disk space

### Step 1: Clone Repository

```bash
git clone https://github.com/simonzander/PeerWave.git
cd PeerWave
```

### Step 2: Configure Environment

```bash
# Copy environment template
cp server/.env.example server/.env

# Generate secure secrets
openssl rand -base64 32  # For SESSION_SECRET
openssl rand -base64 32  # For LIVEKIT_API_KEY
openssl rand -base64 32  # For LIVEKIT_API_SECRET

# Edit .env file
nano server/.env
```

**Minimum required changes:**
```env
SESSION_SECRET=<your-generated-secret>
LIVEKIT_API_KEY=<your-generated-key>
LIVEKIT_API_SECRET=<your-generated-secret>
LIVEKIT_TURN_DOMAIN=your-domain.com  # Or IP address
```

### Step 3: Start Services

```bash
# Start in background
docker-compose up -d

# View logs
docker-compose logs -f

# Check status
docker-compose ps
```

### Step 4: Access Application

- **Web Interface**: http://localhost:3000
- **Health Check**: http://localhost:3000/health

### Step 5: Stop Services

```bash
# Stop services
docker-compose down

# Stop and remove volumes (WARNING: deletes data!)
docker-compose down -v
```

## Manual Deployment

### Prerequisites
- Node.js 22.x
- Flutter 3.27.1+
- SQLite3
- LiveKit Server (separate installation)

### Step 1: Build Web Client

```bash
cd client

# Install dependencies
flutter pub get

# Build web client
flutter build web --release --web-renderer canvaskit

# Copy to server
cp -r build/web ../server/web
```

### Step 2: Setup Server

```bash
cd server

# Install dependencies
npm install --production

# Copy environment template
cp .env.example .env

# Edit configuration
nano .env
```

### Step 3: Start Server

```bash
# Production mode
NODE_ENV=production node server.js

# Or with PM2
pm2 start server.js --name peerwave
```

### Step 4: Setup LiveKit

Follow [LiveKit installation guide](https://docs.livekit.io/home/self-hosting/deployment/)

Configure `livekit-config.yaml`:
```yaml
port: 7880
rtc:
  port_range_start: 30100
  port_range_end: 30200
  use_external_ip: true
turn:
  enabled: true
  domain: your-domain.com
  tls_port: 5349
  udp_port: 443
```

## Building from Source

### Build Docker Image with Web Client

```bash
# Linux/Mac
chmod +x build-docker.sh
./build-docker.sh v1.0.0

# Windows
.\build-docker.ps1 v1.0.0

# Build and push to Docker Hub
./build-docker.sh v1.0.0 --push
```

### Build Native Clients

**Windows:**
```bash
cd client
flutter build windows --release

# Create installer (requires Inno Setup)
iscc windows-installer.iss
```

**macOS:**
```bash
cd client
flutter build macos --release

# Create DMG (requires create-dmg)
create-dmg --volname "PeerWave" \
  --window-pos 200 120 \
  --window-size 800 400 \
  "PeerWave.dmg" \
  "build/macos/Build/Products/Release/PeerWave.app"
```

**Linux:**
```bash
cd client
flutter build linux --release

# Create AppImage (requires appimagetool)
./tools/create-appimage.sh
```

## Native Client Distribution

### GitHub Releases

Native clients are automatically built and published via GitHub Actions:

1. Tag a release: `git tag v1.0.0 && git push --tags`
2. GitHub Actions builds native clients
3. Clients uploaded to GitHub Releases

### Manual Distribution

**Installers:**
- `PeerWave-{version}-windows-installer.exe` - Windows installer
- `PeerWave-{version}-windows-x64.zip` - Windows portable
- `PeerWave-{version}.dmg` - macOS installer
- `PeerWave-{version}.AppImage` - Linux portable

**Checksums:**
Generate checksums for verification:
```bash
sha256sum PeerWave-* > checksums.txt
```

## Production Deployment

### Security Checklist

- [ ] Change all default secrets
- [ ] Use strong random passwords (32+ chars)
- [ ] Enable HTTPS with valid certificates
- [ ] Configure firewall rules
- [ ] Set up fail2ban for brute force protection
- [ ] Enable rate limiting
- [ ] Regular security updates
- [ ] Backup encryption keys

### SSL/TLS Setup

**With Let's Encrypt:**
```bash
# Install certbot
sudo apt install certbot

# Get certificate
sudo certbot certonly --standalone -d your-domain.com

# Configure server
ENABLE_HTTPS=true
CERT_PATH=/etc/letsencrypt/live/your-domain.com/fullchain.pem
KEY_PATH=/etc/letsencrypt/live/your-domain.com/privkey.pem
```

**With custom certificates:**
```bash
# Place certificates in server/cert/
cp your-cert.crt server/cert/server.crt
cp your-key.key server/cert/server.key

# Update docker-compose.yml
volumes:
  - ./server/cert:/usr/src/app/cert:ro
```

### Reverse Proxy (Nginx)

```nginx
server {
    listen 80;
    server_name your-domain.com;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name your-domain.com;

    ssl_certificate /etc/letsencrypt/live/your-domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/your-domain.com/privkey.pem;

    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Backup Strategy

**Database Backup:**
```bash
# Create backup directory
mkdir -p backups

# Backup SQLite database
cp server/db/peerwave.sqlite backups/peerwave-$(date +%Y%m%d-%H%M%S).sqlite

# Automated backup (cron)
0 2 * * * /path/to/backup-script.sh
```

**Docker Volume Backup:**
```bash
# Backup all volumes
docker run --rm \
  -v peerwave_db:/data \
  -v $(pwd)/backups:/backup \
  alpine tar czf /backup/db-backup.tar.gz /data
```

### Monitoring

**Health Checks:**
```bash
# Basic health
curl http://localhost:3000/health

# Detailed status
docker-compose ps
docker-compose logs --tail=100
```

**Metrics (Prometheus):**
```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'peerwave'
    static_configs:
      - targets: ['localhost:3000']
```

### Scaling

**Horizontal Scaling:**
- Use load balancer (Nginx, HAProxy)
- Sticky sessions required (Socket.IO)
- Shared Redis for session storage
- Shared database (PostgreSQL recommended)

**Vertical Scaling:**
```yaml
# docker-compose.yml
deploy:
  resources:
    limits:
      cpus: '4.0'
      memory: 8G
```

## Configuration Reference

See `server/config/config.example.js` and `server/.env.example` for complete reference.

### Essential Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `NODE_ENV` | Environment mode | `development` |
| `PORT` | Server port | `3000` |
| `SESSION_SECRET` | Session encryption key | **MUST CHANGE** |
| `LIVEKIT_URL` | LiveKit WebSocket URL | `ws://localhost:7880` |
| `LIVEKIT_API_KEY` | LiveKit API key | **MUST CHANGE** |
| `LIVEKIT_API_SECRET` | LiveKit API secret | **MUST CHANGE** |
| `LIVEKIT_TURN_DOMAIN` | TURN server domain | `localhost` |

### Optional Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `DB_PATH` | SQLite database path | `./db/peerwave.sqlite` |
| `CORS_ORIGINS` | Allowed CORS origins | `http://localhost:3000` |
| `MAX_FILE_SIZE` | Max upload size (bytes) | `104857600` (100MB) |
| `ENABLE_HTTPS` | Enable HTTPS | `false` |
| `LOG_LEVEL` | Logging level | `info` |

## Troubleshooting

### Web Client Not Loading
**Symptom:** Blank page or 404 errors

**Solution:**
```bash
# Rebuild web client
cd client
flutter build web --release
cp -r build/web ../server/web

# Or use build script
./build-docker.sh
```

### Database Locked Errors
**Symptom:** "Database is locked" in logs

**Solution:**
```env
# Enable WAL mode in .env
DB_WAL_MODE=true
```

### Video Calls Not Connecting
**Symptom:** Video hangs or doesn't connect

**Checklist:**
- [ ] LiveKit is running: `docker-compose logs peerwave-livekit`
- [ ] Firewall allows UDP ports 30100-30400
- [ ] TURN domain is correct public IP/domain
- [ ] Certificates valid (if using TURN over TLS)

### Native Client Connection Issues
**Symptom:** "Connection failed" or 401 errors

**Solution:**
```bash
# Check HMAC authentication
# Ensure SESSION_SECRET is persistent across restarts
# Verify server time is synchronized (NTP)
```

### Performance Issues
**Symptom:** Slow response or high CPU/memory

**Diagnosis:**
```bash
# Check resource usage
docker stats

# Check logs for errors
docker-compose logs --tail=500

# Database performance
sqlite3 db/peerwave.sqlite "VACUUM;"
```

## Support

- **Documentation**: [GitHub Wiki](https://github.com/simonzander/PeerWave/wiki)
- **Issues**: [GitHub Issues](https://github.com/simonzander/PeerWave/issues)
- **Discussions**: [GitHub Discussions](https://github.com/simonzander/PeerWave/discussions)
- **Commercial Support**: See [COMMERCIAL_LICENSE.md](../COMMERCIAL_LICENSE.md)
