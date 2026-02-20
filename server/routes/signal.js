const express = require('express');
const { SignalSignedPreKey, SignalPreKey, SignalIdentity, Client } = require('../db/model');
const { verifyAuthEither } = require('../middleware/sessionAuth');
const logger = require('../utils/logger');
const writeQueue = require('../db/writeQueue');
const { getDeviceSockets } = require('../utils/deviceSockets');
const {
  normalizePagination,
  fetchPendingMessagesForDevice,
  fetchPendingMessagesForDeviceV2,
} = require('../services/pendingMessagesService');

const router = express.Router();

/**
 * POST /api/signal/signed-prekey
 * Store a signed pre-key
 */
router.post('/signed-prekey', verifyAuthEither, async (req, res) => {
  try {
    logger.info('[SIGNAL API] POST /signed-prekey called');
    logger.debug('[SIGNAL API] Headers:', { 
      contentType: req.headers['content-type'],
      hasRawBody: !!req.rawBody,
      rawBodyLength: req.rawBody?.length
    });
    logger.debug('[SIGNAL API] Body:', { 
      body: req.body,
      bodyKeys: Object.keys(req.body || {}),
      bodyType: typeof req.body
    });
    logger.debug('[SIGNAL API] Session:', { 
      hasSession: !!req.session, 
      sessionUuid: req.session?.uuid,
      sessionAuth: req.session?.authenticated 
    });
    logger.debug('[SIGNAL API] Auth result:', { userId: req.userId, clientId: req.clientId });
    
    const userId = req.userId;
    const clientId = req.clientId;
    
    if (!userId || !clientId) {
      logger.warn('[SIGNAL API] 401 - Missing userId or clientId');
      return res.status(401).json({ error: 'Unauthorized' });
    }

    const { id, data, signature } = req.body;
    
    logger.debug('[SIGNAL API] Extracted fields:', { 
      hasId: id !== undefined && id !== null, 
      hasData: !!data, 
      hasSignature: !!signature,
      id, 
      dataLength: data?.length,
      signatureLength: signature?.length
    });
    
    if (id === undefined || id === null || !data || !signature) {
      logger.warn('[SIGNAL API] 400 - Missing fields:', { id: id !== undefined && id !== null, data: !!data, signature: !!signature });
      return res.status(400).json({ error: 'Missing required fields: id, data, signature' });
    }

    // Create if not exists, otherwise do nothing - enqueue write operation
    await writeQueue.enqueue(async () => {
      return await SignalSignedPreKey.findOrCreate({
        where: {
          signed_prekey_id: id,
          owner: userId,
          client: clientId,
        },
        defaults: {
          signed_prekey_data: data,
          signed_prekey_signature: signature,
        }
      });
    }, `storeSignedPreKey-${id}`);

    logger.info('[SIGNAL API] ✅ Signed pre-key stored successfully');
    res.json({ success: true });
  } catch (error) {
    logger.error('Error storing signed pre-key:', error);
    res.status(500).json({ error: 'Failed to store signed pre-key' });
  }
});

/**
 * DELETE /api/signal/signed-prekey/:id
 * Remove a signed pre-key
 */
router.delete('/signed-prekey/:id', verifyAuthEither, async (req, res) => {
  try {
    const userId = req.userId;
    const clientId = req.clientId;
    
    if (!userId || !clientId) {
      return res.status(401).json({ error: 'Unauthorized' });
    }

    const { id } = req.params;

    await writeQueue.enqueue(async () => {
      return await SignalSignedPreKey.destroy({
        where: { 
          signed_prekey_id: parseInt(id), 
          owner: userId, 
          client: clientId 
        }
      });
    }, `removeSignedPreKey-${id}`);

    res.json({ success: true });
  } catch (error) {
    logger.error('Error removing signed pre-key:', error);
    res.status(500).json({ error: 'Failed to remove signed pre-key' });
  }
});

/**
 * GET /api/signal/signed-prekeys
 * Get all signed pre-keys for the current user/device
 */
router.get('/signed-prekeys', verifyAuthEither, async (req, res) => {
  try {
    const userId = req.userId;
    const clientId = req.clientId;
    
    if (!userId || !clientId) {
      return res.status(401).json({ error: 'Unauthorized' });
    }

    const signedPreKeys = await SignalSignedPreKey.findAll({
      where: { owner: userId, client: clientId },
      order: [['createdAt', 'DESC']]
    });

    res.json({ success: true, signedPreKeys });
  } catch (error) {
    logger.error('Error fetching signed pre-keys:', error);
    res.status(500).json({ error: 'Failed to fetch signed pre-keys' });
  }
});

/**
 * GET /api/signal/pending-messages
 * Fetch pending Signal messages for the current user/device
 */
router.get('/pending-messages', verifyAuthEither, async (req, res) => {
  try {
    const userId = req.userId;
    const clientId = req.clientId;

    if (!userId || !clientId) {
      return res.status(401).json({ error: 'Unauthorized' });
    }

    const { limit, offset } = normalizePagination({
      rawLimit: req.query.limit ?? req.query.batchSize ?? 20,
      rawOffset: req.query.offset ?? 0,
      defaultLimit: 20,
    });
    const source = req.query.source ?? 'http';

    const client = await Client.findOne({
      where: { clientid: clientId },
      attributes: ['device_id'],
    });

    if (!client?.device_id) {
      logger.warn('[SIGNAL API] Missing device_id for pending messages');
      return res.status(400).json({ error: 'Missing device id' });
    }

    const deviceId = client.device_id;

    logger.info(
      `[SIGNAL API] Fetching pending messages (${source}): limit=${limit}, offset=${offset}`,
    );

    const { responseItems, hasMore } = await fetchPendingMessagesForDevice({
      userId,
      deviceId,
      limit,
      offset,
    });

    return res.json({
      success: true,
      items: responseItems,
      messages: responseItems,
      hasMore,
      offset,
      total: responseItems.length,
    });
  } catch (error) {
    logger.error('[SIGNAL API] Error fetching pending messages', error);
    return res.status(500).json({ error: 'Failed to fetch pending messages' });
  }
});

/**
 * GET /api/signal/pending-messages/v2
 * Fetch pending Signal messages for the current user/device (1:1 + group)
 */
router.get('/pending-messages/v2', verifyAuthEither, async (req, res) => {
  try {
    const userId = req.userId;
    const clientId = req.clientId;

    if (!userId || !clientId) {
      return res.status(401).json({ error: 'Unauthorized' });
    }

    const { limit, offset } = normalizePagination({
      rawLimit: req.query.limit ?? req.query.batchSize ?? 20,
      rawOffset: req.query.offset ?? 0,
      defaultLimit: 20,
    });
    const source = req.query.source ?? 'http';

    const client = await Client.findOne({
      where: { clientid: clientId },
      attributes: ['device_id'],
    });

    if (!client?.device_id) {
      logger.warn('[SIGNAL API] Missing device_id for pending messages v2');
      return res.status(400).json({ error: 'Missing device id' });
    }

    const deviceId = client.device_id;

    logger.info(
      `[SIGNAL API] Fetching pending messages v2 (${source}): limit=${limit}, offset=${offset}`,
    );

    const { responseItems, hasMore, totalAvailable } =
      await fetchPendingMessagesForDeviceV2({
        userId,
        deviceId,
        limit,
        offset,
      });

    return res.json({
      success: true,
      items: responseItems,
      messages: responseItems,
      hasMore,
      offset,
      total: responseItems.length,
      totalAvailable: totalAvailable ?? responseItems.length,
    });
  } catch (error) {
    logger.error('[SIGNAL API] Error fetching pending messages v2', error);
    return res.status(500).json({ error: 'Failed to fetch pending messages' });
  }
});

/**
 * POST /api/signal/prekey
 * Store a pre-key
 */
router.post('/prekey', verifyAuthEither, async (req, res) => {
  try {
    const userId = req.userId;
    const clientId = req.clientId;
    
    if (!userId || !clientId) {
      return res.status(401).json({ error: 'Unauthorized' });
    }

    const { id, data } = req.body;
    
    if (id === undefined || id === null || !data) {
      return res.status(400).json({ error: 'Missing required fields: id, data' });
    }

    // Only store if prekey_data is a 33-byte base64-encoded public key
    let decoded;
    try {
      decoded = Buffer.from(data, 'base64');
    } catch (e) {
      logger.error('[SIGNAL API] Invalid base64 in prekey_data');
      return res.status(400).json({ error: 'Invalid base64 encoding' });
    }
    
    if (decoded.length !== 33) {
      logger.error(`[SIGNAL API] Refusing to store pre-key: prekey_data is ${decoded.length} bytes (expected 33). Possible private key leak or wrong format.`);
      return res.status(400).json({ error: 'Invalid key size - must be 33 bytes' });
    }

    await writeQueue.enqueue(async () => {
      return await SignalPreKey.findOrCreate({
        where: {
          prekey_id: id,
          owner: userId,
          client: clientId,
        },
        defaults: {
          prekey_data: data,
        }
      });
    }, `storePreKey-${id}`);

    res.json({ success: true });
  } catch (error) {
    logger.error('Error storing pre-key:', error);
    res.status(500).json({ error: 'Failed to store pre-key' });
  }
});

/**
 * DELETE /api/signal/prekey/:id
 * Remove a pre-key
 */
router.delete('/prekey/:id', verifyAuthEither, async (req, res) => {
  try {
    const userId = req.userId;
    const clientId = req.clientId;
    
    if (!userId || !clientId) {
      return res.status(401).json({ error: 'Unauthorized' });
    }

    const { id } = req.params;

    await writeQueue.enqueue(async () => {
      return await SignalPreKey.destroy({
        where: { 
          prekey_id: parseInt(id), 
          owner: userId, 
          client: clientId 
        }
      });
    }, `removePreKey-${id}`);

    res.json({ success: true });
  } catch (error) {
    logger.error('Error removing pre-key:', error);
    res.status(500).json({ error: 'Failed to remove pre-key' });
  }
});

/**
 * DELETE /api/signal/keys
 * Delete ALL Signal keys for current device (when IdentityKeyPair is regenerated)
 */
router.delete('/keys', verifyAuthEither, async (req, res) => {
  try {
    const userId = req.userId;
    const clientId = req.clientId;
    
    if (!userId || !clientId) {
      return res.status(401).json({ error: 'Unauthorized' });
    }

    const { reason, timestamp } = req.body;
    
    logger.warn('[SIGNAL API] CRITICAL: Deleting ALL Signal keys');
    logger.debug('[SIGNAL API] Key deletion details:', { 
      userId, 
      clientId,
      reason: reason || 'Unknown',
      timestamp: timestamp || new Date().toISOString()
    });

    await writeQueue.enqueue(async () => {
      const results = await Promise.all([
        SignalPreKey.destroy({ where: { owner: userId, client: clientId } }),
        SignalSignedPreKey.destroy({ where: { owner: userId, client: clientId } }),
        SignalIdentity.destroy({ where: { owner: userId, client: clientId } })
      ]);
      
      logger.info('[SIGNAL API] Key deletion completed:', {
        preKeysDeleted: results[0],
        signedPreKeysDeleted: results[1],
        identitiesDeleted: results[2]
      });
      
      return results;
    }, `deleteAllSignalKeys-${userId}-${clientId}`);

    res.json({ success: true });
  } catch (error) {
    logger.error('[SIGNAL API] Error deleting all Signal keys:', error);
    res.status(500).json({ error: 'Failed to delete Signal keys' });
  }
});

/**
 * POST /api/signal/identity
 * Store identity key
 */
router.post('/identity', verifyAuthEither, async (req, res) => {
  try {
    const userId = req.userId;
    const clientId = req.clientId;
    
    if (!userId || !clientId) {
      return res.status(401).json({ error: 'Unauthorized' });
    }

    const { publicKey, registrationId } = req.body;
    
    if (!publicKey || registrationId === undefined) {
      return res.status(400).json({ error: 'Missing required fields: publicKey, registrationId' });
    }

    await writeQueue.enqueue(async () => {
      return await SignalIdentity.upsert({
        owner: userId,
        client: clientId,
        identity_key: publicKey,
        registration_id: registrationId,
      });
    }, `storeIdentity-${userId}-${clientId}`);

    res.json({ success: true });
  } catch (error) {
    logger.error('Error storing identity:', error);
    res.status(500).json({ error: 'Failed to store identity' });
  }
});

/**
 * POST /api/signal/sender-key/rotate
 * Rotate sender key for a group
 * This triggers the group to regenerate and distribute a new sender key
 */
router.post('/sender-key/rotate', verifyAuthEither, async (req, res) => {
  try {
    const userId = req.userId;
    const clientId = req.clientId;
    
    if (!userId || !clientId) {
      return res.status(401).json({ error: 'Unauthorized' });
    }

    const { groupId, address } = req.body;
    
    if (!groupId || !address || !address.name || address.deviceId === undefined) {
      return res.status(400).json({ 
        error: 'Missing required fields: groupId, address (with name and deviceId)' 
      });
    }

    logger.info('[SIGNAL API] Sender key rotation requested', {
      userId,
      clientId,
      groupId,
      senderName: address.name,
      senderDeviceId: address.deviceId
    });

    // Note: Actual sender key distribution happens via Signal Protocol
    // on the client side. This endpoint just logs the rotation event.
    // In a full implementation, you might:
    // - Notify other group members
    // - Track rotation history
    // - Enforce rotation policies

    res.json({ 
      success: true,
      message: 'Sender key rotation acknowledged'
    });
  } catch (error) {
    logger.error('Error rotating sender key:', error);
    res.status(500).json({ error: 'Failed to rotate sender key' });
  }
});

/**
 * POST /api/signal/distribute-sender-key
 * Distribute encrypted sender key to a specific group member
 * Signal Protocol: Sender keys are distributed via 1-to-1 encrypted channels
 * Server only routes the encrypted payload, never stores sender keys
 */
router.post('/distribute-sender-key', verifyAuthEither, async (req, res) => {
  try {
    const senderId = req.userId;
    const senderClientId = req.clientId;
    
    if (!senderId || !senderClientId) {
      return res.status(401).json({ error: 'Unauthorized' });
    }

    const { groupId, recipientId, recipientDeviceId, encryptedDistribution, messageType } = req.body;
    
    if (!groupId || !recipientId || !recipientDeviceId || !encryptedDistribution || messageType === undefined) {
      return res.status(400).json({ 
        error: 'Missing required fields: groupId, recipientId, recipientDeviceId, encryptedDistribution, messageType' 
      });
    }

    logger.info('[SIGNAL API] Distributing sender key');
    logger.debug(`[SIGNAL API] Sender: ${senderId}, Recipient: ${recipientId}:${recipientDeviceId}, Group: ${groupId}`);

    // Get recipient's socket (if online)
    const deviceSockets = getDeviceSockets();
    const recipientSocketId = deviceSockets.get(`${recipientId}:${recipientDeviceId}`);
    
    // Get sender's device ID for the response
    const senderClient = await Client.findOne({
      where: { clientid: senderClientId },
      attributes: ['device_id']
    });

    const payload = {
      groupId,
      senderId,
      senderDeviceId: senderClient?.device_id || 1,
      distributionMessage: encryptedDistribution,  // Encrypted SenderKeyDistributionMessage
      messageType
    };

    if (recipientSocketId) {
      // Recipient is online - deliver immediately via Socket.IO
      const io = req.app.get('io');
      
      if (!io) {
        logger.error('[SIGNAL API] Socket.IO instance not available');
        return res.status(500).json({ error: 'Socket.IO not initialized' });
      }
      
      // Use io.to() to emit to a specific socket by ID
      io.to(recipientSocketId).emit('receiveSenderKeyDistribution', payload);
      logger.info('[SIGNAL API] ✅ Sender key delivered (online)');
      return res.json({ success: true, delivered: true });
    }
    
    // Recipient is offline - queue for delivery
    logger.info('[SIGNAL API] ⚠️ Recipient offline, queuing sender key distribution');
    
    await writeQueue.enqueue(async () => {
      return await Item.create({
        sender: senderId,
        deviceSender: senderClient?.device_id || 1,
        receiver: recipientId,
        deviceReceiver: recipientDeviceId,
        type: 'signal:senderKeyDistribution',
        payload: JSON.stringify(payload),
        cipherType: messageType,  // The outer encryption type (PreKey or Signal)
        itemId: `senderkey-${groupId}-${Date.now()}`
      });
    }, `senderkey-dist-${recipientId}-${recipientDeviceId}-${Date.now()}`);
    
    logger.info('[SIGNAL API] ✅ Sender key queued for offline delivery');
    res.json({ success: true, delivered: false, queued: true });
  } catch (error) {
    logger.error('[SIGNAL API] Error distributing sender key:', error);
    res.status(500).json({ error: 'Failed to distribute sender key' });
  }
});

module.exports = router;
