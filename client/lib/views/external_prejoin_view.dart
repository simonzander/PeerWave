import 'package:flutter/material.dart';
import 'dart:async';
import '../models/external_session.dart';
import '../services/external_participant_service.dart';

/// External pre-join view - for guests joining via invitation link
/// 
/// Features:
/// - Display name entry
/// - Meeting information display
/// - Waiting room while waiting for admission
/// - Real-time admission status updates
/// - Admitted/declined notifications
class ExternalPreJoinView extends StatefulWidget {
  final String invitationToken;
  final VoidCallback onAdmitted;
  final VoidCallback onDeclined;

  const ExternalPreJoinView({
    super.key,
    required this.invitationToken,
    required this.onAdmitted,
    required this.onDeclined,
  });

  @override
  State<ExternalPreJoinView> createState() => _ExternalPreJoinViewState();
}

class _ExternalPreJoinViewState extends State<ExternalPreJoinView> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _externalService = ExternalParticipantService();

  bool _isJoining = false;
  bool _isWaiting = false;
  ExternalSession? _session;
  StreamSubscription? _admittedSubscription;
  StreamSubscription? _declinedSubscription;
  Timer? _pollingTimer;

  @override
  void initState() {
    super.initState();
    _externalService.initializeListeners();
    _setupListeners();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _admittedSubscription?.cancel();
    _declinedSubscription?.cancel();
    _pollingTimer?.cancel();
    super.dispose();
  }

  void _setupListeners() {
    // Listen for admission
    _admittedSubscription = _externalService.onGuestAdmitted.listen((session) {
      if (mounted && session.sessionId == _session?.sessionId) {
        _pollingTimer?.cancel();
        widget.onAdmitted();
      }
    });

    // Listen for decline
    _declinedSubscription = _externalService.onGuestDeclined.listen((session) {
      if (mounted && session.sessionId == _session?.sessionId) {
        _pollingTimer?.cancel();
        widget.onDeclined();
      }
    });
  }

  Future<void> _handleJoin() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isJoining = true);

    try {
      final session = await _externalService.joinMeeting(
        invitationToken: widget.invitationToken,
        displayName: _nameController.text.trim(),
      );

      if (mounted) {
        setState(() {
          _session = session;
          _isJoining = false;
        });

        if (session.isAdmitted) {
          // Already admitted
          widget.onAdmitted();
        } else if (session.isDeclined) {
          // Already declined
          widget.onDeclined();
        } else {
          // Waiting for admission
          setState(() => _isWaiting = true);
          _startPolling();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isJoining = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to join: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _startPolling() {
    // Poll every 3 seconds to check admission status
    _pollingTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (_session == null || !mounted) {
        timer.cancel();
        return;
      }

      try {
        final updatedSession = await _externalService.getSessionStatus(_session!.sessionId);

        if (mounted) {
          if (updatedSession.isAdmitted) {
            timer.cancel();
            widget.onAdmitted();
          } else if (updatedSession.isDeclined) {
            timer.cancel();
            widget.onDeclined();
          }
        }
      } catch (e) {
        debugPrint('Polling error: $e');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isWaiting) {
      return _buildWaitingView();
    }

    return _buildNameEntryView();
  }

  Widget _buildNameEntryView() {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Logo or icon
                  Icon(
                    Icons.today,
                    size: 80,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 24),

                  // Title
                  Text(
                    'Join Meeting',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),

                  Text(
                    'Enter your name to join as a guest',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey[600],
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),

                  // Name field
                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Display Name',
                      hintText: 'Enter your name',
                      prefixIcon: Icon(Icons.person),
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Please enter your name';
                      }
                      if (value.trim().length < 2) {
                        return 'Name must be at least 2 characters';
                      }
                      return null;
                    },
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _handleJoin(),
                  ),
                  const SizedBox(height: 24),

                  // Join button
                  ElevatedButton.icon(
                    onPressed: _isJoining ? null : _handleJoin,
                    icon: _isJoining
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login),
                    label: Text(_isJoining ? 'Joining...' : 'Join Meeting'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWaitingView() {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Animated waiting indicator
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: 1.0),
                duration: const Duration(seconds: 2),
                builder: (context, value, child) {
                  return Transform.scale(
                    scale: 0.8 + (value * 0.2),
                    child: child,
                  );
                },
                onEnd: () {
                  if (mounted) {
                    setState(() {});
                  }
                },
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.hourglass_empty,
                    size: 60,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 32),

              Text(
                'Waiting for admission',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),

              Text(
                'The meeting host will admit you shortly',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              // Display name
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.person, color: Colors.grey[600]),
                    const SizedBox(width: 8),
                    Text(
                      _nameController.text,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              const CircularProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}
