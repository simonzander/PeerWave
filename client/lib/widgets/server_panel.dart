import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/server_config_native.dart';
import '../services/device_identity_service.dart';
import '../providers/unread_messages_provider.dart';

/// Discord-like server panel for native clients
/// Shows list of connected servers with icons and notification badges
/// Far-left sidebar (~70px wide)
class ServerPanel extends StatefulWidget {
  final Function(String serverId)? onServerSelected;

  const ServerPanel({Key? key, this.onServerSelected}) : super(key: key);

  @override
  State<ServerPanel> createState() => _ServerPanelState();
}

class _ServerPanelState extends State<ServerPanel> {
  List<ServerConfig> _servers = [];
  String? _activeServerId;
  UnreadMessagesProvider? _unreadProvider;

  @override
  void initState() {
    super.initState();
    _loadServers();
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
    _unreadProvider?.removeListener(_updateActiveServerBadge);
    super.dispose();
  }

  void _updateActiveServerBadge() {
    if (_activeServerId != null && _unreadProvider != null) {
      final total =
          _unreadProvider!.totalChannelUnread +
          _unreadProvider!.totalDirectMessageUnread +
          _unreadProvider!.totalActivityNotifications;
      setState(() {
        final index = _servers.indexWhere((s) => s.id == _activeServerId);
        if (index != -1) {
          _servers[index].unreadCount = total;
        }
      });
    }
  }

  void _loadServers() {
    setState(() {
      _servers = ServerConfigService.getAllServers();
      _activeServerId = ServerConfigService.getActiveServer()?.id;
    });
    
    // Load server metadata (name and picture) for all servers
    for (final server in _servers) {
      ServerConfigService.updateServerMetadata(server.id).then((_) {
        if (mounted) {
          setState(() {
            _servers = ServerConfigService.getAllServers();
          });
        }
      });
    }
  }

  Future<void> _switchServer(String serverId) async {
    // Save current server's unread count before switching
    if (_unreadProvider != null) {
      await ServerConfigService.saveCurrentServerUnreadCount(
        _unreadProvider!.totalChannelUnread,
        _unreadProvider!.totalDirectMessageUnread,
        _unreadProvider!.totalActivityNotifications,
      );
    }

    await ServerConfigService.setActiveServer(serverId);
    await ServerConfigService.resetUnreadCount(serverId);
    
    // Switch device identity for native (multi-server support)
    if (!kIsWeb) {
      final server = ServerConfigService.getServerById(serverId);
      if (server != null) {
        final switched = await DeviceIdentityService.instance.switchToServer(server.serverUrl);
        if (!switched) {
          debugPrint('[ServerPanel] Warning: Could not switch to server identity for ${server.serverUrl}');
        }
      }
    }

    setState(() {
      _activeServerId = serverId;
    });

    widget.onServerSelected?.call(serverId);

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

  void _showEditServerDialog(ServerConfig server) {
    final controller = TextEditingController(
      text: server.displayName ?? server.getDisplayName(),
    );

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Server'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Display Name',
            hintText: 'Enter server name',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              await ServerConfigService.updateDisplayName(
                server.id,
                controller.text,
              );
              _loadServers();
              if (mounted) {
                Navigator.pop(context);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
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
        context.go('/server-selection');
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
            const SnackBar(
              content: Text('Server deleted successfully'),
              backgroundColor: Colors.green,
            ),
          );
        }

        // If no servers left, go to server selection
        if (_servers.isEmpty && mounted) {
          context.go('/server-selection');
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

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: _ServerIcon(
                    server: server,
                    isActive: isActive,
                    hasUnread: hasUnread,
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
                  extra: {'isAddingServer': true},
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
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ServerIcon({
    required this.server,
    required this.isActive,
    required this.hasUnread,
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

          // Notification badge
          if (hasUnread)
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
          color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
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
