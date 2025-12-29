const config = {};

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
// If CORS_ORIGINS is not set, use the app URL (for production) or allow all (for development)
config.cors = {
    origin: process.env.CORS_ORIGINS 
        ? process.env.CORS_ORIGINS.split(',').map(o => o.trim()) 
        : (process.env.NODE_ENV === 'production' ? config.app.url : '*'),
    credentials: true
};

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

config.session = {
    secret: process.env.SESSION_SECRET || 'your-secret-key-CHANGE-IN-PRODUCTION',
    resave: false,
    saveUninitialized: true,
    cookie: { 
        secure: process.env.NODE_ENV === 'production' && config.https
    }
};

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

module.exports = config;