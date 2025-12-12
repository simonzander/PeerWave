import 'package:flutter/material.dart';
import 'dart:async';
import '../models/external_session.dart';
import '../services/external_participant_service.dart';

/// Admission overlay - shows waiting guests to meeting participants
///
/// Features:
/// - List of waiting guests
/// - Admit/Decline buttons for each guest
/// - Real-time updates via streams
/// - Compact overlay design
/// - Badge count indicator
class AdmissionOverlay extends StatefulWidget {
  final String meetingId;

  const AdmissionOverlay({super.key, required this.meetingId});

  @override
  State<AdmissionOverlay> createState() => _AdmissionOverlayState();
}

class _AdmissionOverlayState extends State<AdmissionOverlay> {
  final _externalService = ExternalParticipantService();
  List<ExternalSession> _waitingGuests = [];
  StreamSubscription? _guestWaitingSubscription;
  StreamSubscription? _guestAdmittedSubscription;
  StreamSubscription? _guestDeclinedSubscription;
  StreamSubscription? _admissionRequestSubscription;
  bool _isExpanded = false;
  bool _isLoading = true;
  final Set<String> _processedSessions = {}; // Track already processed sessions

  @override
  void initState() {
    super.initState();
    _externalService.initializeListeners();
    _loadWaitingGuests();
    _setupListeners();
  }

  @override
  void dispose() {
    _guestWaitingSubscription?.cancel();
    _guestAdmittedSubscription?.cancel();
    _guestDeclinedSubscription?.cancel();
    _admissionRequestSubscription?.cancel();
    super.dispose();
  }

  void _setupListeners() {
    _guestWaitingSubscription = _externalService.onGuestWaiting.listen((
      session,
    ) {
      if (mounted && session.meetingId == widget.meetingId) {
        setState(() {
          _waitingGuests.add(session);
        });
      }
    });

    _guestAdmittedSubscription = _externalService.onGuestAdmitted.listen((
      session,
    ) {
      if (mounted && session.meetingId == widget.meetingId) {
        setState(() {
          _waitingGuests.removeWhere((g) => g.sessionId == session.sessionId);
        });
      }
    });

    _guestDeclinedSubscription = _externalService.onGuestDeclined.listen((
      session,
    ) {
      if (mounted && session.meetingId == widget.meetingId) {
        setState(() {
          _waitingGuests.removeWhere((g) => g.sessionId == session.sessionId);
          _processedSessions.add(session.sessionId);
        });
      }
    });

    // NEW: Listen for admission requests (new event from redesign)
    _admissionRequestSubscription = _externalService.onGuestAdmissionRequest
        .listen((data) {
          if (mounted && data['meeting_id'] == widget.meetingId) {
            final sessionId = data['session_id'] as String?;
            final displayName = data['display_name'] as String?;

            if (sessionId != null && displayName != null) {
              // Play notification sound
              _playNotificationSound();

              // Create ExternalSession from admission request data
              final now = DateTime.now();
              final session = ExternalSession(
                sessionId: sessionId,
                meetingId: widget.meetingId,
                displayName: displayName,
                createdAt: now,
                updatedAt: now,
                expiresAt: now.add(const Duration(hours: 24)),
                admissionStatus: 'waiting',
              );

              // Add to waiting list if not already there
              setState(() {
                if (!_waitingGuests.any((g) => g.sessionId == sessionId)) {
                  _waitingGuests.add(session);
                  _isExpanded = true; // Auto-expand when new request arrives
                }
              });
            }
          }
        });
  }

  Future<void> _loadWaitingGuests() async {
    setState(() => _isLoading = true);

    try {
      final guests = await _externalService.getWaitingGuests(widget.meetingId);
      if (mounted) {
        setState(() {
          _waitingGuests = guests;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
      debugPrint('Failed to load waiting guests: $e');
    }
  }

  void _playNotificationSound() {
    // Simple beep sound using HTML audio API (web only)
    // For native apps, you would use audioplayers package
    try {
      // Create a simple notification beep with AudioContext
      // This is a placeholder - in production, use an actual audio file
      debugPrint('[ADMISSION] 🔔 Guest admission request notification');

      // TODO: Implement actual audio notification
      // For web: use dart:html AudioElement
      // For native: use audioplayers package
    } catch (e) {
      debugPrint('Failed to play notification sound: $e');
    }
  }

  Future<void> _admitGuest(ExternalSession guest) async {
    // Check if already processed by another participant
    if (_processedSessions.contains(guest.sessionId)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${guest.displayName} was already admitted by another participant',
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    try {
      await _externalService.admitGuest(
        guest.sessionId,
        meetingId: widget.meetingId,
      );

      if (mounted) {
        setState(() => _processedSessions.add(guest.sessionId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✓ Admitted ${guest.displayName}'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      final errorMessage = e.toString();
      if (errorMessage.contains('already admitted') ||
          errorMessage.contains('already declined')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${guest.displayName} was already processed by another participant',
              ),
              backgroundColor: Colors.orange,
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to admit guest: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _declineGuest(ExternalSession guest) async {
    // Check if already processed by another participant
    if (_processedSessions.contains(guest.sessionId)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${guest.displayName} was already processed by another participant',
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    try {
      await _externalService.declineGuest(
        guest.sessionId,
        meetingId: widget.meetingId,
      );

      if (mounted) {
        setState(() => _processedSessions.add(guest.sessionId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Declined ${guest.displayName}')),
        );
      }
    } catch (e) {
      final errorMessage = e.toString();
      if (errorMessage.contains('already admitted') ||
          errorMessage.contains('already declined')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${guest.displayName} was already processed by another participant',
              ),
              backgroundColor: Colors.orange,
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to decline guest: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_waitingGuests.isEmpty && !_isLoading) {
      return const SizedBox.shrink();
    }

    return Positioned(
      top: 16,
      right: 16,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: _isExpanded ? 320 : 200,
          constraints: BoxConstraints(maxHeight: _isExpanded ? 400 : 60),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(context).colorScheme.primary,
              width: 2,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(),
              if (_isExpanded) ...[
                const Divider(height: 1),
                Expanded(child: _buildGuestList()),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return InkWell(
      onTap: () => setState(() => _isExpanded = !_isExpanded),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              Icons.person_add,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Waiting Guests',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            // Badge count
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${_waitingGuests.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              _isExpanded ? Icons.expand_less : Icons.expand_more,
              color: Colors.grey[600],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGuestList() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_waitingGuests.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'No guests waiting',
            style: TextStyle(color: Colors.grey[600]),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: _waitingGuests.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final guest = _waitingGuests[index];
        return _buildGuestItem(guest);
      },
    );
  }

  Widget _buildGuestItem(ExternalSession guest) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: Text(
                  guest.displayName[0].toUpperCase(),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      guest.displayName,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      _formatWaitTime(guest.createdAt),
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _declineGuest(guest),
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('Decline'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _admitGuest(guest),
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Admit'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatWaitTime(DateTime createdAt) {
    final duration = DateTime.now().difference(createdAt);

    if (duration.inMinutes < 1) {
      return 'Just now';
    } else if (duration.inMinutes < 60) {
      return '${duration.inMinutes}m ago';
    } else {
      return '${duration.inHours}h ago';
    }
  }
}
