# PeerWave Certificate Renewal FAQ

## Q: How does certificate renewal work with Traefik?

**A: Traefik auto-renews, you auto-extract.**

```
┌─────────────────────────────────────────────────────┐
│ Traefik Container (Manages HTTPS)                  │
│ ┌─────────────────────────────────────────────────┐ │
│ │ acme.json                                       │ │
│ │ ├── app.peerwave.org                           │ │
│ │ │   ├── Certificate (base64)                   │ │
│ │ │   └── Private Key (base64)                   │ │
│ │ │                                               │ │
│ │ └── Auto-renews every 60 days ✓                │ │
│ └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
                      ↓
          (Cron job extracts daily)
                      ↓
┌─────────────────────────────────────────────────────┐
│ Your Server (PeerWave Directory)                   │
│ ┌─────────────────────────────────────────────────┐ │
│ │ livekit-certs/                                  │ │
│ │ ├── turn-cert.pem  ← Extracted copy            │ │
│ │ └── turn-key.pem   ← Extracted copy            │ │
│ │                                                 │ │
│ │ Updated daily by cron ✓                        │ │
│ └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
                      ↓
         (Mounted as volume)
                      ↓
┌─────────────────────────────────────────────────────┐
│ LiveKit Container (TURN Server)                    │
│ ┌─────────────────────────────────────────────────┐ │
│ │ /certs/turn-cert.pem                           │ │
│ │ /certs/turn-key.pem                            │ │
│ │                                                 │ │
│ │ Reloaded on restart ✓                          │ │
│ └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

---

## Q: Do I need to do anything when certificates renew?

**A: No, if you set up the cron job.**

### With Automation (Recommended):
1. Traefik renews certificate (automatic)
2. Cron job extracts new cert (automatic)
3. LiveKit restarts with new cert (automatic)
4. **You do nothing!** ✓

### Without Automation (Not Recommended):
1. Traefik renews certificate
2. ❌ LiveKit keeps using old certificate
3. ❌ Old certificate expires after 90 days
4. ❌ TURN server stops working
5. ❌ Video calls fail
6. ❌ You manually fix it (too late!)

---

## Q: How often should I run the extraction?

**A: Daily (safe and recommended).**

### Why Daily?

| Frequency | Pros | Cons |
|-----------|------|------|
| **Every hour** | Fastest detection | Unnecessary overhead |
| **Daily** ✅ | Catches renewal within 24h | None |
| **Weekly** | Less frequent runs | 7-day delay after renewal |
| **Monthly** | Minimal runs | Risk missing renewal |

**Recommendation:** Daily at 3 AM (low traffic time)

```bash
# Cron schedule: Daily at 3 AM
0 3 * * * /path/to/extract-traefik-certs.sh
```

---

## Q: What happens if I forget to set up auto-extraction?

**A: TURN server fails after 90 days.**

### Timeline Without Automation:

```
Day 1:   Manual extraction, everything works ✓
Day 60:  Traefik renews certificate
         LiveKit still using old cert (not updated)
Day 90:  Old certificate expires
         ❌ TURN/TLS (port 5349) stops working
         ❌ Users behind strict firewalls can't connect
         ❌ Video calls fail for some users
Day 91:  You realize the problem
         Manual extraction fixes it (but damage done)
```

### Timeline With Automation:

```
Day 1:   Extraction, everything works ✓
Day 60:  Traefik renews certificate
         Cron extracts new cert automatically ✓
         LiveKit restarts with new cert ✓
Day 90+: Still working perfectly ✓
         No downtime, no issues ✓
```

---

## Q: How do I verify auto-renewal is working?

### Check Cron Job is Scheduled:

```bash
# View your cron jobs
crontab -l

# Should see something like:
# 0 3 * * * cd /path/to/PeerWave && sudo ./extract-traefik-certs.sh app.peerwave.org /path/to/acme.json >> /var/log/livekit-cert-update.log 2>&1
```

### Check Logs:

```bash
# View extraction log
sudo tail -20 /var/log/livekit-cert-update.log

# Should see daily entries like:
# Mon Dec 23 03:00:01 2025: Checking certificates for app.peerwave.org...
# Mon Dec 23 03:00:02 2025: ✓ Certificates updated and LiveKit restarted
```

### Manually Test Extraction:

```bash
# Run script manually
sudo ./extract-traefik-certs.sh app.peerwave.org /path/to/acme.json

# Should output:
# PeerWave Certificate Extractor
# ================================
# Domain: app.peerwave.org
# Source: /path/to/acme.json
# Output: ./livekit-certs
#
# Extracting certificate... ✓
# Extracting private key... ✓
# Setting permissions... ✓
# Verifying certificate... ✓
#
# Success! Certificates extracted to ./livekit-certs
```

### Check Certificate Dates:

```bash
# Check expiry date
openssl x509 -in livekit-certs/turn-cert.pem -noout -dates

# Example output:
# notBefore=Dec 23 00:00:00 2025 GMT
# notAfter=Mar 23 00:00:00 2026 GMT  ← Should be ~90 days from generation

# Check if cert is valid
openssl x509 -in livekit-certs/turn-cert.pem -noout -checkend 0 && echo "Valid" || echo "Expired"
```

### Check LiveKit is Using Updated Cert:

```bash
# Check cert inside container
docker exec peerwave-livekit ls -lh /certs/

# Should show:
# -rw-r--r-- 1 root root 1.8K Dec 23 03:00 turn-cert.pem
# -rw------- 1 root root 1.7K Dec 23 03:00 turn-key.pem
```

---

## Q: Can I use systemd timer instead of cron?

**A: Yes!**

### Create systemd service:

```bash
sudo cat > /etc/systemd/system/livekit-cert-update.service << 'EOF'
[Unit]
Description=Extract Traefik certificates for LiveKit
After=docker.service

[Service]
Type=oneshot
ExecStart=/path/to/PeerWave/extract-traefik-certs.sh app.peerwave.org /path/to/acme.json
StandardOutput=journal
StandardError=journal
EOF
```

### Create systemd timer:

```bash
sudo cat > /etc/systemd/system/livekit-cert-update.timer << 'EOF'
[Unit]
Description=Daily LiveKit certificate update

[Timer]
OnCalendar=daily
OnCalendar=03:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
```

### Enable timer:

```bash
# Reload systemd
sudo systemctl daemon-reload

# Enable timer
sudo systemctl enable livekit-cert-update.timer

# Start timer
sudo systemctl start livekit-cert-update.timer

# Check status
sudo systemctl status livekit-cert-update.timer

# View logs
sudo journalctl -u livekit-cert-update.service -f
```

---

## Q: What if Traefik and LiveKit use different certificate paths?

**A: They don't - they use the SAME certificate, different locations.**

```
One Certificate, Two Locations:

Source:
└── Traefik's acme.json
    └── app.peerwave.org certificate

Usage:
├── Traefik: Reads from acme.json (automatic)
│   └── Used for https://app.peerwave.org
│
└── LiveKit: Reads from /certs/ mount (extracted)
    └── Used for turns://app.peerwave.org:5349
```

---

## Q: Do I need to restart anything after extraction?

**A: Yes, LiveKit container (automatic in script).**

The extraction script automatically restarts LiveKit:

```bash
# In extract-traefik-certs.sh:
docker-compose -f docker-compose.traefik.yml restart peerwave-livekit
```

**Why restart?**
- LiveKit loads certificates on startup
- To use new certificate, must reload
- Restart is quick (~2 seconds)
- Minimal disruption to active calls

---

## Q: How do I know when Traefik renewed the certificate?

### Check Traefik logs:

```bash
docker logs traefik 2>&1 | grep -i "renew"
```

### Check certificate issue date:

```bash
# Check when current cert was issued
openssl x509 -in livekit-certs/turn-cert.pem -noout -startdate

# Compare with Traefik's cert
sudo cat /path/to/acme.json | \
  jq -r '.http.Certificates[] | select(.domain.main=="app.peerwave.org") | .certificate' | \
  base64 -d | \
  openssl x509 -noout -startdate
```

### Monitor extraction logs:

```bash
# Watch for changes in log
tail -f /var/log/livekit-cert-update.log

# When Traefik renews, you'll see:
# Mon Jan 22 03:00:01 2026: Checking certificates for app.peerwave.org...
# Mon Jan 22 03:00:02 2026: ✓ Certificates updated and LiveKit restarted
#   ↑ New start date indicates renewal happened
```

---

## Summary Checklist

✅ **Required Setup:**
- [ ] Extract initial certificates from Traefik's acme.json
- [ ] Copy to `livekit-certs/` directory
- [ ] Test LiveKit can read certificates
- [ ] Set up automated extraction (cron or systemd timer)
- [ ] Verify cron job is scheduled
- [ ] Check logs show successful extraction

✅ **Ongoing Monitoring:**
- [ ] Check logs monthly: `tail /var/log/livekit-cert-update.log`
- [ ] Verify certificate expiry: `openssl x509 -in livekit-certs/turn-cert.pem -noout -dates`
- [ ] Test TURN connectivity: https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/

✅ **If Something Goes Wrong:**
- [ ] Check cron is running: `systemctl status cron`
- [ ] Check script permissions: `ls -lh extract-traefik-certs.sh`
- [ ] Run script manually to test: `sudo ./extract-traefik-certs.sh`
- [ ] Check Traefik logs: `docker logs traefik`
- [ ] Check LiveKit logs: `docker logs peerwave-livekit`

**With proper automation, certificate renewal is completely hands-off!**
