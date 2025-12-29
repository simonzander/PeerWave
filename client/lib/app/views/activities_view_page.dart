import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'base_view.dart';
import '../../widgets/context_panel.dart'; // For ContextPanelType enum
import '../../screens/activities/activities_view.dart';

/// Activities View Page
///
/// Shows recent activities across all communication channels
/// No context panel - activities are the overview
class ActivitiesViewPage extends BaseView {
  const ActivitiesViewPage({super.key, required super.host});

  @override
  State<ActivitiesViewPage> createState() => _ActivitiesViewPageState();
}

class _ActivitiesViewPageState extends BaseViewState<ActivitiesViewPage> {
  @override
  bool get shouldShowContextPanel => false; // No context panel for activities

  @override
  ContextPanelType get contextPanelType => ContextPanelType.activities; // Not used but required

  @override
  Widget buildContextPanel() => const SizedBox.shrink(); // Not used but required

  @override
  Widget buildMainContent() {
    return ActivitiesView(
      onDirectMessageTap: _handleDirectMessageTap,
      onChannelTap: _handleChannelTap,
    );
  }

  /// Handle tap on direct message activity
  void _handleDirectMessageTap(String uuid, String displayName) {
    debugPrint('[ACTIVITIES_VIEW] Navigate to message: $uuid ($displayName)');
    context.go('/app/messages/$uuid', extra: {'displayName': displayName});
  }

  /// Handle tap on channel activity
  void _handleChannelTap(String uuid, String name, String type) {
    debugPrint(
      '[ACTIVITIES_VIEW] Navigate to channel: $uuid ($name, type: $type)',
    );
    context.go('/app/channels/$uuid', extra: {'name': name, 'type': type});
  }
}
