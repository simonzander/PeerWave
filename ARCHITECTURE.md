# PeerWave Traffic Flow & Certificate Usage

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                   │
│  Domain: app.peerwave.org                                        │
│  Certificate: /etc/letsencrypt/live/app.peerwave.org/           │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘

                              ▼
                              
        ┌─────────────────────┴─────────────────────┐
        │                                           │
        │  Same Certificate, Different Routing     │
        │                                           │
        └─────────────────────┬─────────────────────┘
                              │
                ┌─────────────┴─────────────┐
                │                           │
                ▼                           ▼
                
    ┌───────────────────┐         ┌───────────────────┐
    │  HTTP/HTTPS       │         │  WebRTC/TURN      │
    │  Port 443 TCP     │         │  Multiple Ports   │
    └───────────────────┘         └───────────────────┘
                │                           │
                ▼                           ▼
                
    ┌───────────────────┐         ┌───────────────────┐
    │ Traefik Proxy     │         │ Direct Exposure   │
    │ (Auto-manages)    │         │ (Manual copy)     │
    └───────────────────┘         └───────────────────┘
                │                           │
                ▼                           ▼
                
    ┌───────────────────┐         ┌───────────────────┐
    │ PeerWave Server   │         │ LiveKit Container │
    │ Container         │         │                   │
    │ (port 3000)       │         │ 7880 WebSocket    │
    │                   │         │ 5349 TURN/TLS     │
    │                   │         │ 443  TURN/UDP     │
    │                   │         │ 30100-30400 RTP   │
    └───────────────────┘         └───────────────────┘
```

## Traffic Flow Details

### 1. Web Application (HTTP/HTTPS)

```
User Browser
    ↓
https://app.peerwave.org
    ↓
[Traefik Reverse Proxy]
    │
    ├─ Terminates SSL/TLS
    ├─ Uses Let's Encrypt certificate (automatic)
    └─ Forwards to PeerWave Server (HTTP internally)
    ↓
PeerWave Server Container (port 3000)
```

**Certificate:** Managed by Traefik automatically

### 2. WebRTC Signaling (WebSocket)

```
User Browser/App
    ↓
wss://app.peerwave.org:7880
    ↓
[No Proxy - Direct Connection]
    ↓
LiveKit Container (port 7880)
```

**Certificate:** Same Let's Encrypt cert, copied to livekit-certs/

### 3. TURN Server (NAT Traversal)

```
User Browser/App
    ↓
turns://app.peerwave.org:5349
    ↓
[No Proxy - Direct Connection]
    ↓
LiveKit TURN Server (port 5349)
```

**Certificate:** Same Let's Encrypt cert, copied to livekit-certs/

### 4. Media Streams (RTP/UDP)

```
User Browser/App
    ↓
UDP connections to app.peerwave.org:30100-30400
    ↓
[No Proxy - Direct UDP]
    ↓
LiveKit Media Server (ports 30100-30400)
```

**No certificate needed** (UDP media is encrypted with SRTP/DTLS)

## Certificate File Locations

### On Host Server

```
/etc/letsencrypt/live/app.peerwave.org/
├── fullchain.pem  ─────┬──→ Used by Traefik (automatic)
└── privkey.pem  ───────┤
                        │
                        └──→ Copied to:
                              ./livekit-certs/turn-cert.pem
                              ./livekit-certs/turn-key.pem
                              (used by LiveKit, manual)
```

### In Containers

**Traefik Container:**
```
/etc/traefik/acme.json
└── Contains Let's Encrypt certificates (managed automatically)
```

**LiveKit Container:**
```
/certs/turn-cert.pem  ← Mounted from host ./livekit-certs/turn-cert.pem
/certs/turn-key.pem   ← Mounted from host ./livekit-certs/turn-key.pem
```

## Why This Architecture?

### HTTP/HTTPS Goes Through Traefik

✅ **Advantages:**
- Clean URLs (no port numbers)
- Automatic SSL certificate management
- Easy to add more services
- Centralized SSL/TLS termination
- Better security (hide internal ports)

❌ **Why not for WebRTC?**
- WebRTC needs direct UDP access (Traefik is TCP-only)
- TURN protocol requires direct server access
- Media streams need low latency (no proxy overhead)

### WebRTC Goes Direct to LiveKit

✅ **Advantages:**
- Low latency (no proxy overhead)
- UDP support (required for media)
- Direct peer-to-peer negotiation
- Better media quality

❌ **Disadvantages:**
- Ports must be exposed (7880, 5349, 30100-30400)
- Manual certificate copying required
- Firewall rules needed

## Common Questions

### Q: Can I use different domains?

**A: Yes, but not recommended.**

You could use:
- `app.peerwave.org` for HTTP/HTTPS
- `turn.peerwave.org` for TURN server

But this requires:
- Two DNS records
- Two certificates to manage
- More complex configuration

**Recommendation:** Use one domain for everything (simpler).

### Q: Why can't Traefik handle WebRTC?

**A: Traefik is an HTTP reverse proxy.**

- Works great for HTTP/HTTPS (Layer 7)
- Doesn't support raw UDP (required for media)
- Doesn't support TURN protocol
- Adds latency for real-time media

### Q: Do I need to open port 7880 publicly?

**A: Yes, for WebRTC to work.**

WebRTC clients need to connect to LiveKit's WebSocket (port 7880) for:
- Room joining
- Track publishing/subscribing
- Signaling

**Security:** 
- Port 7880 is authenticated (JWT tokens)
- TLS encryption available (wss://)
- Only authorized users can join rooms

### Q: Can I use one certificate for multiple subdomains?

**A: Yes, with wildcard certificate.**

Generate certificate:
```bash
sudo certbot certonly --standalone -d "*.peerwave.org" -d "peerwave.org"
```

Then use for:
- `app.peerwave.org` (main app)
- `turn.peerwave.org` (TURN server)
- `api.peerwave.org` (API)

## Quick Setup Summary

### Single Domain Setup (Recommended)

```bash
# 1. Generate Let's Encrypt certificate
sudo certbot certonly --standalone -d app.peerwave.org

# 2. Copy for LiveKit
mkdir -p livekit-certs
sudo cp /etc/letsencrypt/live/app.peerwave.org/fullchain.pem ./livekit-certs/turn-cert.pem
sudo cp /etc/letsencrypt/live/app.peerwave.org/privkey.pem ./livekit-certs/turn-key.pem
sudo chown $(id -u):$(id -g) livekit-certs/*.pem

# 3. Configure environment
cat > .env << EOF
DOMAIN=app.peerwave.org
LIVEKIT_TURN_DOMAIN=app.peerwave.org
# ... other variables
EOF

# 4. Deploy
docker-compose -f docker-compose.traefik.yml up -d
```

**Result:**
- ✅ `https://app.peerwave.org` → Web interface (via Traefik)
- ✅ `wss://app.peerwave.org:7880` → WebRTC signaling (direct)
- ✅ `turns://app.peerwave.org:5349` → TURN server (direct)

All using the **same certificate** from the **same domain**.
