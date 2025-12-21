# Delete Conversation Feature

## Overview
Added right-click (desktop) and long-press (mobile) context menu options to delete conversations from both the message list and channel list.

## Implementation Details

### Message List (`messages_list_view.dart`)
- **Context Menu**: Right-click or long-press on any conversation tile
- **Functionality**: 
  - Shows confirmation dialog
  - Deletes all messages with that user from SQLite
  - Removes conversation from recent conversations list
  - Removes star if conversation was starred
  - Emits `conversationDeleted` event
  - Shows success/error snackbar

### Channel List (`channels_list_view.dart`)
- **Context Menu**: Right-click or long-press on any channel tile
- **Functionality**:
  - Shows confirmation dialog with channel name
  - Deletes all messages from that channel in SQLite
  - Removes star if channel was starred
  - Emits `conversationDeleted` event
  - Shows success/error snackbar

## User Experience

### Desktop (Windows/macOS/Linux)
- Right-click on conversation/channel → Delete option appears
- Click "Delete" → Confirmation dialog
- Confirm → Messages deleted, UI updates

### Mobile (Android/iOS)
- Long-press on conversation/channel → Delete option appears
- Tap "Delete" → Confirmation dialog
- Confirm → Messages deleted, UI updates

## Technical Components

### Gesture Detection
```dart
GestureDetector(
  onSecondaryTapDown: (details) => _showContextMenu(...),  // Right-click
  onLongPressStart: (details) => _showContextMenu(...),     // Long-press
  child: AnimatedSelectionTile(...)
)
```

### Deletion Flow
1. User triggers context menu (right-click/long-press)
2. `_showConversationContextMenu()` or `_showChannelContextMenu()` displays menu
3. User selects "Delete" option
4. Confirmation dialog appears
5. On confirmation:
   - `SqliteMessageStore.deleteConversation(userId)` or `deleteChannel(channelId)`
   - Remove from recent conversations (messages only)
   - Remove star if starred
   - Emit `AppEvent.conversationDeleted`
   - Reload UI
   - Show snackbar confirmation

## Event System
- **Event**: `AppEvent.conversationDeleted`
- **Payload**: `{'userId': userId}` or `{'channelId': channelId}`
- **Purpose**: Notify other parts of the app that a conversation was deleted

## Safety Features
- **Confirmation Dialog**: Always asks "Are you sure?" before deletion
- **Non-reversible Warning**: Dialog clearly states "This action cannot be undone"
- **Error Handling**: Try-catch blocks with user-friendly error messages

## Files Modified
1. `client/lib/screens/dashboard/messages_list_view.dart`
   - Added `_showDeleteConversationDialog()`
   - Added `_deleteConversation()`
   - Added `_showConversationContextMenu()`
   - Wrapped `AnimatedSelectionTile` with `GestureDetector`

2. `client/lib/screens/dashboard/channels_list_view.dart`
   - Added `_showDeleteChannelDialog()`
   - Added `_deleteChannelMessages()`
   - Added `_showChannelContextMenu()`
   - Wrapped `AnimatedSelectionTile` with `GestureDetector`
   - Added imports for `SqliteMessageStore` and `EventBus`

3. `client/lib/services/event_bus.dart`
   - Added `conversationDeleted` to `AppEvent` enum

## Storage Methods Used
- `SqliteMessageStore.deleteConversation(String userId)` - Deletes all 1:1 messages
- `SqliteMessageStore.deleteChannel(String channelId)` - Deletes all channel messages
- `SqliteRecentConversationsStore.removeConversation(String userId)` - Removes from recent list
- `StarredConversationsService.unstarConversation(String uuid)` - Removes star from conversation
- `StarredChannelsService.unstarChannel(String uuid)` - Removes star from channel

## Testing Checklist
- [ ] Desktop: Right-click on message conversation → Delete works
- [ ] Desktop: Right-click on channel → Delete works
- [ ] Mobile: Long-press on message conversation → Delete works
- [ ] Mobile: Long-press on channel → Delete works
- [ ] Confirmation dialog appears with correct conversation/channel name
- [ ] Cancel button works (no deletion)
- [ ] Delete button removes messages from SQLite
- [ ] UI updates after deletion (conversation/channel removed from list)
- [ ] Starred conversations are unstarred when deleted
- [ ] Error handling works (network issues, database errors)
- [ ] Success snackbar appears after deletion
- [ ] Error snackbar appears if deletion fails
