# Profile Page Implementation

## Overview
Complete user profile management system allowing users to view and edit their profile information, including displayName, profile picture, @name for mentions, and account deletion.

## Features

### ✅ Profile Information Display
- **UUID**: Read-only, unique identifier
- **Email**: Read-only, registered email address
- **Display Name**: Editable username shown in the app
- **@Name**: Editable unique identifier for @mentions in chat
- **Profile Picture**: Uploadable image (max 1MB)

### ✅ Real-time @Name Validation
- Checks availability as user types (500ms debounce)
- Shows green checkmark if available
- Shows error message if already taken
- Excludes current user's own @name from uniqueness check

### ✅ Account Deletion
- Two-step confirmation process:
  1. Initial warning dialog with "Delete Account" button
  2. Typed confirmation ("DELETE") to prevent accidental deletion
- Permanently deletes:
  - User account
  - All associated clients/devices
  - Signal keys (PreKeys, SignedPreKeys)
  - Channel memberships
- Redirects to login page after deletion

## File Structure

### Frontend (Flutter)
```
client/lib/app/profile_page.dart
```
- Main profile page UI
- Loads current user data on init
- Real-time @name availability checking
- Image picker for profile picture
- Two-step account deletion confirmation

### Backend (Node.js)
```
server/routes/client.js
```
Added endpoints:
- `GET /client/profile` - Get current user profile
- `POST /client/profile/update` - Update profile (displayName, picture, atName)
- `GET /client/profile/check-atname?atName=xxx` - Check @name availability
- `DELETE /client/profile/delete` - Delete account

### Routing
```
client/lib/main.dart
```
- Route: `/app/settings/profile`
- Accessible from Settings → Profile

## API Endpoints

### 1. GET /client/profile
**Description**: Retrieve current user's profile data

**Authentication**: Required (session.uuid)

**Response**:
```json
{
  "uuid": "550e8400-e29b-41d4-a716-446655440000",
  "email": "user@example.com",
  "displayName": "John Doe",
  "atName": "johndoe",
  "picture": "data:image/png;base64,iVBORw0KGgoAAAANS..."
}
```

### 2. POST /client/profile/update
**Description**: Update user profile information

**Authentication**: Required (session.uuid)

**Request Body**:
```json
{
  "displayName": "New Name",
  "atName": "newhandle",
  "picture": "data:image/png;base64,iVBORw0KGgoAAAANS..."
}
```

**Validation**:
- displayName: Required, must be unique
- atName: Optional, must be unique if provided
- picture: Optional, base64 data URL, max 1MB

**Response**:
```json
{
  "status": "ok",
  "message": "Profile updated successfully"
}
```

**Error Responses**:
- `409`: Display name or @name already taken
- `413`: Picture size too large (> 1MB)
- `400`: Invalid picture format or empty displayName

### 3. GET /client/profile/check-atname
**Description**: Check if @name is available

**Authentication**: Required (session.uuid)

**Query Parameters**:
- `atName`: The @name to check (e.g., `?atName=johndoe`)

**Response**:
```json
{
  "available": true,
  "atName": "johndoe"
}
```

**Logic**:
- Excludes current user from uniqueness check
- Returns `available: false` if taken by another user

### 4. DELETE /client/profile/delete
**Description**: Permanently delete user account

**Authentication**: Required (session.uuid)

**Response**:
```json
{
  "status": "ok",
  "message": "Account deleted successfully"
}
```

**Side Effects**:
- Deletes user record from `Users` table
- Deletes all associated `Clients` (devices)
- Deletes all `SignalPreKey` and `SignalSignedPreKey` records
- Removes user from all `ChannelMembers`
- Destroys user session
- Logs deletion event

## User Flow

### Viewing Profile
1. User navigates to Settings → Profile (`/app/settings/profile`)
2. Profile page loads current user data via `GET /client/profile`
3. Displays UUID, email (read-only), displayName, @name, and profile picture
4. Loading spinner shown during data fetch

### Editing Profile
1. User modifies displayName, @name, or uploads new picture
2. For @name changes:
   - 500ms debounce timer starts
   - After delay, `GET /client/profile/check-atname` called
   - Green checkmark shown if available, error message if taken
3. User clicks "Update Profile"
4. `POST /client/profile/update` called with changes
5. Success message shown, profile reloaded
6. Errors displayed in red banner if validation fails

### Uploading Picture
1. User clicks camera icon on profile avatar
2. Browser file picker opens (accepts `image/*`)
3. File loaded as ArrayBuffer, converted to Uint8List
4. Size validated (max 1MB), error shown if too large
5. Preview shown immediately in avatar
6. Picture encoded as base64 data URL on save

### Deleting Account
1. User clicks "Delete Account" button in Danger Zone
2. **First confirmation dialog**:
   - Warning about permanent deletion
   - Lists consequences (all data lost)
   - "Cancel" or "Delete Account" buttons
3. If confirmed, **second confirmation dialog**:
   - User must type "DELETE" to confirm
   - Text field validation before allowing deletion
4. `DELETE /client/profile/delete` called
5. Account deleted, session destroyed
6. User redirected to login page (`/`)

## Database Schema

### User Model
```javascript
User {
  uuid: UUID (primary key)
  email: STRING (unique, not null)
  displayName: STRING (unique, nullable)
  atName: STRING (unique, nullable)  // NEW: For @mentions
  picture: BLOB (nullable)
  active: BOOLEAN (default: true)
  createdAt: DATE
  updatedAt: DATE
}
```

**Key Constraints**:
- `displayName` and `atName` must be unique across all users
- `atName` is used for @mentions in chat (e.g., @johndoe)
- Picture stored as binary BLOB, returned as base64 data URL

## Security Considerations

### Authentication
- All endpoints require valid session (`req.session.uuid`)
- Returns 401 Unauthorized if session missing

### Authorization
- Users can only view/edit their own profile
- @name and displayName uniqueness enforced at database level
- Cannot claim another user's @name or displayName

### Data Validation
- Display name cannot be empty
- Picture size limited to 1MB
- Base64 picture format validated
- @name format validated (trimmed)

### Account Deletion
- Two-step confirmation prevents accidental deletion
- Hard delete (not soft) - user record permanently removed
- All associated data cascade deleted
- Session destroyed to prevent further requests

## UI Design

### Layout
- Centered card layout (max-width: 500px)
- Matches `RegisterProfilePage` styling
- White card with elevation shadow
- Rounded corners (16px border radius)

### Components
1. **Title Section**: "Profile Settings" heading with subtitle
2. **Avatar Section**: 
   - Large circular avatar (120px diameter)
   - Camera icon button overlay (bottom-right)
   - Shows current picture or placeholder icon
3. **Read-only Fields** (disabled, grey):
   - UUID with fingerprint icon
   - Email with email icon
4. **Editable Fields**:
   - Display Name (person icon)
   - @Name (alternate_email icon, "@" prefix)
5. **Error Banner**: Red background, error icon, message text
6. **Update Button**: Primary color, full width, loading spinner when saving
7. **Danger Zone**:
   - Red divider
   - Warning text
   - Red outlined "Delete Account" button with trash icon

### Loading States
- Initial load: Full-page circular progress indicator
- @name check: Small spinner in suffix icon
- Saving: Button shows spinner, disabled state
- Account deletion: Button disabled during request

### Error Handling
- Network errors caught and displayed in error banner
- Validation errors shown inline (e.g., @name availability)
- Success messages shown as green SnackBar
- All errors logged to console

## Testing

### Manual Test Cases

#### ✅ Profile Loading
1. Navigate to `/app/settings/profile`
2. Verify UUID, email, displayName, @name displayed correctly
3. Verify profile picture loaded if exists

#### ✅ Display Name Update
1. Change display name
2. Click "Update Profile"
3. Verify success message
4. Reload page, verify change persisted

#### ✅ @Name Uniqueness
1. Enter existing @name from another user
2. Wait 500ms
3. Verify error message "This @name is already taken"
4. Try to save, verify error shown
5. Change to unique @name
6. Verify green checkmark appears

#### ✅ Picture Upload
1. Click camera icon
2. Select image < 1MB
3. Verify preview shown immediately
4. Click "Update Profile"
5. Verify success message
6. Reload page, verify picture persisted

#### ✅ Picture Size Limit
1. Click camera icon
2. Select image > 1MB
3. Verify error message "Image is too large. Maximum size is 1MB."

#### ✅ Account Deletion Flow
1. Click "Delete Account"
2. Click "Cancel" in first dialog → Nothing happens
3. Click "Delete Account" again
4. Click "Delete Account" in first dialog
5. Type "DELET" (wrong) in second dialog
6. Verify error message
7. Type "DELETE" correctly
8. Click "Confirm Deletion"
9. Verify account deleted
10. Verify redirected to login page

## Known Limitations

1. **Picture Format**: Only images supported (no GIFs, videos)
2. **Picture Size**: Hard limit of 1MB (backend enforced)
3. **@Name Validation**: Basic uniqueness check only (no regex pattern enforcement)
4. **Account Recovery**: No soft delete - deletion is permanent
5. **Debounce**: Fixed 500ms delay (not configurable)

## Future Enhancements

### Potential Features
- [ ] Password change functionality
- [ ] Two-factor authentication settings
- [ ] Email change with verification
- [ ] Session management (view/revoke active sessions)
- [ ] Profile visibility settings (public/private)
- [ ] Custom bio/status text
- [ ] Account export (GDPR compliance)
- [ ] Soft delete with 30-day grace period

### Technical Improvements
- [ ] Image cropping before upload
- [ ] Multiple image format support (WebP, AVIF)
- [ ] Progressive image loading
- [ ] Optimistic UI updates
- [ ] Form validation library (e.g., form_builder_validators)
- [ ] Better debounce implementation (cancelable timer)

## Troubleshooting

### Common Issues

**Problem**: Profile page shows loading spinner indefinitely
- **Cause**: `GET /client/profile` endpoint failing
- **Solution**: Check server logs, verify session is valid

**Problem**: "@name already taken" error when using own @name
- **Cause**: Logic error in uniqueness check
- **Solution**: Verify `uuid: { [Op.ne]: userUuid }` in query

**Problem**: Picture upload fails silently
- **Cause**: Base64 encoding error or size validation issue
- **Solution**: Check browser console for errors, verify file size < 1MB

**Problem**: Account deletion doesn't redirect
- **Cause**: Session not properly destroyed
- **Solution**: Check `req.session.destroy()` call in backend

**Problem**: @name check shows spinner forever
- **Cause**: `/client/profile/check-atname` endpoint error
- **Solution**: Check server logs, verify query parameter format

## Deployment Notes

### Prerequisites
- Existing User table with `atName` column (nullable, unique)
- Session middleware configured in server
- ApiService properly initialized in Flutter app

### Migration Steps
1. Ensure database has `atName` column:
   ```sql
   ALTER TABLE Users ADD COLUMN atName VARCHAR(255) UNIQUE;
   ```
2. Deploy backend changes (client.js)
3. Deploy frontend changes (profile_page.dart, main.dart)
4. Test in staging environment
5. Deploy to production
6. Monitor logs for errors

### Rollback Plan
If issues arise:
1. Revert frontend: Replace ProfilePage route with placeholder
2. Revert backend: Remove new endpoints from client.js
3. Database rollback: Drop `atName` column if not used

## Code Metrics

### Frontend
- **File**: `client/lib/app/profile_page.dart`
- **Lines**: ~650 lines
- **State Management**: StatefulWidget with local state
- **Dependencies**: 
  - `dart:html` (file picker)
  - `dart:convert` (base64 encoding)
  - `go_router` (navigation)
  - `api_service` (HTTP requests)

### Backend
- **File**: `server/routes/client.js`
- **New Endpoints**: 4
- **Lines Added**: ~220 lines
- **Dependencies**: Existing (Sequelize, express)

## References

- **Design Reference**: `register_profile_page.dart`
- **Database Model**: `server/db/model.js`
- **API Service**: `client/lib/services/api_service.dart`
- **Routing**: `client/lib/main.dart`

## Changelog

### v1.0.0 (2024-01-XX)
- ✅ Initial implementation
- ✅ Profile viewing and editing
- ✅ @name uniqueness validation
- ✅ Profile picture upload
- ✅ Account deletion with confirmation
- ✅ Real-time @name availability check
- ✅ Integration with Settings navigation
