/// Model representing storage information
class StorageInfo {
  final String sessionStore;
  final String identityStore;
  final String preKeyStore;
  final String signedPreKeyStore;
  final String messageStore;

  const StorageInfo({
    required this.sessionStore,
    required this.identityStore,
    required this.preKeyStore,
    required this.signedPreKeyStore,
    required this.messageStore,
  });

  StorageInfo copyWith({
    String? sessionStore,
    String? identityStore,
    String? preKeyStore,
    String? signedPreKeyStore,
    String? messageStore,
  }) {
    return StorageInfo(
      sessionStore: sessionStore ?? this.sessionStore,
      identityStore: identityStore ?? this.identityStore,
      preKeyStore: preKeyStore ?? this.preKeyStore,
      signedPreKeyStore: signedPreKeyStore ?? this.signedPreKeyStore,
      messageStore: messageStore ?? this.messageStore,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'sessionStore': sessionStore,
      'identityStore': identityStore,
      'preKeyStore': preKeyStore,
      'signedPreKeyStore': signedPreKeyStore,
      'messageStore': messageStore,
    };
  }

  factory StorageInfo.fromJson(Map<String, dynamic> json) {
    return StorageInfo(
      sessionStore: json['sessionStore'] as String,
      identityStore: json['identityStore'] as String,
      preKeyStore: json['preKeyStore'] as String,
      signedPreKeyStore: json['signedPreKeyStore'] as String,
      messageStore: json['messageStore'] as String,
    );
  }

  static const empty = StorageInfo(
    sessionStore: 'N/A',
    identityStore: 'N/A',
    preKeyStore: 'N/A',
    signedPreKeyStore: 'N/A',
    messageStore: 'N/A',
  );
}
