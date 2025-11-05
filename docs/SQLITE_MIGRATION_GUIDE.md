# SQLite Migration Implementation Guide

## ✅ Phase 1: Infrastructure (COMPLETED)

### Created Files:
1. **`lib/services/storage/database_helper.dart`** - Central database management
2. **`lib/services/storage/sqlite_message_store.dart`** - Message storage with indexing
3. **`lib/services/storage/sqlite_recent_conversations_store.dart`** - Conversation management

### Added Dependencies:
```yaml
sqflite: ^2.3.3+2                  # Native SQLite
sqflite_common_ffi: ^2.3.3         # FFI support
sqflite_common_ffi_web: ^0.4.5+1   # Web (IndexedDB backend)
```

---

## 📋 Phase 2: Migration Steps

### Step 1: Run Flutter Pub Get

```powershell
cd client
flutter pub get
```

### Step 2: Test Database Initialization

Create a test file to verify database setup:

**`lib/services/storage/database_test.dart`**:
```dart
import 'database_helper.dart';
import 'sqlite_message_store.dart';
import 'sqlite_recent_conversations_store.dart';

Future<void> testDatabase() async {
  print('=== Testing Database Initialization ===');
  
  // Initialize database
  final db = await DatabaseHelper.database;
  print('✓ Database initialized');
  
  // Get database info
  final info = await DatabaseHelper.getDatabaseInfo();
  print('Database info: $info');
  
  // Test message store
  final messageStore = await SqliteMessageStore.getInstance();
  await messageStore.storeReceivedMessage(
    itemId: 'test_msg_1',
    message: 'Hello from SQLite!',
    sender: 'test_user',
    timestamp: DateTime.now().toIso8601String(),
    type: 'message',
  );
  print('✓ Stored test message');
  
  final msg = await messageStore.getMessage('test_msg_1');
  print('Retrieved message: $msg');
  
  // Test conversations store
  final conversationsStore = await SqliteRecentConversationsStore.getInstance();
  await conversationsStore.addOrUpdateConversation(
    userId: 'test_user',
    displayName: 'Test User',
  );
  print('✓ Stored test conversation');
  
  final conversations = await conversationsStore.getRecentConversations();
  print('Retrieved conversations: $conversations');
  
  // Get statistics
  final msgStats = await messageStore.getStatistics();
  print('Message stats: $msgStats');
  
  final convStats = await conversationsStore.getStatistics();
  print('Conversation stats: $convStats');
  
  print('=== Database Test Complete ===');
}
```

### Step 3: Update ActivitiesService

**File**: `lib/services/activities_service.dart`

**Replace**:
```dart
// OLD: Using PermanentDecryptedMessagesStore
final receivedMessages = await SignalService.instance.decryptedMessagesStore.getMessagesFromSender(userId);
final receivedSenders = await SignalService.instance.decryptedMessagesStore.getAllUniqueSenders();
```

**With**:
```dart
// NEW: Using SqliteMessageStore
import 'storage/sqlite_message_store.dart';

final messageStore = await SqliteMessageStore.getInstance();
final receivedMessages = await messageStore.getMessagesFromConversation(userId);
final receivedSenders = await messageStore.getAllUniqueConversationPartners();
```

### Step 4: Update SignalService

**File**: `lib/services/signal_service.dart`

**Replace all references to**:
- `decryptedMessagesStore` → `SqliteMessageStore`
- `sentMessagesStore` → `SqliteMessageStore` (with `direction: 'sent'`)

**Example**:
```dart
// OLD
await decryptedMessagesStore.storeDecryptedMessage(
  itemId: itemId,
  message: plaintext,
  sender: sender,
  timestamp: timestamp,
  type: type,
);

// NEW
final messageStore = await SqliteMessageStore.getInstance();
await messageStore.storeReceivedMessage(
  itemId: itemId,
  message: plaintext,
  sender: sender,
  timestamp: timestamp,
  type: type,
);
```

### Step 5: Update RecentConversationsService

**File**: `lib/services/recent_conversations_service.dart`

**Replace entire implementation**:
```dart
import 'storage/sqlite_recent_conversations_store.dart';

class RecentConversationsService {
  static Future<void> addOrUpdateConversation({
    required String userId,
    required String displayName,
    String? picture,
  }) async {
    final store = await SqliteRecentConversationsStore.getInstance();
    await store.addOrUpdateConversation(
      userId: userId,
      displayName: displayName,
      picture: picture,
    );
  }

  static Future<List<Map<String, String>>> getRecentConversations() async {
    final store = await SqliteRecentConversationsStore.getInstance();
    final conversations = await store.getRecentConversations(limit: 20);
    
    // Convert to old format for compatibility
    return conversations.map((c) => {
      'uuid': c['uuid'] as String,
      'displayName': c['displayName'] as String,
      'picture': c['picture'] as String? ?? '',
      'lastMessageAt': c['lastMessageAt'] as String,
    }).toList();
  }

  static Future<void> removeConversation(String userId) async {
    final store = await SqliteRecentConversationsStore.getInstance();
    await store.removeConversation(userId);
  }

  static Future<void> clearAll() async {
    final store = await SqliteRecentConversationsStore.getInstance();
    await store.clearAll();
  }

  static Future<void> updateTimestamp(String userId) async {
    final store = await SqliteRecentConversationsStore.getInstance();
    await store.updateTimestamp(userId);
  }
}
```

---

## 🔍 Phase 3: Testing & Validation

### Test Checklist:

- [ ] Database initializes on both web and native
- [ ] Messages can be stored and retrieved
- [ ] Conversations are properly sorted
- [ ] Queries are fast (test with 1000+ messages)
- [ ] Unread counts work correctly
- [ ] Pin/archive functionality works
- [ ] Data persists after app restart

### Performance Testing:

```dart
Future<void> performanceTest() async {
  final messageStore = await SqliteMessageStore.getInstance();
  final stopwatch = Stopwatch()..start();
  
  // Insert 1000 messages
  for (int i = 0; i < 1000; i++) {
    await messageStore.storeReceivedMessage(
      itemId: 'perf_test_$i',
      message: 'Performance test message $i',
      sender: 'user_${i % 10}', // 10 different users
      timestamp: DateTime.now().toIso8601String(),
      type: 'message',
    );
  }
  
  stopwatch.stop();
  print('Inserted 1000 messages in ${stopwatch.elapsedMilliseconds}ms');
  
  // Query test
  stopwatch.reset();
  stopwatch.start();
  
  final senders = await messageStore.getAllUniqueConversationPartners();
  
  stopwatch.stop();
  print('Found ${senders.length} unique senders in ${stopwatch.elapsedMilliseconds}ms');
  
  // Conversation query test
  stopwatch.reset();
  stopwatch.start();
  
  final messages = await messageStore.getMessagesFromConversation('user_0', limit: 20);
  
  stopwatch.stop();
  print('Retrieved ${messages.length} messages in ${stopwatch.elapsedMilliseconds}ms');
}
```

---

## 📊 Expected Performance Improvements

| Operation | Old (FlutterSecureStorage) | New (SQLite) | Improvement |
|-----------|---------------------------|--------------|-------------|
| Get conversation | ~5-10s (10k messages) | ~50-100ms | **50-100x faster** |
| Count conversations | ~5s | ~1ms | **5000x faster** |
| Get last message | ~2s | ~10ms | **200x faster** |
| Filter by type | ~3s | ~20ms | **150x faster** |
| Pagination | Not supported | Native | **∞** |

---

## 🚀 Phase 4: Cleanup (Optional)

After migration is complete and tested, you can remove old storage files:

**Can be deleted**:
- `lib/services/permanent_decrypted_messages_store.dart`
- `lib/services/decrypted_group_items_store.dart`
- `lib/services/permanent_sent_messages_store.dart`
- `lib/services/sent_group_items_store.dart`

**Keep for now** (migrate in Phase 5):
- Signal protocol stores (sessions, keys, etc.)

---

## 🔐 Phase 5: Signal Protocol Migration (Future)

After messages are stable, migrate Signal protocol stores:

1. Create `SqliteSignalStore` wrapper
2. Migrate session store
3. Migrate key stores
4. Test end-to-end encryption still works

---

## 📝 Migration Notes

### No Data Migration Needed
Since you're in development mode, we're starting fresh. Users will need to:
1. Clear app data (or reinstall)
2. Re-establish Signal sessions
3. New messages will use SQLite automatically

### Backward Compatibility
Keep old storage code for a few releases to allow graceful migration if needed.

### Database Versioning
The database schema is versioned. Future changes can be handled in `_onUpgrade()` method.

---

## 🛠️ Next Steps

1. **Run `flutter pub get`** in the client directory
2. **Test database initialization** on both web and native
3. **Update ActivitiesService** to use SqliteMessageStore
4. **Test message storage** end-to-end
5. **Update UI** to use new conversation store features (unread counts, pinning)
6. **Performance testing** with large datasets
7. **Deploy** to development environment

---

## 🐛 Troubleshooting

### Web: IndexedDB Access Errors
If you get IndexedDB errors on web, check browser console for quota issues.

### Native: Database Locked
If database is locked, ensure you're not opening multiple instances. Use singleton pattern.

### Migration Errors
If you need to reset the database during development:
```dart
await DatabaseHelper.deleteDatabase();
```

---

## 📞 Support

For issues or questions during migration, check:
1. Console logs for `[DATABASE]` prefix
2. Database info: `await DatabaseHelper.getDatabaseInfo()`
3. Statistics: `await messageStore.getStatistics()`
