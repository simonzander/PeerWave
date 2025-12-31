const express = require('express');
const externalParticipantService = require('../services/externalParticipantService');
const meetingService = require('../services/meetingService');
const { sanitizeForLog } = require('../utils/logSanitizer');

module.exports = function(io) {
  const router = express.Router();

/**
 * Validate meeting invitation token (external access)
 * GET /api/meetings/external/join/:token
 */
router.get('/meetings/external/join/:token', async (req, res) => {
  try {
    const { token } = req.params;
    console.log('[EXTERNAL] Validating invitation token:', token);

    const result = await externalParticipantService.validateInvitationToken(token);
    console.log('[EXTERNAL] Validation result:', result);

    if (!result) {
      console.log('[EXTERNAL] Invalid token - not found');
      return res.status(404).json({ error: 'Invalid invitation token' });
    }

    if (result.error === 'outside_time_window') {
      console.log('[EXTERNAL] Token outside time window');
      return res.status(403).json({
        error: 'Outside time window',
        message: 'This invitation is only valid 1 hour before and after the meeting start time.',
        meeting: {
          title: result.meeting.title,
          start_time: result.meeting.start_time
        }
      });
    }

    console.log('[EXTERNAL] Checking active participants for meeting:', result.meeting.meeting_id);
    // Check if meeting has any active participants (for conditional access)
    const hasParticipants = await meetingService.hasActiveParticipants(result.meeting.meeting_id);
    console.log('[EXTERNAL] Has active participants:', hasParticipants);

    res.json({
      meeting: {
        meeting_id: result.meeting.meeting_id,
        title: result.meeting.title,
        description: result.meeting.description,
        start_time: result.meeting.start_time,
        end_time: result.meeting.end_time,
        created_by: result.meeting.created_by,
        has_active_participants: hasParticipants
      }
    });
  } catch (error) {
    console.error('[EXTERNAL] Error validating invitation token:', error);
    console.error('[EXTERNAL] Error stack:', error.stack);
    res.status(500).json({ error: 'Failed to validate invitation', details: error.message });
  }
});

/**
 * Register external participant session
 * POST /api/meetings/external/register
 */
router.post('/meetings/external/register', async (req, res) => {
  try {
    const {
      invitation_token,
      display_name,
      identity_key_public,
      signed_pre_key,
      pre_keys
    } = req.body;

    // Validate required fields
    if (!invitation_token || !display_name) {
      return res.status(400).json({ error: 'Missing required fields: invitation_token, display_name' });
    }

    // Validate invitation token
    const result = await externalParticipantService.validateInvitationToken(invitation_token);
    
    if (!result || result.error) {
      return res.status(403).json({ error: 'Invalid or expired invitation' });
    }

    // Delete any existing sessions with the same token (kick duplicate sessions)
    const deletedCount = await externalParticipantService.deleteSessionsByToken(
      result.meeting.meeting_id,
      invitation_token
    );

    if (deletedCount > 0) {
      console.log(`Kicked ${deletedCount} duplicate session(s) for token ${invitation_token}`);
    }

    // Use provided keys or generate temporary ones
    let keys;
    if (identity_key_public && signed_pre_key && pre_keys) {
      keys = { identity_key_public, signed_pre_key, pre_keys };
    } else {
      // Generate temporary keys (for browser that doesn't have Signal keys)
      keys = externalParticipantService.generateTemporaryKeys();
    }

    // Create session
    const session = await externalParticipantService.createSession({
      meeting_id: result.meeting.meeting_id,
      display_name,
      identity_key_public: keys.identity_key_public || keys.identityKeyPublic,
      signed_pre_key: keys.signed_pre_key || keys.signedPreKey,
      pre_keys: keys.pre_keys || keys.preKeys
    });

    // Session created - guest will request admission after key exchange
    console.log(`[EXTERNAL] Created session ${session.session_id} for meeting ${result.meeting.meeting_id}`);

    res.status(201).json({
      session_id: session.session_id,
      meeting_id: session.meeting_id,
      display_name: session.display_name,
      admitted: session.admitted,
      admitted_by: session.admitted_by || null,
      admitted_at: session.joined_at || null,
      expires_at: session.expires_at,
      created_at: session.createdAt || new Date().toISOString(),
      updated_at: session.updatedAt || new Date().toISOString(),
      identity_key_public: session.identity_key_public,
      signed_pre_key: session.signed_pre_key,
      pre_keys: session.pre_keys
    });
  } catch (error) {
    console.error('Error registering external participant:', error);
    res.status(500).json({ error: 'Failed to register external participant' });
  }
});

/**
 * Get external participant keys (for E2EE key exchange)
 * GET /api/meetings/external/keys/:sessionId
 */
router.get('/meetings/external/keys/:sessionId', async (req, res) => {
  try {
    const { sessionId } = req.params;
    const { token } = req.query;

    // Validate token parameter
    if (!token) {
      return res.status(400).json({ error: 'Token required' });
    }

    const session = await externalParticipantService.getSession(sessionId);

    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }

    // Validate token matches session's meeting
    const validToken = await externalParticipantService.validateTokenForMeeting(
      token, 
      session.meeting_id
    );
    
    if (!validToken) {
      return res.status(403).json({ error: 'Invalid or expired token' });
    }

    // Check if session expired
    const expired = await externalParticipantService.isSessionExpired(sessionId);
    if (expired) {
      return res.status(403).json({ error: 'Session expired' });
    }

    res.json({
      session_id: session.session_id,
      display_name: session.display_name,
      identity_key_public: session.identity_key_public,
      signed_pre_key: session.signed_pre_key,
      pre_keys: session.pre_keys
    });
  } catch (error) {
    console.error('Error getting external keys:', error);
    res.status(500).json({ error: 'Failed to get keys' });
  }
});

/**
 * Get participant's Signal Protocol keybundle (for guest → participant E2EE)
 * GET /api/meetings/external/:sessionId/participant/:userId/:deviceId/keys
 * Used by guest to fetch authenticated participant's Signal keys
 * Requires valid session ID
 */
router.get('/meetings/external/:sessionId/participant/:userId/:deviceId/keys', async (req, res) => {
  try {
    const { sessionId, userId, deviceId } = req.params;

    // Validate session exists
    const session = await externalParticipantService.getSession(sessionId);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }

    // Check rate limit (3 fetches/min per participant per guest)
    const rateLimitKey = `${session.meeting_id}:${userId}:${deviceId}`;
    const allowed = await externalParticipantService.checkKeybundleRateLimit(rateLimitKey);
    if (!allowed) {
      return res.status(429).json({ 
        error: 'Rate limit exceeded',
        message: 'Maximum 3 keybundle fetches per minute per participant'
      });
    }

    // Get participant's keybundle from database
    const keybundle = await externalParticipantService.getParticipantKeybundle(
      session.meeting_id,
      userId,
      deviceId
    );

    if (!keybundle) {
      return res.status(404).json({ error: 'Participant keys not found' });
    }

    res.json(keybundle);
  } catch (error) {
    console.error('[EXTERNAL] Error getting participant keybundle:', error);
    res.status(500).json({ error: 'Failed to get participant keys' });
  }
});

/**
 * Get guest's Signal Protocol keybundle (for participant → guest E2EE)
 * GET /api/meetings/:meetingId/external/:sessionId/keys
 * Used by authenticated participant to fetch guest's Signal keys
 * Requires authentication (called by authenticated users only)
 */
router.get('/meetings/:meetingId/external/:sessionId/keys', async (req, res) => {
  try {
    const { meetingId, sessionId } = req.params;

    // Validate session exists and belongs to meeting
    const session = await externalParticipantService.getSession(sessionId);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }

    if (session.meeting_id !== meetingId) {
      return res.status(403).json({ error: 'Session does not belong to this meeting' });
    }

    // Get guest's keybundle and consume one pre-key
    const keybundle = await externalParticipantService.getGuestKeybundle(sessionId);

    if (!keybundle) {
      return res.status(404).json({ error: 'Guest keys not found' });
    }

    res.json(keybundle);
  } catch (error) {
    console.error('[EXTERNAL] Error getting guest keybundle:', error);
    res.status(500).json({ error: 'Failed to get guest keys' });
  }
});

/**
 * Get LiveKit room participants (authenticated users only)
 * GET /api/meetings/:meetingId/livekit-participants?token=xxx
 * Requires valid guest invitation token
 */
router.get('/meetings/:meetingId/livekit-participants', async (req, res) => {
  try {
    const { meetingId } = req.params;
    const { token } = req.query;
    
    // Validate token parameter
    if (!token) {
      return res.status(400).json({ error: 'Token required' });
    }
    
    // Validate token matches this meeting
    const validToken = await externalParticipantService.validateTokenForMeeting(token, meetingId);
    if (!validToken) {
      return res.status(403).json({ error: 'Invalid or expired token' });
    }
    
    // Get LiveKit room participants
    const livekitWrapper = require('../lib/livekit-wrapper');
    const RoomServiceClient = await livekitWrapper.getRoomServiceClient();
    const config = require('../config/config');
    const { sequelize, User } = require('../db/model');
    
    const roomService = new RoomServiceClient(
      config.livekit.url,
      config.livekit.apiKey,
      config.livekit.apiSecret
    );
    
    let participants = [];
    try {
      participants = await roomService.listParticipants(meetingId);
    } catch (error) {
      // Room might not exist yet
      if (error.message && error.message.includes('not found')) {
        participants = [];
      } else {
        throw error;
      }
    }
    
    // Filter out external guests (only return authenticated users)
    const authenticatedParticipants = participants.filter(p => {
      return !p.identity.startsWith('guest_');
    });
    
    // Get meeting details for end_time check
    const [meetings] = await sequelize.query(`
      SELECT end_time FROM meetings WHERE meeting_id = ?
    `, {
      replacements: [meetingId]
    });
    
    // Map to useful format
    const participantList = await Promise.all(
      authenticatedParticipants.map(async (p) => {
        // Parse identity (format: "userId:deviceId")
        const [userId, deviceIdStr] = p.identity.split(':');
        
        // Parse device ID - if missing or invalid, log warning
        const deviceId = parseInt(deviceIdStr);
        if (!deviceIdStr || isNaN(deviceId)) {
          console.warn(`[EXTERNAL] ⚠️ Invalid LiveKit identity format: "${sanitizeForLog(p.identity)}" (expected "userId:deviceId")`);
          return null; // Skip participants with malformed identities
        }
        
        // Get user info from database
        const user = await User.findOne({ where: { uuid: userId } });
        
        return {
          user_id: userId,
          device_id: deviceId,
          display_name: user?.displayName || 'Unknown',
          livekit_identity: p.identity
        };
      })
    );
    
    // Filter out null entries (participants with invalid identities)
    const validParticipants = participantList.filter(p => p !== null);
    
    res.json({
      participants: validParticipants,
      count: validParticipants.length,
      room_active: validParticipants.length > 0,
      meeting_end_time: meetings[0]?.end_time || null
    });
  } catch (error) {
    console.error('[EXTERNAL] Error getting LiveKit participants:', error);
    res.status(500).json({ error: 'Failed to get participants' });
  }
});

/**
 * Request admission (after key exchange)
 * POST /api/meetings/:meetingId/external/:sessionId/request-admission
 */
router.post('/meetings/:meetingId/external/:sessionId/request-admission', async (req, res) => {
  try {
    const { meetingId, sessionId } = req.params;
    
    // Get session
    const session = await externalParticipantService.getSession(sessionId);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }
    
    // Verify session belongs to this meeting
    if (session.meeting_id !== meetingId) {
      return res.status(403).json({ error: 'Session does not belong to this meeting' });
    }
    
    // Check cooldown (5 seconds between retries)
    const cooldownRemaining = await externalParticipantService.checkAdmissionCooldown(sessionId);
    if (cooldownRemaining !== null) {
      return res.status(429).json({ 
        error: 'Please wait before retrying',
        retry_after: cooldownRemaining
      });
    }
    
    // Update status to 'requesting' (admitted = false)
    const updated = await externalParticipantService.updateAdmissionStatus(
      sessionId,
      false,
      new Date()
    );
    
    // Emit admission request to all participants
    if (io) {
      io.to(`meeting:${meetingId}`).emit('meeting:guest_admission_request', {
        session_id: sessionId,
        meeting_id: meetingId,
        display_name: session.display_name,
        admitted: false,
        created_at: session.createdAt || new Date().toISOString()
      });
      console.log(`[EXTERNAL] Guest ${sanitizeForLog(sessionId)} requested admission to ${sanitizeForLog(meetingId)}`);
    }
    
    res.json({ 
      success: true, 
      admitted: false,
      message: 'Admission request sent'
    });
  } catch (error) {
    console.error('[EXTERNAL] Error requesting admission:', error);
    res.status(500).json({ error: 'Failed to request admission' });
  }
});

/**
 * Request admission (after key exchange)
 * POST /api/meetings/:meetingId/external/:sessionId/request-admission
 */
router.post('/meetings/:meetingId/external/:sessionId/request-admission', async (req, res) => {
  try {
    const { meetingId, sessionId } = req.params;
    
    // Get session
    const session = await externalParticipantService.getSession(sessionId);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }
    
    // Verify session belongs to this meeting
    if (session.meeting_id !== meetingId) {
      return res.status(403).json({ error: 'Session does not belong to this meeting' });
    }
    
    // Check cooldown (5 seconds between retries)
    const cooldownRemaining = await externalParticipantService.checkAdmissionCooldown(sessionId);
    if (cooldownRemaining !== null) {
      return res.status(429).json({ 
        error: 'Please wait before retrying',
        retry_after: cooldownRemaining
      });
    }
    
    // Update status to 'requesting' (admitted = false)
    const updated = await externalParticipantService.updateAdmissionStatus(
      sessionId,
      false,
      new Date()
    );
    
    // Emit admission request to all participants
    if (io) {
      io.to(`meeting:${meetingId}`).emit('meeting:guest_admission_request', {
        session_id: sessionId,
        meeting_id: meetingId,
        display_name: session.display_name,
        admitted: false,
        created_at: session.createdAt || new Date().toISOString()
      });
      console.log(`[EXTERNAL] Guest ${sanitizeForLog(sessionId)} requested admission to ${sanitizeForLog(meetingId)}`);
    }
    
    res.json({ 
      success: true, 
      admitted: false,
      message: 'Admission request sent'
    });
  } catch (error) {
    console.error('[EXTERNAL] Error requesting admission:', error);
    res.status(500).json({ error: 'Failed to request admission' });
  }
});

/**
 * End external session
 * DELETE /api/meetings/external/session/:sessionId
 */
router.delete('/meetings/external/session/:sessionId', async (req, res) => {
  try {
    const { sessionId } = req.params;

    await externalParticipantService.deleteSession(sessionId);

    res.json({ success: true });
  } catch (error) {
    console.error('Error deleting external session:', error);
    res.status(500).json({ error: 'Failed to delete session' });
  }
});

/**
 * Update external session (display name)
 * PATCH /api/meetings/external/session/:sessionId
 */
router.patch('/meetings/external/session/:sessionId', async (req, res) => {
  try {
    const { sessionId } = req.params;
    const { display_name } = req.body;

    if (!display_name || display_name.trim().length === 0) {
      return res.status(400).json({ error: 'display_name is required' });
    }

    const session = await externalParticipantService.getSession(sessionId);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }

    // Check if session expired
    const expired = await externalParticipantService.isSessionExpired(sessionId);
    if (expired) {
      return res.status(403).json({ error: 'Session expired' });
    }

    // Update display name
    await externalParticipantService.updateSessionDisplayName(sessionId, display_name.trim());

    res.json({ 
      success: true,
      session_id: sessionId,
      display_name: display_name.trim()
    });
  } catch (error) {
    console.error('Error updating external session:', error);
    res.status(500).json({ error: 'Failed to update session' });
  }
});

/**
 * Get waiting external participants for a meeting (for admission overlay)
 * GET /api/meetings/:meetingId/external/waiting
 * Requires authentication (internal users only)
 */
router.get('/meetings/:meetingId/external/waiting', async (req, res) => {
  try {
    const { meetingId } = req.params;

    const waiting = await externalParticipantService.getWaitingParticipants(meetingId);

    res.json({ waiting });
  } catch (error) {
    console.error('Error getting waiting participants:', error);
    res.status(500).json({ error: 'Failed to get waiting participants' });
  }
});

/**
 * Admit external participant
 * POST /api/meetings/:meetingId/external/:sessionId/admit
 * Requires authentication (internal users only)
 */
router.post('/meetings/:meetingId/external/:sessionId/admit', async (req, res) => {
  try {
    const { meetingId, sessionId } = req.params;
    const { admitted_by } = req.body;

    if (!admitted_by) {
      return res.status(400).json({ error: 'admitted_by required' });
    }

    // Get current session
    const session = await externalParticipantService.getSession(sessionId);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }

    // First-come-first-served check
    if (session.admitted !== false) {
      return res.status(409).json({ 
        error: 'Session already processed',
        current_status: session.admitted === true ? 'admitted' : 'not requesting'
      });
    }

    // Update to admitted
    const updated = await externalParticipantService.updateAdmissionStatus(
      sessionId,
      true,
      admitted_by
    );

    // Emit to ALL participants (for overlay removal)
    if (io) {
      // Emit to participants in default namespace
      io.to(`meeting:${meetingId}`).emit('meeting:guest_admitted', {
        session_id: sessionId,
        meeting_id: meetingId,
        display_name: updated.display_name,
        admitted: true,
        admitted_by: admitted_by
      });
      
      // Emit SPECIFIC event to guest in /external namespace
      io.of('/external').to(`meeting:${meetingId}`).emit('meeting:admission_granted', {
        session_id: sessionId,
        meeting_id: meetingId,
        admitted_by: admitted_by
      });
      
      console.log(`[EXTERNAL] Guest ${sanitizeForLog(sessionId)} ADMITTED to ${sanitizeForLog(meetingId)} by ${sanitizeForLog(admitted_by)}`);
    }

    res.json(updated);
  } catch (error) {
    console.error('Error admitting external participant:', error);
    res.status(500).json({ error: 'Failed to admit participant' });
  }
});

/**
 * Decline external participant
 * POST /api/meetings/:meetingId/external/:sessionId/decline
 * Requires authentication (internal users only)
 */
router.post('/meetings/:meetingId/external/:sessionId/decline', async (req, res) => {
  try {
    const { meetingId, sessionId } = req.params;
    const { declined_by } = req.body;

    if (!declined_by) {
      return res.status(400).json({ error: 'declined_by required' });
    }

    // Get current session
    const session = await externalParticipantService.getSession(sessionId);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }

    // First-come-first-served check
    if (session.admitted !== false) {
      return res.status(409).json({ 
        error: 'Session already processed',
        current_status: session.admitted === true ? 'admitted' : 'not requesting'
      });
    }

    // Update to declined (reset to null for retry)
    const updated = await externalParticipantService.updateAdmissionStatus(
      sessionId,
      null,
      declined_by
    );

    // Emit to ALL participants (for overlay removal)
    if (io) {
      // Emit to participants in default namespace
      io.to(`meeting:${meetingId}`).emit('meeting:guest_declined', {
        session_id: sessionId,
        meeting_id: meetingId,
        display_name: updated.display_name,
        admitted: null,
        declined_by: declined_by
      });
      
      // Emit SPECIFIC event to guest in /external namespace
      io.of('/external').to(`meeting:${meetingId}`).emit('meeting:admission_denied', {
        session_id: sessionId,
        meeting_id: meetingId,
        declined_by: declined_by,
        reason: 'Host declined your request'
      });
      
      console.log(`[EXTERNAL] Guest ${sanitizeForLog(sessionId)} DECLINED from ${sanitizeForLog(meetingId)} by ${sanitizeForLog(declined_by)}`);
    }

    res.json(updated);
  } catch (error) {
    console.error('Error declining external participant:', error);
    res.status(500).json({ error: 'Failed to decline participant' });
  }
});

/**
 * Consume a one-time pre-key
 * POST /api/meetings/external/session/:sessionId/consume-prekey
 * Used when server user establishes Signal session with guest
 */
router.post('/meetings/external/session/:sessionId/consume-prekey', async (req, res) => {
  try {
    const { sessionId } = req.params;
    const { pre_key_id } = req.body;

    if (pre_key_id === undefined || pre_key_id === null) {
      return res.status(400).json({ error: 'pre_key_id required' });
    }

    const result = await externalParticipantService.consumePreKey(sessionId, pre_key_id);
    res.json(result);
  } catch (error) {
    console.error('Error consuming pre-key:', error);
    res.status(500).json({ error: 'Failed to consume pre-key' });
  }
});

/**
 * Replenish one-time pre-keys
 * POST /api/meetings/external/session/:sessionId/prekeys
 * Used by guest to add more pre-keys when running low
 */
router.post('/meetings/external/session/:sessionId/prekeys', async (req, res) => {
  try {
    const { sessionId } = req.params;
    const { pre_keys } = req.body;

    if (!pre_keys || !Array.isArray(pre_keys)) {
      return res.status(400).json({ error: 'pre_keys array required' });
    }

    const result = await externalParticipantService.replenishPreKeys(sessionId, pre_keys);
    res.json(result);
  } catch (error) {
    console.error('Error replenishing pre-keys:', error);
    res.status(500).json({ error: 'Failed to replenish pre-keys' });
  }
});

/**
 * Get remaining pre-key count
 * GET /api/meetings/external/session/:sessionId/prekeys
 * Used by guest to monitor pre-key inventory
 */
router.get('/meetings/external/session/:sessionId/prekeys', async (req, res) => {
  try {
    const { sessionId } = req.params;
    const result = await externalParticipantService.getRemainingPreKeys(sessionId);
    res.json(result);
  } catch (error) {
    console.error('Error getting remaining pre-keys:', error);
    res.status(500).json({ error: 'Failed to get pre-key count' });
  }
});

/**
 * Get E2EE keys for establishing Signal session
 * GET /api/meetings/external/keys/:sessionId
 * Used by server users to fetch guest's public keys
 * Requires authentication (internal users only)
 */
router.get('/meetings/external/keys/:sessionId', async (req, res) => {
  try {
    const { sessionId } = req.params;
    const keys = await externalParticipantService.getKeysForSession(sessionId);
    res.json(keys);
  } catch (error) {
    console.error('Error getting external participant keys:', error);
    res.status(500).json({ error: 'Failed to get participant keys' });
  }
});

  return router;
};
