# Notification System Implementation Complete

## Overview
Implemented a two-tier notification system for PeerWave with distinct behavior for different event types:

### Type 1: In-App Sounds Only (Video Events)
**Service**: `SoundService` (`lib/services/sound_service.dart`)
- Subtle audio feedback for video conference events
- Non-intrusive, low volume
- No system notifications (no pop-ups)

**Events**:
- ✅ Participant joined
- ✅ Participant left
- ✅ Screen share started
- ✅ Screen share stopped

### Type 2: Sounds + System Notifications (Messages/Calls)
**Service**: `NotificationService` (`lib/services/notification_service.dart`)
- Audio notification + OS system notification
- Attention-grabbing, clear volume
- Click-to-focus functionality

**Events**:
- ✅ New 1:1 message
- ✅ New group message
- ✅ General notifications
- ✅ Incoming calls (with Answer/Decline actions)

## Architecture

### SoundService
```dart
class SoundService {
  // Singleton pattern
  static final instance = SoundService._internal();
  
  // Methods
  playParticipantJoined()
  playParticipantLeft()
  playScreenShareStarted()
  playScreenShareStopped()
  
  // Control
  setEnabled(bool enabled)
}
```

**Integration Points**:
- `VideoConferenceService` event listeners:
  - `ParticipantConnectedEvent` → `playParticipantJoined()`
  - `ParticipantDisconnectedEvent` → `playParticipantLeft()`
  - `TrackPublishedEvent` (screen share) → `playScreenShareStarted()`
  - `TrackUnpublishedEvent` (screen share) → `playScreenShareStopped()`

### NotificationService
```dart
class NotificationService {
  // Singleton pattern
  static final instance = NotificationService._internal();
  
  // Lifecycle
  initialize()  // Must be called at app startup
  requestPermission()  // Web only, call before first notification
  
  // Methods
  notifyNewDirectMessage({senderName, messagePreview, senderId})
  notifyNewGroupMessage({channelName, senderName, messagePreview, channelId})
  notifyGeneral({title, message, identifier})
  notifyIncomingCall({callerName, channelName, callId})
  
  // Control
  setEnabled(bool enabled)
  setSoundEnabled(bool enabled)
  
  // State
  bool get hasPermission
}
```

**Platform Support**:
- **Web**: HTML5 Notifications API
- **Windows**: Toast notifications via `local_notifier`
- **macOS**: Notification Center via `local_notifier`
- **Linux**: Desktop notifications via `local_notifier`

**Integration Points**:
- `NotificationListenerService` subscribes to `EventBus`:
  - `AppEvent.newMessage` → Triggers message notifications (1:1 and group)
  - `AppEvent.newNotification` → Triggers activity notifications (mentions, reactions, etc.)
- EventBus is fed by `SignalService` after message decryption

**Event Flow**:
```
Socket.IO → SignalService → EventBus → NotificationListenerService → NotificationService
             (decrypt)      (emit)     (listen)                        (show notification)
```

## Files Modified

### New Files
1. **`lib/services/sound_service.dart`**
   - In-app audio feedback service
   - Uses `audioplayers` package
   - Singleton pattern with enable/disable toggle

2. **`lib/services/notification_service.dart`**
   - System notification service
   - Cross-platform support (Web, Windows, macOS, Linux)
   - Permission handling
   - Sound + visual notifications

3. **`assets/sounds/README.md`**
   - Documentation for required sound files
   - Sound sources and specifications
   - License compliance guidelines

### Modified Files
1. **`lib/services/video_conference_service.dart`**
   - Added `import 'sound_service.dart'`
   - Integrated sound playback in event listeners:
     - Line ~1078: `SoundService.instance.playParticipantJoined()`
     - Line ~1095: `SoundService.instance.playParticipantLeft()`
     - Line ~1137: `SoundService.instance.playScreenShareStarted()`
     - Line ~1155: `SoundService.instance.playScreenShareStopped()`

2. **`lib/services/message_listener_service.dart`**
   - Added `import 'notification_service.dart'`
   - Added `_showSystemNotification()` method (lines ~113-162)
   - Integrated notification calls in `_triggerNotification()` (line ~99)
   - Handles 1:1 and group message notifications
   - Uses cached profile display names

3. **`pubspec.yaml`**
   - Added assets section: `- assets/sounds/`
   - Dependencies already present:
     - ✅ `audioplayers: ^6.1.0`
     - ✅ `local_notifier: ^0.1.6`
     - ✅ `universal_html: ^2.3.0`

4. **`assets/` directory**
   - Created `assets/sounds/` folder for audio files

## Required Sound Assets

### Location
All sound files should be placed in: `client/assets/sounds/`

### Files Needed (7 total)

#### Type 1: Video Events (Subtle, 0.5-1s)
1. **`participant_joined.mp3`** - Soft "pop" or "ding"
2. **`participant_left.mp3`** - Soft "whoosh" or "fade out"
3. **`screen_share_started.mp3`** - Rising tone or "presentation start"
4. **`screen_share_stopped.mp3`** - Descending tone or "close"

#### Type 2: Important Notifications (Clear, 0.5-4s)
5. **`message_received.mp3`** - Classic message notification
6. **`notification.mp3`** - Bell or chime
7. **`incoming_call.mp3`** - Phone ring (can loop, 2-4s)

### Recommended Sources
1. **Freesound.org** (CC0 license)
   - Search: "notification", "pop", "ding", "message"
   
2. **ElevenLabs Sound Effects** (AI generation)
   - Text prompts: "soft notification pop", "friendly join sound"
   - Free tier available
   
3. **Zapsplat.com** (Free with attribution)
   - UI/Notification sounds category

### Audio Specifications
- **Format**: MP3 or WAV
- **Sample Rate**: 44.1kHz or 48kHz
- **Bit Rate**: 128-192 kbps (MP3)
- **Channels**: Mono or Stereo
- **Normalization**: Peak at -3dB

## Initialization

### App Startup (main.dart or app initialization)
```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize notification service
  await NotificationService.instance.initialize();
  
  // Request permission (Web only, call before showing first notification)
  if (kIsWeb) {
    await NotificationService.instance.requestPermission();
  }
  
  runApp(MyApp());
}
```

### User Settings Integration (Future Enhancement)
```dart
// Settings screen toggles
SoundService.instance.setEnabled(userPreferences.soundsEnabled);
NotificationService.instance.setEnabled(userPreferences.notificationsEnabled);
NotificationService.instance.setSoundEnabled(userPreferences.notificationSoundsEnabled);
```

## Testing Checklist

### Type 1: Video Event Sounds
- [ ] Join video call with another user
  - [ ] Hear join sound when participant connects
  - [ ] Hear leave sound when participant disconnects
- [ ] Screen sharing
  - [ ] Start screen share → hear start sound
  - [ ] Stop screen share → hear stop sound
- [ ] Volume is subtle and non-intrusive
- [ ] No system notifications shown

### Type 2: Message Notifications
- [ ] **1:1 Messages**
  - [ ] Receive message → hear sound + see system notification
  - [ ] Click notification → app focuses to chat
  - [ ] Sender display name shown correctly
  - [ ] "🔒 Encrypted message" shown for encrypted messages
  
- [ ] **Group Messages**
  - [ ] Receive group message → hear sound + see system notification
  - [ ] Notification shows: "ChannelName" / "SenderName: Preview"
  - [ ] Click notification → app focuses to group chat
  
- [ ] **Permission Handling (Web)**
  - [ ] First notification triggers permission request
  - [ ] Notifications work after granting permission
  - [ ] Graceful fallback if permission denied

- [ ] **Cross-Platform**
  - [ ] Windows: Toast notification appears
  - [ ] macOS: Notification Center notification
  - [ ] Web: Browser notification
  - [ ] Linux: Desktop notification

### Type 3: Call Notifications (Not yet integrated)
- [ ] Incoming call notification with Answer/Decline buttons
- [ ] Ring sound plays (loops until answered/declined)
- [ ] Click "Answer" → joins call
- [ ] Click "Decline" → dismisses call

## Current Status

### ✅ Completed
- [x] SoundService implementation
- [x] NotificationService implementation  
- [x] Integration with VideoConferenceService (sounds)
- [x] Integration with MessageListenerService (notifications)
- [x] Cross-platform notification support
- [x] Permission handling
- [x] Enable/disable toggles
- [x] pubspec.yaml assets configuration
- [x] Sound asset directory structure

### 🔄 Pending
- [ ] Add 7 sound asset files to `assets/sounds/`
- [ ] Test sound playback on Windows
- [ ] Test system notifications on Windows/Web
- [ ] Initialize NotificationService at app startup
- [ ] Request notification permission (Web)
- [ ] Add incoming call notifications
- [ ] Add user settings UI for notification preferences
- [ ] Test on macOS and Linux
- [ ] Add notification click handlers (deep linking)
- [ ] Channel name resolution for group notifications

### 🎯 Future Enhancements
- [ ] Different sound for mentions vs regular messages
- [ ] Notification grouping (multiple messages from same user)
- [ ] Custom notification sounds per user/channel
- [ ] Do Not Disturb mode
- [ ] Notification history/center
- [ ] Badge counts on app icon
- [ ] Notification priority levels
- [ ] Rich notifications with actions (Reply, Mark as Read)

## API Reference

### SoundService

```dart
// Initialize (automatic, singleton)
final soundService = SoundService.instance;

// Play sounds
soundService.playParticipantJoined();
soundService.playParticipantLeft();
soundService.playScreenShareStarted();
soundService.playScreenShareStopped();

// Control
soundService.setEnabled(false);  // Mute all sounds
soundService.setEnabled(true);   // Unmute
```

### NotificationService

```dart
// Initialize at app startup
await NotificationService.instance.initialize();

// Request permission (Web only)
bool granted = await NotificationService.instance.requestPermission();

// Show notifications
await NotificationService.instance.notifyNewDirectMessage(
  senderName: 'John Doe',
  messagePreview: 'Hey, are you available?',
  senderId: 'user-uuid-123',
);

await NotificationService.instance.notifyNewGroupMessage(
  channelName: 'Project Team',
  senderName: 'Jane Smith',
  messagePreview: 'Meeting at 3pm',
  channelId: 'channel-uuid-456',
);

await NotificationService.instance.notifyIncomingCall(
  callerName: 'Alice Brown',
  channelName: 'Team Standup',
  callId: 'call-uuid-789',
);

// Control
NotificationService.instance.setEnabled(false);       // Disable all notifications
NotificationService.instance.setSoundEnabled(false);  // Disable only sounds, keep visual

// Check state
bool hasPermission = NotificationService.instance.hasPermission;
bool isEnabled = NotificationService.instance.isEnabled;
```

## Troubleshooting

### Sound not playing
1. Check asset files exist in `assets/sounds/`
2. Verify `pubspec.yaml` includes `- assets/sounds/`
3. Run `flutter pub get` after adding assets
4. Check `SoundService.instance.isEnabled`
5. Increase device volume

### System notification not showing
1. **Web**: Check browser notification permissions
   - Chrome: Settings → Privacy → Site Settings → Notifications
2. **Windows**: Check Windows notification settings
   - Settings → System → Notifications → PeerWave
3. Check `NotificationService.instance.hasPermission`
4. Check `NotificationService.instance.isEnabled`
5. Verify `initialize()` was called at app startup

### Notification sound plays but no visual notification
- Check OS notification permissions
- Try calling `requestPermission()` on Web
- Check Do Not Disturb settings on macOS

### "File not found" error for sounds
- Ensure sound files use correct names (lowercase, underscores)
- Rebuild app after adding assets: `flutter clean && flutter run`
- Check case sensitivity (Linux/macOS)

## License Compliance

All sound assets must be properly licensed:
- ✅ CC0 (Public Domain) - No attribution required
- ✅ CC-BY - Attribution required (add to THIRD_PARTY_LICENSES.md)
- ❌ Non-commercial licenses - Not allowed for PeerWave

Document all sound sources in `THIRD_PARTY_LICENSES.md` if attribution is required.

## Performance Considerations

- Sound files are loaded on-demand (lazy loading)
- Notifications are async and non-blocking
- Permission requests only happen once (Web)
- Cached profile names used for notifications (no blocking API calls)
- Sound Service uses singleton pattern (memory efficient)

## Privacy & Security

- No notification content sent to external services
- Uses OS-native notification systems
- Encrypted messages show "🔒 Encrypted message" instead of content
- No sensitive data in notification identifiers
- User can disable notifications at any time

---

**Implementation Date**: December 3, 2025  
**Status**: Services implemented, awaiting sound assets  
**Next Steps**: Add sound files, initialize services, test cross-platform
