import 'package:flutter/material.dart';
import '../services/api_service.dart';

class MeetingRsvpConfirmationScreen extends StatefulWidget {
  final String meetingId;
  final String status;
  final String email;
  final String token;

  const MeetingRsvpConfirmationScreen({
    super.key,
    required this.meetingId,
    required this.status,
    required this.email,
    required this.token,
  });

  @override
  State<MeetingRsvpConfirmationScreen> createState() =>
      _MeetingRsvpConfirmationScreenState();
}

class _MeetingRsvpConfirmationScreenState
    extends State<MeetingRsvpConfirmationScreen> {
  bool _loading = true;
  String? _error;

  String? _meetingTitle;
  DateTime? _startTime;
  DateTime? _endTime;

  @override
  void initState() {
    super.initState();
    _confirm();
  }

  Future<void> _confirm() async {
    try {
      ApiService.init();

      final response = await ApiService.get(
        '/api/meetings/${widget.meetingId}/rsvp/${widget.status}',
        queryParameters: {
          'email': widget.email,
          'token': widget.token,
          'format': 'json',
        },
      );

      final data = response.data;
      if (data is Map) {
        final ok = data['success'] == true;
        if (!ok) {
          throw Exception(data['error'] ?? 'RSVP failed');
        }

        setState(() {
          _meetingTitle = data['meetingTitle']?.toString();
          final startRaw = data['startTime']?.toString();
          final endRaw = data['endTime']?.toString();
          _startTime = startRaw != null ? DateTime.tryParse(startRaw) : null;
          _endTime = endRaw != null ? DateTime.tryParse(endRaw) : null;
          _loading = false;
        });
      } else {
        throw Exception('Unexpected response');
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Meeting RSVP')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? _ErrorView(message: _error!)
            : _SuccessView(
                meetingTitle: _meetingTitle ?? widget.meetingId,
                status: widget.status,
                startTime: _startTime,
                endTime: _endTime,
                textStyle: theme.textTheme,
              ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  const _ErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Could not confirm RSVP',
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _SuccessView extends StatelessWidget {
  final String meetingTitle;
  final String status;
  final DateTime? startTime;
  final DateTime? endTime;
  final TextTheme textStyle;

  const _SuccessView({
    required this.meetingTitle,
    required this.status,
    required this.startTime,
    required this.endTime,
    required this.textStyle,
  });

  @override
  Widget build(BuildContext context) {
    String? timeRange;
    if (startTime != null && endTime != null) {
      final start = MaterialLocalizations.of(
        context,
      ).formatFullDate(startTime!.toLocal());
      final startT = MaterialLocalizations.of(
        context,
      ).formatTimeOfDay(TimeOfDay.fromDateTime(startTime!.toLocal()));
      final endT = MaterialLocalizations.of(
        context,
      ).formatTimeOfDay(TimeOfDay.fromDateTime(endTime!.toLocal()));
      timeRange = '$start, $startT – $endT';
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('RSVP confirmed', style: textStyle.headlineSmall),
            const SizedBox(height: 12),
            Text('You responded: $status', style: textStyle.bodyLarge),
            const SizedBox(height: 16),
            Text(meetingTitle, style: textStyle.titleMedium),
            if (timeRange != null) ...[
              const SizedBox(height: 8),
              Text(timeRange, style: textStyle.bodyMedium),
            ],
          ],
        ),
      ),
    );
  }
}
