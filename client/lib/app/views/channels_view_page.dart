import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'base_view.dart';
import '../../widgets/context_panel.dart';
import '../../screens/dashboard/channels_list_view.dart';
import '../../screens/messages/signal_group_chat_screen.dart';
import '../../views/video_conference_prejoin_view.dart';
import '../../views/video_conference_view.dart';
import '../../services/event_bus.dart';
import '../../services/video_conference_service.dart';
import '../../services/api_service.dart';
import '../../services/activities_service.dart';
import '../../services/starred_channels_service.dart';
import '../../services/signal_service.dart';

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

  // Context panel state - channels data
  List<Map<String, dynamic>> _allChannels = [];
  bool _isLoadingChannels = false;

  @override
  void initState() {
    super.initState();
    _setupEventBusListeners();
    _loadChannelsForContextPanel();
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
          debugPrint(
            '[CHANNELS_VIEW] New channel via Event Bus: ${data['name']}',
          );
          if (mounted) {
            _loadChannelsForContextPanel(); // Reload channels
          }
        });

    // Listen for channel updates
    _channelUpdatedSubscription = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.channelUpdated)
        .listen((data) {
          debugPrint(
            '[CHANNELS_VIEW] Channel updated via Event Bus: ${data['uuid']}',
          );
          if (mounted) {
            _loadChannelsForContextPanel(); // Reload channels
          }
        });

    // Listen for channel deletions
    _channelDeletedSubscription = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.channelDeleted)
        .listen((data) {
          debugPrint(
            '[CHANNELS_VIEW] Channel deleted via Event Bus: ${data['uuid']}',
          );
          if (mounted) {
            _loadChannelsForContextPanel(); // Reload channels
          }
        });

    debugPrint('[CHANNELS_VIEW] Event Bus listeners registered');
  }

  /// Load channels for context panel
  Future<void> _loadChannelsForContextPanel() async {
    setState(() => _isLoadingChannels = true);

    try {
      // Get WebRTC channels with live participants
      final webrtcWithParticipants =
          await ActivitiesService.getWebRTCChannelParticipants();

      // Get all member/owner channels
      ApiService.init();
      final resp = await ApiService.get('/client/channels?limit=1000');

      if (resp.statusCode == 200) {
        final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
        final channels = (data['channels'] as List<dynamic>? ?? []);

        // Get current user ID for ownership
        final currentUserId = SignalService.instance.currentUserId;

        final channelsList = channels.map((ch) {
          final channelMap = Map<String, dynamic>.from(ch as Map);
          channelMap['isMember'] = true;
          channelMap['isOwner'] =
              (currentUserId != null && channelMap['owner'] == currentUserId);

          // Get starred state
          try {
            channelMap['isStarred'] = StarredChannelsService.instance.isStarred(
              channelMap['uuid'] as String? ?? '',
            );
          } catch (e) {
            channelMap['isStarred'] = false;
          }

          // Add live participant data for WebRTC channels
          if (channelMap['type'] == 'webrtc') {
            final liveData = webrtcWithParticipants.firstWhere(
              (item) => item['channelId'] == channelMap['uuid'],
              orElse: () => <String, dynamic>{},
            );
            if (liveData.isNotEmpty &&
                (liveData['participants'] as List?)?.isNotEmpty == true) {
              channelMap['participants'] = liveData['participants'];
            }
          }

          return channelMap;
        }).toList();

        // Enrich Signal channels with last message
        await _enrichSignalChannelsWithLastMessage(channelsList);

        if (mounted) {
          setState(() {
            _allChannels = channelsList;
            _isLoadingChannels = false;
          });
        }
      } else {
        if (mounted) {
          setState(() => _isLoadingChannels = false);
        }
      }
    } catch (e, stackTrace) {
      debugPrint('[CHANNELS_VIEW] Error loading channels: $e');
      debugPrint('[CHANNELS_VIEW] Stack trace: $stackTrace');

      if (mounted) {
        setState(() => _isLoadingChannels = false);
      }
    }
  }

  /// Enrich Signal channels with last message info
  Future<void> _enrichSignalChannelsWithLastMessage(
    List<Map<String, dynamic>> channels,
  ) async {
    try {
      final conversations = await ActivitiesService.getRecentGroupConversations(
        limit: 100,
      );

      for (final channel in channels.where((ch) => ch['type'] == 'signal')) {
        final conv = conversations.firstWhere(
          (c) => c['channelId'] == channel['uuid'],
          orElse: () => <String, dynamic>{},
        );

        if (conv.isNotEmpty) {
          final lastMessages = (conv['lastMessages'] as List?) ?? [];
          channel['lastMessage'] = lastMessages.isNotEmpty
              ? (lastMessages.first['message'] as String? ?? '')
              : '';
          channel['lastMessageTime'] = conv['lastMessageTime'] ?? '';
        } else {
          channel['lastMessage'] = '';
          channel['lastMessageTime'] = '';
        }
      }
    } catch (e) {
      debugPrint('[CHANNELS_VIEW] Error enriching signal channels: $e');
    }
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
      allChannels: _allChannels,
      activeChannelUuid: widget.initialChannelUuid,
      onChannelTap: (uuid, name, type) {
        // Navigate to specific channel
        debugPrint('[CHANNELS_VIEW] Navigate to: $uuid ($name, type: $type)');
        context.go(
          '/app/channels/$uuid',
          extra: <String, dynamic>{'name': name, 'type': type},
        );
      },
      onCreateChannel: () {
        debugPrint('[CHANNELS_VIEW] Create new channel');
        // TODO: Show create channel dialog
      },
      isLoadingChannels: _isLoadingChannels,
    );
  }

  @override
  Widget buildMainContent() {
    // If a specific channel is selected, show the appropriate screen
    if (widget.initialChannelUuid != null &&
        widget.initialChannelType != null) {
      if (widget.initialChannelType == 'signal') {
        // Show Signal group chat screen
        return SignalGroupChatScreen(
          channelUuid: widget.initialChannelUuid!,
          channelName: widget.initialChannelName ?? 'Channel',
        );
      } else if (widget.initialChannelType == 'webrtc') {
        // Check if already in this channel - if so, show full view directly
        final videoService = Provider.of<VideoConferenceService>(
          context,
          listen: false,
        );
        final alreadyInThisChannel =
            videoService.isInCall &&
            videoService.currentChannelId == widget.initialChannelUuid;

        if (alreadyInThisChannel || _videoConferenceConfig != null) {
          // Show actual video conference view (already joined or joining)
          return VideoConferenceView(
            channelId:
                _videoConferenceConfig?['channelId'] ??
                widget.initialChannelUuid!,
            channelName:
                _videoConferenceConfig?['channelName'] ??
                widget.initialChannelName ??
                'Channel',
            host: widget.host,
            selectedCamera: _videoConferenceConfig?['selectedCamera'],
            selectedMicrophone: _videoConferenceConfig?['selectedMicrophone'],
          );
        } else {
          // Show prejoin view first
          return VideoConferencePreJoinView(
            channelId: widget.initialChannelUuid!,
            channelName: widget.initialChannelName ?? 'Channel',
            onJoinReady: (config) {
              debugPrint(
                '[CHANNELS_VIEW] Ready to join conference: ${config['channelId']}',
              );
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

  @override
  void onRetry() {
    super.onRetry();
    _loadChannelsForContextPanel();
  }
}
