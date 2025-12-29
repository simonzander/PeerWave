# PeerWave Deployment Guide Summary

## Quick Reference

### Deployment Comparison

| Feature | Simple (docker-compose.yml) | Traefik (docker-compose.traefik.yml) |
|---------|----------------------------|--------------------------------------|
| **Setup Time** | 5 minutes | 15-30 minutes |
| **SSL/HTTPS** | Manual | Automatic (Let's Encrypt) |
| **Best For** | Development, Testing | Production, Public hosting |
| **Domain Required** | No (localhost) | Yes |
| **Reverse Proxy** | No | Yes (Traefik) |
| **Certificate Management** | Manual | Auto-renewal |

---

## File Structure Overview

```
PeerWave/
├── docker-compose.yml              # Simple deployment
├── docker-compose.traefik.yml      # Production with Traefik
├── .env.traefik.example            # Traefik environment template
├── server/.env.example             # Simple deployment template
├── livekit-config.yaml             # LiveKit configuration
├── livekit-certs/                  # TURN server certificates
│   ├── turn-cert.pem              # TLS certificate (gitignored)
│   └── turn-key.pem               # Private key (gitignored)
├── db/                             # SQLite database (gitignored)
│   └── peerwave.sqlite
├── CERTIFICATES.md                 # Certificate setup guide
└── README.md                       # Main documentation
```

---

## Key Differences: Simple vs Traefik

### Simple Deployment (docker-compose.yml)

**Pros:**
- ✅ Quick setup (5 minutes)
- ✅ No external dependencies
- ✅ Perfect for development
- ✅ Works offline

**Cons:**
- ❌ No automatic HTTPS
- ❌ Manual certificate management
- ❌ Exposed ports (3000, 7880)
- ❌ Not suitable for public hosting

**Use When:**
- Local development
- Internal network deployment
- Testing and debugging
- No domain/SSL needed

### Traefik Deployment (docker-compose.traefik.yml)

**Pros:**
- ✅ Automatic HTTPS (Let's Encrypt)
- ✅ Auto-certificate renewal
- ✅ Production-ready
- ✅ Clean URLs (no port numbers)
- ✅ Better security (reverse proxy)

**Cons:**
- ❌ Requires Traefik setup
- ❌ Requires domain
- ❌ More complex configuration
- ❌ Need external proxy network

**Use When:**
- Public-facing deployment
- Production environment
- Need automatic SSL
- Multiple services on same server

---

## Certificate Requirements

### Single Domain, Single Certificate, Different Routing

**You only need ONE Let's Encrypt certificate for your domain.**

```
Domain: app.peerwave.org
Certificate: One Let's Encrypt certificate
├── Traefik uses it for HTTPS (automatic)
└── LiveKit uses it for TURN/TLS (manual copy)
```

### Certificate Management by Deployment

| Component | Certificate Source | Management | Domain |
|-----------|-------------------|------------|---------|
| **Traefik (HTTPS)** | Let's Encrypt | Automatic (Traefik) | app.peerwave.org |
| **LiveKit (TURN)** | Same certificate | Manual copy | app.peerwave.org |

### Why Manual Copy for LiveKit?

Traefik stores certificates internally and auto-renews them. LiveKit runs in a separate container and needs the certificate files mounted as a volume.

**Solution:** Copy the same certificate to `livekit-certs/` directory and mount it to LiveKit container.

---

## Routing Architecture

### Simple Deployment

```
Client Browser/App
    ↓
http://localhost:3000 ────→ PeerWave Server (port 3000)
ws://localhost:7880 ───────→ LiveKit (port 7880)
turns://localhost:5349 ────→ LiveKit TURN (port 5349)
```

### Traefik Deployment

```
Client Browser/App
    ↓
https://app.peerwave.org ──→ [Traefik] ──→ PeerWave Server (internal)
                              ↓
                         (Manages HTTPS with Let's Encrypt)

wss://app.peerwave.org:7880 ────────────→ LiveKit (direct, bypasses Traefik)
turns://app.peerwave.org:5349 ──────────→ LiveKit TURN (direct, uses copied cert)
```

**Key Point:** HTTP/HTTPS goes through Traefik. WebRTC traffic goes direct to LiveKit.

---

## Port Exposure Comparison

### Simple Deployment
```
Host Machine               Container
─────────────────         ──────────
3000       → (HTTP)   →   3000   (server)
7880       → (WS)     →   7880   (livekit)
5349       → (TURN)   →   5349   (livekit)
443/udp    → (TURN)   →   443    (livekit)
30100-30400/udp        →   30100-30400 (media)
```

### Traefik Deployment
```
Host Machine               Traefik               Container
─────────────────         ─────────────         ──────────
80         → (HTTP)   →   [Traefik] → 443 →    3000   (server)
443        → (HTTPS)  →   [Traefik]
7880       → (WS)     →                  →      7880   (livekit)
5349       → (TURN)   →                  →      5349   (livekit)
443/udp    → (TURN)   →                  →      443    (livekit)
30100-30400/udp                          →      30100-30400 (media)
```

**Note:** In Traefik mode, port 3000 is NOT exposed to the host - only Traefik accesses it via internal network.

---

## When to Use What

### Use Simple Deployment If:
- ✅ Running locally for development
- ✅ Internal network only (company intranet)
- ✅ Don't need HTTPS
- ✅ Want quick testing
- ✅ Behind a different reverse proxy (not Traefik)

### Use Traefik Deployment If:
- ✅ Public-facing deployment
- ✅ Need automatic HTTPS
- ✅ Already using Traefik for other services
- ✅ Want production-grade setup
- ✅ Need certificate auto-renewal

---

## Migration Path

### From Simple to Traefik

1. **Backup your data:**
```bash
cp -r db db.backup
```

2. **Stop simple deployment:**
```bash
docker-compose down
```

3. **Setup Traefik:**
```bash
# Install Traefik (if not already)
docker network create proxy
# Deploy Traefik container with Let's Encrypt
```

4. **Get certificates for LiveKit (Choose ONE method):**

#### Method A: Extract from Traefik (Recommended if Traefik already running)

Traefik stores certificates in `acme.json`. Extract them:

```bash
# Install jq for JSON parsing
sudo apt install jq

# Find your Traefik acme.json location (common paths)
# /etc/traefik/acme.json OR ./traefik/acme.json

# Extract certificate
sudo cat /path/to/acme.json | \
  jq -r '.http.Certificates[] | select(.domain.main=="app.yourdomain.com") | .certificate' | \
  base64 -d > ./livekit-certs/turn-cert.pem

# Extract private key
sudo cat /path/to/acme.json | \
  jq -r '.http.Certificates[] | select(.domain.main=="app.yourdomain.com") | .key' | \
  base64 -d > ./livekit-certs/turn-key.pem

# Set permissions
chmod 644 ./livekit-certs/turn-cert.pem
chmod 600 ./livekit-certs/turn-key.pem
chown $(id -u):$(id -g) ./livekit-certs/*.pem
```

**Note:** Traefik auto-renews certificates. Set up a cron job to re-extract:

```bash
# Create extraction script
cat > ~/update-livekit-certs.sh << 'EOF'
#!/bin/bash
DOMAIN="app.yourdomain.com"
ACME_JSON="/path/to/acme.json"
PEERWAVE_DIR="/path/to/PeerWave"

# Extract certificates
cat $ACME_JSON | \
  jq -r ".http.Certificates[] | select(.domain.main==\"$DOMAIN\") | .certificate" | \
  base64 -d > $PEERWAVE_DIR/livekit-certs/turn-cert.pem

cat $ACME_JSON | \
  jq -r ".http.Certificates[] | select(.domain.main==\"$DOMAIN\") | .key" | \
  base64 -d > $PEERWAVE_DIR/livekit-certs/turn-key.pem

# Restart LiveKit
cd $PEERWAVE_DIR
docker-compose -f docker-compose.traefik.yml restart peerwave-livekit
EOF

chmod +x ~/update-livekit-certs.sh

# Add to crontab (run daily at 3 AM)
(crontab -l 2>/dev/null; echo "0 3 * * * /home/$(whoami)/update-livekit-certs.sh") | crontab -
```

#### Method B: Generate with DNS Challenge (If Traefik not yet running)

Use DNS challenge instead of standalone (doesn't need port 80):

```bash
# Stop Traefik temporarily if running
docker stop traefik

# Generate certificate with DNS challenge
sudo certbot certonly --manual --preferred-challenges dns -d app.yourdomain.com

# Follow prompts to add DNS TXT record
# Wait for DNS propagation (1-5 minutes)

# Copy to LiveKit
mkdir -p livekit-certs
sudo cp /etc/letsencrypt/live/app.yourdomain.com/fullchain.pem ./livekit-certs/turn-cert.pem
sudo cp /etc/letsencrypt/live/app.yourdomain.com/privkey.pem ./livekit-certs/turn-key.pem
sudo chown $(id -u):$(id -g) livekit-certs/*.pem

# Start Traefik
docker start traefik
```

7. **Deploy with Traefik:**
```bash
cp .env.traefik.example .env
nano .env  # Configure your domain and secrets

# Update livekit-config.yaml
nano livekit-config.yaml  # Set turn.domain: app.yourdomain.com
```

8. **Start PeerWave:**
```bash
docker-compose -f docker-compose.traefik.yml up -d
```

9. **Verify:**
```bash
# Check logs
docker-compose -f docker-compose.traefik.yml logs -f

# Test HTTPS
curl -I https://app.yourdomain.com
```

---

## Common Scenarios

### Scenario 1: Developer Testing
**Recommended:** Simple deployment
```bash
docker-compose up -d
# Access: http://localhost:3000
```

### Scenario 2: Company Internal Use
**Recommended:** Simple deployment with custom domain via /etc/hosts
```bash
# Add to /etc/hosts: 192.168.1.100  peerwave.local
docker-compose up -d
# Access: http://peerwave.local:3000
```

### Scenario 3: Small Public Instance
**Recommended:** Traefik deployment
```bash
docker-compose -f docker-compose.traefik.yml up -d
# Access: https://peerwave.yourdomain.com
```

### Scenario 4: Enterprise Deployment
**Recommended:** Traefik + external load balancer
- Multiple PeerWave instances behind load balancer
- Shared database (consider PostgreSQL migration)
- Redis for session storage
- Separate LiveKit cluster

---

## Environment Variable Cheat Sheet

### Minimal Setup (Development)
```bash
SESSION_SECRET=$(openssl rand -base64 32)
LIVEKIT_API_KEY=devkey
LIVEKIT_API_SECRET=secret
```

### Production Setup
```bash
DOMAIN=app.yourdomain.com
LIVEKIT_TURN_DOMAIN=app.yourdomain.com
SESSION_SECRET=$(openssl rand -base64 32)
LIVEKIT_API_KEY=$(openssl rand -base64 32)
LIVEKIT_API_SECRET=$(openssl rand -base64 32)
EMAIL_HOST=smtp.gmail.com
EMAIL_PORT=587
EMAIL_USER=your-email@gmail.com
EMAIL_PASS=your-app-password
```

---

## Troubleshooting Decision Tree

```
Cannot access PeerWave
    ├─ Simple deployment?
    │   ├─ Check: http://localhost:3000
    │   ├─ Check: docker-compose logs
    │   └─ Check: port 3000 not blocked
    │
    └─ Traefik deployment?
        ├─ Check: https://yourdomain.com
        ├─ Check: docker network ls (proxy exists?)
        ├─ Check: docker logs traefik
        └─ Check: DNS pointing to server

Video calls not working
    ├─ Check: docker-compose logs peerwave-livekit
    ├─ Check: Firewall (UDP ports 30100-30400)
    ├─ Check: TURN certificates valid
    ├─ Test: https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/
    └─ Verify: LIVEKIT_API_KEY matches in server and livekit

Certificate errors
    ├─ HTTP (port 443 TCP) → Traefik manages (auto)
    └─ TURN (port 5349) → Manual setup required
        ├─ Check: livekit-certs/turn-cert.pem exists
        ├─ Check: Certificate not expired
        └─ Check: Domain matches LIVEKIT_TURN_DOMAIN
```

---

## Quick Commands Reference

```bash
# Start simple
docker-compose up -d

# Start Traefik
docker-compose -f docker-compose.traefik.yml up -d

# View logs
docker-compose logs -f peerwave-server

# Restart LiveKit
docker-compose restart peerwave-livekit

# Check certificate expiry
openssl x509 -in livekit-certs/turn-cert.pem -noout -dates

# Generate secret
openssl rand -base64 32

# Test SMTP
docker exec -it peerwave-server node -e "require('nodemailer').createTransporter(require('./config/config.js').smtp).verify(console.log)"
```

---

## Support Resources

- **Certificate Setup**: [CERTIFICATES.md](CERTIFICATES.md)
- **Full Documentation**: [README.md](README.md)
- **GitHub Issues**: https://github.com/simonzander/PeerWave/issues
- **Email**: support@peerwave.org
