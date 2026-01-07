const jwt = require('jsonwebtoken');
const crypto = require('crypto');

// Generate JWT secret if not set (store this in environment variable in production!)
const JWT_SECRET = process.env.JWT_SECRET || crypto.randomBytes(64).toString('hex');

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
    return jwt.sign(
        {
            ...payload,
            type: 'custom_tab_auth',
            jti: crypto.randomBytes(16).toString('hex'), // Unique token ID
        },
        JWT_SECRET,
        {
            expiresIn: '60s', // 60 seconds
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
        // Check if token was already used
        if (usedTokens.has(token)) {
            console.error('[JWT] Token already used (replay attack?)');
            return null;
        }

        // Verify signature and expiration
        const decoded = jwt.verify(token, JWT_SECRET, {
            algorithms: ['HS256']
        });

        // Verify token type
        if (decoded.type !== 'custom_tab_auth') {
            console.error('[JWT] Invalid token type:', decoded.type);
            return null;
        }

        // Check if token was revoked
        const revokeKey = `${decoded.jti}:${decoded.iat}`;
        if (revokedTokens.has(revokeKey)) {
            console.error('[JWT] Token was revoked');
            return null;
        }

        // Mark token as used (one-time use)
        usedTokens.add(token);

        return decoded;
    } catch (error) {
        if (error.name === 'TokenExpiredError') {
            console.error('[JWT] Token expired');
        } else if (error.name === 'JsonWebTokenError') {
            console.error('[JWT] Invalid token signature');
        } else {
            console.error('[JWT] Token verification error:', error.message);
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
            console.error('[JWT] Cannot revoke token - missing JTI');
            return false;
        }

        // Store JTI with timestamp for cleanup
        const revokeKey = `${decoded.jti}:${decoded.iat || Date.now()}`;
        revokedTokens.add(revokeKey);
        
        // Also mark as used to prevent immediate use
        usedTokens.add(token);
        
        console.log('[JWT] ✓ Token revoked', { jti: decoded.jti });
        return true;
    } catch (error) {
        console.error('[JWT] Error revoking token:', error.message);
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
