import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'base_view.dart';
import 'people_context_data_loader.dart';
import '../../widgets/context_panel.dart';
import '../../screens/people/people_screen.dart';
import '../../providers/unread_messages_provider.dart';
import '../../services/event_bus.dart';

/// People View Page
///
/// Shows all people/contacts with recent conversations
///
/// Structure:
/// - Desktop: Context Panel (PeopleContextPanel) + Main Content (PeopleScreen)
/// - Tablet: Main Content only (PeopleScreen with showRecentSection=true)
/// - Mobile: Main Content only (PeopleScreen with showRecentSection=true)
///
/// Features:
/// - Recent conversations in context panel (desktop only)
/// - Full people grid in main content (all layouts)
/// - Search functionality
/// - Real-time updates via EventBus (Phase 2)
class PeopleViewPage extends BaseView {
  const PeopleViewPage({super.key, required super.host});

  @override
  State<PeopleViewPage> createState() => _PeopleViewPageState();
}

class _PeopleViewPageState extends BaseViewState<PeopleViewPage> {
  // Context Panel Data
  List<Map<String, dynamic>> _recentPeople = [];
  List<Map<String, dynamic>> _starredPeople = [];
  bool _isLoadingContextPanel = false;
  static const int _contextPanelLimit = 10;

  // EventBus subscriptions
  StreamSubscription? _newMessageSubscription;
  StreamSubscription? _conversationSubscription;

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

  /// Setup Event Bus listeners for real-time updates
  void _setupEventBusListeners() {
    // Listen for new messages
    _newMessageSubscription = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.newMessage)
        .listen((data) {
          debugPrint('[PEOPLE_VIEW] New message received via Event Bus');
          // Reload context panel data to update recent conversations
          if (mounted) {
            _loadContextPanelData();
          }
        });

    // Listen for new conversations
    _conversationSubscription = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.newConversation)
        .listen((data) {
          debugPrint('[PEOPLE_VIEW] New conversation via Event Bus');
          // Reload context panel data to add new conversation
          if (mounted) {
            _loadContextPanelData();
          }
        });

    debugPrint('[PEOPLE_VIEW] Event Bus listeners registered');
  }

  @override
  ContextPanelType get contextPanelType => ContextPanelType.people;

  @override
  Widget buildContextPanel() {
    // Use existing ContextPanel widget wrapper with people type
    return ContextPanel(
      type: ContextPanelType.people,
      recentPeople: _recentPeople,
      starredPeople: _starredPeople,
      onMessageTap: _handlePersonTap,
      isLoadingPeople: _isLoadingContextPanel,
      onLoadMorePeople: _loadMoreRecentPeople,
      hasMorePeople: false, // TODO: Implement pagination if needed
    );
  }

  @override
  Widget buildMainContent() {
    return PeopleScreen(
      onMessageTap: _handlePersonTap,
      showRecentSection: true, // Always show recent section in main content
    );
  }

  // ============================================================================
  // Context Panel Data Loading
  // ============================================================================

  /// Load data for context panel (recent conversations)
  /// Shows last 10 people from recent 1:1 conversations
  Future<void> _loadContextPanelData() async {
    setState(() => _isLoadingContextPanel = true);

    try {
      debugPrint('[PEOPLE_VIEW] Loading context panel data...');

      // Get unread provider from context
      final unreadProvider = context.read<UnreadMessagesProvider>();

      // Use shared utility to load data
      final peopleList = await PeopleContextDataLoader.loadRecentPeople(
        limit: _contextPanelLimit,
        unreadProvider: unreadProvider,
      );

      // Load starred people separately
      final starredList = await PeopleContextDataLoader.loadStarredPeople(
        unreadProvider: unreadProvider,
      );

      if (mounted) {
        setState(() {
          _recentPeople = peopleList;
          _starredPeople = starredList;
          _isLoadingContextPanel = false;
        });
      }

      debugPrint(
        '[PEOPLE_VIEW] Loaded ${_recentPeople.length} people for context panel',
      );
    } catch (e, stackTrace) {
      debugPrint('[PEOPLE_VIEW] Error loading context panel data: $e');
      debugPrint('[PEOPLE_VIEW] Stack trace: $stackTrace');

      if (mounted) {
        setState(() => _isLoadingContextPanel = false);
      }
    }
  }

  /// Load more recent people for context panel
  void _loadMoreRecentPeople() {
    debugPrint('[PEOPLE_VIEW] Load more recent people requested');
    // TODO: Implement pagination if we want to show more than 10 in context panel
    // For now, main content shows all people, so this is less critical
  }

  // ============================================================================
  // Event Handlers
  // ============================================================================

  /// Handle person tap - navigate to messages view with this person
  void _handlePersonTap(String uuid, String displayName) {
    debugPrint('[PEOPLE_VIEW] Person tapped: $displayName ($uuid)');

    // Navigate to messages view with specific conversation
    context.go(
      '/app/messages/$uuid',
      extra: <String, dynamic>{'displayName': displayName},
    );
  }

  @override
  void onRetry() {
    super.onRetry();
    _loadContextPanelData();
  }
}
