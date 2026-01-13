import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'session_auth_service.dart';
import 'clientid_native.dart';
import 'server_config_native.dart';
// Only for web:
// ignore: avoid_web_libraries_in_flutter

class AuthService {
  Future<void> removeMailFromHost(String hostname) async {
    final prefs = await SharedPreferences.getInstance();
    final stringList = prefs.getStringList('host_mail_list') ?? [];
    final updatedList = stringList.map((entry) {
      final map = Map<String, String>.from(jsonDecode(entry));
      if (map['host'] == hostname) {
        map['mail'] = '';
      }
      return jsonEncode(map);
    }).toList();
    await prefs.setStringList('host_mail_list', updatedList);
  }

  Future<void> removeHost(String hostname) async {
    final prefs = await SharedPreferences.getInstance();
    final stringList = prefs.getStringList('host_mail_list') ?? [];
    final updatedList = stringList.where((entry) {
      final map = Map<String, String>.from(jsonDecode(entry));
      return map['host'] != hostname;
    }).toList();
    await prefs.setStringList('host_mail_list', updatedList);
  }

  static bool isLoggedIn = false;

  Future<void> saveHostMailList(String hostname, String mail) async {
    final prefs = await SharedPreferences.getInstance();
    final stringList = prefs.getStringList('host_mail_list') ?? [];
    bool updated = false;
    for (int i = 0; i < stringList.length; i++) {
      final map = Map<String, String>.from(jsonDecode(stringList[i]));
      if (map['host'] == hostname) {
        map['mail'] = mail;
        stringList[i] = jsonEncode(map);
        updated = true;
        break;
      }
    }
    if (!updated) {
      stringList.add(jsonEncode({'host': hostname, 'mail': mail}));
    }
    await prefs.setStringList('host_mail_list', stringList);
  }

  Future<List<Map<String, String>>> getHostMailList() async {
    final prefs = await SharedPreferences.getInstance();
    final stringList = prefs.getStringList('host_mail_list') ?? [];
    return stringList
        .map((e) => Map<String, String>.from(jsonDecode(e)))
        .toList();
  }

  /*static Future<bool> login(String email, String password) async {
    await Future.delayed(const Duration(seconds: 1)); // Fake API Call
    isLoggedIn = true;
    return true;
  }

  static void logout() {
    isLoggedIn = false;
  }*/

  static Future<bool> checkSession() async {
    try {
      // For native, check if we have an HMAC session
      final clientId = await ClientIdService.getClientId();
      debugPrint('[AuthService] Checking session for clientId: $clientId');
      final hasSession = await SessionAuthService().hasSession(clientId);

      if (hasSession) {
        debugPrint('[AuthService] Native client has HMAC session');
        isLoggedIn = true;
        return true;
      } else {
        // Session not found in SessionAuthService - check if we can restore from ServerConfig
        debugPrint(
          '[AuthService] No session in SecureStorage, checking ServerConfig backup...',
        );

        final activeServer = ServerConfigService.getActiveServer();
        if (activeServer != null && activeServer.credentials.isNotEmpty) {
          // Restore session from ServerConfig credentials
          debugPrint(
            '[AuthService] Restoring session from ServerConfig backup',
          );
          await SessionAuthService().initializeSession(
            clientId,
            activeServer.credentials,
          );

          // Verify restoration worked
          final restored = await SessionAuthService().hasSession(clientId);
          if (restored) {
            debugPrint(
              '[AuthService] ✓ Session restored from ServerConfig backup',
            );
            isLoggedIn = true;
            return true;
          } else {
            debugPrint('[AuthService] ✗ Failed to restore session from backup');
          }
        }

        debugPrint('[AuthService] Native client has no HMAC session');
        isLoggedIn = false;
        return false;
      }
    } catch (e) {
      debugPrint('[AuthService] Error checking session: $e');
      isLoggedIn = false;
      return false;
    }
  }
}
