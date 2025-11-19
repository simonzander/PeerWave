# HMAC-Based Session Authentication Implementation

## Overview

This implementation provides secure session authentication for native clients using HMAC-SHA256 signatures to prevent various attacks including replay attacks, session hijacking, and client ID theft.

## Architecture

### Components

1. **SessionAuthService** - Core service for generating HMAC signatures
2. **SecureSessionStorage** - Platform-specific secure storage for session secrets
3. **SessionAuthInterceptor** - Dio interceptor that adds auth headers to API requests
4. **Socket Authentication** - WebSocket authentication with HMAC headers

### Security Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    1. Initial Authentication                 │
└─────────────────────────────────────────────────────────────┘

Client                          Server
   │                               │
   ├──── Magic Key + Client ID ───>│
   │                               │ Validate magic key
   │                               │ Generate sessionSecret (256-bit random)
   │<──── Session Secret ──────────│
   │                               │
   │ Store in secure storage       │
   └───────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    2. Authenticated Requests                 │
└─────────────────────────────────────────────────────────────┘

Client                          Server
   │                               │
   │ Generate:                     │
   │  - timestamp                  │
   │  - nonce (UUID)               │
   │  - message = "clientId:timestamp:nonce:path:body"
   │  - signature = HMAC-SHA256(sessionSecret, message)
   │                               │
   ├──── API Request ─────────────>│
   │  Headers:                     │
   │    X-Client-ID: <clientId>    │
   │    X-Timestamp: <timestamp>   │
   │    X-Nonce: <nonce>           │
   │    X-Signature: <signature>   │
   │                               │
   │                               │ Verify:
   │                               │  1. Timestamp within ±5 min
   │                               │  2. Nonce not seen before
   │                               │  3. Signature matches
   │                               │  4. Session not revoked
   │<──── Response ────────────────│
   └───────────────────────────────┘
```

## Security Features

### 1. **HMAC-SHA256 Signatures**
- Each request is signed with a secret only known to client and server
- Prevents tampering with request data
- Server can verify authenticity without storing passwords

### 2. **Replay Attack Prevention**
- **Timestamp**: Requests valid only within ±5 minute window
- **Nonce**: Unique UUID per request, server caches for 10 minutes
- Prevents attackers from reusing captured requests

### 3. **Session Management**
- Session secrets stored in platform-specific secure storage:
  - **iOS**: Keychain
  - **Android**: EncryptedSharedPreferences
  - **Windows**: Credential Manager
  - **macOS**: Keychain
  - **Linux**: Libsecret

### 4. **Session Rotation**
- Server can rotate session secrets periodically (recommended: 24-48 hours)
- Client atomically replaces old secret with new one
- Limits damage from compromised secrets

### 5. **Immediate Revocation**
- Server can instantly revoke sessions
- No waiting for token expiry
- Useful for security incidents or logout

## Implementation Details

### Client-Side

#### 1. Session Initialization (Magic Key Flow)

```dart
// In magic_key_service.dart
final response = await ApiService.post(
  '${serverUrl}/client/magic/verify',
  data: {
    'key': magicKey,
    'clientid': clientId,
  },
);

if (response.data['sessionSecret'] != null) {
  await SessionAuthService().initializeSession(
    clientId,
    response.data['sessionSecret'],
  );
}
```

#### 2. Request Signing

```dart
// Automatically done by SessionAuthInterceptor
final authHeaders = await SessionAuthService().generateAuthHeaders(
  clientId: clientId,
  requestPath: '/api/channels',
  requestBody: json.encode(requestData),
);

// Headers added:
// X-Client-ID: abc123
// X-Timestamp: 1700000000000
// X-Nonce: 550e8400-e29b-41d4-a716-446655440000
// X-Signature: a1b2c3d4e5f6...
```

#### 3. Signature Generation

```dart
String _generateSignature({
  required String sessionSecret,
  required String clientId,
  required int timestamp,
  required String nonce,
  required String requestPath,
  String? requestBody,
}) {
  final message = '$clientId:$timestamp:$nonce:$requestPath:${requestBody ?? ''}';
  final key = utf8.encode(sessionSecret);
  final bytes = utf8.encode(message);
  final hmac = Hmac(sha256, key);
  final digest = hmac.convert(bytes);
  return digest.toString();
}
```

### Server-Side (To Implement)

#### 1. Session Secret Generation

```javascript
// Node.js example
const crypto = require('crypto');

function generateSessionSecret() {
  return crypto.randomBytes(32).toString('base64url');
}

// On magic key verification:
const sessionSecret = generateSessionSecret();
await db.storeClientSession(clientId, sessionSecret);

res.json({
  status: 'ok',
  message: 'Authentication successful',
  sessionSecret: sessionSecret,
});
```

#### 2. Request Verification Middleware

```javascript
async function verifySessionAuth(req, res, next) {
  const clientId = req.headers['x-client-id'];
  const timestamp = parseInt(req.headers['x-timestamp']);
  const nonce = req.headers['x-nonce'];
  const signature = req.headers['x-signature'];

  // 1. Check timestamp (±5 minutes)
  const now = Date.now();
  const maxDiff = 5 * 60 * 1000;
  if (Math.abs(now - timestamp) > maxDiff) {
    return res.status(401).json({ error: 'Request expired' });
  }

  // 2. Check nonce (prevent replay)
  const nonceKey = `nonce:${nonce}`;
  const nonceExists = await redis.get(nonceKey);
  if (nonceExists) {
    return res.status(401).json({ error: 'Duplicate request' });
  }
  await redis.setex(nonceKey, 600, '1'); // Cache for 10 minutes

  // 3. Get session secret
  const sessionSecret = await db.getClientSession(clientId);
  if (!sessionSecret) {
    return res.status(401).json({ error: 'No active session' });
  }

  // 4. Verify signature
  const requestBody = req.body ? JSON.stringify(req.body) : '';
  const message = `${clientId}:${timestamp}:${nonce}:${req.path}:${requestBody}`;
  const expectedSignature = crypto
    .createHmac('sha256', sessionSecret)
    .update(message)
    .digest('hex');

  if (signature !== expectedSignature) {
    return res.status(401).json({ error: 'Invalid signature' });
  }

  // Authentication successful
  req.clientId = clientId;
  next();
}
```

#### 3. WebSocket Authentication

```javascript
io.use(async (socket, next) => {
  const authHeaders = socket.handshake.auth;
  
  try {
    // Verify same as HTTP requests
    const clientId = authHeaders['X-Client-ID'];
    const timestamp = parseInt(authHeaders['X-Timestamp']);
    const nonce = authHeaders['X-Nonce'];
    const signature = authHeaders['X-Signature'];
    
    // ... same verification logic ...
    
    socket.clientId = clientId;
    next();
  } catch (err) {
    next(new Error('Authentication failed'));
  }
});
```

## Database Schema

### Session Storage (Server)

```sql
CREATE TABLE client_sessions (
  client_id VARCHAR(255) PRIMARY KEY,
  session_secret VARCHAR(255) NOT NULL,
  user_id INTEGER NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  last_used TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMP,
  device_info JSON,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE INDEX idx_sessions_user ON client_sessions(user_id);
CREATE INDEX idx_sessions_expires ON client_sessions(expires_at);

-- Nonce cache (can also use Redis)
CREATE TABLE nonce_cache (
  nonce VARCHAR(255) PRIMARY KEY,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_nonce_created ON nonce_cache(created_at);
```

## Session Rotation

### Client

```dart
// Called periodically or when server indicates rotation needed
Future<void> rotateSession(String clientId, String newSessionSecret) async {
  await SessionAuthService().rotateSession(clientId, newSessionSecret);
}
```

### Server

```javascript
// Rotate every 24 hours
async function rotateClientSession(clientId) {
  const newSecret = generateSessionSecret();
  await db.updateClientSession(clientId, newSecret);
  
  // Send to client via WebSocket or next API response
  io.to(clientId).emit('session-rotate', {
    sessionSecret: newSecret,
  });
}
```

## Error Handling

### 401 Unauthorized

```dart
// Handled by UnauthorizedInterceptor
// Triggers automatic re-authentication flow:
// 1. Clear current session
// 2. Redirect to server selection screen
// 3. User enters new magic key
// 4. New session established
```

### Expired Sessions

```javascript
// Server should return specific error code
res.status(401).json({
  error: 'session_expired',
  message: 'Session has expired, please re-authenticate'
});

// Client handles gracefully
if (error.response?.data?.error === 'session_expired') {
  await SessionAuthService().clearSession(clientId);
  // Show re-auth UI
}
```

## Testing

### Generate Test Session

```dart
// For development/testing
final testSecret = SessionAuthService.generateSessionSecret();
await SessionAuthService().initializeSession('test-client', testSecret);
```

### Verify Signature

```dart
final isValid = SessionAuthService().verifySignature(
  sessionSecret: 'test-secret',
  clientId: 'test-client',
  timestamp: DateTime.now().millisecondsSinceEpoch,
  nonce: 'test-nonce',
  requestPath: '/api/test',
  signature: 'expected-signature',
);
```

## Migration from Magic Key Only

1. **Phase 1**: Deploy server changes, generate session secrets on magic key verification
2. **Phase 2**: Deploy client with session auth, fallback to magic key if no session
3. **Phase 3**: Server enforces session auth for all requests
4. **Phase 4**: Remove magic key fallback code

## Performance Considerations

- HMAC-SHA256 is very fast (~microseconds per signature)
- Nonce caching in Redis recommended for high-traffic servers
- Session secrets cached in memory on server for fast lookups
- No impact on request latency (<1ms overhead)

## Security Audit Checklist

- [ ] Session secrets generated with cryptographically secure random
- [ ] Secrets stored in platform-specific secure storage
- [ ] Timestamp validation with appropriate window (±5 minutes)
- [ ] Nonce uniqueness enforced
- [ ] HMAC signature covers all request components
- [ ] Session rotation implemented
- [ ] Session revocation on logout
- [ ] Rate limiting on authentication endpoints
- [ ] Monitoring for suspicious patterns (many failed auth attempts)
- [ ] Secure transmission (HTTPS/WSS only)

## Future Enhancements

1. **Device Binding**: Tie sessions to device hardware identifiers
2. **Geo-fencing**: Detect and block requests from unusual locations
3. **Behavioral Analysis**: ML-based anomaly detection
4. **Multi-factor Re-auth**: Require periodic user verification
5. **Session Sharing**: Allow same session across multiple devices with approval

## Support

For questions or issues:
- Check server logs for signature mismatches
- Verify client clock is synchronized (NTP)
- Ensure secure storage permissions are granted
- Test with known good session secret
