import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:peerwave_client/core/version/version_info.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service to check for application updates from GitHub Releases
class UpdateChecker extends ChangeNotifier {
  static const String _lastCheckKey = 'last_update_check';
  static const String _dismissedVersionKey = 'dismissed_update_version';
  
  UpdateInfo? _latestUpdate;
  bool _isChecking = false;
  DateTime? _lastCheck;
  String? _dismissedVersion;
  
  UpdateInfo? get latestUpdate => _latestUpdate;
  bool get isChecking => _isChecking;
  bool get hasUpdate => _latestUpdate != null && !isUpdateDismissed;
  bool get isUpdateDismissed => _latestUpdate?.version == _dismissedVersion;
  
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final lastCheckStr = prefs.getString(_lastCheckKey);
    if (lastCheckStr != null) {
      _lastCheck = DateTime.parse(lastCheckStr);
    }
    _dismissedVersion = prefs.getString(_dismissedVersionKey);
    notifyListeners();
  }
  
  /// Check for updates from GitHub Releases API
  Future<void> checkForUpdates({bool force = false}) async {
    // Don't check too frequently unless forced
    if (!force && _lastCheck != null) {
      final hoursSinceLastCheck = DateTime.now().difference(_lastCheck!).inHours;
      if (hoursSinceLastCheck < 12) {
        debugPrint('[UpdateChecker] Skipping check (last check ${hoursSinceLastCheck}h ago)');
        return;
      }
    }
    
    _isChecking = true;
    notifyListeners();
    
    try {
      final response = await http.get(
        Uri.parse('https://api.github.com/repos/${VersionInfo.repository.split('/').skip(3).join('/')}/releases/latest'),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      ).timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final remoteVersion = (data['tag_name'] as String).replaceAll('v', '');
        
        // Compare versions
        if (_isNewerVersion(remoteVersion, VersionInfo.version)) {
          // Try to get latest.json for more info
          UpdateInfo? updateInfo;
          try {
            final manifestAsset = (data['assets'] as List).firstWhere(
              (asset) => asset['name'] == 'latest.json',
              orElse: () => null,
            );
            
            if (manifestAsset != null) {
              final manifestResponse = await http.get(
                Uri.parse(manifestAsset['browser_download_url']),
              ).timeout(const Duration(seconds: 5));
              
              if (manifestResponse.statusCode == 200) {
                final manifest = json.decode(manifestResponse.body);
                updateInfo = UpdateInfo.fromManifest(manifest);
              }
            }
          } catch (e) {
            debugPrint('[UpdateChecker] Could not fetch manifest: $e');
          }
          
          // Fallback to basic info from release API
          updateInfo ??= UpdateInfo(
            version: remoteVersion,
            releaseDate: DateTime.parse(data['published_at']),
            releaseUrl: data['html_url'],
            changelog: data['body'] ?? 'No changelog available',
            downloads: _extractDownloadsFromAssets(data['assets']),
          );
          
          _latestUpdate = updateInfo;
          debugPrint('[UpdateChecker] Update available: v$remoteVersion');
        } else {
          _latestUpdate = null;
          debugPrint('[UpdateChecker] No update available (latest: v$remoteVersion)');
        }
      } else {
        debugPrint('[UpdateChecker] GitHub API returned ${response.statusCode}');
      }
      
      _lastCheck = DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastCheckKey, _lastCheck!.toIso8601String());
      
    } catch (e) {
      debugPrint('[UpdateChecker] Error checking for updates: $e');
    } finally {
      _isChecking = false;
      notifyListeners();
    }
  }
  
  /// Dismiss the current update notification
  Future<void> dismissUpdate() async {
    if (_latestUpdate != null) {
      _dismissedVersion = _latestUpdate!.version;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_dismissedVersionKey, _dismissedVersion!);
      notifyListeners();
    }
  }
  
  /// Clear dismissed version (e.g., when user manually checks)
  Future<void> clearDismissed() async {
    _dismissedVersion = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_dismissedVersionKey);
    notifyListeners();
  }
  
  bool _isNewerVersion(String remote, String local) {
    final remoteParts = _parseVersion(remote);
    final localParts = _parseVersion(local);
    
    for (var i = 0; i < 3; i++) {
      if (remoteParts[i] > localParts[i]) return true;
      if (remoteParts[i] < localParts[i]) return false;
    }
    return false;
  }
  
  List<int> _parseVersion(String version) {
    final cleaned = version.split('+')[0]; // Remove build number
    final parts = cleaned.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return parts;
  }
  
  Map<String, String> _extractDownloadsFromAssets(List assets) {
    final downloads = <String, String>{};
    for (final asset in assets) {
      final name = asset['name'] as String;
      final url = asset['browser_download_url'] as String;
      
      if (name.contains('windows')) {
        downloads['windows'] = url;
      } else if (name.contains('macos')) {
        downloads['macos'] = url;
      } else if (name.contains('linux')) {
        downloads['linux'] = url;
      }
    }
    return downloads;
  }
}

/// Information about an available update
class UpdateInfo {
  final String version;
  final DateTime releaseDate;
  final String releaseUrl;
  final String changelog;
  final Map<String, String> downloads;
  final String? minServerVersion;
  final String? maxServerVersion;
  
  UpdateInfo({
    required this.version,
    required this.releaseDate,
    required this.releaseUrl,
    required this.changelog,
    required this.downloads,
    this.minServerVersion,
    this.maxServerVersion,
  });
  
  factory UpdateInfo.fromManifest(Map<String, dynamic> manifest) {
    return UpdateInfo(
      version: manifest['version'],
      releaseDate: DateTime.parse(manifest['release_date']),
      releaseUrl: manifest['release_url'],
      changelog: manifest['changelog'],
      downloads: Map<String, String>.from(manifest['downloads'] ?? {}),
      minServerVersion: manifest['compatibility']?['min_server_version'],
      maxServerVersion: manifest['compatibility']?['max_server_version'],
    );
  }
  
  String get displayVersion => 'v$version';
  
  String? getDownloadUrlForPlatform(String platform) {
    return downloads[platform.toLowerCase()];
  }
}
