# PeerWave Role System

## Overview

The role system supports three different scopes:
- **server**: Server-wide roles (for all users)
- **channelWebRtc**: Roles for WebRTC channels (Video/Audio)
- **channelSignal**: Roles for Signal channels (End-to-end encrypted messages)

## Automatic Role Assignment

When a user is verified (after OTP entry), roles are automatically assigned:

### Administrator Role
Users whose email address is in the `config.admin` array automatically receive the **Administrator** role.

```javascript
// In config/config.js
config.admin = [
    'admin@example.com',
    's.bergt@googlemail.com'
];
```

### Default User Role
All other verified users automatically receive the **User** role.

### Workflow
1. User registers with email
2. User enters OTP
3. `User.verified` is set to `true`
4. `autoAssignRoles()` checks:
   - Is email in `config.admin`? → Administrator role
   - Otherwise → User role
5. Role is assigned via `assignServerRole()`

## Database Structure

### Tables

#### Role
- `uuid` (PK): Unique role ID
- `name`: Role name (e.g., "Administrator")
- `description`: Role description
- `scope`: ENUM('server', 'channelWebRtc', 'channelSignal')
- `permissions`: JSON array with permissions
- `standard`: Boolean - Standard roles cannot be deleted

**Index**: Unique on (`name`, `scope`)

#### UserRole (Junction Table)
For server roles: Many-to-Many between User and Role
- `userId`: User UUID
- `roleId`: Role UUID

#### UserRoleChannel (Junction Table)
For channel roles: Many-to-Many between User, Role and Channel
- `userId`: User UUID
- `roleId`: Role UUID
- `channelId`: Channel UUID

## Standard Roles

### Server Scope
1. **Administrator**
   - Description: Full server access
   - Permissions: `['*']`

2. **Moderator**
   - Description: Server moderator with limited admin rights
   - Permissions: `['user.manage', 'channel.manage', 'message.moderate']`

3. **User**
   - Description: Standard user role
   - Permissions: `['channel.join', 'message.send', 'message.read']`

### Channel WebRTC Scope
1. **Channel Owner**
   - Description: Owner of a WebRTC channel
   - Permissions: `['*']`

2. **Channel Moderator**
   - Description: WebRTC channel moderator
   - Permissions: `['user.kick', 'user.mute', 'stream.manage']`

3. **Channel Member**
   - Description: Regular member of a WebRTC channel
   - Permissions: `['stream.view', 'stream.send', 'chat.send']`

### Channel Signal Scope
1. **Channel Owner**
   - Description: Owner of a Signal channel
   - Permissions: `['*']`

2. **Channel Moderator**
   - Description: Signal channel moderator
   - Permissions: `['message.delete', 'user.kick', 'user.mute']`

3. **Channel Member**
   - Description: Regular member of a Signal channel
   - Permissions: `['message.send', 'message.read', 'message.react']`

## Usage

### Import
```javascript
const {
    assignServerRole,
    assignChannelRole,
    getUserServerRoles,
    hasServerPermission,
    hasChannelPermission,
    createRole,
    deleteRole
} = require('./db/roleHelpers');
```

### Assign Server Roles
```javascript
// Make user an Administrator
await assignServerRole(userId, adminRoleId);

// Remove server role
await removeServerRole(userId, adminRoleId);

// Get all server roles of a user
const roles = await getUserServerRoles(userId);

// Check if user has a permission
const canManageUsers = await hasServerPermission(userId, 'user.manage');
```

### Assign Channel Roles
```javascript
// Make user a Channel Owner
await assignChannelRole(userId, ownerRoleId, channelId);

// Remove channel role
await removeChannelRole(userId, ownerRoleId, channelId);

// Get all channel roles of a user in a channel
const roles = await getUserChannelRoles(userId, channelId);

// Check if user has permission in channel
const canSendMessages = await hasChannelPermission(userId, channelId, 'message.send');
```

### Create Roles
```javascript
// Create new custom role
const newRole = await createRole({
    name: 'VIP',
    description: 'VIP members with special permissions',
    scope: 'server',
    permissions: ['channel.create', 'stream.hd']
});

// Update role (custom roles only)
await updateRole(roleId, {
    permissions: ['channel.create', 'stream.hd', 'message.priority']
});

// Delete role (custom roles only)
await deleteRole(roleId);
```

### Get Roles by Scope
```javascript
// All server roles
const serverRoles = await getRolesByScope('server');

// All WebRTC channel roles
const webrtcRoles = await getRolesByScope('channelWebRtc');

// All Signal channel roles
const signalRoles = await getRolesByScope('channelSignal');
```

## Permissions

### Format
Permissions are strings in format `resource.action`:
- `*`: All permissions
- `user.manage`: Manage users
- `channel.create`: Create channels
- `message.send`: Send messages
- `stream.view`: View streams
- etc.

### Check
Permission checking is done by:
1. Wildcard `*` → Full access
2. Exact match → Access granted

## Protection Against Changes

**Standard Roles** (`standard: true`) can:
- ✅ Be assigned
- ✅ Be removed
- ❌ NOT be changed
- ❌ NOT be deleted

**Custom Roles** (`standard: false`) can:
- ✅ Be assigned
- ✅ Be removed
- ✅ Be changed
- ✅ Be deleted

## Example Workflow

### 1. User Registers
```javascript
// Create user and assign default role
const user = await User.create({ email, displayName });
const userRole = await Role.findOne({ 
    where: { name: 'User', scope: 'server' } 
});
await assignServerRole(user.uuid, userRole.uuid);
```

### 2. User Creates a Channel
```javascript
// Create channel
const channel = await Channel.create({ name, type: 'signal' });

// Set user as Channel Owner
const ownerRole = await Role.findOne({ 
    where: { name: 'Channel Owner', scope: 'channelSignal' } 
});
await assignChannelRole(user.uuid, ownerRole.uuid, channel.uuid);
```

### 3. User Invites Others
```javascript
// Add invited user as Channel Member
const memberRole = await Role.findOne({ 
    where: { name: 'Channel Member', scope: 'channelSignal' } 
});
await assignChannelRole(invitedUserId, memberRole.uuid, channel.uuid);
```

### 4. Permission Check
```javascript
// Check if user can send messages
if (await hasChannelPermission(userId, channelId, 'message.send')) {
    // Send message
} else {
    // Deny access
}
```

## Migration

If the database already exists, run:
```bash
# Create backup
cp db/peerwave.sqlite db/peerwave.sqlite.backup

# Start server (sync: alter performs migration)
# Or manually:
node -e "require('./db/model.js')"
```

Standard roles are automatically initialized on server start.
