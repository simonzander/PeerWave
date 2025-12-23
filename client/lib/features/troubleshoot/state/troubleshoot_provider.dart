import 'package:flutter/foundation.dart';
import '../models/key_metrics.dart';
import '../models/device_info.dart';
import '../models/server_config.dart';
import '../models/storage_info.dart';
import '../../../services/troubleshoot/troubleshoot_service.dart';

/// State management for troubleshoot page.
class TroubleshootProvider extends ChangeNotifier {
  final TroubleshootService _service;

  TroubleshootProvider({required TroubleshootService service})
    : _service = service;

  KeyMetrics? _metrics;
  DeviceInfo? _deviceInfo;
  ServerConfig? _serverConfig;
  StorageInfo? _storageInfo;
  Map<String, dynamic>? _networkMetrics;
  Map<String, int>? _signalProtocolCounts;
  bool _isLoading = false;
  String? _error;
  String? _successMessage;

  KeyMetrics? get metrics => _metrics;
  DeviceInfo? get deviceInfo => _deviceInfo;
  ServerConfig? get serverConfig => _serverConfig;
  StorageInfo? get storageInfo => _storageInfo;
  Map<String, dynamic>? get networkMetrics => _networkMetrics;
  Map<String, int>? get signalProtocolCounts => _signalProtocolCounts;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get successMessage => _successMessage;

  Future<void> loadMetrics() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _metrics = await _service.getKeyMetrics();
      _deviceInfo = await _service.getDeviceInfo();
      _serverConfig = await _service.getServerConfig();
      _storageInfo = await _service.getStorageInfo();
      _networkMetrics = _service.getNetworkMetrics();
      _signalProtocolCounts = await _service.getSignalProtocolCounts();
      _error = null;
    } catch (e) {
      _error = 'Failed to load metrics: $e';
      debugPrint('[TroubleshootProvider] Error loading metrics: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> deleteIdentityKey() async {
    await _executeAction(
      () => _service.deleteIdentityKey(),
      'Identity key deleted successfully',
    );
  }

  Future<void> deleteSignedPreKey() async {
    await _executeAction(
      () => _service.deleteSignedPreKey(),
      'Signed pre-key deleted successfully',
    );
  }

  Future<void> deletePreKeys() async {
    await _executeAction(
      () => _service.deletePreKeys(),
      'Pre-keys deleted successfully',
    );
  }

  Future<void> deleteGroupKey(String channelId) async {
    await _executeAction(
      () => _service.deleteGroupKey(channelId),
      'Group key deleted successfully',
    );
  }

  Future<void> deleteUserSession(String userId) async {
    await _executeAction(
      () => _service.deleteUserSession(userId),
      'User sessions deleted successfully',
    );
  }

  Future<void> deleteDeviceSession(String userId, int deviceId) async {
    await _executeAction(
      () => _service.deleteDeviceSession(userId, deviceId),
      'Device session deleted successfully',
    );
  }

  Future<void> forceSignedPreKeyRotation() async {
    await _executeAction(
      () => _service.forceSignedPreKeyRotation(),
      'Signed pre-key rotated successfully',
    );
  }

  Future<void> forcePreKeyRegeneration() async {
    await _executeAction(
      () => _service.forcePreKeyRegeneration(),
      'Pre-keys regenerated successfully',
    );
  }

  Future<List<Map<String, String>>> getActiveChannels() {
    return _service.getActiveChannels();
  }

  // ========== New Maintenance Operations ==========

  /// 1. Reset Network Metrics
  void resetNetworkMetrics() {
    _service.resetNetworkMetrics();
    _successMessage = 'Network metrics reset successfully';
    loadMetrics(); // Reload to show zeroed metrics
    notifyListeners();
  }

  /// 2. Force Socket Reconnect
  Future<void> forceSocketReconnect() async {
    await _executeAction(
      () => _service.forceSocketReconnect(),
      'Socket reconnected successfully',
    );
  }

  /// 3. Test Server Connection
  Future<void> testServerConnection() async {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();

    try {
      final success = await _service.testServerConnection();
      if (success) {
        _successMessage = '✓ Server responded to ping';
      } else {
        _error = 'Server did not respond (timeout or not connected)';
      }
    } catch (e) {
      _error = 'Connection test failed: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 5. Clear Signal Protocol Sessions
  Future<void> clearSignalSessions() async {
    await _executeAction(
      () => _service.clearSignalSessions(),
      'Signal Protocol sessions cleared successfully',
    );
  }

  /// 7. Sync Keys with Server
  Future<void> syncKeysWithServer() async {
    await _executeAction(
      () => _service.syncKeysWithServer(),
      'Key sync initiated successfully',
    );
  }

  /// Clear Message Storage - Delete all local messages
  Future<void> clearMessageStorage() async {
    await _executeAction(
      () => _service.clearMessageStorage(),
      'All message storage cleared successfully',
    );
  }

  Future<void> _executeAction(
    Future<void> Function() action,
    String successMsg,
  ) async {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();

    try {
      await action();
      _successMessage = successMsg;
      await loadMetrics(); // Reload metrics after action
    } catch (e) {
      _error = e.toString();
      debugPrint('[TroubleshootProvider] Error executing action: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void clearMessages() {
    _error = null;
    _successMessage = null;
    notifyListeners();
  }
}
