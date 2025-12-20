
/// Stub service for web platform (no-op implementation)
class SystemTrayService {
  static final SystemTrayService _instance = SystemTrayService._internal();
  factory SystemTrayService() => _instance;
  SystemTrayService._internal();

  Future<void> initialize() async {
    // No-op on web
  }

  Future<void> setAutostart(bool enabled) async {
    // No-op on web
  }

  Future<bool> isAutostartEnabled() async {
    return false;
  }

  Future<void> showWindow() async {
    // No-op on web
  }

  Future<void> hideWindow() async {
    // No-op on web
  }

  Future<void> quitApp() async {
    // No-op on web
  }

  void dispose() {
    // No-op on web
  }
}
