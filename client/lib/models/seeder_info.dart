/// Information about a seeder (peer who has file chunks available)
/// 
/// Used in P2P file transfers to track which device has which chunks.
/// The deviceKey format is "userId:deviceId" for precise device targeting.
class SeederInfo {
  /// User ID of the seeder
  final String userId;
  
  /// Device ID of the seeder (specific device)
  final String deviceId;
  
  /// List of chunk indices that this seeder has available
  final List<int> availableChunks;
  
  SeederInfo({
    required this.userId,
    required this.deviceId,
    required this.availableChunks,
  });
  
  /// Combined key in format "userId:deviceId"
  /// Used for WebRTC connection targeting
  String get deviceKey => '$userId:$deviceId';
  
  /// Number of chunks this seeder has
  int get chunkCount => availableChunks.length;
  
  /// Check if seeder has a specific chunk
  bool hasChunk(int chunkIndex) {
    return availableChunks.contains(chunkIndex);
  }
  
  /// Create from deviceKey string (parses "userId:deviceId")
  factory SeederInfo.fromDeviceKey(String deviceKey, List<int> chunks) {
    final parts = deviceKey.split(':');
    if (parts.length != 2) {
      throw FormatException('Invalid deviceKey format: $deviceKey (expected userId:deviceId)');
    }
    
    return SeederInfo(
      userId: parts[0],
      deviceId: parts[1],
      availableChunks: chunks,
    );
  }
  
  @override
  String toString() {
    return 'SeederInfo(userId: $userId, deviceId: $deviceId, chunks: ${availableChunks.length})';
  }
  
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    
    return other is SeederInfo &&
        other.userId == userId &&
        other.deviceId == deviceId;
  }
  
  @override
  int get hashCode => userId.hashCode ^ deviceId.hashCode;
}

