# Device-Scoping Implementation Status

**Date:** November 8, 2025  
**Status:** 🔄 In Progress

---

## Problem Identified

The following stores were NOT device-scoped and NOT using encrypted storage:
1. ❌ `PermanentSentMessagesStore` (1:1 sent messages)
2. ❌ `PermanentDecryptedMessagesStore` (1:1 received messages)
3. ❌ `DecryptedGroupItemsStore` (group received messages)
4. ❌ `SentGroupItemsStore` (group sent messages)

They were using direct IndexedDB access (`idbFactoryBrowser.open()`) instead of `DeviceScopedStorageService`.

---

## Conversion Status

### ✅ PermanentSentMessagesStore - COMPLETE

**File:** `client/lib/services/permanent_sent_messages_store.dart`

**Changes Made:**
- ✅ Removed direct IndexedDB access
- ✅ Added `DeviceScopedStorageService` integration
- ✅ Converted all methods to use `putEncrypted()` / `getDecrypted()`
- ✅ Removed unused `idb_shim` import
- ✅ No compilation errors

**Methods Converted:**
- `create()` - Removed IndexedDB initialization
- `storeSentMessage()` - Now uses `putEncrypted()`
- `loadSentMessages()` - Now uses `getAllKeys()` + `getDecrypted()`
- `loadAllSentMessages()` - Now uses `getAllKeys()` + `getDecrypted()`
- `deleteSentMessage()` - Now uses `deleteEncrypted()`
- `deleteAllSentMessages()` - Now uses `deleteEncrypted()`
- `_updateMessageStatus()` - Now uses `getDecrypted()` + `putEncrypted()`
- `clearAll()` - Now uses `getAllKeys()` + `deleteEncrypted()`

**Result:**
- Database naming: `peerwaveSentMessages` → `peerwaveSentMessages_{deviceId}`
- All data encrypted with WebAuthn-derived keys
- Device isolation: each device has separate storage

---

### 🔄 PermanentDecryptedMessagesStore - IN PROGRESS

**File:** `client/lib/services/permanent_decrypted_messages_store.dart`

**Status:** Header updated, methods still need conversion

**Methods to Convert:**
- `hasDecryptedMessage()`
- `getDecryptedMessage()`
- `getDecryptedMessageFull()`
- `getMessagesFromSender()`
- `getAllUniqueSenders()`
- `storeDecryptedMessage()`
- `deleteDecryptedMessage()`
- `clearAll()`

---

### ⏳ DecryptedGroupItemsStore - NOT STARTED

**File:** `client/lib/services/decrypted_group_items_store.dart`

**Methods to Convert:**
- Similar pattern to PermanentDecryptedMessagesStore
- Handles group messages instead of 1:1

---

### ⏳ SentGroupItemsStore - NOT STARTED

**File:** `client/lib/services/sent_group_items_store.dart`

**Methods to Convert:**
- Similar pattern to PermanentSentMessagesStore
- Handles group messages instead of 1:1

---

## Conversion Pattern

### OLD (Direct IndexedDB):
```dart
if (kIsWeb) {
  final IdbFactory idbFactory = idbFactoryBrowser;
  final db = await idbFactory.open(_storeName, version: 2, /*...*/);
  var txn = db.transaction(_storeName, 'readwrite');
  var store = txn.objectStore(_storeName);
  await store.put(data, key);
  await txn.completed;
}
```

### NEW (DeviceScopedStorageService):
```dart
if (kIsWeb) {
  final storage = DeviceScopedStorageService.instance;
  await storage.putEncrypted(_storeName, _storeName, key, data);
}
```

---

## Benefits After Completion

1. **Device Isolation**
   - Each WebAuthn device has separate storage
   - Database naming: `{storeName}_{deviceId}`

2. **Encryption**
   - All data encrypted with WebAuthn-derived keys
   - Keys stored in SessionStorage (cleared on logout)

3. **Consistency**
   - All stores use the same pattern
   - Matches existing Signal protocol stores

4. **Security**
   - No plaintext storage in IndexedDB
   - Device-bound encryption keys

---

## Next Steps

1. Complete conversion of remaining 3 stores (estimated: ~30-45 min)
2. Test all stores with encryption
3. Verify device isolation works correctly
4. Update documentation

---

## Testing Checklist

- [ ] Test PermanentSentMessagesStore with device-scoped storage
- [ ] Test PermanentDecryptedMessagesStore with device-scoped storage
- [ ] Test DecryptedGroupItemsStore with device-scoped storage
- [ ] Test SentGroupItemsStore with device-scoped storage
- [ ] Verify different devices create separate databases
- [ ] Verify logout clears encryption keys
- [ ] Verify re-login derives new keys from WebAuthn

---

**Last Updated:** November 8, 2025  
**Current Focus:** Converting PermanentDecryptedMessagesStore methods
