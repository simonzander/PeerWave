import 'package:idb_shim/idb.dart';
import 'package:idb_shim/idb_browser.dart';

IdbFactory getIdbFactoryWeb() {
  return idbFactoryBrowser;
}

/// Reset the factory cache (no-op for web)
/// Web uses IndexedDB directly, doesn't need reset
void resetIdbFactoryNative() {
  // No-op for web - browser manages IndexedDB lifecycle
}
