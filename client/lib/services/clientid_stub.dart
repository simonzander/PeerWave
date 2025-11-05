// Stub for ClientIdService for web (does nothing)
class ClientIdService {
  static Future<String> getClientId() async {
    // Web does not use client ID
    return '';
  }
}

