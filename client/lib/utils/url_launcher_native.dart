import 'package:url_launcher/url_launcher.dart';

/// Native implementation of URL launcher using package:url_launcher
class UrlLauncher {
  /// Check if URL can be launched
  static Future<bool> canLaunch(String url) async {
    final uri = Uri.parse(url);
    return await canLaunchUrl(uri);
  }

  /// Launch URL in external application
  static Future<void> launch(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
