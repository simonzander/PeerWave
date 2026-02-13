import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/unread_messages_provider.dart';

/// Badge widget that shows unread message count
class NotificationBadge extends StatelessWidget {
  final String? channelId;
  final String? userId;
  final Widget child;
  final bool showZero;

  const NotificationBadge({
    super.key,
    this.channelId,
    this.userId,
    required this.child,
    this.showZero = false,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<UnreadMessagesProvider>(
      builder: (context, unreadProvider, _) {
        int count = 0;
        if (channelId != null && channelId!.isNotEmpty) {
          count = unreadProvider.getChannelUnreadCount(channelId!);
        } else if (userId != null && userId!.isNotEmpty) {
          count = unreadProvider.getDirectMessageUnreadCount(userId!);
        }

        if (count == 0 && !showZero) {
          return child;
        }

        return Stack(
          clipBehavior: Clip.none,
          children: [
            child,
            Positioned(
              right: -8,
              top: -8,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.error,
                  shape: BoxShape.circle,
                ),
                constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                child: Center(
                  child: Text(
                    count > 99 ? '99+' : '$count',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onError,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Global notification counter (e.g., for app bar)
class GlobalNotificationBadge extends StatelessWidget {
  final Widget child;

  const GlobalNotificationBadge({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Consumer<UnreadMessagesProvider>(
      builder: (context, unreadProvider, _) {
        final count =
            unreadProvider.totalDirectMessageUnread +
            unreadProvider.totalChannelUnread;

        if (count == 0) {
          return child;
        }

        return Stack(
          clipBehavior: Clip.none,
          children: [
            child,
            Positioned(
              right: -8,
              top: -8,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.error,
                  shape: BoxShape.circle,
                ),
                constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                child: Center(
                  child: Text(
                    count > 99 ? '99+' : '$count',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onError,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
