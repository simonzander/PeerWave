import 'package:flutter/material.dart';
import 'dart:async';
import '../models/meeting.dart';
import '../services/call_service.dart';

/// Incoming call overlay - displays at top of screen when receiving a call
/// 
/// Features:
/// - Full-width notification bar
/// - Caller information (name, meeting title)
/// - Accept/Decline buttons
/// - Auto-dismiss after timeout (60 seconds)
/// - Automatic ringtone playback via CallService
/// - Navigation to video conference on accept
class IncomingCallOverlay extends StatefulWidget {
  final Map<String, dynamic> callData;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onDismiss;

  const IncomingCallOverlay({
    super.key,
    required this.callData,
    required this.onAccept,
    required this.onDecline,
    required this.onDismiss,
  });

  @override
  State<IncomingCallOverlay> createState() => _IncomingCallOverlayState();
}

class _IncomingCallOverlayState extends State<IncomingCallOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _slideController;
  late Animation<Offset> _slideAnimation;
  Timer? _autoDismissTimer;
  int _remainingSeconds = 60;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();

    // Slide animation
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOut,
    ));

    // Start animation
    _slideController.forward();

    // Auto-dismiss timer
    _autoDismissTimer = Timer(const Duration(seconds: 60), () {
      if (mounted) {
        _handleDecline();
      }
    });

    // Countdown timer
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _remainingSeconds--;
          if (_remainingSeconds <= 0) {
            timer.cancel();
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _slideController.dispose();
    _autoDismissTimer?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _handleAccept() {
    _autoDismissTimer?.cancel();
    _countdownTimer?.cancel();
    widget.onAccept();
  }

  void _handleDecline() async {
    _autoDismissTimer?.cancel();
    _countdownTimer?.cancel();

    // Slide out animation
    await _slideController.reverse();

    if (mounted) {
      widget.onDecline();
    }
  }

  void _handleDismiss() async {
    _autoDismissTimer?.cancel();
    _countdownTimer?.cancel();

    // Slide out animation
    await _slideController.reverse();

    if (mounted) {
      widget.onDismiss();
    }
  }

  @override
  Widget build(BuildContext context) {
    final meeting = widget.callData['meeting'] as Map<String, dynamic>?;
    final caller = widget.callData['caller'] as Map<String, dynamic>?;
    final meetingTitle = meeting?['title'] as String? ?? 'Incoming Call';
    final callerName = caller?['username'] as String? ?? 'Unknown';
    final isVideoCall = !(meeting?['voice_only'] as bool? ?? false);

    return SlideTransition(
      position: _slideAnimation,
      child: Material(
        elevation: 8,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Theme.of(context).colorScheme.primary,
                Theme.of(context).colorScheme.primaryContainer,
              ],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  // Pulsing icon
                  _buildPulsingIcon(isVideoCall),
                  const SizedBox(width: 16),

                  // Call info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          meetingTitle,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$callerName is calling',
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Colors.white.withOpacity(0.9),
                                  ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Auto-dismiss in $_remainingSeconds seconds',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.white.withOpacity(0.7),
                                  ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 12),

                  // Decline button
                  _buildActionButton(
                    icon: Icons.call_end,
                    color: Colors.red,
                    onPressed: _handleDecline,
                    label: 'Decline',
                  ),

                  const SizedBox(width: 8),

                  // Accept button
                  _buildActionButton(
                    icon: Icons.call,
                    color: Colors.green,
                    onPressed: _handleAccept,
                    label: 'Accept',
                  ),

                  const SizedBox(width: 8),

                  // Dismiss button (X)
                  IconButton(
                    onPressed: _handleDismiss,
                    icon: const Icon(Icons.close, color: Colors.white),
                    tooltip: 'Dismiss',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPulsingIcon(bool isVideoCall) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.8, end: 1.2),
      duration: const Duration(milliseconds: 800),
      builder: (context, scale, child) {
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isVideoCall ? Icons.videocam : Icons.phone,
              color: Colors.white,
              size: 28,
            ),
          ),
        );
      },
      onEnd: () {
        // Reverse animation for pulsing effect
        if (mounted) {
          setState(() {});
        }
      },
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
    required String label,
  }) {
    return Tooltip(
      message: label,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Text(label),
          ],
        ),
      ),
    );
  }
}

/// Overlay manager for incoming calls
/// 
/// Usage:
/// ```dart
/// IncomingCallOverlayManager.show(
///   context: context,
///   callData: callData,
///   onAccept: () => navigateToCall(),
///   onDecline: () => declineCall(),
/// );
/// ```
class IncomingCallOverlayManager {
  static OverlayEntry? _currentOverlay;

  /// Show incoming call overlay
  static void show({
    required BuildContext context,
    required Map<String, dynamic> callData,
    required VoidCallback onAccept,
    required VoidCallback onDecline,
  }) {
    // Remove existing overlay if any
    dismiss();

    final overlay = Overlay.of(context);
    final overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: IncomingCallOverlay(
          callData: callData,
          onAccept: () {
            dismiss();
            onAccept();
          },
          onDecline: () {
            dismiss();
            onDecline();
          },
          onDismiss: () {
            dismiss();
            // Stop ringtone on dismiss
            CallService().stopRingtone();
          },
        ),
      ),
    );

    overlay.insert(overlayEntry);
    _currentOverlay = overlayEntry;
  }

  /// Dismiss current overlay
  static void dismiss() {
    _currentOverlay?.remove();
    _currentOverlay = null;
  }

  /// Check if overlay is currently showing
  static bool get isShowing => _currentOverlay != null;
}
