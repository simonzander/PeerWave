import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/notification_provider.dart';
import '../providers/unread_messages_provider.dart';
import '../providers/file_transfer_stats_provider.dart';

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
    return Consumer2<NotificationProvider, UnreadMessagesProvider>(
      builder: (context, notificationProvider, unreadProvider, _) {
        final count = _getCountForType(notificationProvider, unreadProvider, type);
        
        // Special handling for files icon - show transfer indicators
        if (type == NavigationBadgeType.files) {
          return Consumer<FileTransferStatsProvider>(
            builder: (context, stats, child) {
              return Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  Icon(icon),
                  
                  // Transfer indicators
                  if (stats.isUploading || stats.isDownloading)
                    Positioned(
                      right: -8,
                      bottom: -8,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Theme.of(context).colorScheme.shadow.withOpacity(0.2),
                              blurRadius: 2,
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                          if (stats.isUploading)
                              Icon(
                                Icons.arrow_upward,
                                size: 10,
                                color: Theme.of(context).colorScheme.tertiary,
                              ),
                          if (stats.isDownloading)
                              Icon(
                                Icons.arrow_downward,
                                size: 10,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                          ],
                        ),
                      ),
                    ),
                  
                  // Unread count badge (if any)
                  if (count > 0)
                    Positioned(
                      right: -8,
                      top: -8,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.error,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          count > 99 ? '99+' : '$count',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onError,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            height: 1.0,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              );
            },
          );
        }
        
        // Default badge behavior for other types
        if (count == 0) {
          return Icon(icon);
        }

        // Use Stack to position badge in bottom-right corner without increasing icon size
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Icon(icon),
            Positioned(
              right: -8,
              bottom: -8,
              child: Container(
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.error,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  count > 99 ? '99+' : '$count',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onError,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    height: 1.0,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  int _getCountForType(
    NotificationProvider notificationProvider,
    UnreadMessagesProvider unreadProvider,
    NavigationBadgeType type,
  ) {
    switch (type) {
      case NavigationBadgeType.messages:
        // Show unread direct message count
        return unreadProvider.totalDirectMessageUnread;
      
      case NavigationBadgeType.channels:
        // Show unread channel message count
        return unreadProvider.totalChannelUnread;
      
      case NavigationBadgeType.files:
        // TODO: Implement file notification tracking
        return 0;
      
      case NavigationBadgeType.activities:
        // Activities shows notification-type messages (emote, mention, etc.)
        return unreadProvider.totalActivityNotifications;
      
      case NavigationBadgeType.people:
        return 0;
      
      case NavigationBadgeType.meetings:
        // TODO: Implement meeting notification tracking (upcoming meetings, waiting guests)
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
  meetings,
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
    return Consumer2<NotificationProvider, UnreadMessagesProvider>(
      builder: (context, notificationProvider, unreadProvider, _) {
        final count = _getCountForType(notificationProvider, unreadProvider, type);
        
        if (count == 0) {
          return Text(label);
        }

        return Text(
          '$label $count',
          style: const TextStyle(
            fontWeight: FontWeight.w500,
          ),
        );
      },
    );
  }

  int _getCountForType(
    NotificationProvider notificationProvider,
    UnreadMessagesProvider unreadProvider,
    NavigationBadgeType type,
  ) {
    switch (type) {
      case NavigationBadgeType.messages:
        return unreadProvider.totalDirectMessageUnread;
      
      case NavigationBadgeType.channels:
        return unreadProvider.totalChannelUnread;
      
      case NavigationBadgeType.files:
        return 0;
      
      case NavigationBadgeType.activities:
        return notificationProvider.totalUnreadCount;
      
      case NavigationBadgeType.people:
        return 0;
      
      case NavigationBadgeType.meetings:
        return 0;
    }
  }
}

