
// Only for web:
// ignore: avoid_web_libraries_in_flutter

class AuthService {
  static bool isLoggedIn = false;

  /*static Future<bool> login(String email, String password) async {
    await Future.delayed(const Duration(seconds: 1)); // Fake API Call
    isLoggedIn = true;
    return true;
  }

  static void logout() {
    isLoggedIn = false;
  }*/

  static Future<bool> checkSession() async {
    // Ensure a bool is always returned
    isLoggedIn = false;
    return false;
  }
}

