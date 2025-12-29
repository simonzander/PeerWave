import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import '../services/video_conference_service.dart';
import '../services/user_profile_service.dart';
import '../models/audio_settings.dart';
import 'dart:convert';
import 'dart:typed_data';

/// Helper function to decode base64 profile picture
/// Strips data URI prefix if present (e.g., data:image/png;base64,)
Uint8List? _safeDecodeProfilePicture(String base64String) {
  try {
    String cleanedBase64 = base64String;

    // Remove data URI prefix if present (e.g., data:image/png;base64,)
    if (base64String.contains(',')) {
      cleanedBase64 = base64String.split(',').last;
    }

    return base64Decode(cleanedBase64);
  } catch (e) {
    debugPrint('[PARTICIPANT_CONTEXT_MENU] Error decoding profile picture: $e');
    return null;
  }
}

/// Context menu content for per-participant audio controls (without positioning)
class ParticipantContextMenuContent extends StatefulWidget {
  final RemoteParticipant participant;
  final bool isPinned;
  final VoidCallback onPin;

  const ParticipantContextMenuContent({
    super.key,
    required this.participant,
    required this.isPinned,
    required this.onPin,
  });

  @override
  State<ParticipantContextMenuContent> createState() =>
      _ParticipantContextMenuContentState();
}

class _ParticipantContextMenuContentState
    extends State<ParticipantContextMenuContent> {
  late ParticipantAudioState _audioState;
  String? _displayName;
  String? _profilePicture;

  @override
  void initState() {
    super.initState();
    final service = VideoConferenceService.instance;
    _audioState = service.getParticipantAudioState(widget.participant.sid);

    // Load profile with callback
    final userId = widget.participant.identity;
    final profile = UserProfileService.instance.getProfileOrLoad(
      userId,
      onLoaded: (profile) {
        if (mounted && profile != null) {
          setState(() {
            _displayName = profile['displayName'] as String?;
            _profilePicture = profile['picture'] as String?;
          });
        }
      },
    );

    // Use cached data if available
    if (profile != null) {
      _displayName = profile['displayName'] as String?;
      _profilePicture = profile['picture'] as String?;
    }
  }

  void _updateAudioState(ParticipantAudioState newState) {
    setState(() {
      _audioState = newState;
    });
    VideoConferenceService.instance.updateParticipantAudioState(newState);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final userId = widget.participant.identity;
    final displayName = _displayName ?? userId;
    final profilePicture = _profilePicture;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              // Profile picture
              () {
                final decoded =
                    profilePicture != null && profilePicture.isNotEmpty
                    ? _safeDecodeProfilePicture(profilePicture)
                    : null;

                if (decoded != null) {
                  return Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      image: DecorationImage(
                        image: MemoryImage(decoded),
                        fit: BoxFit.cover,
                      ),
                    ),
                  );
                } else {
                  return Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Icon(
                      Icons.person,
                      size: 20,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  );
                }
              }(),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  displayName,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Volume slider
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Volume', style: theme.textTheme.bodySmall),
                  Text(
                    '${(_audioState.volume * 100).round()}%',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Slider(
                value: _audioState.volume,
                min: 0.0,
                max: 2.0,
                divisions: 20,
                onChanged: (value) {
                  _updateAudioState(_audioState.copyWith(volume: value));
                  // Note: Volume control requires audio element manipulation
                  // which is handled at the MediaStreamTrack level in the UI
                },
              ),
            ],
          ),
        ),

        const Divider(height: 1),

        // Local mute toggle
        ListTile(
          dense: true,
          leading: Icon(
            _audioState.locallyMuted ? Icons.volume_off : Icons.volume_up,
            size: 20,
          ),
          title: Text(
            _audioState.locallyMuted ? 'Unmute (Local)' : 'Mute (Local)',
            style: theme.textTheme.bodyMedium,
          ),
          subtitle: Text(
            'Only affects your audio',
            style: theme.textTheme.bodySmall,
          ),
          onTap: () {
            final newMuted = !_audioState.locallyMuted;
            _updateAudioState(_audioState.copyWith(locallyMuted: newMuted));
            // Note: Local muting requires audio element manipulation
            // which is handled at the MediaStreamTrack level in the UI
          },
        ),

        const Divider(height: 1),

        // Pin/Unpin
        ListTile(
          dense: true,
          leading: Icon(
            widget.isPinned ? Icons.push_pin_outlined : Icons.push_pin,
            size: 20,
          ),
          title: Text(
            widget.isPinned ? 'Unpin Participant' : 'Pin Participant',
            style: theme.textTheme.bodyMedium,
          ),
          onTap: widget.onPin,
        ),

        const Divider(height: 1),

        // Reset to defaults
        ListTile(
          dense: true,
          leading: const Icon(Icons.restore, size: 20),
          title: Text('Reset to Defaults', style: theme.textTheme.bodyMedium),
          onTap: () {
            _updateAudioState(
              ParticipantAudioState(participantId: widget.participant.sid),
            );
            // Note: Reset requires audio element manipulation
            // which is handled at the MediaStreamTrack level in the UI
          },
        ),

        const SizedBox(height: 8),
      ],
    );
  }
}

/// Context menu for per-participant audio controls (positioned version for desktop)
class ParticipantContextMenu extends StatefulWidget {
  final RemoteParticipant participant;
  final Offset position;

  const ParticipantContextMenu({
    super.key,
    required this.participant,
    required this.position,
  });

  @override
  State<ParticipantContextMenu> createState() => _ParticipantContextMenuState();
}

class _ParticipantContextMenuState extends State<ParticipantContextMenu> {
  late ParticipantAudioState _audioState;
  String? _displayName;
  String? _profilePicture;

  @override
  void initState() {
    super.initState();
    final service = VideoConferenceService.instance;
    _audioState = service.getParticipantAudioState(widget.participant.sid);

    // Load profile with callback
    final userId = widget.participant.identity;
    final profile = UserProfileService.instance.getProfileOrLoad(
      userId,
      onLoaded: (profile) {
        if (mounted && profile != null) {
          setState(() {
            _displayName = profile['displayName'] as String?;
            _profilePicture = profile['picture'] as String?;
          });
        }
      },
    );

    // Use cached data if available
    if (profile != null) {
      _displayName = profile['displayName'] as String?;
      _profilePicture = profile['picture'] as String?;
    }
  }

  void _updateAudioState(ParticipantAudioState newState) {
    setState(() {
      _audioState = newState;
    });
    VideoConferenceService.instance.updateParticipantAudioState(newState);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final userId = widget.participant.identity;
    final displayName = _displayName ?? userId;
    final profilePicture = _profilePicture;

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 280,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  // Profile picture
                  () {
                    final decoded =
                        profilePicture != null && profilePicture.isNotEmpty
                        ? _safeDecodeProfilePicture(profilePicture)
                        : null;

                    if (decoded != null) {
                      return Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          image: DecorationImage(
                            image: MemoryImage(decoded),
                            fit: BoxFit.cover,
                          ),
                        ),
                      );
                    } else {
                      return Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Icon(
                          Icons.person,
                          size: 20,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      );
                    }
                  }(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      displayName,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Volume slider
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Volume', style: theme.textTheme.bodySmall),
                      Text(
                        '${(_audioState.volume * 100).round()}%',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Slider(
                    value: _audioState.volume,
                    min: 0.0,
                    max: 2.0,
                    divisions: 20,
                    onChanged: (value) {
                      _updateAudioState(_audioState.copyWith(volume: value));
                      // Note: Volume control requires audio element manipulation
                      // which is handled at the MediaStreamTrack level in the UI
                    },
                  ),
                ],
              ),
            ),

            const Divider(height: 1),

            // Local mute toggle
            ListTile(
              dense: true,
              leading: Icon(
                _audioState.locallyMuted ? Icons.volume_off : Icons.volume_up,
                size: 20,
              ),
              title: Text(
                _audioState.locallyMuted ? 'Unmute (Local)' : 'Mute (Local)',
                style: theme.textTheme.bodyMedium,
              ),
              subtitle: Text(
                'Only affects your audio',
                style: theme.textTheme.bodySmall,
              ),
              onTap: () {
                final newMuted = !_audioState.locallyMuted;
                _updateAudioState(_audioState.copyWith(locallyMuted: newMuted));
                // Note: Local muting requires audio element manipulation
                // which is handled at the MediaStreamTrack level in the UI
              },
            ),

            const Divider(height: 1),

            // Reset to defaults
            ListTile(
              dense: true,
              leading: const Icon(Icons.restore, size: 20),
              title: Text(
                'Reset to Defaults',
                style: theme.textTheme.bodyMedium,
              ),
              onTap: () {
                _updateAudioState(
                  ParticipantAudioState(participantId: widget.participant.sid),
                );
                // Note: Reset requires audio element manipulation
                // which is handled at the MediaStreamTrack level in the UI
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows participant context menu at cursor position
Future<void> showParticipantContextMenu(
  BuildContext context,
  RemoteParticipant participant,
  Offset position,
) {
  return showDialog(
    context: context,
    barrierColor: Colors.transparent,
    builder: (context) => Stack(
      children: [
        // Dismiss on tap outside
        Positioned.fill(
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            behavior: HitTestBehavior.opaque,
          ),
        ),
        // Context menu
        Positioned(
          left: position.dx,
          top: position.dy,
          child: ParticipantContextMenu(
            participant: participant,
            position: position,
          ),
        ),
      ],
    ),
  );
}
