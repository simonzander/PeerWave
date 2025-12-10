import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';
import 'preferences_service.dart';

/// Service for playing in-app notification sounds
///
/// Used for non-intrusive audio feedback during video calls:
/// - Participant joined/left
/// - Screen share started/stopped
/// - Incoming call ringtone (looping)
///
/// Does NOT show system notifications - just plays sounds
class SoundService {
  static final SoundService _instance = SoundService._internal();
  static SoundService get instance => _instance;

  SoundService._internal();

  final AudioPlayer _player = AudioPlayer();
  final AudioPlayer _ringtonePlayer = AudioPlayer();
  bool _enabled = true;
  bool _initialized = false;
  bool _isPlayingRingtone = false;

  /// Initialize and load preferences
  Future<void> initialize() async {
    if (_initialized) return;
    _enabled = await PreferencesService().loadVideoSoundsEnabled();
    _initialized = true;
    debugPrint('[SoundService] ✓ Initialized, enabled: $_enabled');
  }

  /// Enable or disable sounds
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    await PreferencesService().saveVideoSoundsEnabled(enabled);
    debugPrint('[SoundService] Sounds ${enabled ? 'enabled' : 'disabled'}');
  }

  bool get isEnabled => _enabled;

  /// Play participant joined sound
  Future<void> playParticipantJoined() async {
    if (!_enabled) return;
    try {
      await _player.play(AssetSource('sounds/participant_joined.mp3'));
      debugPrint('[SoundService] 🔊 Played: participant_joined');
    } catch (e) {
      debugPrint('[SoundService] ❌ Error playing participant_joined: $e');
    }
  }

  /// Play participant left sound
  Future<void> playParticipantLeft() async {
    if (!_enabled) return;
    try {
      await _player.play(AssetSource('sounds/participant_left.mp3'));
      debugPrint('[SoundService] 🔊 Played: participant_left');
    } catch (e) {
      debugPrint('[SoundService] ❌ Error playing participant_left: $e');
    }
  }

  /// Play screen share started sound
  Future<void> playScreenShareStarted() async {
    if (!_enabled) return;
    try {
      await _player.play(AssetSource('sounds/screen_share_started.mp3'));
      debugPrint('[SoundService] 🔊 Played: screen_share_started');
    } catch (e) {
      debugPrint('[SoundService] ❌ Error playing screen_share_started: $e');
    }
  }

  /// Play screen share stopped sound
  Future<void> playScreenShareStopped() async {
    if (!_enabled) return;
    try {
      await _player.play(AssetSource('sounds/screen_share_stopped.mp3'));
      debugPrint('[SoundService] 🔊 Played: screen_share_stopped');
    } catch (e) {
      debugPrint('[SoundService] ❌ Error playing screen_share_stopped: $e');
    }
  }

  /// Play ringtone (loops until stopped)
  Future<void> playRingtone() async {
    if (_isPlayingRingtone) return;

    try {
      // Set looping mode
      await _ringtonePlayer.setReleaseMode(ReleaseMode.loop);
      
      // Play ringtone from assets
      await _ringtonePlayer.play(AssetSource('sounds/ringtone.mp3'));
      
      _isPlayingRingtone = true;
      debugPrint('[SoundService] 🔔 Ringtone started');
    } catch (e) {
      debugPrint('[SoundService] ❌ Error playing ringtone: $e');
    }
  }

  /// Stop ringtone
  Future<void> stopRingtone() async {
    if (!_isPlayingRingtone) return;

    try {
      await _ringtonePlayer.stop();
      _isPlayingRingtone = false;
      debugPrint('[SoundService] 🔇 Ringtone stopped');
    } catch (e) {
      debugPrint('[SoundService] ❌ Error stopping ringtone: $e');
    }
  }

  /// Dispose resources
  void dispose() {
    _player.dispose();
    _ringtonePlayer.dispose();
  }
}
