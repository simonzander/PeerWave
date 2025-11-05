import 'package:uuid/uuid.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ClientIdService {
  static const _key = 'client_id';
  static final _storage = FlutterSecureStorage();
  static String? _clientId;

  static Future<String> getClientId() async {
    if (_clientId != null) return _clientId!;
    String? storedId = await _storage.read(key: _key);
    if (storedId != null) {
      _clientId = storedId;
      return _clientId!;
    }
    // Generate new UUID and persist
    final uuid = Uuid().v4();
    await _storage.write(key: _key, value: uuid);
    _clientId = uuid;
    return _clientId!;
  }
}

