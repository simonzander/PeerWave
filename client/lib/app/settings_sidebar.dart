import 'package:flutter/material.dart';
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
          color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.1),
          child: ListView(
            children: [
              DrawerHeader(
                padding: EdgeInsets.zero,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: 'Back',
                      onPressed: () => GoRouter.of(context).go('/app'),
                    ),
                    const SizedBox(width: 4),
                    Text('Settings', style: Theme.of(context).textTheme.titleLarge),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.settings),
                title: const Text('General'),
                onTap: () => GoRouter.of(context).go('/app/settings/general'),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.person),
                title: const Text('Profile'),
                onTap: () => GoRouter.of(context).go('/app/settings/profile'),
              ),
              ListTile(
                leading: const Icon(Icons.security),
                title: const Text('Credentials'),
                onTap: () => GoRouter.of(context).go('/app/settings/webauthn'),
              ),
              ListTile(
                leading: const Icon(Icons.notifications),
                title: const Text('Notifications'),
                onTap: () => GoRouter.of(context).go('/app/settings/notifications'),
              ),
              ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: const Text('Theme'),
                onTap: () => ThemeSelectorDialog.show(context),
              ),
              const Divider(),
              // P2P File Sharing
              ListTile(
                leading: const Icon(Icons.folder_shared),
                title: const Text('File Sharing'),
                onTap: () => GoRouter.of(context).go('/file-transfer'),
              ),
              const Divider(),
              // Role Management - Only visible for Admins
              Consumer<RoleProvider>(
                builder: (context, roleProvider, child) {
                  if (roleProvider.isAdmin) {
                    return ListTile(
                      leading: const Icon(Icons.admin_panel_settings),
                      title: const Text('Role Management'),
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
                      leading: const Icon(Icons.people),
                      title: const Text('User Management'),
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
