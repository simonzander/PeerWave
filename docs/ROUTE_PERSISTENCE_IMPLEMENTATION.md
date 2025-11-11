# Route Persistence Implementation

## Overview
Implemented route persistence to remember the last visited `/app/*` route before redirecting to signal-setup, then restore it after successful setup.

## User Story
- **Before**: User at `http://localhost:3000/#/app/people` → reload → redirected to signal-setup → after setup, landed at `/app/activities`
- **After**: User at `http://localhost:3000/#/app/people` → reload → redirected to signal-setup → after setup, returns to `/app/people`

## Implementation

### 1. PreferencesService Updates
**File**: `client/lib/services/preferences_service.dart`

Added three new methods to manage last route persistence:

```dart
/// Saves the last visited /app/* route for restoration
Future<void> saveLastRoute(String route)

/// Loads the last visited /app/* route
Future<String?> loadLastRoute()

/// Clears the saved last route
Future<void> clearLastRoute()
```

- Uses IndexedDB on web (same storage as theme preferences)
- Uses SharedPreferences on native platforms
- Storage key: `'last_app_route'`

### 2. Main Router Logic Updates
**File**: `client/lib/main.dart`

Updated the redirect logic to:

1. **Check signal keys for all `/app/*` routes** (not just `/app` and `/`)
   - Changed condition from `if (location == '/app' || location == '/')` 
   - To: `if (location == '/app' || location == '/' || location.startsWith('/app/'))`

2. **Save current route before redirecting to signal-setup**
   ```dart
   if (needsSetup) {
     // Save current route if it's a specific /app/* route
     if (location.startsWith('/app/') && location != '/app' && location != '/') {
       await PreferencesService().saveLastRoute(location);
     }
     return '/signal-setup';
   }
   ```

### 3. Signal Setup Screen Updates
**File**: `client/lib/screens/signal_setup_screen.dart`

After successful signal protocol initialization:

1. **Load saved route** from PreferencesService
2. **Restore saved route** if it exists and starts with `/app/`
3. **Clear saved route** after using (one-time restore)
4. **Fallback to `/app`** if no saved route exists

```dart
// Try to restore last route, otherwise go to /app
final lastRoute = await PreferencesService().loadLastRoute();
if (lastRoute != null && lastRoute.startsWith('/app/')) {
  await PreferencesService().clearLastRoute();
  GoRouter.of(context).go(lastRoute);
} else {
  GoRouter.of(context).go('/app');
}
```

## Behavior

### Saved Routes
Routes that will be persisted and restored:
- `/app/people`
- `/app/messages`
- `/app/channels`
- `/app/activities`
- Any other `/app/*` specific route

### Not Saved Routes
Routes that will NOT be persisted (default behavior):
- `/app` (base route)
- `/` (root)
- Routes are automatically cleared after successful restoration

## Storage

### Web Platform
- Stored in IndexedDB database: `peerwave_preferences`
- Object store: `settings`
- Key: `last_app_route`

### Native Platforms
- Stored in SharedPreferences
- Key: `last_app_route`

## Testing Scenarios

### Scenario 1: User at specific route reloads
1. Navigate to `http://localhost:3000/#/app/people`
2. Reload page (F5)
3. Signal keys need setup → redirect to `/signal-setup`
4. After setup completes → **Returns to `/app/people`** ✅

### Scenario 2: User at base route reloads
1. Navigate to `http://localhost:3000/#/app`
2. Reload page (F5)
3. Signal keys need setup → redirect to `/signal-setup`
4. After setup completes → Goes to `/app` → redirects to `/app/activities` (default)

### Scenario 3: Fresh login
1. User logs in
2. No saved route exists
3. After signal setup → Goes to `/app` → redirects to `/app/activities` (default)

## Debug Logging

Added debug prints for tracking:
- `[MAIN] Saving current route before signal-setup: /app/people`
- `[PreferencesService] Saved last route: /app/people`
- `[PreferencesService] Loaded last route: /app/people`
- `[SIGNAL SETUP] Restoring last route: /app/people`
- `[PreferencesService] Cleared last route`

## Edge Cases Handled

1. **Route validation**: Only restores routes that start with `/app/`
2. **One-time restoration**: Route is cleared immediately after being used
3. **Fallback behavior**: If no route saved or invalid, defaults to `/app`
4. **Cross-session persistence**: Route survives page reloads but not logouts
5. **Base routes excluded**: `/app` and `/` don't save/restore (use default redirect)

## Future Enhancements

Potential improvements:
- Clear saved route on logout for security
- Add route parameter persistence (e.g., `/app/messages?contact=uuid`)
- Add timestamp to expire old saved routes
- Add route history stack for browser-like back navigation
