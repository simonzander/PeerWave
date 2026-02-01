# Multi-Server Support Implementation Roadmap

## 🎯 Architecture Goal

Enable PeerWave to connect to multiple Signal servers simultaneously with complete isolation:
- Each server gets dedicated ApiService, SocketService, KeyManager instances
- Stores remain "dumb" - just use scoped services via dependency injection
- DeviceScopedStorageService handles all data isolation transparently

## 📐 Architecture Diagram

```
SignalClient (per server)
├── serverUrl: "https://server1.com"
├── ApiService (baseUrl: serverUrl)
├── SocketService (serverUrl: serverUrl)
└── KeyManager (serverUrl, apiService, socketService)
    ├── with PermanentIdentityKeyStore
    ├── with PermanentSignedPreKeyStore
    ├── with PermanentPreKeyStore
    ├── with PermanentSenderKeyStore
    └── with PermanentSessionStore
```

**Key Insight**: Stores access KeyManager properties via mixins:
- `apiService` → used for HTTP uploads (server-scoped, knows baseUrl)
- `socketService` → used for real-time events (server-scoped, knows serverUrl)

**Storage Isolation is Automatic:**
- DeviceIdentityService creates unique deviceId per server (via authentication)
- DeviceScopedStorageService uses current deviceId to create isolated databases
- Example: `peerwaveSignal_deviceId_server1` vs `peerwaveSignal_deviceId_server2`
- **Stores don't need serverUrl** - isolation is transparent!

---

## 🚀 PHASE 1: REFACTOR API_SERVICE (TODO)

**Status**: Not Started

**Goal**: Make ApiService instantiable per server

### Current Issues
- Uses static methods exclusively
- Cannot have multiple instances for different servers
- Global state prevents server isolation

### Tasks

#### 1.1 Convert to Instance-Based Class
```dart
class ApiService {
  final String baseUrl;
  final Dio _dio;
  
  ApiService({required this.baseUrl}) {
    _dio = Dio(BaseOptions(
      baseURL: baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ));
  }
  
  // Convert all static methods to instance methods
  Future<Response> post(String path, {dynamic data, Options? options}) async {
    return await _dio.post(path, data: data, options: options);
  }
  
  Future<Response> get(String path, {Map<String, dynamic>? queryParameters, Options? options}) async {
    return await _dio.get(path, queryParameters: queryParameters, options: options);
  }
  
  // ... all other HTTP methods
}
```

#### 1.2 Remove Static/Global State
- [ ] Convert all static methods to instance methods
- [ ] Remove any global Dio instance
- [ ] Ensure each ApiService instance is independent

#### 1.3 Update External Callers (Outside Stores)
- [ ] Find all `ApiService.staticMethod()` calls in the codebase
- [ ] Update to use instance: `apiService.method()`
- [ ] Pass ApiService instance through dependency injection where needed

**Note**: Stores will be updated in Phase 3

**Deliverable**: Multiple ApiService instances can coexist

---

## ⏳ PHASE 2: REFACTOR SOCKET_SERVICE (TODO)

**Status**: Not Started

**Goal**: Make SocketService instantiable per server

### Current Issues
- Uses singleton pattern
- Cannot maintain multiple WebSocket connections
- Global state prevents server isolation

### Tasks

#### 2.1 Convert to Instance-Based Class
```dart
class SocketService {
  final String serverUrl;
  late final IO.Socket _socket;
  bool _isConnected = false;
  
  SocketService({required this.serverUrl}) {
    _socket = IO.io(serverUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
    });
  }
  
  void connect() {
    if (!_isConnected) {
      _socket.connect();
      _isConnected = true;
    }
  }
  
  void disconnect() {
    if (_isConnected) {
      _socket.disconnect();
      _isConnected = false;
    }
  }
  
  void emit(String event, dynamic data) {
    _socket.emit(event, data);
  }
  
  void on(String event, Function(dynamic) callback) {
    _socket.on(event, callback);
  }
  
  // ... other methods
}
```

#### 2.2 Support Multiple Connections
- [ ] Remove singleton pattern
- [ ] Allow multiple active WebSocket connections
- [ ] Proper connection lifecycle management per instance
- [ ] Event listener isolation per instance

#### 2.3 Update External Callers (Outside Stores)
- [ ] Find all `SocketService().method()` calls
- [ ] Update to use instance: `socketService.method()`
- [ ] Pass SocketService instance through dependency injection

**Note**: Stores will be updated in Phase 3

**Deliverable**: Multiple SocketService instances can coexist

---

## ⏳ PHASE 3: UPDATE STORES (TODO)

**Status**: Not Started

**Prerequisites from Phase 1 & 2**:
- ApiService is instantiable (Phase 1 ✅)
- SocketService is instantiable (Phase 2 ✅)

**Goal**: Update stores to use injected service instances

### Tasks

#### 3.1 Add Abstract Getters to All Store Mixins
- [ ] identity_key_store.dart ✅ (already done)
- [ ] signed_pre_key_store.dart
- [ ] pre_key_store.dart
- [ ] sender_key_store.dart
- [ ] session_store.dart

Add to each store:
```dart
mixin PermanentXxxStore implements XxxStore {
  // Abstract getters - provided by KeyManager
  ApiService get apiService;
  SocketService get socketService;
  
  // ... rest of store
}
```

#### 3.2 Replace Static/Singleton Service Calls
Update all stores to use injected instances:
```dart
// Before (WRONG):
await ApiService.post('/signal/prekey', data: {...});
SocketService().emit("removeSignedPreKey", {...});

// After (CORRECT):
await apiService.post('/signal/prekey', data: {...});
socketService.emit("removeSignedPreKey", {...});
```

#### 3.3 Storage Calls Work Automatically
**No changes needed!** DeviceScopedStorageService automatically uses the correct deviceId:
```dart
// Stores just call storage normally:
await storage.storeEncrypted(_storeName, _storeName, key, value);

// Behind the scenes:
// - DeviceIdentityService provides deviceId (unique per server)
// - DeviceScopedStorageService creates: baseName_deviceId
// - Complete isolation automatically!
```

#### 3.4 Remove Duplicate Methods
Delete these redundant methods:
- [ ] identity_key_store.dart: ✅ (already done)
- [ ] sender_key_store.dart: `loadSenderKeyForServer()`

#### 3.5 Clean Up Legacy Code
- [ ] pre_key_store.dart: Remove ~200 lines of commented `FlutterSecureStorage` blocks

#### 3.6 Update Documentation
Add to each store's header:
```dart
/// 🌐 Multi-Server Support:
/// This store is server-scoped via KeyManager.
/// - apiService: Used for HTTP uploads (server-scoped, knows baseUrl)
/// - socketService: Used for real-time events (server-scoped, knows serverUrl)
/// 
/// Storage isolation is automatic:
/// - DeviceIdentityService provides unique deviceId per server
/// - DeviceScopedStorageService creates isolated databases automatically
```

**Deliverable**: Stores use injected service instances

---

## ⏳ PHASE 4: UPDATE KEY_MANAGER (TODO)

**Status**: Not Started

**Prerequisites from Phase 1-3**:
- ApiService is instantiable (Phase 1 ✅)
- SocketService is instantiable (Phase 2 ✅)
- Stores expect injected services (Phase 3 ✅)

**Goal**: Make KeyManager server-scoped and provide services to stores

### Tasks

#### 4.1 Add Properties to KeyManager
```dart
class KeyManager with 
  PermanentIdentityKeyStore,
  PermanentSignedPreKeyStore,
  PermanentPreKeyStore,
  PermanentSenderKeyStore,
  PermanentSessionStore {
  
  final ApiService apiService;
  final SocketService socketService;
  
  // ... existing properties
}
```

#### 4.2 Update Constructor
```dart
KeyManager({
  required this.apiService,
  required this.socketService,
});
```

#### 4.3 Update Initialization
- [ ] Update KeyManager.init() to use scoped services
- [ ] Remove global service references
- [ ] Initialize all store mixins with proper context

**Deliverable**: KeyManager provides server context to all stores

---

## ⏳ PHASE 5: CREATE SIGNAL_CLIENT (TODO)

**Status**: Not Started

**Goal**: Top-level orchestration for per-server Signal instances

### Tasks

#### 5.1 Create SignalClient Class
```dart
class SignalClient {
  final String serverUrl;
  late final ApiService apiService;
  late final SocketService socketService;
  late final KeyManager keyManager;
  
  SignalClient({required this.serverUrl}) {
    apiService = ApiService(baseUrl: serverUrl);
    socketService = SocketService(serverUrl: serverUrl);
    keyManager = KeyManager(
      apiService: apiService,
      socketService: socketService,
    );
  }
  
  Future<void> initialize() async {
    // Authenticate to server (creates deviceId)
    await authenticate();
    
    // Initialize KeyManager (uses deviceId for storage)
    await keyManager.init();
    
    // Connect WebSocket
    socketService.connect();
  }
  
  Future<void> dispose() async {
    socketService.disconnect();
    // Cleanup resources
  }
}
```

#### 5.2 Update Application Code
```dart
// Multi-server usage:
final server1 = SignalClient(serverUrl: "https://server1.com");
final server2 = SignalClient(serverUrl: "https://server2.com");

await server1.initialize();
await server2.initialize();

// Each instance is completely isolated
await server1.keyManager.getIdentityKeyPair(); // server1 data
await server2.keyManager.getIdentityKeyPair(); // server2 data
```

#### 5.3 Add Server Management
- SignalClientManager to track active servers
- Server switching logic
- Cleanup on logout/disconnect

**Deliverable**: Full multi-server support operational

---

## ✅ SUCCESS CRITERIA

- [ ] Can create multiple SignalClient instances simultaneously
- [ ] Each instance has isolated storage (different databases)
- [ ] Each instance communicates with its own server
- [ ] No data leakage between servers
- [ ] No conflicts in API calls or WebSocket events
- [ ] Stores remain simple (no server logic)
- [ ] DeviceScopedStorageService handles all isolation transparently

---

## 📝 NOTES

### Why Stores Don't Need serverUrl
- **ApiService** is initialized with `baseUrl` - knows which server to upload to
- **SocketService** is initialized with `serverUrl` - knows which server for WebSocket
- **Storage isolation** is automatic via deviceId from DeviceIdentityService:
  - User authenticates to server1 → deviceId1 created
  - User authenticates to server2 → deviceId2 created
  - DeviceScopedStorageService uses current deviceId automatically
  - Databases are isolated: `baseName_deviceId1` vs `baseName_deviceId2`

### Backward Compatibility
- Phase 1 changes are backward compatible (stores work with current KeyManager)
- Phase 2+ may require migration of existing code

### Testing Strategy
- Unit tests: Mock ApiService, SocketService per server
- Integration tests: Multiple SignalClient instances
- E2E tests: Simultaneous connections to test servers

---

## 🎯 CURRENT STATUS

**Completed**:
- ✅ Phase 1: ApiService refactored (instance-based)
- ✅ Phase 2: SocketService refactored (instance-based)  
- ✅ Phase 3: Identity store updated (uses abstract getters)
- ✅ Phase 4: KeyManager updated (accepts injected services)
- ✅ Phase 5: SignalClient created (orchestrates all services)

**Active**: Phase 3 - Update remaining stores to use injected services

**Next**: Complete Phase 3 (remaining 4 stores), then wire up external callers

**Architecture**:
```dart
// Multi-server usage NOW possible:
final server1 = SignalClient(serverUrl: "https://server1.com");
final server2 = SignalClient(serverUrl: "https://server2.com");

await server1.initialize();
await server2.initialize();

// Each instance completely isolated
await server1.keyManager.getIdentityKeyPair(); // server1 data
await server2.keyManager.getIdentityKeyPair(); // server2 data
```
