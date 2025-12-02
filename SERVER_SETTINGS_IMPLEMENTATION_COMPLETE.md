# Server Settings & Invitation System Implementation

## Overview
This document describes the complete implementation of the server settings management system with registration controls and email-based invitation system for PeerWave.

## Implementation Date
December 2024

## Features Implemented

### 1. Server Settings Management
- **Server Identity Configuration**
  - Server name customization
  - Server picture/logo upload (base64 encoded, max 2MB)
  - Displayed in /client/meta endpoint for all clients

### 2. Registration Control System
Three registration modes:
- **Open**: Anyone can register (default)
- **Email Suffix**: Only specific email domains allowed (e.g., @company.com)
- **Invitation Only**: Requires valid invitation token to register

### 3. Email-Based Invitation System
- Send invitations to specific email addresses
- 6-digit invitation tokens (similar to OTP)
- 48-hour expiration period
- Email delivery via nodemailer
- Track invitation status (sent, used, expired)
- Admin can revoke invitations

### 4. Permission-Based Access Control
- Server settings management requires `server.manage` permission
- Admin-only access to server settings page
- Non-admin users see "no permission" message

---

## Backend Implementation

### Database Schema

#### ServerSettings Table
```sql
CREATE TABLE ServerSettings (
  id INTEGER PRIMARY KEY,           -- Always 1 (single-row table)
  server_name VARCHAR(255),         -- Server display name
  server_picture TEXT,              -- Base64 encoded image
  registration_mode VARCHAR(50),    -- 'open', 'email_suffix', 'invitation_only'
  allowed_email_suffixes TEXT,      -- JSON array of allowed domains
  created_at TIMESTAMP,
  updated_at TIMESTAMP
);
```

#### Invitations Table
```sql
CREATE TABLE Invitations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  email VARCHAR(255) NOT NULL,      -- Invited email address
  token VARCHAR(6) NOT NULL,        -- 6-digit invitation code
  expires_at TIMESTAMP NOT NULL,    -- 48 hours from creation
  used BOOLEAN DEFAULT FALSE,       -- Whether invitation was used
  used_at TIMESTAMP,                -- When invitation was used
  invited_by VARCHAR(36),           -- UUID of admin who sent invite
  created_at TIMESTAMP,
  updated_at TIMESTAMP,
  
  INDEX idx_email (email),
  INDEX idx_token (token),
  INDEX idx_expires_at (expires_at)
);
```

### API Endpoints

#### Server Settings Routes (Admin Only)

**GET /api/server/settings**
- Returns current server settings
- Requires: `server.manage` permission
- Response:
```json
{
  "status": "ok",
  "settings": {
    "serverName": "PeerWave Server",
    "serverPicture": "data:image/png;base64,...",
    "registrationMode": "open",
    "allowedEmailSuffixes": ["company.com"]
  }
}
```

**POST /api/server/settings**
- Updates server settings
- Requires: `server.manage` permission
- Body:
```json
{
  "serverName": "My Server",
  "serverPicture": "data:image/png;base64,...",
  "registrationMode": "invitation_only",
  "allowedEmailSuffixes": ["example.com"]
}
```

#### Invitation Routes (Admin Only)

**POST /api/server/invitations/send**
- Sends invitation email with 6-digit token
- Requires: `server.manage` permission
- Body: `{ "email": "user@example.com" }`
- Generates random 6-digit token, stores in database
- Sends email via nodemailer

**GET /api/server/invitations**
- Lists all active (unused, non-expired) invitations
- Requires: `server.manage` permission
- Returns array of invitation objects

**DELETE /api/server/invitations/:id**
- Revokes an invitation
- Requires: `server.manage` permission
- Removes invitation from database

#### Public Invitation Route

**POST /api/invitations/verify**
- Validates invitation token (does not mark as used)
- Public endpoint (no auth required)
- Body: `{ "email": "user@example.com", "token": "123456" }`
- Response: `{ "valid": true/false, "message": "..." }`

### Registration Flow Updates

**POST /register** (Modified)
1. Accept optional `invitationToken` field
2. Check `ServerSettings.registration_mode`:
   - **open**: Allow registration
   - **email_suffix**: Validate email domain against `allowed_email_suffixes`
   - **invitation_only**: Require valid `invitationToken`
3. If invitation required, validate token:
   - Must match email + token in Invitations table
   - Must not be used (`used = false`)
   - Must not be expired (`expires_at > NOW()`)
4. Store `pendingInvitationId` in session for later use

**POST /otp** (Modified)
1. After successful OTP verification
2. If `pendingInvitationId` exists in session:
   - Mark invitation as used: `UPDATE Invitations SET used = true, used_at = NOW()`
   - Remove `pendingInvitationId` from session
3. Complete registration as normal

### Client Metadata Update

**GET /client/meta** (Modified)
- Now includes server settings in response
- Response:
```json
{
  "serverName": "PeerWave Server",
  "serverPicture": "data:image/png;base64,...",
  "registrationMode": "open",
  "features": { ... },
  "licenseInfo": { ... }
}
```

---

## Frontend Implementation (Flutter)

### New Components

#### ServerSettingsPage
Location: `client/lib/app/settings/server_settings_page.dart`

Features:
- Server identity section (name + picture upload)
- Registration mode dropdown selector
- Conditional email suffixes field (for email_suffix mode)
- Conditional invitation management section (for invitation_only mode)
- Send invitation form (email input + send button)
- Active invitations list with token display and revoke button
- Permission check: Shows "no permission" message for non-admins

State Management:
- `_serverNameController`: Server name input
- `_emailSuffixesController`: Comma-separated email domains
- `_inviteEmailController`: Invitation email input
- `_registrationMode`: Current registration mode
- `_invitations`: List of active invitations
- `_imageBytes`: Uploaded server picture
- `_currentImageBytes`: Existing server picture

API Calls:
- `GET /api/server/settings` on page load
- `POST /api/server/settings` on save
- `GET /api/server/invitations` when mode is invitation_only
- `POST /api/server/invitations/send` to send invitation
- `DELETE /api/server/invitations/:id` to revoke invitation

### Router Configuration

**main.dart** (Modified)
Added route in both web and native route configurations:
```dart
GoRoute(
  path: '/app/settings/server',
  builder: (context, state) => const ServerSettingsPage(),
  redirect: (context, state) {
    final roleProvider = context.read<RoleProvider>();
    if (!roleProvider.hasServerPermission('server.manage')) {
      return '/app/settings';
    }
    return null;
  },
)
```

### Settings Sidebar Update

**settings_sidebar.dart** (Modified)
Added server settings link with permission check:
```dart
Consumer<RoleProvider>(
  builder: (context, roleProvider, child) {
    if (roleProvider.hasServerPermission('server.manage')) {
      return ListTile(
        leading: const Icon(Icons.dns),
        title: const Text('Server Settings'),
        onTap: () => GoRouter.of(context).go('/app/settings/server'),
      );
    }
    return const SizedBox.shrink();
  },
)
```

---

## File Changes Summary

### Backend Files

#### Created
- `server/migrations/add_server_settings.js` - Database migration for ServerSettings + Invitations tables

#### Modified
- `server/db/model.js` - Added ServerSettings and Invitation model exports
- `server/routes/client.js` - Added server settings + invitation API routes
- `server/routes/auth.js` - Updated registration flow with invitation validation
- `server/server.js` - Added migration runner for server settings

### Frontend Files

#### Created
- `client/lib/app/settings/server_settings_page.dart` - Server settings UI page

#### Modified
- `client/lib/main.dart` - Added server settings route (web + native)
- `client/lib/app/settings_sidebar.dart` - Added server settings link with permission check

---

## Testing Checklist

### Database Migration
- [ ] Run server and verify ServerSettings table created
- [ ] Verify Invitations table created with indexes
- [ ] Verify default ServerSettings row inserted (id=1, server_name='PeerWave Server', registration_mode='open')

### Server Settings API
- [ ] Test GET /api/server/settings as admin (returns current settings)
- [ ] Test GET /api/server/settings as non-admin (403 Forbidden)
- [ ] Test POST /api/server/settings with server name update
- [ ] Test POST /api/server/settings with picture upload (base64)
- [ ] Test POST /api/server/settings with registration mode change
- [ ] Test POST /api/server/settings as non-admin (403 Forbidden)

### Invitation API
- [ ] Test POST /api/server/invitations/send with valid email
- [ ] Verify email received with 6-digit token
- [ ] Test GET /api/server/invitations returns active invitations
- [ ] Test DELETE /api/server/invitations/:id revokes invitation
- [ ] Test POST /api/invitations/verify with valid token (returns valid: true)
- [ ] Test POST /api/invitations/verify with invalid token (returns valid: false)
- [ ] Test POST /api/invitations/verify with expired token (returns valid: false)

### Registration Flow
- [ ] Test registration in **open** mode (should work without token)
- [ ] Test registration in **email_suffix** mode with allowed domain
- [ ] Test registration in **email_suffix** mode with disallowed domain (403 Forbidden)
- [ ] Test registration in **invitation_only** mode without token (403 Forbidden)
- [ ] Test registration in **invitation_only** mode with invalid token (403 Forbidden)
- [ ] Test registration in **invitation_only** mode with valid token (should work)
- [ ] Verify invitation marked as used after successful registration

### Frontend UI
- [ ] Test server settings page loads correctly as admin
- [ ] Test server settings page shows "no permission" message as non-admin
- [ ] Test server name update saves and reloads correctly
- [ ] Test server picture upload (web only)
- [ ] Test registration mode dropdown changes UI conditionally
- [ ] Test email suffixes field appears in email_suffix mode
- [ ] Test invitation section appears in invitation_only mode
- [ ] Test send invitation form sends email and updates list
- [ ] Test revoke invitation removes from list
- [ ] Test settings sidebar shows server settings link for admins only
- [ ] Test navigation to /app/settings/server works

### Integration Tests
- [ ] Test /client/meta includes server settings fields
- [ ] Test full registration flow with invitation end-to-end
- [ ] Test invitation expiration after 48 hours
- [ ] Test invitation cannot be reused after registration
- [ ] Test role permissions prevent unauthorized access

---

## Security Considerations

1. **Permission Checks**: All admin routes check `hasServerPermission('server.manage')`
2. **Email Validation**: Registration validates email format and domain restrictions
3. **Token Security**: 6-digit tokens with 48-hour expiration minimize attack window
4. **Single-Use Tokens**: Invitations marked as used after registration
5. **Input Validation**: Server validates all input parameters
6. **File Size Limits**: Server picture uploads limited to 2MB
7. **SQL Injection Protection**: All queries use Sequelize ORM with parameterization
8. **XSS Prevention**: Frontend sanitizes all user input

---

## Future Enhancements

1. **Native Image Picker**: Implement file picker for native clients (currently web-only)
2. **Bulk Invitations**: Support sending multiple invitations at once
3. **Invitation Templates**: Customizable email templates for invitations
4. **Registration Analytics**: Track registration success rates by mode
5. **Invitation Resend**: Allow resending expired invitations
6. **Custom Token Length**: Configurable token length (4-10 digits)
7. **Domain Autocomplete**: Suggest common email domains in email_suffix mode
8. **Invitation Audit Log**: Track who invited whom and when

---

## Configuration

### Email Configuration
Update `server/config/config.js`:
```javascript
smtp: {
  host: 'smtp.gmail.com',
  port: 587,
  secure: false,
  auth: {
    user: 'your-email@gmail.com',
    pass: 'your-app-password'
  },
  senderadress: 'noreply@peerwave.com'
}
```

### Default Settings
Default values in database:
- Server Name: 'PeerWave Server'
- Registration Mode: 'open'
- Allowed Email Suffixes: []
- Server Picture: null

---

## Troubleshooting

### Migration Fails
- Check database connection in `server/db/model.js`
- Verify sequelize version compatibility
- Check server logs for specific error messages

### Email Not Sending
- Verify SMTP configuration in `config.js`
- Check firewall/port blocking (587 or 465)
- Enable "Less Secure Apps" for Gmail (or use App Password)
- Check nodemailer logs for connection errors

### Permission Denied
- Verify user has `server.manage` permission
- Check RoleProvider initialization in Flutter
- Verify session/HMAC auth working correctly
- Check browser console for 403 errors

### Invitation Not Working
- Verify invitation table created correctly
- Check invitation not expired (< 48 hours)
- Verify email matches invitation email exactly
- Check invitation not already used

---

## Implementation Status

✅ **Completed:**
- Database migration file created
- Models added to exports
- All backend API routes implemented
- Registration validation updated
- Invitation verification implemented
- Flutter ServerSettingsPage created
- Router configuration updated
- Settings sidebar link added
- Permission checks implemented

❌ **Pending:**
- End-to-end testing
- Native image picker implementation
- Email template customization

---

## Related Documentation

- `HMAC_SESSION_AUTH_IMPLEMENTATION.md` - Dual authentication system
- `SERVER_HMAC_AUTH_IMPLEMENTATION.md` - Server-side HMAC implementation
- `docs/DESIGN_SYSTEM_IMPLEMENTATION.md` - UI design patterns
- `docs/ADAPTIVE_LAYOUT_MIGRATION_GUIDE.md` - Layout patterns

---

## Contact & Support

For questions or issues related to this implementation:
1. Check server logs: `docker-compose logs -f server`
2. Check client logs: Flutter console output
3. Review this document for troubleshooting steps
4. Check database state: `SELECT * FROM ServerSettings;`

---

**Implementation by:** GitHub Copilot
**Last Updated:** December 2024
