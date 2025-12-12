/**
 * External Guest Socket.IO Namespace
 * Handles WebSocket connections for unauthenticated external guests
 * 
 * Authentication: session_id + invitation_token
 * Namespace: /external
 */

const externalParticipantService = require('../services/externalParticipantService');

module.exports = function(io) {
  // Create /external namespace for guest connections
  const externalNamespace = io.of('/external');
  
  console.log('[EXTERNAL WS] External guest namespace initialized on /external');

  externalNamespace.on('connection', async (socket) => {
    console.log(`[EXTERNAL WS] Guest connection attempt: ${socket.id}`);

    const { session_id, token, meeting_id } = socket.handshake.auth;

    // Validate authentication
    if (!session_id || !token || !meeting_id) {
      console.log('[EXTERNAL WS] ❌ Missing auth params');
      socket.emit('error', { message: 'Missing session_id, token, or meeting_id' });
      socket.disconnect(true);
      return;
    }

    try {
      // Validate session exists
      const session = await externalParticipantService.getSession(session_id);
      if (!session) {
        console.log(`[EXTERNAL WS] ❌ Session ${session_id} not found`);
        socket.emit('error', { message: 'Invalid session' });
        socket.disconnect(true);
        return;
      }

      // Validate token matches meeting
      const validToken = await externalParticipantService.validateTokenForMeeting(token, meeting_id);
      if (!validToken) {
        console.log(`[EXTERNAL WS] ❌ Invalid token for meeting ${meeting_id}`);
        socket.emit('error', { message: 'Invalid or expired token' });
        socket.disconnect(true);
        return;
      }

      // Verify session belongs to this meeting
      if (session.meeting_id !== meeting_id) {
        console.log(`[EXTERNAL WS] ❌ Session ${session_id} does not belong to meeting ${meeting_id}`);
        socket.emit('error', { message: 'Session mismatch' });
        socket.disconnect(true);
        return;
      }

      // Check if session expired
      const expired = await externalParticipantService.isSessionExpired(session_id);
      if (expired) {
        console.log(`[EXTERNAL WS] ❌ Session ${session_id} expired`);
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

      console.log(`[EXTERNAL WS] ✓ Guest ${session.display_name} (${session_id}) joined meeting ${meeting_id}`);
      
      socket.emit('authenticated', { 
        success: true,
        session_id: session_id,
        meeting_id: meeting_id,
        display_name: session.display_name
      });

      // Log registered event listeners for debugging
      const listenerEventName = `guest:request_e2ee_key:${meeting_id}`;
      console.log(`[EXTERNAL WS] Setting up listener for: ${listenerEventName}`);

      // ==================== GUEST EVENT HANDLERS ====================

      /**
       * Guest requests E2EE key from participant
       * Broadcasts to all participants in meeting room
       * Event name is meeting-specific: guest:request_e2ee_key:${meetingId}
       */
      socket.on(listenerEventName, async (data) => {
        try {
          const { participant_user_id, participant_device_id, request_id } = data;

          console.log(`[EXTERNAL WS] Guest ${session_id} requesting E2EE key from ${participant_user_id || 'all'}:${participant_device_id || 'all'} participants`);

          // Broadcast to meeting room on MAIN namespace (where participants are)
          // Guests are on /external namespace, participants are on / (root) namespace
          io.to(`meeting:${meeting_id}`).emit(`guest:request_e2ee_key:${meeting_id}`, {
            guest_session_id: session_id,
            guest_display_name: session.display_name,
            meeting_id: meeting_id,
            participant_user_id: participant_user_id || null,
            participant_device_id: participant_device_id || null,
            request_id: request_id || `${session_id}_${Date.now()}`,
            timestamp: Date.now()
          });

          console.log(`[EXTERNAL WS] ✓ E2EE key request emitted to meeting ${meeting_id} (main namespace)`);
        } catch (error) {
          console.error('[EXTERNAL WS] Error handling E2EE key request:', error);
          socket.emit('error', { message: 'Failed to request E2EE key' });
        }
      });

      /**
       * Guest sends Signal encrypted message to participant
       * Used for key exchange communication
       */
      socket.on('guest:signal_message', async (data) => {
        try {
          const { recipient_user_id, recipient_device_id, encrypted_message, message_type } = data;

          console.log(`[EXTERNAL WS] Guest ${session_id} sending Signal message (${message_type}) to ${recipient_user_id}:${recipient_device_id}`);

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
              console.log(`[EXTERNAL WS] ✓ Signal message delivered to ${deviceKey}`);
            } else {
              console.log(`[EXTERNAL WS] ⚠️ Recipient socket ${recipientSocketId} not found`);
            }
          } else {
            console.log(`[EXTERNAL WS] ⚠️ Recipient ${deviceKey} not connected`);
          }
        } catch (error) {
          console.error('[EXTERNAL WS] Error handling Signal message:', error);
          socket.emit('error', { message: 'Failed to send Signal message' });
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
          console.log(`[EXTERNAL WS] ⚠️ Rate limit exceeded for guest ${session_id}`);
          return next(new Error('Rate limit exceeded'));
        }

        next();
      });

      /**
       * Disconnect handler
       */
      socket.on('disconnect', async (reason) => {
        console.log(`[EXTERNAL WS] Guest ${session_id} disconnected: ${reason}`);
        
        try {
          // Mark session as left if they haven't joined yet
          if (session.admitted !== true) {
            await externalParticipantService.markLeft(session_id);
          }
        } catch (error) {
          console.error('[EXTERNAL WS] Error marking guest as left:', error);
        }

        // Cleanup rate limiter
        rateLimiter.delete(session_id);
      });

    } catch (error) {
      console.error('[EXTERNAL WS] Authentication error:', error);
      socket.emit('error', { message: 'Authentication failed' });
      socket.disconnect(true);
    }
  });

  return externalNamespace;
};
