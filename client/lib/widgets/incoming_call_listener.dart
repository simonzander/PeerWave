import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:peerwave_client/main.dart';
import 'package:peerwave_client/services/call_service.dart';
import 'package:peerwave_client/services/sound_service.dart';
import 'package:peerwave_client/theme/semantic_colors.dart';
import 'package:peerwave_client/core/events/event_bus.dart';

/// Global widget that listens for incoming calls and displays notifications
class IncomingCallListener extends StatefulWidget {
  final Widget child;

  const IncomingCallListener({super.key, required this.child});

  @override
  State<IncomingCallListener> createState() => _IncomingCallListenerState();
}

class _IncomingCallListenerState extends State<IncomingCallListener> {
  final CallService _callService = CallService();
  final SoundService _soundService = SoundService.instance;
  final List<Map<String, dynamic>> _incomingCalls = [];
  StreamSubscription? _eventSubscription;

  @override
  void initState() {
    super.initState();
    _setupCallListener();
  }

  void _setupCallListener() {
    debugPrint('[IncomingCallListener] Setting up EventBus listener...');

    // Listen for incoming calls via EventBus
    _eventSubscription = EventBus.instance.on(AppEvent.incomingCall).listen((
      data,
    ) async {
      debugPrint(
        '[IncomingCallListener] ========== Received incomingCall event ==========',
      );
      debugPrint('[IncomingCallListener] Event data: $data');

      try {
        final eventData = data as Map<String, dynamic>;

        // Parse payload (comes as decrypted message)
        final payloadStr = eventData['decryptedMessage'] as String;
        debugPrint('[IncomingCallListener] Decrypted message: $payloadStr');

        final payload = jsonDecode(payloadStr) as Map<String, dynamic>;
        debugPrint('[IncomingCallListener] Decoded payload: $payload');

        final callerId = payload['callerId'] as String?;
        final callerName = payload['callerName'] as String? ?? 'Unknown';
        final meetingId = payload['meetingId'] as String?;
        final callType = payload['callType'] as String? ?? 'instant';
        final channelId = payload['channelId'] as String?;
        final channelName = payload['channelName'] as String?;

        if (callerId == null || meetingId == null) {
          debugPrint(
            '[IncomingCallListener] Invalid call notification payload',
          );
          return;
        }

        // Create call data
        final callData = {
          'callerId': callerId,
          'callerName': callerName,
          'meetingId': meetingId,
          'callType': callType,
          'channelId': channelId,
          'channelName': channelName ?? 'Call',
        };

        // Add to queue if not already present
        if (!_incomingCalls.any((c) => c['meetingId'] == meetingId)) {
          setState(() {
            _incomingCalls.add(callData);
          });

          // Play ringtone
          _soundService.playRingtone();

          debugPrint(
            '[IncomingCallListener] Added incoming call to queue: $meetingId from $callerName',
          );
        }
      } catch (e, stackTrace) {
        debugPrint(
          '[IncomingCallListener] Error processing call notification: $e',
        );
        debugPrint('[IncomingCallListener] Stack trace: $stackTrace');
      }
    });

    debugPrint('[IncomingCallListener] ✓ EventBus listener registered');
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    super.dispose();
  }

  void _handleAccept(Map<String, dynamic> callData) {
    final meetingId = callData['meetingId'] as String;

    // Send accept event
    _callService.acceptCall(meetingId);

    // Stop ringtone
    _soundService.stopRingtone();

    // Remove from list
    setState(() {
      _incomingCalls.removeWhere((call) => call['meetingId'] == meetingId);
    });

    // Navigate using GoRouter (same pattern as CallTopBar)
    final navigatorContext = MyApp.rootNavigatorKey.currentContext;
    if (navigatorContext != null) {
      GoRouter.of(navigatorContext).go('/meeting/prejoin/$meetingId');
    } else {
      debugPrint('[IncomingCallListener] ERROR: Navigator key has no context');
    }
  }

  void _handleDecline(Map<String, dynamic> callData) {
    final meetingId = callData['meetingId'] as String;

    // Send decline event with manual reason
    _callService.declineCall(meetingId, reason: 'declined');

    // Stop ringtone
    _soundService.stopRingtone();

    // Remove from list
    setState(() {
      _incomingCalls.removeWhere((call) => call['meetingId'] == meetingId);
    });
  }

  void _handleTimeout(Map<String, dynamic> callData) {
    final meetingId = callData['meetingId'] as String;

    // Send decline event with timeout reason
    _callService.declineCall(meetingId, reason: 'timeout');

    // Stop ringtone
    _soundService.stopRingtone();

    // Remove from list
    setState(() {
      _incomingCalls.removeWhere((call) => call['meetingId'] == meetingId);
    });
  }

  void _handleDismiss(Map<String, dynamic> callData) {
    // Just remove from UI, don't send any events
    final meetingId = callData['meetingId'] as String;

    // Stop ringtone
    _soundService.stopRingtone();

    setState(() {
      _incomingCalls.removeWhere((call) => call['meetingId'] == meetingId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) {
        return Stack(
          children: [
            // Main app content
            widget.child,

            // Incoming call overlays (stack multiple calls from top to bottom)
            ..._incomingCalls.asMap().entries.map((entry) {
              final index = entry.key;
              final callData = entry.value;

              return Positioned(
                top: 20.0 + (index * 90.0), // Stack vertically
                left: 20,
                right: 20,
                child: _IncomingCallBar(
                  callData: callData,
                  onAccept: () => _handleAccept(callData),
                  onDecline: () => _handleDecline(callData),
                  onTimeout: () => _handleTimeout(callData),
                  onDismiss: () => _handleDismiss(callData),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}

/// Simple incoming call bar widget
class _IncomingCallBar extends StatefulWidget {
  final Map<String, dynamic> callData;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onTimeout;
  final VoidCallback onDismiss;

  const _IncomingCallBar({
    required this.callData,
    required this.onAccept,
    required this.onDecline,
    required this.onTimeout,
    required this.onDismiss,
  });

  @override
  State<_IncomingCallBar> createState() => _IncomingCallBarState();
}

class _IncomingCallBarState extends State<_IncomingCallBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _slideController;
  late Animation<Offset> _slideAnimation;
  Timer? _autoDismissTimer;
  Timer? _countdownTimer;
  int _remainingSeconds = 60;

  @override
  void initState() {
    super.initState();

    // Slide animation
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(-1.0, 0.0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideController, curve: Curves.easeOut));

    // Auto-dismiss timer
    _autoDismissTimer = Timer(const Duration(seconds: 60), () {
      if (mounted) {
        _handleTimeout();
      }
    });

    // Countdown timer for display
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

    // Start animation
    _slideController.forward();
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _countdownTimer?.cancel();
    _slideController.dispose();
    super.dispose();
  }

  Future<void> _handleAccept() async {
    _autoDismissTimer?.cancel();
    _countdownTimer?.cancel();
    await _slideController.reverse();
    if (mounted) {
      widget.onAccept();
    }
  }

  Future<void> _handleDecline() async {
    _autoDismissTimer?.cancel();
    _countdownTimer?.cancel();
    await _slideController.reverse();
    if (mounted) {
      widget.onDecline();
    }
  }

  Future<void> _handleTimeout() async {
    _autoDismissTimer?.cancel();
    _countdownTimer?.cancel();
    await _slideController.reverse();
    if (mounted) {
      widget.onTimeout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final callType = widget.callData['callType'] as String;
    final callerName = widget.callData['callerName'] as String;
    final channelName = widget.callData['channelName'] as String?;
    final isChannel = callType == 'channel';

    return SlideTransition(
      position: _slideAnimation,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(context).colorScheme.primary,
              width: 2,
            ),
          ),
          child: Row(
            children: [
              // Call icon
              Icon(
                isChannel ? Icons.groups : Icons.phone,
                color: Theme.of(context).colorScheme.primary,
                size: 32,
              ),
              const SizedBox(width: 16),

              // Call info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isChannel
                          ? 'Incoming call in $channelName'
                          : 'Incoming call from $callerName',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Auto-dismiss in $_remainingSeconds seconds',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),

              // Action buttons
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Decline button
                  IconButton(
                    onPressed: _handleDecline,
                    icon: const Icon(Icons.call_end),
                    color: Theme.of(context).colorScheme.error,
                  ),

                  const SizedBox(width: 8),

                  // Accept button
                  IconButton(
                    onPressed: _handleAccept,
                    icon: const Icon(Icons.call),
                    color: Theme.of(context).colorScheme.success,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
