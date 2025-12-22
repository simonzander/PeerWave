import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/logout_service.dart';
import 'navigation_badge.dart';

/// Navigation Sidebar for Desktop Layout
///
/// Shows icon-only sidebar on the left with navigation between main views
class NavigationSidebar extends StatefulWidget {
  const NavigationSidebar({super.key});

  @override
  State<NavigationSidebar> createState() => _NavigationSidebarState();
}

class _NavigationSidebarState extends State<NavigationSidebar> {
  int _selectedIndex = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateSelectedIndexFromRoute();
  }

  /// Update selected index based on current route
  void _updateSelectedIndexFromRoute() {
    final location = GoRouterState.of(context).matchedLocation;

    int newIndex = 0;
    if (location.startsWith('/app/activities')) {
      newIndex = 0;
    } else if (location.startsWith('/app/meetings')) {
      newIndex = 1;
    } else if (location.startsWith('/app/people')) {
      newIndex = 2;
    } else if (location.startsWith('/app/files')) {
      newIndex = 3;
    } else if (location.startsWith('/app/channels')) {
      newIndex = 4;
    } else if (location.startsWith('/app/messages')) {
      newIndex = 5;
    }

    if (newIndex != _selectedIndex) {
      setState(() {
        _selectedIndex = newIndex;
      });
    }
  }

  void _onNavigationSelected(int index) {
    setState(() {
      _selectedIndex = index;
    });

    // Navigate via GoRouter
    switch (index) {
      case 0:
        context.go('/app/activities');
        break;
      case 1:
        context.go('/app/meetings');
        break;
      case 2:
        context.go('/app/people');
        break;
      case 3:
        context.go('/app/files');
        break;
      case 4:
        context.go('/app/channels');
        break;
      case 5:
        context.go('/app/messages');
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 60,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          const SizedBox(height: 12),

          // Activity Icon
          _buildIconButton(
            badge: NavigationBadge(
              icon: Icons.bolt,
              type: NavigationBadgeType.activities,
              selected: _selectedIndex == 0,
            ),
            isSelected: _selectedIndex == 0,
            onTap: () => _onNavigationSelected(0),
            tooltip: 'Activity',
          ),
          const SizedBox(height: 4),

          // Meetings Icon
          _buildIconButton(
            badge: NavigationBadge(
              icon: Icons.today,
              type: NavigationBadgeType.meetings,
              selected: _selectedIndex == 1,
            ),
            isSelected: _selectedIndex == 1,
            onTap: () => _onNavigationSelected(1),
            tooltip: 'Meetings',
          ),
          const SizedBox(height: 4),

          // People Icon
          _buildIconButton(
            badge: NavigationBadge(
              icon: Icons.people,
              type: NavigationBadgeType.people,
              selected: _selectedIndex == 2,
            ),
            isSelected: _selectedIndex == 2,
            onTap: () => _onNavigationSelected(2),
            tooltip: 'People',
          ),
          const SizedBox(height: 4),

          // Files Icon
          _buildIconButton(
            badge: NavigationBadge(
              icon: Icons.folder,
              type: NavigationBadgeType.files,
              selected: _selectedIndex == 3,
            ),
            isSelected: _selectedIndex == 3,
            onTap: () => _onNavigationSelected(3),
            tooltip: 'Files',
          ),
          const SizedBox(height: 4),

          // Channels Icon
          _buildIconButton(
            badge: NavigationBadge(
              icon: Icons.tag,
              type: NavigationBadgeType.channels,
              selected: _selectedIndex == 4,
            ),
            isSelected: _selectedIndex == 4,
            onTap: () => _onNavigationSelected(4),
            tooltip: 'Channels',
          ),
          const SizedBox(height: 4),

          // Messages Icon
          _buildIconButton(
            badge: NavigationBadge(
              icon: Icons.message,
              type: NavigationBadgeType.messages,
              selected: _selectedIndex == 5,
            ),
            isSelected: _selectedIndex == 5,
            onTap: () => _onNavigationSelected(5),
            tooltip: 'Messages',
          ),

          const Spacer(),

          // Settings Icon at bottom
          _buildIconButton(
            badge: Icon(
              Icons.settings,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
              size: 24,
            ),
            isSelected: false,
            onTap: () => context.go('/app/settings'),
            tooltip: 'Settings',
          ),
          const SizedBox(height: 4),

          // Logout Icon
          _buildIconButton(
            badge: Icon(
              Icons.logout,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
              size: 24,
            ),
            isSelected: false,
            onTap: () =>
                LogoutService.instance.logout(context, userInitiated: true),
            tooltip: 'Logout',
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  /// Build icon button for sidebar
  Widget _buildIconButton({
    required Widget badge,
    required bool isSelected,
    required VoidCallback onTap,
    required String tooltip,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: isSelected
                ? colorScheme.primary.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: isSelected
                ? Border.all(color: colorScheme.primary, width: 2)
                : null,
          ),
          child: badge,
        ),
      ),
    );
  }
}
