import 'package:flutter/material.dart';
import 'dart:async';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'base_view.dart';
import '../../widgets/context_panel.dart';
import '../../screens/messages/direct_messages_screen.dart';
import '../../screens/messages/messages_main_content.dart';
import '../../services/event_bus.dart';
import '../../services/user_profile_service.dart';
import 'people_context_data_loader.dart';
import '../../providers/unread_messages_provider.dart';

/// Messages View Page
/// 
/// Shows direct messages with people context panel
/// Listens to Event Bus for new messages and updates
class MessagesViewPage extends BaseView {
  final String? initialContactUuid;
  final String? initialDisplayName;

  const MessagesViewPage({
    super.key,
    required super.host,
    this.initialContactUuid,
    this.initialDisplayName,
  });

  @override
  State<MessagesViewPage> createState() => _MessagesViewPageState();
}

class _MessagesViewPageState extends BaseViewState<MessagesViewPage> {
  StreamSubscription? _newMessageSubscription;
  StreamSubscription? _conversationSubscription;
  
  // Context Panel Data (shared with People view)
  List<Map<String, dynamic>> _recentPeople = [];
  bool _isLoadingContextPanel = false;
  static const int _contextPanelLimit = 10;
  
  @override
  void initState() {
    super.initState();
    _loadContextPanelData();
    _setupEventBusListeners();
  }
  
  @override
  void dispose() {
    _newMessageSubscription?.cancel();
    _conversationSubscription?.cancel();
    super.dispose();
  }
  
  /// Setup Event Bus listeners for messages
  void _setupEventBusListeners() {
    // Listen for new messages
    _newMessageSubscription = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.newMessage)
        .listen((data) {
      debugPrint('[MESSAGES_VIEW] New message received via Event Bus');
      // Reload context panel data to update recent conversations
      if (mounted) {
        _loadContextPanelData();
      }
    });
    
    // Listen for new conversations
    _conversationSubscription = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.newConversation)
        .listen((data) {
      debugPrint('[MESSAGES_VIEW] New conversation via Event Bus');
      // Reload context panel data to add new conversation
      if (mounted) {
        _loadContextPanelData();
      }
    });
    
    debugPrint('[MESSAGES_VIEW] Event Bus listeners registered');
  }
  
  @override
  ContextPanelType get contextPanelType => ContextPanelType.people;
  
  @override
  Widget buildContextPanel() {
    // Use same context panel as People view
    return ContextPanel(
      type: ContextPanelType.people,
      host: widget.host,
      recentPeople: _recentPeople,
      favoritePeople: const [], // TODO: Implement favorites
      activeContactUuid: widget.initialContactUuid, // Highlight active conversation
      onMessageTap: (uuid, displayName) {
        // Navigate to specific message conversation
        debugPrint('[MESSAGES_VIEW] Navigate to: $uuid ($displayName)');
        context.go('/app/messages/$uuid', extra: {
          'host': widget.host,
          'displayName': displayName,
        });
      },
      isLoadingPeople: _isLoadingContextPanel,
      onLoadMorePeople: _loadMoreRecentPeople,
      hasMorePeople: false,
    );
  }
  
  @override
  Widget buildMainContent() {
    // If we have an initial contact, show that conversation
    if (widget.initialContactUuid != null && widget.initialDisplayName != null) {
      return DirectMessagesScreen(
        host: widget.host,
        recipientUuid: widget.initialContactUuid!,
        recipientDisplayName: widget.initialDisplayName!,
      );
    }
    
    // Otherwise show enriched messages main content with conversation list
    return MessagesMainContent(
      host: widget.host,
      onConversationTap: (uuid, displayName) {
        // Navigate to specific message conversation
        debugPrint('[MESSAGES_VIEW] Navigate to: $uuid ($displayName)');
        context.go('/app/messages/$uuid', extra: {
          'host': widget.host,
          'displayName': displayName,
        });
      },
    );
  }
  
  // ============================================================================
  // Context Panel Data Loading (shared logic with People view)
  // ============================================================================

  /// Load data for context panel (recent conversations)
  /// Shows last 10 people from recent 1:1 conversations
  Future<void> _loadContextPanelData() async {
    setState(() => _isLoadingContextPanel = true);
    
    try {
      debugPrint('[MESSAGES_VIEW] Loading context panel data...');
      
      // Get unread provider from context
      final unreadProvider = context.read<UnreadMessagesProvider>();
      
      // Use shared utility to load data
      final peopleList = await PeopleContextDataLoader.loadRecentPeople(
        limit: _contextPanelLimit,
        unreadProvider: unreadProvider,
      );
      
      // If we have an active contact that's not in the list, add it at the top
      if (widget.initialContactUuid != null && widget.initialDisplayName != null) {
        final activeContactExists = peopleList.any((p) => p['uuid'] == widget.initialContactUuid);
        
        if (!activeContactExists) {
          debugPrint('[MESSAGES_VIEW] Active contact not in recent list, adding to top');
          
          // Get atName from UserProfileService if available
          final profile = UserProfileService.instance.getProfile(widget.initialContactUuid!);
          final atName = profile?['atName'] ?? '';
          
          // Add active contact at the beginning
          peopleList.insert(0, {
            'uuid': widget.initialContactUuid!,
            'displayName': widget.initialDisplayName!,
            'atName': atName,
            'picture': '',
            'online': false,
            'lastMessage': '',
            'lastMessageTime': '',
            'unreadCount': 0,
          });
        }
      }
      
      if (mounted) {
        setState(() {
          _recentPeople = peopleList;
          _isLoadingContextPanel = false;
        });
      }
      
      debugPrint('[MESSAGES_VIEW] Loaded ${_recentPeople.length} people for context panel');
    } catch (e, stackTrace) {
      debugPrint('[MESSAGES_VIEW] Error loading context panel data: $e');
      debugPrint('[MESSAGES_VIEW] Stack trace: $stackTrace');
      
      if (mounted) {
        setState(() => _isLoadingContextPanel = false);
      }
    }
  }

  /// Load more recent people for context panel
  void _loadMoreRecentPeople() {
    debugPrint('[MESSAGES_VIEW] Load more recent people requested');
    // TODO: Implement pagination if needed
  }
  
  @override
  void onRetry() {
    super.onRetry();
    _loadContextPanelData();
  }
}
