#!/bin/bash

# ============================================================
# PeerWave COTURN Setup Script
# Initialisiert COTURN Server für STUN/TURN
# ============================================================

set -e

echo "🚀 PeerWave COTURN Setup"
echo "========================"

# Farben für Output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# ============================================================
# 1. Check Prerequisites
# ============================================================

echo -e "\n${YELLOW}[1/5] Checking prerequisites...${NC}"

if ! command -v docker &> /dev/null; then
    echo -e "${RED}❌ Docker nicht installiert!${NC}"
    exit 1
fi

if ! command -v docker-compose &> /dev/null; then
    echo -e "${RED}❌ Docker Compose nicht installiert!${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Docker und Docker Compose verfügbar${NC}"

# ============================================================
# 2. Generate Shared Secret
# ============================================================

echo -e "\n${YELLOW}[2/5] Generating shared secret...${NC}"

SHARED_SECRET=$(openssl rand -hex 32)
echo -e "${GREEN}✅ Shared Secret generiert${NC}"
echo -e "   Secret: ${SHARED_SECRET}"

# ============================================================
# 3. Update Configuration
# ============================================================

echo -e "\n${YELLOW}[3/5] Updating configuration...${NC}"

# Ersetze Platzhalter in turnserver.conf
sed -i "s/DEIN_GEHEIMER_SHARED_SECRET_HIER_ÄNDERN/${SHARED_SECRET}/g" coturn/turnserver.conf

echo -e "${GREEN}✅ Configuration aktualisiert${NC}"

# ============================================================
# 4. Detect External IP
# ============================================================

echo -e "\n${YELLOW}[4/5] Detecting external IP...${NC}"

EXTERNAL_IP=$(curl -s ifconfig.me)

if [ -z "$EXTERNAL_IP" ]; then
    echo -e "${YELLOW}⚠️  Konnte externe IP nicht automatisch erkennen${NC}"
    read -p "Bitte externe IP eingeben: " EXTERNAL_IP
fi

echo -e "${GREEN}✅ Externe IP: ${EXTERNAL_IP}${NC}"

# Füge external-ip zur Config hinzu
echo "external-ip=${EXTERNAL_IP}" >> coturn/turnserver.conf

# ============================================================
# 5. Create Credentials Helper
# ============================================================

echo -e "\n${YELLOW}[5/5] Creating credential helper...${NC}"

cat > coturn/generate-credentials.sh << 'EOF'
#!/bin/bash
# Generiert temporäre TURN Credentials mit HMAC

SHARED_SECRET="SHARED_SECRET_PLACEHOLDER"
USERNAME="peerwave-$(date +%s)"
TIMESTAMP=$(($(date +%s) + 86400))  # 24 Stunden gültig

# HMAC berechnen
PASSWORD=$(echo -n "${TIMESTAMP}:${USERNAME}" | openssl dgst -sha1 -hmac "${SHARED_SECRET}" -binary | base64)

echo "Username: ${USERNAME}"
echo "Password: ${PASSWORD}"
echo "TTL: 24 hours"
echo ""
echo "WebRTC Config:"
echo "{"
echo "  username: '${USERNAME}',"
echo "  credential: '${PASSWORD}'"
echo "}"
EOF

# Ersetze Shared Secret im Helper
sed -i "s/SHARED_SECRET_PLACEHOLDER/${SHARED_SECRET}/g" coturn/generate-credentials.sh
chmod +x coturn/generate-credentials.sh

echo -e "${GREEN}✅ Credential Helper erstellt${NC}"

# ============================================================
# Summary
# ============================================================

echo -e "\n${GREEN}================================================${NC}"
echo -e "${GREEN}🎉 COTURN Setup abgeschlossen!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo "📝 Nächste Schritte:"
echo ""
echo "1. COTURN starten:"
echo "   docker-compose -f docker-compose.coturn.yml up -d"
echo ""
echo "2. Logs ansehen:"
echo "   docker-compose -f docker-compose.coturn.yml logs -f coturn"
echo ""
echo "3. Credentials generieren:"
echo "   ./coturn/generate-credentials.sh"
echo ""
echo "4. Teste STUN/TURN:"
echo "   https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/"
echo ""
echo "📌 Server Details:"
echo "   External IP: ${EXTERNAL_IP}"
echo "   STUN: stun:${EXTERNAL_IP}:3478"
echo "   TURN: turn:${EXTERNAL_IP}:3478"
echo "   Shared Secret: ${SHARED_SECRET}"
echo ""
echo "⚠️  WICHTIG: Firewall Ports öffnen!"
echo "   sudo ufw allow 3478/udp"
echo "   sudo ufw allow 3478/tcp"
echo "   sudo ufw allow 49152:65535/udp"
echo ""
