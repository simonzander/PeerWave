const jwt = require('jsonwebtoken');
const crypto = require('crypto');
const config = require('../config/config');
const logger = require('./logger');
const { sanitizeForLog } = require('./logSanitizer');

// Use JWT secret from config (auto-generated if not in .env)
const JWT_SECRET = config.jwt.secret;

// In-memory stores (use Redis in production for distributed systems)
const usedTokens = new Set();
const revokedTokens = new Set(); // JTI of revoked tokens

// Cleanup expired tokens every minute
setInterval(() => {
    const now = Date.now();
    
    // Clean used tokens
    for (const token of usedTokens) {
        try {
            const decoded = jwt.decode(token);
            if (decoded && decoded.exp * 1000 < now) {
                usedTokens.delete(token);
            }
        } catch (e) {
            usedTokens.delete(token);
        }
    }
    
    // Clean revoked tokens
    for (const jti of revokedTokens) {
        try {
            // In real implementation, store with expiration time
            // For now, keep for 5 minutes
            const parts = jti.split(':');
            if (parts.length === 2) {
                const timestamp = parseInt(parts[1]);
                if (now - timestamp > 300000) { // 5 minutes
                    revokedTokens.delete(jti);
                }
            }
        } catch (e) {
            revokedTokens.delete(jti);
        }
    }
}, 60000); // Every minute

/**
 * Generate a short-lived JWT token for Custom Tab authentication
 * @param {Object} payload - Token payload
 * @param {string} payload.userId - User UUID
 * @param {string} payload.email - User email
 * @param {string} payload.state - CSRF state parameter
 * @returns {string} Signed JWT token
 */
function generateAuthToken(payload) {
    const jti = crypto.randomBytes(16).toString('hex');
    logger.debug(`[JWT] Generating auth token - User: ${sanitizeForLog(payload.email)}, JTI: ${jti}, Expiry: ${config.jwt.expiresIn}`);
    
    return jwt.sign(
        {
            ...payload,
            type: 'custom_tab_auth',
            jti: jti, // Unique token ID for revocation
        },
        JWT_SECRET,
        {
            expiresIn: config.jwt.expiresIn, // From config (default: 60s)
            algorithm: 'HS256'
        }
    );
}

/**
 * Verify and decode JWT token
 * @param {string} token - JWT token to verify
 * @returns {Object|null} Decoded payload or null if invalid
 */
function verifyAuthToken(token) {
    try {
        logger.debug('[JWT] Verifying auth token...');
        
        // Check if token was already used
        if (usedTokens.has(token)) {
            logger.error('[JWT] ✗ Security violation: Token already used (replay attack prevented)');
            return null;
        }

        // Verify signature and expiration
        const decoded = jwt.verify(token, JWT_SECRET, {
            algorithms: ['HS256']
        });
        
        logger.debug(`[JWT] ✓ Token signature valid - User: ${decoded.email}, JTI: ${decoded.jti}`);

        // Verify token type
        if (decoded.type !== 'custom_tab_auth') {
            logger.error(`[JWT] ✗ Invalid token type: ${decoded.type} (expected: custom_tab_auth)`);
            return null;
        }

        // Check if token was revoked
        const revokeKey = `${decoded.jti}:${decoded.iat}`;
        if (revokedTokens.has(revokeKey)) {
            logger.error(`[JWT] ✗ Token was revoked - JTI: ${decoded.jti}`);
            return null;
        }

        // Mark token as used (one-time use protection)
        usedTokens.add(token);
        logger.debug(`[JWT] ✓ Token marked as used - User: ${decoded.email}`);

        return decoded;
    } catch (error) {
        if (error.name === 'TokenExpiredError') {
            logger.error('[JWT] ✗ Token expired');
        } else if (error.name === 'JsonWebTokenError') {
            logger.error('[JWT] ✗ Invalid token signature');
        } else {
            logger.error('[JWT] ✗ Token verification error:', error.message);
        }
        return null;
    }
}

/**
 * Revoke a JWT token by its JTI
 * @param {string} token - JWT token to revoke
 * @returns {boolean} True if revoked successfully
 */
function revokeToken(token) {
    try {
        // Decode without verification (we just need JTI)
        const decoded = jwt.decode(token);
        if (!decoded || !decoded.jti) {
            logger.error('[JWT] Cannot revoke token - missing JTI');
            return false;
        }

        // Store JTI with timestamp for cleanup
        const revokeKey = `${decoded.jti}:${decoded.iat || Date.now()}`;
        revokedTokens.add(revokeKey);
        
        // Also mark as used to prevent immediate use
        usedTokens.add(token);
        
        logger.debug('[JWT] ✓ Token revoked', { jti: decoded.jti });
        return true;
    } catch (error) {
        logger.error('[JWT] Error revoking token:', error.message);
        return false;
    }
}

/**
 * Check if a token is revoked
 * @param {string} token - JWT token to check
 * @returns {boolean} True if revoked
 */
function isTokenRevoked(token) {
    try {
        const decoded = jwt.decode(token);
        if (!decoded || !decoded.jti) return false;
        
        const revokeKey = `${decoded.jti}:${decoded.iat}`;
        return revokedTokens.has(revokeKey);
    } catch (error) {
        return false;
    }
}

/**
 * Generate CSRF state parameter
 * @returns {string} Random state string
 */
function generateState() {
    return crypto.randomBytes(32).toString('hex');
}

module.exports = {
    generateAuthToken,
    verifyAuthToken,
    revokeToken,
    isTokenRevoked,
    generateState,
    JWT_SECRET
};
