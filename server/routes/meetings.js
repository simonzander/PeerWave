const express = require('express');
const router = express.Router();
const meetingService = require('../services/meetingService');
const presenceService = require('../services/presenceService');
const { verifySessionAuth, verifyAuthEither } = require('../middleware/sessionAuth');
const { hasServerPermission } = require('../db/roleHelpers');
const nodemailer = require('nodemailer');
const config = require('../config/config');

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
    const userId = req.userId;
    
    const meeting = await meetingService.getMeeting(meetingId);

    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check if user is authorized to view this meeting
    // User must be: owner, participant, or invited (for source_user_id in instant calls)
    const isParticipant = meeting.participants.some(p => p.user_id === userId);
    const isSourceUser = meeting.source_user_id === userId;
    const isCreator = meeting.created_by === userId;
    
    if (!isParticipant && !isSourceUser && !isCreator) {
      console.log(`[MEETING] User ${userId} not authorized for meeting ${meetingId}`);
      return res.status(403).json({ error: 'Not authorized to access this meeting' });
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
 * Note: Also supports unauthenticated access for external guests to check if host is present
 */
router.get('/meetings/:meetingId/participants', async (req, res) => {
  try {
    const { meetingId } = req.params;
    const { status, exclude_external } = req.query;

    // Try to extract userId from session/auth, but don't fail if missing (guest access)
    let currentUserId = req.userId || req.session?.userinfo?.uuid;

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // If authenticated, check authorization
    if (currentUserId) {
      const isAuthorized = meeting.created_by === currentUserId ||
                          meeting.participants?.some(p => p.user_id === currentUserId) ||
                          meeting.invited_participants?.includes(currentUserId);

      if (!isAuthorized) {
        return res.status(403).json({ error: 'Not authorized to view participants' });
      }
    }
    // For unauthenticated (guest) access, allow read-only access to participant list

    // Filter participants based on query parameters
    let participants = (meeting.participants || []).map(p => ({
      uuid: p.user_id,
      deviceId: p.device_id || null,
      role: p.role || 'meeting_member',
      joined_at: p.joined_at,
      status: p.status || 'invited'
    }));

    // Filter by status if provided
    if (status) {
      participants = participants.filter(p => p.status === status);
    }

    // Exclude external participants if requested
    if (exclude_external === 'true') {
      // External participants don't have UUIDs (they have session_ids instead)
      // So this filter keeps only server users
      participants = participants.filter(p => p.uuid && p.uuid.length > 0);
    }

    res.json({ participants });
  } catch (error) {
    console.error('Error getting meeting participants:', error);
    res.status(500).json({ error: 'Failed to get participants' });
  }
});

/**
 * Add participant to meeting
 * POST /api/meetings/:meetingId/participants
 */
router.post('/meetings/:meetingId/participants', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId } = req.params;
    const { user_id, role } = req.body;
    const currentUserId = req.userId;

    if (!user_id) {
      return res.status(400).json({ error: 'user_id is required' });
    }

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check permissions (must be owner or manager)
    const isOwner = meeting.created_by === currentUserId;
    const currentParticipant = meeting.participants?.find(p => p.user_id === currentUserId);
    const isManager = currentParticipant?.role === 'meeting_manager';

    if (!isOwner && !isManager) {
      return res.status(403).json({ error: 'Only owner or manager can add participants' });
    }

    // Add participant
    const participant = await meetingService.addParticipant(meetingId, {
      user_id,
      role: role || 'meeting_member'
    });

    // Get user online status for notification
    const isOnline = await presenceService.isUserOnline(user_id);

    res.status(201).json({
      participant,
      isOnline
    });
  } catch (error) {
    console.error('Error adding participant:', error);
    res.status(500).json({ error: 'Failed to add participant: ' + error.message });
  }
});

/**
 * Remove participant from meeting
 * DELETE /api/meetings/:meetingId/participants/:userId
 */
router.delete('/meetings/:meetingId/participants/:userId', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId, userId } = req.params;
    const currentUserId = req.userId;

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check permissions (must be owner, manager, or removing self)
    const isOwner = meeting.created_by === currentUserId;
    const currentParticipant = meeting.participants?.find(p => p.user_id === currentUserId);
    const isManager = currentParticipant?.role === 'meeting_manager';
    const isSelf = userId === currentUserId;

    if (!isOwner && !isManager && !isSelf) {
      return res.status(403).json({ error: 'Not authorized to remove participant' });
    }

    await meetingService.removeParticipant(meetingId, userId);

    res.json({ status: 'ok', message: 'Participant removed' });
  } catch (error) {
    console.error('Error removing participant:', error);
    res.status(500).json({ error: 'Failed to remove participant' });
  }
});

/**
 * Update participant status
 * PATCH /api/meetings/:meetingId/participants/:userId
 */
router.patch('/meetings/:meetingId/participants/:userId', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId, userId } = req.params;
    const { status } = req.body;
    const currentUserId = req.userId;

    if (!status) {
      return res.status(400).json({ error: 'status is required' });
    }

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // User can only update their own status
    if (userId !== currentUserId) {
      return res.status(403).json({ error: 'Can only update your own status' });
    }

    await meetingService.updateParticipantStatus(meetingId, userId, status);

    res.json({ status: 'ok', message: 'Status updated' });
  } catch (error) {
    console.error('Error updating participant status:', error);
    res.status(500).json({ error: 'Failed to update status' });
  }
});

/**
 * Generate external invitation link
 * POST /api/meetings/:meetingId/generate-link
 */
router.post('/meetings/:meetingId/generate-link', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId } = req.params;
    const { label, expires_at, max_uses } = req.body;
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

    const invitation = await meetingService.generateInvitationLink(meetingId, {
      label,
      expires_at,
      max_uses,
      created_by: userId
    });
    
    res.json({
      invitation,
      invitation_token: invitation.token,
      invitation_url: `${req.protocol}://${req.get('host')}/#/join/meeting/${invitation.token}`
    });
  } catch (error) {
    console.error('Error generating invitation link:', error);
    res.status(500).json({ error: 'Failed to generate invitation link' });
  }
});

/**
 * Send email invitation to external participant
 * POST /api/meetings/:meetingId/invite-email
 */
router.post('/meetings/:meetingId/invite-email', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId } = req.params;
    const { email } = req.body;
    const userId = req.userId;
    const username = req.username || req.session?.userinfo?.username || 'A user';

    if (!email) {
      return res.status(400).json({ error: 'Email is required' });
    }

    // Validate email format
    const emailRegex = /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/;
    if (!emailRegex.test(email)) {
      return res.status(400).json({ error: 'Invalid email format' });
    }

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check permissions (must be owner or manager)
    const isOwner = meeting.created_by === userId;
    const participant = meeting.participants?.find(p => p.user_id === userId);
    const isManager = participant?.role === 'meeting_manager';

    if (!isOwner && !isManager) {
      return res.status(403).json({ error: 'Only owner or manager can send invitations' });
    }

    // Generate invitation link with label for email recipient
    const invitation = await meetingService.generateInvitationLink(meetingId, {
      label: `Email invite: ${email}`,
      created_by: userId
    });
    const invitationToken = invitation.token;
    const invitationUrl = `${req.protocol}://${req.get('host')}/#/join/meeting/${invitationToken}`;

    // Get server settings for server name
    const { ServerSettings } = require('../db/model');
    const settings = await ServerSettings.findOne({ where: { id: 1 } });
    const serverName = settings?.server_name || 'PeerWave Server';

    // Format meeting time
    const startTime = new Date(meeting.start_time);
    const endTime = new Date(meeting.end_time);
    const dateOptions = { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' };
    const timeOptions = { hour: '2-digit', minute: '2-digit', timeZoneName: 'short' };

    // Helper function to format date for iCalendar (UTC)
    const formatICalDate = (date) => {
      return date.toISOString().replace(/[-:]/g, "").split(".")[0] + "Z";
    };

    // Create iCal event for calendar integration
    const icsContent = `BEGIN:VCALENDAR
PRODID:-//PeerWave//Meeting Invite//EN
VERSION:2.0
CALSCALE:GREGORIAN
METHOD:REQUEST
BEGIN:VEVENT
UID:${meeting.id}@${serverName.replace(/\s/g, '')}
DTSTAMP:${formatICalDate(new Date())}
DTSTART:${formatICalDate(startTime)}
DTEND:${formatICalDate(endTime)}
SUMMARY:${meeting.title}
DESCRIPTION:${meeting.description || 'Join meeting at: ' + invitationUrl}\\n\\nJoin URL: ${invitationUrl}
ORGANIZER;CN=${username}:mailto:${config.smtp.auth.user}
ATTENDEE;CN=${email};ROLE=REQ-PARTICIPANT;RSVP=TRUE:mailto:${email}
LOCATION:${invitationUrl}
STATUS:CONFIRMED
SEQUENCE:0
END:VEVENT
END:VCALENDAR`.trim();

    // Send email
    console.log('[MEETING_INVITE] Configuring email transporter...');
    const transporter = nodemailer.createTransport(config.smtp);
    
    console.log('[MEETING_INVITE] Sending invitation to:', email);
    await transporter.sendMail({
      from: config.smtp.auth.user,
      to: email,
      subject: `${username} invited you to "${meeting.title}" on ${serverName}`,
      html: `
        <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
          <h2 style="color: #333;">You're Invited to a Meeting!</h2>
          
          <p><strong>${username}</strong> has invited you to join a meeting on ${serverName}.</p>
          
          <div style="background-color: #f5f5f5; padding: 20px; border-radius: 8px; margin: 20px 0;">
            <h3 style="margin-top: 0; color: #555;">Meeting Details</h3>
            <p><strong>Title:</strong> ${meeting.title}</p>
            ${meeting.description ? `<p><strong>Description:</strong> ${meeting.description}</p>` : ''}
            <p><strong>Date:</strong> ${startTime.toLocaleDateString('en-US', dateOptions)}</p>
            <p><strong>Time:</strong> ${startTime.toLocaleTimeString('en-US', timeOptions)} - ${endTime.toLocaleTimeString('en-US', timeOptions)}</p>
          </div>
          
          <div style="margin: 30px 0;">
            <a href="${invitationUrl}" 
               style="background-color: #4CAF50; color: white; padding: 12px 24px; text-decoration: none; border-radius: 4px; display: inline-block;">
              Join Meeting
            </a>
          </div>
          
          <p style="color: #666; font-size: 14px;">
            Or copy and paste this link into your browser:<br>
            <a href="${invitationUrl}">${invitationUrl}</a>
          </p>
          
          <hr style="border: none; border-top: 1px solid #ddd; margin: 30px 0;">
          
          <p style="color: #999; font-size: 12px;">
            This invitation was sent from ${serverName}. If you received this email in error, please ignore it.
          </p>
        </div>
      `,
      
      // Add calendar invite as alternative content (displayed by email clients as calendar event)
      alternatives: [
        {
          contentType: "text/calendar; method=REQUEST; charset=UTF-8",
          content: icsContent
        }
      ],
      
      // Also attach as .ics file (allows manual import if needed)
      attachments: [
        {
          filename: "invite.ics",
          content: icsContent,
          contentType: "text/calendar; charset=UTF-8; method=REQUEST"
        }
      ]
    });

    console.log(`[MEETING_INVITE] Successfully sent invitation to ${email} for meeting ${meetingId}`);
    
    res.json({
      status: 'ok',
      message: 'Invitation sent successfully',
      email: email
    });
  } catch (error) {
    console.error('[MEETING_INVITE] Error:', error);
    res.status(500).json({ error: 'Failed to send invitation: ' + error.message });
  }
});

/**
 * Get all invitation tokens for a meeting
 * GET /api/meetings/:meetingId/invitations
 */
router.get('/meetings/:meetingId/invitations', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId } = req.params;
    const userId = req.userId;

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check permissions
    const participant = meeting.participants?.find(p => p.user_id === userId);
    const isOwner = meeting.created_by === userId;
    if (!isOwner && (!participant || (participant.role !== 'meeting_owner' && participant.role !== 'meeting_manager'))) {
      return res.status(403).json({ error: 'Only owner or manager can view invitations' });
    }

    const invitations = await meetingService.getInvitationTokens(meetingId);
    
    // Add URLs to each invitation
    const baseUrl = `${req.protocol}://${req.get('host')}`;
    const invitationsWithUrls = invitations.map(inv => ({
      ...inv,
      invitation_url: `${baseUrl}/#/join/meeting/${inv.token}`
    }));

    res.json({ invitations: invitationsWithUrls });
  } catch (error) {
    console.error('Error getting invitations:', error);
    res.status(500).json({ error: 'Failed to get invitations' });
  }
});

/**
 * Revoke an invitation token
 * POST /api/meetings/:meetingId/invitations/:token/revoke
 */
router.post('/meetings/:meetingId/invitations/:token/revoke', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId, token } = req.params;
    const userId = req.userId;

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check permissions
    const participant = meeting.participants?.find(p => p.user_id === userId);
    const isOwner = meeting.created_by === userId;
    if (!isOwner && (!participant || (participant.role !== 'meeting_owner' && participant.role !== 'meeting_manager'))) {
      return res.status(403).json({ error: 'Only owner or manager can revoke invitations' });
    }

    const success = await meetingService.revokeInvitationToken(token);
    
    if (!success) {
      return res.status(404).json({ error: 'Invitation not found' });
    }

    res.json({ status: 'ok', message: 'Invitation revoked successfully' });
  } catch (error) {
    console.error('Error revoking invitation:', error);
    res.status(500).json({ error: 'Failed to revoke invitation' });
  }
});

/**
 * Delete an invitation token permanently
 * DELETE /api/meetings/:meetingId/invitations/:token
 */
router.delete('/meetings/:meetingId/invitations/:token', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId, token } = req.params;
    const userId = req.userId;

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check permissions
    const participant = meeting.participants?.find(p => p.user_id === userId);
    const isOwner = meeting.created_by === userId;
    if (!isOwner && (!participant || (participant.role !== 'meeting_owner' && participant.role !== 'meeting_manager'))) {
      return res.status(403).json({ error: 'Only owner or manager can delete invitations' });
    }

    const success = await meetingService.deleteInvitationToken(token);
    
    if (!success) {
      return res.status(404).json({ error: 'Invitation not found' });
    }

    res.json({ status: 'ok', message: 'Invitation deleted successfully' });
  } catch (error) {
    console.error('Error deleting invitation:', error);
    res.status(500).json({ error: 'Failed to delete invitation' });
  }
});

module.exports = router;
