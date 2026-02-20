import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/server_config_native.dart';
import '../services/socket_service_native.dart';
import '../services/device_identity_service.dart';
import '../services/user_profile_service.dart';
import '../services/storage/sqlite_message_store.dart';
import '../providers/unread_messages_provider.dart';
import '../theme/semantic_colors.dart';
import '../core/events/event_bus.dart';

/// Discord-like server panel for native clients
/// Shows list of connected servers with icons and notification badges
/// Far-left sidebar (~70px wide)
class ServerPanel extends StatefulWidget {
  final Function(String serverId)? onServerSelected;

  const ServerPanel({super.key, this.onServerSelected});

  @override
  State<ServerPanel> createState() => _ServerPanelState();
}

class _ServerPanelState extends State<ServerPanel> {
  List<ServerConfig> _servers = [];
  String? _activeServerId;
  UnreadMessagesProvider? _unreadProvider;
  Timer? _statusTimer;
  Map<String, _ServerConnectionStatus> _statusCache = {};

  @override
  void initState() {
    super.initState();
    _loadServers();
    _refreshStatusIfChanged();
    _statusTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _refreshStatusIfChanged(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Setup UnreadMessagesProvider listener
    if (_unreadProvider == null) {
      _unreadProvider = context.watch<UnreadMessagesProvider>();
      _unreadProvider!.addListener(_updateActiveServerBadge);
    }
    // Reload servers when dependencies change (e.g., after navigation)
    _loadServers();
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _unreadProvider?.removeListener(_updateActiveServerBadge);
    super.dispose();
  }

  _ServerConnectionStatus _getServerStatus(String serverId) {
    final socketService = SocketService.instance;
    if (socketService.isServerAuthError(serverId)) {
      return _ServerConnectionStatus.authError;
    }
    if (socketService.isServerConnecting(serverId)) {
      return _ServerConnectionStatus.connecting;
    }
    if (socketService.isServerConnected(serverId)) {
      return _ServerConnectionStatus.connected;
    }
    return _ServerConnectionStatus.offline;
  }

  void _updateActiveServerBadge() {
    // Update badges for all servers using per-server unread counts
    if (_unreadProvider != null) {
      setState(() {
        for (final server in _servers) {
          final unreadCount = _unreadProvider!.getTotalUnreadForServer(
            server.id,
          );
          final index = _servers.indexWhere((s) => s.id == server.id);
          if (index != -1) {
            _servers[index].unreadCount = unreadCount;
          }
        }
      });
    }
  }

  void _loadServers() {
    final newServers = ServerConfigService.getAllServers();
    final newActiveId = ServerConfigService.getActiveServer()?.id;

    setState(() {
      _servers = newServers;
      _activeServerId = newActiveId;
    });

    _refreshStatusIfChanged();

    // Load server metadata (name and picture) for all servers - batch update
    final futures = <Future>[];
    for (final server in _servers) {
      futures.add(ServerConfigService.updateServerMetadata(server.id));
    }

    Future.wait(futures).then((_) {
      if (mounted) {
        setState(() {
          _servers = ServerConfigService.getAllServers();

          // Load unread counts for all servers and update badges
          if (_unreadProvider != null) {
            for (final server in _servers) {
              final unreadCount = _unreadProvider!.getTotalUnreadForServer(
                server.id,
              );
              final index = _servers.indexWhere((s) => s.id == server.id);
              if (index != -1) {
                _servers[index].unreadCount = unreadCount;
              }
            }
          }
        });
      }
    });
  }

  void _refreshStatusIfChanged() {
    if (!mounted) return;
    final servers = ServerConfigService.getAllServers();
    final nextStatus = <String, _ServerConnectionStatus>{};
    var changed = servers.length != _statusCache.length;

    for (final server in servers) {
      final status = _getServerStatus(server.id);
      nextStatus[server.id] = status;
      if (!changed && _statusCache[server.id] != status) {
        changed = true;
      }
    }

    if (changed) {
      setState(() {
        _statusCache = nextStatus;
      });
    } else {
      _statusCache = nextStatus;
    }
  }

  Future<void> _switchServer(String serverId) async {
    // Load unread counts for the new server
    if (_unreadProvider != null) {
      try {
        await _unreadProvider!.loadFromStorage(serverId);
        debugPrint('[ServerPanel] ✓ Unread counts loaded for new server');
      } catch (e) {
        debugPrint('[ServerPanel] ⚠️ Failed to load unread counts: $e');
      }
    }

    // TODO: Database needs per-server connections, can't close while other servers active
    // await DatabaseHelper.close();

    await ServerConfigService.setActiveServer(serverId);
    await ServerConfigService.resetUnreadCount(serverId);

    // Switch device identity for native (multi-server support)
    if (!kIsWeb) {
      final server = ServerConfigService.getServerById(serverId);
      if (server != null) {
        final switched = await DeviceIdentityService.instance.switchToServer(
          server.serverUrl,
        );
        if (!switched) {
          debugPrint(
            '[ServerPanel] Warning: Could not switch to server identity for ${server.serverUrl}',
          );
        }
      }
    }

    // Reload own profile for the new server (profiles are now cached per-server)
    try {
      await UserProfileService.instance.loadOwnProfile();
      debugPrint('[ServerPanel] ✓ Own profile loaded for new server');
    } catch (e) {
      debugPrint('[ServerPanel] ⚠️ Failed to load own profile: $e');
    }

    setState(() {
      _activeServerId = serverId;
    });

    widget.onServerSelected?.call(serverId);

    // Emit server switched event for UI components to reload data
    EventBus.instance.emit(AppEvent.serverSwitched, <String, dynamic>{
      'serverId': serverId,
    });
    debugPrint('[ServerPanel] ✓ Server switched event emitted: $serverId');

    // Reload server list to refresh UI and update all badges
    await Future.delayed(
      Duration(milliseconds: 100),
    ); // Small delay for state to settle
    _loadServers();

    // Trigger reload of the app
    if (mounted) {
      context.go('/app/activities');
    }
  }

  void _showServerMenu(BuildContext context, ServerConfig server) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                Icons.mark_email_read,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: const Text('Mark All as Read'),
              subtitle: const Text('Clear all unread badges'),
              onTap: () async {
                Navigator.pop(context);
                await _markAllAsRead(server);
              },
            ),
            const Divider(),
            ListTile(
              leading: Icon(
                Icons.logout,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Logout',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () async {
                Navigator.pop(context);
                await _logoutFromServer(server);
              },
            ),
            const Divider(),
            ListTile(
              leading: Icon(
                Icons.delete_forever,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Delete Server',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              subtitle: const Text('Remove all data'),
              onTap: () async {
                Navigator.pop(context);
                await _deleteServer(server);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _markAllAsRead(ServerConfig server) async {
    try {
      debugPrint('[ServerPanel] Marking all as read for server: ${server.id}');

      // Switch to this server temporarily if not already active
      final previousServerId = _activeServerId;
      final needsSwitch = _activeServerId != server.id;

      if (needsSwitch) {
        await ServerConfigService.setActiveServer(server.id);
        setState(() {
          _activeServerId = server.id;
        });
      }

      // Clear unread counts in provider (server-aware)
      if (_unreadProvider != null) {
        _unreadProvider!.resetAll();
        debugPrint('[ServerPanel] ✓ Reset all unread counts in provider');
      }

      // Mark all notifications as read in database
      final SqliteMessageStore messageStore =
          await SqliteMessageStore.getInstance();
      await messageStore.markAllNotificationsAsRead();
      debugPrint(
        '[ServerPanel] ✓ Marked all notifications as read in database',
      );

      // Switch back to previous server if needed
      if (needsSwitch && previousServerId != null) {
        await ServerConfigService.setActiveServer(previousServerId);
        setState(() {
          _activeServerId = previousServerId;
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'All notifications marked as read for ${server.getDisplayName()}',
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('[ServerPanel] Error marking all as read: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to mark as read: $e')));
      }
    }
  }

  Future<void> _logoutFromServer(ServerConfig server) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout from Server'),
        content: Text(
          'Are you sure you want to logout from ${server.getDisplayName()}?\n\n'
          'Your local data will be preserved but you will need a new magic key to reconnect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await ServerConfigService.removeServer(server.id);
      _loadServers();

      // If no servers left, go to server selection
      if (_servers.isEmpty && mounted) {
        if (Platform.isAndroid || Platform.isIOS) {
          context.go('/mobile-server-selection');
        } else {
          context.go('/server-selection');
        }
      }
    }
  }

  Future<void> _deleteServer(ServerConfig server) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Server'),
        content: Text(
          'Are you sure you want to PERMANENTLY DELETE ${server.getDisplayName()}?\n\n'
          '⚠️ This will remove:\n'
          '• All messages and channels\n'
          '• All files and media\n'
          '• Encryption keys\n'
          '• SQLite databases\n'
          '• All local data\n\n'
          'This action CANNOT be undone!',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete Permanently'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      // Show loading
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Deleting server data...')),
        );
      }

      try {
        await ServerConfigService.deleteServerWithData(server.id);
        _loadServers();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Server deleted successfully'),
              backgroundColor: Theme.of(context).colorScheme.success,
            ),
          );
        }

        // If no servers left, go to server selection
        if (_servers.isEmpty && mounted) {
          if (Platform.isAndroid || Platform.isIOS) {
            context.go('/mobile-server-selection');
          } else {
            context.go('/server-selection');
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting server: $e'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        children: [
          // Servers list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _servers.length,
              itemBuilder: (context, index) {
                final server = _servers[index];
                final isActive = server.id == _activeServerId;
                final hasUnread = server.unreadCount > 0;
                final status =
                    _statusCache[server.id] ?? _getServerStatus(server.id);

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: _ServerIcon(
                    server: server,
                    isActive: isActive,
                    hasUnread: hasUnread,
                    status: status,
                    onTap: () => _switchServer(server.id),
                    onLongPress: () => _showServerMenu(context, server),
                  ),
                );
              },
            ),
          ),

          // Divider
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Divider(
              height: 2,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),

          // Add Server Button
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _AddServerButton(
              onTap: () {
                context.push(
                  '/server-selection',
                  extra: <String, dynamic>{'isAddingServer': true},
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Server icon widget with notification badge
class _ServerIcon extends StatelessWidget {
  final ServerConfig server;
  final bool isActive;
  final bool hasUnread;
  final _ServerConnectionStatus status;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ServerIcon({
    required this.server,
    required this.isActive,
    required this.hasUnread,
    required this.status,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress, // Right-click support for desktop
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Active indicator (left bar)
          if (isActive)
            Positioned(
              left: 0,
              child: Container(
                width: 4,
                height: 48,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(4),
                  ),
                ),
              ),
            ),

          // Server icon
          Center(
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: isActive
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(isActive ? 16 : 24),
                border: Border.all(
                  color: isActive
                      ? Theme.of(context).colorScheme.primary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Center(
                child: _buildServerImage(context, server, isActive),
              ),
            ),
          ),

          if (status != _ServerConnectionStatus.connected)
            Positioned(
              right: 8,
              top: 0,
              child: _buildStatusIcon(context, status),
            )
          else if (hasUnread)
            Positioned(
              right: 8,
              top: 0,
              child: Container(
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.error,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    width: 2,
                  ),
                ),
                child: Center(
                  child: Text(
                    server.unreadCount > 99
                        ? '99+'
                        : server.unreadCount.toString(),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onError,
                      fontWeight: FontWeight.bold,
                      fontSize: 10,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusIcon(
    BuildContext context,
    _ServerConnectionStatus status,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final icon = switch (status) {
      _ServerConnectionStatus.connecting => Icons.sync,
      _ServerConnectionStatus.offline => Icons.close,
      _ServerConnectionStatus.authError => Icons.warning_amber_rounded,
      _ServerConnectionStatus.connected => Icons.check,
    };
    final color = switch (status) {
      _ServerConnectionStatus.connecting => colorScheme.secondary,
      _ServerConnectionStatus.offline => colorScheme.error,
      _ServerConnectionStatus.authError => colorScheme.error,
      _ServerConnectionStatus.connected => colorScheme.tertiary,
    };

    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        shape: BoxShape.circle,
        border: Border.all(color: colorScheme.surface, width: 1.5),
      ),
      child: Center(child: Icon(icon, size: 12, color: color)),
    );
  }

  /// Build server image with priority: serverPicture > iconPath > first letter
  Widget _buildServerImage(
    BuildContext context,
    ServerConfig server,
    bool isActive,
  ) {
    // Priority 1: Server picture from /client/meta (base64)
    if (server.serverPicture != null && server.serverPicture!.isNotEmpty) {
      try {
        final base64Data = server.serverPicture!.contains(',')
            ? server.serverPicture!.split(',').last
            : server.serverPicture!;
        final bytes = base64Decode(base64Data);
        return ClipRRect(
          borderRadius: BorderRadius.circular(isActive ? 14 : 22),
          child: Image.memory(
            bytes,
            width: 48,
            height: 48,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              // Fallback to letter if image fails to decode
              return _buildLetterAvatar(context, server, isActive);
            },
          ),
        );
      } catch (e) {
        // Fallback to next priority if base64 decode fails
      }
    }

    // Priority 2: Local icon path (custom icon)
    if (server.iconPath != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(isActive ? 14 : 22),
        child: Image.file(
          server.iconPath! as dynamic,
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            // Fallback to letter if file fails to load
            return _buildLetterAvatar(context, server, isActive);
          },
        ),
      );
    }

    // Priority 3: First letter of server name (NOT hostname)
    return _buildLetterAvatar(context, server, isActive);
  }

  /// Build letter avatar for server
  Widget _buildLetterAvatar(
    BuildContext context,
    ServerConfig server,
    bool isActive,
  ) {
    return Text(
      server.getShortName(),
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        color: isActive
            ? Theme.of(context).colorScheme.onPrimaryContainer
            : Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}

enum _ServerConnectionStatus { connected, connecting, offline, authError }

/// Add server button
class _AddServerButton extends StatelessWidget {
  final VoidCallback onTap;

  const _AddServerButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
            width: 2,
            style: BorderStyle.solid,
          ),
        ),
        child: Icon(
          Icons.add,
          color: Theme.of(context).colorScheme.primary,
          size: 28,
        ),
      ),
    );
  }
}
