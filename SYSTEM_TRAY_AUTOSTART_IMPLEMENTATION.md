# System Tray & Autostart Implementation

## Overview
Added system tray functionality and autostart support for PeerWave desktop application (Windows, macOS, Linux).

## Features Implemented

### 1. System Tray Integration
- **Minimize to Tray**: Closing the window hides the app to system tray instead of quitting
- **Tray Icon**: Shows PeerWave icon in system tray
- **Tray Menu**:
  - Show PeerWave - Restores the window
  - Start at Login - Toggle autostart (with checkmark indicator)
  - Quit PeerWave - Completely exits the application

### 2. Autostart Functionality
- **Start at Login**: Option to automatically launch PeerWave when you log in to your computer
- **Toggle**: Can be enabled/disabled from:
  - System tray right-click menu
  - Settings > System Tray page

### 3. Settings Page
- New "System Tray" settings page accessible from Settings sidebar (desktop only)
- Shows:
  - Start at Login toggle switch
  - Explanation of system tray behavior
  - Usage instructions

## User Experience

### Window Closing Behavior
- **Before**: Clicking X button would quit the application
- **After**: Clicking X button minimizes to system tray
- **To Quit**: Right-click tray icon and select "Quit PeerWave"

### System Tray Interactions
- **Left Click**: Show/restore the window
- **Right Click**: Show context menu with options

## Technical Implementation

### New Files Created
1. `lib/services/system_tray_service.dart` - Native implementation
2. `lib/services/system_tray_service_web.dart` - Web stub (no-op)
3. `lib/app/settings/system_tray_settings_page.dart` - Settings UI

### Dependencies Added
- `tray_manager: ^0.2.3` - System tray management
- `launch_at_startup: ^0.3.1` - Autostart functionality
- `window_manager: ^0.4.3` - Advanced window management

### Modified Files
- `pubspec.yaml` - Added new dependencies
- `lib/main.dart` - Initialize system tray service
- `lib/app/settings_sidebar.dart` - Added system tray menu item (desktop only)
- Routes configuration - Added `/app/settings/system-tray` route

### Platform Support
- ✅ Windows
- ✅ macOS
- ✅ Linux
- ❌ Web (features disabled)

## Icon Path
The system tray uses the existing app icon:
- **Windows**: `windows/runner/resources/app_icon.ico`
- **macOS/Linux**: Falls back to PNG format if available

## Testing
1. Run the app on desktop
2. Navigate to Settings > System Tray
3. Enable "Start at Login"
4. Close the window - app should minimize to tray
5. Click tray icon to restore window
6. Right-click tray icon to access menu
7. Log out and back in to verify autostart

## Future Enhancements
- Add notification badges to tray icon
- Add quick actions menu (e.g., start video call, new message)
- Platform-specific customizations
- Tray icon animations for alerts
