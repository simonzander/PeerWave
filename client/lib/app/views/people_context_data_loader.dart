import 'package:flutter/foundation.dart';
import '../../services/recent_conversations_service.dart';
import '../../services/user_profile_service.dart';
import '../../services/storage/sqlite_message_store.dart';
import '../../services/starred_conversations_service.dart';
import '../../providers/unread_messages_provider.dart';

/// Shared utility for loading People context panel data
///
/// Used by both PeopleViewPage and MessagesViewPage to load
/// the same recent conversations data for the context panel.
///
/// This avoids code duplication between the two views.
class PeopleContextDataLoader {
  /// Load recent conversations for context panel
  ///
  /// Returns a list of people with their last messages and timestamps.
  /// Limit defaults to 10 to match context panel design.
  ///
  /// [unreadProvider] Optional provider to get unread counts for badges
  static Future<List<Map<String, dynamic>>> loadRecentPeople({
    int limit = 10,
    UnreadMessagesProvider? unreadProvider,
  }) async {
    try {
      debugPrint('[CONTEXT_DATA_LOADER] Loading recent conversations...');

      // Get recent conversations from service
      final recentConvs =
          await RecentConversationsService.getRecentConversations();
      debugPrint(
        '[CONTEXT_DATA_LOADER] Got ${recentConvs.length} recent conversations',
      );

      // Get message store for last messages
      final messageStore = await SqliteMessageStore.getInstance();

      final peopleList = <Map<String, dynamic>>[];

      for (final conv in recentConvs.take(limit)) {
        final userId = conv['uuid'];
        final displayName = conv['displayName'];
        final picture = conv['picture'];

        if (userId != null && userId.isNotEmpty) {
          // Get last message and unread count
          String lastMessage = '';
          String lastMessageTime = '';
          int unreadCount = 0;

          try {
            // Get last message
            final messages = await messageStore.getMessagesFromConversation(
              userId,
              limit: 1,
              types: ['message', 'file', 'image', 'voice'],
            );

            if (messages.isNotEmpty) {
              final lastMsg = messages.first;
              final msgType = lastMsg['type'] ?? 'message';

              // Format message preview
              lastMessage = formatMessagePreview(msgType, lastMsg['message']);

              // Pass raw ISO timestamp (not formatted) for Timer-based relative time display
              final timestamp = lastMsg['timestamp'];
              if (timestamp != null) {
                lastMessageTime = timestamp; // Raw ISO timestamp
              }
            }

            // Get unread count from provider
            if (unreadProvider != null) {
              unreadCount = unreadProvider.getDirectMessageUnreadCount(userId);
            }
          } catch (e) {
            debugPrint(
              '[CONTEXT_DATA_LOADER] Error loading last message for $userId: $e',
            );
          }

          // Get atName from UserProfileService
          final profile = UserProfileService.instance.getProfile(userId);

          peopleList.add({
            'uuid': userId,
            'displayName': displayName ?? userId,
            'atName': profile?['atName'] ?? '',
            'picture': picture ?? '',
            'online': false, // TODO: Add online status when available
            'lastMessage': lastMessage,
            'lastMessageTime': lastMessageTime,
            'unreadCount': unreadCount, // Add unread count for badge
            'isStarred': StarredConversationsService.instance.isStarred(userId),
          });
        }
      }

      // Sort people list: starred first, then unread messages, then by last message time
      peopleList.sort((a, b) {
        final aStarred = a['isStarred'] as bool? ?? false;
        final bStarred = b['isStarred'] as bool? ?? false;
        final aUnread = a['unreadCount'] as int? ?? 0;
        final bUnread = b['unreadCount'] as int? ?? 0;

        // Starred users come first
        if (aStarred && !bStarred) return -1;
        if (!aStarred && bStarred) return 1;

        // Then users with unread messages
        if (aUnread > 0 && bUnread == 0) return -1;
        if (aUnread == 0 && bUnread > 0) return 1;

        // If both have unread or both don't, maintain original order (by recent conversation time)
        return 0;
      });

      debugPrint('[CONTEXT_DATA_LOADER] Loaded ${peopleList.length} people');
      return peopleList;
    } catch (e, stackTrace) {
      debugPrint('[CONTEXT_DATA_LOADER] Error loading data: $e');
      debugPrint('[CONTEXT_DATA_LOADER] Stack trace: $stackTrace');
      return [];
    }
  }

  /// Load only starred conversations for context panel
  static Future<List<Map<String, dynamic>>> loadStarredPeople({
    UnreadMessagesProvider? unreadProvider,
  }) async {
    try {
      debugPrint('[CONTEXT_DATA_LOADER] Loading starred conversations...');

      // Get starred conversation IDs
      final starredIds = StarredConversationsService.instance
          .getStarredConversations();
      if (starredIds.isEmpty) {
        return [];
      }

      // Get all recent conversations
      final allConvs =
          await RecentConversationsService.getRecentConversations();

      // Filter to only starred ones
      final starredConvs = allConvs
          .where((conv) => starredIds.contains(conv['uuid']))
          .toList();

      // Get message store for last messages
      final messageStore = await SqliteMessageStore.getInstance();

      final peopleList = <Map<String, dynamic>>[];

      for (final conv in starredConvs) {
        final userId = conv['uuid'];
        final displayName = conv['displayName'];
        final picture = conv['picture'];

        if (userId != null && userId.isNotEmpty) {
          String lastMessage = '';
          String lastMessageTime = '';
          int unreadCount = 0;

          try {
            final messages = await messageStore.getMessagesFromConversation(
              userId,
              limit: 1,
              types: ['message', 'file', 'image', 'voice'],
            );

            if (messages.isNotEmpty) {
              final lastMsg = messages.first;
              final msgType = lastMsg['type'] ?? 'message';
              lastMessage = formatMessagePreview(msgType, lastMsg['message']);
              lastMessageTime = lastMsg['timestamp'];
            }

            if (unreadProvider != null) {
              unreadCount = unreadProvider.getDirectMessageUnreadCount(userId);
            }
          } catch (e) {
            debugPrint(
              '[CONTEXT_DATA_LOADER] Error loading starred conversation $userId: $e',
            );
          }

          final profile = UserProfileService.instance.getProfile(userId);

          peopleList.add({
            'uuid': userId,
            'displayName': displayName ?? userId,
            'atName': profile?['atName'] ?? '',
            'picture': picture ?? '',
            'online': false,
            'lastMessage': lastMessage,
            'lastMessageTime': lastMessageTime,
            'unreadCount': unreadCount,
            'isStarred': true,
          });
        }
      }

      debugPrint(
        '[CONTEXT_DATA_LOADER] Loaded ${peopleList.length} starred people',
      );
      return peopleList;
    } catch (e, stackTrace) {
      debugPrint('[CONTEXT_DATA_LOADER] Error loading starred data: $e');
      debugPrint('[CONTEXT_DATA_LOADER] Stack trace: $stackTrace');
      return [];
    }
  }

  /// Format message preview based on type
  static String formatMessagePreview(
    String messageType,
    String? messageContent,
  ) {
    switch (messageType) {
      case 'file':
        return '📎 File';
      case 'image':
        return '🖼️ Image';
      case 'voice':
        return '🎤 Voice';
      case 'message':
      default:
        final message = messageContent ?? '';
        if (message.length > 50) {
          return '${message.substring(0, 50)}...';
        }
        return message;
    }
  }
}
