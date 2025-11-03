# 🔓 Self-Revoke Implementation - P2P File Sharing

**Feature:** Users can remove themselves from a file's share list  
**Date:** October 30, 2025  
**Status:** ✅ Implemented  

---

## 🎯 Feature Overview

Users can now **remove themselves** from a file's `sharedWith` list without needing creator permission.

### Use Cases:

1. **Stop Seeding:** User wants to stop sharing a file
2. **Privacy:** User wants to remove a file from their device
3. **Storage Management:** Free up storage space
4. **Opt-Out:** User received unwanted share and wants to leave

---

## 🔐 Permission Model

### Before (Only Creator Could Revoke):
```
Creator:  ✅ Can revoke anyone
Others:   ❌ Cannot revoke (even themselves!)
```

### After (Self-Revoke Allowed):
```
Creator:  ✅ Can revoke anyone (including self)
Others:   ✅ Can revoke ONLY themselves
          ❌ Cannot revoke other users
```

---

## 🛠️ Implementation

### Server-Side (`server.js`)

```javascript
// Action-specific permission checks
if (action === 'revoke') {
  // Creator can revoke anyone
  if (isCreator) {
    // OK - Creator has full revoke rights
  }
  // Self-revoke: User can remove themselves
  else if (userIds.length === 1 && userIds[0] === userId) {
    console.log(`[P2P FILE] ✓ Self-revoke: User ${userId} removing self`);
    // OK - Self-revoke allowed
  }
  // Non-creator cannot revoke others
  else {
    console.log(`[P2P FILE] ❌ User ${userId} cannot revoke others`);
    return callback?.({ 
      success: false, 
      error: "Only creator can revoke others. You can only remove yourself." 
    });
  }
}
```

**Logic:**
1. ✅ **Creator** → Can revoke anyone
2. ✅ **Self-revoke** (`userIds = [self]`) → Allowed
3. ❌ **Revoke others** → Denied with clear error message

### Client-Side (`file_transfer_service.dart`)

```dart
/// Remove yourself from a file's share list
Future<void> removeSelfFromShare({
  required String fileId,
  required String chatId,
  required String chatType,
}) async {
  final currentUserId = await _getCurrentUserId();
  
  // Use existing revoke with self as target
  await revokeUsersFromShare(
    fileId: fileId,
    chatId: chatId,
    chatType: chatType,
    userIds: [currentUserId], // Only self
  );
}
```

**Features:**
- ✅ Convenience method for self-revoke
- ✅ Reuses existing three-phase commit (server → signal → local)
- ✅ Clean API for UI components

---

## 🧪 Test Scenarios

### ✅ Test 1: Self-Revoke (Non-Creator)

```javascript
// Setup
Alice uploads file.pdf (creator)
Alice shares with Bob

// Action
Bob calls: revokeUsersFromShare(fileId, [Bob])

// Result
✅ SUCCESS: Bob removed from sharedWith
✅ Bob stops seeding
✅ Signal notification sent
✅ Local metadata updated
```

### ✅ Test 2: Creator Self-Revoke

```javascript
// Setup
Alice uploads file.pdf (creator)
Alice shares with Bob, Charlie

// Action
Alice calls: revokeUsersFromShare(fileId, [Alice])

// Result
✅ SUCCESS: Alice removed from sharedWith
⚠️  File still accessible by Bob and Charlie
⚠️  Creator can no longer manage file!
```

### ❌ Test 3: Non-Creator Tries to Revoke Others

```javascript
// Setup
Alice uploads file.pdf (creator)
Alice shares with Bob, Charlie

// Action
Bob calls: revokeUsersFromShare(fileId, [Charlie])

// Result
❌ DENIED: "Only creator can revoke others. You can only remove yourself."
✅ Charlie still has access
✅ Bob can only remove himself
```

### ✅ Test 4: Creator Revokes Others

```javascript
// Setup
Alice uploads file.pdf (creator)
Alice shares with Bob, Charlie

// Action
Alice calls: revokeUsersFromShare(fileId, [Bob, Charlie])

// Result
✅ SUCCESS: Both Bob and Charlie removed
✅ Alice retains full control
✅ Signal notifications sent to both
```

---

## 🔄 Three-Phase Commit Flow

Self-revoke uses the same secure commit as regular revoke:

```
User initiates self-revoke
         │
         ▼
┌──────────────────────┐
│   Phase 1: Server    │
│   Update sharedWith  │
└──────────┬───────────┘
           │ ✅ Success
           ▼
┌──────────────────────┐
│   Phase 2: Signal    │
│   Encrypted notify   │
└──────────┬───────────┘
           │ ✅ Sent
           ▼
┌──────────────────────┐
│   Phase 3: Local     │
│   Update metadata    │
└──────────────────────┘
           │
           ▼
      ✅ Complete
```

**Benefits:**
- ✅ Server is source of truth
- ✅ Signal ensures encrypted notification
- ✅ Local state stays in sync

---

## 📱 UI Integration Examples

### Example 1: File Options Menu

```dart
PopupMenuButton(
  itemBuilder: (context) => [
    PopupMenuItem(
      child: Text('Stop Sharing'),
      onTap: () async {
        await fileTransferService.removeSelfFromShare(
          fileId: fileId,
          chatId: chatId,
          chatType: 'group',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Stopped sharing file')),
        );
      },
    ),
  ],
)
```

### Example 2: Storage Management

```dart
// User wants to free up space
ListTile(
  title: Text('Remove from my device'),
  subtitle: Text('Stop seeding and free up storage'),
  trailing: Icon(Icons.delete_outline),
  onTap: () async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stop seeding?'),
        content: Text('You will stop sharing this file with others.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Remove'),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      await fileTransferService.removeSelfFromShare(
        fileId: fileId,
        chatId: chatId,
        chatType: chatType,
      );
      // Delete local chunks
      await fileTransferService.deleteFile(fileId);
    }
  },
)
```

---

## ⚠️ Important Considerations

### 1. Creator Self-Revoke Warning

If creator removes themselves:
```
⚠️  WARNING: You are the file creator!
⚠️  After removal, you cannot manage this file anymore.
⚠️  Other users will still have access.
⚠️  Continue?
```

**Recommendation:** Show warning dialog before allowing creator self-revoke.

### 2. Last User Self-Revoke

If last user removes themselves:
```
⚠️  WARNING: You are the last seeder!
⚠️  After removal, this file will become unavailable.
⚠️  Consider downloading a copy first.
⚠️  Continue?
```

**Recommendation:** Check seeder count before allowing removal.

### 3. Active Download

If user is downloading:
```
❌  ERROR: Cannot remove yourself while downloading.
❌  Complete or cancel download first.
```

**Recommendation:** Block self-revoke during active download.

---

## 🔍 Logging

### Server Logs

```bash
# Successful self-revoke
[P2P FILE] ✓ Self-revoke: User bob removing self from abc12345

# Denied: Try to revoke others
[P2P FILE] ❌ User bob cannot revoke others from abc12345 (not creator)

# Creator revoke
[P2P FILE] User alice revoking 2 users for file abc12345
```

### Client Logs

```bash
# Self-revoke initiated
[FILE TRANSFER] Self-revoking from file: abc123...

# Three-phase commit
[FILE TRANSFER] Step 1/3: Updating server share...
[FILE TRANSFER] ✓ Server updated: 1 users revoked
[FILE TRANSFER] Step 2/3: Sending encrypted Signal notification...
[FILE TRANSFER] ✓ Signal notifications sent
[FILE TRANSFER] Step 3/3: Updating local metadata...
[FILE TRANSFER] ✓ Successfully removed self from share
```

---

## 🎓 Security Benefits

### ✅ User Privacy
- Users can opt-out of unwanted shares
- No need to contact creator to remove yourself

### ✅ Storage Control
- Users can free up space at any time
- No permission needed for self-management

### ✅ Clear Permissions
- Error messages clearly state what's allowed
- No ambiguity about who can revoke whom

### ✅ Audit Trail
- All self-revokes are logged
- Server tracks who removed themselves

---

## 📊 Permission Matrix

| Action | Creator | Seeder (in sharedWith) | Other User |
|--------|---------|------------------------|------------|
| **Revoke Self** | ✅ | ✅ | N/A |
| **Revoke Others** | ✅ | ❌ | ❌ |
| **Add Users** | ✅ | ✅ | ❌ |
| **Announce File** | ✅ | ✅ | ❌ |
| **Download File** | ✅ | ✅ | ❌ |

---

## 🔮 Future Enhancements

### 1. Auto-Cleanup
```javascript
// When user self-revokes, auto-delete local chunks
if (selfRevoke) {
  await _storage.deleteAllChunks(fileId);
  await _storage.deleteFileMetadata(fileId);
}
```

### 2. Re-Join
```javascript
// Request to rejoin a file
Future<void> requestRejoin(String fileId) async {
  // Send request to creator via Signal
  await _signalService.sendFileAccessRequest(
    fileId: fileId,
    creatorId: creatorId,
  );
}
```

### 3. Temporary Leave
```javascript
// Stop seeding temporarily without leaving permanently
Future<void> pauseSeeding(String fileId) async {
  await _socketFileClient.unannounceFile(fileId);
  // Keep in sharedWith but don't announce
}
```

---

## ✅ Testing Checklist

- [ ] Self-revoke as non-creator works
- [ ] Self-revoke as creator works (with warning)
- [ ] Cannot revoke other users (error message shown)
- [ ] Signal notification sent on self-revoke
- [ ] Local metadata updated correctly
- [ ] Server sharedWith list updated
- [ ] Seeding stops after self-revoke
- [ ] Can re-announce after self-revoke (if still in sharedWith)
- [ ] Last seeder warning shown
- [ ] Creator warning shown before self-revoke

---

## 🎯 Summary

**Self-Revoke Feature:**
- ✅ Users can remove themselves from any file
- ✅ Creator can still revoke anyone
- ✅ Non-creators cannot revoke others
- ✅ Clear error messages
- ✅ Full audit trail
- ✅ Privacy and storage control

**Implementation Complete!** 🎉
