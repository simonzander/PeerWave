import 'package:uuid/uuid.dart';
import 'package:idb_shim/idb_browser.dart';
import 'package:flutter/foundation.dart';

/// Service for managing client IDs paired with email addresses
/// 
/// Each email can have multiple client IDs (one per device/browser)
/// Client IDs are stored locally in IndexedDB
class ClientIdService {
  static const _storeName = 'emailClientIds';
  static const _currentClientIdKey = 'current_client_id'; // Key for current client ID
  static const _dbName = 'peerwave_clientids';
  static final int _dbVersion = 1;
  static final IdbFactory idbFactory = idbFactoryBrowser;
  
  /// Get the current client ID
  /// 
  /// For compatibility with native version, this returns the "current" client ID
  /// which is set during login via getClientIdForEmail()
  static Future<String> getClientId() async {
    debugPrint('[CLIENT_ID] Getting current client ID');
    
    final db = await idbFactory.open(
      _dbName,
      version: _dbVersion,
      onUpgradeNeeded: (VersionChangeEvent event) {
        Database db = event.database;
        if (!db.objectStoreNames.contains(_storeName)) {
          db.createObjectStore(_storeName);
        }
      },
    );

    var txn = db.transaction(_storeName, "readonly");
    var store = txn.objectStore(_storeName);
    var currentClientId = await store.getObject(_currentClientIdKey);
    await txn.completed;
    db.close();
    
    if (currentClientId != null) {
      final clientId = currentClientId as String;
      debugPrint('[CLIENT_ID] Found current client ID: $clientId');
      return clientId;
    }
    
    throw Exception('No current client ID found - user not logged in?');
  }
  
  /// Get or create a client ID for the given email
  /// 
  /// This creates a LOCAL client ID without any server API call.
  /// The email->clientId mapping is stored in IndexedDB.
  /// Also sets this as the "current" client ID.
  static Future<String> getClientIdForEmail(String email) async {
    debugPrint('[CLIENT_ID] Getting client ID for email: $email');
    
    final db = await idbFactory.open(
      _dbName,
      version: _dbVersion,
      onUpgradeNeeded: (VersionChangeEvent event) {
        Database db = event.database;
        // Create object store with email as key
        if (!db.objectStoreNames.contains(_storeName)) {
          db.createObjectStore(_storeName);
        }
      },
    );

    // Try to get existing client ID for this email
    var txn = db.transaction(_storeName, "readonly");
    var store = txn.objectStore(_storeName);
    var existingClientId = await store.getObject(email);
    await txn.completed;
    
    if (existingClientId != null) {
      final clientId = existingClientId as String;
      debugPrint('[CLIENT_ID] Found existing client ID: $clientId');
      
      // Set this as the current client ID
      var writeTxn = db.transaction(_storeName, "readwrite");
      var writeStore = writeTxn.objectStore(_storeName);
      await writeStore.put(clientId, _currentClientIdKey);
      await writeTxn.completed;
      
      db.close();
      return clientId;
    }
    
    // Generate new client ID for this email
    final newClientId = const Uuid().v4();
    debugPrint('[CLIENT_ID] Generated new client ID: $newClientId');
    
    // Store email->clientId mapping AND set as current
    txn = db.transaction(_storeName, "readwrite");
    store = txn.objectStore(_storeName);
    await store.put(newClientId, email);
    await store.put(newClientId, _currentClientIdKey); // Also set as current
    await txn.completed;
    
    db.close();
    return newClientId;
  }
  
  /// Clear client ID for a specific email
  static Future<void> clearClientIdForEmail(String email) async {
    debugPrint('[CLIENT_ID] Clearing client ID for email: $email');
    
    final db = await idbFactory.open(_dbName, version: _dbVersion);
    final txn = db.transaction(_storeName, "readwrite");
    final store = txn.objectStore(_storeName);
    await store.delete(email);
    await txn.completed;
    db.close();
  }
  
  /// Clear all client IDs (for debugging/testing)
  static Future<void> clearAll() async {
    debugPrint('[CLIENT_ID] Clearing all client IDs');
    
    final db = await idbFactory.open(_dbName, version: _dbVersion);
    final txn = db.transaction(_storeName, "readwrite");
    final store = txn.objectStore(_storeName);
    await store.clear();
    await txn.completed;
    db.close();
  }
}
