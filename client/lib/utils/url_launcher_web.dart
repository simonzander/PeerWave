import 'package:web/web.dart' as web;

/// Web implementation of URL launcher using package:web
class UrlLauncher {
  /// Check if URL can be launched (always true on web)
  static Future<bool> canLaunch(String url) async {
    return true;
  }

  /// Launch URL in new tab
  static Future<void> launch(String url) async {
    web.window.open(url, '_blank');
  }
}
