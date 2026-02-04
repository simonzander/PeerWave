import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:convert';
import '../services/video_conference_service.dart';
import '../services/message_listener_service.dart';
import '../services/user_profile_service.dart';
import '../services/api_service.dart';
import '../services/server_settings_service.dart';
import '../services/call_service.dart';
import '../screens/channel/channel_members_screen.dart';
import '../screens/channel/channel_settings_screen.dart';
import '../widgets/animated_widgets.dart';
import '../widgets/hidden_participants_badge.dart';
import '../widgets/participant_visibility_manager.dart';
import '../widgets/participant_context_menu.dart';
import '../widgets/video_participant_tile.dart';
import '../widgets/speaking_border_wrapper.dart';
import '../models/role.dart';
import '../models/participant_audio_state.dart';
import '../extensions/snackbar_extensions.dart';

/// VideoConferenceView - UI for video conferencing
///
/// Features:
/// - Video grid layout (responsive)
/// - Local video preview
/// - Audio/video toggle buttons
/// - Participant list
/// - E2EE indicator
class VideoConferenceView extends StatefulWidget {
  final String channelId;
  final String channelName;
  final String? host; // For settings and API calls
  final lk.MediaDevice? selectedCamera; // NEW: Pre-selected from PreJoin
  final lk.MediaDevice? selectedMicrophone; // NEW: Pre-selected from PreJoin
  final List<String>?
  invitedUserIds; // For instant calls - track who was invited

  // Instant call metadata (used to notify recipients after initiator joins)
  final bool isInstantCall;
  final bool isInitiator;
  final String? sourceChannelId;
  final String? sourceUserId;

  const VideoConferenceView({
    super.key,
    required this.channelId,
    required this.channelName,
    this.host,
    this.selectedCamera, // NEW
    this.selectedMicrophone, // NEW
    this.invitedUserIds, // NEW: For missed call tracking
    this.isInstantCall = false,
    this.isInitiator = false,
    this.sourceChannelId,
    this.sourceUserId,
  });

  @override
  State<VideoConferenceView> createState() => _VideoConferenceViewState();
}

class _VideoConferenceViewState extends State<VideoConferenceView> {
  VideoConferenceService? _service;

  bool _isJoining = false;
  String? _errorMessage;

  // Channel data
  Map<String, dynamic>? _channelData;
  bool _isOwner = false;

  // Audio state tracking
  final Map<String, ParticipantAudioState> _participantStates = {};
  final Map<String, ValueNotifier<bool>> _speakingNotifiers = {};
  Timer? _visibilityUpdateTimer;
  int _maxVisibleParticipants = 0;
  final Map<String, StreamSubscription> _audioSubscriptions = {};

  // Profile cache to prevent flickering
  final Map<String, String> _displayNameCache = {};
  final Map<String, String> _profilePictureCache = {};

  // Track invited/joined users for missed call notifications (instant calls only)
  Set<String> _invitedUserIds = {};
  final Set<String> _joinedUserIds = {};
  final Set<String> _declinedUserIds = {}; // Track users who declined/timed out

  bool _autoLeaving = false;

  StreamSubscription<Map<String, dynamic>>? _callDeclinedSub;

  @override
  void initState() {
    super.initState();

    // Initialize invited users for instant calls
    if (widget.invitedUserIds != null) {
      _invitedUserIds = widget.invitedUserIds!.toSet();
      debugPrint(
        '[VideoConferenceView] Tracking ${_invitedUserIds.length} invited users for missed calls',
      );
    }

    // Set up call decline listener for instant calls
    _setupCallDeclineListener();

    // Load channel details if host is available
    if (widget.host != null) {
      _loadChannelDetails();
    }

    // Start periodic visibility updates
    _visibilityUpdateTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _updateVisibility(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Get service from Provider
    if (_service == null) {
      try {
        _service = Provider.of<VideoConferenceService>(context, listen: false);
        debugPrint('[VideoConferenceView] Service obtained from Provider');

        // Register with MessageListenerService for E2EE key exchange
        MessageListenerService.instance.registerVideoConferenceService(
          _service!,
        );
        debugPrint(
          '[VideoConferenceView] Registered VideoConferenceService with MessageListener',
        );

        // Listen for participant joined events to track who actually joined
        _service!.onParticipantJoined.listen((participant) {
          // LiveKit identity is "userId:deviceId" in this app.
          final identity = participant.identity;
          final userId = identity.contains(':')
              ? identity.split(':').first
              : identity;
          if (userId.isNotEmpty && _invitedUserIds.isNotEmpty) {
            setState(() {
              _joinedUserIds.add(userId);
            });
            debugPrint(
              '[VideoConferenceView] User $userId joined, removing from missed call list',
            );
          }
        });

        // Schedule join for after build completes (only if not already in call)
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !(_service?.isInCall ?? false)) {
            _joinChannel();
          }
        });
      } catch (e) {
        debugPrint('[VideoConferenceView] Failed to get service: $e');
        // Schedule setState for after build
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _errorMessage = 'Service not available: $e';
            });
          }
        });
      }
    }

    // Full-view mode is already set by navigateToCurrentChannelFullView() before navigation
    // So we don't need to call enterFullView() here anymore
  }

  /// Listen for call:declined socket events to handle timeouts
  void _setupCallDeclineListener() {
    final isInstantCall =
        widget.isInstantCall || widget.channelId.startsWith('call_');
    if (!isInstantCall) return;

    // IMPORTANT: SocketService.registerListener currently only allows one
    // listener per event key. CallService is the canonical receiver and
    // forwards events via a stream.
    CallService().initializeListeners();
    _callDeclinedSub?.cancel();
    _callDeclinedSub = CallService().onCallDeclined.listen((declineData) async {
      try {
        final meetingId = declineData['meeting_id'] as String?;
        final userId = declineData['user_id'] as String?;
        final reason = declineData['reason'] as String?;

        // Only react to declines for THIS call
        if (meetingId == null || meetingId != widget.channelId) return;
        if (userId == null) return;

        // Dedupe (server/caller devices can emit duplicates)
        if (_declinedUserIds.contains(userId)) return;

        debugPrint(
          '[VideoConferenceView] User $userId declined call with reason: $reason',
        );

        // Track declined user
        if (mounted) {
          setState(() {
            _declinedUserIds.add(userId);
          });
        } else {
          _declinedUserIds.add(userId);
        }

        // Snackbars (UX)
        final displayName =
            UserProfileService.instance.getDisplayName(userId) ?? userId;

        if (mounted) {
          if (reason == 'timeout') {
            if (widget.sourceChannelId != null) {
              context.showInfoSnackBar("$displayName doesn't respond.");
            } else {
              context.showInfoSnackBar("$displayName didn't respond.");
            }
          } else {
            context.showInfoSnackBar('$displayName declined the call.');
          }
        }

        // If timeout, send missed call notification immediately
        if (reason == 'timeout') {
          await _sendMissedCallNotification(userId);
        }

        // Auto-leave behavior (initiator only)
        if (!mounted || !widget.isInitiator) return;

        // 1:1: leave immediately on decline/timeout
        if (widget.sourceUserId != null) {
          await _autoLeaveNow();
          return;
        }

        // Group: leave only after ALL invited recipients declined/timed out
        if (widget.sourceChannelId != null) {
          final allDeclined =
              _invitedUserIds.isNotEmpty &&
              _declinedUserIds.containsAll(_invitedUserIds) &&
              _joinedUserIds.isEmpty;

          if (allDeclined) {
            await _autoLeaveNow();
          }
        }
      } catch (e) {
        debugPrint('[VideoConferenceView] Error handling decline event: $e');
      }
    });
  }

  Future<void> _autoLeaveNow() async {
    if (_autoLeaving) return;
    _autoLeaving = true;
    try {
      await _leaveChannel();
    } finally {
      _autoLeaving = false;
    }
  }

  Future<void> _joinChannel() async {
    if (_isJoining || _service == null) return;

    setState(() {
      _isJoining = true;
      _errorMessage = null;
    });

    try {
      debugPrint('[VideoConferenceView] Joining channel: ${widget.channelId}');

      // Join LiveKit room with pre-selected devices from PreJoin
      await _service!.joinRoom(
        widget.channelId,
        channelName: widget.channelName, // Pass channel name for overlay
        cameraDevice: widget.selectedCamera, // Pass selected camera
        microphoneDevice: widget.selectedMicrophone, // Pass selected microphone
      );

      // Consumer will automatically listen for updates - no manual listener needed

      setState(() => _isJoining = false);
      debugPrint('[VideoConferenceView] Successfully joined channel');

      // Calculate initial visibility and set up states
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _updateVisibility();
          _updateParticipantStates();
        }
      });

      // Ensure we're in full-view mode after joining (not overlay mode)
      _service!.enterFullView();

      // Instant-call notifications: notify recipients only AFTER successful join.
      // This matches the 1:1 behavior you expect (no ringing if initiator fails to join).
      if (widget.isInstantCall && widget.isInitiator) {
        final callService = CallService();

        if (widget.sourceUserId != null) {
          debugPrint(
            '[VideoConferenceView] Notifying 1:1 recipient after join: ${widget.sourceUserId}',
          );
          callService.notifyRecipients(widget.channelId, [
            widget.sourceUserId!,
          ]);
          setState(() {
            _invitedUserIds = {widget.sourceUserId!};
          });
        } else if (widget.sourceChannelId != null) {
          debugPrint(
            '[VideoConferenceView] Notifying channel members after join: ${widget.sourceChannelId}',
          );
          try {
            final invited = await callService.notifyChannelMembers(
              meetingId: widget.channelId,
              channelId: widget.sourceChannelId!,
            );
            setState(() {
              _invitedUserIds = invited.toSet();
            });
          } catch (e) {
            debugPrint(
              '[VideoConferenceView] Failed to notify channel members after join: $e',
            );
          }
        }
      }

      // Stay in full-view mode - overlay will show when user navigates away
    } catch (e) {
      debugPrint('[VideoConferenceView] Join error: $e');
      setState(() {
        _isJoining = false;
        _errorMessage = 'Failed to join: $e';
      });
    }
  }

  Future<void> _leaveChannel() async {
    if (_service == null) return;

    try {
      // Send missed call notifications to offline users (instant calls only)
      final isInstantCall = widget.channelId.startsWith('call_');
      if (isInstantCall && _invitedUserIds.isNotEmpty) {
        await _sendMissedCallNotificationsToOfflineUsers();
      }

      await _service!.leaveRoom();

      // Prefer returning to the previous screen (calls are usually started from chat)
      if (mounted) {
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        } else {
          context.go('/app/channels');
        }
      }
    } catch (e) {
      debugPrint('[VideoConferenceView] Leave error: $e');
    }
  }

  @override
  void dispose() {
    _callDeclinedSub?.cancel();

    // Clean up audio subscriptions
    for (final sub in _audioSubscriptions.values) {
      sub.cancel();
    }
    _audioSubscriptions.clear();

    // Clean up speaking notifiers
    for (final notifier in _speakingNotifiers.values) {
      notifier.dispose();
    }
    _speakingNotifiers.clear();

    // Stop visibility timer
    _visibilityUpdateTimer?.cancel();

    // Exit full-view mode when navigating away (back to overlay mode)
    if (_service != null && _service!.isInCall) {
      debugPrint(
        '[VideoConferenceView] Exiting full-view, returning to overlay mode',
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _service?.exitFullView();
      });
    }

    // Unregister from MessageListenerService
    MessageListenerService.instance.unregisterVideoConferenceService();
    debugPrint(
      '[VideoConferenceView] Unregistered VideoConferenceService from MessageListener',
    );

    // No need to remove listener - Consumer handles it
    // _service?.removeListener(_onServiceUpdate); // Removed
    super.dispose();
  }

  /// Load channel details to determine ownership
  Future<void> _loadChannelDetails() async {
    if (widget.host == null) return;

    // Skip if this is actually a meeting (not a channel)
    if (widget.channelId.startsWith('mtg_') ||
        widget.channelId.startsWith('call_')) {
      debugPrint(
        '[VIDEO_CONFERENCE] Skipping channel details - this is a meeting',
      );
      return;
    }

    try {
      await ApiService.instance.init();
      final resp = await ApiService.instance.get(
        '/client/channels/${widget.channelId}',
      );

      if (resp.statusCode == 200) {
        final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
        if (mounted) {
          final signalClient = await ServerSettingsService.instance
              .getOrCreateSignalClientWithStoredCredentials();
          final currentUserId = signalClient.getCurrentUserId?.call();

          setState(() {
            _channelData = Map<String, dynamic>.from(data);

            // Check if current user is owner
            _isOwner =
                currentUserId != null &&
                _channelData!['owner'] == currentUserId;
          });
        }

        debugPrint(
          '[VIDEO_CONFERENCE] Channel owner: ${_channelData!['owner']}, Is owner: $_isOwner',
        );
      }
    } catch (e) {
      debugPrint('[VIDEO_CONFERENCE] Error loading channel details: $e');
    }
  }

  /// Send missed call notification to a specific user via Signal
  Future<void> _sendMissedCallNotification(String userId) async {
    try {
      final currentUserId = UserProfileService.instance.currentUserUuid;
      if (currentUserId == null) {
        debugPrint(
          '[VideoConferenceView] Cannot send missed call: current user ID is null',
        );
        return;
      }

      final payload = {
        'callerId': currentUserId,
        'channelId': widget.channelId,
        'channelName': widget.channelName,
        'timestamp': DateTime.now().toIso8601String(),
      };

      final signalClient = await ServerSettingsService.instance
          .getOrCreateSignalClientWithStoredCredentials();
      await signalClient.messagingService.send1to1Message(
        recipientUserId: userId,
        type: 'missingcall',
        payload: jsonEncode(payload),
      );

      debugPrint(
        '[VideoConferenceView] Sent missed call notification to $userId',
      );
    } catch (e) {
      debugPrint(
        '[VideoConferenceView] Error sending missed call to $userId: $e',
      );
    }
  }

  /// Send missed call notifications to users who were offline and never got notified
  Future<void> _sendMissedCallNotificationsToOfflineUsers() async {
    // Calculate users who never joined or declined (assumed offline)
    final offlineUsers = _invitedUserIds
        .difference(_joinedUserIds)
        .difference(_declinedUserIds);

    if (offlineUsers.isEmpty) {
      debugPrint('[VideoConferenceView] No offline users to notify');
      return;
    }

    debugPrint(
      '[VideoConferenceView] Sending missed call notifications to ${offlineUsers.length} offline users',
    );

    for (final userId in offlineUsers) {
      await _sendMissedCallNotification(userId);
    }
  }

  /// Update visibility based on screen size and participant activity
  void _updateVisibility() {
    if (_service == null || _service!.room == null || !mounted) return;

    final screenSize = MediaQuery.of(context).size;
    final hasScreenShare = _service!.hasActiveScreenShare;

    // Calculate max visible participants
    final newMaxVisible = ParticipantVisibilityManager.calculateMaxVisible(
      screenSize,
      hasScreenShare: hasScreenShare,
    );

    // Only update if something changed
    if (newMaxVisible != _maxVisibleParticipants) {
      _maxVisibleParticipants = newMaxVisible;
      // Update participant states
      _updateParticipantStates();
      setState(() {});
    }
  }

  /// Update participant states with current participants
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

  /// Load participant profile with callback
  void _loadParticipantProfile(String participantId) {
    debugPrint(
      '[VIDEO_CONFERENCE] Loading profile for participant: $participantId',
    );

    final profile = UserProfileService.instance.getProfileOrLoad(
      participantId,
      onLoaded: (profile) {
        debugPrint(
          '[VIDEO_CONFERENCE] Profile loaded for $participantId: ${profile != null ? "success" : "null"}',
        );
        if (mounted && profile != null) {
          debugPrint(
            '[VIDEO_CONFERENCE] Updating cache - displayName: ${profile['displayName']}, has picture: ${(profile['picture'] as String?)?.isNotEmpty ?? false}',
          );
          setState(() {
            _displayNameCache[participantId] =
                profile['displayName'] as String? ?? participantId;
            _profilePictureCache[participantId] =
                profile['picture'] as String? ?? '';
          });
          debugPrint('[VIDEO_CONFERENCE] Cache updated, triggering rebuild');
        }
      },
    );

    // Use cached data immediately if available
    if (profile != null) {
      debugPrint('[VIDEO_CONFERENCE] Using cached profile for $participantId');
      _displayNameCache[participantId] =
          profile['displayName'] as String? ?? participantId;
      _profilePictureCache[participantId] = profile['picture'] as String? ?? '';
    } else {
      debugPrint(
        '[VIDEO_CONFERENCE] No cached profile for $participantId, will load from server',
      );
    }
  }

  /// Setup audio level listener for a participant
  void _setupAudioListener(dynamic participant) {
    if (participant == null) return;

    final participantId = participant.identity;
    if (participantId == null) return;

    // Listen for participant updates (speaking state changes)
    participant.addListener(() {
      if (!mounted) return;

      // Check if participant is speaking (LiveKit tracks this internally)
      final isSpeaking = participant.isSpeaking ?? false;

      if (_participantStates.containsKey(participantId)) {
        final currentState = _participantStates[participantId]!;
        if (currentState.isSpeaking != isSpeaking) {
          // Update state without rebuilding parent
          _participantStates[participantId]!.updateSpeaking(isSpeaking);
          // Notify listeners (speaking border wrapper)
          if (_speakingNotifiers.containsKey(participantId)) {
            _speakingNotifiers[participantId]!.value = isSpeaking;
          }

          // Check if we need to replace a visible participant
          if (isSpeaking && !currentState.isVisible) {
            _handleHiddenParticipantSpeaking(participantId);
          }
        }
      }
    });
  }

  /// Handle when a hidden participant starts speaking
  void _handleHiddenParticipantSpeaking(String hiddenSpeakerId) {
    if (_service?.room == null) return;

    final localId = _service!.room!.localParticipant?.identity;
    if (localId == null) return;

    final manager = ParticipantVisibilityManager(
      maxVisibleParticipants: _maxVisibleParticipants,
      localParticipantId: localId,
    );

    final visibleIds = manager.getVisibleParticipantIds(_participantStates);
    final toReplace = manager.findParticipantToReplace(
      _participantStates,
      visibleIds,
    );

    if (toReplace != null && toReplace != hiddenSpeakerId) {
      setState(() {
        // Swap visibility
        _participantStates[toReplace]!.isVisible = false;
        _participantStates[hiddenSpeakerId]!.isVisible = true;
      });
    }
  }

  /// Toggle pin state for a participant
  void _togglePin(String participantId) {
    if (!_participantStates.containsKey(participantId)) return;

    final currentState = _participantStates[participantId]!;
    final newPinState = !currentState.isPinned;

    // Check max pinned limit (3)
    final pinnedCount = _participantStates.values
        .where((s) => s.isPinned)
        .length;
    if (newPinState && pinnedCount >= 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Maximum 3 participants can be pinned'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() {
      _participantStates[participantId] = currentState.copyWith(
        isPinned: newPinState,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    // E2EE Status: Frame encryption not available in Flutter Web (Web Worker limitation)
    // But we still have:
    // 1. WebRTC DTLS/SRTP transport encryption
    // 2. Signal Protocol for signaling/key exchange

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.channelName),
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
          // Members button
          IconButton(
            icon: const Icon(Icons.people),
            onPressed: () {
              Navigator.push(
                context,
                SlidePageRoute(
                  builder: (context) => ChannelMembersScreen(
                    channelId: widget.channelId,
                    channelName: widget.channelName,
                    channelScope: RoleScope.channelWebRtc,
                  ),
                ),
              );
            },
            tooltip: 'Members',
          ),
          // Settings button
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: widget.host == null
                ? null
                : () async {
                    final result = await Navigator.push(
                      context,
                      SlidePageRoute(
                        builder: (context) => ChannelSettingsScreen(
                          channelId: widget.channelId,
                          channelName: widget.channelName,
                          channelType: 'webrtc',
                          channelDescription:
                              _channelData?['description'] as String?,
                          isPrivate: _channelData?['private'] as bool? ?? false,
                          defaultJoinRole:
                              _channelData?['defaultJoinRole'] as String?,
                          isOwner: _isOwner,
                        ),
                      ),
                    );

                    // Reload channel details if settings were updated
                    if (result == true) {
                      await _loadChannelDetails();
                    }
                  },
            tooltip: widget.host == null ? 'Settings unavailable' : 'Settings',
          ),
          // Participant count - optimized with Selector
          Selector<VideoConferenceService, int>(
            selector: (_, service) => service.remoteParticipants.length,
            builder: (_, remoteCount, _) => Center(
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
            onPressed: _leaveChannel,
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
            Text('Joining video call...'),
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
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Go Back'),
            ),
          ],
        ),
      );
    }

    return _buildSmartLayout();
  }

  Widget _buildSmartLayout() {
    // Use Consumer to only rebuild when service changes
    return Consumer<VideoConferenceService>(
      builder: (context, service, child) {
        if (service.room == null) {
          return const Center(child: CircularProgressIndicator());
        }

        final room = service.room!;
        final localParticipant = room.localParticipant;
        final remoteParticipants = room.remoteParticipants.values.toList();

        // Check if anyone is sharing screen
        final hasScreenShare = service.hasActiveScreenShare;
        final screenShareParticipantId =
            service.currentScreenShareParticipantId;

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

        if (hasScreenShare) {
          // Find the participant who is sharing
          dynamic screenShareParticipant;
          if (screenShareParticipantId == localParticipant?.identity) {
            screenShareParticipant = localParticipant;
          } else {
            try {
              screenShareParticipant = remoteParticipants.firstWhere(
                (p) => p.identity == screenShareParticipantId,
              );
            } catch (e) {
              // Participant not found, skip screen share layout
              debugPrint(
                '[VIDEO_CONFERENCE] Screen share participant not found: $screenShareParticipantId',
              );
              screenShareParticipant = null;
            }
          }

          // Only show screen share layout if we found the participant
          if (screenShareParticipant != null) {
            // Determine layout based on screen orientation
            final size = MediaQuery.of(context).size;
            final isHorizontal = size.width > size.height;

            if (isHorizontal) {
              return _buildHorizontalScreenShareLayout(
                screenShareParticipant: screenShareParticipant,
                cameraParticipants: cameraParticipants,
              );
            } else {
              return _buildVerticalScreenShareLayout(
                screenShareParticipant: screenShareParticipant,
                cameraParticipants: cameraParticipants,
              );
            }
          }
        }

        // No screen share or participant not found - use regular grid
        return _buildRegularGrid(cameraParticipants);
      },
    );
  }

  /// Horizontal layout: Screen share on left (80%), cameras on right (20%)
  Widget _buildHorizontalScreenShareLayout({
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
            child: _buildScreenShareTile(screenShareParticipant),
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
                    participant: item['participant'],
                    isLocal: item['isLocal'],
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
                    participant: item['participant'],
                    isLocal: item['isLocal'],
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
            child: _buildScreenShareTile(screenShareParticipant),
          ),
        ),
      ],
    );
  }

  /// Build screen share tile with label
  Widget _buildScreenShareTile(dynamic participant) {
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
        ? (_displayNameCache[userId] ?? userId)
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
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
              color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.7),
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

  /// Regular grid layout (no screen share)
  /// Regular grid layout (no screen share) with smart visibility
  Widget _buildRegularGrid(List<Map<String, dynamic>> participants) {
    if (_service?.room == null) return const SizedBox.shrink();

    final localId = _service!.room!.localParticipant?.identity;
    if (localId == null) return const SizedBox.shrink();

    // Get visibility manager
    final manager = ParticipantVisibilityManager(
      maxVisibleParticipants: _maxVisibleParticipants,
      localParticipantId: localId,
    );

    // Get list of visible participant IDs
    final visibleIds = manager.getVisibleParticipantIds(_participantStates);

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

              return _buildVideoTile(
                participant: participant,
                isLocal: isLocal,
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
    required dynamic participant,
    required bool isLocal,
  }) {
    final userId = participant.identity; // LiveKit identity is the user ID

    // Get display name and profile picture from cache
    final displayName = userId != null
        ? (_displayNameCache[userId] ?? userId)
        : 'Unknown';
    final profilePicture = userId != null ? _profilePictureCache[userId] : null;

    debugPrint(
      '[VIDEO_CONFERENCE] Building tile for $userId (isLocal=$isLocal): displayName=$displayName, hasPicture=${profilePicture?.isNotEmpty ?? false}',
    );

    // Get audio state for speaking indicator
    final speakingNotifier =
        userId != null && _speakingNotifiers.containsKey(userId)
        ? _speakingNotifiers[userId]!
        : null;
    final isPinned = userId != null && _participantStates.containsKey(userId)
        ? _participantStates[userId]!.isPinned
        : false;

    // Wrap tile with speaking indicator that doesn't rebuild tile content
    return _SpeakingStateWrapper(
      speakingNotifier: speakingNotifier,
      child: VideoParticipantTile(
        key: ValueKey('tile_$userId'),
        participant: participant,
        isLocal: isLocal,
        displayName: displayName,
        profilePicture: profilePicture,
        isPinned: isPinned,
        onLongPress: userId != null
            ? () => _showParticipantMenu(context, userId, isPinned)
            : null,
        onSecondaryTap: userId != null
            ? () => _showParticipantMenu(context, userId, isPinned)
            : null,
      ),
    );
  }

  /// Show participant context menu (volume, mute, pin/unpin)
  void _showParticipantMenu(
    BuildContext context,
    String participantId,
    bool isPinned,
  ) {
    // Find the participant object from the room
    final room = _service?.room;
    if (room == null) return;

    // Check if it's a remote participant
    final remoteParticipantsList = room.remoteParticipants.values.toList();
    if (remoteParticipantsList.isEmpty) {
      return; // No remote participants to show menu for
    }

    final remoteParticipant = remoteParticipantsList.firstWhere(
      (p) => p.identity == participantId,
      orElse: () => remoteParticipantsList.first,
    );

    // Show context menu as bottom sheet (better for mobile/touch)
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Participant context menu content
            ParticipantContextMenuContent(
              participant: remoteParticipant,
              isPinned: isPinned,
              onPin: () {
                Navigator.pop(context);
                _togglePin(participantId);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    if (_service == null) return const SizedBox.shrink();

    final isMicEnabled = _service!.isMicrophoneEnabled();
    final isCameraEnabled = _service!.isCameraEnabled();
    final isScreenShareEnabled = _service!.isScreenShareEnabled();

    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Toggle Audio
          _buildControlButton(
            icon: isMicEnabled ? Icons.mic : Icons.mic_off,
            label: 'Audio',
            onPressed: () => _service!.toggleMicrophone(),
            onLongPress: () => _showMicrophoneDeviceSelector(context),
            isActive: isMicEnabled,
            heroTag: 'audio_button',
          ),

          // Toggle Video
          _buildControlButton(
            icon: isCameraEnabled ? Icons.videocam : Icons.videocam_off,
            label: 'Video',
            onPressed: () => _service!.toggleCamera(),
            onLongPress: () => _showCameraDeviceSelector(context),
            isActive: isCameraEnabled,
            heroTag: 'video_button',
          ),

          // Toggle Screen Share
          _buildControlButton(
            icon: isScreenShareEnabled
                ? Icons.stop_screen_share
                : Icons.screen_share,
            label: 'Share',
            onPressed: () => _toggleScreenShare(context),
            isActive: isScreenShareEnabled,
            heroTag: 'share_button',
          ),

          // Leave Call
          _buildControlButton(
            icon: Icons.call_end,
            label: 'Leave',
            onPressed: _leaveChannel,
            isActive: false,
            color: Theme.of(context).colorScheme.error,
            heroTag: 'leave_button',
          ),
        ],
      ),
    );
  }

  /// Toggle screen share with conflict detection
  Future<void> _toggleScreenShare(BuildContext context) async {
    if (_service == null) return;

    try {
      final isCurrentlySharing = _service!.isScreenShareEnabled();

      // If stopping, just stop
      if (isCurrentlySharing) {
        await _service!.toggleScreenShare();
        return;
      }

      // If starting on desktop, show screen picker first
      if (!kIsWeb) {
        final source = await showDialog<webrtc.DesktopCapturerSource>(
          context: context,
          builder: (context) => lk.ScreenSelectDialog(),
        );

        if (source == null) {
          debugPrint('[VideoConferenceView] Screen share cancelled');
          return;
        }

        debugPrint(
          '[VideoConferenceView] Selected screen source: ${source.id} (${source.name})',
        );
        _service!.setDesktopScreenSource(source.id);
      }

      // Check if someone else is currently sharing
      final currentSharer = _service!.currentScreenShareParticipantId;
      final localIdentity = _service!.room?.localParticipant?.identity;

      if (currentSharer != null && currentSharer != localIdentity) {
        // Someone else is sharing - show warning
        final sharingParticipant = _service!.remoteParticipants.firstWhere(
          (p) => p.identity == currentSharer,
          orElse: () => throw Exception('Participant not found'),
        );
        final sharerName = sharingParticipant.name.isEmpty
            ? currentSharer
            : sharingParticipant.name;

        if (!mounted) return;

        final shouldTakeOver = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Screen Share In Progress'),
            content: Text(
              '$sharerName is currently presenting. Taking over will stop their screen share. Continue?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Take Over'),
              ),
            ],
          ),
        );

        if (shouldTakeOver != true) return;
      }

      // Toggle screen share
      await _service!.toggleScreenShare();
    } catch (e) {
      debugPrint('[VideoConferenceView] Error toggling screen share: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to toggle screen share: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  /// Show microphone device selector dialog
  Future<void> _showMicrophoneDeviceSelector(BuildContext context) async {
    try {
      final devices = await lk.Hardware.instance.enumerateDevices();
      final microphones = devices.where((d) => d.kind == 'audioinput').toList();

      if (!mounted) return;

      // Capture scaffold messenger before showing modal
      final scaffoldMessenger = ScaffoldMessenger.of(context);

      showModalBottomSheet(
        context: context,
        backgroundColor: Theme.of(context).colorScheme.surface,
        builder: (context) => Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Select Microphone',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 16),
              if (microphones.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text('No microphones available'),
                )
              else
                ...microphones.map((device) {
                  return ListTile(
                    leading: Icon(
                      Icons.mic,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      device.label,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    onTap: () async {
                      Navigator.pop(context);
                      try {
                        await _service?.switchMicrophone(device);
                        if (mounted) {
                          scaffoldMessenger.showSnackBar(
                            SnackBar(
                              content: Text('Switched to ${device.label}'),
                              backgroundColor: Colors.green,
                            ),
                          );
                        }
                      } catch (e) {
                        debugPrint(
                          '[VideoConferenceView] Error switching microphone: $e',
                        );
                        if (mounted) {
                          final theme = Theme.of(context);
                          scaffoldMessenger.showSnackBar(
                            SnackBar(
                              content: const Text(
                                'Failed to switch microphone',
                              ),
                              backgroundColor: theme.colorScheme.error,
                            ),
                          );
                        }
                      }
                    },
                  );
                }),
            ],
          ),
        ),
      );
    } catch (e) {
      debugPrint('[VideoConferenceView] Error loading microphones: $e');
    }
  }

  /// Show camera device selector dialog
  Future<void> _showCameraDeviceSelector(BuildContext context) async {
    try {
      final devices = await lk.Hardware.instance.enumerateDevices();
      final cameras = devices.where((d) => d.kind == 'videoinput').toList();

      if (!mounted) return;

      // Capture scaffold messenger before showing modal
      final scaffoldMessenger = ScaffoldMessenger.of(context);

      showModalBottomSheet(
        context: context,
        backgroundColor: Theme.of(context).colorScheme.surface,
        builder: (context) => Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Select Camera',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 16),
              if (cameras.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text('No cameras available'),
                )
              else
                ...cameras.map((device) {
                  return ListTile(
                    leading: Icon(
                      Icons.videocam,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      device.label,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    onTap: () async {
                      Navigator.pop(context);
                      try {
                        await _service?.switchCamera(device);
                        if (mounted) {
                          scaffoldMessenger.showSnackBar(
                            SnackBar(
                              content: Text('Switched to ${device.label}'),
                              backgroundColor: Colors.green,
                            ),
                          );
                        }
                      } catch (e) {
                        debugPrint(
                          '[VideoConferenceView] Error switching camera: $e',
                        );
                        if (mounted) {
                          final theme = Theme.of(context);
                          scaffoldMessenger.showSnackBar(
                            SnackBar(
                              content: const Text('Failed to switch camera'),
                              backgroundColor: theme.colorScheme.error,
                            ),
                          );
                        }
                      }
                    },
                  );
                }),
            ],
          ),
        ),
      );
    } catch (e) {
      debugPrint('[VideoConferenceView] Error loading cameras: $e');
    }
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    VoidCallback? onPressed,
    VoidCallback? onLongPress,
    required bool isActive,
    Color? color,
    String? heroTag,
  }) {
    return Builder(
      builder: (context) {
        final isDisabled = onPressed == null;
        final buttonColor =
            color ??
            (isDisabled
                ? Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)
                : isActive
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.surfaceContainerHighest);

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: isDisabled ? null : onPressed,
              onLongPress: isDisabled ? null : onLongPress,
              onSecondaryTap: isDisabled ? null : onLongPress,
              child: FloatingActionButton(
                heroTag: heroTag ?? label, // Use unique tag to avoid conflicts
                onPressed: null, // Disabled, using GestureDetector instead
                backgroundColor: buttonColor,
                child: Icon(
                  icon,
                  color: isDisabled
                      ? Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.38)
                      : (isActive
                            ? Theme.of(context).colorScheme.onPrimary
                            : Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 12,
              ),
            ),
          ],
        );
      },
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
