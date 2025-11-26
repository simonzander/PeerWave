const express = require('express');
const router = express.Router();
const { GroupItem, GroupItemRead, Channel, ChannelMembers, User, Client } = require('../db/model');
const { Op } = require('sequelize');
const { verifyAuthEither } = require('../middleware/sessionAuth');

/**
 * POST /api/group-items
 * Create a new group item (message, reaction, etc.)
 * Body: { channelId, itemId, type, payload, cipherType, senderDevice, timestamp }
 */
router.post('/', verifyAuthEither, async (req, res) => {
    try {
        const userId = req.userId;
        if (!userId) {
            return res.status(401).json({ error: 'Unauthorized' });
        }

        const { channelId, itemId, type, payload, cipherType, senderDevice, timestamp } = req.body;

        // Validate required fields
        if (!channelId || !itemId || !payload || !senderDevice) {
            return res.status(400).json({ error: 'Missing required fields' });
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

        // Check for duplicate itemId
        const existing = await GroupItem.findOne({
            where: { itemId: itemId }
        });

        if (existing) {
            return res.status(200).json({ 
                message: 'Item already exists', 
                item: existing 
            });
        }

        // Create group item
        const groupItem = await GroupItem.create({
            itemId: itemId,
            channel: channelId,
            sender: userId,
            senderDevice: senderDevice,
            type: type || 'message',
            payload: payload,
            cipherType: cipherType || 4,  // Default to SenderKey
            timestamp: timestamp || new Date()
        });

        res.status(201).json({
            success: true,
            item: groupItem
        });
    } catch (error) {
        console.error('Error creating group item:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/group-items/:channelId
 * Get all items for a channel
 * Query params: ?since=timestamp&limit=50
 */
router.get('/:channelId', verifyAuthEither, async (req, res) => {
    try {
        const userId = req.userId;
        if (!userId) {
            return res.status(401).json({ error: 'Unauthorized' });
        }

        const { channelId } = req.params;
        const { since, limit = 50 } = req.query;

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

        // Build query
        const where = { channel: channelId };
        if (since) {
            where.timestamp = { [Op.gt]: new Date(since) };
        }

        const items = await GroupItem.findAll({
            where: where,
            order: [['timestamp', 'ASC']],
            limit: parseInt(limit),
            include: [
                {
                    model: User,
                    as: 'Sender',
                    attributes: ['uuid', 'displayName']
                }
            ]
        });

        res.json({
            success: true,
            items: items,
            count: items.length
        });
    } catch (error) {
        console.error('Error fetching group items:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * POST /api/group-items/:itemId/read
 * Mark an item as read
 * Body: { deviceId }
 */
router.post('/:itemId/read', verifyAuthEither, async (req, res) => {
    try {
        const userId = req.userId;
        if (!userId) {
            return res.status(401).json({ error: 'Unauthorized' });
        }

        const { itemId } = req.params;
        const { deviceId } = req.body;

        if (!deviceId) {
            return res.status(400).json({ error: 'deviceId required' });
        }

        // Find the group item
        const groupItem = await GroupItem.findOne({
            where: { itemId: itemId }
        });

        if (!groupItem) {
            return res.status(404).json({ error: 'Item not found' });
        }

        // Check if user is member of channel
        const membership = await ChannelMembers.findOne({
            where: {
                userId: userId,
                channelId: groupItem.channel
            }
        });

        if (!membership) {
            return res.status(403).json({ error: 'Not a member of this channel' });
        }

        // Create or update read receipt
        const [readReceipt, created] = await GroupItemRead.findOrCreate({
            where: {
                itemId: groupItem.uuid,
                userId: userId,
                deviceId: deviceId
            },
            defaults: {
                readAt: new Date()
            }
        });

        if (!created) {
            // Already marked as read
            return res.json({
                success: true,
                message: 'Already marked as read',
                readReceipt: readReceipt
            });
        }

        // Count total reads for this item
        const readCount = await GroupItemRead.count({
            where: { itemId: groupItem.uuid }
        });

        // Count total members in channel
        const memberCount = await ChannelMembers.count({
            where: { channelId: groupItem.channel }
        });

        res.json({
            success: true,
            readReceipt: readReceipt,
            readCount: readCount,
            totalMembers: memberCount,
            allRead: readCount >= memberCount
        });
    } catch (error) {
        console.error('Error marking item as read:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/group-items/:itemId/read-status
 * Get read status for an item
 */
router.get('/:itemId/read-status', verifyAuthEither, async (req, res) => {
    try {
        const userId = req.userId;
        if (!userId) {
            return res.status(401).json({ error: 'Unauthorized' });
        }

        const { itemId } = req.params;

        // Find the group item
        const groupItem = await GroupItem.findOne({
            where: { itemId: itemId }
        });

        if (!groupItem) {
            return res.status(404).json({ error: 'Item not found' });
        }

        // Check if user is member of channel
        const membership = await ChannelMembers.findOne({
            where: {
                userId: userId,
                channelId: groupItem.channel
            }
        });

        if (!membership) {
            return res.status(403).json({ error: 'Not a member of this channel' });
        }

        // Get all read receipts
        const readReceipts = await GroupItemRead.findAll({
            where: { itemId: groupItem.uuid },
            include: [
                {
                    model: User,
                    as: 'User',
                    attributes: ['uuid', 'displayName']
                }
            ]
        });

        // Count total members
        const memberCount = await ChannelMembers.count({
            where: { channelId: groupItem.channel }
        });

        res.json({
            success: true,
            readCount: readReceipts.length,
            totalMembers: memberCount,
            allRead: readReceipts.length >= memberCount,
            readBy: readReceipts
        });
    } catch (error) {
        console.error('Error fetching read status:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});



module.exports = router;
