const config = require('../config/config');
const express = require("express");
const { Sequelize, DataTypes, Op, UUID, col } = require('sequelize');
const { Fido2Lib } = require('fido2-lib');
const bodyParser = require('body-parser'); // Import body-parser
const nodemailer = require("nodemailer");
const crypto = require('crypto');
const session = require('express-session');
const cors = require('cors');
const magicLinks = require('../store/magicLinksStore');
const { User, Channel, Thread, SignalSignedPreKey, SignalPreKey, Client, Item, Role, ChannelMembers } = require('../db/model');
const fetch = (...args) => import('node-fetch').then(({default: fetch}) => fetch(...args));
const writeQueue = require('../db/writeQueue');
const { autoAssignRoles } = require('../db/autoAssignRoles');
const { hasServerPermission } = require('../db/roleHelpers');
const { buildIceServerConfig } = require('../lib/turnCredentials');
const { RoomServiceClient } = require('livekit-server-sdk');

async function getLocationFromIp(ip) {
    const response = await fetch(`https://ipapi.co/${ip}/json/`);
    if (!response.ok) return null;
    const data = await response.json();
    return {
        city: data.city,
        region: data.region,
        country: data.country_name,
        org: data.org,
        ip: data.ip
    };
}

const clientRoutes = express.Router();

// Add body-parser middleware with default limits for all other routes
clientRoutes.use((req, res, next) => {
    // Skip body parsing for profile setup route - will be handled separately
    if (req.path === '/client/profile/setup' && req.method === 'POST') {
        return next();
    }
    bodyParser.urlencoded({ extended: true })(req, res, () => {
        bodyParser.json()(req, res, next);
    });
});

// Configure session middleware
clientRoutes.use(session({
    secret: config.session.secret, // Replace with a strong secret key
    resave: config.session.resave,
    saveUninitialized: config.session.saveUninitialized,
    cookie: config.cookie // Set to true if using HTTPS
}));

clientRoutes.get("/client/meta", (req, res) => {
    const response = {
        name: "PeerWave",
        version: "1.0.0",
    };
    
    // Add ICE server configuration if user is authenticated
    // Use session UUID or generate a temporary ID for unauthenticated users
    const userId = req.session.uuid || `guest_${Date.now()}`;
    
    try {
        const iceServers = buildIceServerConfig(config, userId);
        response.iceServers = iceServers;
        
        console.log(`[CLIENT META] Providing ICE servers to user ${userId}`);
    } catch (error) {
        console.error('[CLIENT META] Failed to build ICE server config:', error);
        // Fallback to public STUN only
        response.iceServers = [
            { urls: ['stun:stun.l.google.com:19302'] }
        ];
    }
    
    res.json(response);
});

clientRoutes.get("/direct/messages/:userId", async (req, res) => {
    const { userId } = req.params;
    // session.deviceId and session.uuid must be set
    const sessionDeviceId = req.session.deviceId;
    const sessionUuid = req.session.uuid;
    if (!sessionDeviceId || !sessionUuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    try {
        // Hole alle Nachrichten für DIESES Gerät (sessionDeviceId):
        // 1. Von Alice an mich (receiver = meine uuid, sender = Alice, deviceReceiver = mein deviceId)
        // 2. Von mir an Alice (receiver = Alice, sender = ich, deviceReceiver = mein deviceId)
        //    -> Diese Nachrichten wurden für meine eigenen Geräte verschlüsselt (Multi-Device)
        // 
        // WICHTIG: deviceReceiver = sessionDeviceId stellt sicher, dass nur Nachrichten
        // abgerufen werden, die FÜR DIESES GERÄT verschlüsselt wurden
        // NOTE: Item table contains ONLY 1:1 messages (no channel field)
        // Group messages are stored in GroupItem table
        const result = await Item.sequelize.query(`
            SELECT *
            FROM Items
            WHERE
            deviceReceiver = :sessionDeviceId
            AND receiver = :sessionUuid
            AND (sender = :userId OR sender = :sessionUuid)
            ORDER BY rowid ASC
        `, {
            replacements: { sessionDeviceId, sessionUuid, userId },
            model: Item,
            mapToModel: true
        });
        console.log(`[CLIENT.JS] Direct messages (1:1 only) for device ${sessionDeviceId}:`, result.length);
        console.log(`[CLIENT.JS] Query params: deviceReceiver=${sessionDeviceId}, receiver=${sessionUuid}, sender=${userId} OR sender=${sessionUuid}`);
        if (result.length > 0) {
            console.log(`[CLIENT.JS] Sample messages:`, result.slice(0, 3).map(r => ({
                sender: r.sender,
                receiver: r.receiver,
                deviceSender: r.deviceSender,
                deviceReceiver: r.deviceReceiver,
                cipherType: r.cipherType,
                itemId: r.itemId
            })));
        }
        res.status(200).json(result);
    } catch (error) {
        console.error('Error fetching direct messages:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// GET all devices of channel members (for group message encryption)
clientRoutes.get("/channels/:channelId/member-devices", async (req, res) => {
    const { channelId } = req.params;
    const sessionUuid = req.session.uuid;
    
    if (!sessionUuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    
    try {
        // Verify channel exists and user is member
        const channel = await Channel.findByPk(channelId);
        if (!channel) {
            return res.status(404).json({ status: "error", message: "Channel not found" });
        }
        
        // Check if user is owner or member
        const isOwner = channel.owner === sessionUuid;
        const isMember = await ChannelMembers.findOne({
            where: { channelId, userId: sessionUuid }
        });
        
        if (!isOwner && !isMember) {
            return res.status(403).json({ status: "error", message: "Not a member of this channel" });
        }
        
        // Get all member user IDs
        const members = await ChannelMembers.findAll({
            where: { channelId },
            attributes: ['userId']
        });
        
        const memberUserIds = [channel.owner, ...members.map(m => m.userId)];
        const uniqueUserIds = [...new Set(memberUserIds)];
        
        // Get all devices for all members
        const devices = await Client.findAll({
            where: {
                owner: uniqueUserIds
            },
            attributes: ['owner', 'device_id']
        });
        
        const result = devices.map(d => ({
            userId: d.owner,
            deviceId: d.device_id
        }));
        
        res.status(200).json(result);
    } catch (error) {
        console.error('Error fetching channel member devices:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// GET Signal Group Messages for a channel
clientRoutes.get("/channels/:channelId/messages", async (req, res) => {
    const { channelId } = req.params;
    const sessionDeviceId = req.session.deviceId;
    const sessionUuid = req.session.uuid;
    
    if (!sessionDeviceId || !sessionUuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    
    try {
        // Verify channel exists and user is member
        const channel = await Channel.findByPk(channelId);
        if (!channel) {
            return res.status(404).json({ status: "error", message: "Channel not found" });
        }
        
        // Check if user is owner or member
        const isOwner = channel.owner === sessionUuid;
        const isMember = await ChannelMembers.findOne({
            where: { channelId, userId: sessionUuid }
        });
        
        if (!isOwner && !isMember) {
            return res.status(403).json({ status: "error", message: "Not a member of this channel" });
        }
        
        // Get all messages for this channel and this device
        // Similar to direct messages, but filtered by channel
        const result = await Item.sequelize.query(`
            SELECT *
            FROM Items
            WHERE
            deviceReceiver = :sessionDeviceId
            AND receiver = :sessionUuid
            AND channel = :channelId
            ORDER BY rowid ASC
        `, {
            replacements: { sessionDeviceId, sessionUuid, channelId },
            model: Item,
            mapToModel: true
        });
        
        console.log(`[CLIENT.JS] Channel messages for device ${sessionDeviceId}, channel ${channelId}:`, result.length);
        res.status(200).json(result);
    } catch (error) {
        console.error('Error fetching channel messages:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// GET all channel messages for all channels the user is a member of
clientRoutes.get("/channels/messages/all", async (req, res) => {
    const sessionDeviceId = req.session.deviceId;
    const sessionUuid = req.session.uuid;
    
    if (!sessionDeviceId || !sessionUuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    
    try {
        // Get all channels where user is owner or member
        const ownedChannels = await Channel.findAll({
            where: { owner: sessionUuid, type: 'signal' },
            attributes: ['uuid']
        });
        
        const memberChannels = await ChannelMembers.findAll({
            where: { userId: sessionUuid },
            include: [{
                model: Channel,
                as: 'Channel',
                where: { type: 'signal' },
                attributes: ['uuid']
            }],
            attributes: ['channelId']
        });
        
        const channelIds = [
            ...ownedChannels.map(c => c.uuid),
            ...memberChannels.map(m => m.channelId)
        ];
        
        if (channelIds.length === 0) {
            return res.status(200).json([]);
        }
        
        // Get all messages for these channels for this device
        const result = await Item.sequelize.query(`
            SELECT *
            FROM Items
            WHERE
            deviceReceiver = :sessionDeviceId
            AND receiver = :sessionUuid
            AND channel IN (:channelIds)
            ORDER BY rowid ASC
        `, {
            replacements: { sessionDeviceId, sessionUuid, channelIds },
            model: Item,
            mapToModel: true
        });
        
        console.log(`[CLIENT.JS] All channel messages for device ${sessionDeviceId} across ${channelIds.length} channels:`, result.length);
        res.status(200).json(result);
    } catch (error) {
        console.error('Error fetching all channel messages:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// POST Signal Group Message (Sender Key encryption)
clientRoutes.post("/channels/:channelId/group-messages", async (req, res) => {
    const { channelId } = req.params;
    const { itemId, ciphertext, senderId, senderDeviceId, timestamp } = req.body;
    const sessionUuid = req.session.uuid;
    const sessionDeviceId = req.session.deviceId;
    
    if (!sessionUuid || !sessionDeviceId) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    
    try {
        // Verify channel exists
        const channel = await Channel.findByPk(channelId);
        if (!channel) {
            return res.status(404).json({ status: "error", message: "Channel not found" });
        }
        
        // Check if sender is owner or member
        const isOwner = channel.owner === sessionUuid;
        const isMember = await ChannelMembers.findOne({
            where: { channelId, userId: sessionUuid }
        });
        
        if (!isOwner && !isMember) {
            return res.status(403).json({ status: "error", message: "Not a member of this channel" });
        }
        
        // Get all channel members (owner + members)
        const members = await ChannelMembers.findAll({
            where: { channelId },
            attributes: ['userId']
        });
        
        const memberUserIds = new Set(members.map(m => m.userId));
        if (channel.owner) {
            memberUserIds.add(channel.owner);
        }
        
        // Get all devices for all members
        const Client = require('../db/model').Client;
        const memberDevices = await Client.findAll({
            where: { owner: Array.from(memberUserIds) }
        });
        
        // Create an Item for each device (they all share the same encrypted message)
        const items = [];
        for (const device of memberDevices) {
            // Skip sender's own device
            if (device.owner === senderId && device.device_id === senderDeviceId) {
                continue;
            }
            
            items.push({
                itemId,
                sender: senderId,
                receiver: device.owner,
                deviceSender: senderDeviceId,
                deviceReceiver: device.device_id,
                type: 'groupMessage',
                payload: ciphertext,
                cipherType: 4, // Sender Key Message type
                channel: channelId,
                timestamp: timestamp || new Date().toISOString()
            });
        }
        
        // Bulk create all items
        if (items.length > 0) {
            await Item.bulkCreate(items);
            console.log(`[CLIENT.JS] Created ${items.length} group message items for channel ${channelId}`);
        }
        
        // TODO: Emit WebSocket event to online members
        // req.app.get('io').to(channelId).emit('newGroupMessage', { itemId, channelId });
        
        res.status(200).json({ status: "success", itemsSent: items.length });
    } catch (error) {
        console.error('Error sending group message:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Batch store PreKeys via HTTP POST (for progressive initialization)
clientRoutes.post("/signal/prekeys/batch", async (req, res) => {
    const sessionUuid = req.session.uuid;
    const sessionDeviceId = req.session.deviceId;
    
    if (!sessionUuid || !sessionDeviceId) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    
    try {
        const { preKeys } = req.body;
        
        if (!Array.isArray(preKeys) || preKeys.length === 0) {
            return res.status(400).json({ 
                status: "error", 
                message: "Invalid request: preKeys must be a non-empty array" 
            });
        }
        
        // Validate preKeys format
        for (const pk of preKeys) {
            if (typeof pk.id !== 'number' || !pk.data) {
                return res.status(400).json({ 
                    status: "error", 
                    message: "Invalid preKey format: each preKey must have 'id' (number) and 'data' (string)" 
                });
            }
        }
        
        // Find client record
        const client = await Client.findOne({
            where: { owner: sessionUuid, device_id: sessionDeviceId }
        });
        
        if (!client) {
            return res.status(404).json({ 
                status: "error", 
                message: "Client device not found" 
            });
        }
        
        // Prepare batch insert data
        const preKeyRecords = preKeys.map(pk => ({
            owner: sessionUuid,
            client: client.clientid,
            prekey_id: pk.id,
            prekey_data: pk.data  // Note: field name is prekey_data in the model
        }));
        
        // Batch insert with write queue - with timeout to prevent HTTP timeout
        const WRITE_TIMEOUT_MS = 5000; // 5 second timeout for HTTP response
        
        const writePromise = writeQueue.enqueue(
            () => SignalPreKey.bulkCreate(preKeyRecords, {
                updateOnDuplicate: ['prekey_data', 'updatedAt'] // Update prekey_data and timestamp if prekey_id already exists
            }),
            `storePreKeysBatch-${preKeys.length}`
        );
        
        const timeoutPromise = new Promise((resolve) => {
            setTimeout(() => resolve({ timeout: true }), WRITE_TIMEOUT_MS);
        });
        
        // Race between write completion and timeout
        const result = await Promise.race([writePromise, timeoutPromise]);
        
        if (result && result.timeout) {
            // Write is queued but not completed within timeout
            console.log(`[SIGNAL PREKEYS BATCH] User ${sessionUuid} device ${sessionDeviceId} - write queued (${preKeys.length} PreKeys)`);
            
            // Let the write continue in background (don't await)
            writePromise.then(() => {
                console.log(`[SIGNAL PREKEYS BATCH] ✓ Background write completed: ${preKeys.length} PreKeys for ${sessionUuid}`);
            }).catch(err => {
                console.error(`[SIGNAL PREKEYS BATCH] ✗ Background write failed for ${sessionUuid}:`, err);
            });
            
            res.status(202).json({ 
                status: "accepted", 
                stored: preKeys.length,
                message: `${preKeys.length} PreKeys queued for processing`
            });
        } else {
            // Write completed quickly
            console.log(`[SIGNAL PREKEYS BATCH] User ${sessionUuid} device ${sessionDeviceId} stored ${preKeys.length} PreKeys`);
            
            res.status(200).json({ 
                status: "success", 
                stored: preKeys.length,
                message: `${preKeys.length} PreKeys stored successfully`
            });
        }
    } catch (error) {
        console.error('[SIGNAL PREKEYS BATCH] Error storing PreKeys:', error);
        res.status(500).json({ 
            status: "error", 
            message: "Internal server error" 
        });
    }
});

clientRoutes.get("/signal/prekey_bundle/:userId", async (req, res) => {
    const { userId } = req.params;
    const sessionUuid = req.session.uuid;
    try {
        // Helper to get random element
        function getRandom(arr) {
            if (!arr || arr.length === 0) return null;
            return arr[Math.floor(Math.random() * arr.length)];
        }

        // Hole alle Geräte des Ziel-Users (userId) und des eingeloggten Users (sessionUuid)
        const owners = [userId];
        if (sessionUuid && sessionUuid !== userId) {
            owners.push(sessionUuid);
        }

        const clients = await Client.findAll({
            where: { owner: owners },
            attributes: ['clientid', 'owner', 'device_id', 'public_key', 'registration_id'],
            include: [
                {
                    model: SignalSignedPreKey,
                    as: 'SignalSignedPreKeys',
                    required: false,
                    separate: true,
                    order: [['createdAt', 'DESC']]
                },
                {
                    model: SignalPreKey,
                    as: 'SignalPreKeys',
                    required: false
                }
            ]
        });

        // Für jedes Gerät: gib ein random PreKey und NUR den letzten (neuesten) SignedPreKey aus
        const result = clients.map(client => ({
            clientid: client.clientid,
            userId: client.owner,
            device_id: client.device_id,
            public_key: client.public_key,
            registration_id: client.registration_id,
            signedPreKey: (client.SignalSignedPreKeys && client.SignalSignedPreKeys.length > 0)
                ? client.SignalSignedPreKeys[0] // nur der neueste (wegen order DESC)
                : null,
            preKey: getRandom(client.SignalPreKeys)
        }));

        // PreKey nach Ausgabe löschen (wie bisher)
        for (const client of clients) {
            const preKeyObj = getRandom(client.SignalPreKeys);
            if (preKeyObj) {
                await writeQueue.enqueue(
                    () => SignalPreKey.destroy({ where: { owner: client.owner, client: client.clientid, prekey_id: preKeyObj.prekey_id } }),
                    'destroyUsedPreKey'
                );
            }
        }
        res.status(200).json(result);
    } catch (error) {
        console.error('Error fetching signed pre-key:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

clientRoutes.get("/people/list", async (req, res) => {
    if(req.session.authenticated !== true || !req.session.uuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    try {
        const users = await User.findAll({
            attributes: ['uuid', 'displayName', 'picture'],
            where: { uuid: { [Op.ne]: req.session.uuid } } // Exclude the current user
        });
        res.status(200).json(users);
    } catch (error) {
        console.error('Error fetching users:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Batch load profiles by UUIDs (GET endpoint for smart loading)
clientRoutes.get("/people/profiles", async (req, res) => {
    if(req.session.authenticated !== true || !req.session.uuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    try {
        const uuidsParam = req.query.uuids;
        if (!uuidsParam) {
            return res.status(200).json({ profiles: [] });
        }
        
        const uuids = uuidsParam.split(',').map(uuid => uuid.trim()).filter(Boolean);
        if (uuids.length === 0) {
            return res.status(200).json({ profiles: [] });
        }
        
        const users = await User.findAll({
            attributes: ['uuid', 'displayName', 'picture', 'atName'],
            where: { uuid: uuids }
        });
        
        // Convert picture BLOB to base64 string
        const profiles = users.map(user => {
            const userData = user.toJSON();
            if (userData.picture && Buffer.isBuffer(userData.picture)) {
                userData.picture = `data:image/png;base64,${userData.picture.toString('base64')}`;
            }
            return userData;
        });
        
        res.status(200).json({ profiles });
    } catch (error) {
        console.error('Error fetching user profiles:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

clientRoutes.post("/client/people/info", async (req, res) => {
    if(req.session.authenticated !== true || !req.session.uuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    try {
        const { userIds } = req.body;
        if (!Array.isArray(userIds) || userIds.length === 0) {
            return res.status(400).json({ status: "error", message: "userIds must be a non-empty array" });
        }
        const users = await User.findAll({
            attributes: ['uuid', 'displayName', 'picture', 'atName'],
            where: { uuid: userIds } // Include only the specified user IDs
        });
        
        // Convert picture BLOB to base64 string
        const usersData = users.map(user => {
            const userData = user.toJSON();
            if (userData.picture && Buffer.isBuffer(userData.picture)) {
                userData.picture = `data:image/png;base64,${userData.picture.toString('base64')}`;
            }
            return userData;
        });
        
        res.status(200).json(usersData);
    } catch (error) {
        console.error('Error fetching users:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

clientRoutes.post("/client/channels/info", async (req, res) => {
    if(req.session.authenticated !== true || !req.session.uuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }

    try {
        const { channelIds } = req.body;
        if (!Array.isArray(channelIds) || channelIds.length === 0) {
            return res.status(400).json({ status: "error", message: "channelIds must be a non-empty array" });
        }

        const channels = await Channel.findAll({
            where: { uuid: channelIds },
            attributes: ['uuid', 'name', 'description', 'owner', 'private', 'type']
        });

        res.status(200).json({ status: "success", channels });
    } catch (error) {
        console.error('Error fetching channel info:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

clientRoutes.get("/client/channels", async(req, res) => {
    const limit = parseInt(req.query.limit) || 20;
    const typeFilter = req.query.type; // 'webrtc', 'signal', or undefined for all
    
    if(req.session.authenticated !== true || !req.session.uuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    
    try {
        const userUuid = req.session.uuid;
        const { ChannelMembers } = require('../db/model');
        
        // Build where clause for type filter
        const whereClause = { owner: userUuid };
        if (typeFilter && ['webrtc', 'signal'].includes(typeFilter)) {
            whereClause.type = typeFilter;
        }
        
        // Find channels where user is owner
        const ownedChannels = await Channel.findAll({
            where: whereClause,
            order: [['updatedAt', 'DESC']]
        });
        
        // Find channels where user is member
        const memberChannelIds = await ChannelMembers.findAll({
            where: { userId: userUuid },
            attributes: ['channelId']
        });
        
        const memberChannelUuids = memberChannelIds.map(cm => cm.channelId);
        
        let memberChannels = [];
        if (memberChannelUuids.length > 0) {
            const memberWhereClause = {
                uuid: { [Op.in]: memberChannelUuids },
                owner: { [Op.ne]: userUuid } // Exclude owned channels to avoid duplicates
            };
            if (typeFilter && ['webrtc', 'signal'].includes(typeFilter)) {
                memberWhereClause.type = typeFilter;
            }
            
            memberChannels = await Channel.findAll({
                where: memberWhereClause,
                order: [['updatedAt', 'DESC']]
            });
        }
        
        // Combine and sort all channels
        // TODO: Sort by latest message timestamp when Signal group messages are fully implemented
        const allChannels = [...ownedChannels, ...memberChannels]
            .sort((a, b) => new Date(b.updatedAt) - new Date(a.updatedAt))
            .slice(0, limit);
        
        res.status(200).json({ status: "success", channels: allChannels });
    } catch (error) {
        console.error('Error fetching channels:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

clientRoutes.post("/client/channels", async(req, res) => {
    const { name, description, private, type, defaultRoleId } = req.body;
    if(req.session.authenticated !== true || !req.session.uuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    
    // Check if user has channel.create permission
    const hasPermission = await hasServerPermission(req.session.uuid, 'channel.create');
    if (!hasPermission) {
        return res.status(403).json({ status: "error", message: "Insufficient permissions to create channels" });
    }
    
    try {
        // Validate channel type
        const channelType = type || 'webrtc';
        if (!['webrtc', 'signal'].includes(channelType)) {
            return res.status(400).json({ status: "error", message: "Invalid channel type. Must be 'webrtc' or 'signal'" });
        }
        
        // Validate default role if provided
        if (defaultRoleId) {
            const role = await Role.findOne({ where: { uuid: defaultRoleId } });
            if (!role) {
                return res.status(400).json({ status: "error", message: "Invalid default role ID" });
            }
            
            // Verify role scope matches channel type
            const expectedScope = channelType === 'webrtc' ? 'channelWebRtc' : 'channelSignal';
            if (role.scope !== expectedScope) {
                return res.status(400).json({ 
                    status: "error", 
                    message: `Role scope '${role.scope}' does not match channel type '${channelType}'` 
                });
            }
        }
        
        const user = await User.findOne({ where: { uuid: req.session.uuid } });
        if (user) {
            const channel = await writeQueue.enqueue(
                () => Channel.create({ 
                    name: name, 
                    description: description, 
                    private: private || false, 
                    type: channelType,
                    owner: req.session.uuid,
                    defaultRoleId: defaultRoleId || null
                }),
                'createChannelByClient'
            );
            
            // Add the creator as owner with appropriate role
            // The creator gets owner-level permissions, not just the default role
            await channel.addMember(user, { through: { permission: 'owner' } });
            
            res.status(201).json(channel);
        } else {
            res.status(404).json({ status: "error", message: "User not found" });
        }
    } catch (error) {
        console.error('Error creating channel:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// POST /client/channels/:channelId/join - Join a public channel
clientRoutes.post("/client/channels/:channelId/join", async(req, res) => {
    const { channelId } = req.params;
    
    if(req.session.authenticated !== true || !req.session.uuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    
    try {
        const userId = req.session.uuid;
        const { ChannelMembers, UserRoleChannel, Role } = require('../db/model');
        
        // Find the channel
        const channel = await Channel.findOne({ where: { uuid: channelId } });
        if (!channel) {
            return res.status(404).json({ status: "error", message: "Channel not found" });
        }
        
        // Verify channel is public
        if (channel.private) {
            return res.status(403).json({ status: "error", message: "Cannot join private channel" });
        }
        
        // Check if user is already a member
        const existingMember = await ChannelMembers.findOne({
            where: { userId, channelId }
        });
        
        if (existingMember) {
            return res.status(400).json({ status: "error", message: "Already a member of this channel" });
        }
        
        // Check if user is the owner
        if (channel.owner === userId) {
            return res.status(400).json({ status: "error", message: "You are the owner of this channel" });
        }
        
        // Add user to channel
        await ChannelMembers.create({
            userId,
            channelId,
            permission: 'member'
        });
        
        // Assign default role if channel has one
        if (channel.defaultRoleId) {
            await UserRoleChannel.create({
                userId,
                roleId: channel.defaultRoleId,
                channelId
            });
        }
        
        res.status(200).json({ 
            status: "success", 
            message: "Successfully joined channel",
            channel: channel
        });
    } catch (error) {
        console.error('Error joining channel:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Get discoverable channels (public channels user isn't part of)
clientRoutes.get("/client/channels/discover", async(req, res) => {
    const limit = parseInt(req.query.limit) || 10;
    const offset = parseInt(req.query.offset) || 0;
    
    if(req.session.authenticated !== true || !req.session.uuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    
    try {
        const userUuid = req.session.uuid;
        const { ChannelMembers } = require('../db/model');
        
        // Find channels where user is owner
        const ownedChannelIds = await Channel.findAll({
            where: { owner: userUuid },
            attributes: ['uuid']
        });
        
        // Find channels where user is member
        const memberChannelIds = await ChannelMembers.findAll({
            where: { userId: userUuid },
            attributes: ['channelId']
        });
        
        // Combine owned and member channel IDs to exclude
        const excludeChannelUuids = [
            ...ownedChannelIds.map(c => c.uuid),
            ...memberChannelIds.map(cm => cm.channelId)
        ];
        
        // Find public channels user isn't part of
        const discoverChannels = await Channel.findAll({
            where: {
                private: false,
                uuid: { [Op.notIn]: excludeChannelUuids.length > 0 ? excludeChannelUuids : [''] }
            },
            order: [['createdAt', 'DESC']],
            limit: limit,
            offset: offset
        });
        
        // Count total discoverable channels
        const totalCount = await Channel.count({
            where: {
                private: false,
                uuid: { [Op.notIn]: excludeChannelUuids.length > 0 ? excludeChannelUuids : [''] }
            }
        });
        
        res.status(200).json({ 
            status: "success", 
            channels: discoverChannels,
            total: totalCount,
            hasMore: offset + discoverChannels.length < totalCount
        });
    } catch (error) {
        console.error('Error fetching discover channels:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Get channel participants (current LiveKit room participants)
clientRoutes.get("/client/channels/:channelUuid/participants", async(req, res) => {
    const { channelUuid } = req.params;
    
    if(req.session.authenticated !== true || !req.session.uuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    
    try {
        const userUuid = req.session.uuid;
        const { ChannelMembers } = require('../db/model');
        
        // Find the channel
        const channel = await Channel.findOne({ where: { uuid: channelUuid } });
        if (!channel) {
            return res.status(404).json({ status: "error", message: "Channel not found" });
        }
        
        // Check if user is owner or member of this channel
        const isOwner = channel.owner === userUuid;
        const isMember = await ChannelMembers.findOne({
            where: { 
                channelId: channelUuid,
                userId: userUuid
            }
        });
        
        if (!isOwner && !isMember) {
            return res.status(403).json({ status: "error", message: "Access denied. You are not a member of this channel." });
        }
        
        // Get LiveKit configuration
        const apiKey = process.env.LIVEKIT_API_KEY || 'devkey';
        const apiSecret = process.env.LIVEKIT_API_SECRET || 'secret';
        const livekitUrl = process.env.LIVEKIT_URL || 'ws://localhost:7880';
        
        // Initialize LiveKit RoomServiceClient
        const roomService = new RoomServiceClient(livekitUrl, apiKey, apiSecret);
        
        // Get current participants from LiveKit room
        const roomName = `channel-${channelUuid}`;
        let livekitParticipants = [];
        
        try {
            livekitParticipants = await roomService.listParticipants(roomName);
        } catch (error) {
            // Room might not exist or have no participants
            console.log(`No active LiveKit room for channel ${channelUuid}:`, error.message);
        }
        
        // Enrich participant data with user information from database
        const participants = await Promise.all(livekitParticipants.map(async (participant) => {
            let metadata = {};
            try {
                metadata = participant.metadata ? JSON.parse(participant.metadata) : {};
            } catch (e) {
                console.error('Failed to parse participant metadata:', e);
            }
            
            const userId = participant.identity;
            
            // Fetch user details from database
            const user = await User.findOne({
                where: { uuid: userId },
                attributes: ['uuid', 'displayName', 'email', 'picture']
            });
            
            // Convert BigInt to Number for JSON serialization
            const joinedAtTimestamp = participant.joinedAt 
                ? Number(participant.joinedAt) 
                : null;
            
            return {
                uuid: userId,
                displayName: user?.displayName || participant.name || metadata.username || 'Unknown',
                email: user?.email || '',
                picture: user?.picture || '',
                permission: userId === channel.owner ? 'owner' : 'member',
                isOwner: userId === channel.owner,
                // LiveKit specific data (BigInt values converted to Number)
                connectionState: participant.state,
                joinedAt: joinedAtTimestamp,
                tracks: {
                    audio: participant.tracks.some(t => t.type === 'AUDIO'),
                    video: participant.tracks.some(t => t.type === 'VIDEO'),
                    screen: participant.tracks.some(t => t.source === 'SCREEN_SHARE')
                }
            };
        }));
        
        res.status(200).json({ 
            status: "success", 
            participants: participants,
            totalCount: participants.length,
            roomName: roomName
        });
    } catch (error) {
        console.error('Error fetching channel participants:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

/*clientRoutes.get("/login", (req, res) => {
    // Redirect the login, preserving query parameters if present
    let redirectUrl = config.app.url + "/login";
    const query = req.url.split('?')[1];
    if (query) {
        redirectUrl += '?' + query;
    }
    res.redirect(redirectUrl);
});*/

clientRoutes.post("/magic/verify", async (req, res) => {
    const { key, clientid } = req.body;
    console.log("Verifying magic link with key:", key, "and client ID:", clientid);
    if(!key || !clientid) {
        return res.status(400).json({ status: "failed", message: "Missing key or client ID" });
    }
    const entry = magicLinks[key];
    if (entry && entry.expires > Date.now()) {
        // Valid magic link
        req.session.authenticated = true;
        req.session.email = entry.email;
        req.session.uuid = entry.uuid;
        const userAgent = req.headers['user-agent'] || '';
        const ip = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
        const location = await getLocationFromIp(ip);
        const locationString = location
                ? `${location.city}, ${location.region}, ${location.country} (${location.org})`
                : "Location not found";
        const maxDevice = await Client.max('device_id', { where: { owner: entry.uuid } });
        const [client] = await writeQueue.enqueue(
            () => Client.findOrCreate({
                where: { owner: entry.uuid, clientid: clientid },
                defaults: { owner: entry.uuid, clientid: clientid, ip: ip, browser: userAgent, location: locationString, device_id: maxDevice ? maxDevice + 1 : 1 }
            }),
            'clientFindOrCreateMagicLink'
        );
        req.session.clientId = client.clientid;
        req.session.deviceId = client.device_id;
        
        // Set user as active on magic link verification
        await writeQueue.enqueue(
            () => User.update(
                { active: true },
                { where: { uuid: entry.uuid } }
            ),
            'setUserActiveOnMagicLink'
        );
        
        // Auto-assign admin role if user is verified and email is in config.admin
        const user = await User.findOne({ where: { uuid: entry.uuid } });
        if (user && user.verified && config.admin && config.admin.includes(entry.email)) {
            await autoAssignRoles(entry.email, entry.uuid);
        }
        
        // Persist session immediately so Socket.IO can read it
        return req.session.save(err => {
            if (err) {
                console.error('Session save error (magic/verify):', err);
                return res.status(500).json({ status: "error", message: "Session save error" });
            }
            res.status(200).json({ status: "ok", message: "Magic link verified" });
        });
    } else {
        // Invalid or expired magic link
        res.status(400).json({ status: "failed", message: "Invalid or expired magic link" });
    }
});

clientRoutes.post("/client/login", async (req, res) => {
    const { clientid, email } = req.body;
    try {
        const owner = await User.findOne({ where: { email: email } });
        if (!owner) {
            return res.status(401).json({ status: "failed", message: "Invalid email" });
        }
        const client = await Client.findOne({ where: { clientid: clientid, owner: owner.uuid } });
        if (client) {
            req.session.authenticated = true;
            req.session.email = owner.email;
            req.session.uuid = client.owner;
            req.session.clientId = client.clientid;
            req.session.deviceId = client.device_id;
            
            // Set user as active on client login
            await writeQueue.enqueue(
                () => User.update(
                    { active: true },
                    { where: { uuid: owner.uuid } }
                ),
                'setUserActiveOnClientLogin'
            );
            
            // Auto-assign admin role if user is verified and email is in config.admin
            if (owner.verified && config.admin && config.admin.includes(owner.email)) {
                await autoAssignRoles(owner.email, owner.uuid);
            }
            
            return req.session.save(err => {
                if (err) {
                    console.error('Session save error (client/login):', err);
                    return res.status(500).json({ status: "error", message: "Session save error" });
                }
                res.status(200).json({ status: "ok", message: "Client login successful" });
            });
        } else {
            res.status(401).json({ status: "failed", message: "Invalid client ID or not authorized" });
        }
    } catch (error) {
        console.error('Error during client login:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

clientRoutes.get("/channels", async (req, res) => {
    try {
        let threads = [];
        if (req.session.authenticated && req.session.email && req.session.uuid) {
            const channels = await Channel.findAll({
                attributes: ['name', 'type'],
                where: {
                    [Op.or]: [
                        { owner: req.session.uuid },
                        { members: { [Op.like]: `%${req.session.uuid}%` } }
                    ]
                }
            });

            for (const channel of channels) {
                const channelThreads = await Thread.findAll({
                    attributes: ['id', 'parent', 'message', 'sender', 'channel', 'createdAt'],
                    where: { channel: channel.name },
                    order: [['createdAt', 'DESC']],
                    limit: 5,
                    include: [
                        {
                            model: User,
                            as: 'user',
                            attributes: ['uuid', 'displayName', 'picture'],
                            where: { uuid: Sequelize.col('Thread.sender') }
                        }
                    ]
                });

                channelThreads.sort((a, b) => a.createdAt - b.createdAt);

                threads = threads.concat(channelThreads);

            }
            for (let thread of threads) {
                if (thread.dataValues.user.picture) {
                    const bufferData = JSON.parse(thread.dataValues.user.picture);
                    thread.dataValues.user.pictureBase64 = Buffer.from(bufferData.data).toString('base64');
                }
            }

            const user = await User.findOne({ where: { email: req.session.email } });
            if (user.dataValues.picture) {
                const bufferData = JSON.parse(user.dataValues.picture);
                user.dataValues.pictureBase64 = Buffer.from(bufferData.data).toString('base64');
            }
            console.log('Channels:', channels);
            console.log(`Threads:`, threads.user);
            console.log('User Data:', user.dataValues);
            res.render("channels", { channels: channels, threads: threads, user: user });
        } else {
            //res.redirect("/login");
        }
    } catch (error) {
        console.error('Error retrieving channels:', error);
        //res.redirect("/error");
    }
});

clientRoutes.post("/channels/create", async (req, res) => {
    try {
        if (req.session.authenticated && req.session.email && req.session.uuid) {
            let booleanIsPrivate = false;
            const { name, description, isPrivate, type } = req.body;
            if (isPrivate === "on") booleanIsPrivate = true;
            const owner = req.session.uuid;
            const channel = await writeQueue.enqueue(
                () => Channel.create({ name, description, private: booleanIsPrivate, owner, type }),
                'createChannelFromClient'
            );
            res.json(channel);
        } else {
            res.status(401).json({ message: "Unauthorized" });
        }
    } catch (error) {
        console.error('Error creating channel:', error);
        res.status(400).json({ message: "Error creating channel" });
    }
});

clientRoutes.get("/thread/:id", async (req, res) => {
    try {
        if (req.session.authenticated && req.session.email && req.session.uuid) {


            const thread = await Thread.findOne({
                attributes: ['id', 'parent', 'message', 'sender', 'channel', 'createdAt'],
                where: { id: req.params.id },
                include: [
                    {
                        model: User,
                        as: 'user',
                        attributes: ['uuid', 'displayName', 'picture'],
                        where: { uuid: Sequelize.col('Thread.sender') }
                    }
                ]
            });

            if (!thread) {
                res.status(404).json({ message: "Thread not found" });
            } else {
                const channel = await Channel.findOne({
                    attributes: ['name', 'type'],
                    where: { name: thread.channel, [Op.or]: [{ owner: req.session.uuid }, { members: { [Op.like]: `%${req.session.uuid}%` } }] }
                });
                if (!channel) {
                    res.status(401).json({ message: "Unauthorized" });
                    return;
                }
                if (thread.dataValues.user.picture) {
                    const bufferData = JSON.parse(thread.dataValues.user.picture);
                    thread.dataValues.user.pictureBase64 = Buffer.from(bufferData.data).toString('base64');
                }


                console.log(`Thread ${thread.id}:`, thread);
                res.json(thread);
            }
        } else {
            //res.redirect("/login");
        }
    } catch (error) {
        console.error('Error retrieving thread:', error);
        //res.redirect("/error");
    }
});

clientRoutes.get("/channel/:name", async (req, res) => {
    try {
        if (req.session.authenticated && req.session.email && req.session.uuid) {
            const channels = await Channel.findAll({
                attributes: ['name', 'type'],
                where: {
                    [Op.or]: [
                        { owner: req.session.uuid },
                        { members: { [Op.like]: `%${req.session.uuid}%` } }
                    ]
                }
            });

            const channel = await Channel.findOne({
                attributes: ['name', 'description', 'private', 'owner', 'members', 'type'],
                where: { name: req.params.name }
            });

            if (!channel) {
                res.status(404).json({ message: "Channel not found" });
            } else {
                const threads = await Thread.findAll({
                    attributes: ['id', 'parent', 'message', 'sender', 'channel', 'createdAt', [sequelize.literal('(SELECT COUNT(*) FROM Threads AS ChildThreads WHERE ChildThreads.parent = Thread.id)'), 'childCount']],
                    where: { channel: channel.name },
                    order: [['createdAt', 'ASC']],
                    include: [
                        {
                            model: User,
                            as: 'user',
                            attributes: ['uuid', 'displayName', 'picture'],
                            where: { uuid: Sequelize.col('Thread.sender') }
                        }
                    ]
                });

                for (let thread of threads) {
                    if (thread.dataValues.user.picture) {
                        const bufferData = JSON.parse(thread.dataValues.user.picture);
                        thread.dataValues.user.pictureBase64 = Buffer.from(bufferData.data).toString('base64');
                    }
                }

            const user = await User.findOne({ where: { email: req.session.email } });
            if (user.dataValues.picture) {
                const bufferData = JSON.parse(user.dataValues.picture);
                user.dataValues.pictureBase64 = Buffer.from(bufferData.data).toString('base64');
            }

                console.log(`Threads for channel ${channel.name}:`, threads);
                res.render("channel", { channel: channel, threads: threads, channels: channels, user: user });
            }
        } else {
            //res.redirect("/login");
        }
    } catch (error) {
        console.error('Error retrieving channel:', error);
        //res.redirect("/error");
    }
});

clientRoutes.post("/channel/:name/post", async (req, res) => {
    try {
        if (req.session.authenticated && req.session.email && req.session.uuid) {
            const { message } = req.body;
            const sender = req.session.uuid;
            const channel = req.params.name;
            const thread = await writeQueue.enqueue(
                () => Thread.create({ message, sender, channel }),
                'createThreadByClient'
            );
            res.json(thread);
        } else {
            res.status(401).json({ message: "Unauthorized" });
        }
    } catch (error) {
        console.error('Error creating thread:', error);
        res.status(400).json({ message: "Error creating thread" });
    }
});

clientRoutes.post("/usersettings", async (req, res) => {
    try {
        if (req.session.authenticated && req.session.email && req.session.uuid) {
            const { displayname, picture } = req.body;
            const user = await User.findOne({ where: { email: req.session.email } });
            user.displayName = displayname;
            if (picture) {
                const buffer = Buffer.from(picture.split(',')[1], 'base64');
                user.picture = JSON.stringify({ type: "Buffer", data: Array.from(buffer) });
            }
            await writeQueue.enqueue(
                () => user.save(),
                'updateUserSettingsByClient'
            );
            res.json({message: "User settings updated"});
        }
    } catch (error) {
        console.error('Error updating user settings:', error);
        res.json({ message: "Error updating user settings" });
    }
});

// Delete item (cleanup after read receipt)
clientRoutes.delete("/items/:itemId", async (req, res) => {
    try {
        if (!req.session.authenticated || !req.session.uuid) {
            return res.status(401).json({ status: "failed", message: "Not authenticated" });
        }
        
        const { itemId } = req.params;
        const receiverDeviceId = req.query.deviceId ? parseInt(req.query.deviceId) : null;
        const receiverUserId = req.query.receiverId || null; // The user who read the message
        
        // Only allow deletion if user is sender or receiver
        const items = await Item.findAll({ 
            where: { 
                itemId: itemId,
                [Op.or]: [
                    { sender: req.session.uuid },
                    { receiver: req.session.uuid }
                ]
            } 
        });
        
        if (!items || items.length === 0) {
            return res.status(404).json({ status: "failed", message: "Item not found or not authorized" });
        }
        
        // If deviceId AND receiverId are provided, delete only that specific encrypted version
        // This ensures we don't accidentally delete the wrong device's message
        if (receiverDeviceId !== null && receiverUserId !== null) {
            await writeQueue.enqueue(
                () => Item.destroy({ 
                    where: { 
                        itemId: itemId,
                        receiver: receiverUserId,
                        deviceReceiver: receiverDeviceId
                    } 
                }),
                'deleteItemForSpecificDevice'
            );
            console.log(`[CLEANUP] Item ${itemId} for user ${receiverUserId} device ${receiverDeviceId} deleted by ${req.session.uuid}`);
        } else if (receiverDeviceId !== null) {
            // Legacy: only deviceId provided (might delete wrong user's message!)
            await writeQueue.enqueue(
                () => Item.destroy({ 
                    where: { 
                        itemId: itemId,
                        deviceReceiver: receiverDeviceId
                    } 
                }),
                'deleteItemForDevice'
            );
            console.log(`[CLEANUP] Item ${itemId} for device ${receiverDeviceId} deleted by user ${req.session.uuid}`);
        } else {
            // Delete all items with this itemId (all device versions)
            await writeQueue.enqueue(
                () => Item.destroy({ where: { itemId: itemId } }),
                'deleteItemAllDevices'
            );
            console.log(`[CLEANUP] Item ${itemId} (all devices) deleted by user ${req.session.uuid}`);
        }
        
        res.status(200).json({ status: "ok", message: "Item deleted successfully" });
    } catch (error) {
        console.error('Error deleting item:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Profile setup endpoint for initial registration - with increased body limit for images
clientRoutes.post("/client/profile/setup", 
    bodyParser.json({ limit: '2mb' }), // Allow up to 2MB for base64 encoded images
    async (req, res) => {
    try {
        const { displayName, picture } = req.body;
        const userUuid = req.session.uuid;

        if (!userUuid) {
            return res.status(401).json({ status: "error", message: "Not authenticated" });
        }

        if (!displayName || displayName.trim() === '') {
            return res.status(400).json({ status: "error", message: "Display name is required" });
        }

        const user = await User.findOne({ where: { uuid: userUuid } });
        if (!user) {
            return res.status(404).json({ status: "error", message: "User not found" });
        }

        // Check if displayName is already taken by another user
        if (displayName !== user.displayName) {
            const existingUser = await User.findOne({ 
                where: { 
                    displayName: displayName.trim(),
                    uuid: { [Op.ne]: userUuid }
                } 
            });
            if (existingUser) {
                return res.status(409).json({ 
                    status: "error", 
                    message: "Display name already taken" 
                });
            }
        }

        // Update user profile
        const updateData = {
            displayName: displayName.trim()
        };

        // Handle picture if provided (base64 data URL)
        if (picture && picture.startsWith('data:image')) {
            try {
                const base64Data = picture.split(',')[1];
                const buffer = Buffer.from(base64Data, 'base64');
                
                // Limit picture size to 1MB
                if (buffer.length > 1 * 1024 * 1024) {
                    return res.status(413).json({ 
                        status: "error", 
                        message: "Picture size too large (max 1MB)" 
                    });
                }
                
                updateData.picture = buffer;
            } catch (error) {
                console.error('Error processing picture:', error);
                return res.status(400).json({ 
                    status: "error", 
                    message: "Invalid picture format" 
                });
            }
        }

        await user.update(updateData);

        console.log(`[PROFILE SETUP] User ${userUuid} completed profile setup with displayName: ${displayName}`);

        // Clear the registration session - user must log in properly after registration
        req.session.destroy((err) => {
            if (err) {
                console.error('[PROFILE SETUP] Error destroying session:', err);
            } else {
                console.log('[PROFILE SETUP] Registration session cleared - user must log in');
            }
        });

        res.status(200).json({ 
            status: "ok", 
            message: "Profile setup complete. Please log in to continue.",
            user: {
                uuid: user.uuid,
                email: user.email,
                displayName: user.displayName
            }
        });
    } catch (error) {
        console.error('Error setting up profile:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Get current user profile
clientRoutes.get("/client/profile", async (req, res) => {
    try {
        const userUuid = req.session.uuid;

        if (!userUuid) {
            return res.status(401).json({ status: "error", message: "Not authenticated" });
        }

        const user = await User.findOne({ where: { uuid: userUuid } });
        if (!user) {
            return res.status(404).json({ status: "error", message: "User not found" });
        }

        // Convert picture buffer to base64 if exists
        let pictureBase64 = null;
        if (user.picture) {
            pictureBase64 = `data:image/png;base64,${user.picture.toString('base64')}`;
        }

        res.status(200).json({
            uuid: user.uuid,
            email: user.email,
            displayName: user.displayName,
            atName: user.atName,
            picture: pictureBase64
        });
    } catch (error) {
        console.error('Error getting profile:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Update user profile
clientRoutes.post("/client/profile/update",
    bodyParser.json({ limit: '2mb' }),
    async (req, res) => {
    try {
        const { displayName, atName, picture } = req.body;
        const userUuid = req.session.uuid;

        if (!userUuid) {
            return res.status(401).json({ status: "error", message: "Not authenticated" });
        }

        const user = await User.findOne({ where: { uuid: userUuid } });
        if (!user) {
            return res.status(404).json({ status: "error", message: "User not found" });
        }

        const updateData = {};

        // Validate and update displayName
        if (displayName !== undefined) {
            if (!displayName || displayName.trim() === '') {
                return res.status(400).json({ status: "error", message: "Display name cannot be empty" });
            }

            // Check if displayName is already taken by another user
            if (displayName.trim() !== user.displayName) {
                const existingUser = await User.findOne({
                    where: {
                        displayName: displayName.trim(),
                        uuid: { [Op.ne]: userUuid }
                    }
                });
                if (existingUser) {
                    return res.status(409).json({
                        status: "error",
                        message: "Display name already taken"
                    });
                }
            }

            updateData.displayName = displayName.trim();
        }

        // Validate and update atName
        if (atName !== undefined && atName !== null && atName.trim() !== '') {
            const trimmedAtName = atName.trim();

            // Check if atName is already taken by another user
            if (trimmedAtName !== user.atName) {
                const existingUser = await User.findOne({
                    where: {
                        atName: trimmedAtName,
                        uuid: { [Op.ne]: userUuid }
                    }
                });
                if (existingUser) {
                    return res.status(409).json({
                        status: "error",
                        message: "@name already taken"
                    });
                }
            }

            updateData.atName = trimmedAtName;
        }

        // Handle picture update
        if (picture && picture.startsWith('data:image')) {
            try {
                const base64Data = picture.split(',')[1];
                const buffer = Buffer.from(base64Data, 'base64');

                // Limit picture size to 1MB
                if (buffer.length > 1 * 1024 * 1024) {
                    return res.status(413).json({
                        status: "error",
                        message: "Picture size too large (max 1MB)"
                    });
                }

                updateData.picture = buffer;
            } catch (error) {
                console.error('Error processing picture:', error);
                return res.status(400).json({
                    status: "error",
                    message: "Invalid picture format"
                });
            }
        }

        // Apply updates if any
        if (Object.keys(updateData).length > 0) {
            await user.update(updateData);
            console.log(`[PROFILE UPDATE] User ${userUuid} updated profile:`, Object.keys(updateData));
        }

        res.status(200).json({
            status: "ok",
            message: "Profile updated successfully"
        });
    } catch (error) {
        console.error('Error updating profile:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Check if @name is available
clientRoutes.get("/client/profile/check-atname", async (req, res) => {
    try {
        const { atName } = req.query;
        const userUuid = req.session.uuid;

        if (!userUuid) {
            return res.status(401).json({ status: "error", message: "Not authenticated" });
        }

        if (!atName || atName.trim() === '') {
            return res.status(400).json({ status: "error", message: "@name is required" });
        }

        const trimmedAtName = atName.trim();

        // Check if atName is taken by another user (excluding current user)
        const existingUser = await User.findOne({
            where: {
                atName: trimmedAtName,
                uuid: { [Op.ne]: userUuid }
            }
        });

        res.status(200).json({
            available: !existingUser,
            atName: trimmedAtName
        });
    } catch (error) {
        console.error('Error checking @name availability:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Delete user account
clientRoutes.delete("/client/profile/delete", async (req, res) => {
    try {
        const userUuid = req.session.uuid;

        if (!userUuid) {
            return res.status(401).json({ status: "error", message: "Not authenticated" });
        }

        const user = await User.findOne({ where: { uuid: userUuid } });
        if (!user) {
            return res.status(404).json({ status: "error", message: "User not found" });
        }

        console.log(`[ACCOUNT DELETE] User ${userUuid} (${user.email}) is deleting their account`);

        // Delete associated data
        await Client.destroy({ where: { userUuid } });
        await SignalPreKey.destroy({ where: { userUuid } });
        await SignalSignedPreKey.destroy({ where: { userUuid } });
        
        // Remove from channel memberships
        await ChannelMembers.destroy({ where: { userUuid } });

        // Hard delete user
        await user.destroy();

        // Destroy session
        req.session.destroy();

        console.log(`[ACCOUNT DELETE] User ${userUuid} account deleted successfully`);

        res.status(200).json({
            status: "ok",
            message: "Account deleted successfully"
        });
    } catch (error) {
        console.error('Error deleting account:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Manual cleanup endpoint (for testing/admin purposes)
clientRoutes.get("/admin/cleanup", async (req, res) => {
    try {
        // Optional: Add authentication/authorization check here
        // if (!req.session.isAdmin) return res.status(403).json({ error: "Forbidden" });
        
        const { runCleanup } = require('../jobs/cleanup');
        
        console.log('[ADMIN] Manual cleanup triggered by user:', req.session.uuid || 'unauthenticated');
        
        // Run cleanup in background
        runCleanup().then(() => {
            console.log('[ADMIN] Manual cleanup completed');
        }).catch(error => {
            console.error('[ADMIN] Manual cleanup failed:', error);
        });
        
        res.status(200).json({ 
            status: "ok", 
            message: "Cleanup job started",
            config: {
                inactiveUserDays: config.cleanup.inactiveUserDays,
                deleteOldItemsDays: config.cleanup.deleteOldItemsDays
            }
        });
    } catch (error) {
        console.error('Error triggering manual cleanup:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

module.exports = clientRoutes;