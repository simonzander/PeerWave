const config = require('../config/config');
const express = require("express");
const { Sequelize, DataTypes, Op, UUID } = require('sequelize');
const { DESCRIBE } = require('sequelize/lib/query-types');

const sequelize = new Sequelize({
    dialect: 'sqlite',
    storage: './db/peerwave.sqlite',
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

//sequelize.sync({ alter: true });

sequelize.authenticate()
    .then(async () => {
        console.log('Connection to SQLite database has been established successfully.');
        
        // Enable WAL mode and optimizations
        try {
            await sequelize.query("PRAGMA journal_mode=WAL");
            console.log('✓ SQLite WAL mode enabled');
            
            await sequelize.query("PRAGMA busy_timeout=5000");
            console.log('✓ SQLite busy_timeout set to 5000ms');
            
            await sequelize.query("PRAGMA synchronous=NORMAL");
            console.log('✓ SQLite synchronous mode set to NORMAL');
            
            await sequelize.query("PRAGMA cache_size=-64000");
            console.log('✓ SQLite cache_size set to 64MB');
            
            await sequelize.query("PRAGMA temp_store=MEMORY");
            console.log('✓ SQLite temp_store set to MEMORY');
        } catch (error) {
            console.error('Error setting SQLite PRAGMAs:', error);
        }
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

// Basic associations
User.hasMany(Client, { foreignKey: 'owner' });
User.hasMany(SignalPreKey, { foreignKey: 'owner' });
User.hasMany(SignalSignedPreKey, { foreignKey: 'owner' });
User.hasMany(Channel, { foreignKey: 'owner', as: 'OwnedChannels' });
Channel.belongsTo(User, { foreignKey: 'owner', as: 'Owner' });
Client.hasMany(SignalSignedPreKey, { foreignKey: 'client' });
Client.hasMany(SignalPreKey, { foreignKey: 'client' });

// Signal Sender Key associations for Group Chats
Channel.hasMany(SignalSenderKey, { foreignKey: 'channel' });
SignalSenderKey.belongsTo(Channel, { foreignKey: 'channel' });
Client.hasMany(SignalSenderKey, { foreignKey: 'client' });
SignalSenderKey.belongsTo(Client, { foreignKey: 'client' });
User.hasMany(SignalSenderKey, { foreignKey: 'owner' });
SignalSenderKey.belongsTo(User, { foreignKey: 'owner' });

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
    .then(() => console.log('Temporary tables created successfully.'))
    .catch(error => console.error('Error creating temporary tables:', error));
// Create the User table in the database
// Sync referenced tables first
sequelize.sync({ alter: false })
    .then(async () => {
        console.log('All main tables created successfully.');
        
        // Initialize standard roles
        await initializeStandardRoles();
    })
    .catch(error => console.error('Error creating main tables:', error));

// Initialize standard roles
async function initializeStandardRoles() {
    try {
        const standardRoles = [
            // Server scope roles
            {
                name: 'Administrator',
                description: 'Full server access with all permissions',
                scope: 'server',
                permissions: ['*'],
                standard: true
            },
            {
                name: 'Moderator',
                description: 'Server moderator with limited admin permissions',
                scope: 'server',
                permissions: ['user.manage', 'channel.manage', 'message.moderate', 'role.create', 'role.edit', 'role.delete'],
                standard: true
            },
            {
                name: 'User',
                description: 'Standard user role',
                scope: 'server',
                permissions: ['channel.join', 'channel.create', 'message.send', 'message.read'],
                standard: true
            },
            // Channel WebRTC scope roles
            {
                name: 'Channel Owner',
                description: 'Owner of a WebRTC channel with full control',
                scope: 'channelWebRtc',
                permissions: ['*'],
                standard: true
            },
            {
                name: 'Channel Moderator',
                description: 'WebRTC channel moderator',
                scope: 'channelWebRtc',
                permissions: ['user.kick', 'user.mute', 'stream.manage', 'role.assign', 'member.view'],
                standard: true
            },
            {
                name: 'Channel Member',
                description: 'Regular member of a WebRTC channel',
                scope: 'channelWebRtc',
                permissions: ['stream.view', 'stream.send', 'chat.send', 'member.view'],
                standard: true
            },
            // Channel Signal scope roles
            {
                name: 'Channel Owner',
                description: 'Owner of a Signal channel with full control',
                scope: 'channelSignal',
                permissions: ['*'],
                standard: true
            },
            {
                name: 'Channel Moderator',
                description: 'Signal channel moderator',
                scope: 'channelSignal',
                permissions: ['message.delete', 'user.kick', 'user.mute', 'role.assign', 'member.view'],
                standard: true
            },
            {
                name: 'Channel Member',
                description: 'Regular member of a Signal channel',
                scope: 'channelSignal',
                permissions: ['message.send', 'message.read', 'message.react', 'member.view'],
                standard: true
            }
        ];

        for (const roleData of standardRoles) {
            await Role.findOrCreate({
                where: { 
                    name: roleData.name,
                    scope: roleData.scope
                },
                defaults: roleData
            });
        }
        
        console.log('✓ Standard roles initialized');
    } catch (error) {
        console.error('Error initializing standard roles:', error);
    }
}


module.exports = {
    User,
    OTP,
    Client,
    Item,
    SignalSignedPreKey,
    SignalPreKey,
    SignalSenderKey,
    Channel,
    ChannelMembers,
    Role,
    UserRole,
    UserRoleChannel
};