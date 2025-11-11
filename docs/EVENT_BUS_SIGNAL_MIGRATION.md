# Event Bus Migration: Signal Service & API Service

## Overview
Restructured event creation to follow a clear separation of concerns:
- **SocketService**: Transport layer only (raw socket communication)
- **SignalService**: Handles encrypted socket events → emits events after decryption
- **ApiService**: Handles REST API calls → emits events after successful operations

This ensures all events contain **decrypted, validated data** and follow a consistent pattern.

## Architecture

### Event Creators

1. **SignalService** - Emits events for encrypted socket messages:
   - `AppEvent.newMessage` (1:1 and group messages)
   - `AppEvent.newConversation` (new direct message conversations)
   - `AppEvent.userStatusChanged` (user online/offline status)

2. **ApiService** - Emits events for REST API operations:
   - `AppEvent.newChannel` (channel created via API)
   - `AppEvent.channelUpdated` (channel modified via API)
   - `AppEvent.channelDeleted` (channel removed via API)

### Event Flow

```
┌─────────────────────────────────────────────────────────┐
│                    Raw Socket Event                      │
│         (encrypted message, user status, etc.)          │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                  SocketService                           │
│              (Transport Layer Only)                      │
│    • Manages WebSocket connection                        │
│    • Forwards raw events to SignalService               │
│    • No event emission                                  │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                  SignalService                           │
│         (Encryption + Event Creation)                    │
│    • Registers socket listeners                          │
│    • Decrypts messages                                  │
│    • Validates and filters system messages              │
│    • Emits events to EventBus                           │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                    EventBus                              │
│         (Decentralized Event Distribution)               │
│    • Broadcasts events to all subscribers               │
│    • Type-safe event streams                            │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                  Views/Widgets                           │
│            (Event Subscribers)                           │
│    • Listen to relevant events                           │
│    • Update UI with decrypted data                      │
└─────────────────────────────────────────────────────────┘


┌─────────────────────────────────────────────────────────┐
│                 REST API Operation                       │
│         (create/update/delete channel, etc.)            │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                   ApiService                             │
│          (REST API + Event Creation)                     │
│    • Makes HTTP requests                                 │
│    • Wraps channel CRUD operations                      │
│    • Emits events after successful responses            │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                    EventBus                              │
│         (Same event distribution system)                 │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                  Views/Widgets                           │
└─────────────────────────────────────────────────────────┘
```

## Changes Made

### 1. SocketService (`client/lib/services/socket_service.dart`)
**Removed:**
- ❌ `_setupEventBusForwarding()` method
- ❌ All EventBus emissions
- ❌ `import 'event_bus.dart'`

**Result:** Pure transport layer, no business logic

---

### 2. SignalService (`client/lib/services/signal_service.dart`)

**Added:**
- ✅ `import 'event_bus.dart'`
- ✅ `_setupEventBusForwarding()` - registers socket listeners for user status
- ✅ Event emission in `receiveItem()` - for 1:1 messages after decryption
- ✅ Event emission in `groupItem` listener - for group messages after decryption

**Removed:**
- ❌ `emitChannelEvent()` method - moved to ApiService

#### A. 1:1 Messages (Direct Messages)
Located in `receiveItem()` method (after decryption):

```dart
if (!isSystemMessage) {
  debugPrint('[SIGNAL SERVICE] → EVENT_BUS: newMessage (1:1)');
  EventBus.instance.emit(AppEvent.newMessage, item);
  
  EventBus.instance.emit(AppEvent.newConversation, {
    'conversationId': sender,
    'isChannel': false,
  });
}
```

**Triggers:** After decrypting 1:1 messages  
**Events:** `newMessage`, `newConversation`  
**Data:** Fully decrypted message item

#### B. Group Messages (Channel Messages)
Located in `groupItem` socket listener:

```dart
SocketService().registerListener("groupItem", (data) {
  // ... unread count logic ...
  
  if (type == 'message' || type == 'file') {
    debugPrint('[SIGNAL SERVICE] → EVENT_BUS: newMessage (group)');
    EventBus.instance.emit(AppEvent.newMessage, data);
  }
  
  // ... callbacks ...
});
```

**Triggers:** After receiving group message from socket  
**Events:** `newMessage`  
**Data:** Decrypted group message data  
**Filter:** Only 'message' and 'file' types (no system messages)

#### C. User Status Events
Located in `_setupEventBusForwarding()` method:

```dart
SocketService().registerListener('user:status', (data) {
  debugPrint('[SIGNAL SERVICE] → EVENT_BUS: userStatusChanged');
  EventBus.instance.emit(AppEvent.userStatusChanged, data);
});
```

**Triggers:** When server sends user status updates  
**Events:** `userStatusChanged`  
**Data:** User status information (online, offline, typing, etc.)

---

### 3. ApiService (`client/lib/services/api_service.dart`)

**Added:**
- ✅ `import 'event_bus.dart'`
- ✅ `emitEvent()` - generic method to emit events
- ✅ `createChannel()` - wrapper for POST /client/channels with event emission
- ✅ `updateChannel()` - wrapper for PUT /client/channels/:id with event emission
- ✅ `deleteChannel()` - wrapper for DELETE /client/channels/:id with event emission

#### Generic Event Emission
```dart
static void emitEvent(AppEvent event, dynamic data) {
  debugPrint('[API SERVICE] → EVENT_BUS: $event');
  EventBus.instance.emit(event, data);
}
```

**Purpose:** Allows manual event emission if needed  
**Usage:** Generally not needed - use the wrapper methods below

#### Channel CRUD with Automatic Events

**Create Channel:**
```dart
static Future<Response> createChannel(
  String host, {
  required String name,
  String? description,
  bool? isPrivate,
  String? type,
  String? defaultRoleId,
}) async {
  final response = await post('$host/client/channels', data: {...});
  
  if (response.statusCode == 201) {
    emitEvent(AppEvent.newChannel, response.data);
  }
  
  return response;
}
```

**Triggers:** After successful channel creation (201)  
**Events:** `AppEvent.newChannel`  
**Data:** Full channel data from server response

**Update Channel:**
```dart
static Future<Response> updateChannel(
  String host,
  String channelId, {
  String? name,
  String? description,
  bool? isPrivate,
}) async {
  final response = await dio.put('$host/client/channels/$channelId', ...);
  
  if (response.statusCode == 200) {
    emitEvent(AppEvent.channelUpdated, response.data);
  }
  
  return response;
}
```

**Triggers:** After successful channel update (200)  
**Events:** `AppEvent.channelUpdated`  
**Data:** Updated channel data from server response

**Delete Channel:**
```dart
static Future<Response> deleteChannel(String host, String channelId) async {
  final response = await delete('$host/client/channels/$channelId');
  
  if (response.statusCode == 200 || response.statusCode == 204) {
    emitEvent(AppEvent.channelDeleted, {'channelId': channelId});
  }
  
  return response;
}
```

**Triggers:** After successful channel deletion (200 or 204)  
**Events:** `AppEvent.channelDeleted`  
**Data:** `{'channelId': channelId}`

---

### 4. Updated Widget Code

Updated all channel creation code to use new ApiService methods:

**Before:**
```dart
final dio = ApiService.dio;
final resp = await dio.post(
  '${widget.host}/client/channels',
  data: {...},
  options: Options(contentType: 'application/json'),
);
```

**After:**
```dart
final resp = await ApiService.createChannel(
  widget.host,
  name: channelName,
  description: channelDescription,
  isPrivate: isPrivate,
  type: channelType,
  defaultRoleId: selectedRole!.uuid,
);
```

**Updated Files:**
- ✅ `client/lib/widgets/desktop_navigation_drawer.dart`
- ✅ `client/lib/screens/dashboard/channels_list_view.dart`
- ✅ `client/lib/app/sidebar_panel.dart`

---

## Benefits

### 1. Security
- ✅ Events only contain **decrypted** data
- ✅ System messages filtered before emission
- ✅ No raw encrypted data passes through EventBus

### 2. Separation of Concerns
```
SocketService  → Transport (WebSocket management)
SignalService  → Encryption + Socket event creation
ApiService     → REST API + API event creation
EventBus       → Event distribution
Views          → Event consumption
```

### 3. Consistency
- All message events go through decryption pipeline
- All API events go through validation and success checks
- Single pattern for event emission across the app

### 4. Maintainability
- Clear ownership: SignalService for socket events, ApiService for REST events
- Easy to trace event sources
- Centralized event emission logic

### 5. Type Safety
- Events contain proper typed data after processing
- No ambiguity about data format or encryption state

---

## Migration Guide for Developers

### Subscribing to Events (No Changes!)
Views continue to listen to EventBus events as before:

```dart
// In a StatefulWidget
StreamSubscription<Map<String, dynamic>>? _messageSubscription;

@override
void initState() {
  super.initState();
  
  _messageSubscription = EventBus.instance
    .on<Map<String, dynamic>>(AppEvent.newMessage)
    .listen((data) {
      // Handle decrypted message
      print('New message: ${data['message']}');
    });
}

@override
void dispose() {
  _messageSubscription?.cancel();
  super.dispose();
}
```

### Creating/Updating/Deleting Channels
Use the new ApiService wrapper methods:

```dart
// Create channel
try {
  ApiService.init();
  final response = await ApiService.createChannel(
    host,
    name: 'My Channel',
    description: 'Channel description',
    isPrivate: false,
    type: 'signal',
    defaultRoleId: roleId,
  );
  
  if (response.statusCode == 201) {
    // Success! Event already emitted automatically
    print('Channel created: ${response.data['name']}');
  }
} catch (e) {
  print('Error creating channel: $e');
}

// Update channel
try {
  final response = await ApiService.updateChannel(
    host,
    channelId,
    name: 'Updated Name',
    description: 'Updated description',
  );
  
  if (response.statusCode == 200) {
    // Success! Event already emitted automatically
    print('Channel updated');
  }
} catch (e) {
  print('Error updating channel: $e');
}

// Delete channel
try {
  final response = await ApiService.deleteChannel(host, channelId);
  
  if (response.statusCode == 200 || response.statusCode == 204) {
    // Success! Event already emitted automatically
    print('Channel deleted');
  }
} catch (e) {
  print('Error deleting channel: $e');
}
```

### Manual Event Emission (Rare Cases)
If you need to emit an event manually:

```dart
// From SignalService context (for socket events)
EventBus.instance.emit(AppEvent.newMessage, messageData);

// From ApiService context (for API events)
ApiService.emitEvent(AppEvent.channelUpdated, channelData);
```

---

## Testing Checklist

### SignalService Events
- [ ] 1:1 messages trigger `newMessage` events after decryption
- [ ] Group messages trigger `newMessage` events after decryption
- [ ] System messages (receipts) don't trigger message events
- [ ] `newConversation` events emitted for new direct messages
- [ ] User status changes propagate correctly via `userStatusChanged`

### ApiService Events
- [ ] Creating channel triggers `newChannel` event with channel data
- [ ] Updating channel triggers `channelUpdated` event with updated data
- [ ] Deleting channel triggers `channelDeleted` event with channelId
- [ ] Events only emitted on successful responses (2xx status codes)
- [ ] Failed API calls don't emit events

### Integration
- [ ] Views update properly when subscribed to events
- [ ] No encrypted data leaks to EventBus
- [ ] Unread badge updates work correctly
- [ ] Channel list updates after channel CRUD operations
- [ ] Message views update in real-time

---

## Event Reference

### AppEvent Enum

| Event | Emitter | Trigger | Data Type |
|-------|---------|---------|-----------|
| `newMessage` | SignalService | 1:1 or group message decrypted | `Map<String, dynamic>` |
| `newConversation` | SignalService | New direct message conversation | `Map<String, dynamic>` |
| `userStatusChanged` | SignalService | User status update from socket | `Map<String, dynamic>` |
| `newChannel` | ApiService | Channel created via API | `Map<String, dynamic>` |
| `channelUpdated` | ApiService | Channel updated via API | `Map<String, dynamic>` |
| `channelDeleted` | ApiService | Channel deleted via API | `Map<String, dynamic>` |
| `unreadCountChanged` | (Other) | Unread count changes | `Map<String, dynamic>` |
| `fileUploadProgress` | (Other) | File upload progress | `Map<String, dynamic>` |
| `fileUploadComplete` | (Other) | File upload finished | `Map<String, dynamic>` |
| `videoConferenceStateChanged` | (Other) | Video call state changes | `Map<String, dynamic>` |

---

## Future Improvements

1. **Server-Side Channel Events**
   - Have server emit socket events for channel CRUD operations
   - Would ensure real-time updates for all clients
   - Current: API polling may miss updates from other clients

2. **Event Validation**
   - Add schema validation before emitting events
   - Ensure consistent data structure

3. **Event Replay**
   - Store events for offline sync
   - Replay missed events on reconnection

4. **Event Metrics**
   - Track event frequency and performance
   - Debug event flow in production

5. **Event Documentation**
   - Auto-generate event documentation from code
   - Keep event contracts in sync

---

## Related Files

### Core Services
- `client/lib/services/socket_service.dart` - Transport layer
- `client/lib/services/signal_service.dart` - Encryption + socket event emission
- `client/lib/services/api_service.dart` - REST API + API event emission
- `client/lib/services/event_bus.dart` - Event definitions and bus

### Event Subscribers (Examples)
- `client/lib/app/views/messages_view_page.dart` - Subscribes to message events
- `client/lib/app/views/channels_view_page.dart` - Subscribes to channel events

### Event Emitters (Usage Examples)
- `client/lib/widgets/desktop_navigation_drawer.dart` - Uses ApiService.createChannel()
- `client/lib/screens/dashboard/channels_list_view.dart` - Uses ApiService.createChannel()
- `client/lib/app/sidebar_panel.dart` - Uses ApiService.createChannel()

---

## Summary

✅ **Event creators are now clearly separated:**
- **SignalService**: Socket events (messages, user status) - after decryption
- **ApiService**: REST API events (channel CRUD) - after successful operations

✅ **All events contain validated, decrypted data**

✅ **Consistent patterns for event emission across the application**

✅ **Easy to extend with new events in the future**
