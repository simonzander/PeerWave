# TURN/STUN Integration Testing Guide

## 🎯 Ziel
Sicherstellen, dass der Flutter Client die TURN/STUN Server vom Node.js Server bezieht und für WebRTC DataChannel Verbindungen nutzt.

---

## ✅ Pre-Flight Checklist

### 1. Environment Variables gesetzt
```bash
# In .env Datei prüfen:
TURN_SECRET=<secure-base64-secret>
TURN_SERVER_EXTERNAL_HOST=localhost
TURN_SERVER_INTERNAL_HOST=peerwave-coturn
TURN_SERVER_PORT=3478
TURN_SERVER_PORT_TLS=5349
TURN_REALM=peerwave.local
TURN_CREDENTIAL_TTL=86400
PORT=3000
```

### 2. coturn Config mit Secret
```bash
# In server/coturn/turnserver.conf:
static-auth-secret=<same-as-TURN_SECRET>
```

---

## 🧪 Test 1: Docker Container starten

```powershell
# Container stoppen und neu starten
docker-compose down
docker-compose up -d

# Container Status prüfen
docker-compose ps
# Expected: peerwave-server und peerwave-coturn Running
```

**Expected Output:**
```
NAME                  STATUS    PORTS
peerwave-coturn       Up        0.0.0.0:3478->3478/tcp, 3478/udp, ...
peerwave-server       Up        0.0.0.0:3000->3000/tcp
```

---

## 🧪 Test 2: coturn Server erreichbar

```powershell
# STUN Test (von außerhalb Docker)
# Mit Online Tool: https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/

# Oder mit netcat (wenn verfügbar):
nc -u localhost 3478
```

**Expected:** Port ist offen und antwortet

---

## 🧪 Test 3: Node.js Server ICE Config Endpoint

```powershell
# /client/meta Endpoint testen
curl http://localhost:3000/client/meta | ConvertFrom-Json | ConvertTo-Json -Depth 10
```

**Expected Response:**
```json
{
  "name": "PeerWave",
  "version": "1.0.0",
  "iceServers": [
    {
      "urls": ["stun:localhost:3478"]
    },
    {
      "urls": [
        "turn:localhost:3478?transport=udp",
        "turn:localhost:3478?transport=tcp"
      ],
      "username": "1730419200:guest_123456",
      "credential": "base64-hmac-hash"
    },
    {
      "urls": ["turns:localhost:5349?transport=tcp"],
      "username": "1730419200:guest_123456",
      "credential": "base64-hmac-hash"
    },
    {
      "urls": ["stun:stun.l.google.com:19302"]
    }
  ]
}
```

**Prüfpunkte:**
- ✅ `iceServers` Array vorhanden
- ✅ Mindestens 2 Server (STUN + TURN)
- ✅ `username` im Format `timestamp:userid`
- ✅ `credential` ist base64 encoded

---

## 🧪 Test 4: TURN Credentials validieren

```powershell
# Server Logs prüfen
docker logs peerwave-server | Select-String "TURN"
```

**Expected Output:**
```
[TURN] Generated ICE servers for user guest_123456:
  stun: stun:localhost:3478
  turn: turn:localhost:3478
  expiresAt: 2025-11-01T09:32:45.000Z
```

---

## 🧪 Test 5: Flutter Client lädt ICE Config

```powershell
# Flutter App starten (Web)
cd client
flutter run -d chrome

# Oder Docker-Version testen:
# Nach docker-compose up -d
# Browser öffnen: http://localhost:3000
```

**Im Browser Console prüfen:**
```javascript
// Expected Log-Ausgaben:
[INIT] Loading ICE server configuration...
[INIT] ✅ ICE server configuration loaded
[ICE CONFIG] Loading ICE server config from http://localhost:3000...
[ICE CONFIG] ✅ Config loaded successfully
[ICE CONFIG] Server: PeerWave v1.0.0
[ICE CONFIG] ICE Servers: 4
[ICE CONFIG]   [0] stun:localhost:3478
[ICE CONFIG]   [1] turn:localhost:3478?transport=udp, turn:localhost:3478?transport=tcp
[ICE CONFIG]       Username: 1730419200:user123
[ICE CONFIG]   [2] turns:localhost:5349?transport=tcp
[ICE CONFIG]       Username: 1730419200:user123
[ICE CONFIG]   [3] stun:stun.l.google.com:19302
[P2P] Using ICE servers: 4 servers
[P2P] WebRTCFileService created with dynamic ICE servers
```

---

## 🧪 Test 6: WebRTC Connection nutzt TURN

### Vorbereitung:
1. Zwei Browser-Tabs öffnen (oder 2 Browser)
2. In beiden einloggen (verschiedene Accounts)
3. File Transfer starten

### Im Browser DevTools (Chrome):
```javascript
// Console öffnen (F12)
// Nach WebRTC ICE Candidates suchen:

// Expected Output:
candidate:... typ relay raddr ... rport ... (TURN wird genutzt!)
candidate:... typ srflx raddr ... (STUN wird genutzt)
candidate:... typ host (Lokale Candidates)
```

**Prüfpunkte:**
- ✅ `typ relay` vorhanden → TURN funktioniert!
- ✅ `typ srflx` vorhanden → STUN funktioniert!
- ✅ Connection established

### Oder mit chrome://webrtc-internals:
1. `chrome://webrtc-internals` öffnen
2. Active Connection suchen
3. "ICE candidate pair" prüfen
4. Sollte `relay` als Typ zeigen wenn TURN genutzt wird

---

## 🧪 Test 7: Trickle ICE Test (Online Tool)

1. Öffne: https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/
2. Trage ein:
   ```
   STUN/TURN URI: turn:localhost:3478
   Username: <von /client/meta Response>
   Credential: <von /client/meta Response>
   ```
3. Klicke "Add Server"
4. Klicke "Gather candidates"

**Expected Result:**
- ✅ `srflx` candidates (STUN funktioniert)
- ✅ `relay` candidates (TURN funktioniert)
- ⚠️ Falls keine relay: TURN Auth fehlt oder Port blockiert

---

## 🧪 Test 8: Credential Expiry Test

```powershell
# Credential TTL ist 24h (86400s)
# Nach Ablauf sollte Client neue Credentials bekommen

# Simuliere Ablauf (TTL auf 10 Sekunden setzen):
# In .env: TURN_CREDENTIAL_TTL=10
# Container neu starten: docker-compose restart peerwave-server

# Nach 11 Sekunden erneut /client/meta aufrufen:
curl http://localhost:3000/client/meta

# Username sollte neuen Timestamp haben
```

---

## 🐛 Troubleshooting

### Problem: Keine ICE Servers in /client/meta Response

**Diagnose:**
```powershell
# Server Logs prüfen
docker logs peerwave-server | Select-String "CLIENT META|TURN"
```

**Mögliche Ursachen:**
1. TURN_SECRET nicht gesetzt in .env
2. Environment Variables nicht geladen in Docker
3. turnCredentials.js hat Fehler

**Lösung:**
```powershell
# .env prüfen
Get-Content .env | Select-String "TURN"

# Container neu bauen
docker-compose down
docker-compose build --no-cache
docker-compose up -d
```

---

### Problem: TURN Server nicht erreichbar

**Diagnose:**
```powershell
# coturn Logs prüfen
docker logs peerwave-coturn

# Port testen
Test-NetConnection localhost -Port 3478
```

**Mögliche Ursachen:**
1. Port 3478 bereits belegt
2. Firewall blockiert Port
3. coturn Container nicht gestartet

**Lösung:**
```powershell
# Ports prüfen
netstat -an | Select-String "3478"

# Container Status
docker-compose ps

# coturn neu starten
docker-compose restart peerwave-coturn
```

---

### Problem: TURN Auth fehlschlägt

**Diagnose:**
```powershell
# Secret vergleichen
Get-Content .env | Select-String "TURN_SECRET"
Get-Content server/coturn/turnserver.conf | Select-String "static-auth-secret"
```

**Mögliche Ursachen:**
1. Secrets stimmen nicht überein
2. Secret enthält Sonderzeichen die escaped werden müssen

**Lösung:**
```powershell
# Secrets müssen IDENTISCH sein!
# In .env UND turnserver.conf

# Container neu bauen nach Änderung
docker-compose down
docker-compose build --no-cache peerwave-coturn
docker-compose up -d
```

---

### Problem: Flutter Client lädt Config nicht

**Diagnose:**
```powershell
# Browser Console (F12) prüfen
# Suche nach: [ICE CONFIG] oder [INIT]
```

**Mögliche Ursachen:**
1. Server URL falsch in web/server_config.json
2. CORS Problem
3. Network Error

**Lösung:**
```powershell
# server_config.json prüfen
Get-Content client/build/web/server_config.json

# Sollte sein:
# {"apiServer": "http://localhost:3000"}

# CORS prüfen in Browser Network Tab
```

---

## 📊 Success Indicators

### ✅ Alles funktioniert wenn:

1. **Server:**
   - `/client/meta` liefert 4 ICE Servers
   - Logs zeigen: `[TURN] Generated ICE servers for user...`
   - coturn läuft ohne Errors

2. **Client:**
   - Browser Console: `[ICE CONFIG] ✅ Config loaded successfully`
   - Browser Console: `[P2P] Using ICE servers: 4 servers`
   - Browser Console: `[P2P] WebRTCFileService created with dynamic ICE servers`

3. **WebRTC:**
   - chrome://webrtc-internals zeigt `relay` candidates
   - Trickle ICE Test zeigt `relay` und `srflx`
   - File Transfer funktioniert zwischen Clients

---

## 🎉 Final Validation

```powershell
# Complete Test Run
cd d:\PeerWave

# 1. Build & Start
.\build-and-start.ps1

# 2. Check Containers
docker-compose ps
# Expected: All Running

# 3. Test Endpoint
curl http://localhost:3000/client/meta | ConvertFrom-Json

# 4. Check Logs
docker logs peerwave-server | Select-String "TURN" | Select-Object -Last 5
docker logs peerwave-coturn | Select-Object -Last 10

# 5. Open Browser
start http://localhost:3000

# 6. Check Browser Console
# Should see: [ICE CONFIG] ✅ Config loaded successfully
```

**Wenn alle Tests ✅ sind → Integration erfolgreich! 🎉**

---

## 📝 Production Checklist

Vor Production Deployment:

- [ ] TURN_SECRET mit starkem Wert (min. 32 bytes random)
- [ ] TURN_SERVER_EXTERNAL_HOST auf echte Domain/IP setzen
- [ ] TLS Zertifikate für TURNS (Port 5349)
- [ ] Firewall Regeln für Ports 3478, 5349, 49152-65535 UDP
- [ ] docker-compose.prod.yml verwenden
- [ ] Monitoring für coturn einrichten
- [ ] Logs in Production-Tool (ELK, Datadog, etc.)
- [ ] Load Balancing wenn > 100 concurrent users

---

**Dokumentation erstellt:** 31. Oktober 2025  
**Version:** 1.0  
**Status:** Ready for Testing 🚀
