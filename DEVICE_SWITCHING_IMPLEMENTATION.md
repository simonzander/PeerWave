# Device Switching Implementation

## Overview
Implemented runtime device switching for camera and microphone during active video calls. Users can now long-press or right-click on camera/microphone buttons to select different input devices without leaving the call.

## Features

### User Interaction
- **Long Press (Touch)**: Hold camera or microphone button to open device selector
- **Right Click (Desktop)**: Right-click camera or microphone button to open device selector  
- **Modal Bottom Sheet**: Clean device selection UI with device labels
- **Success/Error Feedback**: Toast notifications for switch results

### Device Switching Logic
1. **Enumerate Devices**: Get all available audio/video input devices
2. **Stop Current Track**: Gracefully stop and dispose existing track
3. **Create New Track**: Initialize new track with selected deviceId
4. **Publish Track**: Publish new track to room
5. **Restore State**: Maintain previous enabled/disabled state

## Implementation Details

### Files Modified

#### `client/lib/services/video_conference_service.dart`
Added two new methods for device switching:

```dart
/// Switch to a different camera device
Future<void> switchCamera(MediaDevice device)

/// Switch to a different microphone device  
Future<void> switchMicrophone(MediaDevice device)
```

**Key Steps:**
1. Get current enabled state (`isCameraEnabled()` / `isMicrophoneEnabled()`)
2. Stop all existing tracks of that type via `videoTrackPublications` / `audioTrackPublications`
3. Create new track with `LocalVideoTrack.createCameraTrack(CameraCaptureOptions(deviceId: device.deviceId))`
4. Publish new track via `publishVideoTrack()` / `publishAudioTrack()`
5. Restore previous enabled state if was disabled
6. Notify listeners to update UI

#### `client/lib/views/video_conference_view.dart`
Added device selector dialogs and gesture handling:

```dart
/// Show microphone device selector dialog
Future<void> _showMicrophoneDeviceSelector(BuildContext context)

/// Show camera device selector dialog
Future<void> _showCameraDeviceSelector(BuildContext context)
```

**UI Components:**
- Modal bottom sheet with device list
- Device enumeration via `Hardware.instance.enumerateDevices()`
- Filtering by device kind (`audioinput` / `videoinput`)
- ListTile for each device with appropriate icon

**Gesture Detection:**
Modified `_buildControlButton()` to use `GestureDetector`:
- `onTap`: Normal button press (toggle)
- `onLongPress`: Long-press for device selection
- `onSecondaryTap`: Right-click for device selection

## Technical Notes

### LiveKit Track Management
- **No Direct Device Switching API**: LiveKit doesn't have `setMicrophoneDevice()` or `setCameraDevice()` methods
- **Track Replacement Pattern**: Must stop old track → create new track → publish new track
- **Publication Management**: Use `videoTrackPublications` and `audioTrackPublications` to access current tracks
- **State Preservation**: Important to maintain mute/unmute state across device switches

### FloatingActionButton Limitation
- `FloatingActionButton` doesn't support `onLongPress` parameter
- **Solution**: Wrap with `GestureDetector` and set `onPressed: null` on FAB
- Handles `onTap`, `onLongPress`, and `onSecondaryTap` via GestureDetector

### Error Handling
- Try-catch blocks around device enumeration and switching
- User-friendly error messages via `context.showErrorSnackBar()`
- Debug logging for troubleshooting
- Graceful fallback if no devices available

## Testing Checklist

- [ ] Camera switching updates local video feed
- [ ] Microphone switching updates audio source
- [ ] Remote participants see/hear changes immediately
- [ ] Long-press works on touch devices
- [ ] Right-click works on desktop
- [ ] Mute state preserved after switching
- [ ] Error handling for unavailable devices
- [ ] Multiple device switches without issues
- [ ] Device switching during active screenshare
- [ ] E2EE continues working after device switch

## Usage Example

During a video call:
1. **Long-press** (mobile) or **right-click** (desktop) the camera icon
2. Select new camera from the list
3. Video feed automatically switches to new device
4. Success notification appears

Same process for microphone switching.

## Future Enhancements

- [ ] Show current active device with checkmark
- [ ] Device switch animation/transition
- [ ] Keyboard shortcuts for device selection
- [ ] Remember last selected device per user
- [ ] Test device before switching (preview)
- [ ] Handle device disconnection gracefully
- [ ] Support speaker/audio output device switching
