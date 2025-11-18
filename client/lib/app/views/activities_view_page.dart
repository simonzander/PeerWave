import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'base_view.dart';
import '../../widgets/context_panel.dart';
import '../../screens/activities/activities_view.dart';

/// Activities View Page
/// 
/// Shows recent activities across all communication channels
/// No context panel - activities are the overview
class ActivitiesViewPage extends BaseView {
  const ActivitiesViewPage({
    super.key,
    required super.host,
  });

  @override
  State<ActivitiesViewPage> createState() => _ActivitiesViewPageState();
}

class _ActivitiesViewPageState extends BaseViewState<ActivitiesViewPage> {
  @override
  bool get shouldShowContextPanel => true; // Show notifications panel
  
  @override
  ContextPanelType get contextPanelType => ContextPanelType.activities;
  
  @override
  Widget buildContextPanel() {
    // Check if we're on mobile/tablet for full-width display
    final width = MediaQuery.of(context).size.width;
    final isMobileOrTablet = width < 1024;
    
    return ContextPanel(
      type: ContextPanelType.activities,
      host: widget.host,
      onNotificationTap: _handleNotificationTap,
      useFullWidth: isMobileOrTablet, // Use full width on mobile/tablet
    );
  }
  
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 1024; // Desktop breakpoint
        
        if (isDesktop) {
          // Desktop: Show both context panel and main content
          return super.build(context);
        } else {
          // Mobile/Tablet: Show only context panel (notifications)
          return Scaffold(
            body: buildContextPanel(),
          );
        }
      },
    );
  }
  
  @override
  Widget buildMainContent() {
    return ActivitiesView(
      host: widget.host,
      onDirectMessageTap: _handleDirectMessageTap,
      onChannelTap: _handleChannelTap,
    );
  }
  
  /// Handle notification tap
  void _handleNotificationTap(String type, Map<String, dynamic> data) {
    debugPrint('[ACTIVITIES_VIEW] Notification tapped: $type');
    
    // Route based on notification type
    switch (type) {
      case 'message':
        final userId = data['sender'] as String?;
        if (userId != null) {
          context.go('/app/messages/$userId');
        }
        break;
      case 'groupMessage':
        final channelId = data['channelId'] as String?;
        if (channelId != null) {
          context.go('/app/channels/$channelId');
        }
        break;
      case 'fileShared':
        context.go('/app/files');
        break;
      case 'channelInvite':
        final channelId = data['channelId'] as String?;
        if (channelId != null) {
          context.go('/app/channels/$channelId');
        }
        break;
      case 'call':
        // Handle call notification
        break;
      case 'mention':
        final channelId = data['channelId'] as String?;
        if (channelId != null) {
          context.go('/app/channels/$channelId');
        }
        break;
      case 'reaction':
        // Navigate to the message with reaction
        break;
    }
  }
  
  /// Handle tap on direct message activity
  void _handleDirectMessageTap(String uuid, String displayName) {
    debugPrint('[ACTIVITIES_VIEW] Navigate to message: $uuid ($displayName)');
    context.go('/app/messages/$uuid', extra: {
      'host': widget.host,
      'displayName': displayName,
    });
  }
  
  /// Handle tap on channel activity
  void _handleChannelTap(String uuid, String name, String type) {
    debugPrint('[ACTIVITIES_VIEW] Navigate to channel: $uuid ($name, type: $type)');
    context.go('/app/channels/$uuid', extra: {
      'host': widget.host,
      'name': name,
      'type': type,
    });
  }
}
