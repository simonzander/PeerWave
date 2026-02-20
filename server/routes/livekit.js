/**
 * LiveKit Token Generation and Integration
 * 
 * This module provides:
 * - JWT token generation for LiveKit room access
 * - Channel-based room access control
 * - Integration with existing PeerWave permissions
 */

const express = require('express');
const router = express.Router();
const livekitWrapper = require('../lib/livekit-wrapper');
const { verifyAuthEither } = require('../middleware/sessionAuth');
const { sanitizeForLog } = require('../utils/logSanitizer');
const logger = require('../utils/logger');

// Import models from db/model
const { Channel, ChannelMembers } = require('../db/model');

/**
 * Generate LiveKit access token for a channel
 * POST /api/livekit/token
 * 
 * Body:
 * - channelId: The channel to join (room name)
 * 
 * Returns:
 * - token: JWT token for LiveKit
 * - url: LiveKit server URL
 * - roomName: Room identifier
 */
router.post('/token', verifyAuthEither, async (req, res) => {
  try {
    // Load LiveKit SDK dynamically
    const AccessToken = await livekitWrapper.getAccessToken();
    
    // verifyAuthEither middleware sets req.userId for both native and web clients
    const userId = req.userId;
    const username = req.username || req.session?.userinfo?.username || req.session?.email || 'Unknown';
    
    if (!userId) {
      logger.debug('[LIVEKIT] Channel token: Unauthorized - no user ID');
      return res.status(401).json({ error: 'Not authenticated' });
    }

    const { channelId } = req.body;

    if (!channelId) {
      return res.status(400).json({ error: 'channelId required' });
    }

    logger.debug('[LIVEKIT] Channel token request', sanitizeForLog({ userId, channelId }));

    // Verify user has access to this channel
    const channel = await Channel.findByPk(channelId);
    if (!channel) {
      logger.debug('[LIVEKIT] Channel not found', sanitizeForLog({ channelId }));
      return res.status(404).json({ error: 'Channel not found' });
    }

    // Check if user is a member
    const membership = await ChannelMembers.findOne({
      where: { channelId, userId }
    });

    if (!membership) {
      return res.status(403).json({ error: 'Not a channel member' });
    }

    logger.debug('[LIVEKIT] Membership found', sanitizeForLog({
      userId,
      channelId,
      hasPermissions: !!membership.permissions
    }));

    // Check if user has WebRTC permissions (safely handle missing permissions object)
    const hasWebRtcPermission = membership.permissions?.channelWebRtc ?? true; // Default to true if permissions not set
    
    if (!hasWebRtcPermission) {
      logger.debug('[LIVEKIT] User lacks WebRTC permission', sanitizeForLog({ userId, channelId }));
      return res.status(403).json({ error: 'No WebRTC permission' });
    }

    // Get LiveKit configuration from environment
    const apiKey = process.env.LIVEKIT_API_KEY || 'devkey';
    const apiSecret = process.env.LIVEKIT_API_SECRET || 'secret';
    const livekitUrl = process.env.LIVEKIT_URL || 'ws://localhost:7880';

    // Create access token
    const token = new AccessToken(apiKey, apiSecret, {
      identity: `${userId}`,  // User's unique ID
      name: username,         // Display name
      metadata: JSON.stringify({
        userId,
        username,
        channelId,
        channelName: channel.name
      })
    });

    // Grant permissions based on role
    const isOwner = channel.owner === userId;
    const canPublish = hasWebRtcPermission;
    const canSubscribe = hasWebRtcPermission;

    // Add room grants
    token.addGrant({
      room: `channel-${channelId}`,
      roomJoin: true,
      canPublish: canPublish,
      canSubscribe: canSubscribe,
      canPublishData: true,
      
      // Room admin capabilities (for channel owner)
      ...(isOwner && {
        roomAdmin: true,
        roomList: true,
        roomRecord: false,  // Optional: enable recording
      })
    });

    // Generate JWT
    const jwt = await token.toJwt();

    // Return token and connection info
    res.json({
      token: jwt,
      url: livekitUrl.replace('peerwave-livekit', 'localhost'), // For client
      roomName: `channel-${channelId}`,
      identity: `${userId}`,
      metadata: {
        userId,
        username,
        channelId,
        channelName: channel.name,
        permissions: {
          canPublish,
          canSubscribe,
          isOwner
        }
      }
    });

  } catch (error) {
    logger.error('[LIVEKIT] Token generation error', error);
    res.status(500).json({ error: 'Failed to generate token' });
  }
});

/**
 * Generate LiveKit access token for a meeting
 * POST /api/livekit/meeting-token
 * 
 * Body:
 * - meetingId: The meeting to join (room name will be based on meeting_id)
 * 
 * Returns:
 * - token: JWT token for LiveKit
 * - url: LiveKit server URL
 * - roomName: Room identifier (meeting ID)
 */
router.post('/meeting-token', verifyAuthEither, async (req, res) => {
  try {
    // Load LiveKit SDK dynamically
    const AccessToken = await livekitWrapper.getAccessToken();
    const meetingService = require('../services/meetingService');
    
    const userId = req.userId;
    const username = req.username || req.session?.userinfo?.username || req.session?.email || 'Unknown';
    
    if (!userId) {
      logger.debug('[LIVEKIT] Meeting token: Unauthorized - no user ID');
      return res.status(401).json({ error: 'Not authenticated' });
    }

    const { meetingId } = req.body;

    if (!meetingId) {
      return res.status(400).json({ error: 'meetingId required' });
    }

    logger.debug('[LIVEKIT] Meeting token request', sanitizeForLog({ userId, meetingId }));

    // Get meeting from hybrid storage (memory + DB)
    const meeting = await meetingService.getMeeting(meetingId);

    if (!meeting) {
      logger.debug('[LIVEKIT] Meeting not found', sanitizeForLog({ meetingId }));
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check if user is creator, participant, invited, or source_user (for instant calls)
    const isOwner = meeting.created_by === userId;
    const isParticipant = meeting.participants && meeting.participants.some(p => p.user_id === userId);
    const isInvited = meeting.invited_participants && meeting.invited_participants.includes(userId);
    const isSourceUser = meeting.source_user_id === userId; // For instant calls (recipient)

    if (!isOwner && !isParticipant && !isInvited && !isSourceUser) {
      logger.debug('[LIVEKIT] User not authorized', { userId });
      return res.status(403).json({ error: 'Not authorized for this meeting' });
    }

    logger.debug('[LIVEKIT] User authorized for meeting', sanitizeForLog({
      userId,
      meetingId,
      isOwner,
      isParticipant,
      isInvited,
      isSourceUser
    }));

    // Get LiveKit configuration from environment
    const apiKey = process.env.LIVEKIT_API_KEY || 'devkey';
    const apiSecret = process.env.LIVEKIT_API_SECRET || 'secret';
    const livekitUrl = process.env.LIVEKIT_URL || 'ws://localhost:7880';

    // Get device ID for identity (needed for E2EE guest key exchange)
    let deviceId = req.session?.device_id || req.deviceId;
    
    // If device_id not in session, look it up from Clients table by clientId
    if (!deviceId && req.session?.clientId) {
      const { Client } = require('../db/model');
      const client = await Client.findOne({ 
        where: { clientid: req.session.clientId, owner: userId },
        attributes: ['device_id']
      });
      if (client) {
        deviceId = client.device_id;
        req.session.device_id = deviceId; // Cache in session for future requests
        logger.debug('[LIVEKIT] Loaded device_id from database', sanitizeForLog({ deviceId, clientId: req.session.clientId }));
      }
    }
    
    // Final fallback: if still no device_id, this is an error condition
    if (!deviceId) {
      logger.error('[LIVEKIT] No device_id found for user', sanitizeForLog({ userId, sessionDeviceId: req.session?.device_id, clientId: req.session?.clientId }));
      return res.status(400).json({ 
        error: 'Device not registered',
        message: 'Please refresh the page and log in again to register your device.'
      });
    }

    // Create access token
    const token = new AccessToken(apiKey, apiSecret, {
      identity: `${userId}:${deviceId}`, // Include device ID for E2EE keybundle routing
      name: username,
      metadata: JSON.stringify({
        userId,
        deviceId, // Add device ID to metadata too
        username,
        meetingId,
        meetingTitle: meeting.title,
        isOwner
      })
    });

    // Room name is the meeting ID itself
    const roomName = meetingId;

    // Grant permissions
    const canPublish = true; // All participants can publish
    const canSubscribe = true;

    // Add room grants
    token.addGrant({
      room: roomName,
      roomJoin: true,
      canPublish: canPublish,
      canSubscribe: canSubscribe,
      canPublishData: true,
      
      // Room admin capabilities (for meeting owner)
      ...(isOwner && {
        roomAdmin: true,
        roomList: true,
        roomRecord: false,
      })
    });

    // Generate JWT
    const jwt = await token.toJwt();

    // Update participant status to "joined" in memory
    try {
      // Device ID already obtained above for LiveKit identity
      await meetingService.updateParticipantStatus(meetingId, userId, deviceId, 'joined');
      logger.debug('[LIVEKIT] Updated participant status to joined', sanitizeForLog({ userId, deviceId, meetingId }));
    } catch (statusError) {
      logger.error('[LIVEKIT] Failed to update participant status', statusError);
      // Don't fail the token generation if status update fails
    }

    // Return token and connection info
    res.json({
      token: jwt,
      url: livekitUrl.replace('peerwave-livekit', 'localhost'),
      roomName: roomName,
      identity: `${userId}`,
      metadata: {
        userId,
        username,
        meetingId,
        meetingTitle: meeting.title,
        isOwner,
        permissions: {
          canPublish,
          canSubscribe,
          isOwner
        }
      }
    });

  } catch (error) {
    logger.error('[LIVEKIT] Meeting token generation error', error);
    res.status(500).json({ error: 'Failed to generate meeting token' });
  }
});

/**
 * Generate LiveKit access token for external guest
 * POST /api/livekit/guest-token
 * 
 * Body:
 * - meetingId: The meeting to join
 * - sessionId: Guest session ID from external_meeting_participants
 * 
 * Returns:
 * - token: JWT token for LiveKit
 * - url: LiveKit server URL
 * - roomName: Room identifier
 */
router.post('/guest-token', async (req, res) => {
  try {
    // Load LiveKit SDK dynamically
    const AccessToken = await livekitWrapper.getAccessToken();
    const meetingService = require('../services/meetingService');
    const { ExternalSession } = require('../db/model');
    
    const { meetingId, sessionId } = req.body;

    if (!meetingId || !sessionId) {
      return res.status(400).json({ error: 'meetingId and sessionId required' });
    }

    logger.debug('[LIVEKIT] Guest token request', sanitizeForLog({ sessionId, meetingId }));

    // 1. Validate guest session exists and get participant info
    const guest = await ExternalSession.findOne({
      where: { 
        session_id: sessionId,
        meeting_id: meetingId
      }
    });

    if (!guest) {
      logger.debug('[LIVEKIT] Invalid guest session or meeting', sanitizeForLog({ sessionId, meetingId }));
      return res.status(403).json({ error: 'Invalid guest session' });
    }

    // 2. Check if participant is admitted
    if (guest.admitted !== true) {
      logger.debug('[LIVEKIT] Guest not admitted', sanitizeForLog({ sessionId, admitted: guest.admitted }));
      return res.status(403).json({ error: 'Guest not admitted to meeting' });
    }

    // 3. Get meeting details via meetingService
    const meeting = await meetingService.getMeeting(meetingId);

    if (!meeting) {
      logger.debug('[LIVEKIT] Meeting not found for guest', sanitizeForLog({ meetingId }));
      return res.status(404).json({ error: 'Meeting not found' });
    }

    logger.debug('[LIVEKIT] Guest authorized', sanitizeForLog({
      sessionId,
      displayName: guest.display_name,
      admitted: guest.admitted,
      meetingId,
      meetingTitle: meeting.title
    }));

    // Get LiveKit configuration from environment
    const apiKey = process.env.LIVEKIT_API_KEY || 'devkey';
    const apiSecret = process.env.LIVEKIT_API_SECRET || 'secret';
    const livekitUrl = process.env.LIVEKIT_URL || 'ws://localhost:7880';

    // Create access token for guest
    const token = new AccessToken(apiKey, apiSecret, {
      identity: `guest_${sessionId}`, // Unique identity for guest
      name: guest.display_name || 'Guest',
      metadata: JSON.stringify({
        sessionId,
        displayName: guest.display_name,
        meetingId,
        meetingTitle: meeting.title,
        isGuest: true
      })
    });

    // Room name is either custom or the meeting ID
    const roomName = meeting.livekit_room_name || meetingId;

    // Grant guest permissions
    token.addGrant({
      room: roomName,
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      canPublishData: true,
      // Guests are NOT room admins
      roomAdmin: false,
    });

    // Generate JWT
    const jwt = await token.toJwt();

    logger.debug('[LIVEKIT] Guest token generated', sanitizeForLog({ displayName: guest.display_name, meetingId }));

    res.json({
      token: jwt,
      url: livekitUrl.replace('peerwave-livekit', 'localhost'),
      roomName: roomName,
      identity: `guest_${sessionId}`,
      metadata: {
        sessionId,
        displayName: guest.display_name,
        meetingId,
        isGuest: true
      }
    });

  } catch (error) {
    logger.error('[LIVEKIT] Guest token generation error', error);
    res.status(500).json({ error: 'Failed to generate guest token' });
  }
});

/**
 * Get LiveKit ICE Servers for P2P connections
 * GET /api/livekit/ice-config
 * 
 * Returns ICE server configuration for P2P WebRTC connections
 * Uses LiveKit's embedded TURN server with JWT authentication
 * Replaces Coturn for P2P file transfer and direct messages
 */
/**
 * Get LiveKit ICE Servers for P2P connections
 * GET /api/livekit/ice-config
 * 
 * Returns ICE server configuration for P2P WebRTC connections
 * Uses LiveKit's embedded TURN server with JWT authentication
 * Replaces Coturn for P2P file transfer and direct messages
 */
router.get('/ice-config', verifyAuthEither, async (req, res) => {
  try {
    // Load LiveKit SDK dynamically
    const AccessToken = await livekitWrapper.getAccessToken();
    
    // verifyAuthEither middleware sets req.userId for both native and web clients
    const userId = req.userId;
    const username = req.username || req.session?.userinfo?.username || req.session?.email || 'Unknown';
    
    if (!userId) {
      logger.debug('[LIVEKIT ICE] Unauthorized - No user ID found');
      return res.status(401).json({ error: 'Not authenticated' });
    }

    logger.debug('[LIVEKIT ICE] Config request', { userId: sanitizeForLog(userId), username: sanitizeForLog(username) });

    // Get LiveKit configuration from environment
    const apiKey = process.env.LIVEKIT_API_KEY || 'devkey';
    const apiSecret = process.env.LIVEKIT_API_SECRET || 'secret';
    const turnDomain = process.env.LIVEKIT_TURN_DOMAIN || 'localhost';

    // Create access token for TURN authentication
    // Note: For P2P, we don't need room access, just TURN credentials
    const token = new AccessToken(apiKey, apiSecret, {
      identity: `${userId}`,
      name: username,
      metadata: JSON.stringify({
        userId,
        username,
        purpose: 'p2p-ice'
      })
    });

    // Grant basic permissions (needed for token validity)
    token.addGrant({
      canPublish: true,
      canSubscribe: true,
      canPublishData: true
    });

    // Generate JWT (will be used as TURN credential)
    const jwt = await token.toJwt();

    // Build ICE server configuration
    const iceServers = [
      // 1. Public STUN servers (always available, no auth needed)
      {
        urls: ['stun:stun.l.google.com:19302']
      },
      // 2. LiveKit TURN/TLS (looks like HTTPS, best firewall compatibility)
      {
        urls: [`turns:${turnDomain}:5349?transport=tcp`],
        username: `${userId}`,
        credential: jwt  // JWT token as credential
      },
      // 3. LiveKit TURN/UDP (modern QUIC-compatible, best performance)
      {
        urls: [`turn:${turnDomain}:443?transport=udp`],
        username: `${userId}`,
        credential: jwt
      }
    ];

    // Token lifetime: 24 hours (default for LiveKit JWT)
    const ttl = 3600 * 24;
    const expiresAt = new Date(Date.now() + ttl * 1000).toISOString();

    logger.debug('[LIVEKIT ICE] Generated ICE config', { userId: sanitizeForLog(userId), turnDomain, serversCount: iceServers.length, expiresAt });

    // Return ICE configuration
    res.json({
      iceServers,
      ttl,
      expiresAt
    });

  } catch (error) {
    logger.error('[LIVEKIT ICE] Error generating config', error);
    res.status(500).json({ error: 'Failed to generate ICE config' });
  }
});

/**
 * Get current LiveKit room info
 * GET /api/livekit/room/:channelId
 */
router.get('/room/:channelId', async (req, res) => {
  try {
    // Check if user is authenticated
    const session = req.session;
    
    if (!session || (!session.userinfo && !session.uuid)) {
      return res.status(401).json({ error: 'Not authenticated' });
    }

    // Get user info from either format
    const userId = session.userinfo?.id || session.uuid;

    const { channelId } = req.params;

    // Verify access
    const membership = await ChannelMembers.findOne({
      where: { channelId, userId }
    });

    if (!membership) {
      return res.status(403).json({ error: 'Not a channel member' });
    }

    // Return room information
    res.json({
      roomName: `channel-${channelId}`,
      connected: false,  // Client will update this
      participants: []   // Client will update this
    });

  } catch (error) {
    logger.error('[LIVEKIT] Room info error', error);
    res.status(500).json({ error: 'Failed to get room info' });
  }
});

/**
 * Webhook endpoint for LiveKit events (optional)
 * POST /api/livekit/webhook
 * 
 * LiveKit can send webhooks for:
 * - room_started, room_finished
 * - participant_joined, participant_left
 * - track_published, track_unpublished
 */
router.post('/webhook', async (req, res) => {
  try {
    const event = req.body;
    
    logger.info('[LIVEKIT WEBHOOK] Event received', { event: event.event, room: event.room?.name });

    // Handle different event types
    switch (event.event) {
      case 'room_started':
        // Room was created
        break;
      
      case 'room_finished':
        // Room ended
        break;
      
      case 'participant_joined':
        // User joined
        break;
      
      case 'participant_left':
        // User left
        break;
      
      case 'track_published':
        // Track (audio/video) published
        break;
      
      case 'track_unpublished':
        // Track removed
        break;
    }

    res.status(200).send('OK');
  } catch (error) {
    logger.error('[LIVEKIT WEBHOOK] Error', error);
    res.status(500).json({ error: 'Webhook processing failed' });
  }
});

module.exports = router;
