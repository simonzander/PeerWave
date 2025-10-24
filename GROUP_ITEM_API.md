# Group Item API Documentation

## Overview

The Group Item API provides a simplified and efficient architecture for Signal Protocol group chats. Instead of storing encrypted messages per recipient (N database entries), messages are stored once with Sender Key encryption (1 database entry).

## Architecture Changes

### Old Approach (Item Model)
- Each group message stored N times (once per recipient)
- Sender Key distribution via 1:1 encrypted messages
- Complex key management with Socket.IO events
- Inefficient database usage

### New Approach (GroupItem Model)
- Each group message stored ONCE
- Sender Keys loaded via REST API from server
- Simple key management
- Efficient database usage
- Read receipts tracked separately

## Database Models

### GroupItem
Stores encrypted items (messages, reactions, files, etc.) for group chats.

```javascript
{
  uuid: UUID,              // Primary key (auto-generated)
  itemId: UUID,            // Client-generated ID (unique, for deduplication)
  channel: UUID,           // Channel reference
  sender: UUID,            // User who sent the item
  senderDevice: INTEGER,   // Device ID of sender
  type: STRING,            // 'message', 'reaction', 'file', etc.
  payload: TEXT,           // Encrypted with sender's SenderKey
  cipherType: INTEGER,     // 4 = SenderKey encryption
  timestamp: DATE,         // When the item was created
  createdAt: DATE,         // Auto-generated
  updatedAt: DATE          // Auto-generated
}
```

**Indexes:**
- `(channel, timestamp)` - Fast queries for channel messages
- `(itemId)` - Fast lookups by client ID
- `(sender, channel)` - Fast queries for user's messages in channel

### GroupItemRead
Tracks read receipts for group items.

```javascript
{
  id: INTEGER,             // Primary key (auto-increment)
  itemId: UUID,            // GroupItem reference
  userId: UUID,            // User who read the item
  deviceId: INTEGER,       // Device that read the item
  readAt: DATE             // When it was read
}
```

**Indexes:**
- `(itemId, userId, deviceId)` - Unique constraint (one receipt per device)
- `(itemId)` - Fast count of reads per item

### SignalSenderKey (Updated Usage)
Stores Sender Keys for group encryption. **No longer distributed via 1:1 messages.**

```javascript
{
  channel: UUID,           // Channel reference
  client: UUID,            // Client reference
  owner: UUID,             // User reference
  sender_key: TEXT,        // base64 encoded SenderKeyDistributionMessage
  createdAt: DATE,         // Auto-generated
  updatedAt: DATE          // Auto-generated
}
```

## REST API Endpoints

### 1. Create Group Item

**POST** `/api/group-items`

Create a new encrypted group item (message, reaction, etc.).

**Authentication:** Required (session)

**Request Body:**
```json
{
  "channelId": "channel-uuid",
  "itemId": "client-generated-uuid",
  "type": "message",
  "payload": "base64-encoded-encrypted-data",
  "cipherType": 4,
  "senderDevice": 1,
  "timestamp": "2025-10-24T12:00:00.000Z"
}
```

**Response (201 Created):**
```json
{
  "success": true,
  "item": {
    "uuid": "server-generated-uuid",
    "itemId": "client-generated-uuid",
    "channel": "channel-uuid",
    "sender": "user-uuid",
    "senderDevice": 1,
    "type": "message",
    "payload": "base64-encoded-encrypted-data",
    "cipherType": 4,
    "timestamp": "2025-10-24T12:00:00.000Z",
    "createdAt": "2025-10-24T12:00:00.123Z",
    "updatedAt": "2025-10-24T12:00:00.123Z"
  }
}
```

**Response (200 OK - Duplicate):**
```json
{
  "message": "Item already exists",
  "item": { ... }
}
```

---

### 2. Get Channel Items

**GET** `/api/group-items/:channelId`

Retrieve all items for a channel.

**Authentication:** Required (session)

**Query Parameters:**
- `since` (optional): ISO timestamp - only return items after this time
- `limit` (optional): Number of items to return (default: 50)

**Example:** `/api/group-items/channel-uuid?since=2025-10-24T12:00:00.000Z&limit=100`

**Response (200 OK):**
```json
{
  "success": true,
  "items": [
    {
      "uuid": "item-uuid",
      "itemId": "client-uuid",
      "channel": "channel-uuid",
      "sender": "user-uuid",
      "senderDevice": 1,
      "type": "message",
      "payload": "encrypted-data",
      "cipherType": 4,
      "timestamp": "2025-10-24T12:00:00.000Z",
      "Sender": {
        "uuid": "user-uuid",
        "displayName": "Alice"
      }
    }
  ],
  "count": 42
}
```

---

### 3. Mark Item as Read

**POST** `/api/group-items/:itemId/read`

Mark a group item as read by the current user/device.

**Authentication:** Required (session)

**Request Body:**
```json
{
  "deviceId": 1
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "readReceipt": {
    "id": 123,
    "itemId": "item-uuid",
    "userId": "user-uuid",
    "deviceId": 1,
    "readAt": "2025-10-24T12:05:00.000Z"
  },
  "readCount": 3,
  "totalMembers": 5,
  "allRead": false
}
```

---

### 4. Get Item Read Status

**GET** `/api/group-items/:itemId/read-status`

Get read status and receipts for a specific item.

**Authentication:** Required (session)

**Response (200 OK):**
```json
{
  "success": true,
  "readCount": 3,
  "totalMembers": 5,
  "allRead": false,
  "readBy": [
    {
      "id": 123,
      "itemId": "item-uuid",
      "userId": "user-uuid-1",
      "deviceId": 1,
      "readAt": "2025-10-24T12:05:00.000Z",
      "User": {
        "uuid": "user-uuid-1",
        "displayName": "Alice"
      }
    },
    {
      "id": 124,
      "itemId": "item-uuid",
      "userId": "user-uuid-2",
      "deviceId": 1,
      "readAt": "2025-10-24T12:06:00.000Z",
      "User": {
        "uuid": "user-uuid-2",
        "displayName": "Bob"
      }
    }
  ]
}
```

---

### 5. Get All Sender Keys for Channel

**GET** `/api/sender-keys/:channelId`

Get all sender keys for a channel (for initial sync when joining).

**Authentication:** Required (session)

**Response (200 OK):**
```json
{
  "success": true,
  "senderKeys": [
    {
      "userId": "user-uuid-1",
      "deviceId": 1,
      "clientId": "client-uuid-1",
      "senderKey": "base64-encoded-distribution-message",
      "updatedAt": "2025-10-24T10:00:00.000Z"
    },
    {
      "userId": "user-uuid-2",
      "deviceId": 1,
      "clientId": "client-uuid-2",
      "senderKey": "base64-encoded-distribution-message",
      "updatedAt": "2025-10-24T11:00:00.000Z"
    }
  ],
  "count": 2
}
```

---

### 6. Get Specific Sender Key

**GET** `/api/sender-keys/:channelId/:userId/:deviceId`

Get a specific sender key for a user/device in a channel.

**Authentication:** Required (session)

**Response (200 OK):**
```json
{
  "success": true,
  "userId": "user-uuid",
  "deviceId": 1,
  "clientId": "client-uuid",
  "senderKey": "base64-encoded-distribution-message",
  "updatedAt": "2025-10-24T10:00:00.000Z"
}
```

**Response (404 Not Found):**
```json
{
  "error": "Sender key not found"
}
```

---

### 7. Create or Update Sender Key

**POST** `/api/sender-keys/:channelId`

Create or update the sender key for the current user in a channel.

**Authentication:** Required (session)

**Request Body:**
```json
{
  "senderKey": "base64-encoded-distribution-message",
  "deviceId": 1
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "created": false,
  "message": "Sender key updated"
}
```

## Client Implementation Workflow

### Sending a Group Message

```javascript
// 1. Check if we have a sender key for this channel
const hasSenderKey = await signalService.hasSenderKey(channelId, userId, deviceId);

if (!hasSenderKey) {
  // 2. Create sender key locally
  const distributionMessage = await signalService.createGroupSenderKey(channelId);
  
  // 3. Upload to server
  await fetch(`/api/sender-keys/${channelId}`, {
    method: 'POST',
    body: JSON.stringify({
      senderKey: base64Encode(distributionMessage),
      deviceId: myDeviceId
    })
  });
}

// 4. Encrypt message with our sender key
const encrypted = await signalService.encryptGroupMessage(channelId, message);

// 5. Send to server (stored ONCE for all members)
await fetch('/api/group-items', {
  method: 'POST',
  body: JSON.stringify({
    channelId: channelId,
    itemId: uuid(),
    type: 'message',
    payload: encrypted,
    cipherType: 4,
    senderDevice: myDeviceId,
    timestamp: new Date().toISOString()
  })
});
```

### Receiving a Group Message

```javascript
// 1. Socket.IO event: new group item
socket.on('groupItem', async (data) => {
  const { itemId, channel, sender, senderDevice, payload } = data;
  
  // 2. Check if we have sender's key
  const hasSenderKey = await signalService.hasSenderKey(channel, sender, senderDevice);
  
  if (!hasSenderKey) {
    // 3. Load sender key from server
    const response = await fetch(`/api/sender-keys/${channel}/${sender}/${senderDevice}`);
    const { senderKey } = await response.json();
    
    // 4. Process the distribution message
    await signalService.processSenderKeyDistribution(
      channel,
      sender,
      senderDevice,
      base64Decode(senderKey)
    );
  }
  
  // 5. Decrypt the message
  const decrypted = await signalService.decryptGroupMessage(
    channel,
    sender,
    senderDevice,
    payload
  );
  
  // 6. Display message
  displayMessage(decrypted);
  
  // 7. Send read receipt
  await fetch(`/api/group-items/${itemId}/read`, {
    method: 'POST',
    body: JSON.stringify({ deviceId: myDeviceId })
  });
});
```

### Joining a Channel

```javascript
// 1. User joins channel
await joinChannel(channelId);

// 2. Load all sender keys for this channel
const response = await fetch(`/api/sender-keys/${channelId}`);
const { senderKeys } = await response.json();

// 3. Process all sender keys
for (const key of senderKeys) {
  await signalService.processSenderKeyDistribution(
    channelId,
    key.userId,
    key.deviceId,
    base64Decode(key.senderKey)
  );
}

// 4. Load messages
const messagesResponse = await fetch(`/api/group-items/${channelId}?limit=50`);
const { items } = await messagesResponse.json();

// 5. Decrypt and display messages
for (const item of items) {
  const decrypted = await signalService.decryptGroupMessage(
    item.channel,
    item.sender,
    item.senderDevice,
    item.payload
  );
  displayMessage(decrypted);
}
```

## Benefits of New Architecture

### 1. **Efficiency**
- **Old:** N database entries per group message (one per recipient)
- **New:** 1 database entry per group message
- **Result:** ~90% reduction in database size for 10-member groups

### 2. **Simplicity**
- **Old:** Complex Socket.IO events for key distribution, pending message queues
- **New:** Simple REST API calls to load keys when needed
- **Result:** Easier to debug, maintain, and extend

### 3. **Reliability**
- **Old:** Keys distributed via 1:1 messages (can fail silently)
- **New:** Keys always available on server, loaded on-demand
- **Result:** No missing keys, no pending message queues

### 4. **Scalability**
- **Old:** Broadcast to all members individually (N Socket.IO emits)
- **New:** Single broadcast event, recipients load key if needed
- **Result:** Better performance for large groups

### 5. **Forward Secrecy**
- **Maintained:** Sender keys still use chain keys and ratcheting
- **Security:** Keys stored as encrypted SenderKeyDistributionMessages
- **Result:** No loss of security compared to old approach

## Migration Path

1. **Phase 1:** Deploy new models (GroupItem, GroupItemRead)
2. **Phase 2:** Deploy new REST API endpoints
3. **Phase 3:** Update client to use new API for new messages
4. **Phase 4:** Keep old Item model for backward compatibility
5. **Phase 5:** Migrate old messages to GroupItem (optional)
6. **Phase 6:** Deprecate old Item-based group messages

## Security Considerations

### Sender Key Storage
- Sender keys stored as **base64-encoded SenderKeyDistributionMessages**
- Contains chain key, iteration count, and signature keys
- **NOT** plain encryption keys
- Forward secrecy maintained through chain ratcheting

### Access Control
- Only channel members can read group items
- Only channel members can access sender keys
- Session-based authentication required for all endpoints

### End-to-End Encryption
- Server **never** sees plaintext messages
- Server only stores encrypted payloads
- Keys distributed securely (still E2E encrypted in distribution message)

## Socket.IO Events (Updated)

### Emit from Client

```javascript
// No longer needed - sender key distribution now via REST API
// socket.emit('storeSenderKey', { ... });  ❌ DEPRECATED
// socket.emit('getSenderKey', { ... });    ❌ DEPRECATED
```

### Emit from Server

```javascript
// New group item created
socket.emit('groupItem', {
  itemId: 'uuid',
  channel: 'channel-uuid',
  sender: 'user-uuid',
  senderDevice: 1,
  type: 'message',
  payload: 'encrypted-data',
  cipherType: 4,
  timestamp: '2025-10-24T12:00:00.000Z'
});

// Read receipt updated
socket.emit('groupItemRead', {
  itemId: 'uuid',
  readCount: 3,
  totalMembers: 5,
  allRead: false
});
```

## Error Handling

### Common Error Responses

**401 Unauthorized:**
```json
{ "error": "Unauthorized" }
```

**403 Forbidden:**
```json
{ "error": "Not a member of this channel" }
```

**404 Not Found:**
```json
{ "error": "Item not found" }
// or
{ "error": "Sender key not found" }
```

**400 Bad Request:**
```json
{ "error": "Missing required fields" }
// or
{ "error": "deviceId required" }
```

**500 Internal Server Error:**
```json
{ "error": "Internal server error" }
```

## Performance Optimization Tips

### 1. Batch Key Loading
Load all sender keys when joining a channel (one API call):
```javascript
const { senderKeys } = await fetch(`/api/sender-keys/${channelId}`);
```

### 2. Incremental Message Loading
Use `since` parameter to load only new messages:
```javascript
const { items } = await fetch(`/api/group-items/${channelId}?since=${lastTimestamp}`);
```

### 3. Limit Message History
Use `limit` parameter to avoid loading too many messages:
```javascript
const { items } = await fetch(`/api/group-items/${channelId}?limit=50`);
```

### 4. Cache Sender Keys Locally
Don't reload sender keys that are already in local storage.

### 5. Debounce Read Receipts
Don't send read receipt for every message immediately - batch them or send when user scrolls/focuses.
