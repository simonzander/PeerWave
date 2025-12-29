// This config file loads the server domain from server_config.json at runtime (web only).
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

Future<String?> loadWebApiServer() async {
  if (!kIsWeb) return null;

  // Retry up to 3 times with delay to handle race conditions
  for (int attempt = 0; attempt < 3; attempt++) {
    try {
      final resp = await http.get(Uri.parse('server_config.json'));
      if (resp.statusCode == 200) {
        final jsonMap = jsonDecode(resp.body);
        final apiServer = jsonMap['apiServer'] as String?;

        // Only return if we got a valid non-empty URL
        if (apiServer != null && apiServer.isNotEmpty) {
          debugPrint('[CONFIG] ✅ Loaded API server from config: $apiServer');
          return apiServer;
        } else {
          debugPrint(
            '[CONFIG] ⚠️ server_config.json returned empty apiServer (attempt ${attempt + 1}/3)',
          );
        }
      } else {
        debugPrint(
          '[CONFIG] ⚠️ Failed to load server_config.json: ${resp.statusCode} (attempt ${attempt + 1}/3)',
        );
      }
    } catch (e) {
      debugPrint(
        '[CONFIG] ⚠️ Error loading server_config.json: $e (attempt ${attempt + 1}/3)',
      );
    }

    // Wait before retry (except on last attempt)
    if (attempt < 2) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  debugPrint(
    '[CONFIG] ❌ Failed to load API server after 3 attempts, will use fallback',
  );
  return null;
}
