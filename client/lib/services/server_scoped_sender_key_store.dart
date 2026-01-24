import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'sender_key_store.dart';

/// Wrapper for PermanentSenderKeyStore that adds server-scope context
/// This allows the same store to be used with different server contexts
/// without modifying the underlying store implementation
class ServerScopedSenderKeyStore extends SenderKeyStore {
  final PermanentSenderKeyStore _baseStore;
  final String _serverUrl;

  ServerScopedSenderKeyStore(this._baseStore, this._serverUrl);

  @override
  Future<void> storeSenderKey(
    SenderKeyName senderKeyName,
    SenderKeyRecord record,
  ) async {
    // For now, use base store (writing should always go to active server)
    return _baseStore.storeSenderKey(senderKeyName, record);
  }

  @override
  Future<SenderKeyRecord> loadSenderKey(SenderKeyName senderKeyName) async {
    // Load from server-specific storage
    return _baseStore.loadSenderKeyForServer(senderKeyName, _serverUrl);
  }
}
