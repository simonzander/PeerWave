const express = require('express');
const router = express.Router();
const meetingService = require('../services/meetingService');
const presenceService = require('../services/presenceService');
const { verifySessionAuth, verifyAuthEither } = require('../middleware/sessionAuth');
const { hasServerPermission } = require('../db/roleHelpers');

/**
 * Create a new meeting
 * POST /api/meetings
 */
router.post('/meetings', verifyAuthEither, async (req, res) => {
  try {
    const {
      title,
      description,
      start_time,
      end_time,
      allow_external,
      voice_only,
      mute_on_join,
      max_participants
    } = req.body;

    const created_by = req.userId;

    // Validation
    if (!title || !start_time || !end_time) {
      return res.status(400).json({ error: 'Missing required fields: title, start_time, end_time' });
    }

    const meeting = await meetingService.createMeeting({
      title,
      description,
      created_by,
      start_time: new Date(start_time),
      end_time: new Date(end_time),
      is_instant_call: false,
      allow_external: allow_external || false,
      voice_only: voice_only || false,
      mute_on_join: mute_on_join || false,
      max_participants: max_participants || null
    });

    res.status(201).json(meeting);
  } catch (error) {
    console.error('Error creating meeting:', error);
    res.status(500).json({ error: 'Failed to create meeting' });
  }
});

/**
 * List meetings with filters
 * GET /api/meetings?filter=upcoming|past|my&user_id=xxx
 */
router.get('/meetings', verifyAuthEither, async (req, res) => {
  try {
    const { filter, user_id } = req.query;
    const currentUserId = req.userId;

    let filters = {};

    // Default to showing meetings for current user
    if (filter === 'my' || !filter) {
      filters.user_id = currentUserId;
    } else if (filter === 'upcoming') {
      filters.start_after = new Date();
      filters.status = 'scheduled';
      filters.user_id = currentUserId;
    } else if (filter === 'past') {
      const eightHoursAgo = new Date(Date.now() - 8 * 60 * 60 * 1000);
      filters.end_before = new Date();
      filters.start_after = eightHoursAgo;
      filters.user_id = currentUserId;
    }

    // Allow admins to view all meetings or filter by user
    const isAdmin = await hasServerPermission(currentUserId, 'server.manage');
    if (isAdmin && user_id) {
      filters.user_id = user_id;
    }

    const meetings = await meetingService.listMeetings(filters);
    res.json(meetings);
  } catch (error) {
    console.error('Error listing meetings:', error);
    res.status(500).json({ error: 'Failed to list meetings' });
  }
});

/**
 * Get upcoming meetings (starting within 24 hours)
 * GET /api/meetings/upcoming
 */
router.get('/meetings/upcoming', verifyAuthEither, async (req, res) => {
  try {
    const userId = req.userId;
    const now = new Date();
    const tomorrow = new Date(now.getTime() + 24 * 60 * 60 * 1000);

    const meetings = await meetingService.listMeetings({
      user_id: userId,
      start_after: now,
      end_before: tomorrow,
      status: 'scheduled'
    });

    res.json(meetings);
  } catch (error) {
    console.error('Error getting upcoming meetings:', error);
    res.status(500).json({ error: 'Failed to get upcoming meetings' });
  }
});

/**
 * Get past meetings (ended within 8 hours)
 * GET /api/meetings/past
 */
router.get('/meetings/past', verifyAuthEither, async (req, res) => {
  try {
    const userId = req.userId;
    const now = new Date();
    const eightHoursAgo = new Date(now.getTime() - 8 * 60 * 60 * 1000);

    const meetings = await meetingService.listMeetings({
      user_id: userId,
      start_after: eightHoursAgo,
      end_before: now
    });

    res.json(meetings);
  } catch (error) {
    console.error('Error getting past meetings:', error);
    res.status(500).json({ error: 'Failed to get past meetings' });
  }
});

/**
 * Get user's meetings (created or invited)
 * GET /api/meetings/my
 */
router.get('/meetings/my', verifyAuthEither, async (req, res) => {
  try {
    const userId = req.userId;

    const meetings = await meetingService.listMeetings({
      user_id: userId
    });

    res.json(meetings);
  } catch (error) {
    console.error('Error getting my meetings:', error);
    res.status(500).json({ error: 'Failed to get meetings' });
  }
});

/**
 * Get specific meeting
 * GET /api/meetings/:meetingId
 */
router.get('/meetings/:meetingId', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId } = req.params;
    const meeting = await meetingService.getMeeting(meetingId);

    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    res.json(meeting);
  } catch (error) {
    console.error('Error getting meeting:', error);
    res.status(500).json({ error: 'Failed to get meeting' });
  }
});

/**
 * Update meeting
 * PATCH /api/meetings/:meetingId
 */
router.patch('/meetings/:meetingId', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId } = req.params;
    const userId = req.userId;

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check if user is owner or manager
    const participant = meeting.participants.find(p => p.user_id === userId);
    if (!participant || (participant.role !== 'meeting_owner' && participant.role !== 'meeting_manager')) {
      return res.status(403).json({ error: 'Only owner or manager can update meeting' });
    }

    const updated = await meetingService.updateMeeting(meetingId, req.body);
    res.json(updated);
  } catch (error) {
    console.error('Error updating meeting:', error);
    res.status(500).json({ error: 'Failed to update meeting' });
  }
});

/**
 * Delete meeting
 * DELETE /api/meetings/:meetingId
 */
router.delete('/meetings/:meetingId', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId } = req.params;
    const userId = req.userId;

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check if user is owner
    if (meeting.created_by !== userId) {
      const isAdmin = await hasServerPermission(userId, 'server.manage');
      if (!isAdmin) {
        return res.status(403).json({ error: 'Only owner can delete meeting' });
      }
    }

    await meetingService.deleteMeeting(meetingId);
    res.json({ success: true });
  } catch (error) {
    console.error('Error deleting meeting:', error);
    res.status(500).json({ error: 'Failed to delete meeting' });
  }
});

/**
 * Bulk delete meetings
 * DELETE /api/meetings/bulk
 */
router.delete('/meetings/bulk', verifyAuthEither, async (req, res) => {
  try {
    const { meetingIds } = req.body;
    const userId = req.userId;

    if (!Array.isArray(meetingIds) || meetingIds.length === 0) {
      return res.status(400).json({ error: 'meetingIds array required' });
    }

    const isAdmin = await hasServerPermission(userId, 'server.manage');
    const results = await meetingService.bulkDeleteMeetings(meetingIds, userId, isAdmin);

    res.json(results);
  } catch (error) {
    console.error('Error bulk deleting meetings:', error);
    res.status(500).json({ error: 'Failed to bulk delete meetings' });
  }
});

/**
 * Get meeting participants (from memory for E2EE key exchange)
 * GET /api/meetings/:meetingId/participants
 */
router.get('/meetings/:meetingId/participants', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId } = req.params;
    const currentUserId = req.userId;

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check if user is authorized (creator, participant, or invited)
    const isAuthorized = meeting.created_by === currentUserId ||
                        meeting.participants?.some(p => p.user_id === currentUserId) ||
                        meeting.invited_participants?.includes(currentUserId);

    if (!isAuthorized) {
      return res.status(403).json({ error: 'Not authorized to view participants' });
    }

    // Return participants in E2EE-compatible format (from memory)
    const participants = (meeting.participants || []).map(p => ({
      uuid: p.user_id,
      deviceId: p.device_id || null,
      role: p.role || 'meeting_member',
      joined_at: p.joined_at
    }));

    res.json({ participants });
  } catch (error) {
    console.error('Error getting meeting participants:', error);
    res.status(500).json({ error: 'Failed to get participants' });
  }
});

/**
 * Generate external invitation link
 * POST /api/meetings/:meetingId/generate-link
 */
router.post('/meetings/:meetingId/generate-link', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId } = req.params;
    const userId = req.userId;

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check permissions
    const participant = meeting.participants.find(p => p.user_id === userId);
    if (!participant || (participant.role !== 'meeting_owner' && participant.role !== 'meeting_manager')) {
      return res.status(403).json({ error: 'Only owner or manager can generate invitation link' });
    }

    const invitationToken = await meetingService.generateInvitationLink(meetingId);
    
    res.json({
      invitation_token: invitationToken,
      invitation_url: `${req.protocol}://${req.get('host')}/join/meeting/${invitationToken}`
    });
  } catch (error) {
    console.error('Error generating invitation link:', error);
    res.status(500).json({ error: 'Failed to generate invitation link' });
  }
});

module.exports = router;
