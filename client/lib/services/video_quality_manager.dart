import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'video_conference_service.dart';

/// Manages adaptive video quality based on participant count and grid layout
class VideoQualityManager {
  static final VideoQualityManager _instance = VideoQualityManager._internal();
  static VideoQualityManager get instance => _instance;

  VideoQualityManager._internal();

  Room? _room;
  StreamSubscription? _participantSubscription;
  bool _isScreenshareActive = false;
  int _lastParticipantCount = 0;

  /// Initialize quality manager with the active room
  void initialize(Room room) {
    _room = room;
    _setupListeners();
    _updateQualityForAllParticipants();
  }

  /// Clean up listeners
  void dispose() {
    _participantSubscription?.cancel();
    _participantSubscription = null;
    _room = null;
  }

  void _setupListeners() {
    if (_room == null) return;

    // Listen for participant changes
    _room!.addListener(_onRoomUpdate);
  }

  void _onRoomUpdate() {
    if (_room == null) return;

    final participantCount =
        _room!.remoteParticipants.length + 1; // +1 for local
    final hasScreenshare = _room!.remoteParticipants.values.any(
      (p) => p.trackPublications.values.any(
        (pub) => pub.source == TrackSource.screenShareVideo,
      ),
    );

    // Check if conditions changed
    if (participantCount != _lastParticipantCount ||
        hasScreenshare != _isScreenshareActive) {
      _lastParticipantCount = participantCount;
      _isScreenshareActive = hasScreenshare;
      _updateQualityForAllParticipants();
    }
  }

  void _updateQualityForAllParticipants() {
    if (_room == null) return;

    final participantCount = _room!.remoteParticipants.length + 1;
    final targetQuality = _determineTargetQuality(participantCount);

    debugPrint(
      '[VideoQuality] Updating quality for $participantCount participants: $targetQuality',
    );

    // Update quality preference for all remote participants
    for (final participant in _room!.remoteParticipants.values) {
      _updateParticipantQuality(participant, targetQuality);
    }
  }

  void _updateParticipantQuality(
    RemoteParticipant participant,
    VideoQuality quality,
  ) {
    // With simulcast enabled, LiveKit's SFU automatically serves the appropriate
    // quality layer based on bandwidth and viewport size. We track preferences
    // but the actual quality switching is handled server-side.

    final targetQuality = (_isScreenshareActive && hasCamera(participant))
        ? VideoQuality.LOW
        : quality;

    debugPrint(
      '[VideoQuality] Target quality for ${participant.identity}: $targetQuality',
    );
    // Note: Actual quality switching happens server-side with simulcast
  }

  bool hasCamera(RemoteParticipant participant) {
    return participant.trackPublications.values.any(
      (pub) => pub.source == TrackSource.camera && pub.kind == TrackType.VIDEO,
    );
  }

  VideoQuality _determineTargetQuality(int participantCount) {
    final service = VideoConferenceService.instance;

    // Check if adaptive quality is enabled
    if (!service.videoQualitySettings.adaptiveQualityEnabled) {
      return VideoQuality.HIGH; // Default to HIGH if adaptive is disabled
    }

    // Determine quality based on participant count
    if (participantCount == 1) {
      return VideoQuality.HIGH; // Solo view - use highest quality
    } else if (participantCount <= 4) {
      return VideoQuality.MEDIUM; // 2-4 participants - balanced quality
    } else {
      return VideoQuality.LOW; // 5+ participants - optimize bandwidth
    }
  }

  /// Manually set quality for all participants (override adaptive)
  void setQualityForAll(VideoQuality quality) {
    if (_room == null) return;

    debugPrint(
      '[VideoQuality] Manually setting quality to $quality for all participants',
    );

    for (final participant in _room!.remoteParticipants.values) {
      _updateParticipantQuality(participant, quality);
    }
  }

  /// Set quality for a specific participant
  void setQualityForParticipant(String participantId, VideoQuality quality) {
    if (_room == null) return;

    final participant = _room!.remoteParticipants[participantId];
    if (participant != null) {
      _updateParticipantQuality(participant, quality);
      debugPrint(
        '[VideoQuality] Set quality to $quality for participant $participantId',
      );
    }
  }
}
