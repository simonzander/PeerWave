
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
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
  return stringList.map((e) => Map<String, String>.from(jsonDecode(e))).toList();
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
    // Ensure a bool is always returned
    isLoggedIn = false;
    return false;
  }
}

