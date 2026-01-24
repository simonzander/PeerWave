import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:convert' show base64Decode;
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/server_config_web.dart'
    if (dart.library.io) '../services/server_config_native.dart';
import '../services/logout_service.dart';
import '../services/storage/sqlite_message_store.dart';
import '../providers/unread_messages_provider.dart';
import 'license_footer.dart';

/// Unified drawer widget for mobile screens across all app states
/// Shows contextual menu items based on authentication status and current route
class AppDrawer extends StatefulWidget {
  final bool isAuthenticated;
  final String? currentRoute;

  const AppDrawer({
    super.key,
    required this.isAuthenticated,
    this.currentRoute,
  });

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  UnreadMessagesProvider? _unreadProvider;

  @override
  void initState() {
    super.initState();
    // Setup unread provider listener after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !kIsWeb) {
        _unreadProvider = context.read<UnreadMessagesProvider>();
        _unreadProvider?.addListener(_onUnreadCountsChanged);
      }
    });
  }

  @override
  void dispose() {
    _unreadProvider?.removeListener(_onUnreadCountsChanged);
    super.dispose();
  }

  /// Handle unread counts changes - rebuild to show updated badges
  void _onUnreadCountsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Check if current route is a registration page requiring exit confirmation
  bool get _isRegistrationPage {
    if (widget.currentRoute == null) return false;
    return widget.currentRoute!.startsWith('/register/backupcode') ||
        widget.currentRoute!.startsWith('/register/webauthn') ||
        widget.currentRoute!.startsWith('/register/profile');
  }

  /// Check if we're on mobile platform
  bool get _isMobile {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  /// Get target route for "Add Server" based on platform
  String get _addServerRoute {
    return _isMobile ? '/mobile-server-selection' : '/server-selection';
  }

  /// Show exit confirmation dialog for registration pages
  Future<void> _showExitDialog(
    BuildContext context,
    VoidCallback onConfirm,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        final colorScheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: Text(
            'Leave Registration?',
            style: TextStyle(color: colorScheme.onSurface),
          ),
          content: Text(
            'Your progress will be lost.',
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text('Stay', style: TextStyle(color: colorScheme.primary)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: colorScheme.error),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                'Leave Registration',
                style: TextStyle(color: colorScheme.onError),
              ),
            ),
          ],
        );
      },
    );

    if (result == true && context.mounted) {
      onConfirm();
    }
  }

  /// Handle navigation with exit confirmation for registration pages
  void _navigateWithConfirmation(
    BuildContext context,
    String route, {
    bool closeDrawer = true,
  }) {
    if (_isRegistrationPage) {
      _showExitDialog(context, () {
        if (closeDrawer) Navigator.pop(context);
        if (context.mounted) {
          context.go(route);
        }
      });
    } else {
      if (closeDrawer) Navigator.pop(context);
      if (context.mounted) {
        context.go(route);
      }
    }
  }

  /// Show server context menu with mark as read, logout, and delete options
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

  /// Mark all notifications as read for a server
  Future<void> _markAllAsRead(ServerConfig server) async {
    try {
      debugPrint('[AppDrawer] Marking all as read for server: ${server.id}');

      // Get current active server to restore later
      final activeServer = ServerConfigService.getActiveServer();
      final needsSwitch = activeServer?.id != server.id;

      // Switch to target server if needed
      if (needsSwitch) {
        await ServerConfigService.setActiveServer(server.id);
      }

      // Clear unread counts in provider
      if (context.mounted) {
        final unreadProvider = context.read<UnreadMessagesProvider>();
        unreadProvider.resetAll();
        debugPrint('[AppDrawer] ✓ Reset all unread counts in provider');
      }

      // Mark all notifications as read in database
      final messageStore = await SqliteMessageStore.getInstance();
      await messageStore.markAllNotificationsAsRead();
      debugPrint('[AppDrawer] ✓ Marked all notifications as read in database');

      // Switch back to previous server if needed
      if (needsSwitch && activeServer != null) {
        await ServerConfigService.setActiveServer(activeServer.id);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'All notifications marked as read for ${server.getDisplayName()}',
            ),
          ),
        );

        // Refresh drawer to update any unread badge UI
        setState(() {});
      }
    } catch (e) {
      debugPrint('[AppDrawer] Error marking all as read: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to mark as read: $e')));
      }
    }
  }

  /// Logout from a server
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

    if (confirm == true && mounted) {
      // Check if we're removing the active server
      final activeServer = ServerConfigService.getActiveServer();
      final isRemovingActive = activeServer?.id == server.id;

      // Remove the server
      await ServerConfigService.removeServer(server.id);

      // Get remaining servers
      final servers = ServerConfigService.getAllServers();

      if (servers.isEmpty && mounted) {
        // No servers left - go to server selection
        if (_isMobile) {
          context.go('/mobile-server-selection');
        } else {
          context.go('/server-selection');
        }
      } else if (isRemovingActive && servers.isNotEmpty && mounted) {
        // Removed active server - switch to first remaining server
        await ServerConfigService.setActiveServer(servers.first.id);
        debugPrint(
          '[AppDrawer] Switched to ${servers.first.getDisplayName()} after logout',
        );

        // Force rebuild by navigating
        context.go('/app/activities');
      } else if (mounted) {
        // Removed non-active server - just refresh
        setState(() {}); // Trigger rebuild of drawer
      }
    }
  }

  /// Delete a server permanently
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

    if (confirm == true && mounted) {
      try {
        // Check if we're deleting the active server
        final activeServer = ServerConfigService.getActiveServer();
        final isDeletingActive = activeServer?.id == server.id;

        // Delete all data for this server
        await ServerConfigService.deleteServerWithData(server.id);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${server.getDisplayName()} deleted permanently'),
            ),
          );
        }

        // Navigate based on remaining servers
        final servers = ServerConfigService.getAllServers();
        if (servers.isEmpty && mounted) {
          // No servers left - go to server selection
          if (_isMobile) {
            context.go('/mobile-server-selection');
          } else {
            context.go('/server-selection');
          }
        } else if (isDeletingActive && servers.isNotEmpty && mounted) {
          // Deleted active server - switch to first remaining server
          await ServerConfigService.setActiveServer(servers.first.id);
          debugPrint(
            '[AppDrawer] Switched to ${servers.first.getDisplayName()} after deletion',
          );

          // Force rebuild by navigating
          context.go('/app/activities');
        } else if (mounted) {
          // Deleted non-active server - just refresh
          setState(() {}); // Trigger rebuild of drawer
        }
      } catch (e) {
        debugPrint('[AppDrawer] Error deleting server: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete server: $e')),
          );
        }
      }
    }
  }

  /// Build unread badge widget
  Widget _buildUnreadBadge(
    int unreadCount,
    ColorScheme colorScheme, {
    bool isSmall = false,
  }) {
    if (unreadCount == 0) return const SizedBox.shrink();

    final size = isSmall ? 14.0 : 16.0;
    final fontSize = isSmall ? 9.0 : 10.0;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colorScheme.error,
        shape: BoxShape.circle,
        border: Border.all(color: colorScheme.surface, width: 1.5),
      ),
      child: Center(
        child: Text(
          unreadCount > 99 ? '99+' : unreadCount.toString(),
          style: TextStyle(
            color: colorScheme.onError,
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
            height: 1.0,
          ),
        ),
      ),
    );
  }

  /// Build server selector with expandable tile
  Widget _buildServerSelector(BuildContext context, ColorScheme colorScheme) {
    // Don't show on web (web doesn't support multi-server)
    if (kIsWeb) {
      return const SizedBox.shrink();
    }

    final servers = ServerConfigService.getAllServers();
    final activeServer = ServerConfigService.getActiveServer();

    // Hide completely when empty
    if (servers.isEmpty) {
      return const SizedBox.shrink();
    }

    return ExpansionTile(
      leading: Stack(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: colorScheme.primaryContainer,
            backgroundImage: activeServer?.serverPicture != null
                ? MemoryImage(
                    base64Decode(activeServer!.serverPicture!.split(',').last),
                  )
                : null,
            child: activeServer?.serverPicture == null
                ? Text(
                    activeServer
                            ?.getDisplayName()
                            .substring(0, 1)
                            .toUpperCase() ??
                        'S',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  )
                : null,
          ),
          // Unread badge
          if (_unreadProvider != null && activeServer != null)
            Positioned(
              right: 0,
              bottom: 0,
              child: _buildUnreadBadge(
                _unreadProvider!.getTotalUnreadForServer(activeServer.id),
                colorScheme,
              ),
            ),
        ],
      ),
      title: Text(
        activeServer?.getDisplayName() ?? 'Select Server',
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      children: servers
          .map(
            (server) => ListTile(
              dense: true,
              leading: Stack(
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    backgroundImage: server.serverPicture != null
                        ? MemoryImage(
                            base64Decode(server.serverPicture!.split(',').last),
                          )
                        : null,
                    child: server.serverPicture == null
                        ? Text(
                            server
                                .getDisplayName()
                                .substring(0, 1)
                                .toUpperCase(),
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurface,
                            ),
                          )
                        : null,
                  ),
                  // Unread badge
                  if (_unreadProvider != null)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: _buildUnreadBadge(
                        _unreadProvider!.getTotalUnreadForServer(server.id),
                        colorScheme,
                        isSmall: true,
                      ),
                    ),
                ],
              ),
              title: Text(
                server.getDisplayName(),
                style: TextStyle(
                  fontWeight: server.id == activeServer?.id
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
              trailing: server.id == activeServer?.id
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          // Show alert icon if not authenticated, check icon if authenticated
                          widget.isAuthenticated
                              ? Icons.check_circle
                              : Icons.warning_amber_rounded,
                          color: widget.isAuthenticated
                              ? colorScheme.primary
                              : colorScheme.error,
                          size: 20,
                        ),
                        IconButton(
                          icon: const Icon(Icons.more_vert, size: 20),
                          onPressed: () => _showServerMenu(context, server),
                          tooltip: 'Server options',
                        ),
                      ],
                    )
                  : IconButton(
                      icon: const Icon(Icons.more_vert, size: 20),
                      onPressed: () => _showServerMenu(context, server),
                      tooltip: 'Server options',
                    ),
              onTap: () async {
                if (server.id != activeServer?.id) {
                  // Switch to a different server
                  Navigator.pop(context); // Close drawer first
                  await ServerConfigService.setActiveServer(server.id);
                  if (context.mounted) {
                    context.go('/app/activities');
                  }
                } else {
                  // Active server clicked
                  if (!widget.isAuthenticated) {
                    // Not authenticated - navigate directly to mobile login
                    if (context.mounted) {
                      Navigator.pop(context);
                      if (_isMobile) {
                        // Mobile: Go to WebAuthn login with server URL
                        context.go('/mobile-webauthn', extra: server.serverUrl);
                      } else {
                        // Desktop: Go to server selection (magic key)
                        context.go('/server-selection');
                      }
                    }
                  } else {
                    // Already authenticated - just navigate to activities
                    if (context.mounted) {
                      Navigator.pop(context);
                      context.go('/app/activities');
                    }
                  }
                }
              },
            ),
          )
          .toList(),
    );
  }

  /// Build "Add Server" list tile
  Widget _buildAddServerTile(BuildContext context, ColorScheme colorScheme) {
    // Check if we're already on the target route
    final isOnTargetRoute = widget.currentRoute == _addServerRoute;

    return ListTile(
      leading: Icon(Icons.add_circle_outline, color: colorScheme.onSurface),
      title: Text('Add Server', style: TextStyle(color: colorScheme.onSurface)),
      onTap: () {
        if (isOnTargetRoute) {
          // Already on target page, just close drawer
          Navigator.pop(context);
        } else {
          _navigateWithConfirmation(context, _addServerRoute);
        }
      },
    );
  }

  /// Build "About" dialog tile
  Widget _buildAboutTile(BuildContext context, ColorScheme colorScheme) {
    return ListTile(
      leading: Icon(Icons.info_outline, color: colorScheme.onSurface),
      title: Text('About', style: TextStyle(color: colorScheme.onSurface)),
      onTap: () {
        Navigator.pop(context);
        showAboutDialog(
          context: context,
          applicationName: 'PeerWave',
          applicationVersion: '1.0.0',
          applicationIcon: Image.asset(
            'assets/images/peerwave.png',
            width: 48,
            height: 48,
          ),
          children: [
            Text(
              'Open-source team collaboration platform',
              style: TextStyle(color: colorScheme.onSurface),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          // Header
          DrawerHeader(
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
            ),
            child: Row(
              children: [
                Image.asset(
                  'assets/images/peerwave.png',
                  width: 40,
                  height: 40,
                ),
                const SizedBox(width: 12),
                Text(
                  'PeerWave',
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

          // Server Selector (always show if servers exist)
          _buildServerSelector(context, colorScheme),

          // Add Server (always show)
          _buildAddServerTile(context, colorScheme),

          // Authenticated items
          if (widget.isAuthenticated) ...[
            ListTile(
              leading: Icon(Icons.people_outline, color: colorScheme.onSurface),
              title: Text(
                'People',
                style: TextStyle(color: colorScheme.onSurface),
              ),
              onTap: () {
                Navigator.pop(context);
                context.go('/app/people');
              },
            ),
            ListTile(
              leading: Icon(Icons.today_outlined, color: colorScheme.onSurface),
              title: Text(
                'Meetings',
                style: TextStyle(color: colorScheme.onSurface),
              ),
              onTap: () {
                Navigator.pop(context);
                context.go('/app/meetings');
              },
            ),
            ListTile(
              leading: Icon(
                Icons.settings_outlined,
                color: colorScheme.onSurface,
              ),
              title: Text(
                'Settings',
                style: TextStyle(color: colorScheme.onSurface),
              ),
              onTap: () {
                Navigator.pop(context);
                context.go('/app/settings/general');
              },
            ),
          ],

          const Divider(),

          // About (always show)
          _buildAboutTile(context, colorScheme),

          // Logout (authenticated only)
          if (widget.isAuthenticated)
            ListTile(
              leading: Icon(Icons.logout, color: colorScheme.onSurface),
              title: Text(
                'Logout',
                style: TextStyle(color: colorScheme.onSurface),
              ),
              onTap: () {
                Navigator.pop(context);
                LogoutService.instance.logout(context, userInitiated: true);
              },
            ),

          // License Footer
          const LicenseFooter(),
        ],
      ),
    );
  }
}
