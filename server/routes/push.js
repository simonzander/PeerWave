/**
 * Push Notification Routes
 * 
 * Endpoints for managing FCM push notification tokens.
 * If Firebase is not configured, endpoints return 200 but do nothing.
 */

const express = require('express');
const router = express.Router();
const { PushToken } = require('../db/model');
const { isFirebaseConfigured } = require('../services/firebase_admin');
const { verifyAuthEither } = require('../middleware/sessionAuth');
const logger = require('../utils/logger');

/**
 * POST /api/push/register
 * Register or update FCM token for a device
 * 
 * Body:
 * - fcm_token: Firebase Cloud Messaging token
 * - client_id: Client UUID (from Client model)
 * - platform: 'android' or 'ios'
 * - last_seen: ISO timestamp
 */
router.post('/register', verifyAuthEither, async (req, res) => {
  try {
    // Check authentication (userId is set by verifyAuthEither middleware)
    const userId = req.userId;
    if (!userId) {
      return res.status(401).json({ error: 'Not authenticated' });
    }

    // If Firebase not configured, return success without doing anything
    if (!isFirebaseConfigured()) {
      logger.debug('[PUSH API] Firebase not configured, ignoring token registration');
      return res.json({ success: true, message: 'Push notifications not configured' });
    }

    const { fcm_token, client_id, platform, last_seen } = req.body;

    // Validate required fields
    if (!fcm_token || !client_id || !platform) {
      return res.status(400).json({ error: 'Missing required fields: fcm_token, client_id, platform' });
    }

    // Validate platform
    if (!['android', 'ios'].includes(platform)) {
      return res.status(400).json({ error: 'Invalid platform. Must be android or ios' });
    }

    // Parse last_seen as Date
    const lastSeenDate = last_seen ? new Date(last_seen) : new Date();

    // Upsert token (create or update)
    const [token, created] = await PushToken.upsert({
      user_id: userId,
      client_id,
      fcm_token,
      platform,
      last_seen: lastSeenDate,
      updated_at: new Date()
    }, {
      conflictFields: ['client_id']
    });

    if (created) {
      logger.info(`[PUSH API] Token registered for user ${userId}, client ${client_id}`);
    } else {
      logger.info(`[PUSH API] Token updated for user ${userId}, client ${client_id}`);
    }

    res.json({ success: true, created });
  } catch (error) {
    logger.error('[PUSH API] Token registration error:', error);
    res.status(500).json({ error: 'Failed to register token' });
  }
});

/**
 * POST /api/push/unregister
 * Remove FCM token for a device
 * 
 * Body:
 * - client_id: Client UUID
 */
router.post('/unregister', verifyAuthEither, async (req, res) => {
  try {
    const userId = req.userId;
    if (!userId) {
      return res.status(401).json({ error: 'Not authenticated' });
    }

    // If Firebase not configured, return success without doing anything
    if (!isFirebaseConfigured()) {
      logger.debug('[PUSH API] Firebase not configured, ignoring token unregistration');
      return res.json({ success: true, message: 'Push notifications not configured' });
    }

    const { client_id } = req.body;

    if (!client_id) {
      return res.status(400).json({ error: 'Missing required field: client_id' });
    }

    // Delete token
    const deleted = await PushToken.destroy({
      where: {
        user_id: userId,
        client_id
      }
    });

    if (deleted > 0) {
      logger.info(`[PUSH API] Token removed for user ${userId}, client ${client_id}`);
    }

    res.json({ success: true, deleted: deleted > 0 });
  } catch (error) {
    logger.error('[PUSH API] Token unregistration error:', error);
    res.status(500).json({ error: 'Failed to unregister token' });
  }
});

/**
 * GET /api/push/status
 * Check if push notifications are configured and enabled
 */
router.get('/status', (req, res) => {
  const configured = isFirebaseConfigured();
  res.json({
    configured,
    message: configured 
      ? 'Push notifications are enabled' 
      : 'Push notifications are not configured'
  });
});

module.exports = router;
