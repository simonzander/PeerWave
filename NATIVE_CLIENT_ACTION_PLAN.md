# Windows Flutter Native Client - Action Plan

## 🎯 Goal
Make the Windows Flutter native client work with the refactored architecture, using magic link authentication instead of WebAuthn.

---

## 📋 Current State Analysis

### ✅ Already Prepared (Native Files Exist)
1. **Authentication**
   - `auth/auth_layout_native.dart` - Native auth layout
   - `auth/magic_link_native.dart` - Magic link verification
   - `auth/webauthn_js_stub.dart` - Stub for WebAuthn (not used on native)
   - `services/auth_service_native.dart` - Native auth service
   - `services/clientid_native.dart` - Native client ID generation

2. **Stubs**
   - `app/webauthn_stub.dart` - WebAuthn settings stub
   - `app/backupcode_stub.dart` - Backup code stub
   - `auth/backup_recover_stub.dart` - Backup recovery stub

3. **Utilities**
   - `utils/file_operations_native.dart` - Native file operations

### ❌ Missing/Needs Creation
1. **Post-Login Services** - Need native versions or conditional loading
2. **View Pages** - Currently only web versions exist
3. **Database Services** - Signal Protocol, Message Storage
4. **P2P File Transfer** - Native file storage implementation
5. **Video Conference** - May need platform-specific handling
6. **Socket Service** - May need native-specific connection logic

---

## 🔄 Native Client Workflow

### Authentication Flow
```
1. User opens Windows app
2. First launch: Shows server selection/entry screen
3. User goes to Web → Settings → Credentials → "Add New Client"
4. Web generates hex magic key: {serverUrl}:{randomHash}:{timestamp}:{hmacSignature}
5. Web displays as QR code or copyable string (user choice)
6. Web stores key temporarily in database (5 min expiration, one-time use)
7. User scans QR or pastes key in Windows app
8. App decodes magic key → extracts server URL + auth data
9. App authenticates with server using existing magic link endpoint
10. Server validates (checks expiration, one-time use) → creates session
11. App stores credentials securely (flutter_secure_storage)
12. App creates isolated database: server_{urlHash}_messages, etc.
13. App initializes services → loads dashboard
14. Server icon appears in left server panel
15. Next launch: Last active server opens automatically
```

### Multi-Server Architecture (Discord-like)
- **Server Panel**: Far left (~70px), shows server icons with notification badges
- **Simultaneous Login**: All servers logged in and kept in memory
- **Server Switching**: Click server icon → switches view, all providers cached
- **Data Isolation**: Each server has separate database tables (server_{hash}_*)
- **Notification Badges**: Show total unread count per server
- **Persistence**: All logged-in servers persist across app restarts

### Key Differences from Web
- **No WebAuthn** → Magic link only (hex key with HMAC)
- **No browser storage** → Use flutter_secure_storage for credentials
- **Server Panel** → Discord-like left sidebar with server icons
- **Multi-server support** → Simultaneous connections, isolated databases
- **Native file system** → Use dart:io, Downloads folder + server subfolders
- **Reconnection** → Exponential backoff (up to 5 min), background reconnect

---

## 📝 Implementation Plan

### Phase 1: Core Infrastructure (Priority 1)

#### 1.1 Server Configuration Service
**Create: `services/server_config_native.dart`**
```dart
class ServerConfig {
  String serverHash;    // Hash of server URL (for database naming)
  String serverUrl;     // Full server URL
  String credentials;   // Encrypted credentials
  String? iconPath;     // Custom server icon (optional)
  DateTime lastActive;  // For auto-open last server
  int unreadCount;      // For notification badge
}

// Responsibilities:
// - Manage list of logged-in servers
// - Store/retrieve server configs from flutter_secure_storage
// - Track active server
// - Generate server hash from URL (for database table prefixes)
// - Handle server add/remove/switch
// - Persist last active server
```

**Conditional Import:**
```dart
// In files that need server config
import 'services/server_config_web.dart' 
  if (dart.library.io) 'services/server_config_native.dart';
```

#### 1.2 Database Services
**Create native versions:**
- `services/storage/database_helper_native.dart` - Use sqflite (desktop)
  - Creates separate database tables per server: `server_{urlHash}_messages`
  - Keeps all servers' databases in memory simultaneously
  - Handles table creation/migration per server
  - On logout: Creates new hash-based tables (security isolation)
  
- `services/storage/database_encryption_service_native.dart`
  - Per-server encryption keys stored in flutter_secure_storage
  
- `services/storage/sqlite_message_store_native.dart`
  - Uses server hash prefix for table names
  
- `services/storage/sqlite_group_message_store_native.dart`
  - Uses server hash prefix for table names

**Database Naming Convention:**
```dart
// Example: User logs into https://peerwave.example.com
String serverHash = hashServerUrl("https://peerwave.example.com"); // "abc123def"

// Tables created:
// - server_abc123def_messages
// - server_abc123def_group_messages
// - server_abc123def_signal_store
// - etc.

// On logout + re-login with new magic key:
String newHash = generateUniqueHash(); // "xyz789ghi"
// New tables: server_xyz789ghi_messages (old data isolated)
```

**Files to modify with conditional imports:**
- `services/post_login_init_service.dart` - Add conditional database loading
- `services/signal_service.dart` - Add conditional storage imports

#### 1.3 File Storage Service
**Create: `services/file_transfer/storage_interface_native.dart`**
```dart
// Implement FileStorageInterface using dart:io
// Default location: Downloads folder
// Structure: Downloads/PeerWave/{serverHash}/{channelId}/filename.ext
// User-selectable location via settings (stored globally)
// Handle native file permissions
// Create server-specific subfolders automatically
```

---

### Phase 2: Authentication & Session (Priority 1)

#### 2.1 Update Main.dart Router
**Modify: `main.dart`**
- Add native-specific routes for server selection
- Handle magic link deep linking
- Remove WebAuthn dependencies for native
- Add server selection screen route

#### 2.2 Server Selection Screen
**Create: `screens/server_selection_screen.dart`** (Native-only, no _native suffix needed)
```dart
// Full-screen server selection (shown only on first launch or when no servers)
// Features:
// 1. Enter server URL manually
// 2. Paste magic hex key
// 3. Scan QR code (magic key)
// 4. Show "Add Server" explanation
// 5. Validate magic key format: {serverUrl}:{randomHash}:{timestamp}:{hmacSignature}
// 6. Call existing magic link endpoint on server
// 7. Handle errors (expired key, already used, invalid signature)
```

#### 2.3 Magic Key Decoder & Validator
**Create: `services/magic_key_service.dart`**
```dart
class MagicKeyService {
  // Parse hex key format: {serverUrl}:{randomHash}:{timestamp}:{hmacSignature}
  MagicKeyData parseMagicKey(String hexKey);
  
  // Validate structure (not signature - server does that)
  bool isValidFormat(String hexKey);
  
  // Check if timestamp indicates expiration (client-side check)
  bool isExpired(String hexKey);
  
  // Extract server URL from key
  String getServerUrl(String hexKey);
  
  // Call existing magic link endpoint: POST /auth/magic-link/verify
  Future<AuthResponse> verifyWithServer(String hexKey);
}
```

---

### Phase 3: Post-Login Services (Priority 2)

#### 3.1 Post-Login Init Service
**Modify: `services/post_login_init_service.dart`**

Add conditional initialization:
```dart
// Conditional database initialization
import 'storage/database_helper_web.dart' 
  if (dart.library.io) 'storage/database_helper_native.dart';

Future<void> _initializeDatabase() async {
  if (kIsWeb) {
    // Web: IndexedDB via sqflite_common_ffi_web
  } else {
    // Native: SQLite via sqflite
  }
}
```

#### 3.2 Socket Service Updates
**Modify: `services/socket_service.dart`**
- Handle multi-server connections (one socket per server)
- Reconnection logic with exponential backoff (up to 5 min)
- Track connection state per server
- Emit server-specific events
- Consider create `socket_service_native.dart` if significant differences

---

### Phase 4: View Layer Adaptation (Priority 2)

#### 4.1 Server Panel Widget (Discord-like)
**Create: `widgets/server_panel.dart`** (Native-only)
```dart
// Far-left vertical panel (~70px wide)
// Features:
// - List of server icons (circular/square, customizable per server)
// - Notification badges (show unread count per server)
// - Active server indicator (border/background highlight)
// - Click server icon → switches to that server view
// - "+ Add Server" button at bottom
// - Long-press → server options (edit icon, logout, etc.)
// - Tooltip on hover (server name/URL)
// - Drag to reorder servers (optional)
```

**Server Icon Management:**
```dart
// Default: First letter of server name
// Customizable: User can upload/select icon image
// Stored in: flutter_secure_storage or local app data
```

#### 4.2 App Layout Updates
**Modify: `app/app_layout.dart`**
- Add ServerPanel widget on far left (native only)
- Layout structure for native:
  ```
  [ServerPanel(70px)] [Sidebar] [MainContent] [ContextPanel?]
  ```
- Server switching reloads providers from cached state (no full re-init)
- Keep all server states in memory simultaneously
- Native window controls integration (Windows title bar)

---

### Phase 5: Feature-Specific Adaptations (Priority 3)

#### 5.1 File Transfer
**Native Requirements:**
- Native file picker integration
- Desktop file system access
- Native download folder handling

**Create:**
- `services/file_transfer/file_picker_native.dart`
- `services/file_transfer/download_manager_native.dart` (if needed)

#### 5.2 Video Conference
**Considerations:**
- LiveKit SDK has native support
- May need platform-specific camera/mic permissions
- Native window handling for video

**Action:** Test first, create natives only if issues arise

#### 5.3 Notifications
**Create: `services/notification_service_native.dart`**
- Use local_notifications package
- Native desktop notifications
- Update server panel badges with unread counts
- Aggregate notifications per server
- Click notification → switches to that server + channel
- System tray integration (optional)

---

### Phase 6: Settings & Credentials (Priority 3)

#### 6.1 Settings Screens
**Native-specific settings:**
- Server management (add/remove/logout servers, edit icons)
- No WebAuthn settings (hide for native)
- No backup codes (hide for native)
- Connected devices/clients (visible on web only)
- File download location preference
- Native-specific preferences (theme, startup behavior)

**Create:**
- `app/settings/server_management_page.dart` (Native-only)
  - List all logged-in servers
  - Edit server icon
  - Logout from server (clears credentials, keeps database for history)
  - Default server setting (optional)
  - Add new server (opens server selection flow)

**Modify:**
- `app/settings_sidebar.dart` - Conditional menu items
- Hide WebAuthn, Backup Codes for native
- Add "Server Management" menu item for native

---

## 🔧 Technical Implementation Details

### Conditional Import Pattern
```dart
// Universal file that needs platform-specific implementation
import 'feature_web.dart' if (dart.library.io) 'feature_native.dart';

// Or with more specificity
import 'feature_web.dart' 
  if (dart.library.io) 'feature_native.dart'
  if (dart.library.js) 'feature_web.dart';
```

### Platform Detection
```dart
import 'package:flutter/foundation.dart';

if (kIsWeb) {
  // Web-specific code
} else {
  // Native-specific code
}
```

### Storage Strategy
**Web:**
- IndexedDB via sqflite_common_ffi_web
- sessionStorage/localStorage for config
- Browser cache for files
- One database per client (web_config.json defines server)

**Native:**
- SQLite via sqflite (separate tables per server with hash prefix)
- flutter_secure_storage for server credentials + encryption keys
- Native file system: Downloads/PeerWave/{serverHash}/ (user-configurable)
- All server databases kept in memory simultaneously
- Last active server auto-opens on app start

---

## 📦 Dependencies to Add (pubspec.yaml)

```yaml
dependencies:
  # Native-only dependencies
  sqflite: ^2.3.0  # Native SQLite
  path_provider: ^2.1.0  # Native paths
  flutter_secure_storage: ^9.0.0  # Secure credential storage
  app_links: ^3.4.5  # Deep linking (already has)
  local_notifications: ^16.0.0  # Desktop notifications
  
  # File operations
  file_picker: ^6.0.0  # Native file picker
  path: ^1.8.3
  
  # Universal (already has)
  sqflite_common_ffi: ^2.3.0  # Desktop SQLite support
  sqflite_common_ffi_web: ^0.4.0  # Web SQLite
```

---

## 🎯 Priority Order

### Immediate (Week 1)
1. ✅ Server configuration service (native)
2. ✅ Magic key decoder service
3. ✅ Server selection screen
4. ✅ Update main.dart routing for native
5. ✅ Database services (native)

### High Priority (Week 2)
6. ✅ Post-login init service (conditional)
7. ✅ File storage service (native)
8. ✅ Authentication flow testing
9. ✅ Basic messaging (Signal Protocol)
10. ✅ Socket service (test/adapt)

### Medium Priority (Week 3)
11. ✅ View pages adaptation
12. ✅ File transfer (native)
13. ✅ Settings screens (native)
14. ✅ Multi-server switching

### Lower Priority (Week 4)
15. ✅ Video conference testing
16. ✅ Notifications (native)
17. ✅ UI polish
18. ✅ Performance optimization

---

## 🚫 What NOT to Modify

### Keep Web-Only (Don't Create Native Versions)
1. `auth/*_web.dart` - WebAuthn implementations
2. `web_config.dart` - Web configuration
3. Web-specific UI components that work universally

### Universal Files (Work on Both)
1. Theme system
2. Providers (state management)
3. Models
4. Most widgets
5. Core business logic

---

## 🧪 Testing Strategy

### Development Testing
1. **Run native app:**
   ```bash
   cd client
   flutter run -d windows
   ```

2. **Test magic link flow:**
   - Web: Settings → Credentials → "Add New Client"
   - Web: Generate magic key (choose QR or text)
   - Web: Verify 5-minute countdown timer visible
   - Native: Paste hex key in server selection
   - Native: Verify server added to panel
   - Native: Try using same key again (should fail - one-time use)
   - Native: Wait 5 min, try expired key (should fail)

3. **Test multi-server:**
   - Add 3+ different servers via magic keys
   - Verify each server has separate database tables (check SQLite)
   - Switch between servers (click server icons)
   - Verify state is cached (no reload delay)
   - Send message on Server A, switch to Server B, switch back (message still there)
   - Verify notification badges update per server
   - Close app, reopen → last server should auto-open

4. **Test reconnection:**
   - Stop server Docker container while client connected
   - Verify "reconnecting" indicator appears
   - Verify exponential backoff (logs should show increasing delays)
   - Restart server → verify auto-reconnect
   - During disconnect, verify can still switch to other servers

### Integration Testing
1. Message sending (native ↔ web)
2. File transfer (native ↔ web)
3. Video conference (native ↔ web)
4. Notifications

---

## 📄 Files to Create (Summary)

### Core Services
- [ ] `services/server_config_native.dart` - Multi-server management + storage
- [ ] `services/magic_key_service.dart` - Hex key parser + validator
- [ ] `services/storage/database_helper_native.dart` - Per-server tables (server_{hash}_*)
- [ ] `services/storage/database_encryption_service_native.dart` - Per-server encryption
- [ ] `services/storage/sqlite_message_store_native.dart` - With server hash prefix
- [ ] `services/storage/sqlite_group_message_store_native.dart` - With server hash prefix
- [ ] `services/file_transfer/storage_interface_native.dart` - Downloads/PeerWave/{hash}/
- [ ] `services/file_transfer/file_picker_native.dart` - Native file picker
- [ ] `services/notification_service_native.dart` - Desktop notifications + badges

### Screens
- [ ] `screens/server_selection_screen.dart` - Add server (magic key/QR/manual)
- [ ] `app/settings/server_management_page.dart` - Manage logged-in servers

### Widgets
- [ ] `widgets/server_panel.dart` - Discord-like left sidebar with server icons
- [ ] `widgets/server_icon.dart` - Circular icon with badge (reusable)
- [ ] `widgets/qr_scanner_widget.dart` - QR code scanner for magic keys (optional)

### Files to Modify
- [ ] `main.dart` - Add native routes (server selection), handle deep links
- [ ] `services/post_login_init_service.dart` - Conditional database init per server
- [ ] `services/socket_service.dart` - Multi-server socket connections + reconnect logic
- [ ] `app/app_layout.dart` - Add ServerPanel on far left (native only)
- [ ] `app/settings_sidebar.dart` - Hide WebAuthn/Backup Codes, add Server Management
- [ ] `auth/magic_link_native.dart` - Update to new Material 3 + hex key format
- [ ] `services/auth_service_native.dart` - Integrate with provider architecture

---

## 🎬 Implementation Strategy (Option B: Full Feature Approach)

### Step 1: Check Dependencies (Week 1 - Day 1)
- [ ] Review `pubspec.yaml` for conflicts
- [ ] Add required packages incrementally
- [ ] Test native build with new dependencies

### Step 2: Magic Key Backend (Web Side) (Week 1 - Day 1-2)
- [ ] Verify existing magic link endpoint supports hex key format
- [ ] Update web Settings → Credentials page:
  - [ ] "Add New Client" button
  - [ ] Generate hex key: {serverUrl}:{randomHash}:{timestamp}:{hmacSignature}
  - [ ] Display as QR code (using qr_flutter)
  - [ ] Display as copyable text string
  - [ ] Show 5-minute countdown timer
  - [ ] Store in temporary Sequelize database (existing)
  - [ ] Show list of connected devices/clients with metadata

### Step 3: Server Selection Screen (Week 1 - Day 2-3)
- [ ] Create full UI for `screens/server_selection_screen.dart`
- [ ] Implement magic key input (text field)
- [ ] Add QR scanner (optional, use mobile_scanner package)
- [ ] Create `services/magic_key_service.dart`
- [ ] Call existing magic link verification endpoint
- [ ] Handle errors (expired, invalid, already used)

### Step 4: Server Config Service (Week 1 - Day 3-4)
- [ ] Implement `services/server_config_native.dart`
- [ ] Use flutter_secure_storage for credentials
- [ ] Generate server hash from URL
- [ ] Store list of servers
- [ ] Track last active server
- [ ] Load last server on app start

### Step 5: Database Layer (Week 1 - Day 4-5)
- [ ] Create `services/storage/database_helper_native.dart`
- [ ] Implement per-server table naming (server_{hash}_messages)
- [ ] Keep all servers in memory
- [ ] Create encryption service per server
- [ ] Update message stores with hash prefix

### Step 6: Server Panel UI (Week 2 - Day 1-2)
- [ ] Create `widgets/server_panel.dart`
- [ ] Server icon rendering (default: first letter)
- [ ] Notification badge display
- [ ] Active server indicator
- [ ] "+ Add Server" button
- [ ] Long-press context menu
- [ ] Integrate with `app/app_layout.dart`

### Step 7: Multi-Server State Management (Week 2 - Day 2-3)
- [ ] Update `services/socket_service.dart` for multi-server
- [ ] Implement server switching logic
- [ ] Cache provider states per server
- [ ] Update `services/post_login_init_service.dart`
- [ ] Handle server-specific events

### Step 8: File Storage (Week 2 - Day 3-4)
- [ ] Implement `services/file_transfer/storage_interface_native.dart`
- [ ] Create Downloads/PeerWave/{serverHash}/ structure
- [ ] User-configurable download location
- [ ] Native file picker integration

### Step 9: Settings & Management (Week 2 - Day 4-5)
- [ ] Create `app/settings/server_management_page.dart`
- [ ] Update `app/settings_sidebar.dart` (hide WebAuthn)
- [ ] Implement logout per server
- [ ] Custom server icon upload
- [ ] File location settings

### Step 10: Reconnection Logic (Week 3 - Day 1)
- [ ] Exponential backoff reconnection (up to 5 min)
- [ ] Background reconnect attempts
- [ ] Connection status indicators per server
- [ ] Handle revoked access (require new magic key)

### Step 11: Testing & Polish (Week 3 - Day 2-5)
- [ ] End-to-end testing (web ↔ native)
- [ ] Multi-server switching tests
- [ ] Database isolation verification
- [ ] Notification badge accuracy
- [ ] Performance optimization
- [ ] Update existing native files (auth_layout_native, etc.)

### Step 12: Documentation (Week 4)
- [ ] User guide for magic key setup
- [ ] Multi-server usage instructions
- [ ] Troubleshooting guide
- [ ] Developer notes for conditional imports

---

## 💡 Notes

- **Don't duplicate unnecessarily** - Use conditional imports only when needed
- **Keep web working** - Never break web while adding native
- **Test both platforms** - After each change
- **Document platform differences** - In code comments
- **Use feature flags** - For experimental native features

---

## 🎯 Immediate Next Actions

**Ready to start Phase 1: Option B (Full Feature)**

1. ✅ **Check `pubspec.yaml`** for dependency conflicts
2. ✅ **Add required packages** incrementally (sqflite, flutter_secure_storage, etc.)
3. ✅ **Verify existing magic link endpoint** on server
4. ✅ **Update web credentials page** for magic key generation (QR + text)
5. ✅ **Create server selection screen** with magic key input
6. ✅ **Implement server config service** with multi-server support
7. ✅ **Build database layer** with per-server tables

**Expected Timeline:** 3-4 weeks for full native client functionality

---

## 📌 Key Technical Decisions Made

1. **Magic Key Format**: `{serverUrl}:{randomHash}:{timestamp}:{hmacSignature}` (hex encoded)
2. **Database Naming**: `server_{urlHash}_{tableName}` (e.g., `server_abc123_messages`)
3. **Multi-Server**: All servers in memory, cached provider states, Discord-like panel
4. **File Storage**: `Downloads/PeerWave/{serverHash}/` (user-configurable)
5. **Reconnection**: Exponential backoff, max 5 minutes, background attempts
6. **Server Icons**: Customizable per server, stored in secure storage
7. **Notification Badges**: Total unread count per server
8. **Client Management**: Web-only, shows all connected devices with metadata
9. **Starting Approach**: Option B - Full server selection + magic key flow first

---

**Ready to begin implementation. Shall I start with Step 1: Checking dependencies?**
