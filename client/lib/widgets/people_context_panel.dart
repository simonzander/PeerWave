import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../widgets/user_avatar.dart';
import '../widgets/animated_widgets.dart';
import '../providers/unread_messages_provider.dart';
import '../theme/semantic_colors.dart';

/// People Context Panel - Shows recent conversations and quick access
///
/// This appears in the context panel on desktop, providing quick access
/// to recent conversation partners and favorite contacts.
///
/// On mobile/tablet (where context panel is hidden), this content
/// is integrated into the main PeopleScreen view.
class PeopleContextPanel extends StatelessWidget {
  final List<Map<String, dynamic>> recentPeople;
  final List<Map<String, dynamic>> starredPeople; // Starred conversations
  final String? activeContactUuid; // Currently active conversation
  final Function(String uuid, String displayName) onPersonTap;
  final VoidCallback? onLoadMore;
  final bool isLoading;
  final bool hasMore;

  const PeopleContextPanel({
    super.key,
    required this.recentPeople,
    this.starredPeople = const [],
    this.activeContactUuid,
    required this.onPersonTap,
    this.onLoadMore,
    this.isLoading = false,
    this.hasMore = true,
  });

  @override
  Widget build(BuildContext context) {
    // Get starred UUIDs for filtering
    final starredUuids = starredPeople.map((p) => p['uuid'] as String).toSet();

    // Split recent people into unread and regular recent
    final unreadPeople = recentPeople.where((person) {
      final uuid = person['uuid'] as String;
      final unreadCount = person['unreadCount'] as int? ?? 0;
      // Only show in unread if not starred and has unread messages
      return !starredUuids.contains(uuid) && unreadCount > 0;
    }).toList();

    final regularRecentPeople = recentPeople.where((person) {
      final uuid = person['uuid'] as String;
      final unreadCount = person['unreadCount'] as int? ?? 0;
      // Only show in recent if not starred and no unread messages
      return !starredUuids.contains(uuid) && unreadCount == 0;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1),

        // Content
        Expanded(
          child: isLoading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    // Starred Conversations (only show if there are starred chats)
                    if (starredPeople.isNotEmpty) ...[
                      _buildSectionHeader('Starred'),
                      ...starredPeople.map(
                        (person) => _buildPersonTile(
                          person: person,
                          onTap: () => onPersonTap(
                            person['uuid'],
                            person['displayName'],
                          ),
                          showStar: true,
                          isActive: person['uuid'] == activeContactUuid,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],

                    // Unread Conversations (not starred)
                    if (unreadPeople.isNotEmpty) ...[
                      _buildSectionHeader('Unread'),
                      ...unreadPeople.map(
                        (person) => _buildPersonTile(
                          person: person,
                          onTap: () => onPersonTap(
                            person['uuid'],
                            person['displayName'],
                          ),
                          isActive: person['uuid'] == activeContactUuid,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],

                    // Recent Conversations (not starred, no unread)
                    if (regularRecentPeople.isNotEmpty) ...[
                      _buildSectionHeader('Recent'),
                      ...regularRecentPeople.map(
                        (person) => _buildPersonTile(
                          person: person,
                          onTap: () => onPersonTap(
                            person['uuid'],
                            person['displayName'],
                          ),
                          isActive: person['uuid'] == activeContactUuid,
                        ),
                      ),

                      // Load more link
                      if (hasMore && onLoadMore != null) _buildLoadMoreLink(),

                      const SizedBox(height: 12),
                    ],

                    // Empty state
                    if (recentPeople.isEmpty && starredPeople.isEmpty)
                      _buildEmptyState(),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Builder(
        builder: (context) => Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.7),
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }

  Widget _buildLoadMoreLink() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Builder(
        builder: (context) => InkWell(
          onTap: onLoadMore,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Load more',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.9),
                    decoration: TextDecoration.underline,
                    decorationColor: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.arrow_forward_ios,
                  size: 10,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPersonTile({
    required Map<String, dynamic> person,
    required VoidCallback onTap,
    bool showStar = false,
    bool isActive = false,
  }) {
    return Consumer<UnreadMessagesProvider>(
      builder: (context, unreadProvider, child) {
        final displayName = person['displayName'] as String? ?? 'Unknown';
        final atName = person['atName'] as String? ?? '';
        final picture = person['picture'] as String? ?? '';
        final isOnline = person['online'] as bool? ?? false;
        final userId = person['uuid'] as String? ?? '';
        final lastMessage = person['lastMessage'] as String? ?? '';
        final lastMessageTime = person['lastMessageTime'] as String? ?? '';

        // Get unread count from provider instead of static data
        final unreadCount =
            unreadProvider.directMessageUnreadCounts[userId] ?? 0;

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Material(
            color: isActive
                ? Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withValues(alpha: 0.3)
                : Colors.transparent,
            child: InkWell(
              onTap: onTap,
              hoverColor: isActive
                  ? Theme.of(
                      context,
                    ).colorScheme.primaryContainer.withValues(alpha: 0.3)
                  : Theme.of(context).colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
              splashColor: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.1),
              highlightColor: isActive
                  ? Theme.of(
                      context,
                    ).colorScheme.primaryContainer.withValues(alpha: 0.3)
                  : Theme.of(context).colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.3),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Square avatar with online indicator and unread badge
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: Stack(
                        children: [
                          SquareUserAvatar(
                            userId: userId,
                            displayName: displayName,
                            pictureData: picture.isNotEmpty ? picture : null,
                            size: 48,
                          ),
                          if (isOnline)
                            Positioned(
                              right: -2,
                              bottom: -2,
                              child: Container(
                                width: 14,
                                height: 14,
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.success,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerLow,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          // Unread badge (bottom right, squared red badge)
                          UnreadBadgeOverlay(
                            count: unreadCount,
                            borderColor: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerLow,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),

                    // Name, @username, and last message
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // First line: DisplayName and @username
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  displayName,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (atName.isNotEmpty) ...[
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    '@$atName',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.6),
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                              if (showStar) ...[
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.star,
                                  size: 14,
                                  color: Theme.of(context).colorScheme.tertiary,
                                ),
                              ],
                            ],
                          ),

                          // Second line: Last message
                          if (lastMessage.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              lastMessage,
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.5),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),

                    // Right side: Time
                    if (lastMessageTime.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: _RelativeTimeWidget(timestamp: lastMessageTime),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Builder(
      builder: (context) => Padding(
        padding: const EdgeInsets.all(32.0),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.people_outline,
                size: 48,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 12),
              Text(
                'No recent conversations',
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Widget to display relative time that auto-updates
class _RelativeTimeWidget extends StatefulWidget {
  final String timestamp;

  const _RelativeTimeWidget({required this.timestamp});

  @override
  State<_RelativeTimeWidget> createState() => _RelativeTimeWidgetState();
}

class _RelativeTimeWidgetState extends State<_RelativeTimeWidget> {
  late Timer _timer;
  String _formattedTime = '';

  @override
  void initState() {
    super.initState();
    _updateFormattedTime();
    // Update every minute
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) {
        _updateFormattedTime();
      }
    });
  }

  @override
  void didUpdateWidget(_RelativeTimeWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.timestamp != widget.timestamp) {
      _updateFormattedTime();
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  void _updateFormattedTime() {
    setState(() {
      _formattedTime = _formatRelativeTime(widget.timestamp);
    });
  }

  String _formatRelativeTime(String timestamp) {
    if (timestamp.isEmpty) return '';

    try {
      final messageTime = DateTime.parse(timestamp);
      final now = DateTime.now();
      final difference = now.difference(messageTime);

      if (difference.inMinutes < 1) {
        return 'now';
      } else if (difference.inMinutes < 60) {
        return '${difference.inMinutes}m';
      } else if (difference.inHours < 24) {
        return '${difference.inHours}h';
      } else if (difference.inDays < 7) {
        return '${difference.inDays}d';
      } else {
        return DateFormat('MMM d').format(messageTime);
      }
    } catch (e) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) => Text(
        _formattedTime,
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}
