const config = require('../config/config');
const express = require("express");
const { Sequelize, DataTypes, Op, UUID } = require('sequelize');
const { Fido2Lib } = require('fido2-lib');
const bodyParser = require('body-parser'); // Import body-parser
const nodemailer = require("nodemailer");
const crypto = require('crypto');
const session = require('express-session');
const cors = require('cors');
const fetch = (...args) => import('node-fetch').then(({default: fetch}) => fetch(...args));
const magicLinks = require('../store/magicLinksStore');
const { User, OTP, Client } = require('../db/model');
const bcrypt = require("bcrypt");
const writeQueue = require('../db/writeQueue');
const { autoAssignRoles } = require('../db/autoAssignRoles');

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
    return btoa(String.fromCharCode(...new Uint8Array(buffer)))
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=+$/, '');
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

const transporter = nodemailer.createTransport(config.smtp);

const authRoutes = express.Router();

/*const sequelize = new Sequelize({
    dialect: 'sqlite',
    storage: './db/peerwave.sqlite',
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
authRoutes.use(bodyParser.urlencoded({ extended: true }));
authRoutes.use(bodyParser.json());

// Configure session middleware
authRoutes.use(session({
    secret: config.session.secret, // Replace with a strong secret key
    resave: config.session.resave,
    saveUninitialized: config.session.saveUninitialized,
    cookie: config.cookie // Set to true if using HTTPS
}));

// Implement register route
authRoutes.get("/register", (req, res) => {
    // Render the register form
    res.render("register");
});
authRoutes.post("/register", (req, res) => {

    const email = req.body.email;
    req.session.email = email; // Store email in session for later use

    if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
        return res.status(400).json({ error: "Invalid email address" });
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
                    return res.status(200).json({ status: "waitotp", wait: Math.ceil((existingOtp.expiration - Date.now()) / 1000)});
                } else {
                    // Send email with OTP
                    transporter.sendMail({
                        from: config.smtp.senderadress, // sender address
                        to: email, // list of receivers
                        subject: "Your OTP", // Subject line
                        text: `Your OTP is ${otp}` // plain text body
                    }).then(info => {
                        console.log("Message sent: %s", info.messageId);
                    }).catch(error => {
                        console.error(error);
                    });


                    // Save the OTP and email in a temporary storage for 5 minutes
                    const expiration = new Date().getTime() + 5 * 60 * 1000; // 5 minutes from now
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
            
            req.session.otp = true;
            req.session.authenticated = true;
            req.session.uuid = updatedUser.uuid; // ensure uuid present
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
            //res.render("register-webauthn");
        }
    }).catch(error => {
        console.error('Error finding OTP:', error);
        res.status(400).json({ error: "Invalid OTP" });
        //res.render("otp");
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

// Implement login route
/*authRoutes.get("/login", (req, res) => {
    // Render the login form
    res.render("login");
});
*/
// POST logout route - destroys session and clears cookie
authRoutes.post("/logout", async (req, res) => {
    // Support both HMAC (native) and Session (web) authentication
    const userId = req.userId || req.session.uuid;
    const deviceId = req.deviceId || req.session.deviceId;
    const clientId = req.clientId || req.session.clientId;
    
    console.log(`[AUTH] Logout request from user ${userId}, device ${deviceId}`);
    
    // If HMAC auth (native client), delete the HMAC session from database
    if (req.userId && clientId) {
        try {
            const { sequelize } = require('../db/model');
            await sequelize.query(
                'DELETE FROM client_sessions WHERE client_id = ?',
                { replacements: [clientId] }
            );
            console.log(`[AUTH] ✓ HMAC session deleted for client ${clientId}`);
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
        
        console.log(`[AUTH] ✓ Session destroyed for user ${userId}, device ${deviceId}`);
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

    const host = req.hostname; // "localhost" oder deine ngrok-domain
    // Allow ngrok and localhost for WebAuthn
    const allowedOrigins = [
        "http://localhost:3000",
        "http://localhost:55831",
        `https://${host}`
    ];
    challenge.rp = {
        name: "PeerWave",
        id: host   // muss exakt zum Browser-Origin passen!
    };

    challenge.user = {
        id: base64UrlEncode(uuidArrayBuffer),
        name: user.email,
        displayName: user.email,
    };

    // Challenge auf beides vorbereiten
    challenge.authenticatorSelection = {
        authenticatorAttachment: "platform",
        userVerification: "required"  // damit PIN/Windows Hello angezeigt wird
        // authenticatorAttachment NICHT setzen → erlaubt Plattform + Roaming
    };

    // Optional: andere Policies
    challenge.attestation = "none"; // oder "direct" je nach Security/Privacy

    challenge.challenge = base64UrlEncode(challenge.challenge);

    req.session.challenge = challenge.challenge;
    res.json(challenge);
});

// Verify registration response
authRoutes.post('/webauthn/register', async (req, res) => {
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
            const allowedOrigins = [
                "http://localhost:3000",
                "http://localhost:55831",
                `https://${host}`
            ];
            let origin = req.headers.origin || `https://${host}`;
            if (!allowedOrigins.includes(origin)) {
                console.warn("Unexpected origin for WebAuthn:", origin);
                origin = `https://${host}`;
            }

            const attestationExpectations = {
                challenge: challenge,
                origin: origin,
                factor: "either",
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
            user.credentials.push({
                id: base64UrlEncode(regResult.authnrData.get("credId")),
                publicKey: regResult.authnrData.get("credentialPublicKeyPem"),
                browser: userAgent,
                created: timestamp,
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

            res.json({ status: "ok" });
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

        // Domain/Origin dynamisch bestimmen
        const host = req.hostname; // z. B. "localhost" oder "abc123.ngrok-free.app"
        const protocol = req.secure ? "https" : "http";
        const origin = `${protocol}://${host}`;

        // RP Infos überschreiben
        challenge.rp = {
            name: "PeerWave",
            id: host,
        };

        user.credentials = JSON.parse(user.credentials);

        challenge.allowCredentials = user.credentials.map(cred => ({
            id: cred.id,
            type: "public-key",
        }));

        challenge.challenge = base64UrlEncode(challenge.challenge);
        req.session.challenge = challenge.challenge;
        res.json(challenge);
    } catch (error) {
        console.error('Error:', error);
        if(error.code === 401 && error.email) {
            const otp = Math.floor(100000 + Math.random() * 900000); // Generate a 6-digit OTP
            const email = error.email; // Get the registered email

            transporter.sendMail({
                from: config.smtp.senderadress, // sender address
                to: email, // list of receivers
                subject: "Your OTP", // Subject line
                text: `Your OTP is ${otp}` // plain text body
            }).then(info => {
                console.log("Message sent: %s", info.messageId);
            }).catch(error => {
                console.error(error);
            });

            const expiration = new Date().getTime() + 10 * 60 * 1000; // 10 minutes from now
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
        const { email, assertion } = req.body;
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

        const host = req.hostname;
        const allowedOrigins = [
            "http://localhost:3000",
            "http://localhost:55831",
            `https://${host}`
        ];
        let origin = req.headers.origin || `https://${host}`;
        if (!allowedOrigins.includes(origin)) {
            console.warn("Unexpected origin for WebAuthn:", origin);
            origin = `https://${host}`;
        }

        const assertionExpectations = {
            challenge: challenge,
            origin: origin,
            factor: "either",
            publicKey: credential.publicKey,
            prevCounter: 0,
            userHandle: assertion.response.userHandle,
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
            
            // Optional: attach client info immediately if provided
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
            // Persist session now
            return req.session.save(err => {
                if (err) {
                    console.error('Session save error (/webauthn/authenticate):', err);
                    return res.status(500).json({ status: "error", message: "Session save error" });
                }
                if(!user.backupCodes) {
                    res.status(202).json({ status: "ok", message: "Authentication successful" });
                } else {
                    res.status(200).json({ status: "ok", message: "Authentication successful" });
                }
            });
        } else {
            // Authentication failed
            res.status(400).json({ status: "failed", message: "Authentication failed" });
        }
    } catch (error) {
        console.error('Error during authentication:', error);
        res.status(500).json({ status: "error", message: "Internal server error" });
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
        const serverUrl = `${req.protocol}://${host}`;
        const randomHash = crypto.randomBytes(32).toString('hex');
        const timestamp = Date.now();
        const expiresAt = timestamp + 5 * 60 * 1000; // 5 min expiry
        
        console.log(`[Magic Key] Generating key with serverUrl: ${serverUrl}`);
        
        // Create HMAC signature using session secret
        const dataToSign = `${serverUrl}:${randomHash}:${timestamp}`;
        const hmac = crypto.createHmac('sha256', config.session.secret);
        hmac.update(dataToSign);
        const signature = hmac.digest('hex');
        
        // Construct magic key in hex format
        const magicKey = `${serverUrl}:${randomHash}:${timestamp}:${signature}`;
        
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
                created: cred.created || null,
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
            const { clientId } = req.body
            const userAgent = req.headers['user-agent'] || '';
            const ip = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
            const location = await getLocationFromIp(ip);
            const locationString = location
                    ? `${location.city}, ${location.region}, ${location.country} (${location.org})`
                    : "Location not found";
            const maxDevice = await Client.max('device_id', { where: { owner: req.session.uuid } });
            const [client, created] = await Client.findOrCreate({
                where: { clientid: clientId, owner: req.session.uuid },
                defaults: {
                    owner: req.session.uuid,
                    clientid: clientId,
                    ip: ip,
                    browser: userAgent,
                    location: locationString,
                    device_id: maxDevice ? maxDevice + 1 : 1
                }
            });
            console.log(client, created);
            // device_id kann je nach Sequelize-Return als getter oder plain property vorliegen
            req.session.deviceId = client.device_id || (client.get ? client.get('device_id') : undefined);
            req.session.clientId = client.clientid || (client.get ? client.get('clientid') : undefined);
            req.session.save(err => {
                if (err) {
                    console.error('Session save error:', err);
                    return res.status(500).json({ status: "error", message: "Session save error" });
                }
                if (!created) {
                    writeQueue.enqueue(
                        () => Client.update({ ip: ip, browser: userAgent, location: locationString }, { where: { clientid: client.clientid } }),
                        'updateClientInfo'
                    )
                        .then(() => {
                            res.status(200).json({ status: "ok", message: "Client updated successfully" });
                        })
                        .catch(error => {
                            console.error('Error updating client:', error);
                            res.status(500).json({ status: "error", message: "Internal server error" });
                        });
                } else {
                    res.status(200).json({ status: "ok", message: "Client added successfully" });
                }
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
            res.render("channels", { channels: channels, threads: threads, user: user });
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
                res.render("channel", { channel: channel, threads: threads, channels: channels, user: user });
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

module.exports = authRoutes;
