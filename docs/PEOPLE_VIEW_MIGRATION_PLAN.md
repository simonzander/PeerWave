# People View Migration Action Plan

## Overview
Migrate the People view from the old dashboard system to the new view architecture with proper event system integration.

**Priority:** Design first, then refactoring
**Status:** Planning Phase

---

## Current State Analysis

### Existing Components

1. **`people_screen.dart`** (Main People Screen)
   - ✅ Modern grid layout with cards
   - ✅ Search functionality (displayName, atName)
   - ✅ Recent Conversations section (10 users)
   - ✅ Discover People section (10 random users + Load More)
   - ✅ Last message preview with timestamps
   - ✅ Responsive design
   - ❌ No EventBus integration yet
   - ❌ Uses callback system from old architecture

2. **`people_context_panel.dart`** (Context Panel)
   - ✅ Shows recent people list
   - ✅ Shows favorites (empty currently)
   - ✅ Load more functionality
   - ✅ Last message preview
   - ❌ Desktop only (hidden on tablet/mobile per new design)
   - ❌ No EventBus integration yet

### Integration Points Needed

1. **Route**: `/app/people` (already exists in routing)
2. **View Wrapper**: Need to create `people_view_page.dart` extending `BaseView`
3. **Navigation**: Already in `NavigationSidebar` (desktop) but hidden on mobile
4. **Context Panel**: Shown on desktop only (per new BaseView logic)

---

## Phase 1: Design Migration (Focus Now)

### Goal
Ensure the new People view looks identical to the current implementation while fitting into the new view architecture.

### Tasks

#### 1.1 Create PeopleViewPage Wrapper ✅ NEXT
**File:** `client/lib/app/views/people_view_page.dart`

```dart
import 'package:flutter/material.dart';
import '../views/base_view.dart';
import '../../widgets/context_panel.dart';
import '../../widgets/people_context_panel.dart';
import '../../screens/people/people_screen.dart';

/// People View - Browse and connect with users
/// 
/// Structure:
/// - Desktop: Context Panel (PeopleContextPanel) + Main Content (PeopleScreen)
/// - Tablet: Main Content only (PeopleScreen with showRecentSection=true)
/// - Mobile: Main Content only (PeopleScreen with showRecentSection=true)
class PeopleViewPage extends BaseView {
  const PeopleViewPage({
    super.key,
    required super.host,
  });

  @override
  State<PeopleViewPage> createState() => _PeopleViewPageState();
}

class _PeopleViewPageState extends BaseViewState<PeopleViewPage> {
  // Context Panel state
  List<Map<String, dynamic>> _recentPeople = [];
  bool _isLoadingContextPanel = false;

  @override
  ContextPanelType get contextPanelType => ContextPanelType.people;

  @override
  void initState() {
    super.initState();
    _loadContextPanelData();
  }

  /// Load data for context panel (recent conversations)
  Future<void> _loadContextPanelData() async {
    setState(() => _isLoadingContextPanel = true);
    
    try {
      // TODO: Load recent people from RecentConversationsService
      // This will be same data as PeopleScreen loads
      
      setState(() => _isLoadingContextPanel = false);
    } catch (e) {
      debugPrint('[PEOPLE_VIEW] Error loading context panel data: $e');
      setState(() => _isLoadingContextPanel = false);
    }
  }

  @override
  Widget buildContextPanel() {
    return PeopleContextPanel(
      host: widget.host,
      recentPeople: _recentPeople,
      favoritePeople: const [], // TODO: Implement favorites
      onPersonTap: _handlePersonTap,
      onLoadMore: _loadMoreRecentPeople,
      isLoading: _isLoadingContextPanel,
      hasMore: false, // TODO: Implement pagination
    );
  }

  @override
  Widget buildMainContent() {
    return PeopleScreen(
      host: widget.host,
      onMessageTap: _handlePersonTap,
      showRecentSection: true, // Always show on main screen
    );
  }

  void _handlePersonTap(String uuid, String displayName) {
    // Navigate to messages view with this person
    // TODO: Implement navigation to /app/messages?conversation={uuid}
    debugPrint('[PEOPLE_VIEW] Person tapped: $displayName ($uuid)');
  }

  void _loadMoreRecentPeople() {
    // Load more recent people for context panel
    debugPrint('[PEOPLE_VIEW] Load more recent people');
  }
}
```

**Checklist:**
- [ ] Create `people_view_page.dart`
- [ ] Extend `BaseView` with proper state
- [ ] Implement `buildContextPanel()` using `PeopleContextPanel`
- [ ] Implement `buildMainContent()` using `PeopleScreen`
- [ ] Handle person tap navigation
- [ ] Test layout on Desktop (context panel visible)
- [ ] Test layout on Tablet (context panel hidden)
- [ ] Test layout on Mobile (context panel hidden)

#### 1.2 Verify Routing ✅
**File:** `client/lib/main.dart`

Check if `/app/people` route exists and points to new view:

```dart
GoRoute(
  path: 'people',
  name: 'people',
  builder: (context, state) {
    final host = state.extra as String? ?? '';
    return PeopleViewPage(host: host);
  },
),
```

**Checklist:**
- [ ] Verify route exists
- [ ] Test navigation from sidebar
- [ ] Test direct URL access
- [ ] Verify host parameter passed correctly

#### 1.3 Update Navigation (Mobile Index)
**File:** `client/lib/app/app_layout.dart`

Verify mobile navigation includes People (currently hidden):

```dart
// Mobile: 4 items (Activities, Channels, Messages, Files)
// People is accessible via hamburger drawer menu
```

**Decision:** Keep People in drawer menu only for mobile (matches design).

**Checklist:**
- [ ] Verify People in drawer menu
- [ ] Test drawer navigation to People
- [ ] Ensure icon and label correct

#### 1.4 Style Consistency Review
Compare old vs new People view side-by-side:

**Desktop:**
- [ ] Context panel width matches (~280px)
- [ ] Main content grid layout identical
- [ ] Card styling matches (hover effects, shadows, colors)
- [ ] Typography consistent (font sizes, weights)
- [ ] Search bar styling matches
- [ ] Section headers match
- [ ] Load More button matches

**Tablet/Mobile:**
- [ ] Grid adapts to smaller screens
- [ ] Cards resize appropriately
- [ ] Touch targets are adequate (44x44 minimum)
- [ ] Bottom navigation doesn't overlap content

---

## Phase 2: Event System Integration (After Design)

### Goal
Replace callback-based message updates with EventBus subscriptions for real-time updates.

### Current Callback System

**In `people_screen.dart`:**
- Currently loads data once on init
- No real-time updates when new messages arrive
- Manually refreshes via `_loadInitialData()`

**In `people_context_panel.dart`:**
- Static data passed from parent
- No automatic updates

### Target Event System

Subscribe to these events from EventBus:

1. **`AppEvent.newMessage`** → Update last message in recent conversations
2. **`AppEvent.newConversation`** → Add new person to recent list
3. **`AppEvent.userStatusChanged`** → Update online/offline indicators

### Tasks

#### 2.1 Add EventBus Subscriptions to PeopleViewPage ⏳
**File:** `client/lib/app/views/people_view_page.dart`

```dart
class _PeopleViewPageState extends BaseViewState<PeopleViewPage> {
  // Event subscriptions
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;
  StreamSubscription<Map<String, dynamic>>? _conversationSubscription;
  StreamSubscription<Map<String, dynamic>>? _userStatusSubscription;

  @override
  void initState() {
    super.initState();
    _loadContextPanelData();
    _setupEventBusListeners();
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _conversationSubscription?.cancel();
    _userStatusSubscription?.cancel();
    super.dispose();
  }

  void _setupEventBusListeners() {
    // Listen for new messages
    _messageSubscription = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.newMessage)
        .listen(_handleNewMessage);

    // Listen for new conversations
    _conversationSubscription = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.newConversation)
        .listen(_handleNewConversation);

    // Listen for user status changes
    _userStatusSubscription = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.userStatusChanged)
        .listen(_handleUserStatusChanged);
  }

  void _handleNewMessage(Map<String, dynamic> data) {
    // Determine if 1:1 or group message
    final isChannel = data['channel'] != null;
    
    if (!isChannel) {
      // 1:1 message - update recent people list
      final sender = data['sender'] as String?;
      final message = data['message'] as String?;
      
      if (sender != null && message != null) {
        _updateRecentPerson(sender, message);
      }
    }
  }

  void _handleNewConversation(Map<String, dynamic> data) {
    final conversationId = data['conversationId'] as String?;
    final isChannel = data['isChannel'] as bool? ?? false;
    
    if (!isChannel && conversationId != null) {
      // New 1:1 conversation - add to recent people
      _addRecentPerson(conversationId);
    }
  }

  void _handleUserStatusChanged(Map<String, dynamic> data) {
    final userId = data['userId'] as String?;
    final isOnline = data['online'] as bool? ?? false;
    
    if (userId != null) {
      _updatePersonStatus(userId, isOnline);
    }
  }
}
```

**Checklist:**
- [ ] Add EventBus imports
- [ ] Create StreamSubscription fields
- [ ] Implement `_setupEventBusListeners()`
- [ ] Implement `_handleNewMessage()` with type checking
- [ ] Implement `_handleNewConversation()` with type checking
- [ ] Implement `_handleUserStatusChanged()`
- [ ] Cancel subscriptions in `dispose()`
- [ ] Test real-time updates when new messages arrive
- [ ] Test conversation list updates
- [ ] Test online status indicators

#### 2.2 Update PeopleScreen for Event-Driven Updates ⏳
**File:** `client/lib/screens/people/people_screen.dart`

Currently loads data once. Need to:
1. Accept refresh callback from parent
2. Or make it stateful with its own EventBus subscriptions

**Option A: Callback from Parent** (Simpler)
```dart
class PeopleScreen extends StatefulWidget {
  final ValueNotifier<bool>? refreshTrigger; // Trigger reload from parent
  
  // ... existing code
}

// In parent view, trigger refresh:
_refreshTrigger.value = !_refreshTrigger.value;
```

**Option B: Direct EventBus** (More autonomous)
```dart
class _PeopleScreenState extends State<PeopleScreen> {
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;
  
  void _setupEventBusListeners() {
    _messageSubscription = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.newMessage)
        .listen((data) {
          // Reload recent conversations if it's a 1:1 message
          if (data['channel'] == null) {
            _loadRecentConversationUsers();
          }
        });
  }
}
```

**Decision:** Use Option A initially (simpler), can switch to Option B later.

**Checklist:**
- [ ] Decide on approach (A or B)
- [ ] Implement chosen approach
- [ ] Test automatic refresh when messages received
- [ ] Verify no duplicate entries
- [ ] Check performance (no excessive reloads)

#### 2.3 Message Type Filtering ⏳
**Critical:** Different message types must be handled correctly.

**Message Types from Signal:**
- `message` → Regular text message (show in recent, update preview)
- `file` → File attachment (show as "📎 File")
- `image` → Image attachment (show as "🖼️ Image")
- `voice` → Voice message (show as "🎤 Voice")
- `read_receipt` → System message (IGNORE - don't update UI)
- `delivery_receipt` → System message (IGNORE - don't update UI)
- `senderKeyRequest` → System message (IGNORE - don't update UI)
- `fileKeyRequest` → System message (IGNORE - don't update UI)

**Implementation:**
```dart
void _handleNewMessage(Map<String, dynamic> data) {
  final type = data['type'] as String?;
  
  // Filter out system messages
  const systemTypes = [
    'read_receipt',
    'delivery_receipt',
    'senderKeyRequest',
    'fileKeyRequest',
  ];
  
  if (systemTypes.contains(type)) {
    debugPrint('[PEOPLE_VIEW] Ignoring system message type: $type');
    return;
  }
  
  // Only update for content messages
  const contentTypes = ['message', 'file', 'image', 'voice'];
  if (!contentTypes.contains(type)) {
    debugPrint('[PEOPLE_VIEW] Unknown message type: $type');
    return;
  }
  
  // Handle content message
  final isChannel = data['channel'] != null;
  if (!isChannel) {
    final sender = data['sender'] as String?;
    final message = _formatMessagePreview(data);
    
    if (sender != null && message != null) {
      _updateRecentPerson(sender, message);
    }
  }
}

String _formatMessagePreview(Map<String, dynamic> data) {
  final type = data['type'] as String?;
  
  switch (type) {
    case 'file':
      return '📎 File';
    case 'image':
      return '🖼️ Image';
    case 'voice':
      return '🎤 Voice';
    case 'message':
    default:
      final msg = data['message'] as String? ?? '';
      if (msg.length > 50) {
        return '${msg.substring(0, 50)}...';
      }
      return msg;
  }
}
```

**Checklist:**
- [ ] Define system message types to filter
- [ ] Define content message types to handle
- [ ] Implement type filtering in `_handleNewMessage()`
- [ ] Implement message preview formatting
- [ ] Test with different message types
- [ ] Verify system messages don't trigger updates
- [ ] Verify content messages update correctly

---

## Phase 3: Testing & Validation

### Design Testing
- [ ] Desktop layout matches old dashboard
- [ ] Tablet layout works without context panel
- [ ] Mobile layout works with drawer navigation
- [ ] All hover effects work
- [ ] All animations smooth
- [ ] Typography consistent
- [ ] Colors match theme
- [ ] Icons correct

### Event System Testing
- [ ] New 1:1 message updates recent list
- [ ] New 1:1 message updates last message preview
- [ ] New conversation adds person to recent
- [ ] User status changes update online indicators
- [ ] System messages don't trigger UI updates
- [ ] No duplicate entries in lists
- [ ] Performance acceptable (no lag)
- [ ] Memory usage stable (no leaks)

### Integration Testing
- [ ] Navigation from sidebar works
- [ ] Person tap navigates to messages
- [ ] Search works across all layouts
- [ ] Load More works
- [ ] Refresh works
- [ ] Context panel syncs with main content

---

## Phase 4: Cleanup & Optimization

### Remove Old Code
- [ ] Remove old People view from dashboard (if separate)
- [ ] Remove unused callback systems
- [ ] Remove duplicate data loading logic

### Performance Optimization
- [ ] Implement proper pagination
- [ ] Cache user profiles
- [ ] Debounce event handlers
- [ ] Optimize re-renders

### Documentation
- [ ] Update People view documentation
- [ ] Document event subscriptions
- [ ] Add code comments
- [ ] Update architecture diagrams

---

## Migration Steps Summary

### Step 1: Design (Current Focus)
1. ✅ Create `people_view_page.dart` wrapper
2. ✅ Verify routing
3. ✅ Test layouts (desktop/tablet/mobile)
4. ✅ Ensure visual consistency

### Step 2: Event System
1. ⏳ Add EventBus subscriptions to view
2. ⏳ Implement message type filtering
3. ⏳ Update recent conversations on events
4. ⏳ Update online status on events

### Step 3: Testing
1. ⏳ Visual regression testing
2. ⏳ Functional testing
3. ⏳ Performance testing

### Step 4: Cleanup
1. ⏳ Remove old code
2. ⏳ Optimize performance
3. ⏳ Update documentation

---

## Dependencies

### Required Services
- ✅ `EventBus` (already implemented)
- ✅ `SignalService` (emits events)
- ✅ `RecentConversationsService` (provides data)
- ✅ `UserProfileService` (provides user info)
- ✅ `SqliteMessageStore` (stores messages)

### Required Components
- ✅ `BaseView` (view architecture)
- ✅ `PeopleScreen` (main content)
- ✅ `PeopleContextPanel` (context panel)
- ✅ `NavigationSidebar` (desktop nav)

---

## Known Issues & Considerations

1. **Favorites Feature**
   - Currently not implemented
   - Need API endpoint for user favorites
   - Need UI for marking/unmarking favorites

2. **Online Status**
   - Currently shows `isOnline: false` for all users
   - Need server-side user status tracking
   - Need socket events for status changes

3. **Load More Pagination**
   - Currently loads all users and filters client-side
   - Should implement server-side pagination for better performance

4. **Profile Picture Caching**
   - Currently loads pictures on every render
   - Should implement proper image caching

5. **Search Performance**
   - Currently searches client-side after loading all users
   - Should implement server-side search for large user bases

---

## Success Criteria

### Phase 1 (Design) Complete When:
- [x] New People view looks identical to old dashboard version
- [x] Works on desktop with context panel
- [x] Works on tablet/mobile without context panel
- [x] Navigation works from all entry points
- [x] No visual regressions

### Phase 2 (Events) Complete When:
- [ ] Real-time updates work for new messages
- [ ] System messages properly filtered
- [ ] No callback hell or event listener leaks
- [ ] Performance acceptable
- [ ] All message types handled correctly

### Phase 3 (Testing) Complete When:
- [ ] All automated tests pass
- [ ] Manual testing checklist complete
- [ ] No critical bugs
- [ ] Performance metrics acceptable

### Phase 4 (Cleanup) Complete When:
- [ ] Old code removed
- [ ] Documentation updated
- [ ] Code reviewed and approved
- [ ] Ready for production

---

## Timeline Estimate

- **Phase 1 (Design):** 2-3 hours
- **Phase 2 (Events):** 3-4 hours
- **Phase 3 (Testing):** 2-3 hours
- **Phase 4 (Cleanup):** 1-2 hours

**Total:** ~8-12 hours

---

## Next Action

**START HERE:** Create `client/lib/app/views/people_view_page.dart` with BaseView integration and test on all layouts.
