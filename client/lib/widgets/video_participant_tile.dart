import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import '../widgets/participant_profile_display.dart';

/// Optimized video tile that only rebuilds when its own participant changes
class VideoParticipantTile extends StatefulWidget {
  final dynamic participant;
  final bool isLocal;
  final String? displayName;
  final String? profilePicture;
  final bool isPinned;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;

  const VideoParticipantTile({
    super.key,
    required this.participant,
    required this.isLocal,
    this.displayName,
    this.profilePicture,
    this.isPinned = false,
    this.onLongPress,
    this.onSecondaryTap,
  });

  @override
  State<VideoParticipantTile> createState() => _VideoParticipantTileState();
}

class _VideoParticipantTileState extends State<VideoParticipantTile> {
  lk.VideoTrack? _videoTrack;
  bool _audioMuted = true;
  Widget? _cachedProfileWidget;
  String? _cachedProfilePicture;

  @override
  void initState() {
    super.initState();
    _buildProfileWidget();
    _updateTracks();
    _setupParticipantListener();
  }

  @override
  void didUpdateWidget(VideoParticipantTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.participant != widget.participant) {
      _updateTracks();
    }
    // Only rebuild profile widget if profile picture changed
    if (oldWidget.profilePicture != widget.profilePicture) {
      _buildProfileWidget();
    }
  }

  void _buildProfileWidget() {
    if (widget.profilePicture == _cachedProfilePicture && _cachedProfileWidget != null) {
      return; // Already cached
    }
    
    _cachedProfilePicture = widget.profilePicture;
    final userId = widget.participant?.identity;
    final displayName = widget.displayName ?? userId ?? 'Unknown';
    
    _cachedProfileWidget = RepaintBoundary(
      child: _ProfileDisplaySection(
        profilePicture: widget.profilePicture,
        displayName: displayName,
        userId: userId,
      ),
    );
  }

  void _setupParticipantListener() {
    final participant = widget.participant;
    if (participant == null) return;

    // Listen for track changes
    participant.addListener(_updateTracks);
  }

  void _updateTracks() {
    if (!mounted) return;

    final participant = widget.participant;
    if (participant is! lk.LocalParticipant &&
        participant is! lk.RemoteParticipant) {
      return;
    }

    // Get camera video track (not screen share)
    lk.VideoTrack? videoTrack;
    final cameraPubs = participant.videoTrackPublications.where(
      (p) => p.source != lk.TrackSource.screenShareVideo,
    );
    if (cameraPubs.isNotEmpty) {
      videoTrack = cameraPubs.first.track as lk.VideoTrack?;
    }

    final audioPubs = participant.audioTrackPublications;
    final audioMuted = audioPubs.isEmpty || audioPubs.first.muted;

    // Only update if something changed
    if (_videoTrack != videoTrack || _audioMuted != audioMuted) {
      setState(() {
        _videoTrack = videoTrack;
        _audioMuted = audioMuted;
      });
    }
  }

  @override
  void dispose() {
    widget.participant?.removeListener(_updateTracks);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final userId = widget.participant?.identity;
    final bool videoOff = _videoTrack == null || _videoTrack!.muted;

    final displayName = widget.displayName ?? userId ?? 'Unknown';

    return Card(
      clipBehavior: Clip.antiAlias,
      child: GestureDetector(
        onLongPress: widget.onLongPress,
        onSecondaryTap: widget.onSecondaryTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video or Profile Picture
            if (!videoOff)
              lk.VideoTrackRenderer(
                _videoTrack!,
                key: ValueKey(_videoTrack!.mediaStreamTrack.id),
              )
            else if (_cachedProfileWidget != null)
              _cachedProfileWidget!
            else
              Container(
                color: Theme.of(context).colorScheme.surfaceVariant,
                child: const Center(
                  child: Icon(
                    Icons.videocam_off,
                    size: 48,
                  ),
                ),
              ),

            // Pin indicator
            if (widget.isPinned)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(
                    Icons.push_pin,
                    size: 16,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),

            // Label overlay
            Positioned(
              bottom: 8,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.scrim.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      widget.isLocal ? Icons.person : Icons.person_outline,
                      size: 14,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      widget.isLocal ? 'You' : displayName,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Muted indicator
            if (_audioMuted)
              Positioned(
                top: 8,
                right: 8,
                child: Icon(
                  Icons.mic_off,
                  color: Theme.of(context).colorScheme.error,
                  size: 24,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Isolated profile display that doesn't rebuild when parent changes
class _ProfileDisplaySection extends StatelessWidget {
  final String? profilePicture;
  final String displayName;
  final String? userId;

  const _ProfileDisplaySection({
    required this.profilePicture,
    required this.displayName,
    required this.userId,
  });

  @override
  Widget build(BuildContext context) {
    if (profilePicture != null && profilePicture!.isNotEmpty) {
      return ParticipantProfileDisplay(
        key: ValueKey('profile_$userId'),
        profilePictureBase64: profilePicture!,
        displayName: displayName,
      );
    }

    return Container(
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: const Center(
        child: Icon(
          Icons.videocam_off,
          size: 48,
        ),
      ),
    );
  }
}
