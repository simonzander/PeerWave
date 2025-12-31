// Web-specific storage helper
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

String? getSessionStorageItem(String key) {
  final sessionStorage = globalContext['sessionStorage'] as JSObject?;
  return sessionStorage?.getProperty(key.toJS)?.dartify()?.toString();
}
