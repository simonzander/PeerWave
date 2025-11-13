import 'package:flutter/material.dart';
import 'dart:async';
import 'base_view.dart';
import '../../widgets/context_panel.dart';
import '../../screens/dashboard/channels_list_view.dart';
import '../../screens/messages/signal_group_chat_screen.dart';
import '../../views/video_conference_prejoin_view.dart';
import '../../views/video_conference_view.dart';
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
  
  // Video conference state
  Map<String, dynamic>? _videoConferenceConfig;
  
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
    // Use ContextPanel wrapper (provides width constraint) like people/messages views
    return ContextPanel(
      type: ContextPanelType.channels,
      host: widget.host,
      liveChannels: [],  // TODO: Load from state
      recentChannels: [], // TODO: Load from state
      favoriteChannels: [], // TODO: Load from state
      activeChannelUuid: widget.initialChannelUuid,
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
    // If a specific channel is selected, show the appropriate screen
    if (widget.initialChannelUuid != null && widget.initialChannelType != null) {
      if (widget.initialChannelType == 'signal') {
        // Show Signal group chat screen
        return SignalGroupChatScreen(
          host: widget.host,
          channelUuid: widget.initialChannelUuid!,
          channelName: widget.initialChannelName ?? 'Channel',
        );
      } else if (widget.initialChannelType == 'webrtc') {
        // Show WebRTC video conference
        if (_videoConferenceConfig != null) {
          // Show actual video conference view
          return VideoConferenceView(
            channelId: _videoConferenceConfig!['channelId'],
            channelName: _videoConferenceConfig!['channelName'],
            selectedCamera: _videoConferenceConfig!['selectedCamera'],
            selectedMicrophone: _videoConferenceConfig!['selectedMicrophone'],
          );
        } else {
          // Show prejoin view first
          return VideoConferencePreJoinView(
            channelId: widget.initialChannelUuid!,
            channelName: widget.initialChannelName ?? 'Channel',
            onJoinReady: (config) {
              debugPrint('[CHANNELS_VIEW] Ready to join conference: ${config['channelId']}');
              setState(() {
                _videoConferenceConfig = config;
              });
            },
          );
        }
      }
    }
    
    // Otherwise show the channels list view
    return ChannelsListView(
      host: widget.host,
      onChannelTap: (uuid, name, type) {
        // Navigation is now handled by ChannelsListView using context.go()
        debugPrint('[CHANNELS_VIEW] Navigate to: $uuid ($name, type: $type)');
      },
      onCreateChannel: () {
        debugPrint('[CHANNELS_VIEW] Create new channel');
        // TODO: Show create channel dialog
      },
    );
  }
}
