const config = require('../config/config');
const express = require("express");
const { Sequelize, DataTypes, Op, UUID } = require('sequelize');
const { Fido2Lib } = require('fido2-lib');
const bodyParser = require('body-parser'); // Import body-parser
const nodemailer = require("nodemailer");
const crypto = require('crypto');
const session = require('express-session');

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

const fido2 = new Fido2Lib({
    timeout: 60000,
    rpId: "localhost",
    rpName: "PeerWave",
    challengeSize: 32,
    attestation: "none",
    cryptoParams: [-7, -257],
});

const transporter = nodemailer.createTransport(config.smtp);

const authRoutes = express.Router();

const sequelize = new Sequelize({
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

    User.create({ email })
        .then(user => {
            const otp = Math.floor(10000 + Math.random() * 90000); // Generate a 5-digit OTP
            const email = user.email; // Get the registered email

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


            // Save the OTP and email in a temporary storage for 10 minutes
            const expiration = new Date().getTime() + 10 * 60 * 1000; // 10 minutes from now
            OTP.create({ email, otp, expiration })
            .then(otp => {
                console.log('OTP created successfully:', otp);
                req.session.email = otp.email;
                res.render("otp");
            }).catch(error => {
                console.error('Error creating OTP:', error);
            });

            // Store the temporary storage in a database or cache
            // For example, you can use Redis or a database table to store the temporary storage
            // Make sure to handle the expiration and cleanup of expired OTPs
            // Render the otp form
        })
        .catch(error => {
            console.error('Error creating user:', error);
            res.render("register");
        });

});

authRoutes.post("/otp", (req, res) => {
    const { otp } = req.body;
    const email = req.session.email; // Retrieve email from session
    OTP.findOne({ where: { email: email, otp: otp } }).then(() => {
        OTP.destroy({ where: { email: email } });
        req.session.otp = true;
        res.render("register-webauthn");
    }).catch(error => {
        console.error('Error finding OTP:', error);
        res.render("otp");
    });
});

// Implement login route
authRoutes.get("/login", (req, res) => {
    // Render the login form
    res.render("login");
});

// Implement logout route
authRoutes.get("/logout", (req, res) => {
    // Perform logout logic
    res.redirect("/");
});

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
    const username = req.session.email; // Retrieve email from session
    const user = { id: crypto.randomBytes(16), username, credentials: [] };

    const challenge = await fido2.attestationOptions();
    challenge.user = {
        id: base64UrlEncode(user.id),
        name: user.username,
        displayName: user.username,
    };

    challenge.challenge = base64UrlEncode(challenge.challenge);

    req.session.challenge = challenge.challenge;
    res.json(challenge);
});

// Verify registration response
authRoutes.post('/webauthn/register', async (req, res) => {
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

        const attestationExpectations = {
            challenge: challenge,
            origin: "http://localhost:3000",
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

        user.credentials.push({
            id: base64UrlEncode(regResult.authnrData.get("credId")),
            publicKey: regResult.authnrData.get("credentialPublicKeyPem"),
        });

        user.credentials = JSON.stringify(user.credentials);

        user.changed('credentials', true);

        await user.save();

        res.json({ status: "ok" });
    } catch (error) {
        console.error('Error during registration:', error);
        res.json({ status: "error" });
    }
});

// Generate authentication challenge
authRoutes.post('/webauthn/authenticate-challenge', async (req, res) => {
    try {
        const { email } = req.body;
        console.log(req.body);
        const user = await User.findOne({ where: { email: email } });

        console.log(user);

        if (!user.credentials) {
            throw new Error("User credentials are null.");
        }

        console.log(typeof user.credentials, user.credentials, JSON.parse(user.credentials));

        const challenge = await fido2.assertionOptions();

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
        res.json({ status: "error" });
    }
});

// Verify authentication response
authRoutes.post('/webauthn/authenticate', async (req, res) => {
    try {
        const { email, assertion } = req.body;
        //const user = users[username];

        assertion.rawId = base64UrlDecode(assertion.rawId);
        assertion.response.authenticatorData = base64UrlDecode(assertion.response.authenticatorData);
        assertion.response.clientDataJSON = base64UrlDecode(assertion.response.clientDataJSON);
        assertion.response.signature = base64UrlDecode(assertion.response.signature);
        assertion.response.userHandle = base64UrlDecode(assertion.response.userHandle);

        const user = await User.findOne({ where: { email: email } });
        console.log(user);
        user.credentials = JSON.parse(user.credentials);
        const credential = user.credentials.find(cred => cred.id === assertion.id);

        if (credential) {
            // Credential found, proceed with authentication
        } else {
            // Credential not found, handle authentication failure
        }
        const challenge = base64UrlDecode(req.session.challenge);

    const allowedOrigins = [
        "http://localhost:3000",
        "http://localhost:55831"
        ];
        let origin = req.headers.origin || "http://localhost:3000";
        if (!allowedOrigins.includes(origin)) {
        console.warn("Unexpected origin for WebAuthn:", origin);
        origin = "http://localhost:3000";
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
            //res.redirect('/channels');
            res.status(200).json({ status: "ok", message: "Authentication successful" });
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
    if(req.session.authenticated) res.status(200).json({authenticated: true});
    else res.status(401).json({authenticated: false});
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
            await user.save();
            res.json({message: "User settings updated"});
        }
    } catch (error) {
        console.error('Error updating user settings:', error);
        res.json({ message: "Error updating user settings" });
    }
});

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
    res.send("WebAuthn credential deleted");
});

module.exports = authRoutes;
