const config = {};
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const logger = require('../utils/logger');

// Auto-generate and persist secrets if not in environment
function getOrGenerateSecret(envVar, secretName, byteLength = 32) {
    if (process.env[envVar]) {
        return process.env[envVar];
    }
    
    // Try to load from .secrets file
    const secretsPath = path.join(__dirname, '..', '.secrets');
    let secrets = {};
    
    // Attempt to read file directly without checking existence first (prevents TOCTOU race condition)
    try {
        secrets = JSON.parse(fs.readFileSync(secretsPath, 'utf8'));
        if (secrets[secretName]) {
            logger.info(`✓ Loaded ${secretName} from .secrets file`);
            return secrets[secretName];
        }
    } catch (err) {
        // File doesn't exist or can't be read - will generate new secret
        if (err.code !== 'ENOENT') {
            logger.warn(`⚠️  Could not read .secrets file: ${err.message}`);
        }
    }
    
    // Generate new secret
    const newSecret = crypto.randomBytes(byteLength).toString('hex');
    secrets[secretName] = newSecret;
    
    // Save to .secrets file
    try {
        fs.writeFileSync(secretsPath, JSON.stringify(secrets, null, 2), 'utf8');
        logger.info(`✓ Generated new ${secretName} and saved to .secrets file`);
        logger.info(`  ${secretName}: ${newSecret}`);
        logger.info(`  ⚠️  IMPORTANT: Add .secrets to .gitignore and back it up securely!`);
    } catch (err) {
        // Docker environments may not have write permissions - this is OK if secret is in .env
        if (err.code === 'EACCES') {
            logger.warn(`⚠️  Cannot write .secrets file (Docker/permissions): ${secretsPath}`);
            logger.warn(`  ${secretName}: ${newSecret}`);
            logger.warn(`  💡 Add this to your .env file to persist across restarts`);
        } else {
            logger.error(`⚠️  Could not save .secrets file: ${err.message}`);
            logger.error(`  ${secretName}: ${newSecret}`);
            logger.error(`  ⚠️  Save this secret to your .env file or you'll lose sessions on restart!`);
        }
    }
    
    return newSecret;
}

config.domain = process.env.DOMAIN || 'localhost';
config.port = process.env.PORT || 3000;
config.https = process.env.HTTPS === 'true';
config.db = {
    type: 'sqlite',
    path: process.env.DB_PATH || './data/peerwave.sqlite'
};
config.app = {
    name: 'PeerWave',
    url: process.env.APP_URL || `${config.https ? 'https' : 'http'}://${config.domain}${config.port !== 3000 && config.port !== 443 ? ':' + config.port : ''}`,
    description: 'PeerWave'
};

// CORS Configuration
// SECURITY: Always use explicit origin whitelist, never '*' with credentials
// If CORS_ORIGINS is not set:
//   - Production: Use app URL only
//   - Development: Use safe localhost defaults based on configured ports
const protocol = config.https ? 'https' : 'http';
const viteDevPort = parseInt(process.env.VITE_DEV_PORT || '5173');
const developmentOrigins = [
    `${protocol}://localhost:${config.port}`,
    `${protocol}://127.0.0.1:${config.port}`,
    `http://localhost:${viteDevPort}`, // Vite dev server (typically HTTP even if main app is HTTPS)
    `http://127.0.0.1:${viteDevPort}`
];

config.cors = {
    origin: process.env.CORS_ORIGINS 
        ? process.env.CORS_ORIGINS.split(',').map(o => o.trim()).filter(o => o && o !== '*')
        : (process.env.NODE_ENV === 'production' ? [config.app.url] : developmentOrigins),
    credentials: true
};

// Validation: Warn if production uses localhost
if (process.env.NODE_ENV === 'production' && !process.env.CORS_ORIGINS) {
    const hasLocalhost = config.cors.origin.some(url => 
        url.includes('localhost') || url.includes('127.0.0.1')
    );
    if (hasLocalhost) {
        logger.warn('⚠️  WARNING: Production mode detected with localhost CORS origin!');
        logger.warn('   Please set CORS_ORIGINS or APP_URL environment variable for production.');
        logger.warn('   Example: CORS_ORIGINS=https://yourdomain.com,https://www.yourdomain.com');
    }
}

// SMTP Configuration - Optional (for meeting invitations)
config.smtp = process.env.EMAIL_HOST ? {
    senderadress: process.env.EMAIL_FROM || `"PeerWave" <no-reply@${config.domain}>`,
    host: process.env.EMAIL_HOST,
    port: parseInt(process.env.EMAIL_PORT || '587'),
    secure: process.env.EMAIL_SECURE === 'true',
    auth: {
        user: process.env.EMAIL_USER,
        pass: process.env.EMAIL_PASS
    }
} : null;

// Session Configuration (Slack/Teams Model - 90 days mobile, 14 days web)
config.session = {
    secret: getOrGenerateSecret('SESSION_SECRET', 'SESSION_SECRET', 32),
    resave: false,
    saveUninitialized: true,
    cookie: { 
        secure: process.env.NODE_ENV === 'production' && config.https,
        maxAge: parseInt(process.env.WEB_SESSION_DAYS || '14') * 24 * 60 * 60 * 1000 // 14 days default
    },
    // HMAC session expiration for native clients (mobile/desktop)
    hmacSessionDays: parseInt(process.env.HMAC_SESSION_DAYS || '90'), // 90 days default
    // Token refresh threshold (refresh if less than X days remaining)
    refreshThresholdDays: parseInt(process.env.SESSION_REFRESH_DAYS || '7'), // Auto-refresh when < 7 days
    // Session cleanup interval (hours)
    cleanupIntervalHours: parseInt(process.env.SESSION_CLEANUP_HOURS || '1') // Cleanup every hour
};

// JWT Configuration (for Chrome Custom Tab callbacks)
config.jwt = {
    secret: getOrGenerateSecret('JWT_SECRET', 'JWT_SECRET', 64),
    expiresIn: '60s' // 60 seconds for auth callbacks
};

// Log session configuration on startup
logger.info('🔐 Session Configuration:');
logger.info(`   Web Session: ${Math.floor(config.session.cookie.maxAge / (24 * 60 * 60 * 1000))} days`);
logger.info(`   HMAC Session: ${config.session.hmacSessionDays} days`);
logger.info(`   Auto-refresh threshold: ${config.session.refreshThresholdDays} days`);
logger.info(`   Cleanup interval: ${config.session.cleanupIntervalHours} hour(s)`);

// Admin users: Comma-separated list of email addresses that will receive Administrator role
// Users with these emails will automatically get admin privileges when verified
config.admin = process.env.ADMIN_EMAILS ? process.env.ADMIN_EMAILS.split(',').map(email => email.trim()) : [];

// Cleanup configuration
config.cleanup = {
    // Inactive users: Mark users as inactive after X days without client update
    inactiveUserDays: parseInt(process.env.CLEANUP_INACTIVE_USER_DAYS || '30'),
    
    // ✅ Separate retention periods for different message types
    deleteSystemMessagesDays: parseInt(process.env.CLEANUP_SYSTEM_MESSAGES_DAYS || '1'),     // read_receipt, senderKeyRequest, fileKeyRequest, etc.
    deleteRegularMessagesDays: parseInt(process.env.CLEANUP_REGULAR_MESSAGES_DAYS || '7'),    // message, file (buffer for offline devices - 7 days)
    deleteGroupMessagesDays: parseInt(process.env.CLEANUP_GROUP_MESSAGES_DAYS || '7'),      // Group messages (7 days buffer)
    
    // Cronjob schedule (runs every day at 2:00 AM)
    cronSchedule: process.env.CLEANUP_CRON_SCHEDULE || '0 2 * * *'
};

// LiveKit Server configuration (for meetings/calls)
config.livekit = {
    url: process.env.LIVEKIT_URL || 'ws://localhost:7880',
    // Use internal hostname when running in Docker
    apiKey: process.env.LIVEKIT_API_KEY || 'devkey',
    apiSecret: process.env.LIVEKIT_API_SECRET || 'secret',
};

// OTP Configuration
config.otp = {
    expirationMinutes: parseInt(process.env.OTP_EXPIRATION_MINUTES || '10'), // How long OTP is valid
    waitTimeMinutes: parseInt(process.env.OTP_WAIT_TIME_MINUTES || '1'),     // Minimum time before requesting new OTP
};

// Invitation Configuration
config.invitation = {
    expirationHours: parseInt(process.env.INVITATION_EXPIRATION_HOURS || '48'), // How long invitation is valid (default: 48 hours)
};

// Refresh Token Configuration (for native client session renewal)
config.refreshToken = {
    expiresInDays: parseInt(process.env.REFRESH_TOKEN_DAYS || '60'),           // 60 days (industry standard)
    rotationEnabled: process.env.REFRESH_TOKEN_ROTATION !== 'false',           // Always rotate for security
    cleanupIntervalHours: parseInt(process.env.REFRESH_TOKEN_CLEANUP_HOURS || '24')  // Run cleanup daily
};

// Server Operator Information (displayed on login page)
config.serverOperator = {
    owner: process.env.SERVER_OWNER || null,
    contact: process.env.SERVER_CONTACT || null,
    location: process.env.SERVER_LOCATION || null,
    additionalInfo: process.env.SERVER_ADDITIONAL_INFO || null,
};

module.exports = config;