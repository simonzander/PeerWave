<div align="center>
  <img src="https://github.com/simonzander/PeerWave/blob/main/client/assets/images/peerwave.png?raw=true" height="100px" width="100px">
  <h1>
  PeerWave</h1>
  <strong>
    Self-hosted, end-to-end encrypted communication platform
  </strong>
  <br>
  <span>
    Messaging, file sharing, and real-time meetings built on WebRTC, Signal Protocol, and zero-trust principles.
  </span>
</div>
<br>

<p align="center">
  <a href="https://github.com/simonzander/PeerWave/actions/workflows/release.yml">
    <img src="https://github.com/simonzander/PeerWave/actions/workflows/release.yml/badge.svg" alt="Build Status">
  </a>
  <img src="https://img.shields.io/github/last-commit/simonzander/peerwave" alt="GitHub last commit">
  <a href="https://github.com/simonzander/PeerWave/issues?q=is:issue+is:open+label:bug">
    <img src="https://img.shields.io/github/issues-search?query=https%3A%2F%2Fgithub.com%2Fsimonzander%2FPeerWave%2Fissues%3Fq%3Dis%3Aissue%2Bis%3Aopen%2Blabel%3Abug&label=ISSUES&color=red" alt="GitHub issues">
  </a>
</p>

![License: Source-Available](https://img.shields.io/badge/license-Source--Available-blue.svg)
![Commercial Use Requires License](https://img.shields.io/badge/commercial%20use-requires%20license-red.svg)
![Not for SaaS Hosting](https://img.shields.io/badge/Hosting%2FSaaS-Requires%20Commercial%20License-orange)

## How it works

PeerWave is a self-hosted communication platform designed around a zero-trust model.  
All sensitive data is encrypted on the client before transmission and is never accessible to the server.

PeerWave uses the following core technologies:

- **Signal Protocol** for end-to-end encrypted messaging and key exchange
- **WebRTC** for peer-to-peer audio, video, and data transport
- **WebAuthn (Passkeys)** for passwordless authentication
- **Ephemeral session keys** for media encryption during calls and meetings

The server is responsible only for:
- user and channel metadata
- encrypted message routing
- WebRTC signaling

At no point does the server have access to plaintext messages, files, media streams, or encryption keys.

## Table of Contents
- [How it works?](#how-it-works)
- [Table of Contents](#table-of-contents)
- [Quick Start](#quick-start)
- [Getting Started](#getting-started)
  - [Node](#node)
  - [Docker Build](#docker-build)
  - [Docker Hub](#docker-hub)
- [Limitations](#limitations)
- [Support](#support)
- [License](#license)
  - [Commercial Licensing](#commercial-licensing)

## Quick Start

**New to PeerWave?** Choose your deployment:

1. **Local Testing:** Use [Docker Compose (Simple)](#option-1-docker-compose-simple---recommended-for-getting-started) - No SSL, runs on localhost
2. **Production:** Use [Docker Compose + Traefik](#option-2-docker-compose--traefik-production-with-ssl) - Auto SSL with Let's Encrypt
3. **Custom Build:** Use [Manual Build](#option-3-manual-build-from-source) - For developers

**Files you'll need:**
- `docker-compose.yml` or `docker-compose.traefik.yml` - Container orchestration
- `.env` - Your configuration (secrets, domain, etc.)
- `livekit-config.yaml` - Video server settings
- `nginx-livekit.conf` - Proxy config (Traefik deployment only)

---

### Deployment Options

Choose the deployment method that fits your needs:

| Method | Use Case | Complexity | Source |
|--------|----------|------------|--------|
| **Docker Compose (Simple)** | Local dev, small deployments | ⭐ Easy | Docker Hub |
| **Docker Compose + Traefik** | Production with SSL | ⭐⭐ Medium | Docker Hub |
| **Manual Build** | Custom modifications | ⭐⭐⭐ Advanced | Source Code |

---

### Option 1: Docker Compose (Simple - Recommended for Getting Started)

Perfect for local development or simple deployments without reverse proxy. Uses pre-built images from Docker Hub.

```bash
# 1. Download configuration files (recommended)
# Download only what you need:
# - docker-compose.yml
# - docker-compose.traefik.yml (if using Traefik)
# - server/.env.example or .env.traefik.example
#
# You can use:
#   wget https://raw.githubusercontent.com/simonzander/PeerWave/main/docker-compose.yml
#   wget https://raw.githubusercontent.com/simonzander/PeerWave/main/docker-compose.traefik.yml
#   wget https://raw.githubusercontent.com/simonzander/PeerWave/main/server/.env.example
#   wget https://raw.githubusercontent.com/simonzander/PeerWave/main/.env.traefik.example
#
# Or download from GitHub web UI.
#
# For developers: clone the repo if you want to build or modify the source.

# 2. Copy environment template
cp server/.env.example server/.env

# 3. Edit configuration - CHANGE THE SECRETS!
nano server/.env
# Required: SESSION_SECRET, LIVEKIT_API_KEY, LIVEKIT_API_SECRET

# 4. Start all services (images pulled from Docker Hub)
docker-compose up -d

# 5. View logs
docker-compose logs -f peerwave-server
```

**✅ Images:** Automatically pulled from Docker Hub (no build needed!)

**✅ Certificates:** 
- **Option A:** Provide your own - place `turn-cert.pem` and `turn-key.pem` in `./livekit-certs/` and restart
- **Option B:** Auto-generated self-signed (default, no manual setup needed!)

**Access PeerWave:** `http://localhost:3000`

---

### Option 2: Docker Compose + Traefik (Production with SSL)

Best for production deployments with automatic HTTPS via Let's Encrypt. Uses pre-built images from Docker Hub.

#### Prerequisites

1. **Traefik** running with Let's Encrypt configured
2. **Domain** pointing to your server
3. **Ports** 80, 443 open for Traefik
4. **Proxy network** created: `docker network create proxy`

#### Deployment Steps

```bash
# 1. Download configuration files (recommended)
# Download only what you need:
# - docker-compose.traefik.yml
# - .env.traefik.example
# - livekit-config.yaml (if customizing TURN domain)
# - nginx-livekit.conf.example (rename to nginx-livekit.conf)
#
# You can use:
#   wget https://raw.githubusercontent.com/simonzander/PeerWave/main/docker-compose.traefik.yml
#   wget https://raw.githubusercontent.com/simonzander/PeerWave/main/.env.traefik.example
#   wget https://raw.githubusercontent.com/simonzander/PeerWave/main/livekit-config.yaml
#   wget https://raw.githubusercontent.com/simonzander/PeerWave/main/nginx-livekit.conf.example
#
# Or download from GitHub web UI.
#
# For developers: clone the repo if you want to build or modify the source.

# 2. Copy Traefik environment template
cp .env.traefik.example .env

# 3. Copy nginx proxy configuration
cp nginx-livekit.conf.example nginx-livekit.conf

# 3. Copy nginx proxy configuration
cp nginx-livekit.conf.example nginx-livekit.conf

# 4. Edit configuration
nano .env
```

**Required variables:**
```bash
DOMAIN=app.yourdomain.com
HTTPS=true
LIVEKIT_TURN_DOMAIN=app.yourdomain.com
TRAEFIK_ACME_PATH=/etc/traefik/acme.json  # Your Traefik's acme.json path
LIVEKIT_CONFIG_PATH=/data/compose/25/livekit-config.yaml  # Absolute path
NGINX_LIVEKIT_CONFIG_PATH=/data/compose/25/nginx-livekit.conf  # Absolute path
SESSION_SECRET=$(openssl rand -base64 32)
LIVEKIT_API_KEY=$(openssl rand -base64 32)
LIVEKIT_API_SECRET=$(openssl rand -base64 32)
```

```bash
# 5. Update livekit-config.yaml with your domain and API keys
nano livekit-config.yaml
# Set: turn.domain: app.yourdomain.com
# Set: keys section with your LIVEKIT_API_KEY: LIVEKIT_API_SECRET

# 6. Verify nginx-livekit.conf (usually no changes needed)
# Should have: proxy_pass http://172.17.0.1:7880;

# 7. Start services (images pulled from Docker Hub, certs extracted automatically!)
docker-compose -f docker-compose.traefik.yml up -d

# 8. View logs
docker-compose -f docker-compose.traefik.yml logs -f
```

**✅ Images:** Automatically pulled from Docker Hub (no build needed!)

**✅ Certificates:** Auto-extracted from Traefik's acme.json (no manual setup needed!)

**Access PeerWave:** `https://app.yourdomain.com`

---

### Option 3: Manual Build from Source

For developers who want to customize PeerWave or contribute to development.

```bash
# 1. Clone repository
git clone https://github.com/simonzander/PeerWave.git
cd PeerWave

# 2. Build Flutter web client
cd client
flutter build web --release
cp -r build/web ../server/web

# 3. Build Docker image
cd ../server
docker build -t peerwave-custom:latest .

# 4. Update docker-compose.yml to use your custom image
# Change: image: simonzander/peerwave:latest
# To: image: peerwave-custom:latest

# 5. Configure and start
cp .env.example .env
nano .env  # Set your secrets
cd ..
docker-compose up -d
```

**📦 Build Script:** Use the provided build script for easier building:

```bash
# Linux/macOS
chmod +x build-docker.sh
./build-docker.sh v1.0.0

# Windows PowerShell
.\build-docker.ps1 v1.0.0

# Build and push to Docker Hub
./build-docker.sh v1.0.0 --push
```

**Access PeerWave:** `http://localhost:3000`

---

### Configuration

#### Required Environment Variables

| Variable | Description | Required | Example |
|----------|-------------|----------|---------|
| `DOMAIN` | Your domain | ✅ Traefik | `app.yourdomain.com` |
| `HTTPS` | Enable HTTPS/secure cookies | ✅ Traefik | `true` |
| `SESSION_SECRET` | Session encryption key | ✅ Yes | `$(openssl rand -base64 32)` |
| `LIVEKIT_API_KEY` | LiveKit API key | ✅ Yes | `$(openssl rand -base64 32)` |
| `LIVEKIT_API_SECRET` | LiveKit API secret | ✅ Yes | `$(openssl rand -base64 32)` |
| `LIVEKIT_TURN_DOMAIN` | Your domain for TURN | ✅ Prod | `app.yourdomain.com` |
| `TRAEFIK_ACME_PATH` | Path to Traefik's acme.json | ✅ Traefik | `/etc/traefik/acme.json` |
| `LIVEKIT_CONFIG_PATH` | Path to livekit-config.yaml | ✅ Traefik | `/data/compose/25/livekit-config.yaml` |
| `NGINX_LIVEKIT_CONFIG_PATH` | Path to nginx-livekit.conf | ✅ Traefik | `/data/compose/25/nginx-livekit.conf` |

#### Optional Environment Variables

| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `PORT` | Server port | `3000` | `4000` |
| `NODE_ENV` | Environment | `production` | `development` |
| `APP_URL` | Base application URL | `http://localhost:3000` | `https://app.yourdomain.com` |
| `HTTPS` | Enable secure cookies | `false` | `true` |
| `EMAIL_HOST` | SMTP server (optional) | - | `smtp.gmail.com` |
| `EMAIL_PORT` | SMTP port | `587` | `587` |
| `EMAIL_SECURE` | Use SSL/TLS | `false` | `true` |
| `EMAIL_USER` | SMTP username | - | `your-email@gmail.com` |
| `EMAIL_PASS` | SMTP password | - | `your-app-password` |
| `EMAIL_FROM` | From address | `no-reply@domain` | `"PeerWave" <noreply@yourdomain.com>` |
| `ADMIN_EMAILS` | Comma-separated admin emails | - | `admin@example.com,admin2@example.com` |
| `CLEANUP_INACTIVE_USER_DAYS` | Days until user marked inactive | `30` | `60` |
| `CLEANUP_SYSTEM_MESSAGES_DAYS` | System message retention | `1` | `3` |
| `CLEANUP_REGULAR_MESSAGES_DAYS` | Regular message retention | `7` | `14` |
| `CLEANUP_GROUP_MESSAGES_DAYS` | Group message retention | `7` | `30` |
| `CLEANUP_CRON_SCHEDULE` | Cleanup cron schedule | `0 2 * * *` | `0 3 * * *` |
| `CORS_ORIGINS` | Allowed origins | Auto | `https://app.yourdomain.com` |

#### Configuration Files

**server/.env** (Simple deployment):
```bash
# Required
SESSION_SECRET=your-long-random-string-here
LIVEKIT_API_KEY=your-livekit-key
LIVEKIT_API_SECRET=your-livekit-secret

# Optional - Email (for meeting invitations)
EMAIL_HOST=smtp.gmail.com
EMAIL_PORT=587
EMAIL_SECURE=true
EMAIL_USER=your-email@gmail.com
EMAIL_PASS=your-app-password
EMAIL_FROM="PeerWave" <noreply@yourdomain.com>

# Optional - Admin users
ADMIN_EMAILS=admin@example.com,admin2@example.com
```

**.env** (Traefik deployment):
```bash
# Required
DOMAIN=app.yourdomain.com
LIVEKIT_TURN_DOMAIN=app.yourdomain.com
TRAEFIK_ACME_PATH=/etc/traefik/acme.json
LIVEKIT_CONFIG_PATH=/data/compose/25/livekit-config.yaml
NGINX_LIVEKIT_CONFIG_PATH=/data/compose/25/nginx-livekit.conf
SESSION_SECRET=your-long-random-string
LIVEKIT_API_KEY=your-key
LIVEKIT_API_SECRET=your-secret

# Production settings
NODE_ENV=production
HTTPS=true
APP_URL=https://app.yourdomain.com

# Optional - Email (for meeting invitations)
EMAIL_HOST=smtp.gmail.com
EMAIL_PORT=587
EMAIL_SECURE=true
EMAIL_USER=your-email@gmail.com
EMAIL_PASS=your-app-password
EMAIL_FROM="PeerWave" <noreply@yourdomain.com>

# Optional - Admin users
ADMIN_EMAILS=admin@example.com
```

#### Generate Secure Secrets

```bash
# Linux/macOS
openssl rand -base64 32

# Windows PowerShell
[Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
```

**Important:** The `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` in your `.env` file must match the keys in `livekit-config.yaml`:

```yaml
# livekit-config.yaml
keys:
  your-api-key-here: your-api-secret-here
```

Both must use the same values for authentication to work.

---

### Native Clients

Download pre-built native clients from [GitHub Releases](https://github.com/simonzander/PeerWave/releases):

- **Windows**: `.exe` installer or portable `.zip`
- **Android**: `.apk`
- **macOS**: `.dmg` installer (coming soon)
- **Linux**: AppImage (coming soon)

#### Build from Source

**Windows:**
```bash
cd client
flutter build windows --release
```

**Android:**
```bash
cd client
flutter build apk --release --split-per-abi
```
See [ANDROID_BUILD.md](ANDROID_BUILD.md) for detailed Android build instructions.

**macOS:**
```bash
flutter build macos --release
```

**Linux:**
```bash
flutter build linux --release
```

---

### Production Deployment Checklist

#### Security (Critical!)

- [ ] Generate new `SESSION_SECRET` (min 32 chars): `openssl rand -base64 32`
- [ ] Generate new `LIVEKIT_API_KEY`: `openssl rand -base64 32`
- [ ] Generate new `LIVEKIT_API_SECRET`: `openssl rand -base64 32`
- [ ] **Never use** `devkey` or `secret` in production
- [ ] Setup TLS certificates for LiveKit TURN (see [CERTIFICATES.md](CERTIFICATES.md))

#### Configuration

- [ ] Set `NODE_ENV=production`
- [ ] Configure `LIVEKIT_TURN_DOMAIN` with your domain
- [ ] Set up email (SMTP) for meeting invitations
- [ ] Configure `CORS_ORIGINS` for your domain(s)
- [ ] Review and adjust `livekit-config.yaml` port ranges
- [ ] Verify TURN server connectivity with [trickle-ice](https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/)

---

### Required Ports

#### For Simple Deployment (docker-compose.yml)

| Port | Protocol | Service | Purpose |
|------|----------|---------|---------|
| 3000 | TCP | Web/API Server | Main application |
| 7880 | TCP | LiveKit WebSocket | WebRTC signaling |
| 7881 | TCP | LiveKit HTTP API | Internal API |
| 443 | UDP | TURN/UDP (QUIC) | P2P NAT traversal |
| 5349 | TCP/UDP | TURN/TLS | Firewall-friendly P2P |
| 30100-30200 | UDP | RTP Media | WebRTC audio/video |
| 30300-30400 | UDP | TURN Relay | P2P relay ports |

#### For Traefik Deployment (docker-compose.traefik.yml)

| Port | Protocol | Service | Purpose | Notes |
|------|----------|---------|---------|-------|
| 80 | TCP | HTTP | Redirect to HTTPS | Traefik managed |
| 443 | TCP | HTTPS | Web/API Server | Traefik managed |
| 7880 | TCP | LiveKit WS | WebRTC signaling | Via nginx proxy |
| 443 | UDP | TURN/UDP | P2P traversal | Direct to LiveKit |
| 5349 | TCP/UDP | TURN/TLS | Firewall-friendly | Direct to LiveKit |
| 30100-30200 | UDP | RTP Media | WebRTC streams | Direct to LiveKit |
| 30300-30400 | UDP | TURN Relay | P2P relay | Direct to LiveKit |

**Architecture Notes:**
- Traefik manages HTTPS (port 443 TCP) and routes to nginx proxy
- nginx proxy (bridge network) forwards WebSocket to LiveKit (host network)
- LiveKit uses **host networking** due to VPS limitations with UDP port ranges
- Direct UDP ports (443, 5349, 30100-30400) bind to host for WebRTC traffic

**VPS Compatibility:** If your VPS doesn't support bridge networking with UDP ports, this configuration uses host networking for LiveKit while keeping other services on bridge networks.

---

### Troubleshooting

For common issues and solutions, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

**VPS-Specific Issues:**
- Bridge networking fails with UDP ports → Use host networking (already configured in docker-compose.traefik.yml)
- 502 Bad Gateway with LiveKit → Check nginx-livekit.conf uses `172.17.0.1:7880`
- `host.docker.internal` doesn't work on Linux → Use Docker bridge gateway IP

Quick diagnostics:
```bash
# Check all services are running
docker-compose ps

# View logs
docker-compose logs --tail=50

# Test connectivity
curl -I http://localhost:3000
```

---

## License

PeerWave is **Source-Available**.

- Private, educational and personal use: **free**
- Viewing, studying, and modifying the source: **allowed**
- Commercial use (including company internal use): **requires a paid license**
- Hosting or offering PeerWave as a public service (SaaS / cloud / multi-tenant): **not permitted without a commercial license**

### Commercial Licensing

Buy your license at https://peerwave.org

**Contact for commercial use:**  
📧 license@peerwave.org 

⚠️ Note: Versions up to v0.x were licensed under MIT.

**This project is licensed under the PolyForm Shield License 1.0.0**
