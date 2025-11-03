# Storage Query Optimization Plan

**Created:** November 3, 2025  
**Status:** Planning - Not Yet Implemented

## Problem Statement

Current implementation loads all database entries into memory and filters them, which will cause performance issues as the database grows. We need to implement proper query capabilities for both IndexedDB (web) and Flutter Secure Storage (mobile/desktop).

---

## IndexedDB (Web) - Query Optimization

### Current Problem:
```dart
// Loads ALL messages into memory, then filters
var cursor = store.openCursor(autoAdvance: true);
await cursor.forEach((cursorWithValue) {
  // Filter in memory
});
```

### Solution: Use IndexedDB Indexes

**1. Create an index on the `sender` field during database creation:**
```dart
onUpgradeNeeded: (VersionChangeEvent event) {
  Database db = event.database;
  if (!db.objectStoreNames.contains(_storeName)) {
    var store = db.createObjectStore(_storeName, autoIncrement: false);
    // Create index on sender field for efficient queries
    store.createIndex('senderIndex', 'sender', unique: false);
  }
}
```

**2. Query using the index:**
```dart
// Instead of scanning all messages
var index = store.index('senderIndex');
var range = KeyRange.only(senderId);  // Exact match
var cursor = index.openCursor(range: range, autoAdvance: true);
```

**Benefits:**
- O(log n) lookup instead of O(n)
- Only loads matching messages, not entire database
- Native IndexedDB performance

### For `getAllUniqueSenders()`:
```dart
// Use cursor on index to get unique values efficiently
var index = store.index('senderIndex');
var cursor = index.openCursor(autoAdvance: true);
Set<String> senders = {};

await cursor.forEach((cursorWithValue) {
  var sender = cursorWithValue.key; // The indexed key (sender ID)
  if (sender != null && sender != 'self') {
    senders.add(sender);
    // Skip to next unique sender value
    cursor.advance(1); 
  }
});
```

Or better yet, use `openKeyCursor()` which only loads keys, not values:
```dart
var index = store.index('senderIndex');
var keyCursor = index.openKeyCursor(autoAdvance: true);
Set<String> senders = {};
String? lastSender;

await keyCursor.forEach((cursor) {
  var sender = cursor.primaryKey; // Get sender without loading message data
  if (sender != lastSender && sender != 'self') {
    senders.add(sender);
    lastSender = sender;
  }
});
```

---

## Flutter Secure Storage (Mobile/Desktop) - Query Optimization

### Current Problem:
```dart
// Loads ALL keys, then reads ALL values, then filters
List<String> keys = List<String>.from(jsonDecode(keysJson));
for (var key in keys) {
  var value = await storage.read(key: key);
  // Parse and filter
}
```

### Solution Options:

### Option 1: Use SQLite with SQLCipher (Recommended)
Flutter Secure Storage doesn't support queries. For better performance, migrate to **SQLite with encryption**:

```dart
import 'package:sqflite_sqlcipher/sqflite.dart';

class PermanentDecryptedMessagesStore {
  static Database? _db;
  
  static Future<Database> get database async {
    if (_db != null) return _db!;
    
    _db = await openDatabase(
      'messages.db',
      password: 'your-encryption-key', // From secure storage
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE decrypted_messages (
            itemId TEXT PRIMARY KEY,
            message TEXT,
            sender TEXT,
            senderDeviceId INTEGER,
            timestamp TEXT,
            type TEXT,
            decryptedAt TEXT
          )
        ''');
        // Create index for fast sender lookups
        await db.execute('CREATE INDEX idx_sender ON decrypted_messages(sender)');
      },
    );
    return _db!;
  }
  
  // Query messages by sender efficiently
  Future<List<Map<String, dynamic>>> getMessagesFromSender(String senderId) async {
    final db = await database;
    return await db.query(
      'decrypted_messages',
      where: 'sender = ? AND type != ?',
      whereArgs: [senderId, 'read_receipt'],
    );
  }
  
  // Get unique senders efficiently
  Future<Set<String>> getAllUniqueSenders() async {
    final db = await database;
    final result = await db.query(
      'decrypted_messages',
      columns: ['sender'],
      distinct: true,
      where: 'sender != ? AND type != ?',
      whereArgs: ['self', 'read_receipt'],
    );
    return result.map((row) => row['sender'] as String).toSet();
  }
}
```

**Benefits:**
- Real SQL queries with WHERE clauses
- Encrypted at rest
- Indexes for O(log n) lookups
- Much faster than key-value storage

**Package to use:**
```yaml
dependencies:
  sqflite_sqlcipher: ^2.2.1
```

---

### Option 2: Maintain a Separate Index File
If you must stick with Flutter Secure Storage:

```dart
// Store a lightweight index file
{
  "senders": {
    "user-uuid-1": {
      "messageCount": 15,
      "lastMessageTime": "2025-11-03T12:00:00Z",
      "messageKeys": ["msg_key_1", "msg_key_2", ...] // Limited list
    },
    "user-uuid-2": { ... }
  }
}
```

**Query flow:**
1. Load index file (small, fast)
2. Check if sender exists in index
3. Only load specific message keys for that sender
4. For `getAllUniqueSenders()`, just return `Object.keys(index.senders)`

**Trade-offs:**
- Must maintain index consistency
- Index updates on every message store/delete
- Still not as fast as SQLite

---

### Option 3: Hybrid Storage Strategy
```dart
// Fast metadata in Hive (supports queries)
// Sensitive content in Flutter Secure Storage

class MessageMetadata {
  String itemId;
  String sender;
  String timestamp;
  String type;
}

// Hive box with indexes
@HiveType(typeId: 0)
class MessageMetadata {
  @HiveField(0) String itemId;
  @HiveField(1) String sender;
  @HiveField(2) String timestamp;
  
  // Query Hive for metadata
  var messages = metadataBox.values
    .where((msg) => msg.sender == senderId)
    .toList();
    
  // Load actual message content from secure storage only when needed
  for (var meta in messages) {
    var content = await secureStorage.read(key: meta.itemId);
  }
}
```

**Packages needed:**
```yaml
dependencies:
  hive: ^2.2.3
  hive_flutter: ^1.1.0
```

---

## Recommended Implementation Strategy

### Phase 1: Add IndexedDB Indexes (Web) - Immediate Win ⚡
**Effort:** ~30 minutes  
**Impact:** High  
**Risk:** Low

1. Add `senderIndex` during database creation
2. Update queries to use index
3. Minimal code changes, big performance gain

**Files to modify:**
- `client/lib/services/permanent_decrypted_messages_store.dart`
- `client/lib/services/permanent_sent_messages_store.dart`

**Implementation steps:**
1. Bump database version from 2 to 3
2. Add index creation in `onUpgradeNeeded`
3. Update `getMessagesFromSender()` to use index
4. Update `getAllUniqueSenders()` to use `openKeyCursor()`

---

### Phase 2: Migrate to SQLite (Mobile/Desktop) - Best Long-term Solution 🎯
**Effort:** ~2-3 days  
**Impact:** Very High  
**Risk:** Medium (requires migration)

1. Add `sqflite_sqlcipher` package
2. Create new SQLite-based store classes
3. Implement migration from Flutter Secure Storage
4. Test thoroughly on iOS, Android, Windows, Linux, macOS

**Benefits:**
- Proper database with SQL queries
- Encrypted at rest
- Industry standard for mobile apps
- Supports complex queries, joins, aggregations

**Files to create:**
- `client/lib/services/sqlite_decrypted_messages_store.dart`
- `client/lib/services/sqlite_sent_messages_store.dart`
- `client/lib/services/storage_migration.dart`

---

### Phase 3: Consider Shared Worker (Web) - Advanced 🚀
**Effort:** ~1 week  
**Impact:** High (for very large datasets)  
**Risk:** Medium (complexity)

For very large datasets on web:
```javascript
// Shared Worker manages IndexedDB queries in background
// Dart communicates via postMessage
// Keeps UI thread responsive
```

Only implement if you have:
- Thousands of messages per user
- Performance issues with Phase 1 implementation
- Need for background sync

---

## Performance Comparison

| Method | Current | IndexedDB Index | SQLite | Hybrid |
|--------|---------|-----------------|--------|--------|
| Load all messages | O(n) | O(1) | O(log n) | O(log n) |
| Query by sender | O(n) | O(log n) | O(log n) | O(log n) |
| Get unique senders | O(n) | O(k) | O(1) | O(1) |
| Memory usage | High | Low | Low | Medium |
| Setup complexity | Simple | Easy | Medium | High |
| Encryption | ✅ | ✅ | ✅ | ✅ |

Where:
- n = total messages
- k = unique senders

---

## Priority Recommendation

**Implement in this order:**

1. **🔥 Immediate (This Week)**: 
   - Phase 1 - Add IndexedDB indexes for web
   - Quick win with minimal risk
   - Solves performance issues for web users immediately

2. **📋 Next Sprint (Within 2 Weeks)**:
   - Phase 2 - Migrate mobile/desktop to SQLite with SQLCipher
   - Proper database solution
   - Better query capabilities
   - Prepare migration path for existing users

3. **🔮 Future (As Needed)**:
   - Phase 3 - Consider pagination/virtual scrolling in UI
   - Shared Worker for web if needed
   - Further optimizations based on real-world usage

---

## Testing Strategy

### Phase 1 Testing (IndexedDB):
- [ ] Create test database with 1000+ messages from 50+ senders
- [ ] Measure query performance before/after
- [ ] Verify index creation on new installs
- [ ] Verify index migration on existing installs
- [ ] Test in Chrome, Firefox, Safari

### Phase 2 Testing (SQLite):
- [ ] Test encryption key generation and storage
- [ ] Test migration from Flutter Secure Storage
- [ ] Test with 10,000+ messages
- [ ] Verify on all platforms (iOS, Android, Windows, Linux, macOS)
- [ ] Test backup/restore scenarios
- [ ] Measure query performance vs current implementation

---

## Migration Considerations

### For Existing Users:

**Phase 1 (IndexedDB):**
- Database version bump automatically triggers migration
- Existing data remains intact
- Index created on first access after update
- No user action required

**Phase 2 (SQLite):**
```dart
Future<void> migrateToSQLite() async {
  // 1. Check if migration needed
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool('migrated_to_sqlite') == true) return;
  
  // 2. Create new SQLite database
  final db = await SQLiteMessagesStore.create();
  
  // 3. Read all messages from secure storage
  final oldStore = await PermanentDecryptedMessagesStore.create();
  // ... migration logic
  
  // 4. Mark migration complete
  await prefs.setBool('migrated_to_sqlite', true);
  
  // 5. Optionally clean up old storage
}
```

---

## Files to Modify/Create

### Phase 1 (IndexedDB Indexes):
- **Modify:** `client/lib/services/permanent_decrypted_messages_store.dart`
- **Modify:** `client/lib/services/permanent_sent_messages_store.dart`
- **Modify:** `client/lib/services/decrypted_group_items_store.dart`
- **Modify:** `client/lib/services/sent_group_items_store.dart`

### Phase 2 (SQLite Migration):
- **Create:** `client/lib/services/sqlite_decrypted_messages_store.dart`
- **Create:** `client/lib/services/sqlite_sent_messages_store.dart`
- **Create:** `client/lib/services/sqlite_group_items_store.dart`
- **Create:** `client/lib/services/storage_migration.dart`
- **Create:** `client/lib/services/database_factory.dart` (factory pattern for web vs mobile)
- **Modify:** `client/lib/services/signal_service.dart` (use new stores)
- **Update:** `client/pubspec.yaml` (add sqflite_sqlcipher)

---

## Additional Optimizations to Consider

1. **Virtual Scrolling**: Only render visible messages in UI
2. **Lazy Loading**: Load messages on-demand as user scrolls
3. **Background Sync**: Use Web Workers/Isolates for heavy queries
4. **Caching**: Cache recent queries in memory with expiration
5. **Pagination**: Implement cursor-based pagination for large result sets

---

## Notes

- Current implementation will work fine for small datasets (<100 conversations, <1000 messages)
- Performance degradation becomes noticeable around:
  - **Web:** 500+ conversations or 5000+ messages
  - **Mobile:** 300+ conversations or 3000+ messages (due to secure storage overhead)
- IndexedDB indexes provide 10-50x performance improvement for queries
- SQLite provides 50-100x performance improvement over secure storage key-value reads

---

## References

- [IndexedDB API - MDN](https://developer.mozilla.org/en-US/docs/Web/API/IndexedDB_API)
- [idb_shim package](https://pub.dev/packages/idb_shim)
- [sqflite_sqlcipher package](https://pub.dev/packages/sqflite_sqlcipher)
- [SQLCipher documentation](https://www.zetetic.net/sqlcipher/)
- [Hive documentation](https://docs.hivedb.dev/)

---

**Next Steps:** Discuss with team and decide on implementation timeline.
