# Phase 1 Progress: Store Multi-Server Preparation

## ✅ Completed: identity_key_store.dart

### Changes Made

1. **Added Abstract Getters** ✅
   - `String get serverUrl`
   - `ApiService get apiService`
   - `SocketService get socketService`

2. **Updated Documentation** ✅
   - Added multi-server support section
   - Explained server-scoped services

3. **Removed Duplicate Methods** ✅
   - Deleted `getIdentityForServer()`
   - Deleted `getIdentityKeyPairForServer()`
   - Deleted `getIdentityKeyPairDataForServer()`

4. **Updated Storage Calls** ✅
   - `getIdentity()` - passes `serverUrl`
   - `getIdentityKeyPairData()` - passes `serverUrl`
   - `storage.storeEncrypted()` - passes `serverUrl`
   - `saveIdentity()` - passes `serverUrl`
   - `removeIdentity()` - passes `serverUrl`
   - `removeIdentityKey()` - passes `serverUrl`
   - `hasIdentityKey()` - passes `serverUrl`
   - `_cleanupDependentKeys()` - passes `serverUrl` to deleteEncrypted

### Limitations (Phase 2/3 Dependencies)

1. **ApiService Still Static** ⚠️
   - Currently: `ApiService.post()` (static method)
   - Future: `apiService.post()` (instance method)
   - Blocker: ApiService needs refactoring to be instantiable

2. **SocketService Still Singleton** ⚠️
   - Currently: `SocketService().emit()` (singleton)
   - Future: `socketService.emit()` (instance)
   - Blocker: SocketService needs refactoring to be instantiable

3. **getAllKeys() No serverUrl Support** ⚠️
   - `storage.getAllKeys()` doesn't accept `serverUrl` parameter yet
   - Used in `_cleanupDependentKeys()` for bulk operations
   - Blocker: DeviceScopedStorageService needs `serverUrl` parameter added

### Status
**identity_key_store.dart: 90% Complete**
- ✅ Abstract getters added
- ✅ Duplicate methods removed
- ✅ Storage isolation added (where supported)
- ⏳ Waiting on Phase 2/3 for service refactoring

---

## 🔜 Remaining Stores

### signed_pre_key_store.dart - TODO
- [ ] Add abstract getters
- [ ] Update storage calls with serverUrl
- [ ] Replace `ApiService.post()` → prepare for `apiService.post()`
- [ ] Replace `SocketService().emit()` → prepare for `socketService.emit()`
- [ ] Update documentation

### pre_key_store.dart - TODO
- [ ] Add abstract getters
- [ ] Update storage calls with serverUrl
- [ ] Replace `ApiService.post()` → prepare for `apiService.post()`
- [ ] Remove ~200 lines of commented legacy code
- [ ] Update documentation

### sender_key_store.dart - TODO
- [ ] Add abstract getters
- [ ] Update storage calls with serverUrl
- [ ] Delete `loadSenderKeyForServer()` duplicate method
- [ ] Update documentation

### session_store.dart - TODO
- [ ] Add abstract getters
- [ ] Update storage calls with serverUrl
- [ ] Update documentation

---

## 📋 Phase 2/3 Blockers

Before stores can fully use injected services, these changes are needed:

### DeviceScopedStorageService
```dart
// Add serverUrl parameter to getAllKeys:
Future<List<String>> getAllKeys(
  String baseName, 
  String storeName,
  {String? serverUrl}  // 👈 ADD THIS
) async {
  // Use serverUrl for database selection
}
```

### ApiService
```dart
// Convert from static to instantiable:
class ApiService {
  final String baseUrl;
  
  ApiService({required this.baseUrl});
  
  Future<Response> post(String path, {dynamic data}) async {
    // Use this.baseUrl
  }
}
```

### SocketService
```dart
// Convert from singleton to instantiable:
class SocketService {
  final String serverUrl;
  
  SocketService({required this.serverUrl});
  
  void emit(String event, dynamic data) {
    // Use this.serverUrl connection
  }
}
```

---

## 🎯 Next Steps

1. **Complete remaining stores** (signed_pre_key, pre_key, sender_key, session)
2. **Document Phase 2/3 requirements** in detail
3. **Create migration guide** for KeyManager integration
4. **Plan ApiService refactoring** (Phase 3)
5. **Plan SocketService refactoring** (Phase 4)

---

## 📊 Overall Progress

| Store | Abstract Getters | Storage serverUrl | Service Prep | Docs | Complete |
|-------|-----------------|-------------------|--------------|------|----------|
| identity_key | ✅ | ✅ | ⚠️ | ✅ | 90% |
| signed_pre_key | ⏳ | ⏳ | ⏳ | ⏳ | 0% |
| pre_key | ⏳ | ⏳ | ⏳ | ⏳ | 0% |
| sender_key | ⏳ | ⏳ | ⏳ | ⏳ | 0% |
| session | ⏳ | ⏳ | ⏳ | ⏳ | 0% |

**Phase 1 Total: 18% Complete**
