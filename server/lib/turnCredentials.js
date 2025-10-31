/**
 * TURN Credential Generator
 * 
 * Generiert zeitlich begrenzte TURN-Credentials nach RFC 5389
 * für sichere Authentication mit coturn Server
 */

const crypto = require('crypto');

/**
 * Generate time-limited TURN credentials using HMAC-SHA1
 * 
 * @param {string} username - Username/User ID
 * @param {string} secret - Shared secret (must match coturn config)
 * @param {number} ttl - Time-to-live in seconds (default: 24 hours)
 * @returns {Object} TURN credentials with username, password, and expiry timestamp
 */
function generateTurnCredentials(username, secret, ttl = 86400) {
    if (!username || !secret) {
        throw new Error('Username and secret are required for TURN credential generation');
    }

    // Calculate expiry timestamp (current time + TTL)
    const timestamp = Math.floor(Date.now() / 1000) + ttl;
    
    // Format: timestamp:username (RFC 5389)
    const turnUsername = `${timestamp}:${username}`;
    
    // Generate HMAC-SHA1 hash
    const hmac = crypto.createHmac('sha1', secret);
    hmac.update(turnUsername);
    const turnPassword = hmac.digest('base64');
    
    return {
        username: turnUsername,
        password: turnPassword,
        ttl: timestamp,
        expiresAt: new Date(timestamp * 1000).toISOString()
    };
}

/**
 * Build ICE server configuration for WebRTC
 * 
 * @param {Object} config - Server configuration object
 * @param {string} userId - User ID for credential generation
 * @returns {Array} Array of ICE server configurations
 */
function buildIceServerConfig(config, userId) {
    const iceServers = [];
    
    // Validate configuration
    if (!config || !config.turn) {
        console.warn('[TURN] No TURN configuration found, using public STUN only');
        return [
            {
                urls: ['stun:stun.l.google.com:19302']
            }
        ];
    }
    
    const { host, port, tlsPort, secret, realm, ttl } = config.turn;
    
    // Validate required fields
    if (!host || !secret) {
        console.warn('[TURN] Incomplete TURN configuration, using public STUN only');
        return [
            {
                urls: ['stun:stun.l.google.com:19302']
            }
        ];
    }
    
    // Generate credentials for this user
    let credentials = null;
    try {
        credentials = generateTurnCredentials(userId, secret, ttl);
    } catch (error) {
        console.error('[TURN] Failed to generate credentials:', error);
        return [
            {
                urls: ['stun:stun.l.google.com:19302']
            }
        ];
    }
    
    // 1. STUN Server (no authentication needed)
    iceServers.push({
        urls: [`stun:${host}:${port}`]
    });
    
    // 2. TURN Server (UDP + TCP)
    iceServers.push({
        urls: [
            `turn:${host}:${port}?transport=udp`,
            `turn:${host}:${port}?transport=tcp`
        ],
        username: credentials.username,
        credential: credentials.password
    });
    
    // 3. TURNS Server (TLS) - if TLS port is configured
    if (tlsPort && tlsPort !== port) {
        iceServers.push({
            urls: [`turns:${host}:${tlsPort}?transport=tcp`],
            username: credentials.username,
            credential: credentials.password
        });
    }
    
    // 4. Fallback to Google STUN (always available)
    iceServers.push({
        urls: ['stun:stun.l.google.com:19302']
    });
    
    console.log(`[TURN] Generated ICE servers for user ${userId}:`, {
        stun: `stun:${host}:${port}`,
        turn: `turn:${host}:${port}`,
        expiresAt: credentials.expiresAt
    });
    
    return iceServers;
}

/**
 * Check if TURN credentials are still valid
 * 
 * @param {string} turnUsername - TURN username in format "timestamp:username"
 * @returns {boolean} True if credentials are still valid
 */
function isCredentialValid(turnUsername) {
    if (!turnUsername || typeof turnUsername !== 'string') {
        return false;
    }
    
    const parts = turnUsername.split(':');
    if (parts.length < 2) {
        return false;
    }
    
    const expiryTimestamp = parseInt(parts[0], 10);
    if (isNaN(expiryTimestamp)) {
        return false;
    }
    
    const currentTimestamp = Math.floor(Date.now() / 1000);
    return currentTimestamp < expiryTimestamp;
}

module.exports = {
    generateTurnCredentials,
    buildIceServerConfig,
    isCredentialValid
};
