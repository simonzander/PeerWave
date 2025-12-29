# ============================================
# Stage 1: Builder - Install dependencies
# ============================================
FROM node:22-slim AS builder

# Install build dependencies for native modules
# mediasoup: python3, python3-pip, make, g++
# bcrypt: make, g++, python3
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    make \
    g++ \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app

# Copy ONLY package files first (better layer caching)
COPY package*.json ./

# Install dependencies
# mediasoup will try prebuilt binary first (fast), compile if needed (slow but works)
RUN npm ci --only=production && \
    npm cache clean --force

# ============================================
# Stage 2: Production - Minimal runtime image
# ============================================
FROM node:22-slim

# Install ONLY runtime dependencies (no build tools)
RUN apt-get update && apt-get install -y \
    python3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app

# Copy package files
COPY package*.json ./

# Copy compiled node_modules from builder stage
COPY --from=builder /usr/src/app/node_modules ./node_modules

# Copy application code (includes pre-built web/ folder)
COPY . .

# Copy license validator binary and set permissions
RUN if [ -f bin/license-validator-linux ]; then \
      chmod +x bin/license-validator-linux && \
      echo "License validator binary configured"; \
    else \
      echo "Warning: License validator binary not found - will use non-commercial mode"; \
    fi

# Create directories for persistent data
# /data - for SQLite database (mounted volume)
# /cert - for SSL certificates (mounted volume)
# /coturn/data - for TURN server data (legacy, kept for compatibility)
RUN mkdir -p /usr/src/app/data /usr/src/app/cert /usr/src/app/coturn/data

# Create entrypoint script to fix volume permissions
RUN echo '#!/bin/sh' > /docker-entrypoint.sh && \
    echo 'set -e' >> /docker-entrypoint.sh && \
    echo '# Fix ownership of mounted volumes' >> /docker-entrypoint.sh && \
    echo 'chown -R node:node /usr/src/app/data /usr/src/app/cert /usr/src/app/coturn/data 2>/dev/null || true' >> /docker-entrypoint.sh && \
    echo '# Switch to node user and run command' >> /docker-entrypoint.sh && \
    echo 'exec gosu node "$@"' >> /docker-entrypoint.sh && \
    chmod +x /docker-entrypoint.sh

# Install gosu for switching users (Debian)
RUN apt-get update && apt-get install -y gosu && rm -rf /var/lib/apt/lists/*

# Health check (Port 3000)
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000/health', (r) => {process.exit(r.statusCode === 200 ? 0 : 1)})"

# Entrypoint fixes permissions, then runs as node user
ENTRYPOINT ["/docker-entrypoint.sh"]

# Expose ports
# 3000: HTTP/WebSocket (Signaling)
EXPOSE 3000

CMD [ "node", "server.js" ]