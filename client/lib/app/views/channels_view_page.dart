import 'package:flutter/material.dart';
import 'dart:async';
import 'base_view.dart';
import '../../widgets/context_panel.dart';
import '../../services/event_bus.dart';

/// Channels View Page
/// 
/// Shows channel messages with channels list context panel
/// Listens to Event Bus for channel updates
/// TODO: Extract actual channel chat view from dashboard_page.dart
class ChannelsViewPage extends BaseView {
  final String? initialChannelUuid;
  final String? initialChannelName;
  final String? initialChannelType;

  const ChannelsViewPage({
    super.key,
    required super.host,
    this.initialChannelUuid,
    this.initialChannelName,
    this.initialChannelType,
  });

  @override
  State<ChannelsViewPage> createState() => _ChannelsViewPageState();
}

class _ChannelsViewPageState extends BaseViewState<ChannelsViewPage> {
  StreamSubscription? _newChannelSubscription;
  StreamSubscription? _channelUpdatedSubscription;
  StreamSubscription? _channelDeletedSubscription;
  
  @override
  void initState() {
    super.initState();
    _setupEventBusListeners();
  }
  
  @override
  void dispose() {
    _newChannelSubscription?.cancel();
    _channelUpdatedSubscription?.cancel();
    _channelDeletedSubscription?.cancel();
    super.dispose();
  }
  
  /// Setup Event Bus listeners for channels
  void _setupEventBusListeners() {
    // Listen for new channels
    _newChannelSubscription = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.newChannel)
        .listen((data) {
      debugPrint('[CHANNELS_VIEW] New channel via Event Bus: ${data['name']}');
      if (mounted) {
        setState(() {
          // Trigger rebuild to update channel list
        });
      }
    });
    
    // Listen for channel updates
    _channelUpdatedSubscription = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.channelUpdated)
        .listen((data) {
      debugPrint('[CHANNELS_VIEW] Channel updated via Event Bus: ${data['uuid']}');
      if (mounted) {
        setState(() {
          // Trigger rebuild to refresh channel info
        });
      }
    });
    
    // Listen for channel deletions
    _channelDeletedSubscription = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.channelDeleted)
        .listen((data) {
      debugPrint('[CHANNELS_VIEW] Channel deleted via Event Bus: ${data['uuid']}');
      if (mounted) {
        setState(() {
          // Trigger rebuild to remove channel from list
        });
      }
    });
    
    debugPrint('[CHANNELS_VIEW] Event Bus listeners registered');
  }
  
  @override
  bool get shouldShowContextPanel => true;
  
  @override
  ContextPanelType get contextPanelType => ContextPanelType.channels;
  
  @override
  Widget buildContextPanel() {
    // Use existing ContextPanel widget with channels type
    return ContextPanel(
      type: ContextPanelType.channels,
      host: widget.host,
      onChannelTap: (uuid, name, type) {
        // Navigate to specific channel
        debugPrint('[CHANNELS_VIEW] Navigate to: $uuid ($name, type: $type)');
        // TODO: Update route to show specific channel
      },
      onCreateChannel: () {
        debugPrint('[CHANNELS_VIEW] Create new channel');
        // TODO: Show create channel dialog
      },
    );
  }
  
  @override
  Widget buildMainContent() {
    // If we have an initial channel, show placeholder for now
    if (widget.initialChannelUuid != null && widget.initialChannelName != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.tag,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              widget.initialChannelName!,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Channel chat view - will be extracted from dashboard',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    
    // Otherwise show empty state
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.tag,
            size: 64,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            'Select a channel',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Choose a channel from the list to start chatting',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
