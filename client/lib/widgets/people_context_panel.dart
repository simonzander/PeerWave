import 'package:flutter/material.dart';
import '../theme/app_theme_constants.dart';
import '../widgets/user_avatar.dart';

/// People Context Panel - Shows recent conversations and quick access
/// 
/// This appears in the context panel on desktop, providing quick access
/// to recent conversation partners and favorite contacts.
/// 
/// On mobile/tablet (where context panel is hidden), this content
/// is integrated into the main PeopleScreen view.
class PeopleContextPanel extends StatelessWidget {
  final String host;
  final List<Map<String, dynamic>> recentPeople;
  final List<Map<String, dynamic>> favoritePeople;
  final String? activeContactUuid; // Currently active conversation
  final Function(String uuid, String displayName) onPersonTap;
  final VoidCallback? onLoadMore;
  final bool isLoading;
  final bool hasMore;

  const PeopleContextPanel({
    super.key,
    required this.host,
    required this.recentPeople,
    required this.favoritePeople,
    this.activeContactUuid,
    required this.onPersonTap,
    this.onLoadMore,
    this.isLoading = false,
    this.hasMore = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppThemeConstants.contextPanelBackground,
      child: Column(
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
                      // Recent Conversations
                      if (recentPeople.isNotEmpty) ...[
                        _buildSectionHeader('Recent'),
                        ...recentPeople.map((person) => _buildPersonTile(
                          person: person,
                          onTap: () => onPersonTap(
                            person['uuid'],
                            person['displayName'],
                          ),
                          isActive: person['uuid'] == activeContactUuid,
                        )),
                        
                        // Load more link
                        if (hasMore && onLoadMore != null)
                          _buildLoadMoreLink(),
                        
                        const SizedBox(height: 12),
                      ],
                      
                      // Favorites
                      if (favoritePeople.isNotEmpty) ...[
                        _buildSectionHeader('Favorites'),
                        ...favoritePeople.map((person) => _buildPersonTile(
                          person: person,
                          onTap: () => onPersonTap(
                            person['uuid'],
                            person['displayName'],
                          ),
                          showStar: true,
                          isActive: person['uuid'] == activeContactUuid,
                        )),
                      ],
                      
                      // Empty state
                      if (recentPeople.isEmpty && favoritePeople.isEmpty)
                        _buildEmptyState(),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppThemeConstants.textSecondary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildLoadMoreLink() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: InkWell(
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
                  color: AppThemeConstants.textSecondary.withOpacity(0.9),
                  decoration: TextDecoration.underline,
                  decorationColor: AppThemeConstants.textSecondary.withOpacity(0.4),
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.arrow_forward_ios,
                size: 10,
                color: AppThemeConstants.textSecondary.withOpacity(0.7),
              ),
            ],
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
    final displayName = person['displayName'] as String? ?? 'Unknown';
    final atName = person['atName'] as String? ?? '';
    final picture = person['picture'] as String? ?? '';
    final isOnline = person['online'] as bool? ?? false;
    final userId = person['uuid'] as String? ?? '';
    final lastMessage = person['lastMessage'] as String? ?? '';
    final lastMessageTime = person['lastMessageTime'] as String? ?? '';
    final unreadCount = person['unreadCount'] as int? ?? 0;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: isActive 
            ? AppThemeConstants.activeChannelBackground // Highlight active conversation
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          hoverColor: isActive 
              ? AppThemeConstants.activeChannelBackground
              : const Color(0xFF1A1E24), // Lighter grey for hover
          splashColor: const Color(0xFF252A32),
          highlightColor: isActive
              ? AppThemeConstants.activeChannelBackground
              : const Color(0xFF1F242B),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                              color: Colors.green,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppThemeConstants.contextPanelBackground,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                      // Unread badge (bottom right, slightly overlapping)
                      if (unreadCount > 0)
                        Positioned(
                          right: -4,
                          bottom: -4,
                          child: Container(
                            constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              shape: unreadCount > 9 ? BoxShape.rectangle : BoxShape.circle,
                              borderRadius: unreadCount > 9 ? BorderRadius.circular(10) : null,
                              border: Border.all(
                                color: AppThemeConstants.contextPanelBackground,
                                width: 2,
                              ),
                            ),
                            child: Text(
                              unreadCount > 99 ? '99+' : '$unreadCount',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                height: 1.0,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
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
                                color: AppThemeConstants.textPrimary,
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
                                  color: AppThemeConstants.textSecondary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                          if (showStar) ...[
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.star,
                              size: 14,
                              color: Colors.amber,
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
                            color: AppThemeConstants.textSecondary.withOpacity(0.8),
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
                    child: Text(
                      lastMessageTime,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppThemeConstants.textSecondary.withOpacity(0.7),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.people_outline,
              size: 48,
              color: AppThemeConstants.textSecondary,
            ),
            const SizedBox(height: 12),
            Text(
              'No recent conversations',
              style: TextStyle(
                fontSize: 14,
                color: AppThemeConstants.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

