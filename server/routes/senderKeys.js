const express = require('express');
const router = express.Router();
const { SignalSenderKey, ChannelMembers, User, Client } = require('../db/model');

/**
 * GET /api/sender-keys/:channelId
 * Get all sender keys for a channel (for initial sync)
 */
router.get('/:channelId', async (req, res) => {
    try {
        const userId = req.session?.uuid;
        if (!userId) {
            return res.status(401).json({ error: 'Unauthorized' });
        }

        const { channelId } = req.params;

        // Check if user is member of channel
        const membership = await ChannelMembers.findOne({
            where: {
                userId: userId,
                channelId: channelId
            }
        });

        if (!membership) {
            return res.status(403).json({ error: 'Not a member of this channel' });
        }

        // Get all sender keys for this channel
        const senderKeys = await SignalSenderKey.findAll({
            where: { channel: channelId },
            include: [
                {
                    model: User,
                    attributes: ['uuid', 'displayName']
                },
                {
                    model: Client,
                    attributes: ['clientid', 'device_id']
                }
            ]
        });

        res.json({
            success: true,
            senderKeys: senderKeys.map(sk => ({
                userId: sk.owner,
                deviceId: sk.Client?.device_id,
                clientId: sk.client,
                senderKey: sk.sender_key,  // base64 encoded SenderKeyDistributionMessage
                updatedAt: sk.updatedAt
            })),
            count: senderKeys.length
        });
    } catch (error) {
        console.error('Error fetching sender keys:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/sender-keys/:channelId/:userId/:deviceId
 * Get a specific sender key
 */
router.get('/:channelId/:userId/:deviceId', async (req, res) => {
    try {
        const requesterId = req.session?.uuid;
        if (!requesterId) {
            return res.status(401).json({ error: 'Unauthorized' });
        }

        const { channelId, userId, deviceId } = req.params;

        // Check if requester is member of channel
        const membership = await ChannelMembers.findOne({
            where: {
                userId: requesterId,
                channelId: channelId
            }
        });

        if (!membership) {
            return res.status(403).json({ error: 'Not a member of this channel' });
        }

        // Find the client for this user and device
        const client = await Client.findOne({
            where: {
                owner: userId,
                device_id: parseInt(deviceId)
            }
        });

        if (!client) {
            return res.status(404).json({ error: 'Client not found' });
        }

        // Get sender key
        const senderKey = await SignalSenderKey.findOne({
            where: {
                channel: channelId,
                client: client.clientid
            }
        });

        if (!senderKey) {
            return res.status(404).json({ error: 'Sender key not found' });
        }

        res.json({
            success: true,
            userId: userId,
            deviceId: parseInt(deviceId),
            clientId: client.clientid,
            senderKey: senderKey.sender_key,
            updatedAt: senderKey.updatedAt
        });
    } catch (error) {
        console.error('Error fetching sender key:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * POST /api/sender-keys/:channelId
 * Create or update sender key for current user
 * Body: { senderKey, deviceId }
 */
router.post('/:channelId', async (req, res) => {
    try {
        const userId = req.session?.uuid;
        if (!userId) {
            return res.status(401).json({ error: 'Unauthorized' });
        }

        const { channelId } = req.params;
        const { senderKey, deviceId } = req.body;

        if (!senderKey || !deviceId) {
            return res.status(400).json({ error: 'senderKey and deviceId required' });
        }

        // Check if user is member of channel
        const membership = await ChannelMembers.findOne({
            where: {
                userId: userId,
                channelId: channelId
            }
        });

        if (!membership) {
            return res.status(403).json({ error: 'Not a member of this channel' });
        }

        // Find the client
        const client = await Client.findOne({
            where: {
                owner: userId,
                device_id: parseInt(deviceId)
            }
        });

        if (!client) {
            return res.status(404).json({ error: 'Client not found' });
        }

        // Create or update sender key
        const [storedKey, created] = await SignalSenderKey.findOrCreate({
            where: {
                channel: channelId,
                client: client.clientid
            },
            defaults: {
                owner: userId,
                sender_key: senderKey
            }
        });

        if (!created) {
            // Update existing key
            storedKey.sender_key = senderKey;
            await storedKey.save();
        }

        res.json({
            success: true,
            created: created,
            message: created ? 'Sender key created' : 'Sender key updated'
        });
    } catch (error) {
        console.error('Error storing sender key:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

module.exports = router;
