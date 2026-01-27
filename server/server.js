/**
 * Required modules
 */
const config = require('./config/config');
const LicenseValidator = require('./lib/license-validator');
const express = require("express");
const { randomUUID } = require('crypto');
const http = require("http");
const app = express();

// Trust proxy headers (required for rate limiting and IP detection behind Docker/nginx)
// Set to 1 to trust only the first proxy (nginx/traefik)
app.set('trust proxy', 1);

const sanitizeHtml = require('sanitize-html');
const cors = require('cors');
const session = require('express-session');
const SequelizeStore = require('connect-session-sequelize')(session.Store);
const sharedSession = require('socket.io-express-session');

// Database initialization - MUST happen before loading model
// This is handled by initializeDatabase() called at the end of the file

let User, Channel, Thread, Client, SignalSignedPreKey, SignalPreKey, Item, ChannelMembers, SignalSenderKey, GroupItem, GroupItemRead;

const path = require('path');
const writeQueue = require('./db/writeQueue');
const { initCleanupJob, runCleanup } = require('./jobs/cleanup');
const { initMeetingReminderJob } = require('./jobs/meetingReminders');
const logger = require('./utils/logger');
const { sendMessageNotification } = require('./services/push_notifications');

// ==================== SECURITY: FORMAT STRING SANITIZATION ====================
// Helper function to safely log user-controlled values
// Prevents format string injection attacks (CodeQL js/tainted-format-string)
// Prevents log injection attacks (CodeQL js/log-injection)
function sanitizeForLog(value) {
  if (value === null || value === undefined) return 'null';
  // Convert to string, remove newlines (log injection), and escape % (format string)
  return String(value)
    .replace(/[\n\r]/g, '') // Remove newlines to prevent log injection
    .replace(/[\x00-\x1F\x7F]/g, '') // Remove control characters
    .replace(/%/g, '%%') // Escape % to prevent format string interpretation
    .substring(0, 1000); // Limit length to prevent log flooding
}

// Initialize license validator
const licenseValidator = new LicenseValidator();

// Validate support subscription on startup
(async () => {
  logger.info('\n🔐 Validating PeerWave Support Subscription...');
  const license = await licenseValidator.validate();
  
  if (license.valid) {
    logger.info('✅ Support Subscription Active');
    logger.info(`   Customer: ${license.customer}`);
    logger.info(`   Edition: Supported Edition`);
    logger.info(`   Expires: ${license.expires.toISOString().split('T')[0]} (${license.daysRemaining} days)`);
    
    if (license.gracePeriod) {
      logger.warn(`   ⚠️  Grace Period: ${license.daysRemaining} days remaining`);
    }
    
    if (license.features.maxUsers) {
      logger.info(`   Max Users: ${license.features.maxUsers}`);
    }
    
    logger.info(`   Grace Period: ${license.gracePeriodDays} days after expiration`);
  } else if (license.error === 'EXPIRED') {
    // Support subscription expired and grace period is over - STOP SERVER
    logger.error('\n❌ FATAL: Support subscription has expired!');
    logger.error(`   ${license.message}`);
    logger.error(`   Server cannot start with expired subscription.`);
    logger.error(`   Please renew your subscription at https://peerwave.org\n`);
    process.exit(1);
  } else {
    logger.info(`ℹ️  No support subscription found: ${license.message}`);
    logger.info(`   Running Community Edition (AGPL-3.0)`);
    logger.info(`   For professional support, visit: https://peerwave.org`);
  }
  logger.info('');
})();

// Function to validate UUID
function isValidUUID(uuid) {
  const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[4][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  return uuidRegex.test(uuid);
}

// 🔄 Pending message queue for devices that are not ready yet
const pendingMessages = new Map(); // deviceKey -> [{event, data, timestamp}]

// 🚀 Helper function to safely emit to a device (only if client is ready)
function safeEmitToDevice(io, userId, deviceId, event, data) {
  const deviceKey = `${userId}:${deviceId}`;
  const socketId = deviceSockets.get(deviceKey);
  
  if (!socketId) {
    logger.warn('[SAFE_EMIT] Device not connected');
    logger.debug(`[SAFE_EMIT] DeviceKey: ${deviceKey}`);
    return false;
  }
  
  const targetSocket = io.sockets.sockets.get(socketId);
  if (!targetSocket) {
    logger.warn('[SAFE_EMIT] Socket not found');
    logger.debug(`[SAFE_EMIT] SocketId: ${socketId}`);
    return false;
  }
  
  if (!targetSocket.clientReady) {
    logger.warn('[SAFE_EMIT] Client not ready yet, queuing event');
    logger.debug(`[SAFE_EMIT] DeviceKey: ${deviceKey}, Event: ${event}`);
    
    // Queue the message for delivery when client becomes ready
    if (!pendingMessages.has(deviceKey)) {
      pendingMessages.set(deviceKey, []);
    }
    pendingMessages.get(deviceKey).push({
      event,
      data,
      timestamp: Date.now()
    });
    logger.info(`[SAFE_EMIT] Queued event for device (queue size: ${pendingMessages.get(deviceKey).length})`);
    logger.debug(`[SAFE_EMIT] Event: '${event}' for ${deviceKey}`);
    return false;
  }
  
  // Client is ready, safe to emit
  targetSocket.emit(event, data);
  logger.info('[SAFE_EMIT] Event sent to device');
  logger.debug(`[SAFE_EMIT] Event: '${event}' to ${deviceKey}`);
  return true;
}

/**
 * Emits an event to all connected devices for a given userId
 * @param {Object} io - Socket.IO server instance
 * @param {string} userId - Target user ID
 * @param {string} event - Event name to emit
 * @param {Object} data - Event payload
 * @returns {number} Number of devices the event was emitted to
 */
function emitToUser(io, userId, event, data) {
  let emittedCount = 0;
  
  // Iterate through all device connections and find matching userId
  deviceSockets.forEach((socketId, deviceKey) => {
    // deviceKey format: "userId:deviceId"
    if (deviceKey.startsWith(userId + ':')) {
      const targetSocket = io.sockets.sockets.get(socketId);
      
      if (targetSocket && targetSocket.clientReady) {
        targetSocket.emit(event, data);
        emittedCount++;
      }
    }
  });
  
  if (emittedCount === 0) {
    logger.info('[EMIT_TO_USER] User has no connected devices for event');
    logger.debug(`[EMIT_TO_USER] User: ${sanitizeForLog(userId)}, Event: ${event}`);
  } else {
    logger.info(`[EMIT_TO_USER] Emitted to ${emittedCount} device(s) for user`);
    logger.debug(`[EMIT_TO_USER] Event: '${event}', User: ${sanitizeForLog(userId)}`);
  }
  
  return emittedCount;
}

// 🚀 Flush pending messages when client becomes ready
function flushPendingMessages(io, socket, userId, deviceId) {
  const deviceKey = `${sanitizeForLog(userId)}:${sanitizeForLog(deviceId)}`;
  const pending = pendingMessages.get(`${userId}:${deviceId}`);
  
  if (!pending || pending.length === 0) {
    logger.debug('[SAFE_EMIT] No pending messages for device');
    logger.debug(`[SAFE_EMIT] DeviceKey: ${deviceKey}`);
    return;
  }
  
  logger.info(`[SAFE_EMIT] Flushing ${pending.length} pending messages for device`);
  logger.debug(`[SAFE_EMIT] DeviceKey: ${deviceKey}`);
  
  for (const msg of pending) {
    const age = Date.now() - msg.timestamp;
    logger.info(`[SAFE_EMIT] Delivering queued event (age: ${age}ms)`);
    logger.debug(`[SAFE_EMIT] Event: '${msg.event}'`);
    socket.emit(msg.event, msg.data);
  }
  
  pendingMessages.delete(`${userId}:${deviceId}`);
  logger.info('[SAFE_EMIT] All pending messages delivered to device');
  logger.debug(`[SAFE_EMIT] DeviceKey: ${deviceKey}`);
}

/**
 * Send Signal messages to all users in sharedWith list about update
 * Uses store-and-forward for offline users
 */
async function sendSharedWithUpdateSignal(fileId, sharedWith) {
  try {
    logger.info(`[SIGNAL] Sending sharedWith update to ${sharedWith.length} users`);
    logger.debug(`[SIGNAL] FileId: ${sanitizeForLog(fileId.substring(0, 8))}`);
    
    for (const userId of sharedWith) {
      try {
        // Get all devices for this user
        const clients = await Client.findAll({
          where: { owner: userId }
        });
        
        if (clients.length === 0) {
          logger.debug('[SIGNAL] No devices found for user');
          logger.debug(`[SIGNAL] User: ${sanitizeForLog(userId)}`);
          continue;
        }
        
        logger.info(`[SIGNAL] Found ${clients.length} devices for user`);
        logger.debug(`[SIGNAL] User: ${sanitizeForLog(userId)}`);
        
        // Send to each device
        for (const client of clients) {
          try {
            // Validate device_id exists
            if (!client.device_id) {
              logger.warn('[SIGNAL] Skipping client with missing device_id');
              logger.debug(`[SIGNAL] User: ${sanitizeForLog(userId)}`);
              continue;
            }
            
            const recipientDeviceId = client.device_id.toString();
            
            // Create Signal message payload
            const message = {
              type: 'file:sharedWith-update',
              fileId: fileId,
              sharedWith: sharedWith,
              timestamp: Date.now()
            };
            
            // Store message in database for offline delivery
            await writeQueue.enqueue(async () => {
              return await Item.create({
                sender: 'SYSTEM', // System message
                deviceSender: '0',
                receiver: userId,
                deviceReceiver: recipientDeviceId,
                type: 'file:sharedWith-update',
                payload: JSON.stringify(message),
                cipherType: 0, // Unencrypted system message
                itemId: `sharedWith-${fileId}-${Date.now()}`
              });
            }, `sharedWith-update-${userId}-${recipientDeviceId}-${Date.now()}`);
            
            logger.info('[SIGNAL] Message stored for user device');
            logger.debug(`[SIGNAL] User: ${sanitizeForLog(userId)}, Device: ${sanitizeForLog(recipientDeviceId)}`);
            
            // Try to deliver immediately if online
            const targetSocketId = deviceSockets.get(`${userId}:${recipientDeviceId}`);
            if (targetSocketId) {
              safeEmitToDevice(io, userId, recipientDeviceId, "receiveItem", {
                sender: 'SYSTEM',
                senderDeviceId: '0',
                recipient: userId,
                type: 'file:sharedWith-update',
                payload: JSON.stringify(message),
                cipherType: 0,
                itemId: `sharedWith-${fileId}-${Date.now()}`
              });
              logger.info('[SIGNAL] Delivered immediately to online device');
              logger.debug(`[SIGNAL] User: ${sanitizeForLog(userId)}, Device: ${sanitizeForLog(recipientDeviceId)}`);
            }
            
          } catch (err) {
            logger.error('[SIGNAL] Failed to send to device');
            logger.debug(`[SIGNAL] Device: ${sanitizeForLog(recipientDeviceId || 'unknown')}`, err);
          }
        }
        
      } catch (err) {
        logger.error('[SIGNAL] Failed to process user');
        logger.debug(`[SIGNAL] User: ${sanitizeForLog(userId)}`, err);
        // Continue with other users
      }
    }
    
    logger.info('[SIGNAL] Completed sending sharedWith updates');
    logger.debug(`[SIGNAL] FileId: ${sanitizeForLog(fileId.substring(0, 8))}`);
  } catch (error) {
    logger.error('[SIGNAL] Error in sendSharedWithUpdateSignal', error);
  }
}

// Configure session middleware with Sequelize store
// This prevents the MemoryStore warning in production
const sessionStore = new SequelizeStore({
    db: require('./db/model').sequelize,
    tableName: 'sessions',
    checkExpirationInterval: 15 * 60 * 1000, // Clean up expired sessions every 15 minutes
    expiration: 24 * 60 * 60 * 1000 // Session expires after 24 hours
});

const sessionMiddleware = session({
    secret: config.session.secret, // Replace with a strong secret key
    store: sessionStore,
    resave: config.session.resave,
    saveUninitialized: config.session.saveUninitialized,
    cookie: config.cookie // Set to true if using HTTPS
});

// Create the sessions table if it doesn't exist
sessionStore.sync();

// Use session middleware in Express
app.use(sessionMiddleware);

// ==================== RAW BODY CAPTURE ====================
// CRITICAL: Capture raw body BEFORE any route handlers
// This is required for HMAC signature verification in sessionAuth
// Must run before verifyAuthEither middleware
const bodyParser = require('body-parser');
app.use(bodyParser.json({
  limit: '50mb', // Increase limit for abuse reports with photos
  verify: (req, res, buf, encoding) => {
    // Store raw body buffer for HMAC signature calculation
    req.rawBody = buf;
  }
}));

// Registration step middleware - redirects to correct step based on session
app.use((req, res, next) => {
  // Only check for registration paths
  if (!req.path.startsWith('/register')) {
    return next();
  }

  // Skip API calls and static resources
  if (req.path.includes('.') || req.path.startsWith('/api/')) {
    return next();
  }

  const step = req.session.registrationStep;
  const currentPath = req.path;

  // Define step to path mapping
  const stepPaths = {
    'otp': '/register/otp',
    'backup_codes': '/register/backupcode',
    'webauthn': '/register/webauthn',
    'profile': '/register/profile',
    'complete': '/app'
  };

  // If no registration step, allow access to /register (start)
  if (!step && currentPath === '/register') {
    return next();
  }

  // If user has a registration step, redirect to correct page
  if (step && stepPaths[step]) {
    const correctPath = stepPaths[step];
    
    // If user is on wrong step page, serve correct step
    if (currentPath !== correctPath && currentPath.startsWith('/register/')) {
      logger.info(`[REGISTRATION] Redirecting to correct step: ${step}`);
      logger.debug(`[REGISTRATION] From: ${currentPath}, To: ${correctPath}`);
      // Return the correct step page instead
      req.url = correctPath;
      req.originalUrl = correctPath;
    }
  }

  next();
});


  const authRoutes = require('./routes/auth');
  const clientRoutes = require('./routes/client');
  const roleRoutes = require('./routes/roles');
  const groupItemRoutes = require('./routes/groupItems');
  const senderKeyRoutes = require('./routes/senderKeys');
  const livekitRoutes = require('./routes/livekit');
  const meetingRoutes = require('./routes/meetings');
  const callRoutes = require('./routes/calls');
  const presenceRoutes = require('./routes/presence');
  const blockReportRoutes = require('./routes/block_report');
  const pushRoutes = require('./routes/push');
  // External routes need io instance for notifications
  const createExternalRoutes = require('./routes/external');

  // Rate limiting middleware
  const { 
    apiLimiter, 
    authLimiter, 
    registrationLimiter, 
    passwordResetLimiter, 
    queryLimiter,
    fileLimiter 
  } = require('./middleware/rateLimiter');

  // Apply general rate limiting to all API routes (fallback)
  app.use('/api', apiLimiter);

  // === AUTHENTICATION & REGISTRATION (Strict) ===
  app.use('/login', authLimiter);
  app.use('/logout', authLimiter);
  app.use('/register', registrationLimiter);
  app.use('/otp', authLimiter);
  app.use('/webauthn/authenticate', authLimiter);
  app.use('/webauthn/authenticate-challenge', authLimiter);
  app.use('/backupcode/verify', authLimiter);
  
  // === PASSWORD RESET (Very Strict) ===
  app.use('/api/auth/reset-password', passwordResetLimiter);
  app.use('/api/auth/forgot-password', passwordResetLimiter);
  
  // === DATABASE QUERIES (Moderate) ===
  app.use('/api/presence', queryLimiter);
  app.use('/api/sender-keys', queryLimiter);
  app.use('/api/group-items', queryLimiter);
  app.use('/api/livekit/room', queryLimiter);
  
  // === MEETINGS & CALLS (Moderate for creation, lenient for reads) ===
  app.use('/api/meetings', (req, res, next) => {
    // Apply stricter limit to POST/PUT/DELETE, lenient for GET
    if (['POST', 'PUT', 'DELETE', 'PATCH'].includes(req.method)) {
      return apiLimiter(req, res, next);
    }
    next();
  });
  app.use('/api/calls', (req, res, next) => {
    if (['POST', 'PUT', 'DELETE'].includes(req.method)) {
      return apiLimiter(req, res, next);
    }
    next();
  });
  
  // === FILE OPERATIONS (Moderate) ===
  // Note: Socket.IO file sharing already has its own rate limiting
  // This covers any HTTP file endpoints if they exist
  
  // === EXTERNAL GUEST ENDPOINTS (Lenient but monitored) ===
  // External routes don't require auth, but still need rate limiting
  app.use('/api/meetings/external', apiLimiter);
  
  // === BLOCK & REPORT ENDPOINTS (Moderate) ===
  app.use('/api', blockReportRoutes);
  
  // === PUSH NOTIFICATION ENDPOINTS ===
  app.use('/api/push', pushRoutes);
  
  app.use(clientRoutes);
  app.use('/api', roleRoutes);
  app.use('/api/group-items', groupItemRoutes);
  app.use('/api/sender-keys', senderKeyRoutes);
  app.use('/api/livekit', livekitRoutes);
  app.use('/api', meetingRoutes);
  app.use('/api', callRoutes);
  app.use('/api', presenceRoutes);
  // Initialize external routes with io (will be set after Socket.IO is initialized)
  let externalRoutes;
  app.use('/api', (req, res, next) => {
    if (!externalRoutes && global.io) {
      externalRoutes = createExternalRoutes(global.io);
    }
    if (externalRoutes) {
      externalRoutes(req, res, next);
    } else {
      next();
    }
  });

  // Support subscription info endpoint
  app.get('/api/license-info', async (req, res) => {
    const license = await licenseValidator.validate();
    
    // Calculate unique active users from deviceSockets
    const activeUserIds = new Set();
    for (const [key] of deviceSockets.entries()) {
      const userId = key.split(':')[0]; // Extract userId from "userId:deviceId"
      activeUserIds.add(userId);
    }
    const activeUserCount = activeUserIds.size;
    
    // Check if subscription is expired
    if (license.error === 'EXPIRED') {
      return res.json({
        type: 'commercial',
        showNotice: true,
        message: 'Support subscription expired • Visit https://peerwave.org',
        isError: true
      });
    }
    
    if (license.valid) {
      // Check if subscription has maxUsers limit and if it's exceeded
      const maxUsers = license.features?.maxUsers;
      const isExceeded = maxUsers && activeUserCount > maxUsers;
      
      // Supported Edition (commercial subscription)
      if (license.type === 'commercial') {
        if (isExceeded) {
          // Show error message for exceeded subscription limit
          return res.json({
            type: 'commercial',
            showNotice: true,
            message: `User limit exceeded (${activeUserCount}/${maxUsers}) • Contact support`,
            isError: true,
            expires: license.expires,
            maxUsers: maxUsers,
            activeUsers: activeUserCount,
            gracePeriodDays: license.features?.gracePeriodDays || 30
          });
        } else {
          // Valid support subscription - hide footer but send data for settings page
          return res.json({
            type: 'commercial',
            showNotice: false,
            message: '',
            isError: false,
            expires: license.expires,
            maxUsers: maxUsers,
            activeUsers: activeUserCount,
            gracePeriodDays: license.features?.gracePeriodDays || 30
          });
        }
      }
      
      // Legacy non-commercial license (should not occur with AGPL-3.0)
      return res.json({
        type: 'community',
        showNotice: true,
        message: 'AGPL-3.0 • Community Edition • No Professional Support',
        isError: false
      });
    } else {
      // No subscription - Community Edition (AGPL-3.0)
      res.json({
        type: 'community',
        showNotice: true,
        message: 'AGPL-3.0 • Community Edition • No Professional Support',
        isError: false
      });
    }
  });

  // Public meeting join page - auth check and Flutter web serving
  app.get('/join/meeting/:token', async (req, res) => {
    const { token } = req.params;
    
    // Validate token format (32 char UUID without dashes)
    if (!token || token.length !== 32) {
      return res.status(400).send(`
        <!DOCTYPE html>
        <html>
        <head>
          <title>Invalid Link - PeerWave</title>
          <style>
            body { font-family: Arial, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #f5f5f5; }
            .container { text-align: center; padding: 40px; background: white; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
            h1 { color: #d32f2f; }
          </style>
        </head>
        <body>
          <div class="container">
            <h1>Invalid Meeting Link</h1>
            <p>The meeting link you're trying to access is invalid.</p>
          </div>
        </body>
        </html>
      `);
    }

    // Check if user is authenticated
    const hasSessionHeaders = req.headers['x-client-id'] && req.headers['x-signature'];
    const hasWebSession = req.session && req.session.uuid;
    
    if (hasSessionHeaders || hasWebSession) {
      // Authenticated user - redirect to meetings overview
      logger.info('[Guest Join] Authenticated user detected, redirecting to /app/meetings');
      return res.redirect('/app/meetings');
    }

    // Unauthenticated user - serve Flutter web app
    logger.info('[Guest Join] Guest user detected, serving Flutter web app');
    logger.debug(`[Guest Join] Token: ${token}`);
    const flutterWebPath = path.join(__dirname, '../client/build/web/index.html');
    res.sendFile(flutterWebPath, (err) => {
      if (err) {
        logger.error('[Guest Join] Failed to serve Flutter web app', err);
        res.status(500).send(`
          <!DOCTYPE html>
          <html>
          <head>
            <title>Error - PeerWave</title>
            <style>
              body { font-family: Arial, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #f5f5f5; }
              .container { text-align: center; padding: 40px; background: white; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
              h1 { color: #d32f2f; }
              p { color: #666; margin-top: 10px; }
            </style>
          </head>
          <body>
            <div class="container">
              <h1>Service Unavailable</h1>
              <p>Flutter web app not found. Please build the client first:</p>
              <code style="background: #f5f5f5; padding: 8px; border-radius: 4px; display: inline-block; margin-top: 10px;">cd client && flutter build web</code>
            </div>
          </body>
          </html>
        `);
      }
    });
  });

  //SOCKET.IO
const rooms = {};
const port = config.port || 3000;

const server = http.createServer(app);
const io = require("socket.io")(server);

// Make io globally available for routes that need it (e.g., external guest notifications)
global.io = io;

io.use(sharedSession(sessionMiddleware, { autoSave: true }));

// Initialize external guest namespace for unauthenticated guest connections
const initializeExternalNamespace = require('./namespaces/external');
initializeExternalNamespace(io);
logger.info('[SERVER] External guest namespace initialized');

const deviceSockets = new Map(); // Key: userId:deviceId, Value: socket.id

// Make deviceSockets globally available for guest message routing
global.deviceSockets = deviceSockets;

// ============================================
// VIDEO CONFERENCE PARTICIPANT TRACKING (RAM)
// ============================================

/**
 * In-Memory Storage für aktive WebRTC Channel Participants
 * Structure: Map<channelId, Set<ParticipantInfo>>
 * 
 * ParticipantInfo: {
 *   userId: string,
 *   socketId: string,
 *   joinedAt: number (timestamp),
 *   hasE2EEKey: boolean
 * }
 * 
 * Cleanup: Automatic on disconnect, manual on leave
 */
const activeVideoParticipants = new Map();

/**
 * Add participant to active participants list
 */
function addVideoParticipant(channelId, userId, socketId) {
    if (!activeVideoParticipants.has(channelId)) {
        activeVideoParticipants.set(channelId, new Set());
    }
    
    const participants = activeVideoParticipants.get(channelId);
    
    // Remove existing entry for this user (if reconnecting)
    participants.forEach(p => {
        if (p.userId === userId) participants.delete(p);
    });
    
    // Add new entry
    participants.add({
        userId,
        socketId,
        joinedAt: Date.now(),
        hasE2EEKey: false
    });
    
    logger.info(`[VIDEO PARTICIPANTS] Added user to channel (total: ${participants.size})`);
    logger.debug(`[VIDEO PARTICIPANTS] User: ${sanitizeForLog(userId)}, Channel: ${sanitizeForLog(channelId)}`);
}

/**
 * Remove participant from active participants list
 */
function removeVideoParticipant(channelId, socketId) {
    if (!activeVideoParticipants.has(channelId)) return;
    
    const participants = activeVideoParticipants.get(channelId);
    let removedUserId = null;
    
    participants.forEach(p => {
        if (p.socketId === socketId) {
            removedUserId = p.userId;
            participants.delete(p);
        }
    });
    
    // Cleanup empty channels
    if (participants.size === 0) {
        activeVideoParticipants.delete(channelId);
        logger.info('[VIDEO PARTICIPANTS] Channel empty - removed from tracking');
        logger.debug(`[VIDEO PARTICIPANTS] Channel: ${sanitizeForLog(channelId)}`);
    } else if (removedUserId) {
        logger.info(`[VIDEO PARTICIPANTS] Removed user from channel (remaining: ${participants.size})`);
        logger.debug(`[VIDEO PARTICIPANTS] User: ${sanitizeForLog(removedUserId)}, Channel: ${sanitizeForLog(channelId)}`);
    }
}

/**
 * Get all participants for a channel
 */
function getVideoParticipants(channelId) {
    if (!activeVideoParticipants.has(channelId)) {
        return [];
    }
    return Array.from(activeVideoParticipants.get(channelId));
}

/**
 * Update participant E2EE key status
 */
function updateParticipantKeyStatus(channelId, socketId, hasKey) {
    if (!activeVideoParticipants.has(channelId)) return;
    
    const participants = activeVideoParticipants.get(channelId);
    participants.forEach(p => {
        if (p.socketId === socketId) {
            p.hasE2EEKey = hasKey;
            logger.info(`[VIDEO PARTICIPANTS] Updated user key status: ${hasKey}`);
            logger.debug(`[VIDEO PARTICIPANTS] User: ${sanitizeForLog(p.userId)}`);
        }
    });
}

io.sockets.on("error", e => logger.error('[SOCKET.IO] Error', e));
io.sockets.on("connection", socket => {

  logger.info('[SOCKET.IO] New connection attempt', { 
    socketId: socket.id,
    hasSession: !!socket.handshake.session,
    sessionUuid: socket.handshake.session?.uuid,
    sessionDeviceId: socket.handshake.session?.deviceId,
    sessionAuth: socket.handshake.session?.authenticated
  });

  // 🔒 Track client ready state (prevents sending events before client is initialized)
  socket.clientReady = false;

  // Helper function to get userId from either native (HMAC) or web (session) auth
  const getUserId = () => socket.data.userId || socket.handshake.session.uuid;
  const getDeviceId = () => socket.data.deviceId || socket.handshake.session.deviceId;
  const getClientId = () => socket.data.clientId || socket.handshake.session.clientId;
  const isAuthenticated = () => socket.data.sessionAuth || socket.handshake.session.authenticated === true;

  // Service imports for meetings & calls
  const meetingService = require('./services/meetingService');
  const presenceService = require('./services/presenceService');
  const externalParticipantService = require('./services/externalParticipantService');
  const meetingCleanupService = require('./services/meetingCleanupService');

  socket.on("authenticate", async (authData) => {
    logger.info('[SOCKET.IO] Authenticate event received', {
      hasAuthData: !!authData,
      authDataType: typeof authData
    });
    // Support both cookie-based (web) and HMAC-based (native) authentication
    try {
      logger.info('[SIGNAL SERVER] authenticate event received');
      
      // Check if HMAC authentication headers are present (native client)
      if (authData && typeof authData === 'object' && authData['X-Client-ID'] && authData['X-Signature']) {
        logger.info('[SIGNAL SERVER] Native client detected, using HMAC auth');
        
        const clientId = authData['X-Client-ID'];
        const timestamp = parseInt(authData['X-Timestamp']);
        const nonce = authData['X-Nonce'];
        const signature = authData['X-Signature'];
        
        // Verify timestamp (±5 minutes)
        const now = Date.now();
        const maxDiff = 5 * 60 * 1000;
        if (Math.abs(now - timestamp) > maxDiff) {
          logger.warn('[SIGNAL SERVER] HMAC auth failed: timestamp expired');
          return socket.emit("authenticated", { authenticated: false, error: 'timestamp_expired' });
        }
        
        // Check nonce
        const { sequelize } = require('./db/model');
        const [nonceCheck] = await sequelize.query(
          'SELECT 1 FROM nonce_cache WHERE nonce = ?',
          { replacements: [nonce] }
        );
        
        if (nonceCheck && nonceCheck.length > 0) {
          logger.warn('[SIGNAL SERVER] HMAC auth failed: duplicate nonce');
          return socket.emit("authenticated", { authenticated: false, error: 'duplicate_nonce' });
        }
        
        await sequelize.query(
          'INSERT INTO nonce_cache (nonce, created_at) VALUES (?, datetime("now"))',
          { replacements: [nonce] }
        );
        
        // Get session
        const [sessions] = await sequelize.query(
          'SELECT session_secret, user_id, expires_at FROM client_sessions WHERE client_id = ?',
          { replacements: [clientId] }
        );
        
        if (!sessions || sessions.length === 0) {
          logger.warn('[SIGNAL SERVER] HMAC auth failed: no session');
          return socket.emit("authenticated", { authenticated: false, error: 'no_session' });
        }
        
        const session = sessions[0];
        
        // Verify signature
        const crypto = require('crypto');
        const message = `${clientId}:${timestamp}:${nonce}:/socket.io/auth:`;
        const expectedSignature = crypto
          .createHmac('sha256', session.session_secret)
          .update(message)
          .digest('hex');
        
        if (signature !== expectedSignature) {
          logger.warn('[SIGNAL SERVER] HMAC auth failed: invalid signature');
          return socket.emit("authenticated", { authenticated: false, error: 'invalid_signature' });
        }
        
        // Get client info
        const { Client } = require('./db/model');
        const client = await Client.findOne({ where: { clientid: clientId } });
        
        if (!client) {
          logger.warn('[SIGNAL SERVER] HMAC auth failed: client not found');
          return socket.emit("authenticated", { authenticated: false, error: 'client_not_found' });
        }
        
        // Authentication successful for native client
        const deviceKey = `${session.user_id}:${client.device_id}`;
        const existingSocketId = deviceSockets.get(deviceKey);
        if (existingSocketId && existingSocketId !== socket.id) {
          logger.warn('[SIGNAL SERVER] Replacing existing socket for device (native)');
          logger.debug(`[SIGNAL SERVER] DeviceKey: ${deviceKey}`);
        }
        
        deviceSockets.set(deviceKey, socket.id);
        socket.data.userId = session.user_id;
        socket.data.deviceId = client.device_id;
        socket.data.clientId = clientId;
        socket.data.sessionAuth = true;
        
        // CRITICAL: Also set socket.handshake.session for compatibility with event handlers
        // Many handlers check socket.handshake.session.authenticated
        socket.handshake.session.uuid = session.user_id;
        socket.handshake.session.deviceId = client.device_id;
        socket.handshake.session.clientId = clientId;
        socket.handshake.session.authenticated = true;
        
        logger.info('[SIGNAL SERVER] Native client authenticated');
        logger.debug(`[SIGNAL SERVER] DeviceKey: ${deviceKey}`);
        logger.info(`[SIGNAL SERVER] ✅ Socket registered in deviceSockets - deviceKey: ${deviceKey}, socketId: ${socket.id}`);
        
        // Register user as online in presence service
        presenceService.onSocketConnected(session.user_id, socket.id).then(status => {
          logger.info(`[PRESENCE] User connected with status: ${status}`);
          logger.debug(`[PRESENCE] User: ${session.user_id}`);
          // Broadcast online status to other users
          socket.broadcast.emit('presence:update', {
            user_id: session.user_id,
            status: status,
            last_seen: new Date()
          });
          logger.info('[PRESENCE] Broadcasted presence:update');
          logger.debug(`[PRESENCE] User: ${session.user_id}`);
        }).catch(err => {
          logger.error('[PRESENCE] Error registering socket connection', err);
        });
        
        return socket.emit("authenticated", { 
          authenticated: true,
          uuid: session.user_id,
          deviceId: client.device_id,
          clientId: clientId
        });
      }
      
      // Fall back to cookie-based authentication (web client)
      logger.info('[SIGNAL SERVER] Web client detected, using cookie auth');
      logger.debug('[SIGNAL SERVER] Session check:', {
        hasUuid: !!socket.handshake.session?.uuid,
        hasEmail: !!socket.handshake.session?.email,
        hasDeviceId: !!socket.handshake.session?.deviceId,
        authenticated: socket.handshake.session?.authenticated
      });
      
      if(socket.handshake.session.uuid && socket.handshake.session.email && socket.handshake.session.deviceId && socket.handshake.session.clientId && socket.handshake.session.authenticated === true) {
        const deviceKey = `${socket.handshake.session.uuid}:${socket.handshake.session.deviceId}`;
        
        // Check if this device already has a socket connection (stale or duplicate)
        const existingSocketId = deviceSockets.get(deviceKey);
        if (existingSocketId && existingSocketId !== socket.id) {
            logger.warn('[SIGNAL SERVER] Replacing existing socket for device');
            logger.debug(`[SIGNAL SERVER] DeviceKey: ${deviceKey}`);
            logger.debug(`[SIGNAL SERVER] Old socket: ${existingSocketId}, New socket: ${socket.id}`);
            logger.debug('[SIGNAL SERVER] Reason: Browser refresh or network reconnection');
        }
        
        deviceSockets.set(deviceKey, socket.id);
        logger.info(`[SIGNAL SERVER] Device registered (Total online: ${deviceSockets.size})`);
        logger.debug(`[SIGNAL SERVER] DeviceKey: ${deviceKey}, Socket: ${socket.id}`);
        logger.info(`[SIGNAL SERVER] ✅ Socket registered in deviceSockets - deviceKey: ${deviceKey}, socketId: ${socket.id}`);
        
        // Store userId in socket.data for video conferencing
        socket.data.userId = socket.handshake.session.uuid;
        socket.data.deviceId = socket.handshake.session.deviceId;
        
        // Register user as online in presence service
        presenceService.onSocketConnected(socket.handshake.session.uuid, socket.id).then(status => {
          logger.info(`[PRESENCE] User connected with status: ${status}`);
          logger.debug(`[PRESENCE] User: ${socket.handshake.session.uuid}`);
          // Broadcast online status to other users
          socket.broadcast.emit('presence:update', {
            user_id: socket.handshake.session.uuid,
            status: status,
            last_seen: new Date()
          });
          logger.info('[PRESENCE] Broadcasted presence:update');
          logger.debug(`[PRESENCE] User: ${socket.handshake.session.uuid}`);
        }).catch(err => {
          logger.error('[PRESENCE] Error registering socket connection', err);
        });
        
        socket.emit("authenticated", { 
          authenticated: true,
          uuid: socket.handshake.session.uuid,
          deviceId: socket.handshake.session.deviceId
        });
      } else {
        logger.warn('[SIGNAL SERVER] Authentication failed - missing session data');
        socket.emit("authenticated", { authenticated: false });
      }
    } catch (error) {
      logger.error('[SIGNAL SERVER] Error during authentication', error);
      socket.emit("authenticated", { authenticated: false });
    }
  });

  // 🚀 NEW: Client ready notification
  // Client signals that PreKeys are generated and listeners are registered
  socket.on("clientReady", async (data) => {
    const userId = getUserId();
    const deviceId = getDeviceId();
    const deviceKey = `${userId}:${deviceId}`;
    const socketInMap = deviceSockets.get(deviceKey);
    
    logger.info('[SIGNAL SERVER] Client ready notification received');
    logger.debug('[SIGNAL SERVER] Data:', data);
    logger.info(`[SIGNAL SERVER] 🔍 clientReady check - userId: ${userId}, deviceId: ${deviceId}, deviceKey: ${deviceKey}`);
    logger.info(`[SIGNAL SERVER] 🔍 Socket in deviceSockets? ${socketInMap === socket.id ? 'YES' : 'NO'} (expected: ${socket.id}, found: ${socketInMap || 'NOT FOUND'})`);
    
    socket.clientReady = true;
    logger.info(`[SIGNAL SERVER] Socket marked as ready for events`);
    logger.debug(`[SIGNAL SERVER] Socket: ${socket.id}`);
    
    // 🚀 Flush any pending messages that were queued while client was initializing
    if (isAuthenticated()) {
      const userId = getUserId();
      const deviceId = getDeviceId();
      flushPendingMessages(io, socket, userId, deviceId);
    }
    
    // ✅ Check for pending messages and notify client
    try {
      if (isAuthenticated()) {
        const userId = getUserId();
        const deviceId = getDeviceId();
        
        // COUNT query (fast, even with thousands of messages)
        const pendingCount = await Item.count({
          where: {
            receiver: userId,
            deviceReceiver: deviceId
          }
        });
        
        if (pendingCount > 0) {
          logger.info(`[SIGNAL SERVER] ${pendingCount} pending messages for user`);
          logger.debug(`[SIGNAL SERVER] User: ${sanitizeForLog(userId)}, Device: ${sanitizeForLog(deviceId)}`);
          socket.emit("pendingMessagesAvailable", {
            count: pendingCount,
            timestamp: new Date().toISOString()
          });
        } else {
          logger.debug('[SIGNAL SERVER] No pending messages for user');
          logger.debug(`[SIGNAL SERVER] User: ${sanitizeForLog(userId)}, Device: ${sanitizeForLog(deviceId)}`);
        }
      }
    } catch (error) {
      logger.error('[SIGNAL SERVER] Error checking pending messages', error);
    }
  });

  // 🚀 NEW: Fetch pending messages with pagination
  socket.on("fetchPendingMessages", async (data) => {
    try {
      if (!isAuthenticated()) {
        logger.error('[SIGNAL SERVER] fetchPendingMessages blocked - not authenticated');
        socket.emit("fetchPendingMessagesError", { error: 'Not authenticated' });
        return;
      }

      const userId = getUserId();
      const deviceId = getDeviceId();
      const { limit = 20, offset = 0 } = data;

      logger.info(`[SIGNAL SERVER] Fetching pending messages: limit=${limit}, offset=${offset}`);
      logger.debug(`[SIGNAL SERVER] User: ${sanitizeForLog(userId)}, Device: ${sanitizeForLog(deviceId)}`);

      // Fetch messages with pagination
      const items = await Item.findAll({
        where: {
          receiver: userId,
          deviceReceiver: deviceId
        },
        limit,
        offset,
        order: [['createdAt', 'ASC']] // Oldest first (chronological order)
      });

      const hasMore = items.length === limit;

      logger.info(`[SIGNAL SERVER] Found ${items.length} pending messages (hasMore: ${hasMore})`);

      // Send response
      socket.emit("pendingMessagesResponse", {
        items: items.map(item => ({
          sender: item.sender,
          senderDeviceId: item.deviceSender,
          recipient: item.receiver,
          type: item.type,
          payload: item.payload,
          cipherType: item.cipherType,
          itemId: item.itemId
        })),
        hasMore,
        offset,
        total: items.length
      });

    } catch (error) {
      logger.error('[SIGNAL SERVER] Error fetching pending messages', error);
      socket.emit("fetchPendingMessagesError", { error: error.message });
    }
  });

  // SIGNAL HANDLE START

  socket.on("signalIdentity", async (data) => {
    logger.info('[SIGNAL SERVER] signalIdentity event received');
    logger.debug('[SIGNAL SERVER] Session check:', {
      authenticated: isAuthenticated(),
      hasUuid: !!socket.handshake.session?.uuid
    });
    try {
      if(isAuthenticated()) {
        const userId = getUserId();
        const clientId = getClientId();
        // Handle the signal identity - enqueue write operation
        await writeQueue.enqueue(async () => {
          return await Client.update(
            { public_key: data.publicKey, registration_id: data.registrationId },
            { where: { owner: userId, clientid: clientId } }
          );
        }, 'signalIdentity');
      }
    } catch (error) {
      logger.error('Error handling signal identity:', error);
    }
  });

  socket.on("getSignedPreKeys", async () => {
    try {
      if(isAuthenticated()) {
        const userId = getUserId();
        const clientId = getClientId();
        // Fetch signed pre-keys from the database
        const signedPreKeys = await SignalSignedPreKey.findAll({
          where: { owner: userId, client: clientId },
          order: [['createdAt', 'DESC']]
        });
        socket.emit("getSignedPreKeysResponse", signedPreKeys);
      }
    } catch (error) {
      logger.error('Error fetching signed pre-keys:', error);
      socket.emit("getSignedPreKeysResponse", { error: 'Failed to fetch signed pre-keys' });
    }
  });

  socket.on("removePreKey", async (data) => {
    try {
      if(isAuthenticated()) {
        const userId = getUserId();
        const clientId = getClientId();
        await writeQueue.enqueue(async () => {
          return await SignalPreKey.destroy({
            where: { prekey_id: data.id, owner: userId, client: clientId }
          });
        }, `removePreKey-${data.id}`);
      }
    } catch (error) {
      logger.error('Error removing pre-key:', error);
    }
  });

  socket.on("removeSignedPreKey", async (data) => {
    try {
      if(isAuthenticated()) {
        const userId = getUserId();
        const clientId = getClientId();
        await writeQueue.enqueue(async () => {
          return await SignalSignedPreKey.destroy({
            where: { signed_prekey_id: data.id, owner: userId, client: clientId }
          });
        }, `removeSignedPreKey-${data.id}`);
      }
    } catch (error) {
      logger.error('Error removing signed pre-key:', error);
    }
  });

  // CRITICAL: Delete ALL Signal keys for current device (when IdentityKeyPair is regenerated)
  socket.on("deleteAllSignalKeys", async (data) => {
    logger.info('[SIGNAL SERVER] deleteAllSignalKeys event received');
    logger.debug('[SIGNAL SERVER] deleteAllSignalKeys data:', { data: sanitizeForLog(data) });
    try {
      if(isAuthenticated()) {
        const uuid = getUserId();
        const clientId = getClientId();
        const reason = data.reason || 'Unknown';
        const timestamp = data.timestamp || new Date().toISOString();
        
        logger.warn('[SIGNAL SERVER] CRITICAL: Deleting ALL Signal keys');
        logger.debug('[SIGNAL SERVER] Key deletion details:', { 
          userId: sanitizeForLog(uuid), 
          clientId: sanitizeForLog(clientId),
          reason: sanitizeForLog(reason), 
          timestamp 
        });
        
        let deletedPreKeys = 0;
        let deletedSignedPreKeys = 0;
        let deletedSenderKeys = 0;
        
        // 1. Delete all PreKeys
        try {
          deletedPreKeys = await writeQueue.enqueue(async () => {
            return await SignalPreKey.destroy({
              where: { owner: uuid, client: clientId }
            });
          }, `deleteAllPreKeys-${clientId}`);
          logger.info(`[SIGNAL SERVER] Deleted ${deletedPreKeys} PreKeys`);
        } catch (error) {
          logger.error('[SIGNAL SERVER] Error deleting PreKeys:', error);
        }
        
        // 2. Delete all SignedPreKeys
        try {
          deletedSignedPreKeys = await writeQueue.enqueue(async () => {
            return await SignalSignedPreKey.destroy({
              where: { owner: uuid, client: clientId }
            });
          }, `deleteAllSignedPreKeys-${clientId}`);
          logger.info(`[SIGNAL SERVER] Deleted ${deletedSignedPreKeys} SignedPreKeys`);
        } catch (error) {
          logger.error('[SIGNAL SERVER] Error deleting SignedPreKeys:', error);
        }
        
        // 3. Delete all SenderKeys
        try {
          deletedSenderKeys = await writeQueue.enqueue(async () => {
            return await SignalSenderKey.destroy({
              where: { owner: uuid, client: clientId }
            });
          }, `deleteAllSenderKeys-${clientId}`);
          logger.info(`[SIGNAL SERVER] Deleted ${deletedSenderKeys} SenderKeys`);
        } catch (error) {
          logger.error('[SIGNAL SERVER] Error deleting SenderKeys:', error);
        }
        
        logger.info('[SIGNAL SERVER] Cascade delete completed', {
          preKeys: deletedPreKeys,
          signedPreKeys: deletedSignedPreKeys,
          senderKeys: deletedSenderKeys
        });
        
        // Send confirmation to client
        socket.emit("deleteAllSignalKeysResponse", {
          success: true,
          deletedPreKeys,
          deletedSignedPreKeys,
          deletedSenderKeys,
          reason,
          timestamp
        });
      } else {
        logger.error('[SIGNAL SERVER] ERROR: deleteAllSignalKeys blocked - not authenticated');
        socket.emit("deleteAllSignalKeysResponse", { 
          success: false, 
          error: 'Not authenticated' 
        });
      }
    } catch (error) {
      logger.error('[SIGNAL SERVER] Error in deleteAllSignalKeys:', error);
      socket.emit("deleteAllSignalKeysResponse", { 
        success: false, 
        error: error.message 
      });
    }
  });

  socket.on("storeSignedPreKey", async (data) => {
    try {
      if(isAuthenticated()) {
        const userId = getUserId();
        const clientId = getClientId();
        // Create if not exists, otherwise do nothing - enqueue write operation
        await writeQueue.enqueue(async () => {
          return await SignalSignedPreKey.findOrCreate({
            where: {
              signed_prekey_id: data.id,
              owner: userId,
              client: clientId,
            },
            defaults: {
              signed_prekey_data: data.data,
              signed_prekey_signature: data.signature,
            }
          });
        }, `storeSignedPreKey-${data.id}`);
      }
    } catch (error) {
      logger.error('Error storing signed pre-key:', error);
    }
  });

  socket.on("storePreKey", async (data) => {
    try {
      if(isAuthenticated()) {
        const userId = getUserId();
        const clientId = getClientId();
        // Only store if prekey_data is a 33-byte base64-encoded public key
        let decoded;
        try {
          decoded = Buffer.from(data.data, 'base64');
        } catch (e) {
          logger.error('[SIGNAL SERVER] Invalid base64 in prekey_data');
          return;
        }
        if (decoded.length !== 33) {
          logger.error(`[SIGNAL SERVER] Refusing to store pre-key: prekey_data is ${decoded.length} bytes (expected 33). Possible private key leak or wrong format.`);
          return;
        }
        await writeQueue.enqueue(async () => {
          return await SignalPreKey.findOrCreate({
            where: {
              prekey_id: data.id,
              owner: userId,
              client: clientId,
            },
            defaults: {
              prekey_data: data.data,
            }
          });
        }, `storePreKey-${data.id}`);
      }
    } catch (error) {
      logger.error('Error storing pre-key:', error);
      logger.debug('[SIGNAL SERVER] storePreKey event data:', { data: sanitizeForLog(data) });
      logger.debug('[SIGNAL SERVER] Session:', { session: socket.handshake.session });
    }
  });

  // Batch store pre-keys
  socket.on("storePreKeys", async (data) => {
    // ACCEPT BOTH FORMATS:
    // NEW: { preKeys: [ { id, data }, ... ] }
    // OLD: [ { id, data }, ... ] (direct array for backwards compatibility)
    try {
      if(isAuthenticated()) {
        const userId = getUserId();
        const clientId = getClientId();
        // Handle both formats: direct array or wrapped in { preKeys: ... }
        const preKeysArray = Array.isArray(data) ? data : (Array.isArray(data.preKeys) ? data.preKeys : null);
        
        if (preKeysArray) {
          logger.info(`[SIGNAL SERVER] Receiving ${preKeysArray.length} PreKeys for batch storage`);
          
          // Enqueue entire batch as a single operation to maintain atomicity
          await writeQueue.enqueue(async () => {
            const results = [];
            for (const preKey of preKeysArray) {
              if (preKey && preKey.id && preKey.data) {
                let decoded;
                try {
                  decoded = Buffer.from(preKey.data, 'base64');
                } catch (e) {
                  logger.error('[SIGNAL SERVER] Invalid base64 in batch prekey_data');
                  continue;
                }
                if (decoded.length !== 33) {
                  logger.error(`[SIGNAL SERVER] Refusing to store batch pre-key: prekey_data is ${decoded.length} bytes (expected 33). Possible private key leak or wrong format. id=${preKey.id}`);
                  continue;
                }
                const result = await SignalPreKey.findOrCreate({
                  where: {
                    prekey_id: preKey.id,
                    owner: userId,
                    client: clientId,
                  },
                  defaults: {
                    prekey_data: preKey.data,
                  }
                });
                results.push(result);
              }
            }
            logger.info(`[SIGNAL SERVER] Successfully stored ${results.length} PreKeys`);
            return results;
          }, `storePreKeys-batch-${preKeysArray.length}`);
          
          // CRITICAL: After storage, return ALL PreKey IDs from server for sync verification
          const allServerPreKeys = await SignalPreKey.findAll({
            where: { 
              owner: userId, 
              client: clientId 
            },
            attributes: ['prekey_id']
          });
          
          const serverPreKeyIds = allServerPreKeys.map(pk => pk.prekey_id);
          logger.info(`[SIGNAL SERVER] Sending sync response with ${serverPreKeyIds.length} PreKey IDs`);
          
          // Send back server's PreKey IDs for client to verify sync
          socket.emit("storePreKeysResponse", {
            success: true,
            serverPreKeyIds: serverPreKeyIds,
            count: serverPreKeyIds.length
          });
          
        } else {
          logger.error('[SIGNAL SERVER] storePreKeys: Invalid data format - expected array or { preKeys: array }');
          socket.emit("storePreKeysResponse", {
            success: false,
            error: 'Invalid data format'
          });
        }
      }
    } catch (error) {
      logger.error('Error storing pre-keys (batch):', error);
      logger.debug('[SIGNAL SERVER] storePreKeys event data:', { data: sanitizeForLog(data) });
      logger.debug('[SIGNAL SERVER] Session:', { session: socket.handshake.session });
      socket.emit("storePreKeysResponse", {
        success: false,
        error: error.message
      });
    }
  });

  // Signal status summary for current device
  socket.on("signalStatus", async (_) => {
    try {
      if(isAuthenticated()) {
        const userId = getUserId();
        const clientId = getClientId();
        
        logger.info('[SIGNAL SERVER] signalStatus request received');
        logger.debug('[SIGNAL SERVER] signalStatus details:', { userId: sanitizeForLog(userId), clientId: sanitizeForLog(clientId) });
        
        // Identity: check if public_key and registration_id are present
        const client = await Client.findOne({
          where: { owner: userId, clientid: clientId }
        });
        const identityPresent = !!(client && client.public_key && client.registration_id);

        // PreKeys: count
        const preKeysCount = await SignalPreKey.count({
          where: { owner: userId, client: clientId }
        });
        logger.info('[SIGNAL SERVER] signalStatus: PreKeys count retrieved');
        logger.debug('[SIGNAL SERVER] PreKeys details:', { userId: sanitizeForLog(userId), clientId: sanitizeForLog(clientId), count: preKeysCount });

        // SignedPreKey: latest
        const signedPreKey = await SignalSignedPreKey.findOne({
          where: { owner: userId, client: clientId },
          order: [['createdAt', 'DESC']]
        });
        let signedPreKeyStatus = null;
        if (signedPreKey) {
          signedPreKeyStatus = {
            id: signedPreKey.signed_prekey_id,
            createdAt: signedPreKey.createdAt,
            signed_prekey_data: signedPreKey.signed_prekey_data,
            signed_prekey_signature: signedPreKey.signed_prekey_signature
          };
        }

        const status = {
          identity: identityPresent,
          identityPublicKey: client ? client.public_key : null, // ← NEW: Send public key for validation
          preKeys: preKeysCount,
          signedPreKey: signedPreKeyStatus
        };
        socket.emit("signalStatusResponse", status);
      }
      else {
        socket.emit("signalStatusResponse", { error: 'Not authenticated' });
      }
    } catch (error) {
      logger.error('Error in signalStatus:', error);
      socket.emit("signalStatusResponse", { error: 'Failed to get signal status' });
    }
  });

  // Troubleshoot: Rotate SignedPreKey (force rotation even if not expired)
  socket.on("rotateSignedPreKey", async () => {
    try {
      if (isAuthenticated()) {
        const userId = getUserId();
        const clientId = getClientId();

        logger.info('[SIGNAL SERVER] rotateSignedPreKey request received');
        logger.debug('[SIGNAL SERVER] Rotation details:', { userId: sanitizeForLog(userId), clientId: sanitizeForLog(clientId) });

        // Delete current SignedPreKey to force client regeneration
        const deletedCount = await writeQueue.enqueue(async () => {
          return await SignalSignedPreKey.destroy({
            where: { owner: userId, client: clientId }
          });
        }, `rotateSignedPreKey-${clientId}`);

        logger.info(`[SIGNAL SERVER] Deleted ${deletedCount} SignedPreKey(s), client will regenerate`);
        socket.emit("rotateSignedPreKeyResponse", { success: true, deletedCount });
      } else {
        socket.emit("rotateSignedPreKeyResponse", { error: 'Not authenticated' });
      }
    } catch (error) {
      logger.error('[SIGNAL SERVER] Error rotating SignedPreKey:', error);
      socket.emit("rotateSignedPreKeyResponse", { error: 'Failed to rotate SignedPreKey' });
    }
  });

  // Troubleshoot: Delete and regenerate SignedPreKey
  socket.on("deleteAndRegenerateSignedPreKey", async () => {
    try {
      if (isAuthenticated()) {
        const userId = getUserId();
        const clientId = getClientId();

        logger.info('[SIGNAL SERVER] deleteAndRegenerateSignedPreKey request received');
        logger.debug('[SIGNAL SERVER] Deletion details:', { userId: sanitizeForLog(userId), clientId: sanitizeForLog(clientId) });

        // Delete all SignedPreKeys for this client
        const deletedCount = await writeQueue.enqueue(async () => {
          return await SignalSignedPreKey.destroy({
            where: { owner: userId, client: clientId }
          });
        }, `deleteSignedPreKey-${clientId}`);

        logger.info(`[SIGNAL SERVER] Deleted ${deletedCount} SignedPreKey(s)`);
        socket.emit("deleteAndRegenerateSignedPreKeyResponse", { success: true, deletedCount });
      } else {
        socket.emit("deleteAndRegenerateSignedPreKeyResponse", { error: 'Not authenticated' });
      }
    } catch (error) {
      logger.error('[SIGNAL SERVER] Error deleting SignedPreKey:', error);
      socket.emit("deleteAndRegenerateSignedPreKeyResponse", { error: 'Failed to delete SignedPreKey' });
    }
  });

  // Troubleshoot: Delete all PreKeys (forces regeneration)
  socket.on("deleteAllPreKeys", async () => {
    try {
      if (isAuthenticated()) {
        const userId = getUserId();
        const clientId = getClientId();

        logger.info('[SIGNAL SERVER] deleteAllPreKeys request received');
        logger.debug('[SIGNAL SERVER] Deletion details:', { userId: sanitizeForLog(userId), clientId: sanitizeForLog(clientId) });

        // Delete all PreKeys for this client
        const deletedCount = await writeQueue.enqueue(async () => {
          return await SignalPreKey.destroy({
            where: { owner: userId, client: clientId }
          });
        }, `deleteAllPreKeys-${clientId}`);

        logger.info(`[SIGNAL SERVER] Deleted ${deletedCount} PreKey(s)`);
        socket.emit("deleteAllPreKeysResponse", { success: true, deletedCount });
      } else {
        socket.emit("deleteAllPreKeysResponse", { error: 'Not authenticated' });
      }
    } catch (error) {
      logger.error('[SIGNAL SERVER] Error deleting PreKeys:', error);
      socket.emit("deleteAllPreKeysResponse", { error: 'Failed to delete PreKeys' });
    }
  });

  // Troubleshoot: Regenerate identity key (requires full re-registration)
  socket.on("regenerateIdentityKey", async () => {
    try {
      if (isAuthenticated()) {
        const userId = getUserId();
        const clientId = getClientId();

        logger.warn('[SIGNAL SERVER] CRITICAL: regenerateIdentityKey request received');
        logger.debug('[SIGNAL SERVER] Regeneration details:', { userId: sanitizeForLog(userId), clientId: sanitizeForLog(clientId) });

        // Delete identity key from client record (forces re-registration)
        await writeQueue.enqueue(async () => {
          await Client.update(
            { public_key: null, registration_id: null },
            { where: { owner: userId, clientid: clientId } }
          );
        }, `regenerateIdentityKey-${clientId}`);

        // Also delete all associated keys (they're signed with old identity)
        const deletedPreKeys = await writeQueue.enqueue(async () => {
          return await SignalPreKey.destroy({
            where: { owner: userId, client: clientId }
          });
        }, `deletePreKeysForIdentity-${clientId}`);

        const deletedSignedPreKeys = await writeQueue.enqueue(async () => {
          return await SignalSignedPreKey.destroy({
            where: { owner: userId, client: clientId }
          });
        }, `deleteSignedPreKeysForIdentity-${clientId}`);

        logger.info(`[SIGNAL SERVER] Identity cleared, deleted ${deletedPreKeys} PreKeys and ${deletedSignedPreKeys} SignedPreKeys`);
        socket.emit("regenerateIdentityKeyResponse", { 
          success: true, 
          deletedPreKeys, 
          deletedSignedPreKeys 
        });
      } else {
        socket.emit("regenerateIdentityKeyResponse", { error: 'Not authenticated' });
      }
    } catch (error) {
      logger.error('[SIGNAL SERVER] Error regenerating identity key:', error);
      socket.emit("regenerateIdentityKeyResponse", { error: 'Failed to regenerate identity key' });
    }
  });

  socket.on("getPreKeys", async () => {
    try {
      if(isAuthenticated()) {
        const userId = getUserId();
        const clientId = getClientId();
        // Fetch pre-keys from the database
        const preKeys = await SignalPreKey.findAll({
          where: { owner: userId, client: clientId }
        });
        socket.emit("getPreKeysResponse", preKeys);
      }
    } catch (error) {
      logger.error('Error fetching pre-keys:', error);
      socket.emit("getPreKeysResponse", { error: 'Failed to fetch pre-keys' });
    }
  });

  // 🔄 SESSION RECOVERY: Handle session corruption/missing session notifications
  socket.on("sessionRecoveryNeeded", async (data) => {
    logger.info('[SIGNAL SERVER] Session recovery notification received');
    logger.debug('[SIGNAL SERVER] Session recovery data:', { data: sanitizeForLog(data) });
    try {
      if(isAuthenticated()) {
        const { senderUserId, senderDeviceId, recipientUserId, recipientDeviceId, reason } = data;
        
        // Validate that the request is from the recipient
        const currentUserId = getUserId();
        const currentDeviceId = getDeviceId();
        if (currentUserId !== recipientUserId || currentDeviceId !== recipientDeviceId) {
          logger.error('[SIGNAL SERVER] Session recovery request from unauthorized device');
          return;
        }
        
        logger.info('[SIGNAL SERVER] Forwarding session recovery request to sender');
        logger.debug('[SIGNAL SERVER] Session recovery forwarding details:', { 
          senderUserId: sanitizeForLog(senderUserId), 
          senderDeviceId: sanitizeForLog(senderDeviceId),
          reason: sanitizeForLog(reason), 
          recipientUserId: sanitizeForLog(recipientUserId), 
          recipientDeviceId: sanitizeForLog(recipientDeviceId) 
        });
        
        // Forward notification to the sender who needs to resend
        safeEmitToDevice(io, senderUserId, senderDeviceId, "sessionRecoveryRequested", {
          recipientUserId: recipientUserId,
          recipientDeviceId: recipientDeviceId,
          reason: reason,
          requestedAt: new Date().toISOString()
        });
        
        logger.info('[SIGNAL SERVER] Session recovery notification sent to sender');
        logger.debug('[SIGNAL SERVER] Session recovery sent to:', { senderUserId: sanitizeForLog(senderUserId), senderDeviceId: sanitizeForLog(senderDeviceId) });
      } else {
        logger.error('[SIGNAL SERVER] sessionRecoveryNeeded blocked - not authenticated');
      }
    } catch (error) {
      logger.error('[SIGNAL SERVER] Error handling session recovery:', error);
    }
  });

  socket.on("sendItem", async (data) => {
    logger.info('[SIGNAL SERVER] sendItem event received');
    logger.debug('[SIGNAL SERVER] sendItem data:', { data: sanitizeForLog(data) });
    logger.debug('[SIGNAL SERVER] Session:', { session: socket.handshake.session });
    try {
      if(isAuthenticated()) {
        const recipientUserId = data.recipient;
        const recipientDeviceId = data.recipientDeviceId;
        const senderUserId = getUserId();
        const senderDeviceId = getDeviceId();
        const type = data.type;
        const payload = data.payload;
        const cipherType = parseInt(data.cipherType, 10);
        const itemId = data.itemId;

        // Store ALL 1:1 messages in the database (including PreKey for offline recipients)
        // NOTE: Item table is for 1:1 messages ONLY (no channel field)
        // Group messages use sendGroupItem event and GroupItem table instead
        logger.info('[SIGNAL SERVER] Storing 1:1 message in DB');
        logger.debug('[SIGNAL SERVER] Message details:', { cipherType, itemId: sanitizeForLog(itemId) });
        
        // Determine if this is a multi-device sync message (sender == receiver)
        const isMultiDeviceSync = (senderUserId === recipientUserId);
        
        const storedItem = await writeQueue.enqueue(async () => {
          return await Item.create({
            sender: senderUserId,
            deviceSender: senderDeviceId,
            receiver: recipientUserId,
            deviceReceiver: recipientDeviceId,
            type: type,
            payload: payload,
            cipherType: cipherType,
            itemId: itemId,
            // If multi-device sync, originalRecipient should be extracted from payload metadata
            // For now, it's null (will be set by client when sending)
            originalRecipient: data.originalRecipient || null
          });
        }, `sendItem-${itemId}`);
         logger.info('[SIGNAL SERVER] Message stored successfully in DB');
         if (isMultiDeviceSync && data.originalRecipient) {
           logger.debug('[SIGNAL SERVER] Multi-device sync message with originalRecipient:', { originalRecipient: sanitizeForLog(data.originalRecipient) });
         }

        // Send delivery receipt to sender IMMEDIATELY after DB storage
        // (regardless of whether recipient is online)
        const senderSocketId = deviceSockets.get(`${senderUserId}:${senderDeviceId}`);
        if (senderSocketId) {
          safeEmitToDevice(io, senderUserId, senderDeviceId, "deliveryReceipt", {
            itemId: itemId,
            recipientUserId: recipientUserId,
            recipientDeviceId: recipientDeviceId,
            deliveredAt: new Date().toISOString()
          });
          logger.info('[SIGNAL SERVER] Delivery receipt sent to sender (message stored in DB)');
          logger.debug('[SIGNAL SERVER] Receipt sent to:', { senderUserId: sanitizeForLog(senderUserId), senderDeviceId: sanitizeForLog(senderDeviceId) });
        }

        // Sende die Nachricht an das spezifische Gerät (recipientDeviceId),
        // für das sie verschlüsselt wurde
        const targetSocketId = deviceSockets.get(`${recipientUserId}:${recipientDeviceId}`);
        const isSelfMessage = (recipientUserId === senderUserId && recipientDeviceId === senderDeviceId);
        
        // DEBUG: Log all connected devices
        logger.info('[SIGNAL SERVER] 🔍 Current deviceSockets state:', {
          totalDevices: deviceSockets.size,
          lookingFor: `${recipientUserId}:${recipientDeviceId}`,
          found: !!targetSocketId,
          allDevices: Array.from(deviceSockets.keys())
        });
        
        logger.debug('[SIGNAL SERVER] Target device details:', { 
          recipientUserId: sanitizeForLog(recipientUserId), 
          recipientDeviceId: sanitizeForLog(recipientDeviceId), 
          hasSocket: !!targetSocketId,
          isSelfMessage,
          cipherType
        });
        if (targetSocketId) {
          // 🚀 Use safe emit (only if client ready)
          safeEmitToDevice(io, recipientUserId, recipientDeviceId, "receiveItem", {
            sender: senderUserId,
            senderDeviceId: senderDeviceId,
            recipient: recipientUserId,
            type: type,
            payload: payload,
            cipherType: cipherType,
            itemId: itemId,
            // Include originalRecipient for multi-device sync
            originalRecipient: data.originalRecipient || null,
            // NOTE: channel is NOT included - receiveItem is for 1:1 messages ONLY
            // Group messages use groupItem event instead
          });
          logger.info('[SIGNAL SERVER] 1:1 message sent to device');
          logger.debug('[SIGNAL SERVER] Message sent to:', { recipientUserId: sanitizeForLog(recipientUserId), recipientDeviceId: sanitizeForLog(recipientDeviceId) });
          
          // Update delivery timestamp in database (recipient received the message)
          await writeQueue.enqueue(async () => {
            return await Item.update(
              { deliveredAt: new Date() },
              { where: { uuid: storedItem.uuid } }
            );
          }, `deliveryUpdate-${itemId}`);
        } else {
          logger.info('[SIGNAL SERVER] Target device offline, message stored in DB');
          logger.debug('[SIGNAL SERVER] Offline device:', { recipientUserId: sanitizeForLog(recipientUserId), recipientDeviceId: sanitizeForLog(recipientDeviceId) });
          
          // Send push notification to offline device (if configured)
          if (!isSelfMessage) {
            // Get sender info for notification
            const senderUser = await User.findOne({
              where: { uuid: senderUserId },
              attributes: ['displayName', 'email']
            });
            const senderName = senderUser?.displayName || senderUser?.email || 'Someone';
            
            // Send push notification (only if device is offline)
            sendMessageNotification(
              recipientUserId,
              senderName,
              'You have a new message',
              {
                senderId: senderUserId,
                senderDeviceId: senderDeviceId,
                itemId: itemId
              }
            ).catch(err => logger.error('[PUSH] Error sending message notification:', err));
          }
        }
       } else {
         logger.error('[SIGNAL SERVER] ERROR: sendItem blocked - not authenticated');
      }
    } catch (error) {
      logger.error('Error sending item:', error);
    }
  });

  // ===== DEPRECATED: OLD GROUP MESSAGE HANDLER =====
  // This handler is kept for backward compatibility but uses the old Item table
  // instead of the new GroupItem table. It should not be used in new code.
  // Use sendGroupItem event instead.
  socket.on("sendGroupMessage", async (data) => {
    logger.warn('[SIGNAL SERVER] WARNING: sendGroupMessage is deprecated, use sendGroupItem instead');
    logger.debug('[SIGNAL SERVER] Received deprecated sendGroupMessage event:', { data: sanitizeForLog(data) });
    
    try {
      if(!isAuthenticated()) {
        logger.error('[SIGNAL SERVER] ERROR: sendGroupMessage blocked - not authenticated');
        return;
      }

      // Redirect to new sendGroupItem handler
      // Map old data format to new format
      const newData = {
        channelId: data.groupId,
        itemId: data.itemId,
        type: 'message',
        payload: data.ciphertext,
        cipherType: 4,  // Sender Key
        timestamp: data.timestamp
      };

      logger.info('[SIGNAL SERVER] Redirecting to sendGroupItem handler with new format');
      // Trigger the new handler
      socket.emit('_internalSendGroupItem', newData);
      
    } catch (error) {
      logger.error('[SIGNAL SERVER] Error in deprecated sendGroupMessage:', error);
    }
  });

  // GROUP MESSAGE READ RECEIPT HANDLER
  socket.on("groupMessageRead", async (data) => {
    try {
      if(!isAuthenticated()) {
        logger.error('[SIGNAL SERVER] ERROR: groupMessageRead blocked - not authenticated');
        return;
      }

      const { itemId, groupId } = data;
      const readerUserId = getUserId();
      const readerDeviceId = getDeviceId();

      // Update readed flag for this specific device's Item
      const updatedCount = await writeQueue.enqueue(async () => {
        return await Item.update(
          { readed: true },
          { 
            where: { 
              itemId: itemId,
              channel: groupId,
              receiver: readerUserId,
              deviceReceiver: readerDeviceId,
              type: 'groupMessage'
            }
          }
        );
      }, `groupMessageRead-${itemId}-${readerDeviceId}`);

      if (updatedCount[0] > 0) {
        logger.info('[SIGNAL SERVER] Message marked as read');
        logger.debug('[SIGNAL SERVER] Read by:', { itemId: sanitizeForLog(itemId), readerUserId: sanitizeForLog(readerUserId), readerDeviceId: sanitizeForLog(readerDeviceId) });

        // Get all Items for this message to calculate read statistics
        const allItems = await Item.findAll({
          where: { 
            itemId: itemId,
            channel: groupId,
            type: 'groupMessage'
          }
        });

        const totalDevices = allItems.length;
        const readDevices = allItems.filter(item => item.readed === true).length;
        const deliveredDevices = allItems.filter(item => item.deliveredAt !== null).length;
        const allRead = readDevices === totalDevices;

        // Send read receipt update to the message sender
        const senderItem = allItems[0]; // All items have the same sender
        if (senderItem) {
          const senderSocketId = deviceSockets.get(`${senderItem.sender}:${senderItem.deviceSender}`);
          if (senderSocketId) {
            safeEmitToDevice(io, senderItem.sender, senderItem.deviceSender, "groupMessageReadReceipt", {
              itemId: itemId,
              groupId: groupId,
              readBy: readerUserId,
              readByDeviceId: readerDeviceId,
              readCount: readDevices,
              deliveredCount: deliveredDevices,
              totalCount: totalDevices,
              allRead: allRead,
              readAt: new Date().toISOString()
            });
            logger.info(`[SIGNAL SERVER] Read receipt sent to sender: ${readDevices}/${totalDevices} devices have read`);
          }

          // If all devices have read the message, delete it from server
          if (allRead) {
            const deletedCount = await writeQueue.enqueue(async () => {
              return await Item.destroy({
                where: { 
                  itemId: itemId,
                  channel: groupId,
                  type: 'groupMessage'
                }
              });
            }, `deleteReadGroupMessage-${itemId}`);
            
            logger.info('[SIGNAL SERVER] Group message read by all devices and deleted from server');
            logger.debug('[SIGNAL SERVER] Deleted message:', { itemId: sanitizeForLog(itemId), totalDevices });
          }
        }
      }
    } catch (error) {
      logger.error('[SIGNAL SERVER] Error in groupMessageRead:', error);
    }
  });

  // Store sender key on server (when device creates/distributes sender key)
  socket.on("storeSenderKey", async (data) => {
    try {
      if(!isAuthenticated()) {
        logger.error('[SIGNAL SERVER] ERROR: storeSenderKey blocked - not authenticated');
        return;
      }

      const { groupId, senderKey } = data;
      const userId = getUserId();
      const deviceId = getDeviceId();

      // Find the client record
      const client = await Client.findOne({
        where: {
          owner: userId,
          device_id: deviceId
        }
      });

      if (!client) {
        logger.error('[SIGNAL SERVER] ERROR: Client not found for storeSenderKey');
        return;
      }

      // Store or update sender key
      const [stored, created] = await SignalSenderKey.findOrCreate({
        where: {
          channel: groupId,
          client: client.clientid
        },
        defaults: {
          channel: groupId,
          client: client.clientid,
          owner: userId,
          sender_key: senderKey
        }
      });

      if (!created) {
        // Update existing sender key
        await stored.update({ sender_key: senderKey });
      }

      logger.info('[SIGNAL SERVER] Stored sender key');
      logger.debug(`[SIGNAL SERVER] User: ${sanitizeForLog(userId)}, Device: ${sanitizeForLog(deviceId)}, Group: ${sanitizeForLog(groupId)}`);
      
      // Send confirmation
      socket.emit("senderKeyStored", { groupId, success: true });
    } catch (error) {
      logger.error('[SIGNAL SERVER] Error in storeSenderKey', error);
    }
  });

  // Broadcast sender key distribution message to all group members
  socket.on("broadcastSenderKey", async (data) => {
    try {
      if(!isAuthenticated()) {
        logger.error('[SIGNAL SERVER] ERROR: broadcastSenderKey blocked - not authenticated');
        return;
      }

      const { groupId, distributionMessage } = data;
      const userId = getUserId();
      const deviceId = getDeviceId();

      logger.info('[SIGNAL SERVER] Broadcasting sender key to group');
      logger.debug(`[SIGNAL SERVER] User: ${sanitizeForLog(userId)}, Device: ${sanitizeForLog(deviceId)}, Group: ${sanitizeForLog(groupId)}`);

      // Get all channel members (same approach as sendGroupItem)
      const members = await ChannelMembers.findAll({
        where: { channelId: groupId }
      });

      if (!members || members.length === 0) {
        logger.info('[SIGNAL SERVER] No members found for group');
        logger.debug(`[SIGNAL SERVER] Group: ${sanitizeForLog(groupId)}`);
        return;
      }

      // Get all client devices for these members
      const memberUserIds = members.map(m => m.userId);
      const memberClients = await Client.findAll({
        where: {
          owner: { [require('sequelize').Op.in]: memberUserIds }
        }
      });

      // Broadcast to all member devices EXCEPT sender
      const payload = {
        groupId,
        senderId: userId,
        senderDeviceId: deviceId,
        distributionMessage
      };

      let deliveredCount = 0;
      for (const client of memberClients) {
        // Skip sender's device
        if (client.owner === userId && client.device_id === deviceId) {
          continue;
        }

        const targetSocketId = deviceSockets.get(`${client.owner}:${client.device_id}`);
        if (targetSocketId) {
          safeEmitToDevice(io, client.owner, client.device_id, 'receiveSenderKeyDistribution', payload);
          deliveredCount++;
        }
      }

      logger.info(`[SIGNAL SERVER] Sender key distribution delivered to ${deliveredCount}/${memberClients.length - 1} devices`);
    } catch (error) {
      logger.error('[SIGNAL SERVER] Error in broadcastSenderKey', error);
    }
  });

  // Retrieve sender key from server (when device needs a missing sender key)
  socket.on("getSenderKey", async (data) => {
    try {
      if(!isAuthenticated()) {
        logger.error('[SIGNAL SERVER] ERROR: getSenderKey blocked - not authenticated');
        return;
      }

      const { groupId, requestedUserId, requestedDeviceId } = data;

      // Find the client record for the requested sender
      const client = await Client.findOne({
        where: {
          owner: requestedUserId,
          device_id: requestedDeviceId
        }
      });

      if (!client) {
        logger.error('[SIGNAL SERVER] ERROR: Client not found for getSenderKey');
        logger.debug(`[SIGNAL SERVER] User: ${sanitizeForLog(requestedUserId)}, Device: ${sanitizeForLog(requestedDeviceId)}`);
        socket.emit("senderKeyResponse", { groupId, requestedUserId, requestedDeviceId, senderKey: null });
        return;
      }

      // Retrieve sender key
      const senderKeyRecord = await SignalSenderKey.findOne({
        where: {
          channel: groupId,
          client: client.clientid
        }
      });

      if (senderKeyRecord) {
        logger.info('[SIGNAL SERVER] Retrieved sender key');
        logger.debug(`[SIGNAL SERVER] User: ${sanitizeForLog(requestedUserId)}, Device: ${sanitizeForLog(requestedDeviceId)}, Group: ${sanitizeForLog(groupId)}`);
        socket.emit("senderKeyResponse", {
          groupId,
          requestedUserId,
          requestedDeviceId,
          senderKey: senderKeyRecord.sender_key,
          success: true
        });
      } else {
        logger.info('[SIGNAL SERVER] Sender key not found');
        logger.debug(`[SIGNAL SERVER] User: ${sanitizeForLog(requestedUserId)}, Device: ${sanitizeForLog(requestedDeviceId)}, Group: ${sanitizeForLog(groupId)}`);
        socket.emit("senderKeyResponse", {
          groupId,
          requestedUserId,
          requestedDeviceId,
          senderKey: null,
          success: false
        });
      }
    } catch (error) {
      logger.error('[SIGNAL SERVER] Error in getSenderKey', error);
    }
  });

  // SIGNAL HANDLE END
  
  /*socket.on("channels", async(callback) => {
    try {
      const channels = await Channel.findAll({
        include: [
          {
            model: User,
            as: 'Members',
            where: { uuid: socket.handshake.session.uuid },
            through: { attributes: [] }
          },
          {
            model: Thread,
            required: false,
            attributes: [],
          }
        ],
        attributes: {
          include: [
            [Channel.sequelize.fn('MAX', Channel.sequelize.col('Threads.createdAt')), 'latestThread']
          ]
        },
        group: ['Channel.name'],
        order: [[Channel.sequelize.literal('latestThread'), 'DESC']],
        limit: 5
      });
      
      callbackHandler(callback, channels);
    } catch (error) {
      logger.error('Error fetching channels', error);
      callbackHandler(callback, { error: 'Failed to fetch channels' });
    }
  });

  /**
   * Event handler for hosting a room
   * @param {number} slots - Number of available download slots for the host
   * @param {Callback} callback - Callback function to be invoked with the room ID
   */
  socket.on("host", (slots, callback) => {
    const room = randomUUID();
    const seeders = {[socket.id]: {slots: Number(slots), peers: 0, level: 0, score: 100.0}};
    rooms[room] = {host: socket.id, seeders: seeders, stream: false, share: {}, meeting: false, meetingSettings: {}};

    socket.join(room);
    callbackHandler(callback, room);
  });

  /**
   * Event handler for connecting as a client to a room
   * @param {string} room - The ID of the room to connect to
   * @param {string} filename - The name of the file to download
   * @param {Callback} callback - Callback function to be invoked with the connection status
   */
  socket.on("client", (room, filename, callback) => {
    const roomData = rooms[room];
    if (!roomData || roomData.host === undefined) {
        if (typeof callback === "function") callback({message: "Room not found", room});
        return;
    }

    socket.join(room);
    const seeders = Object.entries(roomData.seeders);

    // Sanitize filename to prevent prototype pollution
    if (!filename || typeof filename !== 'string') {
        callbackHandler(callback, {message: "Invalid filename", room});
        return;
    }
    const safeFilename = '$' + filename;

    for (const [seeder, value] of seeders) {
        let fileSeeders;
        if (roomData.share.files[safeFilename]) {
            fileSeeders = roomData.share.files[safeFilename].seeders;
        }
        if (!fileSeeders || !fileSeeders.includes(seeder) || value.slots <= value.peers || seeder === socket.id) continue;

        socket.to(seeder).emit("client", socket.id);
        callbackHandler(callback, {message: "Client connected", room, host: seeder});
        socket.to(roomData.host).emit("currentPeers", Object.keys(roomData.seeders).length);
        return;
    }

    callbackHandler(callback, {message: "no available download slot, please try later", room});
  });

  /**
   * Event handler for watching a room
   * @param {string} room - The ID of the room to watch
   * @param {Callback} callback - Callback function to be invoked with the connection status
   */
  socket.on("watch", (room, callback) => {
    const roomData = rooms[room];
    if (!roomData || roomData.host === undefined || roomData.stream !== true) {
        callbackHandler(callback, {message: "Room not found", room});
        return;
    }

    socket.join(room);
    const seedersDesc = Object.entries(roomData.seeders).sort((a,b) => a.score > b.score);

    for (const [seeder, value] of seedersDesc) {
        if (value.slots <= value.peers || seeder === socket.id) continue;

        socket.to(seeder).emit("watch", socket.id);
        callbackHandler(callback, {message: "Client connected", room, host: seeder});
        socket.to(roomData.host).emit("currentPeers", Object.keys(roomData.seeders).length);
        return;
    }

    callbackHandler(callback, {message: "no available stream slot, please try later", room});
  });

  socket.on("negotiationneeded", (id) => {
    socket.to(id).emit("negotiationneeded", socket.id);
  });

  /**
   * Event handler for offering a WebRTC connection
   * @param {string} id - The ID of the recipient socket
   * @param {any} message - The offer message
   */
  socket.on("offer", (id, message) => {
    socket.to(id).emit("offer", socket.id, message);
  });

  socket.on("offerScreenshare", (id, message) => {
    socket.to(id).emit("offerScreenshare", socket.id, message);
  });

  /**
   * Event handler for answering a WebRTC connection
   * @param {string} id - The ID of the recipient socket
   * @param {any} message - The answer message
   */
  socket.on("answer", (id, message) => {
    socket.to(id).emit("answer", socket.id, message);
  });

  socket.on("answerScreenshare", (id, message) => {
    socket.to(id).emit("answerScreenshare", socket.id, message);
  });

  /**
   * Event handler for sending ICE candidate information
   * @param {string} id - The ID of the recipient socket
   * @param {any} message - The ICE candidate message
   */
  socket.on("candidate", (id, message) => {
    socket.to(id).emit("candidate", socket.id, message);
  });

  socket.on("candidateScreenshare", (id, message) => {
    socket.to(id).emit("candidateScreenshare", socket.id, message);
  });

  // ===== P2P FILE SHARING =====
  
  const fileRegistry = require('./store/fileRegistry');
  
  /**
   * Announce a file (user has chunks available for seeding)
   */
  socket.on("announceFile", async (data, callback) => {
    try {
      if (!isAuthenticated()) {
        logger.error('[P2P FILE] ERROR: Not authenticated');
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = getUserId();
      const deviceId = getDeviceId();
      const { fileId, mimeType, fileSize, checksum, chunkCount, availableChunks, sharedWith } = data;

      logger.info(`[P2P FILE] Device announcing file (${mimeType}, ${fileSize} bytes)`);
      logger.debug(`[P2P FILE] User: ${sanitizeForLog(userId)}, Device: ${sanitizeForLog(deviceId)}, FileId: ${sanitizeForLog(fileId.substring(0, 16))}...`);
      if (sharedWith) {
        logger.debug(`[P2P FILE] Shared with: ${sharedWith.join(', ')}`);
      }

      // Check if this is a reannouncement
      const existingFile = fileRegistry.getFileInfo(fileId);
      
      if (existingFile) {
        // ========================================
        // REANNOUNCEMENT - Use merge logic
        // ========================================
        logger.info('[P2P FILE] Reannouncing existing file');
        logger.debug(`[P2P FILE] FileId: ${sanitizeForLog(fileId.substring(0, 8))}`);
        
        const result = fileRegistry.reannounceFile(fileId, userId, deviceId, {
          availableChunks,
          sharedWith
        });
        
        if (!result) {
          logger.error('[P2P FILE] Reannouncement failed');
          logger.debug(`[P2P FILE] FileId: ${sanitizeForLog(fileId.substring(0, 8))}`);
          return callback?.({ success: false, error: "Reannouncement failed" });
        }
        
        // Calculate chunk quality
        const chunkQuality = fileRegistry.getChunkQuality(fileId);
        
        // Broadcast updated sharedWith to all online seeders (WebSocket)
        const seeders = fileRegistry.getSeeders(fileId);
        seeders.forEach(seederKey => {
          const [seederUserId, seederDeviceId] = seederKey.split(':');
          if (seederKey !== `${userId}:${deviceId}`) { // Don't notify sender
            safeEmitToDevice(io, seederUserId, seederDeviceId, "file:sharedWith-updated", {
              fileId,
              sharedWith: result.sharedWith
            });
          }
        });
        
        // Send Signal messages to all holders (async, non-blocking)
        setImmediate(() => {
          sendSharedWithUpdateSignal(fileId, result.sharedWith).catch(err => {
            logger.error('[SIGNAL] Error sending sharedWith update', err);
          });
        });
        
        logger.info(`[P2P FILE] Notifying ${result.sharedWith.length} authorized users about file reannouncement`);
        
        // Notify authorized users about reannouncement
        result.sharedWith.forEach(targetUserId => {
          const targetSockets = Array.from(io.sockets.sockets.values())
            .filter(s => 
              s.handshake.session?.uuid === targetUserId &&
              s.id !== socket.id
            );
          
          targetSockets.forEach(targetSocket => {
            const targetDeviceId = targetSocket.handshake.session?.deviceId;
            if (targetDeviceId) {
              safeEmitToDevice(io, targetUserId, targetDeviceId, "fileAnnounced", {
                fileId,
                userId,
                deviceId,
                mimeType: existingFile.mimeType,
                fileSize: existingFile.fileSize,
                seederCount: result.seedersCount,
                chunkQuality,
                sharedWith: result.sharedWith
              });
            }
          });
        });
        
        callback?.({ 
          success: true, 
          chunkQuality,
          sharedWith: result.sharedWith
        });
        
      } else {
        // ========================================
        // NEW FILE - First announcement
        // ========================================
        
        // Register file with userId:deviceId format + sharedWith
        const fileInfo = fileRegistry.announceFile(userId, deviceId, {
          fileId,
          mimeType,
          fileSize,
          checksum,
          chunkCount,
          availableChunks,
          sharedWith
        });

        // ========================================
        // SECURITY: Check if announce was denied
        // ========================================
        if (!fileInfo) {
          logger.error('[SECURITY] Announce REJECTED for user');
          logger.debug(`[SECURITY] User: ${sanitizeForLog(userId)}, FileId: ${sanitizeForLog(fileId.substring(0, 16))}`);
          return callback?.({ 
            success: false, 
            error: "Permission denied: You don't have access to this file" 
          });
        }

        // Calculate chunk quality
        const chunkQuality = fileRegistry.getChunkQuality(fileId);

        callback?.({ success: true, fileInfo, chunkQuality });

        // LÖSUNG 12: Notify only authorized users (no broadcast!)
        const sharedUsers = fileRegistry.getSharedUsers(fileId);
        logger.info(`[P2P FILE] Notifying ${sharedUsers.length} authorized users about file announcement (quality: ${chunkQuality}%)`);
        
        // Find sockets of authorized users
        const targetSockets = Array.from(io.sockets.sockets.values())
          .filter(s => 
            s.handshake.session?.uuid && 
            sharedUsers.includes(s.handshake.session.uuid) &&
            s.id !== socket.id // Don't notify the announcer
          );
        
        // Send targeted notification to each authorized user
        targetSockets.forEach(targetSocket => {
          const targetUserId = targetSocket.handshake.session?.uuid;
          const targetDeviceId = targetSocket.handshake.session?.deviceId;
          if (targetUserId && targetDeviceId) {
            safeEmitToDevice(io, targetUserId, targetDeviceId, "fileAnnounced", {
              fileId,
              userId,
              deviceId,
              mimeType,
              fileSize,
              seederCount: fileInfo.seederCount,
              chunkQuality,
              sharedWith: sharedUsers
            });
          }
        });
      }

    } catch (error) {
      logger.error('[P2P FILE] Error announcing file', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Get current sharedWith list for a file (for sync before reannouncement)
   */
  socket.on("file:get-sharedWith", async (data, callback) => {
    try {
      if (!isAuthenticated()) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const { fileId } = data;
      
      if (!fileId) {
        return callback?.({ success: false, error: 'Missing fileId' });
      }
      
      const sharedWith = fileRegistry.getSharedWith(fileId);
      
      if (sharedWith !== null) {
        callback?.({
          success: true,
          sharedWith: sharedWith
        });
      } else {
        callback?.({ success: false, error: 'File not found' });
      }
    } catch (error) {
      logger.error('[SOCKET] Error getting sharedWith', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Unannounce a file (user no longer seeding)
   */
  socket.on("unannounceFile", async (data, callback) => {
    try {
      if (!isAuthenticated()) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = getUserId();
      const deviceId = getDeviceId();
      const { fileId } = data;

      logger.info('[P2P FILE] Device unannouncing file');
      logger.debug(`[P2P FILE] User: ${sanitizeForLog(userId)}, Device: ${sanitizeForLog(deviceId)}, FileId: ${sanitizeForLog(fileId)}`);

      const success = fileRegistry.unannounceFile(userId, deviceId, fileId);
      callback?.({ success });

      // LÖSUNG 12: Notify only authorized users about seeder count change
      const fileInfo = fileRegistry.getFileInfo(fileId);
      if (fileInfo) {
        const sharedUsers = fileRegistry.getSharedUsers(fileId);
        
        const targetSockets = Array.from(io.sockets.sockets.values())
          .filter(s => 
            s.handshake.session?.uuid && 
            sharedUsers.includes(s.handshake.session.uuid) &&
            s.id !== socket.id
          );
        
        targetSockets.forEach(targetSocket => {
          const targetUserId = targetSocket.handshake.session?.uuid;
          const targetDeviceId = targetSocket.handshake.session?.deviceId;
          if (targetUserId && targetDeviceId) {
            safeEmitToDevice(io, targetUserId, targetDeviceId, "fileSeederUpdate", {
              fileId,
              seederCount: fileInfo.seederCount
            });
          }
        });
      }

    } catch (error) {
      logger.error('[P2P FILE] Error unannouncing file', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Update available chunks for a file
   */
  socket.on("updateAvailableChunks", async (data, callback) => {
    try {
      if (!isAuthenticated()) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = getUserId();
      const deviceId = getDeviceId();
      const { fileId, availableChunks } = data;

      logger.info(`[P2P FILE] Device updating chunks: ${availableChunks.length} chunks`);
      logger.debug(`[P2P FILE] User: ${sanitizeForLog(userId)}, Device: ${sanitizeForLog(deviceId)}, FileId: ${sanitizeForLog(fileId.substring(0, 8))}`);

      const success = fileRegistry.updateAvailableChunks(userId, deviceId, fileId, availableChunks);
      
      if (!success) {
        return callback?.({ success: false, error: "File not found" });
      }

      callback?.({ success: true });

      // Notify authorized users about chunk update
      const sharedUsers = fileRegistry.getSharedUsers(fileId);
      const fileInfo = fileRegistry.getFileInfo(fileId);
      const chunkQuality = fileRegistry.getChunkQuality(fileId);
      
      if (fileInfo) {
        const targetSockets = Array.from(io.sockets.sockets.values())
          .filter(s => 
            s.handshake.session?.uuid && 
            sharedUsers.includes(s.handshake.session.uuid) &&
            s.id !== socket.id
          );
        
        targetSockets.forEach(targetSocket => {
          const targetUserId = targetSocket.handshake.session?.uuid;
          const targetDeviceId = targetSocket.handshake.session?.deviceId;
          if (targetUserId && targetDeviceId) {
            safeEmitToDevice(io, targetUserId, targetDeviceId, "fileSeederUpdate", {
              fileId,
              seederCount: fileInfo.seederCount,
              chunkQuality
            });
          }
        });
        
        logger.info(`[P2P FILE] Notified ${targetSockets.length} users about chunk update (quality: ${chunkQuality}%)`);
      }

    } catch (error) {
      logger.error('[P2P FILE] Error updating chunks', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Request file information and seeders (LÖSUNG 14: Permission Check)
   */
  socket.on("getFileInfo", async (data, callback) => {
    try {
      if (!isAuthenticated()) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = getUserId();
      const { fileId } = data;
      
      // Check permission
      if (!fileRegistry.canAccess(userId, fileId)) {
        logger.info('[P2P FILE] User denied access to file');
        logger.debug(`[P2P FILE] User: ${sanitizeForLog(userId)}, FileId: ${sanitizeForLog(fileId)}`);
        return callback?.({ success: false, error: "Access denied" });
      }

      const fileInfo = fileRegistry.getFileInfo(fileId);

      if (!fileInfo) {
        return callback?.({ success: false, error: "File not found" });
      }

      // Add quality info
      fileInfo.chunkQuality = fileRegistry.getChunkQuality(fileId);
      fileInfo.missingChunks = fileRegistry.getMissingChunks(fileId);

      callback?.({ success: true, fileInfo });

    } catch (error) {
      logger.error('[P2P FILE] Error getting file info', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Register as downloading a file (leecher) (LÖSUNG 14: Permission Check)
   */
  socket.on("registerLeecher", async (data, callback) => {
    try {
      if (!isAuthenticated()) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = getUserId();
      const deviceId = getDeviceId();
      const { fileId } = data;

      // Check permission
      if (!fileRegistry.canAccess(userId, fileId)) {
        logger.info('[P2P FILE] User denied download access to file');
        logger.debug(`[P2P FILE] User: ${sanitizeForLog(userId)}, FileId: ${sanitizeForLog(fileId)}`);
        return callback?.({ success: false, error: "Access denied" });
      }

      logger.info('[P2P FILE] Device downloading file');
      logger.debug(`[P2P FILE] User: ${sanitizeForLog(userId)}, Device: ${sanitizeForLog(deviceId)}, FileId: ${sanitizeForLog(fileId)}`);

      const success = fileRegistry.registerLeecher(userId, deviceId, fileId);
      callback?.({ success });

    } catch (error) {
      logger.error('[P2P FILE] Error registering leecher', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Unregister as downloading a file
   */
  socket.on("unregisterLeecher", async (data, callback) => {
    try {
      if (!isAuthenticated()) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = getUserId();
      const deviceId = getDeviceId();
      const { fileId } = data;

      const success = fileRegistry.unregisterLeecher(userId, deviceId, fileId);
      callback?.({ success });

    } catch (error) {
      logger.error('[P2P FILE] Error unregistering leecher', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Search for files by name or checksum
   */
  socket.on("searchFiles", async (data, callback) => {
    try {
      const { query } = data;
      const results = fileRegistry.searchFiles(query);

      callback?.({ success: true, results });

    } catch (error) {
      logger.error('[P2P FILE] Error searching files', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Get all active files (with seeders)
   */
  socket.on("getActiveFiles", async (callback) => {
    try {
      const files = fileRegistry.getActiveFiles();
      callback?.({ success: true, files });

    } catch (error) {
      logger.error('[P2P FILE] Error getting active files', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Get available chunks from seeders (LÖSUNG 14: Permission Check)
   */
  socket.on("getAvailableChunks", async (data, callback) => {
    try {
      if (!isAuthenticated()) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = getUserId();
      const { fileId } = data;
      
      // Check permission
      if (!fileRegistry.canAccess(userId, fileId)) {
        logger.info('[P2P FILE] User denied access to chunks for file');
        logger.debug(`[P2P FILE] User: ${sanitizeForLog(userId)}, FileId: ${sanitizeForLog(fileId)}`);
        return callback?.({ success: false, error: "Access denied" });
      }

      const chunks = fileRegistry.getAvailableChunks(fileId);

      callback?.({ success: true, chunks });

    } catch (error) {
      logger.error('[P2P FILE] Error getting available chunks', error);
      callback?.({ success: false, error: error.message });
    }
  });

  // ===== P2P FILE SHARING - WebRTC SIGNALING RELAY =====
  
  /**
   * Share a file with another user (LÖSUNG 13 API - DEPRECATED)
   * @deprecated Use updateFileShare instead
   */
  socket.on("shareFile", async (data, callback) => {
    try {
      if (!isAuthenticated()) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = getUserId();
      const { fileId, targetUserId } = data;

      if (!fileId || !targetUserId) {
        return callback?.({ success: false, error: "Missing fileId or targetUserId" });
      }

      logger.info('[P2P FILE] User sharing file with user');
      logger.debug(`[P2P FILE] Sharer: ${sanitizeForLog(userId)}, Target: ${sanitizeForLog(targetUserId)}, FileId: ${sanitizeForLog(fileId)}`);

      const success = fileRegistry.shareFile(fileId, userId, targetUserId);
      fileRegistry.shareFile(fileId, userId, userId); // Ensure sharer retains access
      
      if (!success) {
        return callback?.({ success: false, error: "Failed to share file (not creator or file not found)" });
      }

      callback?.({ success: true });

      // Notify target user about new file
      const fileInfo = fileRegistry.getFileInfo(fileId);
      if (fileInfo) {
        const targetSockets = Array.from(io.sockets.sockets.values())
          .filter(s => s.handshake.session?.uuid === targetUserId);
        
        targetSockets.forEach(targetSocket => {
          const targetUserId = targetSocket.handshake.session?.uuid;
          const targetDeviceId = targetSocket.handshake.session?.deviceId;
          if (targetUserId && targetDeviceId) {
            safeEmitToDevice(io, targetUserId, targetDeviceId, "fileSharedWithYou", {
              fileId,
              fromUserId: userId,
              fileInfo
            });
          }
        });
      }

    } catch (error) {
      logger.error('[P2P FILE] Error sharing file', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Update file share (add or revoke users) - NEW SECURE VERSION
   * 
   * Permission Model:
   * - Creator can add/revoke anyone
   * - Any seeder can add users (but not revoke)
   * - Must have valid access to the file
   * 
   * Rate Limited: Max 10 operations per minute per user
   * Size Limited: Max 1000 users in sharedWith
   */
  socket.on("updateFileShare", async (data, callback) => {
    try {
      if (!isAuthenticated()) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = getUserId();
      const { fileId, action, userIds } = data;

      // Validation
      if (!fileId || !action || !Array.isArray(userIds) || userIds.length === 0) {
        return callback?.({ success: false, error: "Invalid parameters" });
      }

      if (!['add', 'revoke'].includes(action)) {
        return callback?.({ success: false, error: "Invalid action (must be 'add' or 'revoke')" });
      }

      // Rate limiting (10 operations per minute)
      if (!socket._shareRateLimit) {
        socket._shareRateLimit = { count: 0, resetTime: Date.now() + 60000 };
      }

      const now = Date.now();
      if (now > socket._shareRateLimit.resetTime) {
        socket._shareRateLimit = { count: 0, resetTime: now + 60000 };
      }

      if (socket._shareRateLimit.count >= 10) {
        logger.warn('[P2P FILE] Rate limit exceeded for user');
        logger.debug(`[P2P FILE] User: ${sanitizeForLog(userId)}`);
        return callback?.({ success: false, error: "Rate limit: max 10 share operations per minute" });
      }

      socket._shareRateLimit.count++;

      // Get file info
      const fileInfo = fileRegistry.getFileInfo(fileId);
      if (!fileInfo) {
        return callback?.({ success: false, error: "File not found" });
      }

      // Permission check
      const isCreator = fileInfo.creator === userId;
      const hasAccess = fileRegistry.canAccess(userId, fileId);
      const isSeeder = fileInfo.seeders.some(s => s.startsWith(`${userId}:`));

      if (!isCreator && !hasAccess && !isSeeder) {
        logger.warn('[P2P FILE] User has no permission to modify shares');
        logger.debug(`[P2P FILE] User: ${sanitizeForLog(userId)}, FileId: ${sanitizeForLog(fileId)}`);
        return callback?.({ success: false, error: "Permission denied" });
      }

      // Action-specific permission checks
      if (action === 'revoke') {
        // Creator can revoke anyone
        if (isCreator) {
          // OK - Creator has full revoke rights
        }
        // Self-revoke: User can remove themselves
        else if (userIds.length === 1 && userIds[0] === userId) {
          logger.info('[P2P FILE] Self-revoke: User removing self from file');
          logger.debug(`[P2P FILE] User: ${sanitizeForLog(userId)}, FileId: ${sanitizeForLog(fileId.substring(0, 8))}`);
          // OK - Self-revoke allowed
        }
        // Non-creator cannot revoke others
        else {
          logger.warn('[P2P FILE] User cannot revoke others (not creator)');
          logger.debug(`[P2P FILE] User: ${sanitizeForLog(userId)}, FileId: ${sanitizeForLog(fileId.substring(0, 8))}`);
          return callback?.({ 
            success: false, 
            error: "Only creator can revoke others. You can only remove yourself." 
          });
        }
      }

      // Size limit check (max 1000 users)
      if (action === 'add') {
        const currentSize = fileInfo.sharedWith.length;
        const newSize = currentSize + userIds.length;
        
        if (newSize > 1000) {
          logger.warn(`[P2P FILE] Share limit exceeded: ${newSize} > 1000`);
          logger.debug(`[P2P FILE] FileId: ${sanitizeForLog(fileId)}`);
          return callback?.({ success: false, error: "Maximum 1000 users per file" });
        }
      }

      logger.info(`[P2P FILE] User ${action}ing ${userIds.length} users for file`);
      logger.debug(`[P2P FILE] User: ${sanitizeForLog(userId)}, FileId: ${sanitizeForLog(fileId.substring(0, 8))}`);

      // Execute action
      let successCount = 0;
      let failCount = 0;

      for (const targetUserId of userIds) {
        let success = false;
        
        if (action === 'add') {
          success = fileRegistry.shareFile(fileId, userId, targetUserId);
        } else if (action === 'revoke') {
          success = fileRegistry.unshareFile(fileId, userId, targetUserId);
        }

        if (success) {
          successCount++;
        } else {
          failCount++;
        }
      }

      logger.info(`[P2P FILE] Share update complete: ${successCount} succeeded, ${failCount} failed`);

      callback?.({ 
        success: true, 
        successCount, 
        failCount,
        totalUsers: fileRegistry.getSharedUsers(fileId).length
      });

      // Notify affected users
      const updatedFileInfo = fileRegistry.getFileInfo(fileId);
      const affectedUserIds = action === 'add' ? userIds : userIds.filter(id => id !== userId);

      affectedUserIds.forEach(targetUserId => {
        const targetSockets = Array.from(io.sockets.sockets.values())
          .filter(s => s.handshake.session?.uuid === targetUserId);
        
        targetSockets.forEach(targetSocket => {
          const targetDeviceId = targetSocket.handshake.session?.deviceId;
          if (targetDeviceId) {
            if (action === 'add') {
              safeEmitToDevice(io, targetUserId, targetDeviceId, "fileSharedWithYou", {
                fileId,
                fromUserId: userId,
                fileInfo: updatedFileInfo
              });
            } else {
              safeEmitToDevice(io, targetUserId, targetDeviceId, "fileAccessRevoked", {
                fileId,
                byUserId: userId
              });
            }
          }
        });
      });

    } catch (error) {
      logger.error('[P2P FILE] Error updating file share', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Unshare a file from a user (LÖSUNG 13 API)
   */
  socket.on("unshareFile", async (data, callback) => {
    try {
      if (!isAuthenticated()) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = getUserId();
      const { fileId, targetUserId } = data;

      if (!fileId || !targetUserId) {
        return callback?.({ success: false, error: "Missing fileId or targetUserId" });
      }

      logger.info('[P2P FILE] User unsharing file from user');
      logger.debug(`[P2P FILE] From: ${sanitizeForLog(userId)}, FileId: ${sanitizeForLog(fileId)}, Target: ${sanitizeForLog(targetUserId)}`);

      const success = fileRegistry.unshareFile(fileId, userId, targetUserId);
      
      if (!success) {
        return callback?.({ success: false, error: "Failed to unshare file (not creator or cannot unshare from creator)" });
      }

      callback?.({ success: true });

      // Notify target user about revoked access
      const targetSockets = Array.from(io.sockets.sockets.values())
        .filter(s => s.handshake.session?.uuid === targetUserId);
      
      targetSockets.forEach(targetSocket => {
        const targetDeviceId = targetSocket.handshake.session?.deviceId;
        if (targetDeviceId) {
          safeEmitToDevice(io, targetUserId, targetDeviceId, "fileUnsharedFromYou", {
            fileId,
            fromUserId: userId
          });
        }
      });

    } catch (error) {
      logger.error('[P2P FILE] Error unsharing file', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Get list of users a file is shared with (LÖSUNG 13 API)
   */
  socket.on("getSharedUsers", async (data, callback) => {
    try {
      if (!isAuthenticated()) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = getUserId();
      const { fileId } = data;

      // Only creator can see who file is shared with
      const fileInfo = fileRegistry.getFileInfo(fileId);
      if (!fileInfo || fileInfo.creator !== userId) {
        return callback?.({ success: false, error: "Access denied (not creator)" });
      }

      const sharedUsers = fileRegistry.getSharedUsers(fileId);
      callback?.({ success: true, sharedUsers });

    } catch (error) {
      logger.error('[P2P FILE] Error getting shared users', error);
      callback?.({ success: false, error: error.message });
    }
  });

  // ===== P2P FILE SHARING - WebRTC SIGNALING RELAY =====
  
  /**
   * Relay WebRTC offer from initiator to target peer
   */
  socket.on("file:webrtc-offer", (data) => {
    try {
      const { targetUserId, targetDeviceId, fileId, offer } = data;
      
      logger.info('[P2P WEBRTC] Relaying offer for file');
      logger.debug(`[P2P WEBRTC] FileId: ${sanitizeForLog(fileId)}, Target: ${sanitizeForLog(targetUserId)}:${sanitizeForLog(targetDeviceId || 'broadcast')}`);
      
      // Route to specific device if deviceId provided (and not empty string)
      if (targetDeviceId && targetDeviceId !== '') {
        const targetSocketId = deviceSockets.get(`${targetUserId}:${targetDeviceId}`);
        if (targetSocketId) {
          const fromUserId = getUserId();
          const fromDeviceId = getDeviceId();
          safeEmitToDevice(io, targetUserId, targetDeviceId, "file:webrtc-offer", {
            fromUserId,
            fromDeviceId,
            fileId,
            offer
          });
          logger.info('[P2P WEBRTC] Offer relayed to specific device');
          logger.debug(`[P2P WEBRTC] Target: ${sanitizeForLog(targetUserId)}:${sanitizeForLog(targetDeviceId)}`);
        } else {
          logger.warn('[P2P WEBRTC] Target device not found online');
          logger.debug(`[P2P WEBRTC] Target: ${sanitizeForLog(targetUserId)}:${sanitizeForLog(targetDeviceId)}`);
        }
      } else {
        // Broadcast to all devices of the user
        const targetSockets = Array.from(io.sockets.sockets.values())
          .filter(s => s.handshake.session.uuid === targetUserId);
        
        if (targetSockets.length > 0) {
          const fromUserId = getUserId();
          const fromDeviceId = getDeviceId();
          targetSockets.forEach(targetSocket => {
            const targetDeviceId = targetSocket.handshake.session?.deviceId;
            if (targetDeviceId) {
              safeEmitToDevice(io, targetUserId, targetDeviceId, "file:webrtc-offer", {
                fromUserId,
                fromDeviceId,
                fileId,
                offer
              });
            }
          });
          logger.info(`[P2P WEBRTC] Offer broadcast to ${targetSockets.length} device(s)`);
          logger.debug(`[P2P WEBRTC] User: ${sanitizeForLog(targetUserId)}`);
        } else {
          logger.warn('[P2P WEBRTC] Target user has no devices online');
          logger.debug(`[P2P WEBRTC] User: ${sanitizeForLog(targetUserId)}`);
        }
      }
    } catch (error) {
      logger.error('[P2P WEBRTC] Error relaying offer', error);
    }
  });

  /**
   * Relay WebRTC answer from responder to initiator
   */
  socket.on("file:webrtc-answer", (data) => {
    try {
      const { targetUserId, targetDeviceId, fileId, answer } = data;
      
      logger.info('[P2P WEBRTC] Relaying answer for file');
      logger.debug(`[P2P WEBRTC] FileId: ${sanitizeForLog(fileId)}, Target: ${sanitizeForLog(targetUserId)}:${sanitizeForLog(targetDeviceId)}`);
      
      // Route to specific device if deviceId provided
      if (targetDeviceId) {
        const targetSocketId = deviceSockets.get(`${targetUserId}:${targetDeviceId}`);
        if (targetSocketId) {
          const fromUserId = socket.handshake.session.uuid;
          const fromDeviceId = socket.handshake.session.deviceId;
          safeEmitToDevice(io, targetUserId, targetDeviceId, "file:webrtc-answer", {
            fromUserId,
            fromDeviceId,
            fileId,
            answer
          });
          logger.info('[P2P WEBRTC] Answer relayed to device');
          logger.debug(`[P2P WEBRTC] Target: ${sanitizeForLog(targetUserId)}:${sanitizeForLog(targetDeviceId)}`);
        } else {
          logger.warn('[P2P WEBRTC] Target device not found online');
          logger.debug(`[P2P WEBRTC] Target: ${sanitizeForLog(targetUserId)}:${sanitizeForLog(targetDeviceId)}`);
        }
      } else {
        // Broadcast to all devices (fallback)
        const targetSockets = Array.from(io.sockets.sockets.values())
          .filter(s => s.handshake.session.uuid === targetUserId);
        
        if (targetSockets.length > 0) {
          const fromUserId = socket.handshake.session.uuid;
          const fromDeviceId = socket.handshake.session.deviceId;
          targetSockets.forEach(targetSocket => {
            const targetDeviceId = targetSocket.handshake.session?.deviceId;
            if (targetDeviceId) {
              safeEmitToDevice(io, targetUserId, targetDeviceId, "file:webrtc-answer", {
                fromUserId,
                fromDeviceId,
                fileId,
                answer
              });
            }
          });
          logger.info(`[P2P WEBRTC] Answer broadcast to ${targetSockets.length} devices`);
        } else {
          logger.warn('[P2P WEBRTC] Target user not found online');
          logger.debug(`[P2P WEBRTC] User: ${sanitizeForLog(targetUserId)}`);
        }
      }
    } catch (error) {
      logger.error('[P2P WEBRTC] Error relaying answer', error);
    }
  });

  /**
   * Relay ICE candidate between peers
   */
  socket.on("file:webrtc-ice", (data) => {
    try {
      const { targetUserId, targetDeviceId, fileId, candidate } = data;
      
      logger.debug('[P2P WEBRTC] Relaying ICE candidate for file');
      logger.debug(`[P2P WEBRTC] FileId: ${sanitizeForLog(fileId)}, Target: ${sanitizeForLog(targetUserId)}:${sanitizeForLog(targetDeviceId)}`);
      
      // Route to specific device if deviceId provided
      if (targetDeviceId) {
        const targetSocketId = deviceSockets.get(`${targetUserId}:${targetDeviceId}`);
        if (targetSocketId) {
          const fromUserId = socket.handshake.session.uuid;
          const fromDeviceId = socket.handshake.session.deviceId;
          safeEmitToDevice(io, targetUserId, targetDeviceId, "file:webrtc-ice", {
            fromUserId,
            fromDeviceId,
            fileId,
            candidate
          });
        } else {
          logger.warn('[P2P WEBRTC] Target device not found online');
          logger.debug(`[P2P WEBRTC] Target: ${sanitizeForLog(targetUserId)}:${sanitizeForLog(targetDeviceId)}`);
        }
      } else {
        // Broadcast to all devices (fallback)
        const targetSockets = Array.from(io.sockets.sockets.values())
          .filter(s => s.handshake.session.uuid === targetUserId);
        
        if (targetSockets.length > 0) {
          const fromUserId = getUserId();
          const fromDeviceId = getDeviceId();
          targetSockets.forEach(targetSocket => {
            const targetDeviceId = targetSocket.handshake.session?.deviceId;
            if (targetDeviceId) {
              safeEmitToDevice(io, targetUserId, targetDeviceId, "file:webrtc-ice", {
                fromUserId,
                fromDeviceId,
                fileId,
                candidate
              });
            }
          });
        } else {
          logger.warn('[P2P WEBRTC] Target user not found online');
          logger.debug(`[P2P WEBRTC] User: ${sanitizeForLog(targetUserId)}`);
        }
      }
    } catch (error) {
      logger.error('[P2P WEBRTC] Error relaying ICE candidate', error);
    }
  });

  /**
   * Relay encryption key request from downloader to seeder
   */
  socket.on("file:key-request", (data) => {
    try {
      if (!isAuthenticated()) {
        logger.error('[P2P KEY] Key request blocked - not authenticated');
        return;
      }

      const { targetUserId, fileId } = data;
      const requesterId = getUserId();
      
      logger.info('[P2P KEY] User requesting key for file');
      logger.debug(`[P2P KEY] Requester: ${sanitizeForLog(requesterId)}, FileId: ${sanitizeForLog(fileId)}, Target: ${sanitizeForLog(targetUserId)}`);
      
      // Find seeder's socket and relay the key request
      const targetSockets = Array.from(io.sockets.sockets.values())
        .filter(s => s.handshake.session.uuid === targetUserId);
      
      if (targetSockets.length > 0) {
        targetSockets.forEach(targetSocket => {
          const targetDeviceId = targetSocket.handshake.session?.deviceId;
          if (targetDeviceId) {
            safeEmitToDevice(io, targetUserId, targetDeviceId, "file:key-request", {
              fromUserId: requesterId,
              fileId: fileId
            });
          }
        });
        logger.info('[P2P KEY] Key request relayed to seeder');
        logger.debug(`[P2P KEY] Target: ${sanitizeForLog(targetUserId)}`);
      } else {
        logger.warn('[P2P KEY] Seeder not found online');
        logger.debug(`[P2P KEY] Seeder: ${sanitizeForLog(targetUserId)}`);
        // Send error back to requester
        socket.emit("file:key-response", {
          fromUserId: targetUserId,
          fileId: fileId,
          error: "Seeder not online"
        });
      }
    } catch (error) {
      logger.error('[P2P KEY] Error relaying key request', error);
    }
  });

  /**
   * Relay encryption key response from seeder to downloader
   */
  socket.on("file:key-response", (data) => {
    try {
      if (!isAuthenticated()) {
        logger.error('[P2P KEY] Key response blocked - not authenticated');
        return;
      }

      const { targetUserId, fileId, key, error } = data;
      const seederId = getUserId();
      
      logger.info('[P2P KEY] User sending key for file');
      logger.debug(`[P2P KEY] Seeder: ${sanitizeForLog(seederId)}, FileId: ${sanitizeForLog(fileId)}, Target: ${sanitizeForLog(targetUserId)}`);
      
      // Find requester's socket and relay the key response
      const targetSockets = Array.from(io.sockets.sockets.values())
        .filter(s => s.handshake.session.uuid === targetUserId);
      
      if (targetSockets.length > 0) {
        targetSockets.forEach(targetSocket => {
          const targetDeviceId = targetSocket.handshake.session?.deviceId;
          if (targetDeviceId) {
            safeEmitToDevice(io, targetUserId, targetDeviceId, "file:key-response", {
              fromUserId: seederId,
              fileId: fileId,
              key: key,
              error: error
            });
          }
        });
        logger.info('[P2P KEY] Key response relayed to requester');
        logger.debug(`[P2P KEY] Target: ${sanitizeForLog(targetUserId)}`);
      } else {
        logger.warn('[P2P KEY] Requester not found online');
        logger.debug(`[P2P KEY] Requester: ${sanitizeForLog(targetUserId)}`);
      }
    } catch (error) {
      logger.error('[P2P KEY] Error relaying key response', error);
    }
  });

  /**
   * Relay encryption key request for video conferencing (Signal Protocol encrypted)
   * Used when a participant joins a room and needs the frame encryption key
   */
  socket.on("video:key-request", (data) => {
    try {
      if (!isAuthenticated()) {
        logger.error('[VIDEO E2EE] Key request blocked - not authenticated');
        return;
      }

      const { targetUserId, channelId, signalMessage } = data;
      const requesterId = getUserId();
      
      logger.info('[VIDEO E2EE] User requesting key for channel');
      logger.debug(`[VIDEO E2EE] Requester: ${sanitizeForLog(requesterId)}, Channel: ${sanitizeForLog(channelId)}, Target: ${sanitizeForLog(targetUserId)}`);
      
      // Find target participant's socket and relay the key request
      const targetSockets = Array.from(io.sockets.sockets.values())
        .filter(s => s.handshake.session.uuid === targetUserId);
      
      if (targetSockets.length > 0) {
        targetSockets.forEach(targetSocket => {
          const targetDeviceId = targetSocket.handshake.session?.deviceId;
          if (targetDeviceId) {
            safeEmitToDevice(io, targetUserId, targetDeviceId, "video:key-request", {
              fromUserId: requesterId,
              channelId: channelId,
              signalMessage: signalMessage
            });
          }
        });
        logger.info('[VIDEO E2EE] Key request relayed to participant');
        logger.debug(`[VIDEO E2EE] Target: ${sanitizeForLog(targetUserId)}`);
      } else {
        logger.warn('[VIDEO E2EE] Participant not found online');
        logger.debug(`[VIDEO E2EE] Participant: ${sanitizeForLog(targetUserId)}`);
        // Send error back to requester
        socket.emit("video:key-response", {
          fromUserId: targetUserId,
          channelId: channelId,
          error: "Participant not online"
        });
      }
    } catch (error) {
      logger.error('[VIDEO E2EE] Error relaying key request', error);
    }
  });

  /**
   * Relay encryption key response for video conferencing (Signal Protocol encrypted)
   * Contains the LiveKit frame encryption key encrypted with Signal Protocol
   */
  socket.on("video:key-response", (data) => {
    try {
      if (!socket.handshake.session.uuid) {
        logger.error('[VIDEO E2EE] Key response blocked - not authenticated');
        return;
      }

      const { targetUserId, channelId, signalMessage, error } = data;
      const senderId = getUserId();
      
      logger.info('[VIDEO E2EE] User sending key for channel');
      logger.debug(`[VIDEO E2EE] Sender: ${sanitizeForLog(senderId)}, Channel: ${sanitizeForLog(channelId)}, Target: ${sanitizeForLog(targetUserId)}`);
      
      // Find requester's socket and relay the key response
      const targetSockets = Array.from(io.sockets.sockets.values())
        .filter(s => s.handshake.session.uuid === targetUserId);
      
      if (targetSockets.length > 0) {
        targetSockets.forEach(targetSocket => {
          const targetDeviceId = targetSocket.handshake.session?.deviceId;
          if (targetDeviceId) {
            safeEmitToDevice(io, targetUserId, targetDeviceId, "video:key-response", {
              fromUserId: senderId,
              channelId: channelId,
              signalMessage: signalMessage,
              error: error
            });
          }
        });
        logger.info('[VIDEO E2EE] Key response relayed to requester');
        logger.debug(`[VIDEO E2EE] Target: ${sanitizeForLog(targetUserId)}`);
      } else {
        logger.warn('[VIDEO E2EE] Requester not found online');
        logger.debug(`[VIDEO E2EE] Requester: ${sanitizeForLog(targetUserId)}`);
      }
    } catch (error) {
      logger.error('[VIDEO E2EE] Error relaying key response', error);
    }
  });

  // ============================================
  // VIDEO CONFERENCE PARTICIPANT MANAGEMENT
  // ============================================

  /**
   * Check participants in a channel (called by PreJoin screen)
   * Client asks: "How many participants are in this channel? Am I first?"
   */
  socket.on("video:check-participants", async (data) => {
    try {
      // Support both native (socket.data.userId) and web (socket.handshake.session.uuid) clients
      const userId = socket.data.userId || socket.handshake.session.uuid;
      
      if (!userId) {
        logger.error('[VIDEO PARTICIPANTS] Check blocked - not authenticated');
        socket.emit("video:participants-info", { error: "Not authenticated" });
        return;
      }

      const { channelId } = data;

      if (!channelId) {
        logger.error('[VIDEO PARTICIPANTS] Missing channelId');
        socket.emit("video:participants-info", { error: "Missing channelId" });
        return;
      }

      // Check if this is a meeting (starts with mtg_ or call_)
      const isMeeting = channelId.startsWith('mtg_') || channelId.startsWith('call_');
      
      if (isMeeting) {
        // For meetings: verify meeting exists and user is participant
        const meeting = await meetingService.getMeeting(channelId);
        
        if (!meeting) {
          logger.error('[VIDEO PARTICIPANTS] Meeting not found');
          logger.debug(`[VIDEO PARTICIPANTS] MeetingId: ${sanitizeForLog(channelId)}`);
          socket.emit("video:participants-info", { error: "Meeting not found" });
          return;
        }
        
        // Check if user is creator, participant, invited, or the source_user (person being called in 1:1)
        const isCreator = meeting.created_by === userId;
        const isParticipant = meeting.participants && meeting.participants.some(p => p.uuid === userId);
        const isInvited = meeting.invited_participants && meeting.invited_participants.includes(userId);
        const isSourceUser = meeting.source_user_id === userId; // Person being called in 1:1 instant call
        
        if (!isCreator && !isParticipant && !isInvited && !isSourceUser) {
          logger.error('[VIDEO PARTICIPANTS] User not authorized for meeting');
          logger.debug('[VIDEO PARTICIPANTS] Details:', {
            channelId: sanitizeForLog(channelId),
            userId: sanitizeForLog(userId),
            created_by: sanitizeForLog(meeting.created_by),
            source_user_id: sanitizeForLog(meeting.source_user_id)
          });
          socket.emit("video:participants-info", { error: "Not authorized for this meeting" });
          return;
        }
        
        // Get active participants from memory (participants who have joined video)
        const participants = getVideoParticipants(channelId);
        
        // Filter out requesting user from count (they're not "in" yet)
        const otherParticipants = participants.filter(p => p.userId !== userId);
        
        logger.info(`[VIDEO PARTICIPANTS] Check for meeting: ${otherParticipants.length} active participants`);
        logger.debug(`[VIDEO PARTICIPANTS] Meeting: ${sanitizeForLog(channelId)}`);
        
        socket.emit("video:participants-info", {
          channelId: channelId,
          participantCount: otherParticipants.length,
          isFirstParticipant: otherParticipants.length === 0,
          participants: otherParticipants.map(p => ({
            userId: p.userId,
            joinedAt: p.joinedAt,
            hasE2EEKey: p.hasE2EEKey
          }))
        });
      } else {
        // For channels: check channel membership
        const membership = await ChannelMembers.findOne({
          where: {
            userId: userId,
            channelId: channelId
          }
        });

        if (!membership) {
          logger.error('[VIDEO PARTICIPANTS] User not member of channel');
          socket.emit("video:participants-info", { error: "Not a member of this channel" });
          return;
        }

        // Get active participants
        const participants = getVideoParticipants(channelId);
        
        // Filter out requesting user from count (they're not "in" yet)
        const otherParticipants = participants.filter(p => p.userId !== userId);
        
        logger.info(`[VIDEO PARTICIPANTS] Check for channel: ${otherParticipants.length} active participants`);
        logger.debug(`[VIDEO PARTICIPANTS] Channel: ${sanitizeForLog(channelId)}`);

        socket.emit("video:participants-info", {
          channelId: channelId,
          participantCount: otherParticipants.length,
          isFirstParticipant: otherParticipants.length === 0,
          participants: otherParticipants.map(p => ({
            userId: p.userId,
            joinedAt: p.joinedAt,
            hasE2EEKey: p.hasE2EEKey
          }))
        });
      }
    } catch (error) {
      logger.error('[VIDEO PARTICIPANTS] Error checking participants', error);
      socket.emit("video:participants-info", { error: "Internal server error" });
    }
  });

  /**
   * Register as participant (called by PreJoin screen after device selection)
   * Supports both channels and meetings
   * Client says: "I'm about to join, add me to the list"
   */
  socket.on("video:register-participant", async (data) => {
    try {
      if (!isAuthenticated()) {
        logger.error('[VIDEO PARTICIPANTS] Register blocked - not authenticated');
        return;
      }

      const { channelId } = data; // Can be actual channelId or meetingId
      const userId = getUserId();
      const deviceId = getDeviceId();

      if (!channelId) {
        logger.error('[VIDEO PARTICIPANTS] Missing channelId/meetingId');
        return;
      }

      // Check if it's a meeting ID (starts with mtg_ or call_)
      const isMeeting = channelId.startsWith('mtg_') || channelId.startsWith('call_');

      if (isMeeting) {
        // Meeting/call participant registration
        const meeting = await meetingService.getMeeting(channelId);
        
        if (!meeting) {
          logger.error('[VIDEO PARTICIPANTS] Meeting not found');
          logger.debug(`[VIDEO PARTICIPANTS] MeetingId: ${sanitizeForLog(channelId)}`);
          return;
        }

        // Check if user is participant
        const isParticipant = meeting.created_by === userId ||
                             meeting.participants?.some(p => p.user_id === userId) ||
                             meeting.invited_participants?.includes(userId);

        if (!isParticipant) {
          logger.error('[VIDEO PARTICIPANTS] User not participant of meeting');
          return;
        }

        // Add to memory store
        await meetingService.addParticipant(channelId, {
          user_id: userId,
          device_id: deviceId,
          role: meeting.created_by === userId ? 'meeting_owner' : 'meeting_member'
        });

        // Mark LiveKit room as active
        meetingService.updateLiveKitRoom(channelId, true, [userId]);
        
        // Mark user as busy in presence service
        presenceService.onUserJoinedRoom(userId, channelId).then(status => {
          socket.broadcast.emit('presence:update', {
            user_id: userId,
            status: status,
            last_seen: new Date()
          });
        }).catch(err => {
          logger.error('[PRESENCE] Error marking user as busy', err);
        });

        logger.info('[VIDEO PARTICIPANTS] User registered for meeting');
        logger.debug('[VIDEO PARTICIPANTS] Registration details:', {
          userId: sanitizeForLog(userId),
          meetingId: sanitizeForLog(channelId)
        });

      } else {
        // Channel video call registration
        const membership = await ChannelMembers.findOne({
          where: {
            userId: userId,
            channelId: channelId
          }
        });

        if (!membership) {
          logger.error('[VIDEO PARTICIPANTS] User not member of channel');
          return;
        }

        logger.info('[VIDEO PARTICIPANTS] User registered for channel');
        logger.debug('[VIDEO PARTICIPANTS] Registration details:', {
          userId: sanitizeForLog(userId),
          channelId: sanitizeForLog(channelId)
        });
      }

      // Add to Socket.IO room tracking (for both channels and meetings)
      addVideoParticipant(channelId, userId, socket.id);

      // Join Socket.IO room
      socket.join(channelId);

      // Notify other participants
      socket.to(channelId).emit("video:participant-joined", {
        userId: userId,
        joinedAt: Date.now()
      });

    } catch (error) {
      logger.error('[VIDEO PARTICIPANTS] Error registering participant', error);
    }
  });

  /**
   * Confirm E2EE key received (called after successful key exchange)
   * Client says: "I have the encryption key now"
   */
  socket.on("video:confirm-e2ee-key", async (data) => {
    try {
      if (!isAuthenticated()) {
        logger.error('[VIDEO PARTICIPANTS] Key confirm blocked - not authenticated');
        return;
      }

      const { channelId } = data;
      const userId = getUserId();

      if (!channelId) {
        logger.error('[VIDEO PARTICIPANTS] Missing channelId');
        return;
      }

      // Update key status
      updateParticipantKeyStatus(channelId, socket.id, true);

      // Notify other participants
      socket.to(channelId).emit("video:participant-key-confirmed", {
        userId: userId
      });

      logger.info('[VIDEO PARTICIPANTS] User confirmed E2EE key');
      logger.debug('[VIDEO PARTICIPANTS] Key confirmation details:', {
        userId: sanitizeForLog(userId),
        channelId: sanitizeForLog(channelId)
      });
    } catch (error) {
      logger.error('[VIDEO PARTICIPANTS] Error confirming key', error);
    }
  });

  /**
   * Leave channel or meeting (called when user closes video call)
   * Supports both channels and meetings
   * Client says: "I'm leaving the call"
   */
  socket.on("video:leave-channel", async (data) => {
    try {
      if (!isAuthenticated()) {
        logger.error('[VIDEO PARTICIPANTS] Leave blocked - not authenticated');
        return;
      }

      const { channelId } = data;
      const userId = getUserId();
      const deviceId = getDeviceId();

      if (!channelId) {
        logger.error('[VIDEO PARTICIPANTS] Missing channelId');
        return;
      }

      // Check if it's a meeting
      const isMeeting = channelId.startsWith('mtg_') || channelId.startsWith('call_');

      if (isMeeting) {
        // Remove from meeting memory store
        const result = await meetingService.removeParticipant(channelId, userId, deviceId);
        
        if (result.isEmpty) {
          // Last participant left, mark room as inactive
          meetingService.updateLiveKitRoom(channelId, false, []);
          logger.info('[VIDEO PARTICIPANTS] Meeting now empty');
          logger.debug(`[VIDEO PARTICIPANTS] MeetingId: ${sanitizeForLog(channelId)}`);
        }
        
        // Mark user as no longer in room (recalculate presence)
        presenceService.onUserLeftRoom(userId, channelId).then(status => {
          socket.broadcast.emit('presence:update', {
            user_id: userId,
            status: status,
            last_seen: new Date()
          });
        }).catch(err => {
          logger.error('[PRESENCE] Error updating presence after leaving room', err);
        });
      }

      // Remove from Socket.IO tracking
      removeVideoParticipant(channelId, socket.id);

      // Leave Socket.IO room
      socket.leave(channelId);

      // Notify other participants
      socket.to(channelId).emit("video:participant-left", {
        userId: userId
      });

      logger.info(`[VIDEO PARTICIPANTS] User left ${isMeeting ? 'meeting' : 'channel'}`);
      logger.debug('[VIDEO PARTICIPANTS] Leave details:', {
        userId: sanitizeForLog(userId),
        channelId: sanitizeForLog(channelId),
        isMeeting
      });
    } catch (error) {
      logger.error('[VIDEO PARTICIPANTS] Error leaving channel', error);
    }
  });

  /**
   * Event handler to delete a specific item (1:1 message) for the current user/device as receiver
   * @param {Object} data - Contains itemId to delete
   */
  socket.on("deleteItem", async (data, callback) => {
    try {
      if (!isAuthenticated()) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = getUserId();
      const deviceId = getDeviceId();
      const { itemId } = data;

      if (!itemId) {
        return callback?.({ success: false, error: "Missing itemId" });
      }

      // Delete item where receiver and deviceReceiver match current session
      const deletedCount = await writeQueue.enqueue(async () => {
        return await Item.destroy({
          where: {
            itemId: itemId,
            receiver: userId,
            deviceReceiver: deviceId
          }
        });
      }, `deleteItem-${itemId}-${userId}-${deviceId}`);

      callback?.({ success: true, deletedCount });
    } catch (error) {
      logger.error('[SIGNAL SERVER] Error deleting item', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Event handler for disconnecting from a room
   */
  // ===== NEW GROUP ITEM API (Simplified Architecture) =====
  
  /**
   * Send a group item (message, reaction, file, etc.)
   * Uses GroupItem model - stores encrypted data ONCE for all members
   */
  socket.on("sendGroupItem", async (data) => {
    try {
      if (!isAuthenticated()) {
        logger.error('[GROUP ITEM] Not authenticated');
        socket.emit("groupItemError", { error: "Not authenticated" });
        return;
      }

      const { channelId, itemId, type, payload, cipherType, timestamp } = data;
      const userId = getUserId();
      const deviceId = getDeviceId();

      // Validate required fields
      if (!channelId || !itemId || !payload) {
        logger.error('[GROUP ITEM] Missing required fields');
        socket.emit("groupItemError", { error: "Missing required fields" });
        return;
      }

      // Check if user is member of channel
      const membership = await ChannelMembers.findOne({
        where: {
          userId: userId,
          channelId: channelId
        }
      });

      if (!membership) {
        logger.error('[GROUP ITEM] User not member of channel');
        socket.emit("groupItemError", { error: "Not a member of this channel" });
        return;
      }

      // Check for duplicate itemId
      const existing = await GroupItem.findOne({
        where: { itemId: itemId }
      });

      if (existing) {
        logger.info('[GROUP ITEM] Item already exists, skipping');
        logger.debug(`[GROUP ITEM] ItemId: ${sanitizeForLog(itemId)}`);
        socket.emit("groupItemDelivered", { itemId: itemId, existing: true });
        return;
      }

      // Create group item (stored ONCE for all members)
      const groupItem = await writeQueue.enqueue(async () => {
        return await GroupItem.create({
          itemId: itemId,
          channel: channelId,
          sender: userId,
          senderDevice: deviceId,
          type: type || 'message',
          payload: payload,
          cipherType: cipherType || 4,
          timestamp: timestamp || new Date()
        });
      }, `createGroupItem-${itemId}`);

      logger.info('[GROUP ITEM] Created group item');
      logger.debug('[GROUP ITEM] Create details:', {
        itemId: sanitizeForLog(itemId),
        channelId: sanitizeForLog(channelId)
      });

      // Get all channel members
      const members = await ChannelMembers.findAll({
        where: { channelId: channelId },
        include: [{
          model: User,
          attributes: ['uuid']
        }]
      });

      // Get all client devices for these members
      const memberUserIds = members.map(m => m.userId);
      const memberClients = await Client.findAll({
        where: {
          owner: { [require('sequelize').Op.in]: memberUserIds }
        }
      });

      // Broadcast to all member devices EXCEPT the specific sending device
      // The sending device already has the message via local callback
      // But sender's OTHER devices should receive it (they can decrypt with SenderKey)
      let deliveredCount = 0;
      const offlineMembers = new Set(); // Track offline members for push notifications
      
      for (const client of memberClients) {
        // Skip ONLY the specific sending device to prevent duplicate
        // Do NOT skip sender's other devices - they need the message too!
        if (client.owner === userId && client.device_id === deviceId) {
          continue;
        }
        
        const targetSocketId = deviceSockets.get(`${client.owner}:${client.device_id}`);
        if (targetSocketId) {
          safeEmitToDevice(io, client.owner, client.device_id, "groupItem", {
            itemId: itemId,
            channel: channelId,
            sender: userId,
            senderDevice: deviceId,
            type: type || 'message',
            payload: payload,
            cipherType: cipherType || 4,
            timestamp: timestamp || new Date().toISOString()
          });
          deliveredCount++;
        } else {
          // Device is offline - mark user for push notification
          if (client.owner !== userId) { // Don't notify sender's own devices
            offlineMembers.add(client.owner);
          }
        }
      }

      // Send push notifications to offline members (not the sender)
      if (offlineMembers.size > 0) {
        // Get sender info for notification
        const senderUser = await User.findOne({
          where: { uuid: userId },
          attributes: ['displayName', 'email']
        });
        const senderName = senderUser?.displayName || senderUser?.email || 'Someone';
        
        // Get channel info
        const channel = await Channel.findOne({
          where: { uuid: channelId },
          attributes: ['name']
        });
        const channelName = channel?.name || 'a group';
        
        // Send notification to each offline member
        for (const offlineMemberId of offlineMembers) {
          sendMessageNotification(
            offlineMemberId,
            senderName,
            `New message in ${channelName}`,
            {
              senderId: userId,
              channelId: channelId,
              itemId: itemId,
              type: 'group_message'
            }
          ).catch(err => logger.error('[PUSH] Error sending group message notification:', err));
        }
        
        logger.info(`[GROUP ITEM] Sent push notifications to ${offlineMembers.size} offline members`);
      }

      logger.info(`[GROUP ITEM] Broadcast to ${deliveredCount} devices`);

      // Confirm delivery to sender
      socket.emit("groupItemDelivered", {
        itemId: itemId,
        deliveredCount: deliveredCount,
        totalDevices: memberClients.length
      });

    } catch (error) {
      logger.error('[GROUP ITEM] Error in sendGroupItem', error);
      socket.emit("groupItemError", { error: "Internal server error" });
    }
  });

  /**
   * Delete a group item (for cleanup purposes)
   * This is used by the cleanup service to remove old messages
   */
  socket.on("deleteGroupItem", async (data, callback) => {
    try {
      if (!isAuthenticated()) {
        logger.error('[GROUP ITEM DELETE] Not authenticated');
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = getUserId();
      const { itemId } = data;

      if (!itemId) {
        logger.error('[GROUP ITEM DELETE] Missing itemId');
        return callback?.({ success: false, error: "Missing itemId" });
      }

      // Verify the user is the sender of this group item
      const groupItem = await GroupItem.findOne({
        where: { itemId: itemId }
      });

      if (!groupItem) {
        logger.info('[GROUP ITEM DELETE] Item not found');
        logger.debug(`[GROUP ITEM DELETE] ItemId: ${sanitizeForLog(itemId)}`);
        return callback?.({ success: true, deletedCount: 0 });
      }

      if (groupItem.sender !== userId) {
        logger.error('[GROUP ITEM DELETE] User is not the sender');
        return callback?.({ success: false, error: "Only the sender can delete this item" });
      }

      // Delete the group item
      const deletedCount = await writeQueue.enqueue(async () => {
        return await GroupItem.destroy({
          where: { itemId: itemId }
        });
      }, `deleteGroupItem-${itemId}-${userId}`);

      logger.info('[GROUP ITEM DELETE] Deleted group item');
      logger.debug('[GROUP ITEM DELETE] Delete details:', {
        itemId: sanitizeForLog(itemId),
        deletedCount
      });
      callback?.({ success: true, deletedCount });

    } catch (error) {
      logger.error('[GROUP ITEM DELETE] Error deleting group item', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Mark a group item as read
   */
  socket.on("markGroupItemRead", async (data) => {
    try {
      if (!isAuthenticated()) {
        logger.error('[GROUP ITEM READ] Not authenticated');
        return;
      }

      const { itemId } = data;
      const userId = getUserId();
      const deviceId = getDeviceId();

      if (!itemId) {
        logger.error('[GROUP ITEM READ] Missing itemId');
        return;
      }

      // Find the group item
      const groupItem = await GroupItem.findOne({
        where: { itemId: itemId }
      });

      if (!groupItem) {
        logger.error('[GROUP ITEM READ] Item not found');
        return;
      }

      // Check if user is member of channel
      const membership = await ChannelMembers.findOne({
        where: {
          userId: userId,
          channelId: groupItem.channel
        }
      });

      if (!membership) {
        logger.error('[GROUP ITEM READ] User not member of channel');
        return;
      }

      // Create or update read receipt
      await writeQueue.enqueue(async () => {
        const [receipt, created] = await GroupItemRead.findOrCreate({
          where: {
            itemId: groupItem.uuid,
            userId: userId,
            deviceId: deviceId
          },
          defaults: {
            readAt: new Date()
          }
        });
        return { receipt, created };
      }, `markGroupItemRead-${itemId}-${userId}-${deviceId}`);

      // Count total reads
      const readCount = await GroupItemRead.count({
        where: { itemId: groupItem.uuid }
      });

      // Count total members
      const memberCount = await ChannelMembers.count({
        where: { channelId: groupItem.channel }
      });

      const allRead = readCount >= memberCount;

      logger.info(`[GROUP ITEM READ] Item: ${readCount}/${memberCount} members read`);
      logger.debug(`[GROUP ITEM READ] ItemId: ${sanitizeForLog(itemId)}`);

      // Notify the sender about read status
      const senderSocketId = deviceSockets.get(`${groupItem.sender}:${groupItem.senderDevice}`);
      if (senderSocketId) {
        safeEmitToDevice(io, groupItem.sender, groupItem.senderDevice, "groupItemReadUpdate", {
          itemId: itemId,
          readBy: userId,
          readByDevice: deviceId,
          readCount: readCount,
          totalMembers: memberCount,
          allRead: allRead
        });
      }

      // If all members have read, delete from server (privacy feature)
      if (allRead) {
        logger.info('[GROUP ITEM READ] Item read by all members - deleting from server');
        logger.debug(`[GROUP ITEM READ] ItemId: ${sanitizeForLog(itemId)}`);
        
        // Delete all read receipts first
        await writeQueue.enqueue(async () => {
          await GroupItemRead.destroy({
            where: { itemId: groupItem.uuid }
          });
        }, `deleteGroupItemReads-${itemId}`);
        
        // Then delete the group item itself
        await writeQueue.enqueue(async () => {
          await groupItem.destroy();
        }, `deleteGroupItem-${itemId}`);
        
        logger.info('[GROUP ITEM READ] Item and all read receipts deleted');
        logger.debug(`[GROUP ITEM READ] ItemId: ${sanitizeForLog(itemId)}`);
      }

    } catch (error) {
      logger.error('[GROUP ITEM READ] Error in markGroupItemRead', error);
    }
  });

  // ==================== MEETINGS & CALLS SOCKET.IO EVENTS ====================
  // 
  // NOTE: For operations requiring immediate responses (create, update, delete),
  // use HTTP REST API routes instead (see /api/meetings, /api/calls, /api/external).
  // Socket.IO events below are for real-time notifications and presence only.
  //
  // ============================================================================

  /**
   * Meeting: Join room for real-time events
   * Required for receiving admission notifications
   */
  socket.on('meeting:join-room', async (data) => {
    try {
      logger.debug('[MEETING:JOIN-ROOM] Event received:', data);
      logger.debug('[MEETING:JOIN-ROOM] Socket authenticated:', isAuthenticated());
      
      const userId = getUserId();
      logger.debug('[MEETING:JOIN-ROOM] User ID:', userId);
      
      if (!userId) {
        logger.error('[MEETING:JOIN-ROOM] No user ID - authentication failed');
        return;
      }

      const { meeting_id } = data;
      if (!meeting_id) {
        logger.error('[MEETING:JOIN-ROOM] No meeting_id in data');
        return;
      }

      // Join the meeting socket room
      socket.join(`meeting:${meeting_id}`);
      logger.info('[MEETING:JOIN-ROOM] User joined meeting room');
      logger.debug('[MEETING:JOIN-ROOM] Details:', {
        userId: sanitizeForLog(userId),
        meetingId: sanitizeForLog(meeting_id)
      });
      
      // List all rooms this socket is in
      logger.debug('[MEETING:JOIN-ROOM] Socket rooms:', Array.from(socket.rooms));

      // Notify other participants
      socket.to(`meeting:${meeting_id}`).emit('meeting:participant_joined', {
        meeting_id,
        user_id: userId
      });
    } catch (error) {
      logger.error('[MEETING:JOIN-ROOM] Error joining meeting room', error);
    }
  });

  /**
   * Meeting: Participant left
   * Real-time notification only - broadcasts to other participants
   */
  const handleMeetingLeave = async (data) => {
    try {
      const userId = getUserId();
      if (!userId) {
        logger.error('[MEETING:LEAVE] No user ID');
        return;
      }

      const { meeting_id } = data;
      if (!meeting_id) {
        logger.error('[MEETING:LEAVE] No meeting_id');
        return;
      }
      
      // Leave meeting room
      socket.leave(`meeting:${meeting_id}`);
      logger.info('[MEETING:LEAVE] User left meeting room');
      logger.debug('[MEETING:LEAVE] Details:', {
        userId: sanitizeForLog(userId),
        meetingId: sanitizeForLog(meeting_id)
      });

      // Notify other participants
      socket.to(`meeting:${meeting_id}`).emit('meeting:participant_left', {
        meeting_id,
        user_id: userId
      });
    } catch (error) {
      logger.error('[MEETING:LEAVE] Error handling participant leave', error);
    }
  };
  
  socket.on('meeting:leave', handleMeetingLeave);
  socket.on('meeting:leave-room', handleMeetingLeave); // Alias for consistency

  /**
   * REMOVED: Old insecure participant:send_e2ee_key_to_guest handler
   * Replaced with Signal Protocol encrypted handler: participant:meeting_e2ee_key_response
   */

  /**
   * NEW: Participant: Send E2EE key response via Signal Protocol encrypted message
   * Participant encrypts LiveKit E2EE key with Signal and sends to guest
   * Uses Signal Protocol for end-to-end encryption (replaces plaintext socket.io)
   */
  socket.on('participant:meeting_e2ee_key_response', async (data) => {
    try {
      const userId = getUserId();
      const deviceId = getDeviceId();
      if (!userId || !deviceId) {
        logger.error('[PARTICIPANT] No userId/deviceId for Signal E2EE key response');
        return;
      }

      const { 
        guest_session_id, 
        meeting_id,
        ciphertext, // Signal Protocol encrypted LiveKit E2EE key
        messageType, // 3 = PreKey, 1 = Signal
        request_id 
      } = data;

      logger.info('[PARTICIPANT] Sending Signal-encrypted E2EE key to guest');
      logger.debug('[PARTICIPANT] E2EE key details:', {
        userId: sanitizeForLog(userId),
        deviceId: sanitizeForLog(deviceId),
        guestSessionId: sanitizeForLog(guest_session_id)
      });

      // Send encrypted response to guest's personal room on /external namespace
      io.of('/external').to(`guest:${guest_session_id}`).emit('participant:meeting_e2ee_key_response', {
        participant_user_id: userId,
        participant_device_id: deviceId,
        meeting_id: meeting_id,
        ciphertext: ciphertext,
        messageType: messageType,
        request_id: request_id,
        timestamp: Date.now()
      });

      logger.info('[PARTICIPANT] Signal-encrypted E2EE key sent to guest');
      logger.debug(`[PARTICIPANT] Guest session: ${sanitizeForLog(guest_session_id)}`);
    } catch (error) {
      logger.error('[PARTICIPANT] Error sending Signal E2EE key to guest', error);
    }
  });

  /**
   * Participant: Send Signal message to guest
   * For Signal protocol session establishment
   */
  socket.on('participant:signal_message_to_guest', async (data) => {
    try {
      const userId = getUserId();
      const deviceId = getDeviceId();
      if (!userId || !deviceId) {
        logger.error('[PARTICIPANT] No userId/deviceId for Signal message');
        return;
      }

      const { guest_session_id, encrypted_message, message_type } = data;

      logger.info('[PARTICIPANT] Sending Signal message to guest');
      logger.debug('[PARTICIPANT] Signal message details:', {
        userId: sanitizeForLog(userId),
        deviceId: sanitizeForLog(deviceId),
        messageType: sanitizeForLog(message_type),
        guestSessionId: sanitizeForLog(guest_session_id)
      });

      // Send directly to guest's personal room
      io.of('/external').to(`guest:${guest_session_id}`).emit('participant:signal_message', {
        participant_user_id: userId,
        participant_device_id: deviceId,
        encrypted_message,
        message_type,
        timestamp: Date.now()
      });

      logger.info('[PARTICIPANT] Signal message sent to guest');
      logger.debug(`[PARTICIPANT] Guest session: ${sanitizeForLog(guest_session_id)}`);
    } catch (error) {
      logger.error('[PARTICIPANT] Error sending Signal message to guest', error);
    }
  });

  /**
   * Call: Send incoming call notification (phone-style ringtone)
   * Real-time notification - triggers ringtone on recipient devices
   */
  socket.on('call:notify', async (data) => {
    try {
      const userId = getUserId();
      const deviceId = getDeviceId();
      if (!userId) return;

      const { meeting_id, recipient_ids } = data;
      
      // Get meeting details for context
      const meeting = await meetingService.getMeeting(meeting_id);
      if (!meeting) {
        logger.error('[CALL] Meeting not found');
        logger.debug(`[CALL] MeetingId: ${sanitizeForLog(meeting_id)}`);
        return;
      }

      // Get caller profile
      const caller = await User.findOne({ where: { uuid: userId } });
      const callerName = caller?.displayName || 'Unknown';

      // Send call notification to each recipient
      for (const recipientId of recipient_ids) {
        logger.info('[CALL] Processing notification for recipient');
        logger.debug(`[CALL] RecipientId: ${sanitizeForLog(recipientId)}`);
        
        // Check if user is online
        const isOnline = await presenceService.isOnline(recipientId);
        logger.debug('[CALL] Recipient online status:', { recipientId: sanitizeForLog(recipientId), isOnline });
        
        if (isOnline) {
          // Update participant status to ringing
          await meetingService.updateParticipantStatus(meeting_id, recipientId, 'ringing');

          // Create call notification payload
          const notificationPayload = {
            callerId: userId,
            callerName: callerName,
            meetingId: meeting_id,
            callType: meeting.is_instant_call ? 'instant' : 'scheduled',
            channelId: meeting.channel_id || null,
            channelName: meeting.title || 'Call',
            timestamp: new Date().toISOString(),
          };
          
          // Get all recipient devices
          const recipientClients = await Client.findAll({
            where: { owner: recipientId }
          });
          
          // Send encrypted notification to each device
          for (const client of recipientClients) {
            const itemId = `call_${meeting_id}_${recipientId}_${client.device_id}_${Date.now()}`;
            
            try {
              // Store notification in database as a system message
              await writeQueue.enqueue(async () => {
                return await Item.create({
                  sender: userId,
                  deviceSender: deviceId,
                  receiver: recipientId,
                  deviceReceiver: client.device_id,
                  type: 'call_notification',
                  payload: JSON.stringify(notificationPayload),
                  cipherType: 0, // System message, not encrypted
                  itemId: itemId
                });
              }, `callNotify-${itemId}`);
              
              // Send to device if online
              const success = safeEmitToDevice(io, recipientId, client.device_id, "receiveItem", {
                sender: userId,
                senderDeviceId: deviceId,
                recipient: recipientId,
                type: 'call_notification',
                payload: JSON.stringify(notificationPayload),
                cipherType: 0,
                itemId: itemId,
              });
              
              if (success) {
                logger.info('[CALL] Sent call notification to device');
                logger.debug('[CALL] Notification details:', {
                  recipientId: sanitizeForLog(recipientId),
                  deviceId: sanitizeForLog(client.device_id)
                });
              } else {
                logger.warn('[CALL] Failed to send call notification (device not connected)');
                logger.debug('[CALL] Device details:', {
                  recipientId: sanitizeForLog(recipientId),
                  deviceId: sanitizeForLog(client.device_id)
                });
              }
            } catch (e) {
              logger.error('[CALL] Error sending notification to device', e);
              logger.debug('[CALL] Device details:', {
                recipientId: sanitizeForLog(recipientId),
                deviceId: sanitizeForLog(client.device_id)
              });
            }
          }

          // Notify caller that user is ringing
          socket.emit('call:ringing', {
            meeting_id,
            user_id: recipientId
          });
        }
      }
    } catch (error) {
      logger.error('[CALL] Error notifying call', error);
    }
  });

  /**
   * Call: Accept incoming call
   * Real-time notification - broadcasts acceptance to caller
   */
  socket.on('call:accept', async (data) => {
    try {
      const userId = getUserId();
      if (!userId) return;

      const { meeting_id } = data;

      // Notify caller and other participants
      const meeting = await meetingService.getMeeting(meeting_id);
      for (const p of meeting.participants) {
        emitToUser(io, p.user_id, 'call:accepted', {
          meeting_id,
          user_id: userId
        });
      }
    } catch (error) {
      logger.error('[CALL] Error accepting call', error);
    }
  });

  /**
   * Call: Decline incoming call
   * Real-time notification - broadcasts decline to caller
   */
  socket.on('call:decline', async (data) => {
    try {
      const userId = getUserId();
      if (!userId) return;

      const { meeting_id, reason } = data;

      // Notify caller
      const meeting = await meetingService.getMeeting(meeting_id);
      emitToUser(io, meeting.created_by, 'call:declined', {
        meeting_id,
        user_id: userId,
        reason: reason || 'declined' // Forward the decline reason (timeout vs manual)
      });
    } catch (error) {
      logger.error('[CALL] Error declining call', error);
    }
  });

  // ==================== END MEETINGS & CALLS EVENTS ====================

  socket.on("disconnect", () => {
    const userId = socket.handshake.session?.uuid;
    const deviceId = socket.handshake.session?.deviceId;
    
    logger.info('[SOCKET] Client disconnected');
    logger.debug('[SOCKET] Disconnect details:', {
      socketId: socket.id,
      userId: sanitizeForLog(userId),
      deviceId: sanitizeForLog(deviceId)
    });
    
    // Handle meeting/call participant disconnect
    if (userId) {
      // Unregister socket from presence service
      presenceService.onSocketDisconnected(userId, socket.id).then(status => {
        // Broadcast status update
        if (status === 'offline') {
          socket.broadcast.emit('presence:user_disconnected', {
            user_id: userId,
            last_seen: new Date()
          });
        } else {
          socket.broadcast.emit('presence:update', {
            user_id: userId,
            status: status,
            last_seen: new Date()
          });
        }
      }).catch(err => {
        logger.error('[PRESENCE] Error unregistering socket', err);
      });
      
      // Handle instant call cleanup (WebSocket-based)
      meetingCleanupService.handleParticipantDisconnect(userId).catch(err => {
        logger.error('[MEETING CLEANUP] Error handling disconnect', err);
      });
      
      // Handle external participant disconnect
      if (socket.data.externalSessionId) {
        externalParticipantService.markLeft(socket.data.externalSessionId).catch(err => {
          logger.error('[EXTERNAL] Error marking session left', err);
        });
      }
    }
    
    if(userId && deviceId) {
      const deviceKey = `${userId}:${deviceId}`;
      deviceSockets.delete(deviceKey);
      logger.info('[SOCKET] Cleaned up deviceSockets entry');
      logger.debug('[SOCKET] Device cleanup:', {
        deviceKey,
        remainingDevices: deviceSockets.size
      });
      
      // Clean up P2P file sharing announcements (with deviceId)
      const fileRegistry = require('./store/fileRegistry');
      fileRegistry.handleUserDisconnect(userId, deviceId);
    }
    
    // CRITICAL: Reset client ready state to prevent stale connections
    socket.clientReady = false;

    // NEW: Cleanup video participants
    activeVideoParticipants.forEach((participants, channelId) => {
      const beforeSize = participants.size;
      removeVideoParticipant(channelId, socket.id);
      const afterSize = getVideoParticipants(channelId).length;
      
      if (beforeSize !== afterSize && userId) {
        // Notify other participants in this channel
        socket.to(channelId).emit("video:participant-left", {
          userId: userId
        });
        logger.info('[VIDEO PARTICIPANTS] User removed from channel due to disconnect');
        logger.debug('[VIDEO PARTICIPANTS] Removal details:', {
          userId: sanitizeForLog(userId),
          channelId: sanitizeForLog(channelId)
        });
      }
    });

    if (!rooms) return;


    Object.keys(rooms).forEach((room) => {
        const roomSeeders = rooms[room].seeders;
        const roomFiles = rooms[room].share && rooms[room].share.files;
        const roomParticipants = rooms[room].participants;

        if (roomParticipants && roomParticipants[socket.id]) {
          delete roomParticipants[socket.id];
          socket.to(room).emit("message", socket.id, "leave", "");
          const hourFuture = new Date(Date.now() + 60 * 60 * 1000).getTime();
          const meetingTime = new Date(rooms[room].meetingSettings.meetingDate).getTime();
          if (Object.keys(roomParticipants).length === 0 && hourFuture < meetingTime) {
            delete rooms[room];
          }
        }

        if (!roomSeeders) return;

        if (roomSeeders[socket.id]) {
            delete roomSeeders[socket.id];
            socket.to(rooms[room].host).emit("currentPeers", Object.keys(roomSeeders).length - 1);
        }

        if (!roomFiles) return;

        Object.keys(roomFiles).forEach((file) => {
            const fileSeeders = roomFiles[file].seeders;
            const socketIndex = fileSeeders.indexOf(socket.id);

            if (socketIndex !== -1) {
                fileSeeders.splice(socketIndex, 1);
                socket.to(rooms[room].host).emit("currentFilePeers", file, Object.keys(fileSeeders).length);
            }

            if (fileSeeders.length === 0) {
                delete roomFiles[file];
            }
        });

        socket.to(room).emit("getFiles", roomFiles);
    });
  });

  /**
   * Event handler for setting the number of download slots for a seeder
   * @param {string} room - The ID of the room
   * @param {number} slots - The number of download slots
   */
  socket.on("setSlots", (room, slots) => {
    if (!isValidUUID(room) || !rooms[room]) return;

    // socket.id is trusted (generated by Socket.IO), but ensure it exists
    if (!socket.id || typeof socket.id !== 'string') return;
    const seeder = rooms[room].seeders[socket.id] || (rooms[room].seeders[socket.id] = { peers: 0, slots: 0 });

    seeder.slots = Number(slots);
  });

  /**
   * Event handler for setting the number of connected peers for a seeder
   * @param {string} room - The ID of the room
   * @param {number} peers - The number of connected peers
   */
  socket.on("setPeers", (room, peers) => {
    if (!isValidUUID(room) || !rooms[room]) return;

    // socket.id is trusted (generated by Socket.IO), but ensure it exists
    if (!socket.id || typeof socket.id !== 'string') return;
    const seeder = rooms[room].seeders[socket.id] || (rooms[room].seeders[socket.id] = { peers: 0 });

    seeder.peers += peers;
    if (seeder.peers < 0) seeder.peers = 0;

    if (seeder.level !== undefined && seeder.score !== undefined) {
        let scoreStep = 1 / seeder.slots;
        seeder.score = (100.0 - (seeder.level * 10)) - (scoreStep * seeder.peers);
    }
  });

  /**
   * Event handler for starting or stopping streaming in a room
   * @param {string} room - The ID of the room
   * @param {string} host - The ID of the host socket
   */
  socket.on("stream", (room, host) => {
    if (!isValidUUID(room) || !rooms[room]) return;

    // socket.id is trusted (generated by Socket.IO), but ensure it exists
    if (!socket.id || typeof socket.id !== 'string') return;
    const seeder = rooms[room].seeders[socket.id] || (rooms[room].seeders[socket.id] = {});

    if (rooms[room].host === socket.id) {
        rooms[room].stream = true;
        seeder.level = 0;
        seeder.score = 100.0;
    }

    if (host) {
        seeder.level = ((rooms[room].seeders[host] && rooms[room].seeders[host].level) || 0) + 1;
        seeder.score = 100.0 - (seeder.level * 10);
        seeder.peers = 0;
        seeder.slots = 0;
    }
  });

  /**
 * Event handler for offering a file for download in a room
 * @param {string} room - The ID of the room
 * @param {Object} file - The file object containing name and size
 */
  socket.on("offerFile", (room, file) => {
    if (!isValidUUID(room) || !rooms[room]) return;

    // Sanitize filename to prevent prototype pollution
    if (!file || !file.name || typeof file.name !== 'string') return;
    const safeFilename = '$' + file.name;

    const roomFiles = rooms[room].share.files || {};

    if (rooms[room].host === socket.id) {
        roomFiles[safeFilename] = { size: file.size, seeders: [socket.id], originalName: file.name };
    } else if (roomFiles[safeFilename] &&
        roomFiles[safeFilename].size === file.size &&
        !roomFiles[safeFilename].seeders.includes(socket.id)) {
        roomFiles[safeFilename].seeders.push(socket.id);
    }

    rooms[room].share.files = roomFiles;
    socket.to(room).emit("getFiles", roomFiles);
    socket.to(rooms[room].host).emit("currentFilePeers", file.name, Object.keys(rooms[room].share.files[safeFilename].seeders).length);
  });

  /**
   * Event handler for getting the shared files in a room
   * @param {string} room - The ID of the room
   * @param {Callback} callback - Callback function to be invoked with the shared files
   */
  socket.on("getFiles", (room, callback) => {
    if (!rooms[room] || !rooms[room].share.files) return;

    socket.join(room);
    socket.to(socket.id).emit("getFiles", rooms[room].share.files);

    if (typeof callback === "function") {
        callback(rooms[room].share.files);
    }
  });

  /**
   * Event handler for deleting a file from a room
   * @param {string} filename - The name of the file to delete
   */
  socket.on("deleteFile", (filename) => {
    // Sanitize filename to prevent prototype pollution
    const safeFilename = typeof filename === 'string' ? '$' + filename : null;
    if (!safeFilename) return;
    
    Object.entries(rooms).forEach(([id, room]) => {
        if (room.host !== socket.id) return;
        if (!room.share.files || !room.share.files[safeFilename]) return;

        delete room.share.files[safeFilename];
        socket.to(id).emit("getFiles", room.share.files);
    });
  });

  /**
   * Event handler for downloading a file from a room
   * @param {string} room - The ID of the room
   * @param {Object} file - The file object to download
   * @param {string} host - The ID of the host socket
   */
  socket.on("downloadFile", (room, file, host) => {
    if (!isValidUUID(room) || !rooms[room]) return;

    socket.to(host).emit("downloadFile", socket.id, file);
  });

  /**
   * Event handler for creating a meeting room
   * @param {string} room - The ID of the room
   * @param {string} host - The ID of the host socketst socket
   * @param {Object} settings - The meeting settings
   */
  socket.on("createMeeting", (room, host, settings) => {
    if (!isValidUUID(room) || !rooms[room]) return;
    rooms[room].meeting = true;
    rooms[room].meetingSettings = settings;
  });

  socket.on("message", (room, type, message) => {
    // Sanitize the message to prevent XSS
    const sanMessage = sanitizeHtml(message, {
      allowedTags: [], // Remove all HTML tags
      allowedAttributes: {} // Remove all attributes
    });
    const sanType = sanitizeHtml(type, {
      allowedTags: [], // Remove all HTML tags
      allowedAttributes: {} // Remove all attributes
    });
    socket.to(room).emit("message", socket.id, sanType, sanMessage);
  });

  /*socket.on("meeting", (room, callback) => {
    if (!rooms[room] && rooms[room].meeting) return;
    const roomData = rooms[room];
    if (!rooms[room] && rooms[room].meeting) {
        callbackHandler(callback, {message: "Room not found", room});
        return;
    }
    socket.join(room);
    const participants = Object.entries(rooms[room].participants);

    for (const [participant, value] of participants) {
        if (participant !== socket.id) continue;

        socket.to(participant).emit("meeting", socket.id);
        callbackHandler(callback, {message: "Client connected", room, participant: participant});
        return;
    }
  });*/
  /**
   * Event handler for getting meeting settings
   * @param {string} room - The ID of the room
   * @param {Callback} callback - Callback function to be invoked with the meeting settings
   */
  socket.on("getMeetingSettings", (room, callback) => {
    if (!rooms[room] || !rooms[room].meeting) {
      callbackHandler(callback, { message: "Meeting not found", room });
      return;
    }
    const settings = rooms[room].meetingSettings;
    callbackHandler(callback, { message: "Meeting settings retrieved", room, settings });
  });

  socket.on("getParticipants", (room, callback) => {
    if (!rooms[room] || !rooms[room].meeting) {
      callbackHandler(callback, { message: "Meeting not found", room });
      return;
    }
    const participants = rooms[room].participants;
    callbackHandler(callback, { message: "Meeting settings retrieved", room, participants });
  });
  /**
   * Event handler for joining a meeting
   * @param {string} room - The ID of the meeting room
   * @param {string} name - The name of the participant
   */
  socket.on("joinMeeting", (room, name, callback) => {
    if (!rooms[room] || !rooms[room].meeting) return;
    socket.join(room);
    if (!rooms[room].participants) rooms[room].participants = {};
    rooms[room].participants[socket.id] = {name: name, id: socket.id};
    socket.to(room).emit("participantJoined", rooms[room].participants[socket.id]);
    socket.to(room).emit("message", socket.id, "join", "");
    callbackHandler(callback, { message: "meeting joined", participants: rooms[room].participants, id: socket.id });
  });
});
  // SOCKET.IO END

  // Use CORS configuration from config
  // SECURITY: Validate CORS configuration to prevent permissive settings
  const corsOrigin = config.cors.origin;
  const isWildcard = corsOrigin === '*' || corsOrigin === true;
  
  if (isWildcard && config.cors.credentials) {
    logger.error('[SECURITY] CORS origin cannot be "*" or true when credentials are enabled!');
    logger.error('[SECURITY] Please set CORS_ORIGINS environment variable to a comma-separated list of allowed origins');
    process.exit(1);
  }
  
  // Dynamic CORS handler to support mobile apps
  // Mobile apps identify themselves via X-PeerWave-App-Secret header
  // Web apps must match the whitelist
  const mobileAppSecret = 'peerwave-mobile-app';
  
  // Custom CORS middleware to access request headers
  app.use((req, res, next) => {
    const origin = req.headers.origin;
    const appSecret = req.headers['x-peerwave-app-secret'];
    const isTrustedMobileApp = appSecret === mobileAppSecret;
    
    // Allow same-origin requests (no Origin header)
    if (!origin) {
      return next();
    }
    
    // Allow trusted mobile apps (identified by secret header)
    if (isTrustedMobileApp) {
      res.setHeader('Access-Control-Allow-Origin', origin || '*');
      res.setHeader('Access-Control-Allow-Credentials', 'true');
      res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
      res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-PeerWave-App-Secret');
      
      if (req.method === 'OPTIONS') {
        return res.sendStatus(200);
      }
      return next();
    }
    
    // Allow localhost for development
    if (origin && (
        origin.startsWith('http://localhost') ||
        origin.startsWith('http://127.0.0.1') ||
        origin.startsWith('http://10.0.2.2'))) {
      res.setHeader('Access-Control-Allow-Origin', origin);
      res.setHeader('Access-Control-Allow-Credentials', 'true');
      res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
      res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-PeerWave-App-Secret');
      
      if (req.method === 'OPTIONS') {
        return res.sendStatus(200);
      }
      return next();
    }
    
    // Check against whitelist for web origins
    const allowedOrigins = Array.isArray(corsOrigin) ? corsOrigin : [corsOrigin];
    if (origin && allowedOrigins.indexOf(origin) !== -1) {
      res.setHeader('Access-Control-Allow-Origin', origin);
      res.setHeader('Access-Control-Allow-Credentials', 'true');
      res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
      res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-PeerWave-App-Secret');
      
      if (req.method === 'OPTIONS') {
        return res.sendStatus(200);
      }
      return next();
    }
    
    // Reject unknown origins
    res.status(403).send('Origin not allowed by CORS policy');
  });
  
  logger.info('[CORS] Configured with origins:', Array.isArray(corsOrigin) ? corsOrigin.join(', ') : corsOrigin);
  logger.info('[CORS] Allows trusted mobile apps with secret:', mobileAppSecret.substring(0, 10) + '...');

  // Register and signin webpages
  app.use(authRoutes);

// Database error handler middleware (must be after routes)
const dbErrorHandler = require('./middleware/dbErrorHandler');
app.use(dbErrorHandler);

/**
 * Room data object to store information about each room
 * @typedef {Object} RoomData
 * @property {string} host - The ID of the host socket
 * @property {Object} seeders - Object containing information about seeders in the room
 * @property {boolean} stream - Indicates if the room is currently streaming
 * @property {Object} share - Object containing shared files in the room
 */

/**
 * Object to store information about each seeder in a room
 * @typedef {Object} SeederData
 * @property {number} slots - Number of available download slots for the seeder
 * @property {number} peers - Number of connected peers to the seeder
 * @property {number} level - Level of the seeder in the streaming hierarchy
 * @property {number} score - Score of the seeder based on level and number of peers
 */

/**
 * Callback function type
 * @callback Callback
 * @param {any} data - The data to be passed to the callback function
 */



/**
 * Handles the callback function by invoking it with the provided data.
 *
 * @param {Callback} callback - The callback function to be invoked.
 * @param {any} data - The data to be passed to the callback function.
 */
function callbackHandler(callback, data) {
  if (typeof callback === "function") {
    callback(data);
  }
}

// Serve dynamic server_config.json with API server URL
app.get('/server_config.json', (req, res) => {
  const apiServer = config.app.url;
  res.json({ apiServer });
});

// Serve .well-known directory for Digital Asset Links (Android passkeys)
app.use('/.well-known', express.static(path.resolve(__dirname, 'public/.well-known'), {
  setHeaders: (res, path) => {
    if (path.endsWith('assetlinks.json')) {
      res.setHeader('Content-Type', 'application/json');
      res.setHeader('Access-Control-Allow-Origin', '*');
    }
  }
}));

// Serve static files from Flutter web build output
app.use(express.static(path.resolve(__dirname, 'web')));

// For SPA fallback
app.get('*', (req, res) => {
  res.sendFile(path.resolve(__dirname, 'web', 'index.html'));
});

// Cleanup and meeting services are initialized in the database initialization sequence
// (see end of file - after migrations and model are ready)

// Graceful shutdown handler
process.on('SIGTERM', async () => {
  logger.info('[SHUTDOWN] SIGTERM received, shutting down gracefully');
  
  try {
    process.exit(0);
  } catch (error) {
    logger.error('[SHUTDOWN] Error during shutdown', error);
    process.exit(1);
  }
});

process.on('SIGINT', async () => {
  logger.info('[SHUTDOWN] SIGINT received, shutting down gracefully');
  
  try {
    process.exit(0);
  } catch (error) {
    logger.error('[SHUTDOWN] Error during shutdown', error);
    process.exit(1);
  }
});

// Initialize database and start server
(async () => {
  logger.info('═'.repeat(35));
  logger.info('DATABASE INITIALIZATION');
  logger.info('═'.repeat(35));
  
  try {
    // Step 1: Run migrations
    const { runMigrations } = require('./db/init-database');
    await runMigrations();
    logger.info('[DATABASE] Migrations completed');
    
    // Step 2: Load model (will sync/create tables)
    const models = require('./db/model');
    
    // Step 3: Wait for model to be ready
    await models.dbReady;
    logger.info('[DATABASE] Model ready');
    
    // Assign models to global variables
    User = models.User;
    Channel = models.Channel;
    Thread = models.Thread;
    Client = models.Client;
    SignalSignedPreKey = models.SignalSignedPreKey;
    SignalPreKey = models.SignalPreKey;
    Item = models.Item;
    ChannelMembers = models.ChannelMembers;
    SignalSenderKey = models.SignalSenderKey;
    GroupItem = models.GroupItem;
    GroupItemRead = models.GroupItemRead;
    const Role = models.Role;
    
    // Step 4: Initialize standard roles
    async function initializeStandardRoles() {
        try {
            const standardRoles = [
                // Server scope roles
                { name: 'Administrator', description: 'Full server access with all permissions', scope: 'server', permissions: ['*'], standard: true },
                { name: 'Moderator', description: 'Server moderator with limited admin permissions', scope: 'server', permissions: ['user.manage', 'channel.manage', 'message.moderate', 'role.create', 'role.edit', 'role.delete'], standard: false },
                { name: 'User', description: 'Standard user role', scope: 'server', permissions: ['channel.join', 'channel.create', 'message.send', 'message.read'], standard: false },
                // Channel WebRTC scope roles
                { name: 'Channel Owner', description: 'Owner of a WebRTC channel with full control', scope: 'channelWebRtc', permissions: ['*'], standard: true },
                { name: 'Channel Moderator', description: 'WebRTC channel moderator', scope: 'channelWebRtc', permissions: ['user.add', 'user.kick', 'user.mute', 'stream.manage', 'role.assign', 'member.view'], standard: false },
                { name: 'Channel Member', description: 'Regular member of a WebRTC channel', scope: 'channelWebRtc', permissions: ['stream.view', 'stream.send', 'chat.send', 'member.view'], standard: false },
                // Channel Signal scope roles
                { name: 'Channel Owner', description: 'Owner of a Signal channel with full control', scope: 'channelSignal', permissions: ['*'], standard: true },
                { name: 'Channel Moderator', description: 'Signal channel moderator', scope: 'channelSignal', permissions: ['user.add', 'message.delete', 'user.kick', 'user.mute', 'role.assign', 'member.view'], standard: false },
                { name: 'Channel Member', description: 'Regular member of a Signal channel', scope: 'channelSignal', permissions: ['message.send', 'message.read', 'message.react', 'member.view'], standard: false }
            ];
            for (const roleData of standardRoles) {
                await Role.findOrCreate({ where: { name: roleData.name, scope: roleData.scope }, defaults: roleData });
            }
        } catch (error) {
            logger.error('[ROLES] Error initializing standard roles', error);
            throw error;
        }
    }
    await initializeStandardRoles();
    logger.info('[DATABASE] Standard roles initialized');
    
    // Step 5: Initialize cleanup and meeting services
    initCleanupJob();
    initMeetingReminderJob();
    runCleanup();
    const meetingCleanupService = require('./services/meetingCleanupService');
    const presenceService = require('./services/presenceService');
    meetingCleanupService.start();
    presenceService.start();
    logger.info('[DATABASE] Meeting and presence services initialized');
    
    // Step 6: Start server
    server.listen(port, async () => {
      logger.info(`[SERVER] Running on port ${port}`);
      
      // Start HMAC session auth cleanup jobs
      const { cleanupNonces, cleanupSessions } = require('./middleware/sessionAuth');
      const config = require('./config/config');
      
      // Clean up old nonces every 10 minutes (fixed - nonces are short-lived)
      setInterval(cleanupNonces, 10 * 60 * 1000);
      logger.info('[SERVER] HMAC nonce cleanup job started (every 10 minutes)');
      
      // Clean up expired sessions using configurable interval
      const cleanupHours = config.session.cleanupIntervalHours || 1;
      const cleanupMs = cleanupHours * 60 * 60 * 1000;
      setInterval(cleanupSessions, cleanupMs);
      logger.info(`[SERVER] HMAC session cleanup job started (every ${cleanupHours} hour${cleanupHours > 1 ? 's' : ''})`);
    });
  } catch (error) {
    logger.error('[DATABASE] Initialization failed', error);
    process.exit(1);
  }
})();

// Export deviceSockets accessor for cron jobs
function getDeviceSockets() {
  return deviceSockets;
}

module.exports = { getDeviceSockets };