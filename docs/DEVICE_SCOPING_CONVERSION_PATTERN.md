# Converting PermanentSentMessagesStore to Device-Scoped Storage

## Pattern to Follow

### OLD Pattern (direct IndexedDB):
```dart
if (kIsWeb) {
  final IdbFactory idbFactory = idbFactoryBrowser;
  final db = await idbFactory.open(_storeName, version: 2, /*...*/);
  var txn = db.transaction(_storeName, 'readwrite');
  var store = txn.objectStore(_storeName);
  
  // Operations...
  await store.put(data, key);
  
  await txn.completed;
}
```

### NEW Pattern (DeviceScopedStorageService):
```dart
if (kIsWeb) {
  final storage = DeviceScopedStorageService.instance;
  
  // Put encrypted
  await storage.putEncrypted(_storeName, _storeName, key, data);
  
  // Get decrypted
  var value = await storage.getDecrypted(_storeName, _storeName, key);
  
  // Get all keys
  final keys = await storage.getAllKeys(_storeName, _storeName);
  
  // Delete
  await storage.deleteEncrypted(_storeName, _storeName, key);
}
```

## Methods to Convert

1. ✅ `create()` - Remove IndexedDB initialization
2. ✅ `storeSentMessage()` - Use `putEncrypted()`
3. ✅ `loadSentMessages()` - Use `getAllKeys()` + `getDecrypted()`
4. ⏳ `loadAllSentMessages()` - Use `getAllKeys()` + `getDecrypted()`
5. ⏳ `deleteSentMessage()` - Use `deleteEncrypted()`
6. ⏳ `deleteAllSentMessages()` - Use `getAllKeys()` + `deleteEncrypted()`
7. ⏳ `_updateMessageStatus()` - Use `getDecrypted()` + `putEncrypted()`
8. ⏳ `clearAll()` - Use `getAllKeys()` + `deleteEncrypted()` for each

---

**Result**: Database naming changes from `peerwaveSentMessages` → `peerwaveSentMessages_{deviceId}`
