/**
 * PeerWave Server Configuration Blueprint
 * 
 * Copy this file to config.js and adjust values for your deployment
 * Or use environment variables to override defaults
 */

module.exports = {
  // Server Configuration
  server: {
    port: process.env.PORT || 3000,
    nodeEnv: process.env.NODE_ENV || 'development',
    host: process.env.HOST || '0.0.0.0',
  },

  // Database Configuration
  database: {
    // SQLite database path (relative or absolute)
    path: process.env.DB_PATH || './data/peerwave.sqlite',
    // Enable WAL mode for better concurrency
    walMode: process.env.DB_WAL_MODE !== 'false',
  },

  // Session Configuration
  session: {
    // Session secret - MUST be changed in production
    secret: process.env.SESSION_SECRET || 'change-this-in-production-to-a-long-random-string',
    // Session cookie name
    name: process.env.SESSION_NAME || 'peerwave.sid',
    // Cookie settings
    cookie: {
      maxAge: parseInt(process.env.SESSION_MAX_AGE || '2592000000'), // 30 days
      httpOnly: true,
      secure: process.env.NODE_ENV === 'production',
      sameSite: process.env.NODE_ENV === 'production' ? 'strict' : 'lax',
    },
  },

  // HMAC Authentication (for native clients)
  hmac: {
    // Session expiry for native clients (in days)
    sessionExpiryDays: parseInt(process.env.HMAC_SESSION_EXPIRY_DAYS || '30'),
    // Nonce cache cleanup interval (in minutes)
    nonceCleanupInterval: parseInt(process.env.HMAC_NONCE_CLEANUP_INTERVAL || '10'),
  },

  // LiveKit Configuration (for video calls)
  livekit: {
    // LiveKit server URL (WebSocket)
    url: process.env.LIVEKIT_URL || 'ws://localhost:7880',
    // LiveKit API credentials
    apiKey: process.env.LIVEKIT_API_KEY || 'devkey',
    apiSecret: process.env.LIVEKIT_API_SECRET || 'secret',
    // TURN server domain (for P2P connections)
    turnDomain: process.env.LIVEKIT_TURN_DOMAIN || 'localhost',
    // Token expiry (in seconds)
    tokenExpiry: parseInt(process.env.LIVEKIT_TOKEN_EXPIRY || '86400'), // 24 hours
  },

  // CORS Configuration
  cors: {
    // Allowed origins (comma-separated in env var)
    origins: process.env.CORS_ORIGINS 
      ? process.env.CORS_ORIGINS.split(',').map(o => o.trim())
      : ['http://localhost:3000', 'http://localhost:8080'],
    credentials: true,
  },

  // File Upload Limits
  upload: {
    // Max file size in bytes (default 100MB)
    maxFileSize: parseInt(process.env.MAX_FILE_SIZE || '104857600'),
    // Max files per upload
    maxFiles: parseInt(process.env.MAX_FILES || '10'),
  },

  // Security Settings
  security: {
    // Enable HTTPS (requires cert files)
    enableHttps: process.env.ENABLE_HTTPS === 'true',
    // Certificate paths (if HTTPS enabled)
    certPath: process.env.CERT_PATH || './cert/server.crt',
    keyPath: process.env.KEY_PATH || './cert/server.key',
    // Rate limiting
    rateLimit: {
      windowMs: parseInt(process.env.RATE_LIMIT_WINDOW_MS || '900000'), // 15 minutes
      max: parseInt(process.env.RATE_LIMIT_MAX || '100'), // limit each IP to 100 requests per windowMs
    },
  },

  // Logging Configuration
  logging: {
    // Log level: error, warn, info, debug
    level: process.env.LOG_LEVEL || 'info',
    // Enable request logging
    enableRequestLog: process.env.ENABLE_REQUEST_LOG !== 'false',
  },

  // Cleanup Jobs
  cleanup: {
    // Auto-cleanup old sessions (in days)
    sessionCleanupDays: parseInt(process.env.SESSION_CLEANUP_DAYS || '30'),
    // Auto-cleanup old messages (in days, 0 = disabled)
    messageCleanupDays: parseInt(process.env.MESSAGE_CLEANUP_DAYS || '0'),
  },
};
