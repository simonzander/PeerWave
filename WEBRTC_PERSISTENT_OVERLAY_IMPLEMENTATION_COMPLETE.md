# WebRTC Persistent Overlay - Implementation Complete ✅

## Overview
Successfully implemented a persistent WebRTC video overlay that allows users to navigate anywhere in the app while in a video call. The overlay includes a draggable video window and a global status bar.

## Implementation Summary

### Phase 1: Service Extension ✅
**File**: `client/lib/services/video_conference_service.dart`

**New Properties**:
- `_isInCall`: Tracks if user is currently in a call
- `_channelName`: Stores the name of the active channel
- `_callStartTime`: Records when the call started (for duration display)
- `_isOverlayVisible`: Controls overlay visibility
- `_overlayPositionX`: X coordinate for overlay position
- `_overlayPositionY`: Y coordinate for overlay position

**New Getters**:
- `isInCall`, `channelName`, `callStartTime`, `isOverlayVisible`, `overlayPositionX`, `overlayPositionY`

**New Methods**:
- `toggleOverlayVisible()`: Toggle overlay visibility
- `hideOverlay()`: Hide the overlay
- `showOverlay()`: Show the overlay
- `updateOverlayPosition(double x, double y)`: Update overlay position
- `_savePersistence()`: Save call state to LocalStorage
- `_clearPersistence()`: Clear persisted call state
- `checkForRejoin()`: Check for and rejoin active calls on app restart

**Updated Methods**:
- `joinRoom()`: Now accepts `channelName` parameter, sets call state, saves persistence
- `leaveRoom()`: Clears call state and persistence

### Phase 2: UI Components ✅

#### CallDurationTimer Widget
**File**: `client/lib/widgets/call_duration_timer.dart`
- Displays live call duration (MM:SS or HH:MM:SS format)
- Updates every second using `Timer.periodic`
- Auto-disposes timer on widget disposal

#### CallTopBar Widget
**File**: `client/lib/widgets/call_top_bar.dart`
- Global status bar at the top of the screen
- Green background (Colors.green.shade700) for visibility
- Shows:
  - Red live indicator dot
  - Channel name
  - Call duration (live timer)
  - Participant count
  - Toggle overlay button
  - Leave call button
- Only visible when `isInCall == true`

#### CallOverlay Widget
**File**: `client/lib/widgets/call_overlay.dart`
- Draggable video overlay (320x180px, 16:9 aspect ratio)
- Features:
  - Drag anywhere on screen (web-compatible GestureDetector)
  - Minimize/maximize button (240x135px when minimized)
  - Close button (hides overlay)
  - Video grid layout (max 4 participants visible)
  - Shadow and rounded corners for visibility
  - Bounds checking (stays on screen)
- Only visible when `isInCall == true` and `isOverlayVisible == true`

### Phase 3: App Integration ✅
**File**: `client/lib/main.dart`

**Changes**:
1. Added imports for VideoConferenceService, CallTopBar, CallOverlay
2. Removed `checkForRejoin()` from main() startup (moved to PostLoginInitService)
3. Updated `MaterialApp.router`:
   - Added `builder` property with Stack layout
   - Stack children:
     - Original app router (child)
     - Positioned CallTopBar (top: 0, left: 0, right: 0)
     - CallOverlay (draggable, positioned by service)

**File**: `client/lib/services/post_login_init_service.dart`

**Changes**:
1. Added import for VideoConferenceService
2. Updated total steps from 14 to 15
3. Added final step: Call `checkForRejoin()` after all services initialized
   - Ensures database, signal, and socket services are ready before rejoining
   - Non-blocking: doesn't fail initialization if rejoin fails

### Phase 4: Navigation Integration ✅
**File**: `client/lib/views/video_conference_view.dart`

**Changes**:
1. Updated `joinRoom()` call to pass `channelName` parameter
2. **Removed auto-navigation** - user stays in full-view after joining
3. Added `didChangeDependencies()` logic:
   - Hides overlay when entering/returning to full-view
   - Only joins call if not already in a call (prevents double-join on return)
4. Added `dispose()` logic:
   - Shows overlay when user navigates away from full-view
   - Preserves call state when navigating

**File**: `client/lib/widgets/call_top_bar.dart`

**Changes**:
1. Added "Full view" button (⛶ icon) when overlay is visible
   - Navigates back to VideoConferenceView
   - Positioned before toggle video button
2. Button only visible when `isOverlayVisible == true`

**File**: `client/lib/services/video_conference_service.dart`

**Changes**:
1. Updated `joinRoom()` to set `_isOverlayVisible = false` initially
   - User starts in full-view mode
   - Overlay only shows when navigating away

## User Flow

### Joining a Call
1. User clicks on a WebRTC channel in channels list
2. Navigates to `/app/channels/{uuid}` → VideoConferencePreJoinView
3. User selects camera/microphone, clicks "Join Call"
4. VideoConferenceView calls `service.joinRoom(channelId, channelName: name)`
5. Service sets `isInCall = true`, `isOverlayVisible = false` (starts hidden), saves persistence
6. **User stays in full-view VideoConferenceView** (no auto-navigation)
7. User sees full-screen video conference with all participants

### During a Call
- **In Full-View**: VideoConferenceView shows full-screen conference
- **Navigate away**: Click any navigation (messages, dashboard, etc.)
  - VideoConferenceView detects navigation (dispose) and shows overlay
  - Green status bar appears at top (channel name, duration, participants)
  - Draggable video overlay appears (with own video + remote participants)
- **Return to full-view**: Click "Full view" button (⛶) in status bar
  - Navigates back to VideoConferenceView
  - VideoConferenceView detects entry and hides overlay
  - Full-screen video conference restored
- **Toggle overlay**: Click eye icon in status bar to hide/show video overlay
- **Drag overlay**: Click and drag overlay to reposition
- **Minimize overlay**: Click minimize icon to reduce size
- **Leave call**: Click leave button in status bar or full-view

### After App Reload
1. App starts, post-login initialization completes
2. PostLoginInitService calls `checkForRejoin()` as final step
3. Service checks LocalStorage for `shouldRejoin` flag
4. If found, automatically rejoins the call with overlay visible
5. User can navigate to full-view using status bar button

## Persistence Schema
**LocalStorage Keys** (SharedPreferences):
- `shouldRejoin`: Boolean flag
- `lastChannelId`: UUID of active channel
- `lastChannelName`: Name of active channel
- `callStartTime`: ISO 8601 timestamp
- `overlayVisible`: Boolean flag
- `overlayPositionX`: Double value
- `overlayPositionY`: Double value

## Technical Details

### State Management
- **Provider Pattern**: VideoConferenceService extends ChangeNotifier
- **Consumer Widgets**: CallTopBar and CallOverlay use Consumer<VideoConferenceService>
- **Reactive Updates**: All UI updates automatically when service notifies listeners

### Layout Architecture
```
MaterialApp.router
└── builder: (context, child) => Stack
    ├── child (GoRouter navigation tree)
    ├── Positioned(top: 0) → CallTopBar
    └── CallOverlay (draggable position)
```

### Cross-Platform Compatibility
- **Web**: Uses `GestureDetector` for drag (Draggable widget not supported)
- **Native**: Also uses `GestureDetector` for consistency
- **Bounds Checking**: `clamp()` ensures overlay stays on screen

### Video Grid Layout
- **Max 4 participants visible** in overlay
- **Responsive Grid**:
  - 1 participant: 1x1 grid
  - 2 participants: 1x2 grid
  - 3-4 participants: 2x2 grid
- **Centered when minimized**: Single tile when overlay is small

## Files Modified
1. `client/lib/services/video_conference_service.dart` - Service extension
2. `client/lib/main.dart` - App integration, Stack layout
3. `client/lib/views/video_conference_view.dart` - Auto-navigation after join

## Files Created
1. `client/lib/widgets/call_duration_timer.dart` - Live timer widget
2. `client/lib/widgets/call_top_bar.dart` - Global status bar
3. `client/lib/widgets/call_overlay.dart` - Draggable video overlay
4. `WEBRTC_PERSISTENT_OVERLAY_ACTION_PLAN.md` - Implementation plan
5. `WEBRTC_PERSISTENT_OVERLAY_IMPLEMENTATION_COMPLETE.md` - This document

## Testing Checklist

### Basic Functionality
- [ ] Click WebRTC channel → prejoin view opens
- [ ] Select devices → join call
- [ ] **User stays in full VideoConferenceView** (no auto-navigation)
- [ ] Full-screen video shows all participants
- [ ] Status bar hidden in full-view
- [ ] Overlay hidden in full-view

### Full-View ↔ Overlay Navigation
- [ ] Navigate away from full-view → overlay appears
- [ ] Navigate away → status bar appears at top
- [ ] Click "Full view" button in status bar → returns to full-view
- [ ] Return to full-view → overlay hides
- [ ] Return to full-view → status bar remains visible
- [ ] Navigate away again → overlay reappears

### Overlay Interactions
- [ ] Drag overlay to different positions
- [ ] Overlay stays on screen (bounds checking)
- [ ] Minimize overlay → size reduces
- [ ] Maximize overlay → size restores
- [ ] Toggle visibility → overlay hides/shows
- [ ] Close overlay → overlay hidden (still in call)

### Navigation While in Call
- [ ] Navigate to messages → overlay follows
- [ ] Navigate to dashboard → overlay follows
- [ ] Navigate to settings → overlay follows
- [ ] Navigate to file transfer → overlay follows
- [ ] Overlay visible on all pages (except full-view)

### Status Bar
- [ ] Shows channel name correctly
- [ ] Shows live call duration (updates every second)
- [ ] Shows participant count (updates when users join/leave)
- [ ] "Full view" button visible when overlay shown
- [ ] Toggle button hides/shows overlay
- [ ] Leave button ends call and hides UI

### Persistence & Rejoin
- [ ] Reload browser while in call → auto-rejoin after login
- [ ] After rejoin, overlay is visible
- [ ] After rejoin, can navigate to full-view
- [ ] Overlay position persists across reload
- [ ] Call duration continues from original start time
- [ ] Leave call → persistence cleared
- [ ] Restart app (not in call) → no auto-rejoin

### Video Display
- [ ] Local video shows in full-view
- [ ] Remote participant videos show in full-view
- [ ] Local video shows in overlay
- [ ] Remote participant videos show in overlay
- [ ] Grid layout adjusts for 1-4 participants
- [ ] Video remains smooth during drag
- [ ] E2EE status visible

## Known Limitations
1. **Max 4 participants visible** in overlay (design constraint for small space)
2. **Desktop/Web only** (mobile apps use different layout patterns)
3. **Single active call** (no multiple simultaneous calls)
4. **Auto-rejoin on reload** requires SharedPreferences (web browser storage)

## Future Enhancements
- Picture-in-Picture (PiP) mode for native platforms
- Expandable overlay to show all participants
- Screen sharing in overlay mode
- Audio-only mode (no video tiles)
- Overlay snap-to-edges functionality
- Multiple call support with call switching

## Completion Status
✅ Phase 1: Service Extension - COMPLETE  
✅ Phase 2: UI Components - COMPLETE  
✅ Phase 3: App Integration - COMPLETE  
✅ Phase 4: Navigation Integration - COMPLETE  

**All phases implemented successfully!**

## Notes
- Implementation follows Flutter best practices
- Uses Provider for state management
- Web-compatible drag handling
- Responsive layout with bounds checking
- Persistent state across app reloads
- Clean separation of concerns (service, UI, navigation)

---
*Implementation completed: 2024*
*Architecture: Flutter/Dart with Provider pattern*
*Platform: Web (primary), Desktop (secondary)*
