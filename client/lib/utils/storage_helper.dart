// Web-specific storage helper
import 'dart:html' as html;

String? getSessionStorageItem(String key) {
  return html.window.sessionStorage[key];
}
