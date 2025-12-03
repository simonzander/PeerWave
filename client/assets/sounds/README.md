# Sound Assets

This directory contains sound files for PeerWave notifications and events.

## Required Sound Files

### Type 1: Video Conference Events (SoundService)
Used by `SoundService` for in-app audio feedback during video calls:

1. **participant_joined.mp3** - Plays when someone joins the video call
   - Suggested: Short, friendly "pop" or "ding" sound
   - Duration: 0.5-1 second
   - Volume: Subtle, non-intrusive

2. **participant_left.mp3** - Plays when someone leaves the video call
   - Suggested: Soft "whoosh" or "fade out" sound
   - Duration: 0.5-1 second
   - Volume: Subtle, non-intrusive

3. **screen_share_started.mp3** - Plays when screen sharing starts
   - Suggested: Rising tone or "presentation start" sound
   - Duration: 0.5-1 second
   - Volume: Subtle, non-intrusive

4. **screen_share_stopped.mp3** - Plays when screen sharing stops
   - Suggested: Descending tone or "close" sound
   - Duration: 0.5-1 second
   - Volume: Subtle, non-intrusive

### Type 2: Important Notifications (NotificationService)
Used by `NotificationService` for system notifications with sound:

5. **message_received.mp3** - Plays for new 1:1 or group messages
   - Suggested: Classic message "pop" or notification sound
   - Duration: 0.5-1.5 seconds
   - Volume: Clear and attention-grabbing

6. **notification.mp3** - Plays for general app notifications
   - Suggested: Bell or chime sound
   - Duration: 0.5-1.5 seconds
   - Volume: Clear and attention-grabbing

7. **incoming_call.mp3** - Plays for incoming calls
   - Suggested: Phone ring or call tone
   - Duration: 2-4 seconds (can loop)
   - Volume: Clear and urgent

## Sound Sources

### Free Sound Libraries (CC0/Public Domain)
- **Freesound.org** - https://freesound.org
  - Search for "notification", "pop", "ding", etc.
  - Filter by CC0 license for commercial use
  
- **Zapsplat.com** - https://www.zapsplat.com
  - Free sound effects with attribution
  - UI/Notification sounds category

- **Mixkit** - https://mixkit.co/free-sound-effects
  - Free sound effects, no attribution required

### AI Sound Generation
- **ElevenLabs** - https://elevenlabs.io/sound-effects
  - Text-to-sound generation
  - "Soft notification pop", "friendly join sound", etc.

- **AudioGen by Meta** - Open source AI sound generation
  - Can generate custom sounds from text prompts

### Manual Recording/Creation
- **Audacity** (Free, open source)
  - Record and edit your own sounds
  - Generate tones and effects

## Audio Specifications
- **Format**: MP3 or WAV
- **Sample Rate**: 44.1kHz or 48kHz
- **Bit Rate**: 128-192 kbps (MP3)
- **Channels**: Mono or Stereo
- **Normalization**: Peak at -3dB to avoid clipping

## Testing
After adding sound files, test them in the app:
1. Video conference events - join/leave/screen share
2. Message notifications - send test messages
3. Call notifications - initiate test calls
4. Check volume levels across all platforms (Web, Windows, macOS)

## License Compliance
Ensure all sound files are:
- Licensed for commercial use
- Properly attributed if required
- Documented in THIRD_PARTY_LICENSES.md
