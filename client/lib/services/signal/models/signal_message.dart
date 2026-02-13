/// Standardized 1:1 encrypted message model
///
/// Represents a direct message between two users with Signal Protocol encryption.
/// Used for consistent message handling across the application.
class SignalMessage {
  final String itemId;
  final String senderId;
  final String recipientId;
  final int senderDeviceId;
  final int recipientDeviceId;
  final String type;
  final String encryptedContent;
  final Map<String, dynamic>? metadata;
  final DateTime timestamp;
  final MessageStatus status;

  SignalMessage({
    required this.itemId,
    required this.senderId,
    required this.recipientId,
    required this.senderDeviceId,
    required this.recipientDeviceId,
    required this.type,
    required this.encryptedContent,
    this.metadata,
    DateTime? timestamp,
    this.status = MessageStatus.pending,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Create from server/socket data
  factory SignalMessage.fromJson(Map<String, dynamic> json) {
    return SignalMessage(
      itemId: json['itemId'] as String,
      senderId: json['senderId'] as String,
      recipientId: json['recipientId'] as String,
      senderDeviceId: json['senderDeviceId'] as int,
      recipientDeviceId: json['recipientDeviceId'] as int,
      type: json['type'] as String,
      encryptedContent: json['encryptedContent'] as String,
      metadata: json['metadata'] as Map<String, dynamic>?,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : DateTime.now(),
      status: _statusFromString(json['status'] as String?),
    );
  }

  /// Convert to JSON for storage/transmission
  Map<String, dynamic> toJson() {
    return {
      'itemId': itemId,
      'senderId': senderId,
      'recipientId': recipientId,
      'senderDeviceId': senderDeviceId,
      'recipientDeviceId': recipientDeviceId,
      'type': type,
      'encryptedContent': encryptedContent,
      'metadata': metadata,
      'timestamp': timestamp.toIso8601String(),
      'status': status.toString().split('.').last,
    };
  }

  /// Create a copy with updated fields
  SignalMessage copyWith({
    String? itemId,
    String? senderId,
    String? recipientId,
    int? senderDeviceId,
    int? recipientDeviceId,
    String? type,
    String? encryptedContent,
    Map<String, dynamic>? metadata,
    DateTime? timestamp,
    MessageStatus? status,
  }) {
    return SignalMessage(
      itemId: itemId ?? this.itemId,
      senderId: senderId ?? this.senderId,
      recipientId: recipientId ?? this.recipientId,
      senderDeviceId: senderDeviceId ?? this.senderDeviceId,
      recipientDeviceId: recipientDeviceId ?? this.recipientDeviceId,
      type: type ?? this.type,
      encryptedContent: encryptedContent ?? this.encryptedContent,
      metadata: metadata ?? this.metadata,
      timestamp: timestamp ?? this.timestamp,
      status: status ?? this.status,
    );
  }

  static MessageStatus _statusFromString(String? status) {
    switch (status) {
      case 'pending':
        return MessageStatus.pending;
      case 'sent':
        return MessageStatus.sent;
      case 'delivered':
        return MessageStatus.delivered;
      case 'read':
        return MessageStatus.read;
      case 'failed':
        return MessageStatus.failed;
      default:
        return MessageStatus.pending;
    }
  }

  @override
  String toString() {
    return 'SignalMessage(itemId: $itemId, type: $type, status: $status)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SignalMessage && other.itemId == itemId;
  }

  @override
  int get hashCode => itemId.hashCode;
}

/// Message delivery status
enum MessageStatus {
  /// Message created but not sent yet
  pending,

  /// Message sent to server
  sent,

  /// Message delivered to recipient's device
  delivered,

  /// Message read by recipient
  read,

  /// Message failed to send
  failed,
}
