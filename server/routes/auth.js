const config = require('../config/config');
const express = require("express");
const { Sequelize, DataTypes, Op, UUID } = require('sequelize');
const { Fido2Lib } = require('fido2-lib');
const bodyParser = require('body-parser'); // Import body-parser
const nodemailer = require("nodemailer");
const crypto = require('crypto');
const { sanitizeForLog } = require('../utils/logSanitizer');
const logger = require('../utils/logger');
const session = require('express-session');
const rateLimit = require('express-rate-limit');
const { sessionLimiter, authLimiter } = require('../middleware/rateLimiter');
const fetch = (...args) => import('node-fetch').then(({default: fetch}) => fetch(...args));
const magicLinks = require('../store/magicLinksStore');
const { User, OTP, Client, ClientSession, RefreshToken, SignalPreKey, SignalSignedPreKey, SignalSenderKey, Item, GroupItem, GroupItemRead, sequelize } = require('../db/model');
const bcrypt = require("bcrypt");
const writeQueue = require('../db/writeQueue');
const { autoAssignRoles } = require('../db/autoAssignRoles');
const { generateAuthToken, verifyAuthToken, revokeToken } = require('../utils/jwtHelper');
const { verifySessionAuth, verifyAuthEither } = require('../middleware/sessionAuth');

/**
 * Generate a refresh token for native client session renewal
 * @param {string} clientId - Client UUID
 * @param {string} userUuid - User UUID
 * @returns {Promise<string>} Refresh token
 */
async function generateRefreshToken(clientId, userUuid) {
    try {
        const token = crypto.randomBytes(64).toString('base64url');
        const expiresInDays = config.refreshToken?.expiresInDays || 60;
        const expiresAt = new Date(Date.now() + expiresInDays * 24 * 60 * 60 * 1000);
        
        // Store in database
        await writeQueue.enqueue(
            () => RefreshToken.create({
                token,
                client_id: clientId,
                user_id: userUuid,
                session_id: clientId,
                expires_at: expiresAt,
                created_at: new Date(),
                used_at: null,
                rotation_count: 0
            }),
            'createRefreshToken'
        );
        
        logger.info('[REFRESH TOKEN] Generated refresh token', { expiresInDays });
        logger.debug('[REFRESH TOKEN] Token created', { clientId: sanitizeForLog(clientId) });
        
        return token;
    } catch (error) {
        logger.error('[REFRESH TOKEN] Error generating token', error);
        throw error;
    }
}

/**
 * Shared function to find or create a Client record
 * Used by both web (/client/addweb) and native (/token/exchange, /webauthn/authenticate)
 * 
 * @param {string} clientId - UUID generated client-side
 * @param {string} userUuid - User's UUID
 * @param {Object} req - Express request object (for IP, user-agent, etc.)
 * @param {string} [deviceInfo] - Optional device info string (e.g., "PeerWave Client Windows 11 - DESKTOP-PC")
 * @returns {Promise<Object>} Client record with device_id and clientid
 */
async function findOrCreateClient(clientId, userUuid, req, deviceInfo) {
    // Use provided deviceInfo or fall back to user-agent
    const browserString = deviceInfo || req.headers['user-agent'] || 'Unknown Device';
    const userAgent = req.headers['user-agent'] || '';
    const ip = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
    const location = await getLocationFromIp(ip);
    const locationString = location
        ? `${location.city}, ${location.region}, ${location.country} (${location.org})`
        : "Location not found";
    
    // First, check if this clientId exists (regardless of owner)
    const existingClient = await Client.findOne({ where: { clientid: clientId } });
    
    if (existingClient && existingClient.owner !== userUuid) {
        // SECURITY: Client ID belongs to a different user
        // This can happen if the client app doesn't regenerate UUID on account switch
        // We must delete ALL server-side data for this client before transferring ownership
        // to prevent User Y from accessing User X's encrypted messages/keys
        
        const oldOwner = existingClient.owner;
        const oldDeviceId = existingClient.device_id;
        
        logger.warn('[CLIENT] Ownership conflict', {
            clientId: sanitizeForLog(clientId),
            currentOwner: sanitizeForLog(oldOwner),
            newOwner: sanitizeForLog(userUuid)
        });
        logger.warn('[CLIENT] Deleting all server-side data', { deviceId: oldDeviceId, oldOwner: sanitizeForLog(oldOwner) });
        
        // Delete all messages and read receipts for this device by the old owner
        const [itemsDeleted, groupItemsDeleted, readReceiptsDeleted] = await Promise.all([
            Item.destroy({ 
                where: { 
                    [Op.or]: [
                        { sender: oldOwner, deviceSender: oldDeviceId },
                        { receiver: oldOwner, deviceReceiver: oldDeviceId }
                    ]
                } 
            }),
            GroupItem.destroy({ 
                where: { 
                    sender: oldOwner,
                    senderDevice: oldDeviceId 
                } 
            }),
            GroupItemRead.destroy({
                where: {
                    userId: oldOwner,
                    deviceId: oldDeviceId
                }
            })
        ]);
        
        logger.warn('[CLIENT] Deleted messages', { itemsDeleted, groupItemsDeleted, readReceiptsDeleted });
        
        // Delete all Signal protocol keys (prevents decryption of old messages)
        const [preKeysDeleted, signedPreKeysDeleted, senderKeysDeleted, sessionsDeleted] = await Promise.all([
            SignalPreKey.destroy({ where: { client: clientId } }),
            SignalSignedPreKey.destroy({ where: { client: clientId } }),
            SignalSenderKey.destroy({ where: { client: clientId } }),
            ClientSession.destroy({ where: { client_id: clientId } })
        ]);
        
        logger.warn('[CLIENT] Deleted Signal protocol keys', { preKeysDeleted, signedPreKeysDeleted, senderKeysDeleted, sessionsDeleted });
        
        // Get max device_id for new owner
        const maxDevice = await Client.max('device_id', { where: { owner: userUuid } });
        
        // Transfer ownership with new device_id
        await writeQueue.enqueue(
            () => Client.update(
                { 
                    owner: userUuid,
                    device_id: maxDevice ? maxDevice + 1 : 1,
                    ip: ip,
                    browser: browserString,
        // Reload to get updated values
        await existingClient.reload();
        
        logger.info('[CLIENT] Ownership transferred');
        logger.debug('[CLIENT] Ownership transferred', {
            newOwner: sanitizeForLog(userUuid),
            deviceId: existingClient.device_id
        });
        
        return {
            client: existingClient,
            created: false,
            ownershipTransferred: true,
            device_id: existingClient.device_id,
            clientid: existingClient.clientid
        };
    }
    
    // Get max device_id for this user and auto-increment
    const maxDevice = await Client.max('device_id', { where: { owner: userUuid } });
    
    // Find existing client or create new one (scoped to correct owner)
    const [client, created] = await Client.findOrCreate({
        where: { clientid: clientId },
        defaults: {
            owner: userUuid,
            clientid: clientId,
            ip: ip,
            browser: browserString,
            location: locationString,
            device_id: maxDevice ? maxDevice + 1 : 1
        }
    });
    
    // Update metadata if client already exists
    if (!created) {
        await writeQueue.enqueue(
            () => Client.update(
                { ip, browser: browserString, location: locationString },
                { where: { clientid: clientId } }
            ),
            'updateClientInfo'
        );
    }
    
    logger.info(`[CLIENT] ${created ? 'Created' : 'Found'} client`);
    logger.debug(`[CLIENT] ${created ? 'Created' : 'Found'} client`, {
        clientId: sanitizeForLog(clientId),
        deviceId: client.device_id
    });
    
    return {
        client,
        created,
        ownershipTransferred: false,
        device_id: client.device_id || (client.get ? client.get('device_id') : undefined),
        clientid: client.clientid || (client.get ? client.get('clientid') : undefined)
    };
}

class AppError extends Error {
    constructor(message, code, email = "") {
        super(message);
        this.code = code;
        this.email = email;
    }
}

function generateBackupCodes(count = 10) {
    const codes = [];
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    for (let i = 0; i < count; i++) {
        // 16-stelliger alphanumerischer Code
        let code = '';
        for (let j = 0; j < 16; j++) {
            code += chars.charAt(Math.floor(Math.random() * chars.length));
        }
        codes.push(code);
    }
    return codes;
}

// Hashen und Speichern (DB oder Session)
async function saveBackupCodes(email, codes) {
    const hashedCodes = await Promise.all(codes.map(async code => {
        const hash = await bcrypt.hash(code, 10);
        return { codeHash: hash, used: false };
    }));

    // Beispiel: in DB speichern
    await writeQueue.enqueue(
        () => User.update(
            { backupCodes: JSON.stringify(hashedCodes) },
            { where: { email: email } }
        ),
        'saveBackupCodes'
    );

    return codes; // Nur einmalig dem User zeigen!
}

async function verifyBackupCode(email, enteredCode) {
    const user = await User.findOne({ where: { email: email } });

    if (!user || !user.backupCodes) return false;

    let codes = JSON.parse(user.backupCodes);

    for (let codeObj of codes) {
        if (!codeObj.used && await bcrypt.compare(enteredCode, codeObj.codeHash)) {
            // Code gültig → markieren als verbraucht
            codeObj.used = true;

            await writeQueue.enqueue(
                () => User.update(
                    { backupCodes: JSON.stringify(codes) },
                    { where: { email: email } }
                ),
                'verifyBackupCode'
            );

            return true; // Erfolg
        }
    }

    return false; // Kein Treffer
}

// Rate limiters for security-sensitive endpoints
const tokenExchangeLimiter = rateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    max: 5, // 5 requests per IP per window
    message: { error: 'Too many token exchange attempts, please try again later' },
    standardHeaders: true,
    legacyHeaders: false,
    // Use clientId as key for better tracking
    keyGenerator: (req) => {
        return req.body.clientId || req.ip;
    }
});

const tokenRevocationLimiter = rateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    max: 10, // 10 revocations per IP per window
    message: { error: 'Too many revocation attempts, please try again later' },
    standardHeaders: true,
    legacyHeaders: false,
});

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

// Helper functions for URL-safe base64 encoding and decoding
function base64UrlEncode(buffer) {
    let result = btoa(String.fromCharCode(...new Uint8Array(buffer)))
        .replace(/\+/g, '-')
        .replace(/\//g, '_');
    
    // Remove padding - base64 only has 0-2 trailing '=' chars
    // Using while loop to avoid ReDoS vulnerability
    while (result.endsWith('=')) {
        result = result.slice(0, -1);
    }
    return result;
}

function base64UrlDecode(base64) {
    if (typeof base64 !== 'string') {
        throw new TypeError('Expected input to be a string but type was: ' + typeof base64);
    }
    base64 = base64
        .replace(/-/g, '+')
        .replace(/_/g, '/');
    // Pad with '=' to make the length a multiple of 4
    while (base64.length % 4) {
        base64 += '=';
    }
    return Uint8Array.from(atob(base64), c => c.charCodeAt(0)).buffer;
}

function uuidToArrayBuffer(uuidStr) {
    // UUID ohne Bindestriche
    const hex = uuidStr.replace(/-/g, "");
    const bytes = new Uint8Array(16);
    for (let i = 0; i < 16; i++) {
        bytes[i] = parseInt(hex.substr(i * 2, 2), 16);
    }
    return bytes.buffer;
}

const fido2 = new Fido2Lib({
    timeout: 60000,
    challengeSize: 32,
    attestation: "none",
    cryptoParams: [-7, -257],
});

// Only create transporter if SMTP is configured
const transporter = config.smtp ? nodemailer.createTransport(config.smtp) : null;

const authRoutes = express.Router();

/*const sequelize = new Sequelize({
    dialect: 'sqlite',
    storage: process.env.DB_PATH || './data/peerwave.sqlite',
});

const temporaryStorage = new Sequelize({
    dialect: 'sqlite',
    storage: ':memory:'
});

sequelize.authenticate()
    .then(() => {
        console.log('Connection to SQLite database has been established successfully.');
    })
    .catch(error => {
        console.error('Unable to connect to the database:', error);
    });

    temporaryStorage.authenticate()
    .then(() => {
        console.log('Connection to temp SQLite database has been established successfully.');
    })
    .catch(error => {
        console.error('Unable to connect to the temp database:', error);
    });

// Define User model
const User = sequelize.define('User', {
    email: {
        type: DataTypes.STRING,
        allowNull: false,
        unique: true
    },
    verified: {
        type: DataTypes.BOOLEAN,
        allowNull: false,
        defaultValue: false
    },
    displayName: {
        type: DataTypes.STRING,
        allowNull: true,
        unique: true
    },
    credentials: {
        type: DataTypes.TEXT,
        allowNull: true
    },
    uuid: {
        type: DataTypes.UUID,
        defaultValue: Sequelize.UUIDV4,
        primaryKey: true,
        allowNull: false,
        unique: true
    },
    picture: {
        type: DataTypes.BLOB,
        allowNull: true
    },
});

// Define client model
const Client = sequelize.define('Client', {
    owner: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Users',
            key: 'uuid'
        }
    },
    clientid: {
        type: DataTypes.STRING,
        allowNull: false,
        unique: true
    }
});

// Define public key model
const PublicKey = sequelize.define('PublicKey', {
    owner: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Users', // Name of the referenced table
            key: 'uuid' // Primary key in the referenced table
        }
    },
    credential: {
        type: DataTypes.TEXT,
        allowNull: false
    },
    reciever: {
        type: DataTypes.UUID,
        allowNull: true,
        references: {
            model: 'Users', // Name of the referenced table
            key: 'uuid' // Primary key in the referenced table
        }
    },
    channel: {
        type: DataTypes.STRING,
        allowNull: true,
        references: {
            model: 'Channel', // Name of the referenced table
            key: 'name' // Primary key in the referenced table
        }
    }
});
// Define OTP model
const OTP = temporaryStorage.define('OTP', {
    email: {
        type: DataTypes.STRING,
        allowNull: false
    },
    otp: {
        type: DataTypes.INTEGER,
        allowNull: false
    },
    expiration: {
        type: DataTypes.DATE,
        allowNull: false
    }
});
// define Channel model
const Channel = sequelize.define('Channel', {
    name: {
        type: DataTypes.STRING,
        primaryKey: true,
        allowNull: false,
        unique: true
    },
    description: {
        type: DataTypes.STRING,
        allowNull: true
    },
    private: {
        type: DataTypes.BOOLEAN,
        allowNull: false,
        defaultValue: false
    },
    owner: {
        type: DataTypes.STRING,
        allowNull: false,
    },
    members: {
        type: DataTypes.TEXT,
        allowNull: true
    },
    type: {
        type: DataTypes.STRING,
        allowNull: false,
        defaultValue: "text"
    },
    keys: {
        type: DataTypes.TEXT,
        allowNull: true
    }
});
const Thread = sequelize.define('Thread', {
    id: {
        type: DataTypes.INTEGER,
        autoIncrement: true,
        primaryKey: true,
        allowNull: false
    },
    parent: {
        type: DataTypes.INTEGER,
        allowNull: true,
        defaultValue: null
    },
    message: {
        type: DataTypes.TEXT,
        allowNull: false
    },
    sender: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Users', // Name of the referenced table
            key: 'uuid' // Primary key in the referenced table
        }
    },
    channel: {
        type: DataTypes.STRING,
        allowNull: false
    }
});

const Emote = sequelize.define('Emotes', {
    id: {
        type: DataTypes.INTEGER,
        autoIncrement: true,
        primaryKey: true,
        allowNull: false
    },
    sender: {
        type: DataTypes.STRING,
        allowNull: false
    },
    thread: {
        type: DataTypes.INTEGER,
        allowNull: false
    },
    emote: {
        type: DataTypes.STRING,
        allowNull: false
    }
});

User.hasMany(Thread, { foreignKey: 'sender' });
Channel.hasMany(Thread, { foreignKey: 'channel' });
Thread.hasMany(Emote, { foreignKey: 'thread' });
Thread.belongsTo(User, { as: 'user', foreignKey: 'sender' });
User.hasMany(PublicKey, { foreignKey: 'owner' });
User.hasMany(PublicKey, { foreignKey: 'reciever' });
Channel.hasMany(PublicKey, { foreignKey: 'channel' });
User.hasMany(Client, { foreignKey: 'owner' });

// Create the User table in the database
User.sync({ alter: true })
    .then(() => {
        logger.info('[AUTH] User table synced successfully');
    })
    .catch(error => {
        logger.error('[AUTH] Error syncing User table', error);
    });

// Create the OTP table in the database
OTP.sync({ alter: true })
    .then(() => {
        logger.info('[AUTH] OTP table synced successfully');
    })
    .catch(error => {
        logger.error('[AUTH] Error syncing OTP table', error);
    });

// Create the Channel table in the database
Channel.sync({ alter: true })
    .then(() => {
        logger.info('[AUTH] Channel table synced successfully');
    })
    .catch(error => {
        logger.error('[AUTH] Error syncing Channel table', error);
    });

// Create the Thread table in the database
Thread.sync({ alter: true })
    .then(() => {
        logger.info('[AUTH] Thread table synced successfully');
    })
    .catch(error => {
        logger.error('[AUTH] Error syncing Thread table', error);
    });

// Create the Emote table in the database
Emote.sync({ alter: true })
    .then(() => {
        logger.info('[AUTH] Emote table synced successfully');
    })
    .catch(error => {
        logger.error('[AUTH] Error syncing Emote table', error);
    });

// Create the PublicKey table in the database
PublicKey.sync({ alter: true })
    .then(() => {
        logger.info('[AUTH] PublicKey table synced successfully');
    })
    .catch(error => {
        logger.error('[AUTH] Error syncing PublicKey table', error);
    });

// Create the Client table in the database
Client.sync({ alter: true })
    .then(() => {
        logger.info('[AUTH] Client table synced successfully');
    })
    .catch(error => {
        logger.error('[AUTH] Error syncing Client table', error);
    });
*/
// Add body-parser middleware
authRoutes.use(bodyParser.urlencoded({ 
    extended: true,
    verify: (req, res, buf) => {
        req.rawBody = buf;
    }
}));
authRoutes.use(bodyParser.json({
    verify: (req, res, buf) => {
        req.rawBody = buf;
    }
}));

// Configure session middleware
authRoutes.use(session({
    secret: config.session.secret, // Replace with a strong secret key
    resave: config.session.resave,
    saveUninitialized: config.session.saveUninitialized,
    cookie: config.cookie // Set to true if using HTTPS
}));

// REMOVED: Pug register route (Pug disabled, Flutter web client used)
authRoutes.post("/register", async (req, res) => {

    const email = req.body.email;
    const invitationToken = req.body.invitationToken; // Optional invitation token
    req.session.email = email; // Store email in session for later use
    req.session.registrationStep = 'otp'; // Track registration progress

    if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
        return res.status(400).json({ error: "Invalid email address" });
    }

    try {
        // Check server registration settings
        const { ServerSettings, Invitation } = require('../db/model');
        const settings = await ServerSettings.findOne({ where: { id: 1 } });
        
        if (settings) {
            const registrationMode = settings.registration_mode || 'open';
            
            // Handle email_suffix mode
            if (registrationMode === 'email_suffix') {
                const allowedSuffixes = JSON.parse(settings.allowed_email_suffixes || '[]');
                if (allowedSuffixes.length > 0) {
                    const emailDomain = email.split('@')[1];
                    const isAllowed = allowedSuffixes.some(suffix => 
                        emailDomain.endsWith(suffix)
                    );
                    
                    if (!isAllowed) {
                        return res.status(403).json({ 
                            error: "Registration is restricted to specific email domains" 
                        });
                    }
                }
            }
            
            // Handle invitation_only mode
            if (registrationMode === 'invitation_only') {
                if (!invitationToken) {
                    return res.status(403).json({ 
                        error: "An invitation is required to register" 
                    });
                }
                
                // Validate invitation
                const invitation = await Invitation.findOne({
                    where: {
                        email,
                        token: invitationToken,
                        used: false,
                        expires_at: {
                            [Op.gt]: new Date()
                        }
                    }
                });
                
                if (!invitation) {
                    return res.status(403).json({ 
                        error: "Invalid or expired invitation" 
                    });
                }
                
                // Mark invitation as used (will be finalized after email verification)
                req.session.pendingInvitationId = invitation.id;
            }
        }

        User.findOrCreate({ where: { email } })
            .then(([user, created]) => {
                if (!created && (user.verified == true && !user.credentials && user.backupCodes != "")) {
                return res.status(400).json({ error: "Email already registered. Try logging in instead or starting the recovery process." });
            }
            const otp = Math.floor(10000 + Math.random() * 90000); // Generate a 5-digit OTP
            const email = user.email; // Get the registered email

            OTP.findOne({ where: { email } }).then(existingOtp => {
                if (existingOtp && existingOtp.expiration > Date.now()) {
                    const remainingTime = Math.ceil((existingOtp.expiration - Date.now()) / 1000);
                    const minWaitTime = config.otp.waitTimeMinutes * 60;
                    // Only enforce wait if OTP was created less than waitTime ago
                    if (remainingTime > (config.otp.expirationMinutes - config.otp.waitTimeMinutes) * 60) {
                        return res.status(200).json({ status: "waitotp", wait: remainingTime });
                    }
                    // Wait time passed, allow creating new OTP (old one will be replaced)
                } else {
                    // Send email with OTP (if SMTP is configured)
                    if (transporter) {
                        transporter.sendMail({
                            from: config.smtp.senderadress,
                            to: email,
                            subject: "Your One-Time Password (OTP)",
                            html: `
                              <div style="font-family:'Nunito Sans', system-ui, -apple-system, sans-serif; background-color:#0f1419; padding:40px 16px; color:#d6dde3;">
                                <div style="max-width:600px; margin:0 auto; background-color:#141b22; border-radius:12px; padding:32px; box-shadow:0 0 0 1px rgba(0, 188, 212, 0.08);">
                                  <h2 style="margin-top:0; color:#2dd4bf; font-weight:600; letter-spacing:0.3px;">Your Verification Code</h2>
                                  <p style="color:#cbd5dc; line-height:1.6;">Enter this code to verify your account:</p>
                                  <div style="margin:32px 0; padding:24px; background-color:#0f1419; border-radius:10px; border:2px solid rgba(45, 212, 191, 0.3); text-align:center;">
                                    <div style="font-size:42px; font-weight:700; letter-spacing:12px; color:#2dd4bf; font-family:'Courier New', monospace;">${otp}</div>
                                  </div>
                                  <div style="margin:24px 0; padding:16px; background-color:#0f1419; border-radius:8px; border:1px solid rgba(255,255,255,0.06);">
                                    <p style="margin:0; color:#9fb3bf; font-size:14px; line-height:1.6;">
                                      <strong style="color:#f59e0b;">⚠️ Security Notice:</strong><br>
                                      This code expires in <strong style="color:#2dd4bf;">${config.otp.expirationMinutes} minutes</strong>. Never share this code with anyone.
                                    </p>
                                  </div>
                                  <hr style="border:none; border-top:1px solid rgba(255,255,255,0.06); margin:32px 0;">
                                  <p style="font-size:12px; color:#6b7c86; margin:0;">Sent from PeerWave<br><a href="https://peerwave.org" style="text-decoration: none; display: flex; align-items: center;"><img src="https://peerwave.org/logo_28.png" style="width:24px;height:24px;padding-right: 0.25rem;"/><span style="color:white;">PeerWave</span><span style="color:#4fbfb3;"> - Private communication you fully control.</span></a></p>
                                </div>
                              </div>
                            `,
                            text: `Your OTP is ${otp}. This code expires in ${config.otp.expirationMinutes} minutes.`
                        }).then(info => {
                            logger.info('[OTP] Email sent', { messageId: info.messageId });
                        }).catch(error => {
                            logger.error('[OTP] Error sending email', error);
                        });
                    } else {
                        logger.warn('[OTP] SMTP not configured - email not sent');
                    }


                    // Save the OTP and email in temporary storage
                    const expiration = new Date().getTime() + config.otp.expirationMinutes * 60 * 1000;
                    writeQueue.enqueue(
                        () => OTP.create({ email, otp, expiration }),
                        'createOTP'
                    )
                    .then(otp => {
                        logger.info('[OTP] Created successfully');
                        logger.debug('[OTP] Created', { email: otp.email });
                        req.session.email = otp.email;
                        res.status(200).json({ status: "otp", wait: Math.ceil((otp.expiration - Date.now()) / 1000) });
                    }).catch(error => {
                        logger.error('[OTP] Error creating OTP', error);
                    });

                    // Store the temporary storage in a database or cache
                    // For example, you can use Redis or a database table to store the temporary storage
                    // Make sure to handle the expiration and cleanup of expired OTPs
                    // Render the otp form
                        }
            });

            
        })
        .catch(error => {
            logger.error('[AUTH] Error creating user', error);
            res.status(500).json({ error: "Error on creating user" });
        });
        
    } catch (error) {
        logger.error('[AUTH] Error in registration', error);
        res.status(500).json({ error: "Internal server error" });
    }

});

authRoutes.post("/otp", (req, res) => {
    const { email, otp } = req.body;
    OTP.findOne({ where: { email: email, otp: otp } }).then(async otp => {
        if(!otp) {
            return res.status(400).json({ error: "Invalid OTP" });
        } else if (otp.expiration < Date.now()) {
            return res.status(400).json({ error: "OTP expired. Please request a new one." });
        } else {
            await writeQueue.enqueue(
                () => OTP.destroy({ where: { email: email } }),
                'destroyOTP'
            );
            await writeQueue.enqueue(
                () => User.update({ verified: true }, { where: { email: email } }),
                'verifyUser'
            );
            const updatedUser = await User.findOne({ where: { email } });
            
            // Auto-assign roles based on email and configuration
            await autoAssignRoles(email, updatedUser.uuid);
            
            // Mark invitation as used if registration was via invitation
            if (req.session.pendingInvitationId) {
                const { Invitation } = require('../db/model');
                await writeQueue.enqueue(
                    () => Invitation.update(
                        { used: true, used_at: new Date() },
                        { where: { id: req.session.pendingInvitationId } }
                    ),
                    'markInvitationUsed'
                );
                delete req.session.pendingInvitationId;
                logger.info('[INVITATION] Marked invitation as used');
                logger.debug('[INVITATION] Invitation used', { email: sanitizeForLog(email) });
            }
            
            req.session.otp = true;
            req.session.authenticated = true;
            req.session.uuid = updatedUser.uuid; // ensure uuid present
            req.session.email = updatedUser.email; // Store email for backup codes
            // Update registration step based on user status
            if (!updatedUser.backupCodes) {
                req.session.registrationStep = 'backup_codes';
            } else {
                req.session.registrationStep = 'complete';
            }
            // Optional: attach client info immediately if provided
            const clientId = req.body && req.body.clientId;
            if (clientId) {
                const maxDevice = await Client.max('device_id', { where: { owner: updatedUser.uuid } });
                const [client] = await Client.findOrCreate({
                    where: { owner: updatedUser.uuid, clientid: clientId },
                    defaults: { owner: updatedUser.uuid, clientid: clientId, device_id: maxDevice ? maxDevice + 1 : 1 }
                });
                req.session.deviceId = client.device_id || (client.get ? client.get('device_id') : undefined);
                req.session.clientId = client.clientid || (client.get ? client.get('clientid') : undefined);
            }
            return req.session.save(err => {
                if (err) {
                    logger.error('[AUTH] Session save error (/otp)', err);
                    return res.status(500).json({ status: "error", message: "Session save error" });
                }
                if(!updatedUser.backupCodes) {
                    res.status(202).json({ status: "ok", message: "Authentication successful" });
                } else {
                    res.status(200).json({ status: "ok", message: "Authentication successful" });
                }
            });
        }
    }).catch(error => {
        logger.error('[AUTH] Error finding OTP', error);
        res.status(400).json({ error: "Invalid OTP" });
    });
});

authRoutes.get("/backupcode/list", async(req, res) => {
    if (!req.session.authenticated) {
        return res.status(401).json({ error: "Unauthorized" });
    }
    try {
        const user = await User.findOne({ where: { email: req.session.email } });
        if (!user) {
            return res.status(404).json({ error: "User not found" });
        }
        if(user.backupCodes) {
            return res.status(400).json({ error: "Backup codes already generated" });
        }
        
        const backupCodes = generateBackupCodes();
        await saveBackupCodes(user.email, backupCodes);
        req.session.registrationStep = 'webauthn';
        res.status(200).json({ status: "ok", backupCodes: backupCodes });

    } catch (error) {
        logger.error('[AUTH] Error fetching backup codes', error);
        res.status(500).json({ error: "Internal server error" });
    }
});

authRoutes.get("/backupcode/usage", sessionLimiter, verifyAuthEither, async(req, res) => {
    try {
        const user = await User.findOne({ where: { uuid: req.userId } });
        if (!user) {
            return res.status(404).json({ error: "User not found" });
        }
        if(!user.backupCodes) {
            return res.status(400).json({ error: "No backup codes generated" });
        }
        const codes = JSON.parse(user.backupCodes);
        const usedCount = codes.filter(code => code.used).length;
        const totalCount = codes.length;

        res.status(200).json({ status: "ok", usedCount, totalCount });
    } catch (error) {
        logger.error('[AUTH] Error fetching backup code usage', error);
        res.status(500).json({ error: "Internal server error" });
    }
});

authRoutes.post("/backupcode/verify", async(req, res) => {
    const { code } = req.body;
    if (!req.session.email) {
        return res.status(401).json({ error: "Unauthorized" });
    }
    try {
        const email = req.session.email;
        // Brute-force protection: Store failed attempts and wait time in session
        if (!req.session.backupCodeBrute) {
            req.session.backupCodeBrute = { count: 0, waitUntil: 0 };
        }
        const now = Date.now();
        if (req.session.backupCodeBrute.waitUntil && now < req.session.backupCodeBrute.waitUntil) {
            const waitSeconds = Math.ceil((req.session.backupCodeBrute.waitUntil - now) / 1000);
            return res.status(429).json({ status: "wait", message: waitSeconds });
        }
    const valid = await verifyBackupCode(email, code);
        if (!valid) {
            // Increase brute-force counter and wait time
            req.session.backupCodeBrute.count = (req.session.backupCodeBrute.count || 0) + 1;
            let waitTime = 60 * Math.pow(1.8, req.session.backupCodeBrute.count - 1); // in seconds
            waitTime = Math.ceil(waitTime);
            req.session.backupCodeBrute.waitUntil = now + waitTime * 1000;
            return res.status(429).json({ status: "wait", message: waitTime });
        } else {
            // Reset brute-force counter on success
            req.session.backupCodeBrute = { count: 0, waitUntil: 0 };
            // Find user to set uuid in session
            const user = await User.findOne({ where: { email } });
            req.session.authenticated = true;
            req.session.uuid = user.uuid;
            // Optional: set client if provided
            const clientId = req.body && req.body.clientId;
            if (clientId) {
                const maxDevice = await Client.max('device_id', { where: { owner: user.uuid } });
                const [client] = await Client.findOrCreate({
                    where: { owner: user.uuid, clientid: clientId },
                    defaults: { owner: user.uuid, clientid: clientId, device_id: maxDevice ? maxDevice + 1 : 1 }
                });
                req.session.deviceId = client.device_id || (client.get ? client.get('device_id') : undefined);
                req.session.clientId = client.clientid || (client.get ? client.get('clientid') : undefined);
            }
            return req.session.save(err => {
                if (err) {
                    logger.error('[AUTH] Session save error (/backupcode/verify)', err);
                    return res.status(500).json({ status: "error", message: "Session save error" });
                }
                res.status(200).json({ status: "ok", message: "Backup code verified successfully" });
            });
        }
    } catch (error) {
        logger.error('[AUTH] Error verifying backup code', error);
        res.status(500).json({ error: "Internal server error" });
    }
});

authRoutes.post("/backupcode/mobile-verify", sessionLimiter, async(req, res) => {
    const { email, backupCode, clientId } = req.body;
    
    if (!email || !backupCode) {
        return res.status(400).json({ error: "Email and backup code are required" });
    }
    
    try {
        logger.info('[BACKUPCODE MOBILE] Login attempt');
        logger.debug('[BACKUPCODE MOBILE] Login attempt', { email: sanitizeForLog(email) });
        
        // Brute-force protection: Store failed attempts in session
        if (!req.session.backupCodeBrute) {
            req.session.backupCodeBrute = { count: 0, waitUntil: 0 };
        }
        
        const now = Date.now();
        if (req.session.backupCodeBrute.waitUntil && now < req.session.backupCodeBrute.waitUntil) {
            const waitSeconds = Math.ceil((req.session.backupCodeBrute.waitUntil - now) / 1000);
            return res.status(429).json({ status: "wait", message: `Too many attempts. Wait ${waitSeconds} seconds.` });
        }
        
        // Verify backup code
        const valid = await verifyBackupCode(email, backupCode);
        
        if (!valid) {
            // Increase brute-force counter and wait time
            req.session.backupCodeBrute.count = (req.session.backupCodeBrute.count || 0) + 1;
            let waitTime = 60 * Math.pow(1.8, req.session.backupCodeBrute.count - 1); // in seconds
            waitTime = Math.ceil(waitTime);
            req.session.backupCodeBrute.waitUntil = now + waitTime * 1000;
            return res.status(401).json({ status: "error", message: "Invalid backup code" });
        }
        
        // Reset brute-force counter on success
        req.session.backupCodeBrute = { count: 0, waitUntil: 0 };
        
        // Find user
        const user = await User.findOne({ where: { email } });
        if (!user) {
            return res.status(404).json({ error: "User not found" });
        }
        
        // Set session as authenticated
        req.session.authenticated = true;
        req.session.email = email;
        req.session.uuid = user.uuid;
        
        // Set user as active
        await writeQueue.enqueue(
            () => User.update(
                { active: true },
                { where: { uuid: user.uuid } }
            ),
            'setUserActiveOnBackupCodeAuth'
        );
        
        // Auto-assign admin role if configured
        if (user.verified && config.admin && config.admin.includes(email)) {
            await autoAssignRoles(email, user.uuid);
        }
        
        // Create HMAC session for mobile clients (same as WebAuthn)
        let sessionSecret = null;
        
        if (clientId) {
            // Use shared function to find or create client
            const deviceInfo = req.body && req.body.deviceInfo;
            const result = await findOrCreateClient(clientId, user.uuid, req, deviceInfo);
            req.session.deviceId = result.device_id;
            req.session.clientId = result.clientid;
            
            // Generate session secret for HMAC authentication
            sessionSecret = crypto.randomBytes(32).toString('base64url');
            const userAgent = req.headers['user-agent'] || '';
            const ip = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
            const location = await getLocationFromIp(ip);
            const locationString = location 
                ? `${location.city}, ${location.region}, ${location.country} (${location.org})`
                : "Location not found";
            
            // Store session in database with configurable expiration
            try {
                const sessionDays = config.session.hmacSessionDays || 90;
                await writeQueue.enqueue(
                    () => sequelize.query(
                        `INSERT OR REPLACE INTO client_sessions 
                         (client_id, session_secret, user_id, device_id, device_info, expires_at, last_used, created_at)
                         VALUES (?, ?, ?, ?, ?, datetime('now', '+' || ? || ' days'), datetime('now'), datetime('now'))`,
                        { 
                            replacements: [
                                clientId, 
                                sessionSecret, 
                                user.uuid,
                                result.device_id, 
                                JSON.stringify({ userAgent, ip, location: locationString }),
                                sessionDays
                            ] 
                        }
                    ),
                    'createBackupCodeMobileSession'
                );
                logger.info('[BACKUPCODE MOBILE] HMAC session created', { sessionDays });
                logger.debug('[BACKUPCODE MOBILE] HMAC session created', { clientId: sanitizeForLog(clientId), sessionDays });
            } catch (sessionErr) {
                logger.error('[BACKUPCODE MOBILE] Error creating HMAC session', sessionErr);
            }
            
            // Generate refresh token for mobile clients
            try {
                const refreshToken = await generateRefreshToken(clientId, user.uuid);
                // Store for response (added below)
                response.refreshToken = refreshToken;
            } catch (refreshErr) {
                logger.error('[BACKUPCODE MOBILE] Error generating refresh token', refreshErr);
                // Continue anyway - session still works without refresh token
            }
        }
        
        // Save session and return response
        return req.session.save(err => {
            if (err) {
                logger.error('[BACKUPCODE MOBILE] Session save error', err);
                return res.status(500).json({ status: "error", message: "Session save error" });
            }
            
            const response = {
                status: "ok",
                message: "Backup code verified successfully"
            };
            
            // Include HMAC credentials for mobile clients
            if (sessionSecret) {
                response.sessionSecret = sessionSecret;
                response.userId = user.uuid;
                response.email = email;
                if (response.refreshToken) {
                    logger.info('[BACKUPCODE MOBILE] Login successful with refresh token');
                } else {
                    logger.info('[BACKUPCODE MOBILE] Login successful');
                }
                logger.debug('[BACKUPCODE MOBILE] Login successful', { email: sanitizeForLog(email) });
            }
            
            res.status(200).json(response);
        });
        
    } catch (error) {
        logger.error('[BACKUPCODE MOBILE] Error', error);
        res.status(500).json({ error: "Internal server error" });
    }
});

authRoutes.post("/backupcode/regenerate", sessionLimiter, verifyAuthEither, async(req, res) => {
    try {
        const user = await User.findOne({ where: { uuid: req.userId } });
        if (!user) {
            return res.status(404).json({ error: "User not found" });
        }
        if(user.backupCodes) {
            backupCodes = JSON.parse(user.backupCodes);
            const usedCount = backupCodes.filter(code => code.used).length;
            if(usedCount > backupCodes.length - 2) {
                user.backupCodes = null;
                await writeQueue.enqueue(
                    () => user.save(),
                    'regenerateBackupCodes'
                );
                return res.status(200).json({ status: "ok", message: "You can now generate new backup codes." });
            } else {
                return res.status(400).json({ error: "You can only regenerate backup codes if you have used at least 8 of your existing codes." });
            }
        } else {
            return res.status(400).json({ error: "No backup codes to regenerate. You can generate new backup codes." });
        }        
    } catch (error) {
        logger.error('[AUTH] Error regenerating backup codes', error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// POST logout route - destroys session and clears cookie
authRoutes.post("/logout", async (req, res) => {
    // Support both HMAC (native) and Session (web) authentication
    const userId = req.userId || req.session.uuid;
    const deviceId = req.deviceId || req.session.deviceId;
    const clientId = req.clientId || req.session.clientId;
    
    logger.info('[AUTH] Logout request');
    logger.debug('[AUTH] Logout request', { userId: sanitizeForLog(userId), deviceId: sanitizeForLog(deviceId) });
    
    // If HMAC auth (native client), delete the HMAC session from database
    if (req.userId && clientId) {
        try {
            await sequelize.query(
                'DELETE FROM client_sessions WHERE client_id = ?',
                { replacements: [clientId] }
            );
            logger.info('[AUTH] HMAC session deleted');
            logger.debug('[AUTH] HMAC session deleted', { clientId: sanitizeForLog(clientId) });
            return res.json({ success: true, message: 'Logged out successfully' });
        } catch (error) {
            logger.error('[AUTH] Error deleting HMAC session', error);
            return res.status(500).json({ success: false, error: 'Failed to delete session' });
        }
    }
    
    // If Session auth (web client), destroy the session
    req.session.destroy((err) => {
        if (err) {
            logger.error('[AUTH] Error destroying session', err);
            return res.status(500).json({ success: false, error: 'Failed to destroy session' });
        }
        
        // Clear the session cookie
        res.clearCookie('connect.sid', {
            path: '/',
            httpOnly: true,
            secure: process.env.NODE_ENV === 'production',
            sameSite: 'strict'
        });
        
        logger.info('[AUTH] Session destroyed');
        logger.debug('[AUTH] Session destroyed', { userId: sanitizeForLog(userId), deviceId: sanitizeForLog(deviceId) });
        res.json({ success: true, message: 'Logged out successfully' });
    });
});

/*
// GET logout route (legacy, commented out)
authRoutes.get("/logout", (req, res) => {
    // Perform logout logic
    res.redirect("/");
});
*/

// Implement delete account route
authRoutes.post("/delete-account", (req, res) => {
    // Perform delete account logic
    res.send("Account deleted");
});

// Implement webauthn registration route
/*authRoutes.post("/webauthn/register", (req, res) => {
    // Perform webauthn registration logic
    res.send("WebAuthn registration successful");
});*/


// Generate registration challenge
authRoutes.post('/webauthn/register-challenge', sessionLimiter, async (req, res) => {
    // Support both authenticated users adding credentials (req.userId from middleware)
    // and users in registration flow (req.session.email)
    let user;
    if (req.userId) {
        // HMAC or session authenticated user adding additional credential
        user = await User.findOne({ where: { uuid: req.userId } });
    } else if (req.session.email && typeof req.session.email === 'string') {
        // User in registration flow (OTP verified or during WebAuthn registration step)
        user = await User.findOne({ where: { email: req.session.email } });
    } else {
        return res.status(401).json({ error: "User not authenticated" });
    }
    
    if (!user || !user.uuid) {
        return res.status(400).json({ error: "User not found or missing UUID for WebAuthn registration." });
    }
    let uuidArrayBuffer;
    try {
        uuidArrayBuffer = uuidToArrayBuffer(user.uuid);
    } catch (e) {
        return res.status(400).json({ error: "Invalid UUID format for WebAuthn registration." });
    }

    const challenge = await fido2.attestationOptions();

    // Use environment variable for production, fallback to req.hostname for local dev
    const host = process.env.DOMAIN || req.hostname || 'localhost';
    logger.debug('[WEBAUTHN REG] RP ID', { host });
    
    // Allow ngrok and localhost for WebAuthn
    const allowedOrigins = [
        "http://localhost:3000",
        "http://localhost:55831",
        `https://${host}`
    ];
    
    // rpId must be the domain without protocol for WebAuthn validation
    challenge.rp = {
        name: "PeerWave",
        id: host   // Domain only: "app.peerwave.org" or "localhost"
    };

    challenge.user = {
        id: base64UrlEncode(uuidArrayBuffer),
        name: user.email,
        displayName: user.email,
    };

    // Allow both platform (phone fingerprint) and cross-platform (Google Password Manager, YubiKey)
    challenge.authenticatorSelection = {
        // authenticatorAttachment: removed to allow all authenticator types
        userVerification: "preferred",  // Prefer biometric/PIN but allow fallback
        residentKey: "required",  // Require discoverable credentials for passwordless login
        requireResidentKey: false  // Deprecated field, keep false for backwards compatibility
    };

    // Optional: andere Policies
    challenge.attestation = "none"; // oder "direct" je nach Security/Privacy

    challenge.challenge = base64UrlEncode(challenge.challenge);

    req.session.challenge = challenge.challenge;
    res.json(challenge);
});

// Verify registration response
authRoutes.post('/webauthn/register', async (req, res) => {
    // Check if this is during registration flow (first credential)
    const isFirstCredential = req.session.registrationStep === 'webauthn';
    logger.debug('[WEBAUTHN] Registration request', {
        isFirstCredential,
        registrationStep: req.session.registrationStep,
        authenticated: req.session.authenticated
    });
    
    // Support both authenticated users (adding credentials) and users in registration flow
    const isAuthenticated = req.session.authenticated || req.userId; // req.userId set by verifyAuthEither middleware
    const hasSessionEmail = req.session.email;
    const hasOtpVerification = req.session.otp;
    
    if(!hasOtpVerification && !isAuthenticated && !hasSessionEmail) {
        return res.status(400).json({ status: "error", message: "User not authenticated." });
    }
    else {
        try {
            const { attestation } = req.body;

            //const user = await User.findOne({ where: { email: req.session.email } });

            // Convert id and rawId from base64url string to ArrayBuffer
            //attestation.id = new Uint8Array(base64url.toBuffer(attestation.id)).buffer;
            //attestation.rawId = new Uint8Array(base64url.toBuffer(attestation.rawId)).buffer;

            //attestation.id = base64UrlDecode(attestation.id),
            attestation.rawId = base64UrlDecode(attestation.rawId);

            attestation.response.attestationObject = base64UrlDecode(attestation.response.attestationObject),
            attestation.response.clientDataJSON = base64UrlDecode(attestation.response.clientDataJSON);

            //attestation.id = Buffer.from(attestation.id, 'base64');
            //attestation.rawId = Buffer.from(attestation.rawId, 'base64');

            const challenge = base64UrlDecode(req.session.challenge);

            // Use DOMAIN from environment (not req.hostname which can be user-controlled)
            const host = process.env.DOMAIN || req.hostname || 'localhost';
            
            // Decode clientDataJSON to check the actual origin
            const clientData = JSON.parse(Buffer.from(attestation.response.clientDataJSON, 'base64').toString('utf8'));
            const actualOrigin = clientData.origin;
            
            // Allow web origins and Android APK origins
            const allowedOrigins = [
                "http://localhost:3000",
                "http://localhost:55831",
                `https://${host}`
            ];
            
            // Determine origin based on client type
            let origin;
            if (actualOrigin.startsWith('android:apk-key-hash:')) {
                // Native Android app - use the APK key hash from clientDataJSON
                origin = actualOrigin;
            } else {
                // Web or Chrome Custom Tab - use standard origin
                origin = req.headers.origin || `https://${host}`;
                if (!allowedOrigins.includes(origin)) {
                    logger.warn('[WEBAUTHN] Unexpected origin', { origin });
                }
            }

            // Standard WebAuthn validation for all clients
            // rpId is required for validating the RP ID hash in authenticator data
            const attestationExpectations = {
                challenge: challenge,
                origin: origin,
                factor: "either",
                rpId: host,
            };
            const regResult = await fido2.attestationResult(attestation, attestationExpectations);

            // Get user from either userId (HMAC auth) or session email (registration flow)
            let user;
            if (req.userId) {
                user = await User.findOne({ where: { uuid: req.userId } });
            } else {
                user = await User.findOne({ where: { email: req.session.email } });
            }

            if (typeof user.credentials === 'string') {
                user.credentials = JSON.parse(user.credentials);
            }
            if (!Array.isArray(user.credentials)) {

                user.credentials = [];
            }

            // Add browser info, registration time, and empty lastLogin
            const userAgent = req.headers['user-agent'] || '';
            const ip = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
            const now = new Date();
            const pad = n => n.toString().padStart(2, '0');
            const timestamp = `${now.getFullYear()}-${pad(now.getMonth()+1)}-${pad(now.getDate())} ${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;
            const location = await getLocationFromIp(ip);
            // Get transports from attestation, ensuring hybrid is always included for cross-device support
            const transports = attestation.response.transports || ["internal", "hybrid"];
            // Ensure hybrid is always present to enable Google Password Manager and other cross-device options
            if (!transports.includes("hybrid")) {
                transports.push("hybrid");
            }
            
            // Use the credential ID as sent by the client (already base64url encoded)
            // This ensures the ID matches what the authenticator expects in allowCredentials
            user.credentials.push({
                id: attestation.id,
                publicKey: regResult.authnrData.get("credentialPublicKeyPem"),
                transports: transports,
                browser: userAgent,
                createdAt: timestamp,
                location: (location ? `${location.city}, ${location.region}, ${location.country} (${location.org})` : "Location not found"),
                ip: ip,
                lastLogin: ""
            });

            user.credentials = JSON.stringify(user.credentials);

            user.changed('credentials', true);

            await writeQueue.enqueue(
                () => user.save(),
                'saveWebAuthnCredential'
            );

            // Advance registration step to profile if this is during registration
            if (isFirstCredential) {
                req.session.registrationStep = 'profile';
                // Mark session as authenticated so profile setup page is accessible
                req.session.authenticated = true;
                req.session.uuid = user.uuid;
                logger.info('[WEBAUTHN] First credential registered');
                logger.debug('[WEBAUTHN] First credential registered', {
                    uuid: user.uuid,
                    email: user.email,
                    registrationStep: req.session.registrationStep,
                    authenticated: req.session.authenticated
                });
            } else {
                logger.info('[WEBAUTHN] Additional credential registered');
            }
            
            // Handle client info and create HMAC session for mobile (same as authentication)
            const clientId = req.body && req.body.clientId;
            let sessionSecret = null;
            
            if (clientId) {
                // Use shared function to find or create client
                const deviceInfo = req.body && req.body.deviceInfo;
                const result = await findOrCreateClient(clientId, user.uuid, req, deviceInfo);
                
                // Generate session secret for native clients (HMAC authentication)
                sessionSecret = crypto.randomBytes(32).toString('base64url');
                const userAgent = req.headers['user-agent'] || '';
                const registrationIp = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
                const registrationLocation = await getLocationFromIp(registrationIp);
                const locationString = registrationLocation 
                    ? `${registrationLocation.city}, ${registrationLocation.region}, ${registrationLocation.country} (${registrationLocation.org})`
                    : "Location not found";
                
                // Store session in database with configurable expiration
                try {
                    const sessionDays = config.session.hmacSessionDays || 90;
                    await writeQueue.enqueue(
                        () => sequelize.query(
                            `INSERT OR REPLACE INTO client_sessions 
                             (client_id, session_secret, user_id, device_id, device_info, expires_at, last_used, created_at)
                             VALUES (?, ?, ?, ?, ?, datetime('now', '+' || ? || ' days'), datetime('now'), datetime('now'))`,
                            { 
                                replacements: [
                                    clientId, 
                                    sessionSecret, 
                                    user.uuid,
                                    result.device_id, 
                                    JSON.stringify({ userAgent, ip: registrationIp, location: locationString }),
                                    sessionDays
                                ] 
                            }
                        ),
                        'createClientSessionOnRegistration'
                    );
                    logger.info('[WEBAUTHN] HMAC session created on registration', { sessionDays });
                    logger.debug('[WEBAUTHN] HMAC session created', { clientId: sanitizeForLog(clientId), sessionDays });
                } catch (sessionErr) {
                    logger.error('[WEBAUTHN] Error creating HMAC session on registration', sessionErr);
                }
            }
            
            // Return session secret for mobile clients
            const response = { status: "ok" };
            if (sessionSecret) {
                response.sessionSecret = sessionSecret;
                response.userId = user.uuid;
                response.email = user.email;
            }

            res.json(response);
        } catch (error) {
            logger.error('[WEBAUTHN] Error during registration', error);
            res.json({ status: "error" });
        }
    }
});

// Generate authentication challenge
authRoutes.post('/webauthn/authenticate-challenge', async (req, res) => {
    try {
        const { email, fromCustomTab } = req.body;
        req.session.email = email;
        const user = await User.findOne({ where: { email: email } });

        if(!user) {
            throw new AppError("User not found. Please register first.", 404);
        }
        if(!user.credentials && !user.backupCodes) {
            throw new AppError("Account is not verified. Please verify with OTP.", 401, email);
        }
        if (!user.credentials && user.backupCodes) {
            throw new AppError("No credentials found. Please start recovery process.", 400);
        }

        const challenge = await fido2.assertionOptions();

        // Use environment variable for production (most reliable)
        // Fallback to req.hostname for local development
        const host = process.env.DOMAIN || req.hostname || req.get('host')?.split(':')[0] || 'localhost';
        // Check X-Forwarded-Proto for reverse proxy (Nginx, Cloudflare, Traefik)
        // req.secure is often false behind proxies
        const protocol = req.headers['x-forwarded-proto'] || (req.secure ? 'https' : 'http');
        const origin = `${protocol}://${host}`;

        logger.debug('[WEBAUTHN AUTH] RP configuration', {
            host,
            origin,
            protocolSource: req.headers['x-forwarded-proto'] ? 'x-forwarded-proto' : 'req.secure'
        });

        // Validate host is never empty (critical for Google Play Services)
        if (!host || host.trim() === '') {
            logger.error('[WEBAUTHN AUTH] Host is empty - check DOMAIN env variable');
            throw new AppError("Invalid hostname for authentication - server misconfiguration", 500);
        }
        
        // IMPORTANT: Do NOT set challenge.rp for authentication (assertionOptions)
        // rp is ONLY for registration (attestationOptions)
        // WebAuthn spec strictly enforces this requirement

        user.credentials = JSON.parse(user.credentials);

        logger.debug('[WEBAUTHN AUTH] Found credentials', { count: user.credentials.length });

        // Include credential IDs to help browsers and password managers
        // filter to the user's passkeys. Chrome Custom Tab and web clients
        // both benefit from having allowCredentials populated.
        challenge.allowCredentials = user.credentials.map(cred => {
            const transports = cred.transports || ["internal", "hybrid"];
            if (!transports.includes("hybrid")) {
                transports.push("hybrid");
            }
            return {
                id: cred.id,
                type: "public-key",
                transports: transports,
            };
        });
        logger.debug('[WEBAUTHN AUTH] Including credential IDs for authentication');
        
        // Add user verification preference for flexibility
        challenge.userVerification = "preferred";

        challenge.challenge = base64UrlEncode(challenge.challenge);
        req.session.challenge = challenge.challenge;
        
        // Generate and store CSRF state for Custom Tab authentication
        if (fromCustomTab) {
            const { generateState } = require('../utils/jwtHelper');
            const state = generateState();
            req.session.customTabState = state;
            challenge.state = state;
            logger.debug('[CUSTOM TAB AUTH] Generated CSRF state for challenge');
        }
        
        res.json(challenge);
    } catch (error) {
        logger.error('[WEBAUTHN AUTH] Error generating challenge', error);
        if(error.code === 401 && error.email) {
            const otp = Math.floor(100000 + Math.random() * 900000); // Generate a 6-digit OTP
            const email = error.email; // Get the registered email
            
            // Send recovery email (if SMTP is configured)
            if (transporter) {
                transporter.sendMail({
                    from: config.smtp.senderadress,
                    to: email,
                    subject: "Your Recovery Code",
                    html: `
                      <div style="font-family:'Nunito Sans', system-ui, -apple-system, sans-serif; background-color:#0f1419; padding:40px 16px; color:#d6dde3;">
                        <div style="max-width:600px; margin:0 auto; background-color:#141b22; border-radius:12px; padding:32px; box-shadow:0 0 0 1px rgba(0, 188, 212, 0.08);">
                          <h2 style="margin-top:0; color:#f59e0b; font-weight:600; letter-spacing:0.3px;">Account Recovery</h2>
                          <p style="color:#cbd5dc; line-height:1.6;">We received a request to access your account. Use this recovery code to continue:</p>
                          <div style="margin:32px 0; padding:24px; background-color:#0f1419; border-radius:10px; border:2px solid rgba(245, 158, 11, 0.3); text-align:center;">
                            <div style="font-size:42px; font-weight:700; letter-spacing:12px; color:#f59e0b; font-family:'Courier New', monospace;">${otp}</div>
                          </div>
                          <div style="margin:24px 0; padding:16px; background-color:#0f1419; border-radius:8px; border:1px solid rgba(255,255,255,0.06);">
                            <p style="margin:0; color:#9fb3bf; font-size:14px; line-height:1.6;">
                              <strong style="color:#ef4444;">⚠️ Security Alert:</strong><br>
                              This code expires in <strong style="color:#f59e0b;">${config.otp.expirationMinutes} minutes</strong>. If you didn't request this, please ignore this email and secure your account.
                            </p>
                          </div>
                          <hr style="border:none; border-top:1px solid rgba(255,255,255,0.06); margin:32px 0;">
                          <p style="font-size:12px; color:#6b7c86; margin:0;">Sent from PeerWave<br><a href="https://peerwave.org" style="text-decoration: none; display: flex; align-items: center;"><img src="https://peerwave.org/logo_28.png" style="width:24px;height:24px;padding-right: 0.25rem;"/><span style="color:white;">PeerWave</span><span style="color:#4fbfb3;"> - Private communication you fully control.</span></a></p>
                        </div>
                      </div>
                    `,
                    text: `Your recovery code is ${otp}. This code expires in ${config.otp.expirationMinutes} minutes.`
                }).then(info => {
                    logger.info('[RECOVERY] Email sent', { messageId: info.messageId });
                }).catch(error => {
                    logger.error('[RECOVERY] Error sending email', error);
                });
            } else {
                logger.warn('[RECOVERY] SMTP not configured - email not sent');
            }

            const expiration = new Date().getTime() + config.otp.expirationMinutes * 60 * 1000;
            writeQueue.enqueue(
                () => OTP.create({ email, otp, expiration }),
                'createOTPForLogin'
            )
            .then(otp => {
                logger.info('[OTP] Created successfully for login');
                logger.debug('[OTP] Created', { email: otp.email });
                req.session.email = otp.email;
            }).catch(error => {
                logger.error('[OTP] Error creating OTP for login', error);
            });
        }
        res.status(error.code || 500).json({ error: error.message });
    }
});

// Verify authentication response
authRoutes.post('/webauthn/authenticate', authLimiter, async (req, res) => {
    try {
        const { email, assertion, fromCustomTab, state } = req.body;
        
        // Security: Validate fromCustomTab claim - must have valid CSRF state to prove legitimacy
        // This prevents attackers from bypassing session creation by claiming to be a Custom Tab
        // Use server-controlled flag to track verified Custom Tab auth (not user input)
        let isVerifiedCustomTab = false;
        
        if (fromCustomTab) {
            if (!state) {
                logger.error('[CUSTOM TAB AUTH] Rejected: fromCustomTab claimed but no state provided');
                return res.status(400).json({ 
                    status: "error", 
                    message: "Invalid Custom Tab authentication request - state required" 
                });
            }
            
            const sessionState = req.session.customTabState;
            if (!sessionState || sessionState !== state) {
                logger.error('[CUSTOM TAB AUTH] CSRF validation failed', { 
                    hasSessionState: !!sessionState, 
                    stateMatch: sessionState === state 
                });
                return res.status(403).json({ 
                    status: "error", 
                    message: "CSRF validation failed" 
                });
            }
            
            // CSRF validation passed - set server-controlled flag
            isVerifiedCustomTab = true;
            logger.info('[CUSTOM TAB AUTH] Authentication request received and validated');
            logger.debug('[CUSTOM TAB AUTH] CSRF state validated');
            // Clear state after use (one-time use protection)
            delete req.session.customTabState;
        }
        
        req.session.email = email;
        //const user = users[username];

        assertion.rawId = base64UrlDecode(assertion.rawId);
        assertion.response.authenticatorData = base64UrlDecode(assertion.response.authenticatorData);
        assertion.response.clientDataJSON = base64UrlDecode(assertion.response.clientDataJSON);
        assertion.response.signature = base64UrlDecode(assertion.response.signature);
        if(typeof assertion.response.userHandle == 'string') {
            assertion.response.userHandle = base64UrlDecode(assertion.response.userHandle);
        }

        const user = await User.findOne({ where: { email: email } });
        user.credentials = JSON.parse(user.credentials);
        const credential = user.credentials.find(cred => cred.id === assertion.id);
        
        if (!credential) {
            throw new AppError("Credential not found for this user", 404);
        }

        if (credential) {
            // Credential found, proceed with authentication
            const userAgent = req.headers['user-agent'] || '';
            const ip = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
            const location = await getLocationFromIp(ip);
            const now = new Date();
            const pad = n => n.toString().padStart(2, '0');
            const timestamp = `${now.getFullYear()}-${pad(now.getMonth()+1)}-${pad(now.getDate())} ${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;

            // Update credential fields
            credential.lastLogin = timestamp;
            credential.browser = userAgent;
            credential.ip = location ? location.ip : ip;
            credential.location = location
                ? `${location.city}, ${location.region}, ${location.country} (${location.org})`
                : "Location not found";

            // Save updated credentials array
            user.credentials = JSON.stringify(user.credentials);
            user.changed('credentials', true);
            await writeQueue.enqueue(
                () => user.save(),
                'updateCredentialLastLogin'
            );
        } else {
            // Credential not found, handle authentication failure
        }
        const challenge = base64UrlDecode(req.session.challenge);

        // Keep RP ID / origin computation consistent with the challenge route.
        // This is critical behind reverse proxies (Traefik/Nginx/Cloudflare)
        // where req.hostname may not reflect the public domain.
        const host = process.env.DOMAIN || req.hostname || req.get('host')?.split(':')[0] || 'localhost';
        const protocol = req.headers['x-forwarded-proto'] || (req.secure ? 'https' : 'http');
        logger.debug('[WEBAUTHN AUTH VERIFY] RP configuration', { host, protocol });
        
        // Decode clientDataJSON to check the actual origin
        const clientData = JSON.parse(Buffer.from(assertion.response.clientDataJSON, 'base64').toString('utf8'));
        const actualOrigin = clientData.origin;
        
        // Allow web origins and Android APK origins
        const allowedOrigins = [
            "http://localhost:3000",
            "http://localhost:55831",
            `https://${host}`
        ];
        
        // Determine origin based on client type
        let origin;
        if (actualOrigin.startsWith('android:apk-key-hash:')) {
            // Native Android app - use the APK key hash from clientDataJSON
            origin = actualOrigin;
        } else {
            // Web or Chrome Custom Tab - use standard origin
            origin = req.headers.origin || `${protocol}://${host}`;
            if (!allowedOrigins.includes(origin)) {
                logger.warn('[WEBAUTHN] Unexpected origin', { origin });
            }
        }

        // Standard WebAuthn validation for all clients
        // rpId is required for validating the RP ID hash in authenticator data
        const assertionExpectations = {
            challenge: challenge,
            origin: origin,
            factor: "either",
            publicKey: credential.publicKey,
            prevCounter: 0,
            userHandle: assertion.response.userHandle,
            rpId: host,
        };
        const authnResult = await fido2.assertionResult(assertion, assertionExpectations);

        if (authnResult.audit.complete) {
            // Authentication was successful
            
            // Set user as active on authentication
            await writeQueue.enqueue(
                () => User.update(
                    { active: true },
                    { where: { uuid: user.uuid } }
                ),
                'setUserActiveOnAuth'
            );
            
            // Auto-assign admin role if user is verified and email is in config.admin
            if (user.verified && config.admin && config.admin.includes(email)) {
                await autoAssignRoles(email, user.uuid);
            }
            
            // For app-based login (Custom Tab), skip session creation and only return JWT
            // Use server-controlled flag (not user input) to prevent bypass attacks
            if (isVerifiedCustomTab) {
                logger.debug('[CUSTOM TAB AUTH] App-based login - skipping session creation');
                const response = { 
                    status: "ok", 
                    message: "Authentication successful"
                };
                
                // Generate secure signed JWT for Custom Tab authentication
                logger.debug('[CUSTOM TAB AUTH] Generating JWT token for Custom Tab callback');
                const authToken = generateAuthToken({
                    userId: user.uuid,
                    email: email,
                    credentialId: credential.id, // Include for device identity setup
                    state: state // Include state for additional verification
                });
                
                response.authToken = authToken;
                logger.info('[CUSTOM TAB AUTH] JWT token generated', { expiresIn: config.jwt.expiresIn });
                logger.debug('[CUSTOM TAB AUTH] JWT token generated', { email: sanitizeForLog(user.email), expiresIn: config.jwt.expiresIn });
                
                if(!user.backupCodes) {
                    return res.status(202).json(response);
                } else {
                    return res.status(200).json(response);
                }
            }
            
            // Standard web/mobile login - create session
            req.session.authenticated = true;
            req.session.email = email;
            req.session.uuid = user.uuid;
            
            // Handle client info and create HMAC session for mobile
            const clientId = req.body && req.body.clientId;
            let sessionSecret = null;
            
            if (clientId) {
                // Use shared function to find or create client
                const deviceInfo = req.body && req.body.deviceInfo;
                const result = await findOrCreateClient(clientId, user.uuid, req, deviceInfo);
                req.session.deviceId = result.device_id;
                req.session.clientId = result.clientid;
                
                // Generate session secret for native clients (HMAC authentication)
                sessionSecret = crypto.randomBytes(32).toString('base64url');
                const userAgent = req.headers['user-agent'] || '';
                const ip = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
                const location = await getLocationFromIp(ip);
                const locationString = location 
                    ? `${location.city}, ${location.region}, ${location.country} (${location.org})`
                    : "Location not found";
                
                // Store session in database with configurable expiration
                try {
                    const sessionDays = config.session.hmacSessionDays || 90;
                    await writeQueue.enqueue(
                        () => sequelize.query(
                            `INSERT OR REPLACE INTO client_sessions 
                             (client_id, session_secret, user_id, device_id, device_info, expires_at, last_used, created_at)
                             VALUES (?, ?, ?, ?, ?, datetime('now', '+' || ? || ' days'), datetime('now'), datetime('now'))`,
                            { 
                                replacements: [
                                    clientId, 
                                    sessionSecret, 
                                    user.uuid,
                                    result.device_id, 
                                    JSON.stringify({ userAgent, ip, location: locationString }),
                                    sessionDays
                                ] 
                            }
                        ),
                        'createClientSession'
                    );
                    logger.info('[WEBAUTHN] HMAC session created', { sessionDays });
                    logger.debug('[WEBAUTHN] HMAC session created', { clientId: sanitizeForLog(clientId), sessionDays });
                } catch (sessionErr) {
                    logger.error('[WEBAUTHN] Error creating HMAC session', sessionErr);
                    // Continue anyway - web clients don't need HMAC sessions
                }
                
                // Generate refresh token for native clients
                if (sessionSecret) {
                    try {
                        const refreshToken = await generateRefreshToken(clientId, user.uuid);
                        // Store for response (added below)
                        response.refreshToken = refreshToken;
                    } catch (refreshErr) {
                        logger.error('[WEBAUTHN] Error generating refresh token', refreshErr);
                        // Continue anyway - session still works without refresh token
                    }
                }
            }
            
            // Persist session now
            return req.session.save(err => {
                if (err) {
                    logger.error('[WEBAUTHN] Session save error (/webauthn/authenticate)', err);
                    return res.status(500).json({ status: "error", message: "Session save error" });
                }
                
                const response = { 
                    status: "ok", 
                    message: "Authentication successful"
                };
                
                // Include session secret for mobile clients
                if (sessionSecret) {
                    response.sessionSecret = sessionSecret;
                    response.userId = user.uuid;
                    response.email = email;
                    if (response.refreshToken) {
                        logger.info('[WEBAUTHN] HMAC session credentials + refresh token included in response');
                    } else {
                        logger.info('[WEBAUTHN] HMAC session credentials included in response');
                    }
                    logger.debug('[WEBAUTHN] HMAC credentials', { email: sanitizeForLog(email) });
                }
                
                if(!user.backupCodes) {
                    res.status(202).json(response);
                } else {
                    res.status(200).json(response);
                }
            });
        } else {
            // Authentication failed
            res.status(400).json({ status: "failed", message: "Authentication failed" });
        }
    } catch (error) {
        logger.error('[WEBAUTHN] Error during authentication', error);
        res.status(500).json({
            status: "error",
            message: error && error.message ? error.message : "Internal server error"
        });
    }
});

authRoutes.get("/webauthn/check", sessionLimiter, (req, res) => {
    if(req.session.authenticated || req.session.otp) res.status(200).json({authenticated: true});
    else res.status(401).json({authenticated: false});
});

authRoutes.get("/magic/generate", sessionLimiter, verifyAuthEither, async (req, res) => {
    try {
        // Get user email for magic link
        const user = await User.findOne({ where: { uuid: req.userId } });
        if (!user) {
            return res.status(404).json({ error: "User not found" });
        }
        
        // Generate magic key with new format: {serverUrl}:{randomHash}:{timestamp}:{hmacSignature}
        // Use hostname and explicit port to ensure port is included
        const host = req.get('host') || 'localhost:3000';
        // Check X-Forwarded-Proto header for reverse proxy HTTPS (Nginx, Cloudflare, etc.)
        const protocol = req.get('x-forwarded-proto') || req.protocol;
        const serverUrl = `${protocol}://${host}`;
        const randomHash = crypto.randomBytes(32).toString('hex');
        const timestamp = Date.now();
        const expiresAt = timestamp + 5 * 60 * 1000; // 5 min expiry
        
        logger.debug('[Magic Key] Generating key', { serverUrl });
        
        // Create HMAC signature using session secret
        const dataToSign = `${serverUrl}|${randomHash}|${timestamp}`;
        const hmac = crypto.createHmac('sha256', config.session.secret);
        hmac.update(dataToSign);
        const signature = hmac.digest('hex');
        
        // Construct magic key with pipe delimiter (safe for all URL formats including IPv6)
        const magicKey = `${serverUrl}|${randomHash}|${timestamp}|${signature}`;
        
        // Store in temporary store (one-time use)
        magicLinks[randomHash] = { 
            email: user.email, 
            uuid: req.userId, 
            expires: expiresAt,
            used: false  // Flag for one-time use
        };
        
        // Cleanup expired keys
        Object.keys(magicLinks).forEach(key => {
            if (magicLinks[key].expires < Date.now()) {
                delete magicLinks[key];
            }
        });
        
        res.json({ magicKey: magicKey, expiresAt: expiresAt });
    } catch (error) {
        logger.error('[Magic Key] Error generating magic key', error);
        res.status(500).json({ error: "Internal server error" });
    }
});

authRoutes.get("/webauthn/list", sessionLimiter, verifyAuthEither, async (req, res) => {
    try {
        const user = await User.findOne({ where: { uuid: req.userId } });
        if (user) {
            // Handle null or empty credentials
            const credentialsData = user.credentials ? JSON.parse(user.credentials) : [];
            const credentials = (Array.isArray(credentialsData) ? credentialsData : []).map(cred => ({
                id: cred.id,
                browser: cred.browser || null,
                ip: cred.ip || null,
                location: cred.location || null,
                createdAt: cred.createdAt || cred.created || null,  // Support both old and new field names
                lastLogin: cred.lastLogin || null
            }));
            res.status(200).json({ status: "ok", credentials: credentials });
        } else {
            res.status(404).json({ status: "failed", message: "User not found" });
        }
    } catch (error) {
        logger.error('[WEBAUTHN] Error fetching credentials', error);
        res.status(500).json({ error: "Internal server error" });
    }
});

authRoutes.post("/client/addweb", async (req, res) => {
    if(req.session.authenticated && req.session.email && req.session.uuid) {
        try {
            const { clientId, deviceInfo } = req.body;
            
            // Use shared function to find or create client
            const result = await findOrCreateClient(clientId, req.session.uuid, req, deviceInfo);
            
            // Store in session for web clients
            req.session.deviceId = result.device_id;
            req.session.clientId = result.clientid;
            
            req.session.save(err => {
                if (err) {
                    logger.error('[CLIENT] Session save error', err);
                    return res.status(500).json({ status: "error", message: "Session save error" });
                }
                res.status(200).json({ 
                    status: "ok", 
                    message: result.created ? "Client added successfully" : "Client updated successfully" 
                });
            });

        } catch (error) {
            logger.error('[CLIENT] Error adding client', error);
            res.status(500).json({ status: "error", message: "Internal server error" });
        }
    } else {
        res.status(401).json({ status: "failed", message: "Unauthorized" });
    }
});

authRoutes.get("/client/list", sessionLimiter, verifyAuthEither, async (req, res) => {
    try {
        const clients = await Client.findAll({ where: { owner: req.userId }, attributes: { exclude: ['public_key', 'registration_id'] } });
        res.status(200).json({ status: "ok", clients: clients });
    } catch (error) {
        logger.error('[CLIENT] Error fetching client list', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

authRoutes.post("/client/delete", sessionLimiter, verifyAuthEither, async (req, res) => {
    try {
        const { clientId } = req.body;
        const currentClientId = req.clientId || req.session.clientId; // HMAC or session
        
        // Prevent deletion of current session's client
        if (clientId === currentClientId) {
            return res.status(400).json({ 
                status: "error", 
                message: "Cannot delete the current session's client. Please logout first or use another device." 
            });
        }
        
        // Get the client to find its clientid for cleanup
        const client = await Client.findOne({ where: { id: clientId, owner: req.userId } });
        if (!client) {
            return res.status(404).json({ status: "error", message: "Client not found" });
        }
        
        const clientIdStr = client.clientid;
        
        // Delete refresh tokens for this client
        await writeQueue.enqueue(
            () => RefreshToken.destroy({ where: { client_id: clientIdStr } }),
            'deleteClientRefreshTokens'
        );
        
        // Delete session from database
        await sequelize.query(
            'DELETE FROM client_sessions WHERE client_id = ?',
            { replacements: [clientIdStr] }
        );
        
        // Delete associated Signal keys
        await writeQueue.enqueue(async () => {
            await SignalPreKey.destroy({ where: { client: clientIdStr } });
            await SignalSignedPreKey.destroy({ where: { client: clientIdStr } });
        }, 'deleteClientSignalKeys');
        
        // Finally, delete the client
        await writeQueue.enqueue(
            () => Client.destroy({ where: { id: clientId, owner: req.userId } }),
            'deleteClient'
        );
        res.status(200).json({ status: "ok", message: "Client deleted successfully" });
    } catch (error) {
        logger.error('[CLIENT] Error deleting client', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

// Implement webauthn delete route
authRoutes.post("/webauthn/delete", sessionLimiter, verifyAuthEither, async (req, res) => {
    // Perform webauthn delete logic
    try {
        const { credentialId } = req.body;
        const user = await User.findOne({ where: { uuid: req.userId } });
        
        if (user) {
            user.credentials = JSON.parse(user.credentials);
            
            // Prevent deletion if only one credential remains
            if (user.credentials.length <= 1) {
                return res.status(400).json({
                    status: "error",
                    message: "Cannot delete the last WebAuthn credential. You must have at least one security key."
                });
            }
            
            user.credentials = user.credentials.filter(cred => cred.id !== credentialId);
            user.credentials = JSON.stringify(user.credentials);
            user.changed('credentials', true);
            await writeQueue.enqueue(
                () => user.save(),
                'deleteWebAuthnCredential'
            );
            res.status(200).send("WebAuthn credential deleted");
        } else {
            res.status(404).send("User not found");
        }
    } catch (error) {
        logger.error('[WEBAUTHN] Error deleting credential', error);
        res.status(500).send("Internal Server Error");
    }
});

// ==================== INVITATION VERIFICATION ROUTE (PUBLIC) ====================

// POST verify invitation token (public endpoint for registration validation)
authRoutes.post("/api/invitations/verify", async (req, res) => {
    try {
        const { email, token } = req.body;
        
        if (!email || !token) {
            return res.status(400).json({ 
                valid: false, 
                message: "Email and token required" 
            });
        }
        
        const { Invitation } = require('../db/model');
        
        const invitation = await Invitation.findOne({
            where: {
                email,
                token,
                used: false,
                expires_at: {
                    [Op.gt]: new Date()
                }
            }
        });
        
        if (!invitation) {
            return res.json({ 
                valid: false, 
                message: "Invalid or expired invitation" 
            });
        }
        
        res.json({ 
            valid: true, 
            message: "Invitation is valid" 
        });
    } catch (error) {
        logger.error('[INVITATION] Error verifying invitation', error);
        res.status(500).json({ 
            valid: false, 
            message: "Internal server error" 
        });
    }
});

// REMOVED: /auth/passkey endpoint - Using Flutter web login page (/#/login?from=app) instead

// REMOVED: /auth/token/generate endpoint - Token is now generated directly in /webauthn/authenticate
// when fromCustomTab=true, eliminating the need for a separate API call

// Token Exchange Endpoint
// POST /auth/token/exchange
// Exchanges short-lived auth token for session
// Rate limited to prevent brute force attacks
authRoutes.post('/token/exchange', tokenExchangeLimiter, async (req, res) => {
    try {
        const { token: rawToken, clientId: rawClientId } = req.body;
        
        // Validate types and normalize - fail fast on invalid types
        if (typeof rawToken !== 'string' || typeof rawClientId !== 'string') {
            return res.status(400).json({ error: 'Invalid request parameters' });
        }
        
        // Normalize by trimming whitespace
        const token = rawToken.trim();
        const clientId = rawClientId.trim();
        
        // Validate clientId format (UUID) - server-side validation rule, not user-controlled
        const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
        if (!uuidRegex.test(clientId)) {
            logger.warn('[TOKEN EXCHANGE] Invalid clientId format');
            return res.status(400).json({ error: 'Invalid clientId format' });
        }
        
        logger.info('[TOKEN EXCHANGE] Request received');
        logger.debug('[TOKEN EXCHANGE] Request', { 
            hasToken: !!token, 
            clientId: clientId.substring(0, 8) + '...'
        });
        
        // Verify JWT signature, expiration, and one-time use
        const decoded = verifyAuthToken(token);
        
        if (!decoded) {
            return res.status(401).json({ error: 'Invalid or expired token' });
        }
        
        const { userId, email, credentialId } = decoded;
        logger.info('[TOKEN EXCHANGE] Token verified');
        logger.debug('[TOKEN EXCHANGE] Token details', { 
            userId: userId.substring(0, 8) + '...',
            email: email,
            hasCredentialId: !!credentialId
        });
        
        // Get user from database (use uuid, not id)
        const user = await User.findOne({ where: { uuid: userId } });
        if (!user) {
            return res.status(404).json({ error: 'User not found' });
        }
        
        // Use shared function to find or create Signal Client record (required for Signal protocol)
        const deviceInfo = req.body && req.body.deviceInfo;
        const result = await findOrCreateClient(clientId, user.uuid, req, deviceInfo);
        logger.info('[TOKEN EXCHANGE] Client record ensured');
        logger.debug('[TOKEN EXCHANGE] Client details', { 
            clientId: result.clientid, 
            deviceId: result.device_id,
            created: result.created
        });
        
        // Generate session secret
        const sessionSecret = crypto.randomBytes(32).toString('hex');
        
        // Calculate expiration (90 days from now)
        const sessionDays = config.session?.hmacSessionDays || 90;
        const expiresAt = new Date();
        expiresAt.setDate(expiresAt.getDate() + sessionDays);
        
        // Store session in database
        await writeQueue.enqueue(
            () => ClientSession.upsert({
                client_id: clientId,
                user_id: user.uuid,
                session_secret: sessionSecret,
                expires_at: expiresAt,
                last_used: new Date()
            })
        );
        
        logger.info('[TOKEN EXCHANGE] Session created', { email: user.email, sessionDays });
        
        // Generate refresh token
        let refreshToken;
        try {
            refreshToken = await generateRefreshToken(clientId, user.uuid);
            logger.info('[TOKEN EXCHANGE] Refresh token generated');
        } catch (refreshErr) {
            logger.error('[TOKEN EXCHANGE] Error generating refresh token', refreshErr);
            // Continue anyway - session still works without refresh token
        }
        
        const response = {
            sessionSecret,
            userId: user.uuid,
            email: user.email,
            credentialId: credentialId // Include for device identity setup
        };
        
        if (refreshToken) {
            response.refreshToken = refreshToken;
        }
        
        res.json(response);
        
    } catch (error) {
        logger.error('[TOKEN EXCHANGE] Error', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// Token Revocation Endpoint
// POST /auth/token/revoke
// Revokes a JWT token (invalidates it before expiration)
// Rate limited to prevent abuse
authRoutes.post('/token/revoke', tokenRevocationLimiter, async (req, res) => {
    try {
        const { token } = req.body;
        
        // Validate token with proper type and format checks
        if (!token || typeof token !== 'string' || token.trim().length === 0) {
            return res.status(400).json({ error: 'Valid token required' });
        }
        
        logger.info('[TOKEN REVOKE] Revocation requested');
        
        const success = revokeToken(token);
        
        if (success) {
            res.json({ 
                status: 'ok',
                message: 'Token revoked successfully' 
            });
        } else {
            res.status(400).json({ 
                error: 'Failed to revoke token - token may be invalid or already expired' 
            });
        }
        
    } catch (error) {
        logger.error('[TOKEN REVOKE] Error', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// Refresh Token Endpoint
// POST /auth/token/refresh
// Refreshes expired HMAC session using refresh token
// Rate limited to 10 requests per hour per client
const refreshTokenLimiter = rateLimit({
    windowMs: 60 * 60 * 1000, // 1 hour
    max: 10, // 10 requests per hour
    message: 'Too many refresh attempts, please try again later',
    standardHeaders: true,
    legacyHeaders: false,
});

authRoutes.post('/token/refresh', refreshTokenLimiter, async (req, res) => {
    try {
        const { clientId, refreshToken } = req.body;
        
        // Validate inputs
        if (!clientId || typeof clientId !== 'string' || !refreshToken || typeof refreshToken !== 'string') {
            return res.status(400).json({ error: 'clientId and refreshToken are required' });
        }
        
        logger.info('[REFRESH TOKEN] Refresh request received');
        logger.debug('[REFRESH TOKEN] Request', { clientId: sanitizeForLog(clientId) });
        
        // Find the refresh token in database
        const tokenRecord = await RefreshToken.findOne({ 
            where: { 
                token: refreshToken,
                client_id: clientId
            } 
        });
        
        if (!tokenRecord) {
            logger.warn('[REFRESH TOKEN] Token not found');
            return res.status(401).json({ error: 'Invalid refresh token' });
        }
        
        // Check if token is expired
        if (new Date() > new Date(tokenRecord.expires_at)) {
            logger.warn('[REFRESH TOKEN] Token expired');
            await writeQueue.enqueue(
                () => RefreshToken.destroy({ where: { token: refreshToken } }),
                'deleteExpiredRefreshToken'
            );
            return res.status(401).json({ error: 'Refresh token expired' });
        }
        
        // Check one-time use
        if (tokenRecord.used_at !== null) {
            logger.warn('[REFRESH TOKEN] Token already used');
            return res.status(401).json({ error: 'Refresh token already used' });
        }
        
        // Mark old token as used
        await writeQueue.enqueue(
            () => RefreshToken.update(
                { used_at: new Date() },
                { where: { token: refreshToken } }
            ),
            'markRefreshTokenUsed'
        );
        
        // Generate new session secret
        const sessionSecret = crypto.randomBytes(32).toString('base64url');
        const sessionDays = config.session?.hmacSessionDays || 90;
        const expiresAt = new Date();
        expiresAt.setDate(expiresAt.getDate() + sessionDays);
        
        // Update client session
        await writeQueue.enqueue(
            () => sequelize.query(
                `UPDATE client_sessions 
                 SET session_secret = ?, 
                     expires_at = ?,
                     last_used = datetime('now')
                 WHERE client_id = ?`,
                { replacements: [sessionSecret, expiresAt.toISOString(), clientId] }
            ),
            'updateClientSessionOnRefresh'
        );
        
        // Generate new refresh token (rotation for security)
        const newRefreshToken = await generateRefreshToken(clientId, tokenRecord.user_id);
        
        logger.info('[REFRESH TOKEN] Session refreshed successfully');
        logger.debug('[REFRESH TOKEN] New tokens generated', { clientId: sanitizeForLog(clientId) });
        
        res.json({
            sessionSecret,
            refreshToken: newRefreshToken,
            userId: tokenRecord.user_id
        });
        
    } catch (error) {
        logger.error('[REFRESH TOKEN] Error', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// POST /auth/session/refresh
// Manually refresh HMAC session (extends expiration)
// Requires valid HMAC authentication via sessionAuth middleware
authRoutes.post('/session/refresh', sessionLimiter, verifySessionAuth, async (req, res) => {
    try {
        const { clientId } = req;
        const sessionDays = config.session.hmacSessionDays || 90;
        
        // Extend session expiration
        await sequelize.query(
            `UPDATE client_sessions 
             SET expires_at = datetime('now', '+' || ? || ' days'),
                 last_used = datetime('now')
             WHERE client_id = ?`,
            { replacements: [sessionDays, clientId] }
        );
        
        logger.info('[SESSION REFRESH] Session manually refreshed', { sessionDays });
        logger.debug('[SESSION REFRESH] Refreshed for client', { clientId: sanitizeForLog(clientId), sessionDays });
        
        res.json({
            status: 'ok',
            message: 'Session refreshed successfully',
            expiresIn: sessionDays + ' days'
        });
        
    } catch (error) {
        logger.error('[SESSION REFRESH] Error', error);
        res.status(500).json({ error: 'Failed to refresh session' });
    }
});

/**
 * GET /auth/sessions/list
 * Lists all active sessions for the authenticated user
 * Combines HMAC sessions and WebAuthn credentials
 */
authRoutes.get('/sessions/list', sessionLimiter, verifyAuthEither, async (req, res) => {
    try {
        const userId = req.userId; // Set by verifyAuthEither middleware
        const currentClientId = req.clientId || req.session.clientId; // HMAC or session
        
        // Get HMAC sessions from client_sessions table
        const hmacSessions = await sequelize.query(
            `SELECT 
                cs.client_id AS id,
                cs.device_info,
                cs.last_used,
                cs.expires_at,
                cs.created_at,
                c.browser,
                c.ip,
                c.location
            FROM client_sessions cs
            LEFT JOIN clients c ON cs.client_id = c.clientid
            WHERE cs.user_id = ? 
            AND (cs.expires_at IS NULL OR cs.expires_at > datetime('now'))
            ORDER BY cs.last_used DESC`,
            {
                replacements: [userId],
                type: Sequelize.QueryTypes.SELECT
            }
        );
        
        // Parse device info and browser user agent
        const sessions = hmacSessions.map(session => {
            const deviceInfo = session.device_info ? JSON.parse(session.device_info) : {};
            const userAgent = session.browser || '';
            
            // Parse user agent for browser and OS
            let browser = null;
            let os = null;
            
            if (userAgent) {
                // Extract browser
                if (userAgent.includes('Chrome/') && !userAgent.includes('Edg/')) {
                    browser = 'Chrome';
                } else if (userAgent.includes('Edg/')) {
                    browser = 'Edge';
                } else if (userAgent.includes('Firefox/')) {
                    browser = 'Firefox';
                } else if (userAgent.includes('Safari/') && !userAgent.includes('Chrome/')) {
                    browser = 'Safari';
                }
                
                // Extract OS
                if (userAgent.includes('Windows NT')) {
                    os = 'Windows';
                } else if (userAgent.includes('Mac OS X')) {
                    os = 'macOS';
                } else if (userAgent.includes('Linux')) {
                    os = 'Linux';
                } else if (userAgent.includes('Android')) {
                    os = 'Android';
                } else if (userAgent.includes('iOS') || userAgent.includes('iPhone') || userAgent.includes('iPad')) {
                    os = 'iOS';
                }
            }
            
            // Extract location (city, country)
            let location = null;
            if (session.location) {
                const locationMatch = session.location.match(/^([^,]+),\s*([^,]+),\s*([^(]+)/);
                if (locationMatch) {
                    location = `${locationMatch[1]}, ${locationMatch[3].trim()}`;
                }
            }
            
            return {
                id: session.id,
                device_name: deviceInfo.deviceName || browser || 'Unknown Device',
                browser: browser,
                os: os,
                location: location,
                ip_address: session.ip,
                last_active: session.last_used,
                expires_at: session.expires_at,
                is_current: session.id === currentClientId
            };
        });
        
        res.json({ sessions });
        
    } catch (error) {
        logger.error('[SESSIONS LIST] Error', error);
        res.status(500).json({ error: 'Failed to load sessions' });
    }
});

/**
 * POST /auth/sessions/revoke
 * Revokes a specific session
 */
authRoutes.post('/sessions/revoke', sessionLimiter, verifyAuthEither, async (req, res) => {
    try {
        const userId = req.userId; // Set by verifyAuthEither middleware
        const currentClientId = req.clientId || req.session.clientId; // HMAC or session
        const { sessionId } = req.body;
        
        if (!sessionId) {
            return res.status(400).json({ error: 'Session ID required' });
        }
        
        // Check if revoking current session
        if (sessionId === currentClientId) {
            // Revoke current session - will trigger logout
            await sequelize.query(
                `DELETE FROM client_sessions WHERE client_id = ? AND user_id = ?`,
                { replacements: [sessionId, userId] }
            );
            
            // Clear session if using cookie auth
            if (req.session && req.session.destroy) {
                req.session.destroy();
            }
            
            logger.info('[SESSION REVOKE] Current session revoked');
            logger.debug('[SESSION REVOKE] Current session revoked', { userId: sanitizeForLog(userId) });
            return res.json({ status: 'ok', message: 'Current session revoked' });
        }
        
        // Revoke other session
        await sequelize.query(
            `DELETE FROM client_sessions WHERE client_id = ? AND user_id = ?`,
            { replacements: [sessionId, userId] }
        );
        
        logger.info('[SESSION REVOKE] Session revoked');
        logger.debug('[SESSION REVOKE] Session revoked', { sessionId: sanitizeForLog(sessionId), userId: sanitizeForLog(userId) });
        res.json({ status: 'ok', message: 'Session revoked' });
        
    } catch (error) {
        logger.error('[SESSION REVOKE] Error', error);
        res.status(500).json({ error: 'Failed to revoke session' });
    }
});

/**
 * POST /auth/sessions/revoke-all
 * Revokes all sessions except the current one
 */
authRoutes.post('/sessions/revoke-all', sessionLimiter, verifyAuthEither, async (req, res) => {
    try {
        const userId = req.userId; // Set by verifyAuthEither middleware
        const currentClientId = req.clientId || req.session.clientId; // HMAC or session
        
        // 1. First delete associated refresh tokens to avoid FK constraint violation
        await sequelize.query(
            `DELETE FROM refresh_tokens WHERE user_id = ? AND client_id != ?`,
            { replacements: [userId, currentClientId] }
        );
        
        // 2. Then delete all sessions except current
        const result = await sequelize.query(
            `DELETE FROM client_sessions WHERE user_id = ? AND client_id != ?`,
            { replacements: [userId, currentClientId] }
        );
        
        const deletedCount = result[1] || 0;
        
        logger.info('[SESSION REVOKE ALL] Sessions revoked', { deletedCount, userId: sanitizeForLog(userId) });
        res.json({ 
            status: 'ok', 
            message: 'All other sessions revoked',
            revoked_count: deletedCount
        });
        
    } catch (error) {
        logger.error('[SESSION REVOKE ALL] Error', error);
        res.status(500).json({ error: 'Failed to revoke sessions' });
    }
});

module.exports = authRoutes;

