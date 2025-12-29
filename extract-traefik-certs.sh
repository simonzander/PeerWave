#!/bin/bash
# Extract certificates from Traefik's acme.json for LiveKit TURN server
# Usage: ./extract-traefik-certs.sh [domain] [acme.json path]

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
DOMAIN="${1:-app.peerwave.org}"
ACME_JSON="${2:-/etc/traefik/acme.json}"
OUTPUT_DIR="./livekit-certs"

echo -e "${YELLOW}PeerWave Certificate Extractor${NC}"
echo "================================"
echo ""
echo "Domain: $DOMAIN"
echo "Source: $ACME_JSON"
echo "Output: $OUTPUT_DIR"
echo ""

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}✗ Error: jq is not installed${NC}"
    echo "Install with: sudo apt install jq"
    exit 1
fi

# Check if acme.json exists
if [ ! -f "$ACME_JSON" ]; then
    echo -e "${RED}✗ Error: acme.json not found at $ACME_JSON${NC}"
    echo ""
    echo "Common locations:"
    echo "  - /etc/traefik/acme.json"
    echo "  - ./traefik/acme.json"
    echo "  - /var/lib/traefik/acme.json"
    echo ""
    echo "Find it with: sudo find / -name 'acme.json' 2>/dev/null"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Extract certificate
echo -n "Extracting certificate... "
CERT=$(cat "$ACME_JSON" | jq -r ".http.Certificates[] | select(.domain.main==\"$DOMAIN\") | .certificate")

if [ -z "$CERT" ] || [ "$CERT" == "null" ]; then
    echo -e "${RED}✗ Failed${NC}"
    echo ""
    echo -e "${RED}Certificate for '$DOMAIN' not found in acme.json${NC}"
    echo ""
    echo "Available domains:"
    cat "$ACME_JSON" | jq -r '.http.Certificates[].domain.main' | sed 's/^/  - /'
    exit 1
fi

echo "$CERT" | base64 -d > "$OUTPUT_DIR/turn-cert.pem"
echo -e "${GREEN}✓${NC}"

# Extract private key
echo -n "Extracting private key... "
KEY=$(cat "$ACME_JSON" | jq -r ".http.Certificates[] | select(.domain.main==\"$DOMAIN\") | .key")
echo "$KEY" | base64 -d > "$OUTPUT_DIR/turn-key.pem"
echo -e "${GREEN}✓${NC}"

# Set permissions
echo -n "Setting permissions... "
chmod 644 "$OUTPUT_DIR/turn-cert.pem"
chmod 600 "$OUTPUT_DIR/turn-key.pem"
echo -e "${GREEN}✓${NC}"

# Verify certificates
echo -n "Verifying certificate... "
CERT_EXPIRES=$(openssl x509 -in "$OUTPUT_DIR/turn-cert.pem" -noout -enddate | cut -d= -f2)
echo -e "${GREEN}✓${NC}"

echo ""
echo -e "${GREEN}Success!${NC} Certificates extracted to $OUTPUT_DIR"
echo ""
echo "Certificate details:"
echo "  - Expires: $CERT_EXPIRES"
echo "  - Domain: $DOMAIN"
echo ""
echo "Files created:"
echo "  - $OUTPUT_DIR/turn-cert.pem (644)"
echo "  - $OUTPUT_DIR/turn-key.pem (600)"
echo ""
echo "Next steps:"
echo "  1. Update livekit-config.yaml with your domain"
echo "  2. Restart LiveKit: docker-compose restart peerwave-livekit"
echo ""
echo "To automate renewal, add to crontab:"
echo "  0 3 * * * $PWD/$0 $DOMAIN $ACME_JSON >> /var/log/livekit-cert-update.log 2>&1"
