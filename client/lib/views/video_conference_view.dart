import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:provider/provider.dart';
import '../services/video_conference_service.dart';
import '../services/message_listener_service.dart';
import '../screens/channel/channel_members_screen.dart';
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
  final MediaDevice? selectedCamera;        // NEW: Pre-selected from PreJoin
  final MediaDevice? selectedMicrophone;    // NEW: Pre-selected from PreJoin
  
  const VideoConferenceView({
    super.key,
    required this.channelId,
    required this.channelName,
    this.selectedCamera,        // NEW
    this.selectedMicrophone,    // NEW
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
        MessageListenerService.instance.registerVideoConferenceService(_service!);
        debugPrint('[VideoConferenceView] Registered VideoConferenceService with MessageListener');
        
        // Schedule join for after build completes
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
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
        cameraDevice: widget.selectedCamera,        // Pass selected camera
        microphoneDevice: widget.selectedMicrophone, // Pass selected microphone
      );
      
      // Consumer will automatically listen for updates - no manual listener needed
      
      setState(() => _isJoining = false);
      debugPrint('[VideoConferenceView] Successfully joined channel');
      
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
      
      // Go back
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      debugPrint('[VideoConferenceView] Leave error: $e');
    }
  }
  
  @override
  void dispose() {
    // Unregister from MessageListenerService
    MessageListenerService.instance.unregisterVideoConferenceService();
    debugPrint('[VideoConferenceView] Unregistered VideoConferenceService from MessageListener');
    
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
                  'DTLS/SRTP Encrypted',
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
                MaterialPageRoute(
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
            Icon(Icons.error_outline, size: 64, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            Text(_errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Go Back'),
            ),
          ],
        ),
      );
    }
    
    return _buildVideoGrid();
  }
  
  Widget _buildVideoGrid() {
    // Use Consumer to only rebuild when service changes
    return Consumer<VideoConferenceService>(
      builder: (context, service, child) {
        if (service.room == null) {
          return const Center(child: CircularProgressIndicator());
        }
        
        final room = service.room!;
        final localParticipant = room.localParticipant;
        final remoteParticipants = service.remoteParticipants;
        
        debugPrint('[VideoConferenceView] Building video grid:');
        debugPrint('[VideoConferenceView]   - Local participant: ${localParticipant?.identity}');
        debugPrint('[VideoConferenceView]   - Remote participants: ${remoteParticipants.length}');
        for (final remote in remoteParticipants) {
          debugPrint('[VideoConferenceView]     - ${remote.identity}');
          debugPrint('[VideoConferenceView]       Video tracks: ${remote.videoTrackPublications.length}');
          debugPrint('[VideoConferenceView]       Audio tracks: ${remote.audioTrackPublications.length}');
        }
        
        // Build participant list
        final List<dynamic> participants = [];
        if (localParticipant != null) {
          participants.add({'participant': localParticipant, 'isLocal': true});
        }
        for (final remote in remoteParticipants) {
          participants.add({'participant': remote, 'isLocal': false});
        }
        
        debugPrint('[VideoConferenceView] Total participants to render: ${participants.length}');
        
        // Calculate grid dimensions
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
            
            return _buildVideoTile(
              participant: participant,
              isLocal: isLocal,
            );
          },
        );
      },
    );
  }
  
  Widget _buildVideoTile({
    required dynamic participant,
    required bool isLocal,
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
    
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Video
          if (videoTrack != null && !videoTrack.muted)
            VideoTrackRenderer(
              videoTrack,
            )
          else
            Container(
              color: Theme.of(context).colorScheme.surfaceVariant,
              child: Center(
                child: Icon(Icons.videocam_off, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                    isLocal ? 'You' : identity,
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
              child: Icon(Icons.mic_off, color: Theme.of(context).colorScheme.error, size: 24),
            ),
        ],
      ),
    );
  }
  
  Widget _buildControls() {
    if (_service == null) return const SizedBox.shrink();
    
    final isMicEnabled = _service!.isMicrophoneEnabled();
    final isCameraEnabled = _service!.isCameraEnabled();
    
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
            isActive: isMicEnabled,
          ),
          
          // Toggle Video
          _buildControlButton(
            icon: isCameraEnabled ? Icons.videocam : Icons.videocam_off,
            label: 'Video',
            onPressed: () => _service!.toggleCamera(),
            isActive: isCameraEnabled,
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
  
  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    required bool isActive,
    Color? color,
  }) {
    return Builder(
      builder: (context) {
        final buttonColor = color ?? (isActive ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.surfaceVariant);
        
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FloatingActionButton(
              onPressed: onPressed,
              backgroundColor: buttonColor,
              child: Icon(icon, color: Theme.of(context).colorScheme.onPrimary),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 12),
            ),
          ],
        );
      },
    );
  }
}
