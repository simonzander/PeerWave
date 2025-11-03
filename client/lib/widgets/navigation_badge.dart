import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/notification_provider.dart';

/// Badge widget for navigation items showing notification counts
/// 
/// Usage:
/// ```dart
/// NavigationDestination(
///   icon: NavigationBadge(
///     icon: Icons.message_outlined,
///     type: NavigationBadgeType.messages,
///   ),
///   label: 'Messages',
/// )
/// ```
class NavigationBadge extends StatelessWidget {
  final IconData icon;
  final NavigationBadgeType type;
  final bool selected;

  const NavigationBadge({
    super.key,
    required this.icon,
    required this.type,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<NotificationProvider>(
      builder: (context, notificationProvider, _) {
        final count = _getCountForType(notificationProvider, type);
        
        if (count == 0) {
          return Icon(icon);
        }

        return Badge(
          label: Text(count > 99 ? '99+' : count.toString()),
          backgroundColor: Theme.of(context).colorScheme.error,
          textColor: Theme.of(context).colorScheme.onError,
          child: Icon(icon),
        );
      },
    );
  }

  int _getCountForType(NotificationProvider provider, NavigationBadgeType type) {
    switch (type) {
      case NavigationBadgeType.messages:
        // Count all notifications (for now, total unread)
        // TODO: Distinguish between direct messages and channels
        return provider.totalUnreadCount;
      
      case NavigationBadgeType.channels:
        // TODO: Implement channel-specific counting
        return 0;
      
      case NavigationBadgeType.files:
        // TODO: Implement file notification tracking
        return 0;
      
      case NavigationBadgeType.activities:
        // TODO: Implement activity notification tracking
        return 0;
      
      case NavigationBadgeType.people:
        return 0;
    }
  }
}

/// Types of navigation badges
enum NavigationBadgeType {
  messages,
  channels,
  files,
  activities,
  people,
}

/// Label with badge for navigation items
/// 
/// Shows count after label text (e.g., "Messages 3")
class NavigationLabelWithBadge extends StatelessWidget {
  final String label;
  final NavigationBadgeType type;

  const NavigationLabelWithBadge({
    super.key,
    required this.label,
    required this.type,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<NotificationProvider>(
      builder: (context, notificationProvider, _) {
        final count = _getCountForType(notificationProvider, type);
        
        if (count == 0) {
          return Text(label);
        }

        return Text(
          '$label $count',
          style: TextStyle(
            fontWeight: FontWeight.w500,
          ),
        );
      },
    );
  }

  int _getCountForType(NotificationProvider provider, NavigationBadgeType type) {
    switch (type) {
      case NavigationBadgeType.messages:
        return provider.totalUnreadCount;
      
      case NavigationBadgeType.channels:
        return 0;
      
      case NavigationBadgeType.files:
        return 0;
      
      case NavigationBadgeType.activities:
        return 0;
      
      case NavigationBadgeType.people:
        return 0;
    }
  }
}
