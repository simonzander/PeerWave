import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../providers/role_provider.dart';

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
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
