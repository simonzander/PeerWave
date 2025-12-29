import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sqflite/sqflite.dart';
import 'package:peerwave_client/core/storage/app_directories.dart';
import '../device_identity_service.dart';
import '../server_config_native.dart';

/// Native database helper with per-server table isolation
///
/// Architecture:
/// - Single database file per device: peerwave_{deviceId}.db
/// - Per-server tables with hash prefix: server_{serverHash}_messages
/// - All servers kept in memory simultaneously
/// - Table creation on-demand when server is added
class DatabaseHelperNative {
  static Database? _database;
  static bool _initializing = false;
  static const String _databaseBaseName = 'peerwave';
  static const int _databaseVersion = 6;

  static final DeviceIdentityService _deviceIdentity =
      DeviceIdentityService.instance;
  static final Map<String, bool> _serverTablesCreated =
      {}; // Track which servers have tables

  /// Get device-scoped database name
  static String get _databaseName {
    if (!_deviceIdentity.isInitialized) {
      throw Exception('[DATABASE] Device identity not initialized');
    }

    final deviceId = _deviceIdentity.deviceId;
    final dbName = '${_databaseBaseName}_$deviceId.db';
    return dbName;
  }

  /// Get the singleton database instance
  static Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }

    if (_initializing) {
      while (_database == null && _initializing) {
        await Future.delayed(Duration(milliseconds: 100));
      }
      if (_database != null) {
        return _database!;
      }
    }

    _initializing = true;
    try {
      debugPrint('[DATABASE_NATIVE] Starting database initialization');
      _database = await _initDatabase();
      debugPrint('[DATABASE_NATIVE] ✓ Database initialization successful');
      return _database!;
    } finally {
      _initializing = false;
    }
  }

  /// Initialize the database
  static Future<Database> _initDatabase() async {
    final path = AppDirectories.getDatabasePath(_databaseName);

    debugPrint('[DATABASE_NATIVE] Database path: $path');

    final db = await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: (db, version) async {
        debugPrint('[DATABASE_NATIVE] Creating new database v$version');
        // Create base schema (no server-specific tables yet)
        await _createBaseSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        debugPrint(
          '[DATABASE_NATIVE] Upgrading from v$oldVersion to v$newVersion',
        );
        await _onUpgrade(db, oldVersion, newVersion);
      },
      onOpen: (db) async {
        debugPrint('[DATABASE_NATIVE] Database opened successfully');

        // Initialize tables for all configured servers
        final servers = ServerConfigService.getAllServers();
        for (final server in servers) {
          await ensureServerTables(server.serverHash);
        }
      },
    );

    return db;
  }

  /// Create base database schema (non-server-specific tables)
  static Future<void> _createBaseSchema(Database db) async {
    debugPrint('[DATABASE_NATIVE] Creating base schema...');

    // Server metadata table (tracks which servers have data)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS server_metadata (
        server_hash TEXT PRIMARY KEY,
        server_url TEXT NOT NULL,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
        last_sync INTEGER,
        UNIQUE(server_hash)
      )
    ''');

    debugPrint('[DATABASE_NATIVE] ✓ Base schema created');
  }

  /// Ensure all tables exist for a specific server
  static Future<void> ensureServerTables(String serverHash) async {
    final db = await database;

    if (_serverTablesCreated[serverHash] == true) {
      debugPrint(
        '[DATABASE_NATIVE] Tables for server $serverHash already created',
      );
      return;
    }

    debugPrint('[DATABASE_NATIVE] Creating tables for server: $serverHash');

    await db.transaction((txn) async {
      // Messages table
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS server_${serverHash}_messages (
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
          created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
        )
      ''');

      await txn.execute(
        'CREATE INDEX IF NOT EXISTS idx_${serverHash}_messages_sender ON server_${serverHash}_messages(sender)',
      );
      await txn.execute(
        'CREATE INDEX IF NOT EXISTS idx_${serverHash}_messages_channel ON server_${serverHash}_messages(channel_id)',
      );
      await txn.execute(
        'CREATE INDEX IF NOT EXISTS idx_${serverHash}_messages_timestamp ON server_${serverHash}_messages(timestamp DESC)',
      );
      await txn.execute(
        'CREATE INDEX IF NOT EXISTS idx_${serverHash}_messages_conversation ON server_${serverHash}_messages(sender, channel_id, timestamp DESC)',
      );

      // Recent conversations table
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS server_${serverHash}_recent_conversations (
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

      await txn.execute(
        'CREATE INDEX IF NOT EXISTS idx_${serverHash}_recent_pinned ON server_${serverHash}_recent_conversations(pinned DESC, last_message_at DESC)',
      );
      await txn.execute(
        'CREATE INDEX IF NOT EXISTS idx_${serverHash}_recent_unread ON server_${serverHash}_recent_conversations(unread_count)',
      );

      // Signal protocol store table
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS server_${serverHash}_signal_store (
          key TEXT PRIMARY KEY,
          value BLOB NOT NULL,
          updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
        )
      ''');

      // Group messages table
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS server_${serverHash}_group_messages (
          item_id TEXT PRIMARY KEY,
          message BLOB NOT NULL,
          sender TEXT NOT NULL,
          sender_device_id INTEGER,
          channel_id TEXT NOT NULL,
          timestamp TEXT NOT NULL,
          type TEXT NOT NULL,
          metadata TEXT,
          decrypted_at TEXT NOT NULL,
          created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
        )
      ''');

      await txn.execute(
        'CREATE INDEX IF NOT EXISTS idx_${serverHash}_group_messages_channel ON server_${serverHash}_group_messages(channel_id, timestamp DESC)',
      );
      await txn.execute(
        'CREATE INDEX IF NOT EXISTS idx_${serverHash}_group_messages_sender ON server_${serverHash}_group_messages(sender)',
      );

      // Channels table
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS server_${serverHash}_channels (
          channel_id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          description TEXT,
          type TEXT NOT NULL CHECK(type IN ('public', 'private')),
          owner TEXT,
          created_at TEXT NOT NULL,
          last_message_at TEXT,
          unread_count INTEGER DEFAULT 0,
          pinned INTEGER DEFAULT 0,
          archived INTEGER DEFAULT 0,
          updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
        )
      ''');

      await txn.execute(
        'CREATE INDEX IF NOT EXISTS idx_${serverHash}_channels_type ON server_${serverHash}_channels(type)',
      );
      await txn.execute(
        'CREATE INDEX IF NOT EXISTS idx_${serverHash}_channels_pinned ON server_${serverHash}_channels(pinned DESC, last_message_at DESC)',
      );

      // Starred channels table
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS server_${serverHash}_starred_channels (
          channel_id TEXT PRIMARY KEY,
          starred_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
        )
      ''');

      // File metadata table
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS server_${serverHash}_file_metadata (
          file_id TEXT PRIMARY KEY,
          filename TEXT NOT NULL,
          mime_type TEXT,
          size INTEGER NOT NULL,
          sender TEXT NOT NULL,
          channel_id TEXT,
          local_path TEXT,
          thumbnail_path TEXT,
          uploaded_at TEXT NOT NULL,
          created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
        )
      ''');

      await txn.execute(
        'CREATE INDEX IF NOT EXISTS idx_${serverHash}_files_channel ON server_${serverHash}_file_metadata(channel_id, uploaded_at DESC)',
      );
      await txn.execute(
        'CREATE INDEX IF NOT EXISTS idx_${serverHash}_files_sender ON server_${serverHash}_file_metadata(sender)',
      );

      // Add server to metadata table
      await txn.execute(
        '''
        INSERT OR IGNORE INTO server_metadata (server_hash, server_url)
        VALUES (?, ?)
      ''',
        [serverHash, 'unknown'],
      );
    });

    _serverTablesCreated[serverHash] = true;
    debugPrint(
      '[DATABASE_NATIVE] ✓ All tables created for server: $serverHash',
    );
  }

  /// Handle database upgrades
  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    debugPrint(
      '[DATABASE_NATIVE] Upgrading database from v$oldVersion to v$newVersion',
    );

    // Get all server hashes from metadata
    final servers = await db.query('server_metadata');

    for (final server in servers) {
      final serverHash = server['server_hash'] as String;

      if (oldVersion < 6 && newVersion >= 6) {
        // Add starred_channels table
        await db.execute('''
          CREATE TABLE IF NOT EXISTS server_${serverHash}_starred_channels (
            channel_id TEXT PRIMARY KEY,
            starred_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
          )
        ''');
      }

      // Add more upgrade migrations here as needed
    }

    debugPrint('[DATABASE_NATIVE] ✓ Database upgrade complete');
  }

  /// Delete all tables for a specific server (when user logs out)
  static Future<void> deleteServerTables(String serverHash) async {
    final db = await database;

    debugPrint('[DATABASE_NATIVE] Deleting all tables for server: $serverHash');

    await db.transaction((txn) async {
      await txn.execute('DROP TABLE IF EXISTS server_${serverHash}_messages');
      await txn.execute(
        'DROP TABLE IF EXISTS server_${serverHash}_recent_conversations',
      );
      await txn.execute(
        'DROP TABLE IF EXISTS server_${serverHash}_signal_store',
      );
      await txn.execute(
        'DROP TABLE IF EXISTS server_${serverHash}_group_messages',
      );
      await txn.execute('DROP TABLE IF EXISTS server_${serverHash}_channels');
      await txn.execute(
        'DROP TABLE IF EXISTS server_${serverHash}_starred_channels',
      );
      await txn.execute(
        'DROP TABLE IF EXISTS server_${serverHash}_file_metadata',
      );

      // Remove from metadata
      await txn.delete(
        'server_metadata',
        where: 'server_hash = ?',
        whereArgs: [serverHash],
      );
    });

    _serverTablesCreated.remove(serverHash);
    debugPrint(
      '[DATABASE_NATIVE] ✓ All tables deleted for server: $serverHash',
    );
  }

  /// Get table name with server prefix
  static String getTableName(String serverHash, String baseTableName) {
    return 'server_${serverHash}_$baseTableName';
  }

  /// Close database (for app shutdown)
  static Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
      _serverTablesCreated.clear();
      debugPrint('[DATABASE_NATIVE] Database closed');
    }
  }

  /// Reset database (for testing)
  static Future<void> reset() async {
    await close();

    final path = AppDirectories.getDatabasePath(_databaseName);

    try {
      await deleteDatabase(path);
      debugPrint('[DATABASE_NATIVE] Database deleted: $path');
    } catch (e) {
      debugPrint('[DATABASE_NATIVE] Error deleting database: $e');
    }
  }
}
