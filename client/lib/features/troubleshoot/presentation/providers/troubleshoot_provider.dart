import 'package:flutter/foundation.dart';
import '../../domain/entities/key_metrics.dart';
import '../../domain/usecases/get_key_metrics.dart';
import '../../domain/repositories/troubleshoot_repository.dart';

/// State management for troubleshoot page.
class TroubleshootProvider extends ChangeNotifier {
  final GetKeyMetrics getKeyMetrics;
  final TroubleshootRepository repository;

  TroubleshootProvider({required this.getKeyMetrics, required this.repository});

  KeyMetrics? _metrics;
  bool _isLoading = false;
  String? _error;
  String? _successMessage;

  KeyMetrics? get metrics => _metrics;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get successMessage => _successMessage;

  Future<void> loadMetrics() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _metrics = await getKeyMetrics();
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
      () => repository.deleteIdentityKey(),
      'Identity key deleted successfully',
    );
  }

  Future<void> deleteSignedPreKey() async {
    await _executeAction(
      () => repository.deleteSignedPreKey(),
      'Signed pre-key deleted successfully',
    );
  }

  Future<void> deletePreKeys() async {
    await _executeAction(
      () => repository.deletePreKeys(),
      'Pre-keys deleted successfully',
    );
  }

  Future<void> deleteGroupKey(String channelId) async {
    await _executeAction(
      () => repository.deleteGroupKey(channelId),
      'Group key deleted successfully',
    );
  }

  Future<void> deleteUserSession(String userId) async {
    await _executeAction(
      () => repository.deleteUserSession(userId),
      'User sessions deleted successfully',
    );
  }

  Future<void> deleteDeviceSession(String userId, int deviceId) async {
    await _executeAction(
      () => repository.deleteDeviceSession(userId, deviceId),
      'Device session deleted successfully',
    );
  }

  Future<void> forceSignedPreKeyRotation() async {
    await _executeAction(
      () => repository.forceSignedPreKeyRotation(),
      'Signed pre-key rotated successfully',
    );
  }

  Future<void> forcePreKeyRegeneration() async {
    await _executeAction(
      () => repository.forcePreKeyRegeneration(),
      'Pre-keys regenerated successfully',
    );
  }

  Future<List<Map<String, String>>> getActiveChannels() {
    return repository.getActiveChannels();
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
