<div align="center>
  <img src="https://github.com/simonzander/PeerWave/blob/main/public/logo_43.png?raw=true" height="100px">
  <h1>
  PeerWave</h1>
  <strong>WebRTC share peer to peer to peer... the endless meshed wave of sharing</strong>
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

## How it works?

[![PeerWave Demo](https://img.youtube.com/vi/S69E2orWrys/default.jpg)](https://youtu.be/S69E2orWrys)

In the current version, you can share your screen, window, tab, or multiple files. This app uses [Socket.io](https://socket.io/) to manage some metadata for peers and files. The data is shared directly between peers without a server in the middle. All direct peers share the same stream or downloaded files to increase your audience and overcome limitations.

This is achieved using the [WebRTC](https://webrtc.org/) standard. A Google [STUN](https://en.wikipedia.org/wiki/STUN) server is used to establish connections between peers, but you can use your [own STUN server](https://www.stunprotocol.org/) if you host the app yourself. All metadata in this app is temporary and will be lost if the server restarts.

:rotating_light: **New Feature: Meeting** :rotating_light:

We're excited to announce our latest feature! You can now create a room for instant or scheduled meetings. Participants can join using their webcam and microphone, and even share their screens. Get ready to enhance your collaboration experience!

## Table of Contents
- [How it works?](#how-it-works)
- [Table of Contents](#table-of-contents)
- [Try It](#try-it)
- [Meeting](#meeting)
  - [Chat Function](#chat-function)
  - [Voice Only](#voice-only)
  - [Scheduled or Instant Meeting](#scheduled-or-instant-meeting)
  - [Emojis](#emojis)
  - [Switch Camera \& Microphone in Meeting](#switch-camera--microphone-in-meeting)
  - [Mute and Unmute](#mute-and-unmute)
  - [Camera On and Off](#camera-on-and-off)
  - [Screen Sharing](#screen-sharing)
  - [Set Max Cam Resolution to Prevent Traffic](#set-max-cam-resolution-to-prevent-traffic)
  - [Raise Hand](#raise-hand)
  - [Other Audio Output in Chrome with Test Sound](#other-audio-output-in-chrome-with-test-sound)
- [Stream Settings](#stream-settings)
  - [Cropping](#cropping)
  - [Resizing](#resizing)
- [Getting Started](#getting-started)
  - [Node](#node)
  - [Docker Build](#docker-build)
  - [Docker Hub](#docker-hub)
- [Limitations](#limitations)
- [Support](#support)
- [License](#license)
  - [Commercial Licensing](#commercial-licensing)

## Try It
You can find a running instance at [peerwave.org](https://peerwave.org)

## Meeting
Our new meeting feature provides a comprehensive set of tools designed to enhance your communication and collaboration experience. Below is a detailed overview of each capability:

### Chat Function
- **Description**: Engage in real-time text conversations alongside video meetings.
- **Usage**: Accessible via the chat icon within the meeting interface.

### Voice Only
- **Description**: Participate in meetings using audio-only mode.
- **Usage**: Select the voice-only option when creating the meeting.

### Scheduled or Instant Meeting
- **Description**: Create meetings that can either be scheduled for a future time or initiated instantly.
- **Usage**: Use the Schedule or Instant when you set up a meeting.

### Emojis
- **Description**: Express emotions and reactions using a variety of emojis during meetings.
- **Usage**: Access the emoji panel within the meeting interface.

### Switch Camera & Microphone in Meeting
- **Description**: Toggle between different cameras and microphones during the meeting.
- **Usage**: Use the bottom menu within the meeting interface to switch devices.

### Mute and Unmute
- **Description**: Control your audio input by muting or unmuting your microphone.
- **Usage**: Click the microphone icon to mute or unmute during the meeting.

### Camera On and Off
- **Description**: Turn your camera on or off during the meeting as needed.
- **Usage**: Click the camera icon to enable or disable your video feed.

### Screen Sharing
- **Description**: Share your screen to present documents, slides, or other content.
- **Usage**: Click the screen sharing button and select the screen or window you wish to share.

### Set Max Cam Resolution to Prevent Traffic
- **Description**: Optimize bandwidth usage by setting a maximum camera resolution.
- **Usage**: Adjust the camera resolution settings when you set up the meeting.

### Raise Hand
- **Description**: Indicate that you wish to speak without interrupting the conversation.
- **Usage**: Click the raise hand icon to notify the host and participants.

### Other Audio Output in Chrome with Test Sound
- **Description**: Select different audio outputs in Chrome and test sound settings to ensure optimal audio performance.
- **Usage**: Select Sound Output before joining the meeting. You can also test it.

These features are designed to provide a versatile and user-friendly meeting experience, enabling effective communication and collaboration.

## Stream Settings
### Cropping 
You can crop the hosted video with an experimental API that has not yet been standardized. As of 2024-06-19, this API is available in Chrome 94, Edge 94 and Opera 80.
### Resizing
You can resize the hosted video with an experimental API that has not yet been standardized. As of 2024-06-19, this API is available in Chrome 94, Edge 94 and Opera 80. 
## Getting Started

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

#### Infrastructure

- [ ] Setup SSL certificates (Traefik + LiveKit)
- [ ] Configure firewall rules (see Required Ports below)
- [ ] Setup database backups (volume: `./db`)
- [ ] Configure monitoring and logging
- [ ] Test video calls from different networks
- [ ] Verify TURN server connectivity with [trickle-ice](https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/)

#### Optional Enhancements

- [ ] Setup CDN for static assets
- [ ] Configure rate limiting
- [ ] Enable database WAL mode
- [ ] Setup log rotation
- [ ] Configure health checks
- [ ] Setup backup strategy

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

### Firewall Configuration

#### UFW (Ubuntu/Debian)

```bash
# Web (Traefik managed)
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# LiveKit WebRTC
sudo ufw allow 7880/tcp
sudo ufw allow 443/udp
sudo ufw allow 5349
sudo ufw allow 30100:30200/udp
sudo ufw allow 30300:30400/udp
```

#### firewalld (CentOS/RHEL)

```bash
# Web
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https

# LiveKit
sudo firewall-cmd --permanent --add-port=7880/tcp
sudo firewall-cmd --permanent --add-port=443/udp
sudo firewall-cmd --permanent --add-port=5349/tcp
sudo firewall-cmd --permanent --add-port=5349/udp
sudo firewall-cmd --permanent --add-port=30100-30200/udp
sudo firewall-cmd --permanent --add-port=30300-30400/udp

sudo firewall-cmd --reload
```

---

---

### Troubleshooting

#### Web client not loading

**Issue:** Blank page or 404 errors

**Solution:**
```bash
# Check web files exist in container
docker exec peerwave-server ls -la /usr/src/app/web/

# Rebuild image with web client
./build-docker.sh latest
```

#### Video calls not working

**Issue:** Can't join meetings or see other participants

**Solutions:**

1. **Check LiveKit is running:**
```bash
docker-compose logs peerwave-livekit
# Should show: "LiveKit server started"
```

2. **Verify API credentials match:**
```bash
# server/.env and docker-compose.yml must have same values
grep LIVEKIT_API server/.env
```

3. **Test TURN server connectivity:**
- Visit: https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/
- Server: `turn:your-domain.com:5349`
- Username: `test`
- Credential: (your LIVEKIT_API_SECRET)
- Should show `relay` candidates

4. **Check firewall rules:**
```bash
# Ensure UDP ports are open
sudo ufw status | grep 30100
sudo ufw status | grep 443/udp
```

5. **Verify certificate setup:**
```bash
# Check certificates exist and have correct permissions
ls -lh livekit-certs/
# turn-cert.pem should be 644, turn-key.pem should be 600

# Check certificate is valid
openssl x509 -in livekit-certs/turn-cert.pem -noout -dates

# Test TURN/TLS connection
openssl s_client -connect your-domain.com:5349
```

#### Database errors

**Issue:** SQLite locked or permission denied

**Solution:**
```bash
# Check volume permissions
ls -la ./db/

# Fix permissions
sudo chown -R 1000:1000 ./db/
chmod 755 ./db/
chmod 644 ./db/peerwave.sqlite
```

#### Authentication issues (native clients)

**Issue:** "Session expired" or "Unauthorized" errors

**Solutions:**

1. **Verify SESSION_SECRET is persistent:**
```bash
# Check .env file exists
cat server/.env | grep SESSION_SECRET

# Ensure it doesn't change between container restarts
docker-compose down && docker-compose up -d
```

2. **Check time synchronization:**
```bash
# Server and client clocks must be synchronized (within 5 minutes)
date
# Install NTP if needed
sudo apt install ntp
```

3. **Clear client cache:**
- Windows: Delete `%APPDATA%/PeerWave`
- macOS: Delete `~/Library/Application Support/PeerWave`
- Linux: Delete `~/.config/PeerWave`

#### Certificate renewal issues

**Issue:** TURN server stops working after Let's Encrypt renewal

**Solution:**
```bash
# Manually update certificates
sudo cp /etc/letsencrypt/live/your-domain.com/fullchain.pem ./livekit-certs/turn-cert.pem
sudo cp /etc/letsencrypt/live/your-domain.com/privkey.pem ./livekit-certs/turn-key.pem
sudo chown $(id -u):$(id -g) livekit-certs/*.pem

# Restart LiveKit
docker-compose restart peerwave-livekit

# Setup auto-renewal (see CERTIFICATES.md)
```

#### High CPU/Memory usage

**Issue:** Server consuming excessive resources

**Solutions:**

1. **Limit concurrent meetings:**
```yaml
# livekit-config.yaml
room:
  max_participants: 50  # Reduce if needed
```

2. **Reduce video quality:**
```yaml
# livekit-config.yaml
video:
  max_bitrate: 2000000  # 2 Mbps
```

3. **Enable database WAL mode:**
```bash
# In server/.env
DB_WAL_MODE=true
```

4. **Monitor resources:**
```bash
docker stats peerwave-server peerwave-livekit
```

#### Email sending fails

**Issue:** Meeting invitations not being sent

**Solution:**
```bash
# Test SMTP configuration
docker exec -it peerwave-server node -e "
const nodemailer = require('nodemailer');
const config = require('./config/config.js');
const transporter = nodemailer.createTransporter(config.smtp);
transporter.verify((err, success) => {
  console.log(err ? 'SMTP Error: ' + err.message : 'SMTP OK');
});
"
```

#### Traefik integration issues

**Issue:** 502 Bad Gateway or can't access via domain

**Solutions:**

1. **Verify proxy network exists:**
```bash
docker network ls | grep proxy
# Create if missing: docker network create proxy
```

2. **Check Traefik labels:**
```bash
docker inspect peerwave-server | grep -A 20 Labels
```

3. **View Traefik logs:**
```bash
docker logs traefik
```

4. **Test direct container access:**
```bash
# Should work without Traefik
curl -I http://localhost:3000
```

---

### Getting Help

- **Documentation**: Check [CERTIFICATES.md](CERTIFICATES.md) for SSL setup
- **Issues**: [GitHub Issues](https://github.com/simonzander/PeerWave/issues)
- **Discussions**: [GitHub Discussions](https://github.com/simonzander/PeerWave/discussions)
- **Email**: support@peerwave.org

When reporting issues, include:
- PeerWave version
- Deployment method (Docker Compose, Traefik, etc.)
- Browser/client version
- Relevant logs: `docker-compose logs --tail=100`

## Limitations
The main limitation is your upload speed, which is shared with your direct peers. If you are streaming, factors like the codec, resolution, and quick refreshes can increase your CPU (for VP8/VP9) or GPU (for H.264) load and affect your upload speed. The Chrome browser can handle up to 512 data connections and 56 streams.

If you are sharing files, the file size and the number of files increase your memory usage. The files are splitted in chunks and your peers share also your downloaded file and hold the data in their memory.

## Support
If you like this project, you can support me by [buying me a coffee](https://buymeacoffee.com/simonz). Feature requests and bug reports are welcome.

## License

PeerWave is **Source-Available**.

- Private and personal use: **free**
- Viewing, studying, and modifying the source: **allowed**
- Commercial use (including company internal use): **requires a paid license**
- Hosting or offering PeerWave as a public service (SaaS / cloud / multi-tenant): **not permitted without a commercial license**

### Commercial Licensing

Commercial licenses are based on company size (annual billing):

| Employees | Annual Price |
|---|---:|
| 1–5 | 199 € |
| 6–25 | 499 € |
| 26–100 | 1,499 € |
| 101–500 | 4,999 € |
| > 500 | Contact us |

**Contact for commercial use:**  
📧 license@peerwave.org 

⚠️ Note: Versions up to v0.x were licensed under MIT. Starting from v1.0.0, this project is licensed under the PolyForm Shield License 1.0.0.test
