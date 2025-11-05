import 'package:uuid/uuid.dart';
import 'package:idb_shim/idb_browser.dart';

class ClientIdService {
  static const _key = 'clientId';
  static final IdbFactory idbFactory = idbFactoryBrowser;
  static final _storage = 'peerwaveStorage';
  static final _dbName = 'peerwave';
  static final int _dbVersion = 1;
  static String? _clientId;

  static Future<String> getClientId() async {
    if (_clientId != null) return _clientId!;

    final db = await idbFactory.open(_dbName, version: _dbVersion, onUpgradeNeeded: (VersionChangeEvent event) {
      Database db = event.database;
      // create the store
      db.createObjectStore(_storage, autoIncrement: true);
    });

    var txn = db.transaction(_storage, "readonly");
    var store = txn.objectStore(_storage);
    var clientIdFromDb = await store.getObject(_key);
    await txn.completed;
    if (clientIdFromDb != null) {
      _clientId = clientIdFromDb as String;
      return _clientId!;
    } else {
      // Generate new UUID and persist
      final uuid = Uuid().v4();
      txn = db.transaction(_storage, "readwrite");
      store = txn.objectStore(_storage);
      store.put(uuid, _key);
      await txn.completed;
      _clientId = uuid;
      return _clientId!;
    }
  }
}

