# Group Chat Screen Migration Status

## Architecture Understanding

**Direct Messages** (already working):
```dart
final signalClient = await ServerSettingsService.instance.getOrCreateSignalClient();
await signalClient.messagingService.send1to1Message(...);  // Works!
```

SignalClient exposes `messagingService` as a **public property**, and screens call methods directly on it.

**Group Messages** (needs fixing):
The screen tries to call methods that don't exist yet on MessagingService:
```dart
await signalClient.messagingService.sendGroupItem(...);      // ❌ Doesn't exist
await signalClient.messagingService.hasSenderKey(...);       // ❌ Doesn't exist
await signalClient.messagingService.decryptGroupItem(...);   // ❌ Doesn't exist
```

MessagingService **has** `GroupMessagingMixin` but it only provides basic methods like `sendGroupMessage()` and `decryptGroupMessage()`. The screen needs more comprehensive methods that match what the old SignalService provided.

## Problem
The `signal_group_chat_screen.dart` file extensively uses the deprecated `SignalService.instance` singleton pattern throughout. It needs to be migrated to use the new per-server `SignalClient` from `ServerSettingsService`.

## Deprecated SignalService Usage Found (8 locations)

1. **Line 166**: `SignalService.instance.currentUserId`
   - Replace with: `UserProfileService.instance.currentUserUuid`

2. **Line 585**: `final signalService = SignalService.instance;`
   - Used for: `decryptGroupItem()`, `decryptedGroupItemsStore.storeDecryptedGroupItem()`, `currentUserId`
   - Needs: SignalClient to expose group decryption methods

3. **Line 676**: `SignalService.instance.markGroupItemAsRead(itemId);`
   - Needs: SignalClient to expose `markGroupItemAsRead()` method

4. **Line 789**: `final signalService = SignalService.instance;`
   - Used for: `loadSentGroupItems()`, `loadReceivedGroupItems()`, `decryptGroupItem()`, `currentUserId`
   - Needs: SignalClient to expose group item loading/decryption methods

5. **Line 1040**: `final signalService = SignalService.instance;`
   - Used for: Signal initialization check, `hasSenderKey()`, `createGroupSenderKey()`, `uploadSenderKeyToServer()`, `sendGroupItem()`
   - Needs: SignalClient to expose ALL group messaging methods

6. **Line 1402**: `SignalService.instance.currentUserId ?? ''`
   - Replace with: `UserProfileService.instance.currentUserUuid ?? ''`

7. **Line 1498**: `final signalService = SignalService.instance;`
   - Used for: `sendGroupItem()` (reactions)
   - Needs: SignalClient to expose `sendGroupItem()` method

8. **Line 1557**: `final signalService = SignalService.instance;`
   - Used for: `sendGroupItem()` (reactions)
   - Needs: SignalClient to expose `sendGroupItem()` method

## Required SignalClient Methods (Not Yet Exposed)

The following methods need to be exposed on SignalClient for group messaging:

### Group Session Management
- `hasSenderKey(channelId, userId, deviceId)` - Check if sender key exists
- `createGroupSenderKey(channelId)` - Create new sender key for group
- `uploadSenderKeyToServer(channelId)` - Upload sender key to server
- `loadAllSenderKeysForChannel(channelId)` - Batch load all member keys

### Group Messaging
- `sendGroupItem(channelId, message, itemId, type, metadata)` - Send encrypted group message
- `decryptGroupItem(channelId, senderId, senderDeviceId, ciphertext)` - Decrypt group message
- `markGroupItemAsRead(itemId)` - Send read receipt for group message

### Group Message Storage
- `loadSentGroupItems(channelId)` - Load sent messages from store
- `loadReceivedGroupItems(channelId)` - Load received/decrypted messages from store
- Access to `decryptedGroupItemsStore` for storing decrypted messages

## Solution: Add Methods to GroupMessagingMixin

Add the following methods to `group_messaging_mixin.dart` to match what the old SignalService provided:

```dart
/// Check if sender key exists for group
Future<bool> hasSenderKey(String channelId, String userId, int deviceId) async {
  final senderAddress = SignalProtocolAddress(userId, deviceId);
  final senderKeyName = SenderKeyName(channelId, senderAddress);
  return await senderKeyStore.containsSenderKey(senderKeyName);
}

/// Create sender key for group (wrapper for existing method)
Future<void> createGroupSenderKey(String groupId) async {
  return await createAndDistributeSenderKey(groupId);
}

/// Upload sender key to server via REST API
Future<void> uploadSenderKeyToServer(String channelId) async {
  // Implementation needed - send to /api/channels/:channelId/sender-keys
}

/// Load all sender keys for channel from server
Future<Map<String, dynamic>> loadAllSenderKeysForChannel(String channelId) async {
  // Implementation needed - fetch from /api/channels/:channelId/sender-keys
}

/// Send group item with any type (message, file, emote, etc.)
Future<String> sendGroupItem({
  required String channelId,
  required String message,
  required String itemId,
  String type = 'message',
  Map<String, dynamic>? metadata,
}) async {
  // Already exists as sendGroupMessage - just add type parameter
  // Or rename sendGroupMessage to sendGroupItem
}

/// Decrypt group item (wrapper for existing decryptGroupMessage)
Future<String> decryptGroupItem({
  required String channelId,
  required String senderId,
  required int senderDeviceId,
  required String ciphertext,
}) async {
  // Call existing decryptGroupMessage with proper data format
  final data = {
    'channel': channelId,
    'message': ciphertext,
  };
  return await decryptGroupMessage(data, senderId, senderDeviceId);
}

/// Mark group item as read
void markGroupItemAsRead(String itemId) {
  socketService.emit('markGroupItemAsRead', {'itemId': itemId});
}
```

## Migration Strategy (SIMPLIFIED)

## Migration Strategy (SIMPLIFIED)

### Phase 1: Add Methods to GroupMessagingMixin ✅
Add the methods above to `group_messaging_mixin.dart`. These are mostly wrappers/renames of existing methods to match the API that the screen expects.

### Phase 2: Update signal_group_chat_screen.dart
Once Phase 1 is complete, do a simple find-and-replace:

**Replace SignalService singleton calls:**
```dart
// OLD (8 locations)
final signalService = SignalService.instance;
await signalService.sendGroupItem(...);

// NEW
final signalClient = await ServerSettingsService.instance.getOrCreateSignalClient();
await signalClient.messagingService.sendGroupItem(...);
```

**Replace currentUserId/currentDeviceId:**
```dart
// OLD
SignalService.instance.currentUserId
SignalService.instance.currentDeviceId

// NEW
UserProfileService.instance.currentUserUuid
DeviceIdentityService.instance.deviceId
```

**Update callback registration:**
```dart
// OLD
SignalService.instance.registerItemCallback('groupItem', handler);

// NEW
for (final type in displayableMessageTypes) {
  signalClient.registerReceiveItemChannel(type, widget.channelUuid, handler);
}
```

That's it! No need for wrapper methods on SignalClient - just call `signalClient.messagingService` directly, exactly like we do for direct messages.

### Phase 3: Update _initializeGroupChannel
Replace sender key setup calls:
```dart
// OLD
await SignalService.instance.hasSenderKey(...);
await SignalService.instance.createGroupSenderKey(...);
await SignalService.instance.uploadSenderKeyToServer(...);

// NEW  
await signalClient.messagingService.hasSenderKey(...);
await signalClient.messagingService.createGroupSenderKey(...);
await signalClient.messagingService.uploadSenderKeyToServer(...);
```

## Current Status
❌ **BLOCKED** - Cannot complete migration until SignalClient exposes group messaging methods.

The screen file has been partially updated but has compilation errors due to missing methods. Once Phase 1 (exposing methods on SignalClient) is complete, the full migration can be finished.

## Next Steps
1. **PRIORITY**: Expose all required group messaging methods on SignalClient (Phase 1)
2. Complete screen migration once methods are available (Phase 2)
3. Test group messaging end-to-end with new architecture
4. Update callback registration to use new patterns (Phase 3)
