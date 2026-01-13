import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:convert' show base64Decode;
import 'package:go_router/go_router.dart';
import '../services/server_config_web.dart'
    if (dart.library.io) '../services/server_config_native.dart';
import '../services/logout_service.dart';
import 'license_footer.dart';

/// Unified drawer widget for mobile screens across all app states
/// Shows contextual menu items based on authentication status and current route
class AppDrawer extends StatelessWidget {
  final bool isAuthenticated;
  final String? currentRoute;

  const AppDrawer({
    super.key,
    required this.isAuthenticated,
    this.currentRoute,
  });

  /// Check if current route is a registration page requiring exit confirmation
  bool get _isRegistrationPage {
    if (currentRoute == null) return false;
    return currentRoute!.startsWith('/register/backupcode') ||
        currentRoute!.startsWith('/register/webauthn') ||
        currentRoute!.startsWith('/register/profile');
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
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: colorScheme.primaryContainer,
        backgroundImage: activeServer?.serverPicture != null
            ? MemoryImage(
                base64Decode(activeServer!.serverPicture!.split(',').last),
              )
            : null,
        child: activeServer?.serverPicture == null
            ? Text(
                activeServer?.getDisplayName().substring(0, 1).toUpperCase() ??
                    'S',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onPrimaryContainer,
                ),
              )
            : null,
      ),
      title: Text(
        activeServer?.getDisplayName() ?? 'Select Server',
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      children: servers
          .map(
            (server) => ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 14,
                backgroundColor: colorScheme.surfaceContainerHighest,
                backgroundImage: server.serverPicture != null
                    ? MemoryImage(
                        base64Decode(server.serverPicture!.split(',').last),
                      )
                    : null,
                child: server.serverPicture == null
                    ? Text(
                        server.getDisplayName().substring(0, 1).toUpperCase(),
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurface,
                        ),
                      )
                    : null,
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
                  ? Icon(
                      // Show alert icon if not authenticated, check icon if authenticated
                      isAuthenticated
                          ? Icons.check_circle
                          : Icons.warning_amber_rounded,
                      color: isAuthenticated
                          ? colorScheme.primary
                          : colorScheme.error,
                      size: 20,
                    )
                  : null,
              onTap: () async {
                if (server.id != activeServer?.id) {
                  // Switch to a different server
                  await ServerConfigService.setActiveServer(server.id);
                  if (context.mounted) {
                    Navigator.pop(context);
                    context.go('/app/activities');
                  }
                } else {
                  // Active server clicked
                  if (!isAuthenticated) {
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
    final isOnTargetRoute = currentRoute == _addServerRoute;

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
          if (isAuthenticated) ...[
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
          if (isAuthenticated)
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
