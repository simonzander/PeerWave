// ============================================================
// PeerWave COTURN Integration
// Node.js Helper für dynamische TURN Credentials
// ============================================================

const crypto = require('crypto');

class TurnCredentialsService {
  constructor(sharedSecret, ttlSeconds = 86400) {
    this.sharedSecret = sharedSecret;
    this.ttlSeconds = ttlSeconds; // Default: 24 Stunden
  }

  /**
   * Generiert temporäre TURN Credentials mit HMAC
   * @param {string} username - Optional: Custom username
   * @returns {Object} { username, credential, ttl }
   */
  generateCredentials(username = null) {
    // Timestamp: Jetzt + TTL
    const timestamp = Math.floor(Date.now() / 1000) + this.ttlSeconds;
    
    // Username Format: timestamp:username
    const user = username || `peerwave-${Date.now()}`;
    const turnUsername = `${timestamp}:${user}`;
    
    // HMAC-SHA1 für Password
    const hmac = crypto.createHmac('sha1', this.sharedSecret);
    hmac.update(turnUsername);
    const turnPassword = hmac.digest('base64');
    
    return {
      username: turnUsername,
      credential: turnPassword,
      ttl: this.ttlSeconds,
      expiresAt: new Date(timestamp * 1000).toISOString()
    };
  }

  /**
   * Generiert vollständige ICE Server Config für WebRTC
   * @param {string} turnServerUrl - TURN Server URL (z.B. "turn:your-server.com:3478")
   * @param {string} stunServerUrl - Optional: STUN Server URL
   * @returns {Array} ICE Servers Config
   */
  getIceServersConfig(turnServerUrl, stunServerUrl = null) {
    const creds = this.generateCredentials();
    
    const iceServers = [];
    
    // STUN Server (falls angegeben)
    if (stunServerUrl) {
      iceServers.push({ urls: stunServerUrl });
    }
    
    // TURN Server mit Credentials
    iceServers.push({
      urls: turnServerUrl,
      username: creds.username,
      credential: creds.credential
    });
    
    return iceServers;
  }
}

// ============================================================
// Express.js Route Beispiel
// ============================================================

/**
 * Beispiel: Express Route für ICE Servers
 * 
 * GET /api/ice-servers
 * Returns: { iceServers: [...] }
 */
function setupIceServersRoute(app, config) {
  const turnService = new TurnCredentialsService(
    config.turnSharedSecret,
    config.turnTtl || 86400
  );

  app.get('/api/ice-servers', (req, res) => {
    try {
      const iceServers = turnService.getIceServersConfig(
        config.turnServerUrl,
        config.stunServerUrl
      );

      res.json({
        iceServers,
        ttl: turnService.ttlSeconds
      });
    } catch (error) {
      console.error('Error generating ICE servers:', error);
      res.status(500).json({ error: 'Failed to generate ICE servers' });
    }
  });
}

// ============================================================
// Socket.IO Integration Beispiel
// ============================================================

/**
 * Beispiel: Socket.IO Event für ICE Servers
 * 
 * Client emittiert: 'request-ice-servers'
 * Server antwortet mit: iceServers Config
 */
function setupIceServersSocket(io, config) {
  const turnService = new TurnCredentialsService(
    config.turnSharedSecret,
    config.turnTtl || 86400
  );

  io.on('connection', (socket) => {
    socket.on('request-ice-servers', () => {
      try {
        const iceServers = turnService.getIceServersConfig(
          config.turnServerUrl,
          config.stunServerUrl
        );

        socket.emit('ice-servers', {
          iceServers,
          ttl: turnService.ttlSeconds
        });
      } catch (error) {
        console.error('Error generating ICE servers:', error);
        socket.emit('error', { message: 'Failed to generate ICE servers' });
      }
    });
  });
}

// ============================================================
// Config Beispiel (config/config.js)
// ============================================================

const TURN_CONFIG = {
  // Eigener TURN Server
  turnServerUrl: process.env.TURN_SERVER_URL || 'turn:your-server.com:3478',
  stunServerUrl: process.env.STUN_SERVER_URL || 'stun:your-server.com:3478',
  turnSharedSecret: process.env.TURN_SHARED_SECRET || 'your-shared-secret-here',
  turnTtl: parseInt(process.env.TURN_TTL) || 86400, // 24 Stunden
  
  // Fallback: Public STUN (kostenlos)
  publicStunServers: [
    'stun:stun.l.google.com:19302',
    'stun:stun1.l.google.com:19302'
  ]
};

// ============================================================
// Hybrid Config: Eigener Server + Public Fallback
// ============================================================

function getHybridIceServers(config) {
  const turnService = new TurnCredentialsService(
    config.turnSharedSecret,
    config.turnTtl
  );

  const iceServers = [];
  
  // 1. Public STUN (kostenlos, immer verfügbar)
  config.publicStunServers.forEach(url => {
    iceServers.push({ urls: url });
  });
  
  // 2. Eigener STUN Server
  if (config.stunServerUrl) {
    iceServers.push({ urls: config.stunServerUrl });
  }
  
  // 3. Eigener TURN Server mit Credentials
  const creds = turnService.generateCredentials();
  iceServers.push({
    urls: config.turnServerUrl,
    username: creds.username,
    credential: creds.credential
  });
  
  return iceServers;
}

// ============================================================
// Exports
// ============================================================

module.exports = {
  TurnCredentialsService,
  setupIceServersRoute,
  setupIceServersSocket,
  getHybridIceServers,
  TURN_CONFIG
};

// ============================================================
// CLI Test Tool
// ============================================================

if (require.main === module) {
  // Test Credentials generieren
  console.log('🧪 TURN Credentials Test\n');
  
  const testSecret = 'test-shared-secret-12345';
  const service = new TurnCredentialsService(testSecret, 3600); // 1 Stunde
  
  const creds = service.generateCredentials('test-user');
  
  console.log('Generated Credentials:');
  console.log('  Username:', creds.username);
  console.log('  Password:', creds.credential);
  console.log('  TTL:', creds.ttl, 'seconds');
  console.log('  Expires:', creds.expiresAt);
  console.log('\nWebRTC Config:');
  console.log(JSON.stringify({
    urls: 'turn:your-server.com:3478',
    username: creds.username,
    credential: creds.credential
  }, null, 2));
}
