FROM node:lts-alpine

# Install dependencies for native modules (bcrypt, etc.)
RUN apk add --no-cache python3 make g++

WORKDIR /usr/src/app

# Copy package files first (better caching)
COPY package*.json ./

# Install dependencies
RUN npm ci --omit=dev && \
    npm cache clean --force

# Copy application code (includes pre-built web/ folder)
COPY . .

# Create directories for persistent data
RUN mkdir -p /usr/src/app/db /usr/src/app/cert /usr/src/app/coturn/data

# Health check (Port 3000)
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000/health', (r) => {process.exit(r.statusCode === 200 ? 0 : 1)})"

# Run as non-root user
USER node

EXPOSE 3000

CMD [ "node", "server.js" ]