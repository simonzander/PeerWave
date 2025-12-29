// Web export - exports IndexedDBStorage as StorageImpl
export 'indexeddb_storage.dart' show IndexedDBStorage;

// Factory function
import 'indexeddb_storage.dart';
import 'storage_interface.dart';

FileStorageInterface createFileStorage() => IndexedDBStorage();
