import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme_constants.dart';
import '../providers/unread_messages_provider.dart';

/// Channels Context Panel - Shows recent and favorite channels
/// 
/// This appears in the context panel on desktop, providing quick access
/// to channel list organized by type and activity status.
class ChannelsContextPanel extends StatelessWidget {
  final String host;
  final List<Map<String, dynamic>> liveChannels;
  final List<Map<String, dynamic>> recentChannels;
  final List<Map<String, dynamic>> favoriteChannels;
  final String? activeChannelUuid;
  final Function(String uuid, String name, String type) onChannelTap;
  final VoidCallback? onCreateChannel;
  final bool isLoading;
  final VoidCallback? onLoadMore;
  final bool hasMore;

  const ChannelsContextPanel({
    super.key,
    required this.host,
    required this.liveChannels,
    required this.recentChannels,
    required this.favoriteChannels,
    this.activeChannelUuid,
    required this.onChannelTap,
    this.onCreateChannel,
    this.isLoading = false,
    this.onLoadMore,
    this.hasMore = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppThemeConstants.contextPanelBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with Create button
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: AppThemeConstants.textSecondary.withOpacity(0.1),
                  width: 1,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Channels',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppThemeConstants.textPrimary,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline, size: 20),
                  onPressed: onCreateChannel,
                  tooltip: 'Create Channel',
                  color: AppThemeConstants.textSecondary,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          
          const Divider(height: 1),
          
          // Content
          Expanded(
            child: isLoading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      // Live Channels (WebRTC with participants)
                      if (liveChannels.isNotEmpty) ...[
                        _buildSectionHeader('Live Now', icon: Icons.circle, iconColor: Colors.red),
                        ...liveChannels.map((channel) => _buildChannelTile(
                          channel: channel,
                          onTap: () => onChannelTap(
                            channel['uuid'],
                            channel['name'],
                            channel['type'],
                          ),
                          isActive: channel['uuid'] == activeChannelUuid,
                          isLive: true,
                        )),
                        const SizedBox(height: 12),
                      ],
                      
                      // Recent Channels
                      if (recentChannels.isNotEmpty) ...[
                        _buildSectionHeader('Recent'),
                        ...recentChannels.map((channel) => _buildChannelTile(
                          channel: channel,
                          onTap: () => onChannelTap(
                            channel['uuid'],
                            channel['name'],
                            channel['type'],
                          ),
                          isActive: channel['uuid'] == activeChannelUuid,
                        )),
                        
                        // Load more link
                        if (hasMore && onLoadMore != null)
                          _buildLoadMoreLink(),
                        
                        const SizedBox(height: 12),
                      ],
                      
                      // Favorite Channels
                      if (favoriteChannels.isNotEmpty) ...[
                        _buildSectionHeader('Favorites', icon: Icons.star, iconColor: Colors.amber),
                        ...favoriteChannels.map((channel) => _buildChannelTile(
                          channel: channel,
                          onTap: () => onChannelTap(
                            channel['uuid'],
                            channel['name'],
                            channel['type'],
                          ),
                          showStar: true,
                          isActive: channel['uuid'] == activeChannelUuid,
                        )),
                      ],
                      
                      // Empty state
                      if (liveChannels.isEmpty && recentChannels.isEmpty && favoriteChannels.isEmpty)
                        _buildEmptyState(),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, {IconData? icon, Color? iconColor}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 12,
              color: iconColor ?? AppThemeConstants.textSecondary,
            ),
            const SizedBox(width: 6),
          ],
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppThemeConstants.textSecondary,
              letterSpacing: 0.5,
            ),
          ),
        ],
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

  Widget _buildChannelTile({
    required Map<String, dynamic> channel,
    required VoidCallback onTap,
    bool showStar = false,
    bool isActive = false,
    bool isLive = false,
  }) {
    return Consumer<UnreadMessagesProvider>(
      builder: (context, unreadProvider, child) {
        final name = channel['name'] as String? ?? 'Unnamed Channel';
        final description = channel['description'] as String? ?? '';
        final type = channel['type'] as String? ?? 'signal';
        final uuid = channel['uuid'] as String? ?? '';
        final memberCount = channel['memberCount'] as int? ?? 0;
        
        // Get unread count from provider
        final unreadCount = unreadProvider.channelUnreadCounts[uuid] ?? 0;

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Material(
            color: isActive 
                ? AppThemeConstants.activeChannelBackground
                : Colors.transparent,
            child: InkWell(
              onTap: onTap,
              hoverColor: isActive 
                  ? AppThemeConstants.activeChannelBackground
                  : const Color(0xFF1A1E24),
              splashColor: const Color(0xFF252A32),
              highlightColor: isActive
                  ? AppThemeConstants.activeChannelBackground
                  : const Color(0xFF1F242B),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Channel icon
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: isLive 
                            ? Colors.red.withOpacity(0.2)
                            : type == 'webrtc'
                                ? Colors.blue.withOpacity(0.2)
                                : Colors.grey.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        type == 'webrtc' ? Icons.videocam : Icons.tag,
                        size: 20,
                        color: isLive 
                            ? Colors.red
                            : type == 'webrtc'
                                ? Colors.blue
                                : AppThemeConstants.textSecondary,
                      ),
                    ),
                    
                    const SizedBox(width: 12),
                    
                    // Channel details
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Channel name and badge
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  name,
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
                              if (isLive) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.red.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: Colors.red, width: 1),
                                  ),
                                  child: const Text(
                                    'LIVE',
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.red,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          
                          // Description or member count
                          if (description.isNotEmpty || memberCount > 0) ...[
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                if (memberCount > 0) ...[
                                  Icon(
                                    Icons.people,
                                    size: 12,
                                    color: AppThemeConstants.textSecondary.withOpacity(0.7),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '$memberCount',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: AppThemeConstants.textSecondary.withOpacity(0.7),
                                    ),
                                  ),
                                  if (description.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      '•',
                                      style: TextStyle(
                                        color: AppThemeConstants.textSecondary.withOpacity(0.5),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                ],
                                if (description.isNotEmpty)
                                  Flexible(
                                    child: Text(
                                      description,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: AppThemeConstants.textSecondary.withOpacity(0.7),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    
                    // Unread badge
                    if (unreadCount > 0)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          shape: unreadCount > 9 ? BoxShape.rectangle : BoxShape.circle,
                          borderRadius: unreadCount > 9 ? BorderRadius.circular(10) : null,
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
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.tag,
              size: 48,
              color: AppThemeConstants.textSecondary,
            ),
            const SizedBox(height: 12),
            Text(
              'No channels yet',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppThemeConstants.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Create or join a channel to get started',
              style: TextStyle(
                fontSize: 12,
                color: AppThemeConstants.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            if (onCreateChannel != null) ...[
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: onCreateChannel,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Create Channel'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
