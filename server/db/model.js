const config = require('../config/config');
const express = require("express");
const { Sequelize, DataTypes, Op, UUID } = require('sequelize');
const { DESCRIBE } = require('sequelize/lib/query-types');
const logger = require('../utils/logger');

const sequelize = new Sequelize({
    dialect: 'sqlite',
    storage: process.env.DB_PATH || './data/peerwave.sqlite',
    pool: {
        max: 1,        // SQLite: Only one writer at a time
        min: 0,
        acquire: 30000, // 30 seconds timeout for acquiring connection
        idle: 10000
    },
    retry: {
        max: 5,        // Retry up to 5 times on errors
        match: [
            /SQLITE_BUSY/,
            /database is locked/,
            /SequelizeTimeoutError/
        ]
    },
    logging: false // Disable query logging for performance
});

const temporaryStorage = new Sequelize({
    dialect: 'sqlite',
    storage: ':memory:'
});

// Database sync happens after migrations (in server.js)
// Migrations modify existing schema, sync creates missing tables

// Export a promise that resolves when database is ready
const dbReady = new Promise((resolve, reject) => {
    sequelize.authenticate()
        .then(async () => {
            logger.info('✓ Model connected to database');
            
            // Sync models to database (alter=false since migrations handle schema updates)
            await sequelize.sync({ alter: false });
            logger.info('✓ Database schema synced');
            
            // Apply SQLite optimizations
            try {
                await sequelize.query("PRAGMA journal_mode=WAL");
                await sequelize.query("PRAGMA busy_timeout=5000");
                await sequelize.query("PRAGMA synchronous=NORMAL");
                await sequelize.query("PRAGMA cache_size=-64000");
                await sequelize.query("PRAGMA temp_store=MEMORY");
                logger.info('✓ SQLite optimizations applied');
            } catch (error) {
                logger.warn('⚠ SQLite optimization warning:', error.message);
            }
            
            resolve(); // Database is ready
        })
        .catch(error => {
            logger.error('Unable to connect to the database:', error);
            reject(error);
        });
});

    temporaryStorage.authenticate()
    .then(async () => {
        logger.info('✓ Temporary storage (in-memory) initialized');
        // Sync in-memory tables
        await temporaryStorage.sync();
    })
    .catch(error => {
        logger.error('Unable to connect to the temp database:', error);
        process.exit(1);
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
    atName: {
        type: DataTypes.STRING,
        allowNull: true,
        unique: true
    },
    backupCodes: {
        type: DataTypes.TEXT,
        allowNull: true
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
    active: {
        type: DataTypes.BOOLEAN,
        allowNull: false,
        defaultValue: true
    },
    // Per-user notification settings (server-side)
    meeting_invite_email_enabled: {
        type: DataTypes.BOOLEAN,
        allowNull: false,
        defaultValue: true
    },
    meeting_rsvp_email_to_organizer_enabled: {
        type: DataTypes.BOOLEAN,
        allowNull: false,
        defaultValue: true
    },
    meeting_update_email_enabled: {
        type: DataTypes.BOOLEAN,
        allowNull: false,
        defaultValue: true
    },
    meeting_cancel_email_enabled: {
        type: DataTypes.BOOLEAN,
        allowNull: false,
        defaultValue: true
    },
    meeting_self_invite_email_enabled: {
        type: DataTypes.BOOLEAN,
        allowNull: false,
        defaultValue: false
    }
});

const Role = sequelize.define('Role', {
    name: {
        type: DataTypes.STRING,
        allowNull: false
    },
    description: {
        type: DataTypes.STRING,
        allowNull: true
    },
    uuid: {
        type: DataTypes.UUID,
        defaultValue: Sequelize.UUIDV4,
        primaryKey: true,
        allowNull: false,
        unique: true
    },
    permissions: {
        type: DataTypes.TEXT,
        allowNull: true,
        get() {
            const rawValue = this.getDataValue('permissions');
            return rawValue ? JSON.parse(rawValue) : [];
        },
        set(value) {
            this.setDataValue('permissions', JSON.stringify(value));
        }
    },
    scope: {
        type: DataTypes.ENUM('server', 'channelWebRtc', 'channelSignal'),
        allowNull: false,
        defaultValue: 'server'
    },
    standard: {
        type: DataTypes.BOOLEAN,
        allowNull: false,
        defaultValue: false
    }
}, {
    indexes: [
        {
            unique: true,
            fields: ['name', 'scope']
        }
    ]
});

const SignalPreKey = sequelize.define('SignalPreKey', {
    client: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Clients',
            key: 'clientid'
        }
    },
    owner: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Users',
            key: 'uuid'
        }
    },
    prekey_id: {
        type: DataTypes.INTEGER,
        allowNull: false,
    },
    prekey_data: {
        type: DataTypes.TEXT,
        allowNull: false,
    }
}, {
    indexes: [
        {
            unique: true,
            fields: ['client', 'prekey_id']
        }
    ],
    // Optional: Wenn du möchtest, dass dies der Primärschlüssel ist:
    primaryKey: false // (wird ignoriert, aber keine einzelne Spalte ist PK)
});

const SignalSignedPreKey = sequelize.define('SignalSignedPreKey', {
    client: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Clients',
            key: 'clientid'
        }
    },
    owner: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Users',
            key: 'uuid'
        }
    },
    signed_prekey_id: {
        type: DataTypes.INTEGER,
        allowNull: false,
    },
    signed_prekey_data: {
        type: DataTypes.TEXT,
        allowNull: false,
    },
    signed_prekey_signature: {
        type: DataTypes.TEXT,
        allowNull: false,
    }
}, {
    indexes: [
        {
            unique: true,
            fields: ['client', 'signed_prekey_id']
        }
    ],
    // Optional: Wenn du möchtest, dass dies der Primärschlüssel ist:
    primaryKey: false // (wird ignoriert, aber keine einzelne Spalte ist PK)
});

// SignalSenderKey - Stores sender keys for TEXT/VIDEO CHANNELS ONLY
// NOTE: Meetings and instant calls do NOT use this table
// They use 1:1 Signal sessions for encryption (peer-to-peer key exchange)
const SignalSenderKey = sequelize.define('SignalSenderKey', {
    channel: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Channels',
            key: 'uuid'
        }
    },
    client: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Clients',
            key: 'clientid'
        }
    },
    owner: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Users',
            key: 'uuid'
        }
    },
    sender_key: {
        type: DataTypes.TEXT,
        allowNull: false,
    }
}, {
    timestamps: true,
    indexes: [
        {
            unique: true,
            fields: ['channel', 'client']
        }
    ]
});

// Group Item Model - stores encrypted items (messages, reactions, etc.) for group chats
// One encrypted payload for all members - much more efficient than Item table
const GroupItem = sequelize.define('GroupItem', {
    uuid: {
        type: DataTypes.UUID,
        defaultValue: Sequelize.UUIDV4,
        primaryKey: true,
        allowNull: false,
        unique: true
    },
    itemId: {
        type: DataTypes.UUID,
        allowNull: false,
        unique: true  // Client-generated ID for deduplication
    },
    channel: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Channels',
            key: 'uuid'
        }
    },
    sender: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Users',
            key: 'uuid'
        }
    },
    senderDevice: {
        type: DataTypes.INTEGER,
        allowNull: false
    },
    type: {
        type: DataTypes.STRING,
        allowNull: false,
        defaultValue: 'message'  // 'message', 'reaction', 'file', etc.
    },
    payload: {
        type: DataTypes.TEXT,
        allowNull: false  // Encrypted with sender's SenderKey
    },
    cipherType: {
        type: DataTypes.INTEGER,
        allowNull: false,
        defaultValue: 4  // 4 = SenderKey encryption
    },
    timestamp: {
        type: DataTypes.DATE,
        allowNull: false,
        defaultValue: Sequelize.NOW
    }
}, {
    timestamps: true,  // createdAt, updatedAt
    indexes: [
        {
            fields: ['channel', 'timestamp']  // Fast queries for channel messages
        },
        {
            fields: ['itemId']  // Fast lookups by client ID
        },
        {
            fields: ['sender', 'channel']  // Fast queries for user's messages in channel
        }
    ]
});

// Group Item Read Receipts - tracks who has read which items
const GroupItemRead = sequelize.define('GroupItemRead', {
    id: {
        type: DataTypes.INTEGER,
        primaryKey: true,
        autoIncrement: true
    },
    itemId: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'GroupItems',
            key: 'uuid'
        }
    },
    userId: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Users',
            key: 'uuid'
        }
    },
    deviceId: {
        type: DataTypes.INTEGER,
        allowNull: false
    },
    readAt: {
        type: DataTypes.DATE,
        allowNull: false,
        defaultValue: Sequelize.NOW
    }
}, {
    timestamps: false,
    indexes: [
        {
            unique: true,
            fields: ['itemId', 'userId', 'deviceId']  // One read receipt per device
        },
        {
            fields: ['itemId']  // Fast count of reads per item
        }
    ]
});

// Junction table for User-Role relationship (scope: server)
const UserRole = sequelize.define('UserRole', {
    userId: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Users',
            key: 'uuid'
        }
    },
    roleId: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Roles',
            key: 'uuid'
        }
    }
}, {
    indexes: [
        {
            unique: true,
            fields: ['userId', 'roleId']
        }
    ]
});

// Junction table for User-Role-Channel relationship (scope: channelWebRtc, channelSignal)
const UserRoleChannel = sequelize.define('UserRoleChannel', {
    userId: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Users',
            key: 'uuid'
        }
    },
    roleId: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Roles',
            key: 'uuid'
        }
    },
    channelId: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Channels',
            key: 'uuid'
        }
    }
}, {
    indexes: [
        {
            unique: true,
            fields: ['userId', 'roleId', 'channelId']
        }
    ]
});

// Junction table for Channel Members
const ChannelMembers = sequelize.define('ChannelMembers', {
    userId: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Users',
            key: 'uuid'
        }
    },
    channelId: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Channels',
            key: 'uuid'
        }
    },
    permission: {
        type: DataTypes.STRING,
        allowNull: true,
        defaultValue: 'member'
    }
}, {
    indexes: [
        {
            unique: true,
            fields: ['userId', 'channelId']
        }
    ]
});

const Channel = sequelize.define('Channel', {
    uuid: {
        type: DataTypes.UUID,
        defaultValue: Sequelize.UUIDV4,
        primaryKey: true,
        allowNull: false,
        unique: true
    },
    name: {
        type: DataTypes.STRING,
        allowNull: false,
    },
    description: {
        type: DataTypes.STRING,
        allowNull: true
    },
    owner: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Users',
            key: 'uuid'
        }
    },
    private: {
        type: DataTypes.BOOLEAN,
        allowNull: false,
        defaultValue: false
    },
    type: {
        type: DataTypes.STRING,
        allowNull: false
    },
    defaultRoleId: {
        type: DataTypes.UUID,
        allowNull: true,
        references: {
            model: 'Roles',
            key: 'uuid'
        }
    }
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
        type: DataTypes.UUID,
        defaultValue: Sequelize.UUIDV4,
        primaryKey: true,
        allowNull: false,
        unique: true
    },
    device_id: {
        type: DataTypes.INTEGER,
        allowNull: false,
    },
    public_key: {
        type: DataTypes.TEXT,
        allowNull: true
    },
    registration_id: {
        type: DataTypes.TEXT,
        allowNull: true
    },
    ip: {
        type: DataTypes.STRING,
        allowNull: true
    },
    browser: {
        type: DataTypes.STRING,
        allowNull: true
    },
    location: {
        type: DataTypes.STRING,
        allowNull: true
    }
},
{
    indexes: [
        {
            unique: true,
            fields: ['owner', 'device_id']
        }
    ]
});

// Item Model - for 1:1 direct messages only (not for group messages)
// Group messages use GroupItem model instead
const Item = sequelize.define('Item', {
    uuid: {
        type: DataTypes.UUID,
        defaultValue: Sequelize.UUIDV4,
        primaryKey: true,
        allowNull: false,
        unique: true
    },
    deviceReceiver: {
        type: DataTypes.INTEGER,
        allowNull: false
        // keine Foreign-Key-Referenzierung mehr
    },
    receiver: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Users',
            key: 'uuid'
        }
    },
    sender: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Users',
            key: 'uuid'
        }
    },
    deviceSender: {
        type: DataTypes.INTEGER,
        allowNull: false
        // keine Foreign-Key-Referenzierung mehr
    },
    readed: {
        type: DataTypes.BOOLEAN,
        allowNull: false,
        defaultValue: false
    },
    itemId: {
        type: DataTypes.UUID,
        allowNull: false
    },
    type: {
        type: DataTypes.STRING,
        allowNull: false
    },
    payload: {
        type: DataTypes.TEXT,
        allowNull: false
    },
    cipherType: {
        type: DataTypes.INTEGER,
        allowNull: false
    },
    deliveredAt: {
        type: DataTypes.DATE,
        allowNull: true
    }
    // NOTE: Item table is ONLY for 1:1 messages (no channel field needed)
    // Group messages use the separate GroupItem table which has a channel field
}, { timestamps: true }); // Enable timestamps for createdAt tracking


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

// External participant sessions (guests joining meetings) - stored in memory
const ExternalSession = temporaryStorage.define('ExternalSession', {
    session_id: {
        type: DataTypes.STRING,
        primaryKey: true,
        allowNull: false
    },
    meeting_id: {
        type: DataTypes.STRING,
        allowNull: false
    },
    display_name: {
        type: DataTypes.STRING,
        allowNull: false
    },
    identity_key_public: {
        type: DataTypes.TEXT,
        allowNull: false
    },
    signed_pre_key: {
        type: DataTypes.TEXT,
        allowNull: false
    },
    pre_keys: {
        type: DataTypes.TEXT,
        allowNull: false
    },
    admitted: {
        type: DataTypes.BOOLEAN,
        allowNull: true,
        defaultValue: null
        // null: not requesting or declined (can retry)
        // false: actively requesting admission
        // true: admitted and can join
    },
    last_admission_request: {
        type: DataTypes.DATE,
        allowNull: true
        // Tracks last admission request for cooldown enforcement
    },
    admitted_by: {
        type: DataTypes.STRING,
        allowNull: true
    },
    joined_at: {
        type: DataTypes.DATE,
        allowNull: true
    },
    left_at: {
        type: DataTypes.DATE,
        allowNull: true
    },
    expires_at: {
        type: DataTypes.DATE,
        allowNull: false
    }
});

// Meeting invitation tokens - persistent storage for external guest invitations
// One meeting can have multiple invitation tokens
const MeetingInvitation = sequelize.define('MeetingInvitation', {
    id: {
        type: DataTypes.INTEGER,
        primaryKey: true,
        autoIncrement: true
    },
    meeting_id: {
        type: DataTypes.STRING,
        allowNull: false
    },
    token: {
        type: DataTypes.STRING,
        allowNull: false,
        unique: true
    },
    label: {
        type: DataTypes.STRING,
        allowNull: true
        // Optional label like "Guest Link 1", "Partner Invite"
    },
    created_by: {
        type: DataTypes.STRING,
        allowNull: false
    },
    expires_at: {
        type: DataTypes.DATE,
        allowNull: true
        // null = never expires
    },
    max_uses: {
        type: DataTypes.INTEGER,
        allowNull: true
        // null = unlimited uses
    },
    use_count: {
        type: DataTypes.INTEGER,
        allowNull: false,
        defaultValue: 0
    },
    is_active: {
        type: DataTypes.BOOLEAN,
        allowNull: false,
        defaultValue: true
    }
}, {
    timestamps: true,
    underscored: true,
    createdAt: 'created_at',
    updatedAt: 'updated_at',
    tableName: 'meeting_invitations',
    indexes: [
        { fields: ['meeting_id'] },
        { fields: ['token'], unique: true },
        { fields: ['is_active'] }
    ]
});

// Meeting RSVP status - persistent per-invitee status for scheduled meetings
const MeetingRsvp = sequelize.define('MeetingRsvp', {
    id: {
        type: DataTypes.INTEGER,
        primaryKey: true,
        autoIncrement: true
    },
    meeting_id: {
        type: DataTypes.STRING,
        allowNull: false
    },
    invitee_user_id: {
        type: DataTypes.STRING,
        allowNull: true
    },
    invitee_email: {
        type: DataTypes.STRING,
        allowNull: true
    },
    status: {
        type: DataTypes.STRING,
        allowNull: false,
        defaultValue: 'invited'
    },
    responded_at: {
        type: DataTypes.DATE,
        allowNull: true
    }
}, {
    timestamps: true,
    underscored: true,
    createdAt: 'created_at',
    updatedAt: 'updated_at',
    tableName: 'meeting_rsvps',
    indexes: [
        { fields: ['meeting_id'] },
        { fields: ['meeting_id', 'invitee_user_id'], unique: true },
        { fields: ['meeting_id', 'invitee_email'], unique: true }
    ]
});

// Meetings table - persistent storage for scheduled meetings
// Note: Instant calls are memory-only, not stored here
// Runtime state (participants, status, LiveKit rooms) is in MeetingMemoryStore
const Meeting = sequelize.define('Meeting', {
    meeting_id: {
        type: DataTypes.STRING(255),
        primaryKey: true,
        allowNull: false
    },
    title: {
        type: DataTypes.STRING(255),
        allowNull: false
    },
    description: {
        type: DataTypes.TEXT,
        allowNull: true
    },
    created_by: {
        type: DataTypes.STRING(255),
        allowNull: false
    },
    start_time: {
        type: DataTypes.DATE,
        allowNull: false
    },
    end_time: {
        type: DataTypes.DATE,
        allowNull: false
    },
    is_instant_call: {
        type: DataTypes.BOOLEAN,
        allowNull: false,
        defaultValue: false
    },
    allow_external: {
        type: DataTypes.BOOLEAN,
        allowNull: false,
        defaultValue: false
    },
    invitation_token: {
        type: DataTypes.STRING(255),
        allowNull: true
    },
    invited_participants: {
        type: DataTypes.TEXT,
        allowNull: true,
        get() {
            const raw = this.getDataValue('invited_participants');
            return raw ? JSON.parse(raw) : [];
        },
        set(value) {
            this.setDataValue('invited_participants', JSON.stringify(value));
        }
    },
    voice_only: {
        type: DataTypes.BOOLEAN,
        allowNull: false,
        defaultValue: false
    },
    mute_on_join: {
        type: DataTypes.BOOLEAN,
        allowNull: false,
        defaultValue: false
    }
}, {
    timestamps: true,
    underscored: true,
    createdAt: 'created_at',
    updatedAt: 'updated_at',
    tableName: 'meetings',
    indexes: [
        { fields: ['created_by'] },
        { fields: ['start_time'] },
        { fields: ['end_time'] },
        { fields: ['is_instant_call'] },
        { fields: ['invitation_token'] }
    ]
});

// Client Sessions table for HMAC authentication (native clients)
const ClientSession = sequelize.define('ClientSession', {
    client_id: {
        type: DataTypes.STRING,
        allowNull: false,
        primaryKey: true
    },
    session_secret: {
        type: DataTypes.STRING(255),
        allowNull: false
    },
    user_id: {
        type: DataTypes.STRING,
        allowNull: false
    },
    expires_at: {
        type: DataTypes.DATE,
        allowNull: true
    },
    device_info: {
        type: DataTypes.TEXT,
        allowNull: true
    },
    last_used: {
        type: DataTypes.DATE,
        allowNull: false,
        defaultValue: DataTypes.NOW
    }
}, {
    tableName: 'client_sessions',
    timestamps: true,
    createdAt: 'created_at',
    updatedAt: false
});

// Nonce cache table for replay attack prevention
const NonceCache = sequelize.define('NonceCache', {
    nonce: {
        type: DataTypes.STRING(255),
        allowNull: false,
        primaryKey: true
    },
    created_at: {
        type: DataTypes.DATE,
        allowNull: false,
        defaultValue: DataTypes.NOW
    }
}, {
    tableName: 'nonce_cache',
    timestamps: false
});

// Basic associations
User.hasMany(Client, { foreignKey: 'owner' });
User.hasMany(SignalPreKey, { foreignKey: 'owner' });
User.hasMany(SignalSignedPreKey, { foreignKey: 'owner' });
User.hasMany(Channel, { foreignKey: 'owner', as: 'OwnedChannels' });
Channel.belongsTo(User, { foreignKey: 'owner', as: 'Owner' });
Client.hasMany(SignalSignedPreKey, { foreignKey: 'client' });
Client.hasMany(SignalPreKey, { foreignKey: 'client' });

// Signal Sender Key associations for Group Chats (text channels only)
Channel.hasMany(SignalSenderKey, { foreignKey: 'channel' });
SignalSenderKey.belongsTo(Channel, { foreignKey: 'channel' });
Client.hasMany(SignalSenderKey, { foreignKey: 'client' });
SignalSenderKey.belongsTo(Client, { foreignKey: 'client' });
User.hasMany(SignalSenderKey, { foreignKey: 'owner' });
SignalSenderKey.belongsTo(User, { foreignKey: 'owner' });

// Group Item associations (encrypted group messages/items)
Channel.hasMany(GroupItem, { foreignKey: 'channel', as: 'GroupItems' });
GroupItem.belongsTo(Channel, { foreignKey: 'channel' });
User.hasMany(GroupItem, { foreignKey: 'sender', as: 'SentGroupItems' });
GroupItem.belongsTo(User, { foreignKey: 'sender', as: 'Sender' });

// Group Item Read Receipt associations
GroupItem.hasMany(GroupItemRead, { foreignKey: 'itemId', as: 'ReadReceipts' });
GroupItemRead.belongsTo(GroupItem, { foreignKey: 'itemId', as: 'Item' });
User.hasMany(GroupItemRead, { foreignKey: 'userId', as: 'ReadItems' });
GroupItemRead.belongsTo(User, { foreignKey: 'userId', as: 'User' });

// Channel Members associations
User.hasMany(ChannelMembers, { foreignKey: 'userId', as: 'ChannelMemberships' });
ChannelMembers.belongsTo(User, { foreignKey: 'userId' });
Channel.hasMany(ChannelMembers, { foreignKey: 'channelId', as: 'Memberships' });
ChannelMembers.belongsTo(Channel, { foreignKey: 'channelId' });

// Role associations
// Many-to-Many: User <-> Role (for scope: server)
User.belongsToMany(Role, { 
    through: UserRole, 
    as: 'ServerRoles',
    foreignKey: 'userId',
    otherKey: 'roleId'
});
Role.belongsToMany(User, { 
    through: UserRole, 
    as: 'Users',
    foreignKey: 'roleId',
    otherKey: 'userId'
});

// Many-to-Many: User <-> Role <-> Channel (for scope: channelWebRtc, channelSignal)
User.belongsToMany(Role, { 
    through: UserRoleChannel, 
    as: 'ChannelRoles',
    foreignKey: 'userId',
    otherKey: 'roleId'
});
Role.belongsToMany(User, { 
    through: UserRoleChannel, 
    as: 'ChannelUsers',
    foreignKey: 'roleId',
    otherKey: 'userId'
});
Channel.belongsToMany(Role, { 
    through: UserRoleChannel, 
    as: 'Roles',
    foreignKey: 'channelId',
    otherKey: 'roleId'
});
Role.belongsToMany(Channel, { 
    through: UserRoleChannel, 
    as: 'Channels',
    foreignKey: 'roleId',
    otherKey: 'channelId'
});

// Direct associations for UserRoleChannel to allow includes
UserRoleChannel.belongsTo(User, { foreignKey: 'userId', as: 'User' });
UserRoleChannel.belongsTo(Role, { foreignKey: 'roleId', as: 'Role' });
UserRoleChannel.belongsTo(Channel, { foreignKey: 'channelId', as: 'Channel' });

// Direct associations for UserRole to allow includes
UserRole.belongsTo(User, { foreignKey: 'userId', as: 'User' });
UserRole.belongsTo(Role, { foreignKey: 'roleId', as: 'Role' });

// Many-to-Many: User <-> Channel (for channel membership)
User.belongsToMany(Channel, {
    through: ChannelMembers,
    as: 'Channels',
    foreignKey: 'userId',
    otherKey: 'channelId'
});
Channel.belongsToMany(User, {
    through: ChannelMembers,
    as: 'Members',
    foreignKey: 'channelId',
    otherKey: 'userId'
});

temporaryStorage.sync({ alter: false })
    .then(() => logger.info('Temporary tables created successfully.'))
    .catch(error => logger.error('Error creating temporary tables:', error));

// ServerSettings model (single row configuration)
const ServerSettings = sequelize.define('ServerSettings', {
    id: {
        type: DataTypes.INTEGER,
        primaryKey: true,
        autoIncrement: true
    },
    server_name: {
        type: DataTypes.STRING,
        allowNull: true,
        defaultValue: 'PeerWave Server'
    },
    server_picture: {
        type: DataTypes.TEXT,
        allowNull: true
    },
    registration_mode: {
        type: DataTypes.STRING,
        allowNull: false,
        defaultValue: 'open' // 'open', 'email_suffix', 'invitation_only'
    },
    allowed_email_suffixes: {
        type: DataTypes.TEXT, // JSON array stored as text
        allowNull: true,
        defaultValue: '[]'
    }
}, {
    timestamps: true,
    underscored: true,
    tableName: 'ServerSettings'
});

// Invitations model
const Invitation = sequelize.define('Invitation', {
    id: {
        type: DataTypes.INTEGER,
        primaryKey: true,
        autoIncrement: true
    },
    email: {
        type: DataTypes.STRING,
        allowNull: false
    },
    token: {
        type: DataTypes.STRING(6),
        allowNull: false,
        unique: true
    },
    expires_at: {
        type: DataTypes.DATE,
        allowNull: false
    },
    used: {
        type: DataTypes.BOOLEAN,
        allowNull: false,
        defaultValue: false
    },
    used_at: {
        type: DataTypes.DATE,
        allowNull: true
    },
    invited_by: {
        type: DataTypes.STRING,
        allowNull: false
    }
}, {
    timestamps: true,
    underscored: true,
    createdAt: 'created_at',
    updatedAt: false,
    tableName: 'Invitations',
    indexes: [
        { name: 'invitations_email', fields: ['email'] },
        { name: 'invitations_token', fields: ['token'], unique: true },
        { name: 'invitations_expires_at', fields: ['expires_at'] }
    ]
});

// Blocked Users Model - tracks user blocking relationships
const BlockedUser = sequelize.define('BlockedUser', {
    id: {
        type: DataTypes.INTEGER,
        primaryKey: true,
        autoIncrement: true
    },
    blocker_uuid: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Users',
            key: 'uuid'
        }
    },
    blocked_uuid: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Users',
            key: 'uuid'
        }
    },
    reason: {
        type: DataTypes.STRING,
        allowNull: true
    },
    blocked_at: {
        type: DataTypes.DATE,
        allowNull: false,
        defaultValue: Sequelize.NOW
    }
}, {
    tableName: 'blocked_users',
    timestamps: false,
    indexes: [
        {
            unique: true,
            fields: ['blocker_uuid', 'blocked_uuid']
        },
        {
            fields: ['blocker_uuid']
        },
        {
            fields: ['blocked_uuid']
        }
    ]
});

// Abuse Reports Model - stores user-reported abuse incidents
const AbuseReport = sequelize.define('AbuseReport', {
    id: {
        type: DataTypes.INTEGER,
        primaryKey: true,
        autoIncrement: true
    },
    report_uuid: {
        type: DataTypes.UUID,
        allowNull: false,
        unique: true,
        defaultValue: Sequelize.UUIDV4
    },
    reporter_uuid: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Users',
            key: 'uuid'
        }
    },
    reported_uuid: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Users',
            key: 'uuid'
        }
    },
    description: {
        type: DataTypes.TEXT,
        allowNull: false
    },
    photos: {
        type: DataTypes.TEXT,
        allowNull: true  // JSON string array of base64 photos
    },
    status: {
        type: DataTypes.STRING,
        allowNull: false,
        defaultValue: 'pending'  // 'pending', 'under_review', 'resolved', 'dismissed'
    },
    admin_notes: {
        type: DataTypes.TEXT,
        allowNull: true
    },
    resolved_by: {
        type: DataTypes.UUID,
        allowNull: true,
        references: {
            model: 'Users',
            key: 'uuid'
        }
    },
    resolved_at: {
        type: DataTypes.DATE,
        allowNull: true
    },
    created_at: {
        type: DataTypes.DATE,
        allowNull: false,
        defaultValue: Sequelize.NOW
    }
}, {
    tableName: 'abuse_reports',
    timestamps: false,
    indexes: [
        {
            fields: ['reporter_uuid']
        },
        {
            fields: ['reported_uuid']
        },
        {
            fields: ['status']
        },
        {
            fields: ['report_uuid'],
            unique: true
        }
    ]
});

// Define associations for blocked users
User.hasMany(BlockedUser, { foreignKey: 'blocker_uuid', as: 'blockedByUser' });
User.hasMany(BlockedUser, { foreignKey: 'blocked_uuid', as: 'blockedUsers' });
BlockedUser.belongsTo(User, { foreignKey: 'blocker_uuid', as: 'blocker' });
BlockedUser.belongsTo(User, { foreignKey: 'blocked_uuid', as: 'blockedUser' });

// Define associations for abuse reports
User.hasMany(AbuseReport, { foreignKey: 'reporter_uuid', as: 'reportsMade' });
User.hasMany(AbuseReport, { foreignKey: 'reported_uuid', as: 'reportsReceived' });
User.hasMany(AbuseReport, { foreignKey: 'resolved_by', as: 'reportsResolved' });
AbuseReport.belongsTo(User, { foreignKey: 'reporter_uuid', as: 'reporter' });
AbuseReport.belongsTo(User, { foreignKey: 'reported_uuid', as: 'reported' });
AbuseReport.belongsTo(User, { foreignKey: 'resolved_by', as: 'resolver' });


module.exports = {
    User,
    OTP,
    ExternalSession,
    MeetingInvitation,
        MeetingRsvp,
    Client,
    Item,
    SignalSignedPreKey,
    SignalPreKey,
    SignalSenderKey,
    GroupItem,
    GroupItemRead,
    Channel,
    ChannelMembers,
    Role,
    UserRole,
    UserRoleChannel,
    ClientSession,
    NonceCache,
    ServerSettings,
    Invitation,
    Meeting,
    MeetingInvitation,
    MeetingRsvp,
    BlockedUser,
    AbuseReport,
    sequelize,
    temporaryStorage,
    dbReady
};