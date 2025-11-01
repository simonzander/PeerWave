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
const { AccessToken } = require('livekit-server-sdk');

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
router.post('/token', async (req, res) => {
  try {
    // Check if user is authenticated
    // Support both session.userinfo (REST API) and session.uuid (Socket.IO)
    const session = req.session;
    
    if (!session || (!session.userinfo && !session.uuid)) {
      console.log('[LiveKit] Unauthorized - No session found');
      return res.status(401).json({ error: 'Not authenticated' });
    }

    // Get user info from either format
    const userId = session.userinfo?.id || session.uuid;
    const username = session.userinfo?.username || session.email || 'Unknown';

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
