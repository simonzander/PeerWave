import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/video_conference_service.dart';
import '../services/user_profile_service.dart';
import 'call_duration_timer.dart';
import 'dart:convert';

/// Global top bar showing active call status
/// Only visible when in a call and overlay is visible
class CallTopBar extends StatefulWidget {
  const CallTopBar({Key? key}) : super(key: key);
  
  @override
  State<CallTopBar> createState() => _CallTopBarState();
}

class _CallTopBarState extends State<CallTopBar> {
  @override
  void initState() {
    super.initState();
    // Load participant profiles when topbar is created
    _loadParticipantProfiles();
  }
  
  void _loadParticipantProfiles() async {
    final service = VideoConferenceService.instance;
    if (service.remoteParticipants.isNotEmpty) {
      final uuids = service.remoteParticipants.map((p) => p.identity).toList();
      try {
        await UserProfileService.instance.ensureProfilesLoaded(uuids);
        if (mounted) setState(() {}); // Refresh to show loaded avatars
      } catch (e) {
        debugPrint('[CallTopBar] Failed to load participant profiles: $e');
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    
    return Consumer<VideoConferenceService>(
      builder: (context, service, _) {
        // Show TopBar only when in call AND not in full-view mode
        if (!service.isInCall || service.isInFullView) {
          return const SizedBox.shrink();
        }
        
        return Container(
          color: colorScheme.surfaceContainerHighest,
          child: SafeArea(
            bottom: false,
            child: Container(
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  // Live indicator
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  
                  // Channel info - all in one row
                  Expanded(
                    child: Row(
                      children: [
                        // Channel name
                        Flexible(
                          flex: 3,
                          child: Text(
                            service.channelName ?? 'Video Call',
                            style: TextStyle(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        
                        const SizedBox(width: 8),
                        Text('•', style: TextStyle(color: colorScheme.errorContainer, fontSize: 12)),
                        const SizedBox(width: 8),
                        
                        // Call duration
                        if (service.callStartTime != null)
                          Flexible(
                            flex: 2,
                            child: CallDurationTimer(
                              startTime: service.callStartTime!,
                              style: TextStyle(
                                color: colorScheme.primary,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        
                        const SizedBox(width: 8),
                        Text('•', style: TextStyle(color: colorScheme.errorContainer, fontSize: 12)),
                        const SizedBox(width: 8),
                        
                        // Participant count
                        Text(
                          '${service.remoteParticipants.length + 1}',
                          style: TextStyle(
                            color: colorScheme.primary,
                            fontSize: 12,
                          ),
                        ),
                        
                        const SizedBox(width: 4),
                        
                        // Participant avatars
                        if (service.remoteParticipants.isNotEmpty)
                          Flexible(
                            flex: 1,
                            child: Builder(
                              builder: (context) {
                                // Trigger profile load when participants change
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  _loadParticipantProfiles();
                                });
                                return Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    for (var i = 0; i < service.remoteParticipants.length && i < 3; i++)
                                      _buildParticipantAvatar(service.remoteParticipants[i].identity, colorScheme),
                                    if (service.remoteParticipants.length > 3)
                                      Container(
                                        width: 20,
                                        height: 20,
                                        margin: const EdgeInsets.only(left: 2),
                                        decoration: BoxDecoration(
                                          color: colorScheme.outlineVariant,
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Center(
                                          child: Text(
                                            '+${service.remoteParticipants.length - 3}',
                                            style: TextStyle(
                                              color: colorScheme.primary,
                                              fontSize: 8,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(width: 8),
                  
                  // Return to full view button (delegates navigation to service)
                  IconButton(
                    iconSize: 24,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: Icon(
                      Icons.open_in_full,
                      color: colorScheme.onSurface,
                      size: 20,
                    ),
                    onPressed: () {
                      try {
                        service.navigateToCurrentChannelFullView();
                      } catch (e) {
                        debugPrint('[CallTopBar] Navigation error: $e');
                      }
                    },
                  ),
                  
                  const SizedBox(width: 12),
                  
                  // Show overlay button (visible when overlay is hidden)
                  if (!service.isOverlayVisible)
                    IconButton(
                      iconSize: 24,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: Icon(
                        Icons.video_label,
                        color: colorScheme.onSurface,
                        size: 20,
                      ),
                      onPressed: () => service.showOverlay(),
                    ),
                  
                  if (!service.isOverlayVisible)
                    const SizedBox(width: 12),
                  
                  // Toggle camera button
                  IconButton(
                    iconSize: 24,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: Icon(
                      service.localParticipant?.isCameraEnabled() == true
                          ? Icons.videocam
                          : Icons.videocam_off,
                      color: colorScheme.onSurface,
                      size: 20,
                    ),
                    onPressed: () => service.toggleCamera(),
                  ),
                  
                  const SizedBox(width: 12),
                  
                  // Toggle microphone button
                  IconButton(
                    iconSize: 24,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: Icon(
                      service.localParticipant?.isMicrophoneEnabled() == true
                          ? Icons.mic
                          : Icons.mic_off,
                      color: colorScheme.onSurface,
                      size: 20,
                    ),
                    onPressed: () => service.toggleMicrophone(),
                  ),
                  
                  const SizedBox(width: 12),
                  
                  // Leave call button
                  IconButton(
                    iconSize: 24,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: Icon(
                      Icons.call_end,
                      color: colorScheme.errorContainer,
                      size: 20,
                    ),
                    onPressed: () async {
                      await service.leaveRoom();
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
  
  Widget _buildParticipantAvatar(String uuid, ColorScheme colorScheme) {
    final profileService = UserProfileService.instance;
    final picture = profileService.getPicture(uuid);
    
    return Container(
      width: 20,
      height: 20,
      margin: const EdgeInsets.only(left: 2),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: picture != null && picture.isNotEmpty
            ? Image.memory(
                base64Decode(picture),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return Center(
                    child: Text(
                      uuid.substring(0, 1).toUpperCase(),
                      style: TextStyle(
                        color: colorScheme.onPrimary,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  );
                },
              )
            : Center(
                child: Text(
                  uuid.substring(0, 1).toUpperCase(),
                  style: TextStyle(
                    color: colorScheme.onPrimary,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
      ),
    );
  }
}
