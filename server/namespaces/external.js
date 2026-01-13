/**
 * External Guest Socket.IO Namespace
 * Handles WebSocket connections for unauthenticated external guests
 * 
 * Authentication: session_id + invitation_token
 * Namespace: /external
 */

const externalParticipantService = require('../services/externalParticipantService');
const logger = require('../utils/logger');
const { sanitizeForLog } = require('../utils/logSanitizer');

module.exports = function(io) {
  // Create /external namespace for guest connections
  const externalNamespace = io.of('/external');
  
  logger.info('[EXTERNAL WS] External guest namespace initialized on /external');

  externalNamespace.on('connection', async (socket) => {
    logger.debug(`[EXTERNAL WS] Guest connection attempt: ${socket.id}`);

    const { session_id, token, meeting_id } = socket.handshake.auth;

    // Validate authentication
    if (!session_id || !token || !meeting_id) {
      logger.warn('[EXTERNAL WS] Missing auth params');
      socket.emit('error', { message: 'Missing session_id, token, or meeting_id' });
      socket.disconnect(true);
      return;
    }

    try {
      // Validate session exists
      const session = await externalParticipantService.getSession(session_id);
      if (!session) {
        logger.warn('[EXTERNAL WS] Session not found');
        logger.debug(`[EXTERNAL WS] SessionId: ${sanitizeForLog(session_id)}`);
        socket.emit('error', { message: 'Invalid session' });
        socket.disconnect(true);
        return;
      }

      // Validate token matches meeting
      const validToken = await externalParticipantService.validateTokenForMeeting(token, meeting_id);
      if (!validToken) {
        logger.warn('[EXTERNAL WS] Invalid token for meeting');
        logger.debug(`[EXTERNAL WS] MeetingId: ${sanitizeForLog(meeting_id)}`);
        socket.emit('error', { message: 'Invalid or expired token' });
        socket.disconnect(true);
        return;
      }

      // Verify session belongs to this meeting
      if (session.meeting_id !== meeting_id) {
        logger.warn('[EXTERNAL WS] Session does not belong to meeting');
        logger.debug(`[EXTERNAL WS] Session: ${sanitizeForLog(session_id)}, Meeting: ${sanitizeForLog(meeting_id)}`);
        socket.emit('error', { message: 'Session mismatch' });
        socket.disconnect(true);
        return;
      }

      // Check if session expired
      const expired = await externalParticipantService.isSessionExpired(session_id);
      if (expired) {
        logger.warn('[EXTERNAL WS] Session expired');
        logger.debug(`[EXTERNAL WS] SessionId: ${sanitizeForLog(session_id)}`);
        socket.emit('error', { message: 'Session expired' });
        socket.disconnect(true);
        return;
      }

      // Authentication successful
      socket.data.session_id = session_id;
      socket.data.meeting_id = meeting_id;
      socket.data.display_name = session.display_name;
      socket.data.isGuest = true;

      // Join rooms
      socket.join(`meeting:${meeting_id}`);  // Broadcast room (all participants + guests)
      socket.join(`guest:${session_id}`);    // Personal room (direct messages)

      logger.info('[EXTERNAL WS] Guest joined meeting');
      logger.debug(`[EXTERNAL WS] Name: ${sanitizeForLog(session.display_name)}, Session: ${sanitizeForLog(session_id)}, Meeting: ${sanitizeForLog(meeting_id)}`);
      
      socket.emit('authenticated', { 
        success: true,
        session_id: session_id,
        meeting_id: meeting_id,
        display_name: session.display_name
      });

      // Log registered event listeners for debugging
      logger.info('[EXTERNAL WS] Guest authenticated and ready');
      logger.debug(`[EXTERNAL WS] SessionId: ${sanitizeForLog(session_id)}`);

      // ==================== GUEST EVENT HANDLERS ====================

      /**
       * REMOVED: Old insecure guest:request_e2ee_key handler
       * Replaced with Signal Protocol encrypted handler: guest:meeting_e2ee_key_request
       */

      /**
       * Guest sends Signal encrypted message to participant
       * Used for key exchange communication
       */
      socket.on('guest:signal_message', async (data) => {
        try {
          const { recipient_user_id, recipient_device_id, encrypted_message, message_type } = data;

          logger.info(`[EXTERNAL WS] Guest sending Signal message (${sanitizeForLog(message_type)})`);
          logger.debug(`[EXTERNAL WS] From: ${sanitizeForLog(session_id)}, To: ${sanitizeForLog(recipient_user_id)}:${sanitizeForLog(recipient_device_id)}`);

          // Find recipient's socket
          const deviceKey = `${recipient_user_id}:${recipient_device_id}`;
          const recipientSocketId = global.deviceSockets?.get(deviceKey);

          if (recipientSocketId) {
            const recipientSocket = io.sockets.sockets.get(recipientSocketId);
            if (recipientSocket) {
              recipientSocket.emit('guest:signal_message', {
                from_guest_session_id: session_id,
                from_guest_display_name: session.display_name,
                encrypted_message,
                message_type,
                timestamp: Date.now()
              });
              logger.info('[EXTERNAL WS] Signal message delivered');
              logger.debug(`[EXTERNAL WS] To: ${sanitizeForLog(deviceKey)}`);
            } else {
              logger.warn(`[EXTERNAL WS] Recipient socket not found: ${sanitizeForLog(recipientSocketId)}`);
            }
          } else {
            logger.warn('[EXTERNAL WS] Recipient not connected');
            logger.debug(`[EXTERNAL WS] DeviceKey: ${sanitizeForLog(deviceKey)}`);
          }
        } catch (error) {
          logger.error('[EXTERNAL WS] Error handling Signal message:', error);
          socket.emit('error', { message: 'Failed to send Signal message' });
        }
      });

      /**
       * NEW: Guest requests E2EE key via Signal Protocol encrypted message
       * Broadcasts to participants in meeting for encrypted response
       * Guest initiates: guest → participant (encrypted with Signal)
       */
      socket.on('guest:meeting_e2ee_key_request', async (data) => {
        try {
          const { 
            participant_user_id, 
            participant_device_id,
            ciphertext, // Signal Protocol encrypted request
            messageType, // 3 = PreKey, 1 = Signal
            request_id 
          } = data;

          logger.info('[EXTERNAL WS] Guest requesting E2EE key via Signal');
          logger.debug(`[EXTERNAL WS] From: ${sanitizeForLog(session_id)}, Target: ${sanitizeForLog(participant_user_id)}:${sanitizeForLog(participant_device_id)}`);

          // Broadcast to meeting participants on MAIN namespace
          // Participants will decrypt and respond with encrypted LiveKit E2EE key
          io.to(`meeting:${meeting_id}`).emit('guest:meeting_e2ee_key_request', {
            guest_session_id: session_id,
            guest_display_name: session.display_name,
            meeting_id: meeting_id,
            participant_user_id: participant_user_id,
            participant_device_id: participant_device_id,
            ciphertext: ciphertext,
            messageType: messageType,
            request_id: request_id || `${session_id}_${Date.now()}`,
            timestamp: Date.now()
          });

          logger.info('[EXTERNAL WS] Signal E2EE key request broadcasted');
          logger.debug(`[EXTERNAL WS] Meeting: ${sanitizeForLog(meeting_id)}`);
        } catch (error) {
          logger.error('[EXTERNAL WS] Error handling Signal E2EE key request:', error);
          socket.emit('error', { message: 'Failed to request E2EE key' });
        }
      });

      /**
       * Rate limiting: Track message counts
       */
      const rateLimiter = new Map();
      const RATE_LIMIT_WINDOW = 60000; // 1 minute
      const MAX_MESSAGES_PER_WINDOW = 100;

      socket.use(([event, ...args], next) => {
        const now = Date.now();
        const key = session_id;

        if (!rateLimiter.has(key)) {
          rateLimiter.set(key, { count: 0, resetAt: now + RATE_LIMIT_WINDOW });
        }

        const limit = rateLimiter.get(key);

        if (now > limit.resetAt) {
          // Reset window
          limit.count = 0;
          limit.resetAt = now + RATE_LIMIT_WINDOW;
        }

        limit.count++;

        if (limit.count > MAX_MESSAGES_PER_WINDOW) {
          logger.warn('[EXTERNAL WS] Rate limit exceeded for guest');
          logger.debug(`[EXTERNAL WS] SessionId: ${sanitizeForLog(session_id)}`);
          return next(new Error('Rate limit exceeded'));
        }

        next();
      });

      /**
       * Disconnect handler
       */
      socket.on('disconnect', async (reason) => {
        logger.info(`[EXTERNAL WS] Guest disconnected: ${sanitizeForLog(reason)}`);
        logger.debug(`[EXTERNAL WS] SessionId: ${sanitizeForLog(session_id)}`);
        
        try {
          // Mark session as left if they haven't joined yet
          if (session.admitted !== true) {
            await externalParticipantService.markLeft(session_id);
          }
        } catch (error) {
          logger.error('[EXTERNAL WS] Error marking guest as left:', error);
        }

        // Cleanup rate limiter
        rateLimiter.delete(session_id);
      });

    } catch (error) {
      logger.error('[EXTERNAL WS] Authentication error:', error);
      socket.emit('error', { message: 'Authentication failed' });
      socket.disconnect(true);
    }
  });

  return externalNamespace;
};
