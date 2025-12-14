import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'session_auth_service.dart';
import '../web_config.dart';
import 'server_config_web.dart' if (dart.library.io) 'server_config_native.dart';
import 'clientid_native.dart' if (dart.library.js) 'clientid_web.dart';

/// Service to check if current user is authorized to access a meeting
/// Checks if user is owner or participant
class MeetingAuthorizationService {
  static final MeetingAuthorizationService _instance = MeetingAuthorizationService._internal();
  static MeetingAuthorizationService get instance => _instance;
  
  MeetingAuthorizationService._internal();

  /// Check if current user is authorized to access a meeting
  /// Returns true if user is owner or participant, false otherwise
  Future<bool> checkMeetingAccess(String meetingId) async {
    try {
      debugPrint('[MEETING_AUTH] Checking access for meeting: $meetingId');

      // Get server URL
      String serverUrl;
      if (kIsWeb) {
        final apiServer = await loadWebApiServer();
        serverUrl = apiServer ?? 'localhost:3000';
      } else {
        final activeServer = ServerConfigService.getActiveServer();
        serverUrl = activeServer?.serverUrl ?? 'localhost:3000';
      }

      // Ensure protocol
      if (!serverUrl.startsWith('http://') && !serverUrl.startsWith('https://')) {
        serverUrl = 'http://$serverUrl';
      }

      final url = '$serverUrl/api/meetings/$meetingId';
      debugPrint('[MEETING_AUTH] Fetching meeting details: $url');

      // Get client ID
      final clientId = await ClientIdService.getClientId();

      // Generate auth headers
      final headers = await SessionAuthService().generateAuthHeaders(
        clientId: clientId,
        requestPath: '/api/meetings/$meetingId',
      );

      final response = await http.get(
        Uri.parse(url),
        headers: headers,
      );

      if (response.statusCode == 404) {
        debugPrint('[MEETING_AUTH] ❌ Meeting not found: $meetingId');
        return false;
      }

      if (response.statusCode == 403) {
        debugPrint('[MEETING_AUTH] ❌ Access forbidden: $meetingId');
        return false;
      }

      if (response.statusCode != 200) {
        debugPrint('[MEETING_AUTH] ⚠️ Unexpected status: ${response.statusCode}');
        return false;
      }

      debugPrint('[MEETING_AUTH] ✅ User authorized for meeting: $meetingId');
      return true;
    } catch (e) {
      debugPrint('[MEETING_AUTH] ⚠️ Error checking meeting access: $e');
      return false;
    }
  }

  /// Get meeting details including participants
  /// Returns null if unauthorized or error
  Future<Map<String, dynamic>?> getMeetingDetails(String meetingId) async {
    try {
      debugPrint('[MEETING_AUTH] Getting meeting details: $meetingId');

      // Get server URL
      String serverUrl;
      if (kIsWeb) {
        final apiServer = await loadWebApiServer();
        serverUrl = apiServer ?? 'localhost:3000';
      } else {
        final activeServer = ServerConfigService.getActiveServer();
        serverUrl = activeServer?.serverUrl ?? 'localhost:3000';
      }

      // Ensure protocol
      if (!serverUrl.startsWith('http://') && !serverUrl.startsWith('https://')) {
        serverUrl = 'http://$serverUrl';
      }

      final url = '$serverUrl/api/meetings/$meetingId';

      // Get client ID
      final clientId = await ClientIdService.getClientId();

      // Generate auth headers
      final headers = await SessionAuthService().generateAuthHeaders(
        clientId: clientId,
        requestPath: '/api/meetings/$meetingId',
      );

      final response = await http.get(
        Uri.parse(url),
        headers: headers,
      );

      if (response.statusCode != 200) {
        debugPrint('[MEETING_AUTH] Failed to get meeting: ${response.statusCode}');
        return null;
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      return data;
    } catch (e) {
      debugPrint('[MEETING_AUTH] Error getting meeting details: $e');
      return null;
    }
  }
}
