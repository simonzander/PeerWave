const config = require('../config/config');
const express = require("express");
const { Sequelize, DataTypes, Op, UUID } = require('sequelize');
const { Fido2Lib } = require('fido2-lib');
const bodyParser = require('body-parser'); // Import body-parser
const nodemailer = require("nodemailer");
const crypto = require('crypto');
const { sanitizeForLog } = require('../utils/logSanitizer');
const session = require('express-session');
const rateLimit = require('express-rate-limit');
const fetch = (...args) => import('node-fetch').then(({default: fetch}) => fetch(...args));
const magicLinks = require('../store/magicLinksStore');
const { User, OTP, Client, ClientSession } = require('../db/model');
const bcrypt = require("bcrypt");
const writeQueue = require('../db/writeQueue');
const { autoAssignRoles } = require('../db/autoAssignRoles');
const { generateAuthToken, verifyAuthToken, revokeToken, generateState } = require('../utils/jwtHelper');

/**
 * Shared function to find or create a Client record
 * Used by both web (/client/addweb) and native (/token/exchange, /webauthn/authenticate)
 * 
 * @param {string} clientId - UUID generated client-side
 * @param {string} userUuid - User's UUID
 * @param {Object} req - Express request object (for IP, user-agent, etc.)
 * @returns {Promise<Object>} Client record with device_id and clientid
 */
async function findOrCreateClient(clientId, userUuid, req) {
    const userAgent = req.headers['user-agent'] || '';
    const ip = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
    const location = await getLocationFromIp(ip);
    const locationString = location
        ? `${location.city}, ${location.region}, ${location.country} (${location.org})`
        : "Location not found";
    
    // Get max device_id for this user and auto-increment
    const maxDevice = await Client.max('device_id', { where: { owner: userUuid } });
    
    // Find existing client or create new one
    const [client, created] = await Client.findOrCreate({
        where: { clientid: clientId, owner: userUuid },
        defaults: {
            owner: userUuid,
            clientid: clientId,
            ip: ip,
            browser: userAgent,
            location: locationString,
            device_id: maxDevice ? maxDevice + 1 : 1
        }
    });
    
    // Update metadata if client already exists
    if (!created) {
        await writeQueue.enqueue(
            () => Client.update(
                { ip, browser: userAgent, location: locationString },
                { where: { clientid: clientId } }
            ),
            'updateClientInfo'
        );
    }
    
    console.log(`[CLIENT] ${created ? 'Created' : 'Found'} client ${sanitizeForLog(clientId)} with device_id=${client.device_id}`);
    
    return {
        client,
        created,
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
        console.log('User table created successfully.');
    })
    .catch(error => {
        console.error('Error creating User table:', error);
    });

// Create the OTP table in the database
OTP.sync({ alter: true })
    .then(() => {
        console.log('OTP table created successfully.');
    })
    .catch(error => {
        console.error('Error creating OTP table:', error);
    });

// Create the Channel table in the database
Channel.sync({ alter: true })
    .then(() => {
        console.log('Channel table created successfully.');
    })
    .catch(error => {
        console.error('Error creating Channel table:', error);
    });

// Create the Thread table in the database
Thread.sync({ alter: true })
    .then(() => {
        console.log('Thread table created successfully.');
    })
    .catch(error => {
        console.error('Error creating Thread table:', error);
    });

// Create the Emote table in the database
Emote.sync({ alter: true })
    .then(() => {
        console.log('Emote table created successfully.');
    })
    .catch(error => {
        console.error('Error creating Emote table:', error);
    });

// Create the PublicKey table in the database
PublicKey.sync({ alter: true })
    .then(() => {
        console.log('PublicKey table created successfully.');
    })
    .catch(error => {
        console.error('Error creating PublicKey table:', error);
    });

// Create the Client table in the database
Client.sync({ alter: true })
    .then(() => {
        console.log('Client table created successfully.');
    })
    .catch(error => {
        console.error('Error creating Client table:', error);
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
                            console.log("Message sent: %s", info.messageId);
                        }).catch(error => {
                            console.error('Error sending OTP email:', error);
                        });
                    } else {
                        console.warn('[OTP] SMTP not configured - OTP email not sent');
                    }


                    // Save the OTP and email in temporary storage
                    const expiration = new Date().getTime() + config.otp.expirationMinutes * 60 * 1000;
                    writeQueue.enqueue(
                        () => OTP.create({ email, otp, expiration }),
                        'createOTP'
                    )
                    .then(otp => {
                        console.log('OTP created successfully:', otp);
                        req.session.email = otp.email;
                        res.status(200).json({ status: "otp", wait: Math.ceil((otp.expiration - Date.now()) / 1000) });
                    }).catch(error => {
                        console.error('Error creating OTP:', error);
                    });

                    // Store the temporary storage in a database or cache
                    // For example, you can use Redis or a database table to store the temporary storage
                    // Make sure to handle the expiration and cleanup of expired OTPs
                    // Render the otp form
                        }
            });

            
        })
        .catch(error => {
            console.error('Error creating user:', error);
            res.status(500).json({ error: "Error on creating user" });
        });
        
    } catch (error) {
        console.error('Error in registration:', error);
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
                console.log(`[INVITATION] Marked invitation ${sanitizeForLog(req.session.pendingInvitationId)} as used for ${sanitizeForLog(email)}`);
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
                    console.error('Session save error (/otp):', err);
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
        console.error('Error finding OTP:', error);
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
        console.error('Error fetching backup codes:', error);
        res.status(500).json({ error: "Internal server error" });
    }
});

authRoutes.get("/backupcode/usage", async(req, res) => {
    if (!req.session.authenticated) {
        return res.status(401).json({ error: "Unauthorized" });
    }
    try {
        const user = await User.findOne({ where: { email: req.session.email } });
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
        console.error('Error fetching backup code usage:', error);
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
                    console.error('Session save error (/backupcode/verify):', err);
                    return res.status(500).json({ status: "error", message: "Session save error" });
                }
                res.status(200).json({ status: "ok", message: "Backup code verified successfully" });
            });
        }
    } catch (error) {
        console.error('Error verifying backup code:', error);
        res.status(500).json({ error: "Internal server error" });
    }
});

authRoutes.post("/backupcode/regenerate", async(req, res) => {
    if (!req.session.authenticated) {
        return res.status(401).json({ error: "Unauthorized" });
    }
    try {
        const user = await User.findOne({ where: { email: req.session.email } });
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
        console.error('Error regenerating backup codes:', error);
        res.status(500).json({ error: "Internal server error" });
    }
});

// POST logout route - destroys session and clears cookie
authRoutes.post("/logout", async (req, res) => {
    // Support both HMAC (native) and Session (web) authentication
    const userId = req.userId || req.session.uuid;
    const deviceId = req.deviceId || req.session.deviceId;
    const clientId = req.clientId || req.session.clientId;
    
    console.log(`[AUTH] Logout request from user ${sanitizeForLog(userId)}, device ${sanitizeForLog(deviceId)}`);
    
    // If HMAC auth (native client), delete the HMAC session from database
    if (req.userId && clientId) {
        try {
            const { sequelize } = require('../db/model');
            await sequelize.query(
                'DELETE FROM client_sessions WHERE client_id = ?',
                { replacements: [clientId] }
            );
            console.log(`[AUTH] ✓ HMAC session deleted for client ${sanitizeForLog(clientId)}`);
            return res.json({ success: true, message: 'Logged out successfully' });
        } catch (error) {
            console.error('[AUTH] Error deleting HMAC session:', error);
            return res.status(500).json({ success: false, error: 'Failed to delete session' });
        }
    }
    
    // If Session auth (web client), destroy the session
    req.session.destroy((err) => {
        if (err) {
            console.error('[AUTH] Error destroying session:', err);
            return res.status(500).json({ success: false, error: 'Failed to destroy session' });
        }
        
        // Clear the session cookie
        res.clearCookie('connect.sid', {
            path: '/',
            httpOnly: true,
            secure: process.env.NODE_ENV === 'production',
            sameSite: 'strict'
        });
        
        console.log(`[AUTH] ✓ Session destroyed for user ${sanitizeForLog(userId)}, device ${sanitizeForLog(deviceId)}`);
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
authRoutes.post('/webauthn/register-challenge', async (req, res) => {
    const email = req.session.email; // Retrieve email from session
    const user = await User.findOne({ where: { email: email } });
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
    console.log(`[WEBAUTHN REG] RP ID: ${host}`);
    
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
    console.log('[WEBAUTHN] Registration request - isFirstCredential:', isFirstCredential, 'registrationStep:', req.session.registrationStep, 'authenticated:', req.session.authenticated);
    if(!req.session.otp && !req.session.authenticated && !req.session.email) {
        return res.status(400).json({ status: "error", message: "User not authenticated." });
    }
    else {
        try {
            const { attestation } = req.body;

            console.log(attestation);
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

            const host = req.hostname;
            
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
                    console.warn("Unexpected origin for WebAuthn:", origin);
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

            const user = await User.findOne({ where: { email: req.session.email } });

            if (typeof user.credentials === 'string') {
                user.credentials = JSON.parse(user.credentials);
            }
            if (!Array.isArray(user.credentials)) {

                user.credentials = [];
            }

            console.log("regResult", regResult, regResult.authnrData);

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
                console.log('[WEBAUTHN] First credential registered - session authenticated:', {
                    uuid: user.uuid,
                    email: user.email,
                    registrationStep: req.session.registrationStep,
                    authenticated: req.session.authenticated
                });
            } else {
                console.log('[WEBAUTHN] Additional credential registered - not first credential');
            }
            
            // Handle client info and create HMAC session for mobile (same as authentication)
            const clientId = req.body && req.body.clientId;
            let sessionSecret = null;
            
            if (clientId) {
                const { sequelize } = require('../db/model');
                
                // Use shared function to find or create client
                const result = await findOrCreateClient(clientId, user.uuid, req);
                
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
                    console.log(`[WEBAUTHN] HMAC session created for client on registration (${sessionDays} days): ${sanitizeForLog(clientId)}`);
                } catch (sessionErr) {
                    console.error('[WEBAUTHN] Error creating HMAC session on registration:', sessionErr);
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
            console.error('Error during registration:', error);
            res.json({ status: "error" });
        }
    }
});

// Generate authentication challenge
authRoutes.post('/webauthn/authenticate-challenge', async (req, res) => {
    try {
        const { email } = req.body;
        req.session.email = email;
        console.log(req.body);
        const user = await User.findOne({ where: { email: email } });

        console.log(user);

        if(!user) {
            throw new AppError("User not found. Please register first.", 404);
        }
        if(!user.credentials && !user.backupCodes) {
            throw new AppError("Account is not verified. Please verify with OTP.", 401, email);
        }
        if (!user.credentials && user.backupCodes) {
            throw new AppError("No credentials found. Please start recovery process.", 400);
        }
        console.log(typeof user.credentials, user.credentials, JSON.parse(user.credentials));

        const challenge = await fido2.assertionOptions();

        // Use environment variable for production (most reliable)
        // Fallback to req.hostname for local development
        const host = process.env.DOMAIN || req.hostname || req.get('host')?.split(':')[0] || 'localhost';
        // Check X-Forwarded-Proto for reverse proxy (Nginx, Cloudflare, Traefik)
        // req.secure is often false behind proxies
        const protocol = req.headers['x-forwarded-proto'] || (req.secure ? 'https' : 'http');
        const origin = `${protocol}://${host}`;

        console.log(`[WEBAUTHN AUTH] RP ID: ${host}, Origin: ${origin}, Protocol source: ${req.headers['x-forwarded-proto'] ? 'x-forwarded-proto' : 'req.secure'}`);

        // Validate host is never empty (critical for Google Play Services)
        if (!host || host.trim() === '') {
            console.error('[WEBAUTHN AUTH] ERROR: Host is empty! Check DOMAIN env variable');
            throw new AppError("Invalid hostname for authentication - server misconfiguration", 500);
        }
        
        // IMPORTANT: Do NOT set challenge.rp for authentication (assertionOptions)
        // rp is ONLY for registration (attestationOptions)
        // WebAuthn spec strictly enforces this requirement

        user.credentials = JSON.parse(user.credentials);

        console.log('[WEBAUTHN AUTH] Found credentials for user:', user.credentials.length);
        user.credentials.forEach((cred, idx) => {
            console.log(`[WEBAUTHN AUTH] Credential ${idx}: id=${cred.id}, transports=${JSON.stringify(cred.transports)}`);
        });

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
        console.log('[WEBAUTHN AUTH] Including credential IDs for authentication');
        
        // Add user verification preference for flexibility
        challenge.userVerification = "preferred";

        challenge.challenge = base64UrlEncode(challenge.challenge);
        req.session.challenge = challenge.challenge;
        res.json(challenge);
    } catch (error) {
        console.error('Error:', error);
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
                    console.log("Recovery email sent: %s", info.messageId);
                }).catch(error => {
                    console.error('Error sending recovery email:', error);
                });
            } else {
                console.warn('[RECOVERY] SMTP not configured - recovery email not sent');
            }

            const expiration = new Date().getTime() + config.otp.expirationMinutes * 60 * 1000;
            writeQueue.enqueue(
                () => OTP.create({ email, otp, expiration }),
                'createOTPForLogin'
            )
            .then(otp => {
                console.log('OTP created successfully:', otp);
                req.session.email = otp.email;
            }).catch(error => {
                console.error('Error creating OTP:', error);
            });
        }
        res.status(error.code || 500).json({ error: error.message });
    }
});

// Verify authentication response
authRoutes.post('/webauthn/authenticate', async (req, res) => {
    try {
        const { sequelize } = require('../db/model');
        const { email, assertion, fromCustomTab, state } = req.body;
        
        // Enhanced logging for Custom Tab auth
        if (fromCustomTab) {
            console.log('[CUSTOM TAB AUTH] Authentication request received', {
                email: sanitizeForLog(email),
                hasState: !!state,
                hasSessionState: !!req.session.customTabState
            });
        }
        
        // Verify CSRF state for Custom Tab requests (if state was provided)
        if (fromCustomTab && state) {
            const sessionState = req.session.customTabState;
            if (!sessionState || sessionState !== state) {
                console.error('[CUSTOM TAB AUTH] ✗ CSRF validation failed', { 
                    hasSessionState: !!sessionState, 
                    stateMatch: sessionState === state 
                });
                return res.status(403).json({ 
                    status: "error", 
                    message: "CSRF validation failed" 
                });
            }
            console.log('[CUSTOM TAB AUTH] ✓ CSRF state validated');
            // Clear state after use (one-time use protection)
            delete req.session.customTabState;
        } else if (fromCustomTab) {
            console.log('[CUSTOM TAB AUTH] ⚠ No CSRF state provided (skipping validation)');
        }
        
        req.session.email = email;
        //const user = users[username];

        assertion.rawId = base64UrlDecode(assertion.rawId);
        assertion.response.authenticatorData = base64UrlDecode(assertion.response.authenticatorData);
        assertion.response.clientDataJSON = base64UrlDecode(assertion.response.clientDataJSON);
        assertion.response.signature = base64UrlDecode(assertion.response.signature);
        console.log(assertion);
        console.log(assertion.response);
        console.log(assertion.response.userHandle);
        if(typeof assertion.response.userHandle == 'string') {
            assertion.response.userHandle = base64UrlDecode(assertion.response.userHandle);
        }

        const user = await User.findOne({ where: { email: email } });
        console.log(user);
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
        console.log(`[WEBAUTHN AUTH VERIFY] RP ID: ${host}, Protocol: ${protocol}`);
        
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
                console.warn("Unexpected origin for WebAuthn:", origin);
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
            req.session.authenticated = true;
            req.session.email = email;
            req.session.uuid = user.uuid;
            
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
            
            // Handle client info and create HMAC session for mobile
            const clientId = req.body && req.body.clientId;
            let sessionSecret = null;
            
            if (clientId) {
                // Use shared function to find or create client
                const result = await findOrCreateClient(clientId, user.uuid, req);
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
                                    client.device_id, 
                                    JSON.stringify({ userAgent, ip, location: locationString }),
                                    sessionDays
                                ] 
                            }
                        ),
                        'createClientSession'
                    );
                    console.log(`[WEBAUTHN] HMAC session created for client (${sessionDays} days): ${sanitizeForLog(clientId)}`);
                } catch (sessionErr) {
                    console.error('[WEBAUTHN] Error creating HMAC session:', sessionErr);
                    // Continue anyway - web clients don't need HMAC sessions
                }
            }
            
            // Persist session now
            return req.session.save(err => {
                if (err) {
                    console.error('Session save error (/webauthn/authenticate):', err);
                    return res.status(500).json({ status: "error", message: "Session save error" });
                }
                
                const response = { 
                    status: "ok", 
                    message: "Authentication successful"
                };
                
                // Generate secure signed JWT for Custom Tab authentication
                if (fromCustomTab) {
                    console.log('[CUSTOM TAB AUTH] Generating JWT token for Custom Tab callback...');
                    const authToken = generateAuthToken({
                        userId: user.uuid,
                        email: email,
                        credentialId: credential.id, // Include for device identity setup
                        state: state // Include state for additional verification
                    });
                    
                    response.authToken = authToken;
                    console.log(`[CUSTOM TAB AUTH] ✓ JWT token generated for ${sanitizeForLog(user.email)} (expires: ${config.jwt.expiresIn})`);
                }
                // Include session secret for mobile clients
                else if (sessionSecret) {
                    response.sessionSecret = sessionSecret;
                    response.userId = user.uuid;
                    response.email = email;
                    console.log(`[WEBAUTHN] ✓ HMAC session credentials included in response for ${sanitizeForLog(email)}`);
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
        console.error('Error during authentication:', error);
        res.status(500).json({
            status: "error",
            message: error && error.message ? error.message : "Internal server error"
        });
    }
});

authRoutes.get("/webauthn/check", (req, res) => {
    if(req.session.authenticated || req.session.otp) res.status(200).json({authenticated: true});
    else res.status(401).json({authenticated: false});
});

authRoutes.get("/magic/generate", (req, res) => {
    
    if (req.session.authenticated && req.session.email && req.session.uuid) {
        // Generate magic key with new format: {serverUrl}:{randomHash}:{timestamp}:{hmacSignature}
        // Use hostname and explicit port to ensure port is included
        const host = req.get('host') || 'localhost:3000';
        // Check X-Forwarded-Proto header for reverse proxy HTTPS (Nginx, Cloudflare, etc.)
        const protocol = req.get('x-forwarded-proto') || req.protocol;
        const serverUrl = `${protocol}://${host}`;
        const randomHash = crypto.randomBytes(32).toString('hex');
        const timestamp = Date.now();
        const expiresAt = timestamp + 5 * 60 * 1000; // 5 min expiry
        
        console.log(`[Magic Key] Generating key with serverUrl: ${serverUrl}`);
        
        // Create HMAC signature using session secret
        const dataToSign = `${serverUrl}|${randomHash}|${timestamp}`;
        const hmac = crypto.createHmac('sha256', config.session.secret);
        hmac.update(dataToSign);
        const signature = hmac.digest('hex');
        
        // Construct magic key with pipe delimiter (safe for all URL formats including IPv6)
        const magicKey = `${serverUrl}|${randomHash}|${timestamp}|${signature}`;
        
        // Store in temporary store (one-time use)
        magicLinks[randomHash] = { 
            email: req.session.email, 
            uuid: req.session.uuid, 
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
    } else {
        res.status(401).json({authenticated: false});
    }
});

authRoutes.get("/webauthn/list", async (req, res) => {
    if(req.session.authenticated && req.session.email && req.session.uuid) {
        const user = await User.findOne({ where: { email: req.session.email } });
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
    } else {
        res.status(401).json({ status: "failed", message: "Unauthorized" });
    }
});

authRoutes.post("/client/addweb", async (req, res) => {
    if(req.session.authenticated && req.session.email && req.session.uuid) {
        try {
            const { clientId } = req.body;
            
            // Use shared function to find or create client
            const result = await findOrCreateClient(clientId, req.session.uuid, req);
            
            // Store in session for web clients
            req.session.deviceId = result.device_id;
            req.session.clientId = result.clientid;
            
            req.session.save(err => {
                if (err) {
                    console.error('Session save error:', err);
                    return res.status(500).json({ status: "error", message: "Session save error" });
                }
                res.status(200).json({ 
                    status: "ok", 
                    message: result.created ? "Client added successfully" : "Client updated successfully" 
                });
            });

        } catch (error) {
            console.error('Error adding client:', error);
            res.status(500).json({ status: "error", message: "Internal server error" });
        }
    } else {
        res.status(401).json({ status: "failed", message: "Unauthorized" });
    }
});

authRoutes.get("/client/list", async (req, res) => {
    if(req.session.authenticated && req.session.email && req.session.uuid) {
        try {
            const clients = await Client.findAll({ where: { owner: req.session.uuid }, attributes: { exclude: ['public_key', 'registration_id'] } });
            res.status(200).json({ status: "ok", clients: clients });
        } catch (error) {
            console.error('Error fetching client list:', error);
            res.status(500).json({ status: "error", message: "Internal server error" });
        }
    } else {
        res.status(401).json({ status: "failed", message: "Unauthorized" });
    }
});

authRoutes.post("/client/delete", async (req, res) => {
    if(req.session.authenticated && req.session.email && req.session.uuid) {
        try {
            const { clientId } = req.body
            await writeQueue.enqueue(
                () => Client.destroy({ where: { id: clientId, owner: req.session.uuid } }),
                'deleteClient'
            );
            res.status(200).json({ status: "ok", message: "Client deleted successfully" });
        } catch (error) {
            console.error('Error deleting client:', error);
            res.status(500).json({ status: "error", message: "Internal server error" });
        }
    } else {
        res.status(401).json({ status: "failed", message: "Unauthorized" });
    }
});
/*
authRoutes.post("/client/login", async (req, res) => {
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
            
            // Set user as active on login
            await writeQueue.enqueue(
                () => User.update(
                    { active: true },
                    { where: { uuid: owner.uuid } }
                ),
                'setUserActiveOnLogin'
            );
            
            res.status(200).json({ status: "ok", message: "Client login successful" });
        } else {
            res.status(401).json({ status: "failed", message: "Invalid client ID or not authorized" });
        }
    } catch (error) {
        console.error('Error during client login:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
    }
});

authRoutes.get("/channels", async (req, res) => {
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
            // REMOVED: Pug render (Pug disabled, Flutter web client used)
            res.status(410).json({ error: "Pug routes deprecated - use Flutter web client" });
        } else {
            res.redirect("/login");
        }
    } catch (error) {
        console.error('Error retrieving channels:', error);
        res.redirect("/error");
    }
});

authRoutes.post("/channels/create", async (req, res) => {
    try {
        if (req.session.authenticated && req.session.email && req.session.uuid) {
            let booleanIsPrivate = false;
            const { name, description, isPrivate, type } = req.body;
            if (isPrivate === "on") booleanIsPrivate = true;
            const owner = req.session.uuid;
            const channel = await writeQueue.enqueue(
                () => Channel.create({ name, description, private: booleanIsPrivate, owner, type }),
                'createChannel'
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

authRoutes.get("/thread/:id", async (req, res) => {
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
            res.redirect("/login");
        }
    } catch (error) {
        console.error('Error retrieving thread:', error);
        res.redirect("/error");
    }
});

authRoutes.get("/channel/:name", async (req, res) => {
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
                // REMOVED: Pug render (Pug disabled, Flutter web client used)
                res.status(410).json({ error: "Pug routes deprecated - use Flutter web client" });
            }
        } else {
            res.redirect("/login");
        }
    } catch (error) {
        console.error('Error retrieving channel:', error);
        res.redirect("/error");
    }
});

authRoutes.post("/channel/:name/post", async (req, res) => {
    try {
        if (req.session.authenticated && req.session.email && req.session.uuid) {
            const { message } = req.body;
            const sender = req.session.uuid;
            const channel = req.params.name;
            const thread = await writeQueue.enqueue(
                () => Thread.create({ message, sender, channel }),
                'createThread'
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

authRoutes.post("/usersettings", async (req, res) => {
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
                'updateUserSettings'
            );
            res.json({message: "User settings updated"});
        }
    } catch (error) {
        console.error('Error updating user settings:', error);
        res.json({ message: "Error updating user settings" });
    }
});
*/

/*authRoutes.post("/webauthn/sign-challenge", (req, res) => {
    let user = {
      id: base64url(crypto.randomBytes(16)),
      name: req.session.email,
    };
    console.log(user);
    store.challenge(req, { user: user }, function(err, challenge) {
        console.log(challenge);
      res.json({ user: user, challenge: base64url.encode(challenge) });
    });
});*/




// Implement webauthn login route
/*authRoutes.post("/webauthn/login", passport.authenticate('webauthn', {
    // Specify the authentication options if needed
    // For example, you can redirect to a different route on success or failure
    // See the documentation for more options: http://www.passportjs.org/docs/authenticate/
}), (req, res) => {
    // Handle the successful authentication
    res.send("WebAuthn login successful");
});*/

// Implement webauthn delete route
authRoutes.post("/webauthn/delete", (req, res) => {
    // Perform webauthn delete logic
    if(req.session.authenticated ) {
        const { credentialId } = req.body;
        User.findOne({ where: { email: req.session.email } }).then(async user => {
            if (user) {
                user.credentials = JSON.parse(user.credentials);
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
        }).catch(error => {
            console.error('Error deleting WebAuthn credential:', error);
            res.status(500).send("Internal Server Error");
        });
    } else {
        res.status(401).send("Unauthorized");
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
        console.error('Error verifying invitation:', error);
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
        const { token, clientId } = req.body;
        
        if (!token || !clientId) {
            return res.status(400).json({ error: 'Token and clientId required' });
        }
        
        console.log('[TOKEN EXCHANGE] Request received', { 
            hasToken: !!token, 
            clientId: clientId ? clientId.substring(0, 8) + '...' : 'missing'
        });
        
        // Verify JWT signature, expiration, and one-time use
        const decoded = verifyAuthToken(token);
        
        if (!decoded) {
            return res.status(401).json({ error: 'Invalid or expired token' });
        }
        
        const { userId, email, credentialId } = decoded;
        console.log('[TOKEN EXCHANGE] ✓ Token verified', { 
            userId: userId ? userId.substring(0, 8) + '...' : 'missing',
            email: email,
            hasCredentialId: !!credentialId
        });
        
        // Get user from database (use uuid, not id)
        const user = await User.findOne({ where: { uuid: userId } });
        if (!user) {
            return res.status(404).json({ error: 'User not found' });
        }
        
        // Use shared function to find or create Signal Client record (required for Signal protocol)
        const result = await findOrCreateClient(clientId, user.uuid, req);
        console.log('[TOKEN EXCHANGE] ✓ Client record ensured:', { 
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
        
        console.log('[TOKEN EXCHANGE] ✓ Session created for user', user.email, `(expires in ${sessionDays} days)`);
        
        res.json({
            sessionSecret,
            userId: user.uuid,
            email: user.email,
            credentialId: credentialId // Include for device identity setup
        });
        
    } catch (error) {
        console.error('[TOKEN EXCHANGE] Error:', error);
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
        
        if (!token) {
            return res.status(400).json({ error: 'Token required' });
        }
        
        console.log('[TOKEN REVOKE] Revocation requested');
        
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
        console.error('[TOKEN REVOKE] Error:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// POST /auth/session/refresh
// Manually refresh HMAC session (extends expiration)
// Requires valid HMAC authentication via sessionAuth middleware
const { verifySessionAuth } = require('../middleware/sessionAuth');

authRoutes.post('/session/refresh', verifySessionAuth, async (req, res) => {
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
        
        console.log(`[SESSION REFRESH] ✓ Session manually refreshed for client ${sanitizeForLog(clientId)} (${sessionDays} days)`);
        
        res.json({
            status: 'ok',
            message: 'Session refreshed successfully',
            expiresIn: sessionDays + ' days'
        });
        
    } catch (error) {
        console.error('[SESSION REFRESH] Error:', error);
        res.status(500).json({ error: 'Failed to refresh session' });
    }
});

module.exports = authRoutes;

