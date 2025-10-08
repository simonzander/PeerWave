import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

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
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
