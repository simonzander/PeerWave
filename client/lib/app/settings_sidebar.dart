import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../providers/role_provider.dart';
import '../widgets/theme_selector_dialog.dart';
import '../config/layout_config.dart';

class SettingsSidebar extends StatelessWidget {
  final Widget child;
  const SettingsSidebar({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final layoutType = LayoutConfig.getLayoutType(width);

    if (layoutType == LayoutType.mobile) {
      return _buildMobileLayout(context);
    } else {
      return _buildDesktopLayout(context);
    }
  }

  Widget _buildMobileLayout(BuildContext context) {
    final currentRoute = GoRouterState.of(context).matchedLocation;
    final roleProvider = Provider.of<RoleProvider>(context);

    // Build list of available settings
    final settingsItems = _buildSettingsItems(context, roleProvider);

    return Column(
      children: [
        // Dropdown selector at top
        Container(
          color: Theme.of(context).colorScheme.surface,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Back',
                onPressed: () => GoRouter.of(context).go('/app'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: currentRoute,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 16,
                  ),
                  dropdownColor: Theme.of(context).colorScheme.surface,
                  decoration: InputDecoration(
                    labelText: 'Settings',
                    labelStyle: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    filled: true,
                    fillColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  items: settingsItems
                      .map(
                        (item) => DropdownMenuItem<String>(
                          value: item.route,
                          child: Row(
                            children: [
                              Icon(
                                item.icon,
                                size: 20,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                item.label,
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (String? newRoute) {
                    if (newRoute != null) {
                      if (newRoute == '/app/settings/theme') {
                        ThemeSelectorDialog.show(context);
                      } else {
                        GoRouter.of(context).go(newRoute);
                      }
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        // Content below
        Expanded(
          child: Container(
            color: Theme.of(context).colorScheme.surface,
            child: child,
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopLayout(BuildContext context) {
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
                      icon: Icon(
                        Icons.arrow_back,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
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
                leading: Icon(
                  Icons.settings,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                title: Text(
                  'General',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                onTap: () => GoRouter.of(context).go('/app/settings/general'),
              ),
              const Divider(),
              ListTile(
                leading: Icon(
                  Icons.person,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                title: Text(
                  'Profile',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                onTap: () => GoRouter.of(context).go('/app/settings/profile'),
              ),
              ListTile(
                leading: Icon(
                  Icons.devices,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                title: Text(
                  'Sessions',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                onTap: () => GoRouter.of(context).go('/app/settings/sessions'),
              ),
              ListTile(
                leading: Icon(
                  Icons.security,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                title: Text(
                  'Credentials',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                onTap: () => GoRouter.of(context).go('/app/settings/webauthn'),
              ),
              ListTile(
                leading: Icon(
                  Icons.notifications,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                title: Text(
                  'Notifications',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                onTap: () =>
                    GoRouter.of(context).go('/app/settings/notifications'),
              ),
              ListTile(
                leading: Icon(
                  Icons.palette_outlined,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                title: Text(
                  'Theme',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                onTap: () => ThemeSelectorDialog.show(context),
              ),
              // Voice & Video Settings
              ListTile(
                leading: Icon(
                  Icons.videocam,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                title: Text(
                  'Voice & Video',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                onTap: () =>
                    GoRouter.of(context).go('/app/settings/voice-video'),
              ),
              ListTile(
                leading: Icon(
                  Icons.build_circle,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                title: Text(
                  'Troubleshoot',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                onTap: () =>
                    GoRouter.of(context).go('/app/settings/troubleshoot'),
              ),
              ListTile(
                leading: Icon(
                  Icons.block,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                title: Text(
                  'Blocked Users',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                onTap: () =>
                    GoRouter.of(context).go('/app/settings/blocked-users'),
              ),
              // System Tray Settings - Only visible on desktop
              if (!kIsWeb)
                ListTile(
                  leading: Icon(
                    Icons.launch,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  title: Text(
                    'System Tray',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  onTap: () =>
                      GoRouter.of(context).go('/app/settings/system-tray'),
                ),
              const Divider(),
              Consumer<RoleProvider>(
                builder: (context, roleProvider, child) {
                  if (roleProvider.hasServerPermission('server.manage')) {
                    return Column(
                      children: [
                        ListTile(
                          leading: Icon(
                            Icons.dns,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          title: Text(
                            'Server Settings',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                          onTap: () =>
                              GoRouter.of(context).go('/app/settings/server'),
                        ),
                        ListTile(
                          leading: Icon(
                            Icons.report_problem,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          title: Text(
                            'Abuse Center',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                          onTap: () => GoRouter.of(
                            context,
                          ).go('/app/settings/abuse-center'),
                        ),
                      ],
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
                      leading: Icon(
                        Icons.admin_panel_settings,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      title: Text(
                        'Role Management',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      onTap: () =>
                          GoRouter.of(context).go('/app/settings/roles'),
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
                      leading: Icon(
                        Icons.people,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      title: Text(
                        'User Management',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      onTap: () =>
                          GoRouter.of(context).go('/app/settings/users'),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: Theme.of(context).colorScheme.surface,
            child: child,
          ),
        ),
      ],
    );
  }

  List<_SettingsItem> _buildSettingsItems(
    BuildContext context,
    RoleProvider roleProvider,
  ) {
    final items = <_SettingsItem>[
      _SettingsItem(
        route: '/app/settings/general',
        label: 'General',
        icon: Icons.settings,
      ),
      _SettingsItem(
        route: '/app/settings/profile',
        label: 'Profile',
        icon: Icons.person,
      ),
      _SettingsItem(
        route: '/app/settings/sessions',
        label: 'Sessions',
        icon: Icons.devices,
      ),
      _SettingsItem(
        route: '/app/settings/webauthn',
        label: 'Credentials',
        icon: Icons.security,
      ),
      _SettingsItem(
        route: '/app/settings/notifications',
        label: 'Notifications',
        icon: Icons.notifications,
      ),
      _SettingsItem(
        route: '/app/settings/theme',
        label: 'Theme',
        icon: Icons.palette_outlined,
      ),
      _SettingsItem(
        route: '/app/settings/voice-video',
        label: 'Voice & Video',
        icon: Icons.videocam,
      ),
      _SettingsItem(
        route: '/app/settings/troubleshoot',
        label: 'Troubleshoot',
        icon: Icons.build_circle,
      ),
      _SettingsItem(
        route: '/app/settings/blocked-users',
        label: 'Blocked Users',
        icon: Icons.block,
      ),
    ];

    // Add system tray on native
    if (!kIsWeb) {
      items.add(
        _SettingsItem(
          route: '/app/settings/system-tray',
          label: 'System Tray',
          icon: Icons.launch,
        ),
      );
    }

    // Add admin/permission-based items
    if (roleProvider.hasServerPermission('server.manage')) {
      items.add(
        _SettingsItem(
          route: '/app/settings/server',
          label: 'Server Settings',
          icon: Icons.dns,
        ),
      );
      items.add(
        _SettingsItem(
          route: '/app/settings/abuse-center',
          label: 'Abuse Center',
          icon: Icons.report_problem,
        ),
      );
    }

    if (roleProvider.isAdmin) {
      items.add(
        _SettingsItem(
          route: '/app/settings/roles',
          label: 'Role Management',
          icon: Icons.admin_panel_settings,
        ),
      );
    }

    if (roleProvider.hasServerPermission('user.manage')) {
      items.add(
        _SettingsItem(
          route: '/app/settings/users',
          label: 'User Management',
          icon: Icons.people,
        ),
      );
    }

    return items;
  }
}

class _SettingsItem {
  final String route;
  final String label;
  final IconData icon;

  _SettingsItem({required this.route, required this.label, required this.icon});
}
