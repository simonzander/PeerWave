# Auto-Assign Roles Feature

## Overview
This feature automatically assigns roles to users as soon as they are verified (after OTP entry).

## Configuration

### Define Admin List
In `server/config/config.js`:

```javascript
config.admin = [
    'admin@example.com',
    'another.admin@example.com'
];
```

## How It Works

### 1. Registration & Verification
```
User registers → Email with OTP → User enters OTP → Verification
```

### 2. Automatic Role Assignment

#### A) During Registration
After successful verification (`POST /otp`):

```javascript
// In auth.js
await User.update({ verified: true }, { where: { email } });
const updatedUser = await User.findOne({ where: { email } });

// Automatic role assignment
await autoAssignRoles(email, updatedUser.uuid);
```

#### B) During Subsequent Authentication
When an admin is added to the `config.admin` list **afterwards**, they automatically receive the Administrator role on their **next login**.

**Trigger Points**:

**WebAuthn Authentication** (`POST /webauthn/authenticate`):
```javascript
if (authnResult.audit.complete && user.verified && config.admin.includes(email)) {
    await autoAssignRoles(email, user.uuid);
}
```

**Magic Link Verification** (`POST /magic/verify`):
```javascript
const user = await User.findOne({ where: { uuid: entry.uuid } });
if (user && user.verified && config.admin.includes(entry.email)) {
    await autoAssignRoles(entry.email, entry.uuid);
}
```

**Client Login** (`POST /client/login`):
```javascript
if (owner.verified && config.admin.includes(owner.email)) {
    await autoAssignRoles(owner.email, owner.uuid);
}
```

**Advantage**: Admins can be added **retroactively** without database migration. The role is automatically assigned on next login.

### 3. Role Logic
```javascript
// In db/autoAssignRoles.js
if (config.admin.includes(userEmail)) {
    // Assign Administrator role
    const adminRole = await Role.findOne({ 
        where: { name: 'Administrator', scope: 'server' } 
    });
    await assignServerRole(userId, adminRole.uuid);
} else {
    // Assign default User role
    const userRole = await Role.findOne({ 
        where: { name: 'User', scope: 'server' } 
    });
    await assignServerRole(userId, userRole.uuid);
}
```

## Permissions

### Administrator
- **Permissions**: `['*']` (Wildcard = All Rights)
- **Can**:
  - Manage all users
  - Manage all channels
  - Moderate messages
  - Change server settings
  - Create/edit/delete roles (except standard roles)

### User (Default)
- **Permissions**: `['channel.join', 'message.send', 'message.read']`
- **Can**:
  - Join channels
  - Send/read messages
  - Manage own account

## Example Scenarios

### Scenario 1: Admin Registers
```
1. admin@example.com registers
2. Receives OTP via email
3. Enters OTP
4. System checks: admin@example.com is in config.admin
5. ✅ Administrator role assigned
6. Console log: "✓ Administrator role assigned to user: admin@example.com"
```

### Scenario 2: Regular User Registers
```
1. user@example.com registers
2. Receives OTP via email
3. Enters OTP
4. System checks: user@example.com is NOT in config.admin
5. ✅ User role assigned
6. Console log: "✓ User role assigned to user: user@example.com"
```

### Scenario 3: Retroactive Admin Assignment
```
1. user@example.com is already registered (with User role)
2. Admin adds user@example.com to config.admin
3. Server is restarted (config.admin is reloaded)
4. user@example.com logs in (WebAuthn/Magic Link/Client Login)
5. System checks: user@example.com is NOW in config.admin
6. ✅ Administrator role assigned
7. Console log: "✓ Administrator role assigned to user: user@example.com"
8. User now has both roles: User + Administrator
```

**Important**: The user keeps their old User role and receives the Administrator role additionally. This is correct since an admin should have all user rights.

## API Usage

### Get User Roles
```javascript
const { getUserServerRoles } = require('./db/roleHelpers');

const roles = await getUserServerRoles(userId);
console.log(roles);
// [{ uuid: '...', name: 'Administrator', scope: 'server', permissions: ['*'] }]
```

### Check Permissions
```javascript
const { hasServerPermission } = require('./db/roleHelpers');

const canManageUsers = await hasServerPermission(userId, 'user.manage');
if (canManageUsers) {
    // User can manage other users
}
```

## Migrating Existing Users

If users already exist in the database, you can create a migration script:

```javascript
// migrations/assignRolesToExistingUsers.js
const { User, Role } = require('../db/model');
const { autoAssignRoles } = require('../db/autoAssignRoles');

async function migrateExistingUsers() {
    const verifiedUsers = await User.findAll({ 
        where: { verified: true } 
    });
    
    for (const user of verifiedUsers) {
        try {
            await autoAssignRoles(user.email, user.uuid);
            console.log(`✓ Roles assigned to ${user.email}`);
        } catch (error) {
            console.error(`✗ Error for ${user.email}:`, error);
        }
    }
    
    console.log(`Migration complete: ${verifiedUsers.length} users processed`);
}

migrateExistingUsers();
```

Execute:
```bash
cd server
node migrations/assignRolesToExistingUsers.js
```

## Logging

Role assignment is automatically logged:

```
✓ Administrator role assigned to user: admin@example.com
✓ User role assigned to user: user@example.com
```

On errors:
```
Error auto-assigning roles for user@example.com: [Error Details]
```

**Important**: Role assignment errors do NOT block verification. The user will still be verified.

## Security Notes

### ✅ Best Practices
1. **Protect admin list**: Don't commit `config.js` to Git (`.gitignore`)
2. **Environment variables**: Load admin emails from `.env`
3. **Logging**: Admin assignments should be audited
4. **Minimal principle**: Only necessary emails in admin list

### ⚠️ Recommended Change
Instead of hardcoded admin list in `config.js`:

```javascript
// .env
ADMIN_EMAILS=admin@example.com,s.bergt@googlemail.com

// config.js
config.admin = process.env.ADMIN_EMAILS 
    ? process.env.ADMIN_EMAILS.split(',').map(e => e.trim()) 
    : [];
```

## Troubleshooting

### Problem: Admin doesn't receive admin role
**Solution**:
1. Check `config.admin` array: `console.log(config.admin)`
2. Check email address (case-sensitive!)
3. Check if Administrator role exists in DB
4. Check console logs: "✓ Administrator role assigned..."

### Problem: User has no role
**Solution**:
1. Check if user is verified: `user.verified === true`
2. Check if User role exists in DB (standard roles)
3. Check UserRole junction table: `SELECT * FROM UserRoles WHERE userId = '...'`

### Problem: Standard roles are missing
**Solution**:
```bash
# Start server once with alter: true
# Change in model.js:
sequelize.sync({ alter: true })

# Start server → Standard roles will be created
npm start
```

## Testing

### Manual Test
1. Start server: `npm start`
2. Register user with admin email from `config.admin`
3. Enter OTP
4. Check console: "✓ Administrator role assigned..."
5. Check DB: `SELECT * FROM UserRoles`

### Unit Test
```javascript
// test/autoAssignRoles.test.js
const { autoAssignRoles } = require('../db/autoAssignRoles');
const { getUserServerRoles } = require('../db/roleHelpers');

describe('Auto Assign Roles', () => {
    it('should assign admin role to admin email', async () => {
        const adminEmail = 'admin@example.com';
        const userId = 'test-uuid';
        
        await autoAssignRoles(adminEmail, userId);
        const roles = await getUserServerRoles(userId);
        
        expect(roles[0].name).toBe('Administrator');
    });
    
    it('should assign user role to regular email', async () => {
        const userEmail = 'user@example.com';
        const userId = 'test-uuid-2';
        
        await autoAssignRoles(userEmail, userId);
        const roles = await getUserServerRoles(userId);
        
        expect(roles[0].name).toBe('User');
    });
});
```

## Summary

✅ **What the feature does**:
- Admins (config.admin) → Administrator role
- Other users → User role
- Automatic on verification (OTP)

✅ **What you need to do**:
1. Add admin emails to `config.admin`
2. (Re)start server
3. Register and verify users

✅ **What happens automatically**:
- Role assignment after OTP
- Console logging
- DB entry in UserRoles
