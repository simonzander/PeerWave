// Platform selection for IO platforms (Android, iOS, Desktop)
import 'dart:io';
import 'notification_service_android.dart';
import 'notification_service.dart' as desktop;

/// Export the correct notification service based on platform
dynamic get notificationService {
  if (Platform.isAndroid || Platform.isIOS) {
    return NotificationServiceAndroid.instance;
  } else {
    // Desktop (Windows, macOS, Linux)
    return desktop.NotificationService.instance;
  }
}
