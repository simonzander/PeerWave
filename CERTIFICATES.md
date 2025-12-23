# LiveKit Certificate Setup for Production

LiveKit's embedded TURN server requires TLS certificates for the TURN/TLS port (5349). 

## Certificate Architecture

**Good News:** You can use the **SAME Let's Encrypt certificate** for both HTTP/HTTPS and LiveKit TURN.

### Single Domain, Single Certificate:

```
Domain: app.peerwave.org
Certificate: /etc/letsencrypt/live/app.peerwave.org/
├── Used by Traefik for HTTPS (port 443 TCP) → Automatic
└── Used by LiveKit for TURN/TLS (port 5349) → Manual copy required
```

### Why Two Setups Are Needed:

1. **Traefik manages HTTP/HTTPS automatically:**
   - Traefik reads certificates from Let's Encrypt
   - Auto-renewal handled by Traefik
   - No manual work needed

2. **LiveKit needs certificate manually copied:**
   - LiveKit container runs independently
   - Can't access Traefik's certificate store
   - Needs certificates mounted as volume

**Result:** One certificate, two locations, same domain.

## Certificate vs Routing

### Common Confusion:

❌ **Wrong thinking:** "Different services need different certificates"
✅ **Correct:** "One certificate for the domain, different routing for services"

### Traffic Routing:

```
app.peerwave.org (One Let's Encrypt Certificate)

HTTP/HTTPS (Port 443 TCP)
   ↓
[Traefik Reverse Proxy] ← Manages certificate automatically
   ↓
PeerWave Server Container

WebRTC/TURN (Ports 7880, 5349, 30100-30400)
   ↓
[Direct Port Exposure] ← Needs certificate manually copied
   ↓
LiveKit Container
```

### Why Different Routing?

- **Traefik** = HTTP reverse proxy (handles only HTTP/HTTPS traffic)
- **LiveKit** = WebRTC media server (needs direct UDP/TCP access for media)
- **WebRTC can't go through HTTP proxy** (requires direct peer-to-peer connectivity)

## Quick Setup (Let's Encrypt with Certbot)

### 1. Install Certbot

```bash
# Ubuntu/Debian
sudo apt install certbot

# CentOS/RHEL
sudo yum install certbot
```

### 2. Generate Certificates

```bash
# Replace with your domain
DOMAIN="app.yourdomain.com"

# Generate certificate (standalone - requires port 80 temporarily)
sudo certbot certonly --standalone -d $DOMAIN

# Or use DNS challenge (if port 80 is occupied)
sudo certbot certonly --manual --preferred-challenges dns -d $DOMAIN
```

### 3. Copy Certificates to PeerWave

**Important:** You're copying the SAME certificate to LiveKit, not generating a separate one.

```bash
# Create livekit-certs directory
mkdir -p livekit-certs

# Copy certificates (use YOUR domain)
DOMAIN="app.peerwave.org"
sudo cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem ./livekit-certs/turn-cert.pem
sudo cp /etc/letsencrypt/live/$DOMAIN/privkey.pem ./livekit-certs/turn-key.pem

# Set proper permissions
sudo chmod 644 ./livekit-certs/turn-cert.pem
sudo chmod 600 ./livekit-certs/turn-key.pem
sudo chown $(id -u):$(id -g) ./livekit-certs/*.pem
```

**What happens:**
- Traefik uses: `/etc/letsencrypt/live/app.peerwave.org/*` (automatic)
- LiveKit uses: `./livekit-certs/turn-*.pem` (copied from same certificate)

### 4. Auto-Renewal Setup

Create renewal hook to update LiveKit certificates:

```bash
# Create renewal hook script
sudo nano /etc/letsencrypt/renewal-hooks/deploy/peerwave-update.sh
```

Add this content:

```bash
#!/bin/bash
# Update LiveKit certificates after Let's Encrypt renewal

DOMAIN="app.yourdomain.com"
PEERWAVE_PATH="/path/to/PeerWave"

# Copy renewed certificates
cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem $PEERWAVE_PATH/livekit-certs/turn-cert.pem
cp /etc/letsencrypt/live/$DOMAIN/privkey.pem $PEERWAVE_PATH/livekit-certs/turn-key.pem

# Set permissions
chmod 644 $PEERWAVE_PATH/livekit-certs/turn-cert.pem
chmod 600 $PEERWAVE_PATH/livekit-certs/turn-key.pem

# Restart LiveKit container
cd $PEERWAVE_PATH
docker-compose -f docker-compose.traefik.yml restart peerwave-livekit
```

Make it executable:

```bash
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/peerwave-update.sh
```

### 5. Test Renewal

```bash
# Dry run
sudo certbot renew --dry-run
```

## Alternative: Self-Signed Certificates (Development Only)

⚠️ **Not recommended for production** - browsers will show warnings

```bash
# Generate self-signed certificate
openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout livekit-certs/turn-key.pem \
  -out livekit-certs/turn-cert.pem \
  -days 365 \
  -subj "/CN=turn.peerwave.local"

# Set permissions
chmod 644 livekit-certs/turn-cert.pem
chmod 600 livekit-certs/turn-key.pem
```

## Verify Certificate Setup

```bash
# Check certificate files exist
ls -lh livekit-certs/

# Check certificate expiry
openssl x509 -in livekit-certs/turn-cert.pem -noout -dates

# Test TURN/TLS connection
openssl s_client -connect your-domain.com:5349 -showcerts
```

## Update livekit-config.yaml

Ensure your [livekit-config.yaml](../livekit-config.yaml) points to the certificates:

```yaml
turn:
  enabled: true
  domain: app.yourdomain.com  # Must match certificate CN/SAN
  tls_port: 5349
  udp_port: 443
  cert_file: /certs/turn-cert.pem
  key_file: /certs/turn-key.pem
```

## Troubleshooting

**"Certificate verify failed" errors:**
- Ensure certificate CN/SAN matches `LIVEKIT_TURN_DOMAIN`
- Check certificate is not expired: `openssl x509 -in turn-cert.pem -noout -dates`
- Verify file permissions (cert: 644, key: 600)

**Certificates not found in container:**
- Check volume mount in docker-compose: `- ./livekit-certs:/certs:ro`
- Verify files exist: `ls -lh livekit-certs/`

**Auto-renewal not working:**
- Test renewal hook: `sudo /etc/letsencrypt/renewal-hooks/deploy/peerwave-update.sh`
- Check certbot logs: `sudo cat /var/log/letsencrypt/letsencrypt.log`

## Certificate Lifecycle

1. **Initial Setup**: Generate certificates with certbot
2. **Deployment**: Copy to `livekit-certs/` directory
3. **Auto-Renewal**: Let's Encrypt renews every 60 days
4. **Hook Execution**: Renewal hook copies new certs and restarts LiveKit
5. **No Downtime**: LiveKit reloads certificates without service interruption
