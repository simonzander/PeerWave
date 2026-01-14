const config = require('../config/config');
const express = require("express");
const { Sequelize, DataTypes, Op, UUID, col } = require('sequelize');
const { Fido2Lib } = require('fido2-lib');
const bodyParser = require('body-parser'); // Import body-parser
const nodemailer = require("nodemailer");
const crypto = require('crypto');
const { sanitizeForLog } = require('../utils/logSanitizer');
const logger = require('../utils/logger');
const session = require('express-session');
const fs = require('fs');
const path = require('path');
const versionConfig = require('../config/version');
const magicLinks = require('../store/magicLinksStore');
const { User, Channel, Thread, SignalSignedPreKey, SignalPreKey, Client, Item, Role, ChannelMembers, ClientSession, RefreshToken, sequelize } = require('../db/model');
const fetch = (...args) => import('node-fetch').then(({default: fetch}) => fetch(...args));
const writeQueue = require('../db/writeQueue');
const { autoAssignRoles } = require('../db/autoAssignRoles');
const { hasServerPermission } = require('../db/roleHelpers');
const livekitWrapper = require('../lib/livekit-wrapper');
const { verifySessionAuth, verifyAuthEither } = require('../middleware/sessionAuth');

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
    // Skip body parsing for routes that need custom limits
    if (req.path === '/client/profile/setup' && req.method === 'POST') {
        return next();
    }
    if (req.path === '/api/server/settings' && req.method === 'POST') {
        return next();
    }
    if (req.path === '/client/profile/update' && req.method === 'POST') {
        return next();
    }
    
    // Capture raw body for HMAC signature verification
    bodyParser.urlencoded({ 
        extended: true,
        verify: (req, res, buf) => {
            req.rawBody = buf;
        }
    })(req, res, () => {
        bodyParser.json({ 
            verify: (req, res, buf) => {
                req.rawBody = buf;
            }
        })(req, res, next);
    });
});

// Configure session middleware
clientRoutes.use(session({
    secret: config.session.secret, // Replace with a strong secret key
    resave: config.session.resave,
    saveUninitialized: config.session.saveUninitialized,
    cookie: config.cookie // Set to true if using HTTPS
}));

clientRoutes.get("/client/meta", async (req, res) => {
    const response = {
        name: versionConfig.projectName,
        version: versionConfig.version,
        description: versionConfig.projectDescription,
        compatibility: {
            minClientVersion: versionConfig.minClientVersion,
            maxClientVersion: versionConfig.maxClientVersion,
        },
        features: {
            e2ee: true,
            groupCalls: true,
            fileSharing: true,
            webrtc: true,
        }
    };
    
    // Note: ICE servers are now provided by LiveKit via /api/livekit/ice-config
    // This endpoint only provides server metadata and settings
    
    // Add server settings (server name, picture, registration mode)
    try {
        const { ServerSettings } = require('../db/model');
        const settings = await ServerSettings.findOne({ where: { id: 1 } });
        
        if (settings) {
            response.serverName = settings.server_name || 'PeerWave Server';
            response.serverPicture = settings.server_picture || null;
            response.registrationMode = settings.registration_mode || 'open';
        } else {
            response.serverName = 'PeerWave Server';
            response.serverPicture = null;
            response.registrationMode = 'open';
        }
    } catch (error) {
        logger.error('[CLIENT META] Failed to load server settings', error);
        response.serverName = 'PeerWave Server';
        response.serverPicture = null;
        response.registrationMode = 'open';
    }
    
    // Add server operator information
    response.serverOperator = {
        owner: config.serverOperator.owner,
        contact: config.serverOperator.contact,
        location: config.serverOperator.location,
        additionalInfo: config.serverOperator.additionalInfo
    };
    
    res.json(response);
});

clientRoutes.get("/direct/messages/:userId", verifyAuthEither, async (req, res) => {
    const { userId } = req.params;
    // Support both web (session-based) and native (HMAC) authentication
    const sessionUuid = req.userId || req.session.uuid;
    const sessionDeviceId = req.deviceId || req.session.deviceId;
    
    if (!sessionUuid || !sessionDeviceId) {
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
        logger.debug('[CLIENT.JS] Direct messages (1:1 only)', { deviceId: sanitizeForLog(sessionDeviceId), count: result.length });
        logger.debug('[CLIENT.JS] Query params', { deviceReceiver: sanitizeForLog(sessionDeviceId), receiver: sanitizeForLog(sessionUuid) });
        if (result.length > 0) {
            logger.debug('[CLIENT.JS] Sample messages', result.slice(0, 3).map(r => ({
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
        logger.error('[CLIENT.JS] Error fetching direct messages', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// GET all devices of channel members (for group message encryption)
clientRoutes.get("/channels/:channelId/member-devices", verifyAuthEither, async (req, res) => {
    const { channelId } = req.params;
    const sessionUuid = req.userId || req.session.uuid;
    
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
        logger.error('[CLIENT.JS] Error fetching channel member devices', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// GET Signal Group Messages for a channel
clientRoutes.get("/channels/:channelId/messages", verifyAuthEither, async (req, res) => {
    const { channelId } = req.params;
    const sessionUuid = req.userId || req.session.uuid;
    const sessionDeviceId = req.deviceId || req.session.deviceId;
    
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
        
        logger.debug('[CLIENT.JS] Channel messages', { deviceId: sessionDeviceId, channelId, count: result.length });
        res.status(200).json(result);
    } catch (error) {
        logger.error('[CLIENT.JS] Error fetching channel messages', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// GET all channel messages for all channels the user is a member of
clientRoutes.get("/channels/messages/all", verifyAuthEither, async (req, res) => {
    const sessionUuid = req.userId || req.session.uuid;
    const sessionDeviceId = req.deviceId || req.session.deviceId;
    
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
        
        logger.debug('[CLIENT.JS] All channel messages', { deviceId: sanitizeForLog(sessionDeviceId), channelCount: channelIds.length, messageCount: result.length });
        res.status(200).json(result);
    } catch (error) {
        logger.error('[CLIENT.JS] Error fetching all channel messages', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// POST Signal Group Message (Sender Key encryption)
clientRoutes.post("/channels/:channelId/group-messages", verifyAuthEither, async (req, res) => {
    const { channelId } = req.params;
    const { itemId, ciphertext, senderId, senderDeviceId, timestamp } = req.body;
    const sessionUuid = req.userId || req.session.uuid;
    const sessionDeviceId = req.deviceId || req.session.deviceId;
    
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
            logger.info('[CLIENT.JS] Created group message items', { count: items.length, channelId: sanitizeForLog(channelId) });
        }
        
        // TODO: Emit WebSocket event to online members
        // req.app.get('io').to(channelId).emit('newGroupMessage', { itemId, channelId });
        
        res.status(200).json({ status: "success", itemsSent: items.length });
    } catch (error) {
        logger.error('[CLIENT.JS] Error sending group message', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// 🆕 Lightweight endpoint to check Signal key status (for client validation)
clientRoutes.get("/signal/status/minimal", verifyAuthEither, async (req, res) => {
    const sessionUuid = req.userId || req.session.uuid;
    const sessionDeviceId = req.deviceId || req.session.deviceId;
    
    if (!sessionUuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    
    try {
        // Fetch identity key from Client table
        const client = await Client.findOne({ 
            where: { 
                owner: sessionUuid, 
                clientid: sessionDeviceId 
            }
        });
        
        // Fetch latest SignedPreKey
        const signedPreKey = await SignalSignedPreKey.findOne({
            where: {
                owner: sessionUuid,
                client: sessionDeviceId
            },
            order: [['id', 'DESC']]
        });
        
        // Count PreKeys
        const preKeyCount = await SignalPreKey.count({
            where: {
                owner: sessionUuid,
                client: sessionDeviceId
            }
        });
        
        res.json({
            identityKey: client?.public_key || null,
            signedPreKeyId: signedPreKey?.id || null,
            preKeyCount: preKeyCount
        });
    } catch (error) {
        logger.error('[SIGNAL] Error fetching minimal status', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// 🆕 Validate and sync Signal keys (for client initialization)
clientRoutes.post("/signal/validate-and-sync", verifyAuthEither, async (req, res) => {
    const sessionUuid = req.userId || req.session.uuid;
    const sessionDeviceId = req.deviceId || req.session.deviceId;
    
    if (!sessionUuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    
    try {
        const { localIdentityKey, localSignedPreKeyId, localPreKeyCount } = req.body;
        
        const validationResult = {
            keysValid: true,
            missingKeys: [],
            preKeyIdsToDelete: []
        };
        
        // Fetch server state from Client table (Identity key stored here)
        const serverClient = await Client.findOne({ 
            where: { 
                owner: sessionUuid, 
                device_id: sessionDeviceId 
            }
        });
        
        const serverSignedPreKey = await SignalSignedPreKey.findOne({
            where: {
                owner: sessionUuid,
                client: sessionDeviceId
            },
            order: [['id', 'DESC']]
        });
        
        const serverPreKeys = await SignalPreKey.findAll({
            where: {
                owner: sessionUuid,
                client: sessionDeviceId
            },
            attributes: ['id']
        });
        
        // Validate Identity
        // Allow null public_key (first-time setup), but if it exists it must match
        if (!serverClient) {
            validationResult.keysValid = false;
            validationResult.missingKeys.push('identity');
            validationResult.reason = 'Client record not found';
            return res.json(validationResult);
        }
        
        if (serverClient.public_key !== null && serverClient.public_key !== localIdentityKey) {
            validationResult.keysValid = false;
            validationResult.missingKeys.push('identity');
            validationResult.reason = 'Identity key mismatch';
            return res.json(validationResult);
        }
        
        // Validate SignedPreKey
        // Allow null (first-time setup), but if it exists the ID must match
        if (serverSignedPreKey && serverSignedPreKey.id !== localSignedPreKeyId) {
            validationResult.keysValid = false;
            validationResult.missingKeys.push('signedPreKey');
            validationResult.reason = 'SignedPreKey out of sync';
            return res.json(validationResult);
        }
        
        // Validate PreKeys - find consumed ones
        const serverPreKeyIds = serverPreKeys.map(k => k.id);
        const localPreKeyIds = Array.from({length: localPreKeyCount}, (_, i) => i);
        
        // Find PreKeys that exist locally but not on server (consumed)
        const consumedPreKeyIds = localPreKeyIds.filter(id => !serverPreKeyIds.includes(id));
        
        if (consumedPreKeyIds.length > 0) {
            validationResult.preKeyIdsToDelete = consumedPreKeyIds;
            validationResult.reason = `${consumedPreKeyIds.length} PreKeys consumed`;
        }
        
        res.json(validationResult);
    } catch (error) {
        logger.error('[SIGNAL] Error validating keys', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Batch store PreKeys via HTTP POST (for progressive initialization)
clientRoutes.post("/signal/prekeys/batch", verifyAuthEither, async (req, res) => {
    // Support both web (session-based) and native (HMAC) authentication
    const sessionUuid = req.userId || req.session.uuid;
    const sessionDeviceId = req.deviceId || req.session.deviceId;
    
    if (!sessionUuid) {
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
        // For native clients, use clientId from auth headers; for web, use session deviceId
        const clientQuery = req.sessionAuth && req.clientId 
            ? { owner: sessionUuid, clientid: req.clientId }
            : { owner: sessionUuid, device_id: sessionDeviceId };
        
        const client = await Client.findOne({ where: clientQuery });
        
        if (!client) {
            logger.warn('[SIGNAL PREKEYS BATCH] Client not found', { query: clientQuery });
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
            logger.info('[SIGNAL PREKEYS BATCH] Write queued', { userUuid: sanitizeForLog(sessionUuid), deviceId: sanitizeForLog(sessionDeviceId), count: preKeys.length });
            
            // Let the write continue in background (don't await)
            writePromise.then(() => {
                logger.info('[SIGNAL PREKEYS BATCH] Background write completed', { count: preKeys.length, userUuid: sessionUuid });
            }).catch(err => {
                logger.error('[SIGNAL PREKEYS BATCH] Background write failed', { userUuid: sessionUuid, error: err });
            });
            
            res.status(202).json({ 
                status: "accepted", 
                stored: preKeys.length,
                message: `${preKeys.length} PreKeys queued for processing`
            });
        } else {
            // Write completed quickly
            logger.info('[SIGNAL PREKEYS BATCH] PreKeys stored', { userUuid: sanitizeForLog(sessionUuid), deviceId: sanitizeForLog(sessionDeviceId), count: preKeys.length });
            
            res.status(200).json({ 
                status: "success", 
                stored: preKeys.length,
                message: `${preKeys.length} PreKeys stored successfully`
            });
        }
    } catch (error) {
        logger.error('[SIGNAL PREKEYS BATCH] Error storing PreKeys', error);
        res.status(500).json({ 
            status: "error", 
            message: "Internal server error" 
        });
    }
});

clientRoutes.get("/signal/prekey_bundle/:userId", verifyAuthEither, async (req, res) => {
    const { userId } = req.params;
    const sessionUuid = req.userId || req.session.uuid;
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
        logger.error('[SIGNAL] Error fetching signed pre-key', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

clientRoutes.get("/people/list", verifyAuthEither, async (req, res) => {
    const sessionUuid = req.userId || req.session.uuid;
    if (!sessionUuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    try {
        logger.debug('[PEOPLE_LIST] Fetching users', { sessionUuid });
        
        // Get blocked user UUIDs (both directions)
        const blockedUuids = new Set();
        try {
            const { BlockedUser } = require('../db/model');
            const blockedRecords = await BlockedUser.findAll({
                where: {
                    [Op.or]: [
                        { blocker_uuid: sessionUuid },
                        { blocked_uuid: sessionUuid }
                    ]
                },
                attributes: ['blocker_uuid', 'blocked_uuid']
            });
            
            blockedRecords.forEach(record => {
                if (record.blocker_uuid === sessionUuid) {
                    blockedUuids.add(record.blocked_uuid);
                } else {
                    blockedUuids.add(record.blocker_uuid);
                }
            });
            
            if (blockedUuids.size > 0) {
                logger.debug('[PEOPLE_LIST] Filtering out blocked users', { count: blockedUuids.size });
            }
        } catch (e) {
            logger.warn('[PEOPLE_LIST] Failed to fetch blocked users', { error: e?.message || e });
        }
        
        const users = await User.findAll({
            attributes: ['uuid', 'displayName', 'email', 'picture', 'atName'],
            where: { 
                uuid: { 
                    [Op.ne]: sessionUuid, // Exclude the current user
                    [Op.notIn]: Array.from(blockedUuids) // Exclude blocked users
                },
                active: true, // Only show active users
                verified: true, // Only show verified users who completed registration
                displayName: { [Op.ne]: null }, // Only show users with displayName set
                [Op.and]: [
                    sequelize.where(
                        sequelize.fn('LENGTH', sequelize.col('displayName')),
                        { [Op.gt]: 0 }
                    )
                ]
            }
        });

        // Add presence/online info (best-effort)
        let usersJson = users.map(u => u.toJSON());
        try {
            const presenceService = require('../services/presenceService');
            const userIds = usersJson.map(u => u.uuid).filter(Boolean);
            const presenceData = await presenceService.getPresence(userIds);
            const presenceMap = new Map(presenceData.map(p => [p.user_id, p]));

            usersJson = usersJson.map(u => {
                const presence = presenceMap.get(u.uuid);
                const status = presence?.status || 'offline';
                return {
                    ...u,
                    isOnline: status === 'online' || status === 'busy',
                };
            });
        } catch (e) {
            logger.warn('[PEOPLE_LIST] Failed to attach presence info', { error: e?.message || e });
            // Fall back to returning users without presence
        }

        logger.debug('[PEOPLE_LIST] Found verified users', { count: usersJson.length });
        res.status(200).json(usersJson);
    } catch (error) {
        logger.error('[PEOPLE_LIST] Error fetching users', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Batch load profiles by UUIDs (GET endpoint for smart loading)
clientRoutes.get("/people/profiles", verifyAuthEither, async (req, res) => {
    const sessionUuid = req.userId || req.session.uuid;
    if (!sessionUuid) {
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
        
        // Get presence data for all users
        const presenceService = require('../services/presenceService');
        const presenceData = await presenceService.getPresence(uuids);
        const presenceMap = new Map(presenceData.map(p => [p.user_id, p]));
        
        // Convert picture BLOB to base64 string and add presence data
        const profiles = users.map(user => {
            const userData = user.toJSON();
            if (userData.picture && Buffer.isBuffer(userData.picture)) {
                userData.picture = `data:image/png;base64,${userData.picture.toString('base64')}`;
            }
            
            // Add presence data
            const presence = presenceMap.get(userData.uuid);
            userData.presence = {
                status: presence?.status || 'offline',
                last_seen: presence?.last_heartbeat || presence?.updated_at || null
            };
            
            return userData;
        });
        
        res.status(200).json({ profiles });
    } catch (error) {
        logger.error('[CLIENT.JS] Error fetching user profiles', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

clientRoutes.post("/client/people/info", verifyAuthEither, async (req, res) => {
    const sessionUuid = req.userId || req.session.uuid;
    if (!sessionUuid) {
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
        logger.error('[PROFILES] Error fetching users', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// GET /client/channels/discover - Get discoverable channels (public channels user isn't part of)
// IMPORTANT: This must come BEFORE /client/channels/:uuid to avoid route collision
clientRoutes.get("/client/channels/discover", verifyAuthEither, async(req, res) => {
    const limit = parseInt(req.query.limit) || 10;
    const offset = parseInt(req.query.offset) || 0;
    
    const userUuid = req.userId || req.session.uuid;
    if (!userUuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    
    try {
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
        logger.error('[CHANNELS] Error fetching discover channels', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// GET /client/channels/:uuid - Get single channel details
clientRoutes.get("/client/channels/:uuid", verifyAuthEither, async (req, res) => {
    const sessionUuid = req.userId || req.session.uuid;
    if (!sessionUuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }

    try {
        const { uuid } = req.params;
        
        const channel = await Channel.findOne({
            where: { uuid },
            attributes: ['uuid', 'name', 'description', 'owner', 'private', 'type', 'defaultRoleId']
        });

        if (!channel) {
            return res.status(404).json({ status: "error", message: "Channel not found" });
        }

        res.status(200).json(channel);
    } catch (error) {
        logger.error('[CHANNELS] Error fetching channel details', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// PUT /client/channels/:uuid - Update channel settings (owner only)
clientRoutes.put("/client/channels/:uuid", verifyAuthEither, async (req, res) => {
    const sessionUuid = req.userId || req.session.uuid;
    if (!sessionUuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }

    try {
        const { uuid } = req.params;
        const { name, description, private: isPrivate, defaultRoleId } = req.body;
        
        // Find the channel
        const channel = await Channel.findOne({ where: { uuid } });

        if (!channel) {
            return res.status(404).json({ status: "error", message: "Channel not found" });
        }

        // Check if user is owner
        if (channel.owner !== sessionUuid) {
            return res.status(403).json({ status: "error", message: "Only channel owners can update settings" });
        }

        // Update fields if provided
        const updates = {};
        if (name !== undefined) updates.name = name;
        if (description !== undefined) updates.description = description;
        if (isPrivate !== undefined) updates.private = isPrivate;
        if (defaultRoleId !== undefined) updates.defaultRoleId = defaultRoleId;

        await channel.update(updates);

        res.status(200).json({ status: "success", channel });
    } catch (error) {
        logger.error('[CHANNELS] Error updating channel', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// DELETE /client/channels/:uuid - Delete a channel (owner only)
clientRoutes.delete("/client/channels/:uuid", verifyAuthEither, async (req, res) => {
    const sessionUuid = req.userId || req.session.uuid;
    if (!sessionUuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }

    try {
        const { uuid } = req.params;
        
        // Find the channel
        const channel = await Channel.findOne({ where: { uuid } });

        if (!channel) {
            return res.status(404).json({ status: "error", message: "Channel not found" });
        }

        // Check if user is owner
        if (channel.owner !== sessionUuid) {
            return res.status(403).json({ status: "error", message: "Only channel owners can delete the channel" });
        }

        // Delete all channel memberships
        const { ChannelMembers } = require('../db/model');
        await ChannelMembers.destroy({
            where: { channelId: uuid }
        });

        // Delete all channel role assignments
        const { UserRoleChannel } = require('../db/model');
        await UserRoleChannel.destroy({
            where: { channelId: uuid }
        });

        // Delete the channel itself
        await channel.destroy();

        res.status(200).json({ 
            status: "success",
            message: "Channel deleted successfully" 
        });
    } catch (error) {
        logger.error('[CHANNELS] Error deleting channel', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

clientRoutes.post("/client/channels/info", verifyAuthEither, async (req, res) => {
    const sessionUuid = req.userId || req.session.uuid;
    if (!sessionUuid) {
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
        logger.error('[CHANNELS] Error fetching channel info', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

clientRoutes.get("/client/channels", verifyAuthEither, async(req, res) => {
    const limit = parseInt(req.query.limit) || 20;
    const typeFilter = req.query.type; // 'webrtc', 'signal', or undefined for all
    
    const userUuid = req.userId || req.session.uuid;
    if (!userUuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    
    try {
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
        logger.error('[CHANNELS] Error fetching channels', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

clientRoutes.post("/client/channels", verifyAuthEither, async(req, res) => {
    const { name, description, private, type, defaultRoleId } = req.body;
    const userUuid = req.userId || req.session.uuid;
    if (!userUuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    
    // Check if user has channel.create permission
    const hasPermission = await hasServerPermission(userUuid, 'channel.create');
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
        
        const user = await User.findOne({ where: { uuid: userUuid } });
        if (user) {
            const channel = await writeQueue.enqueue(
                () => Channel.create({ 
                    name: name, 
                    description: description, 
                    private: private || false, 
                    type: channelType,
                    owner: userUuid,
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
        logger.error('[CHANNELS] Error creating channel', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// POST /client/channels/:channelId/join - Join a public channel
clientRoutes.post("/client/channels/:channelId/join", verifyAuthEither, async(req, res) => {
    const { channelId } = req.params;
    
    const userId = req.userId || req.session.uuid;
    if (!userId) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    
    try {
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
        logger.error('[CHANNELS] Error joining channel', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Get channel participants (current LiveKit room participants)
clientRoutes.get("/client/channels/:channelUuid/participants", verifyAuthEither, async(req, res) => {
    const { channelUuid } = req.params;
    
    const userUuid = req.userId || req.session.uuid;
    if (!userUuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    
    try {
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
        
        // Only fetch LiveKit participants for WebRTC channels
        let livekitParticipants = [];
        let roomName = null; // Initialize roomName for response
        
        if (channel.type === 'webrtc') {
            // Get LiveKit configuration
            const apiKey = process.env.LIVEKIT_API_KEY || 'devkey';
            const apiSecret = process.env.LIVEKIT_API_SECRET || 'secret';
            const livekitUrl = process.env.LIVEKIT_URL || 'ws://localhost:7880';
            
            // Initialize LiveKit RoomServiceClient (dynamically loaded)
            const RoomServiceClient = await livekitWrapper.getRoomServiceClient();
            const roomService = new RoomServiceClient(livekitUrl, apiKey, apiSecret);
            
            // Get current participants from LiveKit room
            roomName = `channel-${channelUuid}`;
            
            try {
                livekitParticipants = await roomService.listParticipants(roomName);
            } catch (error) {
                // Room might not exist or have no participants
                logger.debug('[LIVEKIT] No active room', { channelUuid, message: error.message });
            }
        } else if (channel.type === 'signal') {
            // For Signal (text) channels, return channel members instead of LiveKit participants
            // Signal channels don't use LiveKit, so no active room participants
            logger.debug('[LIVEKIT] Signal type channel, skipping participant check', { channelUuid });
        }
        
        // Enrich participant data with user information from database
        const participants = await Promise.all(livekitParticipants.map(async (participant) => {
            let metadata = {};
            try {
                metadata = participant.metadata ? JSON.parse(participant.metadata) : {};
            } catch (e) {
                logger.error('[LIVEKIT] Failed to parse participant metadata', e);
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
        logger.error('[CHANNELS] Error fetching channel participants', error);
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
    logger.debug('[MAGIC LINK] Verifying magic link', { clientId: sanitizeForLog(clientid) });
    
    if(!key || !clientid) {
        return res.status(400).json({ status: "failed", message: "Missing key or client ID" });
    }
    
    // Parse new magic key format: {serverUrl}|{randomHash}|{timestamp}|{hmacSignature}
    // Using pipe delimiter which is safe for all URL formats (including IPv6)
    const parts = key.split('|');
    
    if (parts.length !== 4) {
        return res.status(400).json({ status: "failed", message: `Invalid magic key format - expected 4 parts, got ${parts.length}` });
    }
    
    // Extract components
    const serverUrl = parts[0];
    const randomHash = parts[1];
    const timestamp = parseInt(parts[2]);
    const providedSignature = parts[3];
    
    // Verify HMAC signature
    const config = require('../config/config');
    const crypto = require('crypto');
    const dataToSign = `${serverUrl}|${randomHash}|${timestamp}`;
    const hmac = crypto.createHmac('sha256', config.session.secret);
    hmac.update(dataToSign);
    const expectedSignature = hmac.digest('hex');
    
    if (providedSignature !== expectedSignature) {
        return res.status(400).json({ status: "failed", message: "Invalid magic key signature" });
    }
    
    // Check if key exists and not expired
    // Validate randomHash doesn't access prototype properties
    if (!randomHash || typeof randomHash !== 'string' || randomHash.includes('__')) {
        return res.status(400).json({ status: "failed", message: "Invalid magic link format" });
    }
    const entry = magicLinks[randomHash];
    if (!entry) {
        return res.status(400).json({ status: "failed", message: "Invalid or expired magic link" });
    }
    
    // Check expiration
    if (entry.expires < Date.now()) {
        delete magicLinks[randomHash];
        return res.status(400).json({ status: "failed", message: "Magic link has expired" });
    }
    
    // Check one-time use
    if (entry.used) {
        return res.status(400).json({ status: "failed", message: "Magic link has already been used" });
    }
    
    // Mark as used (one-time use)
    entry.used = true;
    
    // Valid magic link - proceed with authentication
    req.session.authenticated = true;
    req.session.email = entry.email;
    req.session.uuid = entry.uuid;
    const userAgent = req.headers['user-agent'] || '';
    const ip = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
    const location = await getLocationFromIp(ip);
    const locationString = location
            ? `${location.city}, ${location.region}, ${location.country} (${location.org})`
            : "Location not found";
    // Check if this clientid exists for a DIFFERENT user (account switch scenario)
    const existingClient = await Client.findOne({ where: { clientid: clientid } });
    if (existingClient && existingClient.owner !== entry.uuid) {
        // Client is switching accounts - delete old client entry and associated keys
        logger.info('[MAGIC LINK] Client switching accounts', { clientId: sanitizeForLog(clientid), from: sanitizeForLog(existingClient.owner), to: sanitizeForLog(entry.uuid) });
        await writeQueue.enqueue(async () => {
            // Delete Signal Protocol keys
            await SignalPreKey.destroy({ where: { client: clientid } });
            await SignalSignedPreKey.destroy({ where: { client: clientid } });
            // Delete client entry
            await Client.destroy({ where: { clientid: clientid } });
        }, 'deleteClientAndKeysOnAccountSwitch');
    }
    
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
    
    // Delete used magic link (randomHash already validated above)
    delete magicLinks[randomHash];
    
    // Generate session secret for native clients (HMAC authentication)
    const sessionSecret = crypto.randomBytes(32).toString('base64url');
    
    // Store session in database
    try {
        await writeQueue.enqueue(
            () => sequelize.query(
                `INSERT OR REPLACE INTO client_sessions 
                 (client_id, session_secret, user_id, device_id, device_info, expires_at, last_used, created_at)
                 VALUES (?, ?, ?, ?, ?, datetime('now', '+30 days'), datetime('now'), datetime('now'))`,
                { 
                    replacements: [
                        clientid, 
                        sessionSecret, 
                        entry.uuid,
                        client.device_id, 
                        JSON.stringify({ userAgent, ip, location: locationString })
                    ] 
                }
            ),
            'createClientSession'
        );
        logger.info('[MagicKey] Session created', { clientId: sanitizeForLog(clientid) });
    } catch (sessionErr) {
        logger.error('[MagicKey] Error creating session', sessionErr);
        // Continue anyway - web clients don't need sessions
    }
    
    // Generate refresh token for native clients
    let refreshToken;
    try {
        const crypto = require('crypto');
        const config = require('../config/config');
        const { RefreshToken } = require('../db/model');
        const writeQueue = require('../db/writeQueue');
        
        const token = crypto.randomBytes(64).toString('base64url');
        const expiresInDays = config.refreshToken?.expiresInDays || 60;
        const expiresAt = new Date(Date.now() + expiresInDays * 24 * 60 * 60 * 1000);
        
        await writeQueue.enqueue(
            () => RefreshToken.create({
                token,
                client_id: clientid,
                user_id: entry.uuid,
                session_id: clientid,
                expires_at: expiresAt,
                created_at: new Date(),
                used_at: null,
                rotation_count: 0
            }),
            'createRefreshToken'
        );
        
        refreshToken = token;
        logger.info('[MagicKey] Refresh token generated');
    } catch (refreshErr) {
        logger.error('[MagicKey] Error generating refresh token', refreshErr);
        // Continue anyway - session still works without refresh token
    }
    
    // Persist session immediately so Socket.IO can read it
    return req.session.save(err => {
        if (err) {
            logger.error('[MAGIC] Session save error', err);
            return res.status(500).json({ status: "error", message: "Session save error" });
        }
        
        // Return session secret for native clients
        const response = { 
            status: "ok", 
            message: "Magic link verified",
            sessionSecret: sessionSecret,  // Native clients will use this for HMAC auth
            userId: entry.uuid,
            email: entry.email  // For device identity initialization
        };
        
        if (refreshToken) {
            response.refreshToken = refreshToken;
        }
        
        res.status(200).json(response);
    });
});

clientRoutes.post("/client/login", async (req, res) => {
    const { clientid, email } = req.body;
    try {
        const owner = await User.findOne({ where: { email: email } });
        if (!owner) {
            return res.status(401).json({ status: "failed", message: "Invalid email" });
        }
        
        // Check if this clientid exists for a DIFFERENT user (account switch scenario)
        const existingClient = await Client.findOne({ where: { clientid: clientid } });
        if (existingClient && existingClient.owner !== owner.uuid) {
            // Client is switching accounts - delete old client entry and associated keys
            logger.info('[CLIENT LOGIN] Client switching accounts', { clientId: sanitizeForLog(clientid), from: sanitizeForLog(existingClient.owner), to: sanitizeForLog(owner.uuid) });
            await writeQueue.enqueue(async () => {
                // Delete Signal Protocol keys
                await SignalPreKey.destroy({ where: { client: clientid } });
                await SignalSignedPreKey.destroy({ where: { client: clientid } });
                // Delete client entry
                await Client.destroy({ where: { clientid: clientid } });
            }, 'deleteClientAndKeysOnAccountSwitch');
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
                    logger.error('[CLIENT LOGIN] Session save error', err);
                    return res.status(500).json({ status: "error", message: "Session save error" });
                }
                res.status(200).json({ status: "ok", message: "Client login successful" });
            });
        } else {
            res.status(401).json({ status: "failed", message: "Invalid client ID or not authorized" });
        }
    } catch (error) {
        logger.error('[CLIENT] Error during client login', error);
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
            // REMOVED: Pug render (Pug disabled, Flutter web client used)
            res.status(410).json({ error: "Pug routes deprecated - use Flutter web client" });
        } else {
            //res.redirect("/login");
        }
    } catch (error) {
        logger.error('[CHANNELS] Error retrieving channels', error);
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
        logger.error('[CHANNELS] Error creating channel (pug route)', error);
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


                res.json(thread);
            }
        } else {
            //res.redirect("/login");
        }
    } catch (error) {
        logger.error('[THREAD] Error retrieving thread', error);
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

                // REMOVED: Pug render (Pug disabled, Flutter web client used)
                res.status(410).json({ error: "Pug routes deprecated - use Flutter web client" });
            }
        } else {
            //res.redirect("/login");
        }
    } catch (error) {
        logger.error('[THREAD] Error retrieving channel', error);
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
        logger.error('[THREAD] Error creating thread', error);
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
        logger.error('[USER SETTINGS] Error updating', error);
        res.json({ message: "Error updating user settings" });
    }
});

// Delete item (cleanup after read receipt)
clientRoutes.delete("/items/:itemId", verifyAuthEither, async (req, res) => {
    try {
        const sessionUuid = req.userId || req.session.uuid;
        if (!sessionUuid) {
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
                    { sender: sessionUuid },
                    { receiver: sessionUuid }
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
            logger.info('[CLEANUP] Item deleted for specific device', { itemId: sanitizeForLog(itemId), userId: sanitizeForLog(receiverUserId), deviceId: sanitizeForLog(receiverDeviceId), by: sanitizeForLog(req.session.uuid) });
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
            logger.info('[CLEANUP] Item deleted for device', { itemId: sanitizeForLog(itemId), deviceId: sanitizeForLog(receiverDeviceId), by: sanitizeForLog(sessionUuid) });
        } else {
            // Delete all items with this itemId (all device versions)
            await writeQueue.enqueue(
                () => Item.destroy({ where: { itemId: itemId } }),
                'deleteItemAllDevices'
            );
            logger.info('[CLEANUP] Item deleted for all devices', { itemId: sanitizeForLog(itemId), by: sanitizeForLog(sessionUuid) });
        }
        
        res.status(200).json({ status: "ok", message: "Item deleted successfully" });
    } catch (error) {
        logger.error('[CLEANUP] Error deleting item', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Profile setup endpoint for initial registration - with increased body limit for images
clientRoutes.post("/client/profile/setup", 
    verifyAuthEither,
    async (req, res) => {
    try {
        const { displayName, picture, atName } = req.body;
        const userUuid = req.userId || req.session.uuid;

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

        // Validate and update atName if provided
        if (atName && atName.trim() !== '') {
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
                logger.error('[PROFILE SETUP] Error processing picture', error);
                return res.status(400).json({ 
                    status: "error", 
                    message: "Invalid picture format" 
                });
            }
        }

        await user.update(updateData);

        logger.info('[PROFILE SETUP] User completed profile setup', { userUuid, displayName });

        // Mark registration as complete (only for session-based auth)
        if (req.session && req.session.registrationStep) {
            req.session.registrationStep = 'complete';

            // Clear the registration session - user must log in properly after registration
            req.session.destroy((err) => {
                if (err) {
                    logger.error('[PROFILE SETUP] Error destroying session', err);
                } else {
                    logger.info('[PROFILE SETUP] Registration session cleared - user must log in');
                }
            });
        }

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
        logger.error('[PROFILE SETUP] Error setting up profile', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Get current user profile
clientRoutes.get("/client/profile", verifyAuthEither, async (req, res) => {
    try {
        const userUuid = req.userId || req.session.uuid;

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
        logger.error('[PROFILE] Error getting profile', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Update user profile
clientRoutes.post("/client/profile/update",
    verifyAuthEither,
    bodyParser.json({ limit: '2mb' }),
    async (req, res) => {
    try {
        const { displayName, atName, picture } = req.body;
        const userUuid = req.userId || req.session.uuid;

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
                logger.error('[PROFILE UPDATE] Error processing picture', error);
                return res.status(400).json({
                    status: "error",
                    message: "Invalid picture format"
                });
            }
        }

        // Apply updates if any
        if (Object.keys(updateData).length > 0) {
            await user.update(updateData);
            logger.info('[PROFILE UPDATE] User updated profile', { userUuid, fields: Object.keys(updateData) });
        }

        res.status(200).json({
            status: "ok",
            message: "Profile updated successfully"
        });
    } catch (error) {
        logger.error('[PROFILE UPDATE] Error updating profile', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Test endpoint to verify HMAC authentication (for debugging)
clientRoutes.get("/client/auth/test", verifyAuthEither, async (req, res) => {
    try {
        const authMethod = req.sessionAuth ? 'HMAC' : 'Cookie';
        res.status(200).json({
            status: "ok",
            message: "Authentication successful",
            authMethod: authMethod,
            userId: req.userId,
            timestamp: new Date().toISOString()
        });
    } catch (error) {
        logger.error('[AUTH TEST] Error', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Check authentication status before logout (for native clients)
// This endpoint helps native clients determine if they should proceed with logout
// or if the session is still valid and logout should be prevented due to permissions
clientRoutes.get("/client/auth/check", async (req, res) => {
    try {
        const clientId = req.headers['x-client-id'];
        const timestamp = parseInt(req.headers['x-timestamp']);
        const nonce = req.headers['x-nonce'];
        const signature = req.headers['x-signature'];

        // Check if HMAC headers are present (native client)
        if (!clientId || !timestamp || !nonce || !signature) {
            // No HMAC headers - not authenticated
            logger.debug('[AUTH CHECK] No HMAC headers found - client not authenticated');
            return res.status(200).json({
                authenticated: false,
                reason: 'no_credentials',
                message: 'No authentication credentials provided'
            });
        }

        // Verify timestamp (±5 minutes window)
        const now = Date.now();
        const maxDiff = 5 * 60 * 1000;
        if (Math.abs(now - timestamp) > maxDiff) {
            logger.debug('[AUTH CHECK] Request expired', { timestamp, now });
            return res.status(200).json({
                authenticated: false,
                reason: 'request_expired',
                message: 'Authentication timestamp expired'
            });
        }

        // Check for replay attack (nonce reuse)
        const [nonceCheck] = await sequelize.query(
            'SELECT 1 FROM nonce_cache WHERE nonce = ?',
            { replacements: [nonce] }
        );

        if (nonceCheck && nonceCheck.length > 0) {
            logger.debug('[AUTH CHECK] Duplicate nonce', { nonce: sanitizeForLog(nonce) });
            return res.status(200).json({
                authenticated: false,
                reason: 'duplicate_nonce',
                message: 'Request nonce already used'
            });
        }

        // Store nonce for replay prevention
        await sequelize.query(
            'INSERT INTO nonce_cache (nonce, created_at) VALUES (?, datetime("now"))',
            { replacements: [nonce] }
        );

        // Get session from database
        const [sessions] = await sequelize.query(
            `SELECT session_secret, user_id, expires_at, device_info
             FROM client_sessions 
             WHERE client_id = ?`,
            { replacements: [clientId] }
        );

        if (!sessions || sessions.length === 0) {
            logger.debug('[AUTH CHECK] No session found', { clientId: sanitizeForLog(clientId) });
            return res.status(200).json({
                authenticated: false,
                reason: 'no_session',
                message: 'No active session for this client'
            });
        }

        const session = sessions[0];

        // Check if session expired
        if (new Date(session.expires_at) < new Date()) {
            logger.debug('[AUTH CHECK] Session expired', { clientId: sanitizeForLog(clientId) });
            return res.status(200).json({
                authenticated: false,
                reason: 'session_expired',
                message: 'Session has expired'
            });
        }

        // Verify HMAC signature
        const fullPath = req.originalUrl.split('?')[0];
        const message = `${clientId}:${timestamp}:${nonce}:${fullPath}:`;
        const expectedSignature = crypto
            .createHmac('sha256', session.session_secret)
            .update(message)
            .digest('hex');

        const signatureBuffer = Buffer.from(signature, 'hex');
        const expectedBuffer = Buffer.from(expectedSignature, 'hex');

        if (signatureBuffer.length !== expectedBuffer.length ||
            !crypto.timingSafeEqual(signatureBuffer, expectedBuffer)) {
            logger.debug('[AUTH CHECK] Signature mismatch', { clientId: sanitizeForLog(clientId) });
            return res.status(200).json({
                authenticated: false,
                reason: 'invalid_signature',
                message: 'Authentication signature invalid'
            });
        }

        // Update last_used timestamp
        await sequelize.query(
            'UPDATE client_sessions SET last_used = datetime("now") WHERE client_id = ?',
            { replacements: [clientId] }
        );

        // Check if user still exists and is active
        const user = await User.findOne({ where: { uuid: session.user_id } });
        if (!user) {
            logger.debug('[AUTH CHECK] User not found', { userId: session.user_id });
            return res.status(200).json({
                authenticated: false,
                reason: 'user_not_found',
                message: 'User account not found'
            });
        }

        if (!user.active) {
            logger.debug('[AUTH CHECK] User inactive', { userId: session.user_id });
            return res.status(200).json({
                authenticated: false,
                reason: 'user_inactive',
                message: 'User account is inactive'
            });
        }

        // All checks passed - session is valid
        logger.debug('[AUTH CHECK] Client authenticated successfully', { clientId: sanitizeForLog(clientId) });
        
        // Check user permissions for logout prevention scenarios
        const hasChannelCreatePermission = await hasServerPermission(session.user_id, 'channel.create');
        
        res.status(200).json({
            authenticated: true,
            userId: session.user_id,
            email: user.email,
            displayName: user.displayName,
            permissions: {
                channelCreate: hasChannelCreatePermission
            },
            sessionExpiresAt: session.expires_at,
            message: 'Session is valid'
        });
    } catch (error) {
        logger.error('[AUTH CHECK] Error', error);
        res.status(500).json({
            authenticated: false,
            reason: 'server_error',
            message: 'Internal server error during authentication check'
        });
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
        logger.error('[ATNAME] Error checking availability', error);
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

        logger.info('[ACCOUNT DELETE] User deleting account', { userUuid: sanitizeForLog(userUuid), email: sanitizeForLog(user.email) });

        // Get all client IDs for this user before deleting
        const userClients = await Client.findAll({ where: { owner: userUuid } });
        const clientIds = userClients.map(c => c.clientid);
        
        // Delete refresh tokens first (foreign key to client_sessions)
        if (clientIds.length > 0) {
            await RefreshToken.destroy({ where: { client_id: clientIds } });
            await ClientSession.destroy({ where: { client_id: clientIds } });
        }
        
        // Delete associated data
        await Client.destroy({ where: { owner: userUuid } });
        await SignalPreKey.destroy({ where: { owner: userUuid } });
        await SignalSignedPreKey.destroy({ where: { owner: userUuid } });
        
        // Delete blocking relationships (both as blocker and blocked)
        const { BlockedUser } = require('../db/model');
        await BlockedUser.destroy({ where: { [Op.or]: [{ blocker_uuid: userUuid }, { blocked_uuid: userUuid }] } });
        
        // Remove from channel memberships
        await ChannelMembers.destroy({ where: { userId: userUuid } });

        // Hard delete user
        await user.destroy();

        // Destroy session
        req.session.destroy();

        logger.info('[ACCOUNT DELETE] Account deleted successfully', { userUuid });

        res.status(200).json({
            status: "ok",
            message: "Account deleted successfully"
        });
    } catch (error) {
        logger.error('[ACCOUNT DELETE] Error deleting account', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Manual cleanup endpoint (for testing/admin purposes)
clientRoutes.get("/admin/cleanup", async (req, res) => {
    try {
        // Optional: Add authentication/authorization check here
        // if (!req.session.isAdmin) return res.status(403).json({ error: "Forbidden" });
        
        const { runCleanup } = require('../jobs/cleanup');
        
        logger.info('[ADMIN] Manual cleanup triggered', { by: req.session.uuid || 'unauthenticated' });
        
        // Run cleanup in background
        runCleanup().then(() => {
            logger.info('[ADMIN] Manual cleanup completed');
        }).catch(error => {
            logger.error('[ADMIN] Manual cleanup failed', error);
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
        logger.error('[ADMIN] Error triggering manual cleanup', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// ==================== SERVER SETTINGS ROUTES ====================

// GET server settings (admin only)
clientRoutes.get("/api/server/settings", verifyAuthEither, async (req, res) => {
    try {
        const userUuid = req.userId || req.session.uuid;
        
        // Check admin permission
        const isAdmin = await hasServerPermission(userUuid, 'server.manage');
        if (!isAdmin) {
            return res.status(403).json({ status: "error", message: "Forbidden: Admin access required" });
        }
        
        const { ServerSettings } = require('../db/model');
        let settings = await ServerSettings.findOne({ where: { id: 1 } });
        
        // Create default settings if none exist
        if (!settings) {
            settings = await ServerSettings.create({
                id: 1,
                server_name: 'PeerWave Server',
                server_picture: null,
                registration_mode: 'open',
                allowed_email_suffixes: '[]'
            });
        }
        
        res.json({
            status: "ok",
            settings: {
                serverName: settings.server_name,
                serverPicture: settings.server_picture,
                registrationMode: settings.registration_mode,
                allowedEmailSuffixes: JSON.parse(settings.allowed_email_suffixes || '[]')
            }
        });
    } catch (error) {
        logger.error('[SERVER SETTINGS] Error fetching', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// POST server settings (admin only)
clientRoutes.post("/api/server/settings", bodyParser.json({ limit: '5mb' }), verifyAuthEither, async (req, res) => {
    try {
        const userUuid = req.userId || req.session.uuid;
        
        // Check admin permission
        const isAdmin = await hasServerPermission(userUuid, 'server.manage');
        if (!isAdmin) {
            return res.status(403).json({ status: "error", message: "Forbidden: Admin access required" });
        }
        
        const { serverName, serverPicture, registrationMode, allowedEmailSuffixes } = req.body;
        
        // Validate registration mode
        const validModes = ['open', 'email_suffix', 'invitation_only'];
        if (registrationMode && !validModes.includes(registrationMode)) {
            return res.status(400).json({ status: "error", message: "Invalid registration mode" });
        }
        
        const { ServerSettings } = require('../db/model');
        let settings = await ServerSettings.findOne({ where: { id: 1 } });
        
        if (!settings) {
            settings = await ServerSettings.create({ id: 1 });
        }
        
        // Update settings
        if (serverName !== undefined) settings.server_name = serverName;
        if (serverPicture !== undefined) settings.server_picture = serverPicture;
        if (registrationMode !== undefined) settings.registration_mode = registrationMode;
        if (allowedEmailSuffixes !== undefined) {
            settings.allowed_email_suffixes = JSON.stringify(allowedEmailSuffixes);
        }
        
        await settings.save();
        
        logger.info('[SERVER SETTINGS] Updated', { by: userUuid });
        
        res.json({
            status: "ok",
            message: "Server settings updated successfully",
            settings: {
                serverName: settings.server_name,
                serverPicture: settings.server_picture,
                registrationMode: settings.registration_mode,
                allowedEmailSuffixes: JSON.parse(settings.allowed_email_suffixes || '[]')
            }
        });
    } catch (error) {
        logger.error('[SERVER SETTINGS] Error updating', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// ==================== INVITATION ROUTES ====================

// POST send invitation (admin only)
clientRoutes.post("/api/server/invitations/send", verifyAuthEither, async (req, res) => {
    try {
        const userUuid = req.userId || req.session.uuid;
        const emailService = require('../services/emailService');
        
        // Check admin permission
        const isAdmin = await hasServerPermission(userUuid, 'server.manage');
        if (!isAdmin) {
            return res.status(403).json({ status: "error", message: "Forbidden: Admin access required" });
        }
        
        const { email } = req.body;
        
        if (!email || !email.includes('@')) {
            return res.status(400).json({ status: "error", message: "Valid email required" });
        }
        
        // Check if user already exists
        const existingUser = await User.findOne({ where: { email } });
        if (existingUser) {
            return res.status(400).json({ status: "error", message: "User with this email already exists" });
        }
        
        // Generate 6-digit token
        const token = Math.floor(100000 + Math.random() * 900000).toString();
        
        // Calculate expiry using config (default: 48 hours)
        const expiresAt = new Date(Date.now() + config.invitation.expirationHours * 60 * 60 * 1000);
        
        const { Invitation } = require('../db/model');
        
        // Create invitation
        const invitation = await Invitation.create({
            email,
            token,
            expires_at: expiresAt,
            invited_by: userUuid
        });
        
        // Send email
        const { ServerSettings } = require('../db/model');
        const settings = await ServerSettings.findOne({ where: { id: 1 } });
        const serverName = settings?.server_name || 'PeerWave Server';
        
        await emailService.sendEmail({
            smtpConfig: config.smtp,
            message: {
                from: config.smtp.auth.user,
                to: email,
                subject: `You're Invited to Join ${serverName}`,
                html: `
                    <div style="font-family: 'Nunito Sans', system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background-color: #0f1419; padding: 40px 16px; color: #d6dde3; margin: 0;">
                        <div style="max-width: 600px; margin: 0 auto; background-color: #141b22; border-radius: 12px; padding: 32px; box-shadow: 0 4px 16px rgba(0, 0, 0, 0.3), 0 0 0 1px rgba(45, 212, 191, 0.08);">
                            <div style="text-align: center; margin-bottom: 32px;">
                                <h2 style="margin: 0 0 8px 0; color: #2dd4bf; font-size: 28px; font-weight: 600;">You're Invited!</h2>
                                <p style="margin: 0; color: #8b949e; font-size: 14px;">Join ${serverName} at <strong style="color: #2dd4bf;">${config.app.url}</strong></p>
                            </div>
                            
                            <div style="margin: 32px 0; padding: 24px; background-color: #0f1419; border-radius: 10px; border: 2px solid rgba(45, 212, 191, 0.3);">
                                <p style="margin: 0 0 12px 0; color: #cbd5dc; font-size: 14px; text-align: center;">Your invitation code:</p>
                                <div style="font-size: 42px; font-weight: 700; letter-spacing: 12px; color: #2dd4bf; text-align: center; font-family: 'Courier New', monospace;">${token}</div>
                            </div>
                            
                            <div style="background-color: rgba(45, 212, 191, 0.06); border-left: 3px solid #2dd4bf; padding: 16px; border-radius: 6px; margin: 24px 0;">
                                <p style="margin: 0 0 8px 0; color: #cbd5dc; font-size: 14px; line-height: 1.6;">
                                    <strong style="color: #2dd4bf;">⏰ Valid for ${config.invitation.expirationHours} hours</strong>
                                </p>
                                <p style="margin: 0; color: #8b949e; font-size: 13px; line-height: 1.5;">
                                    This invitation code will expire in ${config.invitation.expirationHours} hours. Register soon to secure your account!
                                </p>
                            </div>
                            
                            <div style="text-align: center; margin: 32px 0;">
                                <a href="${config.app.url}/register" style="display: inline-block; background: linear-gradient(135deg, #2dd4bf 0%, #14b8a6 100%); color: #ffffff; text-decoration: none; padding: 14px 32px; border-radius: 8px; font-weight: 600; font-size: 16px; box-shadow: 0 4px 12px rgba(45, 212, 191, 0.3);">
                                    Join ${serverName}
                                </a>
                            </div>
                            
                            <div style="margin-top: 32px; padding-top: 24px; border-top: 1px solid rgba(139, 148, 158, 0.2);">
                                <p style="margin: 0 0 12px 0; color: #cbd5dc; font-size: 14px; line-height: 1.6;">
                                    To complete your registration:
                                </p>
                                <ol style="margin: 0; padding-left: 20px; color: #8b949e; font-size: 13px; line-height: 1.8;">
                                    <li>Visit <a href="${config.app.url}" style="color: #2dd4bf; text-decoration: none;">${config.app.url}</a></li>
                                    <li>Click on "Register" or "Sign Up"</li>
                                    <li>Enter your email address: <strong style="color: #cbd5dc;">${email}</strong></li>
                                    <li>Enter the invitation code above</li>
                                </ol>
                            </div>
                            
                            <div style="margin-top: 32px; padding: 16px; background-color: rgba(255, 193, 7, 0.08); border-left: 3px solid #ffc107; border-radius: 6px;">
                                <p style="margin: 0; color: #8b949e; font-size: 12px; line-height: 1.5;">
                                    <strong style="color: #ffc107;">⚠️ Security Notice:</strong> If you did not expect this invitation, please ignore this email. Never share your invitation code with anyone.
                                </p>
                            </div>
                            
                            <div style="margin-top: 32px; text-align: center; color: #6e7681; font-size: 12px; line-height: 1.5;">
                                <p style="margin: 0;">This is an automated message from ${serverName}</p>
                                <p style="margin: 8px 0 0 0;">${config.app.url}</p>
                            </div>
                        </div>
                    </div>
                `,
                text: `You've been invited to join ${serverName}!

Your invitation code: ${token}

This invitation expires in ${config.invitation.expirationHours} hours.

To register:
1. Visit ${config.app.url}
2. Click on "Register" or "Sign Up"
3. Enter your email: ${email}
4. Enter the invitation code: ${token}

If you did not expect this invitation, please ignore this email.

---
${serverName}
${config.app.url}`
            }
        });
        
        logger.info('[INVITATION] Successfully sent', { email: sanitizeForLog(email), by: sanitizeForLog(userUuid), token: sanitizeForLog(token) });
        
        res.json({
            status: "ok",
            message: "Invitation sent successfully",
            invitation: {
                id: invitation.id,
                email: invitation.email,
                token: invitation.token,
                expiresAt: invitation.expires_at
            }
        });
    } catch (error) {
        logger.error('[INVITATION] Error occurred', error);
        res.status(500).json({ status: "error", message: "Failed to send invitation: " + error.message });
    }
});

// GET list invitations (admin only)
clientRoutes.get("/api/server/invitations", verifyAuthEither, async (req, res) => {
    try {
        const userUuid = req.userId || req.session.uuid;
        
        // Check admin permission
        const isAdmin = await hasServerPermission(userUuid, 'server.manage');
        if (!isAdmin) {
            return res.status(403).json({ status: "error", message: "Forbidden: Admin access required" });
        }
        
        const { Invitation } = require('../db/model');
        
        // Get active invitations (not used, not expired)
        const invitations = await Invitation.findAll({
            where: {
                used: false,
                expires_at: {
                    [Op.gt]: new Date()
                }
            },
            order: [['created_at', 'DESC']]
        });
        
        res.json({
            status: "ok",
            invitations: invitations.map(inv => ({
                id: inv.id,
                email: inv.email,
                token: inv.token,
                createdAt: inv.created_at,
                expiresAt: inv.expires_at,
                invitedBy: inv.invited_by
            }))
        });
    } catch (error) {
        logger.error('[INVITATION] Error fetching', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// DELETE invitation (admin only)
clientRoutes.delete("/api/server/invitations/:id", verifyAuthEither, async (req, res) => {
    try {
        const userUuid = req.userId || req.session.uuid;
        const { id } = req.params;
        
        // Check admin permission
        const isAdmin = await hasServerPermission(userUuid, 'server.manage');
        if (!isAdmin) {
            return res.status(403).json({ status: "error", message: "Forbidden: Admin access required" });
        }
        
        const { Invitation } = require('../db/model');
        
        const deleted = await Invitation.destroy({
            where: { id: parseInt(id) }
        });
        
        if (deleted === 0) {
            return res.status(404).json({ status: "error", message: "Invitation not found" });
        }
        
        logger.info('[INVITATION] Deleted', { id, by: userUuid });
        
        res.json({
            status: "ok",
            message: "Invitation deleted successfully"
        });
    } catch (error) {
        logger.error('[INVITATION] Error deleting', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// DELETE client/device session (logout a specific device)
clientRoutes.delete("/client/:clientId", verifyAuthEither, async (req, res) => {
    try {
        const { clientId } = req.params;
        const userUuid = req.userId || req.session.uuid;
        const currentClientId = req.clientId || req.session.clientId; // HMAC or session
        
        if (!userUuid) {
            return res.status(401).json({ status: "error", message: "Unauthorized" });
        }
        
        // Prevent deletion of current session's client
        if (clientId === currentClientId) {
            return res.status(400).json({ 
                status: "error", 
                message: "Cannot delete the current session's client. Please logout first or use another device." 
            });
        }
        
        // Find the client to verify ownership
        const client = await Client.findOne({ 
            where: { 
                clientid: clientId,
                owner: userUuid 
            } 
        });
        
        if (!client) {
            return res.status(404).json({ 
                status: "error", 
                message: "Client not found or access denied" 
            });
        }
        
        logger.info('[CLIENT DELETE] Deleting client', { userUuid: sanitizeForLog(userUuid), clientId: sanitizeForLog(clientId) });
        
        // Delete associated Signal keys
        await writeQueue.enqueue(async () => {
            await SignalPreKey.destroy({ where: { client: clientId } });
            await SignalSignedPreKey.destroy({ where: { client: clientId } });
            logger.debug('[CLIENT DELETE] Deleted Signal keys', { clientId: sanitizeForLog(clientId) });
        }, 'deleteClientSignalKeys');
        
        // Delete session from database
        await sequelize.query(
            'DELETE FROM client_sessions WHERE client_id = ?',
            { replacements: [clientId] }
        );
        
        // Delete nonce cache entries (optional cleanup for replay attack prevention)
        // This is not critical as nonces expire anyway, but keeps the cache clean
        await sequelize.query(
            'DELETE FROM nonce_cache WHERE created_at < datetime("now", "-1 day")',
            { type: sequelize.QueryTypes.DELETE }
        );
        
        // Delete the client (this also deletes public_key and registration_id stored in Client table)
        await writeQueue.enqueue(
            () => Client.destroy({ where: { clientid: clientId } }),
            'deleteClient'
        );
        
        logger.info('[CLIENT DELETE] Successfully deleted client and all associated data', { clientId: sanitizeForLog(clientId) });
        
        res.status(200).json({ 
            status: "ok", 
            message: "Client deleted successfully" 
        });
    } catch (error) {
        logger.error('[CLIENT DELETE] Error deleting client', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

module.exports = clientRoutes;