import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/api_service.dart';

// Data model for session information
class SessionInfo {
  final String id;
  final String deviceName;
  final String? browser;
  final String? os;
  final String? location;
  final String? ipAddress;
  final DateTime lastActive;
  final DateTime? expiresAt;
  final bool isCurrent;

  SessionInfo({
    required this.id,
    required this.deviceName,
    this.browser,
    this.os,
    this.location,
    this.ipAddress,
    required this.lastActive,
    this.expiresAt,
    required this.isCurrent,
  });

  factory SessionInfo.fromJson(Map<String, dynamic> json) {
    return SessionInfo(
      id: json['id'] as String,
      deviceName: json['device_name'] as String,
      browser: json['browser'] as String?,
      os: json['os'] as String?,
      location: json['location'] as String?,
      ipAddress: json['ip_address'] as String?,
      lastActive: DateTime.parse(json['last_active'] as String),
      expiresAt: json['expires_at'] != null
          ? DateTime.parse(json['expires_at'] as String)
          : null,
      isCurrent: json['is_current'] as bool? ?? false,
    );
  }
}

class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key});

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  List<SessionInfo> _sessions = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await ApiService.instance.get('/sessions/list');
      if (response.statusCode == 200 && response.data != null) {
        // Handle case where response.data might be a String (error) or Map
        if (response.data is String) {
          setState(() {
            _error = response.data as String;
            _loading = false;
          });
          return;
        }

        final data = response.data as Map<String, dynamic>;
        final sessionsJson = data['sessions'] as List<dynamic>;

        setState(() {
          _sessions = sessionsJson
              .map((json) => SessionInfo.fromJson(json as Map<String, dynamic>))
              .toList();
          _loading = false;
        });
      } else {
        setState(() {
          _error = 'Failed to load sessions';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error loading sessions: $e';
        _loading = false;
      });
    }
  }

  Future<void> _revokeSession(String sessionId, bool isCurrent) async {
    if (isCurrent) {
      // Confirm revoking current session
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Revoke Current Session?'),
          content: const Text(
            'This will log you out from this device. You will need to log in again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                'Revoke',
                style: TextStyle(color: Theme.of(context).colorScheme.onError),
              ),
            ),
          ],
        ),
      );

      if (confirm != true) return;
    }

    try {
      final response = await ApiService.instance.post(
        '/sessions/revoke',
        data: {'sessionId': sessionId},
      );

      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                isCurrent ? 'Logged out successfully' : 'Session revoked',
              ),
              backgroundColor: Theme.of(context).colorScheme.primary,
            ),
          );
        }

        if (isCurrent) {
          // Current session revoked - user will be redirected by logout logic
          return;
        }

        // Reload sessions list
        await _loadSessions();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Failed to revoke session'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _revokeAllOtherSessions() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke All Other Sessions?'),
        content: const Text(
          'This will log you out from all other devices. Your current session will remain active.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'Revoke All',
              style: TextStyle(color: Theme.of(context).colorScheme.onError),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final response = await ApiService.instance.post(
        '/sessions/revoke-all',
        data: {},
      );

      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('All other sessions revoked'),
              backgroundColor: Theme.of(context).colorScheme.primary,
            ),
          );
        }

        // Reload sessions list
        await _loadSessions();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Failed to revoke sessions'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (_loading) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: colorScheme.error),
              const SizedBox(height: 16),
              Text(
                _error!,
                style: textTheme.bodyLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _loadSessions,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final otherSessionsCount = _sessions.where((s) => !s.isCurrent).length;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Column(
        children: [
          // Header with title and revoke all button
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              border: Border(
                bottom: BorderSide(color: colorScheme.outlineVariant, width: 1),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Active Sessions',
                        style: textTheme.titleLarge?.copyWith(
                          color: colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_sessions.length} active ${_sessions.length == 1 ? "session" : "sessions"}',
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (otherSessionsCount > 0)
                  FilledButton.tonalIcon(
                    onPressed: _revokeAllOtherSessions,
                    icon: const Icon(Icons.logout),
                    label: const Text('Revoke All Others'),
                    style: FilledButton.styleFrom(
                      foregroundColor: colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),

          // Sessions list
          Expanded(
            child: _sessions.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.devices_other,
                          size: 64,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No active sessions',
                          style: textTheme.titleMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _loadSessions,
                    child: ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _sessions.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final session = _sessions[index];
                        return _SessionCard(
                          session: session,
                          onRevoke: () =>
                              _revokeSession(session.id, session.isCurrent),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  final SessionInfo session;
  final VoidCallback onRevoke;

  const _SessionCard({required this.session, required this.onRevoke});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      elevation: 0,
      color: session.isCurrent
          ? colorScheme.primaryContainer
          : colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: session.isCurrent
              ? colorScheme.primary
              : colorScheme.outlineVariant,
          width: session.isCurrent ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Device name and current badge
            Row(
              children: [
                Icon(
                  _getDeviceIcon(session.deviceName),
                  size: 24,
                  color: session.isCurrent
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurface,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.deviceName,
                        style: textTheme.titleMedium?.copyWith(
                          color: session.isCurrent
                              ? colorScheme.onPrimaryContainer
                              : colorScheme.onSurface,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (session.browser != null || session.os != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          [
                            session.browser,
                            session.os,
                          ].where((e) => e != null).join(' • '),
                          style: textTheme.bodySmall?.copyWith(
                            color: session.isCurrent
                                ? colorScheme.onPrimaryContainer.withOpacity(
                                    0.7,
                                  )
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (session.isCurrent)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'Current',
                      style: textTheme.labelSmall?.copyWith(
                        color: colorScheme.onPrimary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  )
                else
                  IconButton(
                    onPressed: onRevoke,
                    icon: const Icon(Icons.delete_outline),
                    color: colorScheme.error,
                    tooltip: 'Revoke session',
                  ),
              ],
            ),

            const SizedBox(height: 12),

            // Location and IP
            if (session.location != null || session.ipAddress != null)
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  if (session.location != null)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.location_on_outlined,
                          size: 16,
                          color: session.isCurrent
                              ? colorScheme.onPrimaryContainer.withOpacity(0.7)
                              : colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          session.location!,
                          style: textTheme.bodySmall?.copyWith(
                            color: session.isCurrent
                                ? colorScheme.onPrimaryContainer.withOpacity(
                                    0.7,
                                  )
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  if (session.ipAddress != null)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.network_check,
                          size: 16,
                          color: session.isCurrent
                              ? colorScheme.onPrimaryContainer.withOpacity(0.7)
                              : colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          session.ipAddress!,
                          style: textTheme.bodySmall?.copyWith(
                            color: session.isCurrent
                                ? colorScheme.onPrimaryContainer.withOpacity(
                                    0.7,
                                  )
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                ],
              ),

            const SizedBox(height: 12),
            Divider(
              height: 1,
              color: session.isCurrent
                  ? colorScheme.onPrimaryContainer.withOpacity(0.2)
                  : colorScheme.outlineVariant,
            ),
            const SizedBox(height: 12),

            // Last active and expiration
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Icon(
                        Icons.access_time,
                        size: 16,
                        color: session.isCurrent
                            ? colorScheme.onPrimaryContainer.withOpacity(0.7)
                            : colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Last active: ${_formatLastActive(session.lastActive)}',
                        style: textTheme.bodySmall?.copyWith(
                          color: session.isCurrent
                              ? colorScheme.onPrimaryContainer.withOpacity(0.7)
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (session.expiresAt != null)
                  Row(
                    children: [
                      Icon(
                        Icons.event_outlined,
                        size: 16,
                        color: session.isCurrent
                            ? colorScheme.onPrimaryContainer.withOpacity(0.7)
                            : colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Expires: ${_formatExpiration(session.expiresAt!)}',
                        style: textTheme.bodySmall?.copyWith(
                          color: session.isCurrent
                              ? colorScheme.onPrimaryContainer.withOpacity(0.7)
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _getDeviceIcon(String deviceName) {
    final lower = deviceName.toLowerCase();
    if (lower.contains('mobile') ||
        lower.contains('android') ||
        lower.contains('iphone') ||
        lower.contains('ios')) {
      return Icons.phone_android;
    } else if (lower.contains('tablet') || lower.contains('ipad')) {
      return Icons.tablet;
    } else if (lower.contains('mac')) {
      return Icons.laptop_mac;
    } else if (lower.contains('windows')) {
      return Icons.laptop_windows;
    } else if (lower.contains('linux')) {
      return Icons.computer;
    } else {
      return Icons.devices;
    }
  }

  String _formatLastActive(DateTime lastActive) {
    final now = DateTime.now();
    final difference = now.difference(lastActive);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes} min ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours} hr ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else {
      return DateFormat('MMM d, yyyy').format(lastActive);
    }
  }

  String _formatExpiration(DateTime expiresAt) {
    final now = DateTime.now();
    final difference = expiresAt.difference(now);

    if (difference.isNegative) {
      return 'Expired';
    } else if (difference.inDays < 1) {
      return 'Today';
    } else if (difference.inDays < 7) {
      return 'In ${difference.inDays} days';
    } else {
      return DateFormat('MMM d, yyyy').format(expiresAt);
    }
  }
}
