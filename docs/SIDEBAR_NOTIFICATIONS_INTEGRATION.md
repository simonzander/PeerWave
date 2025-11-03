# Sidebar Notifications Integration

## Overview

The sidebar has been enhanced to display notification badges next to channel and direct message names, with automatic sorting by most recent activity.

## Features

### 1. Notification Badges

Both channels and direct messages now display notification badges showing unread message counts:

- **Visual Design**: Red circular badge with white text
- **Position**: Displayed to the right of the channel/user name
- **Count Display**: Shows actual count up to 99, displays "99+" for counts above 99
- **Real-time Updates**: Badges automatically update when new messages arrive via `Consumer<NotificationProvider>`
- **Auto-hide**: Badge disappears when unread count is 0

### 2. Sorting by Recent Activity

Both lists are now sorted by most recent message activity:

- **Sort Order**: Most recent message first (descending)
- **Automatic**: Sorting updates automatically when new messages arrive
- **Fallback**: Items without timestamps maintain their original order at the bottom

### 3. Persistent Direct Messages

The Direct Messages list now persists across app restarts:

- **Storage**: Uses `SharedPreferences` via `RecentConversationsService`
- **Capacity**: Stores up to 20 most recent conversations
- **Auto-update**: Automatically updates when new messages arrive
- **Merging**: Combines stored conversations with runtime conversations passed as props

## Implementation Details

### Direct Messages Dropdown

**File**: `client/lib/app/sidebar_panel.dart`

**Changes**:
```dart
class _DirectMessagesDropdownState extends State<_DirectMessagesDropdown> {
  List<Map<String, String>> _recentConversations = [];

  @override
  void initState() {
    super.initState();
    _loadRecentConversations();
  }

  Future<void> _loadRecentConversations() async {
    final conversations = await RecentConversationsService.getRecentConversations();
    setState(() {
      _recentConversations = conversations;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Merge props and stored conversations
    final allConversations = <String, Map<String, String>>{};
    
    for (final conv in _recentConversations) {
      allConversations[conv['uuid']!] = conv;
    }
    
    for (final dm in widget.directMessages) {
      allConversations[dm['uuid']!] = dm;
    }

    return Consumer<NotificationProvider>(
      builder: (context, notificationProvider, _) {
        // Sort by last message time
        var conversationsList = allConversations.values.toList();
        conversationsList.sort((a, b) {
          final aTime = notificationProvider.lastMessageTimes[a['uuid']];
          final bTime = notificationProvider.lastMessageTimes[b['uuid']];
          
          if (aTime != null && bTime != null) {
            return bTime.compareTo(aTime);
          }
          if (aTime != null) return -1;
          if (bTime != null) return 1;
          return 0;
        });

        // Limit to 20 most recent
        if (conversationsList.length > 20) {
          conversationsList = conversationsList.sublist(0, 20);
        }

        // Render with notification badges
        return Column(
          children: [
            // ... header ...
            Row(
              children: [
                Icon(Icons.person),
                SizedBox(width: 6),
                Expanded(child: Text(displayName)),
                NotificationBadge(
                  userId: uuid,
                  child: SizedBox.shrink(),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
```

### Channels List Widget

**File**: `client/lib/app/sidebar_panel.dart`

**Changes**:
```dart
class _ChannelsListWidgetState extends State<_ChannelsListWidget> {
  @override
  Widget build(BuildContext context) {
    return Consumer<NotificationProvider>(
      builder: (context, notificationProvider, _) {
        // Sort channels by last message time
        final sortedChannels = List<Map<String, dynamic>>.from(widget.channels);
        sortedChannels.sort((a, b) {
          final aTime = notificationProvider.lastMessageTimes[a['uuid']];
          final bTime = notificationProvider.lastMessageTimes[b['uuid']];
          
          if (aTime != null && bTime != null) {
            return bTime.compareTo(aTime);
          }
          if (aTime != null) return -1;
          if (bTime != null) return 1;
          return 0;
        });

        // Render with notification badges
        return Column(
          children: [
            // ... header ...
            Row(
              children: [
                leadingIcon,
                SizedBox(width: 6),
                Expanded(child: Text(name)),
                if (isPrivate) Icon(Icons.lock),
                NotificationBadge(
                  channelId: uuid,
                  child: SizedBox.shrink(),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
```

## Integration with Global Listener System

### Architecture

```
MessageListenerService (Global Singleton)
  ↓
Receives Socket.IO events (receiveItem, groupItem, etc.)
  ↓
Decrypts messages & stores in local storage
  ↓
Triggers notification callback
  ↓
NotificationProvider (ChangeNotifier)
  ↓
Updates _unreadCounts & _lastMessageTimes Maps
  ↓
Calls RecentConversationsService.updateTimestamp()
  ↓
notifyListeners() triggers UI rebuild
  ↓
Sidebar widgets (wrapped in Consumer<NotificationProvider>)
  ↓
Re-render with updated badges and sorting
```

### Workflow

1. **App Startup**:
   - User logs in
   - `MessageListenerService.initialize()` registers global Socket.IO listeners
   - Sidebar loads recent conversations from `SharedPreferences`

2. **New Message Arrives**:
   - Socket.IO event received by `MessageListenerService`
   - Message decrypted and stored in local storage
   - `NotificationProvider._handleDirectMessageNotification()` or `_handleGroupMessageNotification()` called
   - `_unreadCounts[key]++` increments unread count
   - `_lastMessageTimes[key]` updated with message timestamp
   - `RecentConversationsService.updateTimestamp()` persists conversation to storage
   - `notifyListeners()` triggers rebuild of all `Consumer<NotificationProvider>` widgets
   - Sidebar re-renders with updated badge counts and re-sorted lists

3. **User Opens Chat**:
   - Chat screen calls `notificationProvider.markAsRead(key)`
   - Unread count reset to 0
   - `notifyListeners()` triggers rebuild
   - Badge disappears from sidebar

4. **Auto-add New Conversations**:
   - If a message arrives from a user/channel not in the sidebar
   - `NotificationProvider` tracks the timestamp
   - `RecentConversationsService` adds it to persistent storage
   - On next sidebar rebuild, the conversation appears at the top of the list

## Dependencies

### Services
- `MessageListenerService`: Global Socket.IO listener system
- `RecentConversationsService`: Persistent storage for recent DM conversations
- `NotificationProvider`: ChangeNotifier for reactive notification state

### Widgets
- `NotificationBadge`: Reusable badge widget for displaying unread counts
- `Consumer<NotificationProvider>`: Reactive wrapper for auto-updates

### Packages
- `provider`: State management and reactive UI updates
- `shared_preferences`: Persistent storage for recent conversations

## Files Modified

1. **client/lib/app/sidebar_panel.dart**:
   - Added imports for `NotificationProvider`, `RecentConversationsService`, `NotificationBadge`
   - Updated `_DirectMessagesDropdownState`:
     - Added `_recentConversations` state
     - Added `_loadRecentConversations()` method
     - Wrapped build in `Consumer<NotificationProvider>`
     - Added sorting by `lastMessageTimes`
     - Added `NotificationBadge` widgets
   - Updated `_ChannelsListWidgetState`:
     - Wrapped build in `Consumer<NotificationProvider>`
     - Added sorting by `lastMessageTimes`
     - Added `NotificationBadge` widgets

2. **client/lib/providers/notification_provider.dart**:
   - Added `_lastMessageTimes` Map for tracking message timestamps
   - Updated `_handleDirectMessageNotification()` to track timestamps and update storage
   - Updated `_handleGroupMessageNotification()` to track timestamps
   - Added `lastMessageTimes` getter for sorting

3. **client/lib/services/recent_conversations_service.dart**:
   - NEW: Service for persistent storage of recent DM conversations
   - Methods: `addOrUpdateConversation()`, `getRecentConversations()`, `updateTimestamp()`, `removeConversation()`, `clearAll()`

## Testing

### Manual Testing Steps

1. **Badge Display**:
   - Send a message to a channel/user
   - Verify badge appears with count "1"
   - Send more messages
   - Verify badge increments (e.g., "2", "3", etc.)
   - Send 100+ messages
   - Verify badge displays "99+"

2. **Sorting**:
   - Have multiple channels/DMs with messages
   - Send a new message to a channel at the bottom
   - Verify it moves to the top of the list
   - Send another message to a different channel
   - Verify the list re-sorts with most recent first

3. **Badge Clearing**:
   - Open a chat with unread messages
   - Verify the badge disappears immediately

4. **Persistence**:
   - Send messages to create recent conversations
   - Close and restart the app
   - Verify recent conversations still appear in the sidebar
   - Verify up to 20 conversations are stored

5. **Auto-add New Conversations**:
   - Receive a message from a user not in the sidebar
   - Verify the user appears at the top of the Direct Messages list
   - Receive a message in a channel not in the list
   - Verify the channel appears at the top of the Channels list

## Troubleshooting

### Badges Not Appearing

**Symptom**: Messages arrive but badges don't show

**Possible Causes**:
1. `MessageListenerService` not initialized
2. `NotificationProvider` not added to `MultiProvider` in `main.dart`
3. Socket not connected

**Solution**:
```dart
// In main.dart
MultiProvider(
  providers: [
    ChangeNotifierProvider(create: (_) => NotificationProvider()),
  ],
)

// After login:
await MessageListenerService.instance.initialize();
```

### Sorting Not Working

**Symptom**: New messages arrive but list doesn't re-sort

**Possible Causes**:
1. `lastMessageTimes` not being updated in `NotificationProvider`
2. `Consumer<NotificationProvider>` not wrapping the list

**Solution**:
- Check that `_handleDirectMessageNotification()` and `_handleGroupMessageNotification()` include:
  ```dart
  _lastMessageTimes[key] = DateTime.parse(notification.timestamp);
  ```
- Verify sidebar build method is wrapped in `Consumer<NotificationProvider>`

### Recent Conversations Not Persisting

**Symptom**: DM list resets after app restart

**Possible Causes**:
1. `RecentConversationsService.updateTimestamp()` not being called
2. `SharedPreferences` not initialized

**Solution**:
- Check notification handler calls:
  ```dart
  RecentConversationsService.updateTimestamp(key).catchError((e) {
    print('[ERROR] Failed to update conversation: $e');
  });
  ```
- Verify `shared_preferences` package is in `pubspec.yaml`

## Future Enhancements

1. **Sound/Vibration Notifications**:
   - Play sound when badge count increments
   - Vibrate on mobile devices

2. **Badge Customization**:
   - Different colors for different notification types
   - Configurable badge position

3. **Smart Sorting**:
   - Pin important channels to top
   - Separate unread from read conversations

4. **Conversation Metadata**:
   - Show last message preview
   - Display timestamp next to name

5. **Badge Actions**:
   - Long-press to mark as read without opening
   - Swipe to dismiss notifications

## Related Documentation

- [GLOBAL_MESSAGE_LISTENER_IMPLEMENTATION.md](./GLOBAL_MESSAGE_LISTENER_IMPLEMENTATION.md) - Global listener system architecture
- [client/lib/widgets/notification_badge.dart](./client/lib/widgets/notification_badge.dart) - Badge widget implementation
- [client/lib/services/recent_conversations_service.dart](./client/lib/services/recent_conversations_service.dart) - Conversation persistence
- [client/lib/providers/notification_provider.dart](./client/lib/providers/notification_provider.dart) - Notification state management
