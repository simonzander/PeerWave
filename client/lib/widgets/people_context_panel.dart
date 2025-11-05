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
  final Function(String uuid, String displayName) onPersonTap;
  final bool isLoading;

  const PeopleContextPanel({
    super.key,
    required this.host,
    required this.recentPeople,
    required this.favoritePeople,
    required this.onPersonTap,
    this.isLoading = false,
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
                        )),
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

  Widget _buildPersonTile({
    required Map<String, dynamic> person,
    required VoidCallback onTap,
    bool showStar = false,
  }) {
    final displayName = person['displayName'] as String? ?? 'Unknown';
    final atName = person['atName'] as String? ?? '';
    final picture = person['picture'] as String? ?? '';
    final isOnline = person['online'] as bool? ?? false;
    final userId = person['uuid'] as String? ?? '';

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          hoverColor: const Color(0xFF1A1E24), // Lighter grey for hover
          splashColor: const Color(0xFF252A32),
          highlightColor: const Color(0xFF1F242B),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                // Square avatar with online indicator
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
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                
                // Name and @username in column
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
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
                      if (atName.isNotEmpty)
                        Text(
                          '@$atName',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppThemeConstants.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                
                const SizedBox(width: 8),
                
                // Message icon
                Icon(
                  Icons.message_outlined,
                  size: 18,
                  color: AppThemeConstants.textSecondary,
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

