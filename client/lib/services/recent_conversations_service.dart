import 'package:flutter/foundation.dart' show debugPrint;
import 'user_profile_service.dart';
import 'storage/sqlite_recent_conversations_store.dart';
import 'storage/sqlite_message_store.dart';

/// Service for managing recent direct message conversations
///
/// Single Source of Truth: SqliteRecentConversationsStore
/// - Queries SqliteRecentConversationsStore for recent conversations
/// - Loads profile metadata from UserProfileService with await
/// - Returns conversations sorted by last message timestamp
class RecentConversationsService {
  static const int maxRecentConversations = 20;

  /// Get recent conversations from SQLite database
  /// Returns list with uuid, displayName, picture from UserProfileService
  static Future<List<Map<String, String>>> getRecentConversations() async {
    try {
      debugPrint(
        '[RECENT_CONVERSATIONS] Loading recent conversations from SQLite...',
      );

      // Get conversations store
      final conversationsStore =
          await SqliteRecentConversationsStore.getInstance();

      // Get recent conversations
      var recentConvs = await conversationsStore.getRecentConversations(
        limit: null, // Get ALL conversations
      );

      debugPrint(
        '[RECENT_CONVERSATIONS] Found ${recentConvs.length} conversations in SQLite',
      );

      // FALLBACK: If recent_conversations is empty, get from messages table
      if (recentConvs.isEmpty) {
        debugPrint(
          '[RECENT_CONVERSATIONS] recent_conversations table empty, checking messages table...',
        );
        final messageStore = await SqliteMessageStore.getInstance();
        final uniqueSenders = await messageStore
            .getAllUniqueConversationPartners();

        if (uniqueSenders.isNotEmpty) {
          debugPrint(
            '[RECENT_CONVERSATIONS] Found ${uniqueSenders.length} conversations in messages table',
          );
          recentConvs = uniqueSenders
              .map(
                (userId) => {
                  'userId': userId,
                  'displayName': userId,
                  'lastMessageAt': '',
                },
              )
              .toList();
        } else {
          debugPrint(
            '[RECENT_CONVERSATIONS] No conversations found in messages table either',
          );
          return [];
        }
      }

      // Extract user IDs
      final userIds = recentConvs
          .map((conv) => conv['userId'] as String?)
          .where((id) => id != null && id.isNotEmpty)
          .cast<String>()
          .toList();

      // Load profiles from server with await
      if (userIds.isNotEmpty) {
        debugPrint(
          '[RECENT_CONVERSATIONS] Loading profiles for ${userIds.length} users...',
        );
        try {
          await UserProfileService.instance.loadProfiles(userIds);
          debugPrint('[RECENT_CONVERSATIONS] ✓ Profiles loaded');
        } catch (e) {
          debugPrint('[RECENT_CONVERSATIONS] ⚠ Failed to load profiles: $e');
          // Continue with cached data if available
        }
      }

      // Build result with profile data
      final result = recentConvs.map((conv) {
        final userId = conv['userId'] as String;
        final profile = UserProfileService.instance.getProfile(userId);

        return {
          'uuid': userId,
          'displayName':
              profile?['displayName']?.toString() ??
              conv['displayName']?.toString() ??
              userId,
          'picture':
              profile?['picture']?.toString() ??
              conv['picture']?.toString() ??
              '',
          'lastMessageAt': conv['lastMessageAt']?.toString() ?? '',
        };
      }).toList();

      debugPrint(
        '[RECENT_CONVERSATIONS] Returning ${result.length} conversations',
      );
      return result;
    } catch (e) {
      debugPrint('[RECENT_CONVERSATIONS] Error loading conversations: $e');
      return [];
    }
  }
}
