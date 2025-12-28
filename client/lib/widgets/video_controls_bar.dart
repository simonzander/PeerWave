import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import '../theme/semantic_colors.dart';

/// Reusable video controls bar
/// Shows audio/video/screenshare/leave buttons with device selection on long press
class VideoControlsBar extends StatelessWidget {
  final bool isMicEnabled;
  final bool isCameraEnabled;
  final bool isScreenShareEnabled;
  final VoidCallback onToggleMicrophone;
  final VoidCallback onToggleCamera;
  final VoidCallback onToggleScreenShare;
  final VoidCallback onLeave;
  final Future<void> Function(lk.MediaDevice device)? onSwitchMicrophone;
  final Future<void> Function(lk.MediaDevice device)? onSwitchCamera;
  final Function(String sourceId)? onSetDesktopScreenSource;

  const VideoControlsBar({
    super.key,
    required this.isMicEnabled,
    required this.isCameraEnabled,
    required this.isScreenShareEnabled,
    required this.onToggleMicrophone,
    required this.onToggleCamera,
    required this.onToggleScreenShare,
    required this.onLeave,
    this.onSwitchMicrophone,
    this.onSwitchCamera,
    this.onSetDesktopScreenSource,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Toggle Audio
          _buildControlButton(
            context: context,
            icon: isMicEnabled ? Icons.mic : Icons.mic_off,
            label: 'Audio',
            onPressed: onToggleMicrophone,
            onLongPress: onSwitchMicrophone != null
                ? () => _showMicrophoneDeviceSelector(context)
                : null,
            isActive: isMicEnabled,
            heroTag: 'audio_button',
          ),

          // Toggle Video
          _buildControlButton(
            context: context,
            icon: isCameraEnabled ? Icons.videocam : Icons.videocam_off,
            label: 'Video',
            onPressed: onToggleCamera,
            onLongPress: onSwitchCamera != null
                ? () => _showCameraDeviceSelector(context)
                : null,
            isActive: isCameraEnabled,
            heroTag: 'video_button',
          ),

          // Toggle Screen Share
          _buildControlButton(
            context: context,
            icon: isScreenShareEnabled
                ? Icons.stop_screen_share
                : Icons.screen_share,
            label: 'Share',
            onPressed: () => _handleScreenShareToggle(context),
            isActive: isScreenShareEnabled,
            heroTag: 'share_button',
          ),

          // Leave Call
          _buildControlButton(
            context: context,
            icon: Icons.call_end,
            label: 'Leave',
            onPressed: onLeave,
            isActive: false,
            color: Theme.of(context).colorScheme.error,
            heroTag: 'leave_button',
          ),
        ],
      ),
    );
  }

  /// Handle screen share toggle with desktop source picker
  Future<void> _handleScreenShareToggle(BuildContext context) async {
    try {
      final isCurrentlySharing = isScreenShareEnabled;

      // If stopping, just stop
      if (isCurrentlySharing) {
        onToggleScreenShare();
        return;
      }

      // If starting on desktop, show screen picker first
      if (!kIsWeb && onSetDesktopScreenSource != null) {
        final source = await showDialog<webrtc.DesktopCapturerSource>(
          context: context,
          builder: (context) => lk.ScreenSelectDialog(),
        );

        if (source == null) {
          debugPrint('[VideoControlsBar] Screen share cancelled');
          return;
        }

        debugPrint(
          '[VideoControlsBar] Selected screen source: ${source.id} (${source.name})',
        );
        onSetDesktopScreenSource!(source.id);
      }

      // Toggle screen share
      onToggleScreenShare();
    } catch (e) {
      debugPrint('[VideoControlsBar] Error toggling screen share: $e');
      if (context.mounted) {
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
    if (onSwitchMicrophone == null) return;

    try {
      final devices = await lk.Hardware.instance.enumerateDevices();
      final microphones = devices.where((d) => d.kind == 'audioinput').toList();

      if (!context.mounted) return;

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
                        await onSwitchMicrophone!(device);
                        if (context.mounted) {
                          scaffoldMessenger.showSnackBar(
                            SnackBar(
                              content: Text('Switched to ${device.label}'),
                              backgroundColor: Colors.green,
                            ),
                          );
                        }
                      } catch (e) {
                        debugPrint(
                          '[VideoControlsBar] Error switching microphone: $e',
                        );
                        if (context.mounted) {
                          scaffoldMessenger.showSnackBar(
                            SnackBar(
                              content: const Text(
                                'Failed to switch microphone',
                              ),
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.error,
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
      debugPrint('[VideoControlsBar] Error loading microphones: $e');
    }
  }

  /// Show camera device selector dialog
  Future<void> _showCameraDeviceSelector(BuildContext context) async {
    if (onSwitchCamera == null) return;

    try {
      final devices = await lk.Hardware.instance.enumerateDevices();
      final cameras = devices.where((d) => d.kind == 'videoinput').toList();

      if (!context.mounted) return;

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
                        await onSwitchCamera!(device);
                        if (context.mounted) {
                          scaffoldMessenger.showSnackBar(
                            SnackBar(
                              content: Text('Switched to ${device.label}'),
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.success,
                            ),
                          );
                        }
                      } catch (e) {
                        debugPrint(
                          '[VideoControlsBar] Error switching camera: $e',
                        );
                        if (context.mounted) {
                          scaffoldMessenger.showSnackBar(
                            SnackBar(
                              content: const Text('Failed to switch camera'),
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.error,
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
      debugPrint('[VideoControlsBar] Error loading cameras: $e');
    }
  }

  Widget _buildControlButton({
    required BuildContext context,
    required IconData icon,
    required String label,
    VoidCallback? onPressed,
    VoidCallback? onLongPress,
    required bool isActive,
    Color? color,
    String? heroTag,
  }) {
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
            heroTag: heroTag ?? label,
            onPressed: null, // Disabled, using GestureDetector
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
  }
}
