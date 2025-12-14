import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'dart:async';
import 'dart:convert';
import '../services/video_conference_service.dart';
import '../services/api_service.dart';
import '../services/message_listener_service.dart';
import '../services/user_profile_service.dart';
import '../services/meeting_service.dart';
import '../services/socket_service.dart' if (dart.library.io) '../services/socket_service_native.dart';
import '../services/external_participant_service.dart';
import '../services/signal_service.dart';
import '../widgets/video_grid_layout.dart';
import '../widgets/video_controls_bar.dart';
import '../widgets/admission_overlay.dart';
import '../models/participant_audio_state.dart';
import '../extensions/snackbar_extensions.dart';

/// Video conference view for meetings (authenticated users only)
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
  
  // Pending participants (invited but not yet joined)
  final List<Map<String, dynamic>> _pendingParticipants = [];

  @override
  void initState() {
    super.initState();

    // Start periodic visibility updates
    _visibilityUpdateTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _updateVisibility(),
    );

    // Listen for guest E2EE key requests via Signal Protocol Socket.IO events
    _setupGuestE2EEKeyRequestSocketListener();
  }

  /// Set up Socket.IO listener for guest E2EE key requests (via Signal Protocol)
  /// Guests request LiveKit E2EE key via Socket.IO (since they don't have userId for standard Signal routing)
  void _setupGuestE2EEKeyRequestSocketListener() {
    SocketService().socket?.on('guest:meeting_e2ee_key_request', (data) async {
      try {
        debugPrint('[MeetingVideo] 🔐 Received E2EE key request from guest via Socket.IO');
        
        // Validate data structure
        if (data is! Map) {
          debugPrint('[MeetingVideo] ⚠️ Invalid request data format');
          return;
        }
        
        final Map<String, dynamic> requestData = Map<String, dynamic>.from(data);
        final guestSessionId = requestData['guest_session_id'] as String?;
        final meetingId = requestData['meeting_id'] as String?;
        
        if (guestSessionId == null || meetingId == null || meetingId != widget.meetingId) {
          debugPrint('[MeetingVideo] ⚠️ Missing session ID or wrong meeting');
          return;
        }
        
        debugPrint('[MeetingVideo] Guest $guestSessionId requesting E2EE key for meeting $meetingId');
        
        // Get the VideoConferenceService instance
        if (_service == null || _service!.channelSharedKey == null) {
          debugPrint('[MeetingVideo] ⚠️ No E2EE key available to share with guest');
          return;
        }
        
        debugPrint('[MeetingVideo] ✓ Responding to guest with encrypted LiveKit E2EE key...');
        
        // Send encrypted response via Signal Protocol
        // SignalService will encrypt the LiveKit key and send it to the guest
        await SignalService.instance.sendItemToGuest(
          meetingId: meetingId,
          guestSessionId: guestSessionId,
          type: 'meeting_e2ee_key_response',
          payload: {
            'meetingId': meetingId,
            'encryptedKey': base64.encode(_service!.channelSharedKey!),
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          },
        );
        
        debugPrint('[MeetingVideo] ✓ Sent encrypted LiveKit E2EE key to guest $guestSessionId');
      } catch (e, stack) {
        debugPrint('[MeetingVideo] ✗ Error handling guest E2EE key request: $e');
        debugPrint('[MeetingVideo] Stack trace: $stack');
      }
    });
    debugPrint('[MeetingVideo] ✓ Registered Socket.IO listener for guest:meeting_e2ee_key_request');
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

      // Initialize external participant service listeners for admission overlay
      ExternalParticipantService().initializeListeners();

      // Join socket room for meeting events (admission notifications, guest E2EE requests, etc.)
      debugPrint('[MeetingVideo] Attempting to join socket room: meeting:${widget.meetingId}');
      debugPrint('[MeetingVideo] Socket connected: ${SocketService().isConnected}');
      
      if (!SocketService().isConnected) {
        debugPrint('[MeetingVideo] ⚠️ Socket not connected, waiting...');
        // Wait a bit for socket to connect
        await Future.delayed(const Duration(seconds: 1));
      }
      
      SocketService().emit('meeting:join-room', {
        'meeting_id': widget.meetingId,
      });
      debugPrint('[MeetingVideo] ✓ Emitted meeting:join-room event');

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
      // Leave Socket.IO meeting room before leaving LiveKit
      debugPrint('[MeetingVideo] Leaving socket room: meeting:${widget.meetingId}');
      SocketService().emit('meeting:leave-room', {
        'meeting_id': widget.meetingId,
      });
      
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
    // Remove Socket.IO listener for guest E2EE requests
    SocketService().socket?.off('guest:meeting_e2ee_key_request');
    debugPrint('[MeetingVideo] ✓ Removed Socket.IO listener for guest:meeting_e2ee_key_request');
    
    // SECURITY: Clear guest Signal sessions when meeting ends
    // This prevents session keys from persisting in sessionStorage
    SignalService.instance.clearGuestSessions(widget.meetingId);
    debugPrint('[MeetingVideo] ✓ Cleared guest Signal sessions for security');
    
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

  Future<void> _showAddParticipantsDialog() async {
    final TextEditingController searchController = TextEditingController();
    List<Map<String, dynamic>> searchResults = [];
    bool isSearching = false;
    bool isValidEmail = false;
    String emailAddress = '';

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          bool _isValidEmail(String email) {
            final emailRegex = RegExp(
              r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
            );
            return emailRegex.hasMatch(email);
          }

          Future<void> searchUsers(String query) async {
            // Check if it's a valid email
            final isEmail = _isValidEmail(query);
            
            if (query.length < 2) {
              setDialogState(() {
                searchResults = [];
                isSearching = false;
                isValidEmail = false;
                emailAddress = '';
              });
              return;
            }

            setDialogState(() {
              isSearching = true;
              isValidEmail = isEmail;
              emailAddress = isEmail ? query : '';
            });

            try {
              final response = await ApiService.get('/people/list');
              if (response.statusCode == 200) {
                final users = response.data is List ? response.data as List : [];
                final results = <Map<String, dynamic>>[];

                for (final user in users) {
                  final displayName = user['displayName'] ?? '';
                  final atName = user['atName'] ?? '';
                  final email = user['email'] ?? '';
                  final uuid = user['uuid'] ?? '';

                  if (displayName.toLowerCase().contains(query.toLowerCase()) ||
                      atName.toLowerCase().contains(query.toLowerCase()) ||
                      email.toLowerCase().contains(query.toLowerCase())) {
                    results.add({
                      'uuid': uuid,
                      'displayName': displayName,
                      'atName': atName,
                      'email': email,
                      'picture': user['picture'],
                      'isOnline': user['isOnline'] ?? false,
                    });
                  }
                }

                setDialogState(() {
                  searchResults = results;
                  isSearching = false;
                });
              }
            } catch (e) {
              debugPrint('[AddParticipants] Search error: $e');
              setDialogState(() => isSearching = false);
            }
          }

          Future<void> sendEmailInvitation(String email) async {
            try {
              await ApiService.post(
                '/api/meetings/${widget.meetingId}/invite-email',
                data: {'email': email},
              );
              if (mounted) {
                context.showSuccessSnackBar(
                  'Invitation sent to $email',
                );
                Navigator.of(context).pop();
              }
            } catch (e) {
              debugPrint('[AddParticipants] Error sending invitation: $e');
              if (mounted) {
                context.showErrorSnackBar('Failed to send invitation');
              }
            }
          }

          Future<void> addParticipant(Map<String, dynamic> user) async {
            try {
              await MeetingService().addParticipant(
                widget.meetingId,
                user['uuid'] as String,
              );
              
              // Add to pending participants list if user is online
              if (user['isOnline'] == true) {
                setState(() {
                  _pendingParticipants.add({
                    'uuid': user['uuid'],
                    'displayName': user['displayName'],
                    'picture': user['picture'],
                  });
                });
                // TODO: Emit socket event to notify the user
                debugPrint('[AddParticipants] Sending call notification to online user: ${user['uuid']}');
              }
              
              if (mounted) {
                context.showSuccessSnackBar(
                  '${user['displayName']} added to meeting',
                );
                Navigator.of(context).pop();
              }
            } catch (e) {
              debugPrint('[AddParticipants] Error adding participant: $e');
              if (mounted) {
                context.showErrorSnackBar('Failed to add participant');
              }
            }
          }

          return AlertDialog(
            title: const Text('Add Participants'),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: searchController,
                    decoration: const InputDecoration(
                      labelText: 'Search by name, @name, or email',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: searchUsers,
                  ),
                  const SizedBox(height: 16),
                  if (isSearching)
                    const Center(child: CircularProgressIndicator())
                  else if (isValidEmail && emailAddress.isNotEmpty)
                    // Show email invitation option
                    SizedBox(
                      height: 300,
                      child: Column(
                        children: [
                          ListTile(
                            leading: CircleAvatar(
                              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                              child: Icon(
                                Icons.email,
                                color: Theme.of(context).colorScheme.onPrimaryContainer,
                              ),
                            ),
                            title: Text(emailAddress),
                            subtitle: const Text('Send email invitation'),
                            trailing: IconButton(
                              icon: const Icon(Icons.add),
                              onPressed: () => sendEmailInvitation(emailAddress),
                            ),
                          ),
                          if (searchResults.isNotEmpty) ...[
                            const Divider(),
                            const Padding(
                              padding: EdgeInsets.all(8.0),
                              child: Text(
                                'Or select from users:',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                            Expanded(
                              child: ListView.builder(
                                shrinkWrap: true,
                                itemCount: searchResults.length,
                                itemBuilder: (context, index) {
                                  final user = searchResults[index];
                                  final isOnline = user['isOnline'] == true;
                                  return ListTile(
                                    leading: Stack(
                                      children: [
                                        CircleAvatar(
                                          child: Text(
                                            (user['displayName'] as String)
                                                .substring(0, 1)
                                                .toUpperCase(),
                                          ),
                                        ),
                                        if (isOnline)
                                          Positioned(
                                            right: 0,
                                            bottom: 0,
                                            child: Container(
                                              width: 12,
                                              height: 12,
                                              decoration: BoxDecoration(
                                                color: Colors.green,
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: Theme.of(context).colorScheme.surface,
                                                  width: 2,
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                    title: Text(user['displayName'] as String),
                                    subtitle: Text(
                                      user['atName'] as String? ?? 
                                      user['email'] as String? ?? '',
                                    ),
                                    trailing: IconButton(
                                      icon: const Icon(Icons.add),
                                      onPressed: () => addParticipant(user),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ],
                      ),
                    )
                  else if (searchResults.isNotEmpty)
                    SizedBox(
                      height: 300,
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: searchResults.length,
                        itemBuilder: (context, index) {
                          final user = searchResults[index];
                          final isOnline = user['isOnline'] == true;
                          return ListTile(
                            leading: Stack(
                              children: [
                                CircleAvatar(
                                  child: Text(
                                    (user['displayName'] as String)
                                        .substring(0, 1)
                                        .toUpperCase(),
                                  ),
                                ),
                                if (isOnline)
                                  Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      width: 12,
                                      height: 12,
                                      decoration: BoxDecoration(
                                        color: Colors.green,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: Theme.of(context).colorScheme.surface,
                                          width: 2,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            title: Text(user['displayName'] as String),
                            subtitle: Text(
                              user['atName'] as String? ?? 
                              user['email'] as String? ?? '',
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.add),
                              onPressed: () => addParticipant(user),
                            ),
                          );
                        },
                      ),
                    )
                  else if (searchController.text.length >= 2)
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('No users found'),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('Enter at least 2 characters to search'),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
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
          // Add participants button
          IconButton(
            icon: const Icon(Icons.person_add),
            onPressed: _showAddParticipantsDialog,
            tooltip: 'Add Participants',
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
        return Stack(
          children: [
            VideoGridLayout(
              room: service.room,
              hasScreenShare: service.hasActiveScreenShare,
              screenShareParticipantId: service.currentScreenShareParticipantId,
              participantStates: _participantStates,
              speakingNotifiers: _speakingNotifiers,
              displayNameCache: _displayNameCache,
              profilePictureCache: _profilePictureCache,
              maxVisibleParticipants: _maxVisibleParticipants,
              pendingParticipants: _pendingParticipants,
            ),
            // Admission overlay for waiting guests
            AdmissionOverlay(meetingId: widget.meetingId),
          ],
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
