# PeerWave Troubleshooting Guide

Common issues and solutions for PeerWave deployment and operation.

---

## Table of Contents

- [VPS and Network Issues](#vps-and-network-issues)
- [Web Client Issues](#web-client-issues)
- [Video Call Issues](#video-call-issues)
- [Database Issues](#database-issues)
- [Authentication Issues](#authentication-issues)
- [Certificate Issues](#certificate-issues)
- [Performance Issues](#performance-issues)
- [Email Issues](#email-issues)
- [Traefik Integration Issues](#traefik-integration-issues)
- [Getting Help](#getting-help)

---

## Web Client Issues

### Web client not loading

**Issue:** Blank page or 404 errors

**Solution:**
```bash
# Check web files exist in container
docker exec peerwave-server ls -la /usr/src/app/web/

# If missing, rebuild image with web client
./build-docker.sh latest

# Or pull latest from Docker Hub
docker-compose pull peerwave-server
docker-compose up -d
```

---

## Video Call Issues

### Video calls not working

**Issue:** Can't join meetings or see other participants

**Solutions:**

#### 1. Check LiveKit is running

```bash
docker-compose logs peerwave-livekit
# Should show: "LiveKit server started"
```

#### 2. Verify API credentials match

```bash
# Check .env file
grep LIVEKIT_API .env

# Check livekit-config.yaml
grep -A 1 "keys:" livekit-config.yaml

# They must match: LIVEKIT_API_KEY: LIVEKIT_API_SECRET in both files
# Example:
# .env: LIVEKIT_API_KEY=abc123
# .env: LIVEKIT_API_SECRET=xyz789
# livekit-config.yaml:
#   keys:
#     abc123: xyz789
```

#### 3. Test TURN server connectivity

- Visit: https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/
- Server: `turn:your-domain.com:5349`
- Username: `test`
- Credential: (your LIVEKIT_API_SECRET)
- Should show `relay` candidates

**Expected result:** You should see both `srflx` (STUN) and `relay` (TURN) candidates appear.

#### 4. Check firewall rules

```bash
# Ensure UDP ports are open
sudo ufw status | grep 30100
sudo ufw status | grep 443/udp
sudo ufw status | grep 5349

# If ports are blocked, open them:
sudo ufw allow 5349
sudo ufw allow 30100:30200/udp
sudo ufw allow 30300:30400/udp
```

#### 5. Verify certificate setup

```bash
# Check certificates exist and have correct permissions
ls -lh livekit-certs/
# turn-cert.pem should be 644, turn-key.pem should be 600

# Check certificate is valid
openssl x509 -in livekit-certs/turn-cert.pem -noout -dates

# Test TURN/TLS connection
openssl s_client -connect your-domain.com:5349
```

---

## Database Issues

### SQLite locked or permission denied

**Issue:** Database errors, locked database, or permission denied

**Solution:**

```bash
# Check volume permissions
ls -la ./db/

# Fix permissions (Docker user is typically 1000:1000)
sudo chown -R 1000:1000 ./db/
chmod 755 ./db/
chmod 644 ./db/peerwave.sqlite

# If issues persist, restart container
docker-compose restart peerwave-server
```

### Database corruption

**Issue:** Database corruption or integrity errors

**Solution:**

```bash
# Backup current database
cp ./db/peerwave.sqlite ./db/peerwave.sqlite.backup

# Check integrity
sqlite3 ./db/peerwave.sqlite "PRAGMA integrity_check;"

# If corrupted, restore from backup or start fresh
# Note: Starting fresh will lose all data
docker-compose down
rm ./db/peerwave.sqlite
docker-compose up -d
```

---

## Authentication Issues

### Session expired or unauthorized errors (native clients)

**Issue:** "Session expired" or "Unauthorized" errors in native clients

**Solutions:**

#### 1. Verify SESSION_SECRET is persistent

```bash
# Check .env file exists
cat server/.env | grep SESSION_SECRET

# Ensure it doesn't change between container restarts
docker-compose down && docker-compose up -d
```

**Important:** If you change `SESSION_SECRET`, all existing sessions will be invalidated.

#### 2. Check time synchronization

```bash
# Server and client clocks must be synchronized (within 5 minutes)
date

# Install NTP if needed
sudo apt install ntp
sudo systemctl enable ntp
sudo systemctl start ntp
```

#### 3. Clear client cache

- **Windows:** Delete `%APPDATA%/PeerWave`
- **macOS:** Delete `~/Library/Application Support/PeerWave`
- **Linux:** Delete `~/.config/PeerWave`

---

## Certificate Issues

### TURN server stops working after Let's Encrypt renewal

**Issue:** TURN server stops working after Let's Encrypt renewal

**Solutions:**

#### Option 1: Manual certificate update (Simple deployment)

```bash
# Copy renewed certificates
sudo cp /etc/letsencrypt/live/your-domain.com/fullchain.pem ./livekit-certs/turn-cert.pem
sudo cp /etc/letsencrypt/live/your-domain.com/privkey.pem ./livekit-certs/turn-key.pem
sudo chown $(id -u):$(id -g) livekit-certs/*.pem

# Restart LiveKit
docker-compose restart peerwave-livekit
```

#### Option 2: Automatic renewal (Traefik deployment)

If using `docker-compose.traefik.yml`, certificates should auto-renew via the `traefik-certs-dumper` sidecar. If not working:

```bash
# Check cert dumper is running
docker-compose -f docker-compose.traefik.yml logs traefik-certs-dumper

# Check extracted certificates
docker exec peerwave-cert-dumper ls -la /output

# Restart LiveKit to pick up new certs
docker-compose -f docker-compose.traefik.yml restart peerwave-livekit
```

#### Setup auto-renewal script (Simple deployment)

See [CERTIFICATES.md](CERTIFICATES.md) for detailed certificate management instructions.

### Self-signed certificate warnings

**Issue:** Browser warns about self-signed certificates

**Solution:**

This is expected for local/development deployments. For production:

1. Use Let's Encrypt certificates via Traefik (recommended)
2. Import self-signed certificates into client trust store (development only)

---

## Performance Issues

### High CPU/Memory usage

**Issue:** Server consuming excessive resources

**Solutions:**

#### 1. Limit concurrent meetings

```yaml
# livekit-config.yaml
room:
  max_participants: 50  # Reduce if needed
```

#### 2. Reduce video quality

```yaml
# livekit-config.yaml
video:
  max_bitrate: 2000000  # 2 Mbps (lower for less bandwidth)
```

#### 3. Enable database WAL mode

```bash
# In server/.env
DB_WAL_MODE=true
```

Restart the server after making this change.

#### 4. Monitor resources

```bash
# Real-time resource monitoring
docker stats peerwave-server peerwave-livekit

# Check logs for errors
docker-compose logs --tail=100 peerwave-server
docker-compose logs --tail=100 peerwave-livekit
```

#### 5. Adjust cleanup settings

```bash
# In server/.env - reduce message retention periods
CLEANUP_REGULAR_MESSAGES_DAYS=3  # Reduce from default 7
CLEANUP_GROUP_MESSAGES_DAYS=3    # Reduce from default 7
```

---

## Email Issues

### Meeting invitations not being sent

**Issue:** Meeting invitations not being sent

**Solutions:**

#### 1. Test SMTP configuration

```bash
# Test SMTP connection
docker exec -it peerwave-server node -e "
const nodemailer = require('nodemailer');
const config = require('./config/config.js');
if (!config.smtp) {
  console.log('SMTP not configured');
  process.exit(1);
}
const transporter = nodemailer.createTransporter(config.smtp);
transporter.verify((err, success) => {
  console.log(err ? 'SMTP Error: ' + err.message : 'SMTP OK');
  process.exit(err ? 1 : 0);
});
"
```

#### 2. Check environment variables

```bash
# Verify email settings
docker-compose exec peerwave-server env | grep EMAIL
```

#### 3. Common SMTP settings

**Gmail:**
```bash
EMAIL_HOST=smtp.gmail.com
EMAIL_PORT=587
EMAIL_SECURE=true
EMAIL_USER=your-email@gmail.com
EMAIL_PASS=your-app-password  # Use App Password, not regular password
```

**Outlook/Office365:**
```bash
EMAIL_HOST=smtp-mail.outlook.com
EMAIL_PORT=587
EMAIL_SECURE=true
EMAIL_USER=your-email@outlook.com
EMAIL_PASS=your-password
```

**Custom SMTP:**
```bash
EMAIL_HOST=smtp.yourdomain.com
EMAIL_PORT=587
EMAIL_SECURE=true
EMAIL_USER=your-username
EMAIL_PASS=your-password
```

---

## VPS and Network Issues

### Bridge networking fails with UDP port ranges

**Issue:** Docker fails to start with error: `failed to start userland proxy for port mapping` or `failed to set up container networking`

**Cause:** Some VPS providers (OpenVZ, LXC containers) have kernel/iptables limitations that prevent Docker from mapping large UDP port ranges in bridge mode.

**Solution:** Use host networking for LiveKit (already configured in docker-compose.traefik.yml):

```yaml
# LiveKit service uses host networking
peerwave-livekit:
  network_mode: host  # Binds directly to host ports
```

**Trade-off:** Host networking means:
- ✅ Works around VPS limitations
- ✅ Better performance (no NAT overhead)
- ❌ LiveKit can't communicate with bridge network containers
- ❌ Requires nginx proxy to bridge gap

**Verification:**
```bash
# Check if LiveKit is using host networking
docker inspect peerwave-livekit | grep NetworkMode
# Should show: "NetworkMode": "host"

# Verify ports are listening on host
ss -tlnp | grep 7880  # Should show LiveKit process
```

### 502 Bad Gateway with LiveKit WebSocket

**Issue:** Video calls fail with 502 Bad Gateway when connecting to `wss://domain/livekit/rtc`

**Cause:** nginx proxy can't reach LiveKit because `host.docker.internal` doesn't resolve on Linux VPS.

**Solutions:**

#### 1. Use Docker bridge gateway IP (Recommended)

```nginx
# nginx-livekit.conf
location / {
    proxy_pass http://172.17.0.1:7880;  # Docker bridge gateway IP
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}
```

**Why 172.17.0.1?** It's the default Docker bridge gateway IP that always points to the host machine on Linux.

#### 2. Verify Docker bridge gateway IP

```bash
# Check your Docker bridge gateway IP
ip addr show docker0
# Look for: inet 172.17.0.1/16

# Or check Docker network details
docker network inspect bridge | grep Gateway
```

#### 3. Test nginx connectivity

```bash
# Check nginx logs for connection errors
docker logs livekit-proxy --tail 20

# Test from inside nginx container
docker exec livekit-proxy wget -O- http://172.17.0.1:7880
# Should return LiveKit response, not connection refused

# Verify LiveKit is listening on host
ss -tlnp | grep 7880
# Should show: 0.0.0.0:7880 LISTEN
```

#### 4. Architecture overview

```
Client Browser
  ↓ wss://domain/livekit/rtc
Traefik (HTTPS:443 - TLS termination)
  ↓ HTTP to livekit-proxy:8080 (bridge network)
nginx-proxy
  ↓ proxy_pass to 172.17.0.1:7880
  ↓ (Docker bridge gateway → host)
LiveKit (host network, port 7880)
```

**Files to check:**
- `nginx-livekit.conf` - Must use `172.17.0.1:7880`
- `docker-compose.traefik.yml` - LiveKit must use `network_mode: host`
- `.env` - `LIVEKIT_URL` must be `wss://${DOMAIN}/livekit`

## Traefik Integration Issues

### 502 Bad Gateway or can't access via domain

**Issue:** 502 Bad Gateway or can't access via domain (main app, not LiveKit)

**Solutions:**

#### 1. Verify proxy network exists

```bash
docker network ls | grep proxy
# Create if missing:
docker network create proxy
```

#### 2. Check Traefik labels

```bash
docker inspect peerwave-server | grep -A 20 Labels
```

Expected labels:
```yaml
traefik.enable: "true"
traefik.http.routers.peerwave.rule: "Host(`your-domain.com`)"
traefik.http.services.peerwave.loadbalancer.server.port: "3000"
```

#### 3. View Traefik logs

```bash
docker logs traefik --tail=100

# Look for errors related to PeerWave service
docker logs traefik 2>&1 | grep peerwave
```

#### 4. Test direct container access

```bash
# Should work without Traefik
curl -I http://localhost:3000

# If this works but Traefik doesn't, issue is with Traefik configuration
```

#### 5. Verify domain DNS

```bash
# Check DNS resolution
nslookup your-domain.com

# Should point to your server's IP
```

---

## Getting Help

If you're still experiencing issues after trying these solutions:

### Before reporting an issue:

1. **Check existing issues:** [GitHub Issues](https://github.com/simonzander/PeerWave/issues)
2. **Review documentation:**
   - [CERTIFICATES.md](CERTIFICATES.md) - Certificate setup and management
   - [DEPLOYMENT.md](DEPLOYMENT.md) - Deployment guides
   - [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture

### When reporting an issue, include:

- **PeerWave version:** `docker-compose exec peerwave-server cat package.json | grep version`
- **Deployment method:** Docker Compose, Traefik, Manual build
- **Operating system:** Ubuntu 22.04, Windows 11, macOS, etc.
- **Browser/client version:** Chrome 120, Flutter Windows client v1.0.0, etc.
- **Error messages:** Full error messages and stack traces
- **Relevant logs:**
  ```bash
  docker-compose logs --tail=100 peerwave-server
  docker-compose logs --tail=100 peerwave-livekit
  ```

### Support channels:

- **Issues:** [GitHub Issues](https://github.com/simonzander/PeerWave/issues)
- **Discussions:** [GitHub Discussions](https://github.com/simonzander/PeerWave/discussions)
- **Email:** support@peerwave.org

---

## Quick Diagnostics

Run these commands to gather diagnostic information:

```bash
# Check all services are running
docker-compose ps

# View recent logs
docker-compose logs --tail=50

# Check port accessibility
ss -tlnp | grep -E '3000|7880|5349'

# Check disk space
df -h

# Check memory usage
free -h

# Test network connectivity
ping -c 3 8.8.8.8
```
