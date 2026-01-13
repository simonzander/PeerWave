import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' as sqflite_mobile;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';
import 'dart:io' show Platform;
import '../device_identity_service.dart';

/// Central database helper for PeerWave with device-scoped storage
///
/// Database naming: peerwave_{deviceId}.db
/// - Device isolation: Each device has its own database
/// - Application-layer encryption: Sensitive columns encrypted
/// - Handles both native (file-based SQLite) and web (IndexedDB-backed SQLite)
class DatabaseHelper {
  static Database? _database;
  static bool _factoryInitialized = false;
  static bool _initializing = false;
  static bool _isReady = false;
  static String? _lastError;
  static const String _databaseBaseName =
      'peerwave'; // Base name without .db extension
  static const int _databaseVersion =
      7; // Version 7: Add reactions column to messages

  static final DeviceIdentityService _deviceIdentity =
      DeviceIdentityService.instance;

  /// Check if database is ready for use
  static bool get isReady => _isReady;

  /// Check if database is currently initializing
  static bool get isInitializing => _initializing;

  /// Get last error if initialization failed
  static String? get lastError => _lastError;

  /// Get device-scoped database name
  static String get _databaseName {
    if (!_deviceIdentity.isInitialized) {
      throw Exception('[DATABASE] Device identity not initialized');
    }

    final deviceId = _deviceIdentity.deviceId;
    final dbName = '${_databaseBaseName}_$deviceId.db';
    debugPrint('[DATABASE] Device-scoped DB name: $dbName');
    return dbName;
  }

  /// Get the singleton database instance
  static Future<Database> get database async {
    if (_database != null && _isReady) {
      debugPrint('[DATABASE] Returning existing database instance');
      return _database!;
    }

    // Prevent multiple simultaneous initializations
    if (_initializing) {
      debugPrint('[DATABASE] Already initializing, waiting...');
      // Wait for initialization to complete
      int attempts = 0;
      while (_database == null && _initializing && attempts < 300) {
        await Future.delayed(Duration(milliseconds: 100));
        attempts++;
      }
      if (_database != null && _isReady) {
        debugPrint('[DATABASE] Initialization completed by another caller');
        return _database!;
      }
      if (attempts >= 300) {
        throw Exception(
          '[DATABASE] Timeout waiting for initialization (30 seconds)',
        );
      }
    }

    _initializing = true;
    _lastError = null;
    try {
      debugPrint('[DATABASE] ========================================');
      debugPrint('[DATABASE] Starting device-scoped database initialization');
      debugPrint('[DATABASE] ========================================');
      _database = await _initDatabase();
      _isReady = true;
      debugPrint('[DATABASE] ✓ Database initialization successful');
      debugPrint('[DATABASE] ✓ Database is READY for use');
      return _database!;
    } catch (e) {
      _lastError = e.toString();
      _isReady = false;
      debugPrint('[DATABASE] ✗ Database initialization FAILED: $e');
      rethrow;
    } finally {
      _initializing = false;
    }
  }

  /// Wait until database is ready with retry logic
  static Future<Database> waitUntilReady({
    int maxAttempts = 3,
    Duration retryDelay = const Duration(seconds: 2),
  }) async {
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        debugPrint(
          '[DATABASE] Attempt $attempt/$maxAttempts to access database...',
        );
        final db = await database;
        if (_isReady) {
          debugPrint('[DATABASE] ✓ Database ready on attempt $attempt');
          return db;
        }
      } catch (e) {
        debugPrint('[DATABASE] ⚠️ Attempt $attempt failed: $e');
        if (attempt < maxAttempts) {
          debugPrint(
            '[DATABASE] Retrying in ${retryDelay.inSeconds} seconds...',
          );
          await Future.delayed(retryDelay);
        } else {
          debugPrint('[DATABASE] ✗ All $maxAttempts attempts failed');
          rethrow;
        }
      }
    }
    throw Exception(
      '[DATABASE] Failed to initialize database after $maxAttempts attempts',
    );
  }

  /// Initialize the database
  static Future<Database> _initDatabase() async {
    try {
      if (kIsWeb) {
        // Web: Use IndexedDB backend (set factory only once)
        if (!_factoryInitialized) {
          debugPrint('[DATABASE] Initializing web database (IndexedDB)...');

          // Use the web worker version for better performance
          debugPrint(
            '[DATABASE] Setting database factory to databaseFactoryFfiWeb...',
          );
          databaseFactory = databaseFactoryFfiWeb;
          _factoryInitialized = true;
          debugPrint('[DATABASE] ✓ Web database factory initialized');
        }

        debugPrint(
          '[DATABASE] Opening database: $_databaseName (version $_databaseVersion)',
        );
        debugPrint('[DATABASE] About to call openDatabase...');

        final db =
            await openDatabase(
              _databaseName,
              version: _databaseVersion,
              onCreate: (db, version) async {
                debugPrint(
                  '[DATABASE] ✓ onCreate called - Creating new database v$version',
                );
                await _onCreate(db, version);
                debugPrint('[DATABASE] ✓ onCreate completed');
              },
              onUpgrade: (db, oldVersion, newVersion) async {
                debugPrint(
                  '[DATABASE] ✓ onUpgrade called - Upgrading from v$oldVersion to v$newVersion',
                );
                await _onUpgrade(db, oldVersion, newVersion);
                debugPrint('[DATABASE] ✓ onUpgrade completed');
              },
              onOpen: (db) async {
                debugPrint(
                  '[DATABASE] ✓ onOpen called - Database opened successfully',
                );
                try {
                  final tables = await db.rawQuery(
                    "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
                  );
                  final tableNames = tables.map((t) => t['name']).toList();
                  debugPrint(
                    '[DATABASE] ✓ Existing tables (${tableNames.length}): ${tableNames.join(", ")}',
                  );
                } catch (e) {
                  debugPrint('[DATABASE] ✗ Error listing tables: $e');
                }
              },
            ).timeout(
              Duration(seconds: 30),
              onTimeout: () {
                debugPrint('[DATABASE] ✗ TIMEOUT after 30 seconds!');
                throw Exception(
                  '[DATABASE] Timeout opening database after 30 seconds',
                );
              },
            );

        debugPrint(
          '[DATABASE] ✓ openDatabase completed, got database instance',
        );
        debugPrint('[DATABASE] ✓ Web database initialization complete');
        return db;
      } else {
        // Native: Use appropriate sqflite based on platform
        final isDesktop =
            !kIsWeb &&
            (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
        final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

        if (isDesktop) {
          // Desktop: Use sqflite_common_ffi
          if (!_factoryInitialized) {
            debugPrint(
              '[DATABASE] Initializing desktop database factory (sqflite_common_ffi)...',
            );
            sqfliteFfiInit();
            databaseFactory = databaseFactoryFfi;
            _factoryInitialized = true;
            debugPrint('[DATABASE] ✓ Desktop database factory initialized');
          }

          debugPrint('[DATABASE] Initializing desktop database...');
          final directory = await getApplicationDocumentsDirectory();
          final path = join(directory.path, _databaseName);

          debugPrint('[DATABASE] Database path: $path');

          final db = await openDatabase(
            path,
            version: _databaseVersion,
            onCreate: _onCreate,
            onUpgrade: _onUpgrade,
            onOpen: (db) async {
              debugPrint('[DATABASE] Database opened successfully');
            },
          );

          debugPrint('[DATABASE] Desktop database initialization complete');
          return db;
        } else if (isMobile) {
          // Mobile (Android/iOS): Use standard sqflite
          debugPrint(
            '[DATABASE] Initializing mobile database (Android/iOS)...',
          );
          final directory = await getApplicationDocumentsDirectory();
          final path = join(directory.path, _databaseName);

          debugPrint('[DATABASE] Database path: $path');

          final db = await sqflite_mobile.openDatabase(
            path,
            version: _databaseVersion,
            onCreate: (db, version) async {
              debugPrint(
                '[DATABASE] ✓ onCreate called - Creating new database v$version',
              );
              await _onCreate(db, version);
            },
            onUpgrade: (db, oldVersion, newVersion) async {
              debugPrint(
                '[DATABASE] ✓ onUpgrade called - Upgrading from v$oldVersion to v$newVersion',
              );
              await _onUpgrade(db, oldVersion, newVersion);
            },
            onOpen: (db) async {
              debugPrint('[DATABASE] Database opened successfully');
            },
          );

          debugPrint('[DATABASE] Mobile database initialization complete');
          return db;
        } else {
          throw Exception('[DATABASE] Unsupported platform');
        }
      }
    } catch (e, stackTrace) {
      debugPrint('[DATABASE] *** ERROR initializing database: $e');
      debugPrint('[DATABASE] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Create database tables
  static Future<void> _onCreate(Database db, int version) async {
    debugPrint('[DATABASE] Creating database schema version $version...');
    debugPrint(
      '[DATABASE] Using application-layer encryption for sensitive columns',
    );

    // =============================================
    // MESSAGES TABLE (1:1 and Group Messages)
    // =============================================
    // message: BLOB (encrypted message content)
    // Other fields: Plain (for indexing/searching)
    await db.execute('''
      CREATE TABLE messages (
        item_id TEXT PRIMARY KEY,
        message BLOB NOT NULL,
        sender TEXT NOT NULL,
        sender_device_id INTEGER,
        channel_id TEXT,
        timestamp TEXT NOT NULL,
        type TEXT NOT NULL,
        direction TEXT NOT NULL CHECK(direction IN ('received', 'sent')),
        status TEXT,
        read_receipt_sent INTEGER DEFAULT 0,
        metadata TEXT,
        decrypted_at TEXT NOT NULL,
        reactions TEXT DEFAULT '{}',
        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
      )
    ''');

    // Indexes for fast queries (only on non-encrypted columns)
    await db.execute('CREATE INDEX idx_messages_sender ON messages(sender)');
    await db.execute(
      'CREATE INDEX idx_messages_channel ON messages(channel_id)',
    );
    await db.execute(
      'CREATE INDEX idx_messages_timestamp ON messages(timestamp DESC)',
    );
    await db.execute('CREATE INDEX idx_messages_type ON messages(type)');
    await db.execute(
      'CREATE INDEX idx_messages_direction ON messages(direction)',
    );
    await db.execute(
      'CREATE INDEX idx_messages_conversation ON messages(sender, channel_id, timestamp DESC)',
    );

    debugPrint(
      '[DATABASE] ✓ Created messages table with encrypted message column',
    );

    // =============================================
    // RECENT CONVERSATIONS TABLE
    // =============================================
    await db.execute('''
      CREATE TABLE recent_conversations (
        user_id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        picture TEXT,
        last_message_at TEXT NOT NULL,
        unread_count INTEGER DEFAULT 0,
        pinned INTEGER DEFAULT 0,
        archived INTEGER DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_conversations_timestamp ON recent_conversations(last_message_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_conversations_pinned ON recent_conversations(pinned DESC, last_message_at DESC)',
    );

    debugPrint('[DATABASE] ✓ Created recent_conversations table');

    // =============================================
    // SIGNAL PROTOCOL TABLES (encrypted BLOB columns)
    // =============================================

    // Sessions - record is encrypted
    await db.execute('''
      CREATE TABLE signal_sessions (
        address TEXT PRIMARY KEY,
        record BLOB NOT NULL,
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
      )
    ''');

    // Identity Keys - identity_key is encrypted
    await db.execute('''
      CREATE TABLE signal_identity_keys (
        address TEXT PRIMARY KEY,
        identity_key BLOB NOT NULL,
        trust_level INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
      )
    ''');

    // Pre Keys - record is encrypted
    await db.execute('''
      CREATE TABLE signal_pre_keys (
        pre_key_id INTEGER PRIMARY KEY,
        record BLOB NOT NULL,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
      )
    ''');

    // Signed Pre Keys - record is encrypted
    await db.execute('''
      CREATE TABLE signal_signed_pre_keys (
        signed_pre_key_id INTEGER PRIMARY KEY,
        record BLOB NOT NULL,
        timestamp INTEGER NOT NULL,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
      )
    ''');

    // Sender Keys (for group encryption) - record is encrypted
    await db.execute('''
      CREATE TABLE sender_keys (
        sender_key_id TEXT PRIMARY KEY,
        record BLOB NOT NULL,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
      )
    ''');

    debugPrint('[DATABASE] ✓ Created Signal protocol tables');

    // =============================================
    // STARRED CHANNELS TABLE (client-side only)
    // =============================================
    // Stores which channels are starred by this device's user
    // Server has no knowledge of starred channels
    await db.execute('''
      CREATE TABLE starred_channels (
        channel_uuid TEXT PRIMARY KEY,
        starred_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_starred_channels_timestamp ON starred_channels(starred_at DESC)',
    );

    debugPrint('[DATABASE] ✓ Created starred_channels table');

    debugPrint('[DATABASE] Database schema created successfully!');
  }

  /// Handle database upgrades
  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    debugPrint(
      '[DATABASE] Upgrading database from version $oldVersion to $newVersion...',
    );

    // Version 2 → 3: Add status column for sent messages
    if (oldVersion < 3) {
      debugPrint(
        '[DATABASE] Applying migration: Add status column to messages table',
      );
      await db.execute('''
        ALTER TABLE messages ADD COLUMN status TEXT DEFAULT NULL
      ''');
      debugPrint(
        '[DATABASE] ✓ Added status column (for tracking sent/delivered/read status)',
      );
    }

    // Version 3 → 4: Add read_receipt_sent flag for received messages
    if (oldVersion < 4) {
      debugPrint(
        '[DATABASE] Applying migration: Add read_receipt_sent column to messages table',
      );
      await db.execute('''
        ALTER TABLE messages ADD COLUMN read_receipt_sent INTEGER DEFAULT 0
      ''');
      debugPrint(
        '[DATABASE] ✓ Added read_receipt_sent column (prevents duplicate read receipts)',
      );
    }

    // Version 4 → 5: Add metadata column for image/voice/notification messages
    if (oldVersion < 5) {
      debugPrint(
        '[DATABASE] Applying migration: Add metadata column to messages table',
      );
      await db.execute('''
        ALTER TABLE messages ADD COLUMN metadata TEXT DEFAULT NULL
      ''');
      debugPrint(
        '[DATABASE] ✓ Added metadata column (stores JSON metadata for image/voice/mentions)',
      );
    }

    // Version 5 → 6: Add starred_channels table
    if (oldVersion < 6) {
      debugPrint('[DATABASE] Applying migration: Add starred_channels table');
      await db.execute('''
        CREATE TABLE starred_channels (
          channel_uuid TEXT PRIMARY KEY,
          starred_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
        )
      ''');
      await db.execute(
        'CREATE INDEX idx_starred_channels_timestamp ON starred_channels(starred_at DESC)',
      );
      debugPrint(
        '[DATABASE] ✓ Added starred_channels table (client-side starred state)',
      );
    }

    // Version 6 → 7: Add reactions column to messages table
    if (oldVersion < 7) {
      debugPrint(
        '[DATABASE] Applying migration: Add reactions column to messages table',
      );
      await db.execute('''
        ALTER TABLE messages ADD COLUMN reactions TEXT DEFAULT '{}'
      ''');
      debugPrint(
        '[DATABASE] ✓ Added reactions column (stores emoji reactions as JSON map)',
      );
    }
  }

  /// Close the database
  static Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
      debugPrint('[DATABASE] Database closed');
    }
  }

  /// Reset database state (for hot reload)
  /// This prevents "database_closed" errors after hot reload
  static void reset() {
    debugPrint('[DATABASE] Resetting database state for hot reload');
    _database = null;
    _initializing = false;
    // Don't reset _factoryInitialized - factory init should persist
  }

  /// Check if database is properly initialized with all tables
  static Future<bool> isDatabaseReady() async {
    try {
      final db = await database;
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
      );
      final tableNames = tables.map((t) => t['name'] as String).toList();

      // Check for required tables
      final requiredTables = ['messages', 'recent_conversations'];
      final hasAllTables = requiredTables.every(
        (table) => tableNames.contains(table),
      );

      if (hasAllTables) {
        debugPrint(
          '[DATABASE] All required tables present: ${tableNames.join(", ")}',
        );
      } else {
        debugPrint(
          '[DATABASE] Missing tables. Found: ${tableNames.join(", ")}',
        );
      }

      return hasAllTables;
    } catch (e) {
      debugPrint('[DATABASE] Error checking database readiness: $e');
      return false;
    }
  }

  /// Delete the database (for testing/development)
  static Future<void> deleteDatabase() async {
    await close();

    if (kIsWeb) {
      debugPrint('[DATABASE] Deleting web database...');
      await databaseFactoryFfiWeb.deleteDatabase(_databaseName);
      debugPrint('[DATABASE] Web database deleted');
    } else {
      debugPrint('[DATABASE] Deleting native database...');
      final directory = await getApplicationDocumentsDirectory();
      final path = join(directory.path, _databaseName);
      await databaseFactory.deleteDatabase(path);
      debugPrint('[DATABASE] Native database deleted');
    }

    _factoryInitialized = false;
    debugPrint('[DATABASE] Database deletion complete');
  }

  /// Delete all old databases (including non-device-scoped ones)
  /// Use this during development to clean up old data
  static Future<void> deleteAllDatabases() async {
    await close();

    if (kIsWeb) {
      debugPrint('[DATABASE] Deleting all web databases...');
      // Delete current device-scoped database
      await databaseFactoryFfiWeb.deleteDatabase(_databaseName);

      // Delete old non-scoped database if it exists
      try {
        await databaseFactoryFfiWeb.deleteDatabase('peerwave.db');
        debugPrint('[DATABASE] ✓ Deleted old non-scoped database');
      } catch (e) {
        debugPrint('[DATABASE] Old database not found (OK)');
      }

      debugPrint('[DATABASE] All web databases deleted');
    } else {
      debugPrint('[DATABASE] Deleting all native databases...');
      final directory = await getApplicationDocumentsDirectory();

      // Delete current database
      final path = join(directory.path, _databaseName);
      await databaseFactory.deleteDatabase(path);

      // Delete old non-scoped database if it exists
      try {
        final oldPath = join(directory.path, 'peerwave.db');
        await databaseFactory.deleteDatabase(oldPath);
        debugPrint('[DATABASE] ✓ Deleted old non-scoped database');
      } catch (e) {
        debugPrint('[DATABASE] Old database not found (OK)');
      }

      debugPrint('[DATABASE] All native databases deleted');
    }

    _factoryInitialized = false;
    debugPrint('[DATABASE] All database deletion complete');
  }

  /// Reset database (delete and recreate)
  static Future<void> resetDatabase() async {
    debugPrint('[DATABASE] Resetting database...');
    await deleteDatabase();
    _database = await _initDatabase();
    debugPrint('[DATABASE] Database reset complete');
  }

  /// Get database info for debugging
  static Future<Map<String, dynamic>> getDatabaseInfo() async {
    final db = await database;

    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
    );

    final info = <String, dynamic>{
      'version': await db.getVersion(),
      'path': db.path,
      'isOpen': db.isOpen,
      'tables': tables.map((t) => t['name']).toList(),
    };

    // Get row counts for each table
    for (final table in tables) {
      final tableName = table['name'] as String;
      if (!tableName.startsWith('sqlite_')) {
        final count = await db.rawQuery(
          'SELECT COUNT(*) as count FROM $tableName',
        );
        info['${tableName}_count'] = count.first['count'];
      }
    }

    return info;
  }
}
