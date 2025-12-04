import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:livekit_client/livekit_client.dart';
import '../services/video_conference_service.dart';
import '../models/participant_audio_state.dart';
import 'speaking_border_wrapper.dart';

/// Draggable video overlay that shows active call
/// Can be minimized, maximized, and closed
class CallOverlay extends StatefulWidget {
  const CallOverlay({Key? key}) : super(key: key);

  @override
  State<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends State<CallOverlay> {
  bool _isMinimized = false;
  double? _dragStartX;
  double? _dragStartY;
  final Map<String, ParticipantAudioState> _participantStates = {};

  @override
  Widget build(BuildContext context) {
    return Consumer<VideoConferenceService>(
      builder: (context, service, _) {
        // Update participant states
        _updateParticipantStates(service);

        // Hide overlay if: not in call, overlay hidden, OR in full-view mode
        if (!service.isInCall ||
            !service.isOverlayVisible ||
            service.isInFullView) {
          return const SizedBox.shrink();
        }

        final screenSize = MediaQuery.of(context).size;
        final overlayWidth = _isMinimized ? 240.0 : 320.0;
        final overlayHeight = _isMinimized ? 135.0 : 180.0;

        // Use drag positions if actively dragging, otherwise use service positions
        final x = (_dragStartX ?? service.overlayPositionX).clamp(
          0.0,
          screenSize.width - overlayWidth,
        );
        final y = (_dragStartY ?? service.overlayPositionY).clamp(
          0.0,
          screenSize.height - overlayHeight,
        );

        return Positioned(
          left: x,
          top: y,
          child: GestureDetector(
            onPanStart: (details) {
              _dragStartX = x;
              _dragStartY = y;
            },
            onPanUpdate: (details) {
              // Update local position for smooth dragging
              setState(() {
                _dragStartX = (_dragStartX! + details.delta.dx).clamp(
                  0.0,
                  screenSize.width - overlayWidth,
                );
                _dragStartY = (_dragStartY! + details.delta.dy).clamp(
                  0.0,
                  screenSize.height - overlayHeight,
                );
              });
            },
            onPanEnd: (details) {
              // Only update service position when drag ends (persistence + performance)
              if (_dragStartX != null && _dragStartY != null) {
                service.updateOverlayPosition(_dragStartX!, _dragStartY!);
              }
            },
            child: _buildOverlayContent(service, overlayWidth, overlayHeight),
          ),
        );
      },
    );
  }

  Widget _buildOverlayContent(
    VideoConferenceService service,
    double width,
    double height,
  ) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 10,
            spreadRadius: 2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            // Video Grid
            _buildVideoGrid(service),

            // Controls overlay
            Positioned(
              top: 4,
              right: 4,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Minimize/Maximize
                  _buildIconButton(
                    icon: _isMinimized
                        ? Icons.open_in_full
                        : Icons.close_fullscreen,
                    onPressed: () {
                      setState(() {
                        _isMinimized = !_isMinimized;
                      });
                    },
                  ),
                  const SizedBox(width: 4),

                  // Close overlay - TopBar remains visible with "Show Overlay" button
                  _buildIconButton(
                    icon: Icons.close,
                    onPressed: () => service.hideOverlay(),
                  ),
                ],
              ),
            ),

            // Draggable hint
            Positioned(
              top: 4,
              left: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.drag_indicator,
                      size: 16,
                      color: Colors.white.withOpacity(0.7),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      service.channelName ?? 'Video Call',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.9),
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Update participant audio states
  void _updateParticipantStates(VideoConferenceService service) {
    if (service.room == null) return;

    final room = service.room!;
    final allParticipantIds = <String>{};

    // Add local participant
    if (room.localParticipant != null) {
      final localId = room.localParticipant!.identity;
      allParticipantIds.add(localId);

      if (!_participantStates.containsKey(localId)) {
        _participantStates[localId] = ParticipantAudioState(
          participantId: localId,
        );
      }

      // Update speaking state
      final isSpeaking = room.localParticipant!.isSpeaking;
      if (_participantStates[localId]!.isSpeaking != isSpeaking) {
        _participantStates[localId]!.updateSpeaking(isSpeaking);
      }
    }

    // Add remote participants
    for (final remote in room.remoteParticipants.values) {
      final remoteId = remote.identity;
      allParticipantIds.add(remoteId);

      if (!_participantStates.containsKey(remoteId)) {
        _participantStates[remoteId] = ParticipantAudioState(
          participantId: remoteId,
        );
      }

      // Update speaking state
      final isSpeaking = remote.isSpeaking;
      if (_participantStates[remoteId]!.isSpeaking != isSpeaking) {
        _participantStates[remoteId]!.updateSpeaking(isSpeaking);
      }
    }

    // Remove states for participants who left
    _participantStates.removeWhere((id, _) => !allParticipantIds.contains(id));
  }

  Widget _buildVideoGrid(VideoConferenceService service) {
    if (service.room == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    final room = service.room!;
    final localParticipant = room.localParticipant;
    final remoteParticipants = service.remoteParticipants;

    // Check for screen share
    final hasScreenShare = service.hasActiveScreenShare;
    final screenShareParticipantId = service.currentScreenShareParticipantId;

    if (hasScreenShare && screenShareParticipantId != null) {
      // Screen share layout: 60% screen share, 40% participants
      return _buildOverlayScreenShareLayout(
        service: service,
        localParticipant: localParticipant,
        remoteParticipants: remoteParticipants,
        screenShareParticipantId: screenShareParticipantId,
      );
    }

    // Build participant list (show active speakers)
    final List<dynamic> participants = [];
    if (localParticipant != null) {
      participants.add({'participant': localParticipant, 'isLocal': true});
    }

    // Sort remote participants by speaking activity
    final sortedRemote = remoteParticipants.toList()
      ..sort((a, b) {
        final aState = _participantStates[a.identity];
        final bState = _participantStates[b.identity];

        // Currently speaking participants first
        if (aState?.isSpeaking == true && bState?.isSpeaking != true) return -1;
        if (bState?.isSpeaking == true && aState?.isSpeaking != true) return 1;

        // Then by most recently active
        if (aState != null && bState != null) {
          return bState.lastSpokeAt.compareTo(aState.lastSpokeAt);
        }

        return 0;
      });

    // Add remote participants (show max 3 more, prioritize speakers)
    final maxRemote = _isMinimized ? 0 : 3;
    for (var i = 0; i < sortedRemote.length && i < maxRemote; i++) {
      participants.add({'participant': sortedRemote[i], 'isLocal': false});
    }

    if (participants.isEmpty) {
      return Center(
        child: Icon(
          Icons.videocam_off,
          color: Colors.white.withOpacity(0.5),
          size: 48,
        ),
      );
    }

    // Single participant: Show full screen
    if (participants.length == 1) {
      final item = participants[0];
      return _buildVideoTile(
        participant: item['participant'],
        isLocal: item['isLocal'] as bool,
        showLabel: true,
      );
    }

    // Multiple participants: Grid layout
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: participants.length > 2 ? 2 : 1,
        childAspectRatio: 16 / 9,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: participants.length,
      itemBuilder: (context, index) {
        final item = participants[index];
        return _buildVideoTile(
          participant: item['participant'],
          isLocal: item['isLocal'] as bool,
          showLabel: false, // Too small for labels in grid
        );
      },
    );
  }

  /// Build overlay layout with screen share priority
  Widget _buildOverlayScreenShareLayout({
    required VideoConferenceService service,
    required LocalParticipant? localParticipant,
    required List<RemoteParticipant> remoteParticipants,
    required String screenShareParticipantId,
  }) {
    // Find screen sharing participant
    dynamic screenShareParticipant;
    if (screenShareParticipantId == localParticipant?.identity) {
      screenShareParticipant = localParticipant;
    } else {
      try {
        screenShareParticipant = remoteParticipants.firstWhere(
          (p) => p.identity == screenShareParticipantId,
        );
      } catch (e) {
        // Fallback to first remote if not found
        screenShareParticipant = remoteParticipants.isNotEmpty
            ? remoteParticipants.first
            : null;
      }
    }

    // Get screen share track
    VideoTrack? screenShareTrack;
    if (screenShareParticipant != null) {
      final screenPubs = screenShareParticipant.videoTrackPublications.where(
        (p) => p.source == TrackSource.screenShareVideo,
      );
      if (screenPubs.isNotEmpty) {
        screenShareTrack = screenPubs.first.track as VideoTrack?;
      }
    }

    // Build participant list (active speakers only)
    final List<dynamic> participants = [];
    if (localParticipant != null &&
        localParticipant.identity != screenShareParticipantId) {
      participants.add({'participant': localParticipant, 'isLocal': true});
    }

    // Sort and add remote participants (exclude screen sharer)
    final sortedRemote =
        remoteParticipants
            .where((p) => p.identity != screenShareParticipantId)
            .toList()
          ..sort((a, b) {
            final aState = _participantStates[a.identity];
            final bState = _participantStates[b.identity];

            if (aState?.isSpeaking == true && bState?.isSpeaking != true)
              return -1;
            if (bState?.isSpeaking == true && aState?.isSpeaking != true)
              return 1;

            if (aState != null && bState != null) {
              return bState.lastSpokeAt.compareTo(aState.lastSpokeAt);
            }

            return 0;
          });

    final maxParticipants = _isMinimized ? 0 : 3;
    for (var i = 0; i < sortedRemote.length && i < maxParticipants; i++) {
      participants.add({'participant': sortedRemote[i], 'isLocal': false});
    }

    return Column(
      children: [
        // Screen share (60%)
        Expanded(
          flex: 6,
          child: Container(
            color: Colors.black,
            child: screenShareTrack != null
                ? VideoTrackRenderer(
                    screenShareTrack,
                    fit: VideoViewFit.contain,
                  )
                : Center(
                    child: Icon(
                      Icons.screen_share,
                      color: Colors.white.withOpacity(0.5),
                      size: 32,
                    ),
                  ),
          ),
        ),

        // Participants (40%)
        if (participants.isNotEmpty && !_isMinimized)
          Expanded(
            flex: 4,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(4),
              itemCount: participants.length,
              itemBuilder: (context, index) {
                final item = participants[index];
                return SizedBox(
                  width: 120,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: _buildVideoTile(
                      participant: item['participant'],
                      isLocal: item['isLocal'] as bool,
                      showLabel: false,
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildVideoTile({
    required dynamic participant,
    required bool isLocal,
    required bool showLabel,
  }) {
    // Get video track
    VideoTrack? videoTrack;
    bool audioMuted = true;

    if (participant is LocalParticipant || participant is RemoteParticipant) {
      final videoPubs = participant.videoTrackPublications;
      if (videoPubs.isNotEmpty) {
        videoTrack = videoPubs.first.track as VideoTrack?;
      }

      final audioPubs = participant.audioTrackPublications;
      audioMuted = audioPubs.isEmpty || audioPubs.first.muted;
    }

    final identity = participant.identity ?? 'Unknown';

    // Get speaking state
    final isSpeaking = _participantStates.containsKey(identity)
        ? _participantStates[identity]!.isSpeaking
        : false;

    final tileContent = Stack(
      fit: StackFit.expand,
      children: [
        // Video or placeholder
        if (videoTrack != null && !videoTrack.muted)
          VideoTrackRenderer(videoTrack)
        else
          Container(
            color: Colors.grey.shade900,
            child: Center(
              child: Icon(
                Icons.videocam_off,
                size: showLabel ? 32 : 16,
                color: Colors.white.withOpacity(0.5),
              ),
            ),
          ),

        // Label (only if showLabel is true)
        if (showLabel)
          Positioned(
            bottom: 4,
            left: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                isLocal ? 'You' : identity,
                style: const TextStyle(color: Colors.white, fontSize: 10),
              ),
            ),
          ),

        // Muted indicator
        if (audioMuted)
          Positioned(
            top: 4,
            right: 4,
            child: Icon(
              Icons.mic_off,
              color: Colors.red,
              size: showLabel ? 16 : 12,
            ),
          ),
      ],
    );

    // Wrap with speaking border
    return SpeakingBorderWrapper(isSpeaking: isSpeaking, child: tileContent);
  }

  Widget _buildIconButton({
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: IconButton(
        padding: EdgeInsets.zero,
        icon: Icon(icon, color: Colors.white, size: 16),
        onPressed: onPressed,
      ),
    );
  }
}
