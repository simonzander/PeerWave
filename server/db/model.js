const config = require('../config/config');
const express = require("express");
const { Sequelize, DataTypes, Op, UUID } = require('sequelize');

const sequelize = new Sequelize({
    dialect: 'sqlite',
    storage: './db/peerwave.sqlite',
});

const temporaryStorage = new Sequelize({
    dialect: 'sqlite',
    storage: ':memory:'
});

//sequelize.sync({ alter: true });

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

/*const SignalSenderKey = sequelize.define('SignalSenderKey', {
    channel: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Channel',
            key: 'uuid'
        }
    },
    client: {
        type: DataTypes.UUID,
        allowNull: false,
        references: {
            model: 'Client',
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
}, { timestamps: false });*/

/*const Channel = sequelize.define('Channel', {
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
    private: {
        type: DataTypes.BOOLEAN,
        allowNull: false,
        defaultValue: false
    },
    defaultPermissions: {
        type: DataTypes.TEXT,
        allowNull: true // Store JSON string of default permissions
    },
    type: {
        type: DataTypes.STRING,
        allowNull: false
    }
});*/

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
        allowNull: false,
        references: {
            model: 'Clients',
            key: 'device_id'
        }
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
    }
}, { timestamps: false });


// Define public key model
/*const PublicKey = sequelize.define('PublicKey', {
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
*/
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
/*
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
    defaultPermissions: {
        type: DataTypes.TEXT,
        allowNull: true // Store JSON string of default permissions
    },
    // members field removed; handled by many-to-many association below
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
*/
// Many-to-many association for channel members
/*const ChannelMembers = sequelize.define('ChannelMembers', {
    permission: {
        type: DataTypes.TEXT,
        allowNull: true // Store JSON string of permissions
    }
}, { timestamps: false });
User.belongsToMany(Channel, { through: ChannelMembers, as: 'Channels', foreignKey: 'userId' });
Channel.belongsToMany(User, { through: ChannelMembers, as: 'Members', foreignKey: 'channelId' });

User.hasMany(Thread, { foreignKey: 'sender' });
Channel.hasMany(Thread, { foreignKey: 'channel' });
Thread.hasMany(Emote, { foreignKey: 'thread' });
Thread.belongsTo(User, { as: 'user', foreignKey: 'sender' });
User.hasMany(PublicKey, { foreignKey: 'owner' });
User.hasMany(PublicKey, { foreignKey: 'reciever' });
Channel.hasMany(PublicKey, { foreignKey: 'channel' });
*/
User.hasMany(Client, { foreignKey: 'owner' });
User.hasMany(SignalPreKey, { foreignKey: 'owner' });
User.hasMany(SignalSignedPreKey, { foreignKey: 'owner' });
Client.hasMany(SignalSignedPreKey, { foreignKey: 'client' });
Client.hasMany(SignalPreKey, { foreignKey: 'client' });

temporaryStorage.sync({ alter: false })
    .then(() => console.log('Temporary tables created successfully.'))
    .catch(error => console.error('Error creating temporary tables:', error));
// Create the User table in the database
// Sync referenced tables first
sequelize.sync({ alter: false })
    .then(() => console.log('All main tables created successfully.'))
    .catch(error => console.error('Error creating main tables:', error));


module.exports = {
    User,
    OTP,
    Client,
    Item,
    SignalSignedPreKey,
    SignalPreKey,
    //SignalSenderKey,
};