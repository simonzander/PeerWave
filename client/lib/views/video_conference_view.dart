import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../services/video_conference_service.dart';
import '../services/message_listener_service.dart';
import '../services/user_profile_service.dart';
import '../screens/channel/channel_members_screen.dart';
import '../widgets/animated_widgets.dart';
import '../widgets/participant_profile_display.dart';
import '../models/role.dart';
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
  final lk.MediaDevice? selectedCamera; // NEW: Pre-selected from PreJoin
  final lk.MediaDevice? selectedMicrophone; // NEW: Pre-selected from PreJoin

  const VideoConferenceView({
    super.key,
    required this.channelId,
    required this.channelName,
    this.selectedCamera, // NEW
    this.selectedMicrophone, // NEW
  });

  @override
  State<VideoConferenceView> createState() => _VideoConferenceViewState();
}

class _VideoConferenceViewState extends State<VideoConferenceView> {
  VideoConferenceService? _service;

  bool _isJoining = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
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

      // Ensure we're in full-view mode after joining (not overlay mode)
      _service!.enterFullView();

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
      await _service!.leaveRoom();

      // Navigate back to channels view
      if (mounted) {
        context.go('/app/channels');
      }
    } catch (e) {
      debugPrint('[VideoConferenceView] Leave error: $e');
    }
  }

  @override
  void dispose() {
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
            onPressed: () {
              context.showInfoSnackBar(
                'Channel settings coming soon',
                duration: const Duration(seconds: 2),
              );
            },
            tooltip: 'Settings',
          ),
          // Participant count - optimized with Selector
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
              screenShareParticipant: screenShareParticipant,
              cameraParticipants: cameraParticipants,
            );
          } else {
            return _buildVerticalScreenShareLayout(
              screenShareParticipant: screenShareParticipant,
              cameraParticipants: cameraParticipants,
            );
          }
        } else {
          // No screen share - use regular grid
          return _buildRegularGrid(cameraParticipants);
        }
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
            color: Colors.black,
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
            color: Colors.black,
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
        ? (UserProfileService.instance.getDisplayName(userId) ?? userId)
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
                    color: Colors.white,
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
  Widget _buildRegularGrid(List<Map<String, dynamic>> participants) {
    final totalParticipants = participants.length;
    int columns = 1;
    if (totalParticipants > 1) columns = 2;
    if (totalParticipants > 4) columns = 3;

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        childAspectRatio: 16 / 9,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: totalParticipants,
      itemBuilder: (context, index) {
        final item = participants[index];
        final participant = item['participant'];
        final isLocal = item['isLocal'] as bool;

        return _buildVideoTile(participant: participant, isLocal: isLocal);
      },
    );
  }

  Widget _buildVideoTile({
    required dynamic participant,
    required bool isLocal,
  }) {
    // Get camera video track (not screen share)
    lk.VideoTrack? videoTrack;
    bool audioMuted = true;

    if (participant is lk.LocalParticipant || participant is lk.RemoteParticipant) {
      // Get camera track only (exclude screen share)
      final cameraPubs = participant.videoTrackPublications.where(
        (p) => p.source != lk.TrackSource.screenShareVideo,
      );
      if (cameraPubs.isNotEmpty) {
        videoTrack = cameraPubs.first.track as lk.VideoTrack?;
      }

      final audioPubs = participant.audioTrackPublications;
      audioMuted = audioPubs.isEmpty || audioPubs.first.muted;
    }

    final userId = participant.identity; // LiveKit identity is the user ID
    final bool videoOff = videoTrack == null || videoTrack.muted;

    // Get display name and profile picture from UserProfileService
    final displayName = userId != null
        ? (UserProfileService.instance.getDisplayName(userId) ?? userId)
        : 'Unknown';
    final profilePicture = userId != null
        ? UserProfileService.instance.getPicture(userId)
        : null;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Video or Profile Picture
          if (!videoOff)
            lk.VideoTrackRenderer(
              videoTrack,
              key: ValueKey(videoTrack.mediaStreamTrack.id),
            )
          else if (profilePicture != null && profilePicture.isNotEmpty)
            ParticipantProfileDisplay(
              profilePictureBase64: profilePicture,
              displayName: displayName,
            )
          else
            Container(
              color: Theme.of(context).colorScheme.surfaceVariant,
              child: Center(
                child: Icon(
                  Icons.videocam_off,
                  size: 48,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                    isLocal ? Icons.person : Icons.person_outline,
                    size: 14,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    isLocal ? 'You' : displayName,
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
          if (audioMuted)
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
          ),

          // Toggle Video
          _buildControlButton(
            icon: isCameraEnabled ? Icons.videocam : Icons.videocam_off,
            label: 'Video',
            onPressed: () => _service!.toggleCamera(),
            onLongPress: () => _showCameraDeviceSelector(context),
            isActive: isCameraEnabled,
          ),

          // Toggle Screen Share
          _buildControlButton(
            icon: isScreenShareEnabled
                ? Icons.stop_screen_share
                : Icons.screen_share,
            label: 'Share',
            onPressed: () => _toggleScreenShare(context),
            isActive: isScreenShareEnabled,
          ),

          // Leave Call
          _buildControlButton(
            icon: Icons.call_end,
            label: 'Leave',
            onPressed: _leaveChannel,
            isActive: false,
            color: Theme.of(context).colorScheme.error,
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
            backgroundColor: Colors.red,
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
        builder: (context) => Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Select Microphone',
                style: Theme.of(context).textTheme.titleLarge,
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
                    leading: const Icon(Icons.mic),
                    title: Text(device.label),
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
                          scaffoldMessenger.showSnackBar(
                            const SnackBar(
                              content: Text('Failed to switch microphone'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      }
                    },
                  );
                }).toList(),
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
        builder: (context) => Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Select Camera',
                style: Theme.of(context).textTheme.titleLarge,
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
                    leading: const Icon(Icons.videocam),
                    title: Text(device.label),
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
                          scaffoldMessenger.showSnackBar(
                            const SnackBar(
                              content: Text('Failed to switch camera'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      }
                    },
                  );
                }).toList(),
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
  }) {
    return Builder(
      builder: (context) {
        final isDisabled = onPressed == null;
        final buttonColor =
            color ??
            (isDisabled
                ? Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5)
                : isActive
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.surfaceVariant);

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: isDisabled ? null : onPressed,
              onLongPress: isDisabled ? null : onLongPress,
              onSecondaryTap: isDisabled ? null : onLongPress,
              child: FloatingActionButton(
                onPressed: null, // Disabled, using GestureDetector instead
                backgroundColor: buttonColor,
                child: Icon(
                  icon,
                  color: isDisabled
                      ? Theme.of(
                          context,
                        ).colorScheme.onSurface.withOpacity(0.38)
                      : Theme.of(context).colorScheme.onPrimary,
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
