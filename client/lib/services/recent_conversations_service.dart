import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

/// Service for managing recent direct message conversations
class RecentConversationsService {
  static const String _keyRecentDMs = 'recent_direct_messages';
  static const int maxRecentConversations = 20;

  /// Add or update a conversation (moves to top if exists)
  static Future<void> addOrUpdateConversation({
    required String userId,
    required String displayName,
    String? picture,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final conversations = await getRecentConversations();

    // Remove if already exists
    conversations.removeWhere((c) => c['uuid'] == userId);

    // Add at the beginning
    conversations.insert(0, {
      'uuid': userId,
      'displayName': displayName,
      if (picture != null) 'picture': picture,
      'lastMessageAt': DateTime.now().toIso8601String(),
    });

    // Keep only the last 20
    if (conversations.length > maxRecentConversations) {
      conversations.removeRange(maxRecentConversations, conversations.length);
    }

    // Save to SharedPreferences
    await prefs.setString(_keyRecentDMs, jsonEncode(conversations));
  }

  /// Get all recent conversations
  static Future<List<Map<String, String>>> getRecentConversations() async {
    final prefs = await SharedPreferences.getInstance();
    final String? data = prefs.getString(_keyRecentDMs);

    if (data == null || data.isEmpty) {
      return [];
    }

    try {
      final List<dynamic> decoded = jsonDecode(data);
      return decoded.map((item) {
        return {
          'uuid': item['uuid']?.toString() ?? '',
          'displayName': item['displayName']?.toString() ?? 'Unknown',
          if (item['picture'] != null) 'picture': item['picture']?.toString() ?? '',
          'lastMessageAt': item['lastMessageAt']?.toString() ?? '',
        };
      }).toList();
    } catch (e) {
      print('[RECENT_CONVERSATIONS] Error parsing conversations: $e');
      return [];
    }
  }

  /// Remove a conversation
  static Future<void> removeConversation(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final conversations = await getRecentConversations();

    conversations.removeWhere((c) => c['uuid'] == userId);

    await prefs.setString(_keyRecentDMs, jsonEncode(conversations));
  }

  /// Clear all conversations
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyRecentDMs);
  }

  /// Update conversation timestamp (when new message arrives)
  static Future<void> updateTimestamp(String userId) async {
    final conversations = await getRecentConversations();
    final index = conversations.indexWhere((c) => c['uuid'] == userId);

    if (index != -1) {
      final conversation = conversations.removeAt(index);
      conversation['lastMessageAt'] = DateTime.now().toIso8601String();
      conversations.insert(0, conversation);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyRecentDMs, jsonEncode(conversations));
    }
  }
}
