import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme_constants.dart';
import '../providers/unread_messages_provider.dart';

/// Channels Context Panel - Shows categorized channels
/// 
/// This appears in the context panel on desktop, providing quick access
/// to channel list organized by:
/// 1. Starred channels (if any)
/// 2. Live channels (WebRTC with participants)
/// 3. Channels with unread messages (sorted by newest message)
/// 4. All other member/owner channels (sorted by name)
class ChannelsContextPanel extends StatelessWidget {
  final String host;
  final List<Map<String, dynamic>> allChannels; // All member/owner channels
  final String? activeChannelUuid;
  final Function(String uuid, String name, String type) onChannelTap;
  final VoidCallback? onCreateChannel;
  final bool isLoading;

  const ChannelsContextPanel({
    super.key,
    required this.host,
    required this.allChannels,
    this.activeChannelUuid,
    required this.onChannelTap,
    this.onCreateChannel,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<UnreadMessagesProvider>(
      builder: (context, unreadProvider, child) {
        // Categorize channels
        final categorized = _categorizeChannels(unreadProvider);
        
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
                          // Starred Channels
                          if (categorized['starred']!.isNotEmpty) ...[
                            _buildSectionHeader('Starred'),
                            ...categorized['starred']!.map((channel) => _buildChannelTile(
                              channel: channel,
                              onTap: () => onChannelTap(
                                channel['uuid'],
                                channel['name'],
                                channel['type'],
                              ),
                              isActive: channel['uuid'] == activeChannelUuid,
                              showStar: true,
                              unreadProvider: unreadProvider,
                            )),
                            const SizedBox(height: 12),
                          ],
                          
                          // Live Channels (WebRTC with participants)
                          if (categorized['live']!.isNotEmpty) ...[
                            _buildSectionHeader('Live'),
                            ...categorized['live']!.map((channel) => _buildChannelTile(
                              channel: channel,
                              onTap: () => onChannelTap(
                                channel['uuid'],
                                channel['name'],
                                channel['type'],
                              ),
                              isActive: channel['uuid'] == activeChannelUuid,
                              isLive: true,
                              unreadProvider: unreadProvider,
                            )),
                            const SizedBox(height: 12),
                          ],
                          
                          // Unread Messages
                          if (categorized['unread']!.isNotEmpty) ...[
                            _buildSectionHeader('Unread'),
                            ...categorized['unread']!.map((channel) => _buildChannelTile(
                              channel: channel,
                              onTap: () => onChannelTap(
                                channel['uuid'],
                                channel['name'],
                                channel['type'],
                              ),
                              isActive: channel['uuid'] == activeChannelUuid,
                              unreadProvider: unreadProvider,
                            )),
                            const SizedBox(height: 12),
                          ],
                          
                          // Other Channels
                          if (categorized['other']!.isNotEmpty) ...[
                            _buildSectionHeader('Channels'),
                            ...categorized['other']!.map((channel) => _buildChannelTile(
                              channel: channel,
                              onTap: () => onChannelTap(
                                channel['uuid'],
                                channel['name'],
                                channel['type'],
                              ),
                              isActive: channel['uuid'] == activeChannelUuid,
                              unreadProvider: unreadProvider,
                            )),
                          ],
                          
                          // Empty state
                          if (categorized.values.every((list) => list.isEmpty))
                            _buildEmptyState(),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
  
  Map<String, List<Map<String, dynamic>>> _categorizeChannels(UnreadMessagesProvider unreadProvider) {
    final displayedIds = <String>{};
    
    // 1. Starred channels
    final starred = allChannels.where((ch) => ch['isStarred'] == true).toList();
    displayedIds.addAll(starred.map((ch) => ch['uuid'] as String));
    
    // 2. Live WebRTC channels (with participants)
    final live = allChannels.where((ch) => 
      ch['type'] == 'webrtc' && 
      (ch['participants'] as List?)?.isNotEmpty == true &&
      !displayedIds.contains(ch['uuid'])
    ).toList();
    displayedIds.addAll(live.map((ch) => ch['uuid'] as String));
    
    // 3. Channels with unread messages (sorted by newest message first)
    final unread = allChannels.where((ch) => 
      (unreadProvider.channelUnreadCounts[ch['uuid']] ?? 0) > 0 &&
      !displayedIds.contains(ch['uuid'])
    ).toList();
    unread.sort((a, b) {
      final timeA = DateTime.tryParse(a['lastMessageTime'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      final timeB = DateTime.tryParse(b['lastMessageTime'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      return timeB.compareTo(timeA);
    });
    displayedIds.addAll(unread.map((ch) => ch['uuid'] as String));
    
    // 4. All other member/owner channels (sorted by name)
    final other = allChannels.where((ch) => !displayedIds.contains(ch['uuid'])).toList();
    other.sort((a, b) {
      final nameA = (a['name'] as String? ?? '').toLowerCase();
      final nameB = (b['name'] as String? ?? '').toLowerCase();
      return nameA.compareTo(nameB);
    });
    
    return {
      'starred': starred,
      'live': live,
      'unread': unread,
      'other': other,
    };
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

  Widget _buildChannelTile({
    required Map<String, dynamic> channel,
    required VoidCallback onTap,
    required UnreadMessagesProvider unreadProvider,
    bool showStar = false,
    bool isActive = false,
    bool isLive = false,
  }) {
    final name = channel['name'] as String? ?? 'Unnamed Channel';
    final description = channel['description'] as String? ?? '';
    final type = channel['type'] as String? ?? 'signal';
    final uuid = channel['uuid'] as String? ?? '';
    final isPrivate = channel['private'] as bool? ?? false;
    final lastMessage = channel['lastMessage'] as String? ?? '';
    final participants = (channel['participants'] as List?) ?? [];
    
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
                // Squared channel icon (48x48 to match people avatars)
                SizedBox(
                  width: 48,
                  height: 48,
                  child: Stack(
                    children: [
                      AppThemeConstants.squaredIconContainer(
                        icon: isPrivate 
                            ? Icons.lock 
                            : (type == 'webrtc' ? Icons.videocam : Icons.tag),
                        backgroundColor: isLive 
                            ? Colors.red.withOpacity(0.2)
                            : (type == 'webrtc' 
                                ? Colors.blue.withOpacity(0.2) 
                                : Colors.grey.withOpacity(0.2)),
                        iconColor: isLive 
                            ? Colors.red
                            : (type == 'webrtc' 
                                ? Colors.blue 
                                : AppThemeConstants.textSecondary),
                        size: 48,
                      ),
                      // Unread badge (bottom right, overlapping like in people panel)
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
                
                // Channel details
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Channel name with prefix
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              type == 'signal' ? '# $name' : name,
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
                      
                      // Second line: Last message or live status
                      const SizedBox(height: 2),
                      if (isLive && participants.isNotEmpty)
                        Text(
                          '${participants.length} ${participants.length == 1 ? 'participant' : 'participants'} • LIVE',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.red,
                          ),
                        )
                      else if (lastMessage.isNotEmpty)
                        Text(
                          lastMessage,
                          style: TextStyle(
                            fontSize: 12,
                            color: AppThemeConstants.textSecondary.withOpacity(0.8),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      else if (description.isNotEmpty)
                        Text(
                          description,
                          style: TextStyle(
                            fontSize: 12,
                            color: AppThemeConstants.textSecondary.withOpacity(0.8),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      else
                        Text(
                          type == 'webrtc' ? 'Video channel' : 'Text channel',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppThemeConstants.textSecondary.withOpacity(0.6),
                          ),
                        ),
                    ],
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
              Icons.tag,
              size: 48,
              color: AppThemeConstants.textSecondary,
            ),
            const SizedBox(height: 12),
            Text(
              'No channels yet',
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
