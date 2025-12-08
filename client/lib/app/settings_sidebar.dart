import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../providers/role_provider.dart';
import '../widgets/theme_selector_dialog.dart';

class SettingsSidebar extends StatelessWidget {
  final Widget child;
  const SettingsSidebar({Key? key, required this.child}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 220,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: ListView(
            children: [
              DrawerHeader(
                padding: EdgeInsets.zero,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: Icon(Icons.arrow_back, color: Theme.of(context).colorScheme.onSurface),
                      tooltip: 'Back',
                      onPressed: () => GoRouter.of(context).go('/app'),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Settings',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: Icon(Icons.settings, color: Theme.of(context).colorScheme.onSurface),
                title: Text('General', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                onTap: () => GoRouter.of(context).go('/app/settings/general'),
              ),
              const Divider(),
              ListTile(
                leading: Icon(Icons.person, color: Theme.of(context).colorScheme.onSurface),
                title: Text('Profile', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                onTap: () => GoRouter.of(context).go('/app/settings/profile'),
              ),
              ListTile(
                leading: Icon(Icons.security, color: Theme.of(context).colorScheme.onSurface),
                title: Text('Credentials', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                onTap: () => GoRouter.of(context).go('/app/settings/webauthn'),
              ),
              ListTile(
                leading: Icon(Icons.notifications, color: Theme.of(context).colorScheme.onSurface),
                title: Text('Notifications', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                onTap: () => GoRouter.of(context).go('/app/settings/notifications'),
              ),
              ListTile(
                leading: Icon(Icons.palette_outlined, color: Theme.of(context).colorScheme.onSurface),
                title: Text('Theme', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                onTap: () => ThemeSelectorDialog.show(context),
              ),
              // Voice & Video Settings
              ListTile(
                leading: Icon(Icons.videocam, color: Theme.of(context).colorScheme.onSurface),
                title: Text('Voice & Video', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                onTap: () => GoRouter.of(context).go('/app/settings/voice-video'),
              ),
              // System Tray Settings - Only visible on desktop
              if (!kIsWeb)
                ListTile(
                  leading: Icon(Icons.launch, color: Theme.of(context).colorScheme.onSurface),
                  title: Text('System Tray', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                  onTap: () => GoRouter.of(context).go('/app/settings/system-tray'),
                ),
              const Divider(),
              Consumer<RoleProvider>(
                builder: (context, roleProvider, child) {
                  if (roleProvider.hasServerPermission('server.manage')) {
                    return ListTile(
                      leading: Icon(Icons.dns, color: Theme.of(context).colorScheme.onSurface),
                      title: Text('Server Settings', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                      onTap: () => GoRouter.of(context).go('/app/settings/server'),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
              const Divider(),
              // Role Management - Only visible for Admins
              Consumer<RoleProvider>(
                builder: (context, roleProvider, child) {
                  if (roleProvider.isAdmin) {
                    return ListTile(
                      leading: Icon(Icons.admin_panel_settings, color: Theme.of(context).colorScheme.onSurface),
                      title: Text('Role Management', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                      onTap: () => GoRouter.of(context).go('/app/settings/roles'),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
              // User Management - Only visible for users with user.manage permission
              Consumer<RoleProvider>(
                builder: (context, roleProvider, child) {
                  if (roleProvider.hasServerPermission('user.manage')) {
                    return ListTile(
                      leading: Icon(Icons.people, color: Theme.of(context).colorScheme.onSurface),
                      title: Text('User Management', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                      onTap: () => GoRouter.of(context).go('/app/settings/users'),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

