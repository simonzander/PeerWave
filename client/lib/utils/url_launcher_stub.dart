/// Stub implementation for URL launcher
/// This should never be called directly - platform-specific implementations will be used
library;

class UrlLauncher {
  static Future<bool> canLaunch(String url) async {
    throw UnsupportedError('Platform not supported');
  }

  static Future<void> launch(String url) async {
    throw UnsupportedError('Platform not supported');
  }
}
