import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';

/// Central database helper for PeerWave
/// Handles both native (file-based SQLite) and web (IndexedDB-backed SQLite)
class DatabaseHelper {
  static Database? _database;
  static bool _factoryInitialized = false;
  static bool _initializing = false;
  static const String _databaseName = 'peerwave.db'; // .db extension for native, stripped by web
  static const int _databaseVersion = 1;

  /// Get the singleton database instance
  static Future<Database> get database async {
    if (_database != null) {
      print('[DATABASE] Returning existing database instance');
      return _database!;
    }
    
    // Prevent multiple simultaneous initializations
    if (_initializing) {
      print('[DATABASE] Already initializing, waiting...');
      // Wait for initialization to complete
      while (_database == null && _initializing) {
        await Future.delayed(Duration(milliseconds: 100));
      }
      if (_database != null) {
        print('[DATABASE] Initialization completed by another caller');
        return _database!;
      }
    }
    
    _initializing = true;
    try {
      print('[DATABASE] Starting database initialization...');
      _database = await _initDatabase();
      print('[DATABASE] Database initialization successful');
      return _database!;
    } finally {
      _initializing = false;
    }
  }

  /// Initialize the database
  static Future<Database> _initDatabase() async {
    try {
      if (kIsWeb) {
        // Web: Use IndexedDB backend (set factory only once)
        if (!_factoryInitialized) {
          print('[DATABASE] Initializing web database (IndexedDB)...');
          
          // Use the web worker version for better performance
          print('[DATABASE] Setting database factory to databaseFactoryFfiWeb...');
          databaseFactory = databaseFactoryFfiWeb;
          _factoryInitialized = true;
          print('[DATABASE] ✓ Web database factory initialized');
        }
        
        print('[DATABASE] Opening database: $_databaseName (version $_databaseVersion)');
        print('[DATABASE] About to call openDatabase...');
        
        final db = await openDatabase(
          _databaseName,
          version: _databaseVersion,
          onCreate: (db, version) async {
            print('[DATABASE] ✓ onCreate called - Creating new database v$version');
            await _onCreate(db, version);
            print('[DATABASE] ✓ onCreate completed');
          },
          onUpgrade: (db, oldVersion, newVersion) async {
            print('[DATABASE] ✓ onUpgrade called - Upgrading from v$oldVersion to v$newVersion');
            await _onUpgrade(db, oldVersion, newVersion);
            print('[DATABASE] ✓ onUpgrade completed');
          },
          onOpen: (db) async {
            print('[DATABASE] ✓ onOpen called - Database opened successfully');
            try {
              final tables = await db.rawQuery(
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
              );
              final tableNames = tables.map((t) => t['name']).toList();
              print('[DATABASE] ✓ Existing tables (${tableNames.length}): ${tableNames.join(", ")}');
            } catch (e) {
              print('[DATABASE] ✗ Error listing tables: $e');
            }
          },
        ).timeout(
          Duration(seconds: 30),
          onTimeout: () {
            print('[DATABASE] ✗ TIMEOUT after 30 seconds!');
            throw Exception('[DATABASE] Timeout opening database after 30 seconds');
          },
        );
        
        print('[DATABASE] ✓ openDatabase completed, got database instance');
        print('[DATABASE] ✓ Web database initialization complete');
        return db;
      } else {
        // Native: Use file system
        print('[DATABASE] Initializing native database...');
        final directory = await getApplicationDocumentsDirectory();
        final path = join(directory.path, _databaseName);
        
        print('[DATABASE] Database path: $path');
        
        final db = await openDatabase(
          path,
          version: _databaseVersion,
          onCreate: _onCreate,
          onUpgrade: _onUpgrade,
          onOpen: (db) async {
            print('[DATABASE] Database opened successfully');
          },
        );
        
        print('[DATABASE] Native database initialization complete');
        return db;
      }
    } catch (e, stackTrace) {
      print('[DATABASE] *** ERROR initializing database: $e');
      print('[DATABASE] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Create database tables
  static Future<void> _onCreate(Database db, int version) async {
    print('[DATABASE] Creating database schema version $version...');
    
    // =============================================
    // MESSAGES TABLE (1:1 and Group Messages)
    // =============================================
    await db.execute('''
      CREATE TABLE messages (
        item_id TEXT PRIMARY KEY,
        message TEXT NOT NULL,
        sender TEXT NOT NULL,
        sender_device_id INTEGER,
        channel_id TEXT,
        timestamp TEXT NOT NULL,
        type TEXT NOT NULL,
        direction TEXT NOT NULL CHECK(direction IN ('received', 'sent')),
        decrypted_at TEXT NOT NULL,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
      )
    ''');

    // Indexes for fast queries
    await db.execute('CREATE INDEX idx_messages_sender ON messages(sender)');
    await db.execute('CREATE INDEX idx_messages_channel ON messages(channel_id)');
    await db.execute('CREATE INDEX idx_messages_timestamp ON messages(timestamp DESC)');
    await db.execute('CREATE INDEX idx_messages_type ON messages(type)');
    await db.execute('CREATE INDEX idx_messages_direction ON messages(direction)');
    await db.execute('CREATE INDEX idx_messages_conversation ON messages(sender, channel_id, timestamp DESC)');
    
    print('[DATABASE] ✓ Created messages table with indexes');

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

    await db.execute('CREATE INDEX idx_conversations_timestamp ON recent_conversations(last_message_at DESC)');
    await db.execute('CREATE INDEX idx_conversations_pinned ON recent_conversations(pinned DESC, last_message_at DESC)');
    
    print('[DATABASE] ✓ Created recent_conversations table');

    // =============================================
    // SIGNAL PROTOCOL TABLES
    // =============================================
    
    // Sessions
    await db.execute('''
      CREATE TABLE signal_sessions (
        address TEXT PRIMARY KEY,
        record BLOB NOT NULL,
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
      )
    ''');
    
    // Identity Keys
    await db.execute('''
      CREATE TABLE signal_identity_keys (
        address TEXT PRIMARY KEY,
        identity_key BLOB NOT NULL,
        trust_level INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
      )
    ''');
    
    // Pre Keys
    await db.execute('''
      CREATE TABLE signal_pre_keys (
        pre_key_id INTEGER PRIMARY KEY,
        record BLOB NOT NULL,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
      )
    ''');
    
    // Signed Pre Keys
    await db.execute('''
      CREATE TABLE signal_signed_pre_keys (
        signed_pre_key_id INTEGER PRIMARY KEY,
        record BLOB NOT NULL,
        timestamp INTEGER NOT NULL,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
      )
    ''');
    
    // Sender Keys (for group encryption)
    await db.execute('''
      CREATE TABLE sender_keys (
        sender_key_id TEXT PRIMARY KEY,
        record BLOB NOT NULL,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
      )
    ''');
    
    print('[DATABASE] ✓ Created Signal protocol tables');

    print('[DATABASE] Database schema created successfully!');
  }

  /// Handle database upgrades
  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    print('[DATABASE] Upgrading database from version $oldVersion to $newVersion...');
    
    // Add migration logic here when needed
    // Example:
    // if (oldVersion < 2) {
    //   await db.execute('ALTER TABLE messages ADD COLUMN read_status INTEGER DEFAULT 0');
    // }
  }

  /// Close the database
  static Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
      print('[DATABASE] Database closed');
    }
  }

  /// Check if database is properly initialized with all tables
  static Future<bool> isDatabaseReady() async {
    try {
      final db = await database;
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
      );
      final tableNames = tables.map((t) => t['name'] as String).toList();
      
      // Check for required tables
      final requiredTables = ['messages', 'recent_conversations'];
      final hasAllTables = requiredTables.every((table) => tableNames.contains(table));
      
      if (hasAllTables) {
        print('[DATABASE] All required tables present: ${tableNames.join(", ")}');
      } else {
        print('[DATABASE] Missing tables. Found: ${tableNames.join(", ")}');
      }
      
      return hasAllTables;
    } catch (e) {
      print('[DATABASE] Error checking database readiness: $e');
      return false;
    }
  }

  /// Delete the database (for testing/development)
  static Future<void> deleteDatabase() async {
    await close();
    
    if (kIsWeb) {
      print('[DATABASE] Deleting web database...');
      await databaseFactoryFfiWeb.deleteDatabase(_databaseName);
      print('[DATABASE] Web database deleted');
    } else {
      print('[DATABASE] Deleting native database...');
      final directory = await getApplicationDocumentsDirectory();
      final path = join(directory.path, _databaseName);
      await databaseFactory.deleteDatabase(path);
      print('[DATABASE] Native database deleted');
    }
    
    _factoryInitialized = false;
    print('[DATABASE] Database deletion complete');
  }

  /// Reset database (delete and recreate)
  static Future<void> resetDatabase() async {
    print('[DATABASE] Resetting database...');
    await deleteDatabase();
    _database = await _initDatabase();
    print('[DATABASE] Database reset complete');
  }

  /// Get database info for debugging
  static Future<Map<String, dynamic>> getDatabaseInfo() async {
    final db = await database;
    
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
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
        final count = await db.rawQuery('SELECT COUNT(*) as count FROM $tableName');
        info['${tableName}_count'] = count.first['count'];
      }
    }
    
    return info;
  }
}
