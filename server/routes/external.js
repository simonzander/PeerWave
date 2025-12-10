const express = require('express');
const router = express.Router();
const externalParticipantService = require('../services/externalParticipantService');
const meetingService = require('../services/meetingService');

/**
 * Validate meeting invitation token (external access)
 * GET /api/meetings/external/join/:token
 */
router.get('/meetings/external/join/:token', async (req, res) => {
  try {
    const { token } = req.params;

    const result = await externalParticipantService.validateInvitationToken(token);

    if (!result) {
      return res.status(404).json({ error: 'Invalid invitation token' });
    }

    if (result.error === 'outside_time_window') {
      return res.status(403).json({
        error: 'Outside time window',
        message: 'This invitation is only valid 1 hour before and after the meeting start time.',
        meeting: {
          title: result.meeting.title,
          start_time: result.meeting.start_time
        }
      });
    }

    // Check if meeting has any active participants (for conditional access)
    const hasParticipants = await meetingService.hasActiveParticipants(result.meeting.meeting_id);

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
    console.error('Error validating invitation token:', error);
    res.status(500).json({ error: 'Failed to validate invitation' });
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

    res.status(201).json({
      session_id: session.session_id,
      meeting_id: session.meeting_id,
      display_name: session.display_name,
      expires_at: session.expires_at,
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

    const session = await externalParticipantService.getSession(sessionId);

    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
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
 * Get waiting external participants for a meeting (for admission overlay)
 * GET /api/meetings/:meetingId/external/waiting
 * Requires authentication (internal users only)
 */
router.get('/meetings/:meetingId/external/waiting', async (req, res) => {
  try {
    const { meetingId } = req.params;

    const waiting = await externalParticipantService.getWaitingParticipants(meetingId);

    res.json(waiting);
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
    const { sessionId } = req.params;
    const { admitted_by } = req.body; // User UUID who admitted

    if (!admitted_by) {
      return res.status(400).json({ error: 'admitted_by required' });
    }

    const updated = await externalParticipantService.updateAdmissionStatus(
      sessionId,
      'admitted',
      admitted_by
    );

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
    const { sessionId } = req.params;
    const { declined_by } = req.body; // User UUID who declined

    if (!declined_by) {
      return res.status(400).json({ error: 'declined_by required' });
    }

    const updated = await externalParticipantService.updateAdmissionStatus(
      sessionId,
      'declined',
      declined_by
    );

    res.json(updated);
  } catch (error) {
    console.error('Error declining external participant:', error);
    res.status(500).json({ error: 'Failed to decline participant' });
  }
});

module.exports = router;
