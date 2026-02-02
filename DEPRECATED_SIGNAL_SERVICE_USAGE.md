# Deprecated SignalService Usage Report

## Summary
The old `SignalService` singleton has been replaced with `SignalClient` (per-server instances managed by `ServerSettingsService`). A deprecation stub exists at `lib/services/signal_service.dart` that logs warnings but doesn't break the app.

## Migration Required

The following files still reference the deprecated `SignalService.instance`:

### 1. message_list.dart
- **Line 1111**: `currentUserId: SignalService.instance.currentUserId`
- **Usage**: Getting current user ID for message rendering
- **Migration**: 
  ```dart
  // Old:
  SignalService.instance.currentUserId
  
  // New:
  final signalClient = await ServerSettingsService.instance.getOrCreateSignalClient();
  signalClient.getCurrentUserId?.call()
  ```

### 2. meeting_dialog.dart
- **Line 860**: `final signal = SignalService.instance;`
- **Usage**: Accessing signal service for meeting operations
- **Migration**:
  ```dart
  // Old:
  final signal = SignalService.instance;
  
  // New:
  final signalClient = await ServerSettingsService.instance.getOrCreateSignalClient();
  // Use signalClient.meetingService for meeting operations
  ```

### 3. incoming_call_listener.dart
- **Line 36**: `SignalService.instance.registerItemCallback('call_notification', ...)`
- **Line 100**: Comment mentioning SignalService
- **Usage**: Registering callbacks for incoming call notifications
- **Migration**:
  ```dart
  // Old:
  SignalService.instance.registerItemCallback('call_notification', callback);
  
  // New:
  final signalClient = await ServerSettingsService.instance.getOrCreateSignalClient();
  signalClient.messagingService.itemTypeCallbacks['call_notification'] = [callback];
  ```

### 4. enhanced_message_input.dart
- **Line 785**: `final signalService = SignalService.instance;`
- **Line 790**: `signalService: signalService`
- **Line 814**: `await signalService.sendFileItem(...)`
- **Usage**: Sending file messages
- **Migration**:
  ```dart
  // Old:
  await SignalService.instance.sendFileItem(...);
  
  // New:
  final signalClient = await ServerSettingsService.instance.getOrCreateSignalClient();
  await signalClient.messagingService.sendFileMessage(...);
  ```

### 5. video_conference_view.dart
- **Line 450**: `final currentUserId = SignalService.instance.currentUserId;`
- **Line 484**: `await SignalService.instance.sendItem(...)`
- **Usage**: Getting user ID and sending meeting messages
- **Migration**:
  ```dart
  // Old:
  SignalService.instance.currentUserId
  SignalService.instance.sendItem(...)
  
  // New:
  final signalClient = await ServerSettingsService.instance.getOrCreateSignalClient();
  signalClient.getCurrentUserId?.call()
  await signalClient.messagingService.send1to1Message(...)
  ```

### 6. video_conference_prejoin_view.dart
- **Line 112**: `final userId = SignalService.instance.currentUserId;`
- **Line 113**: `final deviceId = SignalService.instance.currentDeviceId;`
- **Line 133**: `if (!SignalService.instance.isInitialized) { ... }`
- **Line 383**: `if (userId == SignalService.instance.currentUserId && ...)`
- **Usage**: Checking initialization and getting user/device IDs
- **Migration**:
  ```dart
  // Old:
  SignalService.instance.isInitialized
  SignalService.instance.currentUserId
  SignalService.instance.currentDeviceId
  
  // New:
  final signalClient = ServerSettingsService.instance.getSignalClient();
  signalClient?.isInitialized ?? false
  signalClient?.getCurrentUserId?.call()
  signalClient?.getCurrentDeviceId?.call()
  ```

## Current Status

✅ **No Breaking Changes**: The deprecation stub ensures the app continues to work
⚠️ **Warnings Logged**: Each deprecated call logs a debug message suggesting the new approach
📋 **Migration Recommended**: Update these files when convenient to remove deprecation warnings

## Migration Priority

1. **High Priority** (Core functionality):
   - incoming_call_listener.dart - Call notifications
   - enhanced_message_input.dart - File sending
   
2. **Medium Priority** (Meeting features):
   - meeting_dialog.dart - Meeting creation
   - video_conference_view.dart - Conference operations
   - video_conference_prejoin_view.dart - Pre-join checks
   
3. **Low Priority** (UI display):
   - message_list.dart - User ID display

## Benefits of Migration

1. **Multi-Server Support**: Properly route operations to the correct server
2. **Type Safety**: Use actual typed services instead of dynamic methods
3. **Better Error Handling**: SignalClient provides proper error handling
4. **Cleaner Code**: Direct access to specific services (messagingService, meetingService)
5. **No Deprecation Warnings**: Clean console output

## Testing After Migration

After updating each file:
1. Test the specific feature (calls, file sending, meetings, etc.)
2. Verify multi-server scenarios work correctly
3. Check that errors are properly handled
4. Confirm no deprecation warnings in console

## Architecture Reference

```
Old Architecture:
┌─────────────────────┐
│  SignalService      │ ← Singleton (all servers)
│  (Deprecated)       │
└─────────────────────┘

New Architecture:
┌─────────────────────────────────┐
│  ServerSettingsService          │
│  ├─ SignalClient (server1)      │ ← Per-server instances
│  ├─ SignalClient (server2)      │
│  └─ SignalClient (server3)      │
│      ├─ MessagingService        │ ← Mixin-based services
│      ├─ MeetingService           │
│      ├─ EncryptionService        │
│      └─ HealingService           │
└─────────────────────────────────┘
```

## Documentation

- SignalClient API: `lib/services/signal/signal.dart`
- Server Settings: `lib/services/server_settings_service.dart`
- Messaging Service: `lib/services/signal/core/messaging/messaging_service.dart`
- Meeting Service: `lib/services/signal/core/meeting/meeting_service.dart`
