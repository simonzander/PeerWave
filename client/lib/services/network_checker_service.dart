import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// Service to check network availability, especially for autostart scenarios
/// Only checks if network interface is up (no external connectivity test)
class NetworkCheckerService {
  static final Connectivity _connectivity = Connectivity();

  /// Wait for network interface to become available
  /// Returns true if network is up, false if timeout reached
  static Future<bool> waitForNetwork({
    Duration timeout = const Duration(minutes: 3),
    Duration checkInterval = const Duration(seconds: 2),
  }) async {
    final startTime = DateTime.now();
    int attemptCount = 0;

    debugPrint(
      '[NetworkChecker] Waiting for network (timeout: ${timeout.inMinutes}min)',
    );

    while (DateTime.now().difference(startTime) < timeout) {
      attemptCount++;

      try {
        final isAvailable = await isNetworkAvailable();

        if (isAvailable) {
          debugPrint(
            '[NetworkChecker] Network available after $attemptCount attempts',
          );
          return true;
        }

        debugPrint(
          '[NetworkChecker] Attempt $attemptCount: Network not yet available, '
          'retrying in ${checkInterval.inSeconds}s...',
        );

        await Future.delayed(checkInterval);
      } catch (e) {
        debugPrint('[NetworkChecker] Error checking network: $e');
        await Future.delayed(checkInterval);
      }
    }

    debugPrint('[NetworkChecker] Timeout reached after $attemptCount attempts');
    return false; // Timeout reached
  }

  /// Check if any network interface is currently up
  /// Returns true if WiFi, Ethernet, or Mobile data is available
  static Future<bool> isNetworkAvailable() async {
    try {
      final connectivityResult = await _connectivity.checkConnectivity();

      // Check if any connection is available (not none)
      final hasConnection = !connectivityResult.contains(
        ConnectivityResult.none,
      );

      if (hasConnection) {
        debugPrint('[NetworkChecker] Network interface: $connectivityResult');
      }

      return hasConnection;
    } catch (e) {
      debugPrint('[NetworkChecker] Error checking connectivity: $e');
      return false;
    }
  }
}
