import 'package:flutter/material.dart';
import '../screens/dashboard/messages_list_view.dart';
import '../widgets/people_context_panel.dart';
import '../widgets/channels_context_panel.dart';
import '../widgets/files_context_panel.dart';
import '../theme/app_theme_constants.dart';

/// Context Panel - Shows contextual content based on selected view
/// 
/// This panel appears between the icon sidebar and main view on desktop,
/// and can be shown as a drawer or overlay on mobile/tablet.
/// 
/// Displays different content types:
/// - Channels list when Channels is selected
/// - Messages list when Messages is selected
/// - People list when People is selected
/// - Files list when Files is selected (future)
class ContextPanel extends StatelessWidget {
  final ContextPanelType type;
  final String host;
  final Function(String uuid, String name, String type)? onChannelTap;
  final Function(String uuid, String displayName)? onMessageTap;
  final VoidCallback? onNavigateToPeople;
  final VoidCallback? onCreateChannel;
  final double width;
  
  // Additional data for People panel
  final List<Map<String, dynamic>>? recentPeople;
  final List<Map<String, dynamic>>? starredPeople;
  final String? activeContactUuid; // Currently active contact/conversation
  final bool isLoadingPeople;
  final VoidCallback? onLoadMorePeople;
  final bool hasMorePeople;
  
  // Additional data for Channels panel
  final List<Map<String, dynamic>>? allChannels; // All member/owner channels
  final String? activeChannelUuid;
  final bool isLoadingChannels;

  const ContextPanel({
    super.key,
    required this.type,
    required this.host,
    this.onChannelTap,
    this.onMessageTap,
    this.onNavigateToPeople,
    this.onCreateChannel,
    this.width = 280,
    this.recentPeople,
    this.starredPeople,
    this.activeContactUuid,
    this.isLoadingPeople = false,
    this.onLoadMorePeople,
    this.hasMorePeople = false,
    this.allChannels,
    this.activeChannelUuid,
    this.isLoadingChannels = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      color: AppThemeConstants.contextPanelBackground,
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    switch (type) {
      case ContextPanelType.channels:
        return ChannelsContextPanel(
          host: host,
          allChannels: allChannels ?? [],
          activeChannelUuid: activeChannelUuid,
          onChannelTap: onChannelTap ?? (uuid, name, type) {},
          onCreateChannel: onCreateChannel,
          isLoading: isLoadingChannels,
        );
        
      case ContextPanelType.messages:
        return MessagesListView(
          host: host,
          onMessageTap: onMessageTap ?? (uuid, displayName) {},
          onNavigateToPeople: onNavigateToPeople ?? () {},
        );
        
      case ContextPanelType.people:
        return PeopleContextPanel(
          host: host,
          recentPeople: recentPeople ?? [],
          starredPeople: starredPeople ?? [],
          activeContactUuid: activeContactUuid,
          onPersonTap: onMessageTap ?? (uuid, displayName) {},
          isLoading: isLoadingPeople,
          onLoadMore: onLoadMorePeople,
          hasMore: hasMorePeople,
        );
        
      case ContextPanelType.files:
        return const FilesContextPanel();
        
      case ContextPanelType.none:
        return const SizedBox.shrink();
    }
  }
}

/// Types of content that can be shown in the context panel
enum ContextPanelType {
  /// No context panel (hidden)
  none,
  
  /// Shows list of channels
  channels,
  
  /// Shows list of recent messages/conversations
  messages,
  
  /// Shows list of people/contacts
  people,
  
  /// Shows list of recent files
  files,
}

