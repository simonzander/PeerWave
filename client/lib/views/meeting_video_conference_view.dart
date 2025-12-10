import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'dart:async';
import '../services/video_conference_service.dart';
import '../services/message_listener_service.dart';
import '../services/user_profile_service.dart';
import '../widgets/video_grid_layout.dart';
import '../widgets/video_controls_bar.dart';
import '../models/participant_audio_state.dart';
import '../extensions/snackbar_extensions.dart';

/// Video conference view for meetings
/// Uses meetingId as the room identifier (not channelId)
class MeetingVideoConferenceView extends StatefulWidget {
  final String meetingId;
  final String meetingTitle;
  final lk.MediaDevice? selectedCamera;
  final lk.MediaDevice? selectedMicrophone;

  const MeetingVideoConferenceView({
    super.key,
    required this.meetingId,
    required this.meetingTitle,
    this.selectedCamera,
    this.selectedMicrophone,
  });

  @override
  State<MeetingVideoConferenceView> createState() =>
      _MeetingVideoConferenceViewState();
}

class _MeetingVideoConferenceViewState
    extends State<MeetingVideoConferenceView> {
  VideoConferenceService? _service;

  bool _isJoining = false;
  String? _errorMessage;

  // Audio state tracking
  final Map<String, ParticipantAudioState> _participantStates = {};
  final Map<String, ValueNotifier<bool>> _speakingNotifiers = {};
  Timer? _visibilityUpdateTimer;
  int _maxVisibleParticipants = 0;
  final Map<String, StreamSubscription> _audioSubscriptions = {};

  // Profile cache
  final Map<String, String> _displayNameCache = {};
  final Map<String, String> _profilePictureCache = {};

  @override
  void initState() {
    super.initState();

    // Start periodic visibility updates
    _visibilityUpdateTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _updateVisibility(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (_service == null) {
      try {
        _service = Provider.of<VideoConferenceService>(context, listen: false);
        debugPrint('[MeetingVideo] Service obtained from Provider');

        // Register with MessageListenerService for E2EE
        MessageListenerService.instance.registerVideoConferenceService(
          _service!,
        );
        debugPrint(
          '[MeetingVideo] Registered VideoConferenceService with MessageListener',
        );

        // Schedule join after build
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !(_service?.isInCall ?? false)) {
            _joinMeeting();
          }
        });
      } catch (e) {
        debugPrint('[MeetingVideo] Failed to get service: $e');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _errorMessage = 'Service not available: $e';
            });
          }
        });
      }
    }
  }

  Future<void> _joinMeeting() async {
    if (_isJoining || _service == null) return;

    setState(() {
      _isJoining = true;
      _errorMessage = null;
    });

    try {
      debugPrint('[MeetingVideo] Joining meeting: ${widget.meetingId}');

      // Join LiveKit room (room name = meeting ID)
      await _service!.joinRoom(
        widget.meetingId, // Use meeting ID as room identifier
        channelName: widget.meetingTitle,
        cameraDevice: widget.selectedCamera,
        microphoneDevice: widget.selectedMicrophone,
      );

      setState(() => _isJoining = false);
      debugPrint('[MeetingVideo] Successfully joined meeting');

      // Calculate initial visibility and set up states
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _updateVisibility();
          _updateParticipantStates();
        }
      });

      // Enter full-view mode
      _service!.enterFullView();
    } catch (e) {
      debugPrint('[MeetingVideo] Join error: $e');
      setState(() {
        _isJoining = false;
        _errorMessage = 'Failed to join: $e';
      });
    }
  }

  Future<void> _leaveMeeting() async {
    if (_service == null) return;

    try {
      await _service!.leaveRoom();

      // Navigate back to meetings list
      if (mounted) {
        context.go('/app/meetings');
      }
    } catch (e) {
      debugPrint('[MeetingVideo] Leave error: $e');
    }
  }

  @override
  void dispose() {
    // Clean up subscriptions
    for (final sub in _audioSubscriptions.values) {
      sub.cancel();
    }
    _audioSubscriptions.clear();

    for (final notifier in _speakingNotifiers.values) {
      notifier.dispose();
    }
    _speakingNotifiers.clear();

    _visibilityUpdateTimer?.cancel();

    // Exit full-view mode
    if (_service != null && _service!.isInCall) {
      debugPrint('[MeetingVideo] Exiting full-view, returning to overlay mode');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _service?.exitFullView();
      });
    }

    // Unregister from MessageListenerService
    MessageListenerService.instance.unregisterVideoConferenceService();
    debugPrint(
      '[MeetingVideo] Unregistered VideoConferenceService from MessageListener',
    );

    super.dispose();
  }

  void _updateVisibility() {
    if (_service == null || _service!.room == null || !mounted) return;

    final screenSize = MediaQuery.of(context).size;
    final hasScreenShare = _service!.hasActiveScreenShare;

    // Calculate max visible participants
    final newMaxVisible = _calculateMaxVisible(screenSize, hasScreenShare);

    if (newMaxVisible != _maxVisibleParticipants) {
      _maxVisibleParticipants = newMaxVisible;
      _updateParticipantStates();
      setState(() {});
    }
  }

  int _calculateMaxVisible(Size screenSize, bool hasScreenShare) {
    if (hasScreenShare) {
      // With screen share: show fewer camera feeds
      return screenSize.width > screenSize.height ? 4 : 3;
    } else {
      // Regular grid: show more participants
      final area = screenSize.width * screenSize.height;
      if (area > 1920 * 1080) return 12; // 4K
      if (area > 1280 * 720) return 9; // 1080p
      return 6; // 720p or less
    }
  }

  void _updateParticipantStates() {
    if (_service?.room == null) return;

    final room = _service!.room!;
    final allParticipantIds = <String>{};

    // Add local participant
    if (room.localParticipant != null) {
      final localId = room.localParticipant!.identity;
      allParticipantIds.add(localId);

      if (!_participantStates.containsKey(localId)) {
        _participantStates[localId] = ParticipantAudioState(
          participantId: localId,
        );
        _speakingNotifiers[localId] = ValueNotifier(false);
        _setupAudioListener(room.localParticipant!);
        _loadParticipantProfile(localId);
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
        _speakingNotifiers[remoteId] = ValueNotifier(false);
        _setupAudioListener(remote);
        _loadParticipantProfile(remoteId);
      }
    }

    // Remove states for participants who left
    _participantStates.removeWhere((id, _) => !allParticipantIds.contains(id));
    _speakingNotifiers.removeWhere((id, notifier) {
      if (!allParticipantIds.contains(id)) {
        notifier.dispose();
        return true;
      }
      return false;
    });
    _audioSubscriptions.removeWhere((id, sub) {
      if (!allParticipantIds.contains(id)) {
        sub.cancel();
        return true;
      }
      return false;
    });
  }

  void _loadParticipantProfile(String participantId) {
    final profile = UserProfileService.instance.getProfileOrLoad(
      participantId,
      onLoaded: (profile) {
        if (mounted && profile != null) {
          setState(() {
            _displayNameCache[participantId] =
                profile['displayName'] as String? ?? participantId;
            _profilePictureCache[participantId] =
                profile['picture'] as String? ?? '';
          });
        }
      },
    );

    if (profile != null) {
      _displayNameCache[participantId] =
          profile['displayName'] as String? ?? participantId;
      _profilePictureCache[participantId] = profile['picture'] as String? ?? '';
    }
  }

  void _setupAudioListener(dynamic participant) {
    if (participant == null) return;

    final participantId = participant.identity;
    if (participantId == null) return;

    participant.addListener(() {
      if (!mounted) return;

      final isSpeaking = participant.isSpeaking ?? false;

      if (_participantStates.containsKey(participantId)) {
        final currentState = _participantStates[participantId]!;
        if (currentState.isSpeaking != isSpeaking) {
          _participantStates[participantId]!.updateSpeaking(isSpeaking);
          if (_speakingNotifiers.containsKey(participantId)) {
            _speakingNotifiers[participantId]!.value = isSpeaking;
          }
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.meetingTitle),
            Row(
              children: [
                Icon(
                  Icons.verified_user,
                  size: 14,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  'E2E Encrypted',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.normal,
                  ),
                ),
              ],
            ),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        actions: [
          // Participant count
          Selector<VideoConferenceService, int>(
            selector: (_, service) => service.remoteParticipants.length,
            builder: (_, remoteCount, __) => Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '${remoteCount + 1} online',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ),
          ),
          // Leave button
          IconButton(
            icon: const Icon(Icons.call_end),
            color: Theme.of(context).colorScheme.error,
            onPressed: _leaveMeeting,
            tooltip: 'Leave Call',
          ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar: _buildControls(),
    );
  }

  Widget _buildBody() {
    if (_isJoining) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Joining meeting...'),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => context.pop(),
              child: const Text('Go Back'),
            ),
          ],
        ),
      );
    }

    return Consumer<VideoConferenceService>(
      builder: (context, service, child) {
        return VideoGridLayout(
          room: service.room,
          hasScreenShare: service.hasActiveScreenShare,
          screenShareParticipantId: service.currentScreenShareParticipantId,
          participantStates: _participantStates,
          speakingNotifiers: _speakingNotifiers,
          displayNameCache: _displayNameCache,
          profilePictureCache: _profilePictureCache,
          maxVisibleParticipants: _maxVisibleParticipants,
        );
      },
    );
  }

  Widget _buildControls() {
    if (_service == null) return const SizedBox.shrink();

    return VideoControlsBar(
      isMicEnabled: _service!.isMicrophoneEnabled(),
      isCameraEnabled: _service!.isCameraEnabled(),
      isScreenShareEnabled: _service!.isScreenShareEnabled(),
      onToggleMicrophone: () => _service!.toggleMicrophone(),
      onToggleCamera: () => _service!.toggleCamera(),
      onToggleScreenShare: () => _service!.toggleScreenShare(),
      onLeave: _leaveMeeting,
      onSwitchMicrophone: (device) => _service!.switchMicrophone(device),
      onSwitchCamera: (device) => _service!.switchCamera(device),
      onSetDesktopScreenSource: (sourceId) =>
          _service!.setDesktopScreenSource(sourceId),
    );
  }
}
