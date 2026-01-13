import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/meeting_service.dart';

/// Notification bar that appears at the top when user receives a meeting invitation
class IncomingCallNotification extends StatelessWidget {
  final String meetingId;
  final String meetingTitle;
  final String inviterName;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const IncomingCallNotification({
    super.key,
    required this.meetingId,
    required this.meetingTitle,
    required this.inviterName,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Material(
      elevation: 8,
      child: Container(
        color: colorScheme.primaryContainer,
        child: SafeArea(
          bottom: false,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                // Call icon
                Icon(Icons.videocam, color: colorScheme.primary, size: 28),
                const SizedBox(width: 12),

                // Call info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Incoming Call',
                        style: TextStyle(
                          color: colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        '$inviterName invited you to "$meetingTitle"',
                        style: TextStyle(
                          color: colorScheme.onPrimaryContainer.withValues(
                            alpha: 0.8,
                          ),
                          fontSize: 12,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 12),

                // Decline button
                OutlinedButton.icon(
                  onPressed: onDecline,
                  icon: const Icon(Icons.call_end, size: 18),
                  label: const Text('Decline'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colorScheme.error,
                    side: BorderSide(color: colorScheme.error),
                  ),
                ),

                const SizedBox(width: 8),

                // Accept button
                ElevatedButton.icon(
                  onPressed: onAccept,
                  icon: const Icon(Icons.videocam, size: 18),
                  label: const Text('Accept'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Manager for showing/hiding incoming call notifications
class IncomingCallNotificationManager extends StatefulWidget {
  final Widget child;

  const IncomingCallNotificationManager({super.key, required this.child});

  static final GlobalKey<_IncomingCallNotificationManagerState> _key =
      GlobalKey<_IncomingCallNotificationManagerState>();

  static void showNotification({
    required String meetingId,
    required String meetingTitle,
    required String inviterName,
    required BuildContext context,
  }) {
    _key.currentState?.showNotification(
      meetingId: meetingId,
      meetingTitle: meetingTitle,
      inviterName: inviterName,
      context: context,
    );
  }

  static void hideNotification() {
    _key.currentState?.hideNotification();
  }

  @override
  State<IncomingCallNotificationManager> createState() =>
      _IncomingCallNotificationManagerState();
}

class _IncomingCallNotificationManagerState
    extends State<IncomingCallNotificationManager> {
  String? _meetingId;
  String? _meetingTitle;
  String? _inviterName;
  bool _isVisible = false;

  void showNotification({
    required String meetingId,
    required String meetingTitle,
    required String inviterName,
    required BuildContext context,
  }) {
    setState(() {
      _meetingId = meetingId;
      _meetingTitle = meetingTitle;
      _inviterName = inviterName;
      _isVisible = true;
    });
  }

  void hideNotification() {
    setState(() {
      _isVisible = false;
      _meetingId = null;
      _meetingTitle = null;
      _inviterName = null;
    });
  }

  Future<void> _acceptCall(BuildContext context) async {
    if (_meetingId == null) return;

    try {
      // Update participant status to accepted
      await MeetingService().updateParticipantStatus(
        _meetingId!,
        '', // Will be filled by backend with current user
        'accepted',
      );

      // Navigate to meeting prejoin
      if (!mounted) return;
      // ignore: use_build_context_synchronously
      context.go('/meeting/prejoin/$_meetingId');
      hideNotification();
    } catch (e) {
      debugPrint('[IncomingCall] Error accepting call: $e');
    }
  }

  Future<void> _declineCall() async {
    if (_meetingId == null) return;

    try {
      // Update participant status to declined
      await MeetingService().updateParticipantStatus(
        _meetingId!,
        '', // Will be filled by backend with current user
        'declined',
      );

      hideNotification();
    } catch (e) {
      debugPrint('[IncomingCall] Error declining call: $e');
      hideNotification();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_isVisible &&
            _meetingId != null &&
            _meetingTitle != null &&
            _inviterName != null)
          IncomingCallNotification(
            meetingId: _meetingId!,
            meetingTitle: _meetingTitle!,
            inviterName: _inviterName!,
            onAccept: () => _acceptCall(context),
            onDecline: _declineCall,
          ),
        Expanded(child: widget.child),
      ],
    );
  }
}
