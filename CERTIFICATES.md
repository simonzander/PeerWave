# LiveKit Certificate Setup for Production

LiveKit's embedded TURN server requires TLS certificates for the TURN/TLS port (5349). These certificates are **separate** from your Traefik/Let's Encrypt certificates used for HTTPS.

## Why Separate Certificates?

- **Traefik certificates**: Used for HTTPS (port 443) - managed by Traefik
- **LiveKit certificates**: Used for TURN/TLS (port 5349) - managed by LiveKit container

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

```bash
# Create livekit-certs directory
mkdir -p livekit-certs

# Copy certificates (adjust paths based on your domain)
sudo cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem ./livekit-certs/turn-cert.pem
sudo cp /etc/letsencrypt/live/$DOMAIN/privkey.pem ./livekit-certs/turn-key.pem

# Set proper permissions
sudo chmod 644 ./livekit-certs/turn-cert.pem
sudo chmod 600 ./livekit-certs/turn-key.pem
sudo chown $(id -u):$(id -g) ./livekit-certs/*.pem
```

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
