// Native export - exports NativeStorage as StorageImpl
export 'native_storage.dart' show NativeStorage;

// Factory function
import 'native_storage.dart';
import 'storage_interface.dart';

FileStorageInterface createFileStorage() => NativeStorage();
