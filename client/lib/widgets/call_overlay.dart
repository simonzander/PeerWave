import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:livekit_client/livekit_client.dart';
import '../services/video_conference_service.dart';

/// Draggable video overlay that shows active call
/// Can be minimized, maximized, and closed
class CallOverlay extends StatefulWidget {
  const CallOverlay({Key? key}) : super(key: key);
  
  @override
  State<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends State<CallOverlay> {
  bool _isMinimized = false;
  double? _dragStartX;
  double? _dragStartY;
  
  @override
  Widget build(BuildContext context) {
    return Consumer<VideoConferenceService>(
      builder: (context, service, _) {
        // Hide overlay if: not in call, overlay hidden, OR in full-view mode
        if (!service.isInCall || !service.isOverlayVisible || service.isInFullView) {
          return const SizedBox.shrink();
        }
        
        final screenSize = MediaQuery.of(context).size;
        final overlayWidth = _isMinimized ? 240.0 : 320.0;
        final overlayHeight = _isMinimized ? 135.0 : 180.0;
        
        // Use drag positions if actively dragging, otherwise use service positions
        final x = (_dragStartX ?? service.overlayPositionX).clamp(0.0, screenSize.width - overlayWidth);
        final y = (_dragStartY ?? service.overlayPositionY).clamp(0.0, screenSize.height - overlayHeight);
        
        return Positioned(
          left: x,
          top: y,
          child: GestureDetector(
            onPanStart: (details) {
              _dragStartX = x;
              _dragStartY = y;
            },
            onPanUpdate: (details) {
              // Update local position for smooth dragging
              setState(() {
                _dragStartX = (_dragStartX! + details.delta.dx).clamp(0.0, screenSize.width - overlayWidth);
                _dragStartY = (_dragStartY! + details.delta.dy).clamp(0.0, screenSize.height - overlayHeight);
              });
            },
            onPanEnd: (details) {
              // Only update service position when drag ends (persistence + performance)
              if (_dragStartX != null && _dragStartY != null) {
                service.updateOverlayPosition(_dragStartX!, _dragStartY!);
              }
            },
            child: _buildOverlayContent(service, overlayWidth, overlayHeight),
          ),
        );
      },
    );
  }
  
  Widget _buildOverlayContent(VideoConferenceService service, double width, double height) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 10,
            spreadRadius: 2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            // Video Grid
            _buildVideoGrid(service),
            
            // Controls overlay
            Positioned(
              top: 4,
              right: 4,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Minimize/Maximize
                  _buildIconButton(
                    icon: _isMinimized ? Icons.open_in_full : Icons.close_fullscreen,
                    onPressed: () {
                      setState(() {
                        _isMinimized = !_isMinimized;
                      });
                    },
                  ),
                  const SizedBox(width: 4),
                  
                  // Close overlay - TopBar remains visible with "Show Overlay" button
                  _buildIconButton(
                    icon: Icons.close,
                    onPressed: () => service.hideOverlay(),
                  ),
                ],
              ),
            ),
            
            // Draggable hint
            Positioned(
              top: 4,
              left: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.drag_indicator,
                      size: 16,
                      color: Colors.white.withOpacity(0.7),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      service.channelName ?? 'Video Call',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.9),
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildVideoGrid(VideoConferenceService service) {
    if (service.room == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    
    final room = service.room!;
    final localParticipant = room.localParticipant;
    final remoteParticipants = service.remoteParticipants;
    
    // Build participant list (max 4 visible)
    final List<dynamic> participants = [];
    if (localParticipant != null) {
      participants.add({'participant': localParticipant, 'isLocal': true});
    }
    
    // Add remote participants (limit to 3 more for total of 4)
    final maxRemote = _isMinimized ? 0 : 3;
    for (var i = 0; i < remoteParticipants.length && i < maxRemote; i++) {
      participants.add({'participant': remoteParticipants[i], 'isLocal': false});
    }
    
    if (participants.isEmpty) {
      return Center(
        child: Icon(
          Icons.videocam_off,
          color: Colors.white.withOpacity(0.5),
          size: 48,
        ),
      );
    }
    
    // Single participant: Show full screen
    if (participants.length == 1) {
      final item = participants[0];
      return _buildVideoTile(
        participant: item['participant'],
        isLocal: item['isLocal'] as bool,
        showLabel: true,
      );
    }
    
    // Multiple participants: Grid layout
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: participants.length > 2 ? 2 : 1,
        childAspectRatio: 16 / 9,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: participants.length,
      itemBuilder: (context, index) {
        final item = participants[index];
        return _buildVideoTile(
          participant: item['participant'],
          isLocal: item['isLocal'] as bool,
          showLabel: false, // Too small for labels in grid
        );
      },
    );
  }
  
  Widget _buildVideoTile({
    required dynamic participant,
    required bool isLocal,
    required bool showLabel,
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
    
    return Stack(
      fit: StackFit.expand,
      children: [
        // Video or placeholder
        if (videoTrack != null && !videoTrack.muted)
          VideoTrackRenderer(videoTrack)
        else
          Container(
            color: Colors.grey.shade900,
            child: Center(
              child: Icon(
                Icons.videocam_off,
                size: showLabel ? 32 : 16,
                color: Colors.white.withOpacity(0.5),
              ),
            ),
          ),
        
        // Label (only if showLabel is true)
        if (showLabel)
          Positioned(
            bottom: 4,
            left: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                isLocal ? 'You' : identity,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                ),
              ),
            ),
          ),
        
        // Muted indicator
        if (audioMuted)
          Positioned(
            top: 4,
            right: 4,
            child: Icon(
              Icons.mic_off,
              color: Colors.red,
              size: showLabel ? 16 : 12,
            ),
          ),
      ],
    );
  }
  
  Widget _buildIconButton({
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: IconButton(
        padding: EdgeInsets.zero,
        icon: Icon(icon, color: Colors.white, size: 16),
        onPressed: onPressed,
      ),
    );
  }
}
