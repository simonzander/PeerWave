# Role System Frontend Integration Guide

This guide explains how to integrate the role-based access control (RBAC) system into your PeerWave Flutter application.

## Overview

The role system consists of:
- **Models**: `Role` and `UserRoles` for data representation
- **API Service**: `RoleApiService` for backend communication
- **State Management**: `RoleProvider` for managing role state
- **UI Widgets**: Permission-based widgets for conditional rendering
- **Screens**: Admin and channel management UIs

## Installation

The required dependencies have been added to `pubspec.yaml`:
- `provider: ^6.1.2` - State management
- `http: ^1.5.0` - Already installed

Run `flutter pub get` if not already done.

## Integration Steps

### 1. Initialize RoleProvider in main.dart

Add the RoleProvider to your main app's MultiProvider:

```dart
import 'package:provider/provider.dart';
import 'providers/role_provider.dart';
import 'services/role_api_service.dart';
import 'web_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Load server URL for web platform
  String? serverUrl = await loadWebApiServer();
  serverUrl ??= 'http://localhost:3000'; // Fallback for non-web platforms
  
  runApp(
    MultiProvider(
      providers: [
        // ... your existing providers ...
        
        ChangeNotifierProvider(
          create: (context) => RoleProvider(
            apiService: RoleApiService(baseUrl: serverUrl!),
          ),
        ),
      ],
      child: const MyApp(),
    ),
  );
}
```

### 2. Load User Roles After Login

After successful login (OTP, WebAuthn, Magic Link, or Client Login), load the user's roles:

```dart
// In your authentication logic
Future<void> onLoginSuccess() async {
  final roleProvider = Provider.of<RoleProvider>(context, listen: false);
  await roleProvider.loadUserRoles();
  
  // Navigate to home screen
  // ...
}
```

### 3. Clear Roles on Logout

When the user logs out, clear their roles:

```dart
Future<void> onLogout() async {
  final roleProvider = Provider.of<RoleProvider>(context, listen: false);
  roleProvider.clearRoles();
  
  // Clear session and navigate to login
  // ...
}
```

### 4. Use Permission Widgets in UI

Use the provided widgets to conditionally show/hide UI elements based on permissions:

#### Server-Level Permissions

```dart
import 'widgets/permission_widget.dart';

// Show content only to admins
AdminOnlyWidget(
  child: ElevatedButton(
    onPressed: () {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => RoleManagementScreen(),
        ),
      );
    },
    child: Text('Manage Roles'),
  ),
)

// Show content only to moderators or higher
ModeratorOnlyWidget(
  child: ListTile(
    leading: Icon(Icons.settings),
    title: Text('Server Settings'),
    onTap: () { /* ... */ },
  ),
)

// Check specific permission
PermissionWidget(
  permission: 'user.manage',
  child: IconButton(
    icon: Icon(Icons.person_remove),
    onPressed: () { /* Kick user */ },
  ),
)
```

#### Channel-Level Permissions

```dart
// Show content only to channel owners
ChannelOwnerWidget(
  channelId: currentChannelId,
  child: IconButton(
    icon: Icon(Icons.delete),
    onPressed: () { /* Delete channel */ },
  ),
)

// Show content only to channel moderators or higher
ChannelModeratorWidget(
  channelId: currentChannelId,
  child: PopupMenuButton(
    itemBuilder: (context) => [
      PopupMenuItem(
        child: Text('Manage Members'),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ChannelMembersScreen(
                channelId: currentChannelId,
                channelName: currentChannelName,
                channelScope: RoleScope.channelWebRtc, // or channelSignal
              ),
            ),
          );
        },
      ),
    ],
  ),
)

// Check channel-specific permission
PermissionWidget(
  permission: 'user.kick',
  channelId: currentChannelId,
  child: IconButton(
    icon: Icon(Icons.remove_circle),
    onPressed: () { /* Kick user from channel */ },
  ),
)
```

### 5. Add Role Management Screen

Add the role management screen to your admin panel or settings:

```dart
import 'screens/admin/role_management_screen.dart';

// In your admin panel or settings menu
ListTile(
  leading: Icon(Icons.security),
  title: Text('Role Management'),
  onTap: () {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RoleManagementScreen(),
      ),
    );
  },
)
```

### 6. Add Channel Member Management

In your channel view, add a button to manage members:

```dart
import 'screens/channel/channel_members_screen.dart';

// In channel AppBar actions
IconButton(
  icon: Icon(Icons.people),
  onPressed: () {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChannelMembersScreen(
          channelId: channel.id,
          channelName: channel.name,
          channelScope: channel.isSignal 
            ? RoleScope.channelSignal 
            : RoleScope.channelWebRtc,
        ),
      ),
    );
  },
)
```

## Permission Checks in Code

You can also check permissions programmatically:

```dart
final roleProvider = Provider.of<RoleProvider>(context, listen: false);

// Check if user is admin
if (roleProvider.isAdmin) {
  // Show admin features
}

// Check server permission
if (roleProvider.hasServerPermission('user.manage')) {
  // Allow user management
}

// Check channel permission
if (roleProvider.hasChannelPermission(channelId, 'role.assign')) {
  // Allow role assignment in channel
}

// Check channel ownership
if (roleProvider.isChannelOwner(channelId)) {
  // Show channel owner features
}
```

## API Endpoints

The following endpoints are available:

- `GET /api/user/roles` - Get current user's roles
- `GET /api/roles?scope=X` - List roles by scope
- `POST /api/roles` - Create new role (requires `role.create`)
- `PUT /api/roles/:roleId` - Update role (requires `role.edit`)
- `DELETE /api/roles/:roleId` - Delete role (requires `role.delete`)
- `POST /api/users/:userId/channels/:channelId/roles` - Assign channel role (requires `role.assign`)
- `DELETE /api/users/:userId/channels/:channelId/roles/:roleId` - Remove channel role
- `GET /api/channels/:channelId/members` - Get channel members (requires `member.view`)
- `POST /api/user/check-permission` - Check permission

## Standard Roles

The system includes 9 standard roles that cannot be modified or deleted:

### Server Scope
1. **Administrator** - Full server access (`*`)
2. **Moderator** - User/channel management, moderation, role management
3. **User** - Basic authenticated user

### Channel WebRTC Scope
4. **Channel Owner** - Full channel control (`*`)
5. **Channel Moderator** - Kick, mute, stream management, role assignment
6. **Channel Member** - View, send streams, chat, view members

### Channel Signal Scope
7. **Channel Owner** - Full channel control (`*`)
8. **Channel Moderator** - Delete messages, kick, mute, role assignment
9. **Channel Member** - Send, read, react to messages, view members

## Common Permissions

### Server Permissions
- `user.manage` - Manage users
- `user.kick` - Kick users from server
- `channel.manage` - Manage channels
- `channel.create` - Create channels
- `message.moderate` - Moderate messages
- `role.create` - Create custom roles
- `role.edit` - Edit custom roles
- `role.delete` - Delete custom roles
- `role.assign` - Assign roles to users

### Channel Permissions
- `user.kick` - Kick users from channel
- `user.mute` - Mute users in channel
- `stream.manage` - Manage streams (WebRTC)
- `stream.view` - View streams (WebRTC)
- `stream.send` - Send streams (WebRTC)
- `chat.send` - Send chat messages
- `message.send` - Send messages (Signal)
- `message.read` - Read messages (Signal)
- `message.react` - React to messages (Signal)
- `message.delete` - Delete messages
- `member.view` - View channel members
- `role.assign` - Assign roles in channel

## Auto-Assign Roles

Users are automatically assigned roles when they verify their account:

- Email addresses in `config.admin` array → **Administrator** role
- All other verified users → **User** role

This happens on:
- OTP verification
- WebAuthn authentication
- Magic link verification
- Client login

## Testing

To test the role system:

1. **Admin Panel**: Log in with an admin account and navigate to Role Management
2. **Create Custom Role**: Create a role with specific permissions
3. **Channel Management**: Open a channel and manage member roles
4. **Permission Checks**: Verify that UI elements show/hide based on permissions
5. **API Testing**: Use the browser dev tools to verify API calls

## Troubleshooting

### Roles not loading
- Check that `loadUserRoles()` is called after login
- Verify the backend API is running
- Check browser console for errors

### Permission widgets not working
- Ensure RoleProvider is in the widget tree
- Verify user roles are loaded (`roleProvider.isLoaded`)
- Check that permissions match exactly (case-sensitive)

### Cannot create/edit roles
- Verify user has `role.create` or `role.edit` permission
- Check that standard roles are not being modified
- Review backend logs for errors

## Next Steps

1. Add role management to your admin panel
2. Add member management to channel views
3. Implement permission checks in your existing features
4. Test role assignment and permission checks
5. Customize permissions based on your needs

For more information, see:
- `server/db/ROLES_README.md` - Backend role system documentation
- `server/db/AUTO_ASSIGN_ROLES_README.md` - Auto-assign roles documentation
