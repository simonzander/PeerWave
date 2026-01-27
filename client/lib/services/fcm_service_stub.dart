/// Stub implementation for platforms without Firebase support (Windows/Linux/macOS)
class FCMService {
  static final FCMService _instance = FCMService._internal();
  factory FCMService() => _instance;
  FCMService._internal();

  /// No-op initialization for non-mobile platforms
  Future<void> initialize() async {
    // Firebase not available on this platform
  }

  /// No-op token registration
  Future<void> registerToken() async {
    // Firebase not available on this platform
  }

  /// No-op token cleanup
  Future<void> unregisterToken() async {
    // Firebase not available on this platform
  }

  /// Dispose resources (no-op)
  void dispose() {
    // Nothing to dispose
  }
}
