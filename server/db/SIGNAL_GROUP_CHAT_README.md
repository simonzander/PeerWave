# Signal Protocol Group Chats

## Overview

PeerWave uses the Signal Protocol for end-to-end encrypted group chats. The system is based on **Sender Keys**, which enable efficient group encryption.

## Database Structure

### SignalSenderKey Table

```javascript
{
    channel: UUID,        // Channel ID (group chat)
    client: UUID,         // Sender's client ID
    owner: UUID,          // Sender's user ID
    sender_key: TEXT,     // Encrypted sender key
    createdAt: TIMESTAMP,
    updatedAt: TIMESTAMP
}
```

**Unique Index**: `[channel, client]` - A client can only have one sender key per channel.

### Channel Table

```javascript
{
    uuid: UUID (PK),
    name: STRING,
    description: STRING,
    private: BOOLEAN,
    type: STRING          // 'signal', 'webrtc', etc.
}
```

### Associations

```javascript
Channel.hasMany(SignalSenderKey)
SignalSenderKey.belongsTo(Channel)

Client.hasMany(SignalSenderKey)
SignalSenderKey.belongsTo(Client)

User.hasMany(SignalSenderKey)
SignalSenderKey.belongsTo(User)
```

## Signal Protocol Components

### 1. PreKeys (1:1 Communication)
- **SignalPreKey**: One-time keys for session establishment
- **SignalSignedPreKey**: Signed PreKeys with authentication

### 2. Sender Keys (Group Chats)
- **SignalSenderKey**: Group encryption
- Each client has one sender key per channel
- All members share their sender keys with each other

## Workflow: Group Chat

### 1. Create Channel
```javascript
const channel = await Channel.create({
    name: 'My Group Chat',
    type: 'signal',
    private: true
});

// Assign owner role
const ownerRole = await Role.findOne({ 
    where: { name: 'Channel Owner', scope: 'channelSignal' } 
});
await assignChannelRole(userId, ownerRole.uuid, channel.uuid);
```

### 2. Create Sender Key
```javascript
// Client creates sender key for this channel
const senderKey = await SignalSenderKey.create({
    channel: channelId,
    client: clientId,
    owner: userId,
    sender_key: encryptedSenderKeyData
});
```

### 3. Add Members
```javascript
// Add new member to group
const memberRole = await Role.findOne({ 
    where: { name: 'Channel Member', scope: 'channelSignal' } 
});
await assignChannelRole(newUserId, memberRole.uuid, channelId);

// Exchange sender keys:
// 1. New member sends their sender key to all
// 2. All members send their sender keys to new member
```

### 4. Send Message (Encrypted)
```javascript
// 1. Encrypt message with own sender key
const encryptedMessage = encryptWithSenderKey(message, mySenderKey);

// 2. Send to all channel members
const members = await getUserChannelRoles(userId, channelId);
for (const member of members) {
    await Item.create({
        sender: myUserId,
        receiver: member.userId,
        deviceSender: myDeviceId,
        deviceReceiver: member.deviceId,
        type: 'groupMessage',
        payload: encryptedMessage,
        cipherType: 3, // Sender Key Cipher
        itemId: channelId
    });
}
```

### 5. Receive Message
```javascript
// 1. Load sender's sender key from DB
const senderKey = await SignalSenderKey.findOne({
    where: {
        channel: channelId,
        client: senderClientId
    }
});

// 2. Decrypt message
const decryptedMessage = decryptWithSenderKey(
    encryptedMessage, 
    senderKey.sender_key
);
```

## Sender Key Management

### Key Rotation
When a member leaves the group, new sender keys should be created:

```javascript
// Remove member
await removeChannelRole(userId, roleId, channelId);

// Delete all sender keys for this channel
await SignalSenderKey.destroy({
    where: { channel: channelId }
});

// All remaining members create new sender keys
// and share them with each other
```

### Key Query
```javascript
// Get all sender keys of a channel
const senderKeys = await SignalSenderKey.findAll({
    where: { channel: channelId },
    include: [
        { model: User, attributes: ['uuid', 'displayName'] },
        { model: Client, attributes: ['clientid', 'device_id'] }
    ]
});

// Get sender key of specific client
const senderKey = await SignalSenderKey.findOne({
    where: {
        channel: channelId,
        client: clientId
    }
});
```

## API Endpoints (Proposal)

### POST /api/channels/:channelId/sender-key
Store sender key for a channel:
```javascript
{
    clientId: "uuid",
    senderKey: "encrypted_key_data"
}
```

### GET /api/channels/:channelId/sender-keys
Get all sender keys of a channel (for new members):
```javascript
[
    {
        clientId: "uuid",
        userId: "uuid",
        displayName: "User Name",
        senderKey: "encrypted_key_data"
    }
]
```

### DELETE /api/channels/:channelId/sender-keys
Delete all sender keys of a channel (Key Rotation):
```javascript
// Deletes all keys, clients must create new ones
```

## Security Notes

### ✅ Best Practices
1. **Unique Constraint**: One client = One sender key per channel
2. **Key Rotation**: Create new keys when members change
3. **Timestamps**: Enabled for tracking and debugging
4. **Proper References**: Correct table names ('Channels', 'Clients')
5. **Associations**: Bidirectional relationships for easy queries

### ⚠️ Important Considerations
1. **Forward Secrecy**: Old messages remain readable with old sender key
2. **Member Removal**: Key rotation required for Perfect Forward Secrecy
3. **Key Storage**: Sender keys are stored encrypted
4. **Device Sync**: Each device needs its own sender key

## Example: Complete Group Chat Flow

```javascript
// 1. Alice creates group
const channel = await Channel.create({
    name: 'Team Chat',
    type: 'signal',
    private: true
});

// 2. Alice becomes owner
await assignChannelRole(aliceId, ownerRole.uuid, channel.uuid);

// 3. Alice creates sender key
await SignalSenderKey.create({
    channel: channel.uuid,
    client: aliceClientId,
    owner: aliceId,
    sender_key: aliceSenderKey
});

// 4. Alice invites Bob
await assignChannelRole(bobId, memberRole.uuid, channel.uuid);

// 5. Bob creates sender key
await SignalSenderKey.create({
    channel: channel.uuid,
    client: bobClientId,
    owner: bobId,
    sender_key: bobSenderKey
});

// 6. Alice and Bob exchange sender keys
// (via encrypted Items)

// 7. Alice sends message
const encrypted = encryptWithSenderKey('Hello Bob!', aliceSenderKey);
await Item.create({
    sender: aliceId,
    receiver: bobId,
    type: 'groupMessage',
    payload: encrypted,
    cipherType: 3,
    itemId: channel.uuid
});

// 8. Bob receives and decrypts
const aliceSenderKey = await SignalSenderKey.findOne({
    where: { channel: channel.uuid, client: aliceClientId }
});
const decrypted = decryptWithSenderKey(encrypted, aliceSenderKey.sender_key);
// => 'Hello Bob!'
```

## Integration with Role System

### Permission Check Before Sending Message
```javascript
// Check if user has permission
const canSend = await hasChannelPermission(
    userId, 
    channelId, 
    'message.send'
);

if (!canSend) {
    throw new Error('No permission to send messages');
}

// Sender key must exist
const senderKey = await SignalSenderKey.findOne({
    where: { channel: channelId, client: clientId }
});

if (!senderKey) {
    throw new Error('Sender key not found - not a channel member');
}
```

## Technical Details

### Cipher Type
- `cipherType: 3` = Sender Key Message (Group)
- `cipherType: 1` = PreKey Message (1:1)
- `cipherType: 2` = Whisper Message (1:1)

### Item Type
- `type: 'groupMessage'` = Group message
- `type: 'message'` = 1:1 message
- `type: 'keyDistribution'` = Exchange sender key

## Migration

If the database exists:
```bash
# Create backup
cp db/peerwave.sqlite db/peerwave.sqlite.backup

# Start server with alter: true (once)
# Adds timestamps and unique index
```

The changes are backwards compatible and don't affect existing data.
