const express = require('express');
const router = express.Router();
const presenceService = require('../services/presenceService');
const { verifySessionAuth, verifyAuthEither } = require('../middleware/sessionAuth');

/**
 * Get presence for specific users (bulk check - GET with query params)
 * GET /api/presence/bulk?user_ids=uuid1,uuid2,uuid3
 * Used before initiating instant calls to check if recipients are online
 */
router.get('/presence/bulk', verifyAuthEither, async (req, res) => {
  try {
    const userIdsParam = req.query.user_ids;
    
    if (!userIdsParam) {
      return res.status(400).json({ error: 'user_ids query parameter required' });
    }

    const userIds = userIdsParam.split(',').map(id => id.trim()).filter(Boolean);
    
    if (userIds.length === 0) {
      return res.status(400).json({ error: 'user_ids must contain at least one ID' });
    }

    const presence = await presenceService.getPresence(userIds);
    
    res.json(presence);
  } catch (error) {
    console.error('Error getting bulk presence:', error);
    res.status(500).json({ error: 'Failed to get presence' });
  }
});

/**
 * DEPRECATED: Update heartbeat (no longer needed with socket-based tracking)
 * POST /api/presence/heartbeat
 */
router.post('/presence/heartbeat', verifyAuthEither, async (req, res) => {
  console.warn('[PRESENCE] /api/presence/heartbeat is deprecated');
  res.json({ status: 'deprecated', message: 'Heartbeat no longer required' });
});

/**
 * Get presence for specific users (bulk)
 * POST /api/presence/users
 */
router.post('/presence/users', verifyAuthEither, async (req, res) => {
  try {
    const { user_ids } = req.body;

    if (!Array.isArray(user_ids)) {
      return res.status(400).json({ error: 'user_ids array required' });
    }

    const presence = await presenceService.getPresence(user_ids);
    
    res.json(presence);
  } catch (error) {
    console.error('Error getting presence:', error);
    res.status(500).json({ error: 'Failed to get presence' });
  }
});

/**
 * Get presence for all channel members
 * GET /api/presence/channel/:channelId
 */
router.get('/presence/channel/:channelId', verifyAuthEither, async (req, res) => {
  try {
    const { channelId } = req.params;

    const presence = await presenceService.getChannelPresence(channelId);
    
    res.json(presence);
  } catch (error) {
    console.error('Error getting channel presence:', error);
    res.status(500).json({ error: 'Failed to get channel presence' });
  }
});

/**
 * Get presence for 1:1 conversation opponent
 * GET /api/presence/conversation/:userId
 */
router.get('/presence/conversation/:userId', verifyAuthEither, async (req, res) => {
  try {
    const { userId } = req.params;

    const presence = await presenceService.getPresence([userId]);
    
    res.json(presence[0] || { user_id: userId, status: 'offline' });
  } catch (error) {
    console.error('Error getting conversation presence:', error);
    res.status(500).json({ error: 'Failed to get presence' });
  }
});

/**
 * Get all online users
 * GET /api/presence/online
 */
router.get('/presence/online', verifyAuthEither, async (req, res) => {
  try {
    const onlineUsers = await presenceService.getOnlineUsers();
    
    res.json(onlineUsers);
  } catch (error) {
    console.error('Error getting online users:', error);
    res.status(500).json({ error: 'Failed to get online users' });
  }
});

module.exports = router;
