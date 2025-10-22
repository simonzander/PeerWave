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
const { User, Channel, Thread, SignalSignedPreKey, SignalPreKey, Client, Item } = require('../db/model');
const fetch = (...args) => import('node-fetch').then(({default: fetch}) => fetch(...args));

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

// Add body-parser middleware
clientRoutes.use(bodyParser.urlencoded({ extended: true }));
clientRoutes.use(bodyParser.json());

// Configure session middleware
clientRoutes.use(session({
    secret: config.session.secret, // Replace with a strong secret key
    resave: config.session.resave,
    saveUninitialized: config.session.saveUninitialized,
    cookie: config.cookie // Set to true if using HTTPS
}));

clientRoutes.get("/client/meta", (req, res) => {
    res.json({
        name: "PeerWave",
        version: "1.0.0",
    });
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
        console.log(`[CLIENT.JS] Direct messages for device ${sessionDeviceId}:`, result.length);
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
                await SignalPreKey.destroy({ where: { owner: client.owner, client: client.clientid, prekey_id: preKeyObj.prekey_id } });
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

clientRoutes.get("/client/channels", async(req, res) => {
    const limit = parseInt(req.query.limit) || 100;
    if(req.session.authenticated !== true || !req.session.uuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    // Fetch channels logic here
    try {
      const channels = await Channel.findAll({
        include: [
          {
            model: User,
            as: 'Members',
            where: { uuid: req.session.uuid },
            through: { attributes: [] }
          },
          {
            model: Thread,
            required: false,
            attributes: [],
          }
        ],
        attributes: {
          include: [
            [Channel.sequelize.fn('MAX', Channel.sequelize.col('Threads.createdAt')), 'latestThread']
          ]
        },
        group: ['Channel.name'],
        order: [[Channel.sequelize.literal('latestThread'), 'DESC']],
        limit: limit
      });
      res.status(200).json(channels);
    } catch (error) {
        console.error('Error fetching channels:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

clientRoutes.post("/client/channels", async(req, res) => {
    const { name, description, private, defaultPermissions } = req.body;
    if(req.session.authenticated !== true || !req.session.uuid) {
        return res.status(401).json({ status: "error", message: "Unauthorized" });
    }
    try {
        // Add the creator as a member with 'admin' permission
        const user = await User.findOne({ where: { uuid: req.session.uuid } });
        if (user) {
            const channel = await Channel.create({ name: name, description: description, private: private, defaultPermissions: defaultPermissions, type: "text", owner: req.session.uuid });
            await channel.addMember(user, { through: { permission: 'admin' } });
        }
        res.status(201).json(channel);
    } catch (error) {
        console.error('Error creating channel:', error);
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
        const [client] = await Client.findOrCreate({
            where: { owner: entry.uuid, clientid: clientid },
            defaults: { owner: entry.uuid, clientid: clientid, ip: ip, browser: userAgent, location: locationString, device_id: maxDevice ? maxDevice + 1 : 1 }
        });
        req.session.clientId = client.clientid;
        req.session.deviceId = client.device_id;
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
            const channel = await Channel.create({ name, description, private: booleanIsPrivate, owner, type });
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
            const thread = await Thread.create({ message, sender, channel });
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
            await user.save();
            res.json({message: "User settings updated"});
        }
    } catch (error) {
        console.error('Error updating user settings:', error);
        res.json({ message: "Error updating user settings" });
    }
});

module.exports = clientRoutes;