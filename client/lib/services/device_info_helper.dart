import 'dart:io' show Platform;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// Helper service to collect and format device information
/// for display in sessions/devices list
class DeviceInfoHelper {
  static final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  /// Get a user-friendly device name string
  /// Examples:
  /// - "PeerWave Client Windows 11 - DESKTOP-PC"
  /// - "PeerWave Client Android 13 - Samsung Galaxy S23"
  /// - "PeerWave Client iOS 17.2 - iPhone 15 Pro"
  /// - "PeerWave Client macOS 14.2 - MacBook Pro"
  /// - "PeerWave Client Web - Chrome 120"
  static Future<String> getDeviceDisplayName() async {
    if (kIsWeb) {
      return await _getWebDeviceName();
    }

    if (Platform.isAndroid) {
      return await _getAndroidDeviceName();
    } else if (Platform.isIOS) {
      return await _getIOSDeviceName();
    } else if (Platform.isWindows) {
      return await _getWindowsDeviceName();
    } else if (Platform.isMacOS) {
      return await _getMacOSDeviceName();
    } else if (Platform.isLinux) {
      return await _getLinuxDeviceName();
    }

    return 'PeerWave Client Unknown';
  }

  static Future<String> _getAndroidDeviceName() async {
    try {
      final androidInfo = await _deviceInfo.androidInfo;
      final brand = androidInfo.brand ?? 'Android';
      final model = androidInfo.model ?? 'Device';
      final version = androidInfo.version.release ?? '';

      // Format: "PeerWave Client Android 13 - Samsung SM-G991B"
      return 'PeerWave Client Android $version - ${_capitalize(brand)} $model';
    } catch (e) {
      return 'PeerWave Client Android';
    }
  }

  static Future<String> _getIOSDeviceName() async {
    try {
      final iosInfo = await _deviceInfo.iosInfo;
      final name =
          iosInfo.name ??
          'iOS Device'; // User's device name like "John's iPhone"
      final model = iosInfo.model ?? 'iPhone';
      final version = iosInfo.systemVersion ?? '';

      // Prefer user-set device name if available, otherwise use model
      final deviceName = name.isNotEmpty ? name : model;

      // Format: "PeerWave Client iOS 17.2 - John's iPhone"
      return 'PeerWave Client iOS $version - $deviceName';
    } catch (e) {
      return 'PeerWave Client iOS';
    }
  }

  static Future<String> _getWindowsDeviceName() async {
    try {
      final windowsInfo = await _deviceInfo.windowsInfo;
      final computerName = windowsInfo.computerName;
      final productName =
          windowsInfo.productName ?? 'Windows'; // e.g., "Windows 11 Pro"

      // Format: "PeerWave Client Windows 11 - DESKTOP-PC"
      return 'PeerWave Client $productName - $computerName';
    } catch (e) {
      return 'PeerWave Client Windows';
    }
  }

  static Future<String> _getMacOSDeviceName() async {
    try {
      final macInfo = await _deviceInfo.macOsInfo;
      final computerName = macInfo.computerName;
      final model = macInfo.model ?? 'Mac';
      final version = macInfo.osRelease ?? '';

      // macOS version mapping (simplified - you could expand this)
      String osVersion = 'macOS';
      if (version.startsWith('23')) {
        osVersion = 'macOS 14 Sonoma';
      } else if (version.startsWith('22')) {
        osVersion = 'macOS 13 Ventura';
      } else if (version.startsWith('21')) {
        osVersion = 'macOS 12 Monterey';
      }

      // Format: "PeerWave Client macOS 14 Sonoma - MacBook Pro"
      return 'PeerWave Client $osVersion - $computerName';
    } catch (e) {
      return 'PeerWave Client macOS';
    }
  }

  static Future<String> _getLinuxDeviceName() async {
    try {
      final linuxInfo = await _deviceInfo.linuxInfo;
      final name = linuxInfo.name ?? 'Linux';
      final version = linuxInfo.versionId ?? '';
      final prettyName = linuxInfo.prettyName ?? '$name $version';

      // Try to get hostname (computer name)
      String hostname = 'Linux-PC';
      try {
        hostname = Platform.localHostname;
      } catch (_) {}

      // Format: "PeerWave Client Ubuntu 22.04 - hostname"
      return 'PeerWave Client $prettyName - $hostname';
    } catch (e) {
      return 'PeerWave Client Linux';
    }
  }

  static Future<String> _getWebDeviceName() async {
    try {
      final webInfo = await _deviceInfo.webBrowserInfo;
      final browserName = webInfo.browserName.name ?? 'Browser';
      final platform = webInfo.platform ?? 'Web';

      // Format: "PeerWave Web Chrome - Windows"
      return 'PeerWave Web ${_capitalize(browserName)} - $platform';
    } catch (e) {
      return 'PeerWave Web Browser';
    }
  }

  /// Capitalize first letter of a string
  static String _capitalize(String text) {
    if (text.isEmpty) return text;
    return text[0].toUpperCase() + text.substring(1);
  }

  /// Get a short device identifier for debugging
  /// Example: "Android-Samsung-SM991B" or "Windows-DESKTOP-PC"
  static Future<String> getDeviceIdentifier() async {
    if (kIsWeb) {
      final webInfo = await _deviceInfo.webBrowserInfo;
      return 'Web-${webInfo.browserName.name}';
    }

    if (Platform.isAndroid) {
      final androidInfo = await _deviceInfo.androidInfo;
      return 'Android-${androidInfo.brand}-${androidInfo.model}'.replaceAll(
        ' ',
        '-',
      );
    } else if (Platform.isIOS) {
      final iosInfo = await _deviceInfo.iosInfo;
      return 'iOS-${iosInfo.model}'.replaceAll(' ', '-');
    } else if (Platform.isWindows) {
      final windowsInfo = await _deviceInfo.windowsInfo;
      return 'Windows-${windowsInfo.computerName}';
    } else if (Platform.isMacOS) {
      final macInfo = await _deviceInfo.macOsInfo;
      return 'macOS-${macInfo.computerName}';
    } else if (Platform.isLinux) {
      try {
        return 'Linux-${Platform.localHostname}';
      } catch (_) {
        return 'Linux-Unknown';
      }
    }

    return 'Unknown';
  }
}
