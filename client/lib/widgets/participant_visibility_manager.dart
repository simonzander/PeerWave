import 'package:flutter/material.dart';
import '../models/participant_audio_state.dart';

/// Manages which participants should be visible based on grid capacity and activity
class ParticipantVisibilityManager {
  final int maxVisibleParticipants;
  final String localParticipantId;

  ParticipantVisibilityManager({
    required this.maxVisibleParticipants,
    required this.localParticipantId,
  });

  /// Calculate which participants should be visible
  /// Priority order:
  /// 1. Local participant (always visible)
  /// 2. Pinned participants
  /// 3. Currently speaking participants
  /// 4. Recently active participants
  List<String> getVisibleParticipantIds(
    Map<String, ParticipantAudioState> allStates,
  ) {
    final visibleIds = <String>[];

    // 1. Always include local participant
    if (allStates.containsKey(localParticipantId)) {
      visibleIds.add(localParticipantId);
    }

    // 2. Add pinned participants
    final pinnedStates = allStates.values
        .where((s) => s.isPinned && s.participantId != localParticipantId)
        .toList();
    for (final state in pinnedStates) {
      if (visibleIds.length >= maxVisibleParticipants) break;
      visibleIds.add(state.participantId);
    }

    // 3. Add currently speaking participants
    final speakingStates = allStates.values
        .where(
          (s) =>
              s.isSpeaking &&
              !s.isPinned &&
              s.participantId != localParticipantId,
        )
        .toList();
    for (final state in speakingStates) {
      if (visibleIds.length >= maxVisibleParticipants) break;
      if (!visibleIds.contains(state.participantId)) {
        visibleIds.add(state.participantId);
      }
    }

    // 4. Fill remaining slots with recently active participants
    final remainingStates =
        allStates.values
            .where(
              (s) =>
                  !s.isSpeaking &&
                  !s.isPinned &&
                  s.participantId != localParticipantId,
            )
            .toList()
          ..sort((a, b) => b.lastSpokeAt.compareTo(a.lastSpokeAt));

    for (final state in remainingStates) {
      if (visibleIds.length >= maxVisibleParticipants) break;
      if (!visibleIds.contains(state.participantId)) {
        visibleIds.add(state.participantId);
      }
    }

    return visibleIds;
  }

  /// Find which visible participant should be replaced when a hidden participant speaks
  /// Returns the participant ID with the longest silence duration (excluding pinned and local)
  String? findParticipantToReplace(
    Map<String, ParticipantAudioState> allStates,
    List<String> currentlyVisible,
  ) {
    // Filter visible participants that can be replaced
    final replaceableCandidates = currentlyVisible
        .where((id) {
          final state = allStates[id];
          if (state == null) return false;
          // Can't replace local, pinned, or currently speaking
          return id != localParticipantId &&
              !state.isPinned &&
              !state.isSpeaking;
        })
        .map((id) => allStates[id]!)
        .toList();

    if (replaceableCandidates.isEmpty) return null;

    // Sort by longest silence (oldest lastSpokeAt)
    replaceableCandidates.sort(
      (a, b) => a.lastSpokeAt.compareTo(b.lastSpokeAt),
    );

    return replaceableCandidates.first.participantId;
  }

  /// Calculate maximum visible participants based on grid dimensions
  static int calculateMaxVisible(
    Size screenSize, {
    bool hasScreenShare = false,
  }) {
    // If screen sharing, allocate less space for participant grid
    final availableHeight = hasScreenShare
        ? screenSize.height * 0.4
        : screenSize.height;
    final availableWidth = screenSize.width;

    // Assume 16:9 aspect ratio tiles with 8px padding
    const tileAspectRatio = 16 / 9;
    const padding = 16.0;

    // Try different grid configurations and pick the largest that fits
    int maxParticipants = 1;

    for (int columns = 1; columns <= 4; columns++) {
      final tileWidth = (availableWidth - (columns + 1) * padding) / columns;
      final tileHeight = tileWidth / tileAspectRatio;

      final int maxRows = ((availableHeight - padding) / (tileHeight + padding))
          .floor();
      final totalTiles = columns * maxRows;

      if (totalTiles > maxParticipants) {
        maxParticipants = totalTiles;
      }
    }

    // Clamp to reasonable limits
    return maxParticipants.clamp(1, 16);
  }
}
