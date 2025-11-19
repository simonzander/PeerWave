const crypto = require('crypto');
const { sequelize } = require('../db/model');

/**
 * HMAC-based session authentication middleware for native clients
 * Web clients continue to use cookie-based authentication
 * This middleware supports both authentication methods
 */

/**
 * Verify HMAC-based session authentication for native clients
 * Checks X-Client-ID, X-Timestamp, X-Nonce, X-Signature headers
 */
async function verifySessionAuth(req, res, next) {
  const clientId = req.headers['x-client-id'];
  const timestamp = parseInt(req.headers['x-timestamp']);
  const nonce = req.headers['x-nonce'];
  const signature = req.headers['x-signature'];

  // Check if all required headers present
  if (!clientId || !timestamp || !nonce || !signature) {
    return res.status(401).json({ 
      error: 'missing_auth_headers',
      message: 'Missing authentication headers' 
    });
  }

  try {
    // 1. Verify timestamp (±5 minutes window)
    const now = Date.now();
    const maxDiff = 5 * 60 * 1000; // 5 minutes in milliseconds
    if (Math.abs(now - timestamp) > maxDiff) {
      console.log(`[SessionAuth] Request expired: timestamp=${timestamp}, now=${now}, diff=${Math.abs(now - timestamp)}ms`);
      return res.status(401).json({ 
        error: 'request_expired',
        message: 'Request timestamp outside acceptable window' 
      });
    }

    // 2. Check nonce for replay attack prevention
    const [nonceCheck] = await sequelize.query(
      'SELECT 1 FROM nonce_cache WHERE nonce = ?',
      { replacements: [nonce] }
    );
    
    if (nonceCheck && nonceCheck.length > 0) {
      console.log(`[SessionAuth] Duplicate nonce detected: ${nonce}`);
      return res.status(401).json({ 
        error: 'duplicate_request',
        message: 'Nonce already used (replay attack prevented)' 
      });
    }
    
    // Store nonce (expires in 10 minutes)
    await sequelize.query(
      'INSERT INTO nonce_cache (nonce, created_at) VALUES (?, datetime("now"))',
      { replacements: [nonce] }
    );

    // 3. Get session secret from database
    const [sessions] = await sequelize.query(
      `SELECT session_secret, user_id, expires_at 
       FROM client_sessions 
       WHERE client_id = ?`,
      { replacements: [clientId] }
    );

    if (!sessions || sessions.length === 0) {
      console.log(`[SessionAuth] No session found for client: ${clientId}`);
      return res.status(401).json({ 
        error: 'no_session',
        message: 'No active session for this client' 
      });
    }

    const session = sessions[0];

    // Check if session expired
    if (new Date(session.expires_at) < new Date()) {
      console.log(`[SessionAuth] Session expired for client: ${clientId}`);
      return res.status(401).json({ 
        error: 'session_expired',
        message: 'Session has expired, please re-authenticate' 
      });
    }

    // 4. Generate expected signature
    const requestBody = req.body ? JSON.stringify(req.body) : '';
    const message = `${clientId}:${timestamp}:${nonce}:${req.path}:${requestBody}`;
    const expectedSignature = crypto
      .createHmac('sha256', session.session_secret)
      .update(message)
      .digest('hex');

    // 5. Compare signatures (constant-time comparison to prevent timing attacks)
    const signatureBuffer = Buffer.from(signature, 'hex');
    const expectedBuffer = Buffer.from(expectedSignature, 'hex');
    
    if (signatureBuffer.length !== expectedBuffer.length || 
        !crypto.timingSafeEqual(signatureBuffer, expectedBuffer)) {
      console.log(`[SessionAuth] Signature mismatch for client: ${clientId}`);
      console.log(`[SessionAuth] Expected: ${expectedSignature}`);
      console.log(`[SessionAuth] Received: ${signature}`);
      console.log(`[SessionAuth] Message: ${message}`);
      return res.status(401).json({ 
        error: 'invalid_signature',
        message: 'Authentication signature mismatch' 
      });
    }

    // Update last_used timestamp
    await sequelize.query(
      'UPDATE client_sessions SET last_used = datetime("now") WHERE client_id = ?',
      { replacements: [clientId] }
    );

    // Authentication successful - attach to request
    req.clientId = clientId;
    req.userId = session.user_id;
    req.sessionAuth = true;

    console.log(`[SessionAuth] ✓ Client ${clientId} authenticated successfully`);
    next();
  } catch (err) {
    console.error('[SessionAuth] Verification error:', err);
    res.status(500).json({ 
      error: 'auth_error',
      message: 'Internal authentication error' 
    });
  }
}

/**
 * Middleware that allows both session auth (native) and cookie auth (web)
 * This should be used on all protected routes to support both client types
 */
async function verifyAuthEither(req, res, next) {
  // Try session auth first (for native clients)
  const hasSessionHeaders = req.headers['x-client-id'] && req.headers['x-signature'];
  
  if (hasSessionHeaders) {
    console.log(`[AuthEither] Native client detected, using session auth`);
    return verifySessionAuth(req, res, next);
  }
  
  // Fall back to cookie/session auth (for web clients)
  if (req.session && req.session.uuid) {
    console.log(`[AuthEither] Web client detected, using cookie auth`);
    req.userId = req.session.uuid;
    req.sessionAuth = false;
    return next();
  }
  
  console.log(`[AuthEither] No valid authentication found`);
  return res.status(401).json({ 
    error: 'unauthorized',
    message: 'Authentication required' 
  });
}

/**
 * Cleanup old nonces (should be called periodically)
 */
async function cleanupNonces() {
  try {
    const result = await sequelize.query(
      'DELETE FROM nonce_cache WHERE created_at < datetime("now", "-10 minutes")'
    );
    console.log(`[SessionAuth] Cleaned up old nonces`);
  } catch (err) {
    console.error('[SessionAuth] Error cleaning up nonces:', err);
  }
}

/**
 * Cleanup expired sessions
 */
async function cleanupSessions() {
  try {
    await sequelize.query(
      'DELETE FROM client_sessions WHERE expires_at < datetime("now")'
    );
    console.log(`[SessionAuth] Cleaned up expired sessions`);
  } catch (err) {
    console.error('[SessionAuth] Error cleaning up sessions:', err);
  }
}

module.exports = { 
  verifySessionAuth, 
  verifyAuthEither,
  cleanupNonces,
  cleanupSessions
};
