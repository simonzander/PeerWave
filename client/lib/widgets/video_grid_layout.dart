import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import '../widgets/video_participant_tile.dart';
import '../widgets/speaking_border_wrapper.dart';
import '../widgets/hidden_participants_badge.dart';
import '../widgets/participant_visibility_manager.dart';
import '../models/participant_audio_state.dart';

/// Reusable video grid layout widget
/// Handles screen share layouts and regular grid with smart visibility
class VideoGridLayout extends StatelessWidget {
  final lk.Room? room;
  final bool hasScreenShare;
  final String? screenShareParticipantId;
  final Map<String, ParticipantAudioState> participantStates;
  final Map<String, ValueNotifier<bool>> speakingNotifiers;
  final Map<String, String> displayNameCache;
  final Map<String, String> profilePictureCache;
  final int maxVisibleParticipants;
  final Function(String participantId, bool isPinned)? onShowParticipantMenu;
  final List<Map<String, dynamic>>? pendingParticipants;

  const VideoGridLayout({
    Key? key,
    required this.room,
    required this.hasScreenShare,
    this.screenShareParticipantId,
    required this.participantStates,
    required this.speakingNotifiers,
    required this.displayNameCache,
    required this.profilePictureCache,
    required this.maxVisibleParticipants,
    this.onShowParticipantMenu,
    this.pendingParticipants,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (room == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final localParticipant = room!.localParticipant;
    final remoteParticipants = room!.remoteParticipants.values.toList();

    // Build participant list (for camera feeds only)
    final List<Map<String, dynamic>> cameraParticipants = [];
    if (localParticipant != null) {
      cameraParticipants.add({
        'participant': localParticipant,
        'isLocal': true,
      });
    }
    for (final remote in remoteParticipants) {
      cameraParticipants.add({'participant': remote, 'isLocal': false});
    }
    
    // Add pending participants (not yet joined)
    if (pendingParticipants != null) {
      for (final pending in pendingParticipants!) {
        cameraParticipants.add({
          'participant': null,
          'isLocal': false,
          'isPending': true,
          'pendingData': pending,
        });
      }
    }

    if (hasScreenShare && screenShareParticipantId != null) {
      // Find the participant who is sharing
      final screenShareParticipant =
          screenShareParticipantId == localParticipant?.identity
          ? localParticipant
          : remoteParticipants.firstWhere(
              (p) => p.identity == screenShareParticipantId,
              orElse: () => remoteParticipants.first,
            );

      // Determine layout based on screen orientation
      final size = MediaQuery.of(context).size;
      final isHorizontal = size.width > size.height;

      if (isHorizontal) {
        return _buildHorizontalScreenShareLayout(
          context: context,
          screenShareParticipant: screenShareParticipant,
          cameraParticipants: cameraParticipants,
        );
      } else {
        return _buildVerticalScreenShareLayout(
          context: context,
          screenShareParticipant: screenShareParticipant,
          cameraParticipants: cameraParticipants,
        );
      }
    } else {
      // No screen share - use regular grid
      return _buildRegularGrid(context, cameraParticipants);
    }
  }

  /// Horizontal layout: Screen share on left (80%), cameras on right (20%)
  Widget _buildHorizontalScreenShareLayout({
    required BuildContext context,
    required dynamic screenShareParticipant,
    required List<Map<String, dynamic>> cameraParticipants,
  }) {
    return Row(
      children: [
        // Screen share - 80% width
        Expanded(
          flex: 8,
          child: Container(
            color: Theme.of(context).colorScheme.surface,
            child: _buildScreenShareTile(context, screenShareParticipant),
          ),
        ),
        // Camera feeds - 20% width (vertical list)
        Expanded(
          flex: 2,
          child: ListView.builder(
            itemCount: cameraParticipants.length,
            itemBuilder: (context, index) {
              final item = cameraParticipants[index];
              return Padding(
                padding: const EdgeInsets.all(4.0),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: _buildVideoTile(
                    context: context,
                    participant: item['participant'],
                    isLocal: item['isLocal'],
                    isPending: item['isPending'] == true,
                    pendingData: item['pendingData'] as Map<String, dynamic>?,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Vertical layout: Cameras on top (20%), screen share below (80%)
  Widget _buildVerticalScreenShareLayout({
    required BuildContext context,
    required dynamic screenShareParticipant,
    required List<Map<String, dynamic>> cameraParticipants,
  }) {
    return Column(
      children: [
        // Camera feeds - 20% height (horizontal scrollable row)
        SizedBox(
          height: MediaQuery.of(context).size.height * 0.2,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: cameraParticipants.length,
            itemBuilder: (context, index) {
              final item = cameraParticipants[index];
              return Padding(
                padding: const EdgeInsets.all(4.0),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: _buildVideoTile(
                    context: context,
                    participant: item['participant'],
                    isLocal: item['isLocal'],
                    isPending: item['isPending'] == true,
                    pendingData: item['pendingData'] as Map<String, dynamic>?,
                  ),
                ),
              );
            },
          ),
        ),
        // Screen share - 80% height
        Expanded(
          child: Container(
            color: Theme.of(context).colorScheme.surface,
            width: double.infinity,
            child: _buildScreenShareTile(context, screenShareParticipant),
          ),
        ),
      ],
    );
  }

  /// Build screen share tile with label
  Widget _buildScreenShareTile(BuildContext context, dynamic participant) {
    // Get screen share track
    lk.VideoTrack? screenShareTrack;
    if (participant is lk.LocalParticipant ||
        participant is lk.RemoteParticipant) {
      final screenPubs = participant.videoTrackPublications.where(
        (p) => p.source == lk.TrackSource.screenShareVideo,
      );
      if (screenPubs.isNotEmpty) {
        screenShareTrack = screenPubs.first.track as lk.VideoTrack?;
      }
    }

    final userId = participant.identity;
    final displayName = userId != null
        ? (displayNameCache[userId] ?? userId)
        : 'Unknown';

    final isLocal = participant is lk.LocalParticipant;
    final label = isLocal ? 'Your Screen' : '$displayName\'s Screen';

    return Stack(
      fit: StackFit.expand,
      children: [
        if (screenShareTrack != null)
          lk.VideoTrackRenderer(
            screenShareTrack,
            key: ValueKey(screenShareTrack.mediaStreamTrack.id),
            fit: lk.VideoViewFit.contain,
          )
        else
          Container(
            color: Theme.of(context).colorScheme.surfaceVariant,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.screen_share,
                    size: 64,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Screen share loading...',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        // Label
        Positioned(
          top: 8,
          left: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.scrim.withOpacity(0.7),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.screen_share,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Regular grid layout (no screen share) with smart visibility
  Widget _buildRegularGrid(
    BuildContext context,
    List<Map<String, dynamic>> participants,
  ) {
    if (room == null) return const SizedBox.shrink();

    final localId = room!.localParticipant?.identity;
    if (localId == null) return const SizedBox.shrink();

    // If maxVisibleParticipants is 0 (not calculated yet), show all participants
    // to prevent empty grid on initial load
    final effectiveMaxVisible = maxVisibleParticipants > 0 
        ? maxVisibleParticipants 
        : participants.length;

    // Get visibility manager
    final manager = ParticipantVisibilityManager(
      maxVisibleParticipants: effectiveMaxVisible,
      localParticipantId: localId,
    );

    // Get list of visible participant IDs
    final visibleIds = manager.getVisibleParticipantIds(participantStates);

    // Filter participants to only show visible ones
    final visibleParticipants = participants.where((item) {
      final participant = item['participant'];
      final participantId = participant.identity;
      return participantId != null && visibleIds.contains(participantId);
    }).toList();

    final totalVisible = visibleParticipants.length;
    final totalHidden = participants.length - totalVisible;

    int columns = 1;
    if (totalVisible > 1) columns = 2;
    if (totalVisible > 4) columns = 3;

    return Stack(
      children: [
        Container(
          color: Theme.of(context).colorScheme.surface,
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              childAspectRatio: 16 / 9,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: totalVisible,
            itemBuilder: (context, index) {
              final item = visibleParticipants[index];
              final participant = item['participant'];
              final isLocal = item['isLocal'] as bool;
              final isPending = item['isPending'] == true;
              final pendingData = item['pendingData'] as Map<String, dynamic>?;

              return _buildVideoTile(
                context: context,
                participant: participant,
                isLocal: isLocal,
                isPending: isPending,
                pendingData: pendingData,
              );
            },
          ),
        ),

        // Hidden participants badge
        if (totalHidden > 0)
          Positioned(
            bottom: 16,
            left: 0,
            right: 0,
            child: Center(
              child: HiddenParticipantsBadge(hiddenCount: totalHidden),
            ),
          ),
      ],
    );
  }

  Widget _buildVideoTile({
    required BuildContext context,
    required dynamic participant,
    required bool isLocal,
    bool isPending = false,
    Map<String, dynamic>? pendingData,
  }) {
    // Handle pending participants (invited but not joined yet)
    if (isPending && pendingData != null) {
      final displayName = pendingData['displayName'] as String? ?? 'Unknown';
      final profilePicture = pendingData['picture'] as String?;
      
      return Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceVariant,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline.withOpacity(0.3),
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Greyed background with profile picture or initial
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
              ),
              child: Center(
                child: CircleAvatar(
                  radius: 40,
                  backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                  child: Text(
                    displayName.substring(0, 1).toUpperCase(),
                    style: TextStyle(
                      fontSize: 32,
                      color: Theme.of(context).colorScheme.onPrimaryContainer.withOpacity(0.5),
                    ),
                  ),
                ),
              ),
            ),
            // Overlay with waiting message
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: Colors.black.withOpacity(0.6),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.person_add,
                      size: 48,
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      displayName,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Waiting for participant to join...',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                        fontSize: 12,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final userId = participant.identity;

    // Get display name and profile picture from cache
    final displayName = userId != null
        ? (displayNameCache[userId] ?? userId)
        : 'Unknown';
    final profilePicture =
        userId != null ? profilePictureCache[userId] : null;

    // Get audio state for speaking indicator
    final speakingNotifier =
        userId != null && speakingNotifiers.containsKey(userId)
        ? speakingNotifiers[userId]!
        : null;
    final isPinned =
        userId != null && participantStates.containsKey(userId)
        ? participantStates[userId]!.isPinned
        : false;

    // Wrap tile with speaking indicator
    return _SpeakingStateWrapper(
      speakingNotifier: speakingNotifier,
      child: VideoParticipantTile(
        key: ValueKey('tile_$userId'),
        participant: participant,
        isLocal: isLocal,
        displayName: displayName,
        profilePicture: profilePicture,
        isPinned: isPinned,
        onLongPress: userId != null && onShowParticipantMenu != null
            ? () => onShowParticipantMenu!(userId, isPinned)
            : null,
        onSecondaryTap: userId != null && onShowParticipantMenu != null
            ? () => onShowParticipantMenu!(userId, isPinned)
            : null,
      ),
    );
  }
}

/// Wrapper that isolates speaking state changes to only affect the border
class _SpeakingStateWrapper extends StatelessWidget {
  final ValueNotifier<bool>? speakingNotifier;
  final Widget child;

  const _SpeakingStateWrapper({
    required this.speakingNotifier,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (speakingNotifier == null) {
      return SpeakingBorderWrapper(isSpeaking: false, child: child);
    }

    return ValueListenableBuilder<bool>(
      valueListenable: speakingNotifier!,
      builder: (context, isSpeaking, child) {
        return SpeakingBorderWrapper(isSpeaking: isSpeaking, child: child!);
      },
      child: child,
    );
  }
}
