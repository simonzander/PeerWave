import 'package:flutter/foundation.dart';

/// Service to track currently active/open conversations
///
/// This service is used to suppress OS notifications for messages
/// in the currently open conversation (since the user is already viewing it).
class ActiveConversationService {
  static final ActiveConversationService _instance =
      ActiveConversationService._internal();
  static ActiveConversationService get instance => _instance;

  ActiveConversationService._internal();

  String? _activeDirectMessageUserId;
  String? _activeGroupChannelId;

  /// Set the currently active 1:1 conversation
  /// Call this when entering a direct message screen
  void setActiveDirectMessage(String userId) {
    _activeDirectMessageUserId = userId;
    _activeGroupChannelId = null; // Clear group
    debugPrint('[ActiveConversation] Set active DM: $userId');
  }

  /// Set the currently active group conversation
  /// Call this when entering a group/channel screen
  void setActiveGroupChannel(String channelId) {
    _activeGroupChannelId = channelId;
    _activeDirectMessageUserId = null; // Clear DM
    debugPrint('[ActiveConversation] Set active channel: $channelId');
  }

  /// Clear the active conversation
  /// Call this when leaving a conversation screen
  void clearActiveConversation() {
    _activeDirectMessageUserId = null;
    _activeGroupChannelId = null;
    debugPrint('[ActiveConversation] Cleared active conversation');
  }

  /// Check if the given direct message should suppress notifications
  /// Returns true if this DM is currently open and active
  bool shouldSuppressDirectMessageNotification(String userId) {
    return _activeDirectMessageUserId == userId;
  }

  /// Check if the given group message should suppress notifications
  /// Returns true if this channel is currently open and active
  bool shouldSuppressGroupNotification(String channelId) {
    return _activeGroupChannelId == channelId;
  }

  // Getters for current state (for debugging/testing)
  String? get activeDirectMessageUserId => _activeDirectMessageUserId;
  String? get activeGroupChannelId => _activeGroupChannelId;
  bool get hasActiveConversation =>
      _activeDirectMessageUserId != null || _activeGroupChannelId != null;
}
