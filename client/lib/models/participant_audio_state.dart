/// Tracks audio activity state for a participant
class ParticipantAudioState {
  final String participantId;
  bool isSpeaking;
  DateTime lastSpokeAt;
  bool isVisible;
  bool isPinned;

  ParticipantAudioState({
    required this.participantId,
    this.isSpeaking = false,
    DateTime? lastSpokeAt,
    this.isVisible = true,
    this.isPinned = false,
  }) : lastSpokeAt = lastSpokeAt ?? DateTime.now();

  /// Update speaking state and timestamp
  void updateSpeaking(bool speaking) {
    isSpeaking = speaking;
    if (speaking) {
      lastSpokeAt = DateTime.now();
    }
  }

  /// Duration since last spoke
  Duration get timeSinceLastSpoke => DateTime.now().difference(lastSpokeAt);

  /// Copy with method for immutable updates
  ParticipantAudioState copyWith({
    bool? isSpeaking,
    DateTime? lastSpokeAt,
    bool? isVisible,
    bool? isPinned,
  }) {
    return ParticipantAudioState(
      participantId: participantId,
      isSpeaking: isSpeaking ?? this.isSpeaking,
      lastSpokeAt: lastSpokeAt ?? this.lastSpokeAt,
      isVisible: isVisible ?? this.isVisible,
      isPinned: isPinned ?? this.isPinned,
    );
  }
}
