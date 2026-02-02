# SignalClient Screen Migration Guide

## Overview
The screens `direct_messages_screen.dart` and `signal_group_chat_screen.dart` need to be updated to use SignalClient (per-server instances) instead of the deprecated SignalService (singleton).

## Key Architectural Changes

### SignalService (Deprecated) → SignalClient (New)
- **Old**: `SignalService.instance` (global singleton)
- **New**: `await ServerSettingsService.instance.getOrCreateSignalClient()` (per-server instance)

### Messaging API Changes
- **Old**: `SignalService.instance.sendItem()`
- **New**: `signalClient.messagingService.send1to1Message()` or `signalClient.messagingService.sendGroupItem()`

### User/Device Identity
- **Old**: `SignalService.instance.currentUserId`
- **New**: `UserProfileService.instance.currentUserUuid`

- **Old**: `SignalService.instance.currentDeviceId`
- **New**: `DeviceIdentityService.instance.deviceId`

### Callbacks/Listeners
The callback architecture has changed significantly:
- **Old**: `SignalService.instance.registerReceiveItem()`, `onDeliveryReceipt()`, `onReadReceipt()`
- **New**: Callbacks are registered via `SignalClient`'s `itemTypeCallbacks` and `receiveItemCallbacks` maps, which are passed to MessagingService during initialization

## Files Requiring Updates

### 1. direct_messages_screen.dart
**Status**: Partially migrated

**Completed**:
- ✅ Added ServerSettingsService, DeviceIdentityService, UserProfileService imports
- ✅ Replaced `currentUserId` with `UserProfileService.instance.currentUserUuid`
- ✅ Replaced `currentDeviceId` with `DeviceIdentityService.instance.deviceId`
- ✅ Updated `_sendReadReceipt()` to use SignalClient
- ✅ Updated `_sendMessageEnhanced()` to use SignalClient
- ✅ Updated `_addReaction()` and `_removeReaction()` to use SignalClient
- ✅ Updated message transformation in `_loadMessages()` to use UserProfileService

**Remaining**:
- ❌ `_setupReceiptListeners()`: Delivery/read receipt callbacks need new architecture
- ❌ `_setupReceiveItemCallbacks()`: registerReceiveItem needs new approach  
- ❌ `dispose()`: Callback cleanup needs updating
- ❌ `deleteItemFromServer()`: Needs SignalClient method

**Impact**: Compile errors in receipt listeners and callback registration

### 2. signal_group_chat_screen.dart
**Status**: Partially migrated

**Completed**:
- ✅ Added ServerSettingsService, DeviceIdentityService imports (UserProfileService already imported)
- ✅ Updated `dispose()` to remove deprecated callback unregistration
- ✅ Replaced `currentUserId` in `_loadChannelDetails()` with UserProfileService
- ✅ Added SignalClient retrieval in `_initializeGroupChannel()`

**Remaining**:
- ❌ `_initializeGroupChannel()`: Identity key check (`identityStore` not public in SignalClient)
- ❌ `_initializeGroupChannel()`: hasSenderKey, createGroupSenderKey, uploadSenderKeyToServer calls
- ❌ `_initializeGroupChannel()`: loadAllSenderKeysForChannel call
- ❌ `_setupMessageListener()`: registerItemCallback needs new architecture
- ❌ `_handleGroupItem()`: decryptGroupItem, decryptedGroupItemsStore access
- ❌ `_sendReadReceiptForMessage()`: markGroupItemAsRead call
- ❌ `_loadMessages()`: loadSentGroupItems, loadReceivedGroupItems calls
- ❌ `_sendMessage()`: hasSenderKey, sendGroupItem calls
- ❌ `_addReaction()` and `_removeReaction()`: sendGroupItem calls
- ❌ Multiple other locations using `SignalService.instance`

**Impact**: Multiple compile errors throughout file

### 3. file_manager_screen.dart
**Status**: Completed ✅

Successfully migrated to use:
- `SignalClient` from `ServerSettingsService.instance.getOrCreateSignalClient()`
- `UserProfileService.instance.currentUserUuid` for user identity
- `signalClient.messagingService` for file sharing

## Next Steps

### Short-term (Required for compilation)
1. **Expose necessary methods in SignalClient**:
   - Group messaging methods (hasSenderKey, createGroupSenderKey, sendGroupItem, etc.)
   - Identity/key access methods that screens need
   - Decrypted message stores access

2. **Create callback registration helpers** in SignalClient:
   - `registerDeliveryCallback()`
   - `registerReadCallback()`
   - `registerReceiveItemCallback()`
   - Make these proxy to the underlying messagingService callbacks

3. **Temporary wrapper methods** (if needed):
   - Add public getters for stores that screens access directly
   - Add delegation methods for operations that screens need

### Long-term (Architecture improvement)
1. **Move business logic out of screens**:
   - Create dedicated service layer for DM and Group messaging
   - Screens should only handle UI, not Signal Protocol details
   
2. **Event-driven architecture**:
   - Replace direct callbacks with EventBus events
   - Screens listen to events instead of registering callbacks

3. **State management**:
   - Consider using Provider/Bloc pattern for message state
   - Remove direct SQLite access from screens

## Migration Priority

1. **High Priority** (Blocking compilation):
   - file_manager_screen.dart ✅ DONE
   - Expose critical methods in SignalClient for group chat
   - Fix callback registration architecture

2. **Medium Priority**:
   - Complete direct_messages_screen.dart migration
   - Complete signal_group_chat_screen.dart migration

3. **Low Priority**:
   - Refactor business logic out of screens
   - Implement event-driven architecture

## Notes

- The SignalClient architecture is fundamentally different from SignalService
- Direct access to internal stores (identityStore, decryptedGroupItemsStore) should be avoided
- Callback patterns need rethinking - current screen code has tight coupling to Signal internals
- Consider creating facade methods in SignalClient for common screen operations
