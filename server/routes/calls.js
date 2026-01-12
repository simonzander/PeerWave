const express = require('express');
const router = express.Router();
const meetingService = require('../services/meetingService');
const presenceService = require('../services/presenceService');
const { verifySessionAuth, verifyAuthEither } = require('../middleware/sessionAuth');
const logger = require('../utils/logger');

/**
 * Create instant call (wrapper around createMeeting)
 * POST /api/calls/instant
 */
router.post('/calls/instant', verifyAuthEither, async (req, res) => {
  try {
    const {
      title,
      source_channel_id,
      source_user_id,
      allow_external
    } = req.body;

    const created_by = req.userId;
    const now = new Date();
    const endTime = new Date(now.getTime() + 24 * 60 * 60 * 1000); // Default 24h duration

    // Create meeting with is_instant_call = true
    const call = await meetingService.createMeeting({
      title: title || 'Instant Call',
      description: null,
      created_by,
      start_time: now,
      end_time: endTime,
      is_instant_call: true,
      source_channel_id,
      source_user_id,
      allow_external: allow_external || false,
      voice_only: false,
      mute_on_join: false,
      max_participants: null
    });

    // Return full Meeting object
    res.status(201).json(call);
  } catch (error) {
    logger.error('[CALLS] Error creating instant call', error);
    res.status(500).json({ error: 'Failed to create instant call' });
  }
});

/**
 * Get call details (wrapper around getMeeting)
 * GET /api/calls/:callId
 */
router.get('/calls/:callId', verifyAuthEither, async (req, res) => {
  try {
    const { callId } = req.params;
    const call = await meetingService.getMeeting(callId);

    if (!call) {
      return res.status(404).json({ error: 'Call not found' });
    }

    if (!call.is_instant_call) {
      return res.status(400).json({ error: 'Not an instant call' });
    }

    res.json(call);
  } catch (error) {
    logger.error('[CALLS] Error getting call', error);
    res.status(500).json({ error: 'Failed to get call' });
  }
});

/**
 * End call (wrapper around deleteMeeting)
 * DELETE /api/calls/:callId
 */
router.delete('/calls/:callId', verifyAuthEither, async (req, res) => {
  try {
    const { callId } = req.params;
    const userId = req.userId;

    const call = await meetingService.getMeeting(callId);
    if (!call) {
      return res.status(404).json({ error: 'Call not found' });
    }

    if (!call.is_instant_call) {
      return res.status(400).json({ error: 'Not an instant call' });
    }

    // Check if user is creator
    if (call.created_by !== userId) {
      return res.status(403).json({ error: 'Only call creator can end call' });
    }

    await meetingService.deleteMeeting(callId);
    res.json({ success: true });
  } catch (error) {
    logger.error('[CALLS] Error ending call', error);
    res.status(500).json({ error: 'Failed to end call' });
  }
});

/**
 * Get call participants (wrapper)
 * GET /api/calls/:callId/participants
 */
router.get('/calls/:callId/participants', verifyAuthEither, async (req, res) => {
  try {
    const { callId } = req.params;
    const call = await meetingService.getMeeting(callId);

    if (!call) {
      return res.status(404).json({ error: 'Call not found' });
    }

    res.json(call.participants);
  } catch (error) {
    logger.error('[CALLS] Error getting call participants', error);
    res.status(500).json({ error: 'Failed to get participants' });
  }
});

/**
 * Invite user to active call (wrapper)
 * POST /api/calls/:callId/invite
 */
router.post('/calls/:callId/invite', verifyAuthEither, async (req, res) => {
  try {
    const { callId } = req.params;
    const { user_id } = req.body;
    const currentUserId = req.userId;

    const call = await meetingService.getMeeting(callId);
    if (!call) {
      return res.status(404).json({ error: 'Call not found' });
    }

    // Check if current user is participant
    const participant = call.participants.find(p => p.user_id === currentUserId);
    if (!participant) {
      return res.status(403).json({ error: 'Must be call participant to invite' });
    }

    // Add new participant
    const newParticipant = await meetingService.addParticipant({
      meeting_id: callId,
      user_id,
      role: 'meeting_member',
      status: 'invited'
    });

    res.status(201).json(newParticipant);
  } catch (error) {
    logger.error('[CALLS] Error inviting to call', error);
    res.status(500).json({ error: 'Failed to invite to call' });
  }
});

/**
 * Generate external link for call (wrapper)
 * POST /api/calls/:callId/generate-link
 */
router.post('/calls/:callId/generate-link', verifyAuthEither, async (req, res) => {
  try {
    const { callId } = req.params;
    const userId = req.userId;

    const call = await meetingService.getMeeting(callId);
    if (!call) {
      return res.status(404).json({ error: 'Call not found' });
    }

    // Check if current user is participant
    const participant = call.participants.find(p => p.user_id === userId);
    if (!participant) {
      return res.status(403).json({ error: 'Must be call participant to generate link' });
    }

    const invitation = await meetingService.generateInvitationLink(callId, {
      created_by: userId,
      label: 'Call invite'
    });
    
    res.json({
      invitation,
      invitation_token: invitation.token,
      invitation_url: `${req.protocol}://${req.get('host')}/#/join/meeting/${invitation.token}`
    });
  } catch (error) {
    logger.error('[CALLS] Error generating call link', error);
    res.status(500).json({ error: 'Failed to generate call link' });
  }
});

/**
 * Accept incoming call
 * POST /api/calls/accept
 */
router.post('/calls/accept', verifyAuthEither, async (req, res) => {
  try {
    const { meeting_id } = req.body;
    const userId = req.userId;

    await meetingService.updateParticipantStatus(meeting_id, userId, 'accepted');
    
    res.json({ success: true });
  } catch (error) {
    logger.error('[CALLS] Error accepting call', error);
    res.status(500).json({ error: 'Failed to accept call' });
  }
});

/**
 * Decline incoming call
 * POST /api/calls/decline
 */
router.post('/calls/decline', verifyAuthEither, async (req, res) => {
  try {
    const { meeting_id } = req.body;
    const userId = req.userId;

    await meetingService.updateParticipantStatus(meeting_id, userId, 'declined');
    
    res.json({ success: true });
  } catch (error) {
    logger.error('[CALLS] Error declining call', error);
    res.status(500).json({ error: 'Failed to decline call' });
  }
});

module.exports = router;
