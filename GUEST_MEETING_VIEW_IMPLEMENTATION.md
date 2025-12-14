# Guest Meeting View Implementation

## Overview
Created a separate, simplified video conference view specifically for external guest participants. This avoids initialization errors and provides an appropriate minimal UI for guests who don't need full meeting management features.

## Files Created

### 1. `client/lib/views/guest_meeting_video_view.dart`
**Purpose**: Simplified video conference view for external guests

**Key Features**:
- **No SignalService dependency**: Guests don't initialize Signal Protocol on the client side
- **No sidebar**: Clean, focused video-only interface
- **No admission overlay**: Guests are already admitted before reaching this view
- **No invite button**: Guests cannot invite others
- **No meeting management**: Guests can only participate, not control the meeting

**Technical Implementation**:
- Loads LiveKit E2EE key from `sessionStorage` (set during prejoin)
- Uses existing `VideoConferenceService` for LiveKit room management
- Reuses `VideoGridLayout` widget for participant display
- Reuses `VideoControlsBar` widget for audio/video/screenshare controls
- Minimal top bar with meeting title and participant count
- Graceful leave handling with window close prompt (web)

**Flow**:
1. Guest completes prejoin (Signal Protocol key exchange, E2EE key receipt)
2. E2EE key stored in sessionStorage: `livekit_e2ee_key`
3. `GuestMeetingVideoView` mounts
4. Loads E2EE key from sessionStorage
5. Joins LiveKit room with E2EE enabled
6. Displays video grid and controls
7. On leave: clears sessionStorage and shows close prompt

## Files Modified

### 1. `client/lib/main.dart`

**Import Added** (line 98):
```dart
import 'views/guest_meeting_video_view.dart';
```

**Routing Logic Updated** (lines 1058-1087):
```dart
GoRoute(
  path: '/meeting/video/:meetingId',
  builder: (context, state) {
    final meetingId = state.pathParameters['meetingId']!;
    final extra = state.extra as Map<String, dynamic>?;
    final isExternal = extra?['isExternal'] == true;

    // Use guest view for external participants
    if (isExternal) {
      return GuestMeetingVideoView(
        meetingId: meetingId,
        meetingTitle: extra?['meetingTitle'] ?? 'Meeting',
        selectedCamera: extra?['selectedCamera'],
        selectedMicrophone: extra?['selectedMicrophone'],
      );
    }

    // Use standard view for authenticated users
    return MeetingVideoConferenceView(
      meetingId: meetingId,
      meetingTitle: extra?['meetingTitle'] ?? 'Meeting',
      selectedCamera: extra?['selectedCamera'],
      selectedMicrophone: extra?['selectedMicrophone'],
    );
  },
),
```

**How `isExternal` is Set**:
When a guest is admitted in `external_prejoin_view.dart`, the `onAdmitted` callback navigates with:
```dart
context.go('/meeting/video/$meetingId', extra: {
  'meetingTitle': displayName,
  'isExternal': true,  // ← This flag triggers guest view
});
```

## Architecture Benefits

### 1. **Separation of Concerns**
- **Authenticated users**: Full-featured `MeetingVideoConferenceView`
  - Sidebar with participants list
  - Meeting management (start/end, invite, admit guests)
  - Full Signal Protocol initialization
  - Profile pictures and user info
  
- **External guests**: Minimal `GuestMeetingVideoView`
  - Video-only interface
  - Essential controls (audio, video, screenshare, leave)
  - No authentication dependencies
  - Simple display name from sessionStorage

### 2. **Reduced Complexity**
Guest view eliminates:
- SignalService initialization checks
- User profile loading
- Channel/group message stores
- Admission overlay logic
- Meeting management features
- Server settings synchronization

### 3. **Better Error Handling**
- Clear error states for guests
- No "Signal Service must be initialized" errors
- Explicit sessionStorage loading with fallback
- Graceful degradation if E2EE key missing

### 4. **Reusability**
Shared widgets between both views:
- `VideoGridLayout` - Participant video grid
- `VideoControlsBar` - Audio/video/screenshare buttons
- `ParticipantAudioState` - Audio level tracking
- `VideoConferenceService` - LiveKit room management

## Guest Flow Summary

```
1. Guest clicks invitation link
   ↓
2. ExternalPreJoinView loads
   ├─ Validates token
   ├─ Generates Signal Protocol keys (sessionStorage)
   ├─ Requests keybundle from participant
   ├─ Receives encrypted LiveKit E2EE key
   ├─ Stores E2EE key in sessionStorage
   └─ Requests admission
   ↓
3. Participant admits guest
   ↓
4. onAdmitted() called
   ├─ Reads meetingId from sessionStorage
   └─ Navigates to /meeting/video/:meetingId with isExternal=true
   ↓
5. GuestMeetingVideoView mounts
   ├─ Loads E2EE key from sessionStorage
   ├─ Joins LiveKit room
   ├─ Enables frame encryption (E2EE)
   └─ Displays video grid
   ↓
6. Guest participates in meeting
   ├─ Audio/video/screenshare controls available
   ├─ Sees other participants
   └─ Can leave at any time
   ↓
7. Guest leaves
   ├─ Clears sessionStorage (E2EE key)
   └─ Shows "close tab" prompt
```

## Testing Checklist

- [ ] Guest can join meeting via invitation link
- [ ] Guest sees simplified UI (no sidebar, no invite button)
- [ ] Guest can toggle audio/video/screenshare
- [ ] Guest sees other participants in grid
- [ ] Guest receives E2EE encrypted video/audio
- [ ] Guest can leave meeting
- [ ] sessionStorage cleared on leave
- [ ] No "Signal Service must be initialized" errors
- [ ] Top bar shows meeting title and participant count
- [ ] Leave button shows "close tab" dialog

## SessionStorage Keys Used

| Key | Purpose | Set By | Used By |
|-----|---------|--------|---------|
| `livekit_e2ee_key` | LiveKit E2EE encryption key | `external_prejoin_view.dart` | `guest_meeting_video_view.dart` |
| `external_meeting_id` | Meeting ID for navigation | `external_prejoin_view.dart` | `main.dart` (onAdmitted callback) |
| `external_display_name` | Guest's display name | `external_prejoin_view.dart` | `main.dart` (onAdmitted callback) |
| `guest_session_id` | Guest session identifier | `external_prejoin_view.dart` | Socket.IO event payload |
| `guest_identity_key` | Guest's Signal Protocol identity | `external_prejoin_view.dart` | Encryption session |
| `guest_signed_pre_key` | Guest's signed pre-key (serialized) | `external_prejoin_view.dart` | Decryption |
| `guest_pre_keys_*` | Guest's one-time pre-keys (serialized) | `external_prejoin_view.dart` | Decryption |

## Notes

- **Web Only**: Guest flow currently designed for web browsers (sessionStorage, window.close())
- **Future**: Could extend to mobile with secure temporary storage
- **Security**: sessionStorage cleared on leave, ephemeral guest sessions
- **E2EE**: Full end-to-end encryption maintained for guest participants
- **Scalability**: Guest view has minimal memory footprint (no message stores, no profiles)
