// This config file loads the server domain from server_config.json at runtime (web only).
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

Future<String?> loadWebApiServer() async {
	if (!kIsWeb) return null;
	try {
		final resp = await http.get(Uri.parse('server_config.json'));
		if (resp.statusCode == 200) {
			final jsonMap = jsonDecode(resp.body);
			return jsonMap['apiServer'] as String?;
		}
	} catch (e) {
		// Handle error or return null
	}
	return null;
}
