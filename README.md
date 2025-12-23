<div align="center>
  <img src="https://github.com/simonzander/PeerWave/blob/main/public/logo_43.png?raw=true" height="100px">
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
  <a href="https://github.com/simonzander/PeerWave/actions/workflows/docker-image.yml">
    <img src="https://github.com/simonzander/peerwave/actions/workflows/docker-image.yml/badge.svg" alt="Build Status">
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
- [Getting Started](#getting-started)
  - [Node](#node)
  - [Docker Build](#docker-build)
  - [Docker Hub](#docker-hub)
- [Limitations](#limitations)
- [Support](#support)
- [License](#license)
  - [Commercial Licensing](#commercial-licensing)

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
#
# You can use:
#   wget https://raw.githubusercontent.com/simonzander/PeerWave/main/docker-compose.traefik.yml
#   wget https://raw.githubusercontent.com/simonzander/PeerWave/main/.env.traefik.example
#   wget https://raw.githubusercontent.com/simonzander/PeerWave/main/livekit-config.yaml
#
# Or download from GitHub web UI.
#
# For developers: clone the repo if you want to build or modify the source.

# 2. Copy Traefik environment template
cp .env.traefik.example .env

# 3. Edit configuration
nano .env
```

**Required variables:**
```bash
DOMAIN=app.yourdomain.com
LIVEKIT_TURN_DOMAIN=app.yourdomain.com
TRAEFIK_ACME_PATH=/etc/traefik/acme.json  # Your Traefik's acme.json path
SESSION_SECRET=$(openssl rand -base64 32)
LIVEKIT_API_KEY=$(openssl rand -base64 32)
LIVEKIT_API_SECRET=$(openssl rand -base64 32)
```

```bash
# 4. Update livekit-config.yaml with your domain
nano livekit-config.yaml
# Set: turn.domain: app.yourdomain.com

# 5. Start services (images pulled from Docker Hub, certs extracted automatically!)
docker-compose -f docker-compose.traefik.yml up -d

# 6. View logs
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
| `SESSION_SECRET` | Session encryption key | ✅ Yes | `$(openssl rand -base64 32)` |
| `LIVEKIT_API_KEY` | LiveKit API key | ✅ Yes | `$(openssl rand -base64 32)` |
| `LIVEKIT_API_SECRET` | LiveKit API secret | ✅ Yes | `$(openssl rand -base64 32)` |
| `LIVEKIT_TURN_DOMAIN` | Your domain for TURN | ✅ Prod | `app.yourdomain.com` |
| `DOMAIN` | Your domain (Traefik) | ✅ Traefik | `app.yourdomain.com` |

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
| `ENABLE_BUYMEACOFFEE` | Show support link | `true` | `false` |
| `ENABLE_DOCUMENTATION` | Show documentation | `true` | `false` |
| `ENABLE_QUICKHOST` | Enable quick host | `true` | `false` |
| `ENABLE_CHANNELS` | Enable channels | `true` | `false` |
| `ENABLE_GITHUB` | Show GitHub link | `true` | `false` |
| `ENABLE_ABOUT` | Show about page | `true` | `false` |
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

---

### Native Clients

Download pre-built native clients from [GitHub Releases](https://github.com/simonzander/PeerWave/releases):

- **Windows**: `.exe` installer or portable `.zip`
- **macOS**: `.dmg` installer (coming soon)
- **Linux**: AppImage (coming soon)

#### Build from Source

```bash
# Windows
cd client
flutter build windows --release

# macOS  
flutter build macos --release

# Linux
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

| Port | Protocol | Service | Purpose | Traefik |
|------|----------|---------|---------|---------|
| 80 | TCP | HTTP | Redirect to HTTPS | ✅ Managed |
| 443 | TCP | HTTPS | Web/API Server | ✅ Managed |
| 7880 | TCP | LiveKit WS | WebRTC signaling | ❌ Direct |
| 443 | UDP | TURN/UDP | P2P traversal | ❌ Direct |
| 5349 | TCP/UDP | TURN/TLS | Firewall-friendly | ❌ Direct |
| 30100-30200 | UDP | RTP Media | WebRTC streams | ❌ Direct |
| 30300-30400 | UDP | TURN Relay | P2P relay | ❌ Direct |

**Note:** Traefik manages HTTP/HTTPS (ports 80/443 TCP). LiveKit requires direct port access for WebRTC.

---

### Troubleshooting

For common issues and solutions, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

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

## Limitations
The main limitation is your upload speed, which is shared with your direct peers. If you are streaming, factors like the codec, resolution, and quick refreshes can increase your CPU (for VP8/VP9) or GPU (for H.264) load and affect your upload speed. The Chrome browser can handle up to 512 data connections and 56 streams.

If you are sharing files, the file size and the number of files increase your memory usage. The files are splitted in chunks and your peers share also your downloaded file and hold the data in their memory.

## License

PeerWave is **Source-Available**.

- Private and personal use: **free**
- Viewing, studying, and modifying the source: **allowed**
- Commercial use (including company internal use): **requires a paid license**
- Hosting or offering PeerWave as a public service (SaaS / cloud / multi-tenant): **not permitted without a commercial license**

### Commercial Licensing

Buy your license at https://peerwave.org

**Contact for commercial use:**  
📧 license@peerwave.org 

⚠️ Note: Versions up to v0.x were licensed under MIT. Starting from v1.0.0, this project is licensed under the PolyForm Shield License 1.0.0.test
