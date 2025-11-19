# Server-Side Implementation Checklist

## Required Server Changes for HMAC Session Authentication

### 1. Database Schema Updates

Add to your existing database:

```sql
-- Client sessions table
CREATE TABLE IF NOT EXISTS client_sessions (
  client_id VARCHAR(255) PRIMARY KEY,
  session_secret VARCHAR(255) NOT NULL,
  user_id INTEGER NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  last_used TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMP,
  device_info TEXT,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE INDEX idx_sessions_user ON client_sessions(user_id);
CREATE INDEX idx_sessions_expires ON client_sessions(expires_at);

-- Nonce cache for replay attack prevention
CREATE TABLE IF NOT EXISTS nonce_cache (
  nonce VARCHAR(255) PRIMARY KEY,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_nonce_created ON nonce_cache(created_at);

-- Cleanup old nonces (run periodically)
-- DELETE FROM nonce_cache WHERE created_at < datetime('now', '-10 minutes');
```

### 2. Magic Key Verification Endpoint Update

**File**: `server/routes/client.js` (or equivalent)

**Current**: Returns `{ status: 'ok', message: '...' }`

**Update to**:

```javascript
// POST /client/magic/verify
router.post('/magic/verify', async (req, res) => {
  const { key: magicKey, clientid: clientId } = req.body;
  
  try {
    // ... existing magic key validation ...
    
    // Generate session secret (256-bit random)
    const crypto = require('crypto');
    const sessionSecret = crypto.randomBytes(32).toString('base64url');
    
    // Store session in database
    await db.run(`
      INSERT OR REPLACE INTO client_sessions 
      (client_id, session_secret, user_id, device_info, expires_at)
      VALUES (?, ?, ?, ?, datetime('now', '+30 days'))
    `, [clientId, sessionSecret, userId, JSON.stringify({ userAgent: req.headers['user-agent'] })]);
    
    res.json({
      status: 'ok',
      message: 'Magic key verified successfully',
      sessionSecret: sessionSecret,  // NEW: Send secret to client
      userId: userId,
      // ... other existing fields ...
    });
  } catch (err) {
    res.status(400).json({ status: 'error', message: err.message });
  }
});
```

### 3. Session Verification Middleware

**Create new file**: `server/middleware/sessionAuth.js`

```javascript
const crypto = require('crypto');

/**
 * Middleware to verify HMAC-based session authentication
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
      return res.status(401).json({ 
        error: 'request_expired',
        message: 'Request timestamp outside acceptable window' 
      });
    }

    // 2. Check nonce for replay attack prevention
    const nonceExists = await db.get(
      'SELECT 1 FROM nonce_cache WHERE nonce = ?',
      [nonce]
    );
    if (nonceExists) {
      return res.status(401).json({ 
        error: 'duplicate_request',
        message: 'Nonce already used (replay attack prevented)' 
      });
    }
    
    // Store nonce (expires in 10 minutes)
    await db.run(
      'INSERT INTO nonce_cache (nonce, created_at) VALUES (?, datetime("now"))',
      [nonce]
    );

    // 3. Get session secret from database
    const session = await db.get(
      `SELECT session_secret, user_id, expires_at 
       FROM client_sessions 
       WHERE client_id = ?`,
      [clientId]
    );

    if (!session) {
      return res.status(401).json({ 
        error: 'no_session',
        message: 'No active session for this client' 
      });
    }

    // Check if session expired
    if (new Date(session.expires_at) < new Date()) {
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
    if (!crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expectedSignature))) {
      return res.status(401).json({ 
        error: 'invalid_signature',
        message: 'Authentication signature mismatch' 
      });
    }

    // Update last_used timestamp
    await db.run(
      'UPDATE client_sessions SET last_used = datetime("now") WHERE client_id = ?',
      [clientId]
    );

    // Authentication successful - attach to request
    req.clientId = clientId;
    req.userId = session.user_id;
    req.sessionAuth = true;

    next();
  } catch (err) {
    console.error('[SessionAuth] Verification error:', err);
    res.status(500).json({ 
      error: 'auth_error',
      message: 'Internal authentication error' 
    });
  }
}

// Optional: Middleware that allows both session auth and cookie auth
async function verifyAuthEither(req, res, next) {
  // Try session auth first (for native clients)
  const hasSessionHeaders = req.headers['x-client-id'] && req.headers['x-signature'];
  
  if (hasSessionHeaders) {
    return verifySessionAuth(req, res, next);
  }
  
  // Fall back to cookie/session auth (for web clients)
  if (req.session && req.session.userId) {
    req.userId = req.session.userId;
    req.sessionAuth = false;
    return next();
  }
  
  return res.status(401).json({ 
    error: 'unauthorized',
    message: 'Authentication required' 
  });
}

module.exports = { verifySessionAuth, verifyAuthEither };
```

### 4. Apply Middleware to Protected Routes

**File**: `server/routes/channels.js` (and other protected routes)

```javascript
const { verifyAuthEither } = require('../middleware/sessionAuth');

// Apply to all routes in this file
router.use(verifyAuthEither);

// Or apply to specific routes
router.get('/channels', verifyAuthEither, async (req, res) => {
  // req.userId is now available
  // req.sessionAuth indicates if native (true) or web (false)
});
```

### 5. WebSocket Authentication Update

**File**: `server/websocket.js` (or wherever socket.io is configured)

```javascript
const crypto = require('crypto');

io.use(async (socket, next) => {
  const auth = socket.handshake.auth;
  
  // Check if session auth headers present (native client)
  if (auth['X-Client-ID'] && auth['X-Signature']) {
    try {
      const clientId = auth['X-Client-ID'];
      const timestamp = parseInt(auth['X-Timestamp']);
      const nonce = auth['X-Nonce'];
      const signature = auth['X-Signature'];

      // Same verification logic as HTTP middleware
      // 1. Check timestamp
      const now = Date.now();
      const maxDiff = 5 * 60 * 1000;
      if (Math.abs(now - timestamp) > maxDiff) {
        return next(new Error('Request expired'));
      }

      // 2. Check nonce
      const nonceExists = await db.get('SELECT 1 FROM nonce_cache WHERE nonce = ?', [nonce]);
      if (nonceExists) {
        return next(new Error('Duplicate request'));
      }
      await db.run('INSERT INTO nonce_cache (nonce) VALUES (?)', [nonce]);

      // 3. Get session
      const session = await db.get(
        'SELECT session_secret, user_id FROM client_sessions WHERE client_id = ?',
        [clientId]
      );
      if (!session) {
        return next(new Error('No active session'));
      }

      // 4. Verify signature
      const message = `${clientId}:${timestamp}:${nonce}:/socket.io/auth:`;
      const expectedSignature = crypto
        .createHmac('sha256', session.session_secret)
        .update(message)
        .digest('hex');

      if (signature !== expectedSignature) {
        return next(new Error('Invalid signature'));
      }

      // Success
      socket.clientId = clientId;
      socket.userId = session.user_id;
      socket.sessionAuth = true;
      
      // Emit authenticated event
      socket.emit('authenticated', {
        authenticated: true,
        userId: session.user_id,
        clientId: clientId,
      });

      next();
    } catch (err) {
      console.error('[Socket] Auth error:', err);
      next(new Error('Authentication failed'));
    }
  } else {
    // Fall back to cookie-based auth for web clients
    const sessionId = socket.request.cookies['connect.sid'];
    // ... existing cookie auth logic ...
    next();
  }
});
```

### 6. Session Management Endpoints (Optional but Recommended)

```javascript
// GET /api/sessions - List active sessions for user
router.get('/sessions', verifyAuthEither, async (req, res) => {
  const sessions = await db.all(`
    SELECT client_id, created_at, last_used, device_info 
    FROM client_sessions 
    WHERE user_id = ? 
    ORDER BY last_used DESC
  `, [req.userId]);
  
  res.json({ sessions });
});

// DELETE /api/sessions/:clientId - Revoke a specific session
router.delete('/sessions/:clientId', verifyAuthEither, async (req, res) => {
  await db.run(
    'DELETE FROM client_sessions WHERE client_id = ? AND user_id = ?',
    [req.params.clientId, req.userId]
  );
  
  res.json({ message: 'Session revoked' });
});

// POST /api/sessions/rotate - Rotate current session secret
router.post('/sessions/rotate', verifySessionAuth, async (req, res) => {
  const newSecret = crypto.randomBytes(32).toString('base64url');
  
  await db.run(
    'UPDATE client_sessions SET session_secret = ? WHERE client_id = ?',
    [newSecret, req.clientId]
  );
  
  res.json({ sessionSecret: newSecret });
});
```

### 7. Cleanup Job (Run Periodically)

```javascript
// Clean up expired sessions and old nonces
async function cleanupSessions() {
  // Remove expired sessions
  await db.run(`
    DELETE FROM client_sessions 
    WHERE expires_at < datetime('now')
  `);
  
  // Remove old nonces (older than 10 minutes)
  await db.run(`
    DELETE FROM nonce_cache 
    WHERE created_at < datetime('now', '-10 minutes')
  `);
}

// Run every hour
setInterval(cleanupSessions, 60 * 60 * 1000);
```

### 8. Testing

```javascript
// Test endpoint to verify session auth is working
router.get('/api/test-auth', verifySessionAuth, (req, res) => {
  res.json({
    message: 'Authentication successful',
    clientId: req.clientId,
    userId: req.userId,
    timestamp: new Date().toISOString(),
  });
});
```

## Deployment Checklist

- [ ] Database migrations applied
- [ ] SessionAuth middleware created
- [ ] Magic key endpoint returns sessionSecret
- [ ] Protected routes use verifyAuthEither middleware
- [ ] WebSocket authentication updated
- [ ] Cleanup job scheduled
- [ ] Test with native client
- [ ] Monitor authentication logs for errors
- [ ] Set up alerts for suspicious patterns (many failed auths)

## Backward Compatibility

The `verifyAuthEither` middleware ensures:
- Web clients continue using cookie-based auth (no changes needed)
- Native clients use new HMAC session auth
- Both work simultaneously during migration period

## Security Notes

1. **HTTPS Required**: Session secrets must only be transmitted over HTTPS
2. **Secret Storage**: Never log session secrets
3. **Rate Limiting**: Add rate limiting to magic key verification endpoint
4. **Monitoring**: Track failed authentication attempts
5. **Session Expiry**: Default 30 days, adjust based on security requirements

## Performance Impact

- Minimal (<1ms per request)
- Nonce cache recommended in Redis for high-traffic servers
- Consider caching session secrets in memory (with TTL)
