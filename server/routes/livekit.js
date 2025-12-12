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
      console.log('[LiveKit] Unauthorized - No user ID found');
      return res.status(401).json({ error: 'Not authenticated' });
    }

    const { channelId } = req.body;

    if (!channelId) {
      return res.status(400).json({ error: 'channelId required' });
    }

    console.log(`[LiveKit] Token request: userId=${userId}, channelId=${channelId}`);

    // Verify user has access to this channel
    const channel = await Channel.findByPk(channelId);
    if (!channel) {
      console.log('[LiveKit] Channel not found:', channelId);
      return res.status(404).json({ error: 'Channel not found' });
    }

    // Check if user is a member
    const membership = await ChannelMembers.findOne({
      where: { channelId, userId }
    });

    if (!membership) {
      return res.status(403).json({ error: 'Not a channel member' });
    }

    console.log(`[LiveKit] Membership found:`, {
      userId,
      channelId,
      permissions: membership.permissions,
      hasPermissions: !!membership.permissions
    });

    // Check if user has WebRTC permissions (safely handle missing permissions object)
    const hasWebRtcPermission = membership.permissions?.channelWebRtc ?? true; // Default to true if permissions not set
    
    if (!hasWebRtcPermission) {
      console.log('[LiveKit] User lacks WebRTC permission');
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
    console.error('LiveKit token generation error:', error);
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
      console.log('[LiveKit Meeting] Unauthorized - No user ID found');
      return res.status(401).json({ error: 'Not authenticated' });
    }

    const { meetingId } = req.body;

    if (!meetingId) {
      return res.status(400).json({ error: 'meetingId required' });
    }

    console.log(`[LiveKit Meeting] Token request: userId=${userId}, meetingId=${meetingId}`);

    // Get meeting from hybrid storage (memory + DB)
    const meeting = await meetingService.getMeeting(meetingId);

    if (!meeting) {
      console.log('[LiveKit Meeting] Meeting not found:', meetingId);
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check if user is creator, participant, or invited
    const isOwner = meeting.created_by === userId;
    const isParticipant = meeting.participants && meeting.participants.some(p => p.uuid === userId);
    const isInvited = meeting.invited_participants && meeting.invited_participants.includes(userId);

    if (!isOwner && !isParticipant && !isInvited) {
      console.log('[LiveKit Meeting] User not authorized:', userId);
      return res.status(403).json({ error: 'Not authorized for this meeting' });
    }

    console.log(`[LiveKit Meeting] User authorized:`, {
      userId,
      meetingId,
      isOwner,
      isParticipant,
      isInvited
    });

    // Get LiveKit configuration from environment
    const apiKey = process.env.LIVEKIT_API_KEY || 'devkey';
    const apiSecret = process.env.LIVEKIT_API_SECRET || 'secret';
    const livekitUrl = process.env.LIVEKIT_URL || 'ws://localhost:7880';

    // Create access token
    const token = new AccessToken(apiKey, apiSecret, {
      identity: `${userId}`,
      name: username,
      metadata: JSON.stringify({
        userId,
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
      const deviceId = req.session?.device_id || req.deviceId || 0;
      await meetingService.updateParticipantStatus(meetingId, userId, deviceId, 'joined');
      console.log(`[LiveKit Meeting] Updated participant ${userId} status to joined`);
    } catch (statusError) {
      console.error('[LiveKit Meeting] Failed to update participant status:', statusError);
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
    console.error('LiveKit meeting token generation error:', error);
    res.status(500).json({ error: 'Failed to generate meeting token' });
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
      console.log('[LiveKit ICE] Unauthorized - No user ID found');
      return res.status(401).json({ error: 'Not authenticated' });
    }

    console.log(`[LiveKit ICE] Config request: userId=${userId}, username=${username}`);

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

    console.log(`[LiveKit ICE] Generated ICE config for user ${userId}:`, {
      turnDomain,
      serversCount: iceServers.length,
      expiresAt
    });

    // Return ICE configuration
    res.json({
      iceServers,
      ttl,
      expiresAt
    });

  } catch (error) {
    console.error('[LiveKit ICE] Error generating config:', error);
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
    console.error('LiveKit room info error:', error);
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
    
    console.log('LiveKit webhook event:', event.event, event.room?.name);

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
    console.error('LiveKit webhook error:', error);
    res.status(500).json({ error: 'Webhook processing failed' });
  }
});

module.exports = router;
