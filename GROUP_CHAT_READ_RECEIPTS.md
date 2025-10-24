# Group Chat Read Receipts Implementation

## Overview
Implemented WhatsApp-style read receipts for group chats with detailed statistics showing "Read by X of Y" and visual indicators (grey/green checkmarks).

## Features
- **Visual Indicators**:
  - Grey single check: Delivered to server
  - Grey double check: Delivered to some/all devices
  - Grey double check + "Read by X of Y": Some devices have read
  - Green double check + "Read by all": All devices have read

- **Automatic Message Cleanup**:
  - Messages deleted immediately when all devices have read them
  - 90-day fallback cleanup for orphaned messages (via cleanup.js)

## Implementation Details

### Database Changes
**File**: `server/db/model.js`
- Uses existing `readed` boolean field in Item model
- No additional fields needed - leverages existing `deliveredAt` for delivery tracking
- `readed` is set to `true` when a device reads the message

### Server-Side Changes
**File**: `server/server.js`

1. **`sendGroupMessage` Socket.IO Handler** (already existed):
   - Creates Items for all member devices
   - Emits messages to online devices
   - Sends `groupMessageDelivery` receipt with recipient count
   - Auto-deletes when all devices have `deliveredAt`

2. **`groupMessageRead` Socket.IO Handler** (NEW):
   - Updates `readed` boolean to `true` for specific device
   - Calculates statistics:
     * `readCount`: Devices with `readed = true`
     * `deliveredCount`: Devices with `deliveredAt` set
     * `totalCount`: Total devices in group
     * `allRead`: True when all devices have `readed = true`
   - Emits `groupMessageReadReceipt` to sender with statistics
   - Auto-deletes message when `allRead === true`

### Client-Side Changes

#### 1. SignalService (`client/lib/services/signal_service.dart`)
- Added listener for `groupMessageReadReceipt` Socket.IO event
- Implemented `_handleGroupMessageReadReceipt()` method
- Triggers callbacks to update UI with read statistics

#### 2. MessageList Widget (`client/lib/widgets/message_list.dart`)
- Modified `_buildMessageStatus()` to support group messages
- Detects group messages by checking if `totalCount != null`
- Display logic:
  ```dart
  if (readCount == totalCount) {
    // Green double check + "Read by all"
  } else if (readCount > 0) {
    // Grey double check + "Read by X of Y"
  } else if (deliveredCount == totalCount) {
    // Grey double check + "Delivered to all"
  } else if (deliveredCount > 0) {
    // Grey check + "Delivered to X of Y"
  }
  ```
- Maintains backward compatibility with 1:1 messages

#### 3. SignalGroupChatScreen (`client/lib/screens/messages/signal_group_chat_screen.dart`)

**Added Methods**:
1. `_handleDeliveryReceipt(data)`:
   - Receives `groupMessageDelivery` from server
   - Updates message with initial counts (deliveredCount: 0, totalCount: recipientCount)
   - Sets status to 'delivered'

2. `_handleReadReceipt(data)`:
   - Receives `groupMessageReadReceipt` from server
   - Updates message with current read/delivered counts
   - Sets status to 'read' when all devices read

**Modified Methods**:
1. `_handleGroupMessage()`:
   - Receives and decrypts message using **Sender Key** (symmetric, O(1) decryption)
   - All devices (including sender's) decrypt with the same key
   - **Checks if message is from current user** (`senderId == currentUserId`)
   - **Only non-sender devices** send read receipt:
     ```dart
     final isOwnMessage = senderId == signalService.currentUserId;
     if (!isOwnMessage) {
       SocketService().emit('groupMessageRead', {
         'itemId': itemId,
         'groupId': widget.channelUuid,
       });
     }
     ```
   - Sender's own devices skip read receipt (they already know they sent it)

2. `_setupMessageListener()` / `dispose()`:
   - Registered/unregistered listeners for:
     * `groupMessageReadReceipt` (via SignalService)
     * `groupMessageDelivery` (via SocketService)

## Data Flow

### Sending a Message
1. User sends message → `sendGroupMessage()`
2. Sender encrypts once with Sender Key (symmetric encryption via GroupCipher)
3. Server creates Items for **recipient devices only** (excludes sender's own devices)
4. Server stores with `cipherType: 4` (CiphertextMessage.senderKeyType)
5. Server emits `groupMessage` event (NOT `receiveItem`) to all online recipient devices
6. All recipients decrypt with GroupCipher using the same Sender Key
7. Server sends `groupMessageDelivery` to sender with `recipientCount`
8. Sender's UI shows grey check + "Delivered to 0 of N"

**Important Implementation Details**: 
- **Sender's devices do NOT receive their own messages** via Socket.IO (they already have it locally)
- **Group messages use `groupMessage` Socket.IO event**, not `receiveItem`
- **CipherType 4** is used for database storage (Signal Protocol's senderKeyType)
- **GroupCipher decrypts**, not SessionCipher (separate encryption domain from 1:1 messages)
- **decryptItem() rejects cipherType 4** to prevent routing errors

### Reading a Message
1. **Recipient device** receives `receiveItem` → decrypts with Sender Key → displays
2. **Important**: Sender's own devices receive the message but **do NOT send read receipts** (they already know they sent it)
3. **Only non-sender devices** emit `groupMessageRead` with `itemId` and `groupId`
4. Server updates `readed = true` for that specific device
5. Server calculates statistics (excluding sender's read status from their own message)
6. Server emits `groupMessageReadReceipt` to sender with statistics
7. Sender's UI updates to show "Read by X of Y"
8. When all non-sender devices read, server deletes message, UI shows green "Read by all"

### Why Sender's Devices Don't Send Read Receipts
- **Signal Protocol Best Practice**: Sender already knows they sent the message
- **Prevents Confusion**: Read receipts are for tracking recipients, not sender
- **Server-Side**: All devices get the message via symmetric key
- **Client-Side**: Only non-sender devices send read receipts
- **Statistics**: totalCount includes all devices, but read receipts only come from recipients

## Statistics Calculation
Server tracks per-device status in Items table:
```sql
SELECT 
  COUNT(CASE WHEN readed = true THEN 1 END) as readCount,
  COUNT(CASE WHEN deliveredAt IS NOT NULL THEN 1 END) as deliveredCount,
  COUNT(*) as totalCount
FROM Items
WHERE itemId = ? AND channel = ? AND type = 'groupMessage'
```

## Auto-Cleanup Logic
1. **Immediate Deletion**: When `allRead === true`, server deletes all Items
2. **Fallback Cleanup**: `cleanup.js` deletes Items older than 90 days
3. This ensures messages don't accumulate even if devices go offline

## Testing Checklist
- [ ] Send message to group with multiple members
- [ ] Verify "Delivered to X of Y" appears as devices receive
- [ ] Verify changes to "Read by X of Y" as devices open chat
- [ ] Verify green "Read by all" when all devices read
- [ ] Verify message deleted from server after all read
- [ ] Test with offline devices (should show partial counts)
- [ ] Test group membership changes (leaving/rejoining)

## Future Enhancements
1. **Performance Optimization**:
   - Batch read receipts (don't emit for every message immediately)
   - Debounce: Wait 1 second after scroll, then send for visible messages

2. **Edge Cases**:
   - Handle users leaving group (adjust totalCount)
   - Handle users rejoining (add new devices to tracking)
   - Very large groups: Show "Read by 42" instead of "Read by 42 of 100"

3. **User Experience**:
   - Tap on status to see list of who has read
   - Different colors for different read states
   - Animations when status changes

## Related Documentation
- `SENDER_KEY_IMPLEMENTATION.md` - Group encryption details
- `server/db/SIGNAL_GROUP_CHAT_README.md` - Signal group chat architecture
- `server/jobs/cleanup.js` - Message cleanup logic
