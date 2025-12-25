import 'package:flutter/foundation.dart' show debugPrint;
import 'signal_service.dart';
import 'api_service.dart';
import 'user_profile_service.dart';
import 'storage/sqlite_message_store.dart';
import 'storage/sqlite_recent_conversations_store.dart';
import 'dart:convert';

/// Service for aggregating and managing activities
/// - WebRTC channel participants
/// - Recent 1:1 conversations
/// - Recent Signal group conversations
class ActivitiesService {
  /// Get WebRTC channels where user is member/owner with participants
  static Future<List<Map<String, dynamic>>>
  getWebRTCChannelParticipants() async {
    try {
      ApiService.init();
      final resp = await ApiService.get('/client/channels?type=webrtc');

      if (resp.statusCode == 200) {
        final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
        final channels = (data['channels'] as List<dynamic>? ?? []);

        final channelsWithParticipants = <Map<String, dynamic>>[];

        for (final channel in channels) {
          // Get participants for each channel
          try {
            final participantsResp = await ApiService.get(
              '/client/channels/${channel['uuid']}/participants',
            );
            if (participantsResp.statusCode == 200) {
              final participantsData = participantsResp.data is String
                  ? jsonDecode(participantsResp.data)
                  : participantsResp.data;

              channelsWithParticipants.add({
                'uuid': channel['uuid'],
                'name': channel['name'],
                'type': 'webrtc',
                'participants': participantsData['participants'] ?? [],
              });
            }
          } catch (e) {
            debugPrint(
              '[ACTIVITIES_SERVICE] Error loading participants for channel ${channel['uuid']}: $e',
            );
          }
        }

        return channelsWithParticipants;
      }
    } catch (e) {
      debugPrint('[ACTIVITIES_SERVICE] Error loading WebRTC channels: $e');
    }
    return [];
  }

  /// Get recent 1:1 conversations with last messages
  static Future<List<Map<String, dynamic>>> getRecentDirectConversations({
    int limit = 20,
  }) async {
    final conversations = <Map<String, dynamic>>[];

    // Displayable message types whitelist
    const displayableTypes = {'message', 'file'};

    try {
      // Use SqliteMessageStore for better performance
      final messageStore = await SqliteMessageStore.getInstance();
      final conversationsStore =
          await SqliteRecentConversationsStore.getInstance();

      // Get recent conversation user IDs from SqliteRecentConversationsStore
      var recentConvs = await conversationsStore.getRecentConversations(
        limit: limit,
      );

      // FALLBACK: If conversations store is empty, get all unique senders from message store
      if (recentConvs.isEmpty) {
        debugPrint(
          '[ACTIVITIES_SERVICE] Conversations store empty, loading from message store...',
        );

        // Get all unique conversation partners from messages (FAST with index!)
        final uniqueSenders = await messageStore
            .getAllUniqueConversationPartners();

        debugPrint(
          '[ACTIVITIES_SERVICE] Found ${uniqueSenders.length} unique conversation partners',
        );

        // Create conversation objects
        recentConvs = uniqueSenders
            .map(
              (userId) => {
                'uuid': userId,
                'userId': userId,
                'displayName': userId, // Will be enriched later
              },
            )
            .toList();
      }

      // Get messages for each user (FAST with indexed queries!)
      for (final conv in recentConvs) {
        final userId = conv['userId'] ?? conv['uuid'];
        if (userId == null) continue;

        // Get all messages from this conversation (received + sent)
        // Uses indexed query: SELECT * FROM messages WHERE sender = ? ORDER BY timestamp DESC
        final allMessages = await messageStore.getMessagesFromConversation(
          userId,
          types: displayableTypes.toList(),
        );

        if (allMessages.isEmpty) continue;

        // Messages are already sorted by timestamp DESC
        // Get last 3 messages
        final lastMessages = allMessages
            .take(3)
            .map(
              (msg) => {
                'itemId': msg['itemId'],
                'message': msg['message'],
                'timestamp': msg['timestamp'],
                'sender': msg['direction'] == 'sent' ? 'self' : msg['sender'],
                'type': msg['type'],
              },
            )
            .toList();

        final lastMessageTime = allMessages.isNotEmpty
            ? DateTime.tryParse(allMessages.first['timestamp'] ?? '') ??
                  DateTime.fromMillisecondsSinceEpoch(0)
            : DateTime.fromMillisecondsSinceEpoch(0);

        conversations.add({
          'type': 'direct',
          'userId': userId,
          'displayName': conv['displayName'] ?? userId,
          'lastMessages': lastMessages,
          'lastMessageTime': lastMessageTime.toIso8601String(),
          'messageCount': allMessages.length,
        });
      }

      debugPrint(
        '[ACTIVITIES_SERVICE] Loaded ${conversations.length} direct conversations',
      );

      // Sort by last message time
      conversations.sort((a, b) {
        final timeA =
            DateTime.tryParse(a['lastMessageTime'] ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final timeB =
            DateTime.tryParse(b['lastMessageTime'] ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return timeB.compareTo(timeA);
      });

      final limitedConversations = conversations.take(limit).toList();

      // Enrich with actual display names from API (if displayName is still UUID)
      // This is needed when RecentConversationsService fallback is used
      final userIdsNeedingNames = limitedConversations
          .where(
            (conv) => conv['displayName'] == conv['userId'],
          ) // UUID used as name
          .map((conv) => conv['userId'] as String)
          .toList();

      if (userIdsNeedingNames.isNotEmpty) {
        debugPrint(
          '[ACTIVITIES_SERVICE] Enriching ${userIdsNeedingNames.length} user display names...',
        );
        // Note: This requires 'host' parameter - will be handled by caller or use UserProfileService
        for (final conv in limitedConversations) {
          final userId = conv['userId'] as String;
          if (userIdsNeedingNames.contains(userId)) {
            // Try UserProfileService first (might be cached from other parts of the app)
            final displayName = UserProfileService.instance.getDisplayName(
              userId,
            );
            if (displayName != userId) {
              conv['displayName'] = displayName;
            }
          }
        }
      }

      return limitedConversations;
    } catch (e) {
      debugPrint('[ACTIVITIES_SERVICE] Error loading direct conversations: $e');
    }

    return [];
  }

  /// Get recent Signal group conversations with last messages
  static Future<List<Map<String, dynamic>>> getRecentGroupConversations({
    int limit = 20,
  }) async {
    final conversations = <Map<String, dynamic>>[];

    // Displayable message types whitelist
    const displayableTypes = {'message', 'file'};

    try {
      // Get list of Signal channels from API
      ApiService.init();
      final resp = await ApiService.get(
        '/client/channels?type=signal&limit=100',
      );

      if (resp.statusCode != 200) return [];

      final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
      final channels = (data['channels'] as List<dynamic>? ?? []);

      final store = SignalService.instance.decryptedGroupItemsStore;

      // Get messages for each channel
      for (final channel in channels) {
        final channelId = channel['uuid'] as String?;
        if (channelId == null) continue;

        // Get received group messages
        final receivedMessages = await store.getChannelItems(channelId);

        // Get sent group items
        final sentMessages = await SignalService.instance.sentGroupItemsStore
            .loadSentItems(channelId);

        // Combine all messages and filter by type
        final allMessages = <Map<String, dynamic>>[
          ...receivedMessages.where(
            (msg) => displayableTypes.contains(msg['type'] ?? 'message'),
          ),
          ...sentMessages
              .where(
                (msg) => displayableTypes.contains(msg['type'] ?? 'message'),
              )
              .map(
                (msg) => {
                  'itemId': msg['itemId'],
                  'message': msg['message'],
                  'timestamp': msg['timestamp'],
                  'sender': 'self',
                  'type': msg['type'] ?? 'message',
                  'channelId': channelId,
                },
              ),
        ];

        if (allMessages.isEmpty) continue;

        // Sort by timestamp (newest first)
        allMessages.sort((a, b) {
          final timeA =
              DateTime.tryParse(a['timestamp'] ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0);
          final timeB =
              DateTime.tryParse(b['timestamp'] ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0);
          return timeB.compareTo(timeA);
        });

        // Get last 3 messages
        final lastMessages = allMessages.take(3).toList();
        final lastMessageTime = allMessages.isNotEmpty
            ? DateTime.tryParse(allMessages.first['timestamp'] ?? '') ??
                  DateTime.fromMillisecondsSinceEpoch(0)
            : DateTime.fromMillisecondsSinceEpoch(0);

        conversations.add({
          'type': 'group',
          'channelId': channelId,
          'channelName': channel['name'] ?? channelId,
          'lastMessages': lastMessages,
          'lastMessageTime': lastMessageTime.toIso8601String(),
          'messageCount': allMessages.length,
        });
      }

      debugPrint(
        '[ACTIVITIES_SERVICE] Loaded ${conversations.length} group conversations',
      );

      // Sort by last message time
      conversations.sort((a, b) {
        final timeA =
            DateTime.tryParse(a['lastMessageTime'] ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final timeB =
            DateTime.tryParse(b['lastMessageTime'] ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return timeB.compareTo(timeA);
      });

      return conversations.take(limit).toList();
    } catch (e) {
      debugPrint('[ACTIVITIES_SERVICE] Error loading group conversations: $e');
    }

    return [];
  }

  /// Mix and sort conversations (direct + group)
  static List<Map<String, dynamic>> mixAndSortConversations(
    List<Map<String, dynamic>> directConvs,
    List<Map<String, dynamic>> groupConvs, {
    int limit = 20,
  }) {
    final mixed = [...directConvs, ...groupConvs];

    // Sort by last message time
    mixed.sort((a, b) {
      final timeA =
          DateTime.tryParse(a['lastMessageTime'] ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final timeB =
          DateTime.tryParse(b['lastMessageTime'] ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return timeB.compareTo(timeA);
    });

    return mixed.take(limit).toList();
  }
}
