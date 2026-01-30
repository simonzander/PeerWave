/// Standardized group encrypted message model
///
/// Represents a message in a group chat using Signal Protocol's SenderKey encryption.
/// Allows efficient one-to-many encryption for group conversations.
class GroupMessage {
  final String itemId;
  final String senderId;
  final String channelId;
  final int senderDeviceId;
  final String type;
  final String encryptedContent;
  final Map<String, dynamic>? metadata;
  final DateTime timestamp;
  final GroupMessageStatus status;
  final List<String>? reactions;
  final int? replyToItemId;

  GroupMessage({
    required this.itemId,
    required this.senderId,
    required this.channelId,
    required this.senderDeviceId,
    required this.type,
    required this.encryptedContent,
    this.metadata,
    DateTime? timestamp,
    this.status = GroupMessageStatus.pending,
    this.reactions,
    this.replyToItemId,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Create from server/socket data
  factory GroupMessage.fromJson(Map<String, dynamic> json) {
    return GroupMessage(
      itemId: json['itemId'] as String,
      senderId: json['senderId'] as String,
      channelId: json['channelId'] as String,
      senderDeviceId: json['senderDeviceId'] as int,
      type: json['type'] as String,
      encryptedContent: json['encryptedContent'] as String,
      metadata: json['metadata'] as Map<String, dynamic>?,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : DateTime.now(),
      status: _statusFromString(json['status'] as String?),
      reactions: (json['reactions'] as List?)?.cast<String>(),
      replyToItemId: json['replyToItemId'] as int?,
    );
  }

  /// Convert to JSON for storage/transmission
  Map<String, dynamic> toJson() {
    return {
      'itemId': itemId,
      'senderId': senderId,
      'channelId': channelId,
      'senderDeviceId': senderDeviceId,
      'type': type,
      'encryptedContent': encryptedContent,
      'metadata': metadata,
      'timestamp': timestamp.toIso8601String(),
      'status': status.toString().split('.').last,
      if (reactions != null) 'reactions': reactions,
      if (replyToItemId != null) 'replyToItemId': replyToItemId,
    };
  }

  /// Create a copy with updated fields
  GroupMessage copyWith({
    String? itemId,
    String? senderId,
    String? channelId,
    int? senderDeviceId,
    String? type,
    String? encryptedContent,
    Map<String, dynamic>? metadata,
    DateTime? timestamp,
    GroupMessageStatus? status,
    List<String>? reactions,
    int? replyToItemId,
  }) {
    return GroupMessage(
      itemId: itemId ?? this.itemId,
      senderId: senderId ?? this.senderId,
      channelId: channelId ?? this.channelId,
      senderDeviceId: senderDeviceId ?? this.senderDeviceId,
      type: type ?? this.type,
      encryptedContent: encryptedContent ?? this.encryptedContent,
      metadata: metadata ?? this.metadata,
      timestamp: timestamp ?? this.timestamp,
      status: status ?? this.status,
      reactions: reactions ?? this.reactions,
      replyToItemId: replyToItemId ?? this.replyToItemId,
    );
  }

  static GroupMessageStatus _statusFromString(String? status) {
    switch (status) {
      case 'pending':
        return GroupMessageStatus.pending;
      case 'sent':
        return GroupMessageStatus.sent;
      case 'failed':
        return GroupMessageStatus.failed;
      default:
        return GroupMessageStatus.pending;
    }
  }

  @override
  String toString() {
    return 'GroupMessage(itemId: $itemId, channelId: $channelId, type: $type, status: $status)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GroupMessage && other.itemId == itemId;
  }

  @override
  int get hashCode => itemId.hashCode;
}

/// Group message delivery status
enum GroupMessageStatus {
  /// Message created but not sent yet
  pending,

  /// Message sent to server/group
  sent,

  /// Message failed to send
  failed,
}
